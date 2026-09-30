-- Allow low-priority location-only enrichment jobs without re-running lead qualification.
alter table booked_solid.work_queue
  drop constraint work_queue_kind_check;

alter table booked_solid.work_queue
  add constraint work_queue_kind_check
  check (kind = any (array[
    'discover'::text,
    'research'::text,
    'contact'::text,
    'qualify'::text,
    'message'::text,
    'followup'::text,
    'result'::text,
    'resolve'::text,
    'location'::text
  ]));
