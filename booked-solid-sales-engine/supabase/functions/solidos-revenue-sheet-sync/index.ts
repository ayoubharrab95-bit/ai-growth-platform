import "jsr:@supabase/functions-js/edge-runtime.d.ts";
Deno.serve(()=>new Response(JSON.stringify({
  ok:false,
  disabled:true,
  replacement:"solidos-revenue-crm-writer"
}),{status:410,headers:{"Content-Type":"application/json"}}));