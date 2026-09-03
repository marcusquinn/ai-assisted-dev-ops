<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Repository Organization

Keep canonical clones under `~/Git/`: direct children for personal-account
repositories and owner directories for organization or third-party repositories.
Keep linked worktrees and archives in their reserved directories, never mixed
with canonical clones.

## Default clone locations

| Repository identity | Default path |
|---------------------|--------------|
| Personal account | `~/Git/<repo>/` |
| Organization or third party | `~/Git/<owner>/<repo>/` |
| Linked worktree | `~/Git/_worktrees/<owner>-<repo>-<branch-slug>/` for nested canonicals |
| Archive | `~/Git/_archive/` |

Examples:

```bash
gh repo clone personal-account/project ~/Git/project
gh repo clone organization/project ~/Git/organization/project
```

## Worktrees

Create worktrees under `${AIDEVOPS_WORKTREE_BASE_DIR:-~/Git/_worktrees}`. Nested
canonical repositories use owner-qualified `<owner>-<repo>-<branch-slug>` names
to avoid collisions; direct personal repositories retain the compatible
`<repo>-<branch-slug>` name. Existing worktrees remain valid until safe cleanup.

Examples:

| Canonical clone | Auto worktree parent |
|-----------------|----------------------|
| `~/Git/project` | `~/Git/_worktrees/project-<branch>` |
| `~/Git/organization/project` | `~/Git/_worktrees/organization-project-<branch>` |

`repos.json` explicit paths are authoritative for existing, local-only, non-GitHub,
and exceptional repositories. Setup and update never move canonical clones;
migration is a separate lossless operation. Configure host-specific personal
account aliases locally rather than assuming a fixed account name.

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
- `tools/wordpress/wp-dev.md` — WordPress-specific layout
