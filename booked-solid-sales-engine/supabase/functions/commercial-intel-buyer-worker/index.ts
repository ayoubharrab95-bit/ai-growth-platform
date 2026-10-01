import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2.57.4";

const json=(x:unknown,s=200)=>new Response(JSON.stringify(x),{status:s,headers:{"content-type":"application/json"}});
const cleanDomain=(u:string)=>{try{return new URL(u).hostname.replace(/^www\./,"").toLowerCase()}catch{return ""}};
const text=(v:unknown)=>typeof v==="string"?v.trim():"";

Deno.serve(async(req)=>{
  if(req.method!=="POST")return json({error:"method_not_allowed"},405);
  const auth=req.headers.get("authorization")||"";
  const key=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")||"";
  if(!key||!auth.startsWith("Bearer "))return json({error:"unauthorized"},401);

  const sb=createClient(Deno.env.get("SUPABASE_URL")!,key,{auth:{persistSession:false}});
  const {data:claim,error:claimErr}=await sb.rpc("solidos_claim_buyer_discovery_jobs",{p_limit:5});
  if(claimErr)return json({error:"claim_failed",detail:claimErr.message},500);
  if(!claim?.enabled)return json({ok:true,processed:0,skipped:claim?.reason||"disabled"});
  if(claim?.buyer_outreach_enabled||claim?.allow_personal_pii_export||!claim?.strict_compliance)
    return json({error:"compliance_guard_failed"},409);

  const jobs=Array.isArray(claim?.jobs)?claim.jobs:[];
  if(!jobs.length)return json({ok:true,processed:0});

  const providerKey=Deno.env.get("TAVILY_API_KEY")||"";
  if(!providerKey){
    for(const j of jobs){
      await sb.rpc("solidos_finish_buyer_discovery_job",{
        p_job_id:j.id,p_candidates:[],p_error:"TAVILY_API_KEY missing; fail-closed, no external search executed",p_blocked:true
      });
    }
    return json({ok:true,processed:0,blocked:jobs.length,reason:"provider_credentials_missing"});
  }

  let processed=0,inserted=0,updated=0,matched=0,failed=0;
  const details:any[]=[];
  for(const j of jobs){
    try{
      const p=j.payload||{};
      const audience=text(p.audience),useCase=text(p.use_case);
      const query=`${audience} companies United States ${useCase} official website`;
      const resp=await fetch("https://api.tavily.com/search",{
        method:"POST",
        headers:{"content-type":"application/json"},
        body:JSON.stringify({api_key:providerKey,query,search_depth:"basic",max_results:10,include_answer:false,include_raw_content:false})
      });
      if(!resp.ok)throw new Error(`provider_http_${resp.status}`);
      const body=await resp.json();
      const candidates:any[]=[];
      const seen=new Set<string>();
      for(const r of (body.results||[])){
        const url=text(r.url),domain=cleanDomain(url),title=text(r.title);
        if(!domain||!title||seen.has(domain))continue;
        if(/linkedin\.com|facebook\.com|instagram\.com|youtube\.com|x\.com|wikipedia\.org|yelp\.com/i.test(domain))continue;
        seen.add(domain);
        const company=title.replace(/\s*[|–—-].*$/,"").slice(0,200);
        candidates.push({
          company_name:company,
          website_url:url,
          domain,
          buyer_type:audience,
          use_case:useCase,
          fit_score:60,
          provider:"tavily",
          source_url:url,
          source_title:title,
          query
        });
      }
      const {data:finish,error:finishErr}=await sb.rpc("solidos_finish_buyer_discovery_job",{
        p_job_id:j.id,p_candidates:candidates,p_error:null,p_blocked:false
      });
      if(finishErr)throw new Error("finish_rpc_"+finishErr.message);
      processed++;
      inserted+=Number(finish?.inserted||0);
      updated+=Number(finish?.updated||0);
      matched+=Number(finish?.matched||0);
      details.push({job_id:j.id,candidates:candidates.length,inserted:finish?.inserted||0,matched:finish?.matched||0});
    }catch(e){
      failed++;
      const msg=e instanceof Error?e.message:String(e);
      await sb.rpc("solidos_finish_buyer_discovery_job",{
        p_job_id:j.id,p_candidates:[],p_error:msg,p_blocked:false
      });
      details.push({job_id:j.id,error:msg});
    }
  }
  return json({ok:failed===0,processed,failed,inserted,updated,matched,outreach:false,personal_pii:false,details},failed?207:200);
});