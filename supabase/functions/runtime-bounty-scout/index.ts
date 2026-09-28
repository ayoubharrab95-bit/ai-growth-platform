import postgres from "npm:postgres@3.4.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey",
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, {
  ssl: "require",
  max: 3,
  idle_timeout: 5,
});

const githubHeaders = () => {
  const token = Deno.env.get("GITHUB_TOKEN");
  if (!token) throw new Error("GITHUB_TOKEN is not configured");
  return {
    Accept: "application/vnd.github+json",
    Authorization: `Bearer ${token}`,
    "X-GitHub-Api-Version": "2022-11-28",
    "User-Agent": "MoneyHunter/1.0",
  };
};

function safeUrl(raw: string): string | null {
  try {
    const u = new URL(raw);
    return u.hostname === "github.com" && u.pathname.startsWith("/") ? u.toString() : null;
  } catch {
    return null;
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "method_not_allowed" }, 405);

  try {
    const body = await req.json().catch(() => ({}));
    const limit = Math.min(20, Math.max(1, Number(body.limit ?? 20)));
    const q = [
      "is:issue",
      "is:open",
      "created:>=2026-09-20",
      "(bounty OR reward OR bounty)",
      "(USDC OR USDT OR EVM OR Base)",
      "-label:spam",
    ].join(" ");

    const res = await fetch(`https://api.github.com/search/issues?q=${encodeURIComponent(q)}&sort=updated&order=desc&per_page=${limit}`, {
      headers: githubHeaders(),
    });
    if (!res.ok) throw new Error(`GitHub search failed: ${res.status}`);
    const data = await res.json();

    const candidates = [];
    for (const item of data.items ?? []) {
      const url = safeUrl(item.html_url ?? "");
      if (!url) continue;

      const repoMatch = String(item.repository_url ?? "").match(/repos\/([^/]+\/[^/]+)$/);
      if (!repoMatch) continue;
      const repo = repoMatch[1];

      const existing = await sql`
        SELECT task_id
        FROM runtime_jobs
        WHERE target = ${url}
          AND status IN ('queued','running')
        LIMIT 1
      `;
      if (existing.length) continue;

      const taskId = crypto.randomUUID();
      const payload = {
        source: "github",
        issue_url: url,
        repository: repo,
        issue_number: item.number,
        title: item.title,
        labels: (item.labels ?? []).map((x: any) => x.name),
        html_url: url,
        payout_preference: ["USDC", "USDT"],
        network_preference: ["Base", "Ethereum", "BSC", "EVM"],
        action: "verify_then_execute",
      };

      await sql`
        INSERT INTO runtime_jobs
          (task_id, agent_role, target, scope, success_metric, risk_level, rollback_plan,
           approval_state, payload, correlation_id, parent_task_id)
        VALUES
          (${taskId}, 'bounty_agent', ${url},
           ${item.title ?? "GitHub bounty"},
           'verified_open_bounty_with_reviewable_submission',
           'low', 'no-op', 'pending',
           ${sql.json(payload)}, ${taskId}, NULL)
      `;

      candidates.push({ task_id: taskId, repository: repo, issue_number: item.number, title: item.title, url });
    }

    await sql`
      UPDATE runtime_agents
      SET last_heartbeat = now()
      WHERE role = 'orchestrator'
    `;

    return json({
      ok: true,
      source: "github",
      scanned: (data.items ?? []).length,
      queued: candidates.length,
      candidates,
      execution_note: "Discovery queues verified candidates. Claiming/submission remains gated until an execution worker has the required credentials and a concrete implementation plan.",
    });
  } catch (err) {
    return json({ ok: false, error: err instanceof Error ? err.message : "internal_error" }, 500);
  }
});
