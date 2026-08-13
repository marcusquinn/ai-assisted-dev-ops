# Auto-Dispatch Reference

Detail for auto-dispatch mechanics, origin label rules, and dispatch dedup. For the essential rules, see `AGENTS.md` "Auto-Dispatch and Completion".

## Origin Label Mutual Exclusion (t2200)

`origin:interactive`, `origin:worker`, and `origin:worker-takeover` are mutually exclusive — an issue/PR has exactly one origin at any time.

**To change an existing issue's origin label:** use `set_origin_label <num> <slug> <kind>` from `shared-constants.sh` — it atomically adds the target and removes the siblings in a single `gh issue edit` call (mirrors the `set_issue_status` pattern for status labels).

For edit sites that fold origin changes into another `gh issue edit` call (e.g., `set_issue_status` extra flags), include explicit `--remove-label` for both sibling origins alongside the `--add-label`.

New issue/PR creation via `gh_create_issue`/`gh_create_pr` is safe — no siblings exist yet.

The `ORIGIN_LABELS` constant in `shared-constants.sh` is the canonical list.

- Regression test: `.agents/scripts/tests/test-origin-label-exclusion.sh`
- One-shot reconciliation: `.agents/scripts/reconcile-origin-labels.sh`

## `#auto-dispatch` Skips `origin:interactive` Self-Assignment (t2157, t2406, t2218)

When any of the three issue-creation paths creates an issue tagged `#auto-dispatch`, the pusher is NOT self-assigned even when the session origin is `interactive`.

**Why:** Self-assignment would create the `(origin:interactive + assigned + active status)` combo that GH#18352/t1996 treats as a permanent dispatch block, stranding the issue until manual `gh issue edit --remove-assignee` or the 1h `STAMPLESS_INTERACTIVE_AGE_THRESHOLD` safety net (t2148, threshold reduced from 24h to 1h in t2942).

The three paths where the skip fires:
- `issue-sync-helper.sh` (TODO-first push)
- `gh_create_issue` (direct wrapper)
- `claim-task-id.sh` (agent-claimed follow-up)

An `[INFO]` log line is emitted when the skip fires: `Skipping auto-assign for #N — auto-dispatch entry is worker-owned`.

For issues already created before this carve-out, `interactive-session-helper.sh post-merge <PR>` (t2225) automates the heal across every issue referenced in a just-merged PR.

Regression tests:
- `.agents/scripts/tests/test-auto-dispatch-no-assign.sh` (issue-sync path)
- `.agents/scripts/tests/test-gh-create-issue-auto-dispatch-skip.sh` (gh_create_issue path)
- `.agents/scripts/tests/test-claim-task-id-autodispatch.sh` (claim-task-id path)

## Auto-Dispatch Conversation Lock (GH#30180)

`auto-dispatch` is both an execution authorization and an instruction-freeze
boundary. Managed creation through `gh_create_issue` locks the conversation and
verifies the resulting GitHub state. Pulse reconciles the complete visible open
issue snapshot so queued and dependency-blocked auto-dispatch issues are also
locked before any worker reads them. The final spawn gate independently repeats
that lock and verification and fails closed if GitHub cannot confirm it.

Worker cleanup retains the lock while `auto-dispatch` remains active, including
retryable failures. Pulse unlocks only locks it owns after automatic execution
eligibility is removed, or existing terminal lifecycle handling removes the
label before cleanup. GitHub locking is defence-in-depth: author/collaborator
validation and untrusted-content rules still apply to content written before the
lock.

Regression tests:
- `.agents/scripts/tests/test-auto-dispatch-conversation-lock.sh`
- `.agents/scripts/tests/test-gh-create-issue-auto-dispatch-skip.sh`
- `.agents/scripts/tests/test-precreation-failure-skip.sh`

## General Dedup Rule — Combined Signal (t1996)

The dispatch dedup signal is `(active status label) AND (non-self assignee)` — both required, neither sufficient alone. Every code path that emits a dispatch claim must consult `dispatch-dedup-helper.sh is-assigned` before assigning a worker. Label-only or assignee-only filters are not safe in multi-operator conditions.

Four cases:

