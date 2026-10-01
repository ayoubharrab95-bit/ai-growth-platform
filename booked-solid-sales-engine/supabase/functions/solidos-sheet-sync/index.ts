import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const H={"Content-Type":"application/json"};
const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const targets=[
  {key:"CORE_CRM",id:"1bW4fcehVou2bC-H_f8v3pHsnjtrgkC14i9TylOhrtrY"},
  {key:"COMMERCIAL_MASTER",id:"1uXM_0J2-QqNlzUWFVjf-1NJQFihQEwoSoX85C2jZ32M"},
  {key:"STARTER",id:"15PA89oGAoAX66IXEZWNB6m1QWrfx24h3uihsnH5YxdU"},
  {key:"GROWTH",id:"1RnHaQjjSaHCS6rN_xTIxQiE7jLJCSWUfqE1GnujgdiQ"},
  {key:"AUTOMATION",id:"165AJTZveayZNPqUbrsS33Oe1PzAdZjtXLL6jBNK2u64"},
  {key:"AGENCY",id:"1CL-gk7Qv_4h-zaaX8Gd7EfR4sFMofHgwtv-6yeGlsz0"},
  {key:"CUSTOM",id:"1TgGcufXBsPXEKku5rc8k6MXZkMJG_gT-tGTjX6OWOvY"},
];

const out=(x:unknown,s=200)=>new Response(JSON.stringify(x),{status:s,headers:H});
const b64url=(data:Uint8Array|string)=>{
  const bytes=typeof data==="string"?new TextEncoder().encode(data):data;
  let b=""; for(const x of bytes)b+=String.fromCharCode(x);
  return btoa(b).replace(/\+/g,"-").replace(/\//g,"_").replace(/=+$/,"");
};
function pemBytes(pem:string){
  const body=pem.replace(/-----BEGIN PRIVATE KEY-----/g,"").replace(/-----END PRIVATE KEY-----/g,"").replace(/\s+/g,"");
  const bin=atob(body); const bytes=new Uint8Array(bin.length);
  for(let i=0;i<bin.length;i++)bytes[i]=bin.charCodeAt(i);
  return bytes.buffer;
}
async function token(sa:any){
  const now=Math.floor(Date.now()/1000);
  const header=b64url(JSON.stringify({alg:"RS256",typ:"JWT"}));
  const payload=b64url(JSON.stringify({
    iss:sa.client_email,
    scope:"https://www.googleapis.com/auth/spreadsheets",
    aud:"https://oauth2.googleapis.com/token",
    iat:now,exp:now+3300
  }));
  const key=await crypto.subtle.importKey("pkcs8",pemBytes(sa.private_key),{name:"RSASSA-PKCS1-v1_5",hash:"SHA-256"},false,["sign"]);
  const sig=new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5",key,new TextEncoder().encode(header+"."+payload)));
  const assertion=header+"."+payload+"."+b64url(sig);
  const body=new URLSearchParams({grant_type:"urn:ietf:params:oauth:grant-type:jwt-bearer",assertion});
  const r=await fetch("https://oauth2.googleapis.com/token",{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded"},body});
  if(!r.ok)throw new Error("google_oauth_"+r.status+":"+await r.text());
  return (await r.json()).access_token as string;
}
function serviceAccount(){
  const raw=Deno.env.get("SOLIDOS_GOOGLE_SERVICE_ACCOUNT_JSON");
  if(!raw)return null;
  try{
    const sa=JSON.parse(raw);
    if(!sa.client_email||!sa.private_key)throw new Error("missing client_email/private_key");
    return sa;
  }catch(e){throw new Error("invalid_service_account_json:"+(e instanceof Error?e.message:String(e)));}
}
async function verifyAccess(accessToken:string){
  const checks=[];
  for(const t of targets){
    try{
      const r=await fetch("https://sheets.googleapis.com/v4/spreadsheets/"+t.id+"?fields=spreadsheetId,properties.title,sheets.properties(sheetId,title)",{
        headers:{Authorization:"Bearer "+accessToken}
      });
      if(!r.ok){checks.push({key:t.key,ok:false,status:r.status});continue;}
      const j=await r.json();
      checks.push({key:t.key,ok:true,title:j?.properties?.title??null,tabs:(j?.sheets??[]).map((s:any)=>s.properties?.title).filter(Boolean)});
    }catch{checks.push({key:t.key,ok:false,status:0});}
  }
  return checks;
}
async function blockOneMissingCredential(){
  const {data,error}=await db.rpc("claim_solidos_sheet_sync");
  if(error)throw error;
  if(!data)return null;
  const {error:finish}=await db.rpc("finish_solidos_sheet_sync",{p_id:data.id,p_status:"BLOCKED_NOT_CONFIGURED",p_error:"SOLIDOS_GOOGLE_SERVICE_ACCOUNT_JSON is not configured. No Google Sheet write was attempted."});
  if(finish)throw finish;
  return {id:data.id,scope:data.sync_scope};
}

Deno.serve(async(req)=>{
  try{
    const body=req.method==="POST"?await req.json().catch(()=>({})):{};
    const action=body.action??"health";
    const sa=serviceAccount();
    if(action==="health"){
      return out({ok:true,system:"SolidOS",component:"native-sheets",configured:!!sa,write_enabled:false,targets:targets.map(x=>x.key)});
    }
    if(action==="verify"){
      if(!sa)return out({ok:false,error:"google_service_account_not_configured",configured:false},503);
      const accessToken=await token(sa);
      const checks=await verifyAccess(accessToken);
      return out({ok:checks.every((x:any)=>x.ok),configured:true,service_account_email:sa.client_email,checks});
    }
    if(action==="gate"){
      if(sa)return out({ok:true,configured:true,blocked:false});
      const blocked=await blockOneMissingCredential();
      return out({ok:true,configured:false,blocked_request:blocked});
    }
    return out({ok:false,error:"unknown_action",allowed:["health","verify","gate"]},400);
  }catch(e){
    console.error(e);
    return out({ok:false,error:e instanceof Error?e.message:String(e)},500);
  }
});