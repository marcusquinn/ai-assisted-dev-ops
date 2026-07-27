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
rewriting the published branch. The follow-up commit message carries the same
trailers so the repository's squash-merge commit preserves the reviewed
manifest consumed by the release verifier. Keep the trailer lines contiguous in
one terminal commit-message block so `git interpret-trailers --parse` retains
the aggregator identity and every repeated source.

PR #28725 reviews this recovery manifest:

```text
Aidevops-Release-Aggregator-PR: 28725
Aidevops-Release-Aggregates: 28701@a8f2cf28004aabdbd774cf3157d984eaafad7cee
Aidevops-Release-Aggregates: 28720@00faf1c84be08457b27bd7ba64c8773b2837726c
```

Manual arbitrary-version package publication is intentionally unsupported. A
recovery operation must use an existing tag that passes the same verifier.

## Actions default-permission impact matrix

Repository default permissions can move from `write` to `read` only after every
workflow declares its needs. The repository audit found eight callers without an
explicit `permissions` block; this code checkpoint makes all eight explicit.

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

1. Re-run actionlint and required CI after the explicit-permission changes merge.
2. Set default Actions workflow permissions to read and disable workflow-authored
   pull-request approval. Verify required workflows still receive their declared
   permissions through completed non-release runs.
3. Create a protected `v*` tag ruleset that blocks creation, update, and deletion
   except for the narrowly documented maintainer release authority. Record the
   prior ruleset response and the exact rollback operation before mutation.
4. Create a `release` environment with required maintainer review and a deployment
   ref policy limited to protected release tags.
5. In a follow-up code checkpoint, bind GitHub release, npm, and Homebrew jobs to
   the `release` environment. Configure npm Trusted Publisher to require the same
   workflow and environment identity where the registry supports that binding.
6. Verify Actions defaults, rulesets, environment protection, and Trusted Publisher
   identity through read-only APIs. Negative verification must use fixture or
   non-publishing paths.

Rollback restores only values captured in the pre-mutation matrix. Code changes
are reverted normally; live settings are never guessed or broadly reset.
