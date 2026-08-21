<!-- aidevops:brief-schema=v2 -->

# t18295: Build a local domain-auction opportunity research pipeline

## Pre-flight

- [x] Memory recall: `domain auction opportunity research Google Ads Google Trends browser automation local CSV SQLite parent child worker issues` → 0 hits — no relevant stored lessons.
- [x] Discovery pass: 3 recent commits touched browser/keyword reference docs; 0 merged PRs and 0 open PRs matched this pipeline; all proposed implementation files are new.
- [x] File refs verified: 8 reference paths checked at HEAD; all exist, and the new-file parent directories exist.
- [x] Tier: `tier:thinking` — this roadmap coordinates a persistent local schema, third-party source contracts, optional browser collection, and evidence scoring across ordered children.
- [x] Seeded draft PR decision recorded: skipped — issue-only decomposition avoids anchoring workers before the foundation child fixes the storage contract.

## Origin

- **Created:** 2026-08-21
- **Session:** `opencode:interactive-2026-08-21`
- **Created by:** `ai-interactive`
- **Parent task:** none
- **Blocked by:** none; this issue is a non-dispatchable roadmap parent.
- **Conversation context:** The user wants BuildOnDomains-like research capability without copying its interface: authorized auction discovery, Google Ads demand metrics, optional browser-assisted Google Trends evidence, and local SQLite/CSV analysis. Background Pulse workers are explicitly authorized.

## What

Deliver a read-only, provider-neutral local research workflow that collects authorized domain-auction inventory, normalizes it into a versioned SQLite store, enriches candidate phrases with quantitative demand evidence, optionally records Google Trends evidence through a visible browser workflow, and exports explainable ranked opportunity datasets.

No web application or replicated interface is part of this roadmap. Research data remains local and exportable as CSV/JSON/Markdown.

## Why

Auction marketplaces expose inconsistent APIs and bulk files, while the valuable decision is not merely finding names but quantifying commercial demand, freshness, cost, and evidence gaps. A local evidence plane gives AI DevOps and the user reproducible analysis without committing to a hosted product, unauthorized scraping, or automated purchasing.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** The parent fixes cross-child trust boundaries and completion criteria but is never implemented directly. Children receive narrower standard/thinking contracts after the storage boundary is established.

## PR Conventions

This issue carries `parent-task`. Child PRs close only their leaf issues. Any PR that references this parent before the final child must use `For #30492` or `Ref #30492`, not a closing keyword. The final integration PR may close the parent only after every child is complete.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The implementation surface is intentionally divided across ordered children, and no code should precede the storage contract.
- **Status:** `not-created`
- **Freshness evidence:** Current references and GitHub collision searches were checked on 2026-08-21.
- **Verification run:** Planning-only discovery; implementation is unverified.
- **Stale-assumption warning:** Re-check source API/feed contracts and recently merged foundation work before each child starts.

## Children

1. `t18296` / #30493 — define the local data contract and SQLite foundation; first available leaf.
2. `t18297` / #30494 — ingest the official Namecheap Market Auctions API; blocked by `t18296`.
3. `t18298` / #30495 — import official GoDaddy/SnapNames/NameJet bulk inventory files; blocked by `t18296`.
4. `t18299` / #30496 — calculate deterministic exact-match candidate quality; blocked by `t18296`.
5. `t18300` / #30497 — collect Google Ads Keyword Planning demand metrics; blocked by `t18296`.
6. `t18301` / #30498 — capture optional browser-assisted Google Trends evidence; blocked by `t18296`.
7. `t18302` / #30499 — integrate ranking, local exports, and operator documentation; blocked by `t18297`, `t18298`, `t18299`, `t18300`, and `t18301`.

