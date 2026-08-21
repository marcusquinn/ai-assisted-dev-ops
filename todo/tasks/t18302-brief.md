<!-- aidevops:brief-schema=v2 -->

# t18302: Produce ranked local domain-opportunity reports and operating workflow

## Pre-flight

- [x] Memory recall: `domain opportunity reporting SQLite CSV analysis` → 0 hits — no relevant stored lessons.
- [x] Discovery pass: 0 commits/merged/open PRs touch the proposed reporting/docs files; five declared implementation siblings intentionally precede this task.
- [x] File refs verified: 8 existing reference paths and all planned parent directories checked at HEAD.
- [x] Tier: `tier:thinking` — final integration must reconcile five independently merged contracts, ranking semantics, missing-evidence behavior, local configuration, and parent closure.
- [x] Seeded draft PR decision recorded: skipped — integration cannot be seeded before all blockers merge.

## Origin

- **Created:** 2026-08-21
- **Session:** `opencode:interactive-2026-08-21`
- **Created by:** `ai-interactive`
- **Parent task:** `t18295` / #30492
- **Blocked by:** `t18297`, `t18298`, `t18299`, `t18300`, and `t18301`; dispatch remains blocked until every native `blockedBy` relationship is verified.
- **Conversation context:** Deliver the usable outcome: local evidence ranking and analysis packets, not a replicated website.

## What

Integrate the merged storage, auction sources, deterministic scoring, Google Ads enrichment, and optional Trends import into one documented local operating workflow. Add stable report/query commands that emit ranked CSV, JSON, and concise Markdown decision packets with score components, demand evidence, current price/deadline, provenance, freshness, missing-evidence flags, and risk annotations.

Provide no web interface. The Markdown/JSON packet should be suitable for AI DevOps or a human to generate business/monetization hypotheses, while clearly separating those hypotheses from measured fields.

## Why

Individual adapters do not create an actionable research routine. Operators need one command sequence, one local configuration model, and exports that explain why an opportunity ranks highly and what evidence is stale or absent.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** The worker must reconcile merged interfaces and choose a final evidence presentation without collapsing unknowns or relative Trends data into misleading totals. Parent closure is consequential and evidence-gated.

## PR Conventions

This is the final leaf. Its PR closes #30499. It may close parent #30492 only after GitHub confirms #30493 through #30498 are complete and all end-to-end criteria pass; otherwise use `For #30492` and leave the parent open.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** All five upstream implementation contracts must be merged and inspected first.
- **Status:** `not-created`
- **Freshness evidence:** Proposed reporting/docs paths are collision-free as of 2026-08-21.
- **Verification run:** Planning-only; end-to-end workflow does not yet exist.
- **Stale-assumption warning:** Re-run discovery and inspect every merged child CLI/store API before editing the foundation entrypoint.

## How (Approach)

### Progressive Context Plan

- **Read first:** merged `domain-opportunity-*` entrypoints, `domain_opportunity_store.py`, and each child test's CLI invocation — establish actual interfaces before integration.
- **Read next:** `.agents/seo/keyword-research.md:75-116,164-182` and `.agents/seo/backlink-checker.md:18-29,82-98` — align terminology and concise routing.
- **Load only if:** `.agents/aidevops/extension.md` — when final configuration/deployment differs from existing patterns.
- **Why:** Integrate shipped contracts rather than re-implementing providers or relying on stale brief sketches.
- **Stop when:** Unified commands, ranking view, missing-evidence semantics, local config, docs, and end-to-end fixture path are fixed.

### Worker Quick-Start

```text
No UI and no purchase authority.
SQLite remains canonical; CSV/JSON/Markdown are deterministic projections.
Measured fields retain source/unit/time; hypotheses are labelled generated/unverified.
Unknown evidence stays unknown, not zero.
Trends is batch-relative and optional; Google Ads supplies the primary demand metrics.
Do not close parent #30492 until every child is complete and end-to-end verification passes.
```

### Files to Modify

- `EDIT: .agents/scripts/domain-opportunity-helper.py` — add stable orchestration/report commands around merged modules without duplicating their implementation.
- `NEW: .agents/scripts/domain_opportunity_reporting.py` — joined queries, filters, ranking projection, CSV/JSON/Markdown rendering, and evidence freshness.
- `NEW: .agents/scripts/tests/test-domain-opportunity-reporting.py` — end-to-end fixture store and deterministic projection coverage.
- `NEW: configs/domain-opportunities-config.json.txt` — placeholder-only locale, freshness, filters, scoring-policy, paths, and source settings.
- `EDIT: .gitignore` — ignore the working config/runtime outputs only if current patterns do not already cover them.
- `NEW: .agents/seo/domain-opportunities.md` — complete local workflow, provider permissions, metrics, interpretation, recovery, and analysis guidance.
- `EDIT: .agents/seo.md` — short pointer from keyword/domain opportunity routing.
- `EDIT: .agents/seo/backlink-checker.md` — replace stale marketplace/API claims with a pointer and clarify backlink-expiry versus auction-opportunity workflows.

### Complete Write Surface

- **Callers/readers:** `.agents/seo.md`, `.agents/seo/backlink-checker.md`, and operators call `.agents/scripts/domain-opportunity-helper.py`; AI/human analysis consumes local CSV/JSON/Markdown exports.
- **Writers/mutation paths:** `.agents/scripts/domain_opportunity_reporting.py` performs read-only SQLite queries and atomic output publication; merged provider/scoring modules remain the only database writers.
- **Tests/fixtures:** `.agents/scripts/tests/test-domain-opportunity-reporting.py` builds a temporary store from merged child fixtures and checks CSV/JSON/Markdown outputs, stale/missing evidence, ranking order, and no network.
- **Schemas/config:** `configs/domain-opportunities-config.json.txt`, `.agents/schemas/domain-opportunity-record.schema.json`, Trends manifest schema, and merged scoring policy define behavior; placeholders contain no account IDs or secrets.
- **Generated/deployed mirrors:** `setup.sh --non-interactive` deploys `.agents/`; actual config, SQLite, raw imports, and exports stay local/gitignored. Documentation points to the source scripts, not deployed copies.
- **Migrations/backfills:** `.agents/scripts/domain_opportunity_store.py` remains the sole migration owner; reporting detects unsupported versions and never migrates or rewrites evidence during a read.
- **Cleanup/rollback paths:** Reverting `.agents/scripts/domain_opportunity_reporting.py` and the documentation leaves all collected data intact; atomic output failure removes only its temporary file and preserves the previous completed export.

### Implementation Steps

1. Verify every blocker is merged and inspect actual CLI/store/test interfaces. Resolve naming drift in this integration PR without duplicating provider logic.
2. Extend the core CLI with stable high-level commands such as:
   - `pipeline-status --db PATH --json`
   - `candidates --db PATH [filters]`
   - `report --db PATH --format csv|json|markdown --output FILE [--as-of UTC]`
   - `analysis-packet --db PATH --output FILE --limit N`
3. Build one joined reporting projection per domain: listing/source/current price/deadline, exact phrase and quality components, Google Ads metrics with locale/month/currency, optional Trends batch/direction/seasonality status, provider appraisal/backlink/history observations, source freshness, missing evidence, risk flags, total/policy version.
4. Sort only using the merged deterministic scoring policy and explicit tie-breakers. Never invent a single absolute Trends/Google Ads composite outside the versioned policy; expose components so users can re-rank in SQLite/CSV.
5. Render stable columns/keys and a concise Markdown packet. Hypothesis prompts/sections may request business model, target user, monetization, evidence references, assumptions, and risks, but any generated answer remains separate from measured data.
6. Add a placeholder-only config template for default locale, geo/language resources, account aliases (not IDs), freshness windows, hard filters, paths, and report fields. Document `aidevops secret set` names without secret examples.
7. Write the SEO guide with setup, source permission matrix, commands, local paths, scheduling suggestion, metric definitions/limitations, browser-assisted Trends handoff, failure recovery, analysis checklist, and explicit non-goals.
8. Update `.agents/seo.md` and `backlink-checker.md` with short progressive-disclosure pointers; do not put the full workflow into always-loaded guidance.
9. Add an end-to-end fixture test and run a production report against a temporary/local smoke DB. Confirm no network, browser, credentials, or purchase path is required.
10. Verify all child/parent issue states. Close the parent only if every child and parent acceptance criterion is demonstrably complete.

### Hazards and Compatibility

- **Concurrency/atomicity:** Reports use a consistent read transaction/snapshot; output publishes atomically so concurrent adapter writes cannot create half-rendered files.
- **Migration/rollback:** Reporting is read-only and rejects unsupported future stores. Reverting it does not migrate or delete data/config.
- **Mixed-version/backward compatibility:** Missing optional child tables/fields produce explicit unavailable status where safe; required foundation incompatibility fails with an actionable version message.
- **Idempotency/retry:** Same database snapshot, `as-of`, config, and format produce deterministic output; retry atomically replaces only the requested projection.
- **Partial failure/recovery:** One unavailable provider/metric is a report flag, not total failure. Output-path errors preserve the previous completed export and database.

### Verification Before Dispatch

