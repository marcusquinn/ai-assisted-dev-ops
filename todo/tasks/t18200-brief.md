<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18200: Avoid false dependency holds from descriptive issue prose

## Pre-flight

- [x] Memory recall: `dependency-event-reconciler hold text false positive descriptive issue body status blocked auto dispatch` → 0 hits — no reusable stored lesson found.
- [x] Discovery pass: 2 recent commits and merged PR #27347 touch the target reconciler; both established the current conservative closure recovery, while 0 open related PRs address descriptive-text false positives.
- [x] File refs verified: 8 source, test, caller, and prior-contract ranges checked at current HEAD.
- [x] Tier: `tier:standard` — the affected path and safety boundary are known, but Markdown-aware operational-marker classification must balance false unblocks against false holds.
- [x] Seeded draft PR decision recorded: skipped — issue-only is safer because no parser edit has been tested and the current worktree contains unrelated mission-planning artifacts.

## Origin

- **Created:** 2026-08-04
- **Session:** OpenCode interactive recovery for issue #29506
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** Dependency #29494 was closed, but #29506 remained `status:blocked`. The closure reconciler treated a compatibility-classification table cell containing “Hold for bounded review” as a live task pause, even though the issue had no operational hold, comments, or hold label.

## What

Make dependency closure reconciliation distinguish explicit operational pause
signals from descriptive, quoted, tabular, or example prose. Preserve every
strong machine/worker hold and exact management-label gate, while allowing an
otherwise-ready dependent issue to move from `status:blocked` to
`status:available` when a phrase such as “hold for review” appears only as
documentation inside its body.

## Why

`_der_has_hold()` currently runs one unanchored regular expression over the
entire issue body, all comments, and a comma-joined label list. Any incidental
phrase can therefore suppress both close-event reconciliation and the periodic
stale sweep indefinitely. In #29506, all native and declared blockers were
terminal and the issue was worker-ready, but a classification table describing
an `unknown_review` outcome matched the `hold for` substring and silently
prevented dispatch.

The guard exists for a valid reason: dependency completion must not erase a
human pause, worker `BLOCKED` result, watchdog escalation, or protected review
gate. The fix must narrow context, not delete the guard or replace fail-closed
behavior with permissive substring matching.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The required behavior and regression matrix are decided,
but implementation must choose a small Bash-compatible line normalizer that
recognizes explicit Markdown hold lines without interpreting examples as live
control state.

## PR Conventions

This is a leaf task. The implementation PR uses a closing keyword for this
issue and does not close or modify #29494 or #29506.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** No parser change has been validated, and issue-only avoids anchoring the worker to an untested regex.
- **Status:** `not-created`
- **Freshness evidence:** Memory, recent commits, merged/open PRs, source call sites, tests, and the #29506 reproduction were checked on 2026-08-04.
- **Verification run:** Existing code was exercised through the live #29506 recovery; implementation tests are unrun.
- **Stale-assumption warning:** Re-check the reconciler and its tests if another PR changes hold detection, stale blocked reconciliation, or status-label transitions first.

## How (Approach)

### Worker Quick-Start

1. Keep exact management labels and strong machine/worker escalation markers fail-closed.
2. Treat ambiguous natural-language phrases as controls only on explicit operational lines after bounded Markdown normalization.
3. Ignore phrase occurrences inside table rows, fenced examples, HTML comments, explanatory sentences, and acceptance/reference prose.
4. Exercise both `_der_has_hold()` directly and the full close/stale-reconcile paths.
5. Do not change blocker resolution, GitHub pagination, issue search, or the final label mutation.

### Files to Modify

- `EDIT: .agents/scripts/dependency-event-reconciler.sh:82-89,341-360` — separate exact label/strong-marker handling from Markdown-aware natural-language hold lines while preserving `_der_try_unblock()` fail-closed behavior.
- `EDIT: .agents/scripts/tests/test-dependency-event-reconciler.sh:235-253,311-323` — add positive and negative hold-context regressions through direct and end-to-end reconciliation.

### Complete Write Surface

