
update solidos_control.settings
set lead_generation_playbook_version=5,
    lead_generation_playbook_updated_at=now(),
    lead_generation_playbook=
      jsonb_set(
        jsonb_set(
          coalesce(lead_generation_playbook,'{}'::jsonb),
          '{version}','5'::jsonb,true
        ),
        '{proven_baseline,orchestrator_version}','61'::jsonb,true
      )
      || jsonb_build_object(
        'stability_audit_v5',jsonb_build_object(
          'known_good_runtime',jsonb_build_object(
            'orchestrator',61,
            'worker',116,
            'qualifier',20,
            'sheet_sync',23,
            'revenue_crm_writer',1
          ),
          'verified_fixes',jsonb_build_array(
            'pg_net watchdog auto-restart event severity corrected from WARNING to allowed WARN.',
            'Orchestrator race-prone single-row mutations now use maybeSingle with safe zero-row fallbacks, eliminating avoidable PGRST116 without changing lead-generation logic.'
          ),
          'audit_results',jsonb_build_object(
            'duplicate_active_jobs',0,
            'duplicate_domains',0,
            'orphan_leads',0,
            'orphan_contacts',0,
            'orphan_evidence',0,
            'qualified_below_threshold',0,
            'hot_rule_violations',0,
            'suppressed_selected_contacts',0,
            'contact_noise',0,
            'exploit_nonallowed',0,
            'osm_production_jobs',0
          ),
          'stability_rule','Do not tune scoring, source rights, or lane capacity based on this audit; current production is healthy and generating leads. Preserve v61/v116 unless newer rolling evidence proves a specific regression.'
        ),
        'future_chat_instruction','Start with solidos_control.future_chat_bootstrap(). Current known-good baseline is Orchestrator v61 + Worker v116. Preserve stability; diagnose with rolling evidence before changing production.'
      ),
    updated_at=now()
where id=true;
