create or replace function commercial_intel.ensure_source_rights_registry()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $function$
declare v_inserted integer:=0;
begin
  insert into commercial_intel.source_rights(
    source_slug,source_name,source_type,provider,rights_status,permitted_uses,
    prohibited_fields,personal_data_policy,review_reason,metadata
  )
  select distinct c.source_first_seen,c.source_first_seen,
    case when c.source_first_seen='tavily' then 'search_provider'
         when c.source_first_seen like 'auto-socrata-%' then 'open_data'
         when c.source_first_seen like 'auto-arcgis-%' then 'open_data'
         else 'unknown' end,
    case when c.source_first_seen='tavily' then 'Tavily'
         when c.source_first_seen like 'auto-socrata-%' then 'Socrata'
         when c.source_first_seen like 'auto-arcgis-%' then 'ArcGIS'
         else null end,
    'REVIEW_REQUIRED','{}'::text[],'{}'::text[],'NO_PERSONAL_PII',
    'Auto-registered from Booked Solid because this source is already present in company data. Commercial export remains blocked until an authoritative rights review is completed.',
    jsonb_build_object('auto_registered',true,'discovered_from','booked_solid.companies.source_first_seen','commercial_export_blocked_until_review',true)
  from booked_solid.companies c
  left join commercial_intel.source_rights sr on sr.source_slug=c.source_first_seen
  where c.source_first_seen is not null and btrim(c.source_first_seen)<>'' and sr.id is null
  on conflict(source_slug) do nothing;
  get diagnostics v_inserted=row_count;
  if v_inserted>0 then
    insert into commercial_intel.audit_log(actor,action,entity_type,reason,after_state)
    values('system','AUTO_REGISTER_SOURCE_RIGHTS','source_rights',
      'Fail-closed registration of Booked Solid sources missing from the commercial rights registry',
      jsonb_build_object('inserted',v_inserted,'rights_status','REVIEW_REQUIRED','at',now()));
  end if;
  return jsonb_build_object('inserted',v_inserted,'default_rights_status','REVIEW_REQUIRED','at',now());
end
$function$;

create or replace view commercial_intel.rights_impact
with (security_invoker=true)
as
with asset_rollup as (
  select ca.source_first_seen source_slug,
    count(*)::integer company_count,
    count(*) filter(where ca.commercial_status='REVIEW_REQUIRED')::integer review_company_count,
    count(*) filter(where ca.commercial_status='REVIEW_REQUIRED' and ca.commercial_score>=70)::integer high_value_review_companies,
    count(*) filter(where ca.commercial_status='REVIEW_REQUIRED' and ca.freshness_score>=70)::integer fresh_review_companies,
    round(avg(ca.commercial_score) filter(where ca.commercial_status='REVIEW_REQUIRED')::numeric,2) avg_review_commercial_score
  from commercial_intel.company_assets ca
  where ca.source_first_seen is not null
  group by ca.source_first_seen
), product_detail as (
  select ca.source_first_seen source_slug,p.slug product_slug,
    count(*) filter(where pm.eligible and not pm.exportable)::integer blocked_eligible_memberships
  from commercial_intel.company_assets ca
  join commercial_intel.product_memberships pm on pm.company_id=ca.company_id
  join commercial_intel.products p on p.id=pm.product_id
  where ca.source_first_seen is not null
  group by ca.source_first_seen,p.slug
), product_rollup as (
  select pd.source_slug,
    coalesce(sum(pd.blocked_eligible_memberships),0)::integer potential_exportable_memberships,
    count(*) filter(where pd.blocked_eligible_memberships>0)::integer affected_products,
    coalesce(jsonb_object_agg(pd.product_slug,pd.blocked_eligible_memberships order by pd.product_slug)
      filter(where pd.blocked_eligible_memberships>0),'{}'::jsonb) product_impact
  from product_detail pd group by pd.source_slug
), base as (
  select sr.id source_rights_id,sr.source_slug,coalesce(sr.source_name,sr.source_slug) source_name,
    sr.source_type,sr.provider,sr.rights_status,sr.public_url,sr.review_evidence_url,sr.license_text,
    sr.review_reason,sr.reviewed_at,sr.reviewed_by,
    coalesce(ar.company_count,0) company_count,coalesce(ar.review_company_count,0) review_company_count,
    coalesce(ar.high_value_review_companies,0) high_value_review_companies,
    coalesce(ar.fresh_review_companies,0) fresh_review_companies,ar.avg_review_commercial_score,
    coalesce(pr.potential_exportable_memberships,0) potential_exportable_memberships,
    coalesce(pr.affected_products,0) affected_products,coalesce(pr.product_impact,'{}'::jsonb) product_impact,
    (coalesce(ar.review_company_count,0)*10+coalesce(pr.potential_exportable_memberships,0)*5+
     coalesce(ar.high_value_review_companies,0)*3+coalesce(pr.affected_products,0)*10)::integer impact_score,
    ((case when sr.public_url is not null then 35 else 0 end)+
     (case when sr.review_evidence_url is not null then 30 else 0 end)+
     (case when sr.license_text is not null then 25 else 0 end)+
     (case when sr.provider is not null then 10 else 0 end))::integer review_readiness_score,
    coalesce((sr.metadata->>'auto_registered')::boolean,false) auto_registered
  from commercial_intel.source_rights sr
  left join asset_rollup ar on ar.source_slug=sr.source_slug
  left join product_rollup pr on pr.source_slug=sr.source_slug
)
select base.*,
 dense_rank() over(order by case when rights_status='REVIEW_REQUIRED' then 0 else 1 end,
 impact_score desc,review_readiness_score desc,source_slug)::integer priority_rank
