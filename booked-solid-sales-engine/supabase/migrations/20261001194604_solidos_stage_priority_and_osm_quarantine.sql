
create or replace function booked_solid.claim_work(p_worker text)
returns setof booked_solid.work_queue
language plpgsql
security definer
set search_path='booked_solid','public'
as $function$
begin
 return query
 update booked_solid.work_queue q
 set status='running',locked_at=now(),locked_by=p_worker,attempts=attempts+1,updated_at=now()
 where q.id=(
   select id from booked_solid.work_queue
   where status='pending' and available_at<=now()
   order by
    case when kind='qualify' and payload->>'reason' like 'pipeline_recovery%' then 100 else 0 end desc,
    case
      when kind='qualify' then 8
      when kind='contact' then 7
      when kind='research' then 6
      when kind='discover' then 5
      when kind='resolve' then 4
      when kind='message' then 3
      when kind='location' then 2
      else 1
    end desc,
    case when created_at < now()-interval '15 minutes' then 50
         when created_at < now()-interval '5 minutes' then 20
         else 0 end desc,
    priority desc, created_at
   for update skip locked limit 1
 )
 returning q.*;
end
$function$;

update booked_solid.source_catalog
set enabled=false,
    lifecycle_state='paused',
    metadata=coalesce(metadata,'{}'::jsonb) ||
      jsonb_build_object(
        'state','quarantined_optional',
        'quarantine_reason','repeated_overpass_transient_failures_failopen_active',
        'quarantined_at',now(),
        'pipeline_dependency','optional',
        'failover_mode','qualification_fallback'
      ),
    updated_at=now()
where slug='openstreetmap_overpass'
  and consecutive_errors>=10;
