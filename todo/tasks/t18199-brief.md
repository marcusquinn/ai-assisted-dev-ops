<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18199: Make issue sync recover from split REST and GraphQL availability

## Pre-flight

- [x] Memory recall: `issue-sync gh auth status REST GraphQL repository identity immutable mapping relationship retryable post-create recovery` → 0 cross-session hits; the current session recovery evidence is recorded in `todo/missions/m-20260804-5d06b1/mission.md`.
- [x] Discovery pass: exact issue-sync searches found no matching open issue or PR. Closed #29149, #28499, and #28945 plus commits `671ed7120`, `11f2cd5fc`, and `e8818ea8d` are adjacent precedents, not complete fixes for this failure chain.
- [x] File refs verified: the active worktree is 16 commits behind current `main`, but the three production files and principal tests cited below are identical across those refs; current-main function boundaries were checked before drafting.
- [x] Tier: `tier:standard` — the trust decision, fallback order, fail-closed cases, write ordering, retry semantics, files, and regression matrix are explicit below.
- [x] Seeded draft PR decision recorded: skipped — a partial auth-only or mapping-only patch would still leave post-create finalisation unsafe or falsely complete.

## Origin

- **Created:** 2026-08-04
- **Session:** OpenCode interactive mission-planning session `m-20260804-5d06b1`
- **Created by:** ai-interactive
- **Parent task:** none; this is a same-session framework reliability finding
- **Blocked by:** none
- **Conversation context:** Creating #29506 succeeded, but `gh auth status` and the REST repository-identity probe failed while direct authenticated GraphQL identity and quota queries remained healthy. Immutable mapping validation then failed, and relationship reconciliation reported success with zero backend calls until the mapping and native edge were recovered manually.

## What

Make issue-sync authentication, immutable repository mapping, and relationship
reconciliation tolerate split GitHub REST/GraphQL availability without weakening
write-target validation. A working authenticated capability must prevent a false
"not authenticated" rejection; either validated repository-ID transport may
establish the immutable mapping; and unresolved dependency mappings must remain
retryable instead of being counted complete.

The change must preserve the coordinator as mapping authority, exact repository
and issue identity checks, post-create write ordering, shared rate-limit state,
bounded request budgets, and fail-closed behavior when neither transport can
prove identity.

## Why

GitHub REST and GraphQL have independent endpoint behavior and quota pressure.
Treating `gh auth status` or one REST metadata endpoint as the sole proof of API
capability can strand an issue after creation: the public tracker exists, but
the local immutable mapping, labels, assignment/lock, and native dependency
finalisation do not. Worse, a declared dependency whose mapping cannot resolve
currently produces no retry token, so bulk reconciliation can report the task
complete with zero backend calls. That hides unfinished safety work and can
leave an auto-dispatch issue incorrectly available.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** This is a bounded shell reliability fix across three known
functions and focused stubbed tests. No product/API design, credential changes,
schema migration, or live GitHub integration test is required.

## PR Conventions

This is a leaf reliability task. Use `Resolves #<issue>` in the PR body. Do not
close or modify mission issues #29494, #29495, #29501, #29502, or #29506. Do not
change GitHub account state, refresh credentials, bypass shared cooldowns, or
make live issue writes during tests.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Auth capability, immutable repository identity, and retry accounting must land together to reproduce and close the observed post-create gap.
- **Status:** `not-created`
- **Freshness evidence:** Current `main`, target-file history, adjacent closed work, exact issue/PR searches, and the live #29506 recovery evidence were reviewed on 2026-08-04.
- **Verification run:** Unrun before implementation; all required tests are stubbed and listed below.
- **Stale-assumption warning:** Re-check `issue-sync-helper.sh`, `issue-sync-lib-ref.sh`, and `issue-sync-relationships.sh` plus #29149/#28499/#28945-derived behavior if any issue-sync or shared GitHub wrapper change lands first.

## How (Approach)

### Progressive Context Plan

