
create or replace function public.solidos_pipeline_pressure()
returns jsonb
language sql
security definer
set search_path=''
as $function$
with m as (
  select
    (select count(*) from booked_solid.work_queue where status='pending' and available_at<=now())::int due_now,
    (select count(*) from booked_solid.work_queue where status='running')::int running_now,
    (select count(*) from booked_solid.work_queue where status='pending' and available_at<=now() and kind='discover')::int discovery_due,
    (select count(*) from booked_solid.work_queue where status='pending' and available_at<=now() and kind in ('resolve','research','qualify','contact','message'))::int downstream_due,
    (select count(*) from booked_solid.work_queue where status in ('pending','running') and kind='resolve')::int resolve_backlog,
    coalesce((select max(extract(epoch from(now()-created_at))) from booked_solid.work_queue where status='pending' and available_at<=now() and kind in ('resolve','research','qualify','contact','message')),0)::int downstream_oldest_seconds,
    (select count(*) from booked_solid.work_queue where created_at>now()-interval '15 minutes' and kind in ('resolve','research','qualify','contact','message'))::int downstream_arrivals_15m,
    (select count(*) from booked_solid.work_queue where status='done' and finished_at>now()-interval '15 minutes' and kind in ('resolve','research','qualify','contact','message'))::int downstream_completed_15m,
    (select count(*) from booked_solid.work_queue where status='running' and locked_at<now()-interval '5 minutes')::int stale_running
),
d as (
  select *,
    case
      when downstream_completed_15m>0 then round(downstream_arrivals_15m::numeric/downstream_completed_15m,2)
      when downstream_arrivals_15m>0 then 9.99
      else 0
    end as arrival_completion_ratio
  from m
)
select jsonb_build_object(
  'at',now(),
  'due_now',due_now,
  'running',running_now,
  'discovery_due',discovery_due,
  'downstream_due',downstream_due,
  'resolve_backlog',resolve_backlog,
  'downstream_oldest_seconds',downstream_oldest_seconds,
  'arrivals_15m',downstream_arrivals_15m,
  'completed_15m',downstream_completed_15m,
  'arrival_completion_ratio',arrival_completion_ratio,
  'stale_running',stale_running,
  'pause',
    stale_running>0
    or running_now>16
    or downstream_due>40
    or (downstream_due>4 and downstream_oldest_seconds>180)
    or discovery_due>15
    or (downstream_due>15 and arrival_completion_ratio>1.5),
  'throttle',
    downstream_due>20
    or (downstream_due>2 and downstream_oldest_seconds>90)
    or discovery_due>9
    or (downstream_due>8 and arrival_completion_ratio>1.2),
  'recommended_limit',
    case
      when stale_running>0 or running_now>16 or downstream_due>40 or (downstream_due>4 and downstream_oldest_seconds>180) or discovery_due>15 or (downstream_due>15 and arrival_completion_ratio>1.5) then 0
      when downstream_due>20 or (downstream_due>2 and downstream_oldest_seconds>90) or discovery_due>9 or (downstream_due>8 and arrival_completion_ratio>1.2) then 1
      when downstream_due>10 or discovery_due>6 then 2
      else 3
    end
)
from d;
$function$;

revoke all on function public.solidos_pipeline_pressure() from public,anon,authenticated;
grant execute on function public.solidos_pipeline_pressure() to service_role;
