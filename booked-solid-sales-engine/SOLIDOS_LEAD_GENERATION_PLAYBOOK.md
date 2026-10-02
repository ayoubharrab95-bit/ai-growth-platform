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

## Stability Charter v4 — preserve the working system

**Future chats/agents must start with:**

`select solidos_control.future_chat_bootstrap();`

This is the read-only startup context for SolidOS. It returns the operating playbook, current system health, rolling 15m/30m/60m flow, pipeline pressure, Strategy Brain + AutoPilot + Portfolio, Source Recovery, pg_net runtime health, and persistent source cursor state.

### Known-good runtime baseline

- Orchestrator **v60**
- Worker **v116**
- Qualifier **v20**
- Sheet Sync **v23**
- Revenue CRM Writer **v1**

This is a rollback/reference baseline, not a permanent freeze. Replace it only after a newer change is verified with real production evidence.

### Stability rules

1. **Preserve first, optimize second.** Do not change planner/source/qualifier/worker behavior because of a short-term fluctuation.
2. **One change at a time.** Changes must be reversible, small, and canary-first.
3. **Use rolling evidence.** Compare 15m/30m/60m Companies, valid Leads, Qualified, HOT/HIGH, and latest valid Lead before declaring a stall.
4. **Backpressure is not failure.** A short pause/throttle while downstream drains is normal if completions continue and the planner resumes automatically.
5. **Diagnose in order:** rolling flow → pressure/backlog → pg_net → source cursor → Nominatim deferrals → lane capacity → source mix → only then code/scoring.
6. **Do not touch without evidence:** scoring thresholds, identity/geography guards, ALLOWED-only rights gate, persistent cursor, Nominatim enrichment policy, pg_net watchdog/queue guards, adaptive capacity, mature zero-yield cycle cap, or safety flags.
7. **Rollback before layering fixes.** If a new change causes a real stall or material quality degradation, revert that change before adding another modification.

### Current learning

The strongest behavior so far comes from productive Champion sources, persistent pagination, soft/adaptive routing, fast downstream draining, and strict identity/rights safety — **not from adding more hard gates**.

### Definition of a real stall

Treat the system as genuinely stalled only when valid Leads/new companies materially stop across sustained rolling windows **or** queues stop draining/responding. A momentary pause with healthy completion flow is normal operating behavior.

## Stability Audit v5

Current known-good runtime after the latest production audit:

- Orchestrator **v61**
- Worker **v116**
- Qualifier **v20**
- Sheet Sync **v23**
- Revenue CRM Writer **v1**

Verified audit fixes:

1. The pg_net watchdog used the invalid severity literal `WARNING` while `health_events` accepts only `INFO/WARN/ERROR`. It now records auto-restart events as `WARN`.
2. Orchestrator race-prone single-row mutations now use `maybeSingle()` with safe zero-row fallbacks. This removes avoidable `PGRST116` failures during concurrent queue activity without changing lead-generation logic.

Production integrity at audit time was clean: no active duplicate jobs/domains, no orphan Leads/Contacts/Evidence, no Qualified rows below threshold, no HOT-rule violations, no suppressed selected contacts, no contact-name noise, no non-ALLOWED exploit routing, and no OSM production jobs.

**Do not tune scoring, source-rights rules, or lane capacity based on this audit.** The system was actively producing Leads and Qualified prospects. Preserve v61/v116 unless rolling live evidence proves a specific regression.

## Decision Maker Intelligence — Worker v118

Decision-maker extraction is intentionally **precision-first**. Do not inflate coverage by accepting uncertain names.

Current rules:
- reject UI/CTA text such as `Read More`, `Learn More`, `View More`, `Click Here`, and similar labels;
- reject role/page-fragment tokens inside a proposed name, including COO/CFO/Secretary/Vice/Finance/Qualifications/Scheduler/Superintendent and related terms;
- reject honorific-only partial names such as `Mr. Lane`;
- reject ordinary four-token candidates unless the fourth token is a recognized suffix (Jr/Sr/II/III/IV);
- reject candidate names that substantially duplicate the company identity;
- if a false person name was attached to a valid direct email/phone, preserve the contact route and remove only the false identity.

Cleanup acceptance: 28 obvious false-person records were identified, 3 valid contact routes were preserved, 25 pure false contacts were suppressed, 8 Qualified leads were revalidated, and the final audit showed **0 suspicious decision-maker names** and **0 company-name-as-person cases**.

