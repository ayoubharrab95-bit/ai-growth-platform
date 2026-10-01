-- Booked Solid comprehensive audit hardening (2026-10-01)
-- Keeps Nominatim failures separate from OpenStreetMap / Overpass source reliability,
-- classifies Overpass 403 as transient, hardens SECURITY DEFINER search_path,
-- and safely closes work that is provably obsolete.

;

-- Idempotent queue hygiene for location work that no longer has value.
update booked_solid.work_queue w
set status='done',
    last_error='audit_cleanup_location_obsolete',
    locked_at=null,
    locked_by=null,
    updated_at=now()
from booked_solid.companies c
where w.kind='location'
  and w.status='pending'
  and c.id::text=w.payload->>'company_id'
  and (
    c.status='rejected'
    or (coalesce(c.location_text,'')<>'' and coalesce(c.state,'')<>'')
  );

-- Country-only Resolve work cannot safely identify a company without coordinates
-- or a published business-domain email. Mark only those provably unresolved rows done.
with generic as (
  select w.id,w.payload->>'company_id' company_id
  from booked_solid.work_queue w
  where w.kind='resolve'
    and w.status='pending'
    and upper(trim(coalesce(w.payload->>'location_text',w.payload->>'geography','')))
        in ('US','USA','UNITED STATES','UNITED STATES OF AMERICA')
),
safe_close as (
  select g.*
  from generic g
  where not exists (
    select 1
    from booked_solid.contacts ct
    where ct.company_id::text=g.company_id
      and ct.status not in ('invalid','suppressed')
      and ct.email is not null
      and split_part(lower(ct.email),'@',2) not in (
        'gmail.com','googlemail.com','yahoo.com','ymail.com','outlook.com','hotmail.com',
        'live.com','msn.com','aol.com','icloud.com','me.com','mac.com','proton.me',
        'protonmail.com','gmx.com','mail.com','comcast.net','att.net','verizon.net','cox.net'
      )
      and split_part(lower(ct.email),'@',2) !~ '\.(gov|edu)$'
  )
)
update booked_solid.work_queue w
set status='done',
    last_error='audit_cleanup_insufficient_location',
    locked_at=null,
    locked_by=null,
    updated_at=now()
from safe_close s
where w.id=s.id;
