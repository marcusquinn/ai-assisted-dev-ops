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
aidevops release [patch|minor|major] <merged-pr-number> [incremental|full]
# Before the new CLI is deployed, use the same helper from a current linked worktree:
# ./.agents/scripts/full-loop-release-helper.sh [patch|minor|major] <merged-pr-number> [incremental|full]
```

The helper creates the fresh detached `origin/main` worktree, invokes `version-manager.sh release --source-pr`, and persists terminal receipts only after every publication and deployment gate succeeds. A tag push durably queues the unified GitHub/npm/Homebrew workflow; the local process observes the exact run but does not wait for terminal completion. Exit `8` means remotely queued work and creates no false terminal receipt. Repeating a completed command, or running `aidevops release reconcile <source-pr>`, reconciles success without another version bump or duplicate publication. A failed or skipped release cannot create or replace success evidence.

The underlying version manager verifies the source PR is merged and its merge SHA is reachable, then atomically checks the tree → bumps and validates version files → commits → signs and pushes the tag. The tag workflow verifies immutable provenance before reconciling GitHub, npm OIDC, and Homebrew. A later trusted reconciliation verifies all three channels, runs local deploy sync from a detached tag worktree, and persists receipts. Direct `version-manager.sh release` execution is not a full-loop release because it cannot persist terminal per-PR lifecycle evidence.

```bash
aidevops release status <merged-pr-number>     # read-only remote/channel state
aidevops release reconcile <merged-pr-number> # recover/finalize newest signed tag
```

Recovery runs the reviewed workflow from `main` because older tags do not contain
the recovery trigger. The workflow itself requires that default-branch ref,
rejects every tag except the newest exact semantic version, and repeats the full
signed-tag verifier before side effects. The `release` environment therefore
allows exactly tag `v*` and branch `main`, with no reviewer or wait timer. See
`reference/release-publication-controls.md` for the live-policy and rollback
contract.

If `main` advanced after authorization, create and review a dedicated aggregation
PR whose squash-merge commit contains `Aidevops-Release-Aggregator-PR` and one
`Aidevops-Release-Aggregates: PR@MERGE_SHA` trailer per included source. Then
rerun the original command. The helper accepts only an exact aggregate `main`
tip, preserves the manifest in the signed tag, marks the aggregate PR published,
and marks included source receipts superseded with immutable release links.
Arbitrary descendants and unreviewed direct commits remain blocked. Full contract:
`reference/release-publication-controls.md` "Intervening-main recovery".

**DO NOT** run separate bump/tag/push commands. **Prerequisites**: terminal-success PR checks/reviews, observed merged state/SHA, authenticated `gh`, an accessible aidevops repository, and unreleased changelog content (or changelog-only `--force`). The helper fetches `origin/main` and creates its own detached release worktree; it does not require or mutate a clean canonical checkout.

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

**Deploy** (aidevops only): immediate workflow success runs post-release deploy sync in the initiating session. Otherwise `aidevops release reconcile` runs it from a detached tag worktree after all public channels converge. Run postflight afterward; do not manually mutate the canonical checkout.

**Task completion** (automatic): Release script scans commits for task IDs and auto-marks them complete in TODO.md.

```bash
.agents/scripts/version-manager.sh list-task-ids    # Preview
.agents/scripts/version-manager.sh auto-mark-tasks  # Run manually
```

**Postflight**: successful package publication canonically dispatches one
exact-tag `postflight.yml` run after GitHub, npm, and Homebrew verification.
`./.agents/scripts/postflight-check.sh` verifies terminal CI, external quality
gates, publication, and deployment health. It does not rerun source lint/security
scans already owned by development, CI, and release preflight. See
`workflows/postflight.md`.

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
| Signed tag already exists | Do not delete or retag it. Run `aidevops release status <source-pr>` and then `aidevops release reconcile <source-pr>`. |
| Publication queued/interrupted | Exit `8` is durable pending state. Reconcile the same source PR; never bump again for the same tag. |
| GitHub CLI not authenticated | `gh auth login` (token needs `repo` scope) |
| Version mismatch | `./.agents/scripts/version-manager.sh validate` — see `version-bump.md` |
