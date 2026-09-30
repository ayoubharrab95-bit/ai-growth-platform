-- Booked Solid additive enrichment: triggers, phones, opportunity ranking, SMS safety gate.
-- This migration does NOT enable SMS sending and does NOT make phone/trigger data a qualification gate.

alter table booked_solid.contacts
  add column if not exists phone text,
  add column if not exists phone_type text,
  add column if not exists phone_confidence numeric,
  add column if not exists phone_source_url text,
  add column if not exists phone_status text not null default 'unverified',
  add column if not exists sms_consent_status text not null default 'unknown',
  add column if not exists sms_eligible boolean not null default false,
  add column if not exists phone_last_verified_at timestamptz;

create index if not exists contacts_company_phone_idx
  on booked_solid.contacts(company_id, phone)
  where phone is not null;

alter table booked_solid.leads
  add column if not exists trigger_score numeric not null default 0,
  add column if not exists opportunity_score numeric not null default 0,
  add column if not exists priority_band text not null default 'standard';

create index if not exists leads_opportunity_score_idx
  on booked_solid.leads(opportunity_score desc);

alter table booked_solid.companies
  add column if not exists enrichment_version integer not null default 0,
  add column if not exists last_enriched_at timestamptz;

alter table booked_solid.runtime_settings
  add column if not exists sms_enabled boolean not null default false,
  add column if not exists sms_provider text,
  add column if not exists sms_require_consent boolean not null default true;

update booked_solid.runtime_settings
set sms_enabled=false,
    sms_provider=null,
    sms_require_consent=true,
    updated_at=now()
where id=true;

-- Populate ranking-only opportunity values for existing candidate/qualified leads.
update booked_solid.leads
set opportunity_score=round(least(100::numeric, score*0.82 + trigger_score*0.18)),
    priority_band=case
      when trigger_score>=35 and round(least(100::numeric, score*0.82 + trigger_score*0.18))>=75 then 'hot'
      when round(least(100::numeric, score*0.82 + trigger_score*0.18))>=70 then 'high'
      when trigger_score>=20 then 'signal'
      else 'standard'
    end,
    updated_at=now()
where status in ('qualified','candidate');
