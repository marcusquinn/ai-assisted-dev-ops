<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18131: Benchmark API savings, tune rollout, and retire flags

Parent: t18124

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `GitHub API efficiency benchmark canary rollout feature flags` → 0 hits — no relevant indexed lesson
- [x] Discovery pass: 2 current target-file commits / 0 overlapping open PRs; implementation-specific flags are intentionally not yet present
- [x] File refs verified: 6 source/config/reference/test surfaces checked, all present at `313548fc6` or verified new-file parents
- [x] Tier: `tier:standard` — deterministic report/tooling plus evidence-led tuning after prior architectural work
- [x] Seeded draft PR decision recorded: skipped — benchmark implementation depends on final schemas from all six preceding leaves

## Origin

- **Created:** 2026-07-15
- **Session:** OpenCode interactive GitHub API efficiency planning
- **Created by:** ai-interactive under maintainer direction
- **Parent task:** t18124
- **Prerequisite:** t18130 closed on 2026-07-18; remaining progress is evidence-gated, not dependency-blocked.
- **Conversation context:** The final phase must compare equivalent baseline and canary windows using t18125 transport evidence, verify that request savings did not hide stale or incorrect decisions, tune bounded TTLs/limits, and remove temporary rollout flags only after the data supports doing so.

## What

Create a deterministic benchmark/report command that compares baseline and canary telemetry over their actual retained windows. Report absolute and normalized HTTP attempts, GraphQL points, REST/search use, retries/pages, latency and burst metrics, cache/single-flight/webhook outcomes, API errors, and freshness/correctness guardrails. Tune documented defaults, record rollback decisions, and remove phase flags/dead compatibility branches only when their canaries pass.

## Why

Local request-count tests prove specific paths, but they cannot establish system-level savings or detect shifted costs, higher error rates, stale state, delayed dispatch/merge, or burst regressions. The programme is complete only when comparable real observations demonstrate lower transport/quota use and every correctness/freshness invariant remains intact.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** No — benchmark tool, tests, reference, telemetry adapter, and final config/flag cleanup coordinate.
- [ ] **Every target file under 500 lines?** No — telemetry source and phase-owned cleanup files may exceed 500 lines.
- [ ] **Exact oldString/newString for every edit?** No — final cleanup depends on merged phase manifests and observed canary data.
- [ ] **No judgment or design decisions?** No — tuning/rollback decisions must interpret measured guardrails.
- [ ] **No error handling or fallback logic to design?** No — incomplete/noncomparable windows must fail without a misleading result.
- [ ] **No cross-package or cross-module changes?** No — shell, config, docs, tests, and prior phase flags interact.
- [ ] **Estimate 1h or less?** No — estimated two hours active plus canary observation.
- [ ] **4 or fewer acceptance criteria?** No — comparability, savings, correctness, cleanup, and audit evidence are separate.
- [x] **Dispatch-path classification:** Current targets do not match `.agents/configs/self-hosting-files.conf`; re-run classification after discovering final flag locations.

**Selected tier:** `tier:standard`

**Tier rationale:** The report follows the final telemetry schema and deterministic comparison rules. Human-style taste is not needed, but data quality and cleanup decisions require more than a mechanical edit.

## PR Conventions

Final leaf task. Its PR closes this child. It may close parent t18124 only when every earlier child is closed and the parent acceptance criteria are explicitly evidenced; otherwise use a non-closing parent reference.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Skipped at planning time because final report fields, feature flags, and cleanup surfaces did not exist before t18125–t18130 merged.
- **Status:** `not-created`; interactive implementation is active.
- **Freshness evidence:** Telemetry, shim, benchmark, reference, and test surfaces were rechecked against `659cd3d8f` on 2026-07-20.
- **Verification run:** Quota instrumentation/shim suites, benchmark/evidence fixtures, ShellCheck, changed lint, and complexity regressions pass; official comparable live evidence remains pending.
- **Scope refresh:** Direct REST quota attribution paths were added before implementation; ambiguous and GraphQL costs remain fail-closed.

## How (Approach)

### Progressive Context Plan

