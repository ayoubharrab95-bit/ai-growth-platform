import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const db = createClient(supabaseUrl, serviceKey);
const US_MARKETS=["Dallas TX","Houston TX","Austin TX","San Antonio TX","Miami FL","Tampa FL","Orlando FL","Jacksonville FL","Phoenix AZ","Atlanta GA","Charlotte NC","Raleigh NC","Nashville TN","Denver CO","Columbus OH","Cincinnati OH","Cleveland OH","Philadelphia PA","Pittsburgh PA","St. Louis MO","Kansas City MO","Richmond VA","Northern Virginia","Chicago IL","Indianapolis IN","New Jersey","San Francisco CA","Los Angeles CA","San Diego CA","Sacramento CA","Seattle WA","Portland OR","Las Vegas NV","Salt Lake City UT","Boston MA","New York NY","Milwaukee WI","Minneapolis MN","Detroit MI","Oklahoma City OK","Tulsa OK"];
const MARKET_COORDS:Record<string,[number,number]>={
"Dallas TX":[32.7767,-96.7970],"Houston TX":[29.7604,-95.3698],"Austin TX":[30.2672,-97.7431],"San Antonio TX":[29.4241,-98.4936],
"Miami FL":[25.7617,-80.1918],"Tampa FL":[27.9506,-82.4572],"Orlando FL":[28.5383,-81.3792],"Jacksonville FL":[30.3322,-81.6557],
"Phoenix AZ":[33.4484,-112.0740],"Atlanta GA":[33.7490,-84.3880],"Charlotte NC":[35.2271,-80.8431],"Raleigh NC":[35.7796,-78.6382],
"Nashville TN":[36.1627,-86.7816],"Denver CO":[39.7392,-104.9903],"Columbus OH":[39.9612,-82.9988],"Cincinnati OH":[39.1031,-84.5120],
"Cleveland OH":[41.4993,-81.6944],"Philadelphia PA":[39.9526,-75.1652],"Pittsburgh PA":[40.4406,-79.9959],"St. Louis MO":[38.6270,-90.1994],
"Kansas City MO":[39.0997,-94.5786],"Richmond VA":[37.5407,-77.4360],"Northern Virginia":[38.8816,-77.0910],"Chicago IL":[41.8781,-87.6298],
"Indianapolis IN":[39.7684,-86.1581],"New Jersey":[40.0583,-74.4057],"San Francisco CA":[37.7749,-122.4194],"Los Angeles CA":[34.0522,-118.2437],"San Diego CA":[32.7157,-117.1611],
"Sacramento CA":[38.5816,-121.4944],"Seattle WA":[47.6062,-122.3321],"Portland OR":[45.5152,-122.6784],"Las Vegas NV":[36.1699,-115.1398],
"Salt Lake City UT":[40.7608,-111.8910],"Boston MA":[42.3601,-71.0589],"New York NY":[40.7128,-74.0060],"Milwaukee WI":[43.0389,-87.9065],
"Minneapolis MN":[44.9778,-93.2650],"Detroit MI":[42.3314,-83.0458],"Oklahoma City OK":[35.4676,-97.5164],"Tulsa OK":[36.1540,-95.9928]
};
function hashText(s:string){let h=0;for(const ch of s)h=(h*31+ch.charCodeAt(0))>>>0;return h;}
function marketFor(s:any,marketRows:any[]=[]){
 if(s.geography&&s.geography!=="US")return s.geography;
 const live=(marketRows??[]).filter((m:any)=>["testing","active"].includes(String(m.lifecycle_state||"active"))&&Number.isFinite(Number(m.latitude))&&Number.isFinite(Number(m.longitude)));
 if(live.length){
   const ranked=[...live].sort((a:any,b:any)=>(Number(b.quality_score||50)+Number(b.exploration_weight||1)*8)-(Number(a.quality_score||50)+Number(a.exploration_weight||1)*8));
   const explore=(hashText(String(s.slug)+":"+String(s.uses_count??0))%100)<20;
   const pool=explore?live:ranked.slice(0,Math.max(8,Math.ceil(ranked.length*0.6)));
   const idx=(hashText(String(s.slug))+Number(s.uses_count??0))%pool.length;
   return pool[idx].display_name;
 }
 const idx=(hashText(String(s.slug))+Number(s.uses_count??0))%US_MARKETS.length;return US_MARKETS[idx];
}
function coordsFor(name:string,marketRows:any[]=[]){
 const m=(marketRows??[]).find((x:any)=>x.display_name===name);
 if(m&&Number.isFinite(Number(m.latitude))&&Number.isFinite(Number(m.longitude)))return [Number(m.latitude),Number(m.longitude)];
 return MARKET_COORDS[name]??[null,null];
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: cors });
}

