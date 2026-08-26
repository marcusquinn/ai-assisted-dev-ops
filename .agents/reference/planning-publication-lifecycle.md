<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Atomic Task Dispatch and Planning Publication

Decision record for GH#27791. This document defines how `/new-task`, task-ID
allocation, planning publication, issue sync, and pulse dispatch must coordinate
when `TODO.md` and `todo/**` are the canonical planning source.

## Decision

Use a **hold-until-published** model with an orthogonal
`publication:pending` issue label.

- `claim-task-id.sh` may create an issue before planning publication because the
  issue-backed allocation and immutable mapping are part of collision safety.
- An issue created from unpublished local planning state receives
  `publication:pending`. It does not receive `auto-dispatch` or
  `status:available`, even when those are the intended post-publication labels.
- Creators must include `publication:pending` in the issue-create request rather
  than add it afterward, so issue-open synchronization cannot race the blocker.
- A task becomes publishable only when its TODO entry and worker brief (or a
  canonical stub that identifies a worker-ready issue body) are both visible on
  the repository's default branch.
- Default-branch issue sync is the authority that projects dispatch intent from
  those files to GitHub. It removes `publication:pending` only after validating
  the canonical source, then applies the intended lifecycle and dispatch labels.
- Pulse treats `publication:pending` as an unconditional blocker at candidate
  query, dedup, and pre-launch verification layers. Absence of
  `status:available` is the normal first guard; the explicit blocker is
  defence-in-depth against partial label mutations and external automation.

The invariant is:

```text
dispatchable(issue)
  => issue is open
  && issue has auto-dispatch
  && issue has status:available
  && issue lacks publication:pending
  && canonical_task(default_branch, issue) is worker-ready
  && all existing trust, dependency, ownership, and dedup gates pass
```

The reverse is intentionally not guaranteed: a published task can remain
blocked, parent-only, claimed, held for review, or manual.

## Authority and durable state

| Concern | Authority | Durable evidence |
|---|---|---|
| Unique task ID and issue mapping | task coordinator / `claim-task-id.sh` CAS | counter branch plus validated task-to-issue mapping |
| Worker brief | default branch | `todo/tasks/<task>-brief.md`, including a canonical issue-body stub when used |
| Dispatch intent | default branch | TODO tags, brief readiness, dependencies, and origin metadata |
| Publication in progress | GitHub issue | `publication:pending` |
| Planning publication attempt | Git branch / PR | planning commit and machine-readable task manifest in the planning PR body |
| Runtime claim | GitHub issue | existing assignee, status, and dispatch-claim evidence |

An issue body can contain the complete worker instructions, but it does not
independently authorize dispatch. A canonical stub on the default branch binds
that body to the task and makes the selected source explicit. This preserves the
existing no-duplication optimization without making issue creation order a
hidden dispatch switch.

## State model

Publication is independent of execution status:

```text
LOCAL_ONLY
  issue: absent (offline/no-issue) or publication:pending
  default branch: no canonical task

PUBLISHING
  issue: publication:pending; no auto-dispatch/status:available projection
  publication: direct push in progress OR planning PR open

PUBLISHED
  issue: publication:pending removed
  default branch: TODO entry + worker-ready brief/stub validated
  issue: intended labels projected (available, blocked, parent, claimed, manual)

PUBLICATION_FAILED
  issue: publication:pending retained
  default branch: canonical task absent or invalid
  recovery: retry the same publication/mapping; never allocate a replacement ID
```

`publication:pending` is preferable to overloading `status:blocked` because
publication can coexist with intended `status:blocked`, `status:claimed`, or
interactive states. It is preferable to `no-auto-dispatch` because that label
expresses durable manual intent and would require guessing whether removal was
safe. `status:queued` is not suitable because it already means a worker was
selected but has not started.

## Transitions

### Direct-push success and failure

```text
allocate ID + create issue
  -> apply publication:pending
  -> write TODO + brief/stub locally
  -> validate planning snapshot
  -> push planning commit to default branch
      success -> reconcile canonical task
                 -> project intended labels
                 -> remove publication:pending last
      failure -> retain publication:pending
                 -> preserve local snapshot and immutable issue mapping
                 -> retry publication idempotently
```

Removing the blocker last means an API failure cannot expose an incompletely
projected issue. If the final removal fails, default-branch issue sync retries
the same transition. Repeating the transition is a no-op once labels match.

### Protected-branch success and failure

