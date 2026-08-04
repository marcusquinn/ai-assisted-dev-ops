<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18124: Maximise GitHub API efficiency without freshness regressions

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `GitHub API efficiency telemetry cache snapshots rate limits webhooks` → 0 hits — no relevant indexed lesson; current source evidence is recorded below
- [x] Discovery pass: 2 target-file commits / 6 historical related issue families / 0 overlapping open PRs; the recent gh-shim recursion change does not implement this programme
- [x] File refs verified: 13 implementation and test surfaces checked, all present at `313548fc6`
- [x] Tier: `tier:thinking` — architectural parent coordinating seven ordered cache, transport, concurrency, and webhook phases
- [x] Seeded draft PR decision recorded: skipped — this parent is a tracker and each implementation must remain in its dependency-gated leaf

## Origin

- **Created:** 2026-07-15
- **Session:** OpenCode interactive GitHub API efficiency planning
- **Created by:** ai-interactive under maintainer direction
- **Parent task:** None
- **Blocked by:** None
- **Conversation context:** The maintainer requested an evidence-based plan that reduces actual GitHub HTTP requests, GraphQL points, duplicate reads, latency, and burst pressure without weakening freshness or merge correctness. The selected execution model is one worker at a time with Pulse advancing a native dependency chain.

## What

Coordinate seven implementation phases that first establish exact transport telemetry, then make empty cache results authoritative, reuse canonical snapshots, cache PR check status by head SHA, coalesce concurrent requests, invalidate state from verified webhooks, and finally benchmark the complete system. The result must show measured request and quota savings while preserving fail-closed dispatch, review, and merge decisions.

## Why

Current instrumentation counts logical wrapper calls rather than proven network attempts, cache consumers erase valid empty results, state fingerprints and verification queries refetch data already available in snapshots, check enrichment performs one REST request per PR, and rate-limit state is split between process-local and shared caches. Optimising before fixing observability would create unverifiable claims and could hide stale state, so the work must proceed in order.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** No — seven leaves span transport, cache, checks, concurrency, webhook, benchmark, and test surfaces.
- [ ] **Every target file under 500 lines?** No — the gh shim and Pulse prefetch helpers exceed 500 lines.
- [ ] **Exact oldString/newString for every edit?** No — each leaf owns a bounded design decision.
- [ ] **No judgment or design decisions?** No — canonical state and freshness boundaries require architectural trade-offs.
- [ ] **No error handling or fallback logic to design?** No — API uncertainty and stale-cache behavior must remain fail-closed.
- [ ] **No cross-package or cross-module changes?** No — shell, awk, Python, config, and tests coordinate.
- [ ] **Estimate 1h or less?** No — aggregate active AI estimate is 13 hours plus observation windows.
- [ ] **4 or fewer acceptance criteria?** No — every phase has positive and regression criteria.
- [x] **Dispatch-path classification:** None of the planned targets match `.agents/configs/self-hosting-files.conf`; the parent remains non-dispatchable by `parent-task` policy.

**Selected tier:** `tier:thinking`

**Tier rationale:** This is a non-dispatchable architectural tracker. Design and implementation judgment is isolated in seven worker-ready leaves rather than performed against the parent.

## PR Conventions

This issue carries `parent-task`. Planning and intermediate implementation PRs use a non-closing `For` or `Ref` parent reference. Leaf PRs close only their own child issue; the final benchmark phase may close the parent only after all children and parent acceptance criteria are verified.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** A parent tracker must not own implementation code, and a shared seed would overlap every child branch.
- **Status:** `not-created`
- **Freshness evidence:** Discovery and source verification ran against `313548fc6` after task IDs were allocated.
- **Verification run:** Planning readiness only; implementation tests are intentionally deferred to leaves.
- **Stale-assumption warning:** Re-run discovery before each child dispatch because the target helpers are active framework code.

## Phases

