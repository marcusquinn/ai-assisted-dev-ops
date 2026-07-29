<!-- aidevops:brief-schema=v2 -->

# t18182: Preserve a clean canonical checkout across simplification-state refresh publication

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `simplification-state publication canonical dirty` → 0 hits — no prior reusable lesson was available before discovery
- [x] Discovery pass: 1 recent source commit / 1 relevant merged PR / 0 open PRs — PR #28228 introduced checkout-free publication, while commit `88e4b8feb` later added receipt/handoff security that this fix must preserve
- [x] File refs verified: 12 refs checked against current `origin/main`, all present
- [x] Tier: `tier:thinking` — five coordinated shell/test surfaces, a shared publication security boundary, and more than 2,000 source lines to synthesize
- [x] Seeded draft PR decision recorded: skipped — issue-only avoids anchoring the worker to an untested external-snapshot API

## Origin

- **Created:** 2026-07-29
- **Session:** OpenCode interactive diagnosis and auto-dispatch handoff
- **Created by:** AI DevOps (ai-interactive), directed by the maintainer
- **Parent task:** None; leaf regression task for GH#28872
- **Blocked by:** None
- **Conversation context:** Post-rollout cleanup found the canonical checkout dirty only because simplification maintenance had refreshed the tracked registry before publishing it checkout-free. The user requested a worker-ready auto-dispatch fix rather than folding generated state into unrelated PRs.

## What

Make the complete simplification-state refresh, same-cycle scan, and publication lifecycle operate on an isolated state snapshot. A successful, no-op, conflicting, or failed publication must leave the canonical checkout's HEAD, index, tracked files, and untracked files unchanged while retaining the existing allowlist, lease, publication-ID, handoff receipt, and retry guarantees.

## Why

PR #28228 / issue #28225 replaced canonical `git add`/commit/push with checkout-free `commit-tree` publication, but it covered only the publisher's own before/after behavior. The caller still mutates `.agents/configs/simplification-state.json` first. On 2026-07-29 the canonical checkout showed that file modified while one commit behind; its entire local diff exactly matched checkout-free publication commit `f5ac0cecd`. This benign residue blocks clean canonical synchronization and creates false concern during parallel full-loop sessions.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** The invariant is decided, but the worker must design a narrowly scoped external-source snapshot contract across a security-sensitive publisher and the weekly scan lifecycle without growing two near-threshold shell orchestrators.

## PR Conventions

