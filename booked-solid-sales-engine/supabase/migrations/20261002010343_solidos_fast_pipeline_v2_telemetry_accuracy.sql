
create or replace view solidos_control.pipeline_stage_health as
with kinds as (
  select unnest(array['discover','resolve','research','qualify','contact','message','location']::text[]) as kind
),
agg as (
  select
    k.kind,
    count(w.*) filter (where w.status='pending' and w.available_at<=now())::int as due_now,
    count(w.*) filter (where w.status='pending' and w.available_at>now())::int as scheduled_future,
    count(w.*) filter (where w.status='running')::int as running_now,
    coalesce(max(extract(epoch from (now()-w.available_at)))
      filter (where w.status='pending' and w.available_at<=now()),0)::int as oldest_due_seconds,
    count(w.*) filter (where w.status='done' and w.finished_at>now()-interval '15 minutes')::int as completed_15m,
    count(w.*) filter (where w.status='done' and w.finished_at>now()-interval '60 minutes')::int as completed_60m,
    round(avg(greatest(0,extract(epoch from (w.last_started_at-w.available_at))))
      filter (where w.status='done' and w.finished_at>now()-interval '60 minutes'
              and w.last_started_at is not null),1) as avg_queue_wait_seconds_60m,
    round(percentile_cont(0.95) within group
      (order by greatest(0,extract(epoch from (w.last_started_at-w.available_at)))::double precision)
      filter (where w.status='done' and w.finished_at>now()-interval '60 minutes'
              and w.last_started_at is not null)::numeric,1) as p95_queue_wait_seconds_60m,
    round(avg(greatest(0,extract(epoch from (w.finished_at-w.last_started_at))))
      filter (where w.status='done' and w.finished_at>now()-interval '60 minutes'
              and w.last_started_at is not null and w.finished_at is not null),1)
      as avg_end_to_end_after_first_claim_seconds_60m
  from kinds k
  left join booked_solid.work_queue w on w.kind=k.kind
  group by k.kind
)
select
  a.kind,a.due_now,a.scheduled_future,a.running_now,a.oldest_due_seconds,
  a.completed_15m,a.completed_60m,a.avg_queue_wait_seconds_60m,
  a.p95_queue_wait_seconds_60m,a.avg_end_to_end_after_first_claim_seconds_60m,
  s.target_queue_seconds,s.warning_queue_seconds,s.target_total_seconds,
  case
    when a.running_now>0 and exists(
      select 1 from booked_solid.work_queue w
      where w.kind=a.kind and w.status='running'
        and w.locked_at<now()-interval '5 minutes'
    ) then 'DEGRADED'
    when a.oldest_due_seconds>s.warning_queue_seconds then 'WARNING'
    when a.due_now=0 or a.oldest_due_seconds<=s.target_queue_seconds then 'HEALTHY'
    else 'WATCH'
  end as sla_state
from agg a
left join solidos_control.pipeline_sla s using(kind);