- **Read first:** `issue-sync-helper.sh:135-145`, `issue-sync-lib-ref.sh:219-301`, and `issue-sync-relationships.sh:861-903,1190-1251`.
- **Then load:** `framework-issue-helper.sh:294-317` for the existing API-capability fallback and `issue-sync-lib-ref.sh:304-358` for response-owned GraphQL cost validation.
- **Load only if:** coordinator binding semantics are unclear — `task-coordinator.mjs` `bind-issue`/`resolve-issue`; shared cooldown routing changes are needed — `shared-gh-wrappers.sh` and `shared-gh-secondary-cooldown.sh`.
- **Why:** keep the fix inside issue-sync unless a focused regression proves the shared wrapper contract itself is wrong.
- **Stop when:** API-only auth, dual repository-ID resolution, post-create validation, unresolved-mapping retry, genuine no-op, and total-outage cases all pass without live GitHub access.

### Worker Quick-Start

```text
1. Reproduce each branch with gh/_gh_with_timeout stubs; never depend on the developer's live credentials or quota.
2. Accept gh auth status, an explicit token environment, or a successful authenticated viewer-capability probe; fail only when no accepted capability works.
3. Resolve repository identity through one bounded GraphQL/REST strategy that validates exact owner/name and a non-empty node ID; either transport may recover the other.
4. Keep the coordinator authoritative and require the resolved issue number to equal the intended write target before any assignment, lock, label, body, or relationship write.
5. When a task declares blocked-by/blocks but its mapping cannot resolve, emit RELS:0 RETRYABLE:1, preserve it in the pending workset, and return non-zero from reconciliation.
6. Keep tasks with no declared relationship metadata as successful no-ops; zero backend calls alone is neither success nor failure evidence.
7. Do not bypass cooldowns, print tokens/raw API bodies, add retries without a deadline, or weaken fail-closed mapping checks.
```

### Files to Modify

- `.agents/scripts/issue-sync-helper.sh` — make `verify_gh_cli()` probe authenticated API capability after stale/failed keyring status before declaring auth unavailable.
- `.agents/scripts/issue-sync-lib-ref.sh` — add bounded dual-transport repository-node-ID resolution and reuse it in `resolve_task_gh_number()`.
- `.agents/scripts/issue-sync-relationships.sh` — classify declared dependency mapping failures as retryable and make bulk fallback use the canonical retry result.
- `NEW: .agents/scripts/tests/test-issue-sync-auth-capability.sh` — API-only, keyring-only, explicit-token, and total-auth-failure matrix.
- `.agents/scripts/tests/test-issue-mapping-isolation.sh` — GraphQL/REST repository identity fallback, malformed identity, and total-outage mapping cases.
- `.agents/scripts/tests/test-issue-sync-push-failures.sh` — post-create mapping validation/write-order regression when only one metadata transport works.
- `.agents/scripts/tests/test-issue-sync-relationship-deadline.sh` — direct unresolved-mapping outcome and sanitized retry classification.
- `.agents/scripts/tests/test-issue-sync-relationship-resume.sh` — bulk `complete=0/1`, pending-state, and zero-backend-call retry telemetry.

### Complete Write Surface

- **Callers/readers:** `push`, `enrich`, `pull`, `reconcile`, and `relationships` enter through `_init_cmd()`/`verify_gh_cli()`; mapping consumers call `resolve_task_gh_number()` or `require_task_issue_mapping()`; post-create and relationship paths depend on both.
- **Writers/mutation paths:** Issue creation remains unchanged. After creation, TODO `ref:GH`, coordinator `bind-issue`, assignment/lock/tier/status writes, and native relationship mutations must remain behind exact immutable mapping validation. The fix adds no new write type.
- **Tests/fixtures:** `NEW: .agents/scripts/tests/test-issue-sync-auth-capability.sh` plus changes to `.agents/scripts/tests/test-issue-mapping-isolation.sh`, `.agents/scripts/tests/test-issue-sync-push-failures.sh`, `.agents/scripts/tests/test-issue-sync-relationship-deadline.sh`, and `.agents/scripts/tests/test-issue-sync-relationship-resume.sh` model independent auth-status, REST, GraphQL, coordinator, post-create, and relationship outcomes. No network, real token, repository mutation, or live GitHub fixture is permitted.
- **Schemas/config:** Not applicable because the fix changes runtime routing and retry classification only. Do not modify task-coordinator schemas, `.agents/configs/pulse-rate-limit.conf`, credential configuration, or repository settings.
- **Generated/deployed mirrors:** Tracked `.agents/scripts/` files deploy through existing setup behavior. No generated runtime mirror or checked-in test output changes.
- **Migrations/backfills:** Not applicable because existing coordinator mappings and TODO `ref:GH` projections retain their schema and identity; unresolved historical records are retried through the existing `.agents/scripts/issue-sync-helper.sh relationships` reconciliation path.
- **Cleanup/rollback paths:** Reverting `.agents/scripts/issue-sync-helper.sh`, `.agents/scripts/issue-sync-lib-ref.sh`, `.agents/scripts/issue-sync-relationships.sh`, `NEW: .agents/scripts/tests/test-issue-sync-auth-capability.sh`, and the four modified `test-issue-*` files removes the additive fallback/retry behavior. No remote issue, coordinator schema, or repository data cleanup is required.