Leaf task: title the implementation PR `t18182: ...` and use `Resolves #28872`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Current discovery proves the bug and boundaries, but the safest publisher API should be implemented and tested together by the worker.
- **Status:** `not-created`
- **Freshness evidence:** Source, callers, tests, PR #28228, commit `88e4b8feb`, and live commit `f5ac0cecd` checked on 2026-07-29.
- **Verification run:** Discovery only; implementation tests are unrun.
- **Stale-assumption warning:** Re-read `planning-publisher.sh` receipt/snapshot helpers if another planning-publication change lands before dispatch.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/pulse-simplification-orchestration.sh:276-335,470-557` — locate state refresh, same-cycle state consumers, and orchestration size constraints.
- **Then read:** `.agents/scripts/pulse-simplification-state.sh:164-352` — preserve branch guards, mutation semantics, and publication result handling.
- **Load only if changing the publisher contract:** `.agents/scripts/planning-publisher.sh:53-109,649-810` and `.agents/scripts/tests/test-planning-publisher.sh:285-398` — preserve path allowlisting, blob snapshots, leases, receipts, conflict handling, and replay.
- **Why:** The fix must isolate state generation without weakening a recently hardened checkout-free publication boundary.
- **Stop when:** The worker can name the temporary-state owner, destination/source validation contract, cleanup behavior, and tests for success/no-op/conflict/failure.

### Worker Quick-Start

1. `_simplification_state_refresh`, `_simplification_state_prune`, and `_simplification_state_backfill_closed` already accept an arbitrary `state_file`; use that seam rather than rewriting their mutation logic.
2. `_simplification_state_push` currently hardcodes the repository-relative source at `.agents/scripts/pulse-simplification-state.sh:325-345`; it needs a validated external source while preserving that exact destination.
3. `run_weekly_complexity_scan` passes the canonical state path to refresh and both language scans at `.agents/scripts/pulse-simplification-orchestration.sh:530-536`; all three consumers must share one isolated snapshot for the cycle.
4. Existing test `test_simplification_state_scope_preserves_checkout` snapshots an already-dirty fixture before calling only the publisher. Add an end-to-end clean-fixture regression that performs refresh plus publication.
5. Do not restore/reset the canonical file after publication. Prevent every canonical write instead.

### Files to Modify

- `EDIT: .agents/scripts/pulse-simplification-orchestration.sh:276-335,470-557` — own a temporary state snapshot across refresh, publication, and same-cycle scans without growing the orchestrators inline.
- `EDIT: .agents/scripts/pulse-simplification-state.sh:164-352` — publish a caller-supplied state snapshot to the fixed registry destination while preserving branch and result semantics.
- `EDIT: .agents/scripts/planning-publisher.sh:53-109,649-810` — add a narrowly allowlisted destination/source snapshot seam; keep source paths out of durable receipts and trees.
- `EDIT: .agents/scripts/tests/test-planning-publisher.sh:285-398` — cover external-source allowlisting, receipt integrity, replay, conflict, and rejection cases.
- `NEW: .agents/scripts/tests/test-simplification-state-publication-isolation.sh` — exercise the refresh-to-publish lifecycle from a clean canonical fixture.

### Complete Write Surface

- **Callers/readers:** `run_weekly_complexity_scan` calls `_complexity_scan_state_refresh`, then passes the same state file to `_complexity_scan_lang_shell` and `_complexity_scan_lang_md`; `complexity-scan-helper.sh` reads the supplied registry.
- **Writers/mutation paths:** `_simplification_state_refresh`, `_simplification_state_prune`, and `_simplification_state_backfill_closed` mutate their `state_file`; `_simplification_state_push` delegates to `planning_publish`; `_planning_publish_snapshot` writes blobs and `planning_publish` advances the remote ref with a lease.
- **Tests/fixtures:** Existing publisher coverage is in `.agents/scripts/tests/test-planning-publisher.sh`; state preservation coverage also exists in `.agents/scripts/tests/test-simplification-state-preserve.sh`; add the end-to-end isolation fixture named above.
- **Schemas/config:** Preserve `.agents/configs/simplification-state.json` JSON shape and `aidevops-planning-publication-v2` receipt format. An external source path is runtime-only and must not enter either schema.
- **Generated/deployed mirrors:** `setup.sh` deploys repository scripts; no generated copy is edited directly. The registry remains a tracked generated state file on the remote default branch.
- **Migrations/backfills:** N/A because the persisted registry and receipt schemas remain unchanged; existing files stay readable and the next scan uses the same JSON through a temporary copy.
- **Cleanup/rollback paths:** `.agents/scripts/pulse-simplification-orchestration.sh` owns temporary-snapshot cleanup; rollback reverts the coordinated caller/publisher changes and must never reset, stash, clean, or delete canonical user state.

### Implementation Steps

1. Introduce a focused helper that creates a private temporary copy of the tracked registry and returns/owns its cleanup. Keep temporary artifacts under the framework agent workspace when available, with `mktemp` fallback consistent with existing shell helpers.
2. Pass that one snapshot through prune, refresh, recently-closed backfill, publication, and both same-cycle language scans. If no state changes, skip publication but still scan against and clean the snapshot.
3. Extend `_simplification_state_push` and the publisher through a narrow destination/source contract: destination remains exactly `.agents/configs/simplification-state.json`; source must be a regular, non-symlink file; generic planning publication behavior stays unchanged.
4. Bind publication IDs and receipts to the destination path plus blob, never to the local temporary pathname. Preserve force-with-lease contention, retryable conflict return `2`, no-op replay, validator behavior, and handoff verification from `88e4b8feb`.
5. Add hermetic tests proving clean-checkout invariance across successful refresh/publication, no-op, injected contention, validation failure, and malformed/symlink external-source rejection. Assert the same-cycle scanner reads the refreshed snapshot.
6. Keep generated registry updates out of the implementation PR; tests create fixtures only.

### Hazards and Compatibility

- **Concurrency/atomicity:** Multiple pulse instances may derive snapshots from different source HEADs. Existing parent-conflict checks and force-with-lease behavior remain authoritative; a loser returns retryable conflict without touching canonical state or overwriting the winner.
- **Migration/rollback:** No migration. Do not add a cleanup step that resets canonical paths, because it could erase a parallel human edit. Reverting the feature restores the old call path without changing stored JSON.
- **Mixed-version/backward compatibility:** Preserve ordinary `planning_publish` callers and current one-path snapshots. Keep `_simplification_state_push` callable by existing tests or update every in-repo caller atomically within this PR.
- **Idempotency/retry:** Replaying identical destination/blob content must remain a no-op with the same remote commit semantics; temporary filenames must not affect publication IDs or receipts.
- **Partial failure/recovery:** Temp creation, JSON mutation, validation, receipt, or push failure must clean temporary files, retain canonical bytes/index/HEAD, and leave the objective retryable on the next pulse.

### Complexity Impact

- **Target functions:** `planning_publish` (currently 98 lines), `run_weekly_complexity_scan` (81 lines), `_complexity_scan_state_refresh` (59 lines), and `_simplification_state_push` (28 lines).
- **Estimated growth:** Approximately +60-120 production lines plus tests.
- **Projected post-change:** `planning_publish` and `run_weekly_complexity_scan` would exceed or crowd the 100-line function gate if logic is added inline.
- **Action required:** Add/extract focused snapshot-source and state-lifecycle helpers first; keep both existing orchestrators at or below their current sizes.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-simplification-state-publication-isolation.sh
bash .agents/scripts/tests/test-planning-publisher.sh
bash .agents/scripts/tests/test-simplification-state-preserve.sh
bash .agents/scripts/tests/test-full-loop-merge.sh
shellcheck .agents/scripts/pulse-simplification-orchestration.sh .agents/scripts/pulse-simplification-state.sh .agents/scripts/planning-publisher.sh .agents/scripts/tests/test-planning-publisher.sh .agents/scripts/tests/test-simplification-state-publication-isolation.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Isolation test proves the end-to-end canonical invariant and same-cycle state use; publisher tests prove source/destination validation, receipts, retries, and conflicts; preserve test protects registry semantics; full-loop test protects the recent publication-receipt merge bridge; ShellCheck and changed lint cover shell quality.
- **Broad verification trigger:** The shared planning publisher is a full-loop merge boundary, so its focused full-loop merge suite is required. No release or full repository gate is required unless the changed-file linter finds broader coupling.

### Recoverability Checkpoint

- [ ] Focused tests pass: `bash .agents/scripts/tests/test-simplification-state-publication-isolation.sh && bash .agents/scripts/tests/test-planning-publisher.sh`
- [ ] WIP commit created before broader gates: `wip: isolate simplification state publication`
- [ ] Evidence-triggered broader verification then run: `bash .agents/scripts/tests/test-full-loop-merge.sh && .agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Keep canonical checkouts pristine throughout simplification-state refresh and checkout-free publication.
- **Preserved user directions:** Deliver this as a worker-ready auto-dispatch fix; do not create a duplicate worktree-cleanup mechanism.
- **Trigger and evidence:** Not triggered; network/rate-limit or publication conflict may pause only the push path.
- **Completed and verified:** The regression and prior partial fix are documented; implementation remains open.
- **Remaining acceptance criteria:** All criteria below until code and tests merge.
- **Unsafe route not to repeat:** Resetting/restoring canonical files after the fact or adding generated state to unrelated feature PRs.
- **Next safe route:** Continue from the isolated snapshot with hermetic publisher fixtures; preserve a WIP commit before broad gates.
- **Resume condition:** Focused isolation and publisher suites pass with canonical before/after digests identical.
- **Owner and status:** Auto-dispatch worker; not-triggered.

