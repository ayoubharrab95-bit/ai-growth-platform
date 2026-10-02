CREATE OR REPLACE FUNCTION solidos_control.system_snapshot()
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO ''
AS $function$
with m as (
  select
    (select count(*) from booked_solid.work_queue where status='pending' and available_at<=now())::int due_now,
    (select count(*) from booked_solid.work_queue where status='running')::int running_now,
    (select count(*) from booked_solid.work_queue where status='running' and locked_at<now()-interval '5 minutes')::int stale_running,
    (select count(*) from booked_solid.work_queue where status='failed')::int failed_history,
    (select count(*) from solidos_control.dead_letter where recovery_status='UNRESOLVED')::int actionable_failed,
    (select count(*) from solidos_control.dead_letter where recovery_status='RETRY_SCHEDULED')::int retry_scheduled,
    (select count(*) from solidos_control.dead_letter where recovery_status='IGNORED')::int ignored_failed,
    (select count(*) from solidos_control.dead_letter where recovery_status='RECOVERED')::int recovered_failed,
    (select count(*) from solidos_control.dirty_companies)::int dirty_backlog,
    (select count(*) from solidos_control.source_health where enabled and health_state='DEGRADED')::int degraded_sources,
    (select count(*) from solidos_control.source_health where enabled and health_state='COOLING')::int cooling_sources,
    (select count(*) from solidos_control.sheet_sync_requests where status='BLOCKED_NOT_CONFIGURED')::int blocked_sheets,
    (select count(*) from solidos_control.sheet_sync_requests where status='RUNNING' and started_at<now()-interval '10 minutes')::int stale_sheet_sync,
    (select count(*) from booked_solid.leads where lower(status)='qualified')::int qualified_count,
    (select count(*) from booked_solid.leads where lower(status)='qualified' and lower(coalesce(priority_band,''))='hot')::int hot_count,
    (select count(*) from booked_solid.leads where lower(status)='qualified' and lower(coalesce(priority_band,''))='high')::int high_count,
    (select count(*) from booked_solid.priority_enrichment_log where status='promoted')::int promotion_count,
    (select count(*) from solidos_control.pipeline_stage_health where sla_state in ('WARNING','DEGRADED'))::int sla_warning_stages,
    (select coalesce(sum(completed_15m),0) from solidos_control.pipeline_stage_health)::int completed_15m
)
select jsonb_build_object(
  'system','SolidOS',
  'snapshot_at',now(),
  'mode',(select mode from solidos_control.settings where id=true),
  'health_status',
    case
      when m.actionable_failed>0
        or m.dirty_backlog>100
        or m.degraded_sources>2
        or m.stale_running>0
        or m.stale_sheet_sync>0
        then 'DEGRADED'
      when m.blocked_sheets>0 then 'BLOCKED_EXTERNAL'
      when m.cooling_sources>0
        or m.due_now>60
        or m.dirty_backlog>50
        or m.sla_warning_stages>2
        then 'HEALTHY_WITH_WARNINGS'
      else 'HEALTHY'
    end,
  'core',jsonb_build_object(
    'companies',(select count(*) from booked_solid.companies),
    'leads',(select count(*) from booked_solid.leads),
    'qualified',m.qualified_count,
    'candidates',(select count(*) from booked_solid.leads where lower(status)='candidate'),
    'due_now',m.due_now,
    'scheduled_future',(select count(*) from booked_solid.work_queue where status='pending' and available_at>now()),
    'running',m.running_now,
    'stale_running',m.stale_running,
    'failed_history',m.failed_history,
    'actionable_failed',m.actionable_failed,
    'dead_letter_retry_scheduled',m.retry_scheduled,
    'dead_letter_ignored',m.ignored_failed,
    'dead_letter_recovered',m.recovered_failed
  ),
  'intel',jsonb_build_object(
    'dirty_backlog',m.dirty_backlog,
    'dirty_oldest_seconds',coalesce((select extract(epoch from(now()-min(first_dirty_at)))::bigint from solidos_control.dirty_companies),0),
    'assets',(select count(*) from commercial_intel.company_assets),
    'safe_assets',(select count(*) from commercial_intel.company_assets where commercial_status='COMMERCIAL_SAFE'),
    'review_assets',(select count(*) from commercial_intel.company_assets where commercial_status='REVIEW_REQUIRED'),
    'signals',(select count(*) from commercial_intel.business_signals where active),
    'exportable_memberships',(select count(*) from commercial_intel.product_memberships where exportable)
  ),
  'sources',jsonb_build_object(
    'enabled',(select count(*) from booked_solid.source_catalog where enabled),
    'healthy',(select count(*) from solidos_control.source_health where enabled and health_state='HEALTHY'),
    'degraded',m.degraded_sources,
    'cooling',m.cooling_sources,
    'optional_quarantined',(select count(*) from booked_solid.source_catalog where not enabled and metadata->>'state'='quarantined_optional')
  ),
  'priority_yield',jsonb_build_object(
    'enabled',true,
    'policy','70/30 rolling exploit/explore',
    'hot',m.hot_count,
    'high',m.high_count,
    'hot_high',m.hot_count+m.high_count,
    'qualified',m.qualified_count,
    'hot_high_yield',case when m.qualified_count>0 then round((m.hot_count+m.high_count)::numeric/m.qualified_count,4) else 0 end,
    'promotions',m.promotion_count,
    'enrichment_queued',(select count(*) from booked_solid.priority_enrichment_log where status='queued')
  ),
  'fast_pipeline',jsonb_build_object(
    'version','v2',
    'lane_workers_active',exists(select 1 from cron.job where jobname='solidos-worker-lanes-1m' and active),
    'planner_2m_active',exists(select 1 from cron.job where jobname='booked-solid-planner-2m' and active),
    'event_chain_kicks_10m',(select count(*) from solidos_control.worker_dispatch_log where created_at>now()-interval '10 minutes'),
    'fast_sheet_dispatches_10m',(select count(*) from solidos_control.sheet_dispatch_log where created_at>now()-interval '10 minutes'),
    'completed_jobs_15m',m.completed_15m,
    'sla_warning_stages',m.sla_warning_stages,
    'resolution_cache_entries',(select count(*) from booked_solid.resolution_cache),
    'active_duplicates',(select count(*) from (
      select kind,coalesce(payload->>'company_id',payload->>'lead_id') k
      from booked_solid.work_queue
      where status in ('pending','running')
        and kind in ('resolve','research','qualify','contact','message')
      group by kind,coalesce(payload->>'company_id',payload->>'lead_id')
      having count(*)>1
    ) d)
  ),
  'sheet_engine',jsonb_build_object(
    'pending_requests',(select count(*) from solidos_control.sheet_sync_requests where status='PENDING'),
    'running_requests',(select count(*) from solidos_control.sheet_sync_requests where status='RUNNING'),
    'stale_running_requests',m.stale_sheet_sync,
    'blocked_not_configured',m.blocked_sheets,
    'targets',(select count(*) from commercial_intel.sheet_targets where sync_enabled),
    'last_success',(select max(last_sync_at) from commercial_intel.sheet_targets where upper(coalesce(last_sync_status,''))='SUCCESS'),
    'native_component_active',true,
    'fast_core_sync_active',true,
    'fallback_1m_active',exists(select 1 from cron.job where jobname='solidos-native-sheet-sync-1m' and active),
    'hourly_refresh_active',exists(select 1 from cron.job where jobname='solidos-hourly-sheet-refresh' and active)
  ),
  'safety',jsonb_build_object(
    'email_enabled',(select email_enabled from booked_solid.runtime_settings where id=true),
    'sms_enabled',(select sms_enabled from booked_solid.runtime_settings where id=true),
    'buyer_outreach_enabled',(select buyer_outreach_enabled from commercial_intel.settings where id=true),
    'personal_pii_export',(select allow_personal_pii_export from commercial_intel.settings where id=true)
  ),
  'operating_playbook',jsonb_build_object(
    'required',(select lead_generation_playbook_required from solidos_control.settings where id=true),
    'version',(select lead_generation_playbook_version from solidos_control.settings where id=true),
    'updated_at',(select lead_generation_playbook_updated_at from solidos_control.settings where id=true),
    'read_function','solidos_control.lead_generation_playbook_snapshot()',
    'github_path','booked-solid-sales-engine/SOLIDOS_LEAD_GENERATION_PLAYBOOK.md',
    'instruction','Read the lead-generation playbook before changing planner, source routing, qualification, Source Recovery, or discovery behavior.'
  )
)
from m;
$function$
