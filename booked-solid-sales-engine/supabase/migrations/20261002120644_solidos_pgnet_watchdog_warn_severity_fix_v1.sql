CREATE OR REPLACE FUNCTION solidos_control.pgnet_watchdog()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_worker_queue integer:=0;
  v_total_queue integer:=0;
  v_latest_response timestamptz;
  v_response_age integer:=0;
  v_last_restart timestamptz;
  v_action text:='healthy';
  v_locked boolean;
begin
  v_locked:=pg_try_advisory_xact_lock(hashtext('solidos_pgnet_watchdog'));
  if not v_locked then
    return jsonb_build_object('ok',true,'action','lock_busy','at',now());
  end if;

  select count(*),
         count(*) filter(where url like '%/functions/v1/booked-solid-worker')
  into v_total_queue,v_worker_queue
  from net.http_request_queue;

  select max(created) into v_latest_response
  from net._http_response;

  v_response_age:=case
    when v_latest_response is null then 0
    else greatest(0,extract(epoch from(now()-v_latest_response))::integer)
  end;

  select max(created_at) into v_last_restart
  from solidos_control.health_events
  where component='pg_net'
    and event_type='auto_restart';

  if v_worker_queue>=2 and v_response_age>=75 then
    if v_last_restart is null or v_last_restart<now()-interval '4 minutes' then
      perform net.worker_restart();
      v_action:='restarted';
      insert into solidos_control.health_events(component,severity,event_type,details)
      values(
        'pg_net','WARN','auto_restart',
        jsonb_build_object(
          'worker_queue',v_worker_queue,
          'total_queue',v_total_queue,
          'response_age_seconds',v_response_age,
          'reason','worker_queue_stalled'
        )
      );
    else
      v_action:='restart_cooldown';
    end if;
  elsif v_worker_queue>=8 then
    v_action:='queue_guard';
  end if;

  return jsonb_build_object(
    'ok',true,
    'action',v_action,
    'worker_queue',v_worker_queue,
    'total_queue',v_total_queue,
    'response_age_seconds',v_response_age,
    'last_restart_at',v_last_restart,
    'at',now()
  );
exception when others then
  insert into solidos_control.health_events(component,severity,event_type,details)
  values(
    'pg_net','ERROR','watchdog_error',
    jsonb_build_object('error',left(sqlerrm,500),'at',now())
  );
  return jsonb_build_object('ok',false,'action','error','error',left(sqlerrm,500),'at',now());
end
$function$
