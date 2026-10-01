create or replace function solidos_control.system_snapshot()
returns jsonb
language sql
stable
security invoker
set search_path=''
as $function$
with m as (
  select
    (select count(*) from booked_solid.work_queue where status='pending' and available_at<=now())::int due_now,
    (select count(*) from booked_solid.work_queue where status='failed')::int failed_history,
    (select count(*) from solidos_control.dead_letter where recovery_status='UNRESOLVED')::int actionable_failed,
    (select count(*) from solidos_control.dead_letter where recovery_status='RETRY_SCHEDULED')::int retry_scheduled,
    (select count(*) from solidos_control.dead_letter where recovery_status='IGNORED')::int ignored_failed,
    (select count(*) from solidos_control.dead_letter where recovery_status='RECOVERED')::int recovered_failed,
    (select count(*) from solidos_control.dirty_companies)::int dirty_backlog,
    (select count(*) from solidos_control.source_health where enabled and health_state='DEGRADED')::int degraded_sources,
    (select count(*) from solidos_control.source_health where enabled and health_state='COOLING')::int cooling_sources,
    (select count(*) from solidos_control.sheet_sync_requests where status='BLOCKED_NOT_CONFIGURED')::int blocked_sheets
)
select jsonb_build_object(
  'system','SolidOS','snapshot_at',now(),'mode',(select mode from solidos_control.settings where id=true),
  'health_status',case
    when m.actionable_failed>0 or m.dirty_backlog>50 or m.degraded_sources>2 then 'DEGRADED'
    when m.blocked_sheets>0 then 'BLOCKED_EXTERNAL'
    when m.cooling_sources>0 or m.due_now>15 then 'HEALTHY_WITH_WARNINGS'
    else 'HEALTHY' end,
  'core',jsonb_build_object(
    'companies',(select count(*) from booked_solid.companies),
    'leads',(select count(*) from booked_solid.leads),
    'qualified',(select count(*) from booked_solid.leads where lower(status)='qualified'),
    'candidates',(select count(*) from booked_solid.leads where lower(status)='candidate'),
    'due_now',m.due_now,'scheduled_future',(select count(*) from booked_solid.work_queue where status='pending' and available_at>now()),
    'running',(select count(*) from booked_solid.work_queue where status='running'),
    'failed_history',m.failed_history,'actionable_failed',m.actionable_failed,
    'dead_letter_retry_scheduled',m.retry_scheduled,'dead_letter_ignored',m.ignored_failed,
    'dead_letter_recovered',m.recovered_failed),
  'intel',jsonb_build_object(
    'dirty_backlog',m.dirty_backlog,
    'dirty_oldest_seconds',coalesce((select extract(epoch from(now()-min(first_dirty_at)))::bigint from solidos_control.dirty_companies),0),
    'assets',(select count(*) from commercial_intel.company_assets),
    'safe_assets',(select count(*) from commercial_intel.company_assets where commercial_status='COMMERCIAL_SAFE'),
    'review_assets',(select count(*) from commercial_intel.company_assets where commercial_status='REVIEW_REQUIRED'),
    'signals',(select count(*) from commercial_intel.business_signals where active),
    'exportable_memberships',(select count(*) from commercial_intel.product_memberships where exportable)),
  'sources',jsonb_build_object(
    'enabled',(select count(*) from booked_solid.source_catalog where enabled),
    'healthy',(select count(*) from solidos_control.source_health where enabled and health_state='HEALTHY'),
    'degraded',m.degraded_sources,'cooling',m.cooling_sources),
  'sheet_engine',jsonb_build_object(
    'pending_requests',(select count(*) from solidos_control.sheet_sync_requests where status='PENDING'),
    'blocked_not_configured',m.blocked_sheets,
    'targets',(select count(*) from commercial_intel.sheet_targets where sync_enabled),
    'last_success',(select max(last_sync_at) from commercial_intel.sheet_targets where upper(coalesce(last_sync_status,''))='SUCCESS'),
    'native_component_active',true),
  'safety',jsonb_build_object(
    'email_enabled',(select email_enabled from booked_solid.runtime_settings where id=true),
    'sms_enabled',(select sms_enabled from booked_solid.runtime_settings where id=true),
    'buyer_outreach_enabled',(select buyer_outreach_enabled from commercial_intel.settings where id=true),
    'personal_pii_export',(select allow_personal_pii_export from commercial_intel.settings where id=true))
)
from m;
$function$;