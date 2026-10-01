create or replace function solidos_control.recover_transient_dead_letters(p_limit integer default 5)
returns jsonb
language plpgsql
security invoker
set search_path=''
as $function$
declare
  r record;
  v_requeued integer:=0;
  v_limit integer:=least(greatest(coalesce(p_limit,5),1),20);
  v_osm_ready boolean:=false;
begin
  select (enabled and consecutive_errors=0 and lifecycle_state not in ('degraded','paused')
    and (nullif(metadata->>'cooldown_until','') is null
      or (metadata->>'cooldown_until')::timestamptz<=now()))
  into v_osm_ready
  from booked_solid.source_catalog where slug='openstreetmap_overpass';

  if not coalesce(v_osm_ready,false) then
    update solidos_control.dead_letter
    set recovery_status='RETRY_SCHEDULED',
        metadata=metadata||jsonb_build_object(
          'waiting_for_source','openstreetmap_overpass',
          'recovery_controller_checked_at',now()),
        updated_at=now()
    where failure_class='overpass_transient' and recovery_status='UNRESOLVED';
    return jsonb_build_object('requeued',0,'source_ready',false,
      'waiting',(select count(*) from solidos_control.dead_letter
        where failure_class='overpass_transient' and recovery_status='RETRY_SCHEDULED'),'at',now());
  end if;

  for r in
    select d.work_queue_id
    from solidos_control.dead_letter d
    join booked_solid.work_queue q on q.id=d.work_queue_id
    where d.failure_class='overpass_transient'
      and d.recovery_status in ('UNRESOLVED','RETRY_SCHEDULED')
      and q.status='failed'
    order by d.failed_at,d.work_queue_id
    for update of d skip locked
    limit v_limit
  loop
    update booked_solid.work_queue
    set status='pending',attempts=0,available_at=now(),locked_at=null,locked_by=null,last_error=null,updated_at=now()
    where id=r.work_queue_id and status='failed';
    if found then
      update solidos_control.dead_letter
      set recovery_status='RETRY_SCHEDULED',
          metadata=metadata||jsonb_build_object('requeued_at',now(),'recovery_batch_limit',v_limit),
          updated_at=now()
      where work_queue_id=r.work_queue_id;
      v_requeued:=v_requeued+1;
    end if;
  end loop;
  return jsonb_build_object('requeued',v_requeued,'source_ready',true,
    'remaining',(select count(*) from solidos_control.dead_letter
      where failure_class='overpass_transient' and recovery_status in ('UNRESOLVED','RETRY_SCHEDULED')),'at',now());
end
$function$;

create or replace function solidos_control.capture_dead_letter_trigger()
returns trigger
language plpgsql
security invoker
set search_path=''
as $function$
begin
  if new.status='failed' and old.status is distinct from 'failed' then
    insert into solidos_control.dead_letter(
      work_queue_id,kind,payload,attempts,last_error,first_seen_at,failed_at,source_slug,failure_class
    )
    values(new.id,new.kind,coalesce(new.payload,'{}'::jsonb),new.attempts,new.last_error,new.created_at,new.updated_at,
      new.payload->>'source_slug',
      case
        when coalesce(new.last_error,'') ~* 'overpass.*(504|406|http_0)|overpass_transient' then 'overpass_transient'
        when coalesce(new.last_error,'') ~* 'timeout' then 'network_timeout'
        when coalesce(new.last_error,'') ~* '429|rate' then 'rate_limit'
        when coalesce(new.last_error,'') ~* '5[0-9][0-9]' then 'upstream_5xx'
        else 'unknown' end)
    on conflict(work_queue_id) do update set
      attempts=excluded.attempts,last_error=excluded.last_error,failed_at=excluded.failed_at,
      failure_class=excluded.failure_class,recovery_status='UNRESOLVED',updated_at=now();
  elsif new.status='done' then
    update solidos_control.dead_letter
    set recovery_status='RECOVERED',
        metadata=metadata||jsonb_build_object('recovered_at',now()),updated_at=now()
    where work_queue_id=new.id and recovery_status<>'RECOVERED';
  end if;
  return new;
end
$function$;

do $$
begin
  if exists(select 1 from cron.job where jobname='solidos-dead-letter-recovery-10m') then
    perform cron.unschedule((select jobid from cron.job where jobname='solidos-dead-letter-recovery-10m'));
  end if;
  perform cron.schedule('solidos-dead-letter-recovery-10m','*/10 * * * *',
    'select solidos_control.recover_transient_dead_letters(5);');
end $$;
