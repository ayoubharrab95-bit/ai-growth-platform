
alter table booked_solid.work_queue
  add column if not exists first_started_at timestamptz,
  add column if not exists last_started_at timestamptz,
  add column if not exists finished_at timestamptz,
  add column if not exists processing_lane text;

create index if not exists idx_bs_work_queue_kind_pick
  on booked_solid.work_queue(kind,status,available_at,priority desc);

create index if not exists idx_bs_work_queue_company_kind_status
  on booked_solid.work_queue(((payload->>'company_id')),kind,status)
  where nullif(payload->>'company_id','') is not null;

create table if not exists solidos_control.pipeline_sla (
  kind text primary key,
  target_queue_seconds integer not null,
  warning_queue_seconds integer not null,
  target_total_seconds integer not null,
  enabled boolean not null default true,
  updated_at timestamptz not null default now()
);

insert into solidos_control.pipeline_sla(kind,target_queue_seconds,warning_queue_seconds,target_total_seconds)
values
  ('discover',60,120,180),
  ('resolve',45,120,240),
  ('research',45,120,240),
  ('qualify',30,90,180),
  ('contact',45,120,240),
  ('message',60,180,300),
  ('location',60,180,300)
on conflict(kind) do update set
  target_queue_seconds=excluded.target_queue_seconds,
  warning_queue_seconds=excluded.warning_queue_seconds,
  target_total_seconds=excluded.target_total_seconds,
  updated_at=now();

alter table solidos_control.pipeline_sla enable row level security;

create or replace function booked_solid.work_lane(
  p_kind text,
  p_priority numeric,
  p_payload jsonb
)
returns text
language sql
immutable
set search_path=''
as $function$
select case
  when p_kind in ('resolve','research','qualify','contact','message')
   and (
     coalesce(p_priority,0)>=85
     or coalesce(p_payload->>'reason','') like 'priority_yield%'
     or coalesce(p_payload->>'reason','') like 'pipeline_recovery%'
     or coalesce(p_payload->>'reason','') like 'lead_yield_resolution_recovery%'
     or coalesce(p_payload->>'source_tier','')='proven'
   ) then 'fast'
  when p_kind='resolve' then 'resolve'
  when p_kind='research' then 'research'
  when p_kind='qualify' then 'qualify'
  when p_kind in ('contact','message') then 'contact'
  when p_kind in ('discover','location') then 'discovery'
  else 'general'
end
$function$;

create or replace function booked_solid.claim_work_lane(
  p_worker text,
  p_lane text default 'auto'
)
returns setof booked_solid.work_queue
language plpgsql
security definer
set search_path='booked_solid','public'
as $function$
declare
  v_lane text:=lower(coalesce(nullif(p_lane,''),'auto'));
begin
 return query
 update booked_solid.work_queue q
 set status='running',
     locked_at=now(),
     locked_by=p_worker,
     attempts=attempts+1,
     first_started_at=coalesce(first_started_at,now()),
     last_started_at=now(),
     finished_at=null,
     processing_lane=v_lane,
     updated_at=now()
 where q.id=(
   with pressure as (
     select count(*)::int as resolve_due
     from booked_solid.work_queue
     where status='pending'
       and kind='resolve'
       and available_at<=now()
   )
   select w.id
   from booked_solid.work_queue w
   cross join pressure p
   where w.status='pending'
     and w.available_at<=now()
     and (
       v_lane='auto'
       or (v_lane='fast' and booked_solid.work_lane(w.kind,w.priority,w.payload)='fast')
       or (v_lane='resolve' and w.kind='resolve')
       or (v_lane='research' and w.kind='research')
       or (v_lane='qualify' and w.kind='qualify')
       or (v_lane='contact' and w.kind in ('contact','message'))
       or (v_lane='discovery' and w.kind in ('discover','location'))
       or (v_lane='general' and booked_solid.work_lane(w.kind,w.priority,w.payload)='general')
     )
   order by
     case when booked_solid.work_lane(w.kind,w.priority,w.payload)='fast' then 100 else 0 end desc,
     case when w.kind='qualify' and w.payload->>'reason' like 'pipeline_recovery%' then 90 else 0 end desc,
     case
       when v_lane='auto' and p.resolve_due>60 and w.kind='resolve' then 9
       when w.kind='qualify' then 8
       when w.kind='contact' then 7
       when w.kind='research' then 6
       when w.kind='resolve' then 5
       when w.kind='discover' then 4
       when w.kind='message' then 3
       when w.kind='location' then 2
       else 1
     end desc,
     case
       when w.created_at < now()-interval '15 minutes' then 50
       when w.created_at < now()-interval '5 minutes' then 20
       when w.created_at < now()-interval '2 minutes' then 8
       else 0
     end desc,
     w.priority desc,
     w.created_at
   for update of w skip locked
   limit 1
 )
 returning q.*;
