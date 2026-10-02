
import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const H={"Content-Type":"application/json","Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type"};
const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const out=(x:unknown,s=200)=>new Response(JSON.stringify(x),{status:s,headers:H});

function h(s:any){return String(s??"").replace(/&/g,"&amp;").replace(/</g,"&lt;").replace(/>/g,"&gt;").replace(/"/g,"&quot;")}
function oneLine(s:any){return String(s??"").replace(/[\r\n]+/g," ").replace(/\s+/g," ").trim()}
function firstName(s:any){const x=oneLine(s);return x?x.split(" ")[0]:""}
function localPart(email:string){return String(email||"").split("@")[0].toLowerCase()}
function isSuspicious(email:string){
 const lp=localPart(email);
 return !email || ["first","firstname","test","example","noreply","no-reply","donotreply","do-not-reply"].includes(lp) || lp.length<2;
}
function isWeak(email:string){const lp=String(email||"").toLowerCase().split("@")[0];return /(employment|careers?|jobs?|support|concierge|reservations?|dining|spa|events?|groups?|humanresources|human-resources|noreply|no-reply|donotreply|do-not-reply)/.test(lp)||lp==="hr"}
function isGeneric(email:string){return /^(info|office|admin|hello|contact|sales|marketing|service|team|inquiries|inquiry|reception|frontdesk|estimates?|estimating|quotes?|build|projects?)@/i.test(email)}
function utm(base:string,company:string,offer:string,seq:number,angle:string,leadId:string){
 const u=new URL(base);
 u.searchParams.set("utm_source","outbound_email");
 u.searchParams.set("utm_medium","email");
 u.searchParams.set("utm_campaign",offer);
 u.searchParams.set("utm_content","seq"+seq+"_"+angle);
 u.searchParams.set("utm_company",company);
 u.searchParams.set("utm_lead",leadId);
 return u.toString();
}
function evidenceTypes(rows:any[]){return new Set(rows.map(x=>String(x.evidence_type||"")))}
function angleFor(types:Set<string>,trade:string){
 if(types.has("trigger_change_order_workflow")||types.has("change_orders")) return "revenue_protection";
 if(types.has("trigger_manual_workflow")) return "operational_leverage";
 if(types.has("trigger_hiring_estimator")||types.has("trigger_active_hiring")) return "capacity_without_more_admin";
 if(types.has("trigger_quote_speed")) return "speed_to_quote";
 if(types.has("trigger_expansion")||types.has("trigger_multi_location_growth")) return "consistency_at_scale";
 if(trade==="Property Operations" && (types.has("workflow_complexity")||types.has("property_operations"))) return "operational_leverage";
 if(types.has("buyer_signal")) return "capacity_without_more_admin";
 if(types.has("field_quoting")) return "speed_to_quote";
 if(types.has("scale_signal")) return "consistency_at_scale";
 if(types.has("estimation_pain")) return "estimate_speed_and_margin";
 if(types.has("website_conversion_gap")&&types.has("seo_foundation_gap")) return "digital_conversion";
 return "workflow_fit";
}
function offerKeyFor(lead:any,types:Set<string>,trade:string){
 if(types.has("change_orders")) return "penmark";
 const joined=JSON.stringify(lead.lead_brief||{}).toLowerCase();
 if(types.has("workflow_complexity") && /(buildertrend|monthly software|saas|generic platform|software overload)/.test(joined)) return "buildertrend_alternative";
 if(trade==="Property Operations" && (types.has("property_operations")||types.has("workflow_complexity")||types.has("scale_signal"))) return "automation";
 if(lead.offer==="website_growth") return "website_growth";
 return lead.offer==="automation"?"automation":lead.offer==="penmark"?"penmark":"custom_estimator";
}
function observationFor(types:Set<string>,trade:string,company:string,evidence:any[]){
 const trigger=evidence.filter(x=>String(x.evidence_type||"").startsWith("trigger_")).sort((a,b)=>Number(b.metadata?.trigger_strength||0)-Number(a.metadata?.trigger_strength||0))[0];
 if(trigger?.evidence_type==="trigger_hiring_estimator") return "I noticed "+company+" appears to be adding capacity around estimating or project delivery, which is usually when quote prep and handoffs start taking more admin time.";
 if(trigger?.evidence_type==="trigger_expansion") return "I noticed public signs that "+company+" is expanding its footprint, which can make consistent estimating and handoffs harder to maintain across more work.";
 if(trigger?.evidence_type==="trigger_manual_workflow") return "I noticed public references to a manual or spreadsheet-heavy workflow around the operation.";
 if(trigger?.evidence_type==="trigger_multi_location_growth") return "I noticed "+company+" appears to operate across multiple locations or regions, where keeping workflows consistent can get harder as volume grows.";
 if(trigger?.evidence_type==="trigger_quote_speed") return "I noticed "+company+" emphasizes fast estimates or quotes, so reducing the manual steps behind that process may be especially useful.";
 if(trigger?.evidence_type==="trigger_change_order_workflow") return "I noticed change orders or scope changes are part of the workflow, where clean approvals and updated job value can protect margin.";
 if(trigger?.evidence_type==="trigger_recurring_service") return "I noticed "+company+" has recurring service or maintenance workflows, which often create repetitive admin and follow-up work.";
 if(trigger?.evidence_type==="trigger_active_hiring") return "I noticed "+company+" is actively hiring, which can be a sign the team is adding capacity and operational workload.";
 const conversionGap=evidence.find(x=>x.evidence_type==="website_conversion_gap");
 const seoGap=evidence.find(x=>x.evidence_type==="seo_foundation_gap");
 if(conversionGap&&seoGap) return "I reviewed the public site for "+company+" and the sampled HTML did not expose a clear quote/contact conversion path, meta description, or business structured-data markup.";
 const permit=evidence.find(x=>x.evidence_type==="permit_activity");
 const assoc=evidence.find(x=>x.evidence_type==="association_membership");
 if(permit) return "I came across recent permit activity tied to "+company+", which usually means the estimating and handoff process has to stay tight as projects move.";
 if(assoc) return "I noticed "+company+" is listed with a recognized trade association and your site puts estimates and project delivery front and center.";
 if(types.has("buyer_signal")) return "I noticed signals that "+company+" is building capacity around estimating or project delivery.";
 if(types.has("field_quoting")) return "I noticed your customer journey puts a lot of weight on getting from inquiry to an estimate quickly.";
 if(types.has("scale_signal")) return "I noticed "+company+" appears to operate across a broader service footprint, where keeping quotes and pricing consistent can get harder as volume grows.";
 if(trade==="Property Operations") return "I noticed "+company+" is managing multiple owner, tenant or property workflows where repetitive admin can stack up quickly.";
 if(types.has("estimation_pain")) return "I noticed estimates and proposals are a central part of how "+company+" wins work.";
 return "I spent a little time looking at how "+company+" presents its services and workflow.";
}
function valueFor(angle:string,offer:string){
 if(offer==="penmark") return "PenMark keeps change orders, approvals, photos and updated job value in one clean workflow — without adding a monthly software bill.";
 if(offer==="website_growth") return "Booked Solid builds contractor websites around clearer conversion paths, stronger service positioning, local-search foundations and copy designed to turn existing traffic into better inquiries.";
 if(angle==="operational_leverage") return "Booked Solid builds custom automation around the workflow a team already uses, so repetitive admin and handoffs can happen with fewer manual steps.";
 if(angle==="speed_to_quote") return "Booked Solid builds custom estimating tools that can turn quote preparation from hours into minutes while keeping pricing logic and branded proposals consistent.";
 if(angle==="capacity_without_more_admin") return "The idea is to let the team handle more estimating volume without adding the same amount of admin work.";
 if(angle==="consistency_at_scale") return "The goal is consistent pricing, proposal logic and handoffs across the team without forcing everyone into another generic platform.";
 return "Booked Solid builds custom estimating software around the way a contractor already prices and sells work — with no monthly software fee and full code ownership.";
}
function costFrame(angle:string){
 if(angle==="digital_conversion") return "When a contractor already has traffic but the site does not make the next step obvious, the hidden cost is often qualified visitors leaving before they request a quote or contact the team.";
 if(angle==="operational_leverage") return "If even a few recurring owner, property or internal handoffs are still being copied between tools, the cost usually shows up as staff time and slower follow-through rather than as a single obvious line item.";
 if(angle==="speed_to_quote"||angle==="estimate_speed_and_margin") return "If estimates still require several manual lookups, spreadsheet steps or proposal edits, the hidden cost is not only admin time — it is also how long a good prospect waits before receiving a clean number.";
 if(angle==="capacity_without_more_admin") return "When demand grows, the bottleneck often becomes the amount of quoting and coordination each additional job creates.";
 return "The useful question is whether the current workflow still earns its keep once you count the time spent re-entering details, checking prices and moving information between people.";
}
function pickContact(contacts:any[],brief:any){
 const resolved=brief?.contact_resolution;
 if(resolved?.recipient_email && !isSuspicious(resolved.recipient_email) && !isWeak(resolved.recipient_email)){
  return {email:String(resolved.recipient_email).toLowerCase(),name:resolved.recipient_name||null,role:resolved.recipient_role||null,source:resolved.contact_class||"contact_resolution",score:Number(resolved.score||0),contact_class:resolved.contact_class||null};
 }
 const people=Array.isArray(brief?.decision_makers_public)?brief.decision_makers_public:[];
 for(const p of people){
  if(p?.email && !isSuspicious(p.email) && !isWeak(p.email)) return {email:String(p.email).toLowerCase(),name:p.name||null,role:p.role||null,source:"decision_maker",score:90,contact_class:"decision_maker_direct"};
 }
 const valid=(contacts||[]).filter(c=>c.email&&c.status!=="invalid"&&c.status!=="suppressed"&&!isSuspicious(c.email)&&!isWeak(c.email));
 const executive=valid.find(c=>/(owner|president|ceo|founder|vice president|vp|director|operations|estimator)/i.test(String(c.role||"")));
 if(executive) return {email:executive.email.toLowerCase(),name:executive.full_name||null,role:executive.role||null,source:"direct_role",score:85,contact_class:"decision_maker_direct"};
 const nonGeneric=valid.find(c=>!isGeneric(c.email));
 if(nonGeneric) return {email:nonGeneric.email.toLowerCase(),name:nonGeneric.full_name||null,role:nonGeneric.role||null,source:"direct",score:65,contact_class:"direct_email"};
 const general=valid[0];
 if(general) return {email:general.email.toLowerCase(),name:null,role:null,source:"general",score:55,contact_class:"generic_only"};
 return null;
}
function greeting(contact:any,company:string){
 if(contact?.name) return "Hi "+firstName(contact.name)+",";
 return "Hi "+company+" team,";
}
function shortCompany(company:string){
 let s=String(company||"").replace(/\s+rentals and property management.*$/i,"").replace(/,\s*Phoenix$/i,"").replace(/\s{2,}/g," ").trim();
 if(s.length>42)s=s.slice(0,42).trim();
 return s;
}
function subjects(company:string,topic:string){
 const c=shortCompany(company);
 return [
  c+": a quick idea for "+topic,
  "Another thought on "+c+"'s "+topic,
  "Worth pressure-testing this?",
  "One more angle: own the workflow",
  "Should I close the loop?"
 ];
}
function offsetHours(company:any){
 const t=(String(company.location_text||"")+" "+String(company.state||"")+" "+String(company.metadata?.query||"")).toLowerCase();
 if(/phoenix|\baz\b|arizona|california|san francisco|los angeles|san diego|seattle|washington/.test(t))return -7;
 if(/denver|colorado|salt lake|utah/.test(t))return -6;
 if(/dallas|houston|austin|texas|chicago|illinois|st\. louis|missouri|milwaukee|minneapolis|oklahoma|tulsa/.test(t))return -5;
 if(/pennsylvania|new jersey|delaware|new york|boston|massachusetts|atlanta|georgia|florida|charlotte|raleigh|virginia|ohio|indiana/.test(t))return -4;
 return -5;
}
function scheduledBusinessTime(company:any,dayOffset:number){
 const off=offsetHours(company),now=Date.now();
 const localNow=new Date(now+off*3600000);
 let y=localNow.getUTCFullYear(),m=localNow.getUTCMonth(),d=localNow.getUTCDate()+dayOffset;
 let localTarget=new Date(Date.UTC(y,m,d,9,17,0,0));
 while([0,6].includes(localTarget.getUTCDay()))localTarget=new Date(localTarget.getTime()+86400000);
 let utc=new Date(localTarget.getTime()-off*3600000);
 if(dayOffset===0&&utc.getTime()<now+30*60000){
   localTarget=new Date(localTarget.getTime()+86400000);
   while([0,6].includes(localTarget.getUTCDay()))localTarget=new Date(localTarget.getTime()+86400000);
   utc=new Date(localTarget.getTime()-off*3600000);
 }
 return {iso:utc.toISOString(),offset:off};
}
function messageParts(seq:number,args:any){
 const {company,greet,observation,value,angle,offerDisplay,contactUrl}=args;
 const topic=args.topic;
 if(seq===1) return {
  text:`${greet}\n\n${observation}\n\n${value}\n\nI had one specific idea for ${company} that may be worth comparing against your current process. If it is useful, the page below shows exactly how we approach it.\n\n— Courtney\nBooked Solid Copy`,
  headline:"A practical idea for "+company
 };
 if(seq===2) return {
  text:`${greet}\n\nOne reason I reached out: Booked Solid is not another off-the-shelf subscription. We build around the workflow you already use, and the client owns the code.\n\nFor ${company}, that could mean keeping the parts of your process that already work while removing the repetitive estimating and handoff steps around them.\n\nIf you want to see the model, I linked the most relevant page below.\n\n— Courtney`,
  headline:"Keep the workflow. Remove the friction."
 };
 if(seq===3) return {
  text:`${greet}\n\n${costFrame(angle)}\n\nThat is the part we usually pressure-test first — not “do you need software?” but “which repeated steps are expensive enough to automate?”\n\nIf that is worth a look, you can see the approach below.\n\n— Courtney`,
  headline:"Where is the workflow actually costing time?"
 };
 if(seq===4) return {
  text:`${greet}\n\nA different angle in case this is more relevant: the system is built for ${company}'s process, can connect with tools like QuickBooks or a CRM where appropriate, has no monthly Booked Solid software fee, and the code is yours.\n\nThat matters when the real problem is not a missing feature — it is forcing a unique operation into generic software.\n\n— Courtney`,
  headline:"Own the system instead of renting the limitation."
 };
 return {
  text:`${greet}\n\nI do not want to fill your inbox, so I will close the loop after this.\n\nIf improving ${topic} is on the radar at ${company}, I would be happy to look at the current workflow and tell you whether there is actually something worth automating. If not, no problem.\n\n— Courtney`,
  headline:"Should I close the loop?"
 };
}
function htmlEmail(args:any){
 const {logo,headline,text,ctaLabel,landingUrl,brandName,contactUrl}=args;
 const paras=text.split("\n\n").map((p:string)=>{
   if(p.startsWith("— Courtney")) return '<p style="margin:26px 0 0;color:#222;font-size:15px;line-height:1.65">'+h(p).replace(/\n/g,"<br>")+'</p>';
   return '<p style="margin:0 0 18px;color:#333;font-size:15px;line-height:1.72">'+h(p).replace(/\n/g,"<br>")+'</p>';
 }).join("");
 return `<!doctype html><html><body style="margin:0;padding:0;background:#f3f1ec;font-family:Arial,Helvetica,sans-serif;color:#222;">
 <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="background:#f3f1ec;padding:28px 12px;">
 <tr><td align="center">
 <table role="presentation" width="100%" cellspacing="0" cellpadding="0" border="0" style="max-width:620px;background:#ffffff;border:1px solid #e7e0d3;border-radius:14px;overflow:hidden;">
 <tr><td style="padding:28px 34px 18px;text-align:center;border-bottom:1px solid #eee8de;">
 <img src="${h(logo)}" width="82" alt="${h(brandName)}" style="display:inline-block;width:82px;height:auto;border:0;">
 </td></tr>
 <tr><td style="padding:34px 38px 10px;">
 <div style="font-size:11px;letter-spacing:1.8px;text-transform:uppercase;color:#9a7a3d;font-weight:700;margin-bottom:12px;">Built around your workflow</div>
 <h1 style="margin:0 0 24px;font-size:25px;line-height:1.28;color:#161616;font-family:Georgia,'Times New Roman',serif;font-weight:700;">${h(headline)}</h1>
 ${paras}
 <table role="presentation" cellspacing="0" cellpadding="0" border="0" style="margin:28px 0 20px;"><tr><td>
 <a href="${h(landingUrl)}" style="display:inline-block;background:#171717;color:#ffffff;text-decoration:none;font-size:14px;font-weight:700;padding:14px 20px;border-radius:7px;border:1px solid #171717;">${h(ctaLabel)}</a>
 </td></tr></table>
 <p style="margin:8px 0 0;font-size:12px;line-height:1.6;color:#777;">Prefer a conversation? <a href="${h(contactUrl)}" style="color:#7b6131;text-decoration:underline;">Book a 30-minute discovery call</a>.</p>
 </td></tr>
 <tr><td style="padding:20px 38px 28px;border-top:1px solid #eee8de;background:#fbfaf7;">
 <p style="margin:0;font-size:11px;line-height:1.6;color:#888;">${h(brandName)} · Personalized business outreach.<br>{{POSTAL_ADDRESS}}<br><a href="{{unsubscribe_url}}" style="color:#777;text-decoration:underline;">Unsubscribe</a></p>
 </td></tr></table></td></tr></table></body></html>`;
}

Deno.serve(async req=>{
 try{
  if(req.method==="OPTIONS") return new Response("ok",{headers:H});
  const b=await req.json().catch(()=>({}));
  if(!b.lead_id) return out({ok:false,error:"lead_id_required"},400);

  const {data:lead,error:le}=await db.schema("booked_solid").from("leads").select("*,companies(*)").eq("id",b.lead_id).single();
  if(le) throw le;
  if(lead.status!=="qualified") return out({ok:false,error:"lead_not_qualified",status:lead.status},409);

  const company=lead.companies;
  const [{data:contacts},{data:evidence},{data:settings},{data:runtime}]=await Promise.all([
   db.schema("booked_solid").from("contacts").select("*").eq("company_id",company.id).neq("status","suppressed"),
   db.schema("booked_solid").from("evidence").select("*").eq("company_id",company.id).order("confidence",{ascending:false}).order("observed_at",{ascending:false}).limit(50),
   db.schema("booked_solid").from("outreach_settings").select("*").eq("id",true).single(),
   db.schema("booked_solid").from("runtime_settings").select("*").eq("id",true).single()
  ]);
  if(!settings) throw new Error("outreach_settings_missing");

  const contact=pickContact(contacts||[],lead.lead_brief||{});
  if(!contact){
    await db.schema("booked_solid").from("leads").update({lead_brief:{...(lead.lead_brief||{}),outreach:{state:"contact_required",updated_at:new Date().toISOString()}}}).eq("id",lead.id);
    return out({ok:true,lead_id:lead.id,state:"contact_required",queued:0});
  }

  const types=evidenceTypes(evidence||[]);
  const evidenceSeen=new Set<string>();
  const rankedEvidence=[...(evidence||[])].sort((a:any,b:any)=>{
   const at=String(a.evidence_type||"").startsWith("trigger_")?1:0,bt=String(b.evidence_type||"").startsWith("trigger_")?1:0;
   if(at!==bt)return bt-at;
   return Number(b.metadata?.trigger_strength||b.confidence||0)-Number(a.metadata?.trigger_strength||a.confidence||0);
  }).filter((x:any)=>{const k=String(x.evidence_type||"")+"|"+String(x.source_url||"");if(evidenceSeen.has(k))return false;evidenceSeen.add(k);return true;});
  const angle=angleFor(types,company.trade||"");
  const offerKey=offerKeyFor(lead,types,company.trade||"");
  const {data:offer,error:oe}=await db.schema("booked_solid").from("offer_catalog").select("*").eq("offer_key",offerKey).eq("enabled",true).single();
  if(oe) throw oe;

  const base=settings.homepage_url.replace(/\/$/,"")+offer.landing_path;
  const observation=observationFor(types,company.trade||"",company.name,evidence||[]);
  const value=valueFor(angle,offerKey);
  const greet=greeting(contact,company.name);
  const topic=offerKey==="penmark"?"change-order control":company.trade==="Property Operations"?"operational workflow":"estimating workflow";
  const subs=subjects(company.name,topic);
  const cadence=Array.isArray(settings.cadence_days)?settings.cadence_days:[0,3,7,12,20];
  const rows:any[]=[];

  for(let i=0;i<5;i++){
   const seq=i+1;
   const landing=utm(seq===5?settings.contact_url:base,company.canonical_domain||company.name,offerKey,seq,angle,lead.id);
   const msg=messageParts(seq,{company:company.name,greet,observation,value,angle,offerDisplay:offer.display_name,contactUrl:settings.contact_url,topic});
   const cta=seq===5?"Book a 30-minute call":offer.cta_label;
   const timing=scheduledBusinessTime(company,Number(cadence[i]??[0,3,7,12,20][i]));
   rows.push({
    lead_id:lead.id,
    sequence_no:seq,
    channel:"email",
    subject:subs[i],
    body:msg.text,
    body_text:msg.text,
    body_html:htmlEmail({logo:settings.brand_logo_url,headline:msg.headline,text:msg.text,ctaLabel:cta,landingUrl:landing,brandName:settings.brand_name,contactUrl:utm(settings.contact_url,company.canonical_domain||company.name,offerKey,seq,angle,lead.id)}),
    recipient_email:contact.email,
    recipient_name:contact.name,
    angle,
    landing_url:landing,
    cta_label:cta,
    message_version:"psych_v2",
    status:runtime?.email_enabled?"ready":"blocked_email_not_configured",
    scheduled_at:timing.iso,
    personalization_evidence:rankedEvidence.slice(0,8).map((x:any)=>({type:x.evidence_type,claim:x.claim,url:x.source_url,confidence:x.confidence,trigger_strength:x.metadata?.trigger_strength??null})),
    stop_conditions:{reply:true,booking:true,unsubscribe:true,hard_bounce:true},
    metadata:{offer_key:offerKey,contact_source:contact.source,contact_role:contact.role||null,contact_score:Number(contact.score||lead.lead_brief?.contact_resolution?.score||0),contact_class:contact.contact_class||lead.lead_brief?.contact_resolution?.contact_class||null,contact_risk:isSuspicious(contact.email)?"suspicious":isWeak(contact.email)?"weak_function_inbox":localPart(contact.email).length<=2?"short_local_part":isGeneric(contact.email)?"generic":"normal",trigger_score:Number(lead.trigger_score||0),opportunity_score:Number(lead.opportunity_score||0),priority_band:lead.priority_band||"standard",phone_available:Boolean(lead.lead_brief?.contact_resolution?.phone),sms_eligible:Boolean(lead.lead_brief?.contact_resolution?.sms_eligible===true),sms_sending_enabled:false,company_trade:company.trade,source_first_seen:company.source_first_seen,recipient_utc_offset:timing.offset,schedule_policy:"weekday_0917_local_approx"}
   });
  }

  const {data:queued,error:qe}=await db.schema("booked_solid").from("outreach_queue").upsert(rows,{onConflict:"lead_id,sequence_no"}).select("id,sequence_no,status,subject,scheduled_at,recipient_email,angle,landing_url");
  if(qe) throw qe;

  await db.schema("booked_solid").from("leads").update({
   lead_brief:{...(lead.lead_brief||{}),outreach:{
    state:runtime?.email_enabled?"ready":"blocked_email_not_configured",
    recipient_email:contact.email,recipient_name:contact.name||null,contact_role:contact.role||null,
    angle,offer_key:offerKey,cadence_days:cadence,message_version:"psych_v2",prepared_at:new Date().toISOString()
   }},
   updated_at:new Date().toISOString()
  }).eq("id",lead.id);

  return out({ok:true,lead_id:lead.id,company:company.name,recipient:contact.email,angle,offer_key:offerKey,queued:queued?.length??0,email_enabled:Boolean(runtime?.email_enabled),messages:queued});
 }catch(e){console.error(e);return out({ok:false,error:e instanceof Error?e.message:String(e)},500)}
});
