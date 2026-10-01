
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const H={"Content-Type":"application/json","Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type"};
const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const out=(x:unknown,s=200)=>new Response(JSON.stringify(x),{status:s,headers:H});
const clamp=(n:number,a=0,b=100)=>Math.max(a,Math.min(b,n));
const slugify=(s:string)=>String(s||"").toLowerCase().replace(/[^a-z0-9]+/g,"-").replace(/^-|-$/g,"").slice(0,60);
function hash(s:string){let h=2166136261;for(const c of s){h^=c.charCodeAt(0);h=Math.imul(h,16777619)}return (h>>>0).toString(36)}
function cleanText(s:any){return String(s??"").replace(/<[^>]+>/g," ").replace(/&nbsp;/gi," ").replace(/\s+/g," ").trim()}
function titleCase(s:string){return s.toLowerCase().replace(/\b\w/g,c=>c.toUpperCase())}

const HUNT_QUERIES=[
 "building permits contractor",
 "construction permits contractor company",
 "contractor licenses active",
 "state contractor license registry",
 "general contractor licenses active",
 "commercial contractor licenses",
 "residential contractor licenses",
 "building contractor registrations",
 "electrical contractor licenses",
 "electrical permits contractor",
 "plumbing contractor licenses",
 "plumbing permits contractor",
 "hvac mechanical permits contractor",
 "mechanical contractor licenses",
 "mechanical permits contractor",
 "roofing permits contractor",
 "roofing contractor licenses",
 "home improvement contractor licenses",
 "home builder licenses registrations",
 "commercial construction permits contractor",
 "building permit contractor name",
 "painting contractor licenses",
 "landscaping contractor licenses",
 "property management licenses"
];

