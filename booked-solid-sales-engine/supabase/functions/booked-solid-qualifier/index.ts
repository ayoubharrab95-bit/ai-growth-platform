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
  const [{data:company,error:ce},{data:evidence,error:ee},{data:contacts,error:cte}]=await Promise.all([
   db.schema("booked_solid").from("companies").select("*").eq("id",id).single(),
   db.schema("booked_solid").from("evidence").select("*").eq("company_id",id).order("observed_at",{ascending:false}).limit(100),
   db.schema("booked_solid").from("contacts").select("*").eq("company_id",id).neq("status","suppressed")
  ]);
  if(ce)throw ce;if(ee)throw ee;if(cte)throw cte;
  const types=new Set((evidence??[]).map((x:any)=>x.evidence_type));
  const fit=["HVAC","Roofing","Plumbing","Electrical","Remodeling","Painting"].includes(company.trade)?25:15;
  const pain=Math.min(35,Array.from(types).reduce((n:string[],t)=>{if(["estimation_pain","field_quoting","change_orders","workflow_complexity"].includes(t))n.push(t);return n},[]).length*12);
  const evidenceScore=Math.min(20,(evidence??[]).length*4);
  const contact=(contacts??[]).find((c:any)=>c.email)?.email_confidence??0;
  const contactScore=Math.min(20,Number(contact)/5);
  const score=Math.min(100,fit+pain+evidenceScore+contactScore);
  let offer="custom_estimator";
  if(types.has("change_orders"))offer="penmark";
  else if(types.has("workflow_complexity")&&!types.has("estimation_pain"))offer="automation";
  const why=types.has("change_orders")?"Public website shows change-order related signals.":types.has("estimation_pain")?"Public website shows estimating/quoting/proposal signals.":"Public website shows workflow/software complexity signals.";
  const status=score>=70&&contact>=50?"qualified":score>=50?"candidate":"rejected";
  const {data:lead,error:le}=await db.schema("booked_solid").from("leads").upsert({
    company_id:id,contact_id:(contacts??[]).find((c:any)=>c.email)?.id??null,offer,score,
    fit_score:fit,pain_score:pain,evidence_score:evidenceScore,contact_score:contactScore,status,
    why_now:why,lead_brief:{evidence_types:[...types],company:company.name,website:company.website_url}
  },{onConflict:"company_id,offer"}).select("*").single();
  if(le)throw le;
  if(status==="qualified"){
   await db.schema("booked_solid").from("outreach_queue").upsert({
    lead_id:lead.id,sequence_no:1,status:"blocked_email_not_configured",
    personalization_evidence:(evidence??[]).slice(0,5).map((x:any)=>({claim:x.claim,url:x.source_url,snippet:x.snippet}))
   },{onConflict:"lead_id,sequence_no"});
  }
  return out({ok:true,company_id:id,score,offer,status,contact_email:(contacts??[]).find((c:any)=>c.email)?.email??null});
 }catch(e){console.error(e);return out({ok:false,error:String(e)},500)}
});
