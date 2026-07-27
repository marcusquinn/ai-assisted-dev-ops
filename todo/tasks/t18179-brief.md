---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18179: Repair triage ownership isolation and harden public issue review

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `GH#28705 triage ownership isolation prompt injection public issue review` → 0 hits — no relevant lessons
- [x] Discovery pass: 5 recent commits / 0 colliding merged PRs / 0 colliding open PRs found for this failure family
- [x] File refs verified: 9 refs checked, all present at HEAD
- [x] Tier: `tier:thinking` — security-boundary, fallback, cache migration, and cross-module design decisions rule out lower tiers
- [x] Seeded draft PR decision recorded: skipped — the interactive primary session owns implementation and verification

## Origin

- **Created:** 2026-07-27
- **Session:** OpenCode interactive session for GH#28705
- **Created by:** AI DevOps (ai-interactive)
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** A maintainer requested a systemic investigation of widespread `triage-failed` labels and explicit hardening against arbitrary public issue content influencing privileged triage automation.

## What

Make sandboxed triage a genuinely non-worker runtime role, reject untrusted public content before model invocation when deterministic prompt-injection scanning is unavailable or non-clean, strictly validate model output before posting, and re-evaluate stale cached triage state under the corrected policy.

## Why

`_run_triage_review_worker` currently exports the implementation-worker ownership contract while launching `--role triage`. `_cmd_run_prepare` therefore runs the worker ownership fence without a worker login and exits before model invocation. The runtime output is then misclassified as `no-review-header`, which adds `triage-failed` and caches the issue. Separately, public issue bodies, comments, and PR diffs currently reach the maintainer-funded model without a deterministic fail-closed content gate.

## Tier

### Tier checklist (verify before assigning)

- [ ] **2 or fewer files to modify?** No — runtime, triage, cache, and tests span multiple files.
- [ ] **Every target file under 500 lines?** No — the primary dispatch file is over 1,400 lines.
- [ ] **Exact `oldString`/`newString` for every edit?** No — security behavior requires coordinated design.
- [ ] **No judgment or design decisions?** No — role isolation and fail-closed state transitions require judgment.
- [ ] **No error handling or fallback logic to design?** No — scanner/runtime failures need explicit fail-closed routing.
- [ ] **No cross-package or cross-module changes?** No — headless runtime and Pulse triage modules interact.
- [ ] **Estimate 1h or less?** No.
- [ ] **4 or fewer acceptance criteria?** No.
- [x] **Dispatch-path classification:** Self-hosting dispatch files are in scope, so `tier:thinking` is required; this task remains `#no-auto-dispatch #interactive` because the primary session owns it.

**Selected tier:** `tier:thinking`

**Tier rationale:** This repairs a live worker ownership boundary and introduces fail-closed handling for hostile public input across runtime, dispatch, cache, labels, and adversarial tests.

## PR Conventions

