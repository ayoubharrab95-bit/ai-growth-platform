CREATE OR REPLACE FUNCTION solidos_control.strategy_brain_autopilot_metrics()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  s solidos_control.strategy_brain_autopilot_state%rowtype;
  v_pressure jsonb;
  v_perf jsonb;
  v_total_jobs int:=0;
  v_canary_jobs int:=0;
  v_legacy_jobs int:=0;
  v_total_leads int:=0;
  v_total_qualified int:=0;
  v_total_hot_high int:=0;
  v_canary_leads int:=0;
  v_canary_qualified int:=0;
  v_canary_hot_high int:=0;
  v_legacy_leads int:=0;
  v_legacy_qualified int:=0;
  v_legacy_hot_high int:=0;
  v_lead_rate numeric:=0;
  v_qualified_rate numeric:=0;
  v_hot_high_rate numeric:=0;
  v_canary_lead_rate numeric:=0;
  v_legacy_lead_rate numeric:=0;
  v_stale int:=0;
  v_active_dupe_groups int:=0;
  v_recent_failed int:=0;
  v_violations int:=0;
  v_deprioritized_selected int:=0;
  v_sla_watch int:=0;
  v_sla_warnings int:=0;
  v_sla_degraded int:=0;
  v_max_stage_oldest int:=0;
  v_sheet_failed_recent int:=0;
  v_core_sheet_age numeric:=999999;
  v_commercial_sheet_age numeric:=999999;
  v_critical_cron_failures int:=0;
