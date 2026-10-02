-- Guarded attribution repair. Preserves status, scores and source provenance.
-- Previous IDs are retained in lead_brief.strategy_attribution_correction_v1 for rollback.
with bad as (
select l.id,l.strategy_id,s.slug,s.trade as strategy_trade,c.trade as company_trade
from booked_solid.leads l join booked_solid.companies c on c.id=l.company_id
join booked_solid.search_strategies s on s.id=l.strategy_id
where lower(l.status) not in ('rejected','suppressed')
and not (coalesce(s.trade,'Mixed')='Mixed' or coalesce(c.trade,'')='' or s.trade=c.trade
or (s.trade in ('Roofing','Commercial Roofing') and c.trade='Roofing')
or (s.trade in ('HVAC','Commercial HVAC') and c.trade='HVAC')
or (s.trade in ('General Contractor','Commercial Contractor','Construction') and c.trade in ('General Contractor','Commercial Contractor','Construction','Remodeling')))
), fixed as (
update booked_solid.leads l set strategy_id=null,
lead_brief=coalesce(l.lead_brief,'{}'::jsonb)||jsonb_build_object('strategy_attribution_correction_v1',jsonb_build_object('previous_strategy_id',bad.strategy_id,'strategy_slug',bad.slug,'strategy_trade',bad.strategy_trade,'company_trade',bad.company_trade,'corrected_at',now()))
from bad where l.id=bad.id and l.strategy_id=bad.strategy_id
returning l.id,l.status,l.priority_band,l.opportunity_score)
select count(*) corrected,count(*) filter(where lower(status)='qualified') qualified_corrected from fixed;