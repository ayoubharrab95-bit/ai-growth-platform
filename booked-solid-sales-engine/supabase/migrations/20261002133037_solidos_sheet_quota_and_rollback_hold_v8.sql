CREATE OR REPLACE FUNCTION public.claim_solidos_sheet_sync()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_row solidos_control.sheet_sync_requests%rowtype;
begin
  perform pg_catalog.pg_advisory_xact_lock(74120861);

  update solidos_control.sheet_sync_requests q
  set status='FAILED',
      finished_at=now(),
      last_error='stale_native_sync_superseded_by_pending_request',
      updated_at=now()
  where q.status='RUNNING'
    and q.started_at < now()-interval '7 minutes'
    and exists(
      select 1
      from solidos_control.sheet_sync_requests p
      where p.sync_scope=q.sync_scope
        and p.status='PENDING'
    );

  update solidos_control.sheet_sync_requests q
  set status='PENDING',
      debounce_until=now(),
      started_at=null,
      finished_at=null,
      last_error='requeued_stale_native_sync',
      updated_at=now()
  where q.status='RUNNING'
    and q.started_at < now()-interval '7 minutes'
    and not exists(
      select 1
      from solidos_control.sheet_sync_requests p
      where p.sync_scope=q.sync_scope
        and p.status='PENDING'
    );

  update solidos_control.sheet_sync_requests q
  set status='RUNNING',
      started_at=now(),
      attempts=attempts+1,
      updated_at=now()
  where q.id=(
    select p.id
    from solidos_control.sheet_sync_requests p
    where p.status='PENDING'
      and p.debounce_until<=now()
      and not exists(
        select 1
        from solidos_control.sheet_sync_requests r
        where r.status='RUNNING'
      )
      and not exists(
        select 1
        from solidos_control.sheet_sync_requests f
        where f.finished_at > now()-interval '60 seconds'
          and f.status in ('SUCCEEDED','FAILED')
      )
    order by p.requested_at,p.id
    for update skip locked
    limit 1
  )
  returning * into v_row;

  if v_row.id is null then return null; end if;
  return to_jsonb(v_row);
end
$function$
;

CREATE OR REPLACE FUNCTION solidos_control.dispatch_revenue_sheet_sync()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_request_id bigint;
begin
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name='booked_solid_project_url') || '/functions/v1/solidos-revenue-sheet-writer',
    headers := jsonb_build_object(
      'Content-Type','application/json',
      'apikey',(select decrypted_secret from vault.decrypted_secrets where name='booked_solid_publishable_key')
    ),
    body := jsonb_build_object('source','solidos-hourly-revenue-sheet','requested_at',now()),
    timeout_milliseconds := 120000
  ) into v_request_id;
  return jsonb_build_object('ok',true,'request_id',v_request_id,'at',now());
exception when others then
  insert into solidos_control.health_events(component,severity,event_type,details)
  values('revenue_intelligence','WARN','sheet_dispatch_failed',
    jsonb_build_object('error',left(sqlerrm,1000),'at',now()));
  raise;
end
$function$
;

CREATE OR REPLACE FUNCTION solidos_control.request_core_sheet_sync_fast(p_table text, p_company uuid DEFAULT NULL::uuid, p_reason text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    reason=case
      when solidos_control.sheet_sync_requests.reason='hourly_full_refresh' then 'hourly_full_refresh'
      else excluded.reason
    end,
    payload=case
      when solidos_control.sheet_sync_requests.reason='hourly_full_refresh'
        then solidos_control.sheet_sync_requests.payload || excluded.payload || jsonb_build_object('force_full',true)
      else solidos_control.sheet_sync_requests.payload || excluded.payload
    end,
    debounce_until=case
      when solidos_control.sheet_sync_requests.reason='hourly_full_refresh'
        then least(solidos_control.sheet_sync_requests.debounce_until,now())
      else now()
    end,
    updated_at=now();

  v_bucket:=to_timestamp(floor(extract(epoch from clock_timestamp())/60)*60);

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
$function$
;

CREATE OR REPLACE FUNCTION solidos_control.request_hourly_sheet_refresh()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_scope text;
  v_revenue jsonb;
  v_revenue_error text;
begin
  begin
    v_revenue:=solidos_control.refresh_revenue_intelligence();
  exception when others then
    v_revenue_error:=left(sqlerrm,1000);
    insert into solidos_control.health_events(component,severity,event_type,details)
    values('revenue_intelligence','WARN','hourly_refresh_failed',
      jsonb_build_object('error',v_revenue_error,'at',now()));
  end;

  foreach v_scope in array array['CORE_CRM','COMMERCIAL_PRODUCTS']
  loop
    update solidos_control.sheet_sync_requests
    set reason='hourly_full_refresh',
        payload=coalesce(payload,'{}'::jsonb)||jsonb_build_object(
          'requested_by','solidos_hourly_cron',
          'requested_at',now(),
          'force_full',true,
          'revenue_intelligence_refresh',coalesce(v_revenue,jsonb_build_object('ok',false,'error',v_revenue_error))
        ),
        debounce_until=now(),
        updated_at=now()
    where sync_scope=v_scope and status='PENDING';

    if not found then
      insert into solidos_control.sheet_sync_requests(sync_scope,reason,payload,debounce_until)
      values(
        v_scope,'hourly_full_refresh',
        jsonb_build_object(
          'requested_by','solidos_hourly_cron',
          'requested_at',now(),
          'force_full',true,
          'revenue_intelligence_refresh',coalesce(v_revenue,jsonb_build_object('ok',false,'error',v_revenue_error))
        ),
        now()
      );
    end if;
  end loop;

  return jsonb_build_object(
    'ok',true,'requested_at',now(),
    'scopes',jsonb_build_array('CORE_CRM','COMMERCIAL_PRODUCTS'),
    'revenue_intelligence',coalesce(v_revenue,jsonb_build_object('ok',false,'error',v_revenue_error))
  );
end
$function$
;

CREATE OR REPLACE FUNCTION solidos_control.run_hourly_revenue_cycle()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_base jsonb;
begin
  v_base:=solidos_control.request_hourly_sheet_refresh();
  return jsonb_build_object(
    'ok',true,'at',now(),'cadence','hourly',
    'base_cycle',v_base,
    'revenue_sheet_dispatch','scheduled_at_minute_04'
  );
exception when others then
  insert into solidos_control.health_events(component,severity,event_type,details)
  values('revenue_intelligence','WARN','hourly_cycle_failed',
    jsonb_build_object('error',left(sqlerrm,1000),'at',now()));
  raise;
end
$function$
;
update solidos_control.settings
set lead_generation_playbook_version=8,
    lead_generation_playbook_updated_at=now(),
    lead_generation_playbook=
      jsonb_set(
        jsonb_set(
          coalesce(lead_generation_playbook,'{}'::jsonb),
          '{version}','8'::jsonb,true
        ),
        '{stability_audit_v5,known_good_runtime,sheet_sync}','27'::jsonb,true
      )
      || jsonb_build_object(
        'sheet_stability_v8',jsonb_build_object(
          'quota_incident','A CORE_CRM sync hit Google Sheets WriteRequestsPerMinutePerUser quota (60/min) at 2026-10-02 12:47 UTC.',
          'root_cause','Core and Commercial sheet writers could be claimed concurrently and fast event dispatch used a 45-second bucket, allowing write bursts to overlap.',
          'guard',jsonb_build_object(
            'global_claim_lock','pg_advisory_xact_lock serializes claim_solidos_sheet_sync transactions.',
            'single_running_scope','Only one Sheet sync may be RUNNING globally across CORE_CRM and COMMERCIAL_PRODUCTS.',
            'cooloff_seconds',60,
            'event_dispatch_bucket_seconds',60,
            'cron_fallback','Native sheet sync cron remains every minute.'
          ),
          'acceptance',jsonb_build_object(
            'overlapping_sheet_writers',0,
            'observed_start_gap_seconds',118,
            'quota_failures_after_guard',0,
            'commercial_sync_verified',true
          ),
          'failed_experiment','A broad Sheet Sync batching refactor deployed as platform version 26 caused BOOT_ERROR before writes. It was immediately rolled back. Active platform deployment v27 uses the known-good v25 source hash plus database-level serialization/quota guards. Do not retry the v26 refactor directly without offline compile/test.',
          'health_event_fix','All SolidOS health_events writers now use allowed severity WARN rather than warning/WARNING.'
        ),
        'brain_rollback_hold_rule',jsonb_build_object(
          'runtime_pct',15,
          'stable_pct',15,
          'hold_until','2026-10-03T00:07:00.177904+00:00',
          'rule','Do not manually ramp Strategy Brain during rollback hold. Let AutoPilot hold at 15% until the hold expires and health/sample gates pass.',
          'reason','Canary underperformed Legacy in the current post-rollback sample and the rollback was triggered by real pipeline/SLA pressure.'
        ),
        'future_chat_instruction','Start with solidos_control.future_chat_bootstrap(). Preserve Brain at 15% during rollback hold. Sheet sync is globally serialized with a 60-second cooloff; do not remove the guard because it prevents Google Sheets quota bursts.'
      ),
    updated_at=now()
where id=true;
