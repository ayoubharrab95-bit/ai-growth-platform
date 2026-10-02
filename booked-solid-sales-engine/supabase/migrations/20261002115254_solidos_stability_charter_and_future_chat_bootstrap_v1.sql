
update solidos_control.settings
set lead_generation_playbook_version=4,
    lead_generation_playbook_updated_at=now(),
    lead_generation_playbook=
      jsonb_set(
        jsonb_set(
          jsonb_set(
            coalesce(lead_generation_playbook,'{}'::jsonb),
            '{version}','4'::jsonb,true
          ),
          '{proven_baseline,orchestrator_version}','60'::jsonb,true
        ),
        '{proven_baseline,worker_version}','116'::jsonb,true
      )
      || jsonb_build_object(
        'stability_charter',jsonb_build_object(
          'version',1,
          'priority','Preserve the current working system before optimizing it.',
          'known_good_runtime',jsonb_build_object(
            'orchestrator',60,
            'worker',116,
            'qualifier',20,
            'sheet_sync',23,
            'revenue_crm_writer',1
          ),
          'change_freeze',jsonb_build_object(
            'default','Do not change planner/source/qualifier/worker behavior merely because of a short-term fluctuation.',
            'exception','Change only when live evidence identifies a specific reproducible bottleneck, safety issue, or material sustained degradation.',
            'one_change_at_a_time',true,
            'reversible_changes_only',true,
            'canary_first',true
          ),
          'future_chat_startup',jsonb_build_array(
            'Call solidos_control.future_chat_bootstrap() first.',
            'Read operating playbook and stability charter before proposing changes.',
            'Determine whether the issue is a real stall or normal temporary backpressure.',
            'Compare 15m/30m/60m Companies, valid Leads, Qualified and HOT/HIGH before changing code.',
            'Inspect pipeline pressure, source cursor progress, Nominatim deferrals, pg_net response age/queue, source yield and current planner mix.',
            'Prefer observation and recovery over tuning when system health is normal.'
          ),
          'diagnostic_order',jsonb_build_array(
            '1. Is the latest valid Lead recent? Check 15m/30m/60m flow.',
            '2. Is pause/throttle caused by downstream backlog? If yes, allow adaptive lanes to drain.',
            '3. Is pg_net healthy? Check queue and response age before restarting anything.',
            '4. Are productive source cursors advancing and returning unique companies?',
            '5. Are Nominatim deferrals blocking usable source-located companies?',
            '6. Is Resolve/Research/Qualify capacity keeping up with arrivals?',
            '7. Is source mix wasting capacity on mature zero-yield sources?',
            '8. Only after the above, consider code or scoring changes.'
          ),
          'do_not_touch_without_evidence',jsonb_build_array(
            'HOT/HIGH/Qualified thresholds',
            'website identity/geography safety checks',
            'ALLOWED-only production source rights gate',
            'persistent Socrata cursor',
            'Nominatim-as-enrichment policy for useful source locations',
            'pg_net watchdog and both queue guards',
            'adaptive lane capacity and global cap',
            'mature zero-yield source cycle cap',
            'email/SMS/buyer outreach/paid search/PII safety flags'
          ),
          'stability_definition',jsonb_build_object(
            'healthy','Leads continue over rolling windows, no stale workers, no actionable failures, pg_net responds, backlog drains automatically, and planner resumes after backpressure.',
            'normal_pause','Short pause/throttle while downstream drains is expected and must not be treated as a failure if completion continues.',
            'real_stall','Planner/worker infrastructure is healthy but valid Leads and new companies materially stop across sustained rolling windows, or queues stop draining/responding.',
            'rollback_rule','If a new change causes a real stall or material quality degradation, revert that change before adding another fix.'
          ),
          'current_learning','The best behavior so far comes from productive Champion sources, persistent pagination, soft/adaptive routing, fast downstream draining, and strict identity/rights safety—not from adding more hard gates.'
        ),
        'future_chat_instruction','Start with solidos_control.future_chat_bootstrap(). Preserve the Stability Charter and known-good baseline. Do not modify SolidOS from a single snapshot; use rolling live evidence and the documented diagnostic order.'
      ),
    updated_at=now()
where id=true;

