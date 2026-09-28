import "jsr:@supabase/functions-js/edge-runtime.d.ts";

/**
 * Runtime bounty submission gateway.
 *
 * This is the execution boundary between MoneyHunter/runtime jobs and GitHub.
 * It never executes PR code and never auto-approves or auto-merges.
 *
 * The base repository (bounty owner) and head repository (where the agent can
 * push) are intentionally independent, so fork -> upstream submissions work.
 */

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey",
};

type Plan = {
  base_owner: string;
  base_repo: string;
  base_branch: string;
  head_owner: string;
  head_repo: string;
  head_branch: string;
  issue_number: number;
  title: string;
  body: string;
};

type PullRequest = {
  number: number;
  html_url: string;
  state: string;
  head: { ref: string; repo: { full_name: string } | null };
  base: { ref: string; repo: { full_name: string } };
};

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });

function validName(value: string) {
  return /^[A-Za-z0-9_.-]+$/.test(value) && value.length <= 100;
}

function validBranch(value: string) {
  return value.length > 0 && value.length <= 255 && !/[\\s~^:?*\\[\\]]/.test(value);
}

async function github<T>(token: string, path: string, init: RequestInit = {}): Promise<T> {
  const response = await fetch(`https://api.github.com${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${token}`,
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      ...(init.headers ?? {}),
    },
  });

  const raw = await response.text();
  let data: unknown = {};
  try { data = raw ? JSON.parse(raw) : {}; } catch {}

  if (!response.ok) {
    const message = typeof data === "object" && data && "message" in data
      ? String((data as { message: unknown }).message)
      : `GitHub HTTP ${response.status}`;
    throw new Error(message);
  }

  return data as T;
}

async function preflight(token: string, plan: Plan) {
  const values = [
    plan.base_owner, plan.base_repo, plan.head_owner, plan.head_repo,
  ];
  if (values.some((v) => typeof v !== "string" || !validName(v))) {
    return { ok: false, status: "submission_blocked", reason: "Invalid repository owner/name." };
  }

  if (!validBranch(plan.base_branch) || !validBranch(plan.head_branch)) {
    return { ok: false, status: "submission_blocked", reason: "Invalid branch name." };
  }

  if (plan.base_branch === plan.head_branch &&
      plan.base_owner === plan.head_owner &&
      plan.base_repo === plan.head_repo) {
    return { ok: false, status: "submission_blocked", reason: "Head and base cannot be the same branch." };
  }

  if (!Number.isInteger(plan.issue_number) || plan.issue_number <= 0) {
    return { ok: false, status: "submission_blocked", reason: "Valid bounty issue_number required." };
  }

  const base = `${plan.base_owner}/${plan.base_repo}`;
  const head = `${plan.head_owner}/${plan.head_repo}`;

  const [issue, branch] = await Promise.all([
    github<{ state: string; pull_request?: unknown }>(
      token, `/repos/${base}/issues/${plan.issue_number}`
    ),
    github<{ ref: string }>(
      token, `/repos/${head}/git/ref/heads/${encodeURIComponent(plan.head_branch)}`
    ),
  ]);

  if (issue.pull_request) {
    return { ok: false, status: "submission_blocked", reason: `#${plan.issue_number} is already a pull request.` };
  }
  if (issue.state !== "open") {
    return { ok: false, status: "submission_blocked", reason: `Bounty issue #${plan.issue_number} is not open.` };
  }
  if (!branch.ref.endsWith(plan.head_branch)) {
    return { ok: false, status: "submission_blocked", reason: "Head branch verification failed." };
  }

  const headSpec = `${head}:${plan.head_branch}`;
  const existing = await github<PullRequest[]>(
    token,
    `/repos/${base}/pulls?state=open&base=${encodeURIComponent(plan.base_branch)}&head=${encodeURIComponent(headSpec)}&per_page=10`,
  );

  if (existing.length) {
    return {
      ok: true,
      status: "pr_open",
      pr_number: existing[0].number,
      url: existing[0].html_url,
      reused: true,
    };
  }

  return { ok: true, status: "ready" };
}

async function submit(token: string, plan: Plan) {
  const check = await preflight(token, plan);
  if (!check.ok || check.status !== "ready") return check;

  const base = `${plan.base_owner}/${plan.base_repo}`;
  const head = `${plan.head_owner}/${plan.head_repo}`;
  const headSpec = head === base ? plan.head_branch : `${head}:${plan.head_branch}`;

  try {
    const pr = await github<PullRequest>(token, `/repos/${base}/pulls`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        title: plan.title,
        body: plan.body,
        head: headSpec,
        base: plan.base_branch,
        maintainer_can_modify: true,
        draft: false,
      }),
    });

    return {
      ok: true,
      status: "pr_open",
      pr_number: pr.number,
      url: pr.html_url,
      reused: false,
    };
  } catch (error) {
    // Race-safe recovery: another worker may have created the PR.
    const existing = await github<PullRequest[]>(
      token,
      `/repos/${base}/pulls?state=open&base=${encodeURIComponent(plan.base_branch)}&head=${encodeURIComponent(headSpec)}&per_page=10`,
    );
    if (existing.length) {
      return {
        ok: true,
        status: "pr_open",
        pr_number: existing[0].number,
        url: existing[0].html_url,
        reused: true,
      };
    }

    return {
      ok: false,
      status: "submission_blocked",
      reason: `PR creation failed: ${String(error)}`,
      retryable: true,
    };
  }
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST required" }, 405);

  try {
    const token = Deno.env.get("GITHUB_TOKEN") ?? "";
    if (!token) {
      return json({
        ok: false,
        status: "needs_human",
        reason: "GITHUB_TOKEN is not configured for the runtime.",
      }, 503);
    }

    const body = await req.json();
    const plan: Plan = {
      base_owner: body.base_owner,
      base_repo: body.base_repo,
      base_branch: body.base_branch ?? "main",
      head_owner: body.head_owner,
      head_repo: body.head_repo,
      head_branch: body.head_branch,
      issue_number: Number(body.issue_number),
      title: body.title,
      body: body.body,
    };

    const result = await submit(token, plan);
    return json(result, result.ok ? 200 : 409);
  } catch (error) {
    return json({
      ok: false,
      status: "submission_retry",
      reason: String(error),
      retryable: true,
    }, 500);
  }
});
