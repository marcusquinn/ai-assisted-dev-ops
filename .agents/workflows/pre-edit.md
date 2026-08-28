---
mode: subagent
tools:
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# Pre-Edit Git Check

Run before any file edits:

```bash
~/.aidevops/agents/scripts/pre-edit-check.sh
~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --file "path/to/file"
~/.aidevops/agents/scripts/pre-edit-check.sh --loop-mode --task "task description"
```

Pass `--file <path>` when the target file is known — this enables path-based enforcement (t1712). `--task` description heuristics are a fallback for callers that don't know the target path.

OpenCode callers may pass `targetPaths` to `aidevops_pre_edit_check`. Paths are
resolved relative to `workdir`. If every verified target is outside Git
worktrees, the tool reports **Git isolation not applicable** and does not create
an unrelated repository worktree. This result covers only Git isolation: it
does not authorize the external writes or bypass runtime path, secret,
destructive-operation, or managed-directory policy. Repository-local, mixed,
ambiguous, traversal, and symlinked scopes retain the stricter worktree gate or
fail closed. Callers without target paths retain the task-only fallback.

## Mode-Scoped Main-Branch Write Allowlist (t1712, t1990)

Interactive sessions have no `main`/`master` exception: every edit uses a linked worktree. For headless supervisor/routine/issue-sync bookkeeping and explicitly planning-only worker tasks, `pre-edit-check.sh` may allow these paths without a linked worktree:

| Path | Purpose |
|------|---------|
| `README.md` | Top-level readme |
| `TODO.md` | Task backlog |
| `todo/**` | Plans, briefs, task files |

All other paths and all interactive edits require a linked worktree. `pre-edit-check.sh` is authoritative for the mode and path decision; write-time hooks provide additional enforcement where available.

## Git Hook Status Without External-Directory Access

Linked worktrees share Git hooks with their canonical repository through
`git rev-parse --git-common-dir`. Never inspect that external `.git/hooks`
directory with generic Read, Glob, Edit, or Write tools.

Use `aidevops_hook_status` to inspect known pre-commit and pre-push marker
status for the current worktree. The tool is repository-bound for headless
workers and returns statuses only, never hook content or filesystem paths.
Until a running OpenCode session has loaded that tool, use the existing bounded
fallback from the target worktree:

```bash
bash ~/.aidevops/agents/scripts/install-hooks-helper.sh status
```

## Exit Codes

| Code | Meaning | Action |
|------|---------|--------|
| `0` | Safe to edit | Proceed |
| `1` | On `main`/`master` | STOP — present prompt below, WAIT for reply |
| `2` | Worktree required or ownership conflict | Create a fresh linked worktree |
| `3` | Reserved legacy code | Treat as blocked and re-run the current helper |

**Exit 1 prompt** (non-allowlisted path on `main`, interactive mode only):
> On `main`. Suggested branch: `{type}/{suggested-name}`
> 1. Create worktree (recommended)
> 2. Use different branch name

Note: only qualifying headless flows can short-circuit to exit `0` for allowlisted paths (`README.md`, `TODO.md`, `todo/**`). Interactive sessions still receive this prompt and move every edit to a linked worktree.

## Loop Mode

Pass `--file <path>` for path-based enforcement (preferred):

- **Qualifying headless flow + allowlisted path** (`README.md`, `TODO.md`, `todo/**`) → stay on `main`; planning publication may still become a PR if branch protection requires it
- **Any other path** → create worktree

Fallback `--task` description keywords (when `--file` not provided):

- **Docs-only** (`readme`, `changelog`, `documentation`, `docs/`, `typo`, `spelling`) → stay on `main`
- **Code** (`feature`, `fix`, `bug`, `implement`, `refactor`, `add`, `update`, `enhance`, `port`, `ssl`, `helper`) → create worktree; code keywords override docs keywords

## Worktree Default

Keep `~/Git/{repo}/` on `main`. Create linked worktrees under `${AIDEVOPS_WORKTREE_BASE_DIR:-~/Git/_worktrees}`. This avoids blocked branch switches, parallel sessions inheriting the wrong branch, and `local changes would be overwritten` errors.

Stay on `main` only in a qualifying headless flow and only for allowlisted paths: `README.md`, `TODO.md`, `todo/**`. Planning-file commits use `planning-commit-helper.sh "plan: add new task"`; the helper opens a planning-only PR instead of direct-pushing when the default branch is protected. Interactive sessions always create a linked worktree first.

Continue on current branch only when: task matches branch purpose, finishes this session, no parallel sessions expected.

**Create worktree:**

```bash
wt switch -c {type}/{name}
~/.aidevops/agents/scripts/worktree-helper.sh add {type}/{name}
```

The helper refreshes `origin/<default>` before creating a new branch. Fetch failure blocks creation; it never silently falls back to stale local state or arbitrary `HEAD`. An explicit immutable base SHA remains available for audited recovery.

After creating, set the session title with the work item first: `Issue #123: succinct description` or `PR #456: succinct description`. If there is no issue/PR context, call `session-rename_sync_branch`. Branch types: `feature/`, `bugfix/`, `hotfix/`, `refactor/`, `chore/`, `experiment/`, `release/`

## Source vs Deployed Copy

- Source: `~/Git/aidevops/.agents/` — git-tracked, branch matters
- Deployed: `~/.aidevops/agents/` — copied output, not a git repo

Run `pre-edit-check.sh` in the source repo before changing either location.
