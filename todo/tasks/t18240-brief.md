<!-- aidevops:brief-schema=v2 -->

# t18240: Add privacy-safe attribution experiments reporting and growth recommendations

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: Performance Plane owns normalized outcomes, Reports interpretation, Content optimization/Marketing experimentation strategy, and consequential changes remain approval-bound
- [x] Discovery pass: performance schema, CRO attribution guidance, Content optimization, Reports marketing, feedback promotion, campaign results, and service owners reviewed; no open duplicate issue
- [x] File refs verified: 10 target/reference/test parent paths present or intentionally new at `45cd1150e`
- [x] Tier: `tier:thinking` — attribution windows/models, experiment validity, privacy thresholds, and recommendation authority require explicit decisions
- [x] Seeded draft PR decision recorded: skipped — depends on the actual normalized ingest schema shipped by t18236

## Origin

- **Created:** 2026-08-13
- **Session:** OpenCode interactive branded-growth planning session
- **Created by:** ai-interactive
- **Parent task:** t18230 / GH#30136
- **Blocked by:** t18236 / #30142; `blocked-by:t18236`
- **Conversation context:** Convert normalized outcomes into credible learning and growth recommendations rather than vanity-metric optimization or autonomous consequential changes.

## What

Add deterministic, privacy-safe attribution records; a versioned experiment registry and analysis pipeline; marketing performance reports/freshness checks; and evidence-ranked growth recommendations. Connect campaigns, channels, creative variants, touchpoints, conversions, leads, sales, revenue/refunds, costs, and account growth while preserving model/window assumptions, uncertainty, holdouts/controls, sample sufficiency, privacy thresholds, source provenance, and human approval for publishing, audience/offer/budget/outreach/account changes.

## Why

Normalized metrics alone do not explain causality or decide what to improve. A disciplined experimentation and reporting layer prevents overclaiming attribution, optimizing vanity metrics, leaking small-cohort data, or making high-impact changes from weak evidence.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Consequential analytical semantics and automation authority must be designed against the delivered ingest contract before implementation.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Wait for t18236's schemas and storage APIs to avoid speculative code.
- **Status:** `not-created`
- **Freshness evidence:** Current strategy/report/performance sources inspected at `45cd1150e`.
- **Verification run:** `UNVERIFIED — planning only`
- **Stale-assumption warning:** Re-read t18236 implementation and migration notes before choosing files or queries.

## How (Approach)

### Progressive Context Plan

- **Read first:** delivered Performance Plane ingest contract, `.agents/content/optimization.md`, `.agents/reports/marketing.md`, and attribution guidance in CRO chapter 2.
- **Load only if:** recommendations target ads/email/outreach/product, then load the relevant domain owner for guardrails and approval boundaries.
- **Why:** Separate deterministic measurement/analysis from domain judgment and mutation authority.
- **Stop when:** Attribution semantics, experiment schema, privacy/statistical validity, report freshness, recommendation evidence, approvals, and replay are testable.

### Worker Quick-Start

```bash
rg -n 'attribution|window|control|experiment|confidence|significance|sample|variant' .agents/marketing-sales/cro-chapter-02 .agents/content/optimization.md .agents/reports/marketing.md
rg -n 'metric.id|baseline|experiment_variant|confidence|source_ref' .agents/aidevops/performance.md
```

### Files to Modify

