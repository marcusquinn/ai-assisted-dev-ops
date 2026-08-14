<!-- aidevops:brief-schema=v2 -->

# t18236: Implement normalized marketing performance lead and revenue ingestion

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: Performance Plane Phase 1 shipped but directory/ingest/CLI/report phases remain deferred; canonical identity, consent/suppression, conversion/revenue, and freshness are gaps
- [x] Discovery pass: closed performance/campaign parents, KPI schema, campaign promotion, CRM/analytics/commerce/outreach docs, and reach telemetry reviewed; no open duplicate implementation issue
- [x] File refs verified: performance, campaign, feedback, provider health, service, and CLI reference surfaces present at `45cd1150e`
- [x] Tier: `tier:thinking` — canonical marketing subject identity, consent/suppression, attribution-ready event ownership, and migration must be resolved before the write surface is final
- [x] Seeded draft PR decision recorded: skipped — design synthesis must precede implementation

## Origin

- **Created:** 2026-08-13
- **Session:** OpenCode interactive branded-growth planning session
- **Created by:** ai-interactive
- **Parent task:** t18230 / GH#30136
- **Blocked by:** t18238 / #30144; `blocked-by:t18238`
- **Conversation context:** Connect reach and engagement to real conversion, account growth, lead, sale, revenue, refund, and cost outcomes with privacy-safe provenance.

## What

Complete the deferred Performance Plane directory and ingest layer for marketing. Decide and implement canonical campaign/channel/creative/touchpoint/outcome identifiers plus privacy-safe lead/contact/audience identity, consent and suppression state. Add idempotent ingestion for campaign results, social receipts/metrics, analytics conversions, CRM lead/stage events, commerce/payment revenue/refunds, outreach outcomes, and costs using provider-neutral normalized records with raw-evidence references, source freshness/coverage, quality/confidence, and reconciliation.

## Why