```bash
python3 .agents/scripts/domain-opportunity-helper.py pipeline-status --db "$HOME/.aidevops/.agent-workspace/work/domain-opportunities/integration-smoke.sqlite" --json
python3 .agents/scripts/domain-opportunity-helper.py report --db "$HOME/.aidevops/.agent-workspace/work/domain-opportunities/integration-smoke.sqlite" --format csv --output "$HOME/.aidevops/.agent-workspace/work/domain-opportunities/opportunities.csv"
python3 .agents/scripts/tests/test-domain-opportunity-reporting.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Status/report exercise the production read/projection/output path; end-to-end tests prove child fixture integration, deterministic ranking, missing evidence and atomic export; changed lint covers code/config/docs.
- **Broad verification trigger:** Run repository-wide/deploy validation only if `.gitignore`, setup/dependency roots, or generated runtime configuration changes have shared blast radius.

### Recoverability Checkpoint

- [ ] End-to-end fixture report and production smoke projection pass.
- [ ] WIP commit created before broader gates: `wip: integrate local domain opportunity reports`
- [ ] Evidence-triggered broad verification then run: setup/config/dependency gate only if shared roots changed.

### Safety-Stop Recovery

- **Original objective:** Deliver ranked local domain opportunity analysis without a web interface.
- **Preserved user directions:** Google Ads quantitative metrics, optional browser Trends, CSV/SQLite local stores, background workers.
- **Trigger and evidence:** Blocker incomplete, incompatible store, stale source contract, output-size/path fuse, or provider permission uncertainty.
- **Completed and verified:** Preserve merged child evidence and last completed report; keep parent/final issue open.
- **Remaining acceptance criteria:** List the exact missing child, field, or end-to-end command.
- **Unsafe route not to repeat:** Bypassing blockers, closing the parent early, flattening unknown evidence to zero, or adding scraping/purchasing/UI scope.
- **Next safe route:** Reconcile the specific child contract, reduce report scope/limit, or omit the optional source with an explicit flag.
- **Resume condition:** All blockers complete and the store/report contracts are compatible.
- **Owner and status:** Dispatched worker; `not-triggered` initially.

### Files Scope

- `.agents/scripts/domain-opportunity-helper.py`
- `.agents/scripts/domain_opportunity_reporting.py`
- `.agents/scripts/tests/test-domain-opportunity-reporting.py`
- `configs/domain-opportunities-config.json.txt`
- `.gitignore`
- `.agents/seo/domain-opportunities.md`
- `.agents/seo.md`
- `.agents/seo/backlink-checker.md`

## Acceptance Criteria

- [ ] One documented local command sequence initializes/imports/enriches/scores and emits ranked CSV plus JSON or Markdown without a web interface.
- [ ] Every reported candidate exposes policy version, score components, measured source/unit/time, current auction price/deadline, freshness, and missing/risk flags.
- [ ] Re-running the same snapshot/config/as-of yields deterministic row order and equivalent CSV/JSON/Markdown evidence.
- [ ] Missing credentials, providers, or Trends data remain explicit and non-fatal; unknown values are never rendered or scored as measured zero.
- [ ] Config/docs contain placeholders only; no research database, raw auction list, export, token, customer ID, purchase, bid, or scraper path enters git.
- [ ] SEO routing uses concise pointers, existing backlink-expiry behavior remains intact, end-to-end focused tests and changed lint pass.
- [ ] Parent #30492 closes only after #30493 through #30499 are complete and the final end-to-end criteria have evidence.

## Context & Decisions

- This is a local research capability, not a SaaS/interface clone.
- Quantitative ranking is deterministic and versioned; AI-generated business/monetization ideas are labelled hypotheses grounded in exported evidence.
- Source permissions and provenance are first-class fields.
- Google Ads is primary demand evidence; Trends is optional/batch-relative; provider appraisals are estimates.
- Bidding, purchasing, and automated browser scraping remain out of scope.

## Relevant Files

- `.agents/seo.md:56-116` — SEO routing and provider capability summary.
- `.agents/seo/keyword-research.md:75-116,164-182` — current metrics/export workflow vocabulary.
- `.agents/seo/backlink-checker.md:18-29,52-98` — existing expired-domain context and stale marketplace claims.
- `.agents/scripts/marketing-optimization-helper.py:123-157` — integrated Python CLI pattern.
- `.agents/aidevops/extension.md:22-30,145-172` — config/docs/security extension checklist.

## Dependencies

- **Blocked by:** `t18297`, `t18298`, `t18299`, `t18300`, `t18301`
- **Blocks:** parent `t18295` / #30492 completion
- **External:** None for fixture/end-to-end local reporting; real data requires operator-authorized sources and credentials described by upstream children.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 1h | Inspect all merged child interfaces |
| Implementation | 4h | Reporting, config, docs, pointers |
| Verification | 1.5h | End-to-end fixtures, deterministic exports, issue closure |
| **Total** | **6.5h** | |
