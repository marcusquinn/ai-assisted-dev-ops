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

The source resolver classifies an exact-tip aggregation PR as aggregate even
when the caller names that aggregation PR rather than one of its included
sources. This prevents the direct-source fast path from omitting the tag copy.
For an already-signed tag whose redundant aggregate entries are wholly absent,
recovery may reconstruct them only from the signed `Aidevops-Source-Merge` SHA
after validating the aggregator identity, complete commit manifest, and every
included PR. Any explicit partial, duplicate, malformed, or conflicting tag
manifest remains fail-closed. A recovery workflow executes this verifier from
its exact reviewed `main` workflow commit while all release artifacts remain
pinned to the immutable tag checkout.

After all publication and deployment gates succeed, the aggregation PR receives
`release:published`; each included PR receives `release:superseded` plus a JSON
receipt linking its merge SHA to the aggregation PR, release tag, and release
commit. A failed pre-publication attempt records both the requested and current
source SHAs as actionable failure evidence, but creates no tag or publication.
Retries reconcile terminal receipts and cannot publish twice.

### Post-publication supersession

A different recovery path applies when an older signed tag already published all
three package channels, exact-tag postflight dispatch was its sole failed step,
and a later independently authorized release has since become terminal. The old
tag cannot use normal recovery because GitHub, npm, and Homebrew now converge on
the newer version, and deploying its checkout would downgrade the runtime.

`aidevops release reconcile <older-source-pr>` may mark that receipt
`release:superseded` without publication or deployment only when it verifies:

1. the older tag's immutable source provenance and correlated workflow job;
2. successful GitHub release, npm, and Homebrew verification steps followed by
   one failed `Queue exact-tag postflight` step and no other failed step;
3. a strictly descendant latest signed tag with a terminal-success publication
   run and exact current channel convergence; and
4. a local `release:published` receipt for the latest tag's source PR.

The resulting `.successor.json` receipt records both source PRs, merge SHAs,
tags, release commits, and workflow run IDs with evidence type
`post-publication-supersession`. It is distinct from reviewed aggregation: the
newer tag does not retroactively claim an `Aidevops-Aggregated-Source` trailer.
Missing, duplicated, renamed, malformed, nonterminal, or conflicting evidence
fails closed and leaves the older receipt unchanged. `status` remains read-only,
and this path never dispatches publication or runs `post-release` from the stale
checkout.

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

Aggregation PR #28799 reviews authorized PR #28798 at
`bb9a332e2b03167e4ff6dad575d10db3bf986d9c` through the same path because the
deterministic simplification-state registry commit advanced `main` before its
worker-runtime release was published.

Aggregation PR #28843 reviews authorized release checkpoint PR #28841 at
`0c4744706c2beea41e3c56170f2e0b66746c8813` because the deterministic
simplification-state registry commit advanced `main` before publication.

Aggregation PR #28875 reviews authorized PR #28871 at
`4b1ef7ef1d0e5fdd27b4961b47e278063c47ae55` because deterministic task-state
updates and PR #28870 advanced `main` before publication.

Aggregation PR #28879 reviews authorized PR #28871 at
`4b1ef7ef1d0e5fdd27b4961b47e278063c47ae55` and prior aggregation PR #28875 at
`a039ed430bc97bd0327ddfc1d0d2a1b4f790277d` because PR #28876 advanced `main`
before publication.

Aggregation PR #28916 reviews authorized PR #28914 at
`d522f4df38fc17dddc1cc1feed72e7dfa9279088` because the deterministic t18185
completion commit advanced `main` before publication.

Release `v3.32.198` exposed the exact-tip classification gap when publication
named aggregation PR #28916: the signed tag bound its reviewed merge SHA but
omitted the redundant `Aidevops-Aggregated-Source` copy. Publication correctly
failed before side effects. Issue #28917 records the no-retag recovery and the
resolver regression coverage.

Aggregation PR #28987 reviews authorized maintainer-gating PR #28983 at
`e5f19918e375f13a6deaab916d53538c8641872f` because PR #28986 and deterministic
quality and simplification-state updates advanced `main` before publication.

