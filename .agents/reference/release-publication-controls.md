<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Release Publication Controls

This reference is the impact matrix and rollout boundary for repository release
settings. Code hardening and live-setting mutation are separate checkpoints.
Changing repository, environment, npm, or tag-policy settings requires explicit
maintainer operation approval after this matrix has been reviewed.

## Code-enforced provenance

The canonical release path records these trailers in a signed annotated tag:

- `Aidevops-Version`
- `Aidevops-Source-PR`
- `Aidevops-Source-Merge`
- repeated `Aidevops-Aggregated-Source` entries when a reviewed aggregation PR
  replaces one or more earlier authorized sources

`.agents/scripts/release-provenance-helper.sh` verifies the same evidence before
GitHub release creation, npm OIDC publication, and Homebrew update work:

1. tag, `VERSION`, `package.json`, checkout, and bump-commit subject agree;
2. the local and GitHub tag-object SHA agree, and the annotated tag is
   GitHub-verified and points at the checked-out commit;
3. the tag commit is reachable from `origin/main`;
4. the recorded source PR is merged into `main`, its merge SHA matches, and that
   merge is the direct parent of the release commit.

### Intervening-main recovery

An authorized source that is no longer the direct `main` tip cannot publish by
ancestor reachability alone. Recovery requires a new reviewed aggregation PR at
the exact release tip. Its immutable squash-merge message records:

```text
Aidevops-Release-Aggregator-PR: <aggregation-pr>
Aidevops-Release-Aggregates: <authorized-pr>@<merge-sha>
```

Repeat `Aidevops-Release-Aggregates` for every authorized source settled by the
release. The release helper verifies the aggregation PR and every listed PR
against GitHub, requires their exact merge SHAs to be ancestors of the aggregate
tip, and copies the complete manifest into the signed tag. An intervening direct
commit without this reviewed attestation remains blocked.

After all publication and deployment gates succeed, the aggregation PR receives
`release:published`; each included PR receives `release:superseded` plus a JSON
receipt linking its merge SHA to the aggregation PR, release tag, and release
commit. A failed pre-publication attempt records both the requested and current
source SHAs as actionable failure evidence, but creates no tag or publication.
Retries reconcile terminal receipts and cannot publish twice.

The aggregation PR must expose a durable review record before merge. Create it
as a draft from an initial documentation commit, then add the allocated PR
number and every authorized `PR@MERGE_SHA` source in a follow-up commit without
rewriting the published branch. No earlier branch commit may contain a
recognized aggregation trailer. Only the final commit carries one contiguous
trailer block so the repository's squash message and
`git interpret-trailers --parse` expose exactly one aggregator identity and one
entry per source. After merge, verify the parsed squash message and run the
source resolver against the exact `origin/main` tip before publication.

PR #28725 demonstrated the fail-closed duplicate-trailer case: its squash
message retained an earlier separated trailer block plus the final contiguous
block. No release was attempted from that ambiguous manifest; a new reviewed
single-block aggregation supersedes it. PR #28727 then demonstrated the
terminal-receipt guard: publication was rejected because its manifest included
PR #28720, which already recorded `release:not-requested`. Aggregation manifests
must include only sources whose current receipts still permit publication; code
from terminal non-publishing sources may remain in the release tree without
rewriting those receipts. PR #28729 reviews the remaining authorized source,
PR #28701 at its exact merge SHA.

Aggregation PR #28736 reviews authorized PR #28735 at
`023ae92964f6add94517d99a4091e6b1a20c9445` through the same path because the
deterministic t18179 completion commit advanced `main` before its security
release was published.

Manual arbitrary-version package publication is intentionally unsupported. A
recovery operation must use an existing tag that passes the same verifier.

## Actions default-permission impact matrix

Repository default permissions can move from `write` to `read` only after every
workflow declares its needs. The repository audit found eight callers without an
explicit `permissions` block; the merged code-hardening checkpoint made all eight
explicit.

| Workflow | Required permission | Reason |
|---|---|---|
| `update-website-docs.yml` | `contents: read` | Reads this repository; its separate website PAT owns the external write. |
| `plugin-import-check.yml` | `contents: read` | Read-only pull-request validation. |
| `counter-monotonic.yml` | `contents: read` | Reads Git history and `.task-counter`. |
| `markdoc-validate.yml` | `contents: read` | Read-only schema validation. |
| `version-validation.yml` | `contents: read` | Reads versions and existing tags. |
| `task-id-collision-check.yml` | `contents: read`, `pull-requests: read` | Reads commit history and PR metadata. |
| `review-bot-gate.yml` | `contents: read`, `pull-requests: read`, `statuses: write` | Matches the reusable gate contract and publishes its status. |
| `issue-sync.yml` | `actions: read`, `contents: write`, `issues: write`, `pull-requests: write` | Union required by its job-scoped reusable workflow permissions. |

Existing workflows with explicit job or workflow permissions retain their
current least-privilege declarations. No workflow was found that requires the
repository setting allowing GitHub Actions to approve pull-request reviews; the
setting can be disabled after the read-default change is verified.

## Live rollout checkpoint

Apply these operations only through an audited, explicitly approved settings
session. Do not create a release, package, deployment, or test tag as validation.

### Pre-mutation state and rollback matrix

Read-only inventory on 2026-07-27 captured the original exposure immediately
before mutation. The approved rollout completed later that day: API-visible
controls passed the read-only verifier, the unsupported GitHub and npm settings
were captured before and after through their UIs, and PR #28722 merged only after
the protected environment existed. Preserve the private machine-readable
snapshot captured by `release-publication-settings-helper.sh snapshot` as the
rollback source; do not reconstruct rollback values from this summary.

| Control | Pre-mutation state | Approved target | Exact rollback input |
|---|---|---|---|
| Actions defaults | `default_workflow_permissions=write`; workflow PR approval enabled | `read`; PR approval disabled | Restore both values from `actions.workflow_permissions` in the snapshot. |
| Actions policy | Actions enabled; all actions allowed | No change in this checkpoint | Preserve `actions.policy` unchanged. |
| Workflow permissions | All 55 workflows declare `permissions`; the eight previous default-dependent callers are listed above | Keep every declaration explicit | Revert code normally; do not compensate by restoring broad defaults. |
| Release tag rules | No repository rulesets | One active tag ruleset named `Protect aidevops release tags`; exact `refs/tags/v*` include with no exclusions; creation, update, and deletion restrictions only; one specific release-author user as the only bypass | Delete only the created ruleset by its response ID; never delete or replace unrelated rulesets. |
| Environments | No environments | Protected `release` environment; the approved release-author user as the sole reviewer, no team reviewers, self-review allowed, admin bypass disabled, and one selected tag policy `v*` | Delete only the created environment if the snapshot proves it did not exist; otherwise restore the captured detail and policies. |
| npm Trusted Publisher | Existing GitHub Actions publisher; environment binding must be checked in npmjs.com | `marcusquinn/aidevops`, `publish-packages.yml`, environment `release`, `npm publish` only | Restore the exact pre-change publisher fields captured in the npm UI; npm exposes no supported management API for this configuration. |

### Activated state

The verified live state after the rollout is:

- Actions defaults are read-only and workflow-authored pull-request approval is
  disabled; the repository Actions policy remains otherwise unchanged.
- `Protect aidevops release tags` is active for exact `refs/tags/v*` creation,
  update, and deletion, with `marcusquinn` as its sole user bypass.
- `release` requires `marcusquinn`, permits self-review, disallows administrator
  bypass, and accepts only the `v*` tag deployment policy.
- npm Trusted Publisher is bound to `marcusquinn/aidevops`,
  `publish-packages.yml`, environment `release`, with `npm publish` allowed and
  staged publication disabled.

No tag, release, package, deployment, or Homebrew update was created to validate
the rollout. Any subsequent publication still requires separate explicit release
intent and the canonical full-loop release path.

The release-author identity is a consequential live-policy choice and is not
guessed here. The current GitHub REST schema explicitly supports a `User`
repository-ruleset bypass actor on personal repositories, so the approved release
author can be the single bypass principal rather than granting bypass to an entire
repository role.

