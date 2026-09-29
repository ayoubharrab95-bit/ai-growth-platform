import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";
const headers={"Content-Type":"application/json","Access-Control-Allow-Origin":"*","Access-Control-Allow-Headers":"authorization, x-client-info, apikey, content-type"};
const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const out=(x:unknown,s=200)=>new Response(JSON.stringify(x),{status:s,headers});
function domainOf(raw:string){try{return new URL(raw).hostname.replace(/^www\./,"").toLowerCase()}catch{return null}}
function normalize(s:string){return s.toLowerCase().replace(/[^a-z0-9]+/g," ").trim()}
async function brave(query:string){
 const key=Deno.env.get("BRAVE_SEARCH_API_KEY");
 if(!key)return {configured:false,results:[]};
 const u=new URL("https://api.search.brave.com/res/v1/web/search");
 u.searchParams.set("q",query);u.searchParams.set("country","US");u.searchParams.set("search_lang","en");u.searchParams.set("count","20");u.searchParams.set("extra_snippets","true");
 const r=await fetch(u,{headers:{"Accept":"application/json","X-Subscription-Token":key}});
 if(!r.ok)throw new Error("brave_search_http_"+r.status);
 const j=await r.json();return {configured:true,results:j.web?.results??[]};
}
async function run(query:string,strategyId?:string){
 const result=await brave(query);
 if(!result.configured)return out({ok:false,blocked:"BRAVE_SEARCH_API_KEY",message:"Search provider secret is not configured."},424);
 let inserted=0;
 for(const item of result.results){
  const url=item.url as string;const domain=domainOf(url);if(!domain)continue;
  const name=(item.title??domain).replace(/\s*[|–-]\s*.*$/,"").trim();
  const {data:company,error}=await db.schema("booked_solid").from("companies").upsert({
   canonical_domain:domain,normalized_name:normalize(name),name,website_url:"https://"+domain+"/",
   source_first_seen:"brave_web_search",source_last_seen:"brave_web_search",status:"discovered",
   metadata:{search_query:query,search_title:item.title}
  },{onConflict:"canonical_domain"}).select("id").single();
  if(error)throw error;
  const {error:e}=await db.schema("booked_solid").from("evidence").insert({
   company_id:company.id,evidence_type:"search_result",claim:item.description??item.title??"Search result",
   snippet:item.description??null,source_url:url,confidence:55,metadata:{provider:"brave",query}
  });
  if(e)throw e;
  if(strategyId)await db.schema("booked_solid").from("leads").upsert({
   company_id:company.id,strategy_id:strategyId,offer:"pending_match",score:0,status:"candidate",
   lead_brief:{discovery_query:query}
  },{onConflict:"company_id,offer"});
  inserted++;
 }
 return out({ok:true,provider:"brave",query,results:result.results.length,companies_upserted:inserted});
}
Deno.serve(async req=>{
 try{
  if(req.method==="OPTIONS")return new Response("ok",{headers});
  const b=req.method==="POST"?await req.json().catch(()=>({})):{};const q=b.query as string|undefined;
  if(!q)return out({ok:false,error:"query_required"},400);
  return await run(q,b.strategy_id);
 }catch(e){console.error(e);return out({ok:false,error:String(e)},500)}
});