- `NEW: .agents/schemas/marketing-attribution.schema.json` — touchpoint→outcome credit with model/window/version/uncertainty.
- `NEW: .agents/schemas/marketing-experiment.schema.json` — hypothesis, variants, assignment/control, guardrails, sample, analysis, decision.
- `NEW: .agents/schemas/growth-recommendation.schema.json` — evidence, expected impact, confidence, owner, approval, retest, status.
- `NEW: .agents/scripts/marketing-optimization-helper.py` — attribute/experiment/report/recommend/status commands.
- `EDIT: .agents/aidevops/performance.md` — attribution/experiment/report projection and compatibility.
- `EDIT: .agents/content/optimization.md` — consume evidence and define creative/channel iteration handoff.
- `EDIT: .agents/reports/marketing.md` — canonical report contents, freshness, caveats, and decision outputs.
- `EDIT: .agents/aidevops/feedback/mining-promotion.md` — promote validated learning/recommendations without raw private evidence.
- `NEW: .agents/scripts/tests/test-marketing-optimization.py` — deterministic attribution/experiment/privacy/recommendation fixtures.
- `NEW: .agents/scripts/tests/fixtures/marketing-optimization/` — synthetic journeys, controls, refunds, costs, and sparse cohorts.

### Complete Write Surface

- **Callers/readers:** `contract:` Performance CLI/data, Campaigns, Content optimization, Marketing-Sales, Product growth, Reports, routines, final orchestrator.
- **Writers/mutation paths:** `contract:` Attribution projections, experiment registry/results/decisions, report drafts/published bundles, recommendation records, promoted learnings.
- **Tests/fixtures:** `contract:` New hermetic journeys/experiments suite; performance ingest fixtures are upstream inputs.
- **Schemas/config:** `contract:` Three new schemas, versioned attribution model/window config, privacy/minimum-sample policy.
- **Generated/deployed mirrors:** `contract:` `.agents/` deployment; reports follow `_reports/drafts`→review→published contract; private raw evidence stays out.
- **Migrations/backfills:** `contract:` Recompute projections from normalized immutable events when model/window version changes; never mutate historical source events.
- **Cleanup/rollback paths:** `contract:` Drop/rebuild derived projections and reports; retain model version and prior decision audit; recommendations can be superseded, not erased.

### Implementation Steps

1. Define deterministic attribution inputs/outputs and support at least direct/last-touch plus control/experiment evidence where available; every result carries model/window/version and non-causal caveat unless design justifies causality.
2. Define experiment lifecycle: draft→approved→running→analysis_ready→decided→archived, with stable hypothesis/variants, assignment unit, primary/guardrail metrics, sample/window, exclusions, stopping policy, and owner.
3. Implement attribution and experiment analysis over normalized synthetic fixtures, including delayed conversion, refunds, costs, cross-device/unknown identity, missing touchpoints, and concurrent campaigns.
4. Apply minimum cohort/sample, suppression, and aggregation thresholds; prohibit individual-level report/recommendation output.
5. Generate freshness-aware reports for reach, engagement, account growth, traffic, conversion, leads/stages, sales, revenue/refunds, costs, ROI/payback where valid, and source/coverage caveats.
6. Generate recommendations only when evidence records the observed problem/opportunity, target metric, expected impact range, confidence, owner, required approval, rollback, and retest date.
7. Route creative/channel recommendations to existing owners. Never autonomously publish, message, change budgets/audiences/offers, or alter provider accounts.
8. Test no-data, sparse cohort, contradictory metrics, novelty/seasonality, sample peeking, refund correction, stale source, replay, model-version recompute, and recommendation supersession.

### Hazards and Compatibility

- **Concurrency/atomicity:** Experiment assignments/decisions and projection builds require run/version IDs and atomic publish; concurrent analyses cannot overwrite newer decisions.
- **Migration/rollback:** Derived attribution/report projections are rebuildable by model version; source events and decision audit remain immutable.
- **Mixed-version/backward compatibility:** Existing performance records without attribution remain reportable as unattributed; new schemas reject unsupported writes.
- **Idempotency/retry:** Same source snapshot+model version yields same projection/analysis; rerun creates no duplicate recommendation.
- **Partial failure/recovery:** Per-report/experiment failure leaves previous published report and valid projections intact; stale status is explicit.

### Verification Before Dispatch