- **Callers/readers:** `_der_try_unblock()` is the direct reader. `reconcile_dependants_after_verified_closure()` is called by `github-cli-helper.sh`, `issue-sync-helper-close.sh`, `full-loop-helper-merge.sh`, and `pulse-merge.sh`; `pulse-wrapper-cycle.sh` calls `reconcile_stale_blocked_issues()`.
- **Writers/mutation paths:** Keep the existing re-read and single `gh issue edit` transition from `status:blocked` to `status:available`; this task changes only whether verified hold evidence suppresses that write.
- **Tests/fixtures:** Extend `.agents/scripts/tests/test-dependency-event-reconciler.sh`; retain `.agents/scripts/tests/test-pulse-stale-blocked-reconcile.sh` as the pulse wiring regression.
- **Schemas/config:** Not applicable because scoped source/caller searches found no external schema or configuration consumer; the hold vocabulary remains internal to `.agents/scripts/dependency-event-reconciler.sh`.
- **Generated/deployed mirrors:** Tracked `.agents/scripts/` sources deploy through the existing setup copy path. Do not edit `~/.aidevops/agents/` or generated files.
- **Migrations/backfills:** Not applicable because the two target files introduce no persisted format; existing blocked issues are reconsidered naturally by `reconcile_stale_blocked_issues()` after deployment.
- **Cleanup/rollback paths:** Reverting `.agents/scripts/dependency-event-reconciler.sh` and `.agents/scripts/tests/test-dependency-event-reconciler.sh` restores conservative substring matching; no issue relationship or stored state requires cleanup.

### Implementation Steps

1. Split `_der_has_hold()` into bounded predicates for exact management labels, strong machine/worker signals, and ambiguous natural-language pause phrases. Keep the public helper return contract unchanged.
2. Recognize exact dispatch gates such as `needs-maintainer-review`, `hold-for-review`, and `no-auto-dispatch` from parsed labels rather than incidental prose containing those names.
3. Preserve strong signals anywhere in trusted fetched text: `HUMAN_UNBLOCK_REQUIRED`, a worker `**BLOCKED** ... cannot proceed` result, `Worker Watchdog Kill`, `Terminal blocker detected`, and `ACTION REQUIRED`.
4. For phrases such as `defer until`, `do not dispatch`, `on hold`, `hold for`, and `paused`, scan line-by-line. Accept only an explicit operational line after stripping bounded list/quote/emphasis prefixes; skip table rows, fenced code, HTML comments, and explanatory/reference text where the phrase is not the directive.
5. Add a regression using the #29506 shape: a valid `Blocked by #10` declaration plus a Markdown classification row containing `Hold for bounded review; no implementation issue` must unblock after #10 closes.
6. Preserve positive cases for an explicit `On hold for maintainer` line, exact hold labels, and worker/machine escalation comments. Add at least one fenced/example and one explanatory-prose negative case.
7. Run the focused tests and changed-file quality gates. Do not contact or mutate live issues during implementation tests.

### Hazards and Compatibility

- **Concurrency/atomicity:** Existing live label re-read immediately before mutation remains the race guard. Do not cache the final status decision across API calls.
- **Migration/rollback:** No data migration. Rollback restores the old conservative parser; issues already made available remain protected by normal claim and dispatch gates.
- **Mixed-version/backward compatibility:** Runners with the old parser may leave an issue blocked longer; runners with the new parser must still honor exact labels and strong markers, so mixed deployment cannot erase explicit pause state.
- **Idempotency/retry:** Reconciliation remains idempotent: available/active/done issues are unchanged, and retrying a verified closure performs at most the existing label transition.
- **Partial failure/recovery:** Malformed/paginated API responses, unknown blocker state, incomplete comments, and failed label re-reads continue to fail closed. Context parsing must not convert API ambiguity into availability.

### Complexity Impact

- **Target function:** `_der_has_hold` in `.agents/scripts/dependency-event-reconciler.sh`
- **Current line count:** 8 lines (threshold: 100 lines)
- **Estimated growth:** +12 lines in the existing function, with bounded helpers added separately
- **Projected post-change:** about 20 lines (20% of threshold)
- **Action required:** None — keep normalization in small explicit helpers and avoid growing `_der_try_unblock()`.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-dependency-event-reconciler.sh
bash .agents/scripts/tests/test-pulse-stale-blocked-reconcile.sh
shellcheck .agents/scripts/dependency-event-reconciler.sh .agents/scripts/tests/test-dependency-event-reconciler.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The dependency test proves explicit holds remain blocked and descriptive prose can unblock; the pulse test proves periodic recovery stays wired; ShellCheck covers Bash 3.2-safe syntax; changed-file lint covers licensing, formatting, complexity, and secrets.
- **Broad verification trigger:** Not required — call sites and GitHub mutation order are unchanged, and the focused unit plus pulse-wiring tests cover both entry paths.

### Recoverability Checkpoint

- [ ] Focused tests pass: `bash .agents/scripts/tests/test-dependency-event-reconciler.sh && bash .agents/scripts/tests/test-pulse-stale-blocked-reconcile.sh`
- [ ] WIP commit created before broader gates: `wip: narrow dependency hold detection`
- [ ] Evidence-triggered broad verification then run: not required; run `.agents/scripts/linters-local.sh --changed` after ShellCheck.

### Safety-Stop Recovery

