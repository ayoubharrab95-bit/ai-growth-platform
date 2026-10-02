
create table if not exists booked_solid.source_scan_state (
  source_slug text primary key references booked_solid.source_catalog(slug) on delete cascade,
  next_page integer not null default 0,
  last_claimed_page integer,
  page_size integer not null default 100,
  scan_pages integer not null default 60,
  wraps bigint not null default 0,
  claims bigint not null default 0,
  last_claimed_at timestamptz,
  updated_at timestamptz not null default now()
);
alter table booked_solid.source_scan_state enable row level security;
revoke all on booked_solid.source_scan_state from public,anon,authenticated;
grant select,insert,update on booked_solid.source_scan_state to service_role;

CREATE OR REPLACE FUNCTION booked_solid.claim_source_scan_page(p_source_slug text, p_page_size integer DEFAULT 100, p_scan_pages integer DEFAULT 60)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_size integer:=greatest(25,least(coalesce(p_page_size,100),150));
  v_pages integer:=greatest(2,least(coalesce(p_scan_pages,60),500));
  v_page integer;
  v_next integer;
  v_wraps bigint;
  v_claims bigint;
begin
  insert into booked_solid.source_scan_state(
    source_slug,next_page,last_claimed_page,page_size,scan_pages,wraps,claims,last_claimed_at,updated_at
  )
  values(p_source_slug,1,0,v_size,v_pages,0,1,now(),now())
  on conflict(source_slug) do update set
    last_claimed_page=booked_solid.source_scan_state.next_page,
    next_page=case
      when booked_solid.source_scan_state.next_page+1>=v_pages then 0
      else booked_solid.source_scan_state.next_page+1
    end,
    page_size=v_size,
    scan_pages=v_pages,
    wraps=booked_solid.source_scan_state.wraps
      + case when booked_solid.source_scan_state.next_page+1>=v_pages then 1 else 0 end,
    claims=booked_solid.source_scan_state.claims+1,
    last_claimed_at=now(),
    updated_at=now()
  returning last_claimed_page,next_page,wraps,claims
  into v_page,v_next,v_wraps,v_claims;

  return jsonb_build_object(
    'source_slug',p_source_slug,
    'page_index',v_page,
    'offset',v_page*v_size,
    'page_size',v_size,
    'scan_pages',v_pages,
    'next_page',v_next,
    'wraps',v_wraps,
    'claims',v_claims,
    'at',now()
  );
end
$function$
;

CREATE OR REPLACE FUNCTION solidos_control.lane_capacity_plan()
 RETURNS TABLE(ord integer, lane text, desired_n integer, reason jsonb)
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
      when x.resolve_oldest>180 or x.resolve_arrivals>x.resolve_completed
        then least(6,greatest(3,ceil(x.resolve_due/2.0)::int))
      when x.resolve_oldest>75 or x.resolve_due>=3
        then least(5,greatest(2,ceil(x.resolve_due/2.0)::int))
      else least(4,greatest(1,ceil(x.resolve_due/2.0)::int))
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
$function$
;

CREATE OR REPLACE FUNCTION solidos_control.pgnet_watchdog()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_worker_queue integer:=0;
  v_total_queue integer:=0;
  v_latest_response timestamptz;
  v_response_age integer:=0;
  v_last_restart timestamptz;
  v_action text:='healthy';
  v_locked boolean;
begin
  v_locked:=pg_try_advisory_xact_lock(hashtext('solidos_pgnet_watchdog'));
  if not v_locked then
    return jsonb_build_object('ok',true,'action','lock_busy','at',now());
  end if;

  select count(*),
         count(*) filter(where url like '%/functions/v1/booked-solid-worker')
  into v_total_queue,v_worker_queue
  from net.http_request_queue;

  select max(created) into v_latest_response
  from net._http_response;

  v_response_age:=case
    when v_latest_response is null then 0
    else greatest(0,extract(epoch from(now()-v_latest_response))::integer)
  end;

  select max(created_at) into v_last_restart
  from solidos_control.health_events
  where component='pg_net'
    and event_type='auto_restart';

  if v_worker_queue>=2 and v_response_age>=75 then
    if v_last_restart is null or v_last_restart<now()-interval '4 minutes' then
      perform net.worker_restart();
      v_action:='restarted';
      insert into solidos_control.health_events(component,severity,event_type,details)
      values(
        'pg_net','WARNING','auto_restart',
        jsonb_build_object(
          'worker_queue',v_worker_queue,
          'total_queue',v_total_queue,
          'response_age_seconds',v_response_age,
          'reason','worker_queue_stalled'
        )
      );
    else
      v_action:='restart_cooldown';
    end if;
  elsif v_worker_queue>=8 then
    v_action:='queue_guard';
  end if;

  return jsonb_build_object(
    'ok',true,
    'action',v_action,
    'worker_queue',v_worker_queue,
    'total_queue',v_total_queue,
    'response_age_seconds',v_response_age,
    'last_restart_at',v_last_restart,
    'at',now()
  );
exception when others then
  insert into solidos_control.health_events(component,severity,event_type,details)
  values(
    'pg_net','ERROR','watchdog_error',
    jsonb_build_object('error',left(sqlerrm,500),'at',now())
  );
  return jsonb_build_object('ok',false,'action','error','error',left(sqlerrm,500),'at',now());
end
$function$
;

CREATE OR REPLACE FUNCTION solidos_control.work_queue_event_kick()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_lane text;
  v_bucket timestamptz;
  v_lane_limit integer;
  v_lane_kicks integer;
  v_global_kicks integer;
  v_req bigint;
  v_worker_queue integer:=0;
  v_response_age integer:=0;
begin
  if new.status<>'pending'
     or new.available_at>now()+interval '2 seconds'
     or new.kind not in ('resolve','research','qualify','contact','message') then
    return new;
  end if;

  v_lane:=booked_solid.work_lane(new.kind,new.priority,new.payload);
  if v_lane='general' then return new; end if;

  select
    count(*) filter(where url like '%/functions/v1/booked-solid-worker')::int,
    coalesce(extract(epoch from(now()-(select max(created) from net._http_response)))::int,0)
  into v_worker_queue,v_response_age
  from net.http_request_queue;

  -- Preserve event-driven speed while healthy, but never amplify a stalled
  -- pg_net queue. Cron + watchdog will safely pick the job up instead.
  if v_worker_queue>=8
     or (v_worker_queue>=2 and v_response_age>=75) then
    return new;
  end if;

  v_bucket:=to_timestamp(floor(extract(epoch from clock_timestamp())/30)*30);
  v_lane_limit:=case v_lane when 'fast' then 3 when 'resolve' then 2 when 'research' then 2 when 'qualify' then 2 when 'contact' then 1 else 1 end;

  insert into solidos_control.worker_dispatch_budget(bucket_start,lane,kicks,updated_at)
  values(v_bucket,v_lane,1,now())
  on conflict(bucket_start,lane) do update
    set kicks=solidos_control.worker_dispatch_budget.kicks+1,updated_at=now()
    where solidos_control.worker_dispatch_budget.kicks<v_lane_limit
  returning kicks into v_lane_kicks;

  if v_lane_kicks is null then return new; end if;

  insert into solidos_control.worker_dispatch_budget(bucket_start,lane,kicks,updated_at)
  values(v_bucket,'__global__',1,now())
  on conflict(bucket_start,lane) do update
    set kicks=solidos_control.worker_dispatch_budget.kicks+1,updated_at=now()
    where solidos_control.worker_dispatch_budget.kicks<4
  returning kicks into v_global_kicks;

  if v_global_kicks is null then return new; end if;

  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name='booked_solid_project_url') || '/functions/v1/booked-solid-worker',
    headers := jsonb_build_object(
      'Content-Type','application/json',
      'apikey',(select decrypted_secret from vault.decrypted_secrets where name='booked_solid_publishable_key')
    ),
    body := jsonb_build_object(
      'source','solidos-event-chain',
      'batch_size',1,
      'lane',v_lane,
      'event_job_id',new.id
    ),
    timeout_milliseconds := 45000
  ) into v_req;

  insert into solidos_control.worker_dispatch_log(work_queue_id,lane,request_id,trigger_source)
  values(new.id,v_lane,v_req,'event');

  delete from solidos_control.worker_dispatch_budget
  where bucket_start<now()-interval '2 hours';

  return new;
exception when others then
  return new;
end
$function$
;

revoke all on function booked_solid.claim_source_scan_page(text,integer,integer) from public,anon,authenticated;
grant execute on function booked_solid.claim_source_scan_page(text,integer,integer) to service_role;
revoke all on function solidos_control.pgnet_watchdog() from public,anon,authenticated;
grant execute on function solidos_control.pgnet_watchdog() to service_role;
revoke all on function solidos_control.lane_capacity_plan() from public,anon,authenticated;
grant execute on function solidos_control.lane_capacity_plan() to service_role;

insert into booked_solid.source_scan_state(
  source_slug,next_page,last_claimed_page,page_size,scan_pages,wraps,claims,last_claimed_at,updated_at
)
values
 ('auto-socrata-building-permits-dzpkhxfb',12,11,100,60,0,0,null,now()),
 ('auto-socrata-l-i-intent-project-details-t9je9qwa',12,11,100,60,0,0,null,now())
on conflict(source_slug) do update set
  next_page=greatest(booked_solid.source_scan_state.next_page,excluded.next_page),
  page_size=excluded.page_size,
  scan_pages=greatest(booked_solid.source_scan_state.scan_pages,excluded.scan_pages),
  updated_at=now();

select cron.unschedule(jobid)
from cron.job where jobname='solidos-pgnet-watchdog-1m';
select cron.schedule(
  'solidos-pgnet-watchdog-1m',
  '* * * * *',
  'select solidos_control.pgnet_watchdog();'
);

select cron.unschedule(jobid)
from cron.job where jobname='solidos-worker-lanes-1m';
select cron.schedule(
  'solidos-worker-lanes-1m',
  '* * * * *',
  $cron$
  with net_state as (
    select
      count(*) filter(where url like '%/functions/v1/booked-solid-worker')::int worker_queue,
      coalesce(
        extract(epoch from(now()-(select max(created) from net._http_response)))::int,
        0
      ) response_age_s
    from net.http_request_queue
  ),
  alloc as (
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
  cross join net_state n
  where a.desired_n>0
    and n.worker_queue<8
    and not (n.worker_queue>=2 and n.response_age_s>=75);
  $cron$
);
