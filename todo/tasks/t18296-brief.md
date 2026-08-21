<!-- aidevops:brief-schema=v2 -->

# t18296: Define the local domain-opportunity data contract and SQLite foundation

## Pre-flight

- [x] Memory recall: `domain auction opportunity SQLite CSV` → 0 hits — no relevant stored lessons.
- [x] Discovery pass: 0 commits, 0 merged PRs, and 0 open PRs touch the proposed new domain-opportunity files in the last 48h; recent marketing-store work is reference-only.
- [x] File refs verified: 6 refs checked; script, schema, test, and local-work parent directories exist at HEAD.
- [x] Tier: `tier:thinking` — this child fixes the persistent schema and adapter boundary used by five parallel successors.
- [x] Seeded draft PR decision recorded: skipped — schema decisions belong in the dispatched implementation and must be verified together.

## Origin

- **Created:** 2026-08-21
- **Session:** `opencode:interactive-2026-08-21`
- **Created by:** `ai-interactive`
- **Parent task:** `t18295` / #30492
- **Blocked by:** none; first available implementation leaf.
- **Conversation context:** Establish a local, read-only evidence plane before provider-specific workers begin.

## What

Create a standard-library Python CLI, normalized JSON interchange contract, and versioned SQLite store for domain-auction listings and their evidence. The foundation must support deterministic initialization, normalized JSONL import, CSV export, status reporting, source-run provenance, and stable writer APIs for later provider/scoring modules.

Default runtime data belongs under `~/.aidevops/.agent-workspace/work/domain-opportunities/`, with explicit CLI overrides for database and export paths.

## Why

Parallel provider workers need one transaction, identity, units, freshness, and migration contract. Without it, adapters would create incompatible CSVs or schemas and make cross-source opportunity scoring unreliable.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** Persistent schema identity, migrations, concurrency, and privacy boundaries are consequential cross-child architecture. The user-facing constraints are fixed, but the worker must validate the narrowest durable schema.

## PR Conventions

This is a leaf task. The implementation PR uses a closing keyword for #30493 and may reference the parent with `For #30492`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** No implementation exists yet, and pre-seeding a schema would substitute unverified assumptions for the worker's store review.
- **Status:** `not-created`
- **Freshness evidence:** Proposed paths are absent and reference patterns were read at current HEAD.
- **Verification run:** Planning checks only; implementation unverified.
- **Stale-assumption warning:** Re-check the default branch for a newly added domain-opportunity contract before creating files.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/marketing-optimization-helper.py:123-157` and `.agents/scripts/performance_store_schema.py:177-191,350-375` — CLI dispatch and versioned SQLite patterns.
- **Load only if:** `.agents/reference/storage-lifecycle.md` — when deciding cleanup, ownership, or retention behavior.
- **Load only if:** `.agents/scripts/tests/test-marketing-optimization.py:1-19,112-119` — when adding the focused hermetic store test.
- **Why:** Reuse current local-store conventions without copying unrelated marketing complexity.
- **Stop when:** The schema, transaction API, runtime path, and smoke verification are fixed.

### Worker Quick-Start

```text
Canonical identity: (provider, provider_listing_id); retain fqdn as a searchable attribute, not the only identity.
Money: integer micros plus ISO currency; never binary floating point.
Time: UTC ISO-8601 at boundaries; store normalized UTC timestamps.
Raw evidence: local JSON text plus SHA-256/content provenance; never credentials.
SQLite: foreign_keys=ON, WAL, busy_timeout, explicit transactions, PRAGMA user_version.
```

### Files to Modify

- `NEW: .agents/scripts/domain-opportunity-helper.py` — argparse entrypoint with `init`, `status`, `import-jsonl`, and `export-csv`.
- `NEW: .agents/scripts/domain_opportunity_contract.py` — normalization, validation, enums/field constants, UTC and money helpers.
- `NEW: .agents/scripts/domain_opportunity_store.py` — path resolution, schema initialization, transactions, idempotent upserts, queries, and CSV export.
- `NEW: .agents/schemas/domain-opportunity-record.schema.json` — normalized listing interchange schema for adapters and fixtures.
- `NEW: .agents/scripts/tests/test-domain-opportunity.py` — focused standard-library hermetic contract coverage; material uncertainty is schema migration/idempotency, so focused coverage is the cheapest verification.

### Complete Write Surface

- **Callers/readers:** Future `domain-opportunity-namecheap.py`, `domain-opportunity-files.py`, `domain-opportunity-score.py`, `domain-opportunity-google-ads.py`, `domain-opportunity-trends.py`, and the final CLI integration import the contract/store modules.
- **Writers/mutation paths:** Only `.agents/scripts/domain_opportunity_store.py` methods may open write transactions. CLI import and downstream adapters call those methods; no module writes ad hoc SQL files.
- **Tests/fixtures:** `.agents/scripts/tests/test-domain-opportunity.py` owns focused init, migration, idempotency, and export fixtures; model its layout on `.agents/scripts/tests/test-marketing-optimization.py`.
- **Schemas/config:** `.agents/schemas/domain-opportunity-record.schema.json` plus SQLite `user_version=1` define the contract. No credential config is needed in this child.
- **Generated/deployed mirrors:** `setup.sh --non-interactive` deploys scripts/schema. Runtime DB/CSV files are generated under the local workspace and are not tracked.
- **Migrations/backfills:** `.agents/scripts/domain_opportunity_store.py` creates v1 atomically. Empty legacy/unversioned files fail clearly unless they exactly match the v1 bootstrap condition. Future versions are rejected without mutation.
- **Cleanup/rollback paths:** Removing the new `.agents/scripts/domain-opportunity-helper.py` entrypoint leaves the DB untouched. `init` never deletes/recreates an incompatible DB; temporary exports are atomically replaced or cleaned after failure.

### Implementation Steps

1. Define the normalized record contract. Required listing fields: provider, provider listing ID, fqdn/sld/tld, status, auction type, current price micros/currency, bid count, start/end times, source URL, observed time, source-run ID, payload hash, and optional raw JSON. Optional metrics must preserve source and observed time rather than becoming unlabelled listing columns.
2. Create schema v1 with at least `source_runs`, `listings`, `listing_observations`, `keyword_metrics`, `trend_series`, `trend_points`, `candidate_scores`, and `score_components`. Use foreign keys and uniqueness constraints that make retries deterministic.
3. Expose a small store API for beginning/completing/failing source runs, upserting a listing observation, inserting typed metric/trend/score observations, and querying/exporting the current joined view.
4. Implement CLI commands:
   - `init --db PATH`
   - `status --db PATH --json`
   - `import-jsonl --db PATH --input FILE --provider NAME`
   - `export-csv --db PATH --output FILE [--active-only]`
5. Validate all paths before creating parents, reject symlink/path traversal surprises where the existing storage policy requires it, and emit sanitized errors.
6. Add a focused hermetic test for init/reopen, duplicate import, changed observation, CSV round-trip, future-version rejection, and no-network operation.
7. Exercise the production CLI and run changed-file lint before the WIP checkpoint.

### Hazards and Compatibility

- **Concurrency/atomicity:** SQLite WAL plus `busy_timeout`; each source batch is a transaction, while source-run status records terminal failure without leaving half-current rows.
- **Migration/rollback:** Use `PRAGMA user_version`; migration steps are additive and transactional. Never silently downgrade or recreate a future-version DB.
- **Mixed-version/backward compatibility:** Store module exposes `SCHEMA_VERSION`; adapters check compatibility and fail before writes if it differs.
- **Idempotency/retry:** Unique provider/listing identity plus observation content hash prevents duplicate rows while preserving genuine changes.
- **Partial failure/recovery:** Mark interrupted runs failed/stale, retain earlier successful evidence, and permit a later retry with a new run ID.

### Verification Before Dispatch

```bash
python3 .agents/scripts/domain-opportunity-helper.py init --db "$HOME/.aidevops/.agent-workspace/work/domain-opportunities/smoke.sqlite"
python3 .agents/scripts/domain-opportunity-helper.py status --db "$HOME/.aidevops/.agent-workspace/work/domain-opportunities/smoke.sqlite" --json
python3 .agents/scripts/tests/test-domain-opportunity.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** CLI init/status prove runtime paths and schema; the focused test proves identity, transactions, export, and version rejection; changed lint covers Python/schema style and repository policy.
- **Broad verification trigger:** Not required; all files are new and isolated behind an unreferenced CLI.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: `python3 .agents/scripts/tests/test-domain-opportunity.py`
- [ ] WIP commit created before any broad gate: `wip: add domain opportunity store foundation`
- [ ] Evidence-triggered broad verification then run: not required unless shared setup/deploy files are changed.

