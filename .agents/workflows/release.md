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
# Multi-PR authorization (PR numbers are resolved to verified merge SHAs):
aidevops release patch <one-authorized-pr> --expected-sources <pr>,<pr>,<pr>
# Before the new CLI is deployed, use the same helper from a current linked worktree:
# ./.agents/scripts/full-loop-release-helper.sh [patch|minor|major] <merged-pr-number> [incremental|full] [--expected-sources <pr>,<pr>]
```

The helper creates the fresh detached `origin/main` worktree, invokes `version-manager.sh release --source-pr`, and persists terminal receipts only after every publication and deployment gate succeeds. A tag push durably queues the unified GitHub/npm/Homebrew workflow; the local process observes the exact run but does not wait for terminal completion. Exit `8` means remotely queued work and creates no false terminal receipt. Repeating a completed command, or running `aidevops release reconcile <source-pr>`, reconciles success without another version bump or duplicate publication. A failed or skipped release cannot create or replace success evidence.

Before version mutation, the helper reserves the repository's remote release lane. The lane records the active source PR, reviewed source set, phase, tag when known, and terminal receipt without command arguments or secrets. A different source receives the active lane plus exact status/reconcile commands and cannot bump a competing version. The same source resumes through `status` or `reconcile`; process exit does not release queued publication. A same-source lane that remained in the side-effect-free `reserved` phase beyond the bounded stale interval can be recovered through compare-and-swap and a rotated fencing token. Once preparation begins, recovery is reconcile-only because the original process may still publish. Verified terminal receipt evidence advances the lane to inactive so the next source can reserve it atomically. API/authentication uncertainty fails closed; only a verified missing lane ref uses legacy compatibility.

The underlying version manager verifies the source PR is merged and its merge SHA is reachable, then atomically checks the tree → bumps and validates version files → commits → signs and pushes the tag. The tag workflow verifies immutable provenance before reconciling GitHub, npm OIDC, and Homebrew. A later trusted reconciliation verifies all three channels, runs local deploy sync from a detached tag worktree, and persists receipts. Direct `version-manager.sh release` execution is not a full-loop release because it cannot persist terminal per-PR lifecycle evidence.

When the release range contains a conventional `perf:` commit (optionally
scoped or prefixed with `GH#NNN:`), the signed tag includes
`Aidevops-Efficiency-Change: true` and generated release notes include an
efficiency-analysis section. Compare routing, token, cost, and verification
outcomes by the persisted `aidevops_version` before changing routing defaults.

Release authorization is an explicit trust-boundary input, not an inference from
Git ancestry. `--expected-sources` accepts a comma-separated set of PR numbers;
the runner resolves each to its merged `main` SHA, sorts the resulting `PR@SHA`
manifest, and persists it before version mutation. The provenance resolver and
version manager independently require exact equality with the direct or reviewed
aggregation manifest. Missing, extra, duplicate, malformed, and SHA-mismatched
sources fail before a bump, tag, package, or terminal receipt. Omitting the option
retains singleton compatibility by treating the requested source PR as the
expected set. A retry reuses the persisted manifest. When the same source owns a
stale, side-effect-free `reserved` lane with no tag or terminal receipt, an exact
reviewed aggregate at the current `origin/main` tip may transactionally expand a
persisted subset authorization. The helper validates every candidate and terminal
receipt first, rotates the fencing token, updates the authorization and lane with
compare-and-swap semantics, restores prior snapshots after a partial failure, and
then continues the ordinary release command. Other conflicting intent remains
immutable.

```bash
aidevops release status <merged-pr-number>     # read-only remote/channel state
aidevops release reconcile <merged-pr-number> # recover/finalize newest signed tag
# Historical incident evidence only; TAG must already exist and verify:
aidevops release authorization-gap <source-pr> --tag <vX.Y.Z> \
  --expected-sources <pr@merge-sha>,<pr@merge-sha> --reason '<incident reason>'
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
rerun the original source-PR command. If recovery instead names the aggregation
PR itself, the resolver must still classify that exact tip as an aggregate and
copy every reviewed source into the signed tag; it cannot fall through to direct
mode. The helper accepts only an exact aggregate `main` tip, marks the aggregate
PR published, and marks included source receipts superseded with immutable
release links. Arbitrary descendants and unreviewed direct commits remain
blocked.

If an unpublished signed tag and active remote-publication lane already exist,
use the explicit transactional recovery command instead of the ordinary retry:

```bash
aidevops release recover-aggregate <original-source-pr> --tag <vX.Y.Z> \
  --expected-sources <pr[,pr...]>
