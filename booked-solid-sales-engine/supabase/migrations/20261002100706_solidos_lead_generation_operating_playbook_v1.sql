alter table solidos_control.settings
  add column if not exists lead_generation_playbook jsonb not null default '{}'::jsonb,
  add column if not exists lead_generation_playbook_version integer not null default 0,
  add column if not exists lead_generation_playbook_updated_at timestamptz,
  add column if not exists lead_generation_playbook_required boolean not null default true;

comment on column solidos_control.settings.lead_generation_playbook is
'Persistent SolidOS lead-generation operating doctrine. Agents/chats must read this before changing planner, source routing, qualification, or source recovery behavior.';

update solidos_control.settings
set lead_generation_playbook_version=1,
    lead_generation_playbook_updated_at=now(),
    lead_generation_playbook_required=true,
    lead_generation_playbook=jsonb_build_object(
      'name','SolidOS Lead Generation Operating Playbook',
      'version',1,
      'recorded_at',now(),
      'purpose','Preserve the highest-performing safe lead-generation behavior and prevent future chats/agents from reintroducing self-stalls or excessive rigidity.',
      'core_principle','Optimize for valid Leads, Qualified and HOT/HIGH yield with fast flow. Keep hard safety strict, but make routing, source mix, exploration and capacity adaptive instead of hard-stopping.',
      'proven_baseline',jsonb_build_object(
        'orchestrator_version',58,
        'worker_version',114,
        'reason','This baseline restored live lead flow after over-strict routing stopped discovery.',
        'observed_behavior','Phoenix/Mesa Building Permits and Washington L&I were the productive source families during the strongest observed lead-generation period.',
        'evidence_at_recording',jsonb_build_object(
          'phoenix_source_sample',52,
          'phoenix_valid_leads',14,
          'phoenix_qualified',5,
          'phoenix_hot_high',3,
          'best_hour_phoenix_companies',17,
          'best_hour_phoenix_leads',3,
          'best_hour_phoenix_qualified',3,
          'best_hour_phoenix_hot_high',2,
          'page_rotation_acceptance_new_companies_from_two_jobs',8,
          'page_rotation_acceptance_new_leads',4,
          'company_to_lead_minutes_about',2
        )
      ),
      'production_source_policy',jsonb_build_object(
        'rights_gate','Only ALLOWED sources may create production discovery jobs.',
        'review_required','REVIEW_REQUIRED/BLOCKED/INTERNAL_ONLY stay outside production discovery and may be used only for review/recovery/testing that cannot create production leads.',
        'champion_priority','Exploit should prefer the highest-value compatible Champion source/market pair, not the first routable pair.',
        'source_authority','Source Recovery v2.2 classification is newer than stale legacy source-brain/lifecycle labels. If rights=ALLOWED, recovery lane=champion, technical reliability is healthy, zero consecutive errors and no cooldown, do not let a stale legacy blocked/degraded label silently exclude the source.',
        'known_proven_sources',jsonb_build_array(
          jsonb_build_object('slug','auto-socrata-building-permits-dzpkhxfb','market','Phoenix AZ / Mesa','role','Champion exploit'),
          jsonb_build_object('slug','auto-socrata-l-i-intent-project-details-t9je9qwa','market','Washington / Seattle','role','Champion exploit')
        )
      ),
      'anti_stall_routing',jsonb_build_object(
        'rule','Never pre-truncate to the requested job count before source routing.',
        'method','Oversample high-quality strategy candidates, test safe source/market compatibility, then take the first requested number of routable jobs while preserving exploit/explore intent.',
        'fallback','If a top strategy has no compatible source, skip/reroute it and continue through more candidates. Do not return queued=0 while safe routable candidates still exist.',
        'diagnostic','If planner cron succeeds, pressure is zero, workers are healthy, but discovery stops, inspect routing_candidates, routable_candidates, source rights/lane precedence and stale source classification before tightening anything else.'
      ),
      'socrata_scan_policy',jsonb_build_object(
        'problem','Repeatedly reading the first Socrata page eventually returns duplicates and makes a productive source appear exhausted.',
        'rule','Use deterministic page rotation by source + trade + geography + strategy + time bucket so parallel jobs scan different safe pages.',
        'fallback','If an offset page is empty, safely fall back to page 0.',
        'goal','Continue harvesting deeper unique companies without increasing source pressure unsafely or creating a shared cursor race.'
      ),
      'flow_control',jsonb_build_object(
        'healthy_target','When pressure is healthy, planner target is 3 discovery jobs per planning cycle.',
        'adaptive_capacity','Always respect solidos_control.lane_capacity_plan(). Let downstream Resolve/Research/Qualify drain before forcing more Discovery when backlog rises.',
        'throttle','Throttle is protective and temporary; it must slow bursts, not permanently stop discovery.',
        'pg_net','If pg_net queue grows while no new responses arrive and the pg_net worker is active, use the official net.worker_restart() once, then inspect dispatch volume rather than repeatedly adding requests.'
      ),
      'quality_guards_to_keep',jsonb_build_array(
        'Reject website identity/geography mismatches.',
        'Keep contact parser protections against UI/page-fragment names.',
        'Do not attribute a lead to a strategy whose final company trade does not match.',
        'Do not preserve Qualified status merely because the lead was previously Qualified.',
        'Exclude suppressed/rejected leads from Source Yield.',
        'Keep duplicate, orphan, stale-running and source-rights checks.',
        'Do not enable email, SMS, buyer outreach, paid search or personal PII export unless explicitly approved.'
      ),
      'do_not_over_tighten',jsonb_build_array(
        'Do not add a hard gate merely because a metric is imperfect if the same gate can stop all discovery.',
        'Do not treat legacy degraded/blocked metadata as authoritative when a newer verified recovery layer says an ALLOWED Champion is technically healthy.',
        'Do not judge a source only by raw company volume; use company→valid Lead→Qualified→HOT/HIGH yield and conversion latency.',
        'Do not reduce exploration to zero; keep a controlled safe exploration share so new productive sources can emerge.',
        'Do not disable a historically productive source because one short window yields duplicates; inspect pagination/exhaustion first.'
      ),
      'metrics_future_agents_must_check',jsonb_build_array(
        'Companies/hour','Valid Leads/hour','Qualified/hour','HOT/HIGH changes',
        'company_to_lead latency','source sample→lead→qualified→hot/high yield',
        'routing_candidates and routable_candidates','due/running/stale/failed queues',
        'arrival_completion_ratio and throttle/pause','pg_net queue and response freshness',
        'duplicate and orphan counts','Core/Commercial/Revenue sheet freshness'
      ),
      'change_protocol',jsonb_build_object(
        'before_change','Read this playbook plus live system_snapshot(), pipeline pressure, Source Recovery, Source Lead Yield and recent hourly flow.',
        'during_change','Use small canary/adaptive changes. Preserve the proven baseline as rollback reference.',
        'after_change','Verify with live production evidence: new routable discovery jobs, new unique companies, downstream processing and valid Leads. A cron success alone is not proof.',
        'rollback_trigger','If Companies/Leads materially stop while pressure and workers are healthy, roll back the latest restrictive routing/source change or switch it to soft/adaptive behavior.'
      ),
      'future_chat_instruction','Before changing SolidOS lead generation, query solidos_control.lead_generation_playbook_snapshot(). Treat it as the default operating doctrine, then adapt only when newer live evidence clearly supports a better approach.'
    ),
    updated_at=now()
where id=true;

create or replace function solidos_control.lead_generation_playbook_snapshot()
returns jsonb
language sql
stable
set search_path to ''
as $$
  select jsonb_build_object(
    'system',system_name,
    'mode',mode,
    'required',lead_generation_playbook_required,
    'version',lead_generation_playbook_version,
    'updated_at',lead_generation_playbook_updated_at,
    'playbook',lead_generation_playbook
  )
  from solidos_control.settings
  where id=true;
$$;

revoke all on function solidos_control.lead_generation_playbook_snapshot() from public;
revoke all on function solidos_control.lead_generation_playbook_snapshot() from anon;
revoke all on function solidos_control.lead_generation_playbook_snapshot() from authenticated;
grant execute on function solidos_control.lead_generation_playbook_snapshot() to service_role;

comment on function solidos_control.lead_generation_playbook_snapshot() is
'AGENT START HERE before changing SolidOS planner/source/qualification behavior. Returns the persistent lead-generation operating doctrine and proven safe baseline.';

comment on function solidos_control.system_snapshot() is
'SolidOS live health snapshot. Before changing lead generation, agents must also call solidos_control.lead_generation_playbook_snapshot().';
