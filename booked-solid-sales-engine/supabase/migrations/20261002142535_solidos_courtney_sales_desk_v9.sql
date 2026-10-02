
update solidos_control.settings
set lead_generation_playbook_version=9,
    lead_generation_playbook_updated_at=now(),
    lead_generation_playbook=
      jsonb_set(
        coalesce(lead_generation_playbook,'{}'::jsonb),
        '{version}','9'::jsonb,true
      )
      || jsonb_build_object(
        'courtney_sales_desk_v1',jsonb_build_object(
          'sheet_tab','START HERE — COURTNEY',
          'title','COURTNEY — SOLIDOS SALES DESK',
          'purpose','Courtney daily sales command page: live priorities plus the operating playbook.',
          'architecture','Formula-driven from existing synced tabs; no separate cron, no separate writer, and no additional recurring Google write load.',
          'live_sources',jsonb_build_array('COMMAND CENTER','ACTION QUEUE','REVENUE DESK','CONTACT GAPS'),
          'live_kpis',jsonb_build_array('ACT NOW','REVIEW','HOT','HIGH','NEEDS DECISION MAKER'),
          'priority_table','Top 10 HOT/HIGH prospects from ACTION QUEUE ordered by Opportunity, including Decision Maker, Role / Title, Email, Phone, Why Now, Offer and Action.',
          'refresh_behavior','Updates automatically whenever upstream SolidOS tabs refresh. Revenue readiness follows REVENUE DESK cadence; the daily worklist follows ACTION QUEUE/Core CRM cadence.',
          'stability_rule','Do not add a dedicated Courtney Sales Desk cron or writer unless formulas become insufficient. Preserve the current formula-driven architecture to avoid Google Sheets quota pressure.'
        ),
        'future_chat_instruction','Start with solidos_control.future_chat_bootstrap(). Courtney Sales Desk is the first tab (START HERE — COURTNEY) and is formula-driven from existing synced tabs. Do not add a separate writer/cron for it.'
      ),
    updated_at=now()
where id=true;
