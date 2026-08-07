---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18217: Reuse trusted Dependabot verification in full-loop merges

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `trusted Dependabot full-loop exact-head merge authority issue 29769` → 0 hits — no relevant lessons
- [x] Discovery pass: 17 recent commits touched target files; direct PR inspection found this implementation has no competing open PR
- [x] File refs verified: 7 existing refs checked at HEAD; the shared library and this brief are intentional new files
- [x] Tier: `tier:thinking` — this changes a merge-authority trust boundary
- [x] Seeded draft PR decision recorded: skipped — the claimed interactive primary session is implementing and verifying the change

## Origin

- **Created:** 2026-08-07
- **Session:** OpenCode interactive
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** Repeated safe Dependabot merges required linked-issue and root-signed approvals even though Pulse already had a narrow bot trust policy. The user requested a permanent simplification rather than more one-off approvals.

## What

Extract the existing trusted-Dependabot checks into one shared shell library and consume that policy from both Pulse and full-loop merge authority. An allowlisted, same-repository, exact-head dependency update may bypass only the external-contributor cryptographic-authority requirement; normal review, CI, NMR, and merge-head gates remain mandatory.

## Why

`full-loop-helper-merge.sh` currently treats Dependabot as an external author because the bot has no collaborator permission. This forces body edits, linked issues, and repeated cryptographic approvals, while `pulse-merge-gates.sh` independently recognizes tightly constrained dependency updates. Duplicated policy causes drift and unnecessary high-authority operations.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** The implementation changes a security-sensitive merge-authority boundary and must preserve GH#17671 fail-closed behavior across interactive, admin, auto-merge, and Pulse paths.

## PR Conventions

This is a leaf task. The implementation PR body must use `Resolves #29769`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The interactive primary session owns implementation and has current file/test context.
- **Status:** `not-created`
- **Freshness evidence:** Worktree base and direct target-file reads were verified on 2026-08-07.
- **Verification run:** Focused tests are listed below and must pass before PR creation.
- **Stale-assumption warning:** Re-read target files and revalidate PR heads if the base branch or open Dependabot PRs change.

## How (Approach)

### Files to Modify

- `NEW: .agents/scripts/trusted-dependabot-lib.sh` — shared identity, exact-head, repository, commit, file, allowlist, security, and non-review-check predicates
- `EDIT: .agents/scripts/pulse-merge-gates.sh` — source the shared library and remove duplicate implementations
- `EDIT: .agents/scripts/pulse-merge.sh` — bind every trusted-bot policy use to the caller's expected current head
- `EDIT: .agents/scripts/full-loop-helper-merge.sh` — apply the shared predicate after exact-head and NMR checks but before external-author crypto requirements
- `EDIT: .agents/configs/trusted-dependabot-updates.conf` — exact package allowlisting only for reviewed dependency updates
- `EDIT: .agents/scripts/tests/test-pulse-merge-trusted-dependabot.sh` — source and test the shared implementation, including head drift
- `EDIT: .agents/scripts/tests/test-full-loop-merge-authority-guard.sh` — prove trusted-bot bypass and unchanged external/NMR behavior
- `EDIT: .agents/scripts/tests/test-full-loop-merge-flag-conflict.sh` — keep the focused flag fixture isolated from unrelated live merge gates exposed by the broader verification run
- `EDIT: TODO.md` and `NEW: todo/tasks/t18217-brief.md` — task audit trail

### Complete Write Surface

- **Callers/readers:** `pulse-merge-gates.sh`, `pulse-merge.sh`, and `full-loop-helper-merge.sh` call the shared predicates with an expected head.
- **Writers/mutation paths:** Only full-loop/Pulse merge and approval callers act on a positive verdict; the library itself is read-only apart from local logging.
- **Tests/fixtures:** The focused shell suites above model GraphQL snapshots, exact heads, NMR holds, external contributors, merge modes, and isolated flag parsing.
- **Schemas/config:** `.agents/configs/trusted-dependabot-updates.conf` remains exact-match and fail-closed.
- **Generated/deployed mirrors:** `setup.sh --non-interactive` deploys `.agents/scripts/`; do not edit the deployed home-directory copy.
- **Migrations/backfills:** No persisted-data migration is required.
- **Cleanup/rollback paths:** Reverting the shared-library call restores the cryptographic external-author path; missing/unreadable library or config must fail before merge.

### Implementation Steps

1. Move the existing Pulse trusted-Dependabot functions into a sourceable guarded library and add exact-head comparison to its single GraphQL snapshot.
2. Source the library from Pulse and full-loop; retain live NMR as an unconditional hold, then allow only a positive shared verdict to return from the full-loop authority guard before collaborator/crypto handling.
3. Adapt focused tests to exercise the real shared library and prove spoofed author, partial/paginated snapshots, head drift, security failure, non-dependency files, unallowlisted packages, failed checks, PR/linked-issue NMR, and ordinary external contributors fail closed.
4. Run focused tests, ShellCheck, changed-file lint, and the repository-required quality gate before creating the PR.

### Hazards and Compatibility

- **Concurrency/atomicity:** Bind the GraphQL trust snapshot and final merge command to the same expected head SHA; any drift rejects the exception.
- **Migration/rollback:** This is source-only and reversible. The allowlist remains opt-in.
- **Mixed-version/backward compatibility:** Existing three-argument Pulse callers remain valid; full-loop supplies the fourth exact-head argument.
- **Idempotency/retry:** Read-only verification is safe to retry; incomplete or paginated API responses fail closed.
- **Partial failure/recovery:** API, parse, config, permission, or check uncertainty falls through to the existing cryptographic external-contributor path rather than authorizing a merge.

### Complexity Impact

- **Target function:** `_merge_guard_admin_merge_maintainer_review` in `.agents/scripts/full-loop-helper-merge.sh`
- **Current line count:** approximately 90 lines before this change
- **Estimated growth:** +11 lines
- **Projected post-change:** approximately 101 lines
- **Action required:** Keep the new trust logic in the shared helper and add only one bounded call at the existing authority boundary.

### Verification Before Dispatch

```bash
shellcheck .agents/scripts/trusted-dependabot-lib.sh .agents/scripts/pulse-merge-gates.sh .agents/scripts/full-loop-helper-merge.sh .agents/scripts/tests/test-pulse-merge-trusted-dependabot.sh .agents/scripts/tests/test-full-loop-merge-authority-guard.sh
bash .agents/scripts/tests/test-pulse-merge-trusted-dependabot.sh
bash .agents/scripts/tests/test-full-loop-merge-authority-guard.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** ShellCheck covers every changed shell surface; focused suites cover shared trust and full-loop authority; changed lint covers repository policy and task metadata.
- **Broad verification trigger:** Shared merge-authority code affects Pulse and full-loop execution.
- **Broad verification command:** `.agents/scripts/linters-local.sh`

### Recoverability Checkpoint

- [ ] Focused tests pass: the two focused shell test commands above
- [ ] WIP commit created before broad gates: `wip: share trusted Dependabot merge authority`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh`

### Safety-Stop Recovery

- **Original objective:** Eliminate repeated linked-issue/root approval for safely verified Dependabot updates without weakening GH#17671.
- **Preserved user directions:** Implement the permanent simplification, then resume eligible dependency merges and the separately authorized release.
- **Trigger and evidence:** GitHub secondary-rate-limit cooldown was observed during discovery.
- **Completed and verified:** Shared library extraction and focused integration tests are durable in this branch once committed.
- **Remaining acceptance criteria:** PR review/merge, deployment, dependency updates, release, and smoke test.
- **Unsafe route not to repeat:** Repeatedly editing bot PR bodies and issuing root-signed one-off approvals.
- **Next safe route:** Finish local verification, PR the shared policy, then revalidate each dependency PR at its current head.
- **Resume condition:** GitHub read/write budget is available for PR operations.
- **Owner and status:** interactive primary session; recovering

### Files Scope

- `.agents/scripts/trusted-dependabot-lib.sh`
- `.agents/scripts/pulse-merge-gates.sh`
- `.agents/scripts/pulse-merge.sh`
- `.agents/scripts/full-loop-helper-merge.sh`
- `.agents/configs/trusted-dependabot-updates.conf`
- `.agents/scripts/tests/test-pulse-merge-trusted-dependabot.sh`
- `.agents/scripts/tests/test-full-loop-merge-authority-guard.sh`
- `.agents/scripts/tests/test-full-loop-merge-flag-conflict.sh`
- `TODO.md`
- `todo/tasks/t18217-brief.md`

## Acceptance Criteria

- [ ] An exact-head, same-repository, allowlisted Dependabot dependency-only PR passes the full-loop authority guard without a linked issue or cryptographic approval.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-full-loop-merge-authority-guard.sh"
  ```

- [ ] Pulse and full-loop source one shared trusted-Dependabot implementation.

  ```yaml
  verify:
    method: bash
    run: "rg -q '^_is_trusted_dependabot_update_pr\\(\\)' .agents/scripts/trusted-dependabot-lib.sh && ! rg -q '^_is_trusted_dependabot_update_pr\\(\\)' .agents/scripts/pulse-merge-gates.sh .agents/scripts/full-loop-helper-merge.sh"
  ```

- [ ] Spoofed, stale-head, forked, non-dependency, unallowlisted, paginated, security-failed, NMR-held, or ordinary external PRs retain fail-closed behavior.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-merge-trusted-dependabot.sh && bash .agents/scripts/tests/test-full-loop-merge-authority-guard.sh"
  ```