create or replace view solidos_control.pipeline_stage_metrics_v2
with (security_invoker=true)
as
with kinds as (
  select unnest(array['discover','resolve','research','qualify','contact','message','location']::text[]) as kind
),
w as (
  select
    k.kind,
    count(q.*) filter(where q.created_at>now()-interval '60 minutes')::int arrivals_60m,
    count(q.*) filter(where q.status='done' and q.finished_at>now()-interval '60 minutes')::int completions_60m,
    count(q.*) filter(where q.status='pending')::int pending,
    count(q.*) filter(where q.status='pending' and q.available_at<=now())::int due_now,
    count(q.*) filter(where q.status='running')::int running,
    coalesce(max(greatest(0,extract(epoch from(now()-q.available_at))))
      filter(where q.status='pending' and q.available_at<=now()),0)::int oldest_due_seconds,
    round(percentile_cont(.50) within group
      (order by greatest(0,extract(epoch from(q.last_started_at-q.available_at)))::double precision)
      filter(where q.last_started_at>now()-interval '60 minutes' and q.last_started_at is not null)::numeric,1) p50_queue_seconds_60m,
    round(percentile_cont(.95) within group
      (order by greatest(0,extract(epoch from(q.last_started_at-q.available_at)))::double precision)
      filter(where q.last_started_at>now()-interval '60 minutes' and q.last_started_at is not null)::numeric,1) p95_queue_seconds_60m,
    count(q.*) filter(where q.status='failed' and q.updated_at>now()-interval '60 minutes')::int failed_60m,
    count(q.*) filter(where q.attempts>1 and q.updated_at>now()-interval '60 minutes')::int retries_60m,
    count(q.*) filter(where q.status='done' and q.finished_at>now()-interval '15 minutes')::int completions_15m
  from kinds k left join booked_solid.work_queue q on q.kind=k.kind
  group by k.kind
)
select
  w.*,
  case when w.arrivals_60m>0 then round(w.failed_60m::numeric/w.arrivals_60m,4) else 0 end error_rate_60m,
  w.completions_60m::numeric throughput_per_hour,
  s.target_queue_seconds,s.warning_queue_seconds,s.target_total_seconds,
  case
    when w.running>0 and exists(
      select 1 from booked_solid.work_queue q
      where q.kind=w.kind and q.status='running' and q.locked_at<now()-interval '5 minutes'
    ) then 'DEGRADED'
    when w.oldest_due_seconds>s.warning_queue_seconds then 'WARNING'
    when w.due_now=0 or w.oldest_due_seconds<=s.target_queue_seconds then 'HEALTHY'
    else 'WATCH'
  end sla_state
from w left join solidos_control.pipeline_sla s using(kind);

revoke all on solidos_control.pipeline_stage_metrics_v2 from anon,authenticated;
grant select on solidos_control.pipeline_stage_metrics_v2 to service_role;

create or replace function solidos_control.pipeline_metrics_v2()
returns jsonb
language sql
security definer
set search_path=''
as $function$
with sheet as (
  select jsonb_build_object(
    'kind','sheet_sync',
    'arrivals_60m',count(*) filter(where requested_at>now()-interval '60 minutes'),
    'completions_60m',count(*) filter(where status='SUCCEEDED' and finished_at>now()-interval '60 minutes'),
    'pending',count(*) filter(where status='PENDING'),
    'due_now',count(*) filter(where status='PENDING' and debounce_until<=now()),
    'running',count(*) filter(where status='RUNNING'),
    'oldest_due_seconds',coalesce(max(greatest(0,extract(epoch from(now()-debounce_until))))
      filter(where status='PENDING' and debounce_until<=now()),0)::int,
    'p50_latency_seconds_60m',round(percentile_cont(.50) within group
      (order by greatest(0,extract(epoch from(finished_at-requested_at)))::double precision)
      filter(where status='SUCCEEDED' and finished_at>now()-interval '60 minutes')::numeric,1),
    'p95_latency_seconds_60m',round(percentile_cont(.95) within group
      (order by greatest(0,extract(epoch from(finished_at-requested_at)))::double precision)
      filter(where status='SUCCEEDED' and finished_at>now()-interval '60 minutes')::numeric,1),
    'failed_60m',count(*) filter(where status='FAILED' and finished_at>now()-interval '60 minutes'),
    'retries_60m',count(*) filter(where attempts>1 and updated_at>now()-interval '60 minutes'),
    'last_verified_success',max(finished_at) filter(where status='SUCCEEDED' and payload ? 'sync_verification')
  ) v
  from solidos_control.sheet_sync_requests
),
e2e as (
  select jsonb_build_object(
    'measurement_basis','company.created_at to current lead/contact/sheet timestamps; qualified historical transition time is approximated by lead.updated_at until dedicated transition history accumulates',
    'discovery_to_lead_p50_seconds',(
      select round(percentile_cont(.50) within group(order by extract(epoch from(l.created_at-c.created_at)))::numeric,1)
      from booked_solid.leads l join booked_solid.companies c on c.id=l.company_id
      where l.created_at>now()-interval '24 hours' and l.created_at>=c.created_at
    ),
    'discovery_to_lead_p95_seconds',(
      select round(percentile_cont(.95) within group(order by extract(epoch from(l.created_at-c.created_at)))::numeric,1)
      from booked_solid.leads l join booked_solid.companies c on c.id=l.company_id
      where l.created_at>now()-interval '24 hours' and l.created_at>=c.created_at
    ),
    'discovery_to_qualified_p50_seconds_approx',(
      select round(percentile_cont(.50) within group(order by extract(epoch from(l.updated_at-c.created_at)))::numeric,1)
      from booked_solid.leads l join booked_solid.companies c on c.id=l.company_id
      where l.status in ('qualified','message_ready','queued','sent','replied','meeting','won')
        and l.updated_at>now()-interval '24 hours' and l.updated_at>=c.created_at
    ),
    'discovery_to_contact_route_p50_seconds',(
      select round(percentile_cont(.50) within group(order by extract(epoch from(ct.created_at-c.created_at)))::numeric,1)
      from booked_solid.contacts ct join booked_solid.companies c on c.id=ct.company_id
      where ct.created_at>now()-interval '24 hours' and ct.created_at>=c.created_at
    )
  ) v
)
select jsonb_build_object(
  'at',now(),
  'stages',(select coalesce(jsonb_agg(to_jsonb(m) order by m.kind),'[]'::jsonb) from solidos_control.pipeline_stage_metrics_v2 m),
  'sheet_sync',(select v from sheet),
  'end_to_end',(select v from e2e)
);
$function$;

