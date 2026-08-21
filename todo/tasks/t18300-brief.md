<!-- aidevops:brief-schema=v2 -->

# t18300: Enrich domain candidates with Google Ads demand metrics

## Pre-flight

- [x] Memory recall: `Google Ads Keyword Planner historical metrics domain opportunities` → 0 hits — no relevant stored lessons.
- [x] Discovery pass: no existing Google Ads API provider or matching open/merged PR; current GSC OAuth code is reference-only.
- [x] File refs verified: 6 repository paths/directories plus the current official API contract were checked.
- [x] Tier: `tier:standard` — the read-only method, fields, quota, auth inputs, persistence, and offline verification are specified; bounded implementation judgment remains.
- [x] Seeded draft PR decision recorded: skipped — code must target the merged store and the API version current when dispatched.

## Origin

- **Created:** 2026-08-21
- **Session:** `opencode:interactive-2026-08-21`
- **Created by:** `ai-interactive`
- **Parent task:** `t18295` / #30492
- **Blocked by:** `t18296` / #30493; dispatch remains blocked until the native `blockedBy` relationship is verified.
- **Conversation context:** Google Ads Keyword Planning provides more decision-useful quantitative demand, competition, and bid-range evidence than Trends alone.

## What

Implement a read-only Google Ads Keyword Planning adapter around `KeywordPlanIdeaService.GenerateKeywordHistoricalMetrics`. It must batch candidate phrases, preserve variant grouping and locale/network/date context, store monthly demand plus competition and bid-range evidence, cache/replay idempotently, and support fixture-only verification without account access.

The operation must never create campaigns, budgets, ads, or spend.

## Why

Average and monthly searches quantify demand, while competition and top-of-page bid ranges proxy commercial intent. Persisting the raw units and account currency makes the resulting opportunity analysis auditable rather than relying on qualitative trend curves.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The official API method and safety boundary are settled. The worker must implement version-aware REST mapping, OAuth/header handling, batching, caching, and partial-result behavior.

## PR Conventions

This leaf PR closes #30497 and may reference the parent with `For #30492`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The current API version and merged store interfaces must be re-verified immediately before implementation.
- **Status:** `not-created`
- **Freshness evidence:** Official Google Ads v25 docs and repository auth patterns checked on 2026-08-21.
- **Verification run:** Documentation research only; no developer token or customer request was used.
- **Stale-assumption warning:** Google Ads major versions deprecate; inspect current official docs/discovery and do not blindly retain v25.

## How (Approach)

### Progressive Context Plan

- **Read first:** merged `.agents/scripts/domain_opportunity_contract.py` and `domain_opportunity_store.py` — keyword metric identity and writes.
- **Read next:** `.agents/scripts/keyword-research-helper-webmaster.sh:39-68` — current Google token/error convention, while correcting any scope/API differences.
- **Load only if:** current Google Ads REST auth/version/quota docs — before implementing headers, resource names, or mappings.
- **Why:** Keep credentials ephemeral and make a changing third-party API version explicit evidence.
- **Stop when:** Current method version, request/response fields, quota, currency source, and fixture contract are verified.

### Worker Quick-Start

```text
Verified 2026-08-21 method: KeywordPlanIdeaService.GenerateKeywordHistoricalMetrics.
Verified current REST path: POST https://googleads.googleapis.com/v25/customers/{customerId}:generateKeywordHistoricalMetrics.
Required headers: Authorization Bearer token, developer-token; login-customer-id only for manager access.
OAuth scope: https://www.googleapis.com/auth/adwords.
Quota: 1 request/second per customer ID for this method; cache monthly results.
Version v25 is evidence, not a permanent constant: verify the current major before coding.
```

### Files to Modify

