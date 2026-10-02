
insert into booked_solid.search_strategies(
  slug,trade,geography,intent,query_template,offer_hint,
  exploration_weight,performance_score,enabled,lifecycle_state,generation,metadata
)
values
('brain-roofing-estimator-capacity-v2','Roofing','US','buyer_signal',
 'roofing contractor {location} hiring estimator project estimator preconstruction',
 'custom_estimator',1.55,50,true,'testing',0,
 jsonb_build_object('brain_v2_canary',true,'created_by','strategy_brain_v2','offer_family','Custom Estimation Software','signal_family','estimator_capacity')),
('brain-roofing-quote-speed-v2','Roofing','US','estimation_pain',
 'roofing company {location} fast estimates same day quote proposal turnaround',
 'custom_estimator',1.50,50,true,'testing',0,
 jsonb_build_object('brain_v2_canary',true,'created_by','strategy_brain_v2','offer_family','Custom Estimation Software','signal_family','quote_speed')),
('brain-roofing-branch-ops-v2','Roofing','US','scale',
 'roofing company {location} multiple locations branches regional operations',
 'automation',1.45,50,true,'testing',0,
 jsonb_build_object('brain_v2_canary',true,'created_by','strategy_brain_v2','offer_family','Business Automation System','signal_family','multi_location')),

('brain-hvac-service-agreements-v2','HVAC','US','recurring_contracts',
 'HVAC contractor {location} maintenance agreements service plans commercial service',
 'automation',1.55,50,true,'testing',0,
 jsonb_build_object('brain_v2_canary',true,'created_by','strategy_brain_v2','offer_family','Business Automation System','signal_family','recurring_service')),
('brain-hvac-estimator-capacity-v2','HVAC','US','buyer_signal',
 'HVAC company {location} hiring estimator estimating manager preconstruction',
 'custom_estimator',1.55,50,true,'testing',0,
 jsonb_build_object('brain_v2_canary',true,'created_by','strategy_brain_v2','offer_family','Custom Estimation Software','signal_family','estimator_capacity')),
('brain-hvac-dispatch-workflow-v2','HVAC','US','workflow_complexity',
 'HVAC company {location} dispatch service calls estimates CRM workflow',
 'automation',1.45,50,true,'testing',0,
 jsonb_build_object('brain_v2_canary',true,'created_by','strategy_brain_v2','offer_family','Business Automation System','signal_family','workflow_complexity')),

('brain-plumbing-service-contracts-v2','Plumbing','US','recurring_contracts',
 'plumbing contractor {location} commercial service agreements maintenance contracts',
 'automation',1.50,50,true,'testing',0,
 jsonb_build_object('brain_v2_canary',true,'created_by','strategy_brain_v2','offer_family','Business Automation System','signal_family','recurring_service')),
('brain-plumbing-estimator-growth-v2','Plumbing','US','buyer_signal',
 'plumbing company {location} hiring estimator project estimator preconstruction',
 'custom_estimator',1.50,50,true,'testing',0,
 jsonb_build_object('brain_v2_canary',true,'created_by','strategy_brain_v2','offer_family','Custom Estimation Software','signal_family','estimator_capacity')),

('brain-electrical-service-contracts-v2','Electrical','US','recurring_contracts',
 'electrical contractor {location} service contracts maintenance agreements commercial service',
 'automation',1.50,50,true,'testing',0,
 jsonb_build_object('brain_v2_canary',true,'created_by','strategy_brain_v2','offer_family','Business Automation System','signal_family','recurring_service')),
('brain-electrical-estimator-growth-v2','Electrical','US','buyer_signal',
 'electrical contractor {location} hiring estimator preconstruction estimating manager',
 'custom_estimator',1.50,50,true,'testing',0,
 jsonb_build_object('brain_v2_canary',true,'created_by','strategy_brain_v2','offer_family','Custom Estimation Software','signal_family','estimator_capacity')),

('brain-gc-change-order-v2','General Contractor','US','change_orders',
 'general contractor {location} change order approvals estimating project workflow',
 'penmark',1.50,50,true,'testing',0,
 jsonb_build_object('brain_v2_canary',true,'created_by','strategy_brain_v2','offer_family','Business Automation System','signal_family','change_order_workflow')),
('brain-commercial-estimator-capacity-v2','Commercial Contractor','US','buyer_signal',
 'commercial contractor {location} hiring estimator preconstruction estimating manager',
 'custom_estimator',1.55,50,true,'testing',0,
 jsonb_build_object('brain_v2_canary',true,'created_by','strategy_brain_v2','offer_family','Custom Estimation Software','signal_family','estimator_capacity')),
('brain-property-ops-manual-workflow-v2','Property Operations','US','workflow_fragmentation',
 'property management company {location} spreadsheet manual workflow owner reporting maintenance',
 'automation',1.50,50,true,'testing',0,
 jsonb_build_object('brain_v2_canary',true,'created_by','strategy_brain_v2','offer_family','Business Automation System','signal_family','manual_workflow'))
on conflict(slug) do update set
  query_template=excluded.query_template,
  exploration_weight=excluded.exploration_weight,
  metadata=coalesce(booked_solid.search_strategies.metadata,'{}'::jsonb)||excluded.metadata,
  updated_at=now();

select solidos_control.refresh_strategy_brain_v2();
