import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
const H={"Content-Type":"application/json","Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type"};
const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const out=(x:unknown,s=200)=>new Response(JSON.stringify(x),{status:s,headers:H});
function domainOf(raw:string){try{return new URL(raw).hostname.replace(/^www\./,"").toLowerCase()}catch{return null}}
function normalize(s:string){return s.toLowerCase().replace(/[^a-z0-9]+/g," ").trim()}
function clean(html:string){return html.replace(/<script[\s\S]*?<\/script>/gi," ").replace(/<style[\s\S]*?<\/style>/gi," ").replace(/<[^>]+>/g," ").replace(/&nbsp;/gi," ").replace(/&amp;/gi,"&").replace(/\s+/g," ").trim().slice(0,30000)}
function mailboxKind(email:string){
 const lp=String(email||"").toLowerCase().split("@")[0];
 if(!lp)return "missing";
 if(lp.length<2||["first","firstname","test","example"].includes(lp))return "weak";
 if(/(employment|careers?|jobs?|support|concierge|reservations?|dining|spa|events?|groups?|humanresources|human-resources|noreply|no-reply|donotreply|do-not-reply)/.test(lp)||/^(hr)$/.test(lp))return "weak";
 if(/^(info|office|admin|hello|contact|sales|marketing|service|team|inquiries|inquiry)$/.test(lp))return "generic";
 return "direct";
}
function decisionRoleScore(role:string){
 const r=String(role||"").toLowerCase();
 if(/\b(owner|founder|chief executive|ceo|managing partner|principal)\b/.test(r))return 45;
 if(/\bpresident\b/.test(r)&&!/\bvice president\b/.test(r))return 45;
 if(/\b(vice president|vp|director|head of|operations|general manager|gm)\b/.test(r))return 35;
 if(/\b(estimat|preconstruction|project executive|project manager|office manager)\b/.test(r))return 28;
 if(/\bmanager\b/.test(r))return 18;
 return 0;
}
function contactResolutionScore(c:any){
 const kind=mailboxKind(c?.email||"");const role=decisionRoleScore(c?.role||"");
 let score=role+(c?.full_name?10:0)+Math.min(10,Number(c?.email_confidence||0)/10);
 if(kind==="direct")score+=30;else if(kind==="generic")score+=15;else if(kind==="weak")score-=35;
 return Math.max(0,Math.min(100,Math.round(score)));
}
function nameParts(name:string){return normalize(String(name||"")).split(" ").filter(Boolean)}
function emailMatchesName(email:string,name:string){
 const lp=String(email||"").toLowerCase().split("@")[0].replace(/[^a-z0-9._-]/g,"");
 const p=nameParts(name);if(p.length<2||!lp)return false;
 const first=p[0],last=p[p.length-1],fi=first[0]||"";
 const compact=lp.replace(/[._-]/g,"");
 return lp===first||lp===last||lp===first+"."+last||lp===first+"_"+last||lp===first+"-"+last||
        compact===first+last||compact===fi+last||compact===first+last[0];
}
async function findPublicNamedEmail(company:any,person:any,contacts:any[]){
 if(!company?.website_url||!person?.full_name)return null;
 const domain=String(company.canonical_domain||domainOf(company.website_url)||"").toLowerCase();if(!domain)return null;
 const known=(contacts||[]).filter((x:any)=>x.email&&mailboxKind(x.email)==="direct"&&emailMatchesName(x.email,person.full_name));
 if(known.length)return String(known.sort((a:any,b:any)=>Number(b.email_confidence||0)-Number(a.email_confidence||0))[0].email).toLowerCase();
 let root:URL;try{root=new URL(company.website_url)}catch{return null}
 const paths=["/","/about","/team","/our-team","/leadership","/contact"];
 const pages=await Promise.all(paths.map(async p=>{try{
   const r=await fetch(new URL(p,root),{redirect:"follow",signal:AbortSignal.timeout(5000),headers:{"User-Agent":"BookedSolidResearchBot/1.0 (+https://www.bookedsolidcopy.com/)"}});
   if(!r.ok)return null;const h=await r.text();return {h,visible:clean(h)};
 }catch{return null}}));
 for(const pg of pages){
   if(!pg)continue;
   const hay=(pg.h+" "+pg.visible);if(!normalize(hay).includes(normalize(person.full_name)))continue;
   const emails=[...new Set(hay.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi)??[])].map((e:string)=>e.toLowerCase());
   const match=emails.find((e:string)=>{const ed=e.split("@")[1];return (ed===domain||ed.endsWith("."+domain))&&mailboxKind(e)==="direct"&&emailMatchesName(e,person.full_name)});
   if(match)return match;
 }
 return null;
}