| State | Result |
|-------|--------|
| Status label without assignee | Degraded state (worker died mid-claim) — safe to reclaim after `normalize_active_issue_assignments` / stale recovery |
| Non-owner/maintainer assignee without status label | Active contributor claim — always blocks dispatch regardless of labels |
| Owner/maintainer assignee WITH active status label | Active pulse claim — blocks dispatch (GH#18352) |
| Owner/maintainer assignee WITHOUT active status label | Passive backlog bookkeeping — allows dispatch (GH#10521) |

Architecture: `dispatch_with_dedup` → `check_dispatch_dedup` Layer 6 is the canonical enforcement point for all implementation dispatch.

`normalize_active_issue_assignments` in `pulse-issue-reconcile.sh` was hardened in t1996 to also call `is_assigned` before self-assigning orphaned issues.

Test coverage: `.agents/scripts/tests/test-dispatch-dedup-multi-operator.sh` (7 assertions).

## `origin:interactive` Skips Pulse Dispatch (GH#18352)

When an issue carries `origin:interactive` AND has any human assignee, the pulse's deterministic dedup guard (`dispatch-dedup-helper.sh is-assigned`) treats the assignee as blocking — even if that assignee is the repo owner or maintainer, regardless of the current `status:*` label.

This closes the race where an interactive session claimed a task via `claim-task-id.sh` (applying `status:claimed` + owner assignment) and the pulse dispatched a duplicate worker before the session could open its PR.

Full active lifecycle recognised: `status:queued`, `status:in-progress`, `status:in-review`, and `status:claimed` all keep owner/maintainer assignees in the blocking set.

## Issue-Sync TODO Auto-Completion (t2029 → t2166)

`issue-sync.yml` auto-marks TODO entries complete on PR merge. It first attempts direct publication, then treats a terminal GH006 protection rejection as a request to create or update one deterministic issue-sync PR. The job-scoped `GITHUB_TOKEN` opens that PR when the repository setting **Allow GitHub Actions to create and approve pull requests** is enabled. When that setting is disabled, `SYNC_PAT` is the bounded PR API fallback; branch protection and administrator enforcement remain unchanged.

**To configure the fallback when Actions PR creation is disabled** (run in a separate terminal, NOT in AI chat):

Create a fine-grained PAT in GitHub UI: `Settings → Developer settings → Personal access tokens → Fine-grained → Only selected repositories → <repo> → Contents: Read and write; Pull requests: Read and write`, then set it through the interactive prompt:

```bash
gh secret set SYNC_PAT --repo <owner>/<repo>
```

`SYNC_PAT` is per-repo. It is required for protected issue-sync publication only when Actions cannot create the fallback PR; repositories that enable Actions PR creation can use the job token alone. Under the reusable-workflow model, `secrets: inherit` in a same-owner caller grants access to the caller's secret, so any required PAT still has to exist in each downstream repo.

When GH006 and disabled Actions PR creation coincide, the job first attempts the least-privilege job token, recovers any concurrent PR, then retries the PR API write once with `SYNC_PAT`. Token values are never logged.

Without either Actions PR creation or a sufficiently scoped `SYNC_PAT`, the deterministic branch remains available for recovery but the workflow fails closed because it cannot open the PR.

**t2166** extended protected-publication handling to all four jobs. GH#29679 replaces its direct-push remediation path with the deterministic PR flow and reports which credential path is available without printing token values.

**Detector scope (t2806, GH#20745):** `aidevops security check` detects protected issue-sync publication under both classic branch-protection rules and repository rulesets, then checks whether Actions may create the fallback PR. It advises on `SYNC_PAT` only when protection requires the PR path and the job token cannot create it. See `security-posture-helper-repo.sh::_branch_is_rulesets_protected` and `_actions_can_create_pull_requests`.

**Known false-positive (pending t2252):** the auto-completion path may mis-mark planning-only PRs (those using `Ref #NNN` / `For #NNN` without closing keywords) as `status:done` on merge — tracked as GH#19782.

## Dispatch-Path Default (t2821 / t2920)

Tasks that modify the worker dispatch/spawn path **historically** defaulted to `no-auto-dispatch` because of the **tautology failure mode**: a worker dispatched to fix broken dispatch runs through the code being fixed. The canonical incident was #20765 (t2814): 3 worker attempts across ~90 minutes, ~90K tokens burned before a successful opus-4-7 run.

**As of t2920 (Apr 2026), this default is reversed: dispatch-path tasks auto-dispatch like everything else.** The protection cascade now covers the residual risk:

1. **Worker worktree isolation** — workers operate in isolated worktrees; a buggy in-flight fix cannot affect the live pulse.
2. **t2819 pre-dispatch detector** — normalizes dispatch-path tasks to one `tier:thinking` label before dispatch, eliminating wasted lower-tier attempts while runtime routing chooses the model.
3. **CI gates** — every PR runs the full quality suite before merge.
4. **Watchdog kills** — `worker-activity-watchdog.sh` kills workers with no output for 300s.
5. **t2690 circuit breaker** — pauses ALL dispatch when GraphQL budget < 5%.
6. **t2820 cheaper failed attempts** — `no_work` reclassification reduces retry cost.

Combined, this cascade catches what slips. The cost of pre-blocking dispatch-path issues from a single-operator backlog (17 issues stuck on aidevops at the time of t2920) far exceeds the residual tautology risk.

### Trigger

The task's brief `## How` section or `### Files Scope` references any file in the canonical self-hosting set. The canonical list is `.agents/configs/self-hosting-files.conf` — shared by `pre-dispatch-validator-helper.sh` (t2819) and the helpers below. Current entries: `pulse-wrapper.sh`, `pulse-dispatch-*`, `pulse-cleanup.sh`, `headless-runtime-helper.sh`, `headless-runtime-lib.sh`, `worker-lifecycle-common.sh`, `shared-dispatch-dedup.sh`, `shared-claim-lifecycle.sh`, `worker-activity-watchdog.sh`, `dispatch-dedup-helper.sh` (t2832).

### Decision tree (post-t2920)

1. Brief references a dispatch-path file → use `#auto-dispatch` as normal. The t2819 detector replaces lower tier labels with `tier:thinking` before dispatch. The advisory tooling below emits non-blocking informational messages.
2. Author implements the issue interactively → keep `#auto-dispatch` and start through `interactive-start-helper.sh ... --auto-dispatch`. The temporary `status:in-review` + assignee claim blocks concurrent dispatch; release and unassign restore automatic continuation.
3. A durable manual stop is explicitly required → use `#no-auto-dispatch` (or `interactive-session-helper.sh lockdown` when all pulse mutation must stop) and record the unresolved human decision or safety reason.
4. No dispatch-path files in brief → normal dispatch rules apply.

`#dispatch-path-ok` is now redundant. Existing issues that carry it document explicit author intent — leave them alone.

### Tooling (post-t2920, advisory only)

- `task-brief-helper.sh` scans the generated brief and appends a `## Dispatch-Path Classification (advisory)` section when patterns are found, noting that the t2819 detector will auto-elevate the worker.
- `claim-task-id.sh` emits a **non-blocking** stderr `log_info` when `--labels auto-dispatch` is used on a dispatch-path task, naming the auto-elevation. No recommendation to switch to `no-auto-dispatch`.
- Both helpers load patterns from `.agents/configs/self-hosting-files.conf`; adding a new file to the conf automatically updates all detection points.

### When to opt out (post-t2920)

The opt-out (`#no-auto-dispatch`) is a durable exception, not an interactive-session default. Use it when:

1. The user explicitly requests manual-only handling or a backlog freeze with no unattended continuation.
2. An unresolved security, product-safety, billing, or authority decision makes unattended execution unsafe.
3. An incident investigation requires insulation from every pulse mutation; use `lockdown`, then `unlock` when the incident boundary ends.

Routine interactive implementation is not an opt-out: keep `#auto-dispatch`, rely on the active claim for temporary deduplication, and release with unassignment if work remains. Parent/roadmap trackers use `parent-task`, not `no-auto-dispatch`. For routine bug fixes, refactors, and well-specified work in dispatch-path files, use `#auto-dispatch`.

### Environment overrides

| Variable | Effect |
|---|---|
| `AIDEVOPS_SKIP_DISPATCH_PATH_CHECK=1` | Disable both the brief notice and claim-task-id advisory |
| `AIDEVOPS_DISPATCH_PATH_FILES_CONF=<path>` | Override the conf file path |

### Labels

| Label | Meaning |
|---|---|
| `dispatch-path-ok` | (Legacy / redundant since t2920) Author explicitly requested auto-dispatch on a dispatch-path task. New tasks don't need this label. |
| `parent-task` | Unconditional dispatch block — `dispatch-dedup-helper.sh` `_is_assigned_check_parent_task` short-circuits with `PARENT_TASK_BLOCKED` |
| `no-auto-dispatch` | Canonical unconditional issue dispatch block (t2832) — `dispatch-dedup-helper.sh` `_is_assigned_check_no_auto_dispatch` short-circuits with `NO_AUTO_DISPATCH_BLOCKED`. Reserve it for explicit durable manual intent or a recorded unresolved safety/authority decision, never routine interactive ownership. |
| `hold-for-review` | Confirmed unresolved review hold. On issues, blocks dispatch with the same intent as `no-auto-dispatch` (`HOLD_FOR_REVIEW_BLOCKED`). On PRs, blocks auto-merge until explicit maintainer review. Scanner infrastructure failures retry without applying this label. |

Companion fixes: t2819 (self-hosting pre-dispatch tier override), t2820 (no_work reclassification), t2832 (no-auto-dispatch unconditional block), t2920 (default reversed to auto-dispatch + advisory). Derived from #20765 / GH#20827 / GH#21086 dispatch-history analysis.

## Reusable-Workflow Architecture (t2770)

Since v3.9.0, `issue-sync.yml` is a **reusable workflow** — downstream repos ship a ~45-line caller YAML that `uses:` the reusable workflow from `marcusquinn/aidevops`. This eliminates YAML drift (the canonical cause of GH#20637-class incidents where downstream copies went stale) and removes the need for downstream repos to carry `.agents/scripts/` — framework scripts are fetched at runtime via a secondary `actions/checkout` step.

Full architecture, pinning strategies, migration guide: `reference/reusable-workflows.md`.
