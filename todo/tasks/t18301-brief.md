<!-- aidevops:brief-schema=v2 -->

# t18301: Capture optional Google Trends evidence through a browser-assisted workflow

## Pre-flight

- [x] Memory recall: `Google Trends browser CSV domain opportunities` → 0 hits — no relevant stored lessons.
- [x] Discovery pass: no Trends collector or matching open/merged PR; recent Playwriter commits are current reference behavior, not a collision.
- [x] File refs verified: 6 repository references/directories and current official Trends export/help pages checked.
- [x] Tier: `tier:standard` — acquisition is deliberately manual/browser-assisted, while queue/manifest/import/persistence are deterministic.
- [x] Seeded draft PR decision recorded: skipped — the worker must target the merged store and current export shape.

## Origin

- **Created:** 2026-08-21
- **Session:** `opencode:interactive-2026-08-21`
- **Created by:** `ai-interactive`
- **Parent task:** `t18295` / #30492
- **Blocked by:** `t18296` / #30493; dispatch remains blocked until the native `blockedBy` relationship is verified.
- **Conversation context:** Trends is useful directional evidence but has no verified public automation API. The user accepts browser use and wants local datasets, not an interface.

## What

Create an optional queue/manifest/import workflow for Google Trends interest-over-time CSV exports. The tool prepares bounded comparison batches and complete metadata manifests, the operator downloads CSVs through the documented public browser UI, and the importer validates/persists normalized series with raw-file hashes and comparison provenance.

Do not implement unattended scraping, hidden endpoint calls, CAPTCHA bypass, or make Trends a prerequisite for ranking.

## Why

Trends adds directionality and seasonality, but its 0-100 values are sampled and normalized within each geography/timeframe/comparison. A manifest-bound browser export retains enough context to interpret the series and avoids treating relative values as absolute search volume.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The permission boundary is fixed: background code queues and imports; the human-visible browser performs the documented export. The worker implements deterministic manifests and parser compatibility.

## PR Conventions

This leaf PR closes #30498 and may reference the parent with `For #30492`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** CSV shape and merged trend-series store contract must be verified together.
- **Status:** `not-created`
- **Freshness evidence:** Official Trends help and current browser guidance checked on 2026-08-21.
- **Verification run:** Documentation/public page research only; no automated Trends request executed.
- **Stale-assumption warning:** Re-open official export help and validate a fresh operator export before finalizing parser aliases.

## How (Approach)

### Progressive Context Plan

- **Read first:** merged `.agents/scripts/domain_opportunity_contract.py` and `domain_opportunity_store.py` — trend series/point identity and writes.
- **Read next:** `.agents/tools/browser/playwriter.md:20-41,92-157` — visible tab consent and manual handoff; do not treat anti-detection guidance as scraping permission.
- **Load only if:** official Trends export/help/terms pages — when CSV shape or browser workflow differs.
- **Why:** Keep the supported path transparent, reproducible, and terms-aware.
- **Stop when:** Manifest metadata, batch identity, CSV validation, optional-source failure, and comparison limits are fixed.

### Worker Quick-Start

```text
Official site: https://trends.google.com/trends/
Documented path: configure comparison/filter controls, then Download on Interest over time.
Retain: exact term/topic identity and order, optional anchor, geography, timeframe, timezone/granularity, search property, category, language, share URL, export timestamp, raw SHA-256.
Values are relative 0-100 popularity, not search volume; never merge independent batches as absolute values.
No verified automation authorization exists: background workers prepare/import, not drive Google UI.
```

### Files to Modify

- `NEW: .agents/scripts/domain-opportunity-trends.py` — queue, manifest validation, inspect, and import CLI.
- `NEW: .agents/scripts/domain_opportunity_trends.py` — batching, CSV parser profiles, normalized series mapping, and store writes.
- `NEW: .agents/schemas/domain-opportunity-trends-manifest.schema.json` — required browser-export context and batch identity.
- `NEW: .agents/scripts/tests/fixtures/domain-opportunity/google-trends-interest.csv` — synthetic documented-shape CSV.
- `NEW: .agents/scripts/tests/fixtures/domain-opportunity/google-trends-manifest.json` — matching synthetic metadata manifest.
- `NEW: .agents/scripts/tests/test-domain-opportunity-trends.py` — manifest, parser, relative-value, replay, and optional-failure coverage.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/domain-opportunity-trends.py` reads candidate phrases and manifests; final reporting reads trend series/points by comparison batch.
- **Writers/mutation paths:** `.agents/scripts/domain_opportunity_trends.py` writes only trend/source-run rows through `.agents/scripts/domain_opportunity_store.py` and creates queue manifests at an explicit local output path.
- **Tests/fixtures:** `.agents/scripts/tests/test-domain-opportunity-trends.py` reads the synthetic CSV/manifest fixtures; browser/network access is not part of CI.
- **Schemas/config:** `.agents/schemas/domain-opportunity-trends-manifest.schema.json` fixes geography/timeframe/property/category/terms/anchor/export metadata; `.agents/schemas/domain-opportunity-record.schema.json` owns normalized evidence.
- **Generated/deployed mirrors:** `setup.sh --non-interactive` deploys scripts/schemas/fixtures; actual queue manifests and raw CSV exports stay local and gitignored.
- **Migrations/backfills:** `.agents/scripts/domain_opportunity_store.py` owns schema versions and is not edited in this parallel leaf; if comparison batch/anchor provenance does not fit its typed API, stop with an exact foundation blocker.
- **Cleanup/rollback paths:** Removing `.agents/scripts/domain-opportunity-trends.py` disables new imports without deleting series; invalid CSVs remain outside the DB and can be corrected/re-imported.

### Implementation Steps

1. Inspect the merged trend tables and define a manifest schema containing batch ID, term/topic strings and identity type, order, optional anchor, geography, timeframe/start/end, timezone/granularity, search property, category, language, share URL, expected filename, and operator/export time.
2. Implement `queue --db PATH --output DIR` to select candidates missing fresh Trends evidence and write bounded manifests plus a concise browser checklist. It must not launch/control the browser by default.
3. Document the supported browser step: open the official Trends site in a normal visible tab, configure exactly the manifest comparison/filters, download Interest-over-time CSV, and retain the share URL. Ordinary export appears not to require login, but controls/region may vary.
4. Implement `inspect --manifest FILE --input CSV` to validate expected terms, date shape, value range, partial markers, and metadata before writes.
5. Implement `import` to store raw hash, parser profile, comparison batch, points, and manifest context. Preserve `<1`/partial semantics distinctly from numeric zero if present in the export.
6. Never compare/rescale independent batches unless they share a valid anchor and the algorithm records its assumptions. If anchor values are absent/zero/unstable, retain batches separately and mark cross-batch comparability unavailable.
7. Keep failures non-fatal to the core dataset. Missing, stale, malformed, or blocked Trends evidence becomes an explicit status consumed by reporting.
8. Add fixture coverage for exact import, unexpected term/order, duplicate replay, time/geography mismatch, partial values, missing anchor, and no browser/network dependency.

### Hazards and Compatibility

- **Concurrency/atomicity:** One CSV+manifest pair publishes one trend series batch transactionally; queue generation uses unique batch IDs and atomic manifest writes.
- **Migration/rollback:** Parser profile and manifest schema versions are recorded. Foundation compatibility is checked before import; this leaf performs no store migration or historical rewrite.
- **Mixed-version/backward compatibility:** Header aliases may accept known older exports; unrecognized structures fail `inspect` with a safe diagnostic instead of guessing columns.
- **Idempotency/retry:** Raw SHA-256 plus manifest/batch identity prevents duplicate series while allowing a later timeframe/export to coexist.
- **Partial failure/recovery:** Bad/missing CSV affects only its batch; prior trends and all non-Trends opportunity data remain queryable.

### Verification Before Dispatch

```bash
python3 .agents/scripts/domain-opportunity-trends.py inspect --manifest .agents/scripts/tests/fixtures/domain-opportunity/google-trends-manifest.json --input .agents/scripts/tests/fixtures/domain-opportunity/google-trends-interest.csv
python3 .agents/scripts/domain-opportunity-trends.py import --manifest .agents/scripts/tests/fixtures/domain-opportunity/google-trends-manifest.json --input .agents/scripts/tests/fixtures/domain-opportunity/google-trends-interest.csv --db "$HOME/.aidevops/.agent-workspace/work/domain-opportunities/trends-smoke.sqlite"
python3 .agents/scripts/tests/test-domain-opportunity-trends.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Inspect/import prove production manifest/parser/store behavior; focused tests prove relative-value, replay, mismatch, and optional-source guarantees; changed lint covers Python/JSON/CSV policy.
- **Broad verification trigger:** Not required unless the implementation adds browser/runtime dependencies or changes shared MCP configuration; neither is expected.