### Files Scope

- `.agents/scripts/pulse-simplification-orchestration.sh`
- `.agents/scripts/pulse-simplification-state.sh`
- `.agents/scripts/planning-publisher.sh`
- `.agents/scripts/tests/test-planning-publisher.sh`
- `.agents/scripts/tests/test-simplification-state-publication-isolation.sh`

## Acceptance Criteria

- [ ] The refresh-and-publication lifecycle must not alter a clean canonical fixture's HEAD, index, tracked working files, or untracked-file inventory.
- [ ] The remote default branch receives only `.agents/configs/simplification-state.json`, and its content equals the refreshed isolated snapshot.
- [ ] Shell and Markdown scans in the same cycle consume the refreshed snapshot rather than stale canonical state.
- [ ] No-op replay, concurrent remote contention, validator failure, and interrupted publication leave canonical state unchanged and retain existing return/retry semantics.
- [ ] External snapshot sources are accepted only for the exact scope/destination contract; symlinks, directories, unauthorized destinations, and malformed sources fail closed before push.
- [ ] Publication IDs, handoff receipts, and idempotence depend on destination/blob content, not nondeterministic temporary paths.
- [ ] Focused tests, ShellCheck, the full-loop publication bridge suite, and changed-file lint pass.

## Context & Decisions

