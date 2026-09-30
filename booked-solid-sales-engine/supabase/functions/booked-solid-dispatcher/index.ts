
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
const H={"Content-Type":"application/json","Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type"};
const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const out=(x:unknown,s=200)=>new Response(JSON.stringify(x),{status:s,headers:H});
function domain(email:string){return String(email||"").split("@")[1]?.toLowerCase()||""}
Deno.serve(async req=>{
 try{
  if(req.method==="OPTIONS")return new Response("ok",{headers:H});
  const body=await req.json().catch(()=>({}));
  const [{data:runtime},{data:settings}]=await Promise.all([
   db.schema("booked_solid").from("runtime_settings").select("*").eq("id",true).single(),
   db.schema("booked_solid").from("outreach_settings").select("*").eq("id",true).single()
  ]);
  const missing:string[]=[];
  if(!runtime?.email_enabled)missing.push("email_enabled=false");
  if(!runtime?.email_provider)missing.push("email_provider");
  if(runtime?.email_provider&&runtime.email_provider!=="resend")missing.push("unsupported_email_provider:"+runtime.email_provider);
  if(!settings?.sender_email)missing.push("sender_email");
  if(!settings?.postal_address)missing.push("postal_address");
  if(runtime?.email_provider==="resend"&&!Deno.env.get("RESEND_API_KEY"))missing.push("RESEND_API_KEY");
  if(missing.length)return out({ok:true,blocked:true,reason:"email_gate_not_ready",missing});

  const since=new Date(Date.now()-24*3600000).toISOString();
  const {count:sent24}=await db.schema("booked_solid").from("outreach_queue").select("*",{count:"exact",head:true}).eq("status","sent").gte("sent_at",since);
  const remaining=Math.max(0,Number(settings.max_daily_sends||20)-Number(sent24||0));
  if(!remaining)return out({ok:true,blocked:true,reason:"daily_limit_reached",sent_24h:sent24});

  const limit=Math.min(remaining,Math.max(1,Math.min(Number(body.limit||5),10)));
  const {data:due,error:de}=await db.schema("booked_solid").from("outreach_queue")
    .select("*,leads(id,status)")
    .eq("status","ready")
    .lte("scheduled_at",new Date().toISOString())
    .order("scheduled_at",{ascending:true})
    .limit(limit);
  if(de)throw de;
  const results:any[]=[];

  for(const q of due||[]){
   if(q.leads?.status!=="qualified"){await db.schema("booked_solid").from("outreach_queue").update({status:"cancelled",failure_reason:"lead no longer qualified"}).eq("id",q.id);continue;}
   const email=String(q.recipient_email||"").toLowerCase();if(!email){await db.schema("booked_solid").from("outreach_queue").update({status:"failed",failure_reason:"recipient_email_missing"}).eq("id",q.id);continue;}
   const [{data:supEmail},{data:supDomain},{data:stops}]=await Promise.all([
    db.schema("booked_solid").from("suppression").select("id").eq("email",email).limit(1),
    db.schema("booked_solid").from("suppression").select("id").eq("domain",domain(email)).limit(1),
    db.schema("booked_solid").from("outreach_events").select("id,event_type").eq("lead_id",q.lead_id).in("event_type",["reply","booking","bounce","unsubscribe"]).limit(1)
   ]);
   if((supEmail??[]).length||(supDomain??[]).length||(stops??[]).length){
    await db.schema("booked_solid").from("outreach_queue").update({status:"suppressed",failure_reason:"suppression/stop condition"}).eq("id",q.id);continue;
   }
   const unsub=Deno.env.get("SUPABASE_URL")!+"/functions/v1/booked-solid-unsubscribe?t="+encodeURIComponent(String(q.tracking_key));
   const html=String(q.body_html||"").replaceAll("{{POSTAL_ADDRESS}}",String(settings.postal_address)).replaceAll("{{unsubscribe_url}}",unsub);
   const text=String(q.body_text||q.body||"")+"\n\n"+String(settings.postal_address)+"\nUnsubscribe: "+unsub;

   if(runtime.email_provider!=="resend"){results.push({id:q.id,skipped:"unsupported_provider"});continue;}
   const rr=await fetch("https://api.resend.com/emails",{method:"POST",signal:AbortSignal.timeout(15000),headers:{
    "Authorization":"Bearer "+Deno.env.get("RESEND_API_KEY")!,"Content-Type":"application/json"
   },body:JSON.stringify({
    from:settings.sender_name+" <"+settings.sender_email+">",
    to:[email],
    subject:q.subject,
    html,
    text,
    reply_to:settings.sender_email,
    headers:{"List-Unsubscribe":"<"+unsub+">","List-Unsubscribe-Post":"List-Unsubscribe=One-Click"}
   })});
   const payload=await rr.json().catch(()=>({}));
   if(!rr.ok){await db.schema("booked_solid").from("outreach_queue").update({status:"failed",failure_reason:"resend_http_"+rr.status+":"+JSON.stringify(payload).slice(0,300)}).eq("id",q.id);results.push({id:q.id,ok:false,status:rr.status});continue;}
   await db.schema("booked_solid").from("outreach_queue").update({status:"sent",sent_at:new Date().toISOString(),failure_reason:null,metadata:{...(q.metadata||{}),provider_id:payload.id||null}}).eq("id",q.id);
   await db.schema("booked_solid").from("outreach_events").insert({queue_id:q.id,lead_id:q.lead_id,event_type:"sent",metadata:{provider:"resend",provider_id:payload.id||null,delivery_status:"provider_accepted"}});
   results.push({id:q.id,ok:true,provider_id:payload.id||null});
  }
  return out({ok:true,blocked:false,processed:results.length,results});
 }catch(e){console.error(e);return out({ok:false,error:e instanceof Error?e.message:String(e)},500)}
});