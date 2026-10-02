CREATE OR REPLACE FUNCTION solidos_control.refresh_revenue_intelligence()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_run bigint;
  v_rows int:=0;
  v_act int:=0;
  v_review int:=0;
  v_enrich int:=0;
  v_watch int:=0;
  v_hh int:=0;
begin
  insert into solidos_control.revenue_intelligence_runs(metadata)
  values(jsonb_build_object('engine','Revenue Intelligence v1','cadence','hourly'))
  returning id into v_run;

  with lead_best as (
    select distinct on (l.company_id)
      l.company_id,l.id lead_id,l.status,l.priority_band,l.opportunity_score,l.trigger_score,
      l.offer,l.why_now,l.lead_brief,l.updated_at
    from booked_solid.leads l
    where l.status <> 'suppressed'
    order by l.company_id,
      case upper(coalesce(l.priority_band,'STANDARD'))
        when 'HOT' then 4 when 'HIGH' then 3 when 'SIGNAL' then 2 else 1 end desc,
      coalesce(l.opportunity_score,0) desc,
      l.updated_at desc
  ),
  signals as (
    select
      s.company_id,
      count(*) filter(where s.active)::int signal_count,
      round(coalesce(avg(s.avg_confidence) filter(where s.active),0),1) signal_confidence,
      coalesce(array_agg(distinct s.signal_type order by s.signal_type) filter(where s.active),'{}'::text[]) signal_types,
      max(s.last_observed_at) filter(where s.active) last_signal_at,
      count(*) filter(where s.active and s.signal_type ~* '(growth|hiring|expansion|location|permit|project|bid|estimate|proposal)')::int growth_ops_signals,
      count(*) filter(where s.active and s.signal_type ~* '(automation|workflow|process|operations|software|crm|manual|efficien)')::int automation_signals,
      count(*) filter(where s.active and s.signal_type ~* '(website|seo|marketing|digital|review|content|copy|brand)')::int website_signals,
      count(*) filter(where s.active and s.signal_type ~* '(estimate|estimating|bid|proposal|permit|project|construction)')::int estimation_signals
    from commercial_intel.business_signals s
    group by s.company_id
  ),
  memberships as (
    select
      pm.company_id,
      round(coalesce(max(pm.product_score) filter(where pm.eligible),0),1) product_score,
      coalesce(array_agg(distinct p.name order by p.name) filter(where pm.eligible),'{}'::text[]) product_matches,
      count(*) filter(where pm.eligible and (p.slug ~* 'automation' or p.name ~* 'automation'))::int automation_products,
      count(*) filter(where pm.eligible and (p.slug ~* 'growth' or p.name ~* 'growth'))::int growth_products,
      count(*) filter(where pm.eligible and (p.slug ~* 'agency|custom' or p.name ~* 'agency|custom'))::int strategy_products
    from commercial_intel.product_memberships pm
    join commercial_intel.products p on p.id=pm.product_id
    group by pm.company_id
  ),
  evidence as (
    select company_id,count(*)::int evidence_count,
           round(coalesce(avg(confidence),0),1) evidence_confidence,
           count(distinct evidence_type) filter(where evidence_type in ('seo_foundation_gap','website_conversion_gap'))::int website_evidence_signals,
           coalesce(array_agg(distinct evidence_type order by evidence_type)
             filter(where evidence_type in ('seo_foundation_gap','website_conversion_gap')),'{}'::text[]) website_evidence_types,
           round(coalesce(avg(confidence)
             filter(where evidence_type in ('seo_foundation_gap','website_conversion_gap')),0),1) website_evidence_confidence
    from booked_solid.evidence
    group by company_id
  ),
  base as (
    select
      c.id company_id,c.name company_name,c.trade,c.location_text,c.canonical_domain,c.website_url,
      c.source_first_seen,c.source_last_seen,
      lb.lead_id,lb.status lead_status,upper(coalesce(lb.priority_band,'STANDARD')) priority_band,
      coalesce(lb.opportunity_score,ca.opportunity_score,0)::numeric opportunity_score,
      coalesce(lb.trigger_score,0)::numeric trigger_score,
      coalesce(ca.commercial_score,0)::numeric commercial_score,
      coalesce(ca.freshness_score,0)::numeric freshness_score,
      coalesce(m.product_score,0)::numeric product_score,
      coalesce(m.product_matches,'{}'::text[]) product_matches,
      coalesce(s.signal_types,'{}'::text[]) || coalesce(e.website_evidence_types,'{}'::text[]) signal_types,
      coalesce(s.signal_count,0)+coalesce(e.website_evidence_signals,0) signal_count,
      greatest(coalesce(s.signal_confidence,0),coalesce(e.website_evidence_confidence,0))::numeric signal_confidence,
      coalesce(e.website_evidence_signals,0) website_evidence_signals,
      coalesce(s.growth_ops_signals,0) growth_ops_signals,
      coalesce(s.automation_signals,0) automation_signals,
      coalesce(s.website_signals,0) website_signals,
      coalesce(s.estimation_signals,0) estimation_signals,
      coalesce(m.automation_products,0) automation_products,
      coalesce(m.growth_products,0) growth_products,
      coalesce(m.strategy_products,0) strategy_products,
      coalesce(e.evidence_count,0) evidence_count,
      coalesce(lb.why_now,ca.why_now) existing_why_now,
      coalesce(lb.offer,ca.recommended_offer,c.recommended_offer) existing_offer,
      coalesce(lb.lead_brief->'contact_resolution'->>'state','') contact_route_state
    from booked_solid.companies c
    left join lead_best lb on lb.company_id=c.id
    left join commercial_intel.company_assets ca on ca.company_id=c.id
    left join signals s on s.company_id=c.id
    left join memberships m on m.company_id=c.id
    left join evidence e on e.company_id=c.id
    where c.status not in ('rejected','suppressed')
  ),
  scored as (
    select b.*,
      least(100,
        round(
          0.38*opportunity_score
          + 0.15*trigger_score
          + 0.18*commercial_score
          + 0.08*freshness_score
          + 0.09*product_score
          + 0.07*least(100,signal_confidence)
          + case priority_band when 'HOT' then 8 when 'HIGH' then 5 when 'SIGNAL' then 2 else 0 end
          + case when contact_route_state in ('ready','contact_form_available','phone_available','phone_ready') then 5 else 0 end
        ,1)
      ) target_score,
      least(100,round(
        0.45*opportunity_score + 0.15*commercial_score + 0.10*product_score
        + least(24,estimation_signals*8 + growth_ops_signals*3)
        + case when coalesce(existing_offer,'') ~* '(estimate|estimating|bid|proposal)' then 12 else 0 end
      ,1)) estimation_fit,
      least(100,round(
        0.40*opportunity_score + 0.18*commercial_score + 0.12*product_score
        + least(24,automation_signals*8 + automation_products*6 + growth_ops_signals*2)
        + case when coalesce(existing_offer,'') ~* '(automat|workflow|crm|software|system)' then 12 else 0 end
      ,1)) automation_fit,
      least(100,round(
        0.32*opportunity_score + 0.18*commercial_score + 0.10*freshness_score
        + least(34,website_signals*9 + website_evidence_signals*12 + strategy_products*3)
        + case when coalesce(existing_offer,'') ~* '(website|seo|copy|content|marketing)' then 15 else 0 end
      ,1)) website_fit
    from base b
  ),
  final_rows as (
    select s.*,
      case
        when automation_fit>=estimation_fit and automation_fit>=website_fit then 'Business Automation System'
        when estimation_fit>=website_fit then 'Custom Estimation Software'
        else 'Website / SEO / Copywriting'
      end best_offer,
      array_remove(array[
        case when canonical_domain is null then 'Website/domain unresolved' end,
        case when lead_id is null then 'Not yet promoted to lead' end,
        case when signal_count=0 then 'No active commercial trigger' end,
        case when contact_route_state='' then 'Contact route not resolved' end,
        case when evidence_count<2 then 'Needs more evidence' end
      ],null) missing_info,
      case
        when target_score>=80 and priority_band in ('HOT','HIGH')
          and contact_route_state in ('ready','contact_form_available','phone_available','phone_ready')
          and signal_count>0 then 'ACT NOW'
        when target_score>=70 and signal_count>0 then 'REVIEW'
        when target_score>=55 then 'ENRICH'
        else 'WATCH'
      end readiness
    from scored s
  )
  insert into solidos_control.revenue_intelligence_current(
    company_id,lead_id,company_name,trade,location_text,priority_band,target_score,readiness,
    best_offer,estimation_fit,automation_fit,website_fit,why_now,signal_types,signal_count,
    signal_confidence,product_matches,product_score,opportunity_score,trigger_score,
    commercial_score,freshness_score,contact_route_state,evidence_count,missing_info,
    next_action,source_summary,generated_at
  )
  select
    f.company_id,f.lead_id,f.company_name,f.trade,f.location_text,f.priority_band,f.target_score,f.readiness,
    f.best_offer,f.estimation_fit,f.automation_fit,f.website_fit,
    coalesce(nullif(f.existing_why_now,''),
      case
        when f.best_offer='Website / SEO / Copywriting' and f.website_evidence_signals>=2
          then 'Public website review detected both a conversion-path gap and an SEO-foundation gap in the sampled HTML.'
        when f.signal_count>0 then 'Current commercial signals: '||array_to_string(f.signal_types,', ')
        when f.product_score>0 then 'Strong fit detected across Commercial Intelligence products.'
        else 'No strong current trigger; monitor for a fresher signal.'
      end),
    f.signal_types,f.signal_count,f.signal_confidence,f.product_matches,f.product_score,
    f.opportunity_score,f.trigger_score,f.commercial_score,f.freshness_score,
    nullif(f.contact_route_state,''),f.evidence_count,f.missing_info,
    case f.readiness
      when 'ACT NOW' then 'Review the opportunity brief and prepare a tailored sales angle; automated sending remains OFF.'
      when 'REVIEW' then 'Review the strongest commercial signals and confirm the recommended offer before outreach.'
      when 'ENRICH' then 'Fill the missing information before treating this as an active sales target.'
      else 'Keep under hourly monitoring until stronger commercial intent appears.'
    end,
    concat_ws(' → ',nullif(f.source_first_seen,''),nullif(f.source_last_seen,'')),
    now()
  from final_rows f
  on conflict(company_id) do update set
    lead_id=excluded.lead_id,
    company_name=excluded.company_name,
    trade=excluded.trade,
    location_text=excluded.location_text,
    priority_band=excluded.priority_band,
    target_score=excluded.target_score,
    readiness=excluded.readiness,
    best_offer=excluded.best_offer,
    estimation_fit=excluded.estimation_fit,
    automation_fit=excluded.automation_fit,
    website_fit=excluded.website_fit,
    why_now=excluded.why_now,
    signal_types=excluded.signal_types,
    signal_count=excluded.signal_count,
    signal_confidence=excluded.signal_confidence,
    product_matches=excluded.product_matches,
    product_score=excluded.product_score,
    opportunity_score=excluded.opportunity_score,
    trigger_score=excluded.trigger_score,
    commercial_score=excluded.commercial_score,
    freshness_score=excluded.freshness_score,
    contact_route_state=excluded.contact_route_state,
    evidence_count=excluded.evidence_count,
    missing_info=excluded.missing_info,
    next_action=excluded.next_action,
    source_summary=excluded.source_summary,
    generated_at=excluded.generated_at;

  delete from solidos_control.revenue_intelligence_current r
  where not exists(select 1 from booked_solid.companies c where c.id=r.company_id);

  select count(*),
         count(*) filter(where readiness='ACT NOW'),
         count(*) filter(where readiness='REVIEW'),
         count(*) filter(where readiness='ENRICH'),
         count(*) filter(where readiness='WATCH'),
         count(*) filter(where priority_band in ('HOT','HIGH'))
  into v_rows,v_act,v_review,v_enrich,v_watch,v_hh
  from solidos_control.revenue_intelligence_current;

  update solidos_control.revenue_intelligence_runs
  set finished_at=now(),status='SUCCEEDED',rows_scored=v_rows,
      act_now_count=v_act,review_count=v_review,enrich_count=v_enrich,watch_count=v_watch,
      hot_high_count=v_hh,
      metadata=metadata||jsonb_build_object('completed_at',now())
  where id=v_run;

  return jsonb_build_object(
    'ok',true,'run_id',v_run,'rows_scored',v_rows,'act_now',v_act,'review',v_review,
    'enrich',v_enrich,'watch',v_watch,'hot_high',v_hh,'refreshed_at',now()
  );
exception when others then
  update solidos_control.revenue_intelligence_runs
  set finished_at=now(),status='FAILED',error=left(sqlerrm,1000)
  where id=v_run;
  raise;
end
$function$