async function chooseStrategies(limit = 50) {
  const { data, error } = await db
    .schema("booked_solid")
    .from("search_strategies")
    .select("*")
    .eq("enabled", true)
    .order("performance_score", { ascending: false })
    .limit(200);

  if (error) throw error;

  // 80/20 style rotation without hard-coding a single winner:
  // rank by a blend of proven performance, exploration weight, and staleness.
  const now = Date.now();
  const ranked = (data ?? []).map((s: any) => {
    const ageHours = s.last_used_at
      ? Math.max(0, (now - new Date(s.last_used_at).getTime()) / 3600000)
      : 9999;
    const freshnessBoost = Math.min(20, ageHours);
    const explorationBoost = Number(s.exploration_weight ?? 1) * 10;
    const score =
      Number(s.performance_score ?? 50) +
      explorationBoost +
      freshnessBoost -
      Math.min(20, Number(s.uses_count ?? 0) * 0.05);
    return { ...s, planner_score: score };
  }).sort((a: any, b: any) => b.planner_score - a.planner_score);

  return ranked.slice(0, limit);
}

async function queueOneEnrichment(){
  const [{data:leads},{data:activeResearch}] = await Promise.all([
    db.schema("booked_solid").from("leads")
      .select("id,company_id,strategy_id,score,status,companies!inner(id,enrichment_version,last_enriched_at)")
      .in("status",["qualified","candidate"])
      .order("score",{ascending:false})
      .limit(200),
    db.schema("booked_solid").from("work_queue")
      .select("payload")
      .eq("kind","research")
      .in("status",["pending","running"])
  ]);
  const active=new Set((activeResearch??[]).map((x:any)=>String(x.payload?.company_id||"")).filter(Boolean));
  const pool=(leads??[]).filter((x:any)=>Number(x.companies?.enrichment_version??0)<1&&!active.has(String(x.company_id)));
  const next=pool[0];if(!next)return null;
  const priority=next.status==="qualified"?45+Math.min(5,Number(next.score||0)*0.05):25+Math.min(5,Number(next.score||0)*0.03);
  const {data,error}=await db.schema("booked_solid").from("work_queue").insert({
    kind:"research",priority,
    payload:{company_id:next.company_id,strategy_id:next.strategy_id,reason:"incremental_enrichment_v1"},
    status:"pending",available_at:new Date().toISOString()
  }).select("id,priority,payload").single();
  if(error)throw error;
  return {job_id:data.id,company_id:next.company_id,lead_id:next.id,lead_status:next.status,priority};
}

