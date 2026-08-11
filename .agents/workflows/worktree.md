---
description: Parallel branch development with git worktrees
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Git Worktree Workflow

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Separate working directories per branch — no branch-switching conflicts
- **Core principle**: Main repo (`~/Git/{repo}/` or grouped parent) ALWAYS stays on `main`. Create durable linked worktrees under `${AIDEVOPS_WORKTREE_BASE_DIR:-~/Git/_worktrees}`, not runtime temp dirs. Group WordPress repos under `~/Git/wordpress/`, EspoCRM under `~/Git/espocrm/`, and MCP under `~/Git/mcp/` (details: `reference/repo-organization.md`). **Never `git checkout -b` in the main repo** — the next session inherits wrong state.
- **Same-session default**: For the active objective, keep the current chat and target the linked path with file tools and Bash `workdir`; a new chat is only for explicit parallel work, unrelated context, or a verified ownership/permission block.
- **Preferred tool**: [Worktrunk](https://worktrunk.dev) (`brew install max-sixty/worktrunk/wt`) — full docs: `tools/git/worktrunk.md`
- **Fallback**: `~/.aidevops/agents/scripts/worktree-helper.sh`

<!-- AI-CONTEXT-END -->

## Commands

**Worktrunk** (preferred — shell cd, hooks, CI status, merge workflow):

```bash
wt switch -c feature/my-feature        # Create worktree + cd into it (configure path_template to ~/Git/_worktrees)
wt list                                # List worktrees with CI status
wt merge                               # Squash/rebase/merge + cleanup
wt remove                              # Remove current worktree
wt switch -c hotfix/security-patch     # Hotfix without leaving feature work
opencode ~/Git/_worktrees/myrepo-feature-auth/  # Multiple AI sessions on separate worktrees
```

**worktree-helper.sh** (fallback — no cd support):

```bash
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add feature/my-feature          # Auto-path: ~/Git/_worktrees/<repo>-feature-my-feature; cd into printed path
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add feature/my-feature "$HOME/Git/_worktrees/<repo>-feature-my-feature"  # Explicit central path
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh list                            # List worktrees
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh status                          # Status overview
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh remove feature/auth             # Removes directory, NOT the branch
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh clean                           # Batch cleanup merged branches (interactive, runs git fetch --prune)
```

## Integration

`pre-edit-check.sh` works in any worktree — main or linked. After creating a
linked worktree for the active objective, run it against that path and continue
in the same session; the session root need not change.

**Localdev (t1224.8):** Worktree creation auto-sets branch-specific subdomain routing (`https://feature-auth.myapp.local`). Removal auto-cleans the route.

**Session recovery:** After creating branches, title issue/PR sessions as `Issue #123: succinct description` or `PR #456: succinct description`; otherwise run `session-rename_sync_branch`. Check `worktree-sessions.sh list` before closing PRs or deleting branches.

```bash
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-sessions.sh list   # List worktrees with matching sessions
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-sessions.sh open   # Interactive: select + open
```

**Worker self-cleanup (GH#6740):** `full-loop-helper.sh merge` defers current linked-worktree removal to the pulse cleanup stage after parent runtime exit. A runtime can retain a logical `--dir` reference without an observable process cwd, so synchronous removal is unsafe. See `full-loop.md` Step 4.9 and `commands/worktree-cleanup.md`.

## Ownership Safety (t189)

Worktrees registered to creating session's PID in SQLite (`~/.aidevops/.agent-workspace/worktree-registry.db`) — prevents cross-session removal.

```bash
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh registry list    # View ownership
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh registry prune   # Prune stale entries (dead PIDs, missing dirs)
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh remove feature/branch --force  # Override ownership (use with caution)
```

## Troubleshooting

| Problem | Fix |
|---------|-----|
| "Branch is already checked out" | `git worktree list \| grep feature/auth` — use or remove that worktree |
| "Worktree path already exists" | `worktree-helper.sh remove feature/auth --force` if safe, then re-add under `~/Git/_worktrees` |
| Stale worktree references | `git worktree prune` |
| Detached HEAD | `cd` into worktree, `git checkout feature/auth` |
| Worktree deleted mid-session | `git branch --list feature/my-feature` → `worktree-helper.sh add feature/my-feature` → `git stash pop` |

## Related

| File | When to Read |
|------|--------------|
| `git-workflow.md` | Branch naming, commit conventions |
| `branch.md` | Branch type selection |
| `multi-repo-workspace.md` | Multiple repositories |
| `pr.md` | Pull request creation |