begin
  select * into s from solidos_control.strategy_brain_autopilot_state where id=true;
  if not found then
    raise exception 'strategy_brain_autopilot_state_missing';
  end if;

  select public.solidos_pipeline_pressure() into v_pressure;
  select solidos_control.pipeline_performance_snapshot() into v_perf;

  select
    count(*)::int,
    count(*) filter(where w.payload->>'strategy_slug' like 'brain-%')::int,
    count(*) filter(where w.payload->>'strategy_slug' not like 'brain-%')::int,
    count(*) filter(
      where w.payload->>'priority_selection_mode'='exploit'
        and w.payload->>'brain_source_lane'='exploration'
    )::int,
    count(*) filter(where w.payload->>'brain_strategy_decision'='deprioritize')::int
  into v_total_jobs,v_canary_jobs,v_legacy_jobs,v_violations,v_deprioritized_selected
  from booked_solid.work_queue w
  where w.kind='discover'
    and coalesce(w.payload->>'brain_policy_version','0')='2'
    and w.created_at>=s.evaluation_since;

  select
    count(*)::int,
    count(*) filter(where l.status in ('qualified','message_ready','queued','sent','replied','meeting','won'))::int,
    count(*) filter(where upper(coalesce(l.priority_band,'')) in ('HOT','HIGH'))::int
  into v_total_leads,v_total_qualified,v_total_hot_high
  from booked_solid.leads l
  where l.created_at>=s.evaluation_since;

  select
    count(*)::int,
    count(*) filter(where l.status in ('qualified','message_ready','queued','sent','replied','meeting','won'))::int,
    count(*) filter(where upper(coalesce(l.priority_band,'')) in ('HOT','HIGH'))::int
  into v_canary_leads,v_canary_qualified,v_canary_hot_high
  from booked_solid.leads l
  join booked_solid.search_strategies st on st.id=l.strategy_id
  where l.created_at>=s.evaluation_since
    and coalesce((st.metadata->>'brain_v2_canary')::boolean,false);

  select
    count(*)::int,
    count(*) filter(where l.status in ('qualified','message_ready','queued','sent','replied','meeting','won'))::int,
    count(*) filter(where upper(coalesce(l.priority_band,'')) in ('HOT','HIGH'))::int
  into v_legacy_leads,v_legacy_qualified,v_legacy_hot_high
  from booked_solid.leads l
  left join booked_solid.search_strategies st on st.id=l.strategy_id
  where l.created_at>=s.evaluation_since
    and not coalesce((st.metadata->>'brain_v2_canary')::boolean,false);

  v_lead_rate:=round(v_total_leads::numeric/greatest(v_total_jobs,1),5);
  v_qualified_rate:=round(v_total_qualified::numeric/greatest(v_total_leads,1),5);
  v_hot_high_rate:=round(v_total_hot_high::numeric/greatest(v_total_leads,1),5);
  v_canary_lead_rate:=round(v_canary_leads::numeric/greatest(v_canary_jobs,1),5);
  v_legacy_lead_rate:=round(v_legacy_leads::numeric/greatest(v_legacy_jobs,1),5);

  select count(*)::int into v_stale
  from booked_solid.work_queue
  where status='running' and locked_at<now()-interval '5 minutes';

  select count(*)::int into v_active_dupe_groups
  from (
    select kind,payload->>'company_id'
    from booked_solid.work_queue
    where status in ('pending','running') and payload ? 'company_id'
    group by kind,payload->>'company_id'
    having count(*)>1
  ) d;

  select count(*)::int into v_recent_failed
  from booked_solid.work_queue
  where status='failed' and updated_at>now()-interval '60 minutes';

  select
    count(*) filter(where coalesce(x->>'sla_state','HEALTHY')='WATCH')::int,
    count(*) filter(where coalesce(x->>'sla_state','HEALTHY')='WARNING')::int,
    count(*) filter(where coalesce(x->>'sla_state','HEALTHY') in ('DEGRADED','CRITICAL'))::int,
    coalesce(max((x->>'oldest_due_seconds')::int),0)
  into v_sla_watch,v_sla_warnings,v_sla_degraded,v_max_stage_oldest
  from jsonb_array_elements(coalesce(v_perf->'stages','[]'::jsonb)) x;

  select count(*)::int into v_sheet_failed_recent
  from solidos_control.sheet_sync_requests
  where status='FAILED'
    and requested_at>now()-interval '30 minutes'
    and coalesce(last_error,'') not ilike 'stale_native_sync_superseded%';

  select coalesce(extract(epoch from now()-max(finished_at)),999999)
  into v_core_sheet_age
  from solidos_control.sheet_sync_requests
  where sync_scope='CORE_CRM' and status='SUCCEEDED';

  select coalesce(extract(epoch from now()-max(finished_at)),999999)
  into v_commercial_sheet_age
  from solidos_control.sheet_sync_requests
  where sync_scope='COMMERCIAL_PRODUCTS' and status='SUCCEEDED';

  select count(*)::int into v_critical_cron_failures
  from cron.job_run_details r
  join cron.job j on j.jobid=r.jobid
  where r.start_time>now()-interval '30 minutes'
    and r.status not in ('succeeded','running')
    and j.jobname in (
      'booked-solid-planner-2m',
      'solidos-worker-lanes-1m',
      'solidos-native-sheet-sync-1m',
      'solidos-stale-work-reaper-1m',
      'solidos-strategy-brain-v2-10m'
    );

  return jsonb_build_object(
    'at',now(),
    'evaluation_since',s.evaluation_since,
    'hold_until',s.hold_until,
    'sample',jsonb_build_object(
      'total_jobs',v_total_jobs,'canary_jobs',v_canary_jobs,'legacy_jobs',v_legacy_jobs,
      'total_leads',v_total_leads,'total_qualified',v_total_qualified,'total_hot_high',v_total_hot_high,
      'canary_leads',v_canary_leads,'canary_qualified',v_canary_qualified,'canary_hot_high',v_canary_hot_high,
      'legacy_leads',v_legacy_leads,'legacy_qualified',v_legacy_qualified,'legacy_hot_high',v_legacy_hot_high
    ),
    'rates',jsonb_build_object(
      'lead_per_discovery',v_lead_rate,
      'qualified_per_lead',v_qualified_rate,
      'hot_high_per_lead',v_hot_high_rate,
      'canary_lead_per_discovery',v_canary_lead_rate,
      'legacy_lead_per_discovery',v_legacy_lead_rate
    ),
    'health',jsonb_build_object(
      'stale_running',v_stale,
      'active_duplicate_groups',v_active_dupe_groups,
      'recent_failed_60m',v_recent_failed,
      'source_lane_violations',v_violations,
      'deprioritized_selected',v_deprioritized_selected,
      'sla_watch',v_sla_watch,
      'sla_warnings',v_sla_warnings,
      'sla_degraded',v_sla_degraded,
      'max_stage_oldest_seconds',v_max_stage_oldest,
      'pressure_pause',coalesce((v_pressure->>'pause')::boolean,false),
      'pressure_throttle',coalesce((v_pressure->>'throttle')::boolean,false),
      'arrival_completion_ratio',coalesce((v_pressure->>'arrival_completion_ratio')::numeric,0),
      'downstream_oldest_seconds',coalesce((v_pressure->>'downstream_oldest_seconds')::int,0),
      'due_now',coalesce((v_pressure->>'due_now')::int,0),
      'sheet_failed_30m',v_sheet_failed_recent,
      'core_sheet_age_seconds',round(v_core_sheet_age),
      'commercial_sheet_age_seconds',round(v_commercial_sheet_age),
      'critical_cron_failures_30m',v_critical_cron_failures
    ),
    'reference',s.reference_metrics
  );