- **Read first:** t18125–t18130 merged PR summaries and changed-file manifests — establish final schemas, flags, defaults, and rollback switches without rereading unrelated modules.
- **Then read:** `.agents/scripts/gh-api-instrument.sh`, `.agents/scripts/gh-api-aggregate.awk`, and the baseline/canary report files — define comparable windows and normalized metrics.
- **Load only if:** a rollout regression appears — read the owning child brief's Safety-Stop Recovery and revert/tuning guidance.
- **Why:** Final cleanup must be evidence-led and cannot guess file paths or remove emergency controls before observation.
- **Stop when:** report comparability passes, savings and guardrails are recorded, defaults are justified, flags are either removed or retained with owner/expiry, and parent close readiness is explicit.

### Worker Quick-Start

```bash
git log --oneline --name-only --grep='t1812[5-9]\|t18130' -- .agents/scripts .agents/configs .agents/reference
rg -n 'AIDEVOPS_.*(CACHE|SNAPSHOT|SINGLE|WEBHOOK|GH_API)|feature.flag|rollout|compat' .agents/scripts/gh-api-instrument.sh .agents/scripts/pulse-* .agents/scripts/shared-gh-* .agents/configs
```

### Files to Modify

- `NEW: .agents/scripts/github-api-efficiency-benchmark.sh` — validate and compare baseline/canary telemetry with machine-readable and Markdown output.
- `NEW: .agents/scripts/tests/test-github-api-efficiency-benchmark.sh` — fixtures for comparable, incomplete, unequal-window, regression, and pass outcomes.
- `NEW: .agents/reference/github-api-efficiency.md` — metric definitions, request budgets, rollout defaults, rollback thresholds, and operator commands.
- `NEW: .agents/scripts/gh-quota-attribution-lib.sh` — classify only documented exact primary-cost outcomes for direct REST requests; preserve unknown evidence for GraphQL and ambiguous transports.
- `EDIT: .agents/scripts/gh` — pass defensible direct REST success costs into transport instrumentation without changing command output or status.
- `EDIT: .agents/scripts/gh-api-instrument.sh` — add only a thin benchmark/report dispatch if needed; do not duplicate aggregation logic.
- `EDIT: .agents/scripts/tests/test-gh-shim.sh` and `.agents/scripts/tests/test-gh-api-instrument.sh` — cover fixed REST costs, documented zero-cost requests, and fail-closed ambiguous/failure paths.
- `EDIT: .agents/configs/pulse-sweep-budget.json` — remove obsolete verification settings and tune surviving bounded polling defaults when evidence supports it.
- `EDIT: .agents/configs/webhook-receiver.conf` — tune ledger/event defaults only from canary evidence; retain secure loopback and bounded limits.
- `EDIT: exact flag-owning files from t18125–t18130 manifests` — not yet knowable because those flags do not exist; update issue/brief scope with concrete paths before dispatch if they fall outside the paths above.

### Complete Write Surface

- **Callers/readers:** Operators/CI invoke `.agents/scripts/github-api-efficiency-benchmark.sh`; parent closeout reads its Markdown/JSON result and phase modules read tuned configs.
- **Writers/mutation paths:** `.agents/scripts/github-api-efficiency-benchmark.sh` writes reports atomically without runtime mutation; cleanup edits only paths discovered in merged child manifests.
- **Tests/fixtures:** `.agents/scripts/tests/test-github-api-efficiency-benchmark.sh` supplies deterministic telemetry windows with known attempts, points, retries, latency, cache events, errors, and guardrails; shim/instrument fixtures prove that only authoritative direct REST costs become known.
- **Schemas/config:** `.agents/reference/github-api-efficiency.md` defines versioned input/output and `.agents/configs/pulse-sweep-budget.json` plus webhook config retain validated fields.
- **Generated/deployed mirrors:** `.agents/scripts/github-api-efficiency-benchmark.sh`, `.agents/configs/`, and `.agents/reference/github-api-efficiency.md` deploy through setup; reports remain local artifacts.
- **Migrations/backfills:** `.agents/scripts/github-api-efficiency-benchmark.sh` never rewrites telemetry; incompatible/legacy windows are noncomparable and compatibility readers retain an explicit removal task/date.
- **Cleanup/rollback paths:** `.agents/configs/pulse-sweep-budget.json` records prior tuned defaults and rollback triggers; uncertain flags remain with owner/expiry rather than losing the safety route.

### Implementation Steps

