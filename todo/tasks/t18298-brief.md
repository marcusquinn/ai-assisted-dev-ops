<!-- aidevops:brief-schema=v2 -->

# t18298: Import official bulk domain-auction inventory files

## Pre-flight

- [x] Memory recall: `GoDaddy SnapNames NameJet auction inventory files` → 0 hits — no relevant stored lessons.
- [x] Discovery pass: 0 commits, 0 merged PRs, and 0 open PRs touch the proposed bulk-file adapter; related issue hits are intentional siblings.
- [x] File refs verified: 5 repository references and all planned parent directories checked at HEAD.
- [x] Tier: `tier:standard` — local file ingestion, provenance, and provider boundaries are fixed; header/version mapping requires bounded judgment.
- [x] Seeded draft PR decision recorded: skipped — parser code must target the merged foundation contract.

## Origin

- **Created:** 2026-08-21
- **Session:** `opencode:interactive-2026-08-21`
- **Created by:** `ai-interactive`
- **Parent task:** `t18295` / #30492
- **Blocked by:** `t18296` / #30493; dispatch remains blocked until the native `blockedBy` relationship is verified.
- **Conversation context:** Several auction platforms expose official downloadable inventory but no stable public listing API. The pipeline needs local imports without scraping.

## What

Implement file-based ingestion for official GoDaddy Auctions inventory downloads and SnapNames/NameJet CSV or compressed-text auction lists. Support explicit provider selection, safe ZIP/gzip/plain-text handling, header mapping with diagnostics, normalized store writes, rejected-row reporting, and deterministic re-import.

Also accept a generic normalized JSONL/CSV file from any provider when the user has an authorized export. Do not add a DropCatch scraper or infer permission from public accessibility.

## Why

Bulk downloads provide broad coverage with much lower fragility than browser scraping. A safe local importer separates source acquisition/permission from normalization and lets users archive reproducible snapshots.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Input classes, target schema, no-scrape boundary, and failure behavior are decided. The worker still must implement provider aliases and robust archive parsing.

## PR Conventions

This leaf PR closes #30495 and may reference the parent with `For #30492`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Official download headers may change and must be mapped against the merged normalized contract rather than speculative fixtures.
- **Status:** `not-created`
- **Freshness evidence:** Official download pages and repository references were checked on 2026-08-21.
- **Verification run:** Public pages were inspected; no recurring automated download was authorized or executed.
- **Stale-assumption warning:** Re-check provider download documentation and fixture headers at implementation time.

## How (Approach)

### Progressive Context Plan

- **Read first:** merged `.agents/scripts/domain_opportunity_contract.py` and `domain_opportunity_store.py` — authoritative mapping and writes.
- **Load only if:** `.agents/reference/secret-handling.md` — only if optional authenticated file download is added; local import needs no secret.
- **Load only if:** `.agents/reference/storage-lifecycle.md` — when retaining raw source snapshots or rejected-row diagnostics.
- **Why:** Keep archive parsing deterministic and source permission explicit.
- **Stop when:** Provider formats, size/path limits, rejected-row semantics, and no-network fixture verification are fixed.

### Worker Quick-Start

```text
Verified official entry points:
- GoDaddy inventory help: https://kr.godaddy.com/help/download-inventory-files-for-godaddy-auctions-41284
- GoDaddy inventory catalog: https://inventory.auctions.godaddy.com/
- SnapNames downloads: https://www.snapnames.com/download.action
- NameJet downloads: https://www2.namejet.com/download.action?format=csv
Public availability is not recurring-download permission; default to operator-supplied local files.
```

### Files to Modify