```text
allocate ID + create issue (publication:pending)
  -> write TODO + brief/stub locally
  -> create planning branch and PR with task/issue manifest
      PR open -> retain publication:pending
      PR merged -> default-branch issue sync validates files
                   -> project intended labels
                   -> remove publication:pending last
      PR closed unmerged -> retain publication:pending
                            -> record retryable publication failure
                            -> retry reuses issue mapping and opens/reuses a PR
      branch deleted before merge -> same as closed unmerged
```

Planning PR manifest, title, receipt, and retry details are defined in
`planning-pr-publication-contract.md`.

The post-merge transition is driven by the existing default-branch push path,
not by trusting a PR's mergeable state. A `pull_request.closed` reconciliation
may provide faster diagnostics, but only default-branch file validation may
clear the blocker.

### Partial API failures

| Failure | Required result | Recovery |
|---|---|---|
| Issue created, planning publication fails | Issue remains pending and non-dispatchable | Retry with the same issue mapping and publication snapshot |
| Planning lands, issue label mutation fails | Default branch is canonical; issue remains safely pending | Default-branch and periodic reconciliation retry label projection |
| Pending label creation/application fails | Do not apply `auto-dispatch` or `status:available`; fail task creation visibly | Retry issue normalization before publication |
| Final blocker removal fails | Task remains safely pending | Idempotent reconciliation removes it later |
| Blocker removed but verification read fails | Do not report success; pulse pre-launch canonical check fails closed | Reconcile and verify exact issue/default-branch pair |

## Flow-specific behavior

### Auto-dispatch

Store `#auto-dispatch` intent in the local TODO entry, but defer the GitHub
`auto-dispatch` and `status:available` labels until canonical validation. The
current readiness checks still apply before publication and again during issue
sync. Publication does not weaken brief quality gates.

### Interactive claim

An interactive task may be assigned and marked `status:in-progress` while
publication is pending. It remains ineligible for pulse because it is claimed
and carries `publication:pending`. Publication reconciliation removes only the
publication blocker and preserves interactive ownership/status.

### Blocked tasks and parent tasks

After publication, dependency-blocked tasks retain `status:blocked`; parent
tasks retain `parent-task`; neither becomes available merely because planning
landed. Existing native dependency, `parent-task`, maintainer-review, credential,
and security gates remain authoritative in addition to publication readiness.

### Manual tasks

Tasks carrying `#no-auto-dispatch`, `hold-for-review`, or no dispatch intent have
the pending blocker removed after publication but do not gain
`auto-dispatch`/`status:available`.

### Offline and `--no-issue`

No GitHub publication state exists. Planning files can be committed locally,
but the task is not remotely dispatchable. Online reconciliation first creates
or validates the issue mapping with `publication:pending`, publishes the
planning files, then performs the normal canonical transition.

### Batch creation

All batch issues begin pending. One planning publication carries a manifest of
every task/issue pair. After a direct push or PR merge, reconciliation evaluates
each task independently: valid entries transition; invalid entries remain
pending. The batch command succeeds only when every requested task is either
published and reconciled or reported with a durable retry state. A partial API
failure must not roll back already published siblings or expose unpublished
ones.

### Issue-body briefs

When the issue body is worker-ready, publish a small canonical stub containing
the repository slug, immutable issue number, and readiness/schema marker.
Headless mode must not skip the file entirely. Issue edits can then be handled
by the existing readiness/review lifecycle without making an unbound issue body
equivalent to default-branch planning state.

## Alternatives considered

### Delay issue creation until planning is published

**Rejected as the default.** It gives the cleanest visible ordering but conflicts
with the issue-backed collision-safe allocation and cross-runner mapping flow.
It also leaves direct-push success followed by issue-creation failure with a
canonical task that has no tracker. Replacing the allocator would have a much
larger migration and concurrency risk.

It remains valid for explicit offline/`--no-issue` planning, where remote
dispatch is impossible by definition.

### Hold the issue until planning is published

**Selected.** It preserves allocation/mapping behavior, works for both direct
pushes and protected branches, and fails closed under every partial ordering.
The cost is one extra label plus a reconciliation mutation. The label is
orthogonal because publication readiness is not an execution status.

### Treat a worker-ready issue body as the canonical source immediately

**Rejected as the general rule.** It would make dispatch semantics depend on
which body-composition path ran, bypass default-branch review for protected
repositories, and leave TODO/brief reconciliation racing an already running
worker. It also makes batch and offline behavior inconsistent. Canonical stubs
retain the storage optimization while preserving one publication rule.

### Reuse an existing hold label

**Rejected.** `status:blocked` means dependencies, `hold-for-review` means a
human decision, `no-auto-dispatch` means durable manual intent, and
`status:queued` means worker ownership. Reusing any of them makes automated
release ambiguous and can either strand tasks or remove a deliberate hold.

