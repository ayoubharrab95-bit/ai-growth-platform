create or replace function solidos_control.request_sheet_sync(
  p_scope text,p_reason text,p_payload jsonb default '{}'::jsonb
) returns void
language plpgsql
security invoker
set search_path=''
as $function$
begin
  if p_scope not in ('CORE_CRM','COMMERCIAL_PRODUCTS') then
    raise exception 'invalid sync scope';
  end if;
  insert into solidos_control.sheet_sync_requests(sync_scope,reason,payload)
  values(p_scope,coalesce(nullif(p_reason,''),'data_changed'),coalesce(p_payload,'{}'::jsonb))
  on conflict(sync_scope) where status='PENDING'
  do update set
    reason=excluded.reason,
    payload=solidos_control.sheet_sync_requests.payload||excluded.payload,
    debounce_until=least(
      greatest(solidos_control.sheet_sync_requests.debounce_until,now()+interval '90 seconds'),
      solidos_control.sheet_sync_requests.requested_at+interval '5 minutes'
    ),
    updated_at=now();
end
$function$;