Future rule: if a human name cannot be verified, keep the useful contact route and set `decision_maker_known=false`. Accuracy is more important than an artificially high decision-maker count.

## Decision Maker Role Display v7

Decision Maker identity and job title are separate fields throughout the user-facing CRM/revenue views.

Rules:
- show the person name only when `contact_resolution.decision_maker_known=true`;
- show `decision_maker_role` in a separate **Role / Title** column;
- never concatenate title text into the person name;
- if no verified Decision Maker exists, leave the name/title blank while preserving any valid company/direct email or phone route.

Current display coverage:
- ACTION QUEUE — Decision Maker / Contact + Role
- QUALIFIED 360 — Decision Maker + Role
- ALL LEADS — Decision Maker + Role / Title
- CONTACT GAPS / CONTACTS — separate name and role fields
- REVENUE DESK — Decision Maker + Role / Title
- BEST TARGETS — Decision Maker + Role / Title

Verified examples include **Marcus Kuhlmann — Founder**, **Gayland Looney — Owner**, **Dennis Porter — President**, and **Matt Campbell — Principal**.

Known-good sheet baseline: **Sheet Sync v25 + Revenue CRM Writer v4**. This is display-only; scoring, qualification, source routing, contact extraction, and outreach remain unchanged.

## Sheet Quota Guard + Brain Rollback Hold v8

A real Google Sheets quota incident occurred at **2026-10-02 12:47 UTC**: CORE_CRM hit the per-user write-request limit. The failure was caused by overlapping Core/Commercial sheet activity and high-frequency fast dispatch, not by bad CRM data.

Current sheet safeguards:
- `claim_solidos_sheet_sync()` is globally serialized with a Postgres advisory transaction lock;
- only **one** sheet scope may be RUNNING at a time across CORE_CRM and COMMERCIAL_PRODUCTS;
- enforce a **60-second global cooloff** after a completed sheet sync before another scope can start;
- fast Core event dispatch uses a **60-second bucket** (cron fallback remains every minute);
- health events use valid severity `WARN` rather than `warning` / `WARNING`.

Acceptance after the guard: **0 overlapping writers**, observed start gap **118 seconds**, **0 new quota/429 failures**, and a Commercial Products sync completed and verified successfully.

### Failed experiment to remember

A broad batching refactor was deployed briefly as platform Sheet Sync **v26** and failed at function boot before any writes. It was immediately rolled back. The active platform deployment is **v27**, using the known-good v25 source hash plus the database-level serialization/quota guards above. Do not retry the v26 batching refactor directly without offline compile/test.

### Strategy Brain rollback hold

Strategy Brain is intentionally at **15%** after Auto-Rollback. Stable pct is 15%, and the rollback hold runs until **2026-10-03 00:07 UTC**. Do **not** manually ramp during the hold. Canary performance was below Legacy in the post-rollback sample, and the rollback was triggered by real pipeline/SLA pressure. Let AutoPilot evaluate after the hold and only ramp when health and sample gates pass.

## Courtney Sales Desk v9

The first Google Sheets tab, **START HERE — COURTNEY**, is now the live **COURTNEY — SOLIDOS SALES DESK**.

Architecture: it is **formula-driven from existing synced tabs** and intentionally has **no dedicated cron or writer**. This preserves Google Sheets quota headroom and keeps the sales desk synchronized automatically whenever upstream SolidOS tabs refresh.

Live sources:
- COMMAND CENTER
- ACTION QUEUE
- REVENUE DESK
- CONTACT GAPS

Live KPI strip:
- ACT NOW
- REVIEW
- HOT
- HIGH
- NEEDS DECISION MAKER

The live priority table shows the **Top 10 HOT/HIGH prospects from ACTION QUEUE ordered by Opportunity**, with Company, Priority, Opportunity, Decision Maker, Role / Title, Email, Phone, Why Now, Offer, and Action.

Courtney workflow shown directly on the page:
1. Verify the company/website.
2. Check Decision Maker + Role + contact route.
3. Use Why Now as the personalization clue.
4. Pitch one relevant offer.
5. Record review/follow-up in ACTION QUEUE.

Important stability rule: **do not add a separate Courtney Sales Desk cron/writer unless formulas become insufficient**. The current formula-driven design creates no new recurring Google write load.