end
$function$;

create or replace function booked_solid.claim_work(p_worker text)
returns setof booked_solid.work_queue
language sql
security definer
set search_path='booked_solid','public'
as $function$
  select * from booked_solid.claim_work_lane(p_worker,'auto');
$function$;

create or replace function public.claim_booked_solid_work_v2(
  p_worker text,
  p_lane text default 'auto'
)
returns setof booked_solid.work_queue
language sql
security definer
set search_path='booked_solid','public'
as $function$
  select * from booked_solid.claim_work_lane(p_worker,p_lane);
$function$;

revoke all on function public.claim_booked_solid_work_v2(text,text) from public,anon,authenticated;
grant execute on function public.claim_booked_solid_work_v2(text,text) to service_role;

create or replace view solidos_control.pipeline_stage_health as
with kinds as (
  select unnest(array['discover','resolve','research','qualify','contact','message','location'])::text kind
),
agg as (
  select
    k.kind,
    count(w.*) filter(where w.status='pending' and w.available_at<=now())::int due_now,
    count(w.*) filter(where w.status='pending' and w.available_at>now())::int scheduled_future,
    count(w.*) filter(where w.status='running')::int running_now,
    coalesce(max(extract(epoch from(now()-w.created_at))) filter(where w.status='pending' and w.available_at<=now()),0)::int oldest_due_seconds,
    count(w.*) filter(where w.status='done' and w.finished_at>now()-interval '15 minutes')::int completed_15m,
    count(w.*) filter(where w.status='done' and w.finished_at>now()-interval '60 minutes')::int completed_60m,
    round(avg(extract(epoch from(w.first_started_at-w.created_at))) filter(
      where w.status='done' and w.finished_at>now()-interval '60 minutes' and w.first_started_at is not null
    )::numeric,1) avg_queue_wait_seconds_60m,
    round(percentile_cont(0.95) within group(order by extract(epoch from(w.first_started_at-w.created_at))) filter(
      where w.status='done' and w.finished_at>now()-interval '60 minutes' and w.first_started_at is not null
    )::numeric,1) p95_queue_wait_seconds_60m,
    round(avg(extract(epoch from(w.finished_at-w.first_started_at))) filter(
      where w.status='done' and w.finished_at>now()-interval '60 minutes' and w.first_started_at is not null and w.finished_at is not null
    )::numeric,1) avg_end_to_end_after_first_claim_seconds_60m
  from kinds k
  left join booked_solid.work_queue w on w.kind=k.kind
  group by k.kind
)
select
  a.*,
  s.target_queue_seconds,
  s.warning_queue_seconds,
  s.target_total_seconds,
  case
    when a.running_now>0 and exists(
      select 1 from booked_solid.work_queue w
      where w.kind=a.kind and w.status='running' and w.locked_at<now()-interval '5 minutes'
    ) then 'DEGRADED'
    when a.oldest_due_seconds>s.warning_queue_seconds then 'WARNING'
    when a.due_now=0 or a.oldest_due_seconds<=s.target_queue_seconds then 'HEALTHY'
    else 'WATCH'
  end as sla_state
from agg a
left join solidos_control.pipeline_sla s using(kind);