- **Original objective:** Prevent descriptive issue prose from indefinitely suppressing dependency unblocks without weakening real pause gates.
- **Preserved user directions:** Continue safely, retain explicit holds, and avoid duplicate or speculative worker dispatch.
- **Trigger and evidence:** not triggered
- **Completed and verified:** Live #29506 reproduced the false positive; source, tests, callers, and prior rationale are identified.
- **Remaining acceptance criteria:** Implement context-aware matching and pass every positive/negative regression and quality gate below.
- **Unsafe route not to repeat:** Do not remove `_der_has_hold()`, treat every substring as control state, or make API ambiguity fail open.
- **Next safe route:** Reduce the classifier to exact labels, strong markers, and explicit operational lines; add a failing fixture before changing behavior.
- **Resume condition:** Target files have no newer in-flight change, and the #29506-shaped regression fails on the old implementation.
- **Owner and status:** implementation worker; not-triggered

### Files Scope

- `.agents/scripts/dependency-event-reconciler.sh`
- `.agents/scripts/tests/test-dependency-event-reconciler.sh`

## Acceptance Criteria

- [ ] A dependent issue with all blockers closed transitions to available when a hold phrase appears only in a Markdown table, fenced example, HTML comment, or explanatory/reference sentence.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-dependency-event-reconciler.sh"
  ```

- [ ] Explicit operational lines (`On hold`, `Defer until`, `Do not dispatch`, `Paused`, or `Hold for`) still suppress both close-event and stale-sweep unblocking.

  ```yaml
  verify:
    method: codebase
    pattern: "explicit.*hold|operational.*hold|descriptive.*prose|classification.*row"
    path: ".agents/scripts/tests/test-dependency-event-reconciler.sh"
  ```

- [ ] Exact management labels and strong machine/worker escalation markers remain fail-closed even when dependencies are terminal.

  ```yaml
  verify:
    method: codebase
    pattern: "needs-maintainer-review|hold-for-review|HUMAN_UNBLOCK_REQUIRED|Worker Watchdog Kill|Terminal blocker|cannot proceed"
    path: ".agents/scripts/tests/test-dependency-event-reconciler.sh"
  ```

- [ ] API ambiguity, incomplete pagination, open blockers, active status labels, and final-label races retain their existing no-mutation behavior.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-dependency-event-reconciler.sh && bash .agents/scripts/tests/test-pulse-stale-blocked-reconcile.sh"
  ```

- [ ] Focused ShellCheck and changed-file quality gates pass.

  ```yaml
  verify:
    method: bash
    run: "shellcheck .agents/scripts/dependency-event-reconciler.sh .agents/scripts/tests/test-dependency-event-reconciler.sh && .agents/scripts/linters-local.sh --changed"
  ```

## Context & Decisions

- PR #27347 established targeted closure reconciliation; this task narrows only its non-dependency hold classifier.
- t2031 deliberately chose conservative preservation after real workers were redispatched over explicit pauses. That safety boundary remains authoritative.
- #29506 demonstrated that free-text issue bodies now contain extensive schemas, tables, examples, and safety prose where control words are descriptive rather than imperative.
- Exact labels and machine markers are stronger evidence than natural-language substrings and remain authoritative anywhere they are observed.
- Manual re-queue is an acceptable emergency recovery, but periodic reconciliation must not require human inspection for every descriptive false positive.

## Relevant Files

- `.agents/scripts/dependency-event-reconciler.sh:82-89` — current unanchored body/comment/label hold matcher.
- `.agents/scripts/dependency-event-reconciler.sh:341-360` — guarded unblock and final live-label re-read.
- `.agents/scripts/dependency-event-reconciler.sh:363-423` — close-event and stale-sweep entry points.
- `.agents/scripts/tests/test-dependency-event-reconciler.sh:235-253` — existing explicit-hold and ambiguity regressions.
- `.agents/scripts/tests/test-dependency-event-reconciler.sh:311-323` — periodic stale-sweep regressions.
- `todo/tasks/t2031-brief.md:17-36,63-109` — original safety rationale and intended explicit worker/hold markers.

## Dependencies

- **Blocked by:** none
- **Blocks:** reliable auto-dispatch of dependency-gated tasks whose worker-ready briefs contain descriptive control vocabulary.
- **External:** GitHub is not required for focused implementation tests; runtime verification may observe the next naturally reconciled issue after merge.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Regression fixtures | 30m | Reproduce #29506 shape and preserve explicit holds |
| Classifier implementation | 45m | Bounded Markdown-aware line and label handling |
| Focused verification | 30m | Unit, pulse wiring, ShellCheck, changed lint |
| Review/recovery margin | 15m | Fail-closed edge cases and mixed prose |
| **Total** | **2h** | |
