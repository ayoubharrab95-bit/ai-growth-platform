
create or replace function public.claim_solidos_sheet_sync()
returns jsonb
language plpgsql
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
        where r.sync_scope=p.sync_scope
          and r.status='RUNNING'
      )
    order by p.requested_at,p.id
    for update skip locked
    limit 1
  )
  returning * into v_row;

  if v_row.id is null then return null; end if;
  return to_jsonb(v_row);
end
$function$;
