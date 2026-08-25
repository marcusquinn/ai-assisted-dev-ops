<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Dirty Canonical Worktree Preservation

Use when a canonical checkout contains unexpected tracked, staged, untracked,
or local-commit state. Canonical checkouts are read-only service mirrors on any
branch name; implementation sessions belong in linked worktrees.

## Safety rule

Do not stash, reset, clean, or include unexpected files in another PR. Process
cwd does not make a canonical checkout session-owned. Preserve and verify every
byte before removing only the matching state.

## Preserve without mutation

```bash
.agents/scripts/dirty-worktree-backup-helper.sh backup \
  --repo /path/to/repo \
  --reason "unexpected canonical mirror state" \
  --issue <issue-if-known> \
  --task <task-id-if-known>
```

The backup command does not mutate the checkout. It records the original HEAD,
index tree, full worktree tree, status fingerprint, binary patches, copied
untracked files, and stable `refs/aidevops/dirty-worktree-backups/<id>` commits.
When an untracked `.gitignore` controls ignored descendants, those descendants
join the copied, mode- and type-sensitive payload inventory. Capture fails
closed before mutation if that inventory exceeds 10,000 paths or 1 GiB by
default; the `AIDEVOPS_DIRTY_BACKUP_MAX_UNTRACKED_FILES` and
`AIDEVOPS_DIRTY_BACKUP_MAX_UNTRACKED_BYTES` environment variables can lower or
raise those explicit bounds. It prints the backup ID and exact restore command.
Use `verify` and `matches` before any explicit `clean` operation.

## Audited mirror synchronization

An explicit request to synchronize the canonical mirror authorizes this route:

```bash
.agents/scripts/canonical-recovery-helper.sh sync-mirror \
  --repo /path/to/canonical-checkout \
  --issue 123 \
  --confirm SYNCHRONIZE_CANONICAL_MIRROR
```

The helper structurally refuses linked worktrees. It resolves the allowed branch
from registered repository config, committed `HEAD:.aidevops.json`, or
`origin/HEAD`; an untracked/modified project config and arbitrary `--branch`
cannot select the target. Under the canonical recovery lock it:

1. fetches and pins the exact allowed `origin/<branch>` tip;
2. creates and verifies a lossless backup before cleaning matching noise;
3. removes only structurally canonical ownership rows without signalling PIDs;
4. preserves divergent/local-only commits at an audited recovery ref;
5. compare-and-swaps the local ref and updates the worktree to the pinned tip;
6. verifies branch, HEAD, remote ref, worktree cleanliness, and the audit chain.

Clean records an in-progress transition before its first worktree mutation. Any
reset, removal, hook, final-status, or evidence-finalization failure immediately
restores and verifies the complete pre-clean snapshot. The manifest audits the
clean start, rollback, and completion. If interruption also prevents automatic
rollback, run the printed `recover-clean` command with its confirmation token;
it resumes rollback from the verified backup before another clean attempt.

If synchronization stops after a completed cleanup, the old ref remains
unchanged and the printed backup ID/restore command remains valid. Retry the
same command: stable operation IDs reuse matching evidence rather than
overwriting it. A failed compare-and-swap rolls the local ref back. Safe retry
means either verified automatic rollback or an explicit successful
`recover-clean`; never continue from partially cleaned state or bypass the
helper with direct `git pull`, reset, or clean.

## Audited deployment to a non-Git target

Repository editing and runtime deployment are separate boundaries. Keep edits in
a linked worktree, then use `deployment-copy-helper.sh` when reviewed content must
converge into a stable directory that is intentionally outside every Git
worktree. Never point the pre-edit tool at the runtime directory or weaken its
worktree requirement.

The destination must appear exactly in an owner-controlled, non-symlink allow
file with mode `0600` or stricter. For committed source subtrees, the helper
materializes the expected Git tree and refuses untracked, ignored, content or
executable-mode changes, Git metadata, symlinks, special entries, and special
permission bits. Generated artifacts require a separately reviewed tree digest:

```bash
deployment-copy-helper.sh manifest \
  --source /path/to/linked-worktree/build \
  --expected-sha <full-commit-sha> --machine

deployment-copy-helper.sh deploy \
  --source /path/to/linked-worktree/build \
  --destination /path/to/stable-runtime \
  --expected-sha <full-commit-sha> \
  --allow-file ~/.config/aidevops/deployment-copy-targets \
  --reviewed-tree-sha256 <manifest-digest> --dry-run
```

