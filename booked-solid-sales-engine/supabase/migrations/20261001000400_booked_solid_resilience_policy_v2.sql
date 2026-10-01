-- Booked Solid resilience policy v2
-- Safe runtime error classification, source cooldowns, and recovery scoring.
-- Production-applied 2026-10-01.

CREATE OR REPLACE FUNCTION booked_solid.record_source_failure(p_slug text, p_error text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'booked_solid', 'public'
AS $function$
declare
  n integer;
  cls text;
  transient boolean;
  cooldown_minutes integer;
  now_ts timestamptz := now();
begin
  cls := case
    when lower(coalesce(p_error,'')) ~ 'overpass_http_(0|406|408|425|429|5[0-9][0-9])'
      or lower(coalesce(p_error,'')) ~ 'overpass_fallback_failed:overpass_http_(0|406|408|425|429|5[0-9][0-9])' then 'overpass_transient'
    when lower(coalesce(p_error,'')) ~ '(timeout|timed out|aborterror|network|fetch failed|socket|dns|connection reset)' then 'network_timeout'
    when lower(coalesce(p_error,'')) ~ '(http_429|rate.?limit|too many requests)' then 'rate_limit'
    when lower(coalesce(p_error,'')) ~ '(http_5[0-9][0-9]| 5[0-9][0-9])' then 'upstream_5xx'
    when lower(coalesce(p_error,'')) ~ '(http_401|unauthorized)' then 'auth_401'
    when lower(coalesce(p_error,'')) ~ '(http_403|forbidden)' then 'auth_403'
    when lower(coalesce(p_error,'')) ~ '(http_404|not found)' then 'not_found'
    when lower(coalesce(p_error,'')) ~ '(schema|column|unsupported_provider|no_company_layer|invalid field)' then 'schema_or_adapter'
    when lower(coalesce(p_error,'')) ~ '(http_4[0-9][0-9]| 4[0-9][0-9])' then 'upstream_4xx'
    else 'unknown'
  end;

  transient := cls in ('overpass_transient','network_timeout','rate_limit','upstream_5xx');

  update booked_solid.source_catalog
  set last_error_at = now_ts,
      consecutive_errors = consecutive_errors + 1,
      reliability_score = greatest(
        0,
        least(100, coalesce(reliability_score,75) - case when transient then 2 else 6 end)
      ),
      metadata = coalesce(metadata,'{}'::jsonb)
        || jsonb_build_object(
          'consecutive_failures', consecutive_errors + 1,
          'last_runtime_error', left(p_error,500),
          'last_error_class', cls,
          'transient_failure', transient,
          'error_policy_version', 2,
          'last_failure_at', now_ts
        ),
      updated_at = now_ts
  where slug = p_slug
  returning consecutive_errors into n;

  if n is null then return; end if;

  cooldown_minutes := case
    when cls='rate_limit' then least(180, 30 * greatest(1,n))
    when cls='overpass_transient' then case when n=1 then 10 when n=2 then 20 when n=3 then 40 else 60 end
    when cls='network_timeout' then case when n=1 then 10 when n=2 then 20 when n=3 then 40 else 60 end
    when cls='upstream_5xx' then case when n=1 then 15 when n=2 then 30 when n=3 then 60 else 120 end
    when cls in ('auth_401','auth_403','schema_or_adapter','not_found','upstream_4xx') then 360
    else 30
  end;

  update booked_solid.source_catalog
  set metadata = metadata || jsonb_build_object(
        'cooldown_until', now_ts + make_interval(mins => cooldown_minutes),
        'cooldown_minutes', cooldown_minutes
      ),
      lifecycle_state = case
        when n >= 2 and enabled then 'degraded'
        else lifecycle_state
      end,
      updated_at = now_ts
  where slug = p_slug;

  -- Only permanently pause self-healing sources after repeated NON-transient failures.
  -- Transient network/rate-limit failures are handled by cooldown and remain recoverable.
  if not transient and p_slug <> 'openstreetmap_overpass' and n >= 3 then
    update booked_solid.source_catalog
    set enabled = false,
        lifecycle_state = 'paused',
        metadata = metadata || jsonb_build_object(
          'auto_paused_reason','3 consecutive non-transient runtime errors',
          'auto_paused_at',now_ts
        ),
        updated_at = now_ts
    where slug = p_slug;
  end if;
end;
$function$;

CREATE OR REPLACE FUNCTION booked_solid.record_source_success(p_slug text)
 RETURNS void
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'booked_solid', 'public'
AS $function$
  update booked_solid.source_catalog
  set last_success_at=now(),
      consecutive_errors=0,
      reliability_score=least(100,coalesce(reliability_score,75)+2),
      lifecycle_state=case
        when lifecycle_state in ('degraded','testing') then 'canary'
        when lifecycle_state='paused' and enabled then 'canary'
        else lifecycle_state
      end,
      metadata=coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
        'consecutive_failures',0,
        'cooldown_until',null,
        'cooldown_minutes',0,
        'last_recovery_at',now()
      ),
      updated_at=now()
  where slug=p_slug;
$function$;

-- Increase pg_net response timeout for long-running worker/evolution calls.
-- Jobs are located by name so the migration does not depend on production job IDs.
select cron.alter_job(
  (select jobid from cron.job where jobname='booked-solid-worker-5m' limit 1),
  command := $cmd$
 select net.http_post(
   url := (select decrypted_secret from vault.decrypted_secrets where name='booked_solid_project_url') || '/functions/v1/booked-solid-worker',
   headers := jsonb_build_object('Content-Type','application/json','apikey',(select decrypted_secret from vault.decrypted_secrets where name='booked_solid_publishable_key')),
   body := jsonb_build_object('source','cron'),
   timeout_milliseconds := 30000
 ) as request_id;
$cmd$
);

select cron.alter_job(
  (select jobid from cron.job where jobname='booked-solid-evolution-review-6h' limit 1),
  command := $cmd$
 select net.http_post(
   url := (select decrypted_secret from vault.decrypted_secrets where name='booked_solid_project_url') || '/functions/v1/booked-solid-evolution',
   headers := jsonb_build_object('Content-Type','application/json','apikey',(select decrypted_secret from vault.decrypted_secrets where name='booked_solid_publishable_key')),
   body := '{"action":"review"}'::jsonb,
   timeout_milliseconds := 30000
 ) as request_id;
$cmd$
);

select cron.alter_job(
  (select jobid from cron.job where jobname='booked-solid-evolution-daily' limit 1),
  command := $cmd$
 select net.http_post(
   url := (select decrypted_secret from vault.decrypted_secrets where name='booked_solid_project_url') || '/functions/v1/booked-solid-evolution',
   headers := jsonb_build_object('Content-Type','application/json','apikey',(select decrypted_secret from vault.decrypted_secrets where name='booked_solid_publishable_key')),
   body := '{"action":"cycle"}'::jsonb,
   timeout_milliseconds := 30000
 ) as request_id;
$cmd$
);
