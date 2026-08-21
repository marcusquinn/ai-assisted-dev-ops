<!-- aidevops:brief-schema=v2 -->

# t18297: Ingest Namecheap Market auctions through the official API

## Pre-flight

- [x] Memory recall: `Namecheap Market Auctions API domain opportunity` → 0 hits — no relevant stored lessons.
- [x] Discovery pass: 0 commits, 0 merged PRs, and 0 open PRs touch the proposed Namecheap adapter; #30493 is the intentional foundation dependency.
- [x] File refs verified: 5 current reference paths and all new-file parent directories checked at HEAD.
- [x] Tier: `tier:standard` — the official read-only API contract and storage boundary are decided; pagination, mapping, retry, and fixture details require bounded implementation judgment.
- [x] Seeded draft PR decision recorded: skipped — the foundation API must exist on the default branch before adapter code is useful.

## Origin

- **Created:** 2026-08-21
- **Session:** `opencode:interactive-2026-08-21`
- **Created by:** `ai-interactive`
- **Parent task:** `t18295` / #30492
- **Blocked by:** `t18296` / #30493; dispatch remains blocked until the native `blockedBy` relationship is verified.
- **Conversation context:** Namecheap exposes the strongest verified programmatic auction source and is the first live adapter for the local research plane.

## What

Add a read-only adapter for the official Namecheap Market Auctions API `GET /sales` operation. It must page through active `.com` auction listings, map documented sale fields into the foundation contract, preserve raw/provenance evidence, and write idempotently through the shared store.

The adapter must not expose or call bid endpoints.

## Why

Namecheap's official API supplies listing state plus useful attributes such as keyword query/search count, backlinks, domain age, extension count, Ahrefs DR, and Estibot/GoDaddy estimates. One compliant source can make the local pipeline useful before less structured marketplaces are added.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Source, auth type, endpoint, target contract, and safety boundary are fixed. The worker must implement resilient pagination and field mapping without redesigning the platform.

## PR Conventions

This leaf PR closes #30494 and may reference the parent with `For #30492`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Code must compile against the merged #30493 store API rather than a speculative local copy.
- **Status:** `not-created`
- **Freshness evidence:** Official OpenAPI and repository references were checked on 2026-08-21.
- **Verification run:** Public OpenAPI inspected; no authenticated request was made.
- **Stale-assumption warning:** Re-fetch and inspect the official OpenAPI plus the merged foundation API before implementation.

## How (Approach)

### Progressive Context Plan

- **Read first:** the merged `.agents/scripts/domain_opportunity_contract.py` and `domain_opportunity_store.py` — these are authoritative for record and transaction shape.
- **Load only if:** `.agents/aidevops/extension.md:157-172` — when implementing credential/error/rate safety.
- **Load only if:** `.agents/scripts/keyword-research-helper-providers.sh` — when selecting the existing HTTP/secret-loading style; do not copy deprecated shell defects.
- **Why:** Keep the provider adapter narrow and make the shared store the only persistence owner.
- **Stop when:** `/sales` mapping, cursor termination, retry policy, and offline fixture behavior are explicit.

### Worker Quick-Start

```text
Official schema: https://aftermarketapi.namecheap.com/client/swagger.json
Server: https://aftermarketapi.namecheap.com/client/api
Read operation: GET /sales with Bearer JWT and cursor-based pagination.
Never call POST /sales/{saleId}/bids or persist the bearer token.
Default filters: tld=com; active records only unless the operator asks for another status.
```

### Files to Modify

