<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# GH#31382 continuation — approved maintainer batch

## Goal and authority

Continue the approved interactive full-loop batch through verified PR merges and
the explicitly requested release. Primary-session implementation ownership stays
local. This checkpoint is partial progress, not issue completion or a live worker.

## Verified local progress

- `.agents/scripts/task-coordinator.mjs`: compare real paths for direct CLI entry;
  symlink paths (including spaces) now execute, imports remain side-effect free.
- `.agents/scripts/issue-sync-lib-ref.sh`: read back exact persisted mappings after
  backfill and repository-slug refresh, rejecting empty-success child execution.
- Existing coordinator and isolation fixtures cover these behaviors. The isolation
  fixture now loads its existing parser dependency rather than failing because
  `_first_todo_task_line_or_empty` is undefined.
- `bash .agents/scripts/tests/test-task-coordinator.sh`: PASS.
- `bash .agents/scripts/tests/test-issue-mapping-isolation.sh`: PASS.
- ShellCheck, Node syntax, `git diff --check`: PASS.
- `.agents/scripts/linters-local.sh --changed`: exit 0; shfmt advisory remains.
- Schema 8 introduces repository-local aliases without rewriting historical task
  rows or operation results. Foreign-home collisions allocate namespaced internal
  identities under the adoption transaction. Resolver output includes local
  `taskId` plus internal `coordinatorTaskId`.
- Publication references use internal identity; TODO event transitions use local
  tokens. Bare new legacy publications require verified repository context.
- Added passing fixtures for three repositories sharing one token, concurrent
  first adoption, replay, ambiguous non-home rejection, v7 migration preserving
  historical result JSON, and scoped publication references.

## Required review before merge

The migration is implemented but independent closeout is not complete. Inference
review calls failed at both standard and thinking tiers; a read-only reviewer
could not access the allowed worktree source and returned blocked. Do not treat
passing tests as a substitute for independent review of this migration.

Review atomic allocation, exact home binding, migration/replay, old non-home role
conflicts, and local projection versus durable internal identity. Existing durable
conflicts retain their outcome; a changed adoption attempt requires a new explicit
operation ID rather than mutating historical evidence. Resolve any in-scope review
findings and reverify the final rebased head before readiness/merge.

## Batch gates and remaining work

- PR #31426 merged through the canonical gate at
  `fa71e61608090616b1ee29b9191364fa6e06f648`.
- GH#31408 implemented and tested in PR #31431, merged through the canonical gate
  at `83b82f37f59c4ed143995b3ccf4b43d023c1777c`.
- GH#31405 bounded cleanup progress is still pending implementation.
- Reconcile existing PR #31416 without duplicating its executor's work.
- GH#31407 diagnostic repair is shipped; safe reclamation still requires
  producer-bound terminal/publication evidence and must not be claimed complete.
- v3.32.327 was already published; do not repeat it. Recompute latest release and
  exact merged-source inventory only after the remaining merge gates pass.

## Resume

Revalidate the current worktree and PR state. Obtain independent review of the
implemented migration, rerun affected tests after any rebase, and complete the PR
gates. Continue the remaining approved batch without duplicating other executors.
