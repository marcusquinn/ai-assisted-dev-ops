<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Planning & Tasks — Detail Reference

Loaded on-demand when working with tasks, TODO.md, or the supervisor dispatch system.
Core rules are in `AGENTS.md`. Full planning docs: `workflows/plans.md`, `tools/task-management/beads.md`.

## Key Commands

`/new-task`, `/save-todo`, `/ready`, `/sync-beads`, `/plan-status`, `/create-prd`, `/generate-tasks`

Use `/save-todo` after planning. Auto-detects complexity:
- **Simple** → TODO.md only
- **Complex** → PLANS.md + TODO.md reference

## Task Format

`- [ ] t001 Description @owner #tag ~1h started:ISO blocked-by:t002`

Dependencies: `blocked-by:t001`, `blocks:t002`, `t001.1` (subtask).

## Auto-Dispatch

Add `#auto-dispatch` to tasks that can run autonomously (clear spec, bounded scope, no user input needed). Default to including it — only omit when a specific exclusion applies. See `workflows/plans.md` "Auto-Dispatch Tagging". Phase 0 picks these up each pulse cycle (default every 3 minutes; configurable via `supervisor.pulse_interval_seconds`) and auto-creates batches (`auto-YYYYMMDD-HHMMSS`, concurrency = cores/2, min 2) when no active batch exists.

**Interactive claim guard** (t1062): When working interactively on a `#auto-dispatch` task, add `assignee:` or `started:` before pushing — the supervisor skips tasks with these fields to prevent race conditions.

## Lifecycle Status Tags

The supervisor updates `status:` on each TODO.md line at every decision point. Updated by `ai-lifecycle.sh`, batch-committed once per pulse.

**Lifecycle states** (progressive):

| Tag | Meaning |
|-----|---------|
| `status:dispatched` | Worker session launched |
| `status:running` | Worker actively coding |
| `status:evaluating` | Checking worker output |
| `status:pr-open` | PR created, awaiting CI |
| `status:ci-running` | CI checks in progress |
| `status:ci-passed` | CI green, ready to merge |
| `status:merging` | Merge in progress |
| `status:merged` | PR merged to main |
| `status:deploying` | Running deploy/setup |
| `status:deployed` | Live on main, awaiting verification |
| `status:verified` | Post-merge verification passed |

**Action states** (transient):

| Tag | Meaning |
|-----|---------|
| `status:updating-branch` | Updating PR branch via GitHub API |
| `status:rebasing` | Git rebase onto main |
| `status:resolving-conflicts` | AI resolving merge conflicts |
| `status:reviewing-threads` | Triaging PR review comments |

**Problem states** (needs attention or patience):

| Tag | Meaning |
|-----|---------|
| `status:behind-main` | PR needs update, supervisor will handle |
| `status:has-conflicts` | Merge conflicts, AI attempting resolution |
| `status:ci-failed` | CI checks failed, investigating |
| `status:changes-requested` | Human reviewer requested changes |
| `status:blocked:<reason>` | Cannot proceed, reason given |

`SUPERVISOR_AI_LIFECYCLE=true` (default): intelligence-first decision-making — gathers real-world state (DB, GitHub PR, CI, git), decides next action, executes, updates status. Set `false` to fall back to legacy `cmd_pr_lifecycle` bash heuristics.

## Blocker Statuses

Add these tags to tasks needing human action before proceeding. The supervisor's eligibility assessment detects them and skips dispatch: `account-needed`, `hosting-needed`, `login-needed`, `api-key-needed`, `clarification-needed`, `resources-needed`, `payment-needed`, `approval-needed`, `decision-needed`, `design-needed`, `content-needed`, `dns-needed`, `domain-needed`, `testing-needed`.

## Estimation Calibration

Estimates = **AI-assisted wall-clock time** (branch creation to PR-ready). NOT human-developer estimates.

**Calibrated from 340 completed tasks**: median estimate/actual ratio was 2.2x (estimates were 2.2x too high); 53% of tasks had estimates >2x actual. Root cause: estimates written as if a human were doing the work.

