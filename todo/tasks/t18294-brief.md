<!-- aidevops:brief-schema=v2 -->

# t18294: Stop approval batches after systemic GitHub transport failure

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: no matching reusable lesson; current-session repeated-503 evidence retained below
- [x] Discovery pass: local TODO, batch implementation, tests, recent commits, merged PRs, and open PRs inspected; no active duplicate found after GitHub API recovery
- [x] File refs verified: target and batch test exist at `387d8adfd78b0383042539dc66be1d16cdc723ba`
- [x] Tier: `tier:standard` — bounded batch policy with explicit failure classification and regression cases
- [x] Seeded draft PR decision recorded: skipped — brief-first publication was chosen and implementation waits for t18293

## Origin

- **Created:** 2026-08-17
- **Session:** OpenCode interactive maintainer-review session
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** t18293 for conflict-free sequencing
- **Conversation context:** A five-target approval batch continued after repeated GitHub HTTP 503 responses, producing partial signed comments and repeated writes while lifecycle labels, assignment, and locking could not be completed reliably.

## What

Add bounded, machine-readable outage classification to approval batches. After a target fails, stop attempting untouched targets when a minimal health probe confirms a systemic transport/server or shared rate-limit failure; preserve already signed targets, report unattempted targets, and direct recovery through per-target `verify` then `reconcile`.

## Why

