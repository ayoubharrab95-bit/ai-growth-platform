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
function sourceCooling(s:any){
 const raw=s?.metadata?.cooldown_until;
 if(!raw)return false;
 const t=new Date(String(raw)).getTime();
 return Number.isFinite(t)&&t>Date.now();
}
function marketFor(s:any,marketRows:any[]=[],brainEnabled=false,brainPct=15){
 if(s.geography&&s.geography!=="US")return s.geography;
 const live=(marketRows??[]).filter((m:any)=>["testing","active"].includes(String(m.lifecycle_state||"active"))&&Number.isFinite(Number(m.latitude))&&Number.isFinite(Number(m.longitude)));
 if(live.length){
   const brainWeight=brainEnabled?Math.max(0,Math.min(0.50,Number(brainPct||15)/100)):0;
   const ranked=[...live].sort((a:any,b:any)=>{
     const rank=(x:any)=>{
       const legacy=Number(x.quality_score||50)+Number(x.exploration_weight||1)*7+Number(x.metadata?.priority_yield_score||25)*0.35;
       const brainScore=Number(x.metadata?.brain_v2?.score??legacy);
       const decision=String(x.metadata?.brain_v2?.decision??"test");
       const decisionAdj=decision==="exploit"?6:decision==="deprioritize"?-10:0;
       const brainRank=brainScore+decisionAdj;
       return legacy*(1-brainWeight)+brainRank*brainWeight;
     };
     return rank(b)-rank(a);
   });
   const explore=(hashText(String(s.slug)+":"+String(s.uses_count??0))%100)<30;
   const pool=explore?live:ranked.slice(0,Math.max(6,Math.ceil(ranked.length*0.5)));
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

async function chooseStrategies(limit = 50, brainEnabled=false, brainPct=15, balancedGrowthEnabled=false) {
  const { data, error } = await db
    .schema("booked_solid")
    .from("search_strategies")
    .select("*")
    .eq("enabled", true)
    .order("performance_score", { ascending: false })
    .limit(200);

  if (error) throw error;

  const now = Date.now();
  const brainWeight=brainEnabled?Math.max(0,Math.min(0.50,Number(brainPct||15)/100)):0;
  const ranked = (data ?? []).map((s: any) => {
    const ageHours = s.last_used_at
      ? Math.max(0, (now - new Date(s.last_used_at).getTime()) / 3600000)
      : 9999;
    const freshnessBoost = Math.min(18, ageHours);
    const explorationBoost = Number(s.exploration_weight ?? 1) * 8;
    const directYield = Number(s.metadata?.priority_yield?.score ?? 25);
    const tradeYield = Number(s.metadata?.trade_priority_yield_score ?? 25);
    const sample = Number(s.metadata?.priority_yield?.sample ?? 0);
    const confidence = Math.min(1, sample / 8);
    const yieldBoost =
      ((directYield - 25) * 0.35 * confidence) +
      ((tradeYield - 25) * 0.18);
    const legacyScore =
      Number(s.performance_score ?? 50) +
      explorationBoost +
      freshnessBoost +
      yieldBoost -
      Math.min(20, Number(s.uses_count ?? 0) * 0.05);

    const brain= s.metadata?.brain_v2 ?? {};
    const brainScore=Number(brain?.score ?? s.performance_score ?? 50);
    const brainDecision=String(brain?.decision ?? "test");
    const brainConfidence=Number(brain?.confidence ?? 0);
    const decisionAdjustment=brainDecision==="exploit"?8:brainDecision==="deprioritize"?-18:0;
    const brainPlannerScore=
      brainScore +
      freshnessBoost*0.35 +
      explorationBoost*0.35 +
      yieldBoost*0.25 +
      decisionAdjustment*brainConfidence -
      Math.min(12,Number(s.uses_count??0)*0.03);

    const balancedWeight=balancedGrowthEnabled?0.28:0;
    const portfolioScore=Number(s.metadata?.brain_v21?.portfolio_score??brainPlannerScore);
    const portfolioLane=String(s.metadata?.brain_v21?.lane??"");
    const laneAdjustment=portfolioLane==="champion"?10:portfolioLane==="exploit"?6:portfolioLane==="challenger"?3:portfolioLane==="explore"?-12:0;
    const portfolioPlannerScore=portfolioScore+laneAdjustment;
    const baseScore=legacyScore*(1-brainWeight)+brainPlannerScore*brainWeight;
    const score=baseScore*(1-balancedWeight)+portfolioPlannerScore*balancedWeight;
    return {
      ...s,
      planner_score: score,
      legacy_planner_score: legacyScore,
      brain_planner_score: brainPlannerScore,
      brain_score: brainScore,
      brain_decision: brainDecision,
      brain_confidence: brainConfidence,
      brain_canary:Boolean(s.metadata?.brain_v2_canary),
      portfolio_score:Number(s.metadata?.brain_v21?.portfolio_score??0),
      portfolio_lane:String(s.metadata?.brain_v21?.lane??""),
      portfolio_maturity:String(s.metadata?.brain_v21?.maturity??""),
      portfolio_weight:Number(s.metadata?.brain_v21?.allocation_weight??1),
      portfolio_target_share:Number(s.metadata?.brain_v21?.target_share??0),
      portfolio_expected_value:Number(s.metadata?.brain_v21?.expected_value_score??0),
      priority_yield_score: directYield,
      trade_priority_yield_score: tradeYield,
      priority_yield_sample: sample
    };
  }).sort((a: any, b: any) => b.planner_score - a.planner_score);

  return ranked.slice(0, limit);
}

async function queueOneEnrichment(){
  const [{data:leads},{data:activeResearch}] = await Promise.all([
    db.schema("booked_solid").from("leads")
      .select("id,company_id,strategy_id,score,status,companies!inner(id,enrichment_version,last_enriched_at,website_url,metadata)")
      .in("status",["qualified","candidate"])
      .order("score",{ascending:false})
      .limit(300),
    db.schema("booked_solid").from("work_queue")
      .select("payload")
      .eq("kind","research")
      .in("status",["pending","running"])
  ]);
  const active=new Set((activeResearch??[]).map((x:any)=>String(x.payload?.company_id||"")).filter(Boolean));
  const pool=(leads??[])
    .filter((x:any)=>Number(x.companies?.enrichment_version??0)<2&&Boolean(x.companies?.website_url)&&!active.has(String(x.company_id)))
    .sort((a:any,b:any)=>{
      const rank=(x:any)=>{
        const s=Number(x.score||0);
        if(x.status==="candidate"&&s>=50&&s<65)return 300+s; // conversion frontier first
        if(x.status==="qualified")return 200+s;              // improve decision-maker/message quality next
        return 100+s;
      };
      return rank(b)-rank(a);
    });
  const next=pool[0];if(!next)return null;
  const score=Number(next.score||0);
  const priority=next.status==="candidate"&&score>=50&&score<65
    ?58+Math.min(7,score*0.10)
    :next.status==="qualified"
      ?52+Math.min(6,score*0.07)
      :35+Math.min(5,score*0.05);
  const {data,error}=await db.schema("booked_solid").from("work_queue").insert({
    kind:"research",priority,
    payload:{company_id:next.company_id,strategy_id:next.strategy_id,reason:"website_intelligence_v2_incremental"},
    status:"pending",available_at:new Date().toISOString()
  }).select("id,priority,payload").single();
  if(error)throw error;
  return {job_id:data.id,company_id:next.company_id,lead_id:next.id,lead_status:next.status,lead_score:score,priority,enrichment_target_version:2};
}

async function queueContactIntelligenceV2(limit=2){
  const {data:leads}=await db.schema("booked_solid").from("leads")
    .select("id,company_id,score,priority_band,lead_brief,companies!inner(id,website_url,metadata)")
    .eq("status","qualified")
    .order("score",{ascending:false})
    .limit(200);
  const rank=(x:any)=>{
    const band=String(x.priority_band||"standard");
    const b=band==="hot"?400:band==="high"?300:band==="signal"?200:100;
    const state=String(x.lead_brief?.contact_resolution?.state||"contact_required");
    const gap=["contact_required","weak_only","phone_available","contact_form_available"].includes(state)?50:0;
    return b+gap+Number(x.score||0);
  };
  const pool=(leads??[])
    .filter((x:any)=>Boolean(x.companies?.website_url)&&Number(x.companies?.metadata?.contact_intelligence_version||0)<2)
    .sort((a:any,b:any)=>rank(b)-rank(a))
    .slice(0,Math.max(1,limit));
  const queued:any[]=[];
  for(const lead of pool){
    const priority=70+Math.min(20,Number(lead.score||0)*0.15);
    const {data:existing}=await db.schema("booked_solid").from("work_queue")
      .select("id,payload,priority,available_at")
      .eq("kind","contact").eq("status","pending")
      .contains("payload",{lead_id:lead.id})
      .order("created_at",{ascending:false}).limit(1);
    if((existing??[]).length){
      const row=existing![0];
      const payload={...(row.payload??{}),lead_id:lead.id,company_id:lead.company_id,reason:"contact_intelligence_v2_backfill",force_contact_intelligence_v2:true};
      const {data:u}=await db.schema("booked_solid").from("work_queue")
        .update({priority,available_at:new Date().toISOString(),payload,updated_at:new Date().toISOString()})
        .eq("id",row.id).select("id,priority,payload").single();
      if(u)queued.push({job_id:u.id,lead_id:lead.id,company_id:lead.company_id,accelerated_existing:true,priority});
    }else{
      const {data:i,error}=await db.schema("booked_solid").from("work_queue").insert({
        kind:"contact",priority,payload:{lead_id:lead.id,company_id:lead.company_id,contact_retry:0,reason:"contact_intelligence_v2_backfill",force_contact_intelligence_v2:true},
        status:"pending",available_at:new Date().toISOString()
      }).select("id,priority,payload").single();
      if(error)throw error;
      if(i)queued.push({job_id:i.id,lead_id:lead.id,company_id:lead.company_id,accelerated_existing:false,priority});
    }
  }
  return queued;
}

async function planCycle(body: any) {
  const { data: settings } = await db.schema("booked_solid").from("runtime_settings").select("*").eq("id", true).single();
  if (!settings?.search_enabled) return json({ ok: true, paused: true, reason: "search_disabled", email_gate: "blocked_until_email_configuration" });
  const brainEnabled=Boolean(settings?.strategy_brain_enabled);
  const brainCanaryPct=Math.max(0,Math.min(80,Number(settings?.strategy_brain_canary_pct??15)));
  const balancedGrowthEnabled=Boolean(settings?.balanced_growth_enabled);
  const balancedGrowthPolicy=Number(settings?.balanced_growth_policy_version??21);
  const requestedCap=Math.max(1,Math.min(6,Number(body.limit||3)));
  const [{count:dueWork},{count:runningWork},{count:resolveBacklog},{data:osmPressureSource}]=await Promise.all([
    db.schema("booked_solid").from("work_queue")
      .select("*",{count:"exact",head:true}).eq("status","pending").lte("available_at",new Date().toISOString()),
    db.schema("booked_solid").from("work_queue")
      .select("*",{count:"exact",head:true}).eq("status","running"),
    db.schema("booked_solid").from("work_queue")
      .select("*",{count:"exact",head:true}).eq("kind","resolve").in("status",["pending","running"]),
    db.schema("booked_solid").from("source_catalog")
      .select("metadata,lifecycle_state,enabled").eq("slug","openstreetmap_overpass").maybeSingle()
  ]);
  const dueNow=Number(dueWork||0);
  const runningNow=Number(runningWork||0);
  const resolveNow=Number(resolveBacklog||0);
  const osmCooldownRaw=String(osmPressureSource?.metadata?.cooldown_until||"");
  const osmCooldownMs=osmCooldownRaw?new Date(osmCooldownRaw).getTime():0;
  const osmCooling=Number.isFinite(osmCooldownMs)&&osmCooldownMs>Date.now();
  const {data:pipelinePressure,error:pressureErr}=await db.rpc("solidos_pipeline_pressure");
  const pc=(!pressureErr&&pipelinePressure)?pipelinePressure:{};
  const adaptivePause=Boolean(pc?.pause);
  const pressureReason=adaptivePause
    ?"adaptive_pipeline_pressure"
    :(dueNow>60||runningNow>20
      ?"pipeline_backpressure"
      :resolveNow>250
        ?(osmCooling?"resolve_backlog_source_cooling":"resolve_backlog")
        :null);
  if(pressureReason){
    return json({
      ok:true,
      mode:"planner",
      queued:0,
      paused:true,
      reason:pressureReason,
      backpressure:{
        due_now:dueNow,
        running:runningNow,
        resolve_backlog:resolveNow,
        discovery_due:Number(pc?.discovery_due||0),
        downstream_due:Number(pc?.downstream_due||0),
        downstream_oldest_seconds:Number(pc?.downstream_oldest_seconds||0),
        arrivals_15m:Number(pc?.arrivals_15m||0),
        completed_15m:Number(pc?.completed_15m||0),
        arrival_completion_ratio:Number(pc?.arrival_completion_ratio||0),
        stale_running:Number(pc?.stale_running||0),
        osm_cooling:osmCooling,
        osm_cooldown_until:osmCooldownRaw||null,
        resume_when:"adaptive pressure clears; no stale workers; downstream queue within SLA"
      },
      email_gate:"blocked_until_email_configuration",
      discovery_preserved:true
    },200);
  }
  const recommended=Number(pc?.recommended_limit);
  const adaptiveLimit=Number.isFinite(recommended)&&recommended>0?recommended:(dueNow>30?1:dueNow>15?2:requestedCap);
  const requestedLimit=Math.max(1,Math.min(requestedCap,adaptiveLimit));
  const ranked = await chooseStrategies(100,brainEnabled,brainCanaryPct,balancedGrowthEnabled);
  const { data: marketRows } = await db.schema("booked_solid").from("market_catalog").select("*").in("lifecycle_state",["testing","active"]);
  const { data: activeDiscover } = await db.schema("booked_solid").from("work_queue").select("payload,status").eq("kind","discover").in("status",["pending","running"]);
  const { data: recentDiscover } = await db.schema("booked_solid").from("work_queue")
    .select("payload,created_at")
    .eq("kind","discover")
    .order("created_at",{ascending:false})
    .limit(30);
  const recentDiversity=(recentDiscover??[]).slice(0,8);
  const activeIds = new Set((activeDiscover ?? []).map((x:any)=>x.payload?.strategy_id).filter(Boolean));

  // Diversity guard: preserve performance ranking, but prevent one trade from
  // monopolizing the rolling two-hour window (8 planner cycles at 15 minutes).
  // A trade can occupy up to 3 of the last 8 attempts; after that, temporarily
  // prefer the best available strategy from another trade. If no alternative
  // exists, fall back to the normal ranked pool so discovery never stalls.
  const recentTradeCounts = new Map<string,number>();
  for (const job of recentDiversity ?? []) {
    const trade=String(job.payload?.trade??"").trim();
    if(trade) recentTradeCounts.set(trade,(recentTradeCounts.get(trade)??0)+1);
  }
  const candidates = ranked.filter((s:any)=>!activeIds.has(s.id));
  const diversified = candidates.filter((s:any)=>(recentTradeCounts.get(String(s.trade??""))??0)<3);
  const selectionPool = diversified.length ? diversified : candidates;
  const diversificationApplied = Boolean(candidates.length && selectionPool.length && candidates[0]?.id!==selectionPool[0]?.id);

  // Balanced Growth v2.1 portfolio allocation.
  // Exploration stays alive, but varies between 20-30% based on available capacity.
  const recentModes=(recentDiscover??[])
    .map((x:any)=>String(x.payload?.priority_selection_mode||""))
    .filter((x:string)=>x==="exploit"||x==="explore");
  const recentExplore=recentModes.filter((x:string)=>x==="explore").length;
  const recentStrategyCounts=new Map<string,number>();
  const recentSourceCounts=new Map<string,number>();
  for(const job of recentDiscover??[]){
    const id=String(job.payload?.strategy_id||"");
    if(id)recentStrategyCounts.set(id,(recentStrategyCounts.get(id)??0)+1);
    const sourceSlug=String(job.payload?.source_slug||"");
    if(sourceSlug)recentSourceCounts.set(sourceSlug,(recentSourceCounts.get(sourceSlug)??0)+1);
  }

  const arrivalRatio=Number(pc?.arrival_completion_ratio||0);
  const downstreamDue=Number(pc?.downstream_due||0);
  const discoveryDue=Number(pc?.discovery_due||0);
  let explorationPct=0.25;
  if(Boolean(pc?.throttle)||arrivalRatio>1.08||downstreamDue>2||discoveryDue>4)explorationPct=0.20;
  else if(!Boolean(pc?.throttle)&&downstreamDue===0&&arrivalRatio<=0.98&&discoveryDue<=1)explorationPct=0.30;

  const projectedTotal=recentModes.length+requestedLimit;
  const targetExplore=Math.round(projectedTotal*explorationPct);
  const exploreN=Math.max(0,Math.min(requestedLimit,targetExplore-recentExplore));
  const exploitN=Math.max(0,requestedLimit-exploreN);

  const portfolioRank=(x:any,pool:any[])=>{
    if(!balancedGrowthEnabled)return Number(x.planner_score||0);
    const weight=Math.max(0.1,Number(x.portfolio_weight||1));
    const totalWeight=Math.max(0.1,pool.reduce((a:number,v:any)=>a+Math.max(0.1,Number(v.portfolio_weight||1)),0));
    const targetRecent=Math.max(0.5,(recentDiscover?.length||30)*(weight/totalWeight));
    const actual=Number(recentStrategyCounts.get(String(x.id))||0);
    const deficit=targetRecent-actual;
    const lane=String(x.portfolio_lane||"");
    const laneBoost=lane==="champion"?12:lane==="exploit"?8:lane==="challenger"?4:lane==="explore"?-10:0;
    return Number(x.planner_score||0)+deficit*9+laneBoost+Number(x.portfolio_expected_value||0)*0.08;
  };

  const exploitPool=selectionPool
    .filter((x:any)=>!x.brain_canary||x.brain_decision==="exploit"||["champion","exploit"].includes(String(x.portfolio_lane||"")))
    .filter((x:any)=>String(x.portfolio_lane||"")!=="explore");
  const exploitSorted=[...exploitPool].sort((a:any,b:any)=>portfolioRank(b,exploitPool)-portfolioRank(a,exploitPool));
  const exploit = exploitN>0
    ? exploitSorted.slice(0,exploitN).map((x:any)=>({...x,priority_selection_mode:"exploit"}))
    : [];

  const exploitIds=new Set(exploit.map((x:any)=>x.id));
  const explorePool=selectionPool.filter((x:any)=>!exploitIds.has(x.id)&&x.brain_decision!=="deprioritize");
  const exploration = [...explorePool]
    .sort((a:any,b:any)=>{
      const rank=(x:any)=>{
        const age=x.last_used_at?Math.min(36,(Date.now()-new Date(x.last_used_at).getTime())/3600000):36;
        const lowSample=Math.max(0,8-Number(x.priority_yield_sample||0))*2;
        const lane=String(x.portfolio_lane||"");
        const laneBoost=lane==="challenger"?18:lane==="learning"?10:lane==="champion"?-8:lane==="explore"?-4:0;
        const maturity=String(x.portfolio_maturity||"");
        const maturityBoost=maturity==="warming"?12:maturity==="learning"?7:0;
        const canaryBoost=x.brain_canary?8:0;
        return portfolioRank(x,explorePool)+age*0.35+lowSample+laneBoost+maturityBoost+canaryBoost;
      };
      return rank(b)-rank(a);
    })
    .slice(0,exploreN)
    .map((x:any)=>({...x,priority_selection_mode:"explore"}));

  const selected=[...exploit,...exploration].slice(0,requestedLimit);
  const strategies = selected.map((s:any)=>({...s,target_location:marketFor(s,marketRows??[],brainEnabled,brainCanaryPct)}));
  const { data: allEnabledSources } = await db.schema("booked_solid").from("source_catalog").select("*").eq("enabled",true);
  const coolingSources=(allEnabledSources??[]).filter((x:any)=>sourceCooling(x));
  const degradedSources=(allEnabledSources??[]).filter((x:any)=>!sourceCooling(x)&&(Number(x.consecutive_errors||0)>=4||String(x.metadata?.state||"")==="degraded"));
  const sources=(allEnabledSources??[]).filter((x:any)=>!sourceCooling(x)&&Number(x.consecutive_errors||0)<4&&String(x.metadata?.state||"")!=="degraded");
  const sourceBySlug=new Map((sources??[]).map((x:any)=>[x.slug,x]));
  const osmSource=sourceBySlug.get("openstreetmap_overpass");
  const nrcaSource=sourceBySlug.get("nrca_official");
  const usaSpendingSource=sourceBySlug.get("usaspending_api");
  const chicagoPermitSource=sourceBySlug.get("chicago_building_permits");
  const nycPermitSource=sourceBySlug.get("nyc_dob_permits");
  const austinPermitSource=sourceBySlug.get("austin_construction_permits");
  const seattlePermitSource=sourceBySlug.get("seattle_building_permits");
  const bostonPermitSource=sourceBySlug.get("boston_building_permits");
  const sfPermitSource=sourceBySlug.get("sf_building_permit_contacts");
  const philadelphiaPermitSource=sourceBySlug.get("philadelphia_permit_contractors");
  const philadelphiaTradeLicenseSource=sourceBySlug.get("philadelphia_trade_licenses");
  const denverPermitSource=sourceBySlug.get("denver_commercial_permits");
  const citySources=[chicagoPermitSource,nycPermitSource,austinPermitSource,seattlePermitSource,bostonPermitSource,sfPermitSource,philadelphiaPermitSource,philadelphiaTradeLicenseSource,denverPermitSource].filter(Boolean);
  const sourceLeadYield=(x:any)=>Number(x?.metadata?.lead_yield?.score??0);
  const sourceDiscoveryTier=(x:any)=>{
    const rights=String(x?.metadata?.source_v22?.rights_status??x?.metadata?.brain_v2?.rights_status??"");
    const recoveryLane=String(x?.metadata?.source_v22?.portfolio_lane??"");
    const brainLane=String(x?.metadata?.brain_v2?.lane??"");
    if(rights==="BLOCKED"||rights==="INTERNAL_ONLY"||brainLane==="blocked")return "blocked";
    if(rights==="REVIEW_REQUIRED")return "exploration_only";
    if(rights==="ALLOWED"&&recoveryLane==="champion")return "proven";
    if(rights==="ALLOWED"&&recoveryLane==="challenger")return "testing";
    if(rights==="ALLOWED"&&recoveryLane==="exploration")return "exploration_only";
    if(brainLane==="proven")return "proven";
    if(brainLane==="testing")return "testing";
    if(brainLane==="exploration")return "exploration_only";
    return String(x?.metadata?.discovery_tier??x?.metadata?.lead_yield?.tier??"testing");
  };
  const sourceRankValue=(x:any)=>{
    const life=x?.lifecycle_state==="active"?35:15;
    const quality=Number(x?.quality_score||50)*0.20;
    const leadYield=sourceLeadYield(x)*0.55;
    const priorityYield=Number(x?.metadata?.priority_yield_score||0)*0.08;
    const exploration=Number(x?.exploration_weight||1)*1.5;
    const brain=Number(x?.metadata?.brain_v2?.score??0);
    const brainLane=String(x?.metadata?.brain_v2?.lane??"");
    const zeroGuard=Boolean(x?.metadata?.brain_v2?.zero_yield_guard);
    const v22=x?.metadata?.source_v22??{};
    const sourceValue=Number(v22?.source_value_score??0);
    const commercialYield=Number(v22?.commercial_yield_score??0);
    const recoveryLane=String(v22?.portfolio_lane??"");
    const recommendedShare=Math.max(0,Number(v22?.recommended_share_pct??0));
    const actualRecent=Number(recentSourceCounts.get(String(x?.slug||""))||0);
    const targetRecent=(recentDiscover?.length||30)*(recommendedShare/100);
    const shareDeficit=Math.max(-3,Math.min(3,targetRecent-actualRecent));
    const rights=String(v22?.rights_status??x?.metadata?.brain_v2?.rights_status??"");
    const laneBoost=
      recoveryLane==="champion"?24:
      recoveryLane==="challenger"?10:
      recoveryLane==="exploration"?-10:
      brainLane==="proven"?12:brainLane==="testing"?4:brainLane==="exploration"?-8:brainLane==="blocked"?-100:0;
    const rightsPenalty=rights==="REVIEW_REQUIRED"?25:rights==="BLOCKED"?100:0;
    return life+quality+leadYield+priorityYield+exploration+brain*0.30
      +sourceValue*0.50+commercialYield*0.20+laneBoost+shareDeficit*6
      -(zeroGuard?25:0)-rightsPenalty;
  };
  const autoActiveSources=(sources??[])
    .filter((x:any)=>["generic_socrata","generic_arcgis"].includes(String(x.metadata?.adapter||""))&&["active","canary"].includes(String(x.lifecycle_state||"")))
    .sort((a:any,b:any)=>sourceRankValue(b)-sourceRankValue(a));
  const osmTrades=new Set(["Roofing","Commercial Roofing","HVAC","Commercial HVAC","Plumbing","Electrical","Painting","Flooring","Landscaping","General Contractor","Commercial Contractor","Construction","Windows","Deck Builder","Deck Patio","Cabinet","Remodeling","Bathroom Remodeling","Kitchen Remodeling","Kitchen Bath Remodeling","Home Builder","Custom Home Builder","Siding","Concrete","Mixed","Property Operations"]);
  const sourceTradeHint=(source:any)=>{
    const explicit=String(source?.metadata?.trade_hint||source?.metadata?.source_trade_hint||"").trim();
    if(explicit)return explicit;
    // Datasets with an explicit trade column are multi-trade sources; row-level
    // trade classification remains authoritative.
    if(source?.metadata?.field_map?.trade)return "Mixed";
    const text=(String(source?.name||"")+" "+String(source?.slug||"")+" "+String(source?.metadata?.public_url||"")).toLowerCase();
    if(/plumb/.test(text))return "Plumbing";
    if(/electric/.test(text))return "Electrical";
    if(/hvac|heating|air.?conditioning|mechanical/.test(text))return "HVAC";
    if(/roof/.test(text))return "Roofing";
    if(/landscap/.test(text))return "Landscaping";
    if(/paint/.test(text))return "Painting";
    if(/floor/.test(text))return "Flooring";
    if(/concrete/.test(text))return "Concrete";
    if(/remodel|renovation/.test(text))return "Remodeling";
    if(/builder|construction|building permits?/.test(text))return "Mixed";
    return "Mixed";
  };
  const tradeCompatible=(source:any,trade:string)=>{
    const hint=sourceTradeHint(source);
    if(hint==="Mixed"||trade==="Mixed")return true;
    const t=String(trade||"");
    if(hint==="Roofing"&&["Roofing","Commercial Roofing"].includes(t))return true;
    if(hint==="HVAC"&&["HVAC","Commercial HVAC"].includes(t))return true;
    if(hint==="General Contractor"&&["General Contractor","Commercial Contractor","Construction"].includes(t))return true;
    return hint===t;
  };
  const discoveryCapable=(source:any,trade:string,market:string)=>{
    if(!source)return false;
    const slug=String(source.slug||"");
    const sourcePurpose=(slug+" "+String(source.name||"")+" "+String(source.metadata?.source_kind||"")).toLowerCase();
    if(trade==="Property Operations"
       && /(permit|dob|contractor license|trade license)/.test(sourcePurpose)
       && !/(property management|property operations|housing|multifamily|rental)/.test(sourcePurpose))return false;
    if(slug==="openstreetmap_overpass")return osmTrades.has(trade);
    if(slug==="nrca_official")return ["Roofing","Commercial Roofing"].includes(trade);
    if(slug==="usaspending_api")return true;
    const adapter=String(source.metadata?.adapter||"");
    if(["generic_socrata","generic_arcgis"].includes(adapter)){
      const sourceKind=String(source.metadata?.source_kind||"permit").toLowerCase();
      if(trade==="Property Operations"&&!/(property|rental|management|multifamily|housing)/.test(sourceKind+" "+String(source.name||"").toLowerCase()))return false;
      const sm=String(source.metadata?.market_hint||source.metadata?.market||"").trim();
      const jurisdiction=String(source.metadata?.jurisdiction_state||"").trim().toUpperCase();
      const fm=source.metadata?.field_map??{};
      const hasRowGeo=Boolean(fm.city||fm.state);
      if(!sm&&!hasRowGeo&&!jurisdiction)return false;
      if(sm&&sm!==market)return false;
      if(jurisdiction){
        const m=String(market||"").trim();
        const stateMatch=m.match(/\b([A-Z]{2})\b/);
        const stateCode=stateMatch?stateMatch[1].toUpperCase():
          m==="Washington"?"WA":m==="Maryland"?"MD":m==="New Jersey"?"NJ":m==="California"?"CA":m==="Texas"?"TX":
          m==="Florida"?"FL":m==="Arizona"?"AZ":m==="Pennsylvania"?"PA":m==="Ohio"?"OH":m==="Virginia"?"VA":
          m==="North Carolina"?"NC":m==="South Carolina"?"SC":m==="Georgia"?"GA":m==="Colorado"?"CO":m==="Oregon"?"OR":"";
        if(stateCode&&stateCode!==jurisdiction)return false;
        if(!stateCode&&m!=="US"&&m!=="United States")return false;
      }
      return tradeCompatible(source,trade);
    }
    const sm=String(source.metadata?.market_hint||source.metadata?.market||"");
    if(citySources.some((x:any)=>x?.slug===slug))return Boolean(sm)&&sm===market;
    return false;
  };
  const chooseBaseSource=(s:any)=>{
    const trade=String(s.trade||"Mixed"),market=String(s.target_location||"US");
    const useCount=Number(s.uses_count||0);
    const unique=new Map<string,any>();
    for(const x of [osmSource,nrcaSource,usaSpendingSource,...citySources,...autoActiveSources].filter(Boolean)){
      if(discoveryCapable(x,trade,market))unique.set(String(x.slug),x);
    }
    const arr=[...unique.values()];
    if(!arr.length)return null;

    const ranked=[...arr]
      .filter((x:any)=>sourceDiscoveryTier(x)!=="blocked")
      .sort((a:any,b:any)=>sourceRankValue(b)-sourceRankValue(a));
    if(!ranked.length)return null;

    const proven=ranked.filter((x:any)=>sourceDiscoveryTier(x)==="proven");
    const testing=ranked.filter((x:any)=>{
      if(sourceDiscoveryTier(x)!=="testing")return false;
      const sample=Number(x?.metadata?.brain_v2?.sample??x?.metadata?.lead_yield?.sample??0);
      const leads=Number(x?.metadata?.brain_v2?.leads??x?.metadata?.lead_yield?.leads??0);
      return sample<20||leads>0;
    });
    const exploration=ranked.filter((x:any)=>sourceDiscoveryTier(x)==="exploration_only");
    const freshExploration=exploration.filter((x:any)=>!Boolean(x?.metadata?.brain_v2?.zero_yield_guard));
    const zeroYieldExploration=exploration.filter((x:any)=>Boolean(x?.metadata?.brain_v2?.zero_yield_guard));
    const strategyMode=String(s.priority_selection_mode||"exploit");
    const bucket=hashText(String(s.slug)+":brain-source:"+useCount)%100;
    let pool:any[]=[];
    let lane="proven";

    if(strategyMode==="exploit"){
      if(proven.length){ lane="proven"; pool=proven; }
      else if(testing.length){ lane="testing"; pool=testing; }
      else return null;
    }else{
      if(bucket<35 && proven.length){ lane="proven"; pool=proven; }
      else if(bucket<65 && testing.length){ lane="testing"; pool=testing; }
      else{
        lane="exploration";
        const zeroYieldBucket=hashText(String(s.slug)+":"+market+":zero-yield:"+useCount)%100;
        if(zeroYieldBucket<12&&zeroYieldExploration.length)pool=zeroYieldExploration;
        else if(freshExploration.length)pool=freshExploration;
        else if(exploration.length)pool=exploration;
        else if(testing.length){ lane="testing"; pool=testing; }
        else { lane="proven"; pool=proven; }
      }
    }

    if(!pool.length)return null;
    const top=lane==="exploration"
      ? pool.slice(0,Math.max(1,Math.ceil(pool.length*0.60)))
      : pool.slice(0,Math.max(1,Math.ceil(pool.length*0.40)));
    return top[hashText(String(s.slug)+":"+market+":"+lane+":"+useCount)%top.length];
  };
  if (!strategies.length) {
    return json({ ok: true, paused: true, reason: "no_strategy_available" }, 200);
  }

  const marketRankValue=(m:any)=>{
    const legacy=Number(m?.quality_score||50)+Number(m?.exploration_weight||1)*7+Number(m?.metadata?.priority_yield_score||25)*0.35;
    const brain=Number(m?.metadata?.brain_v2?.score??legacy);
    const decision=String(m?.metadata?.brain_v2?.decision??"test");
    return legacy*0.72+brain*0.28+(decision==="exploit"?8:decision==="deprioritize"?-12:0);
  };
  const routed = strategies.map((s:any)=>{
    const useCount=Number(s.uses_count??0);
    const trade=String(s.trade||"Mixed");
    let market=String(s.target_location||"US");
    let routedStrategy={...s,target_location:market};
    let source:any=chooseBaseSource(routedStrategy);

    // If the selected market has no compatible source, preserve the strategy
    // and safely reroute it to the best source-compatible market instead of
    // falling back to an unrelated local dataset or dropping the whole cycle.
    if(!source){
      const rankedMarkets=[...(marketRows??[])]
        .filter((m:any)=>["testing","active"].includes(String(m.lifecycle_state||"active")))
        .sort((a:any,b:any)=>marketRankValue(b)-marketRankValue(a));
      const rotated=rankedMarkets.length
        ? rankedMarkets.slice(hashText(String(s.slug)+":"+useCount)%rankedMarkets.length)
            .concat(rankedMarkets.slice(0,hashText(String(s.slug)+":"+useCount)%rankedMarkets.length))
        : [];
      for(const m of rotated){
        const candidate=String(m.display_name||"");
        if(!candidate||candidate===market)continue;
        const attempt={...s,target_location:candidate};
        const candidateSource=chooseBaseSource(attempt);
        if(candidateSource&&discoveryCapable(candidateSource,trade,candidate)){
          market=candidate;
          routedStrategy=attempt;
          source=candidateSource;
          break;
        }
      }
    }
    if(!source)return null;
    if(!discoveryCapable(source,trade,market))return null;
    const jobMarket=String(source?.metadata?.market_hint||source?.metadata?.market||market);
    const [jobLat,jobLon]=coordsFor(jobMarket,marketRows??[]);
    return {strategy:routedStrategy,job:{
      kind:"discover",
      priority:Math.max(1,Number(s.planner_score)),
      payload:{
        strategy_id:s.id,
        strategy_slug:s.slug,
        trade:s.trade,
        geography:jobMarket,
        intent:s.intent,
        query_template:s.query_template,
        source_id:source.id,
        source_slug:source.slug,
        latitude:jobLat,
        longitude:jobLon,
        offer_hint:s.offer_hint,
        priority_selection_mode:s.priority_selection_mode||"exploit",
        strategy_priority_yield_score:Number(s.priority_yield_score||25),
        trade_priority_yield_score:Number(s.trade_priority_yield_score||25),
        source_priority_yield_score:Number(source?.metadata?.priority_yield_score||25),
        brain_policy_version:brainEnabled?2:0,
        brain_canary_pct:brainCanaryPct,
        brain_strategy_score:Number(s.brain_score??0),
        brain_strategy_decision:String(s.brain_decision??"legacy"),
        brain_source_score:Number(source?.metadata?.brain_v2?.score??0),
        brain_source_lane:String(sourceDiscoveryTier(source)),
        source_recovery_policy:22,
        source_portfolio_lane:String(source?.metadata?.source_v22?.portfolio_lane??""),
        source_value_score:Number(source?.metadata?.source_v22?.source_value_score??0),
        source_commercial_yield_score:Number(source?.metadata?.source_v22?.commercial_yield_score??0),
        source_recommended_share_pct:Number(source?.metadata?.source_v22?.recommended_share_pct??0),
        source_rights_status:String(source?.metadata?.source_v22?.rights_status??source?.metadata?.brain_v2?.rights_status??""),
        balanced_growth_policy:balancedGrowthEnabled?balancedGrowthPolicy:0,
        portfolio_lane:String(s.portfolio_lane||""),
        portfolio_maturity:String(s.portfolio_maturity||""),
        portfolio_score:Number(s.portfolio_score||0),
        portfolio_weight:Number(s.portfolio_weight||1),
        portfolio_target_share:Number(s.portfolio_target_share||0),
        exploration_pct:explorationPct,
        evolution_source:Boolean(source?.metadata?.discovered_by==="self_evolution")
      },
      status:"pending",
      available_at:new Date().toISOString()
    }};
  }).filter(Boolean) as any[];

  if(!routed.length){
    const enrichment=await queueOneEnrichment();
    const contactIntel=await queueContactIntelligenceV2(2);
    return json({
      ok:true,mode:"planner",queued:0,paused:true,reason:"no_compatible_free_source_available",
      email_gate:"blocked_until_email_configuration",
      enrichment_queued:enrichment,
      contact_intelligence_queued:contactIntel,
      discovery_preserved:true,
      source_health:{
        healthy_enabled_sources:sources.length,
        cooling_enabled_sources:coolingSources.length,
        degraded_enabled_sources:degradedSources.length,
        cooling_sources:coolingSources.slice(0,8).map((x:any)=>({slug:x.slug,cooldown_until:x.metadata?.cooldown_until??null,last_error_class:x.metadata?.last_error_class??null}))
      },
      skipped_strategies:strategies.map((s:any)=>({slug:s.slug,trade:s.trade,market:s.target_location}))
    },200);
  }

  const jobs=routed.map((x:any)=>x.job);
  const { data: queued, error } = await db.schema("booked_solid").from("work_queue").insert(jobs).select("id,kind,priority,payload");
  if (error) throw error;

  await Promise.all(routed.map((x:any)=>{
    const s=x.strategy;
    return db.schema("booked_solid").from("search_strategies").update({
      last_used_at:new Date().toISOString(),
      uses_count:Number(s.uses_count??0)+1,
      metadata:{...(s.metadata??{}),last_market:s.target_location}
    }).eq("id",s.id);
  }));
  for(const j of queued??[]){
    const mn=String(j.payload?.geography||"");if(!mn)continue;
    const m=(marketRows??[]).find((x:any)=>x.display_name===mn);
    if(m)await db.schema("booked_solid").from("market_catalog").update({uses_count:Number(m.uses_count??0)+1,last_used_at:new Date().toISOString(),updated_at:new Date().toISOString()}).eq("id",m.id);
  }
  const enrichment=await queueOneEnrichment();
  const contactIntel=await queueContactIntelligenceV2(2);

  return json({
    ok: true,
    mode: "planner",
    email_gate: "blocked_until_email_configuration",
    queued: queued?.length ?? 0,
    enrichment_queued: enrichment,
    contact_intelligence_queued: contactIntel,
    discovery_preserved: true,
    enrichment_is_additive_not_a_gate: true,
    source_health: {
      healthy_enabled_sources: sources.length,
      cooling_enabled_sources: coolingSources.length,
      degraded_enabled_sources: degradedSources.length,
      selected_source: queued?.[0]?.payload?.source_slug??null,
      cooling_sources: coolingSources.slice(0,8).map((x:any)=>({slug:x.slug,cooldown_until:x.metadata?.cooldown_until??null,last_error_class:x.metadata?.last_error_class??null}))
    },
    strategy_brain:{
      enabled:brainEnabled,
      policy_version:2,
      canary_pct:brainCanaryPct,
      rollout:"blended_canary",
      source_zero_yield_guard:true
    },
    balanced_growth:{
      enabled:balancedGrowthEnabled,
      policy_version:balancedGrowthPolicy,
      exploration_pct:explorationPct,
      portfolio_allocator:true,
      unknown_market_generic_sources_blocked:true,
      hard_safety_unchanged:true
    },
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
      legacy_planner_score:s.legacy_planner_score,
      brain_planner_score:s.brain_planner_score,
      brain_score:s.brain_score,
      brain_decision:s.brain_decision,
      portfolio_lane:s.portfolio_lane,
      portfolio_maturity:s.portfolio_maturity,
      portfolio_score:s.portfolio_score,
      portfolio_weight:s.portfolio_weight,
      portfolio_target_share:s.portfolio_target_share,
      priority_selection_mode: s.priority_selection_mode||"exploit",
      priority_yield_score: s.priority_yield_score,
      trade_priority_yield_score: s.trade_priority_yield_score,
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
