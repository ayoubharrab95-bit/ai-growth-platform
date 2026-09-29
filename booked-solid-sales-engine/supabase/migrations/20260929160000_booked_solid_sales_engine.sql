create schema if not exists booked_solid;

create table if not exists booked_solid.source_catalog (
 id uuid primary key default gen_random_uuid(), slug text unique not null, name text not null,
 source_type text not null, base_weight numeric not null default 1, enabled boolean not null default true,
 reliability_score numeric not null default 50, metadata jsonb not null default '{}'::jsonb,
 last_error_at timestamptz, last_success_at timestamptz, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists booked_solid.search_strategies (
 id uuid primary key default gen_random_uuid(), slug text unique not null, trade text not null,
 geography text not null, intent text not null, query_template text not null, offer_hint text,
 exploration_weight numeric not null default 1, performance_score numeric not null default 50,
 uses_count int not null default 0, qualified_count int not null default 0, reply_count int not null default 0,
 meeting_count int not null default 0, won_count int not null default 0, revenue_usd numeric not null default 0,
 enabled boolean not null default true, last_used_at timestamptz, metadata jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists booked_solid.companies (
 id uuid primary key default gen_random_uuid(), canonical_domain text unique, normalized_name text,
 name text not null, trade text, location_text text, state text, country text default 'US', website_url text,
 source_first_seen text, source_last_seen text, employee_band text, fit_score numeric,
 status text not null default 'discovered', recommended_offer text, last_researched_at timestamptz,
 metadata jsonb not null default '{}'::jsonb, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists booked_solid.evidence (
 id uuid primary key default gen_random_uuid(), company_id uuid not null references booked_solid.companies(id) on delete cascade,
 evidence_type text not null, claim text not null, snippet text, source_url text not null,
 observed_at timestamptz not null default now(), confidence numeric not null default 50, metadata jsonb not null default '{}'::jsonb
);

create table if not exists booked_solid.contacts (
 id uuid primary key default gen_random_uuid(), company_id uuid not null references booked_solid.companies(id) on delete cascade,
 full_name text, role text, email text, email_confidence numeric, source_url text,
 status text not null default 'unverified', created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(company_id,email)
);

create table if not exists booked_solid.leads (
 id uuid primary key default gen_random_uuid(), company_id uuid not null references booked_solid.companies(id) on delete cascade,
 contact_id uuid references booked_solid.contacts(id) on delete set null,
 strategy_id uuid references booked_solid.search_strategies(id) on delete set null,
 offer text not null, score numeric not null default 0, fit_score numeric not null default 0,
 pain_score numeric not null default 0, evidence_score numeric not null default 0, contact_score numeric not null default 0,
 status text not null default 'candidate', why_now text, lead_brief jsonb not null default '{}'::jsonb,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
 unique(company_id,offer)
);

create table if not exists booked_solid.outreach_queue (
 id uuid primary key default gen_random_uuid(), lead_id uuid not null references booked_solid.leads(id) on delete cascade,
 sequence_no int not null default 1, channel text not null default 'email', subject text, body text,
 personalization_evidence jsonb not null default '[]'::jsonb,
 status text not null default 'blocked_email_not_configured',
 scheduled_at timestamptz, sent_at timestamptz, failure_reason text, created_at timestamptz not null default now(),
 unique(lead_id,sequence_no)
);

create table if not exists booked_solid.suppression (
 id uuid primary key default gen_random_uuid(), email text, domain text, reason text not null, source text, created_at timestamptz not null default now()
);

create table if not exists booked_solid.work_queue (
 id uuid primary key default gen_random_uuid(), kind text not null, priority numeric not null default 50,
 payload jsonb not null default '{}'::jsonb, status text not null default 'pending', attempts int not null default 0,
 available_at timestamptz not null default now(), locked_at timestamptz, locked_by text, last_error text,
 created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists booked_solid.runs (
 id uuid primary key default gen_random_uuid(), mode text not null, strategy_id uuid references booked_solid.search_strategies(id) on delete set null,
 source_id uuid references booked_solid.source_catalog(id) on delete set null, query_text text,
 status text not null default 'started', discovered_count int not null default 0, qualified_count int not null default 0,
 error text, started_at timestamptz not null default now(), finished_at timestamptz
);

alter table booked_solid.source_catalog enable row level security;
alter table booked_solid.search_strategies enable row level security;
alter table booked_solid.companies enable row level security;
alter table booked_solid.evidence enable row level security;
alter table booked_solid.contacts enable row level security;
alter table booked_solid.leads enable row level security;
alter table booked_solid.outreach_queue enable row level security;
alter table booked_solid.suppression enable row level security;
alter table booked_solid.work_queue enable row level security;
alter table booked_solid.runs enable row level security;

insert into booked_solid.source_catalog(slug,name,source_type,base_weight) values
('web_search','Web search discovery','search',1.2),
('company_websites','Company websites','company_site',1.5),
('trade_associations','Trade associations','association',1.0),
('industry_directories','Industry directories','directory',0.9),
('public_company_sources','Public company sources','public_registry',0.8)
on conflict(slug) do nothing;

insert into booked_solid.search_strategies(slug,trade,geography,intent,query_template,offer_hint,exploration_weight) values
('hvac-estimate-quote','HVAC','US','estimation_pain','{trade} contractor {location} "free estimate"','custom_estimator',1.2),
('hvac-field-quote','HVAC','US','field_quoting','{trade} {location} "request a quote"','custom_estimator',1.0),
('hvac-change-order','HVAC','US','change_orders','{trade} {location} "change order"','penmark',1.1),
('roofing-estimate-quote','Roofing','US','estimation_pain','{trade} contractor {location} "free estimate"','custom_estimator',1.2),
('roofing-change-order','Roofing','US','change_orders','{trade} contractor {location} "change order"','penmark',1.2),
('remodeling-estimate','Remodeling','US','estimation_pain','{trade} contractor {location} "estimate"','custom_estimator',1.2),
('remodeling-change-order','Remodeling','US','change_orders','{trade} {location} "change orders"','penmark',1.2),
('plumbing-estimate','Plumbing','US','estimation_pain','{trade} contractor {location} "free estimate"','custom_estimator',1.0),
('electrical-estimate','Electrical','US','estimation_pain','{trade} contractor {location} "free estimate"','custom_estimator',1.0),
('painting-proposals','Painting','US','proposal_workflow','{trade} contractor {location} proposals estimates','custom_estimator',0.9),
('multi-location-contractors','Mixed','US','scale','contractor {location} "multiple locations" estimate','automation',0.8),
('software-overload','Mixed','US','workflow_fragmentation','contractor {location} estimating software CRM pricing','automation',0.8)
on conflict(slug) do nothing;

create index if not exists idx_bs_company_status on booked_solid.companies(status);
create index if not exists idx_bs_leads_status_score on booked_solid.leads(status,score desc);
create index if not exists idx_bs_queue_pick on booked_solid.work_queue(status,available_at,priority desc);