function signalTypes(text:string){const r:[string,RegExp][]=[["estimation_pain",/(estimate|estimating|proposal|quoting|quote|pricing)/i],["change_orders",/(change order|change-order|scope change|additional work|signed change)/i],["field_quoting",/(on[- ]site quote|field quote|technician quote|instant quote|same[- ]day estimate)/i],["workflow_complexity",/(crm|quickbooks|spreadsheet|multiple locations|project management|dispatch|work order)/i],["buyer_signal",/(hiring|join our team|estimator|preconstruction estimator|project estimator|estimating manager)/i],["scale_signal",/(multiple locations|branches|service areas|portfolio|properties managed|units managed|rooms|regional offices)/i],["recurring_contracts",/(maintenance agreement|service agreement|maintenance contract|service contract)/i],["property_operations",/(property management|vacation rental|guest services|owner services|owner portal|hotel|resort|reservations)/i]];return r.filter(([,x])=>x.test(text)).map(([t])=>t)}
async function updateStrategyLearning(strategyId:string|undefined,outcome:number,newQualified=false){if(!strategyId)return;try{const {data:s}=await db.schema("booked_solid").from("search_strategies").select("performance_score,qualified_count,uses_count,lifecycle_state,metadata,enabled").eq("id",strategyId).maybeSingle();if(!s)return;const perf=Math.max(1,Math.min(95,Number(s.performance_score??50)*0.85+outcome*0.15));let lifecycle=String(s.lifecycle_state||"active"),enabled=Boolean(s.enabled);const generated=s.metadata?.generated_by==="self_evolution";if(generated&&newQualified){lifecycle="active";enabled=true}else if(generated&&lifecycle==="testing"&&Number(s.uses_count||0)>=5&&perf>=55){lifecycle="active"}else if(generated&&Number(s.uses_count||0)>=10&&perf<25){lifecycle="paused";enabled=false}else if(generated&&Number(s.uses_count||0)>=8&&perf<35){lifecycle="degraded"}await db.schema("booked_solid").from("search_strategies").update({performance_score:perf,qualified_count:Number(s.qualified_count??0)+(newQualified?1:0),lifecycle_state:lifecycle,enabled,updated_at:new Date().toISOString()}).eq("id",strategyId);}catch{}}
const ALLOW_PAID_SEARCH=false;
async function search(q:string){
 const tavily=ALLOW_PAID_SEARCH?Deno.env.get("TAVILY_API_KEY"):null;
 if(tavily){
  const r=await fetch("https://api.tavily.com/search",{method:"POST",signal:AbortSignal.timeout(12000),headers:{"Content-Type":"application/json"},body:JSON.stringify({api_key:tavily,query:q,search_depth:"advanced",max_results:20,include_answer:false,include_raw_content:false,exclude_domains:["reddit.com","youtube.com","quora.com","facebook.com","linkedin.com","yelp.com","angi.com","homeadvisor.com","thumbtack.com","porch.com","houzz.com","bobvila.com","forbes.com","localservicequotes.com","centrfederal.ru","indeed.com","ziprecruiter.com","glassdoor.com","monster.com","careerbuilder.com","simplyhired.com","zippia.com","talent.com","jooble.org","builtin.com","bebee.com","vaia.com","theladders.com","icims.com","jobleads.com","lever.co","greenhouse.io","greenhouse.com","workable.com","smartrecruiters.com","ashbyhq.com","bamboohr.com"]})});
  if(!r.ok)throw new Error("tavily_search_http_"+r.status);
  const j=await r.json();return {provider:"tavily",results:(j.results??[]).map((x:any)=>({url:x.url,title:x.title,description:x.content}))};
 }
 const brave=ALLOW_PAID_SEARCH?Deno.env.get("BRAVE_SEARCH_API_KEY"):null;
 if(brave){
  const u=new URL("https://api.search.brave.com/res/v1/web/search");u.searchParams.set("q",q);u.searchParams.set("country","US");u.searchParams.set("search_lang","en");u.searchParams.set("count","20");
  const r=await fetch(u,{headers:{"Accept":"application/json","X-Subscription-Token":brave}});if(!r.ok)throw new Error("brave_search_http_"+r.status);
  const j=await r.json();return {provider:"brave",results:(j.web?.results??[]).map((x:any)=>({url:x.url,title:x.title,description:x.description}))};
 }
 throw new Error("SEARCH_PROVIDER_NOT_CONFIGURED:TAVILY_API_KEY_OR_BRAVE_SEARCH_API_KEY");
}
function osmSelectors(trade:string){
 const t=String(trade||"");
 const m:any={
  "Roofing":[`["craft"="roofer"]`],"Commercial Roofing":[`["craft"="roofer"]`],
  "Plumbing":[`["craft"="plumber"]`],"Electrical":[`["craft"="electrician"]`],
  "HVAC":[`["craft"~"^(hvac|heating_engineer)$"]`],"Commercial HVAC":[`["craft"~"^(hvac|heating_engineer)$"]`],
  "Painting":[`["craft"="painter"]`],"Flooring":[`["craft"="floorer"]`],
  "Landscaping":[`["craft"="landscaper"]`],"Windows":[`["craft"="window_construction"]`],
  "Deck Builder":[`["craft"="carpenter"]`],"Deck Patio":[`["craft"="carpenter"]`],
  "Cabinet":[`["craft"="carpenter"]`],
  "Remodeling":[`["office"="construction_company"]`,`["craft"="builder"]`,`["craft"="carpenter"]`],
  "Bathroom Remodeling":[`["office"="construction_company"]`,`["craft"="builder"]`],
  "Kitchen Remodeling":[`["office"="construction_company"]`,`["craft"="builder"]`],
  "Kitchen Bath Remodeling":[`["office"="construction_company"]`,`["craft"="builder"]`],
  "Home Builder":[`["craft"="builder"]`,`["office"="construction_company"]`],
  "Custom Home Builder":[`["craft"="builder"]`,`["office"="construction_company"]`],
  "Siding":[`["craft"="roofer"]`,`["craft"="carpenter"]`],
  "General Contractor":[`["office"="construction_company"]`,`["craft"="builder"]`],
  "Commercial Contractor":[`["office"="construction_company"]`,`["craft"="builder"]`],
  "Construction":[`["office"="construction_company"]`,`["craft"="builder"]`],
  "Concrete":[`["office"="construction_company"]`,`["craft"="builder"]`],
  "Mixed":[`["office"="construction_company"]`,`["craft"="builder"]`,`["craft"="roofer"]`,`["craft"="plumber"]`,`["craft"="electrician"]`,`["craft"~"^(hvac|heating_engineer)$"]`,`["craft"="painter"]`],
  "Property Operations":[`["office"="property_management"]`]
 };
 return m[t]??[];
}
async function searchOSM(trade:string,location:string,latArg?:number,lonArg?:number){
 const sels=osmSelectors(trade);if(!sels.length)return {provider:"openstreetmap_overpass",results:[]};
 let lat=Number(latArg),lon=Number(lonArg);
 if(!Number.isFinite(lat)||!Number.isFinite(lon)){
  const nu=new URL("https://nominatim.openstreetmap.org/search");nu.searchParams.set("format","jsonv2");nu.searchParams.set("limit","1");nu.searchParams.set("countrycodes","us");nu.searchParams.set("q",location);nu.searchParams.set("email","info@bookedsolidcopy.com");
  const nr=await fetch(nu,{signal:AbortSignal.timeout(7000),headers:{"User-Agent":"BookedSolidResearchBot/1.0 (+https://www.bookedsolidcopy.com/)","Accept":"application/json"}});
  if(!nr.ok)throw new Error("nominatim_http_"+nr.status);const gj=await nr.json();if(!gj?.[0])return {provider:"openstreetmap_overpass",results:[]};lat=Number(gj[0].lat);lon=Number(gj[0].lon);
 }
 const parts=sels.map((s:string)=>`nwr(around:40000,${lat},${lon})${s};`).join("");
 const oq=`[out:json][timeout:18];(${parts});out center tags 50;`;
 let or:any=null;let lastStatus=0;for(const base of ["https://overpass.private.coffee/api/interpreter","https://overpass-api.de/api/interpreter","https://maps.mail.ru/osm/tools/overpass/api/interpreter"]){try{const rr=await fetch(base,{method:"POST",signal:AbortSignal.timeout(18000),headers:{"User-Agent":"BookedSolidResearchBot/1.0 (+https://www.bookedsolidcopy.com/)","Accept":"application/json","Content-Type":"application/x-www-form-urlencoded"},body:new URLSearchParams({data:oq})});lastStatus=rr.status;if(rr.ok){or=rr;break;}}catch{}}if(!or)throw new Error("overpass_http_"+lastStatus);const oj=await or.json();const outRows:any[]=[];
 for(const el of oj.elements??[]){const tags=el.tags??{};const name=String(tags.name??tags.operator??"").trim();let url=String(tags.website??tags["contact:website"]??tags.url??"").trim();if(!name||!url)continue;if(!/^https?:\/\//i.test(url))url="https://"+url.replace(/^\/\//,"");outRows.push({url,title:name,description:[tags.description,tags["contact:phone"],tags.addr_city,tags.addr_state].filter(Boolean).join(" · ")});}
 return {provider:"openstreetmap_overpass",results:outRows.slice(0,20)};
}

function coreTokens(s:string){const stop=new Set(["the","and","inc","llc","corp","corporation","company","co","contractor","contractors","construction","services","service","group","roofing","plumbing","electrical","electric","hvac","mechanical","remodeling","builders","builder"]);return normalize(s).split(" ").filter(x=>x.length>=3&&!stop.has(x));}
function namesMatch(a:string,b:string){const na=normalize(a),nb=normalize(b);if(!na||!nb)return false;if(na.includes(nb)||nb.includes(na))return true;const A=coreTokens(a),B=coreTokens(b);if(!A.length||!B.length)return false;const hits=A.filter(x=>B.includes(x)).length;return hits>=Math.min(2,Math.min(A.length,B.length));}
async function searchWikidata(location:string,latArg?:number,lonArg?:number){
 const lat=Number(latArg),lon=Number(lonArg);if(!Number.isFinite(lat)||!Number.isFinite(lon))return {provider:"wikidata_sparql",results:[]};
 const q=`SELECT DISTINCT ?item ?itemLabel ?website WHERE {
 SERVICE wikibase:around { ?item wdt:P625 ?coord. bd:serviceParam wikibase:center "Point(${lon} ${lat})"^^geo:wktLiteral. bd:serviceParam wikibase:radius "55". }
 ?item wdt:P31/wdt:P279* wd:Q27686. ?item wdt:P856 ?website.
 SERVICE wikibase:label { bd:serviceParam wikibase:language "en". }
 } LIMIT 25`;
 const u=new URL("https://query.wikidata.org/sparql");u.searchParams.set("query",q);u.searchParams.set("format","json");
 const r=await fetch(u,{signal:AbortSignal.timeout(15000),headers:{"Accept":"application/sparql-results+json","User-Agent":"BookedSolidResearchBot/1.0 (+https://www.bookedsolidcopy.com/)"}});
 if(!r.ok)throw new Error("wikidata_http_"+r.status);const j=await r.json();
 return {provider:"wikidata_sparql",results:(j.results?.bindings??[]).map((x:any)=>({url:x.website?.value,title:x.itemLabel?.value||"Hotel / Resort",description:"Wikidata-listed hotel or lodging property near "+location})).filter((x:any)=>x.url)};
}
function inferPermitTrade(text:string){
 const t=String(text||"").toLowerCase();
 if(/roof|reroof/.test(t))return "Roofing";
 if(/plumb|pipe|piping|gas permit/.test(t))return "Plumbing";
 if(/electrical|electric|low voltage|fire alarm/.test(t))return "Electrical";
 if(/hvac|mechanical|boiler|air conditioning|heating|ventilation|chiller/.test(t))return "HVAC";
 if(/paint/.test(t))return "Painting";
 if(/remodel|renovat|alteration|tenant finish|interior|kitchen|bathroom/.test(t))return "Remodeling";
 if(/new construction|erect|general contractor|construction|addition/.test(t))return "General Contractor";
 return null;
}
function companyLikePermitName(name:string){
 const n=String(name||"").trim();
 if(!n||n.length<3)return false;
 if(/^blanket\s*:|^owner\b/i.test(n))return false;
 return /\b(llc|l\.l\.c\.|inc\.?|corp\.?|corporation|company|co\.?|construction|contracting|contractors?|builders?|building|roof(?:ing)?|plumb(?:ing)?|electric(?:al)?|mechanical|hvac|heating|cooling|services?|systems?|group|enterprises?|maintenance|remodel(?:ing)?|renovation|painting)\b/i.test(n);
}
function targetPermitCompanyName(name:string){
 const n=String(name||"").trim();
 if(!n||/\b(consulting|architect|architecture|engineering|associates?|properties|realty|real estate|holdings?)\b/i.test(n))return false;
 return /\b(construction|contracting|contractors?|builders?|building|roof(?:ing)?|plumb(?:ing)?|electric(?:al)?|mechanical|hvac|heating|cooling|foundation|services?|systems?|maintenance|remodel(?:ing)?|renovation|painting|masonry|concrete|carpentry|exteriors?|siding|windows?)\b/i.test(n);
}
function permitSourceUrl(slug:string){
 const m:any={
  chicago_building_permits:"https://data.cityofchicago.org/d/ydr8-5enu",
  nyc_dob_permits:"https://data.cityofnewyork.us/d/qnmk-7xra",
  austin_construction_permits:"https://data.austintexas.gov/d/3syk-w9eu",
  seattle_building_permits:"https://data.seattle.gov/d/76t5-zqzr",
  boston_building_permits:"https://data.boston.gov/dataset/approved-building-permits",
  sf_building_permit_contacts:"https://data.sf.gov/Housing-and-Buildings/Building-Permits-with-Permit-Contacts/9itm-3rmi",
  philadelphia_permit_contractors:"https://opendataphilly.org/datasets/licenses-and-inspections-building-and-zoning-permits/",
  philadelphia_trade_licenses:"https://opendataphilly.org/datasets/licenses-and-inspections-trade-licenses/",
  denver_commercial_permits:"https://www.denvergov.org/opendata/dataset/city-and-county-of-denver-commercial-building-permits",
  oregon_harp_contractors:"https://data.oregon.gov/Business/HARP-Contractors/yp6u-mepw"
 };
 return m[slug]??"https://www.bookedsolidcopy.com/";
}
function inferSiteTrade(text:string){
 const t=String(text||"").toLowerCase();
 if(/property management|property manager|rental management|vacation rental|multifamily management/.test(t))return "Property Operations";
 if(/roofing|roof replacement|roof repair|commercial roof/.test(t))return "Roofing";
 if(/hvac|heating and cooling|air conditioning|furnace|heat pump/.test(t))return "HVAC";
 if(/plumbing|plumber|drain|water heater/.test(t))return "Plumbing";
 if(/electrical contractor|electrician|electrical services/.test(t))return "Electrical";
 if(/painting contractor|commercial painting|residential painting/.test(t))return "Painting";
 if(/remodeling|renovation|kitchen remodel|bathroom remodel/.test(t))return "Remodeling";
 if(/general contractor|commercial contractor|construction company|design[- ]build|construction services/.test(t))return "General Contractor";
 return null;
}
async function searchPermitSource(slug:string,trade:string,location:string,lat?:number,lon?:number){
 let permits:any[]=[];
 if(slug==="chicago_building_permits"){
  const u=new URL("https://data.cityofchicago.org/resource/ydr8-5enu.json");u.searchParams.set("$limit","120");u.searchParams.set("$order","issue_date DESC");
  const r=await fetch(u,{signal:AbortSignal.timeout(12000),headers:{"Accept":"application/json","User-Agent":"BookedSolidResearchBot/1.0"}});if(!r.ok)throw new Error("chicago_permits_http_"+r.status);const rows=await r.json();
  for(const row of rows){for(let i=1;i<=15;i++){const n=row["contact_"+i+"_name"];if(n)permits.push({name:String(n),desc:String(row.work_description??row.permit_type??""),date:row.issue_date??"",cost:row.reported_cost??null});}}
 }else if(slug==="nyc_dob_permits"){
  const u=new URL("https://data.cityofnewyork.us/resource/qnmk-7xra.json");u.searchParams.set("$limit","120");u.searchParams.set("$order","issued_date DESC");
  const r=await fetch(u,{signal:AbortSignal.timeout(12000),headers:{"Accept":"application/json","User-Agent":"BookedSolidResearchBot/1.0"}});if(!r.ok)throw new Error("nyc_permits_http_"+r.status);const rows=await r.json();
  permits=rows.filter((x:any)=>x.applicant_business_name).map((x:any)=>({name:String(x.applicant_business_name),desc:String(x.job_description??x.work_type??""),date:x.issued_date??"",cost:x.estimated_job_costs??null}));
 }else if(slug==="austin_construction_permits"){
  const u=new URL("https://data.austintexas.gov/resource/3syk-w9eu.json");u.searchParams.set("$limit","150");u.searchParams.set("$order","issue_date DESC");u.searchParams.set("$where","contractor_company_name is not null");
  const r=await fetch(u,{signal:AbortSignal.timeout(12000),headers:{"Accept":"application/json","User-Agent":"BookedSolidResearchBot/1.0"}});if(!r.ok)throw new Error("austin_permits_http_"+r.status);const rows=await r.json();
  permits=rows.filter((x:any)=>x.contractor_company_name).map((x:any)=>({name:String(x.contractor_company_name),desc:String(x.description??x.permit_type_desc??"")+" · "+String(x.contractor_trade??""),date:x.issue_date??"",cost:null,trade_hint:inferPermitTrade(String(x.contractor_trade??"")+" "+String(x.description??""))}));
 }else if(slug==="seattle_building_permits"){
  const u=new URL("https://data.seattle.gov/resource/76t5-zqzr.json");u.searchParams.set("$limit","150");u.searchParams.set("$order","issueddate DESC");u.searchParams.set("$where","contractorcompanyname is not null");
  const r=await fetch(u,{signal:AbortSignal.timeout(12000),headers:{"Accept":"application/json","User-Agent":"BookedSolidResearchBot/1.0"}});if(!r.ok)throw new Error("seattle_permits_http_"+r.status);const rows=await r.json();
  permits=rows.filter((x:any)=>x.contractorcompanyname).map((x:any)=>({name:String(x.contractorcompanyname),desc:String(x.description??x.permittypedesc??x.permittypemapped??""),date:x.issueddate??"",cost:x.estprojectcost??null,trade_hint:inferPermitTrade(String(x.description??"")+" "+String(x.permittypedesc??x.permittypemapped??""))}));

 }else if(slug==="boston_building_permits"){
  const u=new URL("https://data.boston.gov/api/3/action/datastore_search");u.searchParams.set("resource_id","6ddcd912-32a0-43df-9908-63574f8c7e77");u.searchParams.set("limit","250");u.searchParams.set("sort","issued_date desc");
  const r=await fetch(u,{signal:AbortSignal.timeout(15000),headers:{"Accept":"application/json","User-Agent":"BookedSolidResearchBot/1.0 (+https://www.bookedsolidcopy.com/)"}});
  if(!r.ok)throw new Error("boston_permits_http_"+r.status);const j=await r.json();if(!j?.success)throw new Error("boston_permits_api_error");const rows=j?.result?.records??[];
  permits=rows.filter((x:any)=>companyLikePermitName(String(x.applicant??""))).map((x:any)=>({name:String(x.applicant),desc:String(x.permittypedescr??x.description??"")+" · "+String(x.comments??"").slice(0,220),date:x.issued_date??"",cost:x.declared_valuation??null,trade_hint:inferPermitTrade(String(x.worktype??"")+" "+String(x.permittypedescr??"")+" "+String(x.description??"")+" "+String(x.comments??""))}));
 }else if(slug==="sf_building_permit_contacts"){
  const u=new URL("https://data.sfgov.org/resource/9itm-3rmi.json");u.searchParams.set("$select","firm_name,role,permit_number,issued_date,estimated_cost,description,firm_city,firm_state,permit_type_definition,reroof");u.searchParams.set("$where","firm_name is not null");u.searchParams.set("$order","issued_date DESC");u.searchParams.set("$limit","180");
  const r=await fetch(u,{signal:AbortSignal.timeout(15000),headers:{"Accept":"application/json","User-Agent":"BookedSolidResearchBot/1.0 (+https://www.bookedsolidcopy.com/)"}});
  if(!r.ok)throw new Error("sf_permits_http_"+r.status);const rows=await r.json();
  permits=rows.filter((x:any)=>x.firm_name&&companyLikePermitName(String(x.firm_name))).map((x:any)=>({name:String(x.firm_name),desc:String(x.permit_type_definition??"")+" · "+String(x.description??"")+" · role "+String(x.role??""),date:x.issued_date??"",cost:x.estimated_cost??null,trade_hint:inferPermitTrade(String(x.permit_type_definition??"")+" "+String(x.description??"")+" "+String(x.reroof??""))}));

 }else if(slug==="philadelphia_permit_contractors"){
  const u=new URL("https://services.arcgis.com/fLeGjb7u4uXqeF9q/arcgis/rest/services/PERMIT_CONTRACTORS/FeatureServer/0/query");
  u.searchParams.set("where","contractor_name IS NOT NULL AND pri_sub = 'Primary'");
  u.searchParams.set("outFields","permit_number,job_id,contractor_id,contractor_name,contractor_address,cal_number,pri_sub,objectid");
  u.searchParams.set("orderByFields","objectid DESC");u.searchParams.set("resultRecordCount","250");u.searchParams.set("returnGeometry","false");u.searchParams.set("f","json");
  const r=await fetch(u,{signal:AbortSignal.timeout(15000),headers:{"Accept":"application/json","User-Agent":"BookedSolidResearchBot/1.0 (+https://www.bookedsolidcopy.com/)"}});
  if(!r.ok)throw new Error("philadelphia_permits_http_"+r.status);const j=await r.json();if(j?.error)throw new Error("philadelphia_permits_api_"+String(j.error.code??"error"));
  const rows=(j?.features??[]).map((f:any)=>f.attributes??{});
  permits=rows.filter((x:any)=>x.contractor_name&&targetPermitCompanyName(String(x.contractor_name))).map((x:any)=>({name:String(x.contractor_name),desc:"Philadelphia L&I permit contractor · permit "+String(x.permit_number??"")+" · "+String(x.pri_sub??"Primary"),date:"",cost:null,trade_hint:inferPermitTrade(String(x.contractor_name??"")),source_trade_independent:true,permit_number:x.permit_number??null,contractor_id:x.contractor_id??null}));

 }else if(slug==="denver_commercial_permits"){
  const u=new URL("https://services1.arcgis.com/zdB7qR0BtYrg0Xpl/arcgis/rest/services/ODC_DEV_COMMERCIALCONSTPERMIT_P/FeatureServer/317/query");
  u.searchParams.set("where","CONTRACTOR_NAME IS NOT NULL");
  u.searchParams.set("outFields","DATE_ISSUED,PERMIT_NUM,CLASS,VALUATION,CONTRACTOR_NAME,OBJECTID");
  u.searchParams.set("orderByFields","DATE_ISSUED DESC");u.searchParams.set("resultRecordCount","220");u.searchParams.set("returnGeometry","false");u.searchParams.set("f","json");
  const r=await fetch(u,{signal:AbortSignal.timeout(15000),headers:{"Accept":"application/json","User-Agent":"BookedSolidResearchBot/1.0 (+https://www.bookedsolidcopy.com/)"}});
  if(!r.ok)throw new Error("denver_commercial_permits_http_"+r.status);const j=await r.json();if(j?.error)throw new Error("denver_commercial_permits_api_"+String(j.error.code??"error"));
  const rows=(j?.features??[]).map((f:any)=>f.attributes??{});
  permits=rows.filter((x:any)=>x.CONTRACTOR_NAME&&targetPermitCompanyName(String(x.CONTRACTOR_NAME))).map((x:any)=>({name:String(x.CONTRACTOR_NAME),desc:"Denver commercial construction permit · "+String(x.CLASS??"Commercial Construction")+" · permit "+String(x.PERMIT_NUM??""),date:x.DATE_ISSUED?new Date(Number(x.DATE_ISSUED)).toISOString():"",cost:x.VALUATION??null,trade_hint:"General Contractor",source_trade_independent:true,permit_number:x.PERMIT_NUM??null}));
 }
 const seen=new Set<string>();const outRows:any[]=[];for(const p of permits){const rawName=String(p.name||"").trim();if(!rawName||/^blanket\s*:/i.test(rawName)||/^owner\b/i.test(rawName))continue;const k=normalize(rawName);if(!k||seen.has(k))continue;seen.add(k);outRows.push({url:null,title:rawName,description:`Recent official permit activity: ${p.desc}${p.cost?" · project cost "+p.cost:""}`,meta:{permit_date:p.date,needs_website_resolution:true,trade_hint:p.trade_hint??inferPermitTrade(String(p.desc||"")),source_trade_independent:Boolean(p.source_trade_independent),permit_number:p.permit_number??null,contractor_id:p.contractor_id??null,source_url:permitSourceUrl(slug)}});if(outRows.length>=20)break;}
 return {provider:slug,results:outRows};
}
function phillyLicenseTrade(t:string){
 const x=String(t||"").toUpperCase();
 if(x==="ELECTRICAL CONTRACTOR")return "Electrical";
 if(x==="PLUMBER MASTER")return "Plumbing";
 if(x==="PA HOME IMPROVEMENT")return "Remodeling";
 if(x==="CONTRACTOR"||x==="EXCAVATION CONTRACTOR"||x==="DEMOLITION")return "General Contractor";
 return null;
}
async function searchPhiladelphiaTradeLicenses(){
 const sql="SELECT licensenumber,licensetype,issuedate,expirationdate,licensestatus,contactname,companyname,commercialactivitylicense,objectid FROM trade_licenses WHERE licensestatus='ACTIVE' AND licensetype IN ('CONTRACTOR','ELECTRICAL CONTRACTOR','PLUMBER MASTER','PA HOME IMPROVEMENT','EXCAVATION CONTRACTOR','DEMOLITION') ORDER BY expirationdate DESC LIMIT 350";
 const u=new URL("https://phl.carto.com/api/v2/sql");u.searchParams.set("q",sql);
 const r=await fetch(u,{signal:AbortSignal.timeout(15000),headers:{"Accept":"application/json","User-Agent":"BookedSolidResearchBot/1.0 (+https://www.bookedsolidcopy.com/)"}});
 if(!r.ok)throw new Error("philadelphia_trade_licenses_http_"+r.status);const j=await r.json();const rows=j?.rows??[];
 const seen=new Set<string>();const results:any[]=[];
 for(const x of rows){
   const raw=String(x.companyname||x.contactname||"").trim();if(!raw)continue;
   if(!x.companyname&&!targetPermitCompanyName(raw))continue;
   if(/\b(university|city of|school district|authority|department of|hospital)\b/i.test(raw))continue;
   const k=normalize(raw);if(!k||seen.has(k))continue;seen.add(k);
   const tradeHint=phillyLicenseTrade(String(x.licensetype||""));if(!tradeHint)continue;
   results.push({url:null,title:raw,description:"Active Philadelphia L&I "+String(x.licensetype||"trade")+" license · license "+String(x.licensenumber||""),meta:{needs_website_resolution:true,trade_hint:tradeHint,source_trade_independent:true,evidence_type:"trade_license",evidence_confidence:95,license_type:x.licensetype??null,license_number:x.licensenumber??null,expiration_date:x.expirationdate??null,source_url:permitSourceUrl("philadelphia_trade_licenses")}});
   if(results.length>=25)break;
 }
 return {provider:"philadelphia_trade_licenses",results};
}
async function searchOregonHarp(){
 const u=new URL("https://data.oregon.gov/resource/yp6u-mepw.json");
 u.searchParams.set("$select","license_number,endorsement_text,county_name,full_name,address,city,state,zip_code,phone_number");
 u.searchParams.set("$where","upper(city)='PORTLAND'");
 u.searchParams.set("$limit","220");
 const r=await fetch(u,{signal:AbortSignal.timeout(15000),headers:{"Accept":"application/json","User-Agent":"BookedSolidResearchBot/1.0 (+https://www.bookedsolidcopy.com/)"}});
 if(!r.ok)throw new Error("oregon_harp_http_"+r.status);const rows=await r.json();
 const seen=new Set<string>();const results:any[]=[];
 for(const x of rows){
   const raw=String(x.full_name||"").trim();if(!raw||!targetPermitCompanyName(raw))continue;
   const k=normalize(raw);if(!k||seen.has(k))continue;seen.add(k);
   const endorsement=String(x.endorsement_text||"");
   const tradeHint=/residential/i.test(endorsement)?"Remodeling":"General Contractor";
   results.push({url:null,title:raw,description:"Active Oregon CCB contractor license · "+endorsement+" · license "+String(x.license_number||""),meta:{needs_website_resolution:true,trade_hint:tradeHint,source_trade_independent:true,evidence_type:"trade_license",evidence_confidence:95,license_number:x.license_number??null,endorsement:endorsement||null,phone:x.phone_number??null,city:x.city??null,state:x.state??null,zip:x.zip_code??null,source_url:permitSourceUrl("oregon_harp_contractors")}});
   if(results.length>=25)break;
 }
 return {provider:"oregon_harp_contractors",results};
}

function firstMapped(row:any,map:any,key:string){
 const f=String(map?.[key]||"");return f?row?.[f]:null;
}
async function searchGenericSocrata(source:any,trade:string){
 const m=source?.metadata??{};const domain=String(m.api_domain||"").replace(/^https?:\/\//,"").replace(/\/$/,"");
 const rid=String(m.resource_id||"");const fm=m.field_map??{};
 if(!domain||!rid||!fm.company)throw new Error("generic_socrata_missing_metadata");
 const u=new URL("https://"+domain+"/resource/"+rid+".json");
 u.searchParams.set("$limit",String(Math.min(150,Number(m.fetch_limit||100))));
 u.searchParams.set("$where",String(fm.company)+" is not null");
 if(fm.date){u.searchParams.set("$order",String(fm.date)+" DESC");}
 const r=await fetch(u,{signal:AbortSignal.timeout(15000),headers:{"Accept":"application/json","User-Agent":"BookedSolidResearchBot/1.0 (+https://www.bookedsolidcopy.com/)"}});
 if(!r.ok)throw new Error("generic_socrata_http_"+r.status);
 const rows=await r.json();if(!Array.isArray(rows))throw new Error("generic_socrata_invalid_payload");
 const seen=new Set<string>();const results:any[]=[];
 for(const row of rows){
  const name=String(firstMapped(row,fm,"company")||"").trim();if(!name||!companyLikePermitName(name))continue;
  const k=normalize(name);if(!k||seen.has(k))continue;seen.add(k);
  const tradeRaw=String(firstMapped(row,fm,"trade")||"");
  const descRaw=String(firstMapped(row,fm,"description")||"");
  const tradeField=String(fm.trade||"").toLowerCase();
  const strongTradeField=/(contractor|license|licence|trade|specialty|speciality)/.test(tradeField);
  const tradeHint=inferPermitTrade((strongTradeField?tradeRaw+" ":"")+name)??(trade!=="Mixed"?trade:null);
  const date=firstMapped(row,fm,"date");
  const permit=firstMapped(row,fm,"permit");
  const license=firstMapped(row,fm,"license");
  const email=String(firstMapped(row,fm,"email")||"").trim().toLowerCase();
  const phone=String(firstMapped(row,fm,"phone")||"").trim();
  const city=String(firstMapped(row,fm,"city")||"").trim();
  const state=String(firstMapped(row,fm,"state")||"").trim();
  const sourceKind=String(m.source_kind||"permit");
  const evidenceType=sourceKind.includes("license")?"trade_license":"permit_activity";
  const label=sourceKind.includes("license")?"Official contractor/license record":"Official permit/contractor record";
  results.push({
   url:null,title:name,
   description:label+(permit?" · permit "+permit:"")+(license?" · license "+license:"")+(tradeRaw?" · "+tradeRaw:"")+(descRaw?" · "+descRaw.slice(0,240):""),
   meta:{
    needs_website_resolution:true,trade_hint:tradeHint,source_trade_independent:true,
    evidence_type:evidenceType,evidence_confidence:94,
    source_url:m.public_url||("https://"+domain+"/d/"+rid),
    record_date:date??null,permit_number:permit??null,license_number:license??null,
    email:/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)?email:null,
    phone:phone||null,city:city||null,state:state||null,
    adapter:"generic_socrata"
   }
  });
  if(results.length>=25)break;
 }
 return {provider:source.slug,results};
}

async function searchGenericArcGIS(source:any,trade:string){
 const m=source?.metadata??{};const service=String(m.service_url||"").replace(/\/$/,"");const fm=m.field_map??{};
 if(!service||!fm.company)throw new Error("generic_arcgis_missing_metadata");
 const u=new URL(service+"/query");
 u.searchParams.set("where",String(fm.company)+" IS NOT NULL");
 const fields=[fm.company,fm.trade,fm.date,fm.permit,fm.license,fm.email,fm.phone,fm.city,fm.state,fm.description].filter(Boolean);
 u.searchParams.set("outFields",Array.from(new Set(fields)).join(","));
 if(fm.date)u.searchParams.set("orderByFields",String(fm.date)+" DESC");
 u.searchParams.set("resultRecordCount",String(Math.min(150,Number(m.fetch_limit||100))));
 u.searchParams.set("returnGeometry","false");u.searchParams.set("f","json");
 const r=await fetch(u,{signal:AbortSignal.timeout(15000),headers:{"Accept":"application/json","User-Agent":"BookedSolidResearchBot/1.0 (+https://www.bookedsolidcopy.com/)"}});
 if(!r.ok)throw new Error("generic_arcgis_http_"+r.status);
 const j=await r.json();if(j?.error)throw new Error("generic_arcgis_api_"+String(j.error.code??"error"));
 const rows=(j?.features??[]).map((f:any)=>f.attributes??{});const seen=new Set<string>();const results:any[]=[];
 for(const row of rows){
  const name=String(row?.[fm.company]||"").trim();if(!name||!companyLikePermitName(name))continue;
  const k=normalize(name);if(!k||seen.has(k))continue;seen.add(k);
  const tradeRaw=String(fm.trade?row?.[fm.trade]??"":"");const descRaw=String(fm.description?row?.[fm.description]??"":"");
  const tradeField=String(fm.trade||"").toLowerCase();const strongTradeField=/(contractor|license|licence|trade|specialty|speciality)/.test(tradeField);
  const tradeHint=inferPermitTrade((strongTradeField?tradeRaw+" ":"")+name)??(trade!=="Mixed"?trade:null);
  const email=String(fm.email?row?.[fm.email]??"":"").trim().toLowerCase();
  const sourceKind=String(m.source_kind||"permit");const evidenceType=sourceKind.includes("license")?"trade_license":"permit_activity";
  const permit=fm.permit?row?.[fm.permit]:null;const license=fm.license?row?.[fm.license]:null;
  results.push({url:null,title:name,description:(sourceKind.includes("license")?"Official contractor/license record":"Official permit/contractor record")+(permit?" · permit "+permit:"")+(license?" · license "+license:"")+(tradeRaw?" · "+tradeRaw:"")+(descRaw?" · "+descRaw.slice(0,240):""),meta:{
   needs_website_resolution:true,trade_hint:tradeHint,source_trade_independent:true,evidence_type:evidenceType,evidence_confidence:94,
   source_url:m.public_url||service,record_date:fm.date?row?.[fm.date]??null:null,permit_number:permit??null,license_number:license??null,
   email:/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)?email:null,phone:fm.phone?String(row?.[fm.phone]??"").trim()||null:null,
   city:fm.city?String(row?.[fm.city]??"").trim()||null:null,state:fm.state?String(row?.[fm.state]??"").trim()||null:null,adapter:"generic_arcgis"
  }});
  if(results.length>=25)break;
 }
 return {provider:source.slug,results};
}
function naicsForTrade(trade:string){const m:any={"Roofing":["238160"],"Commercial Roofing":["238160"],"HVAC":["238220"],"Commercial HVAC":["238220"],"Plumbing":["238220"],"Electrical":["238210"],"Painting":["238320"],"Remodeling":["236118"],"General Contractor":["236220"],"Commercial Contractor":["236220"],"Construction":["236220"],"Mixed":["236220","238160","238220","238210","238320","236118"]};return m[trade]??["236220"];}
async function searchUSASpending(trade:string,location:string,lat?:number,lon?:number){
 const end=new Date();const start=new Date(end.getTime()-370*86400000);const fmt=(d:Date)=>d.toISOString().slice(0,10);
 const body={filters:{award_type_codes:["A","B","C","D"],naics_codes:naicsForTrade(trade),time_period:[{start_date:fmt(start),end_date:fmt(end)}]},fields:["Award ID","Recipient Name","Award Amount","Description","Start Date","End Date"],limit:25,page:1};
 const r=await fetch("https://api.usaspending.gov/api/v2/search/spending_by_award/",{method:"POST",signal:AbortSignal.timeout(15000),headers:{"Content-Type":"application/json","User-Agent":"BookedSolidResearchBot/1.0"},body:JSON.stringify(body)});
 if(!r.ok)throw new Error("usaspending_http_"+r.status);const j=await r.json();const awards=j.results??[];
 const osm=await searchOSM(trade==="Mixed"?"Mixed":trade,location,lat,lon);const outRows:any[]=[];
 for(const b of osm.results){const hit=awards.find((a:any)=>namesMatch(b.title,String(a["Recipient Name"]??"")));if(hit)outRows.push({...b,description:`Recent federal contract signal · ${String(hit["Description"]??"").slice(0,300)} · award ${hit["Award Amount"]??""}`});}
 return {provider:"usaspending_api",results:outRows.slice(0,20)};
}
async function searchNRCADirect(location:string){
 const r=await fetch("https://www.nrca.net/findacontractor",{signal:AbortSignal.timeout(12000),headers:{"Accept":"text/html","User-Agent":"BookedSolidResearchBot/1.0 (+https://www.bookedsolidcopy.com/)"}});
 if(!r.ok)throw new Error("nrca_http_"+r.status);const h=await r.text();const state=(location.match(/\b[A-Z]{2}\b/)||[])[0]||"";const rows=h.match(/<tr[\s\S]*?<\/tr>/gi)??[];const picks:any[]=[];
 for(const row of rows){const m=row.match(/href=["']([^"']*NRCAMbrDetails[^"']*)["'][^>]*>([\s\S]*?)<\/a>/i);if(!m)continue;const txt=clean(row);if(state&&!new RegExp("\\b"+state+"\\b").test(txt))continue;let detail=m[1].replace(/&amp;/g,"&");if(detail.startsWith("/"))detail="https://industry.nrca.net"+detail;else if(!/^https?:/i.test(detail))detail="https://industry.nrca.net/eweb/"+detail;const name=clean(m[2]);picks.push({name,detail});if(picks.length>=12)break;}
 const details=await Promise.all(picks.map(async x=>{try{const rr=await fetch(x.detail,{signal:AbortSignal.timeout(7000),headers:{"User-Agent":"BookedSolidResearchBot/1.0"}});if(!rr.ok)return null;const hh=await rr.text();const links=[...(hh.matchAll(/href=["'](https?:\/\/[^"']+)["']/gi))].map((m:any)=>m[1].replace(/&amp;/g,"&"));const website=links.find((u:string)=>!/(nrca\.net|google\.|facebook\.com|linkedin\.com|instagram\.com|twitter\.com|x\.com)/i.test(u));return website?{url:website,title:x.name,description:"Official NRCA contractor directory listing",meta:{directory_url:x.detail}}:null;}catch{return null;}}));
 return {provider:"nrca_official",results:details.filter(Boolean)};
}
function associationForTrade(trade:string){
 const t=String(trade||"");
 if(["Roofing","Commercial Roofing"].includes(t))return {slug:"nrca_official",name:"NRCA",domain:"nrca.net"};
 if(["HVAC","Commercial HVAC"].includes(t))return {slug:"acca_official",name:"ACCA",domain:"acca.org"};
 if(t==="Plumbing")return {slug:"phcc_official",name:"PHCC",domain:"phccweb.org"};
 if(t==="Electrical")return {slug:"neca_official",name:"NECA",domain:"necanet.org"};
 if(["Remodeling","Bathroom Remodeling","Kitchen Remodeling","Kitchen Bath Remodeling"].includes(t))return {slug:"nari_official",name:"NARI",domain:"nari.org"};
 if(["Home Builder","Custom Home Builder","Construction"].includes(t))return {slug:"nahb_official",name:"NAHB",domain:"nahb.org"};
 if(t==="Property Operations")return {slug:"irem_official",name:"IREM",domain:"irem.org"};
 return null;
}
async function verifyAssociation(c:any){
 const assoc=associationForTrade(c.trade);const key=ALLOW_PAID_SEARCH?Deno.env.get("TAVILY_API_KEY"):null;if(!assoc||!key)return null;
 const {data:old}=await db.schema("booked_solid").from("evidence").select("id").eq("company_id",c.id).eq("evidence_type","association_membership").limit(1);if((old??[]).length)return null;
 const generic=new Set(["roofing","company","contractor","contractors","hvac","plumbing","electrical","electric","remodeling","remodel","construction","commercial","services","service","inc","llc","corp","group"]);
 const tokens=normalize(String(c.name||"")).split(" ").filter((x:string)=>x.length>=4&&!generic.has(x));const companyDomain=String(c.canonical_domain||"").toLowerCase();if(!tokens.length&&!companyDomain)return null;
 try{
  const q=companyDomain?('"' + companyDomain + '"'):('"' + String(c.name||"") + '"');
  const r=await fetch("https://api.tavily.com/search",{method:"POST",signal:AbortSignal.timeout(7000),headers:{"Content-Type":"application/json"},body:JSON.stringify({api_key:key,query:q,search_depth:"basic",max_results:5,include_answer:false,include_raw_content:false,include_domains:[assoc.domain]})});
  if(!r.ok)return null;const j=await r.json();
  const hit=(j.results??[]).find((x:any)=>{const tx=(String(x.title??"")+" "+String(x.content??"")+" "+String(x.url??"")).toLowerCase();const tokenHits=tokens.filter((z:string)=>tx.includes(z)).length;return (companyDomain&&tx.includes(companyDomain))||tokenHits>=Math.min(2,tokens.length)&&tokens.length>=2;});
  if(!hit)return null;
  await db.schema("booked_solid").from("evidence").insert({company_id:c.id,evidence_type:"association_membership",claim:`Official ${assoc.name} directory/search contains a company-name match.`,snippet:String(hit.content??hit.title??"").slice(0,1200),source_url:String(hit.url??""),confidence:85,metadata:{association:assoc.name,official_domain:assoc.domain}});
  await db.schema("booked_solid").from("source_catalog").update({last_success_at:new Date().toISOString()}).eq("slug",assoc.slug);
  return assoc.name;
 }catch{return null;}
}

async function resolveLocationWithNominatim(companyName:string,locationText:string){
 if(!companyName||!locationText)return null;
 try{
  const u=new URL("https://nominatim.openstreetmap.org/search");u.searchParams.set("format","jsonv2");u.searchParams.set("limit","3");u.searchParams.set("countrycodes","us");u.searchParams.set("extratags","1");u.searchParams.set("namedetails","1");u.searchParams.set("q",companyName+", "+locationText);
  const r=await fetch(u,{signal:AbortSignal.timeout(10000),headers:{"Accept":"application/json","User-Agent":"BookedSolidResolver/1.0 (+https://www.bookedsolidcopy.com/)"}});
  if(!r.ok)return null;const rows=await r.json();if(!Array.isArray(rows)||!rows.length)return null;
  const tokens=normalize(companyName).split(" ").filter((x:string)=>x.length>2);
  const hit=rows.find((x:any)=>{const tx=normalize(String(x.display_name||"")+" "+String(x.namedetails?.name||""));const n=tokens.filter((t:string)=>tx.includes(t)).length;return n>=Math.min(2,tokens.length)||tokens.length===1&&n===1;})??rows[0];
  const web=String(hit?.extratags?.website||hit?.extratags?.["contact:website"]||hit?.extratags?.url||"").trim();
  return {lat:Number(hit.lat),lon:Number(hit.lon),website:web||null,display_name:hit.display_name??null};
 }catch{return null}
}
async function resolveCompany(job:any){
 const id=job.payload.company_id;const {data:c,error}=await db.schema("booked_solid").from("companies").select("*").eq("id",id).single();if(error)throw error;
 if(c.website_url&&c.canonical_domain){await db.schema("booked_solid").from("work_queue").insert({kind:"research",priority:Number(job.priority)+3,payload:{company_id:id,strategy_id:job.payload.strategy_id},status:"pending"});return {resolved:true,already:true};}
 let lat=job.payload.latitude,lon=job.payload.longitude;let directWebsite:string|null=null;
 if((lat==null||lon==null)&&String(job.payload.location_text||c.metadata?.source_market||"")){
  const geo=await resolveLocationWithNominatim(String(c.name||""),String(job.payload.location_text||c.metadata?.source_market||job.payload.geography||""));
  if(geo){lat=geo.lat;lon=geo.lon;directWebsite=geo.website;}
 }
 let hit:any=null;
 if(directWebsite){hit={url:directWebsite,title:c.name};}
 else{
  const osm=await searchOSM(job.payload.trade||c.trade||"Mixed",job.payload.geography||"US",lat,lon);
  hit=osm.results.find((x:any)=>namesMatch(String(c.name||""),String(x.title||"")));
  if(!hit&&String(job.payload.location_text||c.metadata?.source_market||"")){
   const geo=await resolveLocationWithNominatim(String(c.name||""),String(job.payload.location_text||c.metadata?.source_market||job.payload.geography||""));
   if(geo?.website)hit={url:geo.website,title:c.name};
   else if(geo){
    const osm2=await searchOSM(job.payload.trade||c.trade||"Mixed",String(job.payload.location_text||job.payload.geography||"US"),geo.lat,geo.lon);
    hit=osm2.results.find((x:any)=>namesMatch(String(c.name||""),String(x.title||"")));
   }
  }
 }
 if(!hit)return {resolved:false,reason:"no_osm_or_nominatim_match"};
 const domain=domainOf(hit.url);if(!domain)return {resolved:false,reason:"no_domain"};
 const {data:dupe}=await db.schema("booked_solid").from("companies").select("id").eq("canonical_domain",domain).neq("id",id).maybeSingle();
 if(dupe){
  await db.schema("booked_solid").from("evidence").update({company_id:dupe.id}).eq("company_id",id);
  await db.schema("booked_solid").from("companies").delete().eq("id",id);
  await db.schema("booked_solid").from("work_queue").insert({kind:"research",priority:Number(job.priority)+3,payload:{company_id:dupe.id,strategy_id:job.payload.strategy_id},status:"pending"});
  return {resolved:true,merged_into:dupe.id,domain};
 }
 await db.schema("booked_solid").from("companies").update({canonical_domain:domain,website_url:"https://"+domain+"/",source_last_seen:"openstreetmap_overpass",metadata:{...(c.metadata??{}),needs_website_resolution:false,resolved_via:"openstreetmap_overpass"}}).eq("id",id);
 await db.schema("booked_solid").from("work_queue").insert({kind:"research",priority:Number(job.priority)+3,payload:{company_id:id,strategy_id:job.payload.strategy_id},status:"pending"});
 return {resolved:true,domain};
}
async function discover(job:any){
 const p=job.payload;const q=String(p.query_template??"").replace("{trade}",p.trade??"Mixed").replace("{location}",p.geography==="US"?"United States":String(p.geography??"US"));let sr:any;
 const {data:sourceDef}=await db.schema("booked_solid").from("source_catalog").select("*").eq("slug",p.source_slug).maybeSingle();
 if(p.source_slug==="openstreetmap_overpass")sr=await searchOSM(p.trade,p.geography,p.latitude,p.longitude);
 else if(p.source_slug==="wikidata_sparql")sr=await searchWikidata(p.geography,p.latitude,p.longitude);
 else if(p.source_slug==="chicago_building_permits"||p.source_slug==="nyc_dob_permits"||p.source_slug==="austin_construction_permits"||p.source_slug==="seattle_building_permits"||p.source_slug==="boston_building_permits"||p.source_slug==="sf_building_permit_contacts"||p.source_slug==="philadelphia_permit_contractors"||p.source_slug==="denver_commercial_permits")sr=await searchPermitSource(p.source_slug,p.trade,p.geography,p.latitude,p.longitude);
 else if(p.source_slug==="philadelphia_trade_licenses")sr=await searchPhiladelphiaTradeLicenses();
 else if(p.source_slug==="oregon_harp_contractors")sr=await searchOregonHarp();
 else if(p.source_slug==="usaspending_api")sr=await searchUSASpending(p.trade,p.geography,p.latitude,p.longitude);
 else if(p.source_slug==="nrca_official")sr=await searchNRCADirect(p.geography);
 else if(sourceDef?.metadata?.adapter==="generic_socrata")sr=await searchGenericSocrata(sourceDef,p.trade??"Mixed");
 else if(sourceDef?.metadata?.adapter==="generic_arcgis")sr=await searchGenericArcGIS(sourceDef,p.trade??"Mixed");
 else sr=await search(q);let n=0;
 for(const item of sr.results){if(n>=5)break;const itemName=String(item.title??"").trim();const domain=domainOf(item.url??"");if(!domain&&item.meta?.needs_website_resolution){
   if(itemName.length<3)continue;const nn=normalize(itemName);let c:any;const {data:existingByName}=await db.schema("booked_solid").from("companies").select("*").eq("normalized_name",nn).limit(1).maybeSingle();
   if(existingByName)c=existingByName;else{const inferredTrade=item.meta?.trade_hint??(item.meta?.source_trade_independent?null:(p.trade==="Mixed"?null:p.trade));const {data:i,error:ie}=await db.schema("booked_solid").from("companies").insert({canonical_domain:null,normalized_name:nn,name:itemName,trade:inferredTrade,website_url:null,source_first_seen:sr.provider,source_last_seen:sr.provider,status:"discovered",metadata:{query:q,needs_website_resolution:true,geography:p.geography,permit_trade_hint:item.meta?.trade_hint??null,source_market:item.meta?.city||item.meta?.state?([item.meta?.city,item.meta?.state].filter(Boolean).join(" ")):null}}).select("*").single();if(ie)throw ie;c=i;}
   const et=item.meta?.evidence_type??"permit_activity";const conf=Number(item.meta?.evidence_confidence??90);const {error:pe}=await db.schema("booked_solid").from("evidence").insert({company_id:c.id,evidence_type:et,claim:item.description??(et==="trade_license"?"Active official trade license":"Recent official permit activity"),snippet:item.description??null,source_url:item.meta?.source_url??permitSourceUrl(sr.provider),confidence:conf,metadata:{provider:sr.provider,query:q,...(item.meta??{})}});if(pe)throw pe;
   if(item.meta?.email){
    const em=String(item.meta.email).toLowerCase();const {data:ec}=await db.schema("booked_solid").from("contacts").select("id").eq("company_id",c.id).eq("email",em).maybeSingle();
    if(!ec)await db.schema("booked_solid").from("contacts").insert({company_id:c.id,email:em,email_confidence:85,source_url:item.meta?.source_url??null,status:"unverified",role:"Public contractor contact"});
   }
   const {data:rq}=await db.schema("booked_solid").from("work_queue").select("id").eq("kind","resolve").in("status",["pending","running"]).contains("payload",{company_id:c.id}).limit(1);
   if(!(rq??[]).length){
    const rowLocation=[item.meta?.city,item.meta?.state].filter(Boolean).join(" ").trim();
    const sameMarket=!rowLocation||String(rowLocation).toLowerCase()===String(p.geography||"").toLowerCase();
    await db.schema("booked_solid").from("work_queue").insert({kind:"resolve",priority:Number(job.priority)+4,payload:{company_id:c.id,strategy_id:p.strategy_id,trade:item.meta?.trade_hint??(item.meta?.source_trade_independent?"Mixed":p.trade),geography:rowLocation||p.geography,location_text:rowLocation||p.geography,latitude:sameMarket?p.latitude:null,longitude:sameMarket?p.longitude:null},status:"pending"});
   }n++;continue;
  }
  if(!domain)continue;const blocked=["reddit.com","youtube.com","quora.com","facebook.com","linkedin.com","yelp.com","angi.com","homeadvisor.com","thumbtack.com","porch.com","houzz.com","bobvila.com","forbes.com","localservicequotes.com","centrfederal.ru","indeed.com","ziprecruiter.com","glassdoor.com","monster.com","careerbuilder.com","simplyhired.com","zippia.com","talent.com","jooble.org","builtin.com","bebee.com","vaia.com","theladders.com","icims.com","jobleads.com","lever.co","greenhouse.io","greenhouse.com","workable.com","smartrecruiters.com","ashbyhq.com","bamboohr.com"];if(blocked.some(d=>domain===d||domain.endsWith("."+d)))continue;const title=itemName;if(/^(what|do|how|why|can|are|the best|best |free estimates?$)/i.test(title)||/\b(directory|top \d+|\d+ best|guide to|software platform|saas|marketplace|reviews?)\b/i.test(title))continue;const name=title.replace(/\s*[|–-]\s*.*$/,"").trim();if(name.length<3)continue;
  let c:any;const {data:existing,error:xe}=await db.schema("booked_solid").from("companies").select("*").eq("canonical_domain",domain).maybeSingle();if(xe)throw xe;
  if(existing){if(existing.metadata?.hard_excluded_vendor||existing.metadata?.hard_excluded_source)continue;const {data:u,error:ue}=await db.schema("booked_solid").from("companies").update({source_last_seen:sr.provider,trade:existing.trade??(p.trade==="Mixed"?null:p.trade),metadata:{...(existing.metadata??{}),query:q}}).eq("id",existing.id).select("*").single();if(ue)throw ue;c=u;}
  else{const {data:i,error:ie}=await db.schema("booked_solid").from("companies").insert({canonical_domain:domain,normalized_name:normalize(name),name,trade:p.trade==="Mixed"?null:p.trade,website_url:"https://"+domain+"/",source_first_seen:sr.provider,source_last_seen:sr.provider,status:"discovered",metadata:{query:q}}).select("*").single();if(ie)throw ie;c=i;}
  const et=sr.provider==="nrca_official"?"association_membership":(sr.provider==="chicago_building_permits"||sr.provider==="nyc_dob_permits"||sr.provider==="austin_construction_permits"||sr.provider==="seattle_building_permits"||sr.provider==="boston_building_permits"||sr.provider==="sf_building_permit_contacts"||sr.provider==="philadelphia_permit_contractors"||sr.provider==="denver_commercial_permits")?"permit_activity":sr.provider==="usaspending_api"?"federal_award_signal":sr.provider==="wikidata_sparql"?"public_registry":"search_result";const conf=et==="association_membership"?90:et==="permit_activity"?90:et==="federal_award_signal"?92:et==="public_registry"?75:55;await db.schema("booked_solid").from("evidence").insert({company_id:c.id,evidence_type:et,claim:item.description??item.title??"Discovery evidence",snippet:item.description??null,source_url:item.meta?.directory_url??item.url,confidence:conf,metadata:{provider:sr.provider,query:q,...(item.meta??{})}});
  if(!c.last_researched_at)await db.schema("booked_solid").from("work_queue").insert({kind:"research",priority:Number(job.priority)+5,payload:{company_id:c.id,strategy_id:p.strategy_id},status:"pending"});n++;}
 await db.schema("booked_solid").rpc("record_source_success",{p_slug:p.source_slug});return {provider:sr.provider,source_slug:p.source_slug,query:q,results:sr.results.length,companies:n};
}
async function research(job:any){
 const {data:c,error}=await db.schema("booked_solid").from("companies").select("*").eq("id",job.payload.company_id).single();if(error)throw error;
 const root=new URL(c.website_url);if(root.protocol!=="https:")throw new Error("HTTPS_REQUIRED");
 const paths=["/","/about","/services","/contact","/team","/estimate","/careers","/locations","/commercial"];
 let combined="";let pages=0;const emails=new Set<string>();
 const pageResults=await Promise.all(paths.map(async p=>{try{const r=await fetch(new URL(p,root),{redirect:"follow",signal:AbortSignal.timeout(6000),headers:{"User-Agent":"BookedSolidResearchBot/1.0 (+https://www.bookedsolidcopy.com/)"}});if(!r.ok)return null;const h=await r.text();return {p,h,visible:clean(h)};}catch{return null;}}));
 for(const pg of pageResults){if(!pg)continue;pages++;combined+=" "+pg.visible;for(const e of pg.visible.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi)??[]){const em=e.toLowerCase();const ed=em.split("@")[1];const hd=root.hostname.toLowerCase().replace(/^www\./,"");if(ed===hd||ed.endsWith("."+hd))emails.add(em);}}
 const home=pageResults.find((x:any)=>x?.p==="/");if(home){const mt=String(home.h).match(/<title[^>]*>([\s\S]*?)<\/title>/i);const ht=mt?clean(mt[1]).replace(/\s*[|–-]\s*.*$/,"").trim():"";const weak=/^(estimator|careers?|jobs?|free estimate|request a quote|home)$/i.test(String(c.name||""));if(ht&&ht.length>=3&&ht.length<120&&(weak||!c.name)){await db.schema("booked_solid").from("companies").update({name:ht,normalized_name:normalize(ht)}).eq("id",c.id);c.name=ht;}}
 const domain=root.hostname.replace(/^www\./,"").toLowerCase();
 const missingName=!c.name||/^free |^do |^how |^what |^the best|^best /i.test(c.name);
 const missingContact=emails.size===0;let supplemental:any[]=[];
 if(ALLOW_PAID_SEARCH&&(missingName||missingContact||combined.length<500)&&Deno.env.get("TAVILY_API_KEY")){
  const queries=[domain+" company name owner contact email","\""+domain+"\" contractor","\""+domain+"\" contact","\""+domain+"\" estimate quote","\""+domain+"\" change order"];
  const sq=queries.slice(0,missingName||missingContact?3:2);const sets=await Promise.all(sq.map(async q=>{try{const r=await fetch("https://api.tavily.com/search",{method:"POST",signal:AbortSignal.timeout(8000),headers:{"Content-Type":"application/json"},body:JSON.stringify({api_key:Deno.env.get("TAVILY_API_KEY"),query:q,search_depth:"basic",max_results:6,include_answer:false,include_raw_content:false,exclude_domains:["reddit.com","youtube.com","quora.com","facebook.com","linkedin.com","yelp.com","angi.com","homeadvisor.com","thumbtack.com","porch.com","houzz.com","bobvila.com","forbes.com","localservicequotes.com","centrfederal.ru","indeed.com","ziprecruiter.com","glassdoor.com","monster.com","careerbuilder.com","simplyhired.com","zippia.com","talent.com","jooble.org","builtin.com","bebee.com","vaia.com","theladders.com","icims.com","jobleads.com","lever.co","greenhouse.io","greenhouse.com","workable.com","smartrecruiters.com","ashbyhq.com","bamboohr.com"]})});if(!r.ok)return [];const j=await r.json();return j.results??[];}catch{return [];}}));supplemental.push(...sets.flat());
 }
 for(const x of supplemental){const u=String(x.url??"");const txt=String(x.title??"")+" "+String(x.content??"");for(const e of txt.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi)??[]){const em=e.toLowerCase();const ed=em.split("@")[1];if(ed===domain||ed.endsWith("."+domain))emails.add(em);}await db.schema("booked_solid").from("evidence").insert({company_id:c.id,evidence_type:"supplemental_search",claim:String(x.title??"Supplemental search result"),snippet:String(x.content??"").slice(0,1200),source_url:u||null,confidence:45,metadata:{provider:"tavily",query_type:"gap_fill"}});}
 if(pages===0&&!supplemental.length){await db.schema("booked_solid").from("companies").update({status:"rejected"}).eq("id",c.id);return {pages,signals:[],emails:0,rejected:"no_reachable_pages"};}
 const supplementalText=supplemental.map(x=>x.content??"").join(" ");const allText=combined+" "+supplementalText;if(!c.trade){const inferred=inferSiteTrade(allText);if(inferred){await db.schema("booked_solid").from("companies").update({trade:inferred,updated_at:new Date().toISOString(),metadata:{...(c.metadata??{}),trade_inferred_from_site:true}}).eq("id",c.id);c.trade=inferred;}}const types=signalTypes(allText);const associationMatch=await verifyAssociation(c);if(associationMatch)types.push("association_membership");
 for(const t of types.filter((x:string)=>x!=="association_membership"))await db.schema("booked_solid").from("evidence").insert({company_id:c.id,evidence_type:t,claim:"Public sources contain signals related to "+t,snippet:allText.slice(0,1200),source_url:root.toString(),confidence:70,metadata:{pages_researched:pages,supplemental_results:supplemental.length}});
 for(const email of emails){const {data:existingContact}=await db.schema("booked_solid").from("contacts").select("id").eq("company_id",c.id).eq("email",email).maybeSingle();if(existingContact)await db.schema("booked_solid").from("contacts").update({email_confidence:75,source_url:root.toString(),status:"unverified"}).eq("id",existingContact.id);else await db.schema("booked_solid").from("contacts").insert({company_id:c.id,email,email_confidence:75,source_url:root.toString(),status:"unverified"});}
 await db.schema("booked_solid").from("companies").update({last_researched_at:new Date().toISOString(),status:c.metadata?.hard_excluded_vendor?"rejected":c.status==="qualified"?"qualified":"discovered",metadata:{...(c.metadata??{}),research_pages:pages,supplemental_searches:supplemental.length}}).eq("id",c.id);
 await db.schema("booked_solid").from("work_queue").insert({kind:"qualify",priority:Number(job.priority)+5,payload:{company_id:c.id,strategy_id:job.payload.strategy_id},status:"pending"});
 return {pages,signals:types,emails:emails.size,supplemental_results:supplemental.length,gap_fill_used:missingName||missingContact||combined.length<500};
}

async function contactResolve(job:any){
 const leadId=job.payload?.lead_id;if(!leadId)throw new Error("contact_resolve_lead_id_required");
 const {data:lead,error:le}=await db.schema("booked_solid").from("leads").select("*,companies(*)").eq("id",leadId).single();if(le)throw le;
 if(lead.status!=="qualified")return {state:"skipped",reason:"lead_not_qualified",lead_id:leadId,status:lead.status};
 const company=lead.companies;
 const {data:raw,error:ce}=await db.schema("booked_solid").from("contacts").select("*").eq("company_id",company.id).neq("status","suppressed");if(ce)throw ce;
 let contacts=(raw??[]).filter((x:any)=>x.status!=="invalid");
 const named=[...contacts].filter((x:any)=>x.full_name).sort((a:any,b:any)=>(decisionRoleScore(b.role)-decisionRoleScore(a.role))||(contactResolutionScore(b)-contactResolutionScore(a)));
 const decisionMakers=named.filter((x:any)=>decisionRoleScore(x.role)>0);
 let decision=decisionMakers[0]??null;

 // First prefer any decision maker whose name can be linked to a DIRECT email
 // that is actually present in project data. This outranks a higher title with a generic inbox.
 for(const person of decisionMakers){
   const ownDirect=person.email&&mailboxKind(person.email)==="direct"?String(person.email).toLowerCase():null;
   const knownDirect=ownDirect??contacts.find((x:any)=>x.email&&mailboxKind(x.email)==="direct"&&emailMatchesName(x.email,person.full_name))?.email?.toLowerCase();
   if(knownDirect){
     const emailRow=contacts.find((x:any)=>String(x.email||"").toLowerCase()===knownDirect);
     if(emailRow && (!emailRow.full_name||!emailRow.role)){
       await db.schema("booked_solid").from("contacts").update({full_name:emailRow.full_name||person.full_name,role:emailRow.role||person.role,email_confidence:Math.max(80,Number(emailRow.email_confidence||0)),updated_at:new Date().toISOString()}).eq("id",emailRow.id);
       emailRow.full_name=emailRow.full_name||person.full_name;emailRow.role=emailRow.role||person.role;emailRow.email_confidence=Math.max(80,Number(emailRow.email_confidence||0));
     }
   }
 }

 // If no project email matched, try the public company pages for the top two decision makers.
 let hasLinkedDecision=contacts.some((x:any)=>x.email&&x.full_name&&decisionRoleScore(x.role)>0&&mailboxKind(x.email)==="direct");
 if(!hasLinkedDecision){
   for(const person of decisionMakers.slice(0,2)){
     const found=await findPublicNamedEmail(company,person,contacts);
     if(!found)continue;
     const existingEmail=contacts.find((x:any)=>String(x.email||"").toLowerCase()===found);
     if(existingEmail){
       if(!existingEmail.full_name||!existingEmail.role){
         await db.schema("booked_solid").from("contacts").update({full_name:existingEmail.full_name||person.full_name,role:existingEmail.role||person.role,email_confidence:Math.max(80,Number(existingEmail.email_confidence||0)),updated_at:new Date().toISOString()}).eq("id",existingEmail.id);
         existingEmail.full_name=existingEmail.full_name||person.full_name;existingEmail.role=existingEmail.role||person.role;existingEmail.email_confidence=Math.max(80,Number(existingEmail.email_confidence||0));
       }
     }else{
       const {data:created,error:ie}=await db.schema("booked_solid").from("contacts").insert({company_id:company.id,full_name:person.full_name,role:person.role,email:found,email_confidence:85,source_url:company.website_url,status:"unverified"}).select("*").single();
       if(!ie&&created)contacts.push(created);
     }
     hasLinkedDecision=true;break;
   }
 }

 const usable=contacts.filter((x:any)=>x.email&&mailboxKind(x.email)!=="weak");
 const directNamed=usable.filter((x:any)=>x.full_name&&decisionRoleScore(x.role)>0&&mailboxKind(x.email)==="direct").sort((a:any,b:any)=>(contactResolutionScore(b)-contactResolutionScore(a))||(decisionRoleScore(b.role)-decisionRoleScore(a.role)))[0];
 const directAny=usable.filter((x:any)=>mailboxKind(x.email)==="direct").sort((a:any,b:any)=>contactResolutionScore(b)-contactResolutionScore(a))[0];
 const generic=usable.filter((x:any)=>mailboxKind(x.email)==="generic").sort((a:any,b:any)=>Number(b.email_confidence||0)-Number(a.email_confidence||0))[0];

 let chosen:any=null;let contactClass="contact_required";let score=0;let namedContact:any=null;
 if(directNamed){chosen=directNamed;namedContact=directNamed;decision=directNamed;contactClass="decision_maker_direct";score=Math.max(90,contactResolutionScore(directNamed));}
 else if(decision&&generic){chosen=generic;namedContact=decision;contactClass="decision_maker_generic_fallback";score=Math.max(72,Math.min(85,decisionRoleScore(decision.role)+30));}
 else if(directAny){chosen=directAny;namedContact=directAny.full_name?directAny:null;contactClass=directAny.full_name?"named_direct":"direct_email";score=Math.max(62,contactResolutionScore(directAny));}
 else if(generic){chosen=generic;namedContact=null;contactClass="generic_only";score=55;}

 const weakOnly=!chosen&&contacts.some((x:any)=>x.email&&mailboxKind(x.email)==="weak");
 const state=chosen?"ready":weakOnly?"weak_only":"contact_required";
 const retryCount=Number(job.payload?.contact_retry??0);
 const nextRetryAt=!chosen&&retryCount<3?new Date(Date.now()+72*3600000).toISOString():null;
 const resolution={
   state,contact_class:contactClass,score,retry_count:retryCount,next_retry_at:nextRetryAt,
   recipient_email:chosen?.email?String(chosen.email).toLowerCase():null,
   recipient_name:namedContact?.full_name||null,
   recipient_role:namedContact?.role||null,
   contact_id:namedContact?.id||chosen?.id||null,
   email_contact_id:chosen?.id||null,
   email_kind:chosen?.email?mailboxKind(chosen.email):null,
   decision_maker_known:Boolean(decision),
   decision_maker_name:decision?.full_name||null,
   decision_maker_role:decision?.role||null,
   resolved_at:new Date().toISOString(),
   candidate_summary:contacts.map((x:any)=>({id:x.id,name:x.full_name||null,role:x.role||null,email:x.email||null,email_kind:x.email?mailboxKind(x.email):"missing",score:contactResolutionScore(x)})).sort((a:any,b:any)=>b.score-a.score).slice(0,8)
 };
 await db.schema("booked_solid").from("leads").update({contact_id:resolution.contact_id,contact_score:score,lead_brief:{...(lead.lead_brief||{}),contact_resolution:resolution},updated_at:new Date().toISOString()}).eq("id",lead.id);

 if(!chosen){
   await db.schema("booked_solid").from("outreach_queue").update({status:"cancelled",failure_reason:weakOnly?"Contact resolution: only weak-function inboxes available.":"Contact resolution: no usable email found."}).eq("lead_id",lead.id).in("status",["blocked_email_not_configured","ready"]);
   if(nextRetryAt)await db.schema("booked_solid").from("work_queue").insert({kind:"contact",priority:Math.max(30,Number(lead.score||0)-15),payload:{lead_id:lead.id,company_id:company.id,contact_retry:retryCount+1,reason:"scheduled_contact_retry"},status:"pending",available_at:nextRetryAt});
   return {lead_id:lead.id,company:company.name,...resolution,queued_message:false,retry_scheduled:Boolean(nextRetryAt)};
 }
 const {data:mq}=await db.schema("booked_solid").from("work_queue").select("id").eq("kind","message").in("status",["pending","running"]).contains("payload",{lead_id:lead.id}).limit(1);
 if(!(mq??[]).length)await db.schema("booked_solid").from("work_queue").insert({kind:"message",priority:Number(lead.score||0)+score/10,payload:{lead_id:lead.id},status:"pending"});
 return {lead_id:lead.id,company:company.name,...resolution,queued_message:true};
}
async function qualify(job:any){
 const id=job.payload.company_id;
 const [{data:c,error:ce},{data:ev,error:ee},{data:ct,error:te},{data:existingLeads,error:lee},{data:settings,error:se}]=await Promise.all([
  db.schema("booked_solid").from("companies").select("*").eq("id",id).single(),
  db.schema("booked_solid").from("evidence").select("*").eq("company_id",id).limit(100),
  db.schema("booked_solid").from("contacts").select("*").eq("company_id",id).neq("status","suppressed"),
  db.schema("booked_solid").from("leads").select("*").eq("company_id",id),
  db.schema("booked_solid").from("runtime_settings").select("*").eq("id",true).single()
 ]);
 if(ce)throw ce;if(ee)throw ee;if(te)throw te;if(lee)throw lee;if(se)throw se;
 const rows=ev??[];const types=new Set(rows.map((x:any)=>x.evidence_type));
 const domain=String(c.canonical_domain||"").toLowerCase();const name=String(c.name||"");
 const badDomain=Boolean(c.metadata?.hard_excluded_source)||/reddit\.com|youtube\.com|quora\.com|facebook\.com|instagram\.com|tiktok\.com|linkedin\.com|usatoday\.com|forbes\.com|yelp\.com|angi\.com|homeadvisor\.com|thumbtack\.com|porch\.com|houzz\.com|indeed\.com|ziprecruiter\.com|glassdoor\.com|monster\.com|careerbuilder\.com|simplyhired\.com|zippia\.com|talent\.com|jooble\.org|builtin\.com|bebee\.com|vaia\.com|theladders\.com|icims\.com|jobleads\.com|lever\.co|greenhouse\.io|greenhouse\.com|workable\.com|smartrecruiters\.com|ashbyhq\.com|bamboohr\.com|myquoteiq\.com|buildium\.com|funnelleasing\.com|secondnature\.com|sharefile\.com/i.test(domain);
 const badTitle=/\b(directory|directories|database|guide|best \d+|\d+ best|how to|what is|what are|do .* offer|news|magazine|article|review|reviews|jobs? in|project manager jobs|estimator jobs|recruiter|recruiting|staffing|talent acquisition|top \d+ crms?|\d+\s+ways\b|ways .* automation|ways to use automation|tasks to save time|client portals? for contractors)\b/i.test(name);const leadgenTitle=/^(get|request|compare|find)\b.*\b(estimate|estimates|quote|quotes)\b/i.test(name);
 const text=(name+" "+String(c.normalized_name||"")+" "+rows.map((x:any)=>String(x.claim||"")+" "+String(x.snippet||"")).join(" ")).toLowerCase();
 const vendorTerms=["software company","software platform","saas","software provider","technology platform","proptech","property management software","estimation software","estimating software","crm software","workflow software","ai platform","marketplace","software solution","technology company","recruiting company","staffing company","recruitment agency","talent agency","executive search"];
 const operatorTerms=["property management company","property manager","property management services","rental management","vacation rental management","apartment management","real estate management services"];
 const vendorName=/\b(software|saas|platform|workflow automation|technology|proptech)\b/i.test(name);const isVendor=Boolean(c.metadata?.hard_excluded_vendor)||vendorName||(vendorTerms.some(t=>text.includes(t))&&!operatorTerms.some(t=>text.includes(t)));const hospitalityNonBuyer=c.trade==="Property Operations"&&/\b(hotel|resort|motel|inn|suites?)\b/i.test(name+" "+domain);const permitSourced=/permits|permit_contractors|permit_contacts|trade_licenses/i.test(String(c.source_first_seen||""));const unclassifiedPermitProfessional=permitSourced&&!c.trade&&/\b(engineer(?:ing)?|architect(?:ure|ural)?|consulting|design studio|surveying)\b/i.test(text);
 if(badDomain||badTitle||leadgenTitle||isVendor||unclassifiedPermitProfessional||hospitalityNonBuyer){
  await db.schema("booked_solid").from("companies").update({status:"rejected",recommended_offer:null,updated_at:new Date().toISOString()}).eq("id",id);
  await db.schema("booked_solid").from("leads").update({status:"suppressed",why_now:isVendor?"Excluded: technology/software vendor rather than an end-customer operating business.":hospitalityNonBuyer?"Excluded: hospitality property rather than a property-management operator.":"Excluded: non-prospect source.",updated_at:new Date().toISOString()}).eq("company_id",id).neq("status","won");
  await updateStrategyLearning(job.payload.strategy_id,8,false);return {score:0,status:"rejected",reason:isVendor?"software_vendor":hospitalityNonBuyer?"hospitality_nonbuyer":leadgenTitle?"leadgen_page":unclassifiedPermitProfessional?"professional_service_nonbuyer":"non_prospect_source"};
 }
 const contractorTrades=["HVAC","Roofing","Plumbing","Electrical","Remodeling","Painting","General Contractor","Commercial Contractor","Cabinet","Flooring","Concrete","Landscaping","Windows","Siding","Deck Builder","Home Builder","Construction"];
 const fit=contractorTrades.includes(c.trade)?25:c.trade==="Property Operations"?22:15;
 const painTypes=["estimation_pain","field_quoting","change_orders","workflow_complexity"];
 const pain=Math.min(32,Array.from(types).filter((t:any)=>painTypes.includes(t)).length*10);
 const intentBonus=(types.has("buyer_signal")?10:0)+(types.has("scale_signal")?6:0)+(types.has("recurring_contracts")?6:0)+(c.trade==="Property Operations"&&types.has("property_operations")?6:0)+(types.has("association_membership")?8:0);
 const realEvidence=rows.filter((x:any)=>x.evidence_type!=="search_result");
 const evidenceScore=Math.min(18,realEvidence.length*3);
 const validContact=(ct??[]).find((x:any)=>x.email&&x.status!=="invalid"&&x.status!=="suppressed"&&mailboxKind(x.email)!=="weak");
 const contactScore=Math.min(20,Number(validContact?.email_confidence??0)/5);
 const score=Math.min(100,fit+pain+intentBonus+evidenceScore+contactScore);
 let offer="custom_estimator";if(types.has("change_orders"))offer="penmark";else if(c.trade==="Property Operations")offer="automation";else if(types.has("estimation_pain")||types.has("field_quoting")||types.has("buyer_signal"))offer="custom_estimator";else if(types.has("recurring_contracts")||types.has("scale_signal")||types.has("workflow_complexity"))offer="automation";
 const hasPain=types.has("estimation_pain")||types.has("field_quoting")||types.has("change_orders");
 const prospectType=hasPain?"pain_led":"fit_led";
 const priorQualified=(existingLeads??[]).find((x:any)=>x.status==="qualified");
 let status=priorQualified?"qualified":score>=65&&realEvidence.length>=1?"qualified":score>=40?"candidate":"rejected";
 const why=prospectType==="pain_led"?"Public evidence shows a relevant operational/estimating signal.":"Company appears to fit Booked Solid's target customer profile; no pain is assumed.";
 if(status==="rejected"){
  await db.schema("booked_solid").from("companies").update({status:"rejected",recommended_offer:null,updated_at:new Date().toISOString()}).eq("id",id);
  for(const l of (existingLeads??[]).filter((x:any)=>x.status!=="won"))await db.schema("booked_solid").from("leads").update({status:"suppressed",why_now:why,updated_at:new Date().toISOString()}).eq("id",l.id);
  await updateStrategyLearning(job.payload.strategy_id,20,false);return {score,offer,status,prospect_type:prospectType,contact_found:!!validContact};
 }
 const priorBrief=(priorQualified??(existingLeads??[])[0])?.lead_brief??{};const leadPayload={company_id:id,contact_id:validContact?.id??null,strategy_id:job.payload.strategy_id??null,offer,score,fit_score:fit,pain_score:pain,evidence_score:evidenceScore,contact_score:contactScore,status,why_now:why,lead_brief:{...priorBrief,prospect_type:prospectType,evidence_types:[...types],company:c.name,website:c.website_url,contact_status:validContact?"unverified":"missing"}};
 const existing=priorQualified??(existingLeads??[]).find((x:any)=>x.offer===offer)??(existingLeads??[])[0];let lead:any;
 if(existing){const {data:u,error:ue}=await db.schema("booked_solid").from("leads").update(leadPayload).eq("id",existing.id).select("*").single();if(ue)throw ue;lead=u;}
 else{const {data:i,error:ie}=await db.schema("booked_solid").from("leads").insert(leadPayload).select("*").single();if(ie)throw ie;lead=i;}
 if(status==="qualified"){
  const {data:cq}=await db.schema("booked_solid").from("work_queue").select("id").eq("kind","contact").in("status",["pending","running"]).contains("payload",{lead_id:lead.id}).limit(1);
  if(!(cq??[]).length)await db.schema("booked_solid").from("work_queue").insert({kind:"contact",priority:score+10,payload:{lead_id:lead.id,company_id:id},status:"pending"});
  await db.schema("booked_solid").from("companies").update({status:"qualified",recommended_offer:offer,fit_score:fit,updated_at:new Date().toISOString()}).eq("id",id);
  await updateStrategyLearning(job.payload.strategy_id,90,!priorQualified);
 }else{
  await db.schema("booked_solid").from("companies").update({status:"discovered",recommended_offer:offer,fit_score:fit,updated_at:new Date().toISOString()}).eq("id",id);
  await updateStrategyLearning(job.payload.strategy_id,50,false);
 }
 return {score,offer,status,prospect_type:prospectType,contact_found:!!validContact,email_enabled:!!settings?.email_enabled,intent_bonus:intentBonus};
}
async function message(job:any){
 const url=Deno.env.get("SUPABASE_URL")!+"/functions/v1/booked-solid-message-prep";
 const key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
 const r=await fetch(url,{method:"POST",signal:AbortSignal.timeout(20000),headers:{"Content-Type":"application/json","Authorization":"Bearer "+key,"apikey":key},body:JSON.stringify({lead_id:job.payload.lead_id})});
 const txt=await r.text();let data:any;try{data=JSON.parse(txt)}catch{data={raw:txt}}
 if(!r.ok)throw new Error("message_prep_http_"+r.status+":"+String(data?.error||txt).slice(0,500));
 return data;
}
Deno.serve(async req=>{try{if(req.method==="OPTIONS")return new Response("ok",{headers:H});await db.schema("booked_solid").from("work_queue").update({status:"pending",locked_at:null,locked_by:null,available_at:new Date().toISOString(),updated_at:new Date().toISOString()}).eq("status","running").lt("locked_at",new Date(Date.now()-15*60000).toISOString());const {data:jobs,error}=await db.rpc("claim_booked_solid_work",{p_worker:"booked-solid-"+crypto.randomUUID()});if(error)throw error;const job=jobs?.[0];if(!job)return out({ok:true,idle:true});let result:any;try{if(job.kind==="discover")result=await discover(job);else if(job.kind==="research")result=await research(job);else if(job.kind==="qualify")result=await qualify(job);else if(job.kind==="contact")result=await contactResolve(job);else if(job.kind==="message")result=await message(job);else if(job.kind==="resolve")result=await resolveCompany(job);else result={skipped:job.kind};await db.schema("booked_solid").from("work_queue").update({status:"done",last_error:null,updated_at:new Date().toISOString()}).eq("id",job.id);return out({ok:true,job_id:job.id,kind:job.kind,result});}catch(e){const msg=e instanceof Error?e.message:(e&&typeof e==="object"?JSON.stringify(e):String(e));const blocked=msg.includes("SEARCH_PROVIDER_NOT_CONFIGURED");const retry=!blocked&&Number(job.attempts??0)<3;if(job.kind==="discover"&&job.payload?.source_slug)await db.schema("booked_solid").rpc("record_source_failure",{p_slug:job.payload.source_slug,p_error:msg});await db.schema("booked_solid").from("work_queue").update({status:blocked?"blocked":retry?"pending":"failed",last_error:msg,available_at:new Date(Date.now()+600000).toISOString(),locked_at:null,locked_by:null,updated_at:new Date().toISOString()}).eq("id",job.id);return out({ok:false,job_id:job.id,kind:job.kind,blocked,retry,error:msg},blocked?424:500);}}catch(e){console.error(e);return out({ok:false,error:String(e)},500)}});
