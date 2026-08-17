<!-- aidevops:brief-schema=v2 -->

# t18293: Reject malformed GitHub login output before approval lifecycle mutation

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: no matching reusable lesson; current-session failure evidence retained below
- [x] Discovery pass: local TODO, target tests, recent commits, merged PRs, and open PRs inspected; no active duplicate found after GitHub API recovery
- [x] File refs verified: target and test directories present at `387d8adfd78b0383042539dc66be1d16cdc723ba`
- [x] Tier: `tier:standard` — bounded validation change with a focused regression fixture
- [x] Seeded draft PR decision recorded: skipped — brief-first publication was chosen instead of speculative implementation

## Origin

- **Created:** 2026-08-17
- **Session:** OpenCode interactive maintainer-review session
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** During approval recovery, `gh api user --jq '.login'` failed with HTTP 503 but emitted a JSON error body on stdout. Command substitution preserved that body and passed it to `gh issue edit --add-assignee`.

## What

Make approval lifecycle assignment fail closed unless the authenticated-user lookup command succeeds and returns exactly one syntactically valid GitHub login. Never forward command errors, JSON payloads, whitespace-separated output, control characters, or empty values to `--add-assignee`.

## Why

The current fallback expression treats any non-empty stdout as an identity even when `gh api user` exits non-zero. During a GitHub outage this converted an upstream error response into an invalid mutation argument, obscured the real failure, and left approval lifecycle state partial.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The desired fail-closed boundary is resolved, but implementation must preserve GitHub Enterprise compatibility and existing lifecycle rollback behavior.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** This task is being filed from a reviewed worker-ready brief; no speculative implementation branch was requested.
- **Status:** `not-created`
- **Freshness evidence:** Local target/test paths and recovered remote merged/open PR searches were checked on 2026-08-17 at `387d8adfd78b0383042539dc66be1d16cdc723ba`.
- **Verification run:** `UNVERIFIED — brief only`
- **Stale-assumption warning:** Re-read the login lookup and lifecycle tests after any approval-helper PR lands.

## How (Approach)

### Files to Modify

- `EDIT: .agents/scripts/approval-helper.sh:696-714` — separate command success from output validation before assignment mutation.
- `NEW: .agents/scripts/tests/test-approval-helper-login-validation.sh` — hermetic success and malformed/error-output regressions.

### Complete Write Surface

- **Callers/readers:** `_approval_apply_issue_lifecycle_updates()` consumes the authenticated login before `gh_issue_edit_safe --add-assignee`; no other caller was found in the scoped search.
- **Writers/mutation paths:** `gh_issue_edit_safe` is the protected assignee mutation; status/label/lock mutations in the same lifecycle function must retain their current ordering and rollback behavior.
- **Tests/fixtures:** New focused shell test should source `approval-helper.sh`, stub `gh`, lifecycle helpers, and mutation calls; existing `.agents/scripts/tests/test-approval-helper-rest-lock-fallback.sh` remains regression coverage.
- **Schemas/config:** N/A because scoped search found no external schema or configuration for this internal login validation.
- **Generated/deployed mirrors:** `setup.sh` later deploys `.agents/scripts/approval-helper.sh`; do not edit `~/.aidevops/agents/` directly.
- **Migrations/backfills:** N/A because the change writes no persisted format and requires no historical backfill.
- **Cleanup/rollback paths:** Revert helper and focused test together; partial lifecycle recovery remains `aidevops approve verify` followed by `aidevops approve reconcile`.

### Implementation Steps

1. Add a small helper that runs `gh api user --jq '.login // empty'`, captures stdout only when the command exits successfully, rejects multiline or non-login-shaped output, prints only the validated login, and explicitly returns `0` or `1`.
2. Replace the `gh_user=$(... || printf '')` expression in `_approval_apply_issue_lifecycle_updates()` with fail-closed helper use. On failure, emit a concise diagnostic, do not call the assignee mutation, and return failure so existing recovery remains authoritative.
3. Add hermetic cases for a valid login, non-zero command with a JSON 503 body on stdout, empty output, multiline output, and punctuation/control-character payloads. Assert invalid payloads never appear in mutation arguments and no assignee mutation occurs.
4. Run focused shell tests, ShellCheck, and changed-file lint. Preserve Bash 3.2 syntax and explicit returns in every added function.