- `NEW: .agents/scripts/domain-opportunity-google-ads.py` — plan/fixture/live sync CLI.
- `NEW: .agents/scripts/domain_opportunity_google_ads.py` — REST client, batching, variant mapping, quota/backoff, cache identity, and store writes.
- `NEW: .agents/scripts/tests/fixtures/domain-opportunity/google-ads-historical-metrics.json` — synthetic/redacted documented-shape response plus request metadata.
- `NEW: .agents/scripts/tests/test-domain-opportunity-google-ads.py` — mapping, units, grouping, quota, retry, redaction, and idempotency checks.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/domain-opportunity-google-ads.py` reads candidate phrase rows through `.agents/scripts/domain_opportunity_store.py`; final reporting reads persisted keyword metric observations.
- **Writers/mutation paths:** `.agents/scripts/domain_opportunity_google_ads.py` writes only keyword metric/source-run records through `.agents/scripts/domain_opportunity_store.py`; it never mutates Google Ads resources.
- **Tests/fixtures:** `.agents/scripts/tests/test-domain-opportunity-google-ads.py` reads `.agents/scripts/tests/fixtures/domain-opportunity/google-ads-historical-metrics.json` and stubs REST/time; no live account is required.
- **Schemas/config:** `.agents/schemas/domain-opportunity-record.schema.json` plus merged keyword metric tables own persistence. Secrets are `GOOGLE_ADS_ACCESS_TOKEN` and `GOOGLE_ADS_DEVELOPER_TOKEN`; customer/login IDs and ISO currency are explicit runtime inputs or secret-backed configuration.
- **Generated/deployed mirrors:** `setup.sh --non-interactive` deploys scripts/fixture; runtime cache/evidence stays in the local SQLite workspace.
- **Migrations/backfills:** `.agents/scripts/domain_opportunity_store.py` owns schema versions and is not edited in this parallel leaf; if monthly series, variant groups, or locale resources cannot fit its typed API, stop with an exact foundation blocker.
- **Cleanup/rollback paths:** Removing `.agents/scripts/domain-opportunity-google-ads.py` disables collection without deleting prior metrics; failed batches retain prior completed observations and expire no cache entry.

### Implementation Steps

1. Verify the current official major version, discovery/request fields, response fields, and OAuth headers. Use standard-library REST and add no SDK or root dependency-manifest change in this parallel leaf.
2. Add `plan` to select eligible phrase readings lacking fresh metrics and group them by locale/network. Print counts and batch IDs, not customer identifiers.
3. Add fixture/live `sync`. Live mode requires OAuth access token, developer token, target customer ID, optional login customer ID, language resource, geo target resources, network, and verified ISO customer currency.
4. Map `results[].text`, `closeVariants`, and `keywordMetrics`: average monthly searches, monthly search volumes, competition, competition index, low/high top-of-page bid micros. Preserve absent values as null and micros as integers.
5. Persist API major version, language, geographies, network, account currency, normalized input phrase set/hash, retrieval date, returned text/variants, and metric source. Do not infer currency from the response because it is not returned there.
6. Treat result groups as unordered and not one-to-one with inputs. Link each input to its returned text/close-variant group or record a missing-result outcome.
7. Enforce no more than one request/second per customer ID, bounded retries honoring provider delay, a maximum batch/page fuse, and monthly freshness caching keyed by phrase set plus locale/network.
8. Add fixture tests for grouped variants, missing fields, micros, monthly series, 401/403, quota response, partial results, deterministic replay, and secret/account-ID redaction.

### Hazards and Compatibility

- **Concurrency/atomicity:** Serialize/throttle requests per customer alias and commit each returned batch transactionally; parallel readers and other providers remain unaffected.
- **Migration/rollback:** Foundation schema compatibility is checked before any request and this leaf performs no migration. API major version is recorded per run so older evidence remains interpretable.
- **Mixed-version/backward compatibility:** Current REST version is configurable/validated; unknown response fields are ignored/preserved, while missing required structure fails the batch without erasing older metrics.
- **Idempotency/retry:** Request identity uses normalized phrase set, locale/network, currency, and monthly period. Same response hash does not duplicate observations.
- **Partial failure/recovery:** One failed batch marks only that source run/batch failed; successful earlier batches remain queryable, and a later run retries stale/missing inputs.

### Verification Before Dispatch

```bash
python3 .agents/scripts/domain-opportunity-google-ads.py plan --fixture .agents/scripts/tests/fixtures/domain-opportunity/google-ads-historical-metrics.json --db "$HOME/.aidevops/.agent-workspace/work/domain-opportunities/google-ads-smoke.sqlite"
python3 .agents/scripts/domain-opportunity-google-ads.py sync --fixture .agents/scripts/tests/fixtures/domain-opportunity/google-ads-historical-metrics.json --currency USD --db "$HOME/.aidevops/.agent-workspace/work/domain-opportunities/google-ads-smoke.sqlite"
python3 .agents/scripts/tests/test-domain-opportunity-google-ads.py
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Plan/fixture sync prove production batching/mapping/store integration; focused tests cover units, versions, quotas, variants, failure and redaction; changed lint covers Python/fixture policy.
- **Broad verification trigger:** Required only if a shared credential helper is changed; a new Google SDK/dependency is outside this parallel leaf.