function sourceKind(title:string,desc:string){
 const tt=title.toLowerCase(),t=(title+" "+desc).toLowerCase();
 if(/permit|plan review|inspection permit/.test(tt))return "permit";
 return /license|licence|registration|registered/.test(t)?"license":"permit";
}
function pickField(human:string[],field:string[],patterns:RegExp[]){
 for(const p of patterns){
  for(let i=0;i<field.length;i++){
   const both=(String(field[i]||"")+" "+String(human[i]||"")).toLowerCase();
   if(p.test(both))return field[i];
  }
 }
 return null;
}
function detectFieldMap(human:string[],field:string[]){
 let company=pickField(human,field,[
  /contractor[_\s-]*(company|business|firm|organization|org)[_\s-]*(name)?/,
  /contractorcompany/,
  /contractor[_\s-]*name/,
  /(company|business|firm|organization|org)[_\s-]*name/
 ]);
 if(company&&/(private_provider|inspector|inspection_agency|applicant|owner|architect|engineer|reviewer|designer)/i.test(String(company)))company=null;
 const map:any={company};
 map.email=pickField(human,field,[/contractor.*email/,/business.*email/,/company.*email/,/email/]);
 map.phone=pickField(human,field,[/contractor.*phone/,/business.*phone/,/company.*phone/,/phone/]);
 map.trade=pickField(human,field,[/contractor.*trade/,/trade.*type/,/license.*type/,/licence.*type/,/specialty|speciality/]);
 map.date=pickField(human,field,[/issued.*date/,/issue.*date/,/permit.*date/,/expiration.*date/,/last.*updated/,/updated.*date/]);
 map.permit=pickField(human,field,[/\bpermit[_\s-]*(num|number|id)\b/,/\b(num|number|id)[_\s-]*permit\b/,/\bpermitno\b/]);
 map.license=pickField(human,field,[/\blicen[sc]e[_\s-]*(num|number|id)\b/,/\bcontractor[_\s-]*licen[sc]e[_\s-]*(num|number|id)?\b/]);
 map.city=pickField(human,field,[/contractor.*city/,/business.*city/,/company.*city/,/^city\b/]);
 map.state=pickField(human,field,[/contractor.*state/,/business.*state/,/company.*state/,/^state\b/]);
 map.description=pickField(human,field,[/description/,/scope.*work/,/work.*description/,/project.*description/]);
 return map;
}
function sourceTradeHint(title:string,desc:string=""){
 const t=(title+" "+desc).toLowerCase();
 if(/plumb|gas permit/.test(t))return "Plumbing";
 if(/electrical|electrician/.test(t))return "Electrical";
 if(/hvac|mechanical|heating|air conditioning/.test(t))return "HVAC";
 if(/roof/.test(t))return "Roofing";
 if(/paint/.test(t))return "Painting";
 if(/landscap/.test(t))return "Landscaping";
 if(/home builder|new home builder|residential builder/.test(t))return "Home Builder";
 if(/remodel|home improvement/.test(t))return "Remodeling";
 if(/plan review|general contractor|construction|building permit|contractor license|contractor licence|building contractor/.test(t))return "Construction";
 return "Mixed";
}
function candidateScopeReason(title:string,desc:string=""){
 const t=(title+" "+desc).toLowerCase();
 if(/elevator|escalator/.test(t))return "out_of_scope_elevator";
 if(/asbestos/.test(t))return "out_of_scope_asbestos";
 if(/\bmold\b/.test(t))return "out_of_scope_mold";
 if(/water well|well contractor|pump installer/.test(t))return "out_of_scope_water_well";
 if(/real estate development|real estate developer|property sale|parcel sales/.test(t))return "out_of_scope_real_estate";
 if(/demolition permits?/.test(t))return "out_of_scope_demolition";
 return null;
}
function relevantDataset(title:string,desc:string){
 const t=(title+" "+desc).toLowerCase();
 return !candidateScopeReason(title,desc)
   && /(permit|license|licence|contractor|construction|building|plumbing|electrical|hvac|mechanical|roof|home improvement|builder|remodel|painting|landscap)/.test(t)
   && !/(restaurant|food|liquor|alcohol|marriage|dog license|pet license|retired|deprecated|archive|historical|trust fund|violation|disciplin|complaint|enforcement)/.test(t);
}
function inferExistingMarket(text:string,markets:any[]){
 const t=text.toLowerCase();
 let best:any=null,bestLen=0;
 for(const m of markets){
  const dn=String(m.display_name||"");
  const city=dn.replace(/\s+[A-Z]{2}$/,"").toLowerCase();
  if(city.length>=4&&t.includes(city)&&city.length>bestLen){best=m;bestLen=city.length}
 }
 return best?.display_name??null;
}
async function upsertCandidate(c:any){
 const {data:old}=await db.schema("booked_solid").from("source_candidates").select("id,state").eq("candidate_key",c.candidate_key).maybeSingle();
 if(old){
  await db.schema("booked_solid").from("source_candidates").update({...c,last_seen_at:new Date().toISOString(),state:old.state==="rejected"?"rejected":old.state}).eq("id",old.id);
  return false;
 }
 await db.schema("booked_solid").from("source_candidates").insert(c);
 return true;
}
async function huntSocrata(query:string,markets:any[]){
 const u=new URL("https://api.us.socrata.com/api/catalog/v1");u.searchParams.set("q",query);u.searchParams.set("limit","25");
 const r=await fetch(u,{signal:AbortSignal.timeout(15000),headers:{"Accept":"application/json","User-Agent":"BookedSolidSourceHunter/1.0 (+https://www.bookedsolidcopy.com/)"}});
 if(!r.ok)throw new Error("socrata_catalog_http_"+r.status);
 const j=await r.json();let added=0;
 for(const x of j?.results??[]){
  const rs=x?.resource??{};if(rs.type!=="dataset"||String(rs.provenance||"").toLowerCase()!=="official")continue;
  const title=cleanText(rs.name),desc=cleanText(rs.description);if(!relevantDataset(title,desc))continue;
  const human=Array.isArray(rs.columns_name)?rs.columns_name:[];const fields=Array.isArray(rs.columns_field_name)?rs.columns_field_name:[];
  const fm=detectFieldMap(human,fields);if(!fm.company)continue;
  const domain=String(x?.metadata?.domain||"").toLowerCase();const rid=String(rs.id||"");if(!domain||!rid)continue;
  let score=35+35+10; // official + strong company field + relevant dataset
  if(fm.email)score+=5;if(fm.trade)score+=5;if(fm.date)score+=5;if(fm.permit||fm.license)score+=5;
  let market=inferExistingMarket(title+" "+desc+" "+domain,markets);
  if(/^(data\.)?(ny|wa|ca|il|tx|fl|pa|nj|oh|mi|co|az)\.gov$/i.test(domain)||/statewide|new york state|washington state|state of /i.test(title+" "+desc))market=null;
  if(market)score+=3;
  const kind=sourceKind(title,desc);
  if(await upsertCandidate({
   candidate_key:"socrata:"+domain+":"+rid,provider_type:"socrata",title,description:desc,api_domain:domain,resource_id:rid,
   api_url:"https://"+domain+"/resource/"+rid+".json",public_url:String(x?.link||x?.permalink||""),
   owner_name:String(x?.owner?.display_name||""),provenance:"official",market_hint:market,source_kind:kind,field_map:fm,
   schema_snapshot:{columns_name:human,columns_field_name:fields,updated_at:rs.updatedAt??null,data_updated_at:rs.data_updated_at??null},
   discovery_query:query,score:clamp(score),state:"candidate",metadata:{catalog:"socrata",domain_category:x?.classification?.domain_category??null}
  }))added++;
 }
 return added;
}
async function huntArcGIS(query:string,markets:any[]){
 const u=new URL("https://www.arcgis.com/sharing/rest/search");
 u.searchParams.set("q",query+' type:"Feature Service"');u.searchParams.set("f","json");u.searchParams.set("num","20");
 const r=await fetch(u,{signal:AbortSignal.timeout(15000),headers:{"Accept":"application/json","User-Agent":"BookedSolidSourceHunter/1.0 (+https://www.bookedsolidcopy.com/)"}});
 if(!r.ok)throw new Error("arcgis_catalog_http_"+r.status);
 const j=await r.json();let added=0;
 for(const x of j?.results??[]){
  const title=cleanText(x.title),desc=cleanText(x.description||x.snippet);if(!relevantDataset(title,desc))continue;
  const owner=String(x.owner||"");const access=cleanText(x.accessInformation||"");const all=(title+" "+desc+" "+access+" "+owner).toLowerCase();
  if(/shovels|living atlas|esri_|marketplace|commercial data provider/.test(all))continue;
  const officialSignal=/(city of|county of|department of|government|municipal|planning and development|building department|state of)/i.test(title+" "+desc+" "+access);
  if(!officialSignal)continue;
  const url=String(x.url||"");if(!/^https:\/\/[^/]+\.arcgis\.com\/.*FeatureServer/i.test(url))continue;
  const market=inferExistingMarket(title+" "+desc+" "+access,markets);
  let score=55+(market?5:0)+(x.access==="public"?10:0);
  if(await upsertCandidate({
   candidate_key:"arcgis:"+String(x.id),provider_type:"arcgis",title,description:desc,api_domain:new URL(url).hostname,
   resource_id:String(x.id),api_url:url,public_url:"https://www.arcgis.com/home/item.html?id="+String(x.id),
   owner_name:owner,provenance:"official_signal",market_hint:market,source_kind:sourceKind(title,desc),
   field_map:{},schema_snapshot:{tags:x.tags??[],access_information:access,license_info:cleanText(x.licenseInfo||"")},
   discovery_query:query,score:clamp(score),state:"candidate",metadata:{catalog:"arcgis",official_signal:true}
  }))added++;
 }
 return added;
}
async function maybeCreateMarketFromRows(rows:any[],fm:any,candidate:any){
 if(candidate.market_hint)return candidate.market_hint;
 const {data:evo}=await db.schema("booked_solid").from("evolution_settings").select("market_expansion_enabled").eq("id",true).maybeSingle();
 if(evo?.market_expansion_enabled===false)return null;
 if(!fm.city||!fm.state)return null;
 const counts=new Map<string,number>();
 for(const row of rows){
  const city=String(row?.[fm.city]||"").trim(),state=String(row?.[fm.state]||"").trim().toUpperCase();
  if(!city||!/^[A-Z]{2}$/.test(state))continue;
  const key=titleCase(city)+" "+state;counts.set(key,(counts.get(key)||0)+1);
 }
 const pairs=[...counts.entries()].sort((a,b)=>b[1]-a[1]);const top=pairs[0];const total=pairs.reduce((n,x)=>n+x[1],0);if(!top||top[1]<Math.max(2,Math.ceil(total*0.6)))return null;
 const display=top[0];const {data:existing}=await db.schema("booked_solid").from("market_catalog").select("*").eq("display_name",display).maybeSingle();
 if(existing)return display;
 try{
  const u=new URL("https://nominatim.openstreetmap.org/search");u.searchParams.set("format","jsonv2");u.searchParams.set("limit","1");u.searchParams.set("countrycodes","us");u.searchParams.set("q",display);
  const r=await fetch(u,{signal:AbortSignal.timeout(10000),headers:{"Accept":"application/json","User-Agent":"BookedSolidMarketExpansion/1.0 (+https://www.bookedsolidcopy.com/)"}});
  if(!r.ok)return null;const j=await r.json();const hit=j?.[0];if(!hit)return null;
  await db.schema("booked_solid").from("market_catalog").insert({
   slug:slugify(display),display_name:display,state_code:display.slice(-2),latitude:Number(hit.lat),longitude:Number(hit.lon),
   lifecycle_state:"testing",quality_score:45,exploration_weight:1.8,metadata:{discovered_by:"source_validation",source_candidate_id:candidate.id}
  });
  return display;
 }catch{return null}
}
async function promoteSocrata(c:any,rows:any[]){
 if(/bond|insurance|principal data/i.test(String(c.title||""))){
  await db.schema("booked_solid").from("source_candidates").update({state:"rejected",rejection_reason:"auxiliary_dataset_not_primary_discovery",last_validated_at:new Date().toISOString()}).eq("id",c.id);
  return null;
 }
 if(/retired|deprecated|archive|historical/i.test(String(c.title||""))){
  await db.schema("booked_solid").from("source_candidates").update({state:"rejected",rejection_reason:"stale_or_retired_dataset",last_validated_at:new Date().toISOString()}).eq("id",c.id);
  return null;
 }
 const {data:knownSources}=await db.schema("booked_solid").from("source_catalog").select("slug,metadata");
 const dup=(knownSources??[]).find((x:any)=>String(x.metadata?.dataset||x.metadata?.resource_id||"")===String(c.resource_id||""));
 if(dup){
  await db.schema("booked_solid").from("source_candidates").update({state:"rejected",rejection_reason:"duplicate_of:"+dup.slug,last_validated_at:new Date().toISOString()}).eq("id",c.id);
  return null;
 }
 const fm=c.field_map??{};let market=await maybeCreateMarketFromRows(rows,fm,c);
 const slug=("auto-socrata-"+slugify(c.title).slice(0,32)+"-"+String(c.resource_id).replace(/[^a-z0-9]/gi,"")).slice(0,90);
 const {data:existing}=await db.schema("booked_solid").from("source_catalog").select("id").eq("slug",slug).maybeSingle();
 if(!existing){
  await db.schema("booked_solid").from("source_catalog").insert({
   slug,name:c.title,source_type:"public_registry",base_weight:0.65,enabled:true,reliability_score:75,
   lifecycle_state:"canary",quality_score:Math.max(60,Number(c.score||0)),exploration_weight:2,last_validated_at:new Date().toISOString(),
   metadata:{cost:"free",api_key_required:false,adapter:"generic_socrata",discovered_by:"self_evolution",candidate_id:c.id,
    api_domain:c.api_domain,resource_id:c.resource_id,field_map:fm,source_kind:c.source_kind,public_url:c.public_url,
    market_hint:market,provider:c.owner_name||c.api_domain,canary:true,fetch_limit:100}
  });
 }
 await db.schema("booked_solid").from("source_candidates").update({state:"promoted",last_validated_at:new Date().toISOString(),market_hint:market}).eq("id",c.id);
 return {slug,market};
}
async function validateSocrata(c:any){
 const fm=c.field_map??{};if(!fm.company)throw new Error("missing_company_field");
 const u=new URL(String(c.api_url));u.searchParams.set("$limit","8");u.searchParams.set("$where",String(fm.company)+" is not null");if(fm.date)u.searchParams.set("$order",String(fm.date)+" DESC");
 const r=await fetch(u,{signal:AbortSignal.timeout(12000),headers:{"Accept":"application/json","User-Agent":"BookedSolidSourceValidator/1.0 (+https://www.bookedsolidcopy.com/)"}});
 if(!r.ok)throw new Error("validation_http_"+r.status);const rows=await r.json();if(!Array.isArray(rows)||!rows.length)throw new Error("empty_dataset");
 const valid=rows.filter((x:any)=>String(x?.[fm.company]||"").trim().length>=3);
 if(!valid.length)throw new Error("no_company_rows");
 return await promoteSocrata(c,valid);
}
async function promoteArcGIS(c:any,serviceUrl:string,fm:any,rows:any[]){
 let market=c.market_hint;
 if(!market&&fm.city&&fm.state){
  const fake={...c,field_map:fm};market=await maybeCreateMarketFromRows(rows,fm,fake);
 }
 const slug=("auto-arcgis-"+slugify(c.title).slice(0,32)+"-"+hash(c.resource_id||serviceUrl)).slice(0,90);
 const {data:existing}=await db.schema("booked_solid").from("source_catalog").select("id").eq("slug",slug).maybeSingle();
 if(!existing){
  await db.schema("booked_solid").from("source_catalog").insert({
   slug,name:c.title,source_type:"public_registry",base_weight:0.60,enabled:true,reliability_score:72,
   lifecycle_state:"canary",quality_score:Math.max(58,Number(c.score||0)),exploration_weight:2,last_validated_at:new Date().toISOString(),
   metadata:{cost:"free",api_key_required:false,adapter:"generic_arcgis",discovered_by:"self_evolution",candidate_id:c.id,
    service_url:serviceUrl,field_map:fm,source_kind:c.source_kind,public_url:c.public_url,market_hint:market,
    provider:c.owner_name||c.api_domain,canary:true,fetch_limit:100}
  });
 }
 await db.schema("booked_solid").from("source_candidates").update({state:"promoted",last_validated_at:new Date().toISOString(),field_map:fm,market_hint:market}).eq("id",c.id);
 return {slug,market};
}
async function validateArcGIS(c:any){
 const root=String(c.api_url||"").replace(/\/$/,"");if(!root)throw new Error("missing_arcgis_url");
 const rr=await fetch(root+"?f=json",{signal:AbortSignal.timeout(12000),headers:{"User-Agent":"BookedSolidSourceValidator/1.0 (+https://www.bookedsolidcopy.com/)"}});
 if(!rr.ok)throw new Error("arcgis_root_http_"+rr.status);const meta=await rr.json();if(meta?.error)throw new Error("arcgis_root_api");
 const layers=Array.isArray(meta.layers)&&meta.layers.length?meta.layers.slice(0,8):[{id:0}];
 for(const layer of layers){
  const lu=root+"/"+String(layer.id);
  const mr=await fetch(lu+"?f=json",{signal:AbortSignal.timeout(10000),headers:{"User-Agent":"BookedSolidSourceValidator/1.0 (+https://www.bookedsolidcopy.com/)"}});
  if(!mr.ok)continue;const lm=await mr.json();const fields=(lm.fields??[]).map((f:any)=>String(f.name||""));const human=(lm.fields??[]).map((f:any)=>String(f.alias||f.name||""));
  const fm=detectFieldMap(human,fields);if(!fm.company)continue;
  const u=new URL(lu+"/query");u.searchParams.set("where",String(fm.company)+" IS NOT NULL");u.searchParams.set("outFields","*");u.searchParams.set("resultRecordCount","8");u.searchParams.set("returnGeometry","false");u.searchParams.set("f","json");
  if(fm.date)u.searchParams.set("orderByFields",String(fm.date)+" DESC");
  const qr=await fetch(u,{signal:AbortSignal.timeout(12000),headers:{"User-Agent":"BookedSolidSourceValidator/1.0 (+https://www.bookedsolidcopy.com/)"}});
  if(!qr.ok)continue;const qj=await qr.json();const rows=(qj?.features??[]).map((f:any)=>f.attributes??{}).filter((x:any)=>String(x?.[fm.company]||"").trim().length>=3);
  if(!rows.length)continue;
  return await promoteArcGIS(c,lu,fm,rows);
 }
 throw new Error("no_company_layer");
}
async function validateCandidates(limit=4,maxCanaries=6){
 const {count:canaryCount}=await db.schema("booked_solid").from("source_catalog").select("*",{count:"exact",head:true}).eq("enabled",true).eq("lifecycle_state","canary").filter("metadata->>discovered_by","eq","self_evolution");
 const slots=Math.max(0,Number(maxCanaries||6)-Number(canaryCount||0));const take=Math.min(limit,slots);
 if(take<=0)return {validated:0,promoted:0,rejected:0,skipped:"canary_capacity_full"};
 const {data:list}=await db.schema("booked_solid").from("source_candidates").select("*").in("state",["candidate","retry"]).gte("score",65).order("score",{ascending:false}).order("last_seen_at",{ascending:false}).limit(take);
 let validated=0,promoted=0,rejected=0;
 for(const c of list??[]){
  const scopeReason=candidateScopeReason(String(c.title||""),String(c.description||""));
  if(scopeReason){
   await db.schema("booked_solid").from("source_candidates").update({state:"rejected",rejection_reason:scopeReason,last_validated_at:new Date().toISOString()}).eq("id",c.id);
   rejected++;continue;
  }
  await db.schema("booked_solid").from("source_candidates").update({state:"validating",validation_attempts:Number(c.validation_attempts||0)+1}).eq("id",c.id);
  try{
   let p:any=null;
   if(c.provider_type==="socrata")p=await validateSocrata(c);
   else if(c.provider_type==="arcgis")p=await validateArcGIS(c);
   else throw new Error("unsupported_provider");
   validated++;if(p)promoted++;
  }catch(e){
   const msg=e instanceof Error?e.message:String(e);const attempts=Number(c.validation_attempts||0)+1;
   const state=attempts>=3?"rejected":"retry";
   await db.schema("booked_solid").from("source_candidates").update({state,rejection_reason:msg,last_validated_at:new Date().toISOString()}).eq("id",c.id);
   if(state==="rejected")rejected++;
  }
 }
 return {validated,promoted,rejected};
}
async function reviewSources(){
 const [{data:sources},{data:companies},{data:leads}]=await Promise.all([
  db.schema("booked_solid").from("source_catalog").select("*"),
  db.schema("booked_solid").from("companies").select("id,source_first_seen,canonical_domain,last_researched_at,status,metadata,created_at").gte("created_at",new Date(Date.now()-30*86400000).toISOString()),
  db.schema("booked_solid").from("leads").select("company_id,status")
 ]);
 const leadByCompany=new Map<string,string[]>();for(const l of leads??[]){const a=leadByCompany.get(l.company_id)||[];a.push(l.status);leadByCompany.set(l.company_id,a)}
 const today=new Date().toISOString().slice(0,10);let activated=0,paused=0;
 for(const s of sources??[]){
  const cs=(companies??[]).filter((c:any)=>c.source_first_seen===s.slug);const n=cs.length;
  const resolved=cs.filter((c:any)=>c.canonical_domain).length;const researched=cs.filter((c:any)=>c.last_researched_at).length;const rejected=cs.filter((c:any)=>c.status==="rejected").length;
  const qualified=cs.filter((c:any)=>(leadByCompany.get(c.id)||[]).some(x=>["qualified","message_ready","queued","sent","replied","meeting","won"].includes(x))).length;
  const qr=n?qualified/n:0,rr=n?resolved/n:0,xr=n?rejected/n:0,resr=n?researched/n:0;
  const rawScore=n?clamp(35+35*qr+15*rr+10*resr-20*xr):clamp(Number(s.reliability_score||50)*0.75);
  const priorScore=clamp(Number(s.quality_score??50)*0.60+Number(s.reliability_score??75)*0.40);
  const sampleWeight=Math.min(1,n/20);
  const score=clamp(priorScore*(1-sampleWeight)+rawScore*sampleWeight);
  let lifecycle=s.lifecycle_state,enabled=s.enabled;
  const auto=String(s.metadata?.discovered_by||"")==="self_evolution";
  if(auto&&lifecycle==="canary"&&n>=5&&(qualified>=1||(n>=10&&researched>=7&&xr<0.3&&rr>=0.7))){lifecycle="active";activated++}
  if(auto&&n>=15&&qualified===0&&(xr>=0.7||rr<0.15)){lifecycle="paused";enabled=false;paused++}
  else if(auto&&n>=12&&(xr>=0.6||rr<0.3)&&lifecycle==="active")lifecycle="degraded";
  await db.schema("booked_solid").from("source_catalog").update({
   quality_score:score,lifecycle_state:lifecycle,enabled,
   metadata:{...(s.metadata??{}),score_policy_version:2,score_sample_size:n,score_sample_weight:Number(sampleWeight.toFixed(3)),score_raw:Number(rawScore.toFixed(3)),score_prior:Number(priorScore.toFixed(3)),score_updated_at:new Date().toISOString()},
   updated_at:new Date().toISOString()
  }).eq("id",s.id);
  await db.schema("booked_solid").from("source_performance_daily").upsert({day:today,source_slug:s.slug,discovered_count:n,resolved_count:resolved,researched_count:researched,qualified_count:qualified,rejected_count:rejected,unresolved_count:n-resolved,quality_score:score},{onConflict:"day,source_slug"});
 }
 return {activated,paused};
}
const GENES=[
 {k:"commercial-estimate-volume",intent:"commercial_estimation",q:"{trade} contractor {location} commercial estimates proposal",offer:"custom_estimator"},
 {k:"proposal-turnaround",intent:"quote_speed",q:"{trade} {location} quote turnaround proposal workflow",offer:"custom_estimator"},
 {k:"multi-crew-scale",intent:"scale",q:"{trade} {location} multiple crews estimating workflow",offer:"automation"},
 {k:"service-contracts",intent:"recurring_contracts",q:"{trade} {location} service contracts quoting",offer:"automation"},
 {k:"change-order-pressure",intent:"change_orders",q:"{trade} {location} change order approval workflow",offer:"penmark"},
 {k:"quickbooks-workflow",intent:"workflow_complexity",q:"{trade} {location} QuickBooks estimates workflow",offer:"automation"},
 {k:"hiring-estimator",intent:"capacity_signal",q:"{trade} {location} hiring estimator preconstruction project manager",offer:"custom_estimator"},
 {k:"permit-activity",intent:"recent_project_activity",q:"{trade} {location} recent permits contractor active projects",offer:"custom_estimator"},
 {k:"multi-location-growth",intent:"multi_location_growth",q:"{trade} {location} multiple locations branches service areas",offer:"automation"},
 {k:"service-area-expansion",intent:"market_expansion",q:"{trade} {location} expanding service area new location",offer:"automation"},
 {k:"commercial-maintenance",intent:"commercial_recurring",q:"{trade} {location} commercial maintenance service agreement contract",offer:"automation"},
 {k:"field-quote-speed",intent:"field_quote_speed",q:"{trade} {location} same day estimate onsite quote fast proposal",offer:"custom_estimator"}
];
async function evolveStrategies(maxNew=2,maxEnabled=180){
 const {data:all}=await db.schema("booked_solid").from("search_strategies").select("*").eq("enabled",true).order("performance_score",{ascending:false}).limit(Math.max(200,Number(maxEnabled||180)+20));
 if((all??[]).length>=Number(maxEnabled||180)){
  const generated=(all??[]).filter((x:any)=>x.metadata?.generated_by==="self_evolution"&&Number(x.uses_count||0)>=10&&Number(x.performance_score||50)<25).sort((a:any,b:any)=>Number(a.performance_score)-Number(b.performance_score)).slice(0,5);
  for(const x of generated)await db.schema("booked_solid").from("search_strategies").update({enabled:false,lifecycle_state:"paused",updated_at:new Date().toISOString()}).eq("id",x.id);
 }
 const existing=new Set((all??[]).map((x:any)=>x.slug));const parents=(all??[]).filter((x:any)=>Number(x.performance_score||0)>=45&&x.trade).slice(0,20);
 let made=0;const seed=Math.floor(Date.now()/86400000);
 for(let pi=0;pi<parents.length&&made<maxNew;pi++){
  const p=parents[(pi+seed)%parents.length];const gene=GENES[(seed+pi+Number(p.uses_count||0))%GENES.length];
  const slug=("evo-"+slugify(p.trade)+"-"+gene.k+"-g"+(Number(p.generation||0)+1)).slice(0,95);
  if(existing.has(slug))continue;
  const q=gene.q.replace("{trade}",String(p.trade));
  const {error}=await db.schema("booked_solid").from("search_strategies").insert({
   slug,trade:p.trade,geography:"US",intent:gene.intent,query_template:q,offer_hint:gene.offer,
   exploration_weight:1.6,performance_score:Math.max(42,Number(p.performance_score||50)*0.82),
   enabled:true,parent_strategy_id:p.id,generation:Number(p.generation||0)+1,lifecycle_state:"testing",
   metadata:{generated_by:"self_evolution",gene:gene.k,parent_slug:p.slug,created_reason:"exploration_variant"}
  });
  if(!error){existing.add(slug);made++}
 }
 return made;
}
async function reviewMarkets(){
 const [{data:markets},{data:companies},{data:leads}]=await Promise.all([
  db.schema("booked_solid").from("market_catalog").select("*"),
  db.schema("booked_solid").from("companies").select("id,metadata,status,created_at").gte("created_at",new Date(Date.now()-45*86400000).toISOString()),
  db.schema("booked_solid").from("leads").select("company_id,status")
 ]);
 const qual=new Set((leads??[]).filter((l:any)=>["qualified","message_ready","queued","sent","replied","meeting","won"].includes(l.status)).map((l:any)=>l.company_id));
 for(const m of markets??[]){
  const cs=(companies??[]).filter((c:any)=>String(c.metadata?.search_market??c.metadata?.source_market??c.metadata?.geography??"")===m.display_name);const n=cs.length,q=cs.filter((c:any)=>qual.has(c.id)).length;
  const score=n?clamp(42+40*(q/n)+Math.min(12,n*0.5)):Number(m.quality_score||50);
  let lifecycle=m.lifecycle_state;if(lifecycle==="testing"&&n>=4)lifecycle=q>=1?"active":"testing";
  await db.schema("booked_solid").from("market_catalog").update({discovered_count:n,qualified_count:q,quality_score:score,lifecycle_state:lifecycle,updated_at:new Date().toISOString()}).eq("id",m.id);
 }
}
async function queueCanaries(limit=2){
 const {data:sources}=await db.schema("booked_solid").from("source_catalog").select("*").eq("enabled",true).in("lifecycle_state",["canary","active"]).order("exploration_weight",{ascending:false});
 const autos=(sources??[]).filter((s:any)=>["generic_socrata","generic_arcgis"].includes(String(s.metadata?.adapter||""))).sort((a:any,b:any)=>{
  const at=a.last_success_at?1:0,bt=b.last_success_at?1:0;if(at!==bt)return at-bt;
  return (Number(b.quality_score||50)+Number(b.exploration_weight||1)*8)-(Number(a.quality_score||50)+Number(a.exploration_weight||1)*8);
 });
 if(!autos.length)return 0;
 let queued=0;
 for(const s of autos){
  if(queued>=limit)break;
  const recentSince=new Date(Date.now()-6*3600000).toISOString();
  const {data:recent}=await db.schema("booked_solid").from("work_queue").select("id,status,created_at").eq("kind","discover").contains("payload",{source_slug:s.slug}).gte("created_at",recentSince).limit(1);
  if((recent??[]).length)continue;
  if(s.last_success_at&&Date.now()-new Date(s.last_success_at).getTime()<6*3600000)continue;

  const tradeHint=sourceTradeHint(String(s.name||""),String(s.metadata?.source_kind||"")+" "+String(s.metadata?.public_url||""));
  let strategy:any=null;
  if(tradeHint!=="Mixed"){
   const {data:specific}=await db.schema("booked_solid").from("search_strategies").select("*").eq("enabled",true).eq("trade",tradeHint).order("performance_score",{ascending:false}).limit(1).maybeSingle();
   strategy=specific;
  }
  if(!strategy){
   const {data:mixed}=await db.schema("booked_solid").from("search_strategies").select("*").eq("enabled",true).eq("trade","Mixed").order("performance_score",{ascending:false}).limit(1).maybeSingle();
   strategy=mixed;
  }
  if(!strategy)continue;

  const marketName=String(s.metadata?.market_hint||"US");let lat=null,lon=null;
  if(marketName!=="US"){
   const {data:m}=await db.schema("booked_solid").from("market_catalog").select("*").eq("display_name",marketName).maybeSingle();
   if(m){lat=m.latitude;lon=m.longitude}
  }
  await db.schema("booked_solid").from("work_queue").insert({kind:"discover",priority:74+Number(s.exploration_weight||1),payload:{
   strategy_id:strategy.id,strategy_slug:strategy.slug,trade:tradeHint,geography:marketName,intent:"source_canary",
   query_template:strategy.query_template,source_id:s.id,source_slug:s.slug,latitude:lat,longitude:lon,offer_hint:strategy.offer_hint,canary:true,
   canary_trade_hint:tradeHint
  },status:"pending"});
  queued++;
 }
 return queued;
}
async function huntCycle(){
 const {data:markets}=await db.schema("booked_solid").from("market_catalog").select("*").in("lifecycle_state",["testing","active"]);
 const day=Math.floor(Date.now()/86400000);let discovered=0;
 for(let i=0;i<3;i++){const q=HUNT_QUERIES[(day+i)%HUNT_QUERIES.length];try{discovered+=await huntSocrata(q,markets??[])}catch(e){console.error("socrata hunt",e)}}
 const aq=HUNT_QUERIES[(day+4)%HUNT_QUERIES.length];try{discovered+=await huntArcGIS(aq,markets??[])}catch(e){console.error("arcgis hunt",e)}
 return discovered;
}
async function cycle(mode:string){
 const {data:settings}=await db.schema("booked_solid").from("evolution_settings").select("*").eq("id",true).single();
 if(settings&&!settings.enabled)return {ok:true,paused:true,reason:"evolution_disabled"};
 if(settings?.allow_paid_search_activation||settings?.allow_email_configuration_changes)throw new Error("unsafe_evolution_setting_rejected");
 const {data:run}=await db.schema("booked_solid").from("evolution_runs").insert({mode,status:"started"}).select("*").single();
 try{
  let discovered=0,validation:any={validated:0,promoted:0,rejected:0},strategies=0,queued=0;
  const sourceReview=await reviewSources();await reviewMarkets();
  if(mode!=="review"){
   if(settings?.source_hunt_enabled!==false)discovered=await huntCycle();
   if(settings?.source_hunt_enabled!==false)validation=await validateCandidates(Number(settings?.max_candidate_validations_per_cycle||5),Number(settings?.max_canary_sources||6));
   if(settings?.strategy_evolution_enabled!==false&&mode!=="sources")strategies=await evolveStrategies(Number(settings?.max_new_strategies_per_cycle||2),Number(settings?.max_enabled_strategies||180));
   queued=await queueCanaries(2);
  }
  const notes={source_review:sourceReview,validation};
  await db.schema("booked_solid").from("evolution_runs").update({
   status:"done",sources_discovered:discovered,sources_validated:validation.validated,sources_promoted:validation.promoted,
   strategies_created:strategies,canary_jobs_queued:queued,notes,finished_at:new Date().toISOString()
  }).eq("id",run.id);
  return {ok:true,mode,run_id:run.id,sources_discovered:discovered,sources_validated:validation.validated,sources_promoted:validation.promoted,strategies_created:strategies,canary_jobs_queued:queued,source_review:sourceReview};
 }catch(e){
  const msg=e instanceof Error?e.message:String(e);
  if(run?.id)await db.schema("booked_solid").from("evolution_runs").update({status:"failed",notes:{error:msg},finished_at:new Date().toISOString()}).eq("id",run.id);
  throw e;
 }
}
async function health(){
 const [{count:cand},{count:auto},{count:markets},{count:strategies},{data:last}]=await Promise.all([
  db.schema("booked_solid").from("source_candidates").select("*",{count:"exact",head:true}),
  db.schema("booked_solid").from("source_catalog").select("*",{count:"exact",head:true}).eq("enabled",true).in("lifecycle_state",["canary","active"]),
  db.schema("booked_solid").from("market_catalog").select("*",{count:"exact",head:true}).in("lifecycle_state",["testing","active"]),
  db.schema("booked_solid").from("search_strategies").select("*",{count:"exact",head:true}).eq("enabled",true),
  db.schema("booked_solid").from("evolution_runs").select("*").order("started_at",{ascending:false}).limit(1).maybeSingle()
 ]);
 return {ok:true,system:"booked-solid-self-evolution",candidate_sources:cand??0,enabled_sources:auto??0,markets:markets??0,enabled_strategies:strategies??0,last_run:last??null,safety:{paid_search_activation:false,unknown_source_direct_activation:false,canary_required:true,error_circuit_breaker:true,email_gate_untouched:true}};
}

Deno.serve(async req=>{
 try{
  if(req.method==="OPTIONS")return new Response("ok",{headers:H});
  const body=req.method==="POST"?await req.json().catch(()=>({})):{};
  const action=body.action??new URL(req.url).searchParams.get("action")??"health";
  if(action==="health")return out(await health());
  if(action==="review")return out(await cycle("review"));
  if(action==="cycle")return out(await cycle("cycle"));
  if(action==="hunt")return out(await cycle("hunt"));
  if(action==="sources")return out(await cycle("sources"));
  return out({ok:false,error:"unknown_action",allowed:["health","review","cycle","hunt","sources"]},400);
 }catch(e){console.error(e);return out({ok:false,error:e instanceof Error?e.message:String(e)},500)}
});
