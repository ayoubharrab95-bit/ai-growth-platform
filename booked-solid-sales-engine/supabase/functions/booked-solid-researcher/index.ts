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
  let combined="";let foundEmails=new Set<string>();let pages=0;const seen=new Set<string>();
  for(const url of urls){
   if(seen.has(url))continue;seen.add(url);
   try{
    const r=await fetch(url,{redirect:"follow",headers:{"User-Agent":"BookedSolidResearchBot/1.0 (+https://www.bookedsolidcopy.com/)"}});
    if(!r.ok)continue;const html=await r.text();pages++;
    combined+=" "+clean(html);
    for(const e of html.match(/[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi)??[])foundEmails.add(e.toLowerCase());
    for(const u of links(html,root.toString()).slice(0,10))if(!seen.has(u))urls.push(u);
   }catch{}
  }
  const types=evidence(combined);
  if(company){
   await db.schema("booked_solid").from("companies").update({status:"researching",last_researched_at:new Date().toISOString()}).eq("id",company.id);
   for(const type of types)await db.schema("booked_solid").from("evidence").insert({
    company_id:company.id,evidence_type:type,claim:"Public website contains signals related to "+type,
    snippet:combined.slice(0,1200),source_url:root.toString(),confidence:70,metadata:{pages_researched:pages}
   });
   for(const email of foundEmails)await db.schema("booked_solid").from("contacts").upsert({
    company_id:company.id,email,email_confidence:60,source_url:root.toString(),status:"unverified"
   },{onConflict:"company_id,email"});
   await db.schema("booked_solid").from("companies").update({status:"discovered",last_researched_at:new Date().toISOString()}).eq("id",company.id);
  }
  return out({ok:true,url:root.toString(),pages_researched:pages,signals:types,emails_found:[...foundEmails].length});
 }catch(e){console.error(e);return out({ok:false,error:String(e)},500)}
});