This maintainer-operated repository uses the same aidevops/model process across
its maintainer accounts, so selecting another account would not create a
meaningfully independent review boundary. The approved release-author user is
therefore also the sole `release` environment reviewer. Keep "Prevent self-review"
disabled so that reviewer can authorize a deployment they initiated, but keep
"Disallow admin bypass" enabled so every publication job still pauses for an
explicit environment approval. This is a deliberate confirmation gate rather
than separation of duties; a genuinely independent human reviewer can replace it
later if the repository's operating model changes.

Operationally, the GitHub release, npm publication, and Homebrew update jobs each
reference `release` and can prompt for approval separately; the Homebrew job waits
for npm first. The designated release-author reviewer must explicitly approve each
pending deployment. The canonical release helper waits for the exact-commit
GitHub release workflow, verifies the published release object, then explicitly
dispatches `publish-packages.yml` at the same signed tag. It reuses an existing
exact-tag package run instead of dispatching a duplicate, and API uncertainty
fails closed before dispatch. A correlated dispatch binds its input tag, event
ref, and event SHA before publication. Registry uncertainty also fails closed;
an exact package version already present on npm is reused rather than published
again.

This handoff does not depend on a workflow-token-created release recursively
starting another workflow. The retained `release: published` trigger supports
external events and immutable tags that predate the dispatch trigger. In
particular, v3.32.188 recovery re-publishes its existing verified release only
after explicit maintainer approval; it does not delete or move the signed tag.
Both trigger paths verify the published release and immutable tag provenance.
Local maintainer credentials can request or recover the workflow but cannot
bypass the environment approval.

The GitHub snapshot and verifier are read-only:

```bash
snapshot_dir="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}"
.agents/scripts/release-publication-settings-helper.sh snapshot \
  --repo marcusquinn/aidevops \
  --output "${snapshot_dir}/release-publication-settings-before.json"

.agents/scripts/release-publication-settings-helper.sh verify-github \
  --repo marcusquinn/aidevops \
  --release-author '<approved-login>' \
  --reviewer '<approved-login>'
```

`verify-github` deliberately reports two manual checks rather than claiming
unsupported API evidence: GitHub's documented environment REST API does not
expose the admin-bypass toggle, and npm documents Trusted Publisher management
only through package settings on npmjs.com. Capture those UI values before and
after mutation. npm also states that saving a publisher does not validate it;
this issue forbids using a real publication as a test, so exact field review is
the terminal non-publishing evidence.

### Mutation order

1. Confirm the code-hardening and explicit-permission checkpoint, PR #28642, is
   merged. Re-run actionlint and required CI for the separate environment-binding
   checkpoint, PR #28722, but keep PR #28722 unmerged until step 8.
2. Capture the GitHub snapshot and npm publisher fields, record the ruleset and
   environment deletion rollback, and verify fresh operation approval.
3. Create the protected `v*` tag ruleset with one specific release-author bypass.
4. Create the `release` environment with the approved release author as its sole
   reviewer, self-review allowed, admin bypass disabled, and the selected `v*` tag
   policy before merging workflows that reference it. Otherwise a workflow run
   can implicitly create an unprotected environment.
5. Bind npm Trusted Publisher to `publish-packages.yml`, environment `release`, and
   the `npm publish` action. Do not enable staged or broader actions in this scope.
6. Set default Actions workflow permissions to read and disable workflow-authored
   pull-request approval. Verify required non-release workflows still receive
   their declared permissions.
7. Run the read-only GitHub verifier and compare npm UI fields to the recorded
   values. Negative verification uses fixtures only; do not create a tag, release,
   package, Homebrew update, or deployment.
   Any API assertion or UI comparison mismatch is a hard stop: do not merge, apply
   the captured rollback inputs, and investigate before taking a new snapshot and
   requesting approval again.
8. Merge environment-binding checkpoint PR #28722 only after the live `release`
   environment is protected and verification passes. That checkpoint binds the
   GitHub release, npm, and Homebrew jobs to `environment: release`.

Rollback restores only values captured in the pre-mutation matrix. Code changes
are reverted normally; live settings are never guessed or broadly reset.