revoke all on function solidos_control.pipeline_metrics_v2() from public,anon,authenticated;
grant execute on function solidos_control.pipeline_metrics_v2() to service_role;

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
    coalesce((select max(greatest(0,extract(epoch from(now()-available_at))))
      from booked_solid.work_queue
      where status='pending' and available_at<=now()
        and kind in ('resolve','research','qualify','contact','message')),0)::int downstream_oldest_seconds,
    (select count(*) from booked_solid.work_queue where created_at>now()-interval '15 minutes' and kind in ('resolve','research','qualify','contact','message'))::int downstream_arrivals_15m,
    (select count(*) from booked_solid.work_queue where status='done' and finished_at>now()-interval '15 minutes' and kind in ('resolve','research','qualify','contact','message'))::int downstream_completed_15m,
    (select count(*) from booked_solid.work_queue where status='running' and locked_at<now()-interval '5 minutes')::int stale_running
),
d as (
  select *,case
    when downstream_completed_15m>0 then round(downstream_arrivals_15m::numeric/downstream_completed_15m,2)
    when downstream_arrivals_15m>0 then 9.99 else 0 end arrival_completion_ratio
  from m
)
select jsonb_build_object(
  'at',now(),'due_now',due_now,'running',running_now,'discovery_due',discovery_due,
  'downstream_due',downstream_due,'resolve_backlog',resolve_backlog,
  'downstream_oldest_seconds',downstream_oldest_seconds,
  'arrivals_15m',downstream_arrivals_15m,'completed_15m',downstream_completed_15m,
  'arrival_completion_ratio',arrival_completion_ratio,'stale_running',stale_running,
  'pause', stale_running>0 or running_now>16 or downstream_due>40
    or (downstream_due>4 and downstream_oldest_seconds>180)
    or discovery_due>15 or (downstream_due>15 and arrival_completion_ratio>1.5),
  'throttle', downstream_due>20
    or (downstream_due>2 and downstream_oldest_seconds>90)
    or discovery_due>9 or (downstream_due>8 and arrival_completion_ratio>1.2),
  'recommended_limit',case
    when stale_running>0 or running_now>16 or downstream_due>40
      or (downstream_due>4 and downstream_oldest_seconds>180)
      or discovery_due>15 or (downstream_due>15 and arrival_completion_ratio>1.5) then 0
    when downstream_due>20 or (downstream_due>2 and downstream_oldest_seconds>90)
      or discovery_due>9 or (downstream_due>8 and arrival_completion_ratio>1.2) then 1
    when downstream_due>10 or discovery_due>6 then 2
    else 3 end
)
from d;
$function$;

revoke all on function public.solidos_pipeline_pressure() from public,anon,authenticated;
grant execute on function public.solidos_pipeline_pressure() to service_role;