create or replace function solidos_control.pipeline_performance_snapshot()
returns jsonb
language sql
security definer
set search_path=''
as $function$
select jsonb_build_object(
  'at',now(),
  'stages',coalesce((
    select jsonb_agg(to_jsonb(x) order by x.kind)
    from solidos_control.pipeline_stage_health x
  ),'[]'::jsonb),
  'totals',jsonb_build_object(
    'due_now',(select count(*) from booked_solid.work_queue where status='pending' and available_at<=now()),
    'running',(select count(*) from booked_solid.work_queue where status='running'),
    'stale_running',(select count(*) from booked_solid.work_queue where status='running' and locked_at<now()-interval '5 minutes'),
    'completed_15m',(select count(*) from booked_solid.work_queue where status='done' and finished_at>now()-interval '15 minutes'),
    'completed_60m',(select count(*) from booked_solid.work_queue where status='done' and finished_at>now()-interval '60 minutes')
  )
);
$function$;

revoke all on function solidos_control.pipeline_performance_snapshot() from public,anon,authenticated;
grant execute on function solidos_control.pipeline_performance_snapshot() to service_role;

create table if not exists solidos_control.worker_dispatch_budget (
  bucket_start timestamptz not null,
  lane text not null,
  kicks integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key(bucket_start,lane)
);
alter table solidos_control.worker_dispatch_budget enable row level security;

create table if not exists solidos_control.worker_dispatch_log (
  id bigserial primary key,
  work_queue_id uuid,
  lane text not null,
  request_id bigint,
  trigger_source text not null default 'event',
  created_at timestamptz not null default now()
);
alter table solidos_control.worker_dispatch_log enable row level security;
create index if not exists worker_dispatch_log_created_idx
  on solidos_control.worker_dispatch_log(created_at desc);

create or replace function solidos_control.work_queue_event_kick()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_lane text;
  v_bucket timestamptz;
  v_lane_limit integer;
  v_lane_kicks integer;
  v_global_kicks integer;
  v_req bigint;
begin
  if new.status<>'pending'
     or new.available_at>now()+interval '2 seconds'
     or new.kind not in ('resolve','research','qualify','contact','message') then
    return new;
  end if;

  v_lane:=booked_solid.work_lane(new.kind,new.priority,new.payload);
  if v_lane='general' then return new; end if;

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
$function$;

drop trigger if exists solidos_work_queue_event_kick on booked_solid.work_queue;
create trigger solidos_work_queue_event_kick
after insert or update of status,available_at on booked_solid.work_queue
for each row execute function solidos_control.work_queue_event_kick();

