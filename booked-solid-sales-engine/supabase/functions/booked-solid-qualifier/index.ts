import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
const H={"Content-Type":"application/json","Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type"};
const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const out=(x:unknown,s=200)=>new Response(JSON.stringify(x),{status:s,headers:H});

Deno.serve(async req=>{
 try{
  if(req.method==="OPTIONS")return new Response("ok",{headers:H});
  const b=await req.json().catch(()=>({}));if(!b.company_id)return out({ok:false,error:"company_id_required"},400);
  const id=b.company_id;
  const [{data:company,error:ce},{data:evidence,error:ee},{data:contacts,error:cte},{data:existingLeads,error:lee}]=await Promise.all([
   db.schema("booked_solid").from("companies").select("*").eq("id",id).single(),
   db.schema("booked_solid").from("evidence").select("*").eq("company_id",id).order("observed_at",{ascending:false}).limit(100),
   db.schema("booked_solid").from("contacts").select("*").eq("company_id",id).neq("status","suppressed"),
   db.schema("booked_solid").from("leads").select("id,status,offer").eq("company_id",id)
  ]);
  if(ce)throw ce;if(ee)throw ee;if(cte)throw cte;if(lee)throw lee;
  const rows=evidence??[];
  const types=new Set(rows.map((x:any)=>x.evidence_type));
  const text=((company.name??"")+" "+(company.normalized_name??"")+" "+rows.map((x:any)=>((x.claim??"")+" "+(x.snippet??""))).join(" ")).toLowerCase();
  const vendorTerms=["software company","software platform","saas","software provider","technology platform","proptech","property management software","estimation software","estimating software","crm software","workflow software","ai platform","api","marketplace","software solution","technology company"];
  const operatorTerms=["property management company","property manager","property management services","rental management","vacation rental management","apartment management","real estate management services"];
  const vendorName=/\b(software|saas|platform|workflow automation|technology|proptech)\b/i.test(String(company.name||""));const isVendor=Boolean(company.metadata?.hard_excluded_vendor)||vendorName||(vendorTerms.some(t=>text.includes(t)) && !operatorTerms.some(t=>text.includes(t)));const hospitalityNonBuyer=company.trade==="Property Operations"&&/\b(hotel|resort|motel|inn|suites?)\b/i.test(String(company.name||"")+" "+String(company.canonical_domain||""));
  if(isVendor||hospitalityNonBuyer){
   await db.schema("booked_solid").from("companies").update({status:"rejected",recommended_offer:null,updated_at:new Date().toISOString()}).eq("id",id);
   await db.schema("booked_solid").from("leads").update({status:"suppressed",why_now:isVendor?"Excluded: technology/software vendor rather than an end-customer operating business.":"Excluded: hospitality property rather than a property-management operator.",updated_at:new Date().toISOString()}).eq("company_id",id).neq("status","won");
   return out({ok:true,company_id:id,status:"rejected",reason:isVendor?"software_vendor":"hospitality_nonbuyer"});
  }
  const contractorTrades=["HVAC","Roofing","Plumbing","Electrical","Remodeling","Painting","General Contractor","Commercial Contractor","Cabinet","Flooring","Concrete","Landscaping","Windows","Siding","Deck Builder","Home Builder","Construction"];
  const fit=contractorTrades.includes(company.trade)?25:company.trade==="Property Operations"?22:15;
  const painTypes=["estimation_pain","field_quoting","change_orders","workflow_complexity"];
  const pain=Math.min(35,Array.from(types).filter(t=>painTypes.includes(t)).length*12);
  const evidenceScore=Math.min(20,rows.filter((x:any)=>x.evidence_type!=="search_result").length*4);
  const contact=(contacts??[]).find((c:any)=>c.email)?.email_confidence??0;
  const contactScore=Math.min(20,Number(contact)/5);
  const score=Math.min(100,fit+pain+evidenceScore+contactScore);
  let offer="custom_estimator";
  if(types.has("change_orders"))offer="penmark";
  else if(types.has("workflow_complexity")&&!types.has("estimation_pain"))offer="automation";
  const prospectType=types.has("estimation_pain")||types.has("field_quoting")||types.has("change_orders")?"pain_led":"fit_led";
  const why=prospectType==="pain_led"?"Public evidence shows a relevant operational/estimating signal.":"Company appears to fit Booked Solid's target customer profile; no pain is assumed.";
  const priorQualified=(existingLeads??[]).some((x:any)=>x.status==="qualified");
  const status=priorQualified?"qualified":score>=65&&rows.filter((x:any)=>x.evidence_type!=="search_result").length>=1?"qualified":score>=40?"candidate":"rejected";
  const {data:lead,error:le}=await db.schema("booked_solid").from("leads").upsert({
    company_id:id,contact_id:(contacts??[]).find((c:any)=>c.email)?.id??null,offer,score,
    fit_score:fit,pain_score:pain,evidence_score:evidenceScore,contact_score:contactScore,status,
    why_now:why,lead_brief:{evidence_types:[...types],company:company.name,website:company.website_url,prospect_type:prospectType,contact_status:contact?"unverified":"missing"}
  },{onConflict:"company_id,offer"}).select("*").single();
  if(le)throw le;
  if(status==="qualified"){
   await db.schema("booked_solid").from("outreach_queue").upsert({
    lead_id:lead.id,sequence_no:1,status:"blocked_email_not_configured",
    personalization_evidence:rows.slice(0,5).map((x:any)=>({claim:x.claim,url:x.source_url,snippet:x.snippet}))
   },{onConflict:"lead_id,sequence_no"});
   await db.schema("booked_solid").from("companies").update({status:"qualified",recommended_offer:offer,fit_score:fit,updated_at:new Date().toISOString()}).eq("id",id);
  } else if(status==="candidate"){
   await db.schema("booked_solid").from("companies").update({status:"discovered",updated_at:new Date().toISOString()}).eq("id",id);
  } else {
   await db.schema("booked_solid").from("companies").update({status:"rejected",recommended_offer:null,updated_at:new Date().toISOString()}).eq("id",id);
  }
  return out({ok:true,company_id:id,score,offer,status,prospect_type:prospectType,contact_email:(contacts??[]).find((c:any)=>c.email)?.email??null});
 }catch(e){console.error(e);return out({ok:false,error:String(e)},500)}
});