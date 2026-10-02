
select cron.unschedule(jobid)
from cron.job
where jobname in ('solidos-revenue-crm-sync-hourly','solidos-revenue-sheet-hourly');

select cron.schedule(
  'solidos-revenue-crm-sync-hourly',
  '4 * * * *',
  $cron$
  select net.http_post(
    url := (select decrypted_secret from vault.decrypted_secrets where name='booked_solid_project_url') || '/functions/v1/solidos-revenue-crm-writer',
    headers := jsonb_build_object(
      'Content-Type','application/json',
      'apikey',(select decrypted_secret from vault.decrypted_secrets where name='booked_solid_publishable_key')
    ),
    body := jsonb_build_object('source','solidos-hourly-revenue-crm','requested_at',now()),
    timeout_milliseconds := 120000
  ) as request_id;
  $cron$
);
