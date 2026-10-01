create or replace function solidos_control.recover_transient_dead_letters(p_limit integer default 5)
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  r record;
  v_requeued integer:=0;
  v_ignored integer:=0;
  v_limit integer:=least(greatest(coalesce(p_limit,5),1),20);
  v_osm_ready boolean:=false;
  v_osm_quarantined boolean:=false;
begin
  select (
    enabled
    and consecutive_errors=0
    and lifecycle_state not in ('degraded','paused')
    and (
      nullif(metadata->>'cooldown_until','') is null
      or (metadata->>'cooldown_until')::timestamptz<=now()
    )
  ),
  (
    not enabled
    and lifecycle_state='paused'
    and coalesce(metadata->>'state','')='quarantined_optional'
  )
  into v_osm_ready,v_osm_quarantined
  from booked_solid.source_catalog
  where slug='openstreetmap_overpass';

  if coalesce(v_osm_quarantined,false) then
    update solidos_control.dead_letter
    set recovery_status='IGNORED',
        metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
          'ignored_reason','source_quarantined_optional_failopen',
          'ignored_at',now(),
          'recovery_controller_checked_at',now()
        ),
        updated_at=now()
    where failure_class='overpass_transient'
      and recovery_status in ('UNRESOLVED','RETRY_SCHEDULED');
    get diagnostics v_ignored=row_count;

    return jsonb_build_object(
      'requeued',0,
      'ignored',v_ignored,
      'source_ready',false,
      'source_quarantined_optional',true,
      'waiting',0,
      'at',now()
    );
  end if;

  if not coalesce(v_osm_ready,false) then
    update solidos_control.dead_letter
    set recovery_status='RETRY_SCHEDULED',
        metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
          'waiting_for_source','openstreetmap_overpass',
          'recovery_controller_checked_at',now()
        ),
        updated_at=now()
    where failure_class='overpass_transient'
      and recovery_status='UNRESOLVED';

    return jsonb_build_object(
      'requeued',0,
      'ignored',0,
      'source_ready',false,
      'source_quarantined_optional',false,
      'waiting',(select count(*) from solidos_control.dead_letter
                 where failure_class='overpass_transient'
                   and recovery_status='RETRY_SCHEDULED'),
      'at',now()
    );
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
    set status='pending',attempts=0,available_at=now(),locked_at=null,locked_by=null,
        last_error=null,updated_at=now()
    where id=r.work_queue_id and status='failed';

    if found then
      update solidos_control.dead_letter
      set recovery_status='RETRY_SCHEDULED',
          metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object(
            'requeued_at',now(),
            'recovery_batch_limit',v_limit
          ),
          updated_at=now()
      where work_queue_id=r.work_queue_id;
      v_requeued:=v_requeued+1;
    end if;
  end loop;

  return jsonb_build_object(
    'requeued',v_requeued,
    'ignored',0,
    'source_ready',true,
    'source_quarantined_optional',false,
    'remaining',(select count(*) from solidos_control.dead_letter
                 where failure_class='overpass_transient'
                   and recovery_status in ('UNRESOLVED','RETRY_SCHEDULED')),
    'at',now()
  );
end
$function$;

revoke all on function solidos_control.recover_transient_dead_letters(integer) from public,anon,authenticated;
grant execute on function solidos_control.recover_transient_dead_letters(integer) to service_role;
