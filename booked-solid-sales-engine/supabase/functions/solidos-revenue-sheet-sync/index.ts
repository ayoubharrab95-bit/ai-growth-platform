import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const SHEET_ID="1bW4fcehVou2bC-H_f8v3pHsnjtrgkC14i9TylOhrtrY";
const H={"Content-Type":"application/json"};
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
function serviceAccount(){
  const raw=Deno.env.get("SOLIDOS_GOOGLE_SERVICE_ACCOUNT_JSON");
  if(!raw)return null;
  const sa=JSON.parse(raw);
  if(!sa.client_email||!sa.private_key)throw new Error("invalid_service_account_json");
  return sa;
}
async function googleToken(sa:any){
  const now=Math.floor(Date.now()/1000);
  const header=b64url(JSON.stringify({alg:"RS256",typ:"JWT"}));
  const payload=b64url(JSON.stringify({iss:sa.client_email,scope:"https://www.googleapis.com/auth/spreadsheets",aud:"https://oauth2.googleapis.com/token",iat:now,exp:now+3300}));
  const key=await crypto.subtle.importKey("pkcs8",pemBytes(sa.private_key),{name:"RSASSA-PKCS1-v1_5",hash:"SHA-256"},false,["sign"]);
  const sig=new Uint8Array(await crypto.subtle.sign("RSASSA-PKCS1-v1_5",key,new TextEncoder().encode(header+"."+payload)));
  const body=new URLSearchParams({grant_type:"urn:ietf:params:oauth:grant-type:jwt-bearer",assertion:header+"."+payload+"."+b64url(sig)});
  const r=await fetch("https://oauth2.googleapis.com/token",{method:"POST",headers:{"Content-Type":"application/x-www-form-urlencoded"},body});
  if(!r.ok)throw new Error("google_oauth_"+r.status+":"+await r.text());
  return (await r.json()).access_token as string;
}
async function gfetch(url:string,init:RequestInit,token:string,label:string){
  const backoff=[5000,15000,30000,45000]; let last="";
  for(let i=0;i<4;i++){
    const r=await fetch(url,{...init,headers:{Authorization:"Bearer "+token,"Content-Type":"application/json",...(init.headers||{})}});
    if(r.ok)return r;
    last=await r.text();
    if(![429,500,502,503,504].includes(r.status)||i===3)throw new Error(label+"_"+r.status+":"+last);
    const ra=Number(r.headers.get("retry-after")||0);
    await new Promise(res=>setTimeout(res,ra?Math.min(60000,ra*1000):backoff[i]));
  }
  throw new Error(label+":"+last);
}
async function metadata(token:string){
  const r=await gfetch("https://sheets.googleapis.com/v4/spreadsheets/"+SHEET_ID+"?fields=sheets.properties(sheetId,title,gridProperties)",{},token,"metadata");
  return await r.json();
}
async function batch(token:string,requests:any[]){
  if(!requests.length)return;
  await gfetch("https://sheets.googleapis.com/v4/spreadsheets/"+SHEET_ID+":batchUpdate",
    {method:"POST",body:JSON.stringify({requests,includeSpreadsheetInResponse:false})},token,"batch");
}
function cell(v:any){
  if(v===null||v===undefined)return {userEnteredValue:{stringValue:""}};
  if(typeof v==="number"&&Number.isFinite(v))return {userEnteredValue:{numberValue:v}};
  if(typeof v==="boolean")return {userEnteredValue:{boolValue:v}};
  return {userEnteredValue:{stringValue:String(v)}};
}
async function readA(token:string,tab:string){
  const r=await gfetch("https://sheets.googleapis.com/v4/spreadsheets/"+SHEET_ID+"/values/"+encodeURIComponent(tab+"!A1:A"),{},token,"read");
  return await r.json();
}
async function loadRows(){
  const out:any[]=[]; let from=0;
  while(true){
    const {data,error}=await db.schema("solidos_control").from("revenue_intelligence_current").select("*").order("target_score",{ascending:false}).range(from,from+999);
    if(error)throw new Error("revenue_rows:"+error.message);
    const part=data||[]; out.push(...part); if(part.length<1000)break; from+=1000;
  }
  return out;
}
function rr(x:any){const r=String(x.readiness||"WATCH");return r==="ACT NOW"?4:r==="REVIEW"?3:r==="ENRICH"?2:1;}
function arr(v:any){return Array.isArray(v)?v.join(" · "):"";}
function build(rows:any[]){
  const sorted=[...rows].sort((a,b)=>rr(b)-rr(a)||(Number(b.target_score)||0)-(Number(a.target_score)||0));
  const actionable=sorted.filter(x=>Number(x.target_score||0)>=55||["HOT","HIGH"].includes(String(x.priority_band||"").toUpperCase()));
  const c={act:0,review:0,enrich:0,watch:0};
  const offers=new Map<string,{n:number,act:number,review:number,sum:number,top:number}>();
  for(const x of rows){
    if(x.readiness==="ACT NOW")c.act++; else if(x.readiness==="REVIEW")c.review++; else if(x.readiness==="ENRICH")c.enrich++; else c.watch++;
    const k=String(x.best_offer||"Unassigned"),v=offers.get(k)||{n:0,act:0,review:0,sum:0,top:0};
    v.n++;v.sum+=Number(x.target_score||0);v.top=Math.max(v.top,Number(x.target_score||0));if(x.readiness==="ACT NOW")v.act++;if(x.readiness==="REVIEW")v.review++;offers.set(k,v);
  }
  const at=rows[0]?.generated_at||new Date().toISOString();
  const desk=[
    ["BOOKED SOLID — REVENUE DESK","","","","","","","","","","","","","","",""],
    ["Updated",at,"Cadence","Hourly","Automated sending","OFF","Purpose","Commercial intelligence → sales direction","","","","","","","",""],
    ["Scored",rows.length,"ACT NOW",c.act,"REVIEW",c.review,"ENRICH",c.enrich,"WATCH",c.watch,"HOT/HIGH",rows.filter(x=>["HOT","HIGH"].includes(String(x.priority_band||""))).length,"","","",""],
    ["","","","","","","","","","","","","","","",""],
    ["Rank","Company","Readiness","Revenue Score","Core Priority","Best Offer","Why Now","Commercial Signals","Product Matches","Contact Route","Missing Info","Next Action","Opportunity","Trigger","Commercial","Generated"],
    ...actionable.slice(0,40).map((x,i)=>[i+1,x.company_name||"",x.readiness||"",Number(x.target_score)||0,String(x.priority_band||"STANDARD").toUpperCase(),x.best_offer||"",x.why_now||"",arr(x.signal_types),arr(x.product_matches),x.contact_route_state||"",arr(x.missing_info),x.next_action||"",Number(x.opportunity_score)||0,Number(x.trigger_score)||0,Number(x.commercial_score)||0,x.generated_at||""])
  ];
  const targets=[
    ["Company","Trade","Location","Readiness","Revenue Score","Core Priority","Best Offer","Estimation Fit","Automation Fit","Website/SEO Fit","Why Now","Signals","Commercial Products","Signal Confidence","Product Score","Opportunity","Trigger","Commercial","Freshness","Missing Info","Next Action","Company ID"],
    ...actionable.slice(0,400).map(x=>[x.company_name||"",x.trade||"",x.location_text||"",x.readiness||"",Number(x.target_score)||0,String(x.priority_band||"STANDARD").toUpperCase(),x.best_offer||"",Number(x.estimation_fit)||0,Number(x.automation_fit)||0,Number(x.website_fit)||0,x.why_now||"",arr(x.signal_types),arr(x.product_matches),Number(x.signal_confidence)||0,Number(x.product_score)||0,Number(x.opportunity_score)||0,Number(x.trigger_score)||0,Number(x.commercial_score)||0,Number(x.freshness_score)||0,arr(x.missing_info),x.next_action||"",x.company_id||""])
  ];
  const match=[
    ["Offer","Targets","ACT NOW","REVIEW","Average Revenue Score","Top Score","How Booked Solid can help"],
    ...[...offers.entries()].sort((a,b)=>b[1].top-a[1].top).map(([k,v])=>[k,v.n,v.act,v.review,v.n?Math.round(v.sum/v.n*10)/10:0,v.top,k==="Custom Estimation Software"?"Estimating, proposals, margins and field-sales workflow":k==="Business Automation System"?"Operational workflow, CRM, repetitive work and integrations":"Website, SEO, conversion copy and digital demand generation"])
  ];
  return {desk,targets,match,counts:c,actionable:actionable.length};
}
async function writeTab(token:string,sm:any,name:string,rows:any[][],minRows:number,cols:number,headerRow:number){
  const p=sm[name],needed=Math.max(minRows,rows.length+30);
  const req:any[]=[];
  if(!p)throw new Error("missing_tab:"+name);
  if(p.rows<needed)req.push({updateSheetProperties:{properties:{sheetId:p.id,gridProperties:{rowCount:needed}},fields:"gridProperties.rowCount"}});
  if(p.cols<cols)req.push({updateSheetProperties:{properties:{sheetId:p.id,gridProperties:{columnCount:cols}},fields:"gridProperties.columnCount"}});
  req.push({repeatCell:{range:{sheetId:p.id,startRowIndex:0,endRowIndex:Math.max(p.rows,needed),startColumnIndex:0,endColumnIndex:cols},cell:{userEnteredValue:{}},fields:"userEnteredValue"}});
  req.push({updateCells:{start:{sheetId:p.id,rowIndex:0,columnIndex:0},rows:rows.map(r=>({values:r.map(cell)})),fields:"userEnteredValue"}});
  req.push({repeatCell:{range:{sheetId:p.id,startRowIndex:headerRow,endRowIndex:headerRow+1,startColumnIndex:0,endColumnIndex:cols},cell:{userEnteredFormat:{textFormat:{bold:true},backgroundColor:{red:0.055,green:0.16,blue:0.27},horizontalAlignment:"LEFT"},userEnteredValue:{}},fields:"userEnteredFormat(textFormat,backgroundColor,horizontalAlignment)"}});
  await batch(token,req);
}
Deno.serve(async(req)=>{
  try{
    const tokenHeader=req.headers.get("x-solidos-internal-token")||"";
    if(!tokenHeader)return out({ok:false,error:"missing_internal_token"},401);
    const {data:tokenOk,error:tokenErr}=await db.schema("solidos_control").rpc("validate_internal_token",{p_name:"revenue_writer",p_token:tokenHeader});
    if(tokenErr||tokenOk!==true)return out({ok:false,error:"invalid_internal_token"},403);
    const sa=serviceAccount(); if(!sa)return out({ok:false,error:"google_service_account_not_configured"},503);
    const token=await googleToken(sa),rows=await loadRows(),built=build(rows);
    let meta=await metadata(token),sm:any={};
    for(const s of meta.sheets||[])sm[s.properties.title]={id:s.properties.sheetId,rows:Number(s.properties.gridProperties?.rowCount||0),cols:Number(s.properties.gridProperties?.columnCount||0)};
    const defs=[["REVENUE DESK",300,16,5],["BEST TARGETS",600,22,1],["OFFER MATCH",300,12,1]] as any[];
    const add=defs.filter(d=>!sm[d[0]]).map(d=>({addSheet:{properties:{title:d[0],gridProperties:{rowCount:d[1],columnCount:d[2],frozenRowCount:d[3]}}}}));
    if(add.length){await batch(token,add);meta=await metadata(token);sm={};for(const s of meta.sheets||[])sm[s.properties.title]={id:s.properties.sheetId,rows:Number(s.properties.gridProperties?.rowCount||0),cols:Number(s.properties.gridProperties?.columnCount||0)};}
    await writeTab(token,sm,"REVENUE DESK",built.desk,300,16,4);
    await writeTab(token,sm,"BEST TARGETS",built.targets,600,22,0);
    await writeTab(token,sm,"OFFER MATCH",built.match,300,12,0);
    const checks:any[]=[];
    for(const [tab,expected] of [["REVENUE DESK","BOOKED SOLID — REVENUE DESK"],["BEST TARGETS","Company"],["OFFER MATCH","Offer"]] as any[]){
      const j=await readA(token,tab),h=String(j.values?.[0]?.[0]||"");if(h!==expected)throw new Error("verify_header:"+tab+":"+h);checks.push({tab,header:h,rows:Math.max(0,(j.values||[]).length-1)});
    }
    return out({ok:true,component:"solidos-revenue-sheet-sync",writer:"v1",scored:rows.length,actionable:built.actionable,counts:built.counts,verified:checks,updated_at:new Date().toISOString()});
  }catch(e){console.error(e);return out({ok:false,error:e instanceof Error?e.message:String(e)},500);}
});