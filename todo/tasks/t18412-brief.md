<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
<!-- aidevops:brief-schema=v2 -->

# t18412: Evaluate user time and economic leverage across representative workflows

## Pre-flight

- [x] Memory recall: maintainer purpose and the six-cell pilot's limitations are preserved in repo planning/evidence.
- [x] Discovery pass: FrontierHarness and model-replay tooling already exist; this task extends outcome measurement, not another benchmark platform.
- [x] File refs verified: pilot guide/results, model-replay workflow/runner/tests and self-improvement metrics guidance checked at `5393632ee`.
- [x] Tier: thinking; meaningful baselines, privacy and value attribution require judgment and explicit unknowns.
- [x] Seeded draft PR decision recorded: skipped pending predecessor delivery and representative task selection.

## Origin

- **Created:** 2026-09-05; **Created by:** ai-interactive in OpenCode.
- **Parent task:** t18402 — `todo/tasks/t18402-brief.md`.
- **Blocked by:** t18404, t18408, t18409, t18410 and t18411.

## What

Deliver a bounded, repeatable evaluation protocol and initial report that measures
verified outcomes, user time/attention, maintenance cost and economic value across
representative information workflows. Compare installed/focused/lighter profiles
using existing tooling; state unmeasured value explicitly rather than substituting
tokens or task counts for user benefit.

## Why

The 100x value-generation ambition concerns user capability, not a single coding
leaderboard. The pilot used one terminal task, a plugin/guide profile, one sample
per cell and subscription OAuth; it cannot establish broad quality, value or
cost superiority. Larger upfront work may be worthwhile when reusable assets
eliminate recurring human work, but maintenance and correction costs must count.

## Tier

**Selected tier:** `tier:thinking` — baseline selection, attribution, privacy and representative outcome design.

## How (Approach)

### Files to Modify

- `NEW: .agents/reference/value-evaluation.md` — protocol and metric definitions, modelled on the evidence/limitations discipline in the existing pilot guide.
- `EDIT: .agents/tools/ai-assistants/frontier-harness-eval.md` and existing `.agents/scripts/frontier-harness-report.mjs` only for reused report fields/coverage needed by the protocol.
- `.agents/workflows/model-replay.md`, `.agents/scripts/model-replay-benchmark.mjs` and `.agents/reference/self-improvement.md` are existing integration/metric owners; exact additional writer paths depend on the selected existing workflow and must be recorded before edits.

### Complete Write Surface

- **Callers/readers:** user/maintainer reports, `.agents/reference/self-improvement.md` and existing replay/pilot analysis consumers.
- **Writers/mutation paths:** existing `frontier-harness-report.mjs`/model-replay writers and a bounded repo-native report; do not introduce another general telemetry database.
- **Tests/fixtures:** `.agents/scripts/tests/test-frontier-harness.mjs` and `.agents/scripts/tests/test-model-replay-benchmark.mjs`; reuse redacted existing cases where available.
- **Schemas/config:** extend the selected existing `frontier-harness-report.mjs` or replay result contract additively, with units, baseline, coverage, confidence and spending distinctions.
- **Generated/deployed mirrors:** `.agents/reference/value-evaluation.md` and report views derive from repo-owned evidence; omit raw private inputs, accounts and sensitive identifiers.
- **Migrations/backfills:** retain `.agents/tools/ai-assistants/frontier-harness-pilot.json` and original replay records; label missing historical metrics and never invent user time or money.
- **Cleanup/rollback paths:** preserve private artifacts governed by `.agents/workflows/model-replay.md` and restore older report readers; do not delete failed attempts or source evidence to improve a score.

### Implementation Steps

1. Define value measures: verified outcome, user-active time/interruptions/corrections, elapsed delivery, reusable work eliminated, monetary benefit/cost where observed, and ongoing maintenance cost.
2. Separate fixed subscription cost, allowance consumption, actual paid API/cloud charges and hypothetical API-price estimates; unknown is not zero.
3. Choose a small documented matrix spanning a short task, longer systems work and at least one non-code information workflow. Verify the real installed profile and required capability before each cell.
4. Use matched model/provider/budgets, repeated and order-balanced cases where affordable; retain failures and report evidence coverage. No real financial mutations, outreach or production deployment merely to populate metrics.
5. Produce an initial bounded report and a decision on which refinements are supported. Identify the next information gap rather than claiming 100x from token ratios.

### Hazards and Compatibility

- **Concurrency/atomicity:** isolate task state and avoid cross-case cache/memory contamination; retain exact configuration identity per run.
- **Migration/rollback:** add metric fields compatibly and preserve historical source records; invalid results are qualified, not overwritten.
- **Mixed-version/backward compatibility:** record profile/runtime/provider differences and do not compare unlike configurations as one causal result.
- **Idempotency/retry:** immutable attempts and stable repo evidence IDs prevent selecting the best retry as canonical success.
- **Partial failure/recovery:** missing baseline/value data and provider/runtime failures remain explicit; no hidden spend or fabricated completion.

### Verification Before Dispatch

```bash
node --test .agents/scripts/tests/test-frontier-harness.mjs
node --test .agents/scripts/tests/test-model-replay-benchmark.mjs
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** existing report/replay tests protect results and missing-data semantics; the initial report must include exact bounded run commands/configuration and verifier evidence. User authorization is subscription OAuth/local execution only; do not purchase services or infer paid API consent.

### Progressive Context Plan

- **Read first:** canonical purpose, existing pilot limitations and the result schema of the chosen existing runner.
- **Load only if:** relevant domain verification/retention controls for a selected case, not the entire domain corpus.
- **Stop when:** the bounded report can support or reject a decision; do not turn measurement into a prerequisite platform project.

## Acceptance Criteria

- [ ] A documented representative protocol and initial report distinguish verified user outcomes/time/money from supporting token/task metrics and unobserved value.
- [ ] Real selected profiles, matched conditions, repetitions/order caveats and failed/missing evidence are visible; no broad superiority or 100x claim is inferred from the pilot.
- [ ] Reusable assets and maintenance/correction overhead are included where observed, without private-data leakage or unauthorized external actions/spend.
- [ ] Existing result consumers remain compatible and retained evidence can be understood from repo-native records rather than a forge-only thread.

## Seeded Draft PR

Skipped — representative cases and integration choices depend on predecessor evidence.

Parent: #31280