- `NEW: .agents/scripts/domain-opportunity-files.py` — CLI for inspect/import with provider and archive options.
- `NEW: .agents/scripts/domain_opportunity_files.py` — safe archive reader, dialect/header detection, provider mappings, rejects, and store orchestration.
- `NEW: .agents/scripts/tests/fixtures/domain-opportunity/godaddy-inventory.csv` — synthetic documented-shape fixture.
- `NEW: .agents/scripts/tests/fixtures/domain-opportunity/snapnames-inventory.csv` — synthetic documented-shape fixture reused for NameJet aliases only where headers match.
- `NEW: .agents/scripts/tests/test-domain-opportunity-files.py` — archive, mapping, malformed-row, size, and replay coverage.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/domain-opportunity-files.py` calls `.agents/scripts/domain_opportunity_files.py`; final integration invokes its stable import command.
- **Writers/mutation paths:** `.agents/scripts/domain_opportunity_files.py` writes listings only through `.agents/scripts/domain_opportunity_store.py` and writes optional rejects to an explicit operator path via atomic replacement.
- **Tests/fixtures:** `.agents/scripts/tests/test-domain-opportunity-files.py` reads the two synthetic provider fixtures plus temporary ZIP/gzip variants; it never fetches provider websites.
- **Schemas/config:** `.agents/schemas/domain-opportunity-record.schema.json` validates normalized rows; provider header aliases live in `.agents/scripts/domain_opportunity_files.py`, not an unversioned user secret.
- **Generated/deployed mirrors:** `setup.sh --non-interactive` deploys scripts; runtime snapshots/rejects remain under the local workspace or explicit output directory.
- **Migrations/backfills:** No independent migration or store edit because `.agents/scripts/domain_opportunity_store.py` owns schema versions; old downloaded files may be re-imported through the adapter and content hash without duplicating observations, while a missing typed API blocks this leaf for foundation repair.
- **Cleanup/rollback paths:** Removing `.agents/scripts/domain-opportunity-files.py` disables imports without deleting stored evidence; temporary extraction happens in memory or a mode-0700 temporary directory that is always removed.

### Implementation Steps

1. Inspect the merged contract and define explicit provider profiles for GoDaddy, SnapNames, and NameJet, including accepted header aliases and required minimum fields.
2. Build a bounded reader for plain CSV/text, gzip, and ZIP. Reject path traversal entries, nested archives, encrypted archives, excessive uncompressed size/ratio, and multiple ambiguous candidate files.
3. Add `inspect` to report detected format, provider, headers, row count estimate, and missing requirements without writing the store.
4. Add `import --provider NAME --input FILE --db PATH [--rejects FILE]`. Require provider selection unless normalized schema detection is exact; never guess a marketplace from a domain link alone.
5. Normalize timestamps, prices/currency, status, type, source URL, and IDs. If a provider lacks an ID, derive a deterministic source snapshot/listing key from provider plus domain plus auction deadline and document collision behavior.
6. Record source filename basename, SHA-256, retrieval/import time supplied by the operator, parser profile version, and rejected-row counts. Do not retain private local absolute paths in exported datasets.
7. Add synthetic fixtures and focused coverage for archive safety, unknown headers, row isolation, duplicate re-import, and generic normalized import.

### Hazards and Compatibility

- **Concurrency/atomicity:** One file is one source run; normalized page/batch writes are transactional and coexist with readers under the foundation's WAL policy.
- **Migration/rollback:** Parser profiles are versioned in source-run metadata; schema incompatibility fails before any rows are written.
- **Mixed-version/backward compatibility:** Unknown extra columns are retained in raw row evidence and ignored; missing required columns fail `inspect/import` with a header diagnostic.
- **Idempotency/retry:** File SHA-256 plus provider listing identity makes exact re-import a no-op while allowing a changed later snapshot.
- **Partial failure/recovery:** Bad rows are isolated and counted; archive/path/required-header failures abort the run before current listing state changes.

### Verification Before Dispatch

```bash
python3 .agents/scripts/domain-opportunity-files.py inspect --provider godaddy --input .agents/scripts/tests/fixtures/domain-opportunity/godaddy-inventory.csv
python3 .agents/scripts/domain-opportunity-files.py import --provider snapnames --input .agents/scripts/tests/fixtures/domain-opportunity/snapnames-inventory.csv --db "$HOME/.aidevops/.agent-workspace/work/domain-opportunities/files-smoke.sqlite"
python3 .agents/scripts/tests/test-domain-opportunity-files.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Inspect/import exercise production parsing and store writes; focused tests cover archives, headers, rejects, and replay; changed lint covers Python/fixture policy.
- **Broad verification trigger:** Not required unless optional network download or shared storage helpers are introduced.

