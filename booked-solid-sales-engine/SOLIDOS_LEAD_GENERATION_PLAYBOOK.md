# SolidOS Lead Generation Operating Playbook

> **AGENT START HERE**
>
> Before changing SolidOS planner, source routing, qualification, Source Recovery, or lead-generation behavior, first run:
>
> `select solidos_control.lead_generation_playbook_snapshot();`
>
> Then inspect the live `system_snapshot()`, pipeline pressure, Source Recovery, Source Lead Yield, and recent hourly flow.

## Core operating principle

Optimize for **valid Leads → Qualified → HOT/HIGH** with fast flow. Keep **hard safety strict**, but make routing, source mix, exploration, and capacity **adaptive/soft rather than hard-stopping**.

The known safe recovery baseline at the time this playbook was recorded is:
- Orchestrator **v58**
- Worker **v114**
- Phoenix/Mesa Building Permits + Washington L&I as the most productive observed source families
- Socrata deterministic page rotation enabled

This is a **rollback reference**, not a permanent version freeze. Newer behavior may replace it only after live evidence proves it performs better safely.

## What produced the best lead flow

The strongest observed Phoenix window produced:
- 17 new companies
- 3 valid Leads
- 3 Qualified
- 2 HOT/HIGH

At playbook creation, Phoenix source history was:
- 52 sampled companies
- 14 valid Leads
- 5 Qualified
- 3 HOT/HIGH

After Socrata page rotation was added, **2 jobs produced 8 new companies**, followed by **4 new Leads in about 2 minutes**.

### Proven source policy

Production discovery may use **ALLOWED** sources only.

Known strong source families:
- `auto-socrata-building-permits-dzpkhxfb` — Phoenix/Mesa — Champion exploit
- `auto-socrata-l-i-intent-project-details-t9je9qwa` — Washington/Seattle — Champion exploit

`REVIEW_REQUIRED`, `BLOCKED`, and `INTERNAL_ONLY` sources must not create production discovery jobs.

For source authority, **Source Recovery v2.2 is newer than stale legacy source-brain/lifecycle labels**. An ALLOWED Champion with healthy technical reliability, zero consecutive errors, and no cooldown must not be silently excluded merely because an older layer still says blocked/degraded.

## Anti-stall routing rule

Never select only the top N strategies **before** checking whether they can actually route.

Correct behavior:
1. Oversample high-quality strategy candidates.
2. Test safe source + market compatibility.
3. Skip/reroute unroutable candidates.
4. Continue until the requested number of safe jobs is filled.
5. Preserve exploit/explore intent.

If the planner cron is succeeding, pressure is zero, workers are healthy, but discovery becomes zero, inspect:
- `routing_candidates`
- `routable_candidates`
- rights/lane precedence
- stale source classification

Do **not** immediately tighten more rules.

## Socrata scanning rule

Do not repeatedly read only the first page.

Use deterministic page rotation based on:
- source
- trade
- geography
- strategy
- time bucket

This lets parallel jobs inspect different safe pages without a shared cursor race. If an offset page is empty, fall back safely to page 0.

Before declaring a previously productive source exhausted, check pagination/duplicate saturation first.

## Flow-control rule

When pressure is healthy, the planner target is **3 discovery jobs per planning cycle**.

Always respect:
`solidos_control.lane_capacity_plan()`

When Resolve/Research/Qualify backlog rises:
- let downstream drain;
- allow throttle to slow the burst;
- do not force more Discovery;
- do not let throttle become a permanent stop.

If `pg_net` requests accumulate while no fresh responses arrive and the pg_net worker is active, use the official:
`select net.worker_restart();`
once, then inspect dispatch volume. Do not keep stacking extra requests.

## Quality guards that must remain

Keep:
- website identity/geography mismatch rejection;
- contact parser protection against UI/page-fragment fake names;
- trade/strategy attribution validation;
- no sticky Qualified status;
- suppressed/rejected exclusion from Source Yield;
- duplicate/orphan/stale-running checks;
- production source-rights gate.

Keep OFF unless explicitly approved:
- email outreach
- SMS
- buyer outreach
- paid search
- personal PII export

## Do not over-tighten SolidOS

Avoid hard gates that can stop all discovery when a soft/adaptive policy would work.

