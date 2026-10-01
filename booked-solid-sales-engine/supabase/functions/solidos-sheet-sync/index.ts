import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const H={"Content-Type":"application/json"};
const db=createClient(Deno.env.get("SUPABASE_URL")!,Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
const BLOCKED_KEYS=new Set(["person_name","personal_email","personal_phone","decision_maker_name","raw_contact_snippet"]);
const TARGETS:any={
  CORE_CRM:{id:"1bW4fcehVou2bC-H_f8v3pHsnjtrgkC14i9TylOhrtrY"},
  MASTER:{id:"1uXM_0J2-QqNlzUWFVjf-1NJQFihQEwoSoX85C2jZ32M"},
  STARTER:{id:"15PA89oGAoAX66IXEZWNB6m1QWrfx24h3uihsnH5YxdU",slug:"contractor-starter"},
  GROWTH:{id:"1RnHaQjjSaHCS6rN_xTIxQiE7jLJCSWUfqE1GnujgdiQ",slug:"growth-signals"},
  AUTOMATION:{id:"165AJTZveayZNPqUbrsS33Oe1PzAdZjtXLL6jBNK2u64",slug:"automation-opportunities"},
  AGENCY:{id:"1CL-gk7Qv_4h-zaaX8Gd7EfR4sFMofHgwtv-6yeGlsz0",slug:"agency-feed"},
  CUSTOM:{id:"1TgGcufXBsPXEKku5rc8k6MXZkMJG_gT-tGTjX6OWOvY",slug:"custom-icp"},
};
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
async function googleToken(sa:any){
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
  const sa=JSON.parse(raw);
  if(!sa.client_email||!sa.private_key)throw new Error("invalid_service_account_json");
  return sa;
}
async function sheetMetadata(id:string,token:string){
  const r=await fetch("https://sheets.googleapis.com/v4/spreadsheets/"+id+"?fields=spreadsheetId,properties.title,sheets.properties(sheetId,title,gridProperties)",{headers:{Authorization:"Bearer "+token}});
  if(!r.ok)throw new Error("sheet_metadata_"+r.status+":"+await r.text());
  return await r.json();
}
function sheetIdMap(meta:any){
  const m:any={};
  for(const s of meta.sheets||[])m[s.properties.title]=s.properties.sheetId;
  return m;
}
function cell(v:any){
  if(v===null||v===undefined)return {userEnteredValue:{stringValue:""}};
  if(typeof v==="number"&&Number.isFinite(v))return {userEnteredValue:{numberValue:v}};
  if(typeof v==="boolean")return {userEnteredValue:{boolValue:v}};
  return {userEnteredValue:{stringValue:String(v)}};
}
function updateRows(sheetId:number,rows:any[][],maxCols=26,maxRows=1000){
  const reqs:any[]=[
    {repeatCell:{range:{sheetId,startRowIndex:0,endRowIndex:maxRows,startColumnIndex:0,endColumnIndex:maxCols},cell:{userEnteredValue:{}},fields:"userEnteredValue"}}
  ];
  if(rows.length){
    reqs.push({updateCells:{
      start:{sheetId,rowIndex:0,columnIndex:0},
      rows:rows.map(r=>({values:r.map(cell)})),
      fields:"userEnteredValue"
    }});
  }
  return reqs;
}
async function batchUpdate(id:string,requests:any[],token:string){
  const r=await fetch("https://sheets.googleapis.com/v4/spreadsheets/"+id+":batchUpdate",{
    method:"POST",
    headers:{Authorization:"Bearer "+token,"Content-Type":"application/json"},
    body:JSON.stringify({requests,includeSpreadsheetInResponse:false})
  });
  if(!r.ok)throw new Error("sheet_batch_"+r.status+":"+await r.text());
  return await r.json();
}
async function readValues(id:string,range:string,token:string){
  const r=await fetch("https://sheets.googleapis.com/v4/spreadsheets/"+id+"/values/"+encodeURIComponent(range)+"?majorDimension=ROWS",{headers:{Authorization:"Bearer "+token}});
  if(!r.ok)throw new Error("sheet_read_"+r.status+":"+await r.text());
  return await r.json();
}
function jsonSafe(v:any){
  if(v===null||v===undefined)return "";
  if(Array.isArray(v))return v.join(", ");
  if(typeof v==="object")return JSON.stringify(v);
  return v;
}
function signalSummary(o:any){
  const keys=Object.keys(o||{}).sort();
  return keys.length?"Observed business signals: "+keys.join(", "):"No approved business-level signal currently available";
}
function assertNoBlockedKeys(obj:any,path="root"){
  if(!obj||typeof obj!=="object")return;
  if(Array.isArray(obj)){obj.forEach((x,i)=>assertNoBlockedKeys(x,path+"["+i+"]"));return;}
  for(const [k,v] of Object.entries(obj)){
    if(BLOCKED_KEYS.has(k))throw new Error("blocked_pii_key:"+path+"."+k);
    assertNoBlockedKeys(v,path+"."+k);
  }
}
async function hashText(s:string){
  const d=new Uint8Array(await crypto.subtle.digest("SHA-256",new TextEncoder().encode(s)));
  return Array.from(d).map(x=>x.toString(16).padStart(2,"0")).join("").slice(0,32);
}
async function getAll(table:string,select="*",order?:{column:string,ascending?:boolean}){
  let q:any=db.schema("commercial_intel").from(table).select(select);
  if(order)q=q.order(order.column,{ascending:order.ascending??true});
  const {data,error}=await q;
  if(error)throw new Error(table+":"+error.message);
  return data||[];
}
async function getCycleRows(cycleId:string,slug:string){
  const {data,error}=await db.schema("commercial_intel").from("sheet_sync_rows")
    .select("cycle_id,product_id,product_slug,company_id,bucket,company_name,canonical_domain,website_url,trade,location_text,state,country,product_score,commercial_score,opportunity_score,priority_band,recommended_offer,rights_status,commercial_status,freshness_score,source_first_seen,match_reasons,restriction_reasons,business_signals,evidence_domains,payload,evaluated_at")
    .eq("cycle_id",cycleId).eq("product_slug",slug).order("product_score",{ascending:false});
  if(error)throw new Error("cycle_rows:"+error.message);
  for(const r of data||[])assertNoBlockedKeys(r.payload||{});
  return data||[];
}
function buildSignals(rows:any[],cycleId:string,snapshotAt:string){
  const m=new Map<string,any>();
  for(const r of rows){
    const sigs=r.business_signals||{};
    for(const [k,v] of Object.entries(sigs)){
      if(!m.has(k))m.set(k,{companies:new Set(),points:0,safe:new Set(),review:new Set(),domains:new Set()});
      const x=m.get(k); x.companies.add(r.company_id); x.points+=Number(v)||0;
      (r.bucket==="SAFE"?x.safe:x.review).add(r.company_id);
      for(const d of r.evidence_domains||[])if(d)x.domains.add(d);
    }
  }
  return [["Signal Type","Companies","Evidence Points","SAFE Companies","Review Companies","Evidence Domains","Cycle ID","Snapshot At"],
    ...Array.from(m.entries()).sort((a,b)=>b[1].companies.size-a[1].companies.size).map(([k,x]:any)=>[
      k,x.companies.size,x.points,x.safe.size,x.review.size,Array.from(x.domains).sort().join(", "),cycleId,snapshotAt
    ])];
}
function productRows(product:any,rows:any[],cycleId:string,snapshotAt:string){
  const safe=rows.filter(r=>r.bucket==="SAFE");
  const review=rows.filter(r=>r.bucket==="REVIEW");
  const overview=[
    ["Metric","Value"],
    ["Product",product.name],["Slug",product.slug],["Cycle ID",cycleId],["Snapshot At",snapshotAt],
    ["Tier",product.plan_tier],["Status",product.status],["Audience",product.audience||""],["Description",product.description||""],
    ["Monthly Price Hint",Number(product.price_hint_monthly)||0],["One-Time Price Hint",Number(product.price_hint_one_time)||0],
    ["Max Records / Package",product.max_records||0],["Eligible Records",rows.length],["SAFE Records",safe.length],["Review Records",review.length],
    ["PII Allowed",!!product.pii_allowed],["Requires Commercial Safe",!!product.requires_commercial_safe]
  ];
  const safeData=[["Company","Domain","Website","Trade","Location","State","Country","Product Score","Commercial Score","Opportunity Score","Priority","Recommended Solution","Signal Summary","Business Signals","Evidence Domains","Freshness Score","Rights","Commercial Status"],
    ...safe.map(r=>[
      r.company_name||"",r.canonical_domain||"",r.website_url||"",r.trade||"",r.location_text||"",r.state||"",r.country||"",
      Number(r.product_score)||0,Number(r.commercial_score)||0,Number(r.opportunity_score)||0,r.priority_band||"",r.recommended_offer||"",
      signalSummary(r.business_signals),jsonSafe(r.business_signals),jsonSafe(r.evidence_domains),Number(r.freshness_score)||0,r.rights_status||"",r.commercial_status||""
    ])];
  const reviewData=[["Company","Domain","Trade","State","Product Score","Rights","Commercial Status","Restriction","Source","Review Reason","Restriction Reasons","Match Reasons"],
    ...review.map(r=>[
      r.company_name||"",r.canonical_domain||"",r.trade||"",r.state||"",Number(r.product_score)||0,r.rights_status||"",r.commercial_status||"",
      (r.restriction_reasons||[])[0]||"SOURCE_RIGHTS_REVIEW_REQUIRED",r.source_first_seen||"",
      r.rights_status==="BLOCKED"?"Source is blocked from resale.":"Authoritative source-rights clearance is still pending for commercial redistribution.",
      jsonSafe(r.restriction_reasons),jsonSafe(r.match_reasons)
    ])];
  return {overview,safeData,reviewData,signals:buildSignals(rows,cycleId,snapshotAt)};
}
async function writeProduct(targetKey:string,product:any,rows:any[],dictRows:any[][],versionRows:any[][],cycleId:string,snapshotAt:string,token:string){
  const id=TARGETS[targetKey].id;
  const meta=await sheetMetadata(id,token); const sm=sheetIdMap(meta);
  const built=productRows(product,rows,cycleId,snapshotAt);
  const tabs:any={
    "OVERVIEW":built.overview,"SAFE DATA":built.safeData,"REVIEW QUEUE":built.reviewData,
    "SIGNALS":built.signals,"DATA DICTIONARY":dictRows,"VERSION LOG":versionRows
  };
  const reqs:any[]=[];
  for(const [name,data] of Object.entries(tabs)){
    if(sm[name]===undefined)throw new Error(targetKey+":missing_tab:"+name);
    reqs.push(...updateRows(sm[name],data as any[][],26,1000));
  }
  await batchUpdate(id,reqs,token);
  return {id,title:meta.properties?.title,safe:built.safeData.length-1,review:built.reviewData.length-1};
}
async function writeMaster(payload:any,token:string){
  const manifest=payload.manifest;
  const id=TARGETS.MASTER.id; const meta=await sheetMetadata(id,token); const sm=sheetIdMap(meta);
  const products=payload.products||[],agents=payload.agents||[],rights=payload.rights||[],
        fields=payload.fields||[],buyers=payload.buyers||[],runs=payload.runs||[],audit=payload.audit||[];
  const command=[["Metric","Value"],["Cycle ID",manifest.cycle_id],["Snapshot At",manifest.snapshot_at],["Assets",manifest.assets?.total||0],["Commercial SAFE",manifest.assets?.safe||0],["Review Required",manifest.assets?.review||0],["Blocked",manifest.assets?.blocked||0],["Active Agents",manifest.agents?.active||0],["Signals",manifest.signals?.rows||0],["Rights Allowed",manifest.rights?.allowed||0],["Rights Review",manifest.rights?.review||0],["Rights Blocked",manifest.rights?.blocked||0],["Buyer Outreach","OFF"],["Personal PII Export","OFF"]];
  const prows=[["Slug","Product","Tier","Status","Monthly Price","One-Time Price","Max Records","Requires SAFE","PII Allowed","Eligible","SAFE","Review"],
    ...products.map((p:any)=>{const x=(manifest.products||[]).find((z:any)=>z.slug===p.slug)||{};return [p.slug,p.name,p.plan_tier,p.status,Number(p.price_hint_monthly)||0,Number(p.price_hint_one_time)||0,p.max_records||0,!!p.requires_commercial_safe,!!p.pii_allowed,x.eligible||0,x.safe||0,x.review||0];})];
  const arows=[["Slug","Name","Role","State","Write Scope","Reads Core","Can Export","Can Change Rights","Can Contact Buyers"],...agents.map((a:any)=>[a.slug,a.name,a.role,a.lifecycle_state,a.write_scope,!!a.reads_core,!!a.can_export,!!a.can_change_rights_status,!!a.can_contact_buyers])];
  const rrows=[["Source","Name","Type","Provider","Rights Status","Public URL","Evidence URL","Review Reason","Reviewed At","Reviewed By"],...rights.map((r:any)=>[r.source_slug,r.source_name||"",r.source_type||"",r.provider||"",r.rights_status,r.public_url||"",r.review_evidence_url||"",r.review_reason||"",r.reviewed_at||"",r.reviewed_by||""])];
  const frows=[["Field Key","Display Name","Category","Sensitivity","Export Status","Description"],...fields.map((f:any)=>[f.field_key,f.display_name,f.category,f.sensitivity,f.default_export_status,f.description||""])];
  const brows=[["Company","Website","Domain","Buyer Type","Target Trades","Target Markets","Use Case","Fit Score","Status","Contact Route","Personal PII Stored"],...buyers.map((b:any)=>[b.company_name,b.website_url||"",b.domain||"",b.buyer_type||"",jsonSafe(b.target_trades),jsonSafe(b.target_markets),b.use_case||"",Number(b.fit_score)||0,b.status||"",b.contact_route||"",!!b.personal_pii_stored])];
  const runrows=[["Agent","Run Type","Status","Input","Output","Blocked","Started","Finished"],...runs.slice(0,500).map((r:any)=>[r.agent_slug,r.run_type,r.status,r.input_count||0,r.output_count||0,r.blocked_count||0,r.started_at||"",r.finished_at||""])];
  const audrows=[["Event At","Actor","Action","Entity Type","Entity ID","Reason"],...audit.slice(0,500).map((a:any)=>[a.event_at,a.actor,a.action,a.entity_type,a.entity_id||"",a.reason||""])];
  const sys=[["Setting","Value"],["Strict Compliance","ON"],["Automatic Rights Promotion","OFF"],["Buyer Hunting","OFF"],["Buyer Outreach","OFF"],["Personal PII Export","OFF"],["Cycle ID",manifest.cycle_id],["Snapshot At",manifest.snapshot_at],["Writer","SolidOS Native Sheets"]];
  const tabs:any={"COMMAND CENTER":command,"PRODUCTS":prows,"AGENTS":arows,"RIGHTS REVIEW":rrows,"FIELD SAFETY":frows,"BUYERS":brows,"RUNS":runrows,"AUDIT":audrows,"SYSTEM":sys};
  const reqs:any[]=[]; for(const [name,data] of Object.entries(tabs)){if(sm[name]===undefined)throw new Error("MASTER:missing_tab:"+name);reqs.push(...updateRows(sm[name],data as any[][],26,1000));}
  await batchUpdate(id,reqs,token);
  return {id,title:meta.properties?.title};
}
async function verifyProductSheet(targetKey:string,expectedSafe:number,expectedReview:number,token:string){
  const id=TARGETS[targetKey].id;
  const safe=await readValues(id,"SAFE DATA!A:A",token);
  const review=await readValues(id,"REVIEW QUEUE!A:A",token);
  const actualSafe=Math.max(0,(safe.values||[]).length-1);
  const actualReview=Math.max(0,(review.values||[]).length-1);
  if(actualSafe!==expectedSafe||actualReview!==expectedReview)throw new Error(targetKey+":verify_counts:"+actualSafe+"/"+actualReview+" expected "+expectedSafe+"/"+expectedReview);
  return {actualSafe,actualReview};
}
async function commercialSync(token:string){
  const {data:payload,error:prepErr}=await db.rpc("solidos_prepare_commercial_sheet_sync");
  if(prepErr)throw new Error("prepare_cycle:"+prepErr.message);
  const manifest=payload?.manifest;
  if(!manifest||manifest.schema_version!==2)throw new Error("invalid_manifest");
  const cycleId=manifest.cycle_id, snapshotAt=manifest.snapshot_at;
  const products=payload.products||[], fields=payload.fields||[], allRows=payload.rows||[], allVersions=payload.versions||[];
  const dictRows=[["Field Key","Display Name","Category","Sensitivity","Export Status","Description"],...fields.map((f:any)=>[f.field_key,f.display_name,f.category,f.sensitivity,f.default_export_status,f.description||""])];
  const bySlug:any={}; for(const p of products)bySlug[p.slug]=p;
  const results:any[]=[];

  try{
    for(const key of ["STARTER","GROWTH","AUTOMATION","AGENCY","CUSTOM"]){
      const slug=TARGETS[key].slug, product=bySlug[slug]; if(!product)throw new Error("missing_product:"+slug);
      const rows=allRows.filter((r:any)=>r.product_slug===slug);
      for(const r of rows)assertNoBlockedKeys(r.payload||{});
      const oldVers=allVersions.filter((v:any)=>v.product_id===product.id).sort((a:any,b:any)=>Number(b.version_no)-Number(a.version_no)).slice(0,20);
      const checksum=await hashText(JSON.stringify(rows.map((r:any)=>[r.company_id,r.bucket,r.product_score,r.commercial_score,r.rights_status,r.commercial_status])));
      const nextVersion=(oldVers?.[0]?.version_no||0)+1;
      const versionRows=[["Version","Snapshot At","Eligible Records","Safe Records","Review Records","Schema Version","Checksum","Status"],
        [nextVersion,snapshotAt,rows.length,rows.filter((r:any)=>r.bucket==="SAFE").length,rows.filter((r:any)=>r.bucket==="REVIEW").length,2,checksum,"publishing"],
        ...oldVers.map((v:any)=>[v.version_no,v.snapshot_at,v.record_count,v.safe_record_count,v.review_record_count,v.schema_version,v.checksum||"",v.status])
      ];
      const res=await writeProduct(key,product,rows,dictRows,versionRows,cycleId,snapshotAt,token);
      const verification=await verifyProductSheet(key,res.safe,res.review,token);
      results.push({key,...res,...verification});
    }

    await writeMaster(payload,token);

    const {data:finish,error:finishErr}=await db.rpc("solidos_finish_commercial_sheet_sync",{p_cycle_id:cycleId,p_success:true,p_error:null});
    if(finishErr)throw new Error("finish_cycle:"+finishErr.message);
    const versions=finish?.versions||[];

    for(const key of ["STARTER","GROWTH","AUTOMATION","AGENCY","CUSTOM"]){
      const slug=TARGETS[key].slug, product=bySlug[slug];
      const vers=versions.filter((v:any)=>v.product_id===product.id).sort((a:any,b:any)=>Number(b.version_no)-Number(a.version_no)).slice(0,20);
      const meta=await sheetMetadata(TARGETS[key].id,token); const sm=sheetIdMap(meta);
      await batchUpdate(TARGETS[key].id,updateRows(sm["VERSION LOG"],[["Version","Snapshot At","Eligible Records","Safe Records","Review Records","Schema Version","Checksum","Status"],...vers.map((v:any)=>[v.version_no,v.snapshot_at,v.record_count,v.safe_record_count,v.review_record_count,v.schema_version,v.checksum||"",v.status])],26,1000),token);
    }

    return {ok:true,cycle_id:cycleId,snapshot_at:snapshotAt,results};
  }catch(e){
    const msg=e instanceof Error?e.message:String(e);
    try{await db.rpc("solidos_finish_commercial_sheet_sync",{p_cycle_id:cycleId,p_success:false,p_error:msg});}catch{}
    throw e;
  }
}

async function fetchAllBooked(table:string,select="*",orderCol?:string,ascending=true){
  const out:any[]=[]; let from=0; const step=1000;
  while(true){
    let q:any=db.schema("booked_solid").from(table).select(select).range(from,from+step-1);
    if(orderCol)q=q.order(orderCol,{ascending});
    const {data,error}=await q;
    if(error)throw new Error("booked_"+table+":"+error.message);
    const part=data||[]; out.push(...part);
    if(part.length<step)break; from+=step;
  }
  return out;
}
function priRank(p:any){const x=String(p||"").toLowerCase();return x==="hot"?4:x==="high"?3:x==="signal"?2:1;}
function contactResolution(l:any){return l?.lead_brief?.contact_resolution||{};}
function searchMarket(c:any){return c?.metadata?.search_market||"US";}
function fmtPri(p:any){return String(p||"standard").toUpperCase();}
function sortLeads(a:any,b:any){return priRank(b.priority_band)-priRank(a.priority_band)||(Number(b.opportunity_score)||0)-(Number(a.opportunity_score)||0);}
async function writeTab(id:string,sm:any,name:string,rows:any[][],token:string,maxRows:number,maxCols:number){
  if(sm[name]===undefined)throw new Error("CORE:missing_tab:"+name);
  await batchUpdate(id,updateRows(sm[name],rows,maxCols,maxRows),token);
}
async function coreSync(token:string){
  const id=TARGETS.CORE_CRM.id;
  const meta=await sheetMetadata(id,token), sm=sheetIdMap(meta);
  const nowIso=new Date().toISOString();

  const [companies,leads,contacts,evidence,messages,settingsRows,work,sourceRows,strategyRows]=await Promise.all([
    fetchAllBooked("companies","*","updated_at",false),
    fetchAllBooked("leads","*","opportunity_score",false),
    fetchAllBooked("contacts","*","updated_at",false),
    fetchAllBooked("evidence","*","observed_at",false),
    fetchAllBooked("outreach_queue","*","created_at",false),
    fetchAllBooked("runtime_settings","*"),
    fetchAllBooked("work_queue","id,status,kind,available_at,locked_at,attempts,last_error,updated_at"),
    fetchAllBooked("source_catalog","slug,enabled,consecutive_errors,metadata"),
    fetchAllBooked("search_strategies","id,enabled,lifecycle_state")
  ]);

  const settings=settingsRows?.[0]||{};
  const companyById=new Map(companies.map((c:any)=>[c.id,c]));
  const leadByCompany=new Map<string,any>();
  const leadById=new Map<string,any>();
  for(const l of leads){
    leadById.set(l.id,l);
    const prev=leadByCompany.get(l.company_id);
    if(!prev||Number(l.opportunity_score||0)>Number(prev.opportunity_score||0)||String(l.updated_at)>String(prev.updated_at))leadByCompany.set(l.company_id,l);
  }

  const bestContactByCompany=new Map<string,any>();
  for(const ct of contacts){
    const prev=bestContactByCompany.get(ct.company_id);
    const rank=(x:any)=>(x?.email?100:0)+(x?.phone?60:0)+Number(x?.email_confidence||0)+Number(x?.phone_confidence||0);
    if(!prev||rank(ct)>rank(prev))bestContactByCompany.set(ct.company_id,ct);
  }

  // Preserve Courtney's manual workflow columns by stable Lead ID.
  const oldAQ=await readValues(id,"ACTION QUEUE!A2:Q500",token);
  const manual=new Map<string,any[]>();
  for(const r of oldAQ.values||[]){
    const leadId=r?.[15];
    if(leadId)manual.set(String(leadId),[r?.[11]||"Not Reviewed",r?.[12]||"",r?.[13]||"",r?.[14]||""]);
  }

  const qualified=leads.filter((l:any)=>String(l.status).toLowerCase()==="qualified").sort(sortLeads);
  const candidates=leads.filter((l:any)=>String(l.status).toLowerCase()==="candidate").sort(sortLeads);
  const ready=qualified.filter((l:any)=>String(contactResolution(l).state||"")==="ready");
  const contactForms=qualified.filter((l:any)=>String(contactResolution(l).state||"")==="contact_form_available");
  const phoneOnly=qualified.filter((l:any)=>String(contactResolution(l).state||"")==="phone_available");
  const namedDM=qualified.filter((l:any)=>!!contactResolution(l).decision_maker_known).length;
  const emailContacts=contacts.filter((c:any)=>!!c.email).length;
  const phoneContacts=contacts.filter((c:any)=>!!c.phone).length;

  const priCounts={hot:0,high:0,signal:0,standard:0} as any;
  for(const l of qualified){
    const p=String(l.priority_band||"standard").toLowerCase();
    priCounts[p]=(priCounts[p]||0)+1;
  }

  const dueNow=work.filter((q:any)=>q.status==="pending"&&Date.parse(q.available_at)<=Date.now()).length;
  const futureWork=work.filter((q:any)=>q.status==="pending"&&Date.parse(q.available_at)>Date.now()).length;
  const runningWork=work.filter((q:any)=>q.status==="running").length;
  const blockedWork=work.filter((q:any)=>q.status==="blocked").length;
  const failedHistory=work.filter((q:any)=>q.status==="failed").length;
  const staleRunning=work.filter((q:any)=>q.status==="running"&&q.locked_at&&Date.parse(q.locked_at)<Date.now()-5*60*1000).length;
  const pendingByKind=(kind:string)=>work.filter((q:any)=>q.status==="pending"&&q.kind===kind).length;

  const enabledSources=sourceRows.filter((s:any)=>s.enabled).length;
  const coolingSources=sourceRows.filter((s:any)=>s.enabled&&s.metadata?.cooldown_until&&Date.parse(s.metadata.cooldown_until)>Date.now()).length;
  const degradedSources=sourceRows.filter((s:any)=>s.enabled&&(Number(s.consecutive_errors||0)>=4||String(s.metadata?.state||"")==="degraded")).length;
  const enabledStrategies=strategyRows.filter((s:any)=>s.enabled&&["active","testing"].includes(String(s.lifecycle_state||"active"))).length;
  const backpressure=dueNow>60||runningWork>20;

  const actionFor=(l:any)=>{
    const cr=contactResolution(l), state=String(cr.state||"");
    if(state==="ready")return "READY";
    if(state==="contact_form_available")return "CONTACT FORM";
    if(state==="phone_available")return "PHONE ONLY";
    if(cr.recipient_email)return "REVIEW EMAIL";
    return "FIND EMAIL";
  };
  const routeLabel=(l:any)=>{
    const s=String(contactResolution(l).state||"");
    return s==="ready"?"Email Ready":s==="contact_form_available"?"Contact Form":s==="phone_available"?"Phone Only":"Needs Contact";
  };
  const contactValue=(l:any,key:string)=>{
    const cr=contactResolution(l), bc=bestContactByCompany.get(l.company_id)||{};
    if(key==="phone")return cr.phone||bc.phone||"";
    if(key==="email")return cr.recipient_email||bc.email||"";
    return "";
  };

  const readyIds=new Set(ready.map((l:any)=>l.id));
  const msgCount=new Map<string,number>();
  for(const m of messages){
    if(!["suppressed","failed"].includes(String(m.status||"").toLowerCase()))msgCount.set(m.lead_id,(msgCount.get(m.lead_id)||0)+1);
  }
  const readyMessages=messages.filter((m:any)=>readyIds.has(m.lead_id)&&!["suppressed","failed"].includes(String(m.status||"").toLowerCase())).length;
  const badMsg=Array.from(readyIds).filter((leadId:any)=>(msgCount.get(leadId)||0)!==5).length;
  const nonQualActive=messages.filter((m:any)=>{
    const l=leadById.get(m.lead_id);
    return l&&String(l.status).toLowerCase()!=="qualified"&&!["suppressed","failed"].includes(String(m.status||"").toLowerCase());
  }).length;
  const smsBad=contacts.filter((c:any)=>c.sms_eligible&&String(c.sms_consent_status||"").toLowerCase()!=="granted").length;
  const seen=new Set<string>(),dups=new Set<string>();
  for(const c of contacts){
    if(c.email){
      const k=c.company_id+"|"+String(c.email).toLowerCase();
      if(seen.has(k))dups.add(k); else seen.add(k);
    }
  }
  const warningCount=[badMsg,nonQualActive,smsBad,dups.size,staleRunning].filter((x:any)=>Number(x)>0).length;

  // Executive dashboard. No company rows or internal UUIDs here.
  const command=[
    ["BOOKED SOLID — COMMAND CENTER","","","","","","",""],
    ["Snapshot",nowIso,"Search",settings.search_enabled?"ON":"OFF","Email",settings.email_enabled?"ON":"OFF","SMS",settings.sms_enabled?"ON":"OFF"],
    ["Companies",companies.length,"Leads",leads.length,"Qualified",qualified.length,"Candidates",candidates.length],
    ["Contacts",contacts.length,"Email Contacts",emailContacts,"Phone Contacts",phoneContacts,"Evidence",evidence.length],
    ["Ready Email Leads",ready.length,"Ready Messages",readyMessages,"Named Decision Makers",namedDM,"Needs Contact Work",qualified.length-ready.length],
    ["Last Sync",nowIso,"Writer","SolidOS Native","Backpressure",backpressure?"ON":"OFF","Warnings",warningCount],
    ["PRIORITY DISTRIBUTION","","","","","","",""],
    ["HOT",priCounts.hot||0,"HIGH",priCounts.high||0,"SIGNAL",priCounts.signal||0,"STANDARD",priCounts.standard||0],
    ["CONTACT ROUTES","","","","","","",""],
    ["EMAIL READY",ready.length,"CONTACT FORM",contactForms.length,"PHONE ONLY",phoneOnly.length,"TOTAL QUALIFIED",qualified.length],
    ["","","","","","","",""],
    ["WORK QUEUE / THROUGHPUT","","","","","","",""],
    ["DUE NOW",dueNow,"RUNNING",runningWork,"FUTURE",futureWork,"FAILED HISTORY",failedHistory],
    ["CONTACT PENDING",pendingByKind("contact"),"QUALIFY PENDING",pendingByKind("qualify"),"RESEARCH PENDING",pendingByKind("research"),"RESOLVE PENDING",pendingByKind("resolve")],
    ["","","","","","","",""],
    ["SYSTEM HEALTH & SAFETY","","","","","","",""],
    ["SOURCES ENABLED",enabledSources,"COOLING",coolingSources,"DEGRADED",degradedSources,"STRATEGIES ON",enabledStrategies],
    ["SEARCH",settings.search_enabled?"ON":"OFF","EMAIL",settings.email_enabled?"ON":"OFF","SMS",settings.sms_enabled?"ON":"OFF","BUYER OUTREACH","OFF"],
    ["BACKPRESSURE",backpressure?"ON":"OFF","BLOCKED WORK",blockedWork,"STALE RUNNING",staleRunning,"DQ WARNINGS",warningCount],
    ["SYNC", "Every ~2 min","ACTION QUEUE",qualified.length,"READY",ready.length,"NEEDS WORK",qualified.length-ready.length],
    ["","","","","","","",""],
    ["LEGEND","","","","","","",""],
    ["HOT","Highest priority","HIGH","Strong priority","SIGNAL","Signal-led","STANDARD","Normal"],
    ["READY","Email route ready","CONTACT FORM","Use public form","PHONE ONLY","Phone route available","FIND EMAIL","Needs contact work"]
  ];

  // Show ALL qualified leads, not only the email-ready subset.
  const aq=[["Company","Priority","Opportunity","Trade","Decision Maker / Contact","Role","Email","Phone","Why Now","Offer","Action","Review Status","Owner","Next Follow-up","Courtney Notes","Lead ID","Company ID"],
    ...qualified.map((l:any)=>{
      const c=companyById.get(l.company_id)||{}, cr=contactResolution(l), m=manual.get(String(l.id))||["Not Reviewed","","",""];
      return [
        c.name||"",fmtPri(l.priority_band),Number(l.opportunity_score)||0,c.trade||"",
        cr.decision_maker_name||cr.recipient_name||"",cr.decision_maker_role||cr.recipient_role||"",
        contactValue(l,"email"),contactValue(l,"phone"),l.why_now||"",l.offer||c.recommended_offer||"",
        actionFor(l),m[0],m[1],m[2],m[3],l.id,l.company_id
      ];
    })];

  const tradeMap=new Map<string,any>();
  for(const l of [...qualified,...candidates]){
    const c=companyById.get(l.company_id)||{}, t=c.trade||"Unknown";
    if(!tradeMap.has(t))tradeMap.set(t,{q:0,c:0,r:0,sum:0,max:0,n:0});
    const x=tradeMap.get(t),opp=Number(l.opportunity_score)||0;
    if(String(l.status).toLowerCase()==="qualified")x.q++; else x.c++;
    if(String(contactResolution(l).state||"")==="ready")x.r++;
    x.sum+=opp;x.n++;x.max=Math.max(x.max,opp);
  }
  const trade=[["Trade","Qualified","Candidates","Ready","Avg Opportunity","Max Opportunity"],
    ...Array.from(tradeMap.entries()).sort((a:any,b:any)=>b[1].q-a[1].q).map(([t,x]:any)=>[t,x.q,x.c,x.r,x.n?Math.round((x.sum/x.n)*10)/10:0,x.max])];

  // User-facing columns first. Stable IDs stay at the end and are hidden in the workbook.
  const q360=[["Company","Priority","Opportunity","Trade","Decision Maker","Role","Email","Phone","Route","Contact Class","Why Now","Offer","Website","Verified Location","State","Search Market","Lead ID","Company ID"],
    ...qualified.map((l:any)=>{
      const c=companyById.get(l.company_id)||{},cr=contactResolution(l);
      return [c.name||"",fmtPri(l.priority_band),Number(l.opportunity_score)||0,c.trade||"",
        cr.decision_maker_name||cr.recipient_name||"",cr.decision_maker_role||cr.recipient_role||"",
        contactValue(l,"email"),contactValue(l,"phone"),routeLabel(l),cr.contact_class||"",l.why_now||"",
        l.offer||c.recommended_offer||"",c.website_url||"",c.location_text||"",c.state||"",searchMarket(c),l.id,l.company_id];
    })];

  const allLeads=[["Company","Status","Priority","Opportunity","Score","Fit","Trade","Offer","Why Now","Email","Phone","Website","Verified Location","State","Search Market","Route","Lead ID","Company ID"],
    ...leads.slice().sort(sortLeads).map((l:any)=>{
      const c=companyById.get(l.company_id)||{};
      return [c.name||"",l.status||"",fmtPri(l.priority_band),Number(l.opportunity_score)||0,Number(l.score)||0,Number(l.fit_score)||0,
        c.trade||"",l.offer||c.recommended_offer||"",l.why_now||"",contactValue(l,"email"),contactValue(l,"phone"),
        c.website_url||"",c.location_text||"",c.state||"",searchMarket(c),routeLabel(l),l.id,l.company_id];
    })];

  const compRows=[["Company","Domain","Website","Trade","Company Status","Lead Status","Priority","Opportunity","Fit","Offer","Recipient Email","Phone","Verified Location","State","Search Market","First Source","Last Source","Last Researched","Enrichment Version","Company ID"],
    ...companies.map((c:any)=>{
      const l=leadByCompany.get(c.id),cr=contactResolution(l),bc=bestContactByCompany.get(c.id)||{};
      return [c.name||"",c.canonical_domain||"",c.website_url||"",c.trade||"",c.status||"",l?.status||"",fmtPri(l?.priority_band),
        l?.opportunity_score??"",l?.fit_score??c.fit_score??"",l?.offer||c.recommended_offer||"",cr.recipient_email||bc.email||"",
        cr.phone||bc.phone||"",c.location_text||"",c.state||"",searchMarket(c),c.source_first_seen||"",c.source_last_seen||"",
        c.last_researched_at||"",c.enrichment_version||0,c.id];
    })];

  const contRows=[["Company","Lead Status","Priority","Name","Role","Email","Email Confidence","Primary Email?","Decision Maker?","Phone","Phone Type","Phone Confidence","Source URL","Contact Status","SMS Consent","SMS Eligible","Phone Verified","Updated","Contact ID","Company ID"],
    ...contacts.map((ct:any)=>{
      const c=companyById.get(ct.company_id)||{},l=leadByCompany.get(ct.company_id),cr=contactResolution(l);
      return [c.name||"",l?.status||"",fmtPri(l?.priority_band),ct.full_name||"",ct.role||"",ct.email||"",ct.email_confidence??"",
        cr.email_contact_id===ct.id?"YES":"NO",cr.decision_maker_contact_id===ct.id?"YES":"NO",ct.phone||"",ct.phone_type||"",
        ct.phone_confidence??"",ct.source_url||ct.phone_source_url||"",ct.status||ct.phone_status||"",ct.sms_consent_status||"unknown",
        !!ct.sms_eligible,ct.phone_last_verified_at||"",ct.updated_at||"",ct.id,ct.company_id];
    })];

  const msgRows=[["Company","Priority","Opportunity","Sequence","Recipient","Email","Subject","Full Message","CTA","Landing URL","Scheduled","Sent","Display Status","Message ID","Lead ID"],
    ...messages.map((m:any)=>{
      const l=leadById.get(m.lead_id)||{},c=companyById.get(l.company_id)||{};
      return [c.name||"",fmtPri(l.priority_band),Number(l.opportunity_score)||0,m.sequence_no||0,m.recipient_name||"",m.recipient_email||"",
        m.subject||"",m.body_text||m.body||"",m.cta_label||"",m.landing_url||"",m.scheduled_at||"",m.sent_at||"",
        String(m.status||"").toUpperCase(),m.id,m.lead_id];
    })];

  const evidenceRows=[["Company","Lead Status","Priority","Opportunity","Evidence Type","Claim","Snippet","Source URL","Confidence","Evidence ID"],
    ...evidence.map((e:any)=>{
      const c=companyById.get(e.company_id)||{},l=leadByCompany.get(e.company_id);
      return [c.name||"",l?.status||"",fmtPri(l?.priority_band),Number(l?.opportunity_score)||0,e.evidence_type||"",e.claim||"",
        e.snippet||"",e.source_url||"",Number(e.confidence)||0,e.id];
    })];

  const gaps=[["Company","Priority","Opportunity","Decision Maker","Role","Email","Phone","Route Status","Next Action","Lead ID"],
    ...qualified.map((l:any)=>{
      const c=companyById.get(l.company_id)||{},cr=contactResolution(l);
      return [c.name||"",fmtPri(l.priority_band),Number(l.opportunity_score)||0,cr.decision_maker_name||cr.recipient_name||"",
        cr.decision_maker_role||cr.recipient_role||"",contactValue(l,"email"),contactValue(l,"phone"),routeLabel(l),actionFor(l),l.id];
    })];

  const dq=[["Check","Status","Count","Note"],
    ["Ready leads without exactly five active messages",badMsg===0?"PASS":"WARN",badMsg,"Each email-ready lead should have five active messages."],
    ["Nonqualified/suppressed active outreach",nonQualActive===0?"PASS":"WARN",nonQualActive,"No active outreach should remain for nonqualified/suppressed leads."],
    ["SMS eligible without consent",smsBad===0?"PASS":"WARN",smsBad,"SMS remains OFF unless consent is granted."],
    ["Duplicate contacts",dups.size===0?"PASS":"WARN",dups.size,"Same company/email duplicates."],
    ["Stale running work >5 minutes",staleRunning===0?"PASS":"WARN",staleRunning,"Stale locks should be reaped automatically."],
    ["Qualified route coverage",(ready.length+contactForms.length+phoneOnly.length)===qualified.length?"PASS":"WARN",qualified.length-(ready.length+contactForms.length+phoneOnly.length),"Every qualified lead should have a usable route or explicit gap."]
  ];

  const oldLog=await readValues(id,"HOURLY LOG!A1:X1000",token);
  let logRows=oldLog.values||[];
  if(!logRows.length)logRows=[["Timestamp","Companies","Δ Companies","Leads","Δ Leads","Qualified","Δ Qualified","Candidates","Ready Leads","Ready Messages","Contacts","Δ Contacts","Email Contacts","Phone Contacts","Evidence","Δ Evidence","Due Work","Blocked Work","Note","Named Decision Makers","Contact Intelligence v2 Qualified Coverage","Contact Form Routes","Phone Routes"]];
  const last=logRows.length>1?logRows[logRows.length-1]:null;
  const lastTs=last?.[0]?Date.parse(String(last[0])):0;
  if(!lastTs||Date.now()-lastTs>=55*60*1000){
    const prev=last||[];
    logRows.push([nowIso,companies.length,prev[1]!==undefined?companies.length-Number(prev[1]||0):"",leads.length,prev[3]!==undefined?leads.length-Number(prev[3]||0):"",
      qualified.length,prev[5]!==undefined?qualified.length-Number(prev[5]||0):"",candidates.length,ready.length,readyMessages,contacts.length,
      prev[10]!==undefined?contacts.length-Number(prev[10]||0):"",emailContacts,phoneContacts,evidence.length,
      prev[14]!==undefined?evidence.length-Number(prev[14]||0):"",dueNow,blockedWork,
      "SolidOS live sync; full CRM tabs refreshed; email/SMS/buyer outreach OFF.",namedDM,qualified.length,contactForms.length,phoneOnly.length]);
  }

  const sys=[["Metric","Value"],
    ["Snapshot",nowIso],["Writer","SolidOS Native Sheets"],["Sync cadence","~2 minutes when data changes"],
    ["Search",settings.search_enabled?"ON":"OFF"],["Email",settings.email_enabled?"ON":"OFF"],["SMS",settings.sms_enabled?"ON":"OFF"],["Buyer outreach","OFF"],
    ["Companies",companies.length],["Leads",leads.length],["Qualified",qualified.length],["Candidates",candidates.length],
    ["Email Ready",ready.length],["Contact Form Routes",contactForms.length],["Phone Only Routes",phoneOnly.length],["Named Decision Makers",namedDM],
    ["Contacts",contacts.length],["Evidence",evidence.length],["Due Work",dueNow],["Running Work",runningWork],["Future Work",futureWork],
    ["Failed History",failedHistory],["Blocked Work",blockedWork],["Stale Running",staleRunning],["Backpressure",backpressure?"ON":"OFF"],
    ["Sources Enabled",enabledSources],["Sources Cooling",coolingSources],["Sources Degraded",degradedSources],["Strategies Enabled",enabledStrategies],
    ["Data Quality",warningCount===0?"PASS":"WARNING"],["Warnings",warningCount]
  ];

  await writeTab(id,sm,"COMMAND CENTER",command,token,200,12);
  await writeTab(id,sm,"ACTION QUEUE",aq,token,500,17);
  await writeTab(id,sm,"TRADE SUMMARY",trade,token,200,11);
  await writeTab(id,sm,"QUALIFIED 360",q360,token,300,18);
  await writeTab(id,sm,"ALL LEADS",allLeads,token,500,18);
  await writeTab(id,sm,"COMPANIES",compRows,token,1000,20);
  await writeTab(id,sm,"CONTACTS",contRows,token,1000,20);
  await writeTab(id,sm,"MESSAGES",msgRows,token,1500,15);
  await writeTab(id,sm,"EVIDENCE",evidenceRows,token,3200,10);
  await writeTab(id,sm,"CONTACT GAPS",gaps,token,500,10);
  await writeTab(id,sm,"DATA QUALITY",dq,token,500,10);
  await writeTab(id,sm,"HOURLY LOG",logRows,token,1000,24);
  await writeTab(id,sm,"SYSTEM STATUS",sys,token,300,10);

  const check=await readValues(id,"COMMAND CENTER!A1:H24",token);
  return {ok:true,companies:companies.length,leads:leads.length,qualified:qualified.length,candidates:candidates.length,
    ready:ready.length,contact_forms:contactForms.length,phone_only:phoneOnly.length,contacts:contacts.length,evidence:evidence.length,
    due_work:dueNow,running_work:runningWork,command_rows:(check.values||[]).length};
}

async function syncPending(token:string){
  const processed:any[]=[];
  for(let i=0;i<2;i++){
    const {data:req,error}=await db.rpc("claim_solidos_sheet_sync");
    if(error)throw new Error("claim_sync:"+error.message);
    if(!req)break;

    try{
      let result:any;
      if(req.sync_scope==="CORE_CRM")result=await coreSync(token);
      else if(req.sync_scope==="COMMERCIAL_PRODUCTS")result=await commercialSync(token);
      else throw new Error("unknown_sync_scope:"+req.sync_scope);

      const {error:finishErr}=await db.rpc("finish_solidos_sheet_sync",{p_id:req.id,p_status:"SUCCEEDED",p_error:null});
      if(finishErr)throw new Error("finish_request:"+finishErr.message);
      processed.push({request_id:req.id,scope:req.sync_scope,result});
    }catch(e){
      const msg=e instanceof Error?e.message:String(e);
      try{await db.rpc("finish_solidos_sheet_sync",{p_id:req.id,p_status:"FAILED",p_error:msg});}catch{}
      throw e;
    }
  }
  return {ok:true,idle:processed.length===0,processed_count:processed.length,processed};
}

async function verifyAll(token:string){
  const checks=[];
  for(const [key,t] of Object.entries(TARGETS)){
    const meta=await sheetMetadata((t as any).id,token);
    checks.push({key,ok:true,title:meta?.properties?.title??null,tabs:(meta?.sheets??[]).map((s:any)=>s.properties?.title).filter(Boolean)});
  }
  return checks;
}

Deno.serve(async(req)=>{
  try{
    const body=req.method==="POST"?await req.json().catch(()=>({})):{};
    const action=body.action??"health";
    const sa=serviceAccount();
    if(action==="health")return out({ok:true,system:"SolidOS",component:"native-sheets",configured:!!sa,write_enabled:!!sa,targets:Object.keys(TARGETS)});
    if(!sa)return out({ok:false,error:"google_service_account_not_configured",configured:false},503);
    const token=await googleToken(sa);
    if(action==="verify"){
      const checks=await verifyAll(token);
      return out({ok:checks.every((x:any)=>x.ok),configured:true,write_enabled:true,service_account_email:sa.client_email,checks});
    }
    if(action==="sync-commercial"){
      const result=await commercialSync(token);
      return out(result);
    }
    if(action==="sync-core"){
      const result=await coreSync(token);
      return out(result);
    }
    if(action==="sync-pending"){
      const result=await syncPending(token);
      return out(result);
    }
    return out({ok:false,error:"unknown_action",allowed:["health","verify","sync-commercial","sync-core","sync-pending"]},400);
  }catch(e){
    console.error(e);
    return out({ok:false,error:e instanceof Error?e.message:String(e)},500);
  }
});