### Implementation Steps

1. Extend `verify_gh_cli()` with the proven `viewer.login` capability fallback used by `framework-issue-helper.sh`, while preserving the explicit `GH_TOKEN`/`GITHUB_TOKEN` fast path and a true-offline failure.
2. Add one repository-node-ID resolver in `issue-sync-lib-ref.sh`. Parse and validate `owner/repo`, use bounded `_gh_with_timeout` calls, accept only a non-empty node ID from an authenticated response, and validate GraphQL through response-owned `rateLimit.cost` rather than assumed cost.
3. Support both availability splits: GraphQL healthy/REST unavailable and REST healthy/GraphQL unavailable. Do not let malformed, partial, wrong-repository, or cost-less responses establish identity.
4. Route `resolve_task_gh_number()` through the resolver before coordinator lookup/backfill. Preserve exact repository slug refresh, issue ID/number checks, state cursor, and sync metadata.
5. Preserve `_push_create_issue()` and `_push_finalize_task_creation()` ordering: issue ref may be recorded for recovery, but assignment, lock, labels, body enrichment, and relationships stay behind `require_task_issue_mapping()`.
6. In `_sync_blocked_by_for_task()`, distinguish a task with no declared relationships from a task whose declared dependency mapping is unresolved. Record failed resolution and return `RELS:0 RETRYABLE:1` for the latter.
7. Replace the bulk command's bare `RELS:0` error fallback with the canonical retry result so helper errors cannot increment `complete` or delete pending resume state.
8. Add the auth, transport-split, malformed/total-outage, post-create ordering, direct retry, bulk pending, and genuine no-op regressions listed in the acceptance criteria.
9. Run focused tests, ShellCheck/format checks through the changed-file linter, and inspect output to ensure no token or raw error payload is emitted.

### Hazards and Compatibility

- **Concurrency/atomicity:** Issue creation can succeed while metadata reads fail. Recovery must reuse the exact task-title/ref and coordinator identity; never create a second issue merely because finalisation is pending.
- **Migration/rollback:** No schema changes. Existing mappings remain valid, and rollback is code-only.
- **Mixed-version/backward compatibility:** Older TODO refs and coordinator records continue to resolve. Callers still receive an issue number or failure; relationship command exit semantics become stricter only for genuinely unfinished declared edges.
- **Idempotency/retry:** Repository identity reads are bounded and side-effect free. Retrying post-create finalisation reuses the existing issue and native relationship idempotence checks. Pending state persists until proof of completion.
- **Partial failure/recovery:** If one transport works, continue through exact validation. If both fail, preserve the TODO ref/mapping recovery evidence, skip post-create writes, retain relationship work as pending, and emit a sanitized rerun path.
- **Security/privacy:** Never print tokens, auth output, raw API bodies, private paths, or credential-source details. A successful capability probe proves API access, not maintainer authority; existing write authorization remains unchanged.
- **Rate limits:** Do not add loops or bypass the shared cooldown. Use one bounded path per transport and existing timeout/deadline accounting.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-issue-sync-auth-capability.sh
bash .agents/scripts/tests/test-issue-mapping-isolation.sh
bash .agents/scripts/tests/test-issue-sync-push-failures.sh
bash .agents/scripts/tests/test-issue-sync-relationship-deadline.sh
bash .agents/scripts/tests/test-issue-sync-relationship-resume.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Auth tests cover preflight; mapping isolation and push-failure tests cover immutable identity/post-create ordering; relationship tests cover direct and bulk retry semantics; changed-file lint covers ShellCheck, formatting, secrets, and repository ratchets.
- **Broad verification trigger:** Run the full issue-sync test family only if shared GitHub wrappers, coordinator storage, or common cooldown logic must change beyond the declared files.

