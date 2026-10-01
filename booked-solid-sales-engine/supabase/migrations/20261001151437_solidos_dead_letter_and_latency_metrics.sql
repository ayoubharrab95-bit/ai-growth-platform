create or replace function solidos_control.capture_dead_letter_trigger()
returns trigger language plpgsql security invoker set search_path=''
as $function$
begin
 if new.status='failed' and old.status is distinct from 'failed' then
  insert into solidos_control.dead_letter(
   work_queue_id,kind,payload,attempts,last_error,first_seen_at,failed_at,source_slug,failure_class
  ) values(
   new.id,new.kind,coalesce(new.payload,'{}'::jsonb),new.attempts,new.last_error,new.created_at,new.updated_at,
   new.payload->>'source_slug',
   case when coalesce(new.last_error,'') ~* 'overpass.*(504|406|http_0)|overpass_transient' then 'overpass_transient'
        when coalesce(new.last_error,'') ~* 'timeout' then 'network_timeout'
        when coalesce(new.last_error,'') ~* '429|rate' then 'rate_limit'
        when coalesce(new.last_error,'') ~* '5[0-9][0-9]' then 'upstream_5xx'
        else 'unknown' end
  )
  on conflict(work_queue_id) do update set attempts=excluded.attempts,last_error=excluded.last_error,
    failed_at=excluded.failed_at,failure_class=excluded.failure_class,recovery_status='UNRESOLVED',updated_at=now();
 elsif new.status='done' and old.status='failed' then
  update solidos_control.dead_letter set recovery_status='RECOVERED',updated_at=now()
   where work_queue_id=new.id;
 end if;
 return new;
end
$function$;

drop trigger if exists solidos_capture_dead_letter on booked_solid.work_queue;
create trigger solidos_capture_dead_letter after update of status on booked_solid.work_queue
for each row execute function solidos_control.capture_dead_letter_trigger();

create or replace view solidos_control.pipeline_latency
with (security_invoker=true)
as
select kind,
 count(*) filter(where status='done' and created_at>now()-interval '24 hours')::int completed_24h,
 round(percentile_cont(0.5) within group(order by extract(epoch from(updated_at-created_at))/60)
  filter(where status='done' and created_at>now()-interval '24 hours')::numeric,2) p50_minutes,
 round(percentile_cont(0.9) within group(order by extract(epoch from(updated_at-created_at))/60)
  filter(where status='done' and created_at>now()-interval '24 hours')::numeric,2) p90_minutes,
 round(percentile_cont(0.95) within group(order by extract(epoch from(updated_at-created_at))/60)
  filter(where status='done' and created_at>now()-interval '24 hours')::numeric,2) p95_minutes
from booked_solid.work_queue group by kind;
