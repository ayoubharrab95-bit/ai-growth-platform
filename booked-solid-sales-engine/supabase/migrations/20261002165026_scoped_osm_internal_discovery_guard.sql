-- SolidOS OSM scoped internal discovery guard.
-- Production migration applied in Supabase as 20261002165026_scoped_osm_internal_discovery_guard.
-- Final verified state after canary: OSM remains REVIEW_REQUIRED / technical recovery only
-- because Edge Runtime returned overpass_http_0 after Worker v124; guards remain in place.

CREATE OR REPLACE FUNCTION commercial_intel.refresh_company_asset_one(p_company_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare v_count integer:=0;
begin
  with lead_best as (
    select distinct on (company_id)
      company_id, fit_score, opportunity_score, priority_band, offer, why_now, status
    from booked_solid.leads
    where company_id=p_company_id
    order by company_id, opportunity_score desc nulls last, updated_at desc
  ),
  contact_flags as (
    select company_id,
      bool_or(full_name is not null) as has_named_people,
      bool_or(email is not null and full_name is not null) as has_personal_email,
      bool_or(phone is not null and full_name is not null) as has_personal_phone
    from booked_solid.contacts
    where company_id=p_company_id
    group by company_id
  )
  insert into commercial_intel.company_assets(
    company_id,company_name,canonical_domain,website_url,trade,location_text,state,country,
    core_status,source_first_seen,source_last_seen,rights_status,commercial_status,
    commercial_score,fit_score,opportunity_score,priority_band,recommended_offer,why_now,
    freshness_score,last_core_update,last_evaluated_at,has_named_people,has_personal_email,
    has_personal_phone,safe_company_payload,restriction_reasons,metadata,updated_at
  )
  select
    c.id,c.name,c.canonical_domain,c.website_url,c.trade,c.location_text,c.state,c.country,
    c.status,c.source_first_seen,c.source_last_seen,
    coalesce(sr.rights_status,'REVIEW_REQUIRED'),
    case
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='ALLOWED'
        and coalesce((sr.metadata->>'commercial_resale_allowed')::boolean,true) then 'COMMERCIAL_SAFE'
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='ALLOWED' then 'INTERNAL_ONLY'
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='BLOCKED' then 'BLOCKED_FROM_RESALE'
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='INTERNAL_ONLY' then 'INTERNAL_ONLY'
      else 'REVIEW_REQUIRED'
    end,
    least(100,greatest(0,
      coalesce(lb.opportunity_score,0)*0.55+
      coalesce(lb.fit_score,c.fit_score,0)*0.35+
      case when c.website_url is not null then 5 else 0 end+
      case when c.state is not null then 5 else 0 end
    )),
    coalesce(lb.fit_score,c.fit_score),lb.opportunity_score,lb.priority_band,
    coalesce(lb.offer,c.recommended_offer),lb.why_now,
    greatest(0,100-extract(epoch from(now()-coalesce(c.updated_at,c.created_at)))/86400.0*2),
    c.updated_at,now(),
    coalesce(cf.has_named_people,false),coalesce(cf.has_personal_email,false),coalesce(cf.has_personal_phone,false),
    jsonb_strip_nulls(jsonb_build_object(
      'company_name',c.name,'canonical_domain',c.canonical_domain,'website_url',c.website_url,
      'trade',c.trade,'location_text',c.location_text,'state',c.state,'country',c.country,
      'commercial_score',round((least(100,greatest(0,
        coalesce(lb.opportunity_score,0)*0.55+
        coalesce(lb.fit_score,c.fit_score,0)*0.35+
        case when c.website_url is not null then 5 else 0 end+
        case when c.state is not null then 5 else 0 end
      )))::numeric,2),
      'opportunity_score',lb.opportunity_score,'priority_band',lb.priority_band,
      'recommended_offer',coalesce(lb.offer,c.recommended_offer)
    )),
    case
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='ALLOWED'
        and coalesce((sr.metadata->>'commercial_resale_allowed')::boolean,true) then '{}'::text[]
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='ALLOWED' then array['SOURCE_RESALE_NOT_APPROVED','SOURCE_ATTRIBUTION_REQUIRED']::text[]
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='BLOCKED' then array['SOURCE_BLOCKED']::text[]
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='INTERNAL_ONLY' then array['SOURCE_INTERNAL_ONLY']::text[]
      else array['SOURCE_RIGHTS_REVIEW_REQUIRED']::text[]
    end,
    jsonb_build_object(
      'core_lead_status',lb.status,
      'source_rights_id',sr.id,
      'core_enrichment_version',c.enrichment_version,
      'commercial_resale_allowed',coalesce((sr.metadata->>'commercial_resale_allowed')::boolean,true),
      'source_license',sr.license_text,
      'source_attribution',sr.provider
    ),
    now()
  from booked_solid.companies c
  left join lead_best lb on lb.company_id=c.id
  left join contact_flags cf on cf.company_id=c.id
  left join commercial_intel.source_rights sr on sr.source_slug=c.source_first_seen
  where c.id=p_company_id
  on conflict(company_id) do update set
    company_name=excluded.company_name,canonical_domain=excluded.canonical_domain,website_url=excluded.website_url,
    trade=excluded.trade,location_text=excluded.location_text,state=excluded.state,country=excluded.country,
    core_status=excluded.core_status,source_first_seen=excluded.source_first_seen,source_last_seen=excluded.source_last_seen,
    rights_status=excluded.rights_status,commercial_status=excluded.commercial_status,
    commercial_score=excluded.commercial_score,fit_score=excluded.fit_score,opportunity_score=excluded.opportunity_score,
    priority_band=excluded.priority_band,recommended_offer=excluded.recommended_offer,why_now=excluded.why_now,
    freshness_score=excluded.freshness_score,last_core_update=excluded.last_core_update,last_evaluated_at=excluded.last_evaluated_at,
    has_named_people=excluded.has_named_people,has_personal_email=excluded.has_personal_email,
    has_personal_phone=excluded.has_personal_phone,safe_company_payload=excluded.safe_company_payload,
    restriction_reasons=excluded.restriction_reasons,metadata=excluded.metadata,updated_at=now();
  get diagnostics v_count=row_count;
  return jsonb_build_object('company_id',p_company_id,'assets_upserted',v_count,'at',now());
end $function$;

CREATE OR REPLACE FUNCTION commercial_intel.refresh_company_assets()
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO ''
AS $function$
declare
  v_count integer;
begin
  with lead_best as (
    select distinct on (company_id)
      company_id, fit_score, opportunity_score, priority_band, offer, why_now, status
    from booked_solid.leads
    order by company_id, opportunity_score desc nulls last, updated_at desc
  ),
  contact_flags as (
    select company_id,
      bool_or(full_name is not null) as has_named_people,
      bool_or(email is not null and full_name is not null) as has_personal_email,
      bool_or(phone is not null and full_name is not null) as has_personal_phone
    from booked_solid.contacts
    group by company_id
  )
  insert into commercial_intel.company_assets(
    company_id,company_name,canonical_domain,website_url,trade,location_text,state,country,
    core_status,source_first_seen,source_last_seen,rights_status,commercial_status,
    commercial_score,fit_score,opportunity_score,priority_band,recommended_offer,why_now,
    freshness_score,last_core_update,last_evaluated_at,has_named_people,has_personal_email,
    has_personal_phone,safe_company_payload,restriction_reasons,metadata,updated_at
  )
  select
    c.id,c.name,c.canonical_domain,c.website_url,c.trade,c.location_text,c.state,c.country,
    c.status,c.source_first_seen,c.source_last_seen,
    coalesce(sr.rights_status,'REVIEW_REQUIRED'),
    case
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='ALLOWED'
        and coalesce((sr.metadata->>'commercial_resale_allowed')::boolean,true) then 'COMMERCIAL_SAFE'
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='ALLOWED' then 'INTERNAL_ONLY'
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='BLOCKED' then 'BLOCKED_FROM_RESALE'
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='INTERNAL_ONLY' then 'INTERNAL_ONLY'
      else 'REVIEW_REQUIRED'
    end,
    least(100,greatest(0,
      coalesce(lb.opportunity_score,0)*0.55 +
      coalesce(lb.fit_score,c.fit_score,0)*0.35 +
      case when c.website_url is not null then 5 else 0 end +
      case when c.state is not null then 5 else 0 end
    )),
    coalesce(lb.fit_score,c.fit_score),
    lb.opportunity_score,lb.priority_band,coalesce(lb.offer,c.recommended_offer),lb.why_now,
    greatest(0,100 - extract(epoch from (now()-coalesce(c.updated_at,c.created_at)))/86400.0 * 2),
    c.updated_at,now(),
    coalesce(cf.has_named_people,false),coalesce(cf.has_personal_email,false),coalesce(cf.has_personal_phone,false),
    jsonb_strip_nulls(jsonb_build_object(
      'company_name',c.name,
      'canonical_domain',c.canonical_domain,
      'website_url',c.website_url,
      'trade',c.trade,
      'location_text',c.location_text,
      'state',c.state,
      'country',c.country,
      'commercial_score',round((least(100,greatest(0,
        coalesce(lb.opportunity_score,0)*0.55 +
        coalesce(lb.fit_score,c.fit_score,0)*0.35 +
        case when c.website_url is not null then 5 else 0 end +
        case when c.state is not null then 5 else 0 end
      )))::numeric,2),
      'opportunity_score',lb.opportunity_score,
      'priority_band',lb.priority_band,
      'recommended_offer',coalesce(lb.offer,c.recommended_offer)
    )),
    case
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='ALLOWED'
        and coalesce((sr.metadata->>'commercial_resale_allowed')::boolean,true) then '{}'::text[]
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='ALLOWED' then array['SOURCE_RESALE_NOT_APPROVED','SOURCE_ATTRIBUTION_REQUIRED']::text[]
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='BLOCKED' then array['SOURCE_BLOCKED']::text[]
      when coalesce(sr.rights_status,'REVIEW_REQUIRED')='INTERNAL_ONLY' then array['SOURCE_INTERNAL_ONLY']::text[]
      else array['SOURCE_RIGHTS_REVIEW_REQUIRED']::text[]
    end,
    jsonb_build_object(
      'core_lead_status',lb.status,
      'source_rights_id',sr.id,
      'core_enrichment_version',c.enrichment_version,
      'commercial_resale_allowed',coalesce((sr.metadata->>'commercial_resale_allowed')::boolean,true),
      'source_license',sr.license_text,
      'source_attribution',sr.provider
    ),
    now()
  from booked_solid.companies c
  left join lead_best lb on lb.company_id=c.id
  left join contact_flags cf on cf.company_id=c.id
  left join commercial_intel.source_rights sr on sr.source_slug=c.source_first_seen
  on conflict (company_id) do update set
    company_name=excluded.company_name,
    canonical_domain=excluded.canonical_domain,
    website_url=excluded.website_url,
    trade=excluded.trade,
    location_text=excluded.location_text,
    state=excluded.state,
    country=excluded.country,
    core_status=excluded.core_status,
    source_first_seen=excluded.source_first_seen,
    source_last_seen=excluded.source_last_seen,
    rights_status=excluded.rights_status,
    commercial_status=excluded.commercial_status,
    commercial_score=excluded.commercial_score,
    fit_score=excluded.fit_score,
    opportunity_score=excluded.opportunity_score,
    priority_band=excluded.priority_band,
    recommended_offer=excluded.recommended_offer,
    why_now=excluded.why_now,
    freshness_score=excluded.freshness_score,
    last_core_update=excluded.last_core_update,
    last_evaluated_at=excluded.last_evaluated_at,
    has_named_people=excluded.has_named_people,
    has_personal_email=excluded.has_personal_email,
    has_personal_phone=excluded.has_personal_phone,
    safe_company_payload=excluded.safe_company_payload,
    restriction_reasons=excluded.restriction_reasons,
    metadata=excluded.metadata,
    updated_at=now();

  get diagnostics v_count = row_count;
  return jsonb_build_object('assets_upserted',v_count,'at',now());
end
$function$;

update commercial_intel.source_rights
set rights_status='REVIEW_REQUIRED',
    permitted_uses=array['company_facts','derived_signals','aggregate_intelligence','internal_discovery']::text[],
    prohibited_fields=array['person_name','personal_email','personal_phone','decision_maker_name','raw_contact_snippet','commercial_resale_export']::text[],
    review_reason='Scoped internal discovery guard is implemented, but production OSM canary is paused because Edge Runtime still returns overpass_http_0. Keep REVIEW_REQUIRED until a successful Edge probe verifies Overpass access.',
    metadata=coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
      'internal_discovery_guard_ready', true,
      'internal_discovery_allowed', true,
      'commercial_resale_allowed', false,
      'odbl_attribution_required', true,
      'odbl_notice_required', true,
      'odbl_share_alike_review_required_for_public_distribution', true,
      'source_use_scope', 'technical_recovery_until_edge_probe_succeeds',
      'production_canary_paused', true,
      'production_canary_pause_reason', 'edge_overpass_http_0_after_v124',
      'next_safe_step', 'run successful Edge probe before setting rights_status back to ALLOWED for canary'
    ),
    reviewed_at=now(),
    reviewed_by='ChatGPT OSM canary rollback after Edge overpass_http_0'
where source_slug='openstreetmap_overpass';

update booked_solid.source_catalog
set enabled=false,
    lifecycle_state='paused',
    metadata=coalesce(metadata,'{}'::jsonb) || jsonb_build_object(
      'state','technical_recovery_only',
      'recovery_rights_gate','REVIEW_REQUIRED',
      'recovery_production_enabled',false,
      'commercial_resale_allowed',false,
      'odbl_attribution_required',true,
      'recovery_preferred_endpoint','https://overpass-api.de/api/interpreter',
      'endpoints', jsonb_build_array('https://overpass-api.de/api/interpreter','https://overpass.private.coffee/api/interpreter','https://maps.mail.ru/osm/tools/overpass/api/interpreter'),
      'overpass_query_timeout_seconds',8,
      'http_timeout_ms',12000,
      'production_paused_at',now(),
      'production_pause_reason','edge_overpass_http_0_after_scoped_canary_v1',
      'next_safe_step','keep rights guard and worker OSM query fix; require successful Edge probe before re-enabling production canary'
    ),
    updated_at=now()
where slug='openstreetmap_overpass';

select solidos_control.refresh_source_recovery_v22();