Do not:
- treat every imperfect metric as a reason to block a source;
- let stale legacy metadata overrule a newer verified recovery layer;
- judge a source only by raw company count;
- reduce exploration to zero;
- disable a proven source after one duplicate-heavy window without checking pagination;
- call a change successful merely because cron says “succeeded.”

## Metrics every future agent must check

Before and after strategy changes, compare:
- Companies/hour
- Valid Leads/hour
- Qualified/hour
- HOT/HIGH changes
- company→Lead latency
- source sample→Lead→Qualified→HOT/HIGH yield
- routing candidates vs routable candidates
- due/running/stale/failed queue counts
- arrival/completion ratio
- throttle/pause
- pg_net queue + response freshness
- duplicates/orphans
- Core/Commercial/Revenue sheet freshness

## Change protocol

**Before:** read the database playbook and current live metrics.

**During:** make small canary/adaptive changes. Preserve the proven baseline as rollback reference.

**After:** require real production evidence:
- routable Discovery jobs;
- new unique companies;
- downstream Resolve/Research/Qualify progress;
- valid new Leads.

**Rollback trigger:** if Companies/Leads materially stop while pressure and workers remain healthy, undo the latest restrictive routing/source change or convert it to soft/adaptive behavior.

The database copy of this document is authoritative for the latest version:
`select solidos_control.lead_generation_playbook_snapshot();`

## Automatic discovery by future chats

`solidos_control.system_snapshot()` now exposes an `operating_playbook` object containing the required flag, current playbook version, read function, and GitHub path. Any future agent that performs the normal SolidOS health check should therefore discover this playbook automatically before changing lead generation.

## Continuous Lead Flow v2

The current proven recovery baseline is **Orchestrator v59 + Worker v116**.

A recurring “works, adds leads, then appears to stop” pattern was traced to multiple interacting bottlenecks rather than a single scoring problem:

- productive Socrata pages were being revisited after the small rotation window saturated;
- Nominatim cooldown could defer otherwise usable companies for 15–20 minutes;
- Resolve capacity reacted too slowly to bursts;
- pg_net worker calls could accumulate while the worker appeared active;
- event-driven dispatch and the 1-minute worker cron could amplify the same stalled pg_net queue.

Current doctrine:

1. **Persistent atomic Socrata cursor.** `booked_solid.source_scan_state` + `booked_solid.claim_source_scan_page(...)` assign sequential pages to parallel jobs. Default scan depth is 60 pages. Do not replace this with a small hash-only page rotation.
2. **Nominatim is enrichment, not a hard gate.** If an ALLOWED source already provides useful city/state, a Nominatim cooldown must not freeze the company. Continue immediately to qualification fallback using source evidence; identity/geography and qualification thresholds remain unchanged.
3. **Resolve burst capacity.** When Resolve due>=3 or oldest>75s, allocate 2–5 workers; if oldest>180s or arrivals exceed completions, allocate 3–6 workers, within the global cap of 12.
4. **pg_net watchdog.** `solidos_control.pgnet_watchdog()` runs every minute. A stall is 2+ queued worker calls with no fresh pg_net response for >=75s; recover with the official `net.worker_restart()`, with restart cooldown.
5. **Queue guards on both dispatch paths.** Cron and event-driven dispatch must not add worker calls into a stalled queue. Event dispatch remains enabled for speed while healthy; cron provides eventual pickup.
6. **Productive exploration.** Explore strategy ideas mostly on proven/testing sources. Keep true source exploration small; mature zero-yield sources must not consume a large share of Resolve capacity.

Live acceptance after these changes produced new leads automatically, including **LYNDEN SHEET METAL INC** as Qualified (score 70, trigger 35) in about **4.81 minutes**, and **DIMENSIONAL COMMUNICATIONS INC** as a new Candidate in about **2.95 minutes**, without manual worker dispatch.

If flow becomes bursty again, inspect **cursor progress → Nominatim deferrals → Resolve backlog → pg_net response age/queue → event+cron dispatch amplification** before changing scoring thresholds or source safety gates.

## Source exploration cycle guard (v3)

A planner cycle may contain **at most one mature zero-yield source job**. Extra mature zero-yield routed candidates are skipped and replaced by the next safe routable Proven/Testing candidate. This preserves source learning without allowing zero-yield exploration to consume most of the Resolve pipeline.

Acceptance evidence after the continuity fixes included **3 KINGS ENVIRONMENTAL INC → Qualified + HOT**, score 96, Opportunity 80, Trigger 40, from Washington L&I.
