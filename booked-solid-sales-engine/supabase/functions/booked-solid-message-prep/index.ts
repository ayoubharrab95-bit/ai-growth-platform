import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
const H={"Content-Type":"application/json","Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type"};
const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const out=(x:unknown,s=200)=>new Response(JSON.stringify(x),{status:s,headers:H});
function esc(s:string){return s.replace(/[\r\n]+/g," ").trim()}
Deno.serve(async req=>{
 try{
  if(req.method==="OPTIONS")return new Response("ok",{headers:H});
  const b=await req.json().catch(()=>({}));if(!b.lead_id)return out({ok:false,error:"lead_id_required"},400);
  const {data:lead,error}=await db.schema("booked_solid").from("leads").select("*,companies(*),contacts(*)").eq("id",b.lead_id).single();if(error)throw error;
  if(lead.status!=="qualified")return out({ok:false,error:"lead_not_qualified",status:lead.status},409);
  const c=lead.companies;const contact=lead.contacts;const name=contact?.full_name?.split(" ")[0]||"there";
  const evidence=await db.schema("booked_solid").from("evidence").select("claim,snippet,source_url").eq("company_id",c.id).order("observed_at",{ascending:false}).limit(3);
  const first=evidence.data?.[0]?.claim||"your estimating workflow";
  let subject="A quick question about estimating at "+c.name;
  let body="Hi "+esc(name)+",\n\nI was looking at "+esc(c.name)+" and noticed "+esc(first).toLowerCase()+".\n\nBooked Solid Copy builds custom estimating and workflow tools for contractors, designed around the way a team already works rather than forcing another generic platform.\n\nIf quoting or proposal work is taking more time than it should, would it be useful to compare notes for 15 minutes?\n\nBest,\nCourtney\nBooked Solid Copy";
  if(lead.offer==="penmark"){
   subject="A quick question about change orders at "+c.name;
   body="Hi "+esc(name)+",\n\nI was looking at "+esc(c.name)+" and noticed "+esc(first).toLowerCase()+".\n\nBooked Solid Copy built PenMark to document change orders, approvals, photos and updated job values without adding a monthly software bill.\n\nIf change orders are ever getting lost between the field and the office, I can show you how it works.\n\nBest,\nCourtney\nBooked Solid Copy";
  }
  const {data:q,error:qe}=await db.schema("booked_solid").from("outreach_queue").upsert({
   lead_id:lead.id,sequence_no:1,subject,body,status:"blocked_email_not_configured",
   personalization_evidence:(evidence.data??[]).map((x:any)=>({claim:x.claim,url:x.source_url}))
  },{onConflict:"lead_id,sequence_no"}).select("*").single();if(qe)throw qe;
  await db.schema("booked_solid").from("leads").update({status:"message_ready"}).eq("id",lead.id);
  return out({ok:true,queue_id:q.id,status:"blocked_email_not_configured",preview:{subject,body}});
 }catch(e){console.error(e);return out({ok:false,error:String(e)},500)}
});