The KPI schema can represent results but no canonical ingest plane connects channel activity to business outcomes. Without identity, consent, provenance, and freshness contracts, optimization would compare incompatible counts or leak protected customer data.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** The worker must synthesize domain and privacy evidence to decide canonical identity/projection boundaries, migrations, and reconciliation before implementing bounded adapters.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** A seed would prematurely select identity/storage/ingest architecture.
- **Status:** `not-created`
- **Freshness evidence:** Repository and GitHub discovery completed against `45cd1150e`.
- **Verification run:** `UNVERIFIED — planning only`
- **Stale-assumption warning:** Recheck current provider/service helper implementations and any newly merged performance work before deciding files.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/aidevops/performance.md:4-28,55-107,110-245`, campaign results/promotion paths, and feedback capture/mining contracts.
- **Load only if:** selecting a source adapter, then inspect only its service doc/helper: GA4, FluentCRM, Stripe/Shopify, outreach provider, or social provider health.
- **Why:** Decide a provider-neutral event/projection contract before multiplying adapters.
- **Stop when:** Identity, consent/suppression, raw evidence, normalized event/result, directory/CLI, migration, freshness, and reconciliation decisions are recorded and testable.

### Worker Quick-Start

```bash
rg -n 'deferred|ingest|directory|source_ref|confidence|metric.id' .agents/aidevops/performance.md
rg -n 'consent|suppression|unsubscribe|lead|contact|revenue|refund|conversion|attribution' .agents/services/crm .agents/services/analytics .agents/services/payments .agents/services/ecommerce .agents/services/outreach
rg -n '_performance/marketing|results.md|promote' .agents/scripts/campaign-helper.sh .agents/aidevops/campaigns-plane.md
```

### Files to Modify

- `EDIT: .agents/aidevops/performance.md` — decide directory, identity, consent, normalized event/result, freshness, and ingest contract.
- `NEW: .agents/schemas/marketing-performance-event.schema.json` — provider-neutral touchpoint/outcome/source evidence.
- `NEW: .agents/schemas/marketing-subject.schema.json` — pseudonymous subject/account/contact/audience, consent, suppression, merge/split provenance.
- `NEW: .agents/scripts/performance-helper.py` — init/ingest/list/status/reconcile/export commands.
- `EDIT: .agents/scripts/commands/performance.md` — user/agent CLI contract and safety guidance.
- `EDIT: .agents/scripts/campaign-helper.sh` — emit/ingest schema records instead of only copying result prose.
- `NEW: .agents/scripts/performance_adapters/` — bounded provider-neutral adapters selected after design; likely campaign, social, analytics, CRM, commerce/payment, and outreach modules.
- `NEW: .agents/scripts/tests/test-marketing-performance-ingest.py` — schema, identity, consent, dedup, freshness, reconciliation, and source fixtures.
- `NEW: .agents/scripts/tests/fixtures/marketing-performance/` — synthetic provider exports/events without real identifiers.

### Complete Write Surface

- **Callers/readers:** `contract:` Campaign launch/results, social provider receipts/health, Content optimization, Marketing-Sales, Product analytics/growth, Reports, later attribution/experiment phase.
- **Writers/mutation paths:** `contract:` `_performance/marketing/` raw-reference/projection records, ingest state/cursors, subject/consent/suppression projections, campaign result promotion, source reconciliation.
- **Tests/fixtures:** `contract:` New hermetic multi-source suite and existing campaign status tests; provider adapters use synthetic fixtures.
- **Schemas/config:** `contract:` Two new schemas, Performance Plane directory/config/version, metric schema compatibility.
- **Generated/deployed mirrors:** `contract:` `.agents/` deployment; `_performance/` is user data and must follow git/sensitivity policy; no private source data in public issues/tests.
- **Migrations/backfills:** `contract:` Existing manual `results.md` and Phase-1 schema remain readable; explicit import/backfill with checkpoint and dry-run; no automatic contact identity merge.
- **Cleanup/rollback paths:** `contract:` Append-only raw evidence refs, rebuildable projections, cursor/checkpoint rollback, subject merge/split audit, and source-specific replay.

### Implementation Steps

1. Inventory actual executable provider helpers and choose the minimal initial adapters; mark documentation-only providers as unavailable rather than pretending ingest exists.
2. Decide data ownership: immutable/pseudonymous source subjects and touchpoints, versioned identity links, consent/suppression ledger, append-only source evidence refs, rebuildable normalized projections.
3. Extend the Phase-1 result schema compatibly or define event→result projection with clear metric/unit/dimension rules for impressions, engagement, followers/subscribers, visits, conversions, leads/stages, sales, revenue/refunds, costs, and derived ratios.
4. Define `_performance/marketing/` layout, schema/config versions, per-source cursors/freshness/coverage, quarantine, and migration/repair.
5. Implement dry-run/validate/ingest/reconcile/status with stable source event IDs and source+account isolation.
6. Implement initial fixture adapters for campaign/manual, social receipt/metric, analytics, CRM, commerce/payment, and outreach classes where local executable surfaces exist; keep secrets and raw PII outside normalized/public outputs.
7. Enforce consent/suppression before audience/export consumers and preserve lawful-basis/source/time evidence; measurement ingest must not itself perform outreach or targeting.
8. Test late/duplicate/out-of-order events, refunds, currency/period semantics, identity merge/split, suppression changes, missing scopes, stale/partial sources, replay, corrupt checkpoints, and projection rebuild.

### Hazards and Compatibility

- **Concurrency/atomicity:** Per-source leases/checkpoints and append-before-project ordering prevent lost/duplicated observations.
- **Migration/rollback:** Back up schema/config/state; raw source evidence remains immutable; projections are rebuilt after rollback.
- **Mixed-version/backward compatibility:** Phase-1 result records and manual campaign result files remain readable; schema versions reject unsupported writes.
- **Idempotency/retry:** Stable source/account/event keys deduplicate replay; late corrections/refunds append compensating records rather than overwrite history.
- **Partial failure/recovery:** Commit source cursor only after durable raw reference and normalized projection; per-source partial status preserves successful siblings.

### Verification Before Dispatch

```bash
python3 .agents/scripts/tests/test-marketing-performance-ingest.py
python3 -c 'import json; from pathlib import Path; json.loads(Path(".agents/schemas/marketing-performance-event.schema.json").read_text()); json.loads(Path(".agents/schemas/marketing-subject.schema.json").read_text())'
bash .agents/scripts/tests/test-campaign-status-routing.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Multi-source fixtures prove schema/identity/consent/dedup/freshness/recovery; campaign suite protects result promotion; schema/lint validate docs/CLI/modules.
- **Broad verification trigger:** Run provider-specific adapter tests only for adapters actually implemented; full repository gate only if shared data-plane or CLI root routing changes.