The five middle children may run in parallel after the foundation merges. Pulse owns dependency promotion; leaf workers must not mutate successor labels manually.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/aidevops/architecture.md:61-85,136-167` — preserve the judgment-versus-mechanics split and flat script layout.
- **Load only if:** `.agents/reference/storage-lifecycle.md` — when a child chooses local path ownership, cleanup, or retention semantics.
- **Load only if:** `.agents/tools/browser/playwriter.md:20-41,92-157` — only for the Trends child.
- **Why:** Keep deterministic ingestion/storage in tools while leaving opportunity judgment explainable and evidence-led.
- **Stop when:** The active child has a fixed write surface, source contract, recovery behavior, and focused verification command.

### Files to Modify

The parent modifies no production code. Children own these planned surfaces:

- `NEW: .agents/scripts/domain-opportunity-helper.py` and `domain_opportunity_*.py` — local CLI, store, adapters, scoring, and exports.
- `NEW: .agents/schemas/domain-opportunity-record.schema.json` — normalized interchange contract.
- `NEW: .agents/seo/domain-opportunities.md` — operator and analysis workflow.
- `EDIT: .agents/seo.md` and `.agents/seo/backlink-checker.md` — concise routing pointers only in the final child.
- `NEW/EDIT: configs/domain-opportunities-config.json.txt` and `.gitignore` — secret-free template and ignored working configuration, only if the foundation confirms this is the repository pattern.

### Complete Write Surface

- **Callers/readers:** SEO agents and operators call the local CLI; final docs point from `.agents/seo.md` and `.agents/seo/backlink-checker.md` to the detailed guide.
- **Writers/mutation paths:** Provider adapters, candidate scoring, Google Ads enrichment, Trends import, and final report generation write only through `.agents/scripts/domain_opportunity_store.py` from the foundation child.
- **Tests/fixtures:** `.agents/scripts/tests/test-marketing-optimization.py` is the verified Python CLI/store test pattern; `.agents/scripts/linters-local.sh --changed` is the changed-file gate.
- **Schemas/config:** `.agents/schemas/domain-opportunity-record.schema.json`, the versioned SQLite schema, and `configs/domain-opportunities-config.json.txt` define persisted/interchange state; runtime credentials use aidevops secret storage.
- **Generated/deployed mirrors:** `setup.sh --non-interactive` deploys `.agents/` changes; research databases and exports are local runtime artifacts and must not be committed.
- **Migrations/backfills:** `.agents/scripts/domain_opportunity_store.py` owns schema version 1; later children use its tables or explicit additive migrations rather than independent incompatible schemas.
- **Cleanup/rollback paths:** Removing the new `.agents/scripts/domain-opportunity-*.py` entrypoints rolls back the capability without deleting user data; runtime cleanup is explicit and never automatic during upgrades.

### Implementation Steps

1. Merge the foundation child and publish its normalized record/store contract.
2. Let Pulse release the five independent ingestion, scoring, and enrichment children once the native blocker closes.
3. Require each child to preserve source provenance, read-only behavior, idempotency, and an offline fixture path.
4. Merge the integration child only after all upstream contracts are available on the default branch.
5. Close this parent only when all child acceptance criteria and the end-to-end local workflow are verified.

### Hazards and Compatibility

- **Concurrency/atomicity:** Parallel children must write separate adapter modules, use the foundation transaction API, and avoid shared store or root dependency-manifest edits; a missing foundation contract blocks that leaf instead of authorizing a competing schema.
- **Migration/rollback:** Additive versioned migrations only. Reject unknown future schema versions and preserve existing databases on code rollback.
- **Mixed-version/backward compatibility:** Adapters declare the minimum store schema they require and fail clearly rather than partially writing to an incompatible database.
- **Idempotency/retry:** Every source run and enrichment observation has a stable provider key or content hash so retries cannot duplicate current listings.
- **Partial failure/recovery:** Failed providers remain source-scoped; one unavailable optional source must not corrupt or block querying previously collected evidence.

### Verification Before Dispatch

```bash
gh issue view 30492 --repo marcusquinn/aidevops --json labels,subIssues
.agents/scripts/issue-sync-helper.sh relationships t18295 --project-root "$(git rev-parse --show-toplevel)"
```

- **Surface mapping:** The first command proves the roadmap label and child graph; the second reconciles declared dependencies from canonical planning data.
- **Broad verification trigger:** Not required for the planning-only parent. Each child owns its affected production and lint gates.

### Files Scope

- `todo/tasks/t18295-brief.md`

## Acceptance Criteria

- [ ] Every listed child exists as a native sub-issue with the declared blocker graph; only `t18296` is initially available.
- [ ] A local command can initialize a versioned SQLite database, ingest at least one authorized auction source, and export ranked CSV without requiring a web interface.
- [ ] Google Ads metrics are stored with locale, period, units, source, and retrieval provenance; absent credentials do not damage the local store.
- [ ] Trends remains optional and browser-assisted; failure or omission does not prevent core analysis.
- [ ] No child implements bidding, purchasing, CAPTCHA bypass, undocumented endpoint replay, or repository-tracked research datasets/secrets.
- [ ] The final operator guide explains source permissions, local paths, commands, evidence limitations, and recovery.

## Context & Decisions

- Replicate the research capability, not BuildOnDomains branding or interface.
- Prefer official APIs and downloadable inventory; browser automation is a last-mile evidence collector, not the auction ingestion foundation.
- Google Ads Keyword Planning is the primary quantitative demand source. Trends is directional normalized evidence, not search volume.
- SQLite is canonical local storage; CSV/JSON/Markdown are exports for analysis and portability.
- Keep purchase authority entirely out of scope.

## Relevant Files

- `.agents/aidevops/architecture.md:61-85` — deterministic mechanics versus model judgment.
- `.agents/seo/keyword-research.md:95-116,156-174` — existing demand and opportunity terminology.
- `.agents/seo/backlink-checker.md:18-29,52-98` — existing expired-domain discovery context.
- `.agents/tools/browser/playwriter.md:20-41,145-157` — visible browser and consent boundary.
- `.agents/scripts/marketing-optimization-helper.py:123-157` — Python CLI entrypoint pattern.
- `.agents/scripts/tests/test-marketing-optimization.py:1-19,112-119` — hermetic Python test pattern.

## Dependencies

- **Blocked by:** none
- **Blocks:** roadmap closure is blocked until #30493 through #30499 complete.
- **External:** Provider accounts and credentials are optional for implementation; live collection requires the user's authorized accounts and accepted provider terms.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Foundation | 1-2 days | Store, contract, CLI, fixtures |
| Parallel adapters/enrichment | 3-6 days | Five bounded children |
| Integration | 1-2 days | Ranking, exports, documentation |
| **Total** | **5-10 worker-days** | Parallelism reduces elapsed time |
