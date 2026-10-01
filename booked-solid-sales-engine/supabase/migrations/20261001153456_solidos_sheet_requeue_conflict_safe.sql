create or replace function public.requeue_blocked_solidos_sheet_sync()
returns integer
language plpgsql
security invoker
set search_path=''
as $function$
declare r record; v_count integer:=0;
begin
  for r in
    select distinct on (b.sync_scope) b.id,b.sync_scope
    from solidos_control.sheet_sync_requests b
    where b.status='BLOCKED_NOT_CONFIGURED'
      and not exists(
        select 1 from solidos_control.sheet_sync_requests p
        where p.sync_scope=b.sync_scope and p.status='PENDING'
      )
    order by b.sync_scope,b.requested_at desc,b.id desc
  loop
    update solidos_control.sheet_sync_requests
    set status='PENDING',debounce_until=now(),started_at=null,finished_at=null,updated_at=now()
    where id=r.id;
    v_count:=v_count+1;
  end loop;
  return v_count;
end
$function$;

revoke all on function public.requeue_blocked_solidos_sheet_sync() from public,anon,authenticated;
grant execute on function public.requeue_blocked_solidos_sheet_sync() to service_role;
