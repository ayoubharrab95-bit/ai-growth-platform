create or replace function public.solidos_prepare_commercial_sheet_sync()
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_manifest jsonb;
  v_cycle uuid;
begin
  v_manifest := commercial_intel.prepare_sheet_sync_cycle();
  v_cycle := (v_manifest->>'cycle_id')::uuid;

  update commercial_intel.sheet_sync_cycles
  set status='syncing', error=null
  where id=v_cycle;

  return jsonb_build_object(
    'manifest', v_manifest,
    'products', coalesce((
      select jsonb_agg(to_jsonb(p) order by p.slug)
      from (
        select id,slug,name,plan_tier,audience,description,price_hint_monthly,price_hint_one_time,
               status,max_records,freshness_days,requires_commercial_safe,pii_allowed
        from commercial_intel.products
        where status='active'
      ) p
    ),'[]'::jsonb),
    'fields', coalesce((
      select jsonb_agg(to_jsonb(f) order by f.field_key)
      from (
        select field_key,display_name,category,sensitivity,default_export_status,description
        from commercial_intel.field_catalog
        where default_export_status='ALLOW'
      ) f
    ),'[]'::jsonb),
    'rows', coalesce((
      select jsonb_agg(to_jsonb(r) order by r.product_slug,r.bucket,r.product_score desc nulls last,r.company_name)
      from (
        select cycle_id,product_id,product_slug,company_id,bucket,company_name,canonical_domain,website_url,
               trade,location_text,state,country,product_score,commercial_score,opportunity_score,priority_band,
               recommended_offer,rights_status,commercial_status,freshness_score,source_first_seen,
               match_reasons,restriction_reasons,business_signals,evidence_domains,payload,evaluated_at
        from commercial_intel.sheet_sync_rows
        where cycle_id=v_cycle
      ) r
    ),'[]'::jsonb),
    'versions', coalesce((
      select jsonb_agg(to_jsonb(v) order by v.product_id,v.version_no desc)
      from (
        select distinct on (dv.product_id,dv.version_no)
               dv.product_id,dv.version_no,dv.snapshot_at,dv.record_count,dv.safe_record_count,
               dv.review_record_count,dv.schema_version,dv.checksum,dv.status
        from commercial_intel.dataset_versions dv
        order by dv.product_id,dv.version_no desc
      ) v
    ),'[]'::jsonb),
    'agents', coalesce((
      select jsonb_agg(to_jsonb(a) order by a.slug)
      from (
        select slug,name,role,lifecycle_state,write_scope,reads_core,can_export,
               can_change_rights_status,can_contact_buyers
        from commercial_intel.agents
      ) a
    ),'[]'::jsonb),
    'rights', coalesce((
      select jsonb_agg(to_jsonb(r) order by r.source_slug)
      from (
        select source_slug,source_name,source_type,provider,rights_status,public_url,
               review_evidence_url,review_reason,reviewed_at,reviewed_by
        from commercial_intel.source_rights
      ) r
    ),'[]'::jsonb),
    'buyers', coalesce((
      select jsonb_agg(to_jsonb(b) order by b.company_name)
      from (
        select company_name,website_url,domain,buyer_type,target_trades,target_markets,use_case,
               fit_score,status,contact_route,personal_pii_stored
        from commercial_intel.buyers
      ) b
    ),'[]'::jsonb),
    'runs', coalesce((
      select jsonb_agg(to_jsonb(ar) order by ar.started_at desc)
      from (
        select agent_slug,run_type,status,input_count,output_count,blocked_count,started_at,finished_at
        from commercial_intel.agent_runs
        order by started_at desc
        limit 500
      ) ar
    ),'[]'::jsonb),
    'audit', coalesce((
      select jsonb_agg(to_jsonb(al) order by al.event_at desc)
      from (
        select event_at,actor,action,entity_type,entity_id,reason
        from commercial_intel.audit_log
        order by event_at desc
        limit 500
      ) al
    ),'[]'::jsonb)
  );
end
$function$;

