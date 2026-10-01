
create unique index if not exists buyers_domain_unique_idx
on commercial_intel.buyers (lower(domain))
where domain is not null;

create or replace function public.solidos_claim_buyer_discovery_jobs(p_limit integer default 5)
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_enabled boolean;
  v_outreach boolean;
  v_strict boolean;
  v_pii boolean;
  v_jobs jsonb;
begin
  select buyer_hunting_enabled,buyer_outreach_enabled,strict_compliance,allow_personal_pii_export
  into v_enabled,v_outreach,v_strict,v_pii
  from commercial_intel.settings
  where id=true;

  if not coalesce(v_enabled,false) then
    return jsonb_build_object('enabled',false,'jobs','[]'::jsonb,'reason','buyer_hunting_disabled');
  end if;

  if coalesce(v_outreach,false) or coalesce(v_pii,false) or not coalesce(v_strict,false) then
    raise exception 'commercial buyer discovery compliance guard failed';
  end if;

  with picked as (
    select id
    from commercial_intel.work_queue
    where kind='BUYER_DISCOVERY'
      and status='pending'
      and available_at<=now()
    order by priority desc,created_at
    for update skip locked
    limit greatest(1,least(coalesce(p_limit,5),10))
  ),
  claimed as (
    update commercial_intel.work_queue q
    set status='running',
        locked_at=now(),
        locked_by='commercial-intel-buyer-worker',
        attempts=attempts+1,
        updated_at=now()
    from picked p
    where q.id=p.id
    returning q.id,q.payload,q.priority,q.attempts
  )
  select coalesce(jsonb_agg(to_jsonb(claimed)),'[]'::jsonb)
  into v_jobs
  from claimed;

  return jsonb_build_object(
    'enabled',true,
    'strict_compliance',v_strict,
    'buyer_outreach_enabled',v_outreach,
    'allow_personal_pii_export',v_pii,
    'jobs',v_jobs
  );
end
$function$;

create or replace function public.solidos_finish_buyer_discovery_job(
  p_job_id uuid,
  p_candidates jsonb default '[]'::jsonb,
  p_error text default null,
  p_blocked boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_job commercial_intel.work_queue%rowtype;
  v_item jsonb;
  v_domain text;
  v_buyer_id uuid;
  v_product_id uuid;
  v_inserted int := 0;
  v_matched int := 0;
  v_updated int := 0;
begin
  select * into v_job
  from commercial_intel.work_queue
  where id=p_job_id
  for update;

  if v_job.id is null then
    raise exception 'buyer discovery job not found';
  end if;

  if p_error is not null then
    update commercial_intel.work_queue
    set status=case when p_blocked then 'blocked' else 'failed' end,
        last_error=left(p_error,500),
        locked_at=null,
        locked_by=null,
        updated_at=now()
    where id=p_job_id;

    return jsonb_build_object('ok',false,'job_id',p_job_id,'blocked',p_blocked,'error',left(p_error,500));
  end if;

  v_product_id := nullif(v_job.payload->>'product_id','')::uuid;

  for v_item in
    select value from jsonb_array_elements(coalesce(p_candidates,'[]'::jsonb))
  loop
    if v_item ?| array['person_name','personal_email','personal_phone','decision_maker_name','raw_contact_snippet'] then
      continue;
    end if;

    v_domain := lower(trim(coalesce(v_item->>'domain','')));
    if v_domain='' then continue; end if;

    select id into v_buyer_id
    from commercial_intel.buyers
    where lower(domain)=v_domain
    limit 1;

    if v_buyer_id is null then
      insert into commercial_intel.buyers(
        company_name,website_url,domain,buyer_type,use_case,fit_score,status,
        contact_route,personal_pii_stored,metadata
      )
      values(
        left(coalesce(nullif(trim(v_item->>'company_name'),''),v_domain),200),
        nullif(trim(v_item->>'website_url'),''),
        v_domain,
        nullif(trim(v_item->>'buyer_type'),''),
        nullif(trim(v_item->>'use_case'),''),
        greatest(0,least(100,coalesce((v_item->>'fit_score')::numeric,60))),
        'candidate',
        null,
        false,
        jsonb_build_object(
          'discovered_by','commercial-intel-buyer-worker',
          'provider',coalesce(nullif(v_item->>'provider',''),'tavily'),
          'source_url',nullif(v_item->>'source_url',''),
          'source_title',nullif(v_item->>'source_title',''),
          'query',nullif(v_item->>'query',''),
          'public_company_data_only',true,
          'personal_pii_stored',false,
          'discovered_at',now()
        )
      )
      returning id into v_buyer_id;
      v_inserted := v_inserted+1;
    else
      update commercial_intel.buyers
      set website_url=coalesce(nullif(trim(v_item->>'website_url'),''),website_url),
          company_name=coalesce(nullif(trim(v_item->>'company_name'),''),company_name),
          buyer_type=coalesce(nullif(trim(v_item->>'buyer_type'),''),buyer_type),
          use_case=coalesce(nullif(trim(v_item->>'use_case'),''),use_case),
          fit_score=greatest(fit_score,coalesce((v_item->>'fit_score')::numeric,fit_score)),
          personal_pii_stored=false,
          updated_at=now()
      where id=v_buyer_id;
      v_updated := v_updated+1;
    end if;

    if v_product_id is not null then
      insert into commercial_intel.buyer_matches(
        buyer_id,product_id,match_score,reasons,sample_size,status,evaluated_at
      )
      values(
        v_buyer_id,v_product_id,
        greatest(0,least(100,coalesce((v_item->>'fit_score')::numeric,60))),
        array['Discovered from product audience query','Company-level public website only']::text[],
        0,'candidate',now()
      )
      on conflict (buyer_id,product_id) do update
      set match_score=greatest(commercial_intel.buyer_matches.match_score,excluded.match_score),
          reasons=excluded.reasons,
          status='candidate',
          evaluated_at=now();
      v_matched := v_matched+1;
    end if;
  end loop;

  update commercial_intel.work_queue
  set status='done',
      last_error=null,
      locked_at=null,
      locked_by=null,
      updated_at=now()
  where id=p_job_id;

  insert into commercial_intel.audit_log(actor,action,entity_type,entity_id,reason,after_state)
  values(
    'commercial-intel-buyer-worker','BUYER_DISCOVERY_COMPLETE','work_queue',p_job_id::text,
    'Company-level buyer discovery completed; outreach and personal PII remained disabled',
    jsonb_build_object('inserted',v_inserted,'updated',v_updated,'matched',v_matched)
  );

  perform solidos_control.request_sheet_sync(
    'COMMERCIAL_PRODUCTS',
    'buyer_discovery_complete',
    jsonb_build_object('job_id',p_job_id,'inserted',v_inserted,'matched',v_matched)
  );

  return jsonb_build_object('ok',true,'job_id',p_job_id,'inserted',v_inserted,'updated',v_updated,'matched',v_matched);
end
$function$;

revoke all on function public.solidos_claim_buyer_discovery_jobs(integer) from public,anon,authenticated;
revoke all on function public.solidos_finish_buyer_discovery_job(uuid,jsonb,text,boolean) from public,anon,authenticated;
grant execute on function public.solidos_claim_buyer_discovery_jobs(integer) to service_role;
grant execute on function public.solidos_finish_buyer_discovery_job(uuid,jsonb,text,boolean) to service_role;
