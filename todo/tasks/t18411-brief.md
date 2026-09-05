<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
<!-- aidevops:brief-schema=v2 -->

# t18411: Calibrate usable context and preserve faithful compaction handoffs

## Pre-flight

- [x] Memory recall: pilot results and native reserve findings are retained in the parent plan and committed pilot evidence.
- [x] Discovery pass: PR #31249 already provides profiles/telemetry/host accounting; no open compaction title match found.
- [x] File refs verified: pilot runner/adapter/report, compaction hook and existing compaction tests checked at `5393632ee`.
- [x] Tier: thinking; cross-runtime reserve/handoff preservation must be evidence-driven, not a universal smaller-window policy.
- [x] Seeded draft PR decision recorded: skipped; measured regressions define acceptance before changing prompts.

## Origin

- **Created:** 2026-09-05; **Created by:** ai-interactive in OpenCode.
- **Parent task:** t18402 — `todo/tasks/t18402-brief.md`.
- **Blocked by:** t18405.

## What

Make context-pressure calibration and handoff verification use actual usable
capacity and delivered core knowledge. Detect/report proven infeasible budgets
without wasting a full compaction loop, and preserve aims, decisions, unapplied
input and next actions through compaction. Do not lower production defaults based
on the single-task pilot.

## Why

OpenCode 1.18.29 subtracted an additional reserve from the adapter's explicit input
limit: context 16,384/output 2,048 left only 12,288 usable input, below the initial
aidevops request. Both arms timed out after repeated compaction. At 18,432, both
passed after two compactions with mixed resource results. This establishes a
calibration defect, not general superiority of a shorter/custom summary.

## Tier

**Selected tier:** `tier:thinking` — resource feasibility and reliable cross-runtime state delivery.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/frontier-harness-run.mjs`, `EDIT: .agents/scripts/frontier_harness_agent.py`, `EDIT: .agents/scripts/frontier-harness-report.mjs`, `EDIT: .agents/plugins/frontier-harness/index.mjs` — calibration, truthful invalid-budget evidence and coverage.
- `EDIT: .agents/plugins/opencode-aidevops/compaction.mjs` only for a handoff defect demonstrated by the required scenarios; preserve existing repo-scoped checkpoint and continuation guards.
- `EDIT: .agents/tools/ai-assistants/frontier-harness-eval.md` — versioned formula, limitations and observed calibration. `model-limits.mjs`/`config-hook.mjs` are read surfaces, not permission to change all defaults.

### Complete Write Surface

- **Callers/readers:** pilot CLI/report and `.agents/plugins/opencode-aidevops/compaction.mjs` consumers after rollover.
- **Writers/mutation paths:** `frontier-harness-run.mjs` manifests, `frontier-harness/index.mjs` telemetry and existing `compaction.mjs` repo-scoped checkpoints; no new global memory store.
- **Tests/fixtures:** `.agents/scripts/tests/test-frontier-harness.mjs`, `.agents/plugins/opencode-aidevops/tests/test-compaction-autocontinue.mjs`, `.agents/plugins/opencode-aidevops/tests/test-compaction-checkpoint-scope.mjs`.
- **Schemas/config:** `frontier_harness_agent.py` model metadata, `frontier-harness-report.mjs` result coverage and `compaction.mjs` checkpoint identity; verify runtime source before relying on a reserve formula.
- **Generated/deployed mirrors:** deployed plugin sources and generated summaries; canonical static guidance stays in `.agents/` and is not blindly regenerated into every handoff.
- **Migrations/backfills:** preserve `compaction.mjs` checkpoints and existing pilot report records; add fields compatibly and never relabel historical failures as passes.
- **Cleanup/rollback paths:** existing `compaction.mjs` scope guards and `frontier-harness-run.mjs` owned-resource cleanup remain authoritative; failed calibration preserves evidence.

### Implementation Steps

1. Verify installed runtime exports/source and record the usable-input formula, initial core/tool footprint, output reserve and actual applied model metadata.
2. Reject or stop a provably infeasible experimental budget with explicit diagnostic evidence before repeated compaction; do not guess token counts or encode open-ended task judgment in a new supervisor.
3. Use existing fixtures/receipts to test aims, decisions, unapplied user corrections, evidence references and next actions after rollover.
4. Remove duplicated static policy from a summary only if t18405 proves its canonical source is reliably restored on that route; retain fallback elsewhere.
5. Keep completed-response subtotals, interrupted/missing usage and summary overhead distinct. No paid API fallback or compaction-as-lossless guarantee.

### Hazards and Compatibility

- **Concurrency/atomicity:** checkpoints and telemetry remain session/repo scoped; one trial's context cannot enter another.
- **Migration/rollback:** version new fields additively, retain old readers and existing checkpoint contents, and restore prior prompt behavior on regression.
- **Mixed-version/backward compatibility:** unknown runtime reserve semantics are reported unsupported/unknown, not assumed equivalent to 1.18.29.
- **Idempotency/retry:** repeated recovery does not replay completed work or obsolete authorization; preserve immutable pilot attempts.
- **Partial failure/recovery:** infeasible configuration, provider failure, missing telemetry and task failure remain distinguishable; safety stops leave the objective open.

### Verification Before Dispatch

```bash
node --test .agents/scripts/tests/test-frontier-harness.mjs
node --test .agents/plugins/opencode-aidevops/tests/test-compaction-autocontinue.mjs
node --test .agents/plugins/opencode-aidevops/tests/test-compaction-checkpoint-scope.mjs
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** pilot tests must cover infeasible/feasible settings and missing usage; existing compaction tests preserve continuation and repo isolation. Bounded live rechecks may use existing subscription OAuth, not paid API/cloud resources.

### Progressive Context Plan

- **Read first:** committed pilot limitations and the installed runtime's actual overflow/compaction contract, then affected handoff functions.
- **Load only if:** checkpoint/lifecycle reference details are needed by a failing protected scenario; avoid moving active work in PRs #31269/#31252.
- **Stop when:** feasibility and handoff evidence are sufficient; do not run broad sweeps on an infeasible budget.

## Acceptance Criteria

- [ ] A feasible calibrated pilot produces a valid result with applied capacity, summary usage and verifier evidence.
- [ ] The known infeasible-budget shape is identified without a full repeated-compaction timeout, while a feasible bounded case still runs.
- [ ] Protected aims, corrections, progress and next steps survive tested rollover without stale authority or cross-repo state replay.
- [ ] Missing/partial usage is explicit, historical failures remain intact, and production context defaults are not changed without representative evidence.

## Seeded Draft PR

Skipped — apply only changes justified by feasibility or handoff evidence.

Parent: #31280
