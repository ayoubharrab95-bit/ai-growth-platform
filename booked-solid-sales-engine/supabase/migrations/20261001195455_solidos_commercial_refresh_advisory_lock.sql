
create or replace function solidos_control.run_commercial_dirty_batch(p_limit integer default 50)
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_locked boolean;
  v_result jsonb;
begin
  v_locked := pg_catalog.pg_try_advisory_xact_lock(pg_catalog.hashtext('solidos_commercial_refresh_lock')::bigint);
  if not v_locked then
    return jsonb_build_object('ok',true,'skipped',true,'reason','commercial_refresh_lock_busy','at',now());
  end if;

  select commercial_intel.process_dirty_companies(greatest(1,least(coalesce(p_limit,50),500)))
  into v_result;
  return coalesce(v_result,jsonb_build_object('ok',true,'processed',0));
end
$function$;

create or replace function solidos_control.run_commercial_full_refresh()
returns jsonb
language plpgsql
security definer
set search_path=''
as $function$
declare
  v_locked boolean;
begin
  v_locked := pg_catalog.pg_try_advisory_xact_lock(pg_catalog.hashtext('solidos_commercial_refresh_lock')::bigint);
  if not v_locked then
    return jsonb_build_object('ok',true,'skipped',true,'reason','commercial_refresh_lock_busy','at',now());
  end if;

  perform commercial_intel.refresh_layer();
  return jsonb_build_object('ok',true,'refreshed',true,'at',now());
end
$function$;

revoke all on function solidos_control.run_commercial_dirty_batch(integer) from public,anon,authenticated;
revoke all on function solidos_control.run_commercial_full_refresh() from public,anon,authenticated;
grant execute on function solidos_control.run_commercial_dirty_batch(integer) to service_role;
grant execute on function solidos_control.run_commercial_full_refresh() to service_role;

do $$
begin
  if exists(select 1 from cron.job where jobname='commercial-intel-dirty-1m') then
    perform cron.unschedule((select jobid from cron.job where jobname='commercial-intel-dirty-1m'));
  end if;
  if exists(select 1 from cron.job where jobname='commercial-intel-refresh-15m') then
    perform cron.unschedule((select jobid from cron.job where jobname='commercial-intel-refresh-15m'));
  end if;

  perform cron.schedule(
    'commercial-intel-dirty-1m',
    '* * * * *',
    'select solidos_control.run_commercial_dirty_batch(50);'
  );

  perform cron.schedule(
    'commercial-intel-refresh-15m',
    '7,22,37,52 * * * *',
    'select solidos_control.run_commercial_full_refresh();'
  );
end $$;
