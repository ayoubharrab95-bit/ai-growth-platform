import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
const H={"Content-Type":"application/json","Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type"};
const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const out=(x:unknown,s=200)=>new Response(JSON.stringify(x),{status:s,headers:H});
function domainOf(raw:string){try{return new URL(raw).hostname.replace(/^www\./,"").toLowerCase()}catch{return null}}
function normalize(s:string){return s.toLowerCase().replace(/[^a-z0-9]+/g," ").trim()}
function clean(html:string){return html.replace(/<script[\s\S]*?<\/script>/gi," ").replace(/<style[\s\S]*?<\/style>/gi," ").replace(/<[^>]+>/g," ").replace(/&nbsp;/gi," ").replace(/&amp;/gi,"&").replace(/\s+/g," ").trim().slice(0,30000)}
function signalTypes(text:string){const r:[string,RegExp][]=[["estimation_pain",/(estimate|estimating|proposal|quoting|quote|pricing)/i],["change_orders",/(change order|change-order|scope change|additional work)/i],["field_quoting",/(on[- ]site quote|field quote|technician quote|instant quote)/i],["workflow_complexity",/(crm|quickbooks|software|spreadsheet|multiple locations|project management)/i]];return r.filter(([,x])=>x.test(text)).map(([t])=>t)}
async function search(q:string){
 const tavily=Deno.env.get("TAVILY_API_KEY");
 if(tavily){
  const r=await fetch("https://api.tavily.com/search",{method:"POST",headers:{"Content-Type":"application/json"},body:JSON.stringify({api_key:tavily,query:q,search_depth:"basic",max_results:20,include_answer:false,include_raw_content:false})});
  if(!r.ok)throw new Error("tavily_search_http_"+r.status);
  const j=await r.json();return {provider:"tavily",results:(j.results??[]).map((x:any)=>({url:x.url,title:x.title,description:x.content}))};
 }
 const brave=Deno.env.get("BRAVE_SEARCH_API_KEY");
 if(brave){
  const u=new URL("https://api.search.brave.com/res/v1/web/search");u.searchParams.set("q",q);u.searchParams.set("country","US");u.searchParams.set("search_lang","en");u.searchParams.set("count","20");
  const r=await fetch(u,{headers:{"Accept":"application/json","X-Subscription-Token":brave}});if(!r.ok)throw new Error("brave_search_http_"+r.status);
  const j=await r.json();return {provider:"brave",results:(j.web?.results??[]).map((x:any)=>({url:x.url,title:x.title,description:x.description}))};
 }
 throw new Error("SEARCH_PROVIDER_NOT_CONFIGURED:TAVILY_API_KEY_OR_BRAVE_SEARCH_API_KEY");
}
async function discover(job:any){
 const p=job.payload;const q=String(p.query_template).replace("{trade}",p.trade).replace("{location}",p.geography==="US"?"United States":p.geography);const sr=await search(q);let n=0;
 for(const item of sr.results){const domain=domainOf(item.url);if(!domain)continue;const name=(item.title??domain).replace(/\s*[|–-]\s*.*$/,"").trim();
  const {data:c,error}=await db.schema("booked_solid").from("companies").upsert({canonical_domain:domain,normalized_name:normalize(name),name,trade:p.trade==="Mixed"?null:p.trade,website_url:"https://"+domain+"/",source_first_seen:sr.provider,source_last_seen:sr.provider,status:"discovered",metadata:{query:q}},{onConflict:"canonical_domain"}).select("*").single();if(error)throw error;
  await db.schema("booked_solid").from("evidence").insert({company_id:c.id,evidence_type:"search_result",claim:item.description??item.title??"Search result",snippet:item.description??null,source_url:item.url,confidence:55,metadata:{provider:sr.provider,query:q}});
  if(!c.last_researched_at)await db.schema("booked_solid").from("work_queue").insert({kind:"research",priority:Number(job.priority)+5,payload:{company_id:c.id,strategy_id:p.strategy_id},status:"pending"});n++;}
 return {provider:sr.provider,query:q,results:sr.results.length,companies:n};
}
async function research(job:any){
 const {data:c,error}=await db.schema("booked_solid").from("companies").select("*").eq("id",job.payload.company_id).single();if(error)throw error;const root=new URL(c.website_url);if(root.protocol!=="https:")throw new Error("HTTPS_REQUIRED");
 const paths=["/","/about","/services","/contact","/team","/estimate","/estimating","/quotes","/pricing","/change-orders","/careers"];let combined="";let pages=0;const emails=new Set<string>();
 for(const p of paths){try{const r=await fetch(new URL(p,root),{redirect:"follow",headers:{"User-Agent":"BookedSolidResearchBot/1.0 (+https://www.bookedsolidcopy.com/)"}});if(!r.ok)continue;const h=await r.text();pages++;combined+=" "+clean(h);for(const e of h.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi)??[])emails.add(e.toLowerCase())}catch{}}
 const types=signalTypes(combined);for(const t of types)await db.schema("booked_solid").from("evidence").insert({company_id:c.id,evidence_type:t,claim:"Public website contains signals related to "+t,snippet:combined.slice(0,1200),source_url:root.toString(),confidence:70,metadata:{pages_researched:pages}});
 for(const email of emails)await db.schema("booked_solid").from("contacts").upsert({company_id:c.id,email,email_confidence:60,source_url:root.toString(),status:"unverified"},{onConflict:"company_id,email"});
 await db.schema("booked_solid").from("companies").update({last_researched_at:new Date().toISOString(),status:"discovered"}).eq("id",c.id);
 await db.schema("booked_solid").from("work_queue").insert({kind:"qualify",priority:Number(job.priority)+5,payload:{company_id:c.id,strategy_id:job.payload.strategy_id},status:"pending"});
 return {pages,signals:types,emails:emails.size};
}
async function qualify(job:any){
 const id=job.payload.company_id;const [{data:c,error:ce},{data:ev,error:ee},{data:ct,error:te}]=await Promise.all([db.schema("booked_solid").from("companies").select("*").eq("id",id).single(),db.schema("booked_solid").from("evidence").select("*").eq("company_id",id).limit(100),db.schema("booked_solid").from("contacts").select("*").eq("company_id",id).neq("status","suppressed")]);if(ce)throw ce;if(ee)throw ee;if(te)throw te;
 const types=new Set((ev??[]).map((x:any)=>x.evidence_type));const fit=["HVAC","Roofing","Plumbing","Electrical","Remodeling","Painting"].includes(c.trade)?25:15;const pain=Math.min(35,[...types].filter(t=>["estimation_pain","field_quoting","change_orders","workflow_complexity"].includes(t)).length*12);const evidenceScore=Math.min(20,(ev??[]).length*4);const cc=Number((ct??[]).find((x:any)=>x.email)?.email_confidence??0);const contactScore=Math.min(20,cc/5);const score=Math.min(100,fit+pain+evidenceScore+contactScore);
 let offer="custom_estimator";if(types.has("change_orders"))offer="penmark";else if(types.has("workflow_complexity")&&!types.has("estimation_pain"))offer="automation";const status=score>=70&&cc>=50?"qualified":score>=50?"candidate":"rejected";
 const {data:lead,error:le}=await db.schema("booked_solid").from("leads").upsert({company_id:id,contact_id:(ct??[]).find((x:any)=>x.email)?.id??null,strategy_id:job.payload.strategy_id??null,offer,score,fit_score:fit,pain_score:pain,evidence_score:evidenceScore,contact_score:contactScore,status,why_now:types.has("change_orders")?"Public website shows change-order related signals.":types.has("estimation_pain")?"Public website shows estimating/quoting/proposal signals.":"Public website shows workflow/software complexity signals.",lead_brief:{evidence_types:[...types],company:c.name,website:c.website_url}},{onConflict:"company_id,offer"}).select("*").single();if(le)throw le;
 if(status==="qualified")await db.schema("booked_solid").from("work_queue").insert({kind:"message",priority:score,payload:{lead_id:lead.id},status:"pending"});return {score,offer,status};
}
async function message(job:any){
 const {data:l,error}=await db.schema("booked_solid").from("leads").select("*,companies(*),contacts(*)").eq("id",job.payload.lead_id).single();if(error)throw error;const {data:ev}=await db.schema("booked_solid").from("evidence").select("claim,source_url").eq("company_id",l.company_id).limit(3);const name=l.contacts?.full_name?.split(" ")[0]||"there";const first=ev?.[0]?.claim||"your estimating workflow";
 let subject="A quick question about estimating at "+l.companies.name;let body="Hi "+name+",\n\nI was looking at "+l.companies.name+" and noticed "+first.toLowerCase()+".\n\nBooked Solid Copy builds custom estimating and workflow tools for contractors around the way their team already works.\n\nIf quoting or proposal work is taking more time than it should, would it be useful to compare notes for 15 minutes?\n\nBest,\nCourtney\nBooked Solid Copy";
 if(l.offer==="penmark"){subject="A quick question about change orders at "+l.companies.name;body="Hi "+name+",\n\nI was looking at "+l.companies.name+" and noticed "+first.toLowerCase()+".\n\nBooked Solid Copy built PenMark to document change orders, approvals, photos and updated job values without adding a monthly software bill.\n\nIf change orders are ever getting lost between the field and office, I can show you how it works.\n\nBest,\nCourtney\nBooked Solid Copy";}
 await db.schema("booked_solid").from("outreach_queue").upsert({lead_id:l.id,sequence_no:1,subject,body,status:"blocked_email_not_configured",personalization_evidence:(ev??[]).map((x:any)=>({claim:x.claim,url:x.source_url}))},{onConflict:"lead_id,sequence_no"});await db.schema("booked_solid").from("leads").update({status:"message_ready"}).eq("id",l.id);return {lead_id:l.id,status:"blocked_email_not_configured"};
}
Deno.serve(async req=>{try{if(req.method==="OPTIONS")return new Response("ok",{headers:H});const {data:jobs,error}=await db.schema("booked_solid").rpc("claim_work",{p_worker:"booked-solid-"+crypto.randomUUID()});if(error)throw error;const job=jobs?.[0];if(!job)return out({ok:true,idle:true});let result:any;try{if(job.kind==="discover")result=await discover(job);else if(job.kind==="research")result=await research(job);else if(job.kind==="qualify")result=await qualify(job);else if(job.kind==="message")result=await message(job);else result={skipped:job.kind};await db.schema("booked_solid").from("work_queue").update({status:"done",last_error:null,updated_at:new Date().toISOString()}).eq("id",job.id);return out({ok:true,job_id:job.id,kind:job.kind,result});}catch(e){const msg=String(e);const blocked=msg.includes("SEARCH_PROVIDER_NOT_CONFIGURED");await db.schema("booked_solid").from("work_queue").update({status:blocked?"blocked":"failed",last_error:msg,available_at:new Date(Date.now()+600000).toISOString(),updated_at:new Date().toISOString()}).eq("id",job.id);return out({ok:false,job_id:job.id,kind:job.kind,blocked,error:msg},blocked?424:500);}}catch(e){console.error(e);return out({ok:false,error:String(e)},500)}});
