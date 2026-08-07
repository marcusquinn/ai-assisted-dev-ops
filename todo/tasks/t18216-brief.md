<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->
# t18216: Fix Dependabot review-gate deadlock and preserve deterministic Qlty installs

## Pre-flight

- [x] Memory recall: `full-loop release Dependabot review bot gate trusted bot qlty action aidevops` → 0 hits — no relevant lessons
- [x] Discovery pass: 2 commits / 0 merged PRs / 0 open implementation PRs touched the review-gate targets; six open Dependabot PRs reproduce the failure
- [x] File refs verified: `.coderabbit.yaml`, `.github/dependabot.yml`, `.github/workflows/code-quality.yml`, and focused test directory exist at HEAD
- [x] Tier: `tier:standard` — bounded configuration change with live cross-service verification and no trust-boundary relaxation
- [x] Seeded draft PR decision recorded: skipped — the primary interactive full-loop session owns implementation through release

## Origin

- **Created:** 2026-08-07
- **Session:** OpenCode interactive session
- **Created by:** AI DevOps (ai-interactive)
- **Conversation context:** Six Dependabot PRs remained blocked for more than three hours. Inspection proved CodeRabbit intentionally ignored their authors while the external-contributor review gate correctly required settled AI review evidence.

## What

Make dependency-update PRs eligible for CodeRabbit review, prevent the known-incompatible Qlty action v2.3.0 update, refresh and merge safe pending dependency updates, and publish a verified aidevops patch release.

## Why

The current policy forms an impossible gate: CodeRabbit skips Dependabot and Renovate, but GitHub reports those authors as contributors and the GH#17671 trust boundary requires review. Separately, qlty-action v2.3.0 installs a moving latest CLI and breaks the repository's deterministic `QLTY_VERSION=0.636.0` contract.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The implementation is bounded and reversible, but successful completion depends on live GitHub Actions, CodeRabbit, Dependabot regeneration, exact-head merge ordering, and release reconciliation.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Current-session implementation is already authorized and owned by the interactive full-loop executor.
- **Status:** `not-created`
- **Freshness evidence:** Memory, recent commits, open PRs, workflow logs, and target files checked on 2026-08-07.
- **Verification run:** Initial live PR diagnostics complete; implementation tests pending.
- **Stale-assumption warning:** Re-check if CodeRabbit changes bot-author behavior or qlty-action adds an explicit CLI-version input.

## How (Approach)

### Files to Modify

- EDIT: `.coderabbit.yaml` — remove dependency-update bots from `reviews.auto_review.ignore_usernames` without changing the GH#17671 external-author gate.
- EDIT: `.github/dependabot.yml` — ignore only qlty-action v2.3.0, whose verified action metadata lacks a version input.
- NEW: `.agents/scripts/tests/test-dependency-review-policy.sh` — enforce the configuration contract.
- EDIT: `TODO.md` and NEW: `todo/tasks/t18216-brief.md` — maintain task traceability.

### Complete Write Surface

- **Callers/readers:** CodeRabbit reads `.coderabbit.yaml`; GitHub Dependabot reads `.github/dependabot.yml`; Code Quality Actions read `.github/workflows/code-quality.yml`.
- **Writers/mutation paths:** This PR writes `.coderabbit.yaml`, `.github/dependabot.yml`, and the focused regression; Dependabot subsequently regenerates its own branches.
- **Tests/fixtures:** `.agents/scripts/tests/test-dependency-review-policy.sh` plus the repository local linter suite cover the changed contracts.
- **Schemas/config:** GitHub's official Dependabot options reference confirms `ignore.dependency-name` and exact `versions` entries. qlty-action v2.3.0 `install/action.yml` exposes only `github-token`.
- **Generated/deployed mirrors:** `setup.sh --non-interactive` deploys the released framework; no generated source mirrors change.
- **Migrations/backfills:** N/A because these service configurations store no migrated records; existing dependency PRs instead require review retrigger/rebase after merge.
- **Cleanup/rollback paths:** `git revert` of the configuration PR restores prior behavior; remove the exact Qlty ignore after a verified action release restores deterministic version selection.

### Implementation Steps

1. Remove bot-author exclusions from CodeRabbit while retaining all external-contributor strict checks.
2. Add a narrowly versioned Dependabot ignore for qlty-action 2.3.0.
3. Add focused regression assertions for both service contracts and the existing Qlty CLI/action pins.
4. Run focused and broad required gates, create the managed PR, address review findings, and merge through `full-loop-helper.sh`.
5. Refresh the six dependency PRs, require terminal-success exact-head checks, and merge eligible updates. Do not merge the incompatible grouped actions head.
6. Publish the authorized patch release, deploy/update, and test the released version and live dependency flow.

### Hazards and Compatibility

- **Concurrency/atomicity:** Weekly review bursts can overlap, but each PR has isolated CodeRabbit state and existing pause controls bound provider concurrency.
- **Migration/rollback:** No migration runs; git revert restores the prior service configuration, while the exact Qlty ignore is removed only after a verified compatible action release.
- **Mixed-version/backward compatibility:** Downstream reusable gates remain strict and unchanged; only default-branch CodeRabbit eligibility changes.
- **Idempotency/retry:** Dependabot refresh/recreate and release reconciliation are idempotent. Resume pending release state instead of creating another tag.
- **Partial failure/recovery:** Keep failed dependency PRs open with terminal diagnostics; merge no PR whose exact head has a non-review required failure, and resume pending release reconciliation without minting a second tag.
- **Trust boundary:** Do not whitelist a login or weaken external-author handling. Dependency bots receive the same settled review required of other contributor-associated PRs.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-dependency-review-policy.sh
shellcheck .agents/scripts/tests/test-dependency-review-policy.sh
.agents/scripts/linters-local.sh
```

- **Surface mapping:** the focused test covers both service configurations and the Qlty workflow pins; ShellCheck covers the new executable test; the repository linter covers YAML, Markdown, and shared release-facing configuration.

Live verification must additionally show a Dependabot PR receives settled CodeRabbit evidence, `review-bot-gate` succeeds, Qlty resolves 0.636.0, merged updates reach `main`, and release/update smoke tests report the published version.

## Acceptance Criteria

- [ ] Dependabot and Renovate PRs are eligible for automatic CodeRabbit review while external/unknown human contributors remain strict and cannot bypass review.
- [ ] qlty-action v2.3.0 is not proposed or merged, while the Qlty CLI remains deterministically pinned to 0.636.0.
- [ ] Focused policy regression, ShellCheck, and repository-required gates pass.
- [ ] Every merged dependency PR has exact-head terminal-success required checks; any incompatible PR remains unmerged or is safely regenerated.
- [ ] The authorized patch release is publicly published, deployed, and verified by update/status smoke tests.

## Handoff

If the safety fuse pauses CI or release reconciliation, preserve the issue, PR numbers, exact head/tag, terminal checks, pending criteria, and resume with the delta-aware wait or `aidevops release reconcile`; never reinterpret a fuse as completion.