Remove `--dry-run` only after reviewing the add/change/delete set. The helper
stages on the destination filesystem, serializes by canonical destination,
records a private operation receipt, preserves the previous tree, activates by
rename, and verifies the complete path/type/mode/content manifest. Output names
the operation ID rather than private rollback paths. Recover interrupted work or
restore the prior destination with the same allow file:

```bash
deployment-copy-helper.sh recover \
  --operation-id <operation-id> --confirm RECOVER_DEPLOYMENT_COPY \
  --allow-file ~/.config/aidevops/deployment-copy-targets

deployment-copy-helper.sh rollback \
  --operation-id <operation-id> --confirm ROLLBACK_DEPLOYMENT_COPY \
  --allow-file ~/.config/aidevops/deployment-copy-targets
```

This does not make replacement of a non-empty directory continuously atomic:
there is a bounded rename interval between preserving the old directory and
activating the staged directory. The durable receipt and recovery command own
that interruption case.

## Converged stale rebase recovery

When a clean canonical checkout has completed an interactive rebase but stale
metadata still blocks `restore-default`, use the separately confirmed cleanup:

```bash
.agents/scripts/canonical-recovery-helper.sh clear-stale-rebase \
  --repo /path/to/canonical-checkout \
  --issue 123 \
  --confirm CLEAR_CONVERGED_STALE_REBASE
```

Under the canonical recovery lock, the helper fetches and pins the configured
default branch, verifies the audit chain, and requires `HEAD`, the local default
ref, and the pinned remote tip to be identical. It accepts only a completed,
clean, structurally valid `rebase-merge` state for that default branch. Active,
dirty, divergent, branch-mismatched, malformed, or changing state fails closed.

Before cleanup, the helper copies and fingerprints all rebase metadata under
`~/.aidevops/.agent-workspace/recovery/canonical/` and creates durable
`refs/aidevops/canonical-recovery/issue-<N>/stale-rebase/<sha>` refs for commit
IDs found in that metadata. It then proves cleanup did not change HEAD, local or
remote refs, the index tree, or worktree content. Run `restore-default` with its
own confirmation token after this command succeeds. Never use direct
`git rebase --quit`, reset, clean, or metadata deletion on a canonical checkout.

## Abandoned active rebase recovery

Use the distinct abandoned-state operation only when a clean canonical mirror
is detached at the pinned remote default tip but old interactive-rebase markers
still describe an incomplete stopped sequence:

```bash
.agents/scripts/canonical-recovery-helper.sh clear-abandoned-rebase \
  --repo /path/to/canonical-checkout \
  --issue 123 \
  --confirm CLEAR_ABANDONED_STALE_REBASE
```

This command does not relax `clear-stale-rebase`. It requires complete stopped
`rebase-merge` metadata for the configured default branch, a matching
`REBASE_HEAD` and `stopped-sha`, metadata whose newest marker is at least 24
hours old, HEAD at the exact pinned remote tip and beyond the stopped commit,
and a local default ref that remains an ancestor of that tip. Fresh, attached,
dirty, divergent, malformed, ambiguous, or changing state fails closed.

Before removal, the helper copies and fingerprints the complete metadata plus
`REBASE_HEAD`. It resolves full or abbreviated commit IDs from todo, done,
backup, stopped, and rewritten metadata and creates durable issue-scoped refs
for every reference. After a final HEAD/ref/index/worktree check, it
compare-deletes only the expected `REBASE_HEAD`, quarantines the metadata,
re-fingerprints the quarantined snapshot, and restores it if concurrent state
appears. After success, run the separately confirmed `restore-default`
operation to attach and fast-forward the configured default branch. Never
substitute `git rebase --quit` or manual `.git` deletion.

Restore preserved state only to a clean checkout on the recorded branch:

```bash
.agents/scripts/dirty-worktree-backup-helper.sh restore \
  --repo /path/to/repo \
  --backup <backup-id> \
  --confirm RESTORE_DIRTY_WORKTREE_BACKUP
```

## Backup retention

Backups live under:

```text
~/.aidevops/.agent-workspace/tmp/dirty-main-backups/
```

Open backups are never pruned automatically, including when a linked PR closes.
Only explicitly acknowledged or restored evidence becomes eligible for terminal
PR/age pruning. Use `.keep` inside a backup directory for indefinite retention.

Manual prune:

```bash
.agents/scripts/dirty-worktree-backup-helper.sh prune --dry-run
.agents/scripts/dirty-worktree-backup-helper.sh acknowledge \
  --backup <backup-id> --confirm ACKNOWLEDGE_DIRTY_WORKTREE_BACKUP
.agents/scripts/dirty-worktree-backup-helper.sh prune --force
```
