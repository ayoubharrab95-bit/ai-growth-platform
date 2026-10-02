
create index if not exists business_signals_active_company_idx
  on commercial_intel.business_signals(company_id)
  where active;
create index if not exists product_memberships_eligible_company_product_idx
  on commercial_intel.product_memberships(company_id,product_id)
  where eligible;

CREATE OR REPLACE FUNCTION commercial_intel.cleanup_sheet_sync_cycles()
 RETURNS integer
 LANGUAGE plpgsql
 SET search_path TO 'commercial_intel', 'pg_catalog'
AS $function$
declare
  v_count integer;
begin
  with doomed as (
    select id
    from commercial_intel.sheet_sync_cycles
    where snapshot_at<now()-interval '24 hours'
      and status in ('succeeded','failed')
  ),
  deleted as (
    delete from commercial_intel.sheet_sync_cycles c
    using doomed d
    where c.id=d.id
    returning c.id
  )
  select count(*) into v_count from deleted;
  return v_count;
end
$function$
;

CREATE OR REPLACE FUNCTION commercial_intel.prepare_sheet_sync_cycle()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'commercial_intel', 'booked_solid', 'pg_catalog'
AS $function$
declare
  v_cycle uuid:=gen_random_uuid();
  v_snapshot timestamptz:=now();
  v_manifest jsonb;
begin
  insert into commercial_intel.sheet_sync_cycles(id,snapshot_at,status)
  values(v_cycle,v_snapshot,'preparing');

  with active_signals as materialized (
    select company_id,signal_type,evidence_count,source_domains
    from commercial_intel.business_signals
    where active
  ),
  signal_counts as (
    select company_id,jsonb_object_agg(signal_type,evidence_count) signal_counts
    from active_signals
    group by company_id
  ),
  signal_domains as (
    select a.company_id,array_agg(distinct d order by d) evidence_domains
    from active_signals a
    cross join lateral unnest(coalesce(a.source_domains,'{}'::text[])) d
    group by a.company_id
  ),
  sig as (
    select coalesce(c.company_id,d.company_id) company_id,
           coalesce(c.signal_counts,'{}'::jsonb) signal_counts,
           coalesce(d.evidence_domains,'{}'::text[]) evidence_domains
    from signal_counts c
    full join signal_domains d using(company_id)
  )
  insert into commercial_intel.sheet_sync_rows(
    cycle_id,product_id,product_slug,company_id,bucket,company_name,canonical_domain,
    website_url,trade,location_text,state,country,product_score,commercial_score,
    opportunity_score,priority_band,recommended_offer,why_now,rights_status,
    commercial_status,freshness_score,source_first_seen,match_reasons,
    restriction_reasons,business_signals,evidence_domains,payload,evaluated_at
  )
  select
    v_cycle,p.id,p.slug,ca.company_id,
    case when pm.exportable then 'SAFE' else 'REVIEW' end,
    ca.company_name,ca.canonical_domain,ca.website_url,ca.trade,ca.location_text,
    ca.state,ca.country,pm.product_score,ca.commercial_score,ca.opportunity_score,
    ca.priority_band,ca.recommended_offer,ca.why_now,ca.rights_status,
    ca.commercial_status,ca.freshness_score,ca.source_first_seen,pm.match_reasons,
    ca.restriction_reasons,coalesce(sig.signal_counts,'{}'::jsonb),
    coalesce(sig.evidence_domains,'{}'::text[]),
    jsonb_strip_nulls(
      ca.safe_company_payload ||
      jsonb_build_object(
        'product_score',round(pm.product_score::numeric,2),
        'why_now',case when pm.exportable then ca.why_now else null end,
        'business_signals',coalesce(sig.signal_counts,'{}'::jsonb),
        'evidence_domains',to_jsonb(coalesce(sig.evidence_domains,'{}'::text[])),
        'rights_status',ca.rights_status,
        'commercial_status',ca.commercial_status,
        'freshness_score',round(ca.freshness_score::numeric,2)
      )
    ),
    pm.evaluated_at
  from commercial_intel.product_memberships pm
  join commercial_intel.products p on p.id=pm.product_id and p.status='active'
  join commercial_intel.company_assets ca on ca.company_id=pm.company_id
  left join sig on sig.company_id=ca.company_id
  where pm.eligible=true;

  with product_stats as (
    select product_id,
           count(*) eligible,
           count(*) filter(where bucket='SAFE') safe,
           count(*) filter(where bucket='REVIEW') review
    from commercial_intel.sheet_sync_rows
    where cycle_id=v_cycle
    group by product_id
  )
  select jsonb_build_object(
    'cycle_id',v_cycle,
    'snapshot_at',v_snapshot,
    'schema_version',2,
    'safety',jsonb_build_object(
      'personal_pii_export',false,
      'direct_personal_email_export',false,
      'direct_personal_phone_export',false,
      'blocked_keys',jsonb_build_array('person_name','personal_email','personal_phone','decision_maker_name','raw_contact_snippet')
    ),
    'assets',jsonb_build_object(
      'total',(select count(*) from commercial_intel.company_assets),
      'safe',(select count(*) from commercial_intel.company_assets where commercial_status='COMMERCIAL_SAFE'),
      'review',(select count(*) from commercial_intel.company_assets where commercial_status='REVIEW_REQUIRED'),
      'blocked',(select count(*) from commercial_intel.company_assets where commercial_status='BLOCKED_FROM_RESALE')
    ),
    'rights',jsonb_build_object(
      'allowed',(select count(*) from commercial_intel.source_rights where rights_status='ALLOWED'),
      'review',(select count(*) from commercial_intel.source_rights where rights_status='REVIEW_REQUIRED'),
      'blocked',(select count(*) from commercial_intel.source_rights where rights_status='BLOCKED'),
      'internal_only',(select count(*) from commercial_intel.source_rights where rights_status='INTERNAL_ONLY')
    ),
    'agents',jsonb_build_object(
      'total',(select count(*) from commercial_intel.agents),
      'active',(select count(*) from commercial_intel.agents where lifecycle_state='active')
    ),
    'signals',jsonb_build_object(
      'types',(select count(distinct signal_type) from commercial_intel.business_signals where active),
      'rows',(select count(*) from commercial_intel.business_signals where active)
    ),
    'products',coalesce((
      select jsonb_agg(jsonb_build_object(
        'slug',p.slug,
        'name',p.name,
        'plan_tier',p.plan_tier,
        'eligible',coalesce(ps.eligible,0),
        'safe',coalesce(ps.safe,0),
        'review',coalesce(ps.review,0)
      ) order by p.plan_tier,p.slug)
      from commercial_intel.products p
      left join product_stats ps on ps.product_id=p.id
      where p.status='active'
    ),'[]'::jsonb)
  ) into v_manifest;

  update commercial_intel.sheet_sync_cycles
  set status='prepared',manifest=v_manifest
  where id=v_cycle;

  return v_manifest;