async function planCycle(body: any) {
  const { data: settings } = await db.schema("booked_solid").from("runtime_settings").select("*").eq("id", true).single();
  if (!settings?.search_enabled) return json({ ok: true, paused: true, reason: "search_disabled", email_gate: "blocked_until_email_configuration" });
  const requestedLimit = 1;
  const ranked = await chooseStrategies(100);
  const { data: marketRows } = await db.schema("booked_solid").from("market_catalog").select("*").in("lifecycle_state",["testing","active"]);
  const { data: activeDiscover } = await db.schema("booked_solid").from("work_queue").select("payload,status").eq("kind","discover").in("status",["pending","running"]);
  const { data: recentDiscover } = await db.schema("booked_solid").from("work_queue")
    .select("payload,created_at")
    .eq("kind","discover")
    .order("created_at",{ascending:false})
    .limit(8);
  const activeIds = new Set((activeDiscover ?? []).map((x:any)=>x.payload?.strategy_id).filter(Boolean));

  // Diversity guard: preserve performance ranking, but prevent one trade from
  // monopolizing the rolling two-hour window (8 planner cycles at 15 minutes).
  // A trade can occupy up to 3 of the last 8 attempts; after that, temporarily
  // prefer the best available strategy from another trade. If no alternative
  // exists, fall back to the normal ranked pool so discovery never stalls.
  const recentTradeCounts = new Map<string,number>();
  for (const job of recentDiscover ?? []) {
    const trade=String(job.payload?.trade??"").trim();
    if(trade) recentTradeCounts.set(trade,(recentTradeCounts.get(trade)??0)+1);
  }
  const candidates = ranked.filter((s:any)=>!activeIds.has(s.id));
  const diversified = candidates.filter((s:any)=>(recentTradeCounts.get(String(s.trade??""))??0)<3);
  const selectionPool = diversified.length ? diversified : candidates;
  const diversificationApplied = Boolean(candidates.length && selectionPool.length && candidates[0]?.id!==selectionPool[0]?.id);
  const strategies = selectionPool.slice(0, requestedLimit).map((s:any)=>({...s,target_location:marketFor(s,marketRows??[])}));
  const { data: sources } = await db.schema("booked_solid").from("source_catalog").select("*").eq("enabled",true);
  const sourceBySlug=new Map((sources??[]).map((x:any)=>[x.slug,x]));
  const osmSource=sourceBySlug.get("openstreetmap_overpass");
  const wikidataSource=sourceBySlug.get("wikidata_sparql");
  const nrcaSource=sourceBySlug.get("nrca_official");
  const chicagoPermitSource=sourceBySlug.get("chicago_building_permits");
  const nycPermitSource=sourceBySlug.get("nyc_dob_permits");
  const austinPermitSource=sourceBySlug.get("austin_construction_permits");
  const seattlePermitSource=sourceBySlug.get("seattle_building_permits");
  const bostonPermitSource=sourceBySlug.get("boston_building_permits");
  const sfPermitSource=sourceBySlug.get("sf_building_permit_contacts");
  const philadelphiaPermitSource=sourceBySlug.get("philadelphia_permit_contractors");
  const philadelphiaTradeLicenseSource=sourceBySlug.get("philadelphia_trade_licenses");
  const denverPermitSource=sourceBySlug.get("denver_commercial_permits");
  const usaSpendingSource=sourceBySlug.get("usaspending_api");
  const autoActiveSources=(sources??[]).filter((x:any)=>["generic_socrata","generic_arcgis"].includes(String(x.metadata?.adapter||""))&&x.lifecycle_state==="active").sort((a:any,b:any)=>(Number(b.quality_score||50)+Number(b.exploration_weight||1)*8)-(Number(a.quality_score||50)+Number(a.exploration_weight||1)*8));
  const osmTrades=new Set(["Roofing","Commercial Roofing","HVAC","Commercial HVAC","Plumbing","Electrical","Painting","Flooring","Landscaping","General Contractor","Commercial Contractor","Construction","Windows","Deck Builder","Deck Patio","Cabinet","Remodeling","Bathroom Remodeling","Kitchen Remodeling","Kitchen Bath Remodeling","Home Builder","Custom Home Builder","Siding","Concrete","Mixed","Property Operations"]);
  if (!strategies.length || !osmSource) {
    return json({ ok: false, reason: "free_sources_not_available" }, 503);
  }
  const jobs = strategies.map((s: any) => {
    const useCount=Number(s.uses_count??0);
    let source:any=osmSource;
    if(autoActiveSources.length && useCount%10===8) source=autoActiveSources[(hashText(String(s.slug)+":"+useCount))%autoActiveSources.length];
    else if(String(s.trade)==="Property Operations" && wikidataSource && useCount%3===2) source=wikidataSource;
    else if(s.target_location==="Chicago IL" && chicagoPermitSource && useCount%4===2) source=chicagoPermitSource;
    else if(s.target_location==="New York NY" && nycPermitSource && useCount%4===2) source=nycPermitSource;
    else if(s.target_location==="Austin TX" && austinPermitSource && useCount%4===2) source=austinPermitSource;
    else if(s.target_location==="Seattle WA" && seattlePermitSource && useCount%4===2) source=seattlePermitSource;
    else if(s.target_location==="Boston MA" && bostonPermitSource && useCount%4===2) source=bostonPermitSource;
    else if(s.target_location==="San Francisco CA" && sfPermitSource && useCount%4===2) source=sfPermitSource;
    else if(s.target_location==="Philadelphia PA" && philadelphiaTradeLicenseSource && useCount%6===4) source=philadelphiaTradeLicenseSource;
    else if(s.target_location==="Philadelphia PA" && philadelphiaPermitSource && useCount%6===2) source=philadelphiaPermitSource;
    else if(s.target_location==="Denver CO" && denverPermitSource && useCount%4===2) source=denverPermitSource;
    else if(["Roofing","Commercial Roofing"].includes(String(s.trade)) && nrcaSource && useCount%8===7) source=nrcaSource;
    else if(String(s.trade)==="Mixed" && usaSpendingSource && useCount%6===5) source=usaSpendingSource;
    else if(!osmTrades.has(String(s.trade)) && usaSpendingSource) source=usaSpendingSource;
    const jobMarket=String(source?.metadata?.market_hint||source?.metadata?.market||s.target_location);
    const [jobLat,jobLon]=coordsFor(jobMarket,marketRows??[]);
    return {
    kind: "discover",
    priority: Math.max(1, Number(s.planner_score)),
    payload: {
      strategy_id: s.id,
      strategy_slug: s.slug,
      trade: s.trade,
      geography: jobMarket,
      intent: s.intent,
      query_template: s.query_template,
      source_id: source.id,
      source_slug: source.slug,
      latitude: jobLat,
      longitude: jobLon,
      offer_hint: s.offer_hint,
      evolution_source: Boolean(source?.metadata?.discovered_by==="self_evolution")
    },
    status: "pending",
    available_at: new Date().toISOString(),
  }});

  const { data: queued, error } = await db
    .schema("booked_solid")
    .from("work_queue")
    .insert(jobs)
    .select("id,kind,priority,payload");

  if (error) throw error;

  await Promise.all(strategies.map((s:any)=>db.schema("booked_solid").from("search_strategies").update({last_used_at:new Date().toISOString(),uses_count:Number(s.uses_count??0)+1,metadata:{...(s.metadata??{}),last_market:s.target_location}}).eq("id",s.id)));
  for(const j of queued??[]){
    const mn=String(j.payload?.geography||"");if(!mn)continue;
    const m=(marketRows??[]).find((x:any)=>x.display_name===mn);
    if(m)await db.schema("booked_solid").from("market_catalog").update({uses_count:Number(m.uses_count??0)+1,last_used_at:new Date().toISOString(),updated_at:new Date().toISOString()}).eq("id",m.id);
  }
  const enrichment=await queueOneEnrichment();

  return json({
    ok: true,
    mode: "planner",
    email_gate: "blocked_until_email_configuration",
    queued: queued?.length ?? 0,
    enrichment_queued: enrichment,
    discovery_preserved: true,
    enrichment_is_additive_not_a_gate: true,
    diversity: {
      recent_window_cycles: 8,
      max_attempts_per_trade: 3,
      recent_trade_counts: Object.fromEntries(recentTradeCounts),
      applied: diversificationApplied,
    },
    strategies: strategies.map((s: any) => ({
      id: s.id,
      slug: s.slug,
      trade: s.trade,
      intent: s.intent,
      query_template: s.query_template,
      offer_hint: s.offer_hint,
      planner_score: s.planner_score,
      market: s.target_location,
    })),
  });
}

