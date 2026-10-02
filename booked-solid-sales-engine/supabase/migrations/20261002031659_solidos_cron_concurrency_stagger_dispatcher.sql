select cron.alter_job(
    4,
    schedule := '1,16,31,46 * * * *',
    active := true
  );