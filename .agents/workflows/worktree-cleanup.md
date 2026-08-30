<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Worktree Cleanup After Merge

After a PR merges, clean up the linked worktree and return the canonical repo to a clean state.

**Key constraint:** Merge through `full-loop-helper.sh merge`; it records cleanup ownership and avoids deleting the branch while its worktree is active.

## Automated Cleanup (workers — GH#6740)

Workers dispatched via `/full-loop` defer current-worktree cleanup after successful immediate merges through `full-loop-helper.sh merge` (Step 4.9). The parent runtime may still use the worktree as a logical project `--dir` even when no OS process cwd points there. The pulse `cleanup_worktrees()` stage removes the deferred worktree after the owner exits. `--auto` only queues the merge, so scheduled cleanup also handles that later after the PR actually merges.

```bash
# Fallback/manual sequence after a lifecycle-helper merge succeeds:
WORKTREE_PATH="$(pwd)"
BRANCH_NAME="$(git rev-parse --abbrev-ref HEAD)"
CANONICAL_DIR="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"

cd "$CANONICAL_DIR" || cd "$HOME"
git fetch origin main 2>/dev/null || true

HELPER="$HOME/.aidevops/agents/scripts/worktree-helper.sh"
if [[ -x "$HELPER" ]]; then
  WORKTREE_FORCE_REMOVE=true "$HELPER" remove "$BRANCH_NAME" --force 2>/dev/null || true
else
  git worktree remove --force "$WORKTREE_PATH" 2>/dev/null || true
  git worktree prune 2>/dev/null || true
fi

git push origin --delete "$BRANCH_NAME" 2>/dev/null || true
git branch -D "$BRANCH_NAME" 2>/dev/null || true
```

Cleanup failures are non-fatal — the PR is already merged.

## Compact Recovery Archives

Use [`../scripts/worktree-archive-helper.md`](../scripts/worktree-archive-helper.md) for the standalone archive, restore, list, verify, and retention commands. The helper preserves local commits, tracked/staged changes, bounded untracked files, and exact base metadata under `~/.aidevops/recovery/archives/`.

Pulse cleanup invokes the helper for attributable stale/failed workers,
terminal issue or PR worktrees, and generated auto/review worktrees after their
retention window. It verifies each archive before removing the full worktree;
local commits, dirty patches, bounded untracked state, and available failure
context remain restorable. Audit rows use `mode=compact-archive`, and async
cleanup reports removed, archived, and failed-archive totals.

Full worktrees remain required for live owners/sessions/processes, recent worker
metrics, security or forensics markers/labels, repeated zero-session failures,
unclear repository/task attribution, remote policy lookup failures, and archive
creation or verification failures.

## Manual Cleanup (interactive sessions)

```bash
# Merge through the lifecycle helper (required from inside a worktree)
full-loop-helper.sh merge PR_NUMBER OWNER/REPO --squash

# Return to canonical repo and pull
CANONICAL_DIR="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
cd "$CANONICAL_DIR"
git fetch origin main

# Remove merged worktrees
wt prune
```

`wt prune` removes worktrees whose branches have been merged and deleted on the remote. Run from the canonical repo (on `main`). If unavailable: `git worktree prune` then delete the worktree directory manually.

## Bulk Remote Branch Cleanup

Use the aidevops CLI route when the remote has accumulated old worker/worktree branches:

```bash
aidevops cleanup remote-branches              # dry-run audit
aidevops cleanup remote-branches --apply      # delete safe candidates
aidevops cleanup branches --repo ~/Git/aidevops --remote origin
```

The command deletes only branches with safety evidence: merged to the default branch or linked to a merged PR, with no open PR and no active local worktree. Unmerged branches are reported as `review` and are not deleted by default.

## See Also

- `workflows/git-workflow.md` — full worktree lifecycle
- `reference/session.md` — session and worktree conventions
- `full-loop.md` Step 4.9 — worker self-cleanup specification
