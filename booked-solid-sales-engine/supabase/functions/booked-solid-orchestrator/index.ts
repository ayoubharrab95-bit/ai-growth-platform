import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const headers = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Content-Type": "application/json",
};

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const out = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers });

async function chooseStrategies(limit = 5) {
  const { data, error } = await db.schema("booked_solid")
    .from("search_strategies")
    .select("*")
    .eq("enabled", true)
    .order("performance_score", { ascending: false })
    .limit(50);
  if (error) throw error;

  const now = Date.now();
  return (data ?? []).map((s: any) => {
    const ageHours = s.last_used_at
      ? Math.max(0, (now - new Date(s.last_used_at).getTime()) / 3600000)
      : 9999;
    const freshness = Math.min(20, ageHours);
    const exploration = Number(s.exploration_weight ?? 1) * 10;
    const usagePenalty = Math.min(20, Number(s.uses_count ?? 0) * 0.05);
    return {
      ...s,
      planner_score: Number(s.performance_score ?? 50) + exploration + freshness - usagePenalty,
    };
  }).sort((a: any, b: any) => b.planner_score - a.planner_score).slice(0, limit);
}

async function plan(body: any) {
  const strategies = await chooseStrategies(Number(body?.limit ?? 5));
  const { data: sources, error } = await db.schema("booked_solid")
    .from("source_catalog").select("*").eq("enabled", true)
    .order("base_weight", { ascending: false }).limit(1);
  if (error) throw error;
  const source = sources?.[0];
  if (!strategies.length || !source) return out({ ok: false, reason: "no_enabled_strategy_or_source" }, 503);

  const jobs = strategies.map((s: any) => ({
    kind: "discover",
    priority: Math.max(1, Number(s.planner_score)),
    payload: {
      strategy_id: s.id, strategy_slug: s.slug, trade: s.trade,
      geography: s.geography, intent: s.intent,
      query_template: s.query_template, source_id: source.id,
      source_slug: source.slug, offer_hint: s.offer_hint,
    },
    status: "pending",
    available_at: new Date().toISOString(),
  }));

  const { data: queued, error: qError } = await db.schema("booked_solid")
    .from("work_queue").insert(jobs).select("id,kind,priority,payload");
  if (qError) throw qError;

  await db.schema("booked_solid").from("search_strategies")
    .update({ last_used_at: new Date().toISOString() })
    .in("id", strategies.map((s: any) => s.id));

  return out({
    ok: true,
    mode: "planner",
    email_gate: "blocked_until_email_configuration",
    queued: queued?.length ?? 0,
    strategies: strategies.map((s: any) => ({
      slug: s.slug, trade: s.trade, intent: s.intent,
      query_template: s.query_template, offer_hint: s.offer_hint,
      planner_score: s.planner_score,
    })),
  });
}

async function health() {
  const [{ count: companies }, { count: leads }, { count: pending }, { count: blocked }] =
    await Promise.all([
      db.schema("booked_solid").from("companies").select("*", { count: "exact", head: true }),
      db.schema("booked_solid").from("leads").select("*", { count: "exact", head: true }),
      db.schema("booked_solid").from("work_queue").select("*", { count: "exact", head: true }).eq("status", "pending"),
      db.schema("booked_solid").from("outreach_queue").select("*", { count: "exact", head: true }).eq("status", "blocked_email_not_configured"),
    ]);

  return out({
    ok: true, system: "booked-solid-sales-engine", status: "ACTIVE",
    email_gate: "BLOCKED_NOT_CONFIGURED",
    metrics: { companies: companies ?? 0, leads: leads ?? 0, pending_work: pending ?? 0, messages_blocked_by_email_gate: blocked ?? 0 },
    guarantees: {
      no_email_without_configuration: true,
      no_maps_export_pipeline: true,
      evidence_required_for_personalization: true,
      suppression_list_supported: true,
      strategy_rotation_enabled: true,
    },
  });
}

Deno.serve(async (req) => {
  try {
    if (req.method === "OPTIONS") return new Response("ok", { headers });
    const body = req.method === "POST" ? await req.json().catch(() => ({})) : {};
    const action = body.action ?? new URL(req.url).searchParams.get("action") ?? "health";
    if (action === "health") return await health();
    if (action === "plan") return await plan(body);
    return out({ ok: false, error: "unknown_action", allowed_actions: ["health", "plan"] }, 400);
  } catch (error) {
    console.error(error);
    return out({ ok: false, error: String(error) }, 500);
  }
});
