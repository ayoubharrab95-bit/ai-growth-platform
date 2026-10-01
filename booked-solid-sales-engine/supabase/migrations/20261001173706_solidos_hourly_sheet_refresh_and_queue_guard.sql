
create unique index if not exists work_queue_one_pending_resolve_company_idx
on booked_solid.work_queue ((payload->>'company_id'))
where kind='resolve'
  and status='pending'
  and nullif(payload->>'company_id','') is not null;

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
    jsonb_build_object('requested_by','solidos_hourly_cron','requested_at',now())
  );
  perform solidos_control.request_sheet_sync(
    'COMMERCIAL_PRODUCTS',
    'hourly_full_refresh',
    jsonb_build_object('requested_by','solidos_hourly_cron','requested_at',now())
  );
  return jsonb_build_object('ok',true,'requested_at',now(),'scopes',jsonb_build_array('CORE_CRM','COMMERCIAL_PRODUCTS'));
end
$function$;

revoke all on function solidos_control.request_hourly_sheet_refresh() from public,anon,authenticated;
grant execute on function solidos_control.request_hourly_sheet_refresh() to service_role;

create or replace function public.claim_solidos_sheet_sync()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $function$
declare
  v_row solidos_control.sheet_sync_requests%rowtype;
begin
  update solidos_control.sheet_sync_requests q
  set status='FAILED',
      finished_at=now(),
      last_error='stale_native_sync_superseded_by_pending_request',
      updated_at=now()
  where q.status='RUNNING'
    and q.started_at < now()-interval '10 minutes'
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
    and q.started_at < now()-interval '10 minutes'
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
    select id
    from solidos_control.sheet_sync_requests
    where status='PENDING'
      and debounce_until<=now()
    order by requested_at,id
    for update skip locked
    limit 1
  )
  returning * into v_row;

  if v_row.id is null then return null; end if;
  return to_jsonb(v_row);
end
$function$;

revoke all on function public.claim_solidos_sheet_sync() from public,anon,authenticated;
grant execute on function public.claim_solidos_sheet_sync() to service_role;

do $$
begin
  if exists(select 1 from cron.job where jobname='solidos-hourly-sheet-refresh') then
    perform cron.unschedule((select jobid from cron.job where jobname='solidos-hourly-sheet-refresh'));
  end if;

  perform cron.schedule(
    'solidos-hourly-sheet-refresh',
    '0 * * * *',
    'select solidos_control.request_hourly_sheet_refresh();'
  );
end $$;
