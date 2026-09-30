import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
const H={"Content-Type":"application/json","Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type"};
const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const out=(x:unknown,s=200)=>new Response(JSON.stringify(x),{status:s,headers:H});
function weakMailbox(email:string){const e=String(email||"").toLowerCase();const lp=e.split("@")[0];return !lp||lp.length<2||["first","firstname","test","example"].includes(lp)||/(employment|careers?|jobs?|support|concierge|reservations?|dining|spa|events?|groups?|humanresources|human-resources|noreply|no-reply|donotreply|do-not-reply)/.test(lp)||lp==="hr"}
function triggerSummary(rows:any[]){
 const best=new Map<string,any>();
 for(const r of rows||[]){const t=String(r.evidence_type||"");if(!t.startsWith("trigger_"))continue;const s=Number(r.metadata?.trigger_strength||0),p=best.get(t);if(!p||s>Number(p.metadata?.trigger_strength||0))best.set(t,r)}
 const items=[...best.values()].sort((a:any,b:any)=>Number(b.metadata?.trigger_strength||0)-Number(a.metadata?.trigger_strength||0));
 return {score:Math.min(100,items.reduce((n:number,x:any)=>n+Number(x.metadata?.trigger_strength||0),0)),items,strongest:items[0]??null};
}


Deno.serve(async req=>{
 try{
  if(req.method==="OPTIONS")return new Response("ok",{headers:H});
  const b=await req.json().catch(()=>({}));if(!b.company_id)return out({ok:false,error:"company_id_required"},400);
  const id=b.company_id;
  const [{data:company,error:ce},{data:evidence,error:ee},{data:contacts,error:cte},{data:existingLeads,error:lee}]=await Promise.all([
   db.schema("booked_solid").from("companies").select("*").eq("id",id).single(),
   db.schema("booked_solid").from("evidence").select("*").eq("company_id",id).order("observed_at",{ascending:false}).limit(100),
   db.schema("booked_solid").from("contacts").select("*").eq("company_id",id).neq("status","suppressed"),
   db.schema("booked_solid").from("leads").select("id,status,offer,lead_brief").eq("company_id",id)
  ]);
  if(ce)throw ce;if(ee)throw ee;if(cte)throw cte;if(lee)throw lee;
  const rows=evidence??[];
  const types=new Set(rows.map((x:any)=>x.evidence_type));const triggers=triggerSummary(rows);const triggerScore=triggers.score;
  const text=((company.name??"")+" "+(company.normalized_name??"")+" "+rows.map((x:any)=>((x.claim??"")+" "+(x.snippet??""))).join(" ")).toLowerCase();
  const vendorTerms=["software company","software platform","saas","software provider","technology platform","proptech","property management software","estimation software","estimating software","crm software","workflow software","ai platform","api","marketplace","software solution","technology company"];
  const operatorTerms=["property management company","property manager","property management services","rental management","vacation rental management","apartment management","real estate management services"];
  const vendorName=/\b(software|saas|platform|workflow automation|technology|proptech)\b/i.test(String(company.name||""));const isVendor=Boolean(company.metadata?.hard_excluded_vendor)||vendorName||(vendorTerms.some(t=>text.includes(t)) && !operatorTerms.some(t=>text.includes(t)));const hospitalityNonBuyer=company.trade==="Property Operations"&&/\b(hotel|resort|motel|inn|suites?)\b/i.test(String(company.name||"")+" "+String(company.canonical_domain||""));const leadgenTitle=/^(get|request|compare|find)\b.*\b(estimate|estimates|quote|quotes)\b/i.test(String(company.name||""));
  if(isVendor||hospitalityNonBuyer||leadgenTitle){
   await db.schema("booked_solid").from("companies").update({status:"rejected",recommended_offer:null,updated_at:new Date().toISOString()}).eq("id",id);
   await db.schema("booked_solid").from("leads").update({status:"suppressed",why_now:isVendor?"Excluded: technology/software vendor rather than an end-customer operating business.":hospitalityNonBuyer?"Excluded: hospitality property rather than a property-management operator.":"Excluded: lead-generation/quote page rather than an operating company.",updated_at:new Date().toISOString()}).eq("company_id",id).neq("status","won");
   return out({ok:true,company_id:id,status:"rejected",reason:isVendor?"software_vendor":hospitalityNonBuyer?"hospitality_nonbuyer":"leadgen_page"});
  }
  const contractorTrades=["HVAC","Roofing","Plumbing","Electrical","Remodeling","Painting","General Contractor","Commercial Contractor","Cabinet","Flooring","Concrete","Landscaping","Windows","Siding","Deck Builder","Home Builder","Construction"];
  const fit=contractorTrades.includes(company.trade)?25:company.trade==="Property Operations"?22:15;
  const painTypes=["estimation_pain","field_quoting","change_orders","workflow_complexity"];
  const pain=Math.min(35,Array.from(types).filter(t=>painTypes.includes(t)).length*12);
  const evidenceScore=Math.min(20,rows.filter((x:any)=>x.evidence_type!=="search_result").length*4);
  const usableContact=(contacts??[]).find((c:any)=>c.email&&!weakMailbox(c.email)&&c.status!=="invalid"&&c.status!=="suppressed");const contact=usableContact?.email_confidence??0;
  const contactScore=Math.min(20,Number(contact)/5);
  const score=Math.min(100,fit+pain+evidenceScore+contactScore);const opportunityScore=Math.round(Math.min(100,score*0.82+triggerScore*0.18));const priorityBand=triggerScore>=35&&opportunityScore>=80?"hot":opportunityScore>=70?"high":triggerScore>=20?"signal":"standard";
  let offer="custom_estimator";
  if(types.has("change_orders"))offer="penmark";
  else if(types.has("workflow_complexity")&&!types.has("estimation_pain"))offer="automation";
  const prospectType=types.has("estimation_pain")||types.has("field_quoting")||types.has("change_orders")?"pain_led":"fit_led";
  const why=triggers.strongest?.claim||(prospectType==="pain_led"?"Public evidence shows a relevant operational/estimating signal.":"Company appears to fit Booked Solid's target customer profile; no pain is assumed.");
  const priorQualified=(existingLeads??[]).some((x:any)=>x.status==="qualified");
  const status=priorQualified?"qualified":score>=65&&rows.filter((x:any)=>x.evidence_type!=="search_result").length>=1?"qualified":score>=40?"candidate":"rejected";
  const priorBrief=(existingLeads??[]).find((x:any)=>x.status==="qualified")?.lead_brief??(existingLeads??[])[0]?.lead_brief??{};
  const {data:lead,error:le}=await db.schema("booked_solid").from("leads").upsert({
    company_id:id,contact_id:usableContact?.id??null,offer,score,
    fit_score:fit,pain_score:pain,evidence_score:evidenceScore,contact_score:contactScore,trigger_score:triggerScore,opportunity_score:opportunityScore,priority_band:priorityBand,status,
    why_now:why,lead_brief:{...priorBrief,evidence_types:[...types],company:company.name,website:company.website_url,prospect_type:prospectType,contact_status:contact?"unverified":"missing",trigger_summary:{score:triggerScore,types:triggers.items.map((x:any)=>x.evidence_type),strongest_type:triggers.strongest?.evidence_type||null,strongest_claim:triggers.strongest?.claim||null,updated_at:new Date().toISOString()},micro_audit:{headline:triggers.strongest?.claim||why,findings:triggers.items.slice(0,3).map((x:any)=>({type:x.evidence_type,claim:x.claim,source_url:x.source_url,confidence:x.confidence})),generated_from_public_evidence:true}}
  },{onConflict:"company_id,offer"}).select("*").single();
  if(le)throw le;
  if(status==="qualified"){
   const {data:cq}=await db.schema("booked_solid").from("work_queue").select("id").eq("kind","contact").in("status",["pending","running"]).contains("payload",{lead_id:lead.id}).limit(1);
   if(!(cq??[]).length)await db.schema("booked_solid").from("work_queue").insert({kind:"contact",priority:score+10+Math.min(15,triggerScore*0.15),payload:{lead_id:lead.id,company_id:id},status:"pending"});
   await db.schema("booked_solid").from("companies").update({status:"qualified",recommended_offer:offer,fit_score:fit,updated_at:new Date().toISOString()}).eq("id",id);
  } else if(status==="candidate"){
   await db.schema("booked_solid").from("companies").update({status:"discovered",updated_at:new Date().toISOString()}).eq("id",id);
  } else {
   await db.schema("booked_solid").from("companies").update({status:"rejected",recommended_offer:null,updated_at:new Date().toISOString()}).eq("id",id);
  }
  return out({ok:true,company_id:id,score,offer,status,prospect_type:prospectType,contact_email:usableContact?.email??null,trigger_score:triggerScore,opportunity_score:opportunityScore,priority_band:priorityBand,sms_enabled:false});
 }catch(e){console.error(e);return out({ok:false,error:String(e)},500)}
});