create or replace function public.solidos_finish_commercial_sheet_sync(
  p_cycle_id uuid,
  p_success boolean,
  p_error text default null
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  r record;
  v_version bigint;
  v_safe int;
  v_review int;
  v_total int;
  v_checksum text;
  v_versions jsonb;
begin
  if not p_success then
    update commercial_intel.sheet_sync_cycles
    set status='failed', error=left(coalesce(p_error,'native sheet sync failed'),1000), finished_at=now()
    where id=p_cycle_id;

    update commercial_intel.sheet_targets
    set last_sync_at=now(), last_sync_status='FAILED',
        last_error=left(coalesce(p_error,'native sheet sync failed'),1000), updated_at=now()
    where sync_enabled;

    return jsonb_build_object('ok',false,'cycle_id',p_cycle_id);
  end if;

  for r in
    select p.id as product_id,p.slug,st.id as target_id,st.target_key
    from commercial_intel.products p
    join commercial_intel.sheet_targets st on st.product_id=p.id
    where p.status='active' and st.sync_enabled
  loop
    select count(*)::int,
           count(*) filter(where bucket='SAFE')::int,
           count(*) filter(where bucket='REVIEW')::int,
           md5(coalesce(string_agg(company_id::text||':'||bucket||':'||coalesce(product_score::text,'')||':'||
                                   coalesce(commercial_score::text,'')||':'||coalesce(rights_status,'')||':'||
                                   coalesce(commercial_status,''),'|' order by company_id),''))
    into v_total,v_safe,v_review,v_checksum
    from commercial_intel.sheet_sync_rows
    where cycle_id=p_cycle_id and product_id=r.product_id;

    select coalesce(max(version_no),0)+1 into v_version
    from commercial_intel.dataset_versions
    where product_id=r.product_id;

    insert into commercial_intel.dataset_versions(
      product_id,version_no,snapshot_at,record_count,safe_record_count,review_record_count,
      schema_version,checksum,status,sheet_target_id,metadata
    )
    select r.product_id,v_version,c.snapshot_at,v_total,v_safe,v_review,2,v_checksum,'published',
           r.target_id,jsonb_build_object('cycle_id',p_cycle_id,'native_writer','solidos-sheet-sync')
    from commercial_intel.sheet_sync_cycles c
    where c.id=p_cycle_id;

    update commercial_intel.sheet_targets
    set last_snapshot_at=(select snapshot_at from commercial_intel.sheet_sync_cycles where id=p_cycle_id),
        last_sync_at=now(),last_sync_status='SUCCESS',last_error=null,updated_at=now()
    where id=r.target_id;
  end loop;

  update commercial_intel.sheet_targets
  set last_snapshot_at=(select snapshot_at from commercial_intel.sheet_sync_cycles where id=p_cycle_id),
      last_sync_at=now(),last_sync_status='SUCCESS',last_error=null,updated_at=now()
  where target_key='MASTER' and sync_enabled;

  update commercial_intel.sheet_sync_cycles
  set status='succeeded',error=null,finished_at=now()
  where id=p_cycle_id;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.product_id,x.version_no desc),'[]'::jsonb)
  into v_versions
  from (
    select dv.product_id,dv.version_no,dv.snapshot_at,dv.record_count,dv.safe_record_count,
           dv.review_record_count,dv.schema_version,dv.checksum,dv.status
    from commercial_intel.dataset_versions dv
    where dv.product_id in (select id from commercial_intel.products where status='active')
    order by dv.product_id,dv.version_no desc
  ) x;

  return jsonb_build_object('ok',true,'cycle_id',p_cycle_id,'versions',v_versions);
end
$function$;

revoke all on function public.solidos_prepare_commercial_sheet_sync() from public,anon,authenticated;
revoke all on function public.solidos_finish_commercial_sheet_sync(uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.solidos_prepare_commercial_sheet_sync() to service_role;
grant execute on function public.solidos_finish_commercial_sheet_sync(uuid,boolean,text) to service_role;