- Keep generated simplification state in dedicated automated commits; do not add it to unrelated implementation PRs.
- Prevent canonical writes instead of restoring/resetting afterward, because post-hoc cleanup can race with parallel human work.
- Reuse the state functions' existing arbitrary `state_file` parameters and the publisher's index/commit-tree model.
- Treat PR #28228 as a partial fix: it stopped staging/committing in canonical but did not isolate the caller's preceding mutation.
- Preserve the receipt/handoff hardening from commit `88e4b8feb` and the exact publication behavior observed in `f5ac0cecd`.

## Relevant Files

- `.agents/scripts/pulse-simplification-orchestration.sh:276-335` — refresh/prune/backfill and publish coordinator.
- `.agents/scripts/pulse-simplification-orchestration.sh:470-557` — weekly scan lifecycle and same-state consumers.
- `.agents/scripts/pulse-simplification-state.sh:164-352` — registry mutation and hardcoded publication source.
- `.agents/scripts/planning-publisher.sh:53-109` — scope allowlist and source-file snapshot construction.
- `.agents/scripts/planning-publisher.sh:649-810` — snapshot preparation, candidate build, lease push, receipts, and replay.
- `.agents/scripts/tests/test-planning-publisher.sh:285-398` — current publisher-only simplification tests whose fixture starts dirty.
- PR #28228 / issue #28225 — prior checkout-free publication change.
- Commit `88e4b8feb` — publication receipt/handoff bridge that must remain intact.
- Commit `f5ac0cecd` — live generated-state commit exactly matching the observed canonical residue.

## Dependencies

- **Blocked by:** None.
- **Blocks:** Reliable clean canonical synchronization and lower-noise parallel full-loop preflight.
- **External:** Existing authenticated GitHub environment for live publication; all regression tests must be hermetic and use local bare remotes.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 45m | Reconfirm publisher receipt and caller contracts |
| Implementation | 1h 45m | Snapshot lifecycle and external-source publication seam |
| Testing | 1h 30m | End-to-end isolation, conflict, receipt, lint, full-loop bridge |
| **Total** | **4h** | Atomic worker task |