## Compatibility, cost, and migration

- Existing published issues without `publication:pending` retain legacy
  behavior. Do not bulk-label historical work.
- Issue-sync pull defers orphan TODO seeding for an open issue carrying the
  exact `publication:pending` label. Once the canonical row appears, reference
  synchronization proceeds normally; removing the label before publication
  restores legacy orphan recovery on the next pull.
- New task-creation paths opt into the protocol together. During rollout, pulse
  must understand the blocker before creators can emit it, and creators must
  defer available labels before reconciliation is enabled.
- Recommended rollout order: dispatch blocker -> reconciliation dry-run ->
  creator pending state -> deferred label projection -> enforce canonical
  pre-launch validation.
- Normal creation adds at most one issue-label mutation; publication adds one
  projection mutation and one blocker removal. Batch reconciliation should use
  the existing prefetched issue set and group label operations to avoid per-task
  list queries.
- The planning PR manifest is derived from changed TODO entries and their
  validated `ref:GH#` fields; it adds no GitHub read per task.
- Periodic reconciliation should query only open `publication:pending` issues
  and use cached/default-branch planning data. This bounds API cost to anomalous
  or in-flight tasks.

## Recovery and idempotency contract

Every reconciliation takes `(repository, task_id, issue_number,
default_branch_sha)` and verifies the immutable mapping before writing.

1. Read the TODO entry and brief/stub from the exact default-branch SHA.
2. Verify the TODO `ref:GH#` matches the target issue and readiness passes.
3. Compute the complete desired label set without mutating.
4. Apply non-dispatch lifecycle, origin, tier, dependency, and blocker labels.
5. Apply `auto-dispatch` and `status:available` only when the desired state is
   dispatchable.
6. Remove `publication:pending` last.
7. Re-read and verify the issue against the same default-branch SHA.

Retries repeat this sequence. Duplicate invocations, merge-webhook replay,
direct-push plus workflow overlap, and API timeouts converge on the same state.
No retry allocates a new ID or creates a second issue.

Planning PR closure without merge is recoverable because the issue and mapping
remain pending. The next `/new-task` publication retry discovers an open or
closed planning attempt by publication ID, reuses a compatible open PR, or
creates a replacement from the current default branch. A periodic diagnostic
may flag pending tasks with no open publication attempt, but must not clear the
blocker or create dispatch labels.

## Implementation decomposition

Implement these ordered child tasks rather than one high-blast-radius PR.

### Child 1: Add the publication blocker and fail-closed dispatch gates

**What:** Before creators emit the label, make `publication:pending` an unconditional defence-in-depth dispatch blocker. **Depends on:** nothing; merge first.

**Files:** register it in `label-sync-helper.sh`; preserve it in `issue-sync-helper-labels.sh`; block it before assignee handling in `dispatch-dedup-helper.sh` and its label module; exclude it in `pulse-wrapper-cycle-gates.sh`; reject it again before claim/launch in `pulse-dispatch-core.sh`; document it in `reference/dispatch-blockers.md`.

**Tests:** update the two dispatch-dedup fixtures and `test-pulse-wrapper-cycle-gates.sh` (add a focused pulse-core fixture only when necessary). Prove `auto-dispatch + status:available + publication:pending` cannot launch, including direct bypasses, while existing dependency, parent, NMR, credential, and claim fixtures remain green.

```bash
bash .agents/scripts/tests/test-dispatch-dedup-helper-is-assigned.sh
bash .agents/scripts/tests/test-dispatch-dedup-helper-enumerate-blockers.sh
bash .agents/scripts/tests/test-pulse-wrapper-cycle-gates.sh
shellcheck .agents/scripts/label-sync-helper.sh \
  .agents/scripts/issue-sync-helper-labels.sh \
  .agents/scripts/dispatch-dedup-helper.sh \
  .agents/scripts/pulse-wrapper-cycle-gates.sh \
  .agents/scripts/pulse-dispatch-core.sh
```

All three layers must fail closed; extract a focused helper rather than growing a function beyond the complexity limit.

### Child 2: Create tasks in pending state and defer dispatch labels

**What:** Every unpublished online task gets the blocker and no positive dispatch projection across rich, fallback, batch, and REST paths. **Depends on:** Child 1.

**Files:** pass explicit publication state through `claim-task-id.sh` and `claim-task-id-issue.sh`; make `issue-sync-helper-push.sh` distinguish unpublished local creation from canonical creation; apply the rule per batch item in `new-task-helper.sh` while retaining intended planning-file labels; prevent defaulting in `apply-status-available-default.yml` when pending.