1. Discover merged child manifests and create an exact table of feature flags, cache schema versions, TTLs, limits, invalidators, fallback routes, and focused tests. Update this brief/issue before editing any newly discovered out-of-scope path.
2. Implement a benchmark CLI accepting explicit baseline/canary inputs and labels. Validate schema, first/last attempt timestamps, effective duration, repository/cycle population, and completeness; refuse comparisons with insufficient or materially non-equivalent data.
3. Report totals and normalized values per repo-hour, Pulse cycle, unchanged cycle, actionable change, and unique head SHA where available: attempts, GraphQL points, REST/search calls, retries/pages, p50/p95 elapsed time, peak short-window burst, API errors, cache hit classes, single-flight waits/takeovers, and webhook invalidations/lag.
4. Add guardrail inputs/results for stale snapshot detections, forced live refreshes, dispatch dependency violations, required-check/merge preflight mismatches, missed webhook recovery, and completed action latency. Unknown guardrail evidence prevents a pass.
5. Compare path-level budgets: no fingerprint/verification list calls, no live fallback after fresh empty hit, at most one aggregate check fetch per unique actionable SHA, one leader per identical concurrent read, and no duplicate webhook actions.
6. Tune only bounded TTL/limits supported by canary evidence. Remove obsolete flags/dead branches and stale config fields; retain uncertain controls with rationale, owner, and expiry. Run all owning phase tests after cleanup.
7. Attach a privacy-safe summary to the child/parent, list exact rollback triggers and retained flags, and close the parent only if every criterion is evidenced.
8. Attribute documented primary cost only for successful direct `github.com` REST calls. Keep cached, conditional, failed, enterprise, opaque-pagination, and GraphQL calls unknown unless their own operation supplies authoritative cost evidence; never use concurrent cumulative-header differencing.

### Hazards and Compatibility

- **Concurrency/atomicity:** Benchmark inputs may still be appended; require immutable copies or fixed timestamp bounds and write reports atomically.
- **Migration/rollback:** Flag/default cleanup follows canary success and records prior values. A regression restores the prior bounded defaults without changing telemetry history.
- **Mixed-version/backward compatibility:** Do not compare mixed schemas as equivalent. Retain legacy readers until the observed fleet is converged or document a separate cleanup task.
- **Idempotency/retry:** Re-running with identical inputs/options yields byte-stable metrics apart from an explicitly separated generation timestamp; source cleanup is independently testable.
- **Partial failure/recovery:** Missing windows, unknown quota cost, incomplete retention, or failed guardrails yield `INCONCLUSIVE`/`REGRESSION`, never a fabricated pass. Keep the parent open; after the approved deadline run, do not automatically retry this leaf.
- **Quota attribution:** REST has documented fixed request charges and zero-cost exceptions, but arbitrary GraphQL and higher-level `gh` operations expose no concurrency-safe per-operation cost. Partial attribution must reduce unknowns without relaxing the benchmark's zero-unknown gate.

### Complexity Impact

- **Target functions:** New benchmark functions plus small existing config/dispatch edits.
- **Current line count:** New files begin at zero; existing telemetry helpers are moderate.
- **Estimated growth:** Benchmark under 250 shell lines plus fixtures/reference, with functions under 80 lines.
- **Projected post-change:** No existing function should cross a threshold; avoid embedding comparison logic in `gh-api-instrument.sh`.
- **Action required:** Keep parsing, normalization, comparison, guardrails, and rendering as separate explicit-return helpers.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-github-api-efficiency-benchmark.sh
shellcheck .agents/scripts/github-api-efficiency-benchmark.sh .agents/scripts/tests/test-github-api-efficiency-benchmark.sh .agents/scripts/gh-api-instrument.sh
python3 -m json.tool .agents/configs/pulse-sweep-budget.json >/dev/null
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Benchmark fixtures prove comparability/fail-closed/pass math; ShellCheck and JSON validation cover tool/config syntax; changed lint plus all child owning tests prove cleanup has no regression.
- **Broad verification trigger:** Required because final cleanup may touch several shared API paths; run normal required CI and repeat the canary after any default change.

### Recoverability Checkpoint

- [x] Focused tests pass: quota instrumentation/shim suites plus benchmark/evidence fixtures
- [x] WIP commit created before post-rebase broad gates: `GH#27777: attribute exact direct REST quota cost`
- [x] Terminal evidence gate: changed lint passed; the final preflight rejected unknown GraphQL cost, so the knowingly invalid canary was not launched

### Safety-Stop Recovery

