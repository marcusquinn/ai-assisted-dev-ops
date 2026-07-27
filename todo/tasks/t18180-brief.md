---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18180: Add malformed triage prompt metadata propagation regression coverage

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `triage prompt metadata propagation regression coverage` → 0 hits — no relevant lessons
- [x] Discovery pass: 1 source commit / 0 colliding merged PRs / 0 colliding open PRs found for this exact validation path
- [x] File refs verified: 4 refs checked, all present at `bf745ca9f`
- [x] Tier: `tier:standard` — the test target is over 500 lines and requires coordinated negative-path assertions
- [x] Seeded draft PR decision recorded: skipped — a focused issue and verified test pattern are sufficient

## Origin

- **Created:** 2026-07-27
- **Session:** OpenCode interactive follow-up to GH#28705 / PR #28735
- **Created by:** AI DevOps (ai-interactive)
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** Exact-object review of PR #28735 accepted the production validator but identified missing direct regression coverage for malformed metadata propagated from prompt construction into triage dispatch.

## What

Add focused regression tests proving that `dispatch_triage_reviews` rejects malformed or inconsistent prompt metadata before worker launch, retains the available worker slot, records an infrastructure retry, and removes the sensitive prompt artifact.

## Why

PR #28735 added `_triage_prompt_metadata_is_valid` as a fail-closed boundary between prompt construction and worker dispatch. Existing tests cover successful metadata propagation but do not exercise malformed item kind, revision, or snapshot values through the dispatch path, so a future parser regression could bypass or break this boundary without a focused failure.

## Tier

### Tier checklist (verify before assigning)

- [x] **2 or fewer files to modify?** Yes — one focused test file; production changes only if a test exposes a defect.
- [ ] **Every target file under 500 lines?** No — the existing test file is 804 lines.
- [ ] **Exact `oldString`/`newString` for every edit?** No — fixture integration requires adapting the existing dispatch stub.
- [x] **No judgment or design decisions?** Yes — expected fail-closed behavior is already implemented.
- [x] **No error handling or fallback logic to design?** Yes — this task verifies existing behavior.
- [x] **No cross-package or cross-module changes?** Yes.
- [x] **Estimate 1h or less?** Yes.
- [x] **4 or fewer acceptance criteria?** Yes.
- [x] **Dispatch-path classification:** The source reference is a self-hosting dispatch file; retain `#auto-dispatch`, with runtime routing responsible for model elevation.

**Selected tier:** `tier:standard`

**Tier rationale:** The implementation is focused, but the large shell test harness and coordinated assertions disqualify `tier:simple`.

## PR Conventions