async function health() {
  const [{ count: companies }, { count: leads }, { count: pending }, { count: blocked }, { count: phones }, { count: smsEligible }] =
    await Promise.all([
      db.schema("booked_solid").from("companies").select("*", { count: "exact", head: true }),
      db.schema("booked_solid").from("leads").select("*", { count: "exact", head: true }),
      db.schema("booked_solid").from("work_queue").select("*", { count: "exact", head: true }).eq("status", "pending"),
      db.schema("booked_solid").from("outreach_queue").select("*", { count: "exact", head: true }).eq("status", "blocked_email_not_configured"),
      db.schema("booked_solid").from("contacts").select("*", { count: "exact", head: true }).not("phone","is",null),
      db.schema("booked_solid").from("contacts").select("*", { count: "exact", head: true }).eq("sms_eligible",true),
    ]);

  return json({
    ok: true,
    system: "booked-solid-sales-engine",
    status: "ACTIVE",
    email_gate: "BLOCKED_NOT_CONFIGURED",
    sms_gate: "BLOCKED_CONSENT_AND_PROVIDER_REQUIRED",
    metrics: {
      companies: companies ?? 0,
      leads: leads ?? 0,
      pending_work: pending ?? 0,
      messages_blocked_by_email_gate: blocked ?? 0,
      phones_collected: phones ?? 0,
      sms_eligible_contacts: smsEligible ?? 0,
    },
    guarantees: {
      no_email_without_configuration: true,
      no_sms_without_configuration_and_consent: true,
      enrichment_never_reduces_discovery: true,
      no_maps_export_pipeline: true,
      evidence_required_for_personalization: true,
      suppression_list_supported: true,
      strategy_rotation_enabled: true,
    },
  });
}

Deno.serve(async (req: Request) => {
  try {
    if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
    const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
    const action = body.action ?? new URL(req.url).searchParams.get("action") ?? "health";

    if (action === "health") return await health();
    if (action === "plan") return await planCycle(body);

    return json({ ok: false, error: "unknown_action", allowed_actions: ["health", "plan"] }, 400);
  } catch (error) {
    console.error(error);
    return json({ ok: false, error: error instanceof Error ? error.message : JSON.stringify(error) }, 500);
  }
});