| Tier | Estimate | Scope | Examples |
|------|----------|-------|---------|
| Trivial | `~15m` | 1-2 file edits, single function | Fix typo, update config value, add label |
| Small | `~30m` | Single-file feature, helper function | New helper script, add CLI flag, fix bug |
| Medium | `~1h` | Multi-file, CI workflow, new integration | New subagent, API integration, workflow |
| Large | `~2h` | 5+ files, new subsystem, cross-cutting | New feature with tests, refactor module |
| Major | `~4h` | Cross-cutting orchestration, new system | New orchestration layer, major redesign |

**Rules:** Default to `~30m` (median actual). Only use `~4h` for genuinely complex multi-system work. `~2h` triggers auto-subtasking. When in doubt, estimate lower — over-estimation wastes dispatch capacity.

**Note on `actual:` field:** Recorded by `session-time-helper.sh` as active session time (AI execution cost), not wall-clock time (delivery speed). Calibration above uses git-measured wall-clock (branch creation to last commit before PR).

## Auto-Subtasking

(t1188.2): Tasks with estimates >2h and no existing subtasks are flagged `needs-subtasking`. The AI reasoner uses `create_subtasks` to break them into dispatchable units (~15m-2h each). Tasks with subtasks are flagged `has-subtasks` — the supervisor dispatches the subtasks instead.

## Cross-Repo Concurrency Fairness

(t1188.2): Each repo gets at least 1 dispatch slot; remaining slots distributed proportionally by queued task count. Prevents one repo's large backlog from starving others.

## Stale-Claim Auto-Recovery

(t1263): Tasks with `assignee:`/`started:` from dead sessions become permanently stuck. The pulse detects stale claims — tasks with these fields where (1) no active worker process, (2) no active worktree, (3) claim age >24h — and auto-unclaims by stripping those fields. Respects t1017 assignee ownership: only unclaims tasks assigned to the local user. Configure: `SUPERVISOR_STALE_CLAIM_SECONDS` (default: 86400).

## Task Completion Rules

CRITICAL — prevents false completion cascade:

### PR Lookup Fallback (t1343)

NEVER rely on a single data source when verifying a merged PR. Use this fallback chain:

1. **Local DB/memory** — check your own session's record of the PR URL
2. **GitHub search** — if local lookup fails:

   ```bash
   gh pr list --repo <owner/repo> --state merged --search "<task_id>" --json number,title,mergedAt --limit 5
   ```

3. **Issue cross-reference** — check the linked issue timeline, then verify merge state:

   ```bash
   # Extract PR numbers from cross-referenced timeline events
   PR_NUMBERS=$(gh api repos/<owner/repo>/issues/<issue_number>/timeline \
     --jq '[.[] | select(.event=="cross-referenced" and .source.issue.pull_request != null) | .source.issue.number] | unique[]')

   # Verify each candidate PR is actually merged (not just linked)
   for pr in $PR_NUMBERS; do
     MERGED=$(gh pr view "$pr" --repo <owner/repo> --json mergedAt -q '.mergedAt // empty' 2>/dev/null)
     if [[ -n "$MERGED" ]]; then
       echo "Confirmed merged PR #$pr (merged at $MERGED)"
       break
     fi
   done
   ```

   IMPORTANT: Cross-referenced events only establish a link — they do NOT confirm merge state. Always verify `mergedAt` via the pulls API.

If ANY source confirms a merged PR (with verified `mergedAt`), treat the task as having PR evidence. The race condition in Issue #2250 occurred because a worker only checked its own DB (source 1), missed the PR created by a different session, and incorrectly flagged the issue as `needs-review`.

- NEVER mark `[x]` unless a merged PR exists with real deliverables for that task
- Use `task-complete-helper.sh <task-id> --pr <number>` or `--verified` to mark tasks complete
- Every completion MUST have `pr:#NNN` or `verified:YYYY-MM-DD` (enforced by helper and `update_todo_on_complete()`)
- The pre-commit hook rejects TODO.md commits where `[ ] → [x]` without proof-log
- File existence is NOT sufficient — verify the PR was merged and contains substantive changes
- `no_pr` or `task_only` worker exits: task stays `[ ]` until human or supervisor verifies the deliverable
- The `issue-sync` GitHub Action auto-closes issues when tasks are marked `[x]` — false completions cascade into closed issues
- NEVER close GitHub issues manually with `gh issue close` — let issue-sync verify deliverables before closing. Manual closure bypasses the proof-log safety check
- **Merge state verification (GH#17871)**: Before closing an issue based on a PR, verify `mergedAt` is non-null via `gh pr view <N> --json mergedAt`. An open PR means work is in progress, not complete. The dedup helper returns exit 0 for BOTH open and merged PRs — callers that close issues must independently verify merge state.
- **Pre-commit enforcement**: warns on `[ ]` → `[x]` without `verified:` or merged PR evidence (warning only — commit proceeds)
- **Framework function references**: NEVER reference framework functions, automation, or processes that don't exist in the codebase. Workers that invent non-existent processes (e.g., referencing `_dispatch_issue_consolidation()` when no such function exists) create false audit trails. If proposing a new process, clearly label it as a proposal — never present it as existing automation.

## Planning File Workflow

**After ANY TODO/planning edit** (interactive sessions only, NOT workers): publish immediately with `planning-commit-helper.sh`. Planning-only files (`TODO.md`, `todo/**`) go direct to the default branch only when that branch accepts direct planning pushes; protected default branches get a planning-only PR. Mixed changes (planning + non-exception files) use a worktree. NEVER `git checkout -b` in the main repo. Do not route `.task-counter` through planning PRs — task IDs remain CAS-allocated by `claim-task-id.sh` on the configured `counter_branch`.

**PR required for ALL non-planning changes** (MANDATORY): Every change to scripts, agents, configs, workflows, or any file outside `TODO.md` and `todo/` MUST go through a worktree + PR + CI pipeline — no matter how small. The pre-edit-check script enforces this; never bypass it.

## Task ID Allocation

MANDATORY: Use `/new-task` or `claim-task-id.sh`. NEVER grep TODO.md for the next ID — causes collisions in parallel sessions.

1. `/new-task "Task title"` — interactive slash command (preferred)
2. `planning-commit-helper.sh next-id --title "Task title"` — wrapper function
3. `claim-task-id.sh --title "Task title" --repo-path "$(pwd)"` — direct script

**Atomic counter** (t1047): IDs allocated from `.task-counter` via CAS loop — fetch from the configured `counter_branch`, increment, commit, push. Push failure (another session grabbed the ID) → retry from fetch. Guarantees no collisions. A protected counter branch is a setup error: initialize a dedicated unprotected branch from the current canonical counter value, set `.aidevops.json` `counter_branch` to it, and verify the selected branch has no pull-request rule while default-branch protection remains unchanged. When config omits `counter_branch`, the allocator adopts a conventional `task-id-counter` branch only after proving its counter is not behind either the default branch or the TODO-derived seed. Never route counter updates through a PR because review/merge is not an atomic lock. GitHub policy preflight rejects a known PR-only branch before reading or advancing the counter; push rejection remains the fallback when policy APIs are unavailable. Batch: `--count N` claims N consecutive IDs atomically. GitHub/GitLab issue creation happens after ID is secured (optional, non-blocking). Offline fallback: local `.task-counter` + 100 offset (reconcile when back online). Output: `task_id=tNNN ref=GH#NNN` (offline: `ref=offline reconcile=true`; batch: adds `task_id_last=tNNN task_count=N`). Retries up to 10 attempts with backoff — no manual intervention needed.

## Worker TODO.md Restriction

Workers must NEVER edit TODO.md. See `workflows/plans.md` "Worker TODO.md Restriction".
