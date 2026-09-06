<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
<!-- aidevops:brief-schema=v2 -->

# t18404: Prove repo-native plans and progress survive loss of a forge

## Pre-flight

- [x] Memory recall: no matching search result; explicit repo/forge ownership direction retained in the parent plan.
- [x] Discovery pass: no open forge/portability title match; existing issue-sync and Beads/TODO paths are prior art, not systems to replace.
- [x] File refs verified: planning, task allocation, issue-sync, task-lifecycle and Beads entry points exist at `5393632ee`.
- [x] Tier: thinking; recovery semantics, evidence completeness and adapter ownership require architectural judgment.
- [x] Seeded draft PR decision recorded: skipped; do not seed an unverified new state engine.

## Origin

- **Created:** 2026-09-05; **Created by:** ai-interactive in OpenCode.
- **Parent task:** t18402 — `todo/tasks/t18402-brief.md`.
- **Blocked by:** t18403; preserve the repo-native dependency and verify its forge edge before dispatch.

## What

Define and demonstrate a bounded recovery contract for plans, task identity,
dependencies, decisions and progress from repository-owned records without the
original forge/account/runtime session DB. Deliver a documented coverage matrix
and offline recovery proof using existing stores and adapters; repair the proven
minimum gap, not a wholesale rewrite of all four forge integrations.

## Why

TODOs/Beads and plans are organisational knowledge. GitHub/GitLab/Gitea/Forgejo are
execution conversations and must not become the only copy of progress or briefs.
Current issue-only/stub brief options and platform-specific refs need an explicit
loss/recovery audit. Never promise recovery of remote events that were never
captured: define durable acknowledgement and observable ingestion lag.

## Tier

**Selected tier:** `tier:thinking` — cross-system persistence/recovery contract and migration decisions.

## How (Approach)

### Files Scope

- `.agents/reference/forge-portability.md`
- `.agents/reference/task-lifecycle.md`
- `.agents/reference/self-improvement.md`
- `.agents/scripts/commands/new-task.md`
- `.agents/workflows/new-task.md`
- `.agents/tools/task-management/beads.md`
- `.agents/scripts/brief-readiness-helper.sh`
- `.agents/scripts/task-brief-helper.sh`
- `.agents/scripts/tests/test-brief-readiness.sh`
- `.agents/scripts/tests/test-forge-portability.sh`
- `todo/tasks/t18404-brief.md`

Retain the original paths below. Integration recovery additionally covers
`.agents/scripts/brief-readiness-helper.sh`, `.agents/scripts/task-brief-helper.sh`,
`.agents/scripts/tests/test-brief-readiness.sh`,
`.agents/scripts/tests/test-forge-portability.sh`, and this brief. The stub writer
fetches only a title and stores a forge-only pointer; its caller suppresses write
failure. Capture the full body locally, preserve existing briefs, and propagate
capture failures. Verify with `bash .agents/scripts/tests/test-forge-portability.sh`,
`bash .agents/scripts/tests/test-brief-readiness.sh`, the sync contract suite,
scoped ShellCheck, changed-file lint and `git diff --check`. The owner-authored
issue is assigned to this worker account; dependency #31285 is closed and merged
in HEAD. No open brief-readiness PR or pushed issue branch was found. This is an
additive, bounded repair, not provider parity or automatic event ingestion.
The command `new-task.md` is a tracked symlink; `.agents/workflows/new-task.md`
is its actual editable invocation-guidance surface, not a separate work package.

### Files to Modify

- `NEW: .agents/reference/forge-portability.md` — ownership, durable acknowledgement, export/recovery matrix and limits.
- `EDIT: .agents/reference/task-lifecycle.md`, `EDIT: .agents/reference/self-improvement.md`, `EDIT: .agents/scripts/commands/new-task.md`, `EDIT: .agents/tools/task-management/beads.md` — align canonical authority and invocation guidance.
- Investigate `.agents/scripts/issue-sync-lib*.sh`, `.agents/scripts/issue-sync-helper*.sh`, `.agents/scripts/issue-sync-relationships.sh`, `.agents/scripts/claim-task-id*.sh` and `.agents/scripts/planning-publisher.sh`; exact code writes are not yet knowable until the recovery gap is located. Limit implementation to the smallest proven gap and file separate remaining adapter work.

