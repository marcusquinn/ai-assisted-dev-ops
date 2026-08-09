<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Compact worktree archives

`worktree-archive-helper.sh` preserves recovery evidence without retaining a full worker worktree. Archives default to `~/.aidevops/recovery/archives/` and are recovery artifacts, not backups of remote GitHub state.

## Commands

```bash
# Archive a worker worktree. The command prints the new archive directory.
worktree-archive-helper.sh archive <worktree-path> \
  --repo owner/repo --issue 123 --reason failed-worker \
  --base-branch develop [--base-sha <commit>] \
  [--output-root <directory>] [--failure-log <file>]

# Verify the manifest, artifact hashes, bundle, and untracked payload safety.
worktree-archive-helper.sh verify <archive-directory>

# Restore to a new linked worktree path. The target must not exist.
worktree-archive-helper.sh restore <archive-directory> \
  --target <new-worktree-path>

# List all archives, or filter by repository and/or issue.
worktree-archive-helper.sh list [--repo owner/repo] [--issue 123] \
  [--output-root <directory>]

# Preview or apply retention. Exactly one mode is required.
worktree-archive-helper.sh prune --older-than 14d --max-total-size 20G \
  [--dry-run|--apply] [--output-root <directory>]
```

`--reason` accepts only `failed-worker` or `post-pr-cleanup`. Untracked capture defaults to at most 10,000 paths and 1 GiB; override those bounds with `AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_FILES` and `AIDEVOPS_WORKTREE_ARCHIVE_MAX_UNTRACKED_BYTES`. `AIDEVOPS_WORKTREE_ARCHIVE_ROOT` changes the default root.

## Archive layout

The path is `<root>/<owner>__<repo>/<issue>/<UTC timestamp>/`:

| Artifact | Purpose |
|---|---|
| `manifest.json` | Schema, source and Git metadata, artifact sizes/SHA-256 hashes, and restore command |
| `commits.bundle` | Incremental Git bundle when `HEAD` contains commits beyond the exact base SHA |
| `diff.patch` | Binary-safe unstaged tracked changes; present even when empty |
| `staged.patch` | Binary-safe staged changes; present even when empty |
| `untracked-files.txt` | Human-readable escaped inventory; present even when empty |
| `untracked.tar.gz` | Bounded untracked regular files and symlinks, when any exist |
| `failure.log` | Optional final 256 KiB excerpt supplied with `--failure-log` |

The manifest records the repository, issue, reason, creation time, source worktree, source Git common directory, branch, `HEAD`, base branch and exact base SHA, default branch, remote branch state, dirty state, artifacts, and restore instructions. `verify` rejects missing, changed, or unsafe artifacts.

## Base selection

The caller must select the semantic base in this order:

1. the PR `baseRefName`;
2. dispatch metadata's target branch;
3. the repository integration branch, or its default branch.

Pass that name with `--base-branch`. Pass the already-observed commit with `--base-sha` whenever available. Without `--base-sha`, the helper resolves `origin/<base-branch>` first and then the local branch. It always stores the resolved commit, because the base is not necessarily `main` and a moving branch name is insufficient recovery evidence.

## Restore workflow

1. Run `verify <archive-directory>` before trusting the archive.
2. Ensure the source repository named by `source_git_common_dir` still exists. Incremental commit bundles deliberately depend on that repository's base objects.
3. Run `restore ... --target <new-path>`. The helper imports bundled commits, creates a uniquely named linked branch at the archived `HEAD`, applies the staged patch to the index, applies the unstaged patch, and safely expands the untracked payload.
4. Inspect `git status`, compare the restored `HEAD` and `base_sha`, and publish a branch/PR before deleting either recovery copy.

Restore never overwrites an existing path. If restoration stops after creating a worktree, preserve it for inspection and use normal guarded worktree cleanup after resolving the cause.

## Retention

The recommended policy is `--older-than 14d --max-total-size 20G`. `prune` selects every archive older than the age limit, then oldest remaining archives until retained size is at or below the cap. It ignores malformed directories rather than deleting unverified data. Always inspect `--dry-run` output before using `--apply` in a manual operation.

## Pulse cleanup integration

Pulse uses compact archives before removing dirty terminal worker worktrees and
dirty generated auto/review worktrees that have reached their cleanup age. It
passes the parsed repository and issue identity, archives with the
`failed-worker` reason, and runs `verify` before guarded worktree removal. The
branch remains as an additional recovery path.

Clean terminal and generated worktrees do not need a compact dirty-state
archive; their existing branch-preservation path remains authoritative. When a
dirty worktree lacks the repository or issue metadata required by this archive
schema, Pulse retains the existing Git-stash recovery fallback rather than
inventing metadata.

Any compact archive creation or verification failure records a skipped cleanup
event and preserves the dirty worktree and branch. The failure stops only that
worktree's deletion and must not fall through to a less protective cleanup path
or stop broader safe cleanup. Interactive/manual owners, security incidents, a
`preserve-forensics` marker or label, repeated unexplained failures, and other
protected evidence continue to retain full worktrees.