- `NEW: .agents/scripts/domain-opportunity-namecheap.py` — provider CLI with fixture and live read-only sync modes.
- `NEW: .agents/scripts/domain_opportunity_namecheap.py` — client, pagination, response validation, mapping, and store orchestration.
- `NEW: .agents/scripts/tests/fixtures/domain-opportunity/namecheap-sales.json` — synthetic/redacted API response fixture using documented fields only.
- `NEW: .agents/scripts/tests/test-domain-opportunity-namecheap.py` — focused mapping, pagination, retry, and secret-redaction checks.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/domain-opportunity-namecheap.py` calls `.agents/scripts/domain_opportunity_namecheap.py`; the final integration child will invoke the same entrypoint or client API.
- **Writers/mutation paths:** `.agents/scripts/domain_opportunity_namecheap.py` writes only through `.agents/scripts/domain_opportunity_store.py`; HTTP responses and tokens are never written outside the local source-run/observation contract.
- **Tests/fixtures:** `.agents/scripts/tests/test-domain-opportunity-namecheap.py` reads `.agents/scripts/tests/fixtures/domain-opportunity/namecheap-sales.json` and stubs transport/cursors; no live network is required.
- **Schemas/config:** `.agents/schemas/domain-opportunity-record.schema.json` owns normalized output. Credentials use `NAMECHEAP_MARKET_API_TOKEN` from aidevops secret storage; no token-valued tracked config is added.
- **Generated/deployed mirrors:** `setup.sh --non-interactive` deploys the scripts and fixture is test-only; runtime records remain in the operator's local SQLite path.
- **Migrations/backfills:** No independent migration or store edit is permitted in this parallel leaf because `.agents/scripts/domain_opportunity_store.py` owns schema versions; if a required typed field/API is absent, stop with an exact foundation blocker and preserve only contract-supported raw evidence.
- **Cleanup/rollback paths:** Removing `.agents/scripts/domain-opportunity-namecheap.py` disables live ingestion without deleting prior observations; failed runs close as failed and retain the last successful snapshot.

### Implementation Steps

1. Verify the installed/default-branch store API and re-open the official OpenAPI before mapping fields.
2. Implement a transport function that reads the bearer token at call time, sends no secret to stdout/logs, uses bounded timeouts, and classifies authentication, rate limit, validation, and transient server failures.
3. Iterate `GET /sales?tld=com` via `nextCursor` until `hasMore` is false or a configurable maximum-page fuse is reached. Reject repeated cursors to prevent loops.
4. Map documented fields, including IDs, name/TLD/status/type, prices, bids, dates, auction type, ratings/rankings, backlink count, valuations, extensions, keyword query/search count, and previous sale details. Preserve absent values as null rather than zero.
5. Write each page through one source run and the store transaction API; use provider ID as canonical identity and retain retrieval timestamp plus payload hash.
6. Provide `--fixture` for deterministic offline verification and an opt-in `sync` mode that requires the secret. Default output reports counts, not domain payloads or credentials.
7. Extend the focused test for two-page pagination, duplicate retry, null fields, malformed item isolation, repeated-cursor failure, 429 recovery, and redacted errors.

### Hazards and Compatibility

- **Concurrency/atomicity:** One adapter invocation owns one source run; page writes use store transactions and must coexist with readers under WAL.
- **Migration/rollback:** The adapter targets the foundation schema version and fails before retrieval/writes on incompatibility; any later foundation migration remains outside this leaf.
- **Mixed-version/backward compatibility:** Unknown response fields are preserved in raw evidence and ignored by mapping; missing optional documented fields remain null.
- **Idempotency/retry:** Provider sale ID and observation hash make page/request retries safe. A repeated cursor fails the run instead of duplicating indefinitely.
- **Partial failure/recovery:** A failed later page marks the run failed and does not replace the last completed source freshness marker; a later run can resume from the start safely.

### Verification Before Dispatch

```bash
python3 .agents/scripts/domain-opportunity-namecheap.py --help
python3 .agents/scripts/domain-opportunity-namecheap.py sync --fixture .agents/scripts/tests/fixtures/domain-opportunity/namecheap-sales.json --db "$HOME/.aidevops/.agent-workspace/work/domain-opportunities/namecheap-smoke.sqlite"
python3 .agents/scripts/tests/test-domain-opportunity-namecheap.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Help and fixture sync exercise the production adapter/store path; focused tests prove pagination, mapping, retries, and redaction; changed lint covers new Python and fixture files.
- **Broad verification trigger:** Not required unless the worker changes shared credential or deployment tooling.

### Recoverability Checkpoint

- [ ] Focused fixture sync and tests pass.
- [ ] WIP commit created before broader gates: `wip: add Namecheap auction ingestion`
- [ ] Evidence-triggered broad verification then run: not required unless shared files change.

### Safety-Stop Recovery

- **Original objective:** Ingest Namecheap auctions read-only into the local evidence store.
- **Preserved user directions:** Local SQLite/CSV research, quantitative opportunity analysis, no interface replication.
- **Trigger and evidence:** Rate, auth, page-count, or timeout fuse; record sanitized failure class and source-run ID.
- **Completed and verified:** Commit fixture-backed mapping/pagination work before attempting optional live verification.
- **Remaining acceptance criteria:** Any live-only check stays optional; fixture and safety criteria remain mandatory.
- **Unsafe route not to repeat:** Unbounded pagination, bid endpoint calls, token logging, or rapid rate-limit retries.
- **Next safe route:** Re-run fixture mode, reduce page limit, or wait for provider reset.
- **Resume condition:** Compatible store plus valid authorized token for optional live smoke.
- **Owner and status:** Dispatched worker; `not-triggered` initially.

### Files Scope

- `.agents/scripts/domain-opportunity-namecheap.py`
- `.agents/scripts/domain_opportunity_namecheap.py`
- `.agents/scripts/tests/fixtures/domain-opportunity/namecheap-sales.json`
- `.agents/scripts/tests/test-domain-opportunity-namecheap.py`

## Acceptance Criteria

- [ ] Fixture mode imports documented active `.com` sales, preserves nulls/units/provenance, and returns deterministic counts.
- [ ] Two-page cursor traversal terminates correctly; duplicate execution adds no duplicate current listing or observation.
- [ ] Rate-limit/transient errors use bounded retry/backoff and never spin on a repeated cursor.
- [ ] Authentication failures and malformed responses leave the prior successful dataset queryable and mark only the current run failed.
- [ ] No implementation path calls a bid endpoint, logs a bearer token, or requires live credentials for tests.
- [ ] Production fixture sync, focused tests, and changed-file lint pass.

## Context & Decisions

- The official API is preferred over browser automation.
- Only read/list operations are in scope; bidding webhooks and user bid history are excluded.
- Provider valuations and keyword counts are observations with provider provenance, not guaranteed facts.
- Live verification is optional because credentials are intentionally unavailable to background workers.

## Relevant Files

- `.agents/aidevops/extension.md:157-172` — API integration security requirements.
- `.agents/scripts/keyword-research-helper-providers.sh` — existing provider request/error style to inspect, not blindly copy.
- `.agents/scripts/domain_opportunity_contract.py` — dependency-created normalized contract.
- `.agents/scripts/domain_opportunity_store.py` — dependency-created persistence API.

## Dependencies

- **Blocked by:** `t18296` / #30493
- **Blocks:** `t18302` / #30499
- **External:** Optional authorized Namecheap Market API token for a live smoke; official OpenAPI is public.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 30m | Merged store plus current OpenAPI |
| Implementation | 3h | Transport, mapping, pagination, persistence |
| Verification | 1h | Fixtures, failure paths, changed lint |
| **Total** | **4.5h** | |