### Complete Write Surface

- **Callers/readers:** `TODO.md`, `todo/tasks/`, Beads consumers, `.agents/scripts/issue-sync-helper.sh` and worker dispatch readers.
- **Writers/mutation paths:** `.agents/scripts/claim-task-id.sh`, `.agents/scripts/planning-publisher.sh` and `.agents/scripts/issue-sync-helper.sh`; enumerate both sync directions before altering state.
- **Tests/fixtures:** `.agents/scripts/test-issue-sync-lib.sh` is an existing sync contract suite; add a focused offline recovery fixture only to prove the required loss scenario.
- **Schemas/config:** stable repo task IDs, foreign-ref mapping, dependencies, progress/evidence records and `.agents/reference/task-lifecycle.md` contracts.
- **Generated/deployed mirrors:** `.agents/scripts/issue-sync-lib-compose.sh` creates forge views from `TODO.md`/briefs; runtime caches and generated stubs are not sole durable sources.
- **Migrations/backfills:** inspect existing `.agents/scripts/issue-sync-lib-ref.sh` and planning publication before choosing any backfill; preserve foreign refs and original evidence.
- **Cleanup/rollback paths:** back up `TODO.md` and `todo/` before conversions; retain unknown fields/provenance and never delete remote or local history as cleanup.

### Implementation Steps

1. Trace repo-to-forge and forge-to-repo paths; identify every field needed to resume work and whether it is actually durable locally.
2. Specify local-first persistence for aidevops-generated plans/progress before forge publication; ingest actionable external decisions before treating them as acknowledged/executable.
3. Preserve one repo task identity across providers. External IDs are mappings, not the canonical identity; restored authorization must be revalidated, not replayed.
4. Run an offline recovery exercise with all forge access disabled, using an existing/focused redacted fixture. Verify task content, dependencies, progress and necessary evidence, not just issue counts.
5. Repair the minimum demonstrated gap with compatibility/rollback coverage. Record unimplemented provider paths explicitly instead of claiming universal parity.

### Hazards and Compatibility

- **Concurrency/atomicity:** reconcile simultaneous local/remote edits without last-writer data loss; document the conflict owner and durable acknowledgement point.
- **Migration/rollback:** additive/versioned state first, verified backfill second; retain old readers and reversible source backups.
- **Mixed-version/backward compatibility:** current TODO/Beads/foreign-ref readers remain usable; unknown fields and evidence are not discarded.
- **Idempotency/retry:** export/import and relationship rebuilding must not create duplicate tasks or replay side effects.
- **Partial failure/recovery:** offline mode remains useful, incomplete ingestion is visible, and recovery refuses unsupported completeness claims.

### Verification Before Dispatch

```bash
bash .agents/scripts/test-issue-sync-lib.sh
.agents/scripts/linters-local.sh --changed
git diff --check
```

- **Surface mapping:** sync tests protect parser/ref compatibility; scoped lint covers changed shell/docs. The new offline-loss fixture and its exact command must be recorded with the chosen bounded repair; no live account purchase or destructive forge operation is authorized.

### Progressive Context Plan

- **Read first:** parent maintainer direction, task-lifecycle ownership, then the actual creation/sync functions for the selected state fields.
- **Load only if:** provider-specific docs for the adapter actually being repaired; verify installed CLI/API versions before mapping changes.
- **Stop when:** the recovery matrix, concrete gap and focused proof are sufficient; do not design another supervisor or general database platform.

## Acceptance Criteria

- [ ] An offline exercise reconstructs complete captured plans, task IDs, dependencies and progress/evidence without the original forge or session DB.
- [ ] Aidevops-generated state is durable before publication and incoming acknowledgement/lag semantics are explicit; unobserved remote events are not falsely claimed recoverable.
- [ ] Repeated recovery preserves identity/provenance and does not duplicate tasks, discard fields, or replay stale authority/actions.
- [ ] Supported and unimplemented adapter coverage is honestly documented, with a bounded compatible repair and remaining gaps individually actionable.

## Seeded Draft PR

Skipped — persistence design must follow the demonstrated existing-store gap.

Parent: #31280
