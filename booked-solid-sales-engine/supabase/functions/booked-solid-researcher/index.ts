import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
const H={"Content-Type":"application/json","Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type"};
const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const out=(x:unknown,s=200)=>new Response(JSON.stringify(x),{status:s,headers:H});
const paths=["/","/about","/services","/contact","/team","/estimate","/estimating","/quotes","/pricing","/change-orders","/careers"];

function clean(html:string){
 return html.replace(/<script[\s\S]*?<\/script>/gi," ").replace(/<style[\s\S]*?<\/style>/gi," ")
 .replace(/<[^>]+>/g," ").replace(/&nbsp;/gi," ").replace(/&amp;/gi,"&")
 .replace(/\s+/g," ").trim().slice(0,30000);
}
function tradeFromIdentity(name:string,domain:string,current?:string|null){
 const x=(String(name||"")+" "+String(domain||"")).toLowerCase();const m:string[]=[];
 if(x.includes("roof"))m.push("Roofing");if(x.includes("plumb"))m.push("Plumbing");if(x.includes("electric"))m.push("Electrical");
 if(x.includes("hvac")||x.includes("heating")||x.includes("cooling")||x.includes("air conditioning"))m.push("HVAC");
 if(x.includes("paint"))m.push("Painting");if(x.includes("fence"))m.push("Fence");if(x.includes("cabinet"))m.push("Cabinet");
 const u=[...new Set(m)];if(current&&u.includes(String(current)))return String(current);return u.length===1?u[0]:null;
}
function links(html:string,base:string){
 const a:string[]=[];const re=/href=["']([^"'#]+)["']/gi;let m;
 while((m=re.exec(html))&&a.length<20){try{const u=new URL(m[1],base);if(u.protocol==="https:"&&u.hostname===new URL(base).hostname)a.push(u.toString())}catch{}}
 return [...new Set(a)];
}
function evidence(text:string){
 const rules=[
  ["estimation_pain",/(estimate|estimating|proposal|quoting|quote|pricing)/i],
  ["change_orders",/(change order|change-order|scope change|additional work)/i],
  ["field_quoting",/(on[- ]site quote|field quote|technician quote|instant quote)/i],
  ["workflow_complexity",/(crm|quickbooks|software|spreadsheet|multiple locations|project management)/i]
 ];
 return rules.filter(([,r])=>r.test(text)).map(([type])=>type);
}
function normalizePhone(raw:string){let d=String(raw||"").replace(/(?:ext\.?|extension|x)\s*\d{1,6}\s*$/i,"").replace(/\D/g,"");if(d.length===11&&d.startsWith("1"))d=d.slice(1);if(d.length!==10||Number(d.slice(0,3))<200||Number(d.slice(3,6))<200)return null;return "+1"+d}
function phones(text:string,url:string){
 const rx=/(?:\+?1[\s.\-()]*)?(?:\(?\d{3}\)?[\s.\-]*)\d{3}[\s.\-]*\d{4}(?:\s*(?:x|ext\.?|extension)\s*\d{1,6})?/gi,out:any[]=[];let m;
 while((m=rx.exec(text))){const before=text.slice(Math.max(0,m.index-40),m.index).toLowerCase();if(/fax\s*[:#-]?\s*$/.test(before))continue;const p=normalizePhone(m[0]);if(p)out.push({phone:p,phone_source_url:url});}
 return out;
}
function triggers(text:string){
 const rules:any[]=[
  ["trigger_hiring_estimator",35,/\b(?:now hiring|we(?:'re| are) hiring|join our team|open positions?|apply (?:now|today)|careers?)\b[\s\S]{0,220}\b(?:estimator|estimating|preconstruction|project manager)\b|\b(?:estimator|estimating manager|preconstruction estimator)\b[\s\S]{0,220}\b(?:hiring|apply|career|position)\b/i,"Public site shows active hiring/capacity signals around estimating or project delivery."],
  ["trigger_expansion",28,/\b(?:expanding|expanded|new location|new office|new branch|recently opened|opening (?:a|our|new)|now serving)\b/i,"Public site shows an expansion or new-market signal."],
  ["trigger_manual_workflow",30,/\b(?:spreadsheets?|excel|paper forms?|manual process|manual entry|manually enter|re-?enter(?:ing)? data)\b/i,"Public site contains signs of a manual or spreadsheet-heavy workflow."],
  ["trigger_multi_location_growth",18,/\b(?:multiple locations|several locations|locations across|branch locations|multiple branches|regional offices)\b/i,"Public site shows multi-location or regional operating complexity."],
  ["trigger_quote_speed",18,/\b(?:same[- ]day estimate|instant estimate|instant quote|fast quote|quick estimate|on[- ]site quote)\b/i,"Public site emphasizes quote or estimate speed."],
  ["trigger_change_order_workflow",22,/\b(?:change orders?|change-order|scope changes?|additional work authorization)\b/i,"Public site references change-order or scope-change workflow."],
  ["trigger_recurring_service",12,/\b(?:maintenance agreement|service agreement|maintenance contract|service contract|membership plan)\b/i,"Public site shows recurring service/maintenance workflows."]
 ];
 return rules.filter((x:any)=>x[2].test(text)).map((x:any)=>({type:x[0],strength:x[1],claim:x[3]}));
}
function digitalSignals(flags:any,pages:number){
 const out:any[]=[];
 // These are detection statements, not broad SEO judgments.
 if(pages>0 && !flags.metaDescription && !flags.structuredData){
  out.push({
   type:"seo_foundation_gap",
   claim:"On the sampled public site, the homepage did not expose a meta description or structured-data markup in the fetched HTML.",
   confidence:72,
   metadata:{digital:true,measured:true,check:"homepage_meta_description_or_structured_data"}
  });
 }
 if(pages>=2 && !flags.form && !flags.quoteCta && !flags.contactCta){
  out.push({
   type:"website_conversion_gap",
   claim:"Across the sampled public pages, no clear quote/contact CTA or HTML form was detected in the fetched content.",
   confidence:74,
   metadata:{digital:true,measured:true,check:"cta_or_form"}
  });
 }
 return out;
}
Deno.serve(async req=>{
 try{
  if(req.method==="OPTIONS")return new Response("ok",{headers:H});
  const b=await req.json().catch(()=>({}));let company:any=null;
  if(b.company_id){
   const r=await db.schema("booked_solid").from("companies").select("*").eq("id",b.company_id).single();
   if(r.error)throw r.error;company=r.data;
  }
  const raw=b.url??company?.website_url;
  if(!raw)return out({ok:false,error:"company_id_or_url_required"},400);
  const root=new URL(raw);if(root.protocol!=="https:")return out({ok:false,error:"https_required"},400);
  const urls=[root.toString(),...paths.map(p=>new URL(p,root).toString())];
  let combined="";let foundEmails=new Set<string>();let foundPhones=new Map<string,any>();let pages=0;const seen=new Set<string>();
  const siteFlags={metaDescription:false,structuredData:false,form:false,quoteCta:false,contactCta:false};
  for(const url of urls){
   if(seen.has(url))continue;seen.add(url);
   try{
    const r=await fetch(url,{redirect:"follow",headers:{"User-Agent":"BookedSolidResearchBot/1.0 (+https://www.bookedsolidcopy.com/)"}});
    if(!r.ok)continue;const html=await r.text();pages++;
    const visible=clean(html);combined+=" "+visible;
    if(pages===1){
      siteFlags.metaDescription=/<meta[^>]+name=["']description["'][^>]+content=["'][^"']{20,}["']/i.test(html)||/<meta[^>]+content=["'][^"']{20,}["'][^>]+name=["']description["']/i.test(html);
      siteFlags.structuredData=/application\/ld\+json/i.test(html)&&/(LocalBusiness|Organization|Contractor|HomeAndConstructionBusiness)/i.test(html);
    }
    siteFlags.form=siteFlags.form||/<form\b/i.test(html);
    siteFlags.quoteCta=siteFlags.quoteCta||/\b(?:request|get|schedule|book|start)\s+(?:a\s+)?(?:free\s+)?(?:estimate|quote|consultation)\b/i.test(visible);
    siteFlags.contactCta=siteFlags.contactCta||/\b(?:contact us|call us|schedule service|book service)\b/i.test(visible);
    for(const e of html.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi)??[])foundEmails.add(e.toLowerCase());
    for(const ph of phones(visible,url)){if(!foundPhones.has(ph.phone))foundPhones.set(ph.phone,ph);}
    for(const u of links(html,root.toString()).slice(0,10))if(!seen.has(u))urls.push(u);
   }catch{}
  }
  const types=evidence(combined);const triggerRows=triggers(combined);const digitalRows=digitalSignals(siteFlags,pages);const identityTrade=company?tradeFromIdentity(company.name,company.canonical_domain,company.trade):null;
  if(company){
   await db.schema("booked_solid").from("companies").update({status:"researching",last_researched_at:new Date().toISOString()}).eq("id",company.id);
   for(const type of types){
    const claim="Public website contains signals related to "+type;
    const {data:oldEv}=await db.schema("booked_solid").from("evidence").select("id").eq("company_id",company.id).eq("evidence_type",type).eq("source_url",root.toString()).eq("claim",claim).limit(1);
    if((oldEv??[]).length) await db.schema("booked_solid").from("evidence").update({snippet:combined.slice(0,1200),confidence:70,observed_at:new Date().toISOString(),metadata:{pages_researched:pages}}).eq("id",oldEv[0].id);
    else await db.schema("booked_solid").from("evidence").insert({company_id:company.id,evidence_type:type,claim,snippet:combined.slice(0,1200),source_url:root.toString(),confidence:70,metadata:{pages_researched:pages}});
   }
   for(const tr of triggerRows){const {data:x}=await db.schema("booked_solid").from("evidence").select("id").eq("company_id",company.id).eq("evidence_type",tr.type).eq("source_url",root.toString()).limit(1);if((x??[]).length)await db.schema("booked_solid").from("evidence").update({claim:tr.claim,snippet:combined.slice(0,1200),confidence:80,observed_at:new Date().toISOString(),metadata:{trigger:true,trigger_strength:tr.strength,pages_researched:pages}}).eq("id",x![0].id);else await db.schema("booked_solid").from("evidence").insert({company_id:company.id,evidence_type:tr.type,claim:tr.claim,snippet:combined.slice(0,1200),source_url:root.toString(),confidence:80,metadata:{trigger:true,trigger_strength:tr.strength,pages_researched:pages}});}
   for(const dg of digitalRows){
    const {data:x}=await db.schema("booked_solid").from("evidence").select("id").eq("company_id",company.id).eq("evidence_type",dg.type).eq("source_url",root.toString()).limit(1);
    const payload={claim:dg.claim,snippet:"Measured from fetched public HTML; no visual or performance inference.",confidence:dg.confidence,observed_at:new Date().toISOString(),metadata:{...dg.metadata,pages_researched:pages}};
    if((x??[]).length)await db.schema("booked_solid").from("evidence").update(payload).eq("id",x![0].id);
    else await db.schema("booked_solid").from("evidence").insert({company_id:company.id,evidence_type:dg.type,source_url:root.toString(),...payload});
   }
   for(const email of foundEmails)await db.schema("booked_solid").from("contacts").upsert({
    company_id:company.id,email,email_confidence:60,source_url:root.toString(),status:"unverified"
   },{onConflict:"company_id,email"});
   for(const ph of foundPhones.values()){const {data:x}=await db.schema("booked_solid").from("contacts").select("id").eq("company_id",company.id).eq("phone",ph.phone).limit(1);if((x??[]).length)await db.schema("booked_solid").from("contacts").update({phone_type:"company_public",phone_confidence:72,phone_source_url:ph.phone_source_url,phone_status:"unverified",sms_consent_status:"unknown",sms_eligible:false,phone_last_verified_at:new Date().toISOString(),updated_at:new Date().toISOString()}).eq("id",x![0].id);else await db.schema("booked_solid").from("contacts").insert({company_id:company.id,phone:ph.phone,phone_type:"company_public",phone_confidence:72,phone_source_url:ph.phone_source_url,phone_status:"unverified",sms_consent_status:"unknown",sms_eligible:false,phone_last_verified_at:new Date().toISOString(),status:"unverified"});}
   await db.schema("booked_solid").from("companies").update({status:company.status==="qualified"?"qualified":"discovered",last_researched_at:new Date().toISOString(),last_enriched_at:new Date().toISOString(),enrichment_version:1,...(identityTrade?{trade:identityTrade}:{}),metadata:{...(company.metadata??{}),phones_found:foundPhones.size,trigger_types:triggerRows.map((x:any)=>x.type)}}).eq("id",company.id);
  }
  return out({ok:true,url:root.toString(),pages_researched:pages,signals:types,triggers:triggerRows.map((x:any)=>({type:x.type,strength:x.strength})),digital_signals:digitalRows.map((x:any)=>x.type),emails_found:[...foundEmails].length,phones_found:foundPhones.size});
 }catch(e){console.error(e);return out({ok:false,error:String(e)},500)}
});
