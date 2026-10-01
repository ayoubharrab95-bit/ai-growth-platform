create or replace function public.record_solidos_sheet_sync_verification(
  p_id bigint,
  p_verification jsonb
)
returns boolean
language plpgsql
security definer
set search_path=''
as $function$
begin
  update solidos_control.sheet_sync_requests
  set payload=coalesce(payload,'{}'::jsonb) || jsonb_build_object('sync_verification',p_verification),
      updated_at=now()
  where id=p_id;
  return found;
end
$function$;

revoke all on function public.record_solidos_sheet_sync_verification(bigint,jsonb) from public,anon,authenticated;
grant execute on function public.record_solidos_sheet_sync_verification(bigint,jsonb) to service_role;
