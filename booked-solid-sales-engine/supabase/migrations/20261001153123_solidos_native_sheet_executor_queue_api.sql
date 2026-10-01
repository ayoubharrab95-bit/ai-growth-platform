create or replace function public.claim_solidos_sheet_sync()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $function$
declare v_row solidos_control.sheet_sync_requests%rowtype;
begin
  update solidos_control.sheet_sync_requests q
  set status='RUNNING',started_at=now(),attempts=attempts+1,updated_at=now()
  where q.id=(
    select id from solidos_control.sheet_sync_requests
    where status='PENDING' and debounce_until<=now()
    order by requested_at,id
    for update skip locked limit 1
  )
  returning * into v_row;
  if v_row.id is null then return null; end if;
  return to_jsonb(v_row);
end
$function$;

create or replace function public.finish_solidos_sheet_sync(
 p_id bigint,p_status text,p_error text default null
) returns void
language plpgsql
security invoker
set search_path=''
as $function$
begin
 if p_status not in ('SUCCEEDED','FAILED','BLOCKED_NOT_CONFIGURED') then
   raise exception 'invalid sheet sync status';
 end if;
 update solidos_control.sheet_sync_requests
 set status=p_status,finished_at=now(),
     last_error=case when p_status='SUCCEEDED' then null else left(p_error,1000) end,
     updated_at=now()
 where id=p_id;
end
$function$;

create or replace function public.requeue_blocked_solidos_sheet_sync()
returns integer
language plpgsql
security invoker
set search_path=''
as $function$
declare v_count integer;
begin
 update solidos_control.sheet_sync_requests
 set status='PENDING',debounce_until=now(),started_at=null,finished_at=null,updated_at=now()
 where status='BLOCKED_NOT_CONFIGURED';
 get diagnostics v_count=row_count;
 return v_count;
end
$function$;

revoke all on function public.claim_solidos_sheet_sync() from public,anon,authenticated;
revoke all on function public.finish_solidos_sheet_sync(bigint,text,text) from public,anon,authenticated;
revoke all on function public.requeue_blocked_solidos_sheet_sync() from public,anon,authenticated;
grant execute on function public.claim_solidos_sheet_sync() to service_role;
grant execute on function public.finish_solidos_sheet_sync(bigint,text,text) to service_role;
grant execute on function public.requeue_blocked_solidos_sheet_sync() to service_role;