### Recoverability Checkpoint

- [ ] Manifest and fixture inspect/import pass.
- [ ] WIP commit created before broader gates: `wip: add browser-assisted Trends imports`
- [ ] Evidence-triggered broad verification then run: not required unless shared browser/runtime files change.

### Safety-Stop Recovery

- **Original objective:** Capture optional Google Trends evidence into local storage.
- **Preserved user directions:** Browser use is acceptable; Google Ads remains the stronger quantitative metric; no UI is required.
- **Trigger and evidence:** Bot/captcha warning, changed export, missing/zero anchor, malformed CSV, or terms/robots uncertainty.
- **Completed and verified:** Preserve local queue/manifest and fixture-backed importer; do not continue the unsafe browser route.
- **Remaining acceptance criteria:** Operator export/import remains open and Trends status stays explicitly missing.
- **Unsafe route not to repeat:** Hidden CSV endpoint calls, unattended scraping, protection bypass, or repeated browser retries.
- **Next safe route:** Manual documented browser export, updated parser profile, or omit Trends and continue with Google Ads.
- **Resume condition:** Human-visible valid export matching the manifest and current documented workflow.
- **Owner and status:** Dispatched worker; `not-triggered` initially.

### Files Scope

- `.agents/scripts/domain-opportunity-trends.py`
- `.agents/scripts/domain_opportunity_trends.py`
- `.agents/schemas/domain-opportunity-trends-manifest.schema.json`
- `.agents/scripts/tests/fixtures/domain-opportunity/google-trends-interest.csv`
- `.agents/scripts/tests/fixtures/domain-opportunity/google-trends-manifest.json`
- `.agents/scripts/tests/test-domain-opportunity-trends.py`

## Acceptance Criteria

- [ ] Queue manifests preserve all comparison/filter metadata required to reproduce and interpret a browser export.
- [ ] Fixture inspect/import stores one batch with raw hash, parser version, normalized points, term order, and source/retrieval provenance.
- [ ] Exact replay is idempotent; mismatched term/time/geography CSVs fail before database mutation.
- [ ] Missing/failed Trends evidence never blocks auction ingestion, deterministic scoring, Google Ads enrichment, or local reporting.
- [ ] No code path calls undocumented Trends endpoints, drives unattended Google UI, bypasses controls, or labels 0-100 values as search volume.
- [ ] Production inspect/import, focused tests, and changed-file lint pass without browser/network access.

## Context & Decisions

- Browser export is a human-visible acquisition step; tooling handles queueing, metadata, validation, and import.
- Trends values remain directional and batch-relative. Google Ads owns absolute-ish demand metrics.
- Playwriter may assist a later interactive session only after explicit tab consent and a current terms check; it is not required by this implementation.
- The core pipeline remains complete when Trends is absent.

## Relevant Files

- `.agents/tools/browser/playwriter.md:20-41,92-157` — visible browser consent and handoff.
- `.agents/reference/screenshot-limits.md` — only if visual troubleshooting is needed; screenshots are not acceptance evidence.
- `.agents/scripts/domain_opportunity_store.py` — dependency-created trend writer.
- `.agents/aidevops/architecture.md:61-85` — deterministic import versus human/model judgment.

## Dependencies

- **Blocked by:** `t18296` / #30493
- **Blocks:** `t18302` / #30499
- **External:** Human-visible browser export from the public Trends site for real data; no login or credential is required by the documented ordinary export flow, though regional/abuse controls may vary.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Merged store and fresh official export shape |
| Implementation | 3.5h | Manifest, queue, inspect/import, parser profiles |
| Verification | 1h | Relative values, mismatch, replay, lint |
| **Total** | **5h** | |