## Courtney Sales Desk — Priority vs Readiness (v9)

The tab **START HERE — COURTNEY** is a live sales work surface updated by the existing CORE_CRM Sheet Sync. Do **not** create a separate Courtney cron/writer.

Keep these concepts separate:
- **Priority** = lead strength: HOT / HIGH / SIGNAL / STANDARD.
- **Readiness** = revenue action state: ACT NOW / REVIEW / ENRICH / WATCH.

Courtney's work order is:
1. Readiness first: **ACT NOW → REVIEW → ENRICH/WATCH**.
2. Within the same Readiness, work **HOT before HIGH**.
3. Then use Opportunity, Decision Maker, Why Now, Offer, and Action to decide the outreach angle.

The live worklist columns are:
**Company | Priority | Readiness | Opportunity | Decision Maker | Role / Title | Email | Phone | Why Now | Offer | Action**.

Ranking is by Readiness, Revenue Score, Priority, then Opportunity. Decision Maker/Role appear only when verified. A general company inbox is a route, not automatically that named person's personal email.

Acceptance: CORE_CRM request 18579 completed SUCCEEDED under Sheet Sync **v28**, verified the Courtney tab, and wrote 10 live priority rows with the new Readiness column.

## Courtney Sales Desk Priority Semantics v9

Do not use an ambiguous single `Priority` label on the Courtney sales dashboard.

Two distinct systems are shown and must remain separate:

- **Lead Strength:** HOT / HIGH / SIGNAL / STANDARD — how strong the lead is.
- **Sales Readiness:** ACT NOW / REVIEW / ENRICH / WATCH — what Courtney should do with it now.

Courtney's work order is: **Sales Readiness first, then Lead Strength within the same readiness tier.** A HOT lead is not automatically "contact now" if its Sales Readiness is still ENRICH or WATCH.

The START HERE — COURTNEY page now shows the full live distribution for both systems and uses the explicit columns **Lead Strength** and **Sales Readiness**. This is a display/interpretation improvement only; scoring thresholds, source routing, qualification, outreach, and worker capacity are unchanged.

Known-good Sheet Sync deployment for this behavior: **v30**.

## Courtney Sales Desk Completeness v10

The Courtney Sales Desk must never make the priority picture look incomplete.

- **Lead Strength** always uses HOT / HIGH / SIGNAL / STANDARD and must sum to total Qualified.
- **Sales Readiness** uses ACT NOW / REVIEW / ENRICH / WATCH.
- Newly Qualified leads that have not yet received Revenue Intelligence scoring are shown explicitly as **PENDING SCORE** rather than disappearing from the readiness totals.
- PENDING SCORE means “awaiting revenue scoring,” not “weak lead.”
- Work order remains: **Sales Readiness first, then Lead Strength within the same readiness tier.**

Known-good Sheet Sync for this behavior: **v31**.

## Production Audit and Stability v11 — 2026-10-02

This is the current verified baseline; earlier version entries describe historical recoveries:
- Orchestrator v61; Worker v122; Qualifier v20; Sheet Sync v35; Revenue CRM Writer v4.
- Brain runtime/stable 15%. Rollback hold until 2026-10-03T00:07:00.177904Z. Let AutoPilot decide after hold, health and sample gates.
- Source rights and safety flags remain unchanged. OSM remains REVIEW_REQUIRED technical recovery only.

Verified fixes, separately canaried:
1. Lead status changes cancel only ready/blocked draft outreach for leads that leave qualified/sent/replied/meeting/won. Reconciled 10 stale drafts; qualified drafts preserved. Two database migrations record canary and promotion.
2. Contact-form extraction rejects static assets, technical/login paths and external URLs. One live contact canary plus five repairs completed; six bad CSS links removed without dropping usable routes.
3. Internal Worker qualification uses the standalone Qualifier's established trade/strategy compatibility rule. Learning uses validated attribution. Corrected 49 remaining mismatches (19 Qualified) without changing their status/score/priority; previous IDs retained in lead_brief.strategy_attribution_correction_v1. The separate qualification canary re-scored one Candidate from61 to59 through normal qualification.
4. ACTION QUEUE, QUALIFIED 360 and CONTACT GAPS show person name/role only when decision_maker_known=true; email/phone routes remain independent. CORE_CRM canary request19796 succeeded. Manual fields for all95 Lead IDs matched before/after.
5. Courtney order is Sales Readiness first, then Lead Strength, then Revenue Score and Opportunity. A real HIGH-before-HOT ACT NOW row ordering bug demonstrated that the old score-first sort violated the intended work order. The narrow display fix was fixture-tested and verified through existing CORE_CRM.

