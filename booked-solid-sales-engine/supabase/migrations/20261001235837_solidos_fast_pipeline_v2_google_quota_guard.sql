
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

  insert into solidos_control.sheet_sync_requests(sync_scope,reason,payload,debounce_until)
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

  -- One immediate Google writer kick per 45s is enough because changes coalesce
  -- into the same pending request. The 1-minute cron remains the safety fallback.
  v_bucket:=to_timestamp(floor(extract(epoch from clock_timestamp())/45)*45);

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

create or replace function solidos_control.request_sheet_sync(
  p_scope text,
  p_reason text,
  p_payload jsonb default '{}'::jsonb
)
returns void
language plpgsql
set search_path=''
as $function$
declare
  v_delay interval;
  v_cap interval;
begin
  if p_scope not in ('CORE_CRM','COMMERCIAL_PRODUCTS') then
    raise exception 'invalid sync scope';
  end if;

  v_delay:=case when p_scope='COMMERCIAL_PRODUCTS' then interval '90 seconds' else interval '45 seconds' end;
  v_cap:=interval '2 minutes';

  insert into solidos_control.sheet_sync_requests(sync_scope,reason,payload,debounce_until)
  values(
    p_scope,
    coalesce(nullif(p_reason,''),'data_changed'),
    coalesce(p_payload,'{}'::jsonb),
    now()+v_delay
  )
  on conflict(sync_scope) where status='PENDING'
  do update set
    reason=excluded.reason,
    payload=solidos_control.sheet_sync_requests.payload||excluded.payload,
    debounce_until=least(
      greatest(solidos_control.sheet_sync_requests.debounce_until,now()+v_delay),
      solidos_control.sheet_sync_requests.requested_at+v_cap
    ),
    updated_at=now();
end
$function$;
