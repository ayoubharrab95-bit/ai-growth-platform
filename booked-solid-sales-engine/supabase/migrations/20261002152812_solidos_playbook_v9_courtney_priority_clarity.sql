
update solidos_control.settings
set lead_generation_playbook_version=9,
    lead_generation_playbook_updated_at=now(),
    lead_generation_playbook=
      jsonb_set(
        coalesce(lead_generation_playbook,'{}'::jsonb),
        '{version}','9'::jsonb,true
      )
      || jsonb_build_object(
        'courtney_sales_desk_priority_v9',jsonb_build_object(
          'sheet','START HERE — COURTNEY',
          'rule','Priority Tier and Sales Readiness are distinct fields and must never be conflated.',
          'priority_tier','HOT / HIGH / SIGNAL / STANDARD = commercial strength and urgency tier.',
          'sales_readiness','ACT NOW / REVIEW / ENRICH / WATCH = what Courtney should do next based on revenue readiness.',
          'work_order','Work Sales Readiness first, then Priority Tier, then Opportunity, Why Now, Decision Maker/Role, route, Offer and Action.',
          'live_table_columns',jsonb_build_array(
            'Company','Priority Tier','Sales Readiness','Opportunity','Decision Maker','Role / Title','Email','Phone','Why Now','Offer','Action'
          ),
          'formatting','Priority Tier and Sales Readiness use value-driven conditional formatting so colors always follow live values rather than stale row formatting.',
          'update_model','The page updates through existing Core CRM Sheet Sync only; do not add a separate writer/cron.',
          'verified_example','HOT + ACT NOW is different from HIGH + REVIEW; both dimensions are shown separately.',
          'sheet_sync_platform_version',29
        ),
        'future_chat_instruction','Start with solidos_control.future_chat_bootstrap(). Preserve Courtney Sales Desk semantics: Priority Tier and Sales Readiness are separate, value-driven fields. Do not collapse them or create a second writer/cron for this page.'
      ),
    updated_at=now()
where id=true;