### Recoverability Checkpoint

- [ ] Focused auth and mapping tests pass before relationship edits.
- [ ] WIP commit created after the first coherent green slice: `wip: recover issue sync identity probes`.
- [ ] Relationship retry tests pass before changed-file lint.
- [ ] If a shared wrapper change becomes necessary, stop, document the new write surface, and run the full issue-sync/shared-wrapper regression family.

### Safety-Stop Recovery

- **Original objective:** Make issue sync finish or durably defer post-create work when REST and GraphQL availability diverge.
- **Preserved user directions:** Create one reusable worker-ready fix issue and report the next mission sequence.
- **Trigger and evidence:** #29506 creation succeeded while auth/repository mapping checks failed; direct GraphQL proved exact identities and healthy quota; relationship sync reported complete with zero backend calls.
- **Completed and verified:** Premise, current-main code paths, adjacent prior fixes, exact files, and regression matrix are captured here.
- **Remaining acceptance criteria:** Implement every positive, negative, ordering, and retry test below.
- **Unsafe route not to repeat:** Do not refresh credentials, bypass cooldowns, create a duplicate issue, manually trust display numbers, or treat zero calls as completion.
- **Next safe route:** Stub both transports, implement bounded capability/identity fallback, retain failed declared edges as pending, then verify write ordering.
- **Resume condition:** No overlapping issue-sync/shared-wrapper PR changes these functions; otherwise rebase assumptions and rerun discovery.
- **Owner and status:** Assigned implementation worker; ready

### Files Scope

- `.agents/scripts/issue-sync-helper.sh`
- `.agents/scripts/issue-sync-lib-ref.sh`
- `.agents/scripts/issue-sync-relationships.sh`
- `.agents/scripts/tests/test-issue-sync-auth-capability.sh`
- `.agents/scripts/tests/test-issue-mapping-isolation.sh`
- `.agents/scripts/tests/test-issue-sync-push-failures.sh`
- `.agents/scripts/tests/test-issue-sync-relationship-deadline.sh`
- `.agents/scripts/tests/test-issue-sync-relationship-resume.sh`

## Acceptance Criteria

- [ ] `verify_gh_cli()` accepts explicit token environments, healthy `gh auth status`, or failed auth status plus a successful authenticated GraphQL viewer probe; it rejects when no accepted probe succeeds.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-issue-sync-auth-capability.sh"
  ```

- [ ] Repository identity resolves with GraphQL healthy/REST unavailable and REST healthy/GraphQL unavailable, while malformed, wrong, missing-cost, and total-outage responses fail closed.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-issue-mapping-isolation.sh"
  ```

- [ ] A successfully created issue can establish its exact coordinator mapping through either valid repository-ID transport before assignment, locking, labelling, enrichment, or relationship writes; failed identity proof leaves those writes untouched.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-issue-sync-push-failures.sh"
  ```

- [ ] A task that declares `blocked-by:` or `blocks:` but cannot resolve its own immutable issue mapping records failed resolution and emits `RELS:0 RETRYABLE:1` without a native mutation.

  ```yaml
  verify:
    method: codebase
    pattern: "RETRYABLE:1|failed.resolution|mapping.*unresolved"
    path: ".agents/scripts/tests/test-issue-sync-relationship-deadline.sh"
  ```

- [ ] Bulk relationship reconciliation counts an unresolved declared dependency as `complete=0/1`, retains it in pending resume state, returns non-zero, and never presents zero backend calls as proof of success.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-issue-sync-relationship-resume.sh"
  ```

- [ ] A task with no `blocked-by:`, `blocks:`, parent, or sub-issue metadata remains a successful no-op, and already-resolved mappings/relationships preserve current idempotent behavior.

  ```yaml
  verify:
    method: codebase
    pattern: "no.*relationship|RELS:0 RETRYABLE:0|already.present|single.pass"
    path: ".agents/scripts/tests/test-issue-sync-relationship-deadline.sh"
  ```

