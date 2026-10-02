
update solidos_control.settings
set lead_generation_playbook_version=3,
    lead_generation_playbook_updated_at=now(),
    lead_generation_playbook=jsonb_set(
      jsonb_set(
        coalesce(lead_generation_playbook,'{}'::jsonb),
        '{version}','3'::jsonb,true
      ),
      '{proven_baseline,orchestrator_version}','60'::jsonb,true
    ) || jsonb_build_object(
      'source_exploration_cycle_guard',jsonb_build_object(
        'rule','Allow at most one mature zero-yield source job per planner cycle.',
        'reason','Preserve controlled source learning without allowing mature zero-yield sources to consume a large share of Resolve capacity.',
        'replacement_behavior','If an additional mature zero-yield routed candidate would exceed the cap, skip it and continue to the next safe routable Proven/Testing candidate.',
        'verified_acceptance',jsonb_build_object(
          'planner_exposed_cap',1,
          'productive_source','auto-socrata-l-i-intent-project-details-t9je9qwa',
          'new_hot_example','3 KINGS ENVIRONMENTAL INC',
          'new_hot_score',96,
          'new_hot_opportunity',80,
          'new_hot_trigger',40
        )
      )
    ),
    updated_at=now()
where id=true;