### Recoverability Checkpoint

- [x] Focused tests pass: marketing performance ingest suite (12 tests)
- [x] WIP commit created before broad gates: `wip: add marketing performance ingest`
- [x] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Normalize privacy-safe marketing/business outcomes for analysis.
- **Preserved user directions:** Maximize reach, conversion, account growth, leads, and sales through evidence, not unverifiable claims.
- **Trigger and evidence:** `not triggered`
- **Completed and verified:** none at dispatch
- **Remaining acceptance criteria:** all below
- **Unsafe route not to repeat:** ingesting live private customer data into tests/public git or merging identities without evidence
- **Next safe route:** synthetic fixtures, pseudonymous IDs, dry-run, quarantined source records, and explicit migration checkpoints
- **Resume condition:** identity/privacy/source contract and fixture evidence are decided
- **Owner and status:** dispatched worker; `not-triggered`

### Files Scope

- `.agents/aidevops/performance.md`
- `.agents/schemas/marketing-performance-event.schema.json`
- `.agents/schemas/marketing-subject.schema.json`
- `.agents/scripts/performance-helper.py`
- `.agents/scripts/commands/performance.md`
- `.agents/scripts/campaign-helper.sh`
- `.agents/scripts/performance_adapters/*.py`
- `.agents/scripts/tests/test-marketing-performance-ingest.py`
- `.agents/scripts/tests/fixtures/marketing-performance/*`

## Acceptance Criteria

- [ ] Synthetic campaign, social, analytics, CRM, commerce/payment, and outreach fixtures ingest into schema-valid source-isolated events/results with provenance, freshness, and stable deduplication.
- [ ] Lead/contact/audience identity is pseudonymous and auditable; consent/suppression state is source- and time-bound, and suppressed subjects cannot become eligible audience exports.
- [ ] Duplicate, late, out-of-order, correction, refund, and replay events converge without double-counting or destructive history rewrites.
- [ ] Missing scopes, stale/partial sources, invalid units/currencies, and identity ambiguity remain explicit and never yield verified metrics.
- [ ] Existing Phase-1 result records and manual campaign result promotion remain backward compatible.

## Context & Decisions

- Performance Plane owns normalized outcomes; source services own provider details; Reports interpret; later phase owns attribution/experiments.
- Measurement authority does not imply outreach, targeting, spend, account mutation, or publishing authority.
- Keep raw private data in authorized source stores; normalized records use bounded references/pseudonymous identities.

## Relevant Files

- `.agents/aidevops/performance.md:4-28,55-107,246-257`
- `.agents/scripts/campaign-helper.sh:532-671`
- `.agents/aidevops/feedback/mining-promotion.md`
- `.agents/services/analytics/google-analytics.md`
- `.agents/services/crm/fluentcrm.md`
- `.agents/services/payments/stripe.md`
- `.agents/services/ecommerce/shopify.md`
- `.agents/services/outreach/smartlead.md`

## Dependencies

- **Blocked by:** t18238 / #30144
- **Blocks:** t18240 / #30147
- **External:** Live provider credentials/data are optional runtime gates; implementation uses synthetic fixtures.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Research/decision | 2h | Identity, privacy, storage, source inventory |
| Implementation | 8h | Plane, CLI, adapters, migration/recovery |
| Testing | 3h | Multi-source temporal/identity matrix |
| **Total** | **~13h** | |
