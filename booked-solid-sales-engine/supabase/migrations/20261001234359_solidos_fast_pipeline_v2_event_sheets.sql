
create table if not exists solidos_control.sheet_dispatch_budget (
  bucket_start timestamptz not null,
  sync_scope text not null,
  kicks integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key(bucket_start,sync_scope)
);
alter table solidos_control.sheet_dispatch_budget enable row level security;

create table if not exists solidos_control.sheet_dispatch_log (
  id bigserial primary key,
  sync_scope text not null,
  reason text,
  request_id bigint,
  created_at timestamptz not null default now()
);
alter table solidos_control.sheet_dispatch_log enable row level security;
create index if not exists sheet_dispatch_log_created_idx
  on solidos_control.sheet_dispatch_log(created_at desc);

create or replace function solidos_control.request_core_sheet_sync_fast(
  p_table text,
  p_company uuid default null,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_payload jsonb;
  v_bucket timestamptz;
  v_kicks integer;
  v_req bigint;
  v_key text;
begin
  v_key:='changed_'||regexp_replace(lower(coalesce(p_table,'unknown')),'[^a-z0-9_]+','_','g');
  v_payload:=jsonb_build_object(
    'fast',true,
    'table',coalesce(p_table,'unknown'),
    v_key,true,
    'company_id',p_company,
    'requested_at',now()
  );

  insert into solidos_control.sheet_sync_requests(
    sync_scope,reason,payload,debounce_until
  )
  values(
    'CORE_CRM',
    coalesce(nullif(p_reason,''),coalesce(p_table,'core')||':fast_change'),
    v_payload,
    now()
  )
  on conflict(sync_scope) where status='PENDING'
  do update set
    reason=excluded.reason,
    payload=solidos_control.sheet_sync_requests.payload||excluded.payload,
    debounce_until=now(),
    updated_at=now();

  v_bucket:=to_timestamp(floor(extract(epoch from clock_timestamp())/20)*20);

  insert into solidos_control.sheet_dispatch_budget(bucket_start,sync_scope,kicks,updated_at)
  values(v_bucket,'CORE_CRM',1,now())
  on conflict(bucket_start,sync_scope) do update
    set kicks=solidos_control.sheet_dispatch_budget.kicks+1,updated_at=now()
    where solidos_control.sheet_dispatch_budget.kicks<1
  returning kicks into v_kicks;

  if v_kicks is null then return; end if;

  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name='booked_solid_project_url') || '/functions/v1/solidos-sheet-sync',
    headers := jsonb_build_object(
      'Content-Type','application/json',
      'apikey',(select decrypted_secret from vault.decrypted_secrets where name='booked_solid_publishable_key')
    ),
    body := jsonb_build_object('action','sync-pending','source','event-fast-core'),
    timeout_milliseconds := 120000
  ) into v_req;

  insert into solidos_control.sheet_dispatch_log(sync_scope,reason,request_id)
  values('CORE_CRM',coalesce(p_reason,p_table),v_req);

  delete from solidos_control.sheet_dispatch_budget
  where bucket_start<now()-interval '2 hours';
exception when others then
  return;
end
$function$;

create or replace function solidos_control.core_change_dirty_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_company uuid;
begin
  if tg_table_name='companies' then
    v_company:=new.id;
  else
    v_company:=new.company_id;
  end if;

  perform solidos_control.mark_company_dirty(
    v_company,
    tg_table_name||':'||lower(tg_op),
    case when tg_table_name in ('leads','evidence') then 80 else 60 end
  );

  perform solidos_control.request_core_sheet_sync_fast(
    tg_table_name,
    v_company,
    tg_table_name||':'||lower(tg_op)
  );

  return new;
end
$function$;

create or replace function solidos_control.outreach_sheet_sync_trigger()
returns trigger
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_company uuid;
begin
  select company_id into v_company
  from booked_solid.leads
  where id=new.lead_id;

  perform solidos_control.request_core_sheet_sync_fast(
    'messages',
    v_company,
    'outreach_queue:'||lower(tg_op)
  );
  return new;
end
$function$;

drop trigger if exists solidos_outreach_sheet_sync on booked_solid.outreach_queue;
create trigger solidos_outreach_sheet_sync
after insert or update on booked_solid.outreach_queue
for each row execute function solidos_control.outreach_sheet_sync_trigger();

create or replace function solidos_control.request_hourly_sheet_refresh()
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
begin
  perform solidos_control.request_sheet_sync(
    'CORE_CRM',
    'hourly_full_refresh',
    jsonb_build_object('requested_by','solidos_hourly_cron','requested_at',now(),'force_full',true)
  );
  perform solidos_control.request_sheet_sync(
    'COMMERCIAL_PRODUCTS',
    'hourly_full_refresh',
    jsonb_build_object('requested_by','solidos_hourly_cron','requested_at',now(),'force_full',true)
  );

  update solidos_control.sheet_sync_requests
  set debounce_until=now(),updated_at=now()
  where status='PENDING'
    and sync_scope in ('CORE_CRM','COMMERCIAL_PRODUCTS')
    and reason='hourly_full_refresh';

  return jsonb_build_object(
    'ok',true,
    'requested_at',now(),
    'scopes',jsonb_build_array('CORE_CRM','COMMERCIAL_PRODUCTS')
  );
end
$function$;

do $$
begin
  if exists(select 1 from cron.job where jobname='solidos-native-sheet-sync-2m') then
    perform cron.unschedule((select jobid from cron.job where jobname='solidos-native-sheet-sync-2m'));
  end if;
  if exists(select 1 from cron.job where jobname='solidos-native-sheet-sync-1m') then
    perform cron.unschedule((select jobid from cron.job where jobname='solidos-native-sheet-sync-1m'));
  end if;

  perform cron.schedule(
    'solidos-native-sheet-sync-1m',
    '* * * * *',
    $cron$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name='booked_solid_project_url') || '/functions/v1/solidos-sheet-sync',
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'apikey',(select decrypted_secret from vault.decrypted_secrets where name='booked_solid_publishable_key')
      ),
      body := jsonb_build_object('action','sync-pending','source','cron-fallback'),
      timeout_milliseconds := 120000
    ) as request_id;
    $cron$
  );

  if exists(select 1 from cron.job where jobname='solidos-sheet-dispatch-cleanup-hourly') then
    perform cron.unschedule((select jobid from cron.job where jobname='solidos-sheet-dispatch-cleanup-hourly'));
  end if;
  perform cron.schedule(
    'solidos-sheet-dispatch-cleanup-hourly',
    '43 * * * *',
    'delete from solidos_control.sheet_dispatch_budget where bucket_start<now()-interval ''2 hours''; delete from solidos_control.sheet_dispatch_log where created_at<now()-interval ''48 hours'';'
  );
end $$;
