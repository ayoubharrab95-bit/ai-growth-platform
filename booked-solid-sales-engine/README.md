# Booked Solid Sales Engine

> **AGENT START HERE:** Before changing SolidOS lead generation, planner, sources, qualification, or Source Recovery, read [SOLIDOS_LEAD_GENERATION_PLAYBOOK.md](./SOLIDOS_LEAD_GENERATION_PLAYBOOK.md) and query `solidos_control.lead_generation_playbook_snapshot()`. The database playbook is the authoritative latest operating doctrine.

Autonomous lead-research and outbound orchestration for Booked Solid Copy.

## Rules
- Discovery, research, qualification and message preparation may run autonomously.
- Personalization requires evidence + source URL.
- Companies are deduplicated by canonical domain.
- Search strategies rotate using performance, exploration and freshness.
- Google Maps export/scraping is not part of the pipeline.
- LinkedIn automation/scraping is not part of the pipeline.
- Email is a hard gate: outreach remains blocked until an approved sender is configured.
- Suppression/unsubscribe is persistent.
- Runtime data is isolated in the booked_solid Supabase schema and does not modify MoneyHunter tables.

## Runtime
- Supabase project: btubdaoqqhmxemcbstrd
- Edge Function: booked-solid-orchestrator
- Actions: health, plan

## Roadmap
Search adapters -> company research -> contact verification -> evidence qualification -> offer matching -> lead briefs -> email gate -> follow-up/reply classification -> outcome learning/revenue attribution.

No email credentials are stored in Git.