This is a leaf issue. The implementation PR must use `Resolves #28754`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Current discovery identifies the exact test harness and behavior; an issue is enough and avoids anchoring a worker to an unverified fixture edit.
- **Status:** `not-created`
- **Freshness evidence:** Source validator, dispatch parser, retry helper, and existing dispatch tests were read against `bf745ca9f`.
- **Verification run:** `UNVERIFIED — planning-only follow-up`
- **Stale-assumption warning:** Re-read the source and test line ranges if `main` changes before implementation.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/tests/test-pulse-wrapper-worker-count.sh:495-804` — extend the prompt-construction stub so each malformed metadata case can be injected and add dispatch-level negative-path assertions.
- `REFERENCE ONLY: .agents/scripts/pulse-ancillary-dispatch.sh:473-533,2391-2510` — preserve the existing infrastructure-retry, artifact-cleanup, metadata-validation, and dispatch contracts. Modify production code only if the new test demonstrates a real defect.

### Complete Write Surface

- **Callers/readers:** `dispatch_triage_reviews` parses `_build_triage_review_prompt` output and calls `_triage_prompt_metadata_is_valid` before `_dispatch_triage_review_worker`.
- **Writers/mutation paths:** the negative path calls `_triage_mark_infrastructure_retry`, removes the prompt artifact directory, and leaves the available-slot count unchanged.
- **Tests/fixtures:** `_setup_dispatch_stub`, `_make_repos_json`, `_make_state_file`, the dispatch tests, and `main()` in `test-pulse-wrapper-worker-count.sh`.
- **Schemas/config:** N/A because the verified `_triage_prompt_metadata_is_valid` search found no external schema; the pipe-delimited contract is local to prompt construction and dispatch.
- **Generated/deployed mirrors:** N/A because `.agents/scripts/tests/test-pulse-wrapper-worker-count.sh` is repository-only test code and no deployed script is edited.
- **Migrations/backfills:** N/A because the existing `_build_triage_review_prompt` result format remains unchanged and no persisted data is rewritten.
- **Cleanup/rollback paths:** assert `_triage_cleanup_sensitive_artifact_dir` removes the temporary prompt directory after rejection and no worker dispatch entry is written.

### Implementation Steps

1. Add a test-controlled metadata result to `_setup_dispatch_stub` while preserving its valid default used by existing tests.
2. Exercise representative invalid contracts: unknown item kind; issue metadata carrying a PR revision; malformed snapshot/public hashes; malformed PR revision; and a PR head SHA that disagrees with the public revision.
3. For each representative class, invoke `dispatch_triage_reviews` with one candidate and assert no worker dispatch, unchanged slot count, controlled infrastructure-retry evidence, and prompt-artifact cleanup.
4. Keep the production validator unchanged unless a failing case proves its current behavior differs from the contract.

### Hazards and Compatibility

- **Concurrency/atomicity:** Tests use per-case files under `TEST_ROOT`; reset logs and injected metadata between cases to prevent cross-test contamination.
- **Migration/rollback:** N/A — no persisted state or schema changes.
- **Mixed-version/backward compatibility:** Preserve the valid default stub output so all existing dispatch tests retain their current expectations.
- **Idempotency/retry:** Assert malformed metadata is classified as infrastructure retry rather than content/model failure.
- **Partial failure/recovery:** Cleanup assertions must fail if a malformed result leaves its prompt artifact behind, even when worker dispatch is correctly blocked.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-pulse-wrapper-worker-count.sh
shellcheck .agents/scripts/tests/test-pulse-wrapper-worker-count.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The focused test covers parser, validator, retry, cleanup, and slot accounting; ShellCheck covers the changed shell fixture; changed-file lint catches repository policy regressions.
- **Broad verification trigger:** Run `test-triage-security-gate.sh` only if production triage code changes; no full-repository gate is justified for test-only edits.

### Files Scope

- `.agents/scripts/tests/test-pulse-wrapper-worker-count.sh`
- `.agents/scripts/pulse-ancillary-dispatch.sh` (reference; conditional edit only if a defect is demonstrated)
- `TODO.md`
- `todo/tasks/t18180-brief.md`

## Acceptance Criteria

- [ ] Valid prompt metadata still dispatches and decrements available slots exactly as existing tests require.
- [ ] Representative malformed issue and PR metadata cannot invoke `_dispatch_triage_review_worker`, and every rejection preserves the available-slot count.
- [ ] Rejected metadata produces controlled infrastructure-retry evidence and removes the associated sensitive prompt artifact; it does not become a content/model failure.
- [ ] The focused test, ShellCheck, and changed-file lint pass; if production code changes, `test-triage-security-gate.sh` also passes.

## Context & Decisions

- Production behavior already fails closed; this is additive regression coverage, not a request to redesign the metadata protocol.
- Prefer a compact table-driven helper if it reduces repeated setup without obscuring which malformed class failed.
- Do not weaken hash or revision validation to make fixtures pass.

## Relevant Files

- `.agents/scripts/pulse-ancillary-dispatch.sh:473-533` — infrastructure retry and sensitive-artifact cleanup.
- `.agents/scripts/pulse-ancillary-dispatch.sh:2391-2413` — prompt metadata validator.
- `.agents/scripts/pulse-ancillary-dispatch.sh:2487-2510` — metadata parsing and fail-closed dispatch branch.
- `.agents/scripts/tests/test-pulse-wrapper-worker-count.sh:495-804` — existing dispatch fixture and assertions.

## Dependencies

- **Blocked by:** none
- **Blocks:** direct regression assurance for the metadata boundary introduced by PR #28735
- **External:** none

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Fixture/test implementation | 35m | Inject malformed metadata and add assertions |
| Verification | 20m | Focused test, ShellCheck, changed-file lint |
| Review/lifecycle | 5m | PR and issue completion |
| **Total** | **1h** | |