Aggregation PR #29014 reviews authorized OpenCode version-control PR #29010 at
`4745adde8faa4a92aa4e27763c52e2c1a02a5e76` because PR #29013 advanced `main`
before publication.

Aggregation PR #29026 reviews corrective OpenCode unified-generator PR #29023
at `623e6aeedd77dbf4b1b69b6f411ae71ceb66515d` because the simplification-state
update advanced `main` before publication.

Aggregation PR #29031 re-reviews authorized aggregation PR #29026 at
`351c820f5db214ddf7a069d57f3db9b74e2b6321` because PR #28910 advanced `main`
before publication.

Aggregation PR #29039 re-reviews authorized aggregation PR #29031 at
`c77eaecf9f8b20139a2d5164c49bdd7d75f928b6` because
PRs #29029, #29037, and #29038 advanced `main` before publication.

Aggregation PR #29037 reviews authorized Pulse triage PR #29033 at
`fb4feba9216c643d7a61838877eedeb99bcef6e1` because PRs #29032 and #29029
advanced `main` before publication.

Aggregation PR #29042 re-reviews authorized Pulse triage PR #29033 at
`fb4feba9216c643d7a61838877eedeb99bcef6e1` and prior aggregation PR #29037 at
`11f3a9fa04af659b69b94cd19b86b642bf8303f7` because PR #29038 advanced `main`
before publication.

Aggregation PR #29045 reviews corrective OpenCode aggregation
PR #29039 at `dd22bd011b2ff0970ff240ab832b1147370320ff` and Pulse aggregation
PR #29042 at `998eeef0885e7db14ff753992d1f2cfe208de481`, so one exact tip preserves
those authorized release chains.

Aggregation PR #29044 reviews authorized profile README PR #29038 at
`dfb6bc4a5b76af8697a299b3a17fc74b7c7fecdb` because aggregation PR #29042
advanced `main` before publication.

Aggregation PR #29052 re-reviews authorized Pulse triage PR #29033 at
`fb4feba9216c643d7a61838877eedeb99bcef6e1` and prior aggregation PR #29037 at
`11f3a9fa04af659b69b94cd19b86b642bf8303f7` because release `v3.32.201`
terminalized PR #29042 without recursively terminalizing those sources, then
the release and simplification-state commits advanced `main`.

Aggregation PR #29075 re-reviews the same unresolved PR #29033 and PR #29037
sources because subsequent merges through PR #29071 advanced `main` before
publication from PR #29052 could complete. Its exact branch base is
`9ee52e20b8c5ffecd4672f8784e78993acb7f70f`.

Aggregation PR #29082 reviews authorized Luna standard-routing PR #29072 at
`d222f326dbdfb705352087e6695ce8bda0d4d0a0` because subsequent merges advanced
`main` before its explicitly authorized patch release could begin.

Aggregation PR #29122 reviews authorized workload-tier policy PR #29113 at
`c9ed6bcc591cf98659e44457123d72cdcbf68ff3`. Protected-main recovery PR #29116
advanced `main` before its explicitly authorized patch release completed. Its
exact branch base is `228488086321849fa623c4d2384b79ffa884efb8`.

Aggregation PR #29130 reviews authorized Cloudron monitoring PR #29117 at
`d23478352070461bc3d1208ba74cc0f80c659dca` because release `v3.32.208`
recovery and PR #29127 advanced `main` before publication. Its exact branch
base is `a144e469da47bad93cd3ebfec8cda0a18429c73d`.

Aggregation PR #29148 reviews authorized Qlty postflight PR #29127 at
`c8d6491cdf52e4ab1b8162ee793958bf7c2dfde9` because releases `v3.32.208` and
`v3.32.209`, plus subsequent merges, advanced `main` before its explicitly
authorized patch release completed. Its exact branch base is
`af4dc8979fde7864fd0d7ffc898f47629dd3241e`.

Aggregation PR #29159 reviews authorized GH audit PR #29152 at
`817e68674104c07951932c9cc914763f31f56b94` because protected release PR #29155
advanced `main` after the source merged, while immutable `v3.32.210` predates
that source. Its exact branch base is
`71ad1b62a0da67f161a9a41992d4d4a5958b5e2c`.

