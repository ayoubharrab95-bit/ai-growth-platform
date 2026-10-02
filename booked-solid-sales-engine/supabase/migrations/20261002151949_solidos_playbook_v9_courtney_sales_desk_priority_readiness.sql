
update solidos_control.settings
set lead_generation_playbook_version=9,
    lead_generation_playbook_updated_at=now(),
    lead_generation_playbook=
      jsonb_set(
        jsonb_set(
          coalesce(lead_generation_playbook,'{}'::jsonb),
          '{version}','9'::jsonb,true
        ),
        '{stability_audit_v5,known_good_runtime,sheet_sync}','28'::jsonb,true
      )
      || jsonb_build_object(
        'courtney_sales_desk_v1',jsonb_build_object(
          'sheet_tab','START HERE — COURTNEY',
          'update_policy','The live section is updated automatically by the existing CORE_CRM Sheet Sync. No separate cron or writer is allowed.',
          'priority_definition','Priority = lead strength band such as HOT, HIGH, SIGNAL, STANDARD.',
          'readiness_definition','Readiness = revenue action state such as ACT NOW, REVIEW, ENRICH, WATCH.',
          'work_order','Courtney should work Readiness first (ACT NOW → REVIEW → ENRICH/WATCH), then Priority inside the same Readiness (HOT before HIGH).',
          'live_columns',jsonb_build_array(
            'Company','Priority','Readiness','Opportunity','Decision Maker','Role / Title',
            'Email','Phone','Why Now','Offer','Action'
          ),
          'ranking','Top worklist ranks by Readiness, Revenue Score, Priority, then Opportunity.',
          'decision_maker_rule','Show Decision Maker and Role only when decision_maker_known=true. A general inbox is a company route, not automatically the named person personal email.',
          'static_guide_preserved',true,
          'sheet_sync_version',28,
          'acceptance','CORE_CRM sync request 18579 completed SUCCEEDED and verified START HERE — COURTNEY with 10 live rows and a Readiness header.'
        ),
        'future_chat_instruction','Start with solidos_control.future_chat_bootstrap(). Keep Priority and Readiness separate in START HERE — COURTNEY. The page is live through CORE_CRM Sheet Sync v28; do not create a separate Courtney cron or writer.'
      ),
    updated_at=now()
where id=true;