### Hazards and Compatibility

- **Concurrency/atomicity:** Validation happens before the assignee write; it must not introduce new state or race windows.
- **Migration/rollback:** No migration; reverting restores prior lookup behavior without changing stored data.
- **Mixed-version/backward compatibility:** Accept legitimate GitHub/GitHub Enterprise login forms already handled by the repository; reject only values that cannot safely be one login argument.
- **Idempotency/retry:** A valid retry repeats existing idempotent lifecycle reconciliation; malformed output causes no new assignee write.
- **Partial failure/recovery:** Earlier status/label work may already exist when lookup fails. Preserve the current non-zero result so `verify`/`reconcile` can inspect and complete the lifecycle later.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-approval-helper-login-validation.sh
bash .agents/scripts/tests/test-approval-helper-rest-lock-fallback.sh
shellcheck .agents/scripts/approval-helper.sh .agents/scripts/tests/test-approval-helper-login-validation.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The focused test proves valid forwarding and malformed-output rejection; REST-lock coverage proves lifecycle recovery is preserved; ShellCheck/lint cover Bash portability and repository policy.
- **Broad verification trigger:** Not required unless implementation changes shared GitHub wrappers outside the declared scope.

### Safety-Stop Recovery

- **Original objective:** Prevent malformed GitHub identity output from becoming an assignee mutation.
- **Preserved user directions:** Solve this independently from batch outage circuit-breaking.
- **Trigger and evidence:** Historical HTTP 503 outage recovered before issue publication; no active safety stop.
- **Completed and verified:** Worker-ready local brief and scoped implementation contract.
- **Remaining acceptance criteria:** Implementation, focused tests, PR, and review.
- **Unsafe route not to repeat:** Retry approval writes while failed `gh` stdout is treated as trusted identity data.
- **Next safe route:** Dispatch from the published issue after this planning snapshot reaches the default branch.
- **Resume condition:** Task is published and the default-branch planning snapshot makes it dispatch-eligible.
- **Owner and status:** unassigned; `not-triggered`

### Files Scope

- `.agents/scripts/approval-helper.sh`
- `.agents/scripts/tests/test-approval-helper-login-validation.sh`

## Acceptance Criteria

- [ ] A successful authenticated-user lookup returning one valid login passes exactly that login to the existing assignee mutation.
- [ ] A failed lookup that emits a GitHub HTTP 503 JSON body on stdout returns non-zero and performs no assignee mutation.
- [ ] Empty, multiline, whitespace-bearing, JSON, option-like, and control-character outputs cannot reach `--add-assignee`.
- [ ] Existing lifecycle lock fallback and `verify`/`reconcile` recovery semantics remain unchanged.
- [ ] Focused tests, ShellCheck, and changed-file lint pass.

## Context & Decisions

- Validate both process exit status and output shape; checking non-empty output alone is insufficient.
- Keep the validation inside approval-helper rather than weakening `gh_issue_edit_safe` globally without evidence that other callers share this contract.
- Do not log the untrusted payload; diagnostics should identify lookup/validation failure without replaying arbitrary response content.
- Remote merged/open PR collision checks completed after API recovery; no active duplicate was found.

## Relevant Files

- `.agents/scripts/approval-helper.sh:696-714` — vulnerable authenticated-login lookup and assignee mutation.
- `.agents/scripts/tests/test-approval-helper-rest-lock-fallback.sh:89-227` — lifecycle stubbing and failure assertions to follow.
- `.agents/scripts/approval-helper.sh:152-186` — existing API probe pattern and explicit status handling.

## Dependencies

- **Blocked by:** none.
- **Blocks:** t18294 is sequenced after this task to avoid concurrent edits to `approval-helper.sh`.
- **External:** GitHub API for issue/PR lifecycle only; implementation tests must be hermetic.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Research/read | 20m | Re-read current lifecycle and login conventions |
| Implementation | 45m | Helper and fail-closed integration |
| Testing | 45m | Malformed/error output matrix and regressions |
| Publication/review | 10m | Publish the verified brief and review the implementation |
| **Total** | **~2h** | |