```

The command requires the reviewed aggregate at the exact `origin/main` tip,
confirms the tag is absent from the remote, GitHub Releases, npm, and Homebrew,
and verifies the existing authorization is an exact subset of the aggregate.
It then rotates the lane token, expands authorization, creates a same-version
empty bump commit over the aggregate, and replaces only the local unpublished
tag. A failure before durable publication restores the exact previous tag
object, authorization manifest, and lane state. Remote tags are never rewritten.
See `reference/release-aggregation-recovery.md` for the state and rollback
contract.

Protected-main reconciliation rechecks the exact tree immediately before pushing the preserved tag. A descendant with a different tree is `aggregation-required` and stops before tag or package mutation, even when it contains the signed release commit. During exact-tag deployment, generic `setup.sh --non-interactive` is blocked by the release lane; only setup carrying the matching source PR and tag may enter the existing setup mutex. The acquisition order is release lane, then setup lock.

For an already-published immutable tag with an authorization gap, do not retag,
republish, infer missing authority from ancestry, or mark omitted PRs
`release:not-requested`/`release:superseded`. Record detached
`authorization-gap` evidence with the expected and observed manifests, tag object,
release commit, timestamp, and reason. This evidence explicitly carries
`terminal_cleanup_evidence:false`; it documents the incident but cannot complete
cleanup or authorize another publication. The command verifies the immutable tag,
resolves every supplied PR/merge pair against that tag commit, rejects a matching
manifest because no gap exists, and treats identical evidence as an idempotent
replay while rejecting conflicting incident evidence.

An already-signed tag whose aggregate list was completely omitted may recover
the redundant list only from its signed `Aidevops-Source-Merge` commit after the
same reviewed manifest and every included PR verify. Any explicit partial or
conflicting tag list remains a hard failure. Recovery runs the verifier from the
exact reviewed `main` workflow commit while package contents stay pinned to the
immutable tag. Full contract: `reference/release-publication-controls.md`
"Intervening-main recovery".

If an older signed tag already completed GitHub, npm, and Homebrew publication
but failed only while queuing postflight, do not recover it after a later release
becomes current. `aidevops release reconcile <older-source-pr>` can instead write
a distinct post-publication supersession receipt after verifying the older run's
exact successful publication steps, strict release ancestry, the latest signed
tag and channels, and the latest source's terminal published receipt. It never
dispatches or deploys the stale tag and does not fabricate aggregate provenance.
See `reference/release-publication-controls.md` "Post-publication supersession".

If a provenance-valid aggregate was already published before reconciliation
discovers an included PR's terminal `release:not-requested` receipt, preserve
that receipt unchanged. Reconciliation may finish only after re-verifying the
signed tag, exact aggregate membership, publication channels, and release
ancestry; it records detached `receipt-conflict` evidence for that member rather
than fabricating `release:superseded`. Preparation of any new release continues
to reject terminal receipts before publication.

**DO NOT** run separate bump/tag/push commands. **Prerequisites**: terminal-success PR checks/reviews, observed merged state/SHA, authenticated `gh`, an accessible aidevops repository, and unreleased changelog content (or changelog-only `--force`). The helper fetches `origin/main` and creates its own detached release worktree; it does not require or mutate a clean canonical checkout.

**Related**: `workflows/version-bump.md` · `workflows/changelog.md` · `workflows/postflight.md` · `reference/release-artifact-provenance.md` · `.agents/scripts/validate-version-consistency.sh`

## Manual Release (Non-aidevops Repos)

Reuse terminal-success CI and lint evidence for the exact release SHA. Do not
repeat a full source scan merely because release follows every merge. Run the
repository's broad gate only when no trustworthy SHA-matched evidence exists or
the release changes shared/root contracts that were not covered by affected
checks.

When a repository publishes installable artifacts, images, update manifests, or
catalogs from GitHub Actions, default to unattended OIDC/Sigstore provenance:
attest the exact file or immutable digest, verify the emitted bundle against the
repository, exact signer workflow, and validated release ref, then publish.
Preserve native ecosystem signing and state clearly whether consumers enforce
the attestation. Full design and examples:
`reference/release-artifact-provenance.md`.

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
| Another source owns the release lane | Run the printed `aidevops release status <active-pr>` command. Reconcile that source when its remote work is ready; aggregate later sources only through a reviewed exact-tip PR. |
| Expected/observed source mismatch | Stop before mutation. Correct the reviewed aggregation manifest or explicit trusted set; never infer authorization from ancestry. |
| Historical immutable tag omitted authorized PRs | Preserve pending receipts and write detached `authorization-gap` evidence. Do not retag or create terminal cleanup evidence. |
| Published tag is older than the latest release | Never republish or deploy the older tag. Reconcile it only through verified post-publication supersession; uncertain evidence remains `release:failed`. |
| GitHub CLI not authenticated | `gh auth login` (token needs `repo` scope) |
| Version mismatch | `./.agents/scripts/version-manager.sh validate` — see `version-bump.md` |