Source outcomes at16:20 UTC (first-seen source; current status; rejected/suppressed excluded): Washington138 valid/38 Qualified/11 HOT+HIGH; Phoenix30/5/3; OSM125/43/14 historical. Historical OSM yield does not authorize new production use. Phoenix had no discovery jobs in the last measured3h while Washington had165; propose a small compatible-pair exposure canary after stability, not a speculative global allocation change.

Measurement cautions:
- 15/30/60 Qualified by Lead creation time is a currently-qualified creation cohort, not qualification event throughput.
- Attribution repairs can alter strategy-derived historical Brain metrics. Do not claim Brain gains or infer historical causality from mutable attribution.
- Historical strategy counters may contain stale attribution; rebuild only from auditable event provenance. Do not reset them speculatively.
- Node syntax/fixture tests are not a complete Deno typecheck; actual completed canary jobs and sheet readback were also required.
- Existing advisor findings were unchanged by DDL. No new public RLS policies or rights exceptions were introduced.
- Keep global sheet serialization/cooloff, manual fields keyed by Lead ID, pg_net guards, persistent cursor, adaptive cap12, thresholds and safety flags.

The development sequence is: observe corrected baseline; test a small Phoenix compatible-market slot; compare Qualified/HOT-HIGH and route yield per unique company and worker capacity; improve only proven latency bottlenecks; profile narrow Sheet reads offline before any batching canary; let AutoPilot govern Brain. No source mix/capacity/score optimization was deployed in this audit.

See SOLIDOS_AUDIT_AND_DEVELOPMENT_PLAN_2026-10-02.md for source comparison, acceptance checks, rollback instructions and the staged plan.

## v12 — OSM scoped internal discovery canary result

OSM remains historically strong: recent source yield showed about 125 valid leads, 43 Qualified, and 14 HOT/HIGH. I implemented the missing guard that prevents OSM/ODbL data from becoming `COMMERCIAL_SAFE` when `commercial_resale_allowed=false`; such assets are now `INTERNAL_ONLY` with resale/attribution restriction reasons.

The production canary did not pass. A single OSM Phoenix HVAC discover job `db4b065d-7887-4919-961e-e6c39f2d3223` first failed with `overpass_http_406`. Worker v124 reduced OSM discovery radius from 40km to 15km, changed Overpass timeout to 8s, capped discovery output at 25 rows, and prefers `overpass-api.de`, but the Edge Runtime still returned `overpass_http_0`. No OSM companies or leads were produced by the canary.

Keep OSM in Technical Recovery until an Edge Runtime probe succeeds. Do not re-enable OSM production discovery merely because an off-platform/local Overpass test succeeds. The next safe step is one successful Edge probe through the existing `solidos-osm-technical-recovery-probe`; only then set OSM back to an internal-only ALLOWED canary and queue one discover job.

## v13 — Source mix recovery after weak lead flow

Lead flow looked stalled while the infrastructure was healthy. The cause was source mix, not worker failure: NYC DOB produced 54 companies in the last 120 minutes with 53 rejected and 0 leads; Austin produced 6 companies with 6 rejected and 0 leads. At the same time Phoenix/Mesa Building Permits was incorrectly paused even though Source Recovery v22 classified it as an ALLOWED champion with technical reliability 100 and median company-to-lead around 2.8 minutes.

Recovery action: reactivate `auto-socrata-building-permits-dzpkhxfb` when Source Recovery says ALLOWED/champion/technical=100/zero errors, and place temporary cooldowns on reject-heavy zero-yield exploration sources such as `nyc_dob_permits` and `austin_construction_permits`. Acceptance: planner selected Phoenix/Mesa, queued 6 jobs, 3 completed quickly, and 11 Phoenix companies were created with no worker failures.

Rule: if lead flow weakens while pg_net, workers, and queues are healthy, inspect source mix before changing scoring. A champion source paused while zero-yield exploration is active is a real routing/source-state bug.