### Recoverability Checkpoint

- [ ] Focused inspect/import and tests pass.
- [ ] WIP commit created before broader gates: `wip: add auction inventory file imports`
- [ ] Evidence-triggered broad verification then run: not required unless shared files change.

### Safety-Stop Recovery

- **Original objective:** Import authorized official auction inventory files into local storage.
- **Preserved user directions:** Local-only research, no interface replication, APIs/files/browser only where appropriate.
- **Trigger and evidence:** Archive size/ratio/path fuse, malformed required headers, or excessive rejected-row threshold.
- **Completed and verified:** Preserve the input hash and sanitized parser diagnostic; never preserve unsafe extracted content.
- **Remaining acceptance criteria:** Safe import/replay and provenance remain open after a fuse.
- **Unsafe route not to repeat:** Unbounded extraction, recursive archives, guessed provider mapping, or scraping a download UI.
- **Next safe route:** Inspect the local file, update a versioned provider profile, or request an authorized export.
- **Resume condition:** Bounded valid local file with recognized headers.
- **Owner and status:** Dispatched worker; `not-triggered` initially.

### Files Scope

- `.agents/scripts/domain-opportunity-files.py`
- `.agents/scripts/domain_opportunity_files.py`
- `.agents/scripts/tests/fixtures/domain-opportunity/godaddy-inventory.csv`
- `.agents/scripts/tests/fixtures/domain-opportunity/snapnames-inventory.csv`
- `.agents/scripts/tests/test-domain-opportunity-files.py`

## Acceptance Criteria

- [ ] `inspect` recognizes each synthetic provider fixture and reports required/unknown headers without mutating SQLite.
- [ ] Plain, gzip, and ZIP forms of a valid fixture normalize to equivalent records with source/profile provenance.
- [ ] Exact re-import is idempotent; a changed snapshot creates only the changed observations.
- [ ] Traversal, encrypted/nested, oversized, and ambiguous archives are rejected before extraction or database mutation.
- [ ] The implementation performs no marketplace page scraping and treats unsupported-provider files only through explicit authorized generic import.
- [ ] Production inspect/import, focused tests, and changed-file lint pass.

## Context & Decisions

- Local import is the default because provider pages did not explicitly grant recurring automated download/republication rights.
- The GoDaddy, SnapNames, and NameJet adapters are parser profiles, not assumptions that each marketplace shares semantics.
- DropCatch is unsupported until an approved feed/export exists; users may import an authorized normalized file without a platform scraper.
- Raw absolute local paths and credentials never enter portable exports.

## Relevant Files

- `.agents/scripts/domain_opportunity_contract.py` — dependency-created normalized record contract.
- `.agents/scripts/domain_opportunity_store.py` — dependency-created source-run/write API.
- `.agents/reference/storage-lifecycle.md` — local artifact ownership and cleanup when needed.
- `.agents/aidevops/architecture.md:152-167` — flat scripts and deterministic mechanics.

## Dependencies

- **Blocked by:** `t18296` / #30493
- **Blocks:** `t18302` / #30499
- **External:** Operator-supplied official/authorized inventory files; no account or credential required for fixture verification.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 45m | Merged contract and current provider formats |
| Implementation | 4h | Safe archives, profiles, normalization, rejects |
| Verification | 1h | Fixtures, replay, archive failure paths |
| **Total** | **5.75h** | |
