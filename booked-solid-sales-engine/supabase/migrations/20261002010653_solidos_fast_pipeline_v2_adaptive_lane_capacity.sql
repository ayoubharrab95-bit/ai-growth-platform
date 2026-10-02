
create or replace function solidos_control.lane_capacity_plan()
returns table(ord int,lane text,desired_n int,reason jsonb)
language sql
security definer
set search_path=''
as $function$
with m as (
  select
    coalesce(max(due_now) filter(where kind='resolve'),0)::int resolve_due,
    coalesce(max(oldest_due_seconds) filter(where kind='resolve'),0)::int resolve_oldest,
    coalesce(max(arrivals_60m) filter(where kind='resolve'),0)::int resolve_arrivals,
    coalesce(max(completions_60m) filter(where kind='resolve'),0)::int resolve_completed,
    coalesce(max(failed_60m) filter(where kind='resolve'),0)::int resolve_failed,
    coalesce(max(due_now) filter(where kind='research'),0)::int research_due,
    coalesce(max(oldest_due_seconds) filter(where kind='research'),0)::int research_oldest,
    coalesce(max(arrivals_60m) filter(where kind='research'),0)::int research_arrivals,
    coalesce(max(completions_60m) filter(where kind='research'),0)::int research_completed,
    coalesce(max(failed_60m) filter(where kind='research'),0)::int research_failed,
    coalesce(max(due_now) filter(where kind='qualify'),0)::int qualify_due,
    coalesce(max(oldest_due_seconds) filter(where kind='qualify'),0)::int qualify_oldest,
    coalesce(max(arrivals_60m) filter(where kind='qualify'),0)::int qualify_arrivals,
    coalesce(max(completions_60m) filter(where kind='qualify'),0)::int qualify_completed,
    coalesce(max(failed_60m) filter(where kind='qualify'),0)::int qualify_failed,
    coalesce(max(due_now) filter(where kind='contact'),0)::int contact_due,
    coalesce(max(due_now) filter(where kind='message'),0)::int message_due,
    coalesce(max(failed_60m) filter(where kind in ('contact','message')),0)::int contact_failed,
    coalesce(max(due_now) filter(where kind in ('discover','location')),0)::int discovery_due
  from solidos_control.pipeline_stage_metrics_v2
),
x as (
  select m.*,
    (select count(*) from booked_solid.work_queue
      where status='pending' and available_at<=now()
        and booked_solid.work_lane(kind,priority,payload)='fast')::int fast_due,
    (select count(*) from booked_solid.work_queue where status='running')::int running_now,
    public.solidos_pipeline_pressure() pressure
  from m
),
raw as (
  select 1 ord,'fast'::text lane,
    least(3,case when x.fast_due>0 then greatest(1,ceil(x.fast_due/2.0)::int) else 0 end)::int want,
    jsonb_build_object('due',x.fast_due,'policy','priority_fast_lane') reason
  from x
  union all
  select 2,'resolve',
    case
      when x.resolve_due=0 then 0
      when x.resolve_failed>=3 then least(2,greatest(1,ceil(x.resolve_due/3.0)::int))
      when x.resolve_oldest>240 or x.resolve_arrivals>x.resolve_completed
        then least(6,greatest(3,ceil(x.resolve_due/2.0)::int))
      when x.resolve_oldest>120
        then least(5,greatest(2,ceil(x.resolve_due/2.0)::int))
      else least(4,greatest(1,ceil(x.resolve_due/3.0)::int))
    end,
    jsonb_build_object('due',x.resolve_due,'oldest_s',x.resolve_oldest,'arrivals_h',x.resolve_arrivals,'completed_h',x.resolve_completed,'failed_h',x.resolve_failed)
  from x
  union all
  select 3,'qualify',
    case
      when x.qualify_due=0 then 0
      when x.qualify_failed>=3 then 1
      when x.qualify_oldest>90 or x.qualify_arrivals>x.qualify_completed
        then least(4,greatest(2,ceil(x.qualify_due/2.0)::int))
      else least(3,greatest(1,ceil(x.qualify_due/2.0)::int))
    end,
    jsonb_build_object('due',x.qualify_due,'oldest_s',x.qualify_oldest,'arrivals_h',x.qualify_arrivals,'completed_h',x.qualify_completed,'failed_h',x.qualify_failed)
  from x
  union all
  select 4,'research',
    case
      when x.research_due=0 then 0
      when x.research_failed>=3 then 1
      when x.research_oldest>120 or x.research_arrivals>x.research_completed
        then least(3,greatest(2,ceil(x.research_due/2.0)::int))
      else least(2,greatest(1,ceil(x.research_due/2.0)::int))
    end,
    jsonb_build_object('due',x.research_due,'oldest_s',x.research_oldest,'arrivals_h',x.research_arrivals,'completed_h',x.research_completed,'failed_h',x.research_failed)
  from x
  union all
  select 5,'contact',
    case
      when x.contact_due+x.message_due=0 then 0
      when x.contact_failed>=3 then 1
      else least(2,greatest(1,ceil((x.contact_due+x.message_due)/2.0)::int))
    end,
    jsonb_build_object('due',x.contact_due+x.message_due,'failed_h',x.contact_failed)
  from x
  union all
  select 6,'discovery',
    case
      when x.discovery_due=0 then 0
      when coalesce((x.pressure->>'pause')::boolean,false) then 0
      else least(
        coalesce((x.pressure->>'recommended_limit')::int,1),
        case when x.discovery_due>4 then 3 when x.discovery_due>1 then 2 else 1 end
      )
    end,
    jsonb_build_object('due',x.discovery_due,'pressure',x.pressure)
  from x
),
alloc as (
  select r.ord,r.lane,r.reason,r.want,x.running_now,
    greatest(
      0,
      least(
        r.want,
        greatest(0,12-x.running_now)
        - coalesce(sum(r.want) over(order by r.ord rows between unbounded preceding and 1 preceding),0)
      )
    )::int n
  from raw r cross join x
)
select ord,lane,n,
       reason || jsonb_build_object('global_running',running_now,'global_cap',12)
from alloc
order by ord;
$function$;

revoke all on function solidos_control.lane_capacity_plan() from public,anon,authenticated;
grant execute on function solidos_control.lane_capacity_plan() to service_role;

select cron.alter_job(
  38,
  schedule := '* * * * *',
  command := $cron$
    with alloc as (
      select * from solidos_control.lane_capacity_plan()
    )
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name='booked_solid_project_url') || '/functions/v1/booked-solid-worker',
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'apikey',(select decrypted_secret from vault.decrypted_secrets where name='booked_solid_publishable_key')
      ),
      body := jsonb_build_object(
        'source','solidos-adaptive-lane-cron',
        'batch_size',1,
        'lane',a.lane,
        'capacity_reason',a.reason
      ),
      timeout_milliseconds := 45000
    ) as request_id
    from alloc a
    cross join lateral generate_series(1,a.desired_n)
    where a.desired_n>0;
  $cron$,
  active := true
);
