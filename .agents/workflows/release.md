---
description: Full release workflow with version bump, tag, and GitHub release
mode: subagent
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Release Workflow

**MANDATORY**: Use this single authorized full-loop entry point for ALL aidevops releases:

```bash
./.agents/scripts/full-loop-release-helper.sh [patch|minor|major] <merged-pr-number> [incremental|full]
```

The helper creates the fresh detached `origin/main` worktree, invokes `version-manager.sh release --source-pr`, and persists terminal receipts only after every publication and deployment gate succeeds. Repeating it with existing `published` or `superseded` evidence reconciles success without another version bump or publication. A failed or skipped release cannot create or replace success evidence.

The underlying version manager verifies the source PR is merged and its merge SHA is reachable, then atomically checks the tree → bumps and validates version files → commits → tags → pushes → creates the GitHub release → runs deploy sync. Publication or deployment failure is a failed release, not warning-only success. Direct `version-manager.sh release` execution is not a full-loop release because it cannot persist terminal per-PR lifecycle evidence.

If `main` advanced after authorization, create and review a dedicated aggregation
PR whose squash-merge commit contains `Aidevops-Release-Aggregator-PR` and one
`Aidevops-Release-Aggregates: PR@MERGE_SHA` trailer per included source. Then
rerun the original command. The helper accepts only an exact aggregate `main`
tip, preserves the manifest in the signed tag, marks the aggregate PR published,
and marks included source receipts superseded with immutable release links.
Arbitrary descendants and unreviewed direct commits remain blocked. Full contract:
`reference/release-publication-controls.md` "Intervening-main recovery".

**DO NOT** run separate bump/tag/push commands. **Prerequisites**: terminal-success PR checks/reviews, observed merged state/SHA, clean synchronized canonical `main`, fresh detached release worktree, authenticated `gh`, and unreleased changelog content (or changelog-only `--force`).

**Related**: `workflows/version-bump.md` · `workflows/changelog.md` · `workflows/postflight.md` · `.agents/scripts/validate-version-consistency.sh`

## Manual Release (Non-aidevops Repos)

Reuse terminal-success CI and lint evidence for the exact release SHA. Do not
repeat a full source scan merely because release follows every merge. Run the
repository's broad gate only when no trustworthy SHA-matched evidence exists or
the release changes shared/root contracts that were not covered by affected
checks.

```bash
# Conditional only: ./.agents/scripts/linters-local.sh --full
git add -A && git commit -m "chore(release): prepare v{MAJOR}.{MINOR}.{PATCH}"
./.agents/scripts/version-manager.sh tag
git push origin main && git push origin --tags
./.agents/scripts/version-manager.sh github-release
# or: gh release create v{VERSION} --title "v{VERSION}" --notes-file RELEASE_NOTES.md
# or: glab release create v{VERSION} --name "v{VERSION}" --notes-file RELEASE_NOTES.md
```

## Post-Release

**Deploy** (aidevops only): the release command runs post-release deploy sync and fails if it cannot verify that step. Run postflight afterward; do not manually mutate the canonical checkout.

**Task completion** (automatic): Release script scans commits for task IDs and auto-marks them complete in TODO.md.

```bash
.agents/scripts/version-manager.sh list-task-ids    # Preview
.agents/scripts/version-manager.sh auto-mark-tasks  # Run manually
```

**Postflight**: `./.agents/scripts/postflight-check.sh` verifies terminal CI,
external quality gates, publication, and deployment health. It does not rerun
source lint/security scans already owned by development, CI, and release
preflight. See `workflows/postflight.md`.

**Follow-up**: Verify artifacts/download links, update docs site, notify stakeholders, close milestone.

## Rollback

```bash
git log --oneline -10
git diff v{PREVIOUS} v{CURRENT}
${AIDEVOPS_DIR:-$HOME/.aidevops}/agents/scripts/worktree-helper.sh add hotfix/v{NEW_PATCH} --base v{CURRENT}
# Critical: cd into the linked worktree path printed by the helper before editing;
# otherwise commits land in the canonical checkout and can disrupt active agents.
# Fix, then:
git commit -m "fix: resolve critical issue"
# or: git revert --no-commit <commit-hash> && git commit -m "revert: rollback v{CURRENT}"
```

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Tag already exists | `git tag -d v{VERSION} && git push origin --delete v{VERSION}` then re-tag |
| GitHub CLI not authenticated | `gh auth login` (token needs `repo` scope) |
| Version mismatch | `./.agents/scripts/version-manager.sh validate` — see `version-bump.md` |