`_execute_approval_batch()` currently increments a generic failure count and always proceeds. That is appropriate for isolated target failures but unsafe and noisy during a shared GitHub outage: every continuation can create another partial approval, consume API budget, and increase reconciliation work.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The continue/stop policy is explicit, while implementation must reuse existing API cooldown/auth semantics without conflating isolated validation failures with systemic outages.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** This task is being filed from a reviewed worker-ready brief and intentionally waits for t18293 before implementation.
- **Status:** `not-created`
- **Freshness evidence:** Local target/test paths and recovered remote merged/open PR searches were checked on 2026-08-17 at `387d8adfd78b0383042539dc66be1d16cdc723ba`; re-read code after t18293 lands.
- **Verification run:** `UNVERIFIED — brief only`
- **Stale-assumption warning:** Rebase on t18293 and re-read `_execute_approval_batch()` plus API-probe helpers before editing.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/approval-helper.sh:152-186,1213-1235` — add/extend bounded availability classification and stop policy after a failed target.
- `EDIT: .agents/scripts/tests/test-approval-helper-batch.sh:19-106` — model successful, isolated-failure, and systemic-failure batches.

### Complete Write Surface

- **Callers/readers:** `_approve_targets()` invokes `_execute_approval_batch()` after one confirmation; single-target behavior should remain compatible.
- **Writers/mutation paths:** `_approve_target_after_confirmation()` may sign/comment before lifecycle failure. The batch controller must never roll back signed evidence or retry a target automatically.
- **Tests/fixtures:** Extend `.agents/scripts/tests/test-approval-helper-batch.sh` with configurable per-target return status and a stubbed availability classification/probe; no live GitHub calls.
- **Schemas/config:** N/A because scoped search found no persisted schema/config for internal symbolic failure classes.
- **Generated/deployed mirrors:** `setup.sh` later deploys `.agents/scripts/approval-helper.sh`; do not edit deployed copies.
- **Migrations/backfills:** N/A because existing signed approvals remain compatible and are reconciled by current commands.
- **Cleanup/rollback paths:** Revert `.agents/scripts/approval-helper.sh` and `.agents/scripts/tests/test-approval-helper-batch.sh` together; existing exhaustive batch continuation is the rollback behavior.

### Implementation Steps

1. Define a bounded API availability probe/classifier that distinguishes at least healthy/authenticated service, shared core/secondary rate-limit stop, systemic server/transport unavailability, and unknown/isolated failure. Reuse existing cooldown and auth-probe parsing where practical; do not parse human-facing error strings from approval output.
2. In `_execute_approval_batch()`, after a target fails, run the classifier once. Continue for healthy or unknown/isolated target failure, but break for confirmed systemic/server/rate-limit classes. Track attempted, failed, successful, and unattempted counts without retrying any target.
3. Emit one concise terminal summary stating that successful targets remain signed and listing/counting untouched targets. Direct operators to `aidevops approve verify` and then `aidevops approve reconcile`; do not claim untouched targets were failures.
4. Extend the batch test harness to prove: all-success still visits every target; an isolated failure still allows later targets; a confirmed systemic failure stops before later targets; successes before the stop remain recorded; the command returns non-zero; and only one classification probe occurs per failed target before termination.
5. Run focused approval tests, ShellCheck, and changed-file lint. Preserve Bash 3.2 syntax, explicit function returns, current confirmation semantics, cryptographic signing, and fail-closed authority checks.

### Hazards and Compatibility

- **Concurrency/atomicity:** The batch remains sequential. Stop decisions apply only to untouched targets and must not mutate or erase prior signed state.
- **Migration/rollback:** No migration; rollback restores continue-through-all behavior.
- **Mixed-version/backward compatibility:** Single-target and isolated-failure behavior stays compatible; new summaries may add attempted/unattempted counts without changing command arguments.
- **Idempotency/retry:** Never auto-retry a failed or signed target. Operator recovery remains explicit `verify` then `reconcile`, which preserves signature idempotency.
- **Partial failure/recovery:** Signed comments can exist without completed labels/assignment/lock. Report that state accurately and leave all acceptance criteria open until reconciliation verifies each attempted target.

### Complexity Impact

- **Target function:** `_execute_approval_batch` in `.agents/scripts/approval-helper.sh`
- **Current line count:** 24 lines (threshold: 100 lines for function-complexity)
- **Estimated growth:** +25 lines
- **Projected post-change:** ~49 lines (49% of threshold)
- **Action required:** Keep classification in a dedicated helper; no parent-function extraction otherwise required.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-approval-helper-batch.sh
bash .agents/scripts/tests/test-approval-auth-errors.sh
bash .agents/scripts/tests/test-approval-helper-rest-lock-fallback.sh
shellcheck .agents/scripts/approval-helper.sh .agents/scripts/tests/test-approval-helper-batch.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Batch tests prove continuation versus termination and exact call counts; auth-error tests protect credential/rate-limit diagnostics; lifecycle tests protect partial-state recovery; ShellCheck/lint cover portability and policy.
- **Broad verification trigger:** Not required unless the classifier changes shared GitHub API wrapper/cooldown files outside the declared scope.

### Safety-Stop Recovery

- **Original objective:** Stop approval batches from amplifying systemic GitHub failures while preserving recoverable signed evidence.
- **Preserved user directions:** Solve this independently from malformed login validation.
- **Trigger and evidence:** Repeated HTTP 503 responses across five approval targets created partial signed comments and uncertain lifecycle state.
- **Completed and verified:** Worker-ready local brief and scoped stop-policy contract.
- **Remaining acceptance criteria:** t18293, implementation, focused tests, PR, and review.
- **Unsafe route not to repeat:** Blanket batch retries during a confirmed systemic outage.
- **Next safe route:** Rebase after t18293, implement hermetically, then verify/reconcile each previously attempted target once API health is stable.
- **Resume condition:** t18293 lands and its approval-helper changes are present in the implementation branch.
- **Owner and status:** unassigned; `blocked`

### Files Scope

- `.agents/scripts/approval-helper.sh`
- `.agents/scripts/tests/test-approval-helper-batch.sh`

## Acceptance Criteria

- [ ] All-success batches and batches with an isolated target failure retain current continue-through behavior and final status semantics.
- [ ] A confirmed systemic HTTP 5xx/transport or shared rate-limit condition stops the batch before any untouched target is signed or mutated.
- [ ] The terminal summary distinguishes successful, failed, and unattempted targets and states that successful targets remain signed.
- [ ] No failed or signed target is automatically retried; recovery guidance uses per-target `verify` followed by `reconcile`.
- [ ] Confirmation, authority, cryptographic signing, lock, and lifecycle fail-closed protections are not weakened.
- [ ] Focused tests, ShellCheck, and changed-file lint pass.

## Context & Decisions

- Fail fast only on confirmed shared/systemic conditions; a target-specific validation or permissions failure must not suppress independent later targets.
- Use machine-readable return state or a dedicated probe, not matching English CLI output.
- Preserve partial success as signed evidence and surface it; do not attempt compensating deletion of comments or signatures.
- Remote merged/open PR collision checks completed after API recovery; no active duplicate was found.

## Relevant Files

- `.agents/scripts/approval-helper.sh:152-186` — existing authenticated/rate-limit probe parser.
- `.agents/scripts/approval-helper.sh:1213-1235` — current continue-through-all batch loop.
- `.agents/scripts/tests/test-approval-helper-batch.sh:19-106` — existing hermetic batch harness.
- `.agents/scripts/pulse-approval-reconcile.sh` — existing bounded post-approval reconciliation behavior to preserve.

## Dependencies

- **Blocked by:** t18293 to avoid overlapping edits and stale assumptions.
- **Blocks:** Safer bulk maintainer approval during future GitHub incidents.
- **External:** GitHub API for issue/PR lifecycle only; implementation tests must be hermetic.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Research/read | 30m | Re-read probes, cooldowns, and t18293 result |
| Implementation | 1h | Classifier and bounded batch controller |
| Testing | 1h | Continue/stop/count/recovery matrix |
| Publication/review | 30m | Collision checks, issue relationship, and review |
| **Total** | **~3h** | |
