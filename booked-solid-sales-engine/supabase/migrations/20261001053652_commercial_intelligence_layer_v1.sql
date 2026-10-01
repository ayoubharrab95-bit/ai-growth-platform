
create schema if not exists commercial_intel;

revoke all on schema commercial_intel from public, anon, authenticated;
grant usage on schema commercial_intel to service_role;

create table commercial_intel.settings (
  id boolean primary key default true check (id),
  enabled boolean not null default true,
  strict_compliance boolean not null default true,
  allow_personal_pii_export boolean not null default false,
  allow_direct_personal_email_export boolean not null default false,
  allow_direct_personal_phone_export boolean not null default false,
  buyer_hunting_enabled boolean not null default false,
  buyer_outreach_enabled boolean not null default false,
  automatic_source_rights_promotion boolean not null default false,
  min_commercial_score numeric not null default 50,
  freshness_days integer not null default 45,
  max_records_per_export integer not null default 5000,
  updated_at timestamptz not null default now()
);

create table commercial_intel.agents (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  role text not null,
  lifecycle_state text not null default 'active'
    check (lifecycle_state in ('active','paused','testing','retired')),
  write_scope text not null default 'commercial_intel_only'
    check (write_scope in ('commercial_intel_only')),
  reads_core boolean not null default true,
  can_export boolean not null default false,
  can_change_rights_status boolean not null default false,
  can_contact_buyers boolean not null default false,
  guardrails jsonb not null default '{}'::jsonb,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table commercial_intel.source_rights (
  id uuid primary key default gen_random_uuid(),
  source_slug text not null unique,
  source_name text,
  source_type text,
  provider text,
  public_url text,
  license_text text,
  rights_status text not null default 'REVIEW_REQUIRED'
    check (rights_status in ('ALLOWED','REVIEW_REQUIRED','INTERNAL_ONLY','BLOCKED')),
  permitted_uses text[] not null default '{}'::text[],
  prohibited_fields text[] not null default '{}'::text[],
  personal_data_policy text not null default 'NO_PERSONAL_PII'
    check (personal_data_policy in ('NO_PERSONAL_PII','BUSINESS_LEVEL_ONLY','EXPLICITLY_ALLOWED')),
  review_reason text,
  review_evidence_url text,
  reviewed_at timestamptz,
  reviewed_by text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table commercial_intel.field_catalog (
  field_key text primary key,
  display_name text not null,
  category text not null,
  sensitivity text not null
    check (sensitivity in ('PUBLIC_COMPANY','DERIVED_INTELLIGENCE','BUSINESS_ROUTE','PERSONAL_PII','RESTRICTED')),
  default_export_status text not null
    check (default_export_status in ('ALLOW','REVIEW','BLOCK')),
  description text,
  source_requirements text[] not null default '{}'::text[],
  notes text
);

create table commercial_intel.products (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  name text not null,
  plan_tier text not null
    check (plan_tier in ('SAMPLE','STARTER','GROWTH','AGENCY','CUSTOM')),
  audience text not null,
  description text not null,
  price_hint_monthly numeric,
  price_hint_one_time numeric,
  status text not null default 'draft'
    check (status in ('draft','active','paused','retired')),
  selection_rules jsonb not null default '{}'::jsonb,
  export_field_keys text[] not null default '{}'::text[],
  max_records integer,
  freshness_days integer not null default 45,
  requires_commercial_safe boolean not null default true,
  pii_allowed boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table commercial_intel.company_assets (
  company_id uuid primary key references booked_solid.companies(id) on delete cascade,
  company_name text not null,
  canonical_domain text,
  website_url text,
  trade text,
  location_text text,
  state text,
  country text,
  core_status text,
  source_first_seen text,
  source_last_seen text,
  rights_status text not null default 'REVIEW_REQUIRED'
    check (rights_status in ('ALLOWED','REVIEW_REQUIRED','INTERNAL_ONLY','BLOCKED')),
  commercial_status text not null default 'REVIEW_REQUIRED'
    check (commercial_status in ('COMMERCIAL_SAFE','REVIEW_REQUIRED','INTERNAL_ONLY','BLOCKED_FROM_RESALE')),
  commercial_score numeric not null default 0,
  fit_score numeric,
  opportunity_score numeric,
  priority_band text,
  recommended_offer text,
  why_now text,
  freshness_score numeric not null default 0,
  last_core_update timestamptz,
  last_evaluated_at timestamptz,
  has_named_people boolean not null default false,
  has_personal_email boolean not null default false,
  has_personal_phone boolean not null default false,
  safe_company_payload jsonb not null default '{}'::jsonb,
  restriction_reasons text[] not null default '{}'::text[],
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table commercial_intel.business_signals (
  company_id uuid not null references booked_solid.companies(id) on delete cascade,
  signal_type text not null,
  evidence_count integer not null default 0,
  avg_confidence numeric not null default 0,
  first_observed_at timestamptz,
  last_observed_at timestamptz,
  source_domains text[] not null default '{}'::text[],
  active boolean not null default true,
  metadata jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (company_id, signal_type)
);

create table commercial_intel.product_memberships (
  product_id uuid not null references commercial_intel.products(id) on delete cascade,
  company_id uuid not null references booked_solid.companies(id) on delete cascade,
  eligible boolean not null default false,
  exportable boolean not null default false,
  product_score numeric not null default 0,
  match_reasons text[] not null default '{}'::text[],
  export_payload jsonb not null default '{}'::jsonb,
  evaluated_at timestamptz not null default now(),
  primary key (product_id, company_id)
);

create table commercial_intel.dataset_versions (
  id uuid primary key default gen_random_uuid(),
  product_id uuid not null references commercial_intel.products(id) on delete cascade,
  version_no bigint not null,
  snapshot_at timestamptz not null default now(),
  record_count integer not null default 0,
  safe_record_count integer not null default 0,
  review_record_count integer not null default 0,
  schema_version integer not null default 1,
  checksum text,
  status text not null default 'prepared'
    check (status in ('prepared','published','superseded','failed')),
  sheet_target_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  unique(product_id, version_no)
);

create table commercial_intel.buyers (
  id uuid primary key default gen_random_uuid(),
  company_name text not null,
  website_url text,
  domain text,
  buyer_type text,
  target_trades text[] not null default '{}'::text[],
  target_markets text[] not null default '{}'::text[],
  use_case text,
  fit_score numeric not null default 0,
  status text not null default 'candidate'
    check (status in ('candidate','qualified','sample_ready','contacted','interested','customer','not_fit','suppressed')),
  contact_route text,
  personal_pii_stored boolean not null default false,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table commercial_intel.buyer_matches (
  buyer_id uuid not null references commercial_intel.buyers(id) on delete cascade,
  product_id uuid not null references commercial_intel.products(id) on delete cascade,
  match_score numeric not null default 0,
  reasons text[] not null default '{}'::text[],
  sample_size integer not null default 0,
  status text not null default 'candidate'
    check (status in ('candidate','sample_ready','approved','rejected')),
  evaluated_at timestamptz not null default now(),
  primary key (buyer_id, product_id)
);

create table commercial_intel.work_queue (
  id uuid primary key default gen_random_uuid(),
  kind text not null check (kind in (
    'SOURCE_RIGHTS_REVIEW','ASSET_REFRESH','SIGNAL_REFRESH','PRODUCT_CLASSIFY',
    'QUALITY_CHECK','PACKAGE_DATASET','SHEET_SYNC','BUYER_DISCOVERY','BUYER_MATCH'
  )),
  priority numeric not null default 50,
  payload jsonb not null default '{}'::jsonb,
  status text not null default 'pending'
    check (status in ('pending','running','done','failed','blocked','cancelled')),
  attempts integer not null default 0,
  available_at timestamptz not null default now(),
  locked_at timestamptz,
  locked_by text,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table commercial_intel.agent_runs (
  id uuid primary key default gen_random_uuid(),
  agent_slug text not null,
  run_type text not null,
  status text not null default 'started'
    check (status in ('started','succeeded','partial','failed')),
  input_count integer not null default 0,
  output_count integer not null default 0,
  blocked_count integer not null default 0,
  notes jsonb not null default '{}'::jsonb,
  started_at timestamptz not null default now(),
  finished_at timestamptz
);

create table commercial_intel.sheet_targets (
  id uuid primary key default gen_random_uuid(),
  target_key text not null unique,
  product_id uuid references commercial_intel.products(id) on delete set null,
  spreadsheet_id text,
  spreadsheet_url text,
  title text not null,
  sync_enabled boolean not null default true,
  sync_frequency text not null default 'hourly',
  last_snapshot_at timestamptz,
  last_sync_at timestamptz,
  last_sync_status text,
  last_error text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table commercial_intel.dataset_versions
  add constraint dataset_versions_sheet_target_fk
  foreign key (sheet_target_id) references commercial_intel.sheet_targets(id) on delete set null;

create table commercial_intel.audit_log (
  id bigint generated always as identity primary key,
  event_at timestamptz not null default now(),
  actor text not null,
  action text not null,
  entity_type text not null,
  entity_id text,
  before_state jsonb,
  after_state jsonb,
  reason text,
  metadata jsonb not null default '{}'::jsonb
);

create index company_assets_commercial_status_idx on commercial_intel.company_assets(commercial_status);
create index company_assets_trade_idx on commercial_intel.company_assets(trade);
create index company_assets_state_idx on commercial_intel.company_assets(state);
create index company_assets_score_idx on commercial_intel.company_assets(commercial_score desc);
create index business_signals_type_idx on commercial_intel.business_signals(signal_type, active);
create index product_memberships_export_idx on commercial_intel.product_memberships(product_id, exportable, product_score desc);
create index work_queue_due_idx on commercial_intel.work_queue(status, available_at, priority desc);
create index buyers_status_idx on commercial_intel.buyers(status, fit_score desc);

alter table commercial_intel.settings enable row level security;
alter table commercial_intel.agents enable row level security;
alter table commercial_intel.source_rights enable row level security;
alter table commercial_intel.field_catalog enable row level security;
alter table commercial_intel.products enable row level security;
alter table commercial_intel.company_assets enable row level security;
alter table commercial_intel.business_signals enable row level security;
alter table commercial_intel.product_memberships enable row level security;
alter table commercial_intel.dataset_versions enable row level security;
alter table commercial_intel.buyers enable row level security;
alter table commercial_intel.buyer_matches enable row level security;
alter table commercial_intel.work_queue enable row level security;
alter table commercial_intel.agent_runs enable row level security;
alter table commercial_intel.sheet_targets enable row level security;
alter table commercial_intel.audit_log enable row level security;

grant select,insert,update,delete on all tables in schema commercial_intel to service_role;
grant usage,select on all sequences in schema commercial_intel to service_role;

insert into commercial_intel.settings(id) values(true)
on conflict (id) do nothing;

insert into commercial_intel.agents(slug,name,role,can_export,can_change_rights_status,can_contact_buyers,guardrails) values
('rights-agent','Rights & Compliance Agent','Classifies source resale rights and blocks uncertain or restricted data',false,true,false,'{"default":"REVIEW_REQUIRED","no_auto_legal_conclusions":true}'::jsonb),
('field-safety-agent','Field Safety Agent','Classifies fields by company-level vs derived vs personal PII',false,false,false,'{"personal_pii_export":false}'::jsonb),
('asset-agent','Commercial Asset Agent','Builds PII-free company intelligence assets from Booked Solid core',false,false,false,'{"core_write":false}'::jsonb),
('signal-agent','Business Signal Agent','Aggregates business-level evidence into non-personal signals',false,false,false,'{"raw_person_snippets":false}'::jsonb),
('product-agent','Product Architect Agent','Matches safe company assets to commercial products and plans',false,false,false,'{"commercial_safe_required":true}'::jsonb),
('quality-agent','Commercial Quality Agent','Checks freshness, provenance, dedupe, score and export eligibility',false,false,false,'{"fail_closed":true}'::jsonb),
('packaging-agent','Packaging & Export Agent','Builds versioned export payloads and sheet-ready datasets',true,false,false,'{"export_safe_only":true}'::jsonb),
('buyer-agent','Buyer Intelligence Agent','Finds and matches likely buyers without contacting them',false,false,false,'{"outreach_enabled":false}'::jsonb)
on conflict (slug) do update set
  name=excluded.name, role=excluded.role, can_export=excluded.can_export,
  can_change_rights_status=excluded.can_change_rights_status,
  can_contact_buyers=excluded.can_contact_buyers, guardrails=excluded.guardrails,
  updated_at=now();

insert into commercial_intel.field_catalog(field_key,display_name,category,sensitivity,default_export_status,description) values
('company_name','Company Name','identity','PUBLIC_COMPANY','ALLOW','Public business/company name'),
('canonical_domain','Domain','identity','PUBLIC_COMPANY','ALLOW','Canonical business domain'),
('website_url','Website','identity','PUBLIC_COMPANY','ALLOW','Public company website'),
('trade','Trade','classification','DERIVED_INTELLIGENCE','ALLOW','Trade/category classification'),
('location_text','Location','geography','PUBLIC_COMPANY','ALLOW','Business-level location text'),
('state','State','geography','PUBLIC_COMPANY','ALLOW','Business state/region'),
('country','Country','geography','PUBLIC_COMPANY','ALLOW','Business country'),
('commercial_score','Commercial Score','scoring','DERIVED_INTELLIGENCE','ALLOW','Internal commercial usefulness score'),
('opportunity_score','Opportunity Score','scoring','DERIVED_INTELLIGENCE','ALLOW','Derived opportunity score'),
('priority_band','Priority Band','scoring','DERIVED_INTELLIGENCE','ALLOW','Derived priority band'),
('recommended_offer','Recommended Solution Category','intelligence','DERIVED_INTELLIGENCE','ALLOW','High-level recommended category, not private contact data'),
('why_now','Why Now','intelligence','DERIVED_INTELLIGENCE','REVIEW','Derived rationale; requires source-safe evidence'),
('business_signals','Business Signals','intelligence','DERIVED_INTELLIGENCE','ALLOW','Aggregated non-personal business signals'),
('evidence_domains','Evidence Domains','provenance','PUBLIC_COMPANY','ALLOW','Domains supporting the derived signal'),
('general_contact_form','Company Contact Form','routing','BUSINESS_ROUTE','ALLOW','General company contact route only'),
('general_business_phone','General Business Phone','routing','BUSINESS_ROUTE','REVIEW','Only when clearly a company-level published number'),
('general_business_inbox','General Business Inbox','routing','BUSINESS_ROUTE','REVIEW','Only when clearly a company-level published inbox'),
('person_name','Person Name','contact','PERSONAL_PII','BLOCK','Named individual'),
('personal_email','Personal/Named Email','contact','PERSONAL_PII','BLOCK','Direct or named-person email'),
('personal_phone','Personal/Direct Phone','contact','PERSONAL_PII','BLOCK','Direct personal phone'),
('decision_maker_name','Decision Maker Name','contact','PERSONAL_PII','BLOCK','Named decision maker'),
('raw_contact_snippet','Raw Contact Snippet','evidence','RESTRICTED','BLOCK','Raw evidence that may contain PII')
on conflict (field_key) do update set
  display_name=excluded.display_name, category=excluded.category,
  sensitivity=excluded.sensitivity, default_export_status=excluded.default_export_status,
  description=excluded.description;

insert into commercial_intel.products(slug,name,plan_tier,audience,description,price_hint_monthly,price_hint_one_time,status,selection_rules,export_field_keys,max_records,freshness_days,requires_commercial_safe,pii_allowed) values
('contractor-starter','Contractor Intelligence — Starter','STARTER','Small agencies and niche vendors','Fresh company-level contractor intelligence with core classification and scores',299,349,'active','{"min_score":55}'::jsonb,array['company_name','canonical_domain','website_url','trade','location_text','state','country','commercial_score','priority_band','business_signals','evidence_domains'],100,45,true,false),
('growth-signals','Contractor Growth Signals','GROWTH','Growth agencies, SaaS and financing vendors','Contractors showing expansion, scale, hiring or multi-location signals',699,699,'active','{"signals":["scale_signal","trigger_expansion","trigger_multi_location_growth","trigger_active_hiring"]}'::jsonb,array['company_name','canonical_domain','website_url','trade','state','commercial_score','opportunity_score','priority_band','why_now','business_signals','evidence_domains'],250,30,true,false),
('automation-opportunities','Automation Opportunity Intelligence','GROWTH','AI automation, CRM, estimating and field-service vendors','Contractors showing estimating, quoting, workflow or change-order complexity',699,699,'active','{"signals":["estimation_pain","workflow_complexity","trigger_manual_workflow","trigger_quote_speed","change_orders","field_quoting"]}'::jsonb,array['company_name','canonical_domain','website_url','trade','state','commercial_score','opportunity_score','recommended_offer','why_now','business_signals','evidence_domains'],250,30,true,false),
('agency-feed','Contractor Intelligence — Agency','AGENCY','Lead-generation and marketing agencies','Broader continuously refreshed company intelligence with multiple business signals',1499,1199,'active','{"min_score":50}'::jsonb,array['company_name','canonical_domain','website_url','trade','location_text','state','country','commercial_score','opportunity_score','priority_band','recommended_offer','why_now','business_signals','evidence_domains','general_contact_form'],500,45,true,false),
('custom-icp','Custom ICP Intelligence Lab','CUSTOM','Enterprise/custom buyers','Configurable company-level dataset for a buyer-specific ICP; exports remain compliance-gated',null,1500,'active','{"custom":true}'::jsonb,array['company_name','canonical_domain','website_url','trade','location_text','state','country','commercial_score','opportunity_score','priority_band','recommended_offer','why_now','business_signals','evidence_domains'],2000,45,true,false)
on conflict (slug) do update set
  name=excluded.name, plan_tier=excluded.plan_tier, audience=excluded.audience,
  description=excluded.description, price_hint_monthly=excluded.price_hint_monthly,
  price_hint_one_time=excluded.price_hint_one_time, status=excluded.status,
  selection_rules=excluded.selection_rules, export_field_keys=excluded.export_field_keys,
  max_records=excluded.max_records, freshness_days=excluded.freshness_days,
  requires_commercial_safe=excluded.requires_commercial_safe, pii_allowed=excluded.pii_allowed,
  updated_at=now();

insert into commercial_intel.sheet_targets(target_key,title,sync_frequency,metadata)
values
('MASTER','Commercial Intelligence — Master Control','hourly','{"purpose":"control_plane"}'::jsonb),
('STARTER','Contractor Intelligence — Starter Feed','hourly','{"product_slug":"contractor-starter"}'::jsonb),
('GROWTH','Contractor Intelligence — Growth Signals','hourly','{"product_slug":"growth-signals"}'::jsonb),
('AUTOMATION','Contractor Intelligence — Automation Opportunities','hourly','{"product_slug":"automation-opportunities"}'::jsonb),
('AGENCY','Contractor Intelligence — Agency Feed','hourly','{"product_slug":"agency-feed"}'::jsonb),
('CUSTOM','Contractor Intelligence — Custom ICP Lab','hourly','{"product_slug":"custom-icp"}'::jsonb)
on conflict (target_key) do update set title=excluded.title,sync_frequency=excluded.sync_frequency,metadata=excluded.metadata,updated_at=now();

update commercial_intel.sheet_targets st
set product_id=p.id
from commercial_intel.products p
where st.metadata->>'product_slug'=p.slug and st.product_id is distinct from p.id;

insert into commercial_intel.source_rights(
  source_slug,source_name,source_type,provider,public_url,license_text,rights_status,
  permitted_uses,prohibited_fields,personal_data_policy,review_reason,metadata
)
select
  s.slug,
  s.name,
  s.source_type,
  coalesce(s.metadata->>'provider',s.metadata->>'agency'),
  coalesce(s.metadata->>'public_url',s.metadata->>'directory_url',s.metadata->>'service',s.metadata->>'api'),
  s.metadata->>'license',
  case
    when lower(coalesce(s.metadata->>'license','')) in (
      'public_domain','public domain','public domain u.s. government','open data commons pddl'
    ) then 'ALLOWED'
    else 'REVIEW_REQUIRED'
  end,
  case
    when lower(coalesce(s.metadata->>'license','')) in (
      'public_domain','public domain','public domain u.s. government','open data commons pddl'
    ) then array['company_facts','derived_signals','aggregate_intelligence']::text[]
    else '{}'::text[]
  end,
  array['person_name','personal_email','personal_phone','decision_maker_name','raw_contact_snippet']::text[],
  'NO_PERSONAL_PII',
  case
    when lower(coalesce(s.metadata->>'license','')) in (
      'public_domain','public domain','public domain u.s. government','open data commons pddl'
    ) then 'Explicit open/public-domain license metadata found in Booked Solid source catalog; personal PII remains blocked.'
    else 'No explicit resale-safe license decision stored yet. Human/agent rights review required before commercial export.'
  end,
  jsonb_build_object(
    'source_lifecycle_state',s.lifecycle_state,
    'source_enabled',s.enabled,
    'source_reliability',s.reliability_score,
    'source_quality',s.quality_score,
    'imported_from','booked_solid.source_catalog'
  )
from booked_solid.source_catalog s
on conflict (source_slug) do update set
  source_name=excluded.source_name,
  source_type=excluded.source_type,
  provider=excluded.provider,
  public_url=excluded.public_url,
  license_text=excluded.license_text,
  metadata=excluded.metadata,
  updated_at=now();

create or replace function commercial_intel.refresh_company_assets()
returns jsonb
language plpgsql
security invoker
set search_path = commercial_intel, booked_solid, pg_catalog
as $$
declare
  v_count integer;
begin
  with lead_best as (
    select distinct on (company_id)
      company_id, fit_score, opportunity_score, priority_band, recommended_offer, why_now, status
    from booked_solid.leads
    order by company_id, opportunity_score desc nulls last, updated_at desc
  ),
  contact_flags as (
    select company_id,
      bool_or(full_name is not null) as has_named_people,
      bool_or(email is not null and full_name is not null) as has_personal_email,
      bool_or(phone is not null and full_name is not null) as has_personal_phone
    from booked_solid.contacts
    group by company_id
  )
  insert into commercial_intel.company_assets(
    company_id,company_name,canonical_domain,website_url,trade,location_text,state,country,
    core_status,source_first_seen,source_last_seen,rights_status,commercial_status,
    commercial_score,fit_score,opportunity_score,priority_band,recommended_offer,why_now,
    freshness_score,last_core_update,last_evaluated_at,has_named_people,has_personal_email,
    has_personal_phone,safe_company_payload,restriction_reasons,metadata,updated_at
  )
  select
    c.id,c.name,c.canonical_domain,c.website_url,c.trade,c.location_text,c.state,c.country,
    c.status,c.source_first_seen,c.source_last_seen,
    coalesce(sr.rights_status,'REVIEW_REQUIRED'),
    case
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='ALLOWED' then 'COMMERCIAL_SAFE'
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='BLOCKED' then 'BLOCKED_FROM_RESALE'
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='INTERNAL_ONLY' then 'INTERNAL_ONLY'
      else 'REVIEW_REQUIRED'
    end,
    least(100,greatest(0,
      coalesce(lb.opportunity_score,0)*0.55 +
      coalesce(lb.fit_score,c.fit_score,0)*0.35 +
      case when c.website_url is not null then 5 else 0 end +
      case when c.state is not null then 5 else 0 end
    )),
    coalesce(lb.fit_score,c.fit_score),
    lb.opportunity_score,lb.priority_band,coalesce(lb.recommended_offer,c.recommended_offer),lb.why_now,
    greatest(0,100 - extract(epoch from (now()-coalesce(c.updated_at,c.created_at)))/86400.0 * 2),
    c.updated_at,now(),
    coalesce(cf.has_named_people,false),coalesce(cf.has_personal_email,false),coalesce(cf.has_personal_phone,false),
    jsonb_strip_nulls(jsonb_build_object(
      'company_name',c.name,
      'canonical_domain',c.canonical_domain,
      'website_url',c.website_url,
      'trade',c.trade,
      'location_text',c.location_text,
      'state',c.state,
      'country',c.country,
      'commercial_score',round((least(100,greatest(0,
        coalesce(lb.opportunity_score,0)*0.55 +
        coalesce(lb.fit_score,c.fit_score,0)*0.35 +
        case when c.website_url is not null then 5 else 0 end +
        case when c.state is not null then 5 else 0 end
      )))::numeric,2),
      'opportunity_score',lb.opportunity_score,
      'priority_band',lb.priority_band,
      'recommended_offer',coalesce(lb.recommended_offer,c.recommended_offer)
    )),
    case
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='ALLOWED' then '{}'::text[]
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='BLOCKED' then array['SOURCE_BLOCKED']::text[]
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='INTERNAL_ONLY' then array['SOURCE_INTERNAL_ONLY']::text[]
      else array['SOURCE_RIGHTS_REVIEW_REQUIRED']::text[]
    end,
    jsonb_build_object(
      'core_lead_status',lb.status,
      'source_rights_id',sr.id,
      'core_enrichment_version',c.enrichment_version
    ),
    now()
  from booked_solid.companies c
  left join lead_best lb on lb.company_id=c.id
  left join contact_flags cf on cf.company_id=c.id
  left join commercial_intel.source_rights sr on sr.source_slug=c.source_first_seen
  on conflict (company_id) do update set
    company_name=excluded.company_name,
    canonical_domain=excluded.canonical_domain,
    website_url=excluded.website_url,
    trade=excluded.trade,
    location_text=excluded.location_text,
    state=excluded.state,
    country=excluded.country,
    core_status=excluded.core_status,
    source_first_seen=excluded.source_first_seen,
    source_last_seen=excluded.source_last_seen,
    rights_status=excluded.rights_status,
    commercial_status=excluded.commercial_status,
    commercial_score=excluded.commercial_score,
    fit_score=excluded.fit_score,
    opportunity_score=excluded.opportunity_score,
    priority_band=excluded.priority_band,
    recommended_offer=excluded.recommended_offer,
    why_now=excluded.why_now,
    freshness_score=excluded.freshness_score,
    last_core_update=excluded.last_core_update,
    last_evaluated_at=excluded.last_evaluated_at,
    has_named_people=excluded.has_named_people,
    has_personal_email=excluded.has_personal_email,
    has_personal_phone=excluded.has_personal_phone,
    safe_company_payload=excluded.safe_company_payload,
    restriction_reasons=excluded.restriction_reasons,
    metadata=excluded.metadata,
    updated_at=now();

  get diagnostics v_count = row_count;
  return jsonb_build_object('assets_upserted',v_count,'at',now());
end
$$;

create or replace function commercial_intel.refresh_business_signals()
returns jsonb
language plpgsql
security invoker
set search_path = commercial_intel, booked_solid, pg_catalog
as $$
declare
  v_count integer;
begin
  insert into commercial_intel.business_signals(
    company_id,signal_type,evidence_count,avg_confidence,first_observed_at,last_observed_at,
    source_domains,active,metadata,updated_at
  )
  select
    e.company_id,
    e.evidence_type,
    count(*)::int,
    avg(e.confidence),
    min(e.observed_at),
    max(e.observed_at),
    array_agg(distinct lower(split_part(regexp_replace(e.source_url,'^https?://','','i'),'/',1)))
      filter (where e.source_url is not null),
    true,
    jsonb_build_object('commercial_transform','aggregate_only','raw_snippets_exported',false),
    now()
  from booked_solid.evidence e
  where e.evidence_type in (
    'estimation_pain','scale_signal','buyer_signal','permit_activity','workflow_complexity',
    'property_operations','trigger_active_hiring','trade_license','intel_business_profile',
    'trigger_expansion','recurring_contracts','field_quoting','trigger_quote_speed',
    'trigger_multi_location_growth','change_orders','trigger_manual_workflow',
    'trigger_recurring_service','fit_signal','trigger_change_order_workflow',
    'trigger_hiring_estimator','association_membership'
  )
    and coalesce(e.metadata->>'active','true') <> 'false'
  group by e.company_id,e.evidence_type
  on conflict (company_id,signal_type) do update set
    evidence_count=excluded.evidence_count,
    avg_confidence=excluded.avg_confidence,
    first_observed_at=excluded.first_observed_at,
    last_observed_at=excluded.last_observed_at,
    source_domains=excluded.source_domains,
    active=true,
    metadata=excluded.metadata,
    updated_at=now();

  get diagnostics v_count = row_count;
  update commercial_intel.business_signals bs
  set active=false,updated_at=now()
  where not exists (
    select 1 from booked_solid.evidence e
    where e.company_id=bs.company_id
      and e.evidence_type=bs.signal_type
      and coalesce(e.metadata->>'active','true') <> 'false'
  );

  return jsonb_build_object('signals_upserted',v_count,'at',now());
end
$$;

create or replace function commercial_intel.refresh_product_memberships()
returns jsonb
language plpgsql
security invoker
set search_path = commercial_intel, booked_solid, pg_catalog
as $$
declare
  v_count integer;
begin
  with signal_rollup as (
    select
      company_id,
      array_agg(signal_type order by signal_type) filter(where active) as signal_types,
      jsonb_object_agg(signal_type,evidence_count) filter(where active) as signal_counts,
      array(
        select distinct d
        from commercial_intel.business_signals b2,
             unnest(coalesce(b2.source_domains,'{}'::text[])) d
        where b2.company_id=bs.company_id and b2.active
        order by d
      ) as evidence_domains
    from commercial_intel.business_signals bs
    group by company_id
  ),
  x as (
    select
      p.id product_id,p.slug product_slug,p.plan_tier,p.max_records,p.selection_rules,
      a.*,
      coalesce(sr.signal_types,'{}'::text[]) signal_types,
      coalesce(sr.signal_counts,'{}'::jsonb) signal_counts,
      coalesce(sr.evidence_domains,'{}'::text[]) evidence_domains,
      case
        when p.slug='contractor-starter' then a.commercial_score>=55
        when p.slug='growth-signals' then coalesce(sr.signal_types,'{}'::text[]) && array['scale_signal','trigger_expansion','trigger_multi_location_growth','trigger_active_hiring']
        when p.slug='automation-opportunities' then coalesce(sr.signal_types,'{}'::text[]) && array['estimation_pain','workflow_complexity','trigger_manual_workflow','trigger_quote_speed','change_orders','field_quoting']
        when p.slug='agency-feed' then a.commercial_score>=50
        when p.slug='custom-icp' then true
        else false
      end as eligible_calc
    from commercial_intel.products p
    cross join commercial_intel.company_assets a
    left join signal_rollup sr on sr.company_id=a.company_id
    where p.status='active'
  )
  insert into commercial_intel.product_memberships(
    product_id,company_id,eligible,exportable,product_score,match_reasons,export_payload,evaluated_at
  )
  select
    x.product_id,x.company_id,
    x.eligible_calc,
    x.eligible_calc and x.commercial_status='COMMERCIAL_SAFE',
    least(100,greatest(0,
      x.commercial_score +
      case when cardinality(x.signal_types)>=3 then 8 when cardinality(x.signal_types)>=1 then 4 else 0 end
    )),
    array_remove(array[
      case when x.commercial_status='COMMERCIAL_SAFE' then 'COMPLIANCE_SAFE' else 'COMPLIANCE_NOT_CLEARED' end,
      case when x.commercial_score>=70 then 'HIGH_COMMERCIAL_SCORE' end,
      case when cardinality(x.signal_types)>0 then 'BUSINESS_SIGNALS_PRESENT' end,
      case when x.priority_band in ('hot','high','Hot','High') then 'CORE_HIGH_PRIORITY' end
    ],null),
    x.safe_company_payload ||
      jsonb_build_object(
        'why_now',case when x.commercial_status='COMMERCIAL_SAFE' then x.why_now else null end,
        'business_signals',x.signal_counts,
        'evidence_domains',to_jsonb(x.evidence_domains),
        'commercial_status',x.commercial_status,
        'rights_status',x.rights_status,
        'freshness_score',round(x.freshness_score::numeric,2)
      ),
    now()
  from x
  on conflict(product_id,company_id) do update set
    eligible=excluded.eligible,
    exportable=excluded.exportable,
    product_score=excluded.product_score,
    match_reasons=excluded.match_reasons,
    export_payload=excluded.export_payload,
    evaluated_at=now();

  get diagnostics v_count = row_count;
  return jsonb_build_object('memberships_upserted',v_count,'at',now());
end
$$;

create or replace function commercial_intel.refresh_layer()
returns jsonb
language plpgsql
security invoker
set search_path = commercial_intel, booked_solid, pg_catalog
as $$
declare
  v_run uuid:=gen_random_uuid();
  a jsonb;
  s jsonb;
  p jsonb;
begin
  insert into commercial_intel.agent_runs(id,agent_slug,run_type,status)
  values(v_run,'asset-agent','FULL_REFRESH','started');

  a:=commercial_intel.refresh_company_assets();
  s:=commercial_intel.refresh_business_signals();
  p:=commercial_intel.refresh_product_memberships();

  insert into commercial_intel.audit_log(actor,action,entity_type,reason,after_state)
  values('system','REFRESH_LAYER','commercial_intel','Scheduled/read-only ingestion from Booked Solid core',
         jsonb_build_object('assets',a,'signals',s,'memberships',p));

  update commercial_intel.agent_runs
  set status='succeeded',
      output_count=(select count(*) from commercial_intel.product_memberships where exportable),
      blocked_count=(select count(*) from commercial_intel.company_assets where commercial_status<>'COMMERCIAL_SAFE'),
      notes=jsonb_build_object('assets',a,'signals',s,'memberships',p),
      finished_at=now()
  where id=v_run;

  return jsonb_build_object(
    'run_id',v_run,
    'assets',a,
    'signals',s,
    'memberships',p,
    'safe_assets',(select count(*) from commercial_intel.company_assets where commercial_status='COMMERCIAL_SAFE'),
    'review_assets',(select count(*) from commercial_intel.company_assets where commercial_status='REVIEW_REQUIRED'),
    'exportable_memberships',(select count(*) from commercial_intel.product_memberships where exportable),
    'buyer_outreach_enabled',(select buyer_outreach_enabled from commercial_intel.settings where id=true)
  );
exception when others then
  update commercial_intel.agent_runs
  set status='failed', notes=jsonb_build_object('error',sqlerrm), finished_at=now()
  where id=v_run;
  raise;
end
$$;

create or replace function commercial_intel.system_snapshot()
returns jsonb
language sql
stable
security invoker
set search_path = commercial_intel, pg_catalog
as $$
select jsonb_build_object(
  'snapshot_at',now(),
  'schema_version',1,
  'settings',(select to_jsonb(s) - 'id' from commercial_intel.settings s where id=true),
  'agents',jsonb_build_object(
    'total',(select count(*) from commercial_intel.agents),
    'active',(select count(*) from commercial_intel.agents where lifecycle_state='active'),
    'buyer_outreach_capable',(select count(*) from commercial_intel.agents where can_contact_buyers=true)
  ),
  'assets',jsonb_build_object(
    'total',(select count(*) from commercial_intel.company_assets),
    'safe',(select count(*) from commercial_intel.company_assets where commercial_status='COMMERCIAL_SAFE'),
    'review',(select count(*) from commercial_intel.company_assets where commercial_status='REVIEW_REQUIRED'),
    'internal_only',(select count(*) from commercial_intel.company_assets where commercial_status='INTERNAL_ONLY'),
    'blocked',(select count(*) from commercial_intel.company_assets where commercial_status='BLOCKED_FROM_RESALE')
  ),
  'rights',jsonb_build_object(
    'allowed',(select count(*) from commercial_intel.source_rights where rights_status='ALLOWED'),
    'review',(select count(*) from commercial_intel.source_rights where rights_status='REVIEW_REQUIRED'),
    'internal_only',(select count(*) from commercial_intel.source_rights where rights_status='INTERNAL_ONLY'),
    'blocked',(select count(*) from commercial_intel.source_rights where rights_status='BLOCKED')
  ),
  'products',(
    select coalesce(jsonb_agg(jsonb_build_object(
      'slug',p.slug,'name',p.name,'plan_tier',p.plan_tier,'status',p.status,
      'eligible',(select count(*) from commercial_intel.product_memberships pm where pm.product_id=p.id and pm.eligible),
      'exportable',(select count(*) from commercial_intel.product_memberships pm where pm.product_id=p.id and pm.exportable)
    ) order by p.plan_tier,p.slug),'[]'::jsonb)
    from commercial_intel.products p
  ),
  'signals',jsonb_build_object(
    'types',(select count(distinct signal_type) from commercial_intel.business_signals where active),
    'rows',(select count(*) from commercial_intel.business_signals where active)
  ),
  'buyers',jsonb_build_object(
    'total',(select count(*) from commercial_intel.buyers),
    'qualified',(select count(*) from commercial_intel.buyers where status='qualified'),
    'customers',(select count(*) from commercial_intel.buyers where status='customer')
  ),
  'queue',jsonb_build_object(
    'pending',(select count(*) from commercial_intel.work_queue where status='pending'),
    'due',(select count(*) from commercial_intel.work_queue where status='pending' and available_at<=now()),
    'running',(select count(*) from commercial_intel.work_queue where status='running'),
    'failed',(select count(*) from commercial_intel.work_queue where status='failed')
  ),
  'sheets',jsonb_build_object(
    'targets',(select count(*) from commercial_intel.sheet_targets),
    'configured',(select count(*) from commercial_intel.sheet_targets where spreadsheet_id is not null),
    'sync_enabled',(select count(*) from commercial_intel.sheet_targets where sync_enabled)
  )
)
$$;
;
