
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
function html(msg:string,status=200,confirm=false){const extra=confirm?"<form method='post'><button type='submit' style='padding:12px 18px;font-size:16px'>Confirm unsubscribe</button></form>":"<p>You will not receive further Booked Solid Copy outreach at this address.</p>";return new Response("<!doctype html><html><head><meta name='robots' content='noindex,nofollow'></head><body style='font-family:Arial,sans-serif;padding:40px;max-width:640px;margin:auto'><h2>"+msg+"</h2>"+extra+"</body></html>",{status,headers:{"Content-Type":"text/html; charset=utf-8","Access-Control-Allow-Origin":"*","Cache-Control":"no-store","X-Robots-Tag":"noindex, nofollow"}})}
Deno.serve(async req=>{
 try{
  if(req.method==="OPTIONS")return new Response("ok",{headers:{"Access-Control-Allow-Origin":"*","Access-Control-Allow-Methods":"GET,POST,OPTIONS"}});
  const u=new URL(req.url);let token=u.searchParams.get("t");
  if(!token&&req.method==="POST"){const b=await req.json().catch(()=>({}));token=b.t||b.token||null;}
  if(!token)return html("Invalid unsubscribe link.",400);
  const {data:q,error}=await db.schema("booked_solid").from("outreach_queue").select("id,lead_id,recipient_email").eq("tracking_key",token).maybeSingle();
  if(error)throw error;if(!q)return html("This unsubscribe link is no longer active.",404);
  if(req.method==="GET")return html("Confirm unsubscribe",200,true);
  if(req.method!=="POST")return html("Method not allowed.",405);
  const email=String(q.recipient_email||"").toLowerCase();
  await db.schema("booked_solid").from("outreach_queue").update({status:"suppressed",failure_reason:"stopped: unsubscribe"}).eq("lead_id",q.lead_id).in("status",["blocked_email_not_configured","ready"]);
  if(email){
    const {data:old}=await db.schema("booked_solid").from("suppression").select("id").eq("email",email).limit(1);
    if(!(old??[]).length)await db.schema("booked_solid").from("suppression").insert({email,domain:null,reason:"unsubscribe",source:"one_click_unsubscribe"});
  }
  await db.schema("booked_solid").from("outreach_events").insert({queue_id:q.id,lead_id:q.lead_id,event_type:"unsubscribe",metadata:{source:"one_click"}});
  return html("You’re unsubscribed.");
 }catch(e){console.error(e);return html("We could not process that request.",500)}
});