- **Original objective:** Prove and safely finalise lower GitHub API use without correctness or freshness regression.
- **Preserved user directions:** Use one production Pulse execution path, avoid competing schedulers and repeated tuning loops, and finish with a binary adopt/no-go decision.
- **Trigger and evidence:** The approved final preflight retained three successful GraphQL attempts without authoritative per-operation cost, so the zero-unknown gate failed before matched windows began.
- **Completed and verified:** Benchmark/report tooling and bounded exact direct REST quota attribution remain implemented. The final preflight failed closed, restored operator state, and produced the terminal no-go decision below.
- **Remaining acceptance criteria:** The original live comparison and adoption criteria remain unmet; this leaf closes as not adopted, and parent t18124 is not close-ready.
- **Unsafe route not to repeat:** Do not compare unequal retained windows, hide unknown quota cost, or delete rollback flags before canary success.
- **Next safe route:** No automatic retry. A future attempt requires a separately authorised task that first supplies authoritative operation-owned GraphQL cost or explicitly revises the acceptance contract.
- **Resume condition:** Explicit new authority plus a changed technical premise; elapsed time or another random workload sample is insufficient.
- **Owner and status:** Build+ `tier:standard`; terminal no-go on 2026-08-04.

### Post-release evidence (2026-07-20)

- Exact direct REST attribution shipped in `v3.32.160`; `v3.32.161` subsequently became the active release without changing the attribution contract.
- The first fully post-release `297s` window recorded 525 attempts, 371 known quota points, and 154 unknown-cost attempts. The unknowns split into 108 GraphQL attempts and 46 REST attempts; 66 of the GraphQL attempts were explicit REST-translator fallbacks.
- A later `299s` `v3.32.161` window recorded 634 attempts, 490 known quota points, and 130 unknown-cost attempts. Its 48 GraphQL attempts remained unknown by policy; 48 of 82 unknown REST attempts failed, so success did not prove whether GitHub charged them.
- Both windows contained long-lived pre-attribution producers alongside current runtimes. In the later window, the same explicit-pagination route produced 101 known and 16 unknown successful page costs, confirming mixed producer generations rather than a current classifier failure. These windows are observations, not comparable canaries.
- The provisional benchmark returned `INCONCLUSIVE` with 47 decision reasons. The canary sidecar was incomplete, quota remained unknown, and webhook/guardrail coverage remains deliberately unowned as documented in `.agents/reference/github-api-efficiency.md`.
- Decision at that checkpoint: retain every rollout and rollback control and do not tune defaults or retire flags. The later deadline authorisation superseded only the indefinite-open state by permitting a terminal no-go; it did not relax any evidence gate.

### Final deadline run and terminal decision (2026-08-04)

- PR #29453 merged the residual exact-attribution fixes as `fca5c68796f359381e248a61cf82bd32102eb629`. A pinned 360-second smoke then passed with 258 exact attempts, 230 known quota points, and zero unknown-cost attempts.
- The following long baseline was invalidated rather than reused: its controller had a 37,434-second liveness gap, retained only one scheduled webhook receipt, restored every managed runtime state, and never produced a comparable window.
- The maintainer explicitly authorised one final 10-hour baseline plus 10-hour canary, with production Pulse as the sole worker launcher, activation/gate boundary probes only, idle-sleep prevention, no retries, and a binary adopt/no-go closeout.
- The final 360-second preflight observed 276 exact attempts and 267 known quota points. Three successful `graphql-selected` attempts returned HTTP 200 with healthy recorded budgets, but lacked authoritative operation-owned cost. Report digest: `5bc6ec1171bf4227e2cf04a374f8557863a0423ab10afb73b24161771f034162`.
- The zero-unknown gate therefore rejected the sample. The matched windows and comparator were intentionally not started, avoiding a knowingly non-comparable 20-hour run. The managed profile and runtime pin were removed, no observation jobs remained loaded, and the normal active runtime was restored.
- **Decision:** terminal no-go. Do not claim aggregate savings, tune defaults, remove dead compatibility fields, or start another observation loop. `v3.32.220` improves exact REST attribution and keeps event refill behind Pulse's existing singleton lock, but this run supplies no direct worker-throughput proof.
- **Retained controls:** `AIDEVOPS_GH_CHECK_STATUS_CACHE_DISABLE`, `AIDEVOPS_GH_REQUEST_STATE_DISABLE`, `AIDEVOPS_GH_REQUEST_STATE_RATE_DISABLE`, `AIDEVOPS_GH_SINGLEFLIGHT_DISABLE`, `PULSE_BATCH_CONDITIONAL_REST_ENABLED`, `PULSE_BATCH_PREFETCH_ENABLED`, and `PULSE_BATCH_SEARCH_LAST_RESORT` remain unchanged. Their owner is parent t18124; they have no automatic expiry and may be removed only by separately authorised complete comparable evidence. `PULSE_BATCH_PREFETCH_ENABLED=0` remains the broad rollback route.

