create table commercial_intel.sheet_sync_cycles (
  id uuid primary key default gen_random_uuid(),
  snapshot_at timestamptz not null default now(),
  status text not null default 'preparing'
    check (status in ('preparing','prepared','syncing','succeeded','failed')),
  manifest jsonb not null default '{}'::jsonb,
  error text,
  created_at timestamptz not null default now(),
  finished_at timestamptz
);

create table commercial_intel.sheet_sync_rows (
  cycle_id uuid not null references commercial_intel.sheet_sync_cycles(id) on delete cascade,
  product_id uuid not null references commercial_intel.products(id) on delete cascade,
  product_slug text not null,
  company_id uuid not null references booked_solid.companies(id) on delete cascade,
  bucket text not null check (bucket in ('SAFE','REVIEW')),
  company_name text not null,
  canonical_domain text,
  website_url text,
  trade text,
  location_text text,
  state text,
  country text,
  product_score numeric not null default 0,
  commercial_score numeric not null default 0,
  opportunity_score numeric,
  priority_band text,
  recommended_offer text,
  why_now text,
  rights_status text not null,
  commercial_status text not null,
  freshness_score numeric not null default 0,
  source_first_seen text,
  match_reasons text[] not null default '{}'::text[],
  restriction_reasons text[] not null default '{}'::text[],
  business_signals jsonb not null default '{}'::jsonb,
  evidence_domains text[] not null default '{}'::text[],
  payload jsonb not null default '{}'::jsonb
    check (not (payload ?| array['person_name','personal_email','personal_phone','decision_maker_name','raw_contact_snippet'])),
  evaluated_at timestamptz,
  created_at timestamptz not null default now(),
  primary key (cycle_id,product_id,company_id)
);

create index sheet_sync_rows_cycle_product_bucket_idx
  on commercial_intel.sheet_sync_rows(cycle_id,product_slug,bucket,product_score desc);
create index sheet_sync_cycles_snapshot_idx
  on commercial_intel.sheet_sync_cycles(snapshot_at desc);

alter table commercial_intel.sheet_sync_cycles enable row level security;
alter table commercial_intel.sheet_sync_rows enable row level security;
grant select,insert,update,delete on commercial_intel.sheet_sync_cycles to service_role;
grant select,insert,update,delete on commercial_intel.sheet_sync_rows to service_role;

create or replace function commercial_intel.prepare_sheet_sync_cycle()
returns jsonb
language plpgsql
security invoker
set search_path = commercial_intel, booked_solid, pg_catalog
as $$
declare
  v_cycle uuid:=gen_random_uuid();
  v_snapshot timestamptz:=now();
  v_manifest jsonb;
begin
  insert into commercial_intel.sheet_sync_cycles(id,snapshot_at,status)
  values(v_cycle,v_snapshot,'preparing');

  insert into commercial_intel.sheet_sync_rows(
    cycle_id,product_id,product_slug,company_id,bucket,company_name,canonical_domain,
    website_url,trade,location_text,state,country,product_score,commercial_score,
    opportunity_score,priority_band,recommended_offer,why_now,rights_status,
    commercial_status,freshness_score,source_first_seen,match_reasons,
    restriction_reasons,business_signals,evidence_domains,payload,evaluated_at
  )
  select
    v_cycle,
    p.id,
    p.slug,
    ca.company_id,
    case when pm.exportable then 'SAFE' else 'REVIEW' end,
    ca.company_name,
    ca.canonical_domain,
    ca.website_url,
    ca.trade,
    ca.location_text,
    ca.state,
    ca.country,
    pm.product_score,
    ca.commercial_score,
    ca.opportunity_score,
    ca.priority_band,
    ca.recommended_offer,
    case when pm.exportable then ca.why_now else ca.why_now end,
    ca.rights_status,
    ca.commercial_status,
    ca.freshness_score,
    ca.source_first_seen,
    pm.match_reasons,
    ca.restriction_reasons,
    coalesce(sig.signal_counts,'{}'::jsonb),
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
  left join lateral (
    select
      jsonb_object_agg(bs.signal_type,bs.evidence_count) filter(where bs.active) signal_counts,
      array(
        select distinct d
        from commercial_intel.business_signals bs2,
             unnest(coalesce(bs2.source_domains,'{}'::text[])) d
        where bs2.company_id=ca.company_id and bs2.active
        order by d
      ) evidence_domains
    from commercial_intel.business_signals bs
    where bs.company_id=ca.company_id
  ) sig on true
  where pm.eligible=true;

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
        'eligible',(select count(*) from commercial_intel.sheet_sync_rows r where r.cycle_id=v_cycle and r.product_id=p.id),
        'safe',(select count(*) from commercial_intel.sheet_sync_rows r where r.cycle_id=v_cycle and r.product_id=p.id and r.bucket='SAFE'),
        'review',(select count(*) from commercial_intel.sheet_sync_rows r where r.cycle_id=v_cycle and r.product_id=p.id and r.bucket='REVIEW')
      ) order by p.plan_tier,p.slug)
      from commercial_intel.products p
      where p.status='active'
    ),'[]'::jsonb)
  ) into v_manifest;

  update commercial_intel.sheet_sync_cycles
  set status='prepared',manifest=v_manifest
  where id=v_cycle;

  delete from commercial_intel.sheet_sync_cycles
  where snapshot_at < now()-interval '7 days'
    and status in ('succeeded','failed');

  return v_manifest;
exception when others then
  update commercial_intel.sheet_sync_cycles
  set status='failed',error=sqlerrm,finished_at=now()
  where id=v_cycle;
  raise;
end
$$;
