<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Repository Organization

Keep canonical clones under a Git workspace, organized by repository owner rather
than technology. The default workspace is `~/Git`.

## Default clone locations

| Repository ownership | Default path |
|----------------------|--------------|
| Personal account | `~/Git/<repo>` |
| Organization or third party | `~/Git/<owner>/<repo>` |
| Local-only, legacy, or exceptional | Explicit `repos.json` path |

Examples:

```bash
gh repo clone personal-account/project ~/Git/project
gh repo clone example-org/service ~/Git/example-org/service
```

Normalize new owner directory names to lowercase. Repository names retain their
upstream spelling. Configure personal aliases per Git host in `repos.json`; do
not assume that one GitHub login is the user's identity on every host:

```json
{
  "git_parent_dirs": ["~/Git"],
  "personal_owners": {
    "github.com": ["personal-account"],
    "gitlab.example": ["work-alias"]
  }
}
```

An explicit `initialized_repos[].path` and `owner/repo` slug remain authoritative.
This preserves non-GitHub hosts, offline volumes, local-only repositories,
historic layouts, and deliberate exceptions.

## Discovery boundary

Repository scans inspect direct children and one owner-directory level. They
exclude `_worktrees`, `_archive`, other underscore/dot-prefixed operational
directories, linked worktrees, submodules, and repositories nested inside an
already detected repository. Scans never recurse to arbitrary depth.

## Worktrees

Create worktrees under `${AIDEVOPS_WORKTREE_BASE_DIR:-~/Git/_worktrees}`.
Root-level repositories use flat `<repo>-<branch-slug>` names; owner-nested
repositories use `<owner>-<repo>-<branch-slug>` to avoid collisions.
`worktree-helper.sh add <branch>` derives this path. Existing sibling worktrees
from older versions remain valid until cleanup removes them safely.

Examples:

| Canonical clone | Generated worktree example |
|-----------------|----------------------------|
| `~/Git/project` | `~/Git/_worktrees/project-feature-change` |
| `~/Git/example-org/service` | `~/Git/_worktrees/example-org-service-feature-change` |

## Migration safety

Setup and update do not move canonical repositories. Treat layout migration as a
separate, reviewed operation: inventory dirty state, branches, remotes, stashes,
submodules, linked worktrees, and destination collisions; back up unique data;
move one repository at a time; update explicit registrations; and verify Git
state before deleting or archiving a source path. Owner names differing only by
case can collide on case-insensitive filesystems and require a manual decision.

## Direct-write workspace boundary

Direct file-mutation tools may write across repositories when both identities
resolve beneath `${AIDEVOPS_GIT_WORKSPACE_ROOT:-~/Git}` and the target is a linked
worktree. Canonical checkouts remain read-only regardless of their location.
Resolved worktree, Git directory, and common-directory paths must all remain
inside the workspace, so sibling-prefix paths and symlink escapes are denied.
Sanctioned outside-Git paths remain separate: a symlink traversed from inside a
Git worktree cannot use that allowance to escape the trusted workspace.

## Related

- `workflows/worktree.md` — worktree mechanics
- `workflows/git-workflow.md` — issue/PR flow
- `tools/wordpress/wp-dev.md` — WordPress-specific development