### Files Scope

- `.agents/scripts/domain-opportunity-helper.py`
- `.agents/scripts/domain_opportunity_contract.py`
- `.agents/scripts/domain_opportunity_store.py`
- `.agents/schemas/domain-opportunity-record.schema.json`
- `.agents/scripts/tests/test-domain-opportunity.py`

## Acceptance Criteria

- [ ] `init` creates schema v1 at an explicit or safe default local path, and `status` reopens it with deterministic JSON output.
- [ ] Importing the same normalized record twice does not duplicate the current listing or observation; a materially changed record creates one new observation.
- [ ] CSV export uses stable documented columns, integer-safe money conversion, UTC timestamps, and source/freshness fields.
- [ ] An unsupported future schema version fails before mutation and leaves the database byte-for-byte usable by its owning version.
- [ ] Runtime databases, raw payloads, exports, and credentials are not added to git and are never printed in full error output.
- [ ] Typed writer/query APIs cover listings, keyword metrics, Trends series, and score components so the five parallel successor leaves do not need to edit the store or root dependency manifests.
- [ ] The focused production CLI path and changed-file lint pass.

## Context & Decisions

- SQLite is canonical; CSV/JSON are interchange/export formats.
- The framework owns code and schemas, not the user's collected research data.
- Provider retrieval, scoring policy, Google Ads auth, and browser behavior are deliberately deferred to their children.
- No UI, bidding, purchasing, or destructive cleanup command is included.

## Relevant Files

- `.agents/scripts/marketing-optimization-helper.py:123-157` — argparse and sanitized failure pattern.
- `.agents/scripts/performance_store_schema.py:177-191,350-375` — versioned SQLite migration/reference pattern.
- `.agents/scripts/tests/test-marketing-optimization.py:1-19,112-119` — standard-library unittest layout.
- `.agents/aidevops/architecture.md:61-85,152-167` — tools own deterministic mechanics; scripts remain flat.

## Dependencies

- **Blocked by:** none
- **Blocks:** `t18297`, `t18298`, `t18299`, `t18300`, `t18301`
- **External:** Python 3 standard library and SQLite only; no API credentials required.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Store and CLI reference patterns |
| Implementation | 4h | Contract, schema, CLI, transactions |
| Verification | 1h | Focused persistence and export checks |
| **Total** | **5.5h** | |