end
$function$
;

CREATE OR REPLACE FUNCTION solidos_control.run_strategy_brain_autopilot()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  s solidos_control.strategy_brain_autopilot_state%rowtype;
  v_metrics jsonb;
  v_sample jsonb;
  v_rates jsonb;
  v_health jsonb;
  v_ref jsonb;
  v_current int;
  v_new int;
  v_next int;
  v_reasons text[]:='{}';
  v_decision text:='HOLD';
  v_hard_regression boolean:=false;
  v_soft_health_ok boolean:=true;
  v_sample_ready boolean:=false;
  v_no_degradation boolean:=false;
  v_improved boolean:=false;
  v_quality_regression boolean:=false;
  v_total_jobs int;
  v_canary_jobs int;
  v_total_leads int;
  v_canary_leads int;
  v_lead_rate numeric;
  v_qual_rate numeric;
  v_hh_rate numeric;
  v_ref_lead numeric;
  v_ref_qual numeric;
  v_ref_hh numeric;
begin
  if not pg_catalog.pg_try_advisory_xact_lock(pg_catalog.hashtext('solidos.strategy_brain_autopilot')) then
    return jsonb_build_object('ok',true,'decision','SKIP_LOCKED','at',now());
  end if;

  select * into s
  from solidos_control.strategy_brain_autopilot_state
  where id=true
  for update;

  if not found then
    raise exception 'strategy_brain_autopilot_state_missing';
  end if;

  select strategy_brain_canary_pct into v_current
  from booked_solid.runtime_settings
  where id=true;

  v_new:=v_current;

  if not s.enabled then
    v_decision:='DISABLED';
    v_reasons:=array['autopilot_disabled'];
  elsif not coalesce((select strategy_brain_enabled from booked_solid.runtime_settings where id=true),false) then
    v_decision:='HOLD';
    v_reasons:=array['strategy_brain_disabled'];
  else
    select solidos_control.strategy_brain_autopilot_metrics() into v_metrics;
    v_sample:=v_metrics->'sample';
    v_rates:=v_metrics->'rates';
    v_health:=v_metrics->'health';
    v_ref:=s.reference_metrics;

    v_total_jobs:=coalesce((v_sample->>'total_jobs')::int,0);
    v_canary_jobs:=coalesce((v_sample->>'canary_jobs')::int,0);
    v_total_leads:=coalesce((v_sample->>'total_leads')::int,0);
    v_canary_leads:=coalesce((v_sample->>'canary_leads')::int,0);
    v_lead_rate:=coalesce((v_rates->>'lead_per_discovery')::numeric,0);
    v_qual_rate:=coalesce((v_rates->>'qualified_per_lead')::numeric,0);
    v_hh_rate:=coalesce((v_rates->>'hot_high_per_lead')::numeric,0);
    v_ref_lead:=greatest(coalesce((v_ref->>'lead_per_discovery')::numeric,0.02874),0.0001);
    v_ref_qual:=greatest(coalesce((v_ref->>'qualified_per_lead')::numeric,0.2),0.0001);
    v_ref_hh:=greatest(coalesce((v_ref->>'hot_high_per_lead')::numeric,0.2),0.0001);

    v_hard_regression :=
      coalesce((v_health->>'stale_running')::int,0)>0
      or coalesce((v_health->>'active_duplicate_groups')::int,0)>0
      or coalesce((v_health->>'source_lane_violations')::int,0)>0
      or coalesce((v_health->>'sla_degraded')::int,0)>0
      or coalesce((v_health->>'recent_failed_60m')::int,0)>s.max_recent_failed
      or (
        coalesce((v_health->>'pressure_pause')::boolean,false)
        and coalesce((v_health->>'downstream_oldest_seconds')::int,0)>180
      )
      or (
        coalesce((v_health->>'arrival_completion_ratio')::numeric,0)>1.30
        and coalesce((v_health->>'downstream_oldest_seconds')::int,0)>180
      )
      or coalesce((v_health->>'due_now')::int,0)>20;

    v_sample_ready :=
      now()>=s.hold_until
      and now()-s.evaluation_since>=s.min_hold
      and v_total_jobs>=s.min_total_jobs
      and v_canary_jobs>=s.min_canary_jobs
      and v_total_leads>=s.min_total_leads
      and v_canary_leads>=s.min_canary_leads;

    if v_total_jobs>=s.min_total_jobs then
      v_quality_regression :=
        v_lead_rate < v_ref_lead*0.65
        or (v_total_leads>=5 and v_qual_rate < v_ref_qual*0.50)
        or (v_total_leads>=8 and v_hh_rate < v_ref_hh*0.40);
    end if;

    v_soft_health_ok :=
      not v_hard_regression
      and not coalesce((v_health->>'pressure_throttle')::boolean,false)
      and coalesce((v_health->>'sla_watch')::int,0)=0
      and coalesce((v_health->>'sla_warnings')::int,0)=0
      and coalesce((v_health->>'sheet_failed_30m')::int,0)=0
      and coalesce((v_health->>'core_sheet_age_seconds')::numeric,999999)<=600
      and coalesce((v_health->>'commercial_sheet_age_seconds')::numeric,999999)<=5400
      and coalesce((v_health->>'critical_cron_failures_30m')::int,0)=0
      and coalesce((v_health->>'arrival_completion_ratio')::numeric,0)<=s.max_arrival_ratio
      and coalesce((v_health->>'downstream_oldest_seconds')::int,0)<=s.max_downstream_oldest_seconds;

    v_no_degradation :=
      v_lead_rate>=v_ref_lead*0.90
      and (v_total_leads<5 or v_qual_rate>=v_ref_qual*0.75)
      and (v_total_leads<8 or v_hh_rate>=v_ref_hh*0.60);

    v_improved :=
      v_lead_rate>=v_ref_lead*1.08
      or (v_total_leads>=5 and v_qual_rate>=v_ref_qual*1.10)
      or (v_total_leads>=8 and v_hh_rate>=v_ref_hh*1.10);

    if v_hard_regression or v_quality_regression then
      if coalesce((v_health->>'stale_running')::int,0)>0 then v_reasons:=array_append(v_reasons,'stale_running'); end if;
      if coalesce((v_health->>'active_duplicate_groups')::int,0)>0 then v_reasons:=array_append(v_reasons,'active_duplicates'); end if;
      if coalesce((v_health->>'source_lane_violations')::int,0)>0 then v_reasons:=array_append(v_reasons,'source_lane_violation'); end if;
      if coalesce((v_health->>'sla_degraded')::int,0)>0 then v_reasons:=array_append(v_reasons,'sla_degraded'); end if;
      if coalesce((v_health->>'recent_failed_60m')::int,0)>s.max_recent_failed then v_reasons:=array_append(v_reasons,'recent_failures'); end if;
      if v_quality_regression then v_reasons:=array_append(v_reasons,'quality_regression'); end if;

      if v_current>s.stable_pct then
        v_new:=greatest(s.min_pct,s.stable_pct);
        update booked_solid.runtime_settings
        set strategy_brain_canary_pct=v_new,updated_at=now()
        where id=true;

        update solidos_control.strategy_brain_autopilot_state
        set evaluation_since=now(),hold_until=now()+rollback_hold,last_metrics=v_metrics,
            last_decision='ROLLBACK',last_reason=v_reasons,last_decision_at=now(),
            last_change_at=now(),last_rollback_at=now(),updated_at=now()
        where id=true;
        v_decision:='ROLLBACK';
      else
        v_decision:='HOLD_SAFETY';
      end if;

    elsif not v_soft_health_ok then
      v_decision:='HOLD_HEALTH';
      if coalesce((v_health->>'pressure_throttle')::boolean,false) then v_reasons:=array_append(v_reasons,'pipeline_throttle'); end if;
      if coalesce((v_health->>'sla_watch')::int,0)>0 then v_reasons:=array_append(v_reasons,'sla_watch'); end if;
      if coalesce((v_health->>'sla_warnings')::int,0)>0 then v_reasons:=array_append(v_reasons,'sla_warning'); end if;
      if coalesce((v_health->>'sheet_failed_30m')::int,0)>0 then v_reasons:=array_append(v_reasons,'sheet_failure'); end if;
      if coalesce((v_health->>'core_sheet_age_seconds')::numeric,999999)>600 then v_reasons:=array_append(v_reasons,'core_sheet_stale'); end if;
      if coalesce((v_health->>'commercial_sheet_age_seconds')::numeric,999999)>5400 then v_reasons:=array_append(v_reasons,'commercial_sheet_stale'); end if;
      if coalesce((v_health->>'critical_cron_failures_30m')::int,0)>0 then v_reasons:=array_append(v_reasons,'critical_cron_failure'); end if;
      if coalesce((v_health->>'arrival_completion_ratio')::numeric,0)>s.max_arrival_ratio then v_reasons:=array_append(v_reasons,'arrival_completion_ratio_high'); end if;
      if coalesce((v_health->>'downstream_oldest_seconds')::int,0)>s.max_downstream_oldest_seconds then v_reasons:=array_append(v_reasons,'downstream_age_high'); end if;

    elsif not v_sample_ready then
      v_decision:='HOLD_SAMPLE';
      if now()<s.hold_until or now()-s.evaluation_since<s.min_hold then v_reasons:=array_append(v_reasons,'minimum_hold_not_met'); end if;
      if v_total_jobs<s.min_total_jobs then v_reasons:=array_append(v_reasons,'total_jobs_below_minimum'); end if;
      if v_canary_jobs<s.min_canary_jobs then v_reasons:=array_append(v_reasons,'canary_jobs_below_minimum'); end if;
      if v_total_leads<s.min_total_leads then v_reasons:=array_append(v_reasons,'total_leads_below_minimum'); end if;
      if v_canary_leads<s.min_canary_leads then v_reasons:=array_append(v_reasons,'canary_leads_below_minimum'); end if;

    elsif not v_no_degradation then
      v_decision:='HOLD_QUALITY';
      v_reasons:=array['quality_not_yet_stable'];

    else
      if v_current>s.stable_pct then
        update solidos_control.strategy_brain_autopilot_state
        set stable_pct=v_current,reference_metrics=
          jsonb_build_object(
            'window_start',s.evaluation_since,'window_end',now(),
            'discover_jobs',v_total_jobs,'leads',v_total_leads,
            'qualified',coalesce((v_sample->>'total_qualified')::int,0),
            'hot_high',coalesce((v_sample->>'total_hot_high')::int,0),
            'lead_per_discovery',v_lead_rate,
            'qualified_per_lead',v_qual_rate,
            'hot_high_per_lead',v_hh_rate
          ),
          updated_at=now()
        where id=true;
        s.stable_pct:=v_current;
      end if;

      if v_improved and v_current<s.max_pct then
        select min(x) into v_next
        from unnest(s.ramp_steps) x
        where x>v_current and x<=s.max_pct;

        if v_next is not null then
          v_new:=v_next;
          update booked_solid.runtime_settings
          set strategy_brain_canary_pct=v_new,updated_at=now()
          where id=true;

          update solidos_control.strategy_brain_autopilot_state
          set evaluation_since=now(),hold_until=now()+min_hold,last_metrics=v_metrics,
              last_decision='RAMP',last_reason=array['quality_improved','health_clear','sample_sufficient'],
              last_decision_at=now(),last_change_at=now(),last_ramp_at=now(),updated_at=now()
          where id=true;
          v_decision:='RAMP';
          v_reasons:=array['quality_improved','health_clear','sample_sufficient'];
        end if;
      elsif v_current>=s.max_pct then
        v_decision:='HOLD_MAX';
        v_reasons:=array['maximum_safe_percentage_reached'];
        update solidos_control.strategy_brain_autopilot_state
        set evaluation_since=now(),hold_until=now()+min_hold,last_metrics=v_metrics,
            last_decision=v_decision,last_reason=v_reasons,last_decision_at=now(),updated_at=now()
        where id=true;
      else
        v_decision:='STABLE_NO_RAMP';
        v_reasons:=array['quality_stable_but_not_improved'];
        update solidos_control.strategy_brain_autopilot_state
        set evaluation_since=now(),hold_until=now()+min_hold,last_metrics=v_metrics,
            last_decision=v_decision,last_reason=v_reasons,last_decision_at=now(),updated_at=now()
        where id=true;
      end if;
    end if;

    if v_decision in ('HOLD_HEALTH','HOLD_SAMPLE','HOLD_QUALITY','HOLD_SAFETY') then
      update solidos_control.strategy_brain_autopilot_state
      set last_metrics=v_metrics,last_decision=v_decision,last_reason=v_reasons,
          last_decision_at=now(),updated_at=now()
      where id=true;
    end if;
  end if;

  insert into solidos_control.strategy_brain_autopilot_log(decision,old_pct,new_pct,stable_pct,reasons,metrics)
  select v_decision,v_current,v_new,stable_pct,v_reasons,coalesce(v_metrics,'{}'::jsonb)
  from solidos_control.strategy_brain_autopilot_state where id=true;

  return jsonb_build_object(
    'ok',true,'decision',v_decision,'old_pct',v_current,'new_pct',v_new,
    'stable_pct',(select stable_pct from solidos_control.strategy_brain_autopilot_state where id=true),
    'reasons',v_reasons,'metrics',coalesce(v_metrics,'{}'::jsonb),'at',now()
  );
end
$function$
;