### Files Scope

- `.agents/scripts/github-api-efficiency-benchmark.sh`
- `.agents/scripts/tests/test-github-api-efficiency-benchmark.sh`
- `.agents/reference/github-api-efficiency.md`
- `.agents/scripts/gh-quota-attribution-lib.sh`
- `.agents/scripts/gh`
- `.agents/scripts/gh-api-instrument.sh`
- `.agents/scripts/gh-api-aggregate.awk`
- `.agents/scripts/tests/test-gh-shim.sh`
- `.agents/scripts/tests/test-gh-api-instrument.sh`
- `.agents/configs/pulse-sweep-budget.json`
- `.agents/configs/webhook-receiver.conf`
- `.agents/scripts/pulse-batch-prefetch-helper.sh`
- `.agents/scripts/pulse-prefetch-infra.sh`
- `.agents/scripts/shared-gh-wrappers-checks.sh`
- `.agents/scripts/shared-gh-request-state.sh`
- `.agents/scripts/pulse-merge-webhook-server.py`
- `.agents/scripts/pulse-merge-webhook-receiver.sh`

## Acceptance Criteria

- [ ] Benchmark rejects incomplete, incompatible, or materially non-equivalent retained windows and never reports unknown quota/freshness evidence as zero or pass.
- [ ] Comparable output reports absolute and normalized attempts, GraphQL points, REST/search use, retries/pages, latency, bursts, API errors, cache/single-flight/webhook outcomes, and effective windows.
- [ ] Canary evidence confirms removal of duplicate fingerprint/verification reads, empty-hit live fallback, unchanged-head check fan-out, identical concurrent fetches, and duplicate webhook actions.
- [ ] Dispatch dependencies, snapshot freshness, required checks, review state, and final merge authority show no stale-positive or correctness regression; unknown guardrails keep the result non-passing.
- [ ] Every tuned default has baseline/canary evidence and a rollback trigger; every removed or retained flag has a recorded rationale, owner, and compatibility decision.
- [ ] All phase-focused tests, benchmark fixtures, ShellCheck, changed lint, required CI, and final canary pass before parent t18124 is closed.

Closure note: these adoption criteria are intentionally not reinterpreted as passing. The maintainer-authorised deadline protocol terminated this leaf as a verified no-go after the preflight correctly rejected unknown GraphQL cost; parent t18124 remains open.

## Context & Decisions

- Comparable effective windows matter more than configured window labels.
- Path-level deterministic budgets complement, but do not replace, real aggregate observation.
- Inconclusive evidence keeps flags and parent open; after the separately authorised deadline protocol it closes this leaf as a recorded no-go rather than triggering another automatic attempt.
- Exact universal GraphQL cost attribution is unavailable from cumulative response headers under concurrency; unknown costs remain unknown rather than being estimated or promoted to zero.
- Release `v3.32.160` was separately authorised and completed; any further publication still requires separate authorisation.

## Relevant Files

- `.agents/scripts/gh-api-instrument.sh:178-251` — source telemetry and retained-window contract.
- `.agents/scripts/gh:387-436` — native transport boundary where direct REST cost provenance can be attached without changing command output.
- `.agents/scripts/gh-api-aggregate.awk:72-130` — machine-readable aggregate source.
- `.agents/configs/pulse-sweep-budget.json` — current polling/cache defaults and obsolete verification field candidate.
- `.agents/configs/webhook-receiver.conf` — webhook event/ledger defaults after t18130.
- `.agents/scripts/tests/test-dispatch-dedup-gh-call-budget.sh` — deterministic request-budget test pattern.

## Dependencies

- **Blocked by:** No open task dependency; t18130 is closed.
- **Blocks:** Parent t18124 remains open with its comparative-adoption criteria unmet; this terminal leaf must not be auto-retried.
- **External:** Fixed baseline/canary observation windows; no paid service or new credential.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Discovery/design | 30m | Final schemas, flags, comparability rules |
| Implementation | 45m | Benchmark, reference, config cleanup |
| Tests/report | 45m | Fixtures, owning suites, closeout evidence |
| Observation | 12–24h wall clock | Repeated bounded observations ended in the terminal no-go recorded above |
| **Total** | **2h active** | |