- Phase 1 — t18125 (GH#27769) measures exact transport attempts, retention, effective windows, and replayable budgets.
- Phase 2 — t18126 (GH#27770) preserves successful empty snapshots and establishes canonical cache-result semantics.
- Phase 3 — t18127 (GH#27771) reuses canonical snapshots and removes redundant fingerprint and verification requests.
- Phase 4 — t18128 (GH#27772) caches PR check status by head SHA and refreshes only actionable changes.
- Phase 5 — t18129 (GH#27774) adds cross-process single-flight and one shared rate-limit state contract.
- Phase 6 — t18130 (GH#27776) invalidates canonical state from authenticated, deduplicated webhook deliveries.
- Phase 7 — t18131 (GH#27777) compares baseline and canary data, tunes rollout, and retires flags only when safe.

All child issues are filed manually from their schema-v2 briefs. No phase auto-file markers are used, preventing duplicate children while native `blockedBy` relationships drive sequential eligibility.

## How (Approach)

### Progressive Context Plan

- **Read first:** `todo/tasks/t18125-brief.md` through `todo/tasks/t18131-brief.md` — each leaf contains the bounded write surface, hazards, tests, and API budget.
- **Load only if:** a child changes dependency or parent state — use `.agents/reference/task-lifecycle.md` and `.agents/reference/parent-task-lifecycle.md` to preserve native relationships and close guards.
- **Why:** The parent defines ordering and outcome metrics; leaves remain the only implementation authority.
- **Stop when:** all seven children are linked, the first alone is eligible, later children are natively blocked, and the benchmark records final evidence.

### Files to Modify

- `EDIT: .agents/scripts/gh-api-instrument.sh` — Phase 1 transport evidence and retention.
- `EDIT: .agents/scripts/pulse-batch-prefetch-helper.sh` — Phases 2, 3, and 6 canonical snapshot contract.
- `EDIT: .agents/scripts/shared-gh-wrappers-checks.sh` — Phase 4 head-SHA check cache.
- `EDIT: .agents/scripts/shared-gh-wrappers-rest-fallback.sh` — Phase 5 shared rate-limit state.
- `EDIT: .agents/scripts/pulse-merge-webhook-server.py` — Phase 6 verified invalidation events.
- `NEW: .agents/scripts/github-api-efficiency-benchmark.sh` — Phase 7 comparative evidence.

### Complete Write Surface

- **Callers/readers:** `todo/tasks/t18125-brief.md` through `todo/tasks/t18131-brief.md` list exact callers; the parent reads only child issue/PR state and final benchmark evidence.
- **Writers/mutation paths:** `.agents/scripts/gh-api-instrument.sh` and the cache/webhook/benchmark paths in each leaf isolate transport log, snapshot, check, rate-limit, delivery-ledger, and report writes.
- **Tests/fixtures:** `.agents/scripts/tests/` focused shell/Python fixtures are named in every leaf; Phase 7 consumes their stable outputs rather than replacing them.
- **Schemas/config:** `.agents/scripts/gh-api-instrument.sh`, `.agents/configs/webhook-receiver.conf`, and leaf cache/report files keep schemas versioned or backward-compatible.
- **Generated/deployed mirrors:** `.agents/` sources deploy through `setup.sh`; no deployed runtime copy is edited directly.
- **Migrations/backfills:** `todo/tasks/t18125-brief.md` through `todo/tasks/t18131-brief.md` require legacy reads or safe cold misses; no one-shot destructive migration is permitted.
- **Cleanup/rollback paths:** `.agents/configs/pulse-sweep-budget.json` plus leaf feature flags and additive cache versions permit phase-local rollback; Phase 7 removes flags only after evidence.

### Implementation Steps

1. Create and link all child issues to this parent, then create the linear native dependency chain `t18126` through `t18131`.
2. Keep `t18125` available and unassigned; keep every downstream child `status:blocked` until its native blocker closes.
3. Let Pulse dispatch one child at a time, run each focused verification suite, and merge the leaf before promoting its successor.
4. Keep this parent open until Phase 7 confirms both savings and correctness/freshness guardrails.

### Hazards and Compatibility

- **Concurrency/atomicity:** Only one child runs at a time because prefetch and wrapper files overlap; native dependency state is the authoritative gate.
- **Migration/rollback:** Every leaf is independently reversible and retains prior behavior behind a temporary flag when mixed versions could disagree.
- **Mixed-version/backward compatibility:** Old readers must tolerate additive fields; new readers must distinguish legacy or unknown state and fail closed where correctness depends on it.
- **Idempotency/retry:** Relationship creation and status promotion are idempotent; retries must not file duplicate children or duplicate PRs.
- **Partial failure/recovery:** A failed child remains open and blocks successors. Safety stops preserve the branch/PR and never mark parent criteria complete.

### Verification Before Dispatch

```bash
for brief in todo/tasks/t1812{5,6,7,8,9}-brief.md todo/tasks/t1813{0,1}-brief.md; do .agents/scripts/verify-brief-helper.sh check-readiness "$brief"; done
.agents/scripts/issue-sync-helper.sh relationships
```

- **Surface mapping:** Brief readiness proves each leaf is dispatchable; relationship sync and GitHub inspection prove parent/subissue and blocked-by ordering.
- **Broad verification trigger:** The parent has no implementation diff; broad source verification belongs to each leaf and final benchmark.

### Recoverability Checkpoint

- [ ] Focused tests pass: every child-specific command recorded in its PR
- [ ] WIP commit created before broad gates: each leaf creates its own recoverable WIP checkpoint
- [ ] Evidence-triggered broad verification then run: Phase 7 verifies the integrated programme after all focused suites

### Safety-Stop Recovery

- **Original objective:** Maximise GitHub API efficiency without correctness or freshness regressions.
- **Preserved user directions:** Use a parent plus seven gated leaves, dispatch telemetry first, and let Pulse progress sequentially.
- **Trigger and evidence:** Not triggered at brief creation.
- **Completed and verified:** Discovery, source verification, task allocation, and phase decomposition.
- **Remaining acceptance criteria:** All implementation, canary, and benchmark criteria below.
- **Unsafe route not to repeat:** Do not dispatch downstream phases before their blocker closes or claim savings from logical-call counts.
- **Next safe route:** Resume from the earliest open child in the native chain.
- **Resume condition:** Its predecessor is closed, readiness still passes, and no target-file collision exists.
- **Owner and status:** Pulse plus one worker at a time; not-triggered.

### Files Scope

- `.agents/scripts/gh-api-instrument.sh`
- `.agents/scripts/gh-api-aggregate.awk`
- `.agents/scripts/gh`
- `.agents/scripts/pulse-batch-prefetch-helper.sh`
- `.agents/scripts/pulse-prefetch-fetch.sh`
- `.agents/scripts/pulse-prefetch-infra.sh`
- `.agents/scripts/pulse-prefetch-repo.sh`
- `.agents/scripts/pulse-pr-list-cache.sh`
- `.agents/scripts/shared-gh-wrappers-checks.sh`
- `.agents/scripts/shared-gh-wrappers-rest-fallback.sh`
- `.agents/scripts/pulse-rate-limit-circuit-breaker.sh`
- `.agents/scripts/pulse-merge-webhook-receiver.sh`
- `.agents/scripts/pulse-merge-webhook-server.py`
- `.agents/configs/webhook-receiver.conf`
- `.agents/scripts/github-api-efficiency-benchmark.sh`
- `.agents/reference/github-api-efficiency.md`
- `.agents/scripts/tests/test-gh-api-instrument.sh`
- `.agents/scripts/tests/test-pulse-batch-prefetch-conditional-rest.sh`
- `.agents/scripts/tests/test-gh-wrapper-rest-fallback.sh`
- `.agents/scripts/tests/test-pulse-merge-webhook-invalidation.py`
- `.agents/scripts/tests/test-github-api-efficiency-benchmark.sh`

## Acceptance Criteria

- [ ] All seven child issues are native subissues, and `t18126` through `t18131` each have exactly one predecessor in the native blocked-by chain.
- [ ] Transport telemetry reports actual attempts, retries, pagination, cache decisions, elapsed time, and quota cost without recording credentials or sensitive payloads.
- [ ] Successful empty snapshots, exact snapshot reuse, head-SHA check caching, single-flight, and webhook invalidation reduce measured network attempts and quota cost.
- [ ] Dispatch, review, required-check, and merge gates never use stale or unknown cached evidence as positive authority.
- [ ] No downstream child dispatches while its predecessor is open, and parent completion never occurs before every child and final benchmark criterion is complete.
- [ ] Phase 7 records baseline/canary medians and totals over comparable effective windows, with rollback decisions for any correctness or freshness regression.

## Context & Decisions

- Measurement precedes optimisation so savings are attributable to transport changes rather than logical wrapper counts.
- Empty arrays are valid successful snapshots; process exit status and explicit metadata distinguish them from misses or failures.
- Existing exact-output PR cache and shared circuit-breaker cache are reference implementations to consolidate, not duplicate.
- Webhooks invalidate state but do not replace bounded polling or final live authority checks.
- Observation windows make wall-clock completion longer than active implementation time.

## Terminal Closeout (2026-08-04)

### Delivered

- All seven planned leaves are native subissues and terminal. Phases 1–6 completed through PRs #27798, #28201, #28206, #28210, #28222, and #28231.
- The implementation now records exact transport attempts, preserves successful empty snapshots, reuses canonical snapshots, caches terminal check projections by immutable head SHA, coalesces cross-process reads, shares rate-limit state, and invalidates cached state from verified webhook deliveries.
- Phase 7 produced the deterministic benchmark and repeatedly exercised exact-runtime observation. PR #29481 records the final maintainer-authorized no-go after the exact-cost preflight rejected three successful GraphQL requests whose operation-owned quota cost remained unknown.
- The final preflight proved the safety boundary: unknown quota evidence remained unknown and prevented a passing comparison. Runtime overrides, observation jobs, and pins were restored afterward.

### Acceptance outcome

- **Satisfied:** the seven planned child issues are linked in order and terminal; implementation phases 1–6 merged with their focused verification.
- **Satisfied:** stale or unknown cached evidence is not accepted as positive dispatch, review, required-check, or merge authority.
- **Not proven:** aggregate network-attempt and quota-cost reduction over comparable baseline/canary windows. The final window was intentionally rejected rather than treating unknown successful GraphQL cost as zero.
- **Not performed:** evidence-dependent TTL tuning, threshold weakening, rollout-flag retirement, or publication.

### Decision

Treat the deployed implementation as the best reasonable bounded state from this programme, not as proof of a mathematical or globally maximal reduction. The known safe engineering optimisations shipped, correctness/freshness authority stayed fail-closed, and further tuning would be speculative without authoritative GraphQL operation cost.

Close t18124 as `not planned` rather than `completed` because its comparative programme-level acceptance criterion was not met. Do not retry the observation protocol or remove retained rollback controls unless a changed technical premise provides authoritative cost for successful GraphQL operations and a maintainer explicitly authorizes new measurement work.

## Relevant Files

- `.agents/scripts/gh-api-instrument.sh:45-55,98-175,238-251` — current logical-call record and fixed line retention.
- `.agents/scripts/pulse-prefetch-fetch.sh:205-248,339-381` — current batch-cache rejection of valid empty arrays.
- `.agents/scripts/pulse-prefetch-infra.sh:229-367,440-460` — duplicate fingerprint and verification reads.
- `.agents/scripts/shared-gh-wrappers-checks.sh:90-128,227-280` — per-head check state and sequential fan-out.
- `.agents/scripts/shared-gh-wrappers-rest-fallback.sh:292-342` — process-local fallback cache.
- `.agents/scripts/pulse-rate-limit-circuit-breaker.sh:79-159` — existing shared rate-limit cache.
- `.agents/scripts/pulse-merge-webhook-server.py:26-37,136-186` — authenticated event receiver without delivery deduplication or cache invalidation.

## Dependencies

- **Blocked by:** None.
- **Blocks:** t18125 through t18131 as the durable roadmap and close guard.
- **External:** GitHub API and webhook deliveries; no new paid service or credential class.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Active implementation | 9h | Seven bounded code phases |
| Focused tests and docs | 4h | Fixtures, lint, benchmark contract |
| Observation | 2–4 days wall clock | 12–24h baseline plus canaries |
| **Total** | **13h active** | Sequential worker execution |
