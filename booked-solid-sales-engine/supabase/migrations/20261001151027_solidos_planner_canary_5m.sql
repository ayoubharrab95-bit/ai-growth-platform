do $$
declare v_cmd text;
begin
  select command into v_cmd from cron.job where jobname='booked-solid-planner-15m';
  if v_cmd is not null then
    perform cron.unschedule((select jobid from cron.job where jobname='booked-solid-planner-15m'));
  end if;
  if exists(select 1 from cron.job where jobname='booked-solid-planner-5m') then
    perform cron.unschedule((select jobid from cron.job where jobname='booked-solid-planner-5m'));
  end if;
  perform cron.schedule(
    'booked-solid-planner-5m','*/5 * * * *',
    $cmd$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name='booked_solid_project_url') || '/functions/v1/booked-solid-orchestrator',
      headers := jsonb_build_object('Content-Type','application/json','apikey',(select decrypted_secret from vault.decrypted_secrets where name='booked_solid_publishable_key')),
      body := jsonb_build_object('action','plan','limit',3),
      timeout_milliseconds := 30000
    ) as request_id;
    $cmd$
  );
end $$;
