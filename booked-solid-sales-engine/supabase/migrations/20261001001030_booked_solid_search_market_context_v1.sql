-- Booked Solid search-market attribution v1
-- IMPORTANT: search_market is search/planner context only.
-- It must never be used as authoritative company location.

with inferred as (
  select c.id,
         coalesce(
           (select m.display_name from booked_solid.market_catalog m
             where m.display_name = nullif(c.metadata->>'geography','') limit 1),
           (select m.display_name from booked_solid.market_catalog m
             where m.display_name = nullif(c.metadata->>'source_market','') limit 1),
           (select m.display_name from booked_solid.market_catalog m
             where coalesce(c.metadata->>'query','') ilike '%' || m.display_name || '%'
             order by length(m.display_name) desc limit 1)
         ) as search_market
  from booked_solid.companies c
  where coalesce(c.metadata->>'search_market','') = ''
)
update booked_solid.companies c
set metadata = coalesce(c.metadata,'{}'::jsonb) || jsonb_build_object(
      'search_market', i.search_market,
      'search_market_provenance', 'historical_search_context_v1',
      'search_market_backfilled_at', now()
    ),
    updated_at = now()
from inferred i
where c.id=i.id and i.search_market is not null;