do $$
begin
  if exists(select 1 from cron.job where jobname='booked-solid-worker-adaptive') then
    perform cron.unschedule((select jobid from cron.job where jobname='booked-solid-worker-adaptive'));
  end if;
  if exists(select 1 from cron.job where jobname='solidos-worker-lanes-1m') then
    perform cron.unschedule((select jobid from cron.job where jobname='solidos-worker-lanes-1m'));
  end if;

  perform cron.schedule(
    'solidos-worker-lanes-1m',
    '* * * * *',
    $cron$
    with base as (
      select
        (select count(*) from booked_solid.work_queue
          where status='pending' and available_at<=now()
            and booked_solid.work_lane(kind,priority,payload)='fast')::int fast_due,
        (select count(*) from booked_solid.work_queue where status='pending' and available_at<=now() and kind='qualify')::int qualify_due,
        (select count(*) from booked_solid.work_queue where status='pending' and available_at<=now() and kind='research')::int research_due,
        (select count(*) from booked_solid.work_queue where status='pending' and available_at<=now() and kind='resolve')::int resolve_due,
        (select count(*) from booked_solid.work_queue where status='pending' and available_at<=now() and kind in ('contact','message'))::int contact_due,
        (select count(*) from booked_solid.work_queue where status='pending' and available_at<=now() and kind in ('discover','location'))::int discovery_due,
        (select count(*) from booked_solid.work_queue where status='running')::int running_now
    ),
    lanes as (
      select * from (values
        (1,'fast'),
        (2,'qualify'),
        (3,'research'),
        (4,'resolve'),
        (5,'contact'),
        (6,'discovery')
      ) v(ord,lane)
    ),
    desired as (
      select l.ord,l.lane,b.running_now,
        case l.lane
          when 'fast' then least(3,case when b.fast_due>0 then greatest(1,ceil(b.fast_due/2.0)::int) else 0 end)
          when 'qualify' then least(3,case when b.qualify_due>0 then greatest(1,ceil(b.qualify_due/2.0)::int) else 0 end)
          when 'research' then least(2,case when b.research_due>0 then greatest(1,ceil(b.research_due/2.0)::int) else 0 end)
          when 'resolve' then least(3,case when b.resolve_due>0 then greatest(1,ceil(b.resolve_due/3.0)::int) else 0 end)
          when 'contact' then least(1,case when b.contact_due>0 then 1 else 0 end)
          when 'discovery' then least(1,case when b.discovery_due>0 then 1 else 0 end)
          else 0
        end::int desired_n
      from lanes l cross join base b
    ),
    alloc as (
      select d.*,
        greatest(
          0,
          least(
            d.desired_n,
            greatest(0,12-d.running_now)
            - coalesce(sum(d.desired_n) over(order by d.ord rows between unbounded preceding and 1 preceding),0)
          )
        )::int n
      from desired d
    )
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name='booked_solid_project_url') || '/functions/v1/booked-solid-worker',
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'apikey',(select decrypted_secret from vault.decrypted_secrets where name='booked_solid_publishable_key')
      ),
      body := jsonb_build_object('source','solidos-lane-cron','batch_size',1,'lane',a.lane),
      timeout_milliseconds := 45000
    ) as request_id
    from alloc a
    cross join lateral generate_series(1,a.n)
    where a.n>0;
    $cron$
  );

  if exists(select 1 from cron.job where jobname='booked-solid-planner-5m') then
    perform cron.unschedule((select jobid from cron.job where jobname='booked-solid-planner-5m'));
  end if;
  perform cron.schedule(
    'booked-solid-planner-2m',
    '*/2 * * * *',
    $cron$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name='booked_solid_project_url') || '/functions/v1/booked-solid-orchestrator',
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'apikey',(select decrypted_secret from vault.decrypted_secrets where name='booked_solid_publishable_key')
      ),
      body := jsonb_build_object('action','plan','limit',3),
      timeout_milliseconds := 30000
    ) as request_id;
    $cron$
  );

  if exists(select 1 from cron.job where jobname='solidos-source-lead-yield-15m') then
    perform cron.unschedule((select jobid from cron.job where jobname='solidos-source-lead-yield-15m'));
  end if;
  perform cron.schedule('solidos-source-lead-yield-10m','2,12,22,32,42,52 * * * *',
    'select booked_solid.refresh_source_lead_yield(7);');

  if exists(select 1 from cron.job where jobname='solidos-priority-enrichment-10m') then
    perform cron.unschedule((select jobid from cron.job where jobname='solidos-priority-enrichment-10m'));
  end if;
  perform cron.schedule('solidos-priority-enrichment-5m','3,8,13,18,23,28,33,38,43,48,53,58 * * * *',
    'select booked_solid.run_priority_yield_cycle(4);');

  if exists(select 1 from cron.job where jobname='solidos-resolution-recovery-10m') then
    perform cron.unschedule((select jobid from cron.job where jobname='solidos-resolution-recovery-10m'));
  end if;
  perform cron.schedule('solidos-resolution-recovery-5m','1,6,11,16,21,26,31,36,41,46,51,56 * * * *',
    'select booked_solid.enqueue_resolution_recovery(6);');

  if exists(select 1 from cron.job where jobname='solidos-priority-yield-hourly') then
    perform cron.unschedule((select jobid from cron.job where jobname='solidos-priority-yield-hourly'));
  end if;
  perform cron.schedule('solidos-priority-yield-30m','15,45 * * * *',
    'select booked_solid.refresh_priority_yield_engine(45);');

  if exists(select 1 from cron.job where jobname='solidos-dispatch-budget-cleanup-hourly') then
    perform cron.unschedule((select jobid from cron.job where jobname='solidos-dispatch-budget-cleanup-hourly'));
  end if;
  perform cron.schedule('solidos-dispatch-budget-cleanup-hourly','41 * * * *',
    'delete from solidos_control.worker_dispatch_budget where bucket_start<now()-interval ''2 hours''; delete from solidos_control.worker_dispatch_log where created_at<now()-interval ''48 hours'';');
end $$;