- [ ] Auth, rate-limit, mapping, and GraphQL failures emit only sanitized classifications/recovery guidance; test output contains no token or raw API payload.

  ```yaml
  verify:
    method: codebase
    pattern: "SECRET_PAYLOAD|raw.*payload|sanit|cannot authenticate|Recovery: rerun"
    path: ".agents/scripts/tests/test-issue-sync-relationship-deadline.sh"
    expect: present
  ```

- [ ] Changed-file ShellCheck, formatting, secret, portability, complexity, and regression gates pass without suppressing violations.

  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/linters-local.sh --changed"
  ```

## Context & Decisions

- This is one failure chain, not three independent features: preflight capability decides whether sync starts, repository identity decides whether the created issue can be bound, and retry accounting decides whether unfinished finalisation remains visible.
- Capability fallback does not grant write authority. Existing repository/issue identity, collaborator, origin, signature, and command-policy gates remain authoritative.
- Repository node identity is immutable and provider-owned; display numbers or local task text alone never authorize mutation.
- Zero backend calls are valid for a relationship-free task but cannot prove completion when declared relationship work could not resolve its target.
- The fix should stay local to issue-sync. Shared cooldown behavior is out of scope unless a focused test proves no local bounded transport strategy can satisfy the observed split-availability case.

## Relevant Files

- `.agents/scripts/issue-sync-helper.sh:135-145` — current keyring-only auth check after explicit-token fast path.
- `.agents/scripts/framework-issue-helper.sh:294-317` — established `viewer.login` capability fallback pattern.
- `.agents/scripts/issue-sync-lib-ref.sh:219-301` — REST-only repository identity, coordinator lookup/backfill, and exact write-target gate.
- `.agents/scripts/issue-sync-lib-ref.sh:304-358` — response-owned-cost GraphQL node/relationship read precedent.
- `.agents/scripts/issue-sync-helper.sh:196-227` and `.agents/scripts/issue-sync-helper-push.sh:135-220` — post-create mapping validation and write ordering.
- `.agents/scripts/issue-sync-relationships.sh:861-903` — silent declared-dependency mapping skip versus node-ID retry handling.
- `.agents/scripts/issue-sync-relationships.sh:1190-1251` — bulk fallback, completion count, pending state, backend telemetry, and exit result.
- `.agents/scripts/tests/test-framework-issue-helper.sh:62-88,215-220` — stale keyring/working API stub precedent.
- `.agents/scripts/tests/test-issue-mapping-isolation.sh:30-115` — repository-scoped mapping and fail-closed fixtures.
- `.agents/scripts/tests/test-issue-sync-push-failures.sh:66-101` — post-create mapping-before-write regression.
- `.agents/scripts/tests/test-issue-sync-relationship-deadline.sh:105-204` — retry outcome/sanitization and nested relationship scope.
- `.agents/scripts/tests/test-issue-sync-relationship-resume.sh:81-135` — completion, pending resume, invalidation, and backend telemetry.

## Dependencies

- **Blocked by:** none.
- **Related prior work:** #29149 / PR #29161 added API-only interactive-session auth recovery; #28499 distinguished relationship outcomes; #28945 added relationship resume/completion telemetry. Reuse their patterns without reopening or modifying them.
- **Blocks:** Reliable issue/relationship creation for any task whose GitHub REST and GraphQL availability diverges; no mission feature dependency is added.
- **External:** GitHub CLI behavior is stubbed. No installed dependency version or third-party symbol mapping changes.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Auth capability fallback | 35m | Function plus isolated matrix |
| Repository identity resolver | 1h 10m | Dual transport, parsing, fail-closed fixtures |
| Post-create ordering regression | 35m | Existing push-failure harness |
| Relationship retry semantics | 55m | Direct and bulk pending behavior |
| Focused verification/review | 45m | Shell tests, lint, regression inspection |
| **Total** | **4h** | |

## Brief Workflow

This issue body is composed under `.agents/workflows/brief.md`. Newly queued
auto-dispatch work must pass the brief schema-v2 readiness contract: complete
write surface, hazards and compatibility, executable surface-mapped checks,
positive behavior, negative/fail-closed behavior, and regression coverage.
