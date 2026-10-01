create or replace function booked_solid.requeue_stale_work(p_stale_minutes integer default 5)
returns jsonb
language plpgsql
security definer
set search_path='booked_solid','public'
as $function$
declare
  v_count integer:=0;
begin
  update booked_solid.work_queue
  set status='pending',
      attempts=greatest(attempts-1,0),
      available_at=now(),
      locked_at=null,
      locked_by=null,
      last_error=null,
      updated_at=now()
  where status='running'
    and locked_at is not null
    and locked_at < now() - make_interval(mins => greatest(2,least(coalesce(p_stale_minutes,5),30)));
  get diagnostics v_count=row_count;
  return jsonb_build_object('requeued',v_count,'stale_minutes',p_stale_minutes,'at',now());
end
$function$;

revoke all on function booked_solid.requeue_stale_work(integer) from public,anon,authenticated;
grant execute on function booked_solid.requeue_stale_work(integer) to service_role;

do $$
begin
  if exists(select 1 from cron.job where jobname='booked-solid-worker-5m') then
    perform cron.unschedule((select jobid from cron.job where jobname='booked-solid-worker-5m'));
  end if;
  if exists(select 1 from cron.job where jobname='booked-solid-worker-adaptive') then
    perform cron.unschedule((select jobid from cron.job where jobname='booked-solid-worker-adaptive'));
  end if;
  if exists(select 1 from cron.job where jobname='solidos-stale-work-reaper-1m') then
    perform cron.unschedule((select jobid from cron.job where jobname='solidos-stale-work-reaper-1m'));
  end if;

  perform cron.schedule('solidos-stale-work-reaper-1m','* * * * *','select booked_solid.requeue_stale_work(5);');

  perform cron.schedule(
    'booked-solid-worker-adaptive',
    '* * * * *',
    $cmd$
    with pressure as (
      select
        (select count(*) from booked_solid.work_queue where status='pending' and available_at<=now())::int as due_now,
        (select count(*) from booked_solid.work_queue where status='running')::int as running_now
    ),
    fanout as (
      select least(
        case
          when due_now > 300 then 8
          when due_now > 100 then 6
          when due_now > 30 then 4
          when due_now > 0 then 2
          else 0
        end,
        greatest(0,12-running_now)
      )::int as n
      from pressure
    )
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name='booked_solid_project_url') || '/functions/v1/booked-solid-worker',
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'apikey',(select decrypted_secret from vault.decrypted_secrets where name='booked_solid_publishable_key')
      ),
      body := jsonb_build_object('source','solidos-adaptive-single','batch_size',1),
      timeout_milliseconds := 45000
    ) as request_id
    from fanout, generate_series(1,fanout.n)
    where fanout.n > 0;
    $cmd$
  );
end $$;