This is a leaf issue. The implementation PR must use `Resolves #28705`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The context-rich interactive session is implementing immediately; a seed would not reduce duplicate exploration.
- **Status:** `not-created`
- **Freshness evidence:** Worktree rebased to `origin/main` at `1d8cc03ad`; target functions and tests read in-session.
- **Verification run:** Not applicable before implementation.
- **Stale-assumption warning:** Re-run targeted tests and inspect any upstream changes if `origin/main` moves before push.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/headless-runtime-worker-prepare.sh:123-202` and `.agents/scripts/pulse-ancillary-dispatch.sh:423-1240` — establish ownership, scan, output, and finalization boundaries.
- **Load only if:** `.agents/reference/review-core.md` or worker diagnostics references — only if existing contracts conflict with focused tests.
- **Why:** Preserve implementation-worker claim fences while preventing triage from acquiring or releasing worker ownership.
- **Stop when:** Role flow, scanner exit semantics, label/cache transitions, and executable regression commands are explicit.

### Worker Quick-Start

1. Triage must not export `WORKER_ISSUE_NUMBER`, `WORKER_REPO_SLUG`, or `WORKER_WORKTREE_PATH`; those variables grant implementation-worker lifecycle semantics.
2. Pass the parsed runtime role into `_cmd_run_prepare` and apply ownership verification only to `worker`.
3. Scan all public prompt fields with `content-scanner-helper.sh` using normalization and a forced full scan; missing helper, missing prompt guard, WARN, BLOCK, or scanner error all stop before model invocation.
4. Security holds add `security-review` and `hold-for-review`, remove stale `triage-failed`, retain `needs-maintainer-review`, and never post hostile content.
5. Output must begin with one exact allowed recommendation line and contain the required bounded structure; variants or preambles are suppressed.

### Files to Modify

- `EDIT: .agents/scripts/headless-runtime-worker-prepare.sh:123-202` — make worker ownership verification and normal/abnormal cleanup role-scoped.
- `EDIT: .agents/scripts/headless-runtime-helper.sh:1701-1724` — pass the parsed role into preparation.
- `EDIT: .agents/scripts/headless-runtime-worker.sh:1799-1875` — bypass claim/worktree release for non-worker completion.
- `EDIT: .agents/scripts/pulse-ancillary-dispatch.sh:423-1240` — classify ownership failures, add fail-closed scanning/security holds, isolate triage environment, strictly validate output, and reconcile labels.
- `EDIT: .agents/scripts/pulse-triage-cache.sh:44-66` — version the deterministic cache hash so stale pre-fix decisions receive one corrected evaluation.
- `EDIT: .agents/scripts/tests/test-headless-runtime-worktree-tests.sh` — preserve the worker fence and prove triage skips it.
- `EDIT: .agents/scripts/tests/test-triage-output-shape.sh` — cover exact output shape and infrastructure label/cache behavior.
- `EDIT: .agents/scripts/tests/test-triage-prefetch-evidence.sh` — reject traversal and symlink evidence citations.
- `EDIT: .agents/scripts/tests/test-triage-review-worker-contract.sh` — prove triage does not inherit implementation-worker environment authority.
- `EDIT: .agents/scripts/tests/test-pulse-wrapper-characterization.sh` — prove cache-schema changes invalidate prior decisions.
- `NEW: .agents/scripts/tests/test-triage-security-gate.sh` — clean, hostile, Unicode-obfuscated, warning, and unavailable-scanner paths.

### Complete Write Surface

- **Callers/readers:** `headless-runtime-helper.sh::cmd_run`, `_build_triage_review_prompt`, `_dispatch_triage_review_worker`, and Pulse triage candidate dispatch.
- **Writers/mutation paths:** GitHub security/hold/triage labels, triage comments, local content-hash/failure cache, session/dispatch lifecycle state.
- **Tests/fixtures:** the four focused shell test files listed above plus existing content-scanner behavior.
- **Schemas/config:** cache hash schema only; no external schema change.
- **Generated/deployed mirrors:** `setup.sh` deploys `.agents/scripts`; do not edit `~/.aidevops/agents/scripts` directly.
- **Migrations/backfills:** cache-schema bump causes one re-evaluation; corrected success/infrastructure/security paths remove stale `triage-failed` labels.
- **Cleanup/rollback paths:** security holds remain until maintainer review; worker claim release and ownership fences remain unchanged for role `worker`.

### Implementation Steps

1. Pass `role` into `_cmd_run_prepare`, default it safely for direct test callers, and guard preparation, completion, and abnormal-exit ownership cleanup with `role == worker`.
2. Stop exporting implementation-worker context from `_run_triage_review_worker`; preserve issue correlation only in its title, session key, and prefetched prompt.
3. Extend runtime infrastructure classification for ownership-contract signatures and remove stale `triage-failed` on infrastructure outcomes without consuming retry/cache budget.
4. Add a deterministic untrusted-content gate before prompt construction/model invocation. Scan current issue metadata/body/comments, PR diff/file paths, and public recent-title evidence. Fail closed for missing dependencies and every non-clean result; constrain cited-file prefetch to tracked regular files inside the repository.
5. Add idempotent security labels/hold behavior without echoing hostile content into logs or comments.
6. Replace permissive “header anywhere” extraction with exact first-line, required-section, required-field, and 800-word validation; post through a body file only after all checks pass.
7. Version the triage content hash and add adversarial regression coverage.

### Hazards and Compatibility

- **Concurrency/atomicity:** Security label writes are idempotent; model dispatch is skipped before issue locking when scanning blocks.
- **Migration/rollback:** Cache versioning causes one bounded re-evaluation. Reverting restores old cache keys but must not remove human security holds.
- **Mixed-version/backward compatibility:** Old runners may still emit ownership-contract failures; the expanded infrastructure classifier prevents false content-failure state during rollout.
- **Idempotency/retry:** Infrastructure and scanner failures do not consume content retry budget. Deterministic model-shape failures retain the existing capped retry behavior.
- **Partial failure/recovery:** A failed scanner or label write still blocks model invocation. A failed comment write is infrastructure, not a model-content failure.

### Complexity Impact

- **Target function:** `_extract_and_post_triage_review` in `.agents/scripts/pulse-ancillary-dispatch.sh`
- **Current line count:** approximately 70 lines (threshold: 100 lines)
- **Estimated growth:** net negative after extracting dedicated scan/shape/post helpers
- **Projected post-change:** below 80 lines
- **Action required:** Extract focused helpers before adding policy branches.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-headless-runtime-helper.sh
bash .agents/scripts/tests/test-triage-review-worker-contract.sh
bash .agents/scripts/tests/test-triage-output-shape.sh
bash .agents/scripts/tests/test-triage-prefetch-evidence.sh
bash .agents/scripts/tests/test-triage-security-gate.sh
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
shellcheck .agents/scripts/headless-runtime-worker-prepare.sh .agents/scripts/headless-runtime-helper.sh .agents/scripts/headless-runtime-worker.sh .agents/scripts/pulse-ancillary-dispatch.sh .agents/scripts/pulse-triage-cache.sh .agents/scripts/tests/test-headless-runtime-worktree-tests.sh .agents/scripts/tests/test-triage-output-shape.sh .agents/scripts/tests/test-triage-prefetch-evidence.sh .agents/scripts/tests/test-triage-review-worker-contract.sh .agents/scripts/tests/test-triage-security-gate.sh .agents/scripts/tests/test-pulse-wrapper-characterization.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Runtime tests prove ownership isolation; triage tests prove scan/output/state behavior; ShellCheck and changed-file lint cover all modified scripts.
- **Broad verification trigger:** Run the full headless helper suite because `_cmd_run_prepare` is a shared runtime boundary; no full-repository lint unless changed-file lint identifies shared-gate uncertainty.

### Recoverability Checkpoint

- [ ] Focused tests pass: commands above
- [ ] WIP commit created before broad gates: `wip: harden triage review isolation`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Repair widespread triage failures and prevent public content from influencing privileged automation.
- **Preserved user directions:** Implement, verify, merge, and publish the explicitly authorized patch release.
- **Trigger and evidence:** not triggered
- **Completed and verified:** root cause and live failure signature established; issue/worktree created.
- **Remaining acceptance criteria:** implementation, tests, PR, merge, release, and live stale-label cleanup.
- **Unsafe route not to repeat:** launching triage with implementation-worker ownership variables or sending unscanned public content to the model.
- **Next safe route:** focused role/scanner/output changes with adversarial tests.
- **Resume condition:** focused tests pass and security review finds no privilege path.
- **Owner and status:** interactive primary session; recovering

### Files Scope

- `.agents/scripts/headless-runtime-worker-prepare.sh`
- `.agents/scripts/headless-runtime-helper.sh`
- `.agents/scripts/headless-runtime-worker.sh`
- `.agents/scripts/pulse-ancillary-dispatch.sh`
- `.agents/scripts/pulse-triage-cache.sh`
- `.agents/scripts/tests/test-headless-runtime-worktree-tests.sh`
- `.agents/scripts/tests/test-triage-output-shape.sh`
- `.agents/scripts/tests/test-triage-prefetch-evidence.sh`
- `.agents/scripts/tests/test-triage-review-worker-contract.sh`
- `.agents/scripts/tests/test-triage-security-gate.sh`
- `.agents/scripts/tests/test-pulse-wrapper-characterization.sh`
- `TODO.md`
- `todo/tasks/t18179-brief.md`

## Acceptance Criteria

- [ ] Triage reaches model invocation without worker ownership verification, worktree transfer, claim transition, or claim release; implementation workers retain both pre-prepare and pre-runtime ownership fences.
- [ ] Public issue metadata/body/comments and PR diff/file data receive deterministic normalized scanning before model invocation; helper absence, WARN, BLOCK, and scanner error all fail closed; contributor citations cannot traverse outside the repo or dereference symlinks.
- [ ] A scan hold adds `security-review` and `hold-for-review`, removes stale `triage-failed`, preserves `needs-maintainer-review`, and does not send content to the model or copy it into a comment/log.
- [ ] Only output whose first line is exactly one of the three allowed recommendation lines, whose required sections/fields exist, and whose total is at most 800 words can be posted.
- [ ] Ownership/prelaunch/comment-write infrastructure failures do not add `triage-failed`, increment retry state, or cache the content hash; stale `triage-failed` is removed.
- [ ] Versioned cache behavior causes pre-fix cached NMR issues to receive one corrected re-evaluation.
- [ ] Focused tests, full headless runtime tests, ShellCheck, and changed-file lint pass.
- [ ] Independent security review confirms the LLM remains recommendation-only with no network, write, dispatch, approval, merge, or release authority.

## Context & Decisions

- Role identity is the authority boundary; triage must not reuse `WORKER_*` lifecycle credentials merely for correlation.
- Scanner policy is fail-closed because the model consumes arbitrary public content using maintainer resources.
- Deterministic scanner findings are security holds, not automated proof of malicious intent and not `triage-failed` model failures.
- Exact output validation replaces permissive variant acceptance because posted comments are the only authorized triage side effect.
- `security-review` already preserves NMR through the cryptographic approval path; `hold-for-review` adds an unconditional dispatch/merge pause.

## Relevant Files

- `.agents/scripts/headless-runtime-worker-prepare.sh:123-202` — preparation ownership fence.
- `.agents/scripts/headless-runtime-helper.sh:1586-1724` — parsed role and prepare caller.
- `.agents/scripts/pulse-ancillary-dispatch.sh:423-1240` — triage prompt, runtime, validation, labels, and cache finalization.
- `.agents/scripts/content-scanner-helper.sh:352-499` — normalized scanner and exit semantics.
- `.agents/scripts/prompt-guard-helper.sh:481-552` — policy check semantics.
- `.agents/workflows/triage-review.md:31-48` — exact output and no-authority contract.

## Dependencies

- **Blocked by:** none
- **Blocks:** reliable NMR triage and cleanup of the current false `triage-failed` cohort
- **External:** GitHub access for issue/PR lifecycle and explicit patch publication already authorized by the maintainer

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 1h | Completed root-cause and security-boundary inspection |
| Implementation | 2.5h | Runtime role, scanner, output, state, and cache changes |
| Testing/review | 1.5h | Adversarial tests, lint, independent review, lifecycle |
| **Total** | **5h** | |
