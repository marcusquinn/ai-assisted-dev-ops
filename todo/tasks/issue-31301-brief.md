<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

## What

Make issue-list labels distinguish active implementation, a blocked partial draft, executable continuation, and genuine review-ready work.

## Why

A draft checkpoint and active interactive claim must not appear review-ready. State projection must preserve #31265 authenticated exact-draft continuation and must not affect #31241.

## How

Use existing lifecycle labels only: `status:claimed` / `status:in-progress` for active ownership, `status:blocked` for an evidenced partial checkpoint with its existing reason/action evidence, `status:available` for a verified executable continuation, and `status:in-review` only for an open non-draft PR ready for review. Keep assignment-plus-active-state dedup, all trust/hold gates, fresh evidence fences, idempotency, and conservative handling of unavailable reads. Never infer current state from prose or timestamps, broadly relabel live work, or turn a corrected body into permission to clear a security/authority hold.

### Files Scope

- `.agents/scripts/dispatch-dedup-stale.sh`
- `.agents/scripts/shared-constants.sh`
- `.agents/scripts/shared-gh-wrappers-status.sh`
- `.agents/scripts/managed-label-provisioning-lib.sh`
- `.agents/scripts/label-sync-helper.sh`
- `.agents/reference/task-lifecycle.md`
- `.agents/reference/dispatch-blockers.md`
- `.agents/reference/auto-dispatch.md`
- `.agents/reference/worker-discipline.md`
- `.agents/scripts/commands/full-loop.md`
- `.agents/scripts/interactive-session-helper.sh`
- `.agents/scripts/interactive-session-helper-commands.sh`
- `.agents/scripts/terminal-blocker-circuit.sh`
- `.agents/scripts/headless-runtime-failure.sh`
- `.agents/scripts/dispatch-claim-helper.sh`
- `.agents/scripts/pr-checkpoint-target-lib.sh`
- `.agents/scripts/pr-checkpoint-continuation-helper.sh`
- Existing lifecycle test fixtures covering claims, release, checkpoint continuation, stale PR continuation, status labels, and revision validation.

## Acceptance

- [ ] Labels alone distinguish active implementation, blocked partial work, executable continuation, and non-draft review-ready work.
- [ ] Blocked states retain a minimal evidence-backed next action; verified correction and continuation clear only stale blockers.
- [ ] Relabelling cannot release a live claim, bypass approval, dispatch a duplicate, or mark an incomplete draft review-ready.
- [ ] Fresh reads make transitions idempotent; unknown reads preserve the prior projection.
- [ ] Existing labels are reused and historical contradictions are handled per issue without a blanket migration.

## Verification

Extend mocked claim/release and checkpoint-continuation suites for blocked-to-corrected-to-continuation, live-owner race, unavailable read, draft-ready, and merge. Assert issue-label projection and unchanged dispatch authority at each step. Run focused ShellCheck and affected tests. No release.

<!-- aidevops:origin:interactive -->
<!-- aidevops:sig -->
