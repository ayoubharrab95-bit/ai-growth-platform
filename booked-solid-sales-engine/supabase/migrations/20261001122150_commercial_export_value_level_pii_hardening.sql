insert into commercial_intel.field_catalog(field_key,display_name,category,sensitivity,default_export_status,description)
values('signal_summary','Signal Summary','intelligence','DERIVED_INTELLIGENCE','ALLOW',
       'PII-free summary generated only from approved business-level signal types')
on conflict(field_key) do update set
 display_name=excluded.display_name,category=excluded.category,sensitivity=excluded.sensitivity,
 default_export_status=excluded.default_export_status,description=excluded.description;

update commercial_intel.products
set export_field_keys =
  array(
    select case when x='why_now' then 'signal_summary' else x end
    from unnest(export_field_keys) x
  ),
  updated_at=now()
where 'why_now'=any(export_field_keys);

create or replace function commercial_intel.refresh_product_memberships()
returns jsonb
language plpgsql
security invoker
set search_path = commercial_intel, booked_solid, pg_catalog
as $$
declare
  v_count integer;
begin
  with signal_rollup as (
    select
      company_id,
      array_agg(signal_type order by signal_type) filter(where active) as signal_types,
      jsonb_object_agg(signal_type,evidence_count) filter(where active) as signal_counts,
      array(
        select distinct d
        from commercial_intel.business_signals b2,
             unnest(coalesce(b2.source_domains,'{}'::text[])) d
        where b2.company_id=bs.company_id and b2.active
        order by d
      ) as evidence_domains
    from commercial_intel.business_signals bs
    group by company_id
  ),
  x as (
    select
      p.id product_id,p.slug product_slug,p.plan_tier,p.max_records,p.selection_rules,
      a.*,
      coalesce(sr.signal_types,'{}'::text[]) signal_types,
      coalesce(sr.signal_counts,'{}'::jsonb) signal_counts,
      coalesce(sr.evidence_domains,'{}'::text[]) evidence_domains,
      case
        when p.slug='contractor-starter' then a.commercial_score>=55
        when p.slug='growth-signals' then coalesce(sr.signal_types,'{}'::text[]) && array['scale_signal','trigger_expansion','trigger_multi_location_growth','trigger_active_hiring']
        when p.slug='automation-opportunities' then coalesce(sr.signal_types,'{}'::text[]) && array['estimation_pain','workflow_complexity','trigger_manual_workflow','trigger_quote_speed','change_orders','field_quoting']
        when p.slug='agency-feed' then a.commercial_score>=50
        when p.slug='custom-icp' then true
        else false
      end as eligible_calc
    from commercial_intel.products p
    cross join commercial_intel.company_assets a
    left join signal_rollup sr on sr.company_id=a.company_id
    where p.status='active'
  )
  insert into commercial_intel.product_memberships(
    product_id,company_id,eligible,exportable,product_score,match_reasons,export_payload,evaluated_at
  )
  select
    x.product_id,x.company_id,
    x.eligible_calc,
    x.eligible_calc and x.commercial_status='COMMERCIAL_SAFE',
    least(100,greatest(0,
      x.commercial_score +
      case when cardinality(x.signal_types)>=3 then 8 when cardinality(x.signal_types)>=1 then 4 else 0 end
    )),
    array_remove(array[
      case when x.commercial_status='COMMERCIAL_SAFE' then 'COMPLIANCE_SAFE' else 'COMPLIANCE_NOT_CLEARED' end,
      case when x.commercial_score>=70 then 'HIGH_COMMERCIAL_SCORE' end,
      case when cardinality(x.signal_types)>0 then 'BUSINESS_SIGNALS_PRESENT' end,
      case when x.priority_band in ('hot','high','Hot','High') then 'CORE_HIGH_PRIORITY' end
    ],null),
    x.safe_company_payload ||
      jsonb_build_object(
        'signal_summary',
          case
            when cardinality(x.signal_types)>0
              then 'Observed business signals: ' || array_to_string(x.signal_types, ', ')
            else 'No approved business-level signal currently available'
          end,
        'business_signals',x.signal_counts,
        'evidence_domains',to_jsonb(x.evidence_domains),
        'commercial_status',x.commercial_status,
        'rights_status',x.rights_status,
        'freshness_score',round(x.freshness_score::numeric,2)
      ),
    now()
  from x
  on conflict(product_id,company_id) do update set
    eligible=excluded.eligible,
    exportable=excluded.exportable,
    product_score=excluded.product_score,
    match_reasons=excluded.match_reasons,
    export_payload=excluded.export_payload,
    evaluated_at=now();

  get diagnostics v_count = row_count;
  return jsonb_build_object('memberships_upserted',v_count,'at',now());
end
$$;
