-- Comprehensive Booked Solid audit hardening.
-- Safe/idempotent: does not enable email, SMS, paid search, or narrow qualification thresholds.

-- Keep website-derived synthetic evidence idempotent.
with ranked as (
  select id,
         row_number() over(
           partition by company_id,evidence_type,source_url,claim
           order by observed_at desc,id
         ) rn
  from booked_solid.evidence
  where claim like 'Public sources contain signals related to %'
     or claim like 'Public website contains signals related to %'
)
delete from booked_solid.evidence e
using ranked r
where e.id=r.id and r.rn>1;

create unique index if not exists evidence_synthetic_unique_idx
  on booked_solid.evidence(company_id,evidence_type,source_url,claim)
  where claim like 'Public sources contain signals related to %'
     or claim like 'Public website contains signals related to %';

-- Public phone and unsubscribe token integrity.
create unique index if not exists contacts_company_phone_unique_idx
  on booked_solid.contacts(company_id,phone)
  where phone is not null;

create unique index if not exists outreach_queue_tracking_key_unique_idx
  on booked_solid.outreach_queue(tracking_key)
  where tracking_key is not null;

update booked_solid.outreach_queue
set tracking_key=gen_random_uuid()
where tracking_key is null;

alter table booked_solid.outreach_queue
  alter column tracking_key set not null;

-- Hospitality properties are not part of the current Booked Solid ICP.
update booked_solid.source_catalog
set enabled=false,
    lifecycle_state='paused',
    metadata=coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
      'disabled_reason','hospitality-only source conflicts with current Booked Solid ICP',
      'disabled_by','comprehensive_audit_2026_09_30'
    ),
    updated_at=now()
where slug='wikidata_sparql';

update booked_solid.search_strategies
set enabled=false,
    lifecycle_state='paused',
    metadata=coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
      'disabled_reason','hotel/resort strategy conflicts with hospitality exclusion',
      'disabled_by','comprehensive_audit_2026_09_30'
    ),
    updated_at=now()
where slug in (
  'hotel-multi-property',
  'resort-multi-property',
  'independent-hotels-guest-automation',
  'small-resorts-automation'
);

-- Conservative identity-based corrections found during the audit.
with fixes(name,new_trade) as (
 values
  ('Butter Plumbing','Plumbing'),
  ('Eagle Painting','Painting'),
  ('Pink Rabbit Roofing and Restoration','Roofing'),
  ('Premium Cabinets of Tulsa','Cabinet'),
  ('All County Fence Contractors LLC.','Fence'),
  ('Edge Electric','Electrical'),
  ('Modern Plumbing Industries, Inc.','Plumbing'),
  ('Pacific West Roofing, LLC','Roofing'),
  ('Palladium Roofing','Roofing'),
  ('Walter Danley Electrical Contracting LLC','Electrical')
)
update booked_solid.companies c
set trade=f.new_trade,
    metadata=coalesce(c.metadata,'{}'::jsonb) || jsonb_build_object(
      'trade_corrected_from_identity',true,
      'previous_trade',c.trade
    ),
    updated_at=now()
from fixes f
where c.name=f.name
  and c.trade is distinct from f.new_trade;
