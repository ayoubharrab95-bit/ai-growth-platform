
update solidos_control.settings
set lead_generation_playbook_version=2,
    lead_generation_playbook_updated_at=now(),
    lead_generation_playbook=jsonb_set(
      jsonb_set(
        jsonb_set(
          coalesce(lead_generation_playbook,'{}'::jsonb),
          '{version}','2'::jsonb,true
        ),
        '{proven_baseline,orchestrator_version}','59'::jsonb,true
      ),
      '{proven_baseline,worker_version}','116'::jsonb,true
    ) || jsonb_build_object(
      'continuous_flow_v2',jsonb_build_object(
        'problem_pattern','System can appear to work, add leads, then pause because productive pages saturate, Nominatim defers companies, or pg_net dispatch bursts accumulate.',
        'source_scan_cursor',jsonb_build_object(
          'required',true,
          'table','booked_solid.source_scan_state',
          'claim_function','booked_solid.claim_source_scan_page(text,integer,integer)',
          'policy','Productive Socrata sources use an atomic persistent sequential cursor so parallel workers claim distinct pages and do not repeatedly rescan a small hash window.',
          'default_scan_pages',60
        ),
        'geocoder_policy',jsonb_build_object(
          'rule','Nominatim is enrichment, not a hard gate, when an ALLOWED source already provides a useful city/state location.',
          'cooldown_behavior','Continue immediately to qualification fallback using source evidence instead of deferring 15-20 minutes.',
          'quality_unchanged','Website identity/geography validation and Qualifier thresholds remain unchanged.'
        ),
        'resolve_capacity',jsonb_build_object(
          'rule','Resolve capacity must burst before backlog becomes a visible stop.',
          'oldest_75s_or_due_3','2-5 resolve workers',
          'oldest_180s_or_arrivals_gt_completions','3-6 resolve workers',
          'global_cap',12
        ),
        'pg_net_reliability',jsonb_build_object(
          'watchdog','solidos_control.pgnet_watchdog() every minute',
          'stall_definition','2 or more queued worker requests and no fresh pg_net response for 75 seconds',
          'action','Official net.worker_restart() with a 4-minute restart cooldown.',
          'cron_guard','Do not add cron workers when worker queue is stalled or already >=8.',
          'event_guard','Event-driven dispatch uses the same queue/stall guard; cron later picks up skipped dispatches.'
        ),
        'source_mix',jsonb_build_object(
          'explore_on_proven_pct_approx',60,
          'explore_on_testing_pct_approx',30,
          'true_exploration_pct_approx',10,
          'mature_zero_yield_share','very small; preserve learning but do not let mature zero-yield sources consume Resolve capacity.'
        ),
        'live_acceptance',jsonb_build_object(
          'cursor_validation','Washington persistent cursor advanced through pages 12-15 with unique new companies.',
          'automatic_leads_after_geocoder_fix',2,
          'qualified_example','LYNDEN SHEET METAL INC',
          'qualified_score',70,
          'qualified_trigger_score',35,
          'qualified_company_to_lead_minutes',4.81,
          'candidate_example','DIMENSIONAL COMMUNICATIONS INC',
          'candidate_company_to_lead_minutes',2.95,
          'manual_worker_dispatch_required',false
        ),
        'future_agent_rule','If leads become bursty again, inspect source cursor progress, Nominatim deferrals, Resolve backlog, pg_net response age/queue, and event+cron dispatch amplification before changing scoring thresholds or tightening source gates.'
      )
    ),
    updated_at=now()
where id=true;