Aggregation PR #29164 re-reviews authorized GH audit PR #29152 at
`817e68674104c07951932c9cc914763f31f56b94` and prior aggregation PR #29159 at
`29714078dee12f926f9a52c9eeb51a63549373e3` because subsequent maintained
merges advanced `main` before publication. Its exact branch base is
`becf4e373d9c8a1eb509af6f90c3a0bb481c6225`.

Aggregation PR #29169 re-reviews authorized workflow diagnostics PR #29161 at
`671ed712079913857b3c5213cf4ff97ed56c4287`; it also covers authorized GH audit
PR #29152 at `817e68674104c07951932c9cc914763f31f56b94`, prior aggregation PR #29159 at
`29714078dee12f926f9a52c9eeb51a63549373e3`, and prior aggregation PR #29164 at
`80d0a1cee4caf0e01514e2278d0ac3665e3c41af`. Immutable `v3.32.211` predates
both authorized sources. The exact branch base is
`80d0a1cee4caf0e01514e2278d0ac3665e3c41af`.

Aggregation PR #29177 re-reviews authorized workflow diagnostics PR #29161 at
`671ed712079913857b3c5213cf4ff97ed56c4287` and unresolved combined aggregation
PR #29169 at `f87af46e46501b5e03f9e015c4b790fae2477a22` for a fresh exact-tip review.
Immutable `v3.32.212` settled aggregation PR #29164 and its GH audit chain;
postflight quota fix PR #29174 then advanced `main` with terminal
`release:not-requested` evidence. The exact branch base is
`dacff2107e272a059bfbba693ab5594742c55f5e`.

Aggregation PR #29509 records authorized Buzz ACP compatibility
PR #29503 at `178b684f70f2fd9a60d4ecf41d777a545023736b`. Subsequent terminal
completion metadata advanced `main` before the explicitly authorized release could publish.
The exact branch base is `89c4f74e440ef6492c5f0add22d085135272edb2`.

Aggregation PR #29545 reviews authorized Buzz ACP drift-reconciliation
PR #29538 at `d83c027410983cf83d5f9afb5d85975b69f6e3ec`. Subsequent maintained
merges advanced `main` after the source received terminal `release:not-requested`
evidence and before the user explicitly authorized publication. The exact branch
base is `c945b97c7ac10016ad08da035b71d12bd0a391f9`.

Aggregation PR #29549 re-reviews authorized PR #29538 at
`d83c027410983cf83d5f9afb5d85975b69f6e3ec` and aggregation PR #29545 at
`9d82088812adfb1793b18746e484216b676a5887` because the latter's required
provenance lines were separated into distinct Git trailer paragraphs. Subsequent
maintained merges advanced `main`; the exact branch base is
`e0c71469e63192a699a3c90b464aa8999d257733`.

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
| Environments | No environments | Protected `release` environment; initially one release-author reviewer and selected tag policy `v*`; the approved unattended successor has no reviewer/wait timer and exact deployment policies for tag `v*` plus branch `main` recovery | Delete only the created environment if the snapshot proves it did not exist; otherwise restore the captured detail and policies. |
| npm Trusted Publisher | Existing GitHub Actions publisher; environment binding must be checked in npmjs.com | `marcusquinn/aidevops`, `publish-packages.yml`, environment `release`, `npm publish` only | Restore the exact pre-change publisher fields captured in the npm UI; npm exposes no supported management API for this configuration. |

### Initial activated state

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

### Unattended successor state

Issue #28737 replaces the initial per-run confirmation gate after production
evidence showed that a protected workflow could outlive the 30-minute local
waiter, leaving false `release:failed` evidence, and that a GitHub release created
with `GITHUB_TOKEN` did not trigger the package workflow. Manual approval by the
same release-author identity was confirmation, not independent review, and is not
a durable authorization boundary.

After the issue #28737 code checkpoint merges, the approved live target is:

- keep the protected `v*` tag ruleset and its single release-author bypass;
- keep npm Trusted Publisher bound to `publish-packages.yml` and `release`;
- remove required reviewers and wait timers from `release`;
- permit exactly `v*` tag deployments and `main` branch recovery deployments;
- keep environment administrator bypass disabled and re-check it in the UI.