from base;

create or replace function commercial_intel.rights_review_manifest(p_limit integer default 5)
returns jsonb
language sql
stable
security invoker
set search_path=''
as $function$
select jsonb_build_object(
 'schema_version',1,'generated_at',now(),
 'strict_compliance',coalesce((select s.strict_compliance from commercial_intel.settings s where s.id=true),true),
 'automatic_promotion',coalesce((select s.automatic_source_rights_promotion from commercial_intel.settings s where s.id=true),false),
 'candidate_count',count(*),
 'candidates',coalesce(jsonb_agg(to_jsonb(x) order by x.impact_score desc,x.review_readiness_score desc,x.source_slug),'[]'::jsonb)
)
from (
 select ri.priority_rank,ri.source_slug,ri.source_name,ri.source_type,ri.provider,ri.rights_status,
 ri.company_count,ri.review_company_count,ri.high_value_review_companies,ri.fresh_review_companies,
 ri.avg_review_commercial_score,ri.potential_exportable_memberships,ri.affected_products,
 ri.product_impact,ri.impact_score,ri.review_readiness_score,ri.public_url,ri.review_evidence_url,
 ri.review_reason,ri.auto_registered
 from commercial_intel.rights_impact ri
 where ri.rights_status='REVIEW_REQUIRED'
 and (ri.review_company_count>0 or ri.potential_exportable_memberships>0)
 order by ri.impact_score desc,ri.review_readiness_score desc,ri.source_slug
 limit least(greatest(coalesce(p_limit,5),1),20)
) x;
$function$;

create or replace function commercial_intel.refresh_layer()
returns jsonb
language plpgsql
security invoker
set search_path=''
as $function$
declare v_run uuid:=gen_random_uuid(); r jsonb; a jsonb; s jsonb; p jsonb;
begin
 insert into commercial_intel.agent_runs(id,agent_slug,run_type,status)
 values(v_run,'asset-agent','FULL_REFRESH','started');
 r:=commercial_intel.ensure_source_rights_registry();
 a:=commercial_intel.refresh_company_assets();
 s:=commercial_intel.refresh_business_signals();
 p:=commercial_intel.refresh_product_memberships();
 insert into commercial_intel.audit_log(actor,action,entity_type,reason,after_state)
 values('system','REFRESH_LAYER','commercial_intel',
   'Scheduled/read-only ingestion from Booked Solid core with fail-closed source-rights registration',
   jsonb_build_object('rights_registry',r,'assets',a,'signals',s,'memberships',p));
 update commercial_intel.agent_runs
 set status='succeeded',
   output_count=(select count(*) from commercial_intel.product_memberships where exportable),
   blocked_count=(select count(*) from commercial_intel.company_assets where commercial_status<>'COMMERCIAL_SAFE'),
   notes=jsonb_build_object('rights_registry',r,'assets',a,'signals',s,'memberships',p),finished_at=now()
 where id=v_run;
 return jsonb_build_object('run_id',v_run,'rights_registry',r,'assets',a,'signals',s,'memberships',p,
   'safe_assets',(select count(*) from commercial_intel.company_assets where commercial_status='COMMERCIAL_SAFE'),
   'review_assets',(select count(*) from commercial_intel.company_assets where commercial_status='REVIEW_REQUIRED'),
   'exportable_memberships',(select count(*) from commercial_intel.product_memberships where exportable),
   'buyer_outreach_enabled',(select buyer_outreach_enabled from commercial_intel.settings where id=true));
exception when others then
 update commercial_intel.agent_runs set status='failed',notes=jsonb_build_object('error',sqlerrm),finished_at=now() where id=v_run;
 raise;
end
$function$;