### Recoverability Checkpoint

- [ ] Current API contract evidence and fixture sync are verified.
- [ ] WIP commit created before broader gates: `wip: add Google Ads demand enrichment`
- [ ] Evidence-triggered broad verification then run: dependency/shared-auth gate only if those surfaces change.

### Safety-Stop Recovery

- **Original objective:** Add read-only Google Ads demand metrics to local candidate evidence.
- **Preserved user directions:** Quantify opportunity potential in SQLite/CSV; do not build a UI.
- **Trigger and evidence:** 1-request/second quota, 429/resource exhaustion, auth/access denial, API deprecation, batch/time fuse.
- **Completed and verified:** Preserve fixture-backed code and completed batch IDs; do not treat a fuse as success.
- **Remaining acceptance criteria:** Missing/stale phrases and any live smoke remain explicit.
- **Unsafe route not to repeat:** Rapid retries, parallel calls for one customer, logging tokens/IDs, or mutating campaign resources.
- **Next safe route:** Fixture mode, wait for reset, reduce batch count, or update the configurable official API version.
- **Resume condition:** Compatible current API version and authorized Basic/Standard developer-token access.
- **Owner and status:** Dispatched worker; `not-triggered` initially.

### Files Scope

- `.agents/scripts/domain-opportunity-google-ads.py`
- `.agents/scripts/domain_opportunity_google_ads.py`
- `.agents/scripts/tests/fixtures/domain-opportunity/google-ads-historical-metrics.json`
- `.agents/scripts/tests/test-domain-opportunity-google-ads.py`

## Acceptance Criteria

- [ ] Fixture/live request planning persists language, geographies, network, API major, account currency provenance, input hash, and retrieval month.
- [ ] Average/monthly searches, competition/index, and low/high bid micros retain documented units and nullability; grouped close variants are not misattributed by position.
- [ ] Exact replay of one fixture/request produces no duplicate metric observations, while a later retrieval month remains a distinct observation.
- [ ] Quota/auth/version/partial failures preserve earlier metrics and expose sanitized batch-level recovery state.
- [ ] No code path creates or changes campaigns/budgets/ads, incurs ad spend, logs tokens/customer IDs, or requires live credentials for tests.
- [ ] Production plan/fixture sync, focused tests, and changed-file lint pass; dependency gates run only if a new SDK is justified.

## Context & Decisions

- Google Ads metrics are the primary quantitative demand signal.
- Bid micros are commercial-intent evidence, not expected revenue or valuation.
- Currency must come from verified account configuration/query, not the historical-metrics response.
- A production developer token with permissible Basic/Standard access may be required; Explorer access is insufficient for this service.

## Relevant Files

- `.agents/scripts/keyword-research-helper-webmaster.sh:39-68` — current Google token/error reference pattern.
- `.agents/seo/keyword-research.md:95-116,156-174` — current demand/opportunity concepts.
- `.agents/scripts/domain_opportunity_store.py` — dependency-created keyword metric writer.
- `.agents/aidevops/extension.md:157-172` — API secret/rate/error safety.

## Dependencies

- **Blocked by:** `t18296` / #30493
- **Blocks:** `t18302` / #30499
- **External:** Optional authorized Google Ads customer, OAuth access token, developer token with Keyword Plan access, geo/language constants, and verified account currency for live sync. Fixture verification is fully local.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 45m | Current API version, auth, merged store |
| Implementation | 4h | Plan, REST mapping, cache, throttle, persistence |
| Verification | 1h | Fixture groups, failures, redaction, lint |
| **Total** | **5.75h** | |