**Tests:** replace the unconditional status-default expectation with pending/canonical fixtures; cover rich/fallback parity in the two existing claim-task tests; add `test-new-task-batch-publication-pending.sh` for a shared publication. Cover rich, bare, REST, interactive, parent, blocked, offline, and no-issue paths.

```bash
bash .agents/scripts/tests/test-claim-task-id-status-default.sh
bash .agents/scripts/tests/test-claim-task-id-auto-dispatch-no-assign.sh
bash .agents/scripts/tests/test-claim-task-id-rest-routing.sh
bash .agents/scripts/tests/test-new-task-batch-publication-pending.sh
shellcheck .agents/scripts/claim-task-id.sh \
  .agents/scripts/claim-task-id-issue.sh \
  .agents/scripts/issue-sync-helper-push.sh \
  .agents/scripts/new-task-helper.sh
```

Require a hard creation failure when the pending label cannot be verified, preserve explicit interactive/blocked/parent intent, and retain offline and `--no-issue` behaviour.

### Child 3: Publish a manifest and reconcile canonical tasks

**What:** Add one idempotent transition that validates the exact default-branch snapshot, projects labels, and removes the blocker last. **Depends on:** Child 2.

**Files:** add a task/issue manifest and publication ID to planning PR bodies in `shared-todo-commit.sh`, and to direct pushes in `planning-publisher.sh`; have `planning-commit-helper.sh` reconcile successful direct publication and distinguish pending PRs; add `planning-publication-reconcile.sh`; call it from `issue-sync-helper-push.sh`; run it on the merged default SHA in both issue-sync workflows.

**Tests:** extend planning-publisher for direct success/failure and metadata, protected-default-PR for the manifest and pending state, and add reconcile fixtures for merge, closed-unmerged, mutation failure, replay, mismatched mapping, invalid brief, and blocker-last.

```bash
bash .agents/scripts/tests/test-planning-publisher.sh
bash .agents/scripts/tests/test-planning-commit-helper-protected-default-pr.sh
bash .agents/scripts/tests/test-planning-publication-reconcile.sh
bash .agents/scripts/tests/test-issue-sync-push-failures.sh
shellcheck .agents/scripts/shared-todo-commit.sh \
  .agents/scripts/planning-publisher.sh \
  .agents/scripts/planning-commit-helper.sh \
  .agents/scripts/planning-publication-reconcile.sh \
  .agents/scripts/issue-sync-helper-push.sh
```

Require exact task/issue/default-SHA binding, no new issue on retry, unchanged pending state for invalid or unmerged planning, and a verified postcondition. Keep orchestration in the new reconciler, not an existing function over 100 lines.

### Child 4: Complete recovery, batch convergence, and documentation

**What:** Make abandoned and partial publications diagnosable and retryable, then update the user contract. **Depends on:** Child 3 and its reconciliation API.

**Files:** summarize each task and retry only failed siblings in `new-task-helper.sh`; add a bounded pending-issue repair scan to `pulse-issue-reconcile.sh`; document pending, direct-published, and planning-PR outcomes (without promising immediate queue visibility) in the new-task command/workflow; link this contract from `task-lifecycle.md`.

**Tests:** add the end-to-end fixture matrix in `test-planning-publication-lifecycle.sh`: direct success, protected PR, merged PR, closed-unmerged PR, creation then publication failure, publication then mutation failure, idempotent replay, and mixed batch convergence without exposing failures. Run ShellCheck on every changed shell file plus planning, issue-sync, dispatch-dedup, and pulse-candidate suites.

```bash
bash .agents/scripts/tests/test-planning-publication-lifecycle.sh
bash .agents/scripts/tests/test-planning-commit-helper-protected-default-pr.sh
bash .agents/scripts/tests/test-issue-sync-push-failures.sh
bash .agents/scripts/tests/test-pulse-wrapper-cycle-gates.sh
markdownlint .agents/scripts/commands/new-task.md \
  .agents/workflows/new-task.md \
  .agents/reference/task-lifecycle.md
```

Require per-item outcomes, safe retry after an unmerged PR, bounded repair scans, and no claim that an open planning PR is queued or dispatchable.

## Acceptance proof

Before publication, creators omit both positive dispatch labels and add an
independent blocker. During publication, only default-branch validation can
authorize the final transition. The blocker is removed last, and pulse verifies
its absence plus canonical readiness immediately before launch. Therefore no
ordering of issue creation, direct push, planning PR creation/merge, workflow
delivery, retry, or partial label mutation can produce a valid dispatchable
state before the selected canonical brief source is available.
