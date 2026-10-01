update solidos_control.sheet_sync_requests
set status='SUCCEEDED',finished_at=now(),last_error=null,updated_at=now()
where status in ('PENDING','BLOCKED_NOT_CONFIGURED')
  and sync_scope in ('CORE_CRM','COMMERCIAL_PRODUCTS');

update commercial_intel.sheet_sync_cycles
set status='failed',
    error='Superseded by successful SolidOS Native Sheets cycle 34689f55-2f93-4ebe-8271-8cbb2eab21fc.',
    finished_at=now()
where status='prepared'
  and id <> '34689f55-2f93-4ebe-8271-8cbb2eab21fc'::uuid;

do $$
begin
  if exists(select 1 from cron.job where jobname='solidos-native-sheet-sync-2m') then
    perform cron.unschedule((select jobid from cron.job where jobname='solidos-native-sheet-sync-2m'));
  end if;
  perform cron.schedule(
    'solidos-native-sheet-sync-2m',
    '*/2 * * * *',
    $cmd$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name='booked_solid_project_url') || '/functions/v1/solidos-sheet-sync',
      headers := jsonb_build_object(
        'Content-Type','application/json',
        'apikey',(select decrypted_secret from vault.decrypted_secrets where name='booked_solid_publishable_key')
      ),
      body := jsonb_build_object('action','sync-pending'),
      timeout_milliseconds := 120000
    ) as request_id;
    $cmd$
  );
end $$;
