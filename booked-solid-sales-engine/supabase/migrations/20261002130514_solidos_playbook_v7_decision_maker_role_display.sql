
update solidos_control.settings
set lead_generation_playbook_version=7,
    lead_generation_playbook_updated_at=now(),
    lead_generation_playbook=
      jsonb_set(
        jsonb_set(
          jsonb_set(
            coalesce(lead_generation_playbook,'{}'::jsonb),
            '{version}','7'::jsonb,true
          ),
          '{stability_audit_v5,known_good_runtime,sheet_sync}','25'::jsonb,true
        ),
        '{stability_audit_v5,known_good_runtime,revenue_crm_writer}','4'::jsonb,true
      )
      || jsonb_build_object(
        'decision_maker_display_v1',jsonb_build_object(
          'rule','Decision Maker name and Role / Title must be separate user-facing fields.',
          'name_policy','Show a Decision Maker name only when contact_resolution.decision_maker_known=true.',
          'role_policy','Show the verified decision_maker_role next to the verified person; never concatenate role text into the person name.',
          'core_tabs',jsonb_build_array('ACTION QUEUE','QUALIFIED 360','ALL LEADS','CONTACT GAPS','CONTACTS'),
          'revenue_tabs',jsonb_build_array('REVENUE DESK','BEST TARGETS'),
          'verified_examples',jsonb_build_array(
            'Marcus Kuhlmann — Founder',
            'Gayland Looney — Owner',
            'Dennis Porter — President',
            'Matt Campbell — Principal'
          ),
          'sheet_sync_version',25,
          'revenue_writer_version',4,
          'safety','Display-only enhancement; no scoring, qualification, source-routing, contact-extraction, or outreach behavior changed.'
        ),
        'future_chat_instruction','Start with solidos_control.future_chat_bootstrap(). Known-good display baseline includes Sheet Sync v25 and Revenue CRM Writer v4. Keep Decision Maker and Role / Title separate, and show names only when decision_maker_known=true.'
      ),
    updated_at=now()
where id=true;
