
create or replace function solidos_control.strategy_brain_snapshot()
returns jsonb
language sql
security definer
set search_path=''
as $function$
with runtime as (
  select strategy_brain_enabled enabled,
         strategy_brain_canary_pct canary_pct,
         strategy_brain_policy_version policy_version
  from booked_solid.runtime_settings where id=true
),
recent_jobs as (
  select
    count(*)::int jobs_30m,
    count(*) filter(where payload->>'priority_selection_mode'='exploit')::int exploit_jobs_30m,
    count(*) filter(where payload->>'priority_selection_mode'='explore')::int explore_jobs_30m,
    count(*) filter(
      where payload->>'priority_selection_mode'='exploit'
        and payload->>'brain_source_lane'='exploration'
        and created_at>='2026-10-02 02:38:00+00'::timestamptz
    )::int exploit_to_exploration_source_violations,
    count(*) filter(where payload->>'brain_strategy_decision'='deprioritize')::int deprioritized_selected_30m,
    count(*) filter(where payload->>'strategy_slug' like 'brain-%')::int canary_jobs_30m
  from booked_solid.work_queue
  where kind='discover'
    and coalesce(payload->>'brain_policy_version','0')='2'
    and created_at>now()-interval '30 minutes'
),
current_metrics as (
  select jsonb_build_object(
    'companies_total',(select count(*) from booked_solid.companies),
    'leads_total',(select count(*) from booked_solid.leads),
    'qualified_total',(select count(*) from booked_solid.leads where status in ('qualified','message_ready','queued','sent','replied','meeting','won')),
    'hot_total',(select count(*) from booked_solid.leads where upper(coalesce(priority_band,''))='HOT'),
    'high_total',(select count(*) from booked_solid.leads where upper(coalesce(priority_band,''))='HIGH'),
    'companies_60m',(select count(*) from booked_solid.companies where created_at>now()-interval '60 minutes'),
    'leads_60m',(select count(*) from booked_solid.leads where created_at>now()-interval '60 minutes'),
    'qualified_touched_60m',(select count(*) from booked_solid.leads where status in ('qualified','message_ready','queued','sent','replied','meeting','won') and updated_at>now()-interval '60 minutes'),
    'act_now',(select count(*) from solidos_control.revenue_intelligence_current where readiness='ACT NOW'),
    'review',(select count(*) from solidos_control.revenue_intelligence_current where readiness='REVIEW')
  ) v
),
strategy_counts as (
  select jsonb_build_object(
    'total',count(*),
    'exploit',count(*) filter(where decision='exploit'),
    'test',count(*) filter(where decision='test'),
    'deprioritize',count(*) filter(where decision='deprioritize'),
    'canary_total',(select count(*) from booked_solid.search_strategies where enabled and coalesce((metadata->>'brain_v2_canary')::boolean,false)),
    'canary_with_attempts',(select count(*) from booked_solid.search_strategies s join solidos_control.strategy_brain_strategy_current b on b.strategy_id=s.id where s.enabled and coalesce((s.metadata->>'brain_v2_canary')::boolean,false) and b.attempts_14d>0),
    'canary_with_leads',(select count(*) from booked_solid.search_strategies s join solidos_control.strategy_brain_strategy_current b on b.strategy_id=s.id where s.enabled and coalesce((s.metadata->>'brain_v2_canary')::boolean,false) and b.leads_45d>0)
  ) v
  from solidos_control.strategy_brain_strategy_current
),
source_counts as (
  select jsonb_build_object(
    'total',count(*),
    'proven',count(*) filter(where lane='proven'),
    'testing',count(*) filter(where lane='testing'),
    'exploration',count(*) filter(where lane='exploration'),
    'blocked',count(*) filter(where lane='blocked'),
    'zero_yield_guard',count(*) filter(where zero_yield_guard)
  ) v
  from solidos_control.strategy_brain_source_current
),
market_counts as (
  select jsonb_build_object(
    'total',count(*),
    'exploit',count(*) filter(where decision='exploit'),
    'test',count(*) filter(where decision='test'),
    'deprioritize',count(*) filter(where decision='deprioritize')
  ) v
  from solidos_control.strategy_brain_market_current
)
select jsonb_build_object(
  'at',now(),
  'enabled',(select enabled from runtime),
  'policy_version',(select policy_version from runtime),
  'canary_pct',(select canary_pct from runtime),
  'latest_run',(select to_jsonb(r) from solidos_control.strategy_brain_runs r order by id desc limit 1),
  'baseline',(select metrics from solidos_control.strategy_brain_baseline where id=true),
  'current',(select v from current_metrics),
  'strategies',(select v from strategy_counts),
  'sources',(select v from source_counts),
  'markets',(select v from market_counts),
  'recent_planner',(select to_jsonb(recent_jobs) from recent_jobs),
  'top_strategies',(
    select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb)
    from (
      select strategy_slug,trade,intent,offer_hint,brain_score,decision,attempts_14d,leads_45d,qualified_45d,hot_high_45d,act_now
      from solidos_control.strategy_brain_strategy_current
      order by brain_score desc
      limit 10
    ) x
  ),
  'guarded_sources',(
    select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb)
    from (
      select source_slug,sample_count,lead_count,brain_score,lane,rights_status
      from solidos_control.strategy_brain_source_current
      where zero_yield_guard
      order by sample_count desc
    ) x
  ),
  'top_markets',(
    select coalesce(jsonb_agg(to_jsonb(x)),'[]'::jsonb)
    from (
      select market_name,brain_score,decision,discovered_count,qualified_count,qualified_rate
      from solidos_control.strategy_brain_market_current
      order by brain_score desc
      limit 8
    ) x
  ),
  'safety',jsonb_build_object(
    'email_enabled',(select email_enabled from booked_solid.runtime_settings where id=true),
    'sms_enabled',(select sms_enabled from booked_solid.runtime_settings where id=true),
    'new_source_auto_enable',false,
    'linkedin_scraping',false,
    'automated_linkedin_messaging',false,
    'hot_high_thresholds_changed',false
  )
);
$function$;

revoke all on function solidos_control.strategy_brain_snapshot() from public,anon,authenticated;
grant execute on function solidos_control.strategy_brain_snapshot() to service_role;