create or replace function solidos_control.future_chat_bootstrap()
returns jsonb
language sql
stable
set search_path to ''
as $$
select jsonb_build_object(
  'system','SolidOS',
  'purpose','Read-only bootstrap context for future chats/agents. Read this before changing production behavior.',
  'read_only',true,
  'startup_instruction','Preserve the current stable baseline. Diagnose with rolling live evidence before making any mutation.',
  'playbook',solidos_control.lead_generation_playbook_snapshot(),
  'live_system',solidos_control.system_snapshot(),
  'pipeline_pressure',public.solidos_pipeline_pressure(),
  'strategy_brain',solidos_control.strategy_brain_snapshot(),
  'brain_autopilot',solidos_control.strategy_brain_autopilot_snapshot(),
  'strategy_portfolio',solidos_control.strategy_portfolio_snapshot(),
  'source_recovery',solidos_control.source_recovery_snapshot(),
  'recent_flow',jsonb_build_object(
    'companies_15m',(select count(*) from booked_solid.companies where created_at>now()-interval '15 minutes'),
    'companies_30m',(select count(*) from booked_solid.companies where created_at>now()-interval '30 minutes'),
    'companies_60m',(select count(*) from booked_solid.companies where created_at>now()-interval '60 minutes'),
    'valid_leads_15m',(select count(*) from booked_solid.leads where created_at>now()-interval '15 minutes' and status not in ('suppressed','rejected')),
    'valid_leads_30m',(select count(*) from booked_solid.leads where created_at>now()-interval '30 minutes' and status not in ('suppressed','rejected')),
    'valid_leads_60m',(select count(*) from booked_solid.leads where created_at>now()-interval '60 minutes' and status not in ('suppressed','rejected')),
    'qualified_15m',(select count(*) from booked_solid.leads where created_at>now()-interval '15 minutes' and status in ('qualified','message_ready','queued','sent','replied','meeting','won')),
    'qualified_30m',(select count(*) from booked_solid.leads where created_at>now()-interval '30 minutes' and status in ('qualified','message_ready','queued','sent','replied','meeting','won')),
    'qualified_60m',(select count(*) from booked_solid.leads where created_at>now()-interval '60 minutes' and status in ('qualified','message_ready','queued','sent','replied','meeting','won')),
    'latest_valid_lead_at',(select max(created_at) from booked_solid.leads where status not in ('suppressed','rejected'))
  ),
  'runtime',jsonb_build_object(
    'pgnet_queue',(select count(*) from net.http_request_queue),
    'pgnet_response_age_seconds',coalesce((select extract(epoch from(now()-max(created)))::int from net._http_response),0),
    'failed_work_30m',(select count(*) from booked_solid.work_queue where status='failed' and updated_at>now()-interval '30 minutes'),
    'stale_running',(select count(*) from booked_solid.work_queue where status='running' and locked_at<now()-interval '5 minutes'),
    'cron_failures_60m',(select count(*) from cron.job_run_details where start_time>now()-interval '60 minutes' and status not in ('succeeded','running'))
  ),
  'source_scan_state',coalesce((
    select jsonb_agg(jsonb_build_object(
      'source_slug',source_slug,
      'next_page',next_page,
      'last_claimed_page',last_claimed_page,
      'claims',claims,
      'wraps',wraps,
      'last_claimed_at',last_claimed_at
    ) order by source_slug)
    from booked_solid.source_scan_state
  ),'[]'::jsonb),
  'github',jsonb_build_object(
    'playbook','booked-solid-sales-engine/SOLIDOS_LEAD_GENERATION_PLAYBOOK.md',
    'project_root','booked-solid-sales-engine/',
    'instruction','Production and GitHub should remain synchronized after any verified change.'
  )
);
$$;

revoke all on function solidos_control.future_chat_bootstrap() from public,anon,authenticated;
grant execute on function solidos_control.future_chat_bootstrap() to service_role;

comment on function solidos_control.future_chat_bootstrap() is
'FUTURE CHAT START HERE. Read-only SolidOS bootstrap with operating playbook, stability charter, live health, rolling flow, pressure, source recovery, strategy state and cursor state. Diagnose before mutating production.';

comment on function solidos_control.system_snapshot() is
'SolidOS live health snapshot. Future chats should start with solidos_control.future_chat_bootstrap() before changing production behavior.';
