
create or replace function solidos_control.request_sheet_sync(
  p_scope text,
  p_reason text,
  p_payload jsonb default '{}'::jsonb
)
returns void
language plpgsql
set search_path=''
as $function$
begin
  if p_scope not in ('CORE_CRM','COMMERCIAL_PRODUCTS') then
    raise exception 'invalid sync scope';
  end if;

  insert into solidos_control.sheet_sync_requests(
    sync_scope,reason,payload,debounce_until
  )
  values(
    p_scope,
    coalesce(nullif(p_reason,''),'data_changed'),
    coalesce(p_payload,'{}'::jsonb),
    now()+interval '45 seconds'
  )
  on conflict(sync_scope) where status='PENDING'
  do update set
    reason=excluded.reason,
    payload=solidos_control.sheet_sync_requests.payload||excluded.payload,
    debounce_until=least(
      greatest(solidos_control.sheet_sync_requests.debounce_until,now()+interval '45 seconds'),
      solidos_control.sheet_sync_requests.requested_at+interval '2 minutes'
    ),
    updated_at=now();
end
$function$;

create or replace function solidos_control.request_hourly_sheet_refresh()
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_scope text;
begin
  foreach v_scope in array array['CORE_CRM','COMMERCIAL_PRODUCTS']
  loop
    update solidos_control.sheet_sync_requests
    set reason='hourly_full_refresh',
        payload=coalesce(payload,'{}'::jsonb)||jsonb_build_object(
          'requested_by','solidos_hourly_cron',
          'requested_at',now(),
          'force_full',true
        ),
        debounce_until=now(),
        updated_at=now()
    where sync_scope=v_scope
      and status='PENDING';

    if not found then
      insert into solidos_control.sheet_sync_requests(
        sync_scope,reason,payload,debounce_until
      )
      values(
        v_scope,
        'hourly_full_refresh',
        jsonb_build_object('requested_by','solidos_hourly_cron','requested_at',now(),'force_full',true),
        now()
      );
    end if;
  end loop;

  return jsonb_build_object(
    'ok',true,
    'requested_at',now(),
    'scopes',jsonb_build_array('CORE_CRM','COMMERCIAL_PRODUCTS')
  );
end
$function$;
