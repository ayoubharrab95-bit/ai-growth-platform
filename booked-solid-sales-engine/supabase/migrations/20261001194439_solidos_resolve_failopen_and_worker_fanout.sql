
do $$
begin
  if exists(select 1 from cron.job where jobname='booked-solid-worker-adaptive') then
    perform cron.unschedule((select jobid from cron.job where jobname='booked-solid-worker-adaptive'));
  end if;

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
          when due_now > 180 then 12
          when due_now > 90 then 10
          when due_now > 30 then 6
          when due_now > 0 then 3
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

create unique index if not exists work_queue_one_pending_resolve_company_idx
on booked_solid.work_queue ((payload->>'company_id'))
where kind='resolve'
  and status='pending'
  and nullif(payload->>'company_id','') is not null;
