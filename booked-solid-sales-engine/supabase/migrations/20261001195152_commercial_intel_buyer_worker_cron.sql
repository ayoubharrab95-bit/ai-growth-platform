
do $$
begin
  if exists(select 1 from cron.job where jobname='commercial-intel-buyer-worker-15m') then
    perform cron.unschedule((select jobid from cron.job where jobname='commercial-intel-buyer-worker-15m'));
  end if;

  perform cron.schedule(
    'commercial-intel-buyer-worker-15m',
    '5,20,35,50 * * * *',
    $cmd$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name='booked_solid_project_url') || '/functions/v1/commercial-intel-buyer-worker',
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'apikey',(select decrypted_secret from vault.decrypted_secrets where name='booked_solid_publishable_key'),
        'Authorization','Bearer ' || (select decrypted_secret from vault.decrypted_secrets where name='booked_solid_publishable_key')
      ),
      body := '{}'::jsonb,
      timeout_milliseconds := 60000
    ) as request_id;
    $cmd$
  );
end $$;