exception when others then
  update commercial_intel.sheet_sync_cycles
  set status='failed',error=sqlerrm,finished_at=now()
  where id=v_cycle;
  raise;
end
$function$
;

CREATE OR REPLACE FUNCTION solidos_control.request_sheet_sync(p_scope text, p_reason text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_delay interval;
  v_cap interval;
begin
  if p_scope not in ('CORE_CRM','COMMERCIAL_PRODUCTS') then
    raise exception 'invalid sync scope';
  end if;

  v_delay:=case
    when p_scope='COMMERCIAL_PRODUCTS' then interval '6 minutes'
    else interval '45 seconds'
  end;
  v_cap:=case
    when p_scope='COMMERCIAL_PRODUCTS' then interval '8 minutes'
    else interval '2 minutes'
  end;

  insert into solidos_control.sheet_sync_requests(sync_scope,reason,payload,debounce_until)
  values(
    p_scope,
    coalesce(nullif(p_reason,''),'data_changed'),
    coalesce(p_payload,'{}'::jsonb),
    now()+v_delay
  )
  on conflict(sync_scope) where status='PENDING'
  do update set
    reason=case
      when solidos_control.sheet_sync_requests.reason='hourly_full_refresh' then 'hourly_full_refresh'
      else excluded.reason
    end,
    payload=case
      when solidos_control.sheet_sync_requests.reason='hourly_full_refresh'
        then solidos_control.sheet_sync_requests.payload || excluded.payload || jsonb_build_object('force_full',true)
      else solidos_control.sheet_sync_requests.payload || excluded.payload
    end,
    debounce_until=case
      when solidos_control.sheet_sync_requests.reason='hourly_full_refresh'
        then least(solidos_control.sheet_sync_requests.debounce_until,now())
      else least(
        greatest(solidos_control.sheet_sync_requests.debounce_until,now()+v_delay),
        solidos_control.sheet_sync_requests.requested_at+v_cap
      )
    end,
    updated_at=now();
end
$function$
;

select cron.unschedule(jobid)
from cron.job where jobname='solidos-commercial-sheet-cycle-cleanup';
select cron.schedule(
  'solidos-commercial-sheet-cycle-cleanup',
  '27 */6 * * *',
  'select commercial_intel.cleanup_sheet_sync_cycles();'
);