```bash
python3 -m unittest .agents/scripts/tests/test-marketing-optimization.py
python3 -m json.tool .agents/schemas/marketing-attribution.schema.json >/dev/null
python3 -m json.tool .agents/schemas/marketing-experiment.schema.json >/dev/null
python3 -m json.tool .agents/schemas/growth-recommendation.schema.json >/dev/null
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Synthetic journeys prove credit, refunds/costs, windows, identity uncertainty, experiments, privacy thresholds, replay, reports, and approval-safe recommendations; schema/lint cover contracts/docs.
- **Broad verification trigger:** Run upstream performance-ingest suite because this phase consumes its schemas; broader provider suites are unnecessary unless adapters change.

### Recoverability Checkpoint

- [ ] Focused tests pass: marketing optimization suite and upstream performance-ingest suite
- [ ] WIP commit created before broad gates: `wip: add attribution experiments and growth recommendations`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Produce privacy-safe, evidence-ranked growth learning and recommendations.
- **Preserved user directions:** Improve reach, conversion, brand accounts, leads, and sales with high-quality authentic campaigns.
- **Trigger and evidence:** `not triggered`
- **Completed and verified:** none at dispatch
- **Remaining acceptance criteria:** all below
- **Unsafe route not to repeat:** individual-level reporting, causal claims from observational correlation, or autonomous consequential mutations
- **Next safe route:** aggregate thresholds, explicit uncertainty, controlled experiments, and approval-bound recommendations
- **Resume condition:** sufficient normalized evidence or an explicit `insufficient_evidence` outcome
- **Owner and status:** dispatched worker; `not-triggered`

### Files Scope

- `.agents/schemas/marketing-attribution.schema.json`
- `.agents/schemas/marketing-experiment.schema.json`
- `.agents/schemas/growth-recommendation.schema.json`
- `.agents/scripts/marketing-optimization-helper.py`
- `.agents/aidevops/performance.md`
- `.agents/content/optimization.md`
- `.agents/reports/marketing.md`
- `.agents/aidevops/feedback/mining-promotion.md`
- `.agents/scripts/tests/test-marketing-optimization.py`
- `.agents/scripts/tests/fixtures/marketing-optimization/*`

## Acceptance Criteria

- [ ] Synthetic journeys produce deterministic, versioned attribution with explicit model/window/coverage/uncertainty and correct refund/cost adjustments.
- [ ] Experiment analysis enforces preregistered metrics/guardrails, assignment/control semantics, sample/privacy thresholds, and an explicit insufficient-evidence outcome.
- [ ] Reports distinguish reach/engagement/account growth from conversion/leads/sales/revenue and never claim causal growth from observational correlation alone.
- [ ] Recommendations cite evidence, confidence, owner, approval, rollback, and retest date; they cannot directly publish, message, spend, retarget, change an offer, or mutate accounts.
- [ ] Recomputing the same model/version/source snapshot is idempotent; changing model version preserves historical decisions and produces a new auditable projection.

## Context & Decisions

- Deterministic helpers calculate and render; Content/Marketing/Product/Reports agents interpret and prioritize.
- Optimize for business outcomes with guardrail metrics, not vanity metrics alone.
- Privacy thresholds and consent/suppression are inherited from the Performance ingest phase and cannot be relaxed here.

## Relevant Files

- `.agents/aidevops/performance.md:55-245`
- `.agents/content/optimization.md`
- `.agents/reports/marketing.md`
- `.agents/marketing-sales/cro-chapter-02/04-attribution-models.md`
- `.agents/aidevops/feedback/mining-promotion.md`
- `.agents/scripts/campaign-helper.sh:605-671`

## Dependencies

- **Blocked by:** t18236 / #30142
- **Blocks:** t18239 / #30146
- **External:** No live data/account required; synthetic fixtures and upstream normalized records are sufficient.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Research/decision | 2h | Models, windows, privacy, experiment policy |
| Implementation | 6h | Schemas, engine, reports, recommendations |
| Testing | 3h | Journeys, cohorts, refunds, replay, authority |
| **Total** | **~11h** | |