The trusted operator's complete expected source set is the publication
authorization input. The runner resolves every explicitly authorized PR to its
merged `main` SHA, normalizes and persists the resulting `PR@SHA` set before any
version mutation, and reuses that exact set on retry. Git ancestry proves code
presence only; it never adds authority. The observed direct or reviewed aggregate
manifest must equal the expected set exactly, so omissions, extras, duplicates,
malformed entries, or SHA mismatches fail before a version bump, tag, package, or
receipt mutation. Calls without an explicit set retain singleton compatibility by
using the requested source PR as the expected set.

After that equality gate, the signed annotated tag becomes the durable
publication record. Before any public side effect, one unified workflow verifies
its exact source PR/merge trailers, GitHub-verified tag object, release commit,
and `main` ancestry. A normal
tag run must execute at the matching tag ref. Recovery must execute the reviewed
workflow from `main`, accepts only the newest exact semantic-version tag, and
repeats the same provenance verifier. GitHub release creation, npm publication,
and Homebrew update are each check-before-write and verify-after-write operations,
so retries converge without duplicate publication or channel downgrade.

Immutable historical tags are never rewritten to repair an authorization gap.
Detached `authorization-gap` evidence records the expected and observed source
sets, tag object, release commit, timestamp, and reason. It is deliberately not a
release status or cleanup receipt, cannot transition cleanup to terminal success,
and cannot authorize publication. Omitted source receipts remain pending until
separately reviewed terminal evidence exists.

This unified path supersedes the interim separate package dispatch. Workflow-run
discovery binds a push to the exact tag commit. Recovery names and verifies an
exact `<tag-commit>.<main-workflow-commit>` correlation: the dispatcher supplies
the verified tag commit and the run identity appends GitHub's actual workflow
commit. This avoids branch-advance races, rejects unavailable or malformed API
responses, and never treats uncertainty as successful correlation.
npm registry uncertainty likewise fails closed before publication. Existing and
new npm versions must match the exact locally packed integrity and shasum; npm's
signature audit must then verify one SLSA provenance statement binding that digest
to this repository and workflow path at either the exact tag ref or reviewed
`main` recovery ref. This preserves recovery after npm succeeds in a tag run but a
later channel fails. Homebrew reconciliation
compares the complete expected formula from the signed tag rather than accepting
matching URL or digest fragments in otherwise drifted content.

The local initiator observes only that the exact tag workflow was queued; it does
not have to remain alive until publication completes. Exit `8` means durable
pending work, not failure. Resume from any trusted session with:

```bash
aidevops release status <source-pr>
aidevops release reconcile <source-pr>
```

`status` is read-only. `reconcile` verifies the newest matching signed tag and
channel state, dispatches recovery only when no successful run has converged, and
finalizes release receipts/local deployment only after GitHub, npm, and Homebrew
agree. Routine interactive publication does not use `sudo`. For a future
headless worker release, `sudo aidevops approve issue <issue> <owner/repo>` may
mint the existing root-signed issue authorization; it does not itself publish and
does not relax the trusted high/critical-priority release gate.

The GitHub snapshot and verifier are read-only:

```bash
snapshot_dir="${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}"
.agents/scripts/release-publication-settings-helper.sh snapshot \
  --repo marcusquinn/aidevops \
  --output "${snapshot_dir}/release-publication-settings-before.json"

.agents/scripts/release-publication-settings-helper.sh verify-github \
  --repo marcusquinn/aidevops \
  --release-author '<approved-login>' \
  --unattended
```

`verify-github` deliberately reports two UI checks rather than claiming
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

For the unattended transition, capture a fresh snapshot after issue #28737 merges
and before changing the environment. Add the exact `main` branch deployment
policy, remove reviewer/wait rules, run `verify-github --unattended`, and compare
the two UI-only controls above. On any mismatch, restore the fresh snapshot before
dispatching recovery. The first authorized recovery is the existing newest tag;
do not create a test tag or version bump solely to validate settings.
