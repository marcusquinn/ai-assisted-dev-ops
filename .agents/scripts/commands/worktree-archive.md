<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Compact Worktree Archives

`worktree-archive-helper.sh` preserves worker recovery evidence without retaining a full worktree. Archives are durable recovery state; linked worktrees remain disposable runtime cache.

## Commands

```bash
worktree-archive-helper.sh archive <worktree-path> --repo owner/repo --issue N \
  --reason failed-worker|post-pr-cleanup --base-branch branch [--base-sha SHA] [--output-root DIR]
worktree-archive-helper.sh restore <archive-dir> --target <new-worktree-path>
worktree-archive-helper.sh list [--repo owner/repo] [--issue N]
worktree-archive-helper.sh verify <archive-dir>
worktree-archive-helper.sh prune --older-than 14d --max-total-size 20G [--dry-run|--apply]
```

`archive` accepts only registered, non-symlink worktree roots and never changes its source. It writes atomically below `~/.aidevops/recovery/archives/<owner>/<repo>/<issue>/<timestamp>/` (override with `--output-root` or `AIDEVOPS_WORKTREE_ARCHIVE_ROOT`). The base branch must be selected in this order by the caller: PR `baseRefName`, dispatch target metadata, then the integration/default branch. The helper records the exact `base_sha`; `--base-sha` overrides resolution from `origin/<base-branch>` then the local branch.

## Layout and restore

Each complete archive has `manifest.json`, mandatory binary-safe `diff.patch` and `staged.patch`, optional `commits.bundle`, `untracked-files.txt`, lossless `untracked-files.nul`, bounded `untracked.tar.gz`, and optional failure evidence. The manifest records repository/issue/reason, paths, branch/head/base/default branch, remote and dirty state, artifacts with hashes and sizes, and restore instructions.

`verify` validates the schema, hashes, bundle, and tar traversal safety. `restore` verifies first, fetches a bundle into a protected restore ref when present, creates a fresh detached worktree, applies staged then unstaged patches, and safely restores untracked files. The target must not already exist. Inspect it before creating a new recovery branch, avoiding collision with the original branch.

Untracked capture is fail-closed at 10,000 files and 1 GiB by default (`AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_FILES` and `AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_BYTES`). Unsupported file types, unsafe paths, or oversized payloads produce no completed archive.

## Retention

`prune` is dry-run by default. It considers only verified archives, plans oldest archives past `--older-than`, then oldest verified archives until the total is below `--max-total-size`. `--apply` removes exactly that verified plan. Malformed archives are intentionally preserved for manual/security review.

## Future integration

Pulse and worker cleanup are **not wired to this helper in this change**. Follow-up integration may archive terminal failed worker worktrees without PRs before deletion, delete clean pushed-PR worktrees as cache, and prune compact archives/full recovery worktrees under retention and size caps. Full worktrees remain appropriate for interactive/manual owners, security incidents, `preserve-forensics` markers or labels, repeated unexplained failures, and archive-safety failures.
