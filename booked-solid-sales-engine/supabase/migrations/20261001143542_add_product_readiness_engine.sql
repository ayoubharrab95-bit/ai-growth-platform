create or replace view commercial_intel.product_readiness
with (security_invoker=true)
as
with counts as (
 select p.id product_id,p.slug,p.name,p.plan_tier,p.status,p.max_records,
  count(pm.company_id) filter(where pm.eligible)::integer eligible,
  count(pm.company_id) filter(where pm.exportable)::integer exportable,
  count(pm.company_id) filter(where pm.eligible and not pm.exportable)::integer compliance_blocked,
  round(avg(pm.product_score) filter(where pm.eligible),2) avg_product_score
 from commercial_intel.products p
 left join commercial_intel.product_memberships pm on pm.product_id=p.id
 group by p.id,p.slug,p.name,p.plan_tier,p.status,p.max_records
), blocked_source_detail as (
 select p.id product_id,ca.source_first_seen source_slug,
  count(*)::integer blocked_records
 from commercial_intel.products p
 join commercial_intel.product_memberships pm on pm.product_id=p.id
 join commercial_intel.company_assets ca on ca.company_id=pm.company_id
 where pm.eligible and not pm.exportable
 group by p.id,ca.source_first_seen
), blocked_source_rollup as (
 select d.product_id,
  coalesce(jsonb_object_agg(d.source_slug,d.blocked_records order by d.blocked_records desc,d.source_slug),'{}'::jsonb) blocked_by_source
 from blocked_source_detail d group by d.product_id
)
select c.*,
 round(least(100::numeric,100.0*c.eligible/nullif(c.max_records,0)),2) inventory_coverage_score,
 round(case when c.eligible=0 then 0 else 100.0*c.exportable/c.eligible end,2) compliance_clearance_score,
 round(least(100::numeric,100.0*c.exportable/nullif(c.max_records,0)),2) export_fill_score,
 round(
  0.25*least(100::numeric,100.0*c.eligible/nullif(c.max_records,0))+
  0.50*case when c.eligible=0 then 0 else 100.0*c.exportable/c.eligible end+
  0.25*least(100::numeric,100.0*c.exportable/nullif(c.max_records,0)),2
 ) readiness_score,
 case
  when c.eligible=0 then 'ELIGIBILITY'
  when c.exportable=0 then 'RIGHTS_CLEARANCE'
  when (100.0*c.exportable/nullif(c.eligible,0))<50 then 'RIGHTS_CLEARANCE'
  when (100.0*c.eligible/nullif(c.max_records,0))<50 then 'INVENTORY_DEPTH'
  else 'PACKAGING_READY'
 end primary_bottleneck,
 coalesce(b.blocked_by_source,'{}'::jsonb) blocked_by_source
from counts c
left join blocked_source_rollup b on b.product_id=c.product_id;

create or replace function commercial_intel.product_readiness_snapshot()
returns jsonb
language sql
stable
security invoker
set search_path=''
as $function$
 select jsonb_build_object(
  'schema_version',1,'generated_at',now(),
  'products',coalesce(jsonb_agg(jsonb_build_object(
    'slug',pr.slug,'name',pr.name,'tier',pr.plan_tier,'status',pr.status,'max_records',pr.max_records,
    'eligible',pr.eligible,'exportable',pr.exportable,'compliance_blocked',pr.compliance_blocked,
    'avg_product_score',pr.avg_product_score,'inventory_coverage_score',pr.inventory_coverage_score,
    'compliance_clearance_score',pr.compliance_clearance_score,'export_fill_score',pr.export_fill_score,
    'readiness_score',pr.readiness_score,'primary_bottleneck',pr.primary_bottleneck,
    'blocked_by_source',pr.blocked_by_source
  ) order by pr.readiness_score desc,pr.slug),'[]'::jsonb)
 )
 from commercial_intel.product_readiness pr;
$function$;
