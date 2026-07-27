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

`.agents/scripts/release-provenance-helper.sh` verifies the same evidence before
GitHub release creation, npm OIDC publication, and Homebrew update work:

1. tag, `VERSION`, `package.json`, checkout, and bump-commit subject agree;
2. the local and GitHub tag-object SHA agree, and the annotated tag is
   GitHub-verified and points at the checked-out commit;
3. the tag commit is reachable from `origin/main`;
4. the recorded source PR is merged into `main`, its merge SHA matches, and that
   merge is the direct parent of the release commit.

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

Read-only inventory on 2026-07-27 confirmed the original exposure remains live.
Capture a fresh machine-readable snapshot immediately before mutation with
`release-publication-settings-helper.sh snapshot`; do not rely on this dated
summary if the live state has changed.

| Control | Pre-mutation state | Approved target | Exact rollback input |
|---|---|---|---|
| Actions defaults | `default_workflow_permissions=write`; workflow PR approval enabled | `read`; PR approval disabled | Restore both values from `actions.workflow_permissions` in the snapshot. |
| Actions policy | Actions enabled; all actions allowed | No change in this checkpoint | Preserve `actions.policy` unchanged. |
| Workflow permissions | All 55 workflows declare `permissions`; the eight previous default-dependent callers are listed above | Keep every declaration explicit | Revert code normally; do not compensate by restoring broad defaults. |
| Release tag rules | No repository rulesets | One active tag ruleset named `Protect aidevops release tags`, targeting `refs/tags/v*`, restricting creation, update, and deletion, with one specific release-author user as the only bypass | Delete only the created ruleset by its response ID; never delete or replace unrelated rulesets. |
| Environments | No environments | Protected `release` environment; independent reviewer(s), self-review prevented, admin bypass disabled, and one selected tag policy `v*` | Delete only the created environment if the snapshot proves it did not exist; otherwise restore the captured detail and policies. |
| npm Trusted Publisher | Existing GitHub Actions publisher; environment binding must be checked in npmjs.com | `marcusquinn/aidevops`, `publish-packages.yml`, environment `release`, `npm publish` only | Restore the exact pre-change publisher fields captured in the npm UI; npm exposes no supported management API for this configuration. |

The current release author and independent reviewer identities are consequential
live-policy choices and are intentionally not guessed or committed here. The
release author must be the single ruleset bypass actor. At least one different
repository collaborator must review the `release` environment, and GitHub's
"Prevent self-review" and "Disallow admin bypass" controls must remain enabled.

The GitHub snapshot and verifier are read-only:

```bash
snapshot_dir="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}"
.agents/scripts/release-publication-settings-helper.sh snapshot \
  --repo marcusquinn/aidevops \
  --output "${snapshot_dir}/release-publication-settings-before.json"

.agents/scripts/release-publication-settings-helper.sh verify-github \
  --repo marcusquinn/aidevops \
  --release-author '<approved-login>' \
  --reviewer '<independent-reviewer-login>'
```

`verify-github` deliberately reports two manual checks rather than claiming
unsupported API evidence: GitHub's documented environment REST API does not
expose the admin-bypass toggle, and npm documents Trusted Publisher management
only through package settings on npmjs.com. Capture those UI values before and
after mutation. npm also states that saving a publisher does not validate it;
this issue forbids using a real publication as a test, so exact field review is
the terminal non-publishing evidence.

### Mutation order

1. Re-run actionlint and required CI after the explicit-permission changes merge.
2. Capture the GitHub snapshot and npm publisher fields, record the ruleset and
   environment deletion rollback, and verify fresh operation approval.
3. Create the protected `v*` tag ruleset with one specific release-author bypass.
4. Create the `release` environment, independent reviewer policy, self-review
   prevention, disabled admin bypass, and selected `v*` tag policy before merging
   workflows that reference it. Otherwise a workflow run can implicitly create an
   unprotected environment.
5. Bind npm Trusted Publisher to `publish-packages.yml`, environment `release`, and
   the `npm publish` action. Do not enable staged or broader actions in this scope.
6. Set default Actions workflow permissions to read and disable workflow-authored
   pull-request approval. Verify required non-release workflows still receive
   their declared permissions.
7. Run the read-only GitHub verifier and compare npm UI fields to the recorded
   values. Negative verification uses fixtures only; do not create a tag, release,
   package, Homebrew update, or deployment.
8. Merge the code checkpoint that binds the GitHub release, npm, and Homebrew jobs
   to the already-protected environment.

Rollback restores only values captured in the pre-mutation matrix. Code changes
are reverted normally; live settings are never guessed or broadly reset.
