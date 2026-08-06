<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18206: Prevent bodyless parent snapshots from closing incomplete trackers

## Pre-flight

- [x] Memory recall: `parent tracker bodyless snapshot premature close incomplete contract` → 0 hits — no reusable stored lesson found.
- [x] Discovery pass: prior merged fixes #19762, #20703, and #27005 establish scoped child parsing and close contracts; no open PR repairs the canonical snapshot/body integration gap reproduced by #29541.
- [x] File refs verified: 14 prefetch producer, snapshot consumer, parent mutation, scheduler, test, issue, and mission references checked at `52773f5a9`.
- [x] Tier: `tier:standard` — the data-loss path and fail-closed repair are decided; implementation requires coordinated cache/live-boundary tests without a new product or authority decision.
- [x] Seeded draft PR decision recorded: skipped — the failing fixture, cache projection, live mutation boundary, and active scheduler repair must land together.

## Origin

- **Created:** 2026-08-06
- **Session:** OpenCode interactive mission recovery `m-20260804-5d06b1`
- **Created by:** ai-interactive under maintainer direction
- **Parent task:** none; this is a systemic framework defect discovered while recovering #29541
- **Blocked by:** none
- **Conversation context:** Pulse closed parent #29541 after seeing its three terminal native children even though the live body retained unchecked acceptance criteria and two unfiled features. The closure comment and source trace prove the canonical issue snapshot omitted `body`, while the final mutation guard re-read labels but discarded the live body.

## What

Make canonical issue snapshots carry complete multiline bodies through both
owner-search and REST-fallback transports, reject otherwise-complete snapshots
whose issue rows lack a string body, and revalidate the live parent body at the
final close mutation boundary. Ensure the active single-pass scheduler can
boundedly reopen a recently closed parent when deterministic live close-contract
evidence proves the closure premature.

The fix must preserve cache efficiency, trust metadata, scoped child parsing,
legacy parent compatibility, GraphQL pagination safety, and normal automatic
closure for genuinely complete parents.

## Why

The active reconciler documents and consumes `body`, but the canonical snapshot
producer omits it. Missing bodies become empty strings, which intentionally mean
"legacy contract unknown" and allow closure. A terminal native child graph can
therefore silently drop unfiled roadmap work and unchecked acceptance criteria.
Existing live mutation checks validate labels only, and the existing recently
closed repair lives in a legacy function that production no longer schedules.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The repair is bounded and reversible with exact behavioral
evidence. It spans transport, validation, mutation, and scheduler seams, so it
requires multi-file implementation judgment rather than a literal simple edit.

## PR Conventions

This is a standalone leaf defect. Its implementation PR uses a closing keyword
for #29645 and `For #29541` as incident evidence; it must not close the
Milestone 2 parent.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** A partial producer-only change would leave stale/live races and closed-parent recovery unresolved.
- **Status:** `not-created`
- **Freshness evidence:** Live #29541 body, closure comment, native child graph, canonical prefetch projection, active single-pass wiring, and prior parent-close fixes were checked on 2026-08-06.
- **Verification run:** After the second independent-review remediation, the four focused suites pass 27, 17, 43, and 29 tests. ShellCheck passes; changed-file lint and Qlty regression `46 -> 46` passed on the prior exact head and remain required again for the final head.
- **Stale-assumption warning:** Re-run discovery if prefetch projection, parent mutation, or single-pass scheduler files advance before coding.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/pulse-batch-prefetch-helper.sh:125-175,261-339,480-535,884-943` and `.agents/scripts/pulse-prefetch-infra.sh:184-288`.
- **Then load:** `.agents/scripts/pulse-issue-reconcile-actions.sh:345-585,1134-1250` and `.agents/scripts/pulse-issue-reconcile.sh:1369-1415`.
- **Load only if:** scheduler repair needs context — `.agents/scripts/pulse-issue-reconcile-parent.sh:298-399` and `.agents/scripts/tests/test-pulse-issue-reconcile.sh:437-470`.
- **Why:** repair the exact cache-to-close path without widening parent parsing or GitHub mutation authority.
- **Stop when:** both transports preserve bodies, incomplete/malformed snapshots fail closed, live body drift blocks closure, recent premature closures are reachable from the active pass, and complete parents still close.

### Worker Quick-Start

1. Add `body` to both canonical issue projection constants and both transport payloads.
2. Preserve multiline body bytes as a JSON string; do not truncate, hash, summarize, or move it to argv.
3. Require every canonical issue item to have a string `body`; old projections become incompatible and refresh naturally.
4. At the final parent mutation boundary, use the fresh REST issue object to validate state/labels and rerun the close-contract predicate against its live body.
5. A live read failure, missing/non-string body, unchecked criterion, keep-open marker, unfiled phase, or insufficient expected-child count blocks closure.
6. Keep legacy complete parents closable when their live body genuinely has no deterministic incomplete contract.
7. Make recently closed repair reachable from the active production single pass with a bounded query/cap and idempotent repair marker.
8. Add behavioral fixtures for the #29541 shape and a body-change race; do not contact live issues in tests.

### Files to Modify

- EDIT: `.agents/scripts/pulse-batch-prefetch-helper.sh` — add body to issue projections, REST rows, search fields, and normalized rows.
- EDIT: `.agents/scripts/pulse-prefetch-infra.sh` — require the body-bearing projection and a string body on every canonical issue item.
- EDIT: `.agents/scripts/pulse-issue-reconcile-actions.sh` — expose the fresh parent object and validate its live body immediately before close.
- EDIT: `.agents/scripts/pulse-issue-reconcile.sh` and, if needed, `.agents/scripts/pulse-issue-reconcile-parent.sh` — make bounded recently-closed repair reachable from the active single pass without restoring duplicate legacy stages.
- EDIT: `.agents/scripts/tests/test-pulse-batch-prefetch-conditional-rest.sh` — prove REST and owner-search body preservation.
- EDIT: `.agents/scripts/tests/test-pulse-prefetch-canonical-snapshot.sh` — prove bodyless snapshots are incompatible.
- EDIT: `.agents/scripts/tests/test-pulse-reconcile-parent-task-subissue-graph.sh` — prove cached/live body drift and live-read failure cannot close.
- EDIT: `.agents/scripts/tests/test-pulse-issue-reconcile.sh` — prove active scheduler reachability and preserve single-pass-only orchestration.
- EDIT: `TODO.md`, `todo/tasks/t18206-brief.md`, and mission recovery evidence — durable incident/task record.

### Complete Write Surface

- **Callers/readers:** `pulse-prefetch.sh` and `pulse-prefetch-infra.sh` consume canonical envelopes; `reconcile_issues_single_pass` consumes cached rows; `_action_cpt_single` and `_try_close_parent_tracker` decide parent mutations; Pulse dispatch preflight schedules only the single pass.
- **Writers/mutation paths:** prefetch writes versioned local JSON envelopes atomically; parent reconciliation may comment, label, reopen, or close only after fresh managed-issue evidence. No repository content, child issue, or implementation state is deleted.
- **Tests/fixtures:** `.agents/scripts/tests/test-pulse-batch-prefetch-conditional-rest.sh` and the parent reconciliation fixtures stub both REST/search payloads and live GitHub issue reads; multiline bodies, absent bodies, incomplete criteria, keep-open markers, live drift, API failure, and complete contracts receive deterministic assertions.
- **Schemas/config:** `.agents/scripts/pulse-prefetch-infra.sh` keeps the snapshot schema identifier at v1, but the exact projection string changes and invalidates old envelopes by design. No user configuration changes.
- **Generated/deployed mirrors:** tracked `.agents/scripts/` sources deploy through setup; do not edit deployed `~/.aidevops/agents/` files.
- **Migrations/backfills:** `.agents/scripts/pulse-prefetch-infra.sh` requires no manual migration; projection mismatch makes old caches miss and refill. Recently closed repair scans only its existing bounded window.
- **Cleanup/rollback paths:** revert `.agents/scripts/pulse-batch-prefetch-helper.sh` and the reconciliation changes to restore prior behavior; local cache envelopes refresh automatically. Reopened parents retain public audit comments and must never be silently reclosed without a complete live contract.

### Implementation Steps

1. Extend issue projection constants in producer and consumer with `body` in one canonical order.
2. Include `.body // ""` in REST and search normalization, preserving valid multiline strings and explicit empty issue bodies.
3. Tighten canonical pair validation so every issue row has a string body; add body-bearing fixture data and a missing-body rejection.
4. Refactor parent close-contract reporting into a bounded helper reusable for cached and live checks without growing `_try_close_parent_tracker` past the complexity threshold.
5. Have the live mutation guard retain the exact issue JSON only after repository issue identity, parent label, state, and protected-label checks pass.
6. Immediately before `gh issue close`, extract a string live body and rerun the contract helper using the verified child count. Fail closed on any read/extraction ambiguity.
7. Thread the existing bounded recently-closed parent query/repair through the active single pass, deduplicating issue rows and preserving per-repo/time caps.
8. Add regressions for REST/search bodies, bodyless snapshot rejection, cached-complete/live-incomplete drift, live-read failure, idempotent reopen, and normal complete-parent closure.
9. Run focused tests, ShellCheck, changed-file lint, and Qlty regression before exact-head review.

### Hazards and Compatibility

- **Concurrency/atomicity:** Body can change after cache creation. The final fresh body check is the compare-before-mutate guard; no cached body may authorize closure by itself.
- **Migration/rollback:** Projection mismatch invalidates old cache envelopes; the next refresh repopulates them. Rollback may reintroduce premature-close risk but requires no data transform.
- **Mixed-version/backward compatibility:** Old producers and new consumers miss safely because projections differ. New producers include body for old consumers, but deployment should keep producer/consumer files in one atomic framework bundle.
- **Idempotency/retry:** Cache writes remain atomic; reopen/comment markers deduplicate repair; repeated complete-parent checks produce at most the existing close transition.
- **Partial failure/recovery:** Search/REST/live API failures, malformed JSON, missing body, pagination ambiguity, or protected labels perform no close. Pulse retries from fresh evidence on a later cycle.

### Complexity Impact

- **Target functions:** `_prefetch_rest_issues_for_slug`, `_normalize_search_to_prefetch_schema`, `_try_close_parent_tracker`, `_pir_parent_mutation_is_allowed`, and `reconcile_issues_single_pass`.
- **Current risk:** `_try_close_parent_tracker` is near the shell function-size threshold.
- **Estimated growth:** under 15 lines in existing functions plus one small close-contract helper and one bounded closed-parent collection helper.
- **Action required:** keep transport projection edits literal and move duplicated cached/live close-contract handling into a named helper.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-pulse-batch-prefetch-conditional-rest.sh
bash .agents/scripts/tests/test-pulse-prefetch-canonical-snapshot.sh
bash .agents/scripts/tests/test-pulse-reconcile-parent-task-subissue-graph.sh
bash .agents/scripts/tests/test-pulse-issue-reconcile.sh
shellcheck .agents/scripts/pulse-batch-prefetch-helper.sh .agents/scripts/pulse-prefetch-infra.sh .agents/scripts/pulse-issue-reconcile-actions.sh .agents/scripts/pulse-issue-reconcile.sh .agents/scripts/pulse-issue-reconcile-parent.sh
.agents/scripts/qlty-regression-helper.sh --base origin/main --head HEAD
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** prefetch tests prove both producers and envelope compatibility; parent tests prove stale/live races, closure, and repair; single-pass tests prove production reachability; ShellCheck and changed lint cover Bash 3.2, complexity, formatting, privacy, and secret rules.
- **Broad verification trigger:** required because canonical issue snapshots and parent lifecycle are cross-repository Pulse infrastructure. Run all four focused suites plus changed-file quality gates.

### Recoverability Checkpoint

- [x] Focused tests pass.
- [x] WIP commit created before broad gates: `wip: fail closed on bodyless parent snapshots`.
- [ ] Broad verification passed; exact-head review evidence remains pending.

### Safety-Stop Recovery

- **Original objective:** Prevent incomplete parent objectives from closing when canonical caches omit or stale their bodies.
- **Preserved user directions:** Recover mission #29541, retain all unfiled work, continue through the no-release full loop, and do not weaken child/authority gates.
- **Trigger and evidence:** triggered by #29541 closure at 2026-08-06T06:16:57Z; closure comment listed three closed children while the live body retained unchecked criteria and F2.4/F2.5.
- **Completed and verified:** root cause, exact producer/consumer/mutation/scheduler paths, implementation, focused/broad tests, parent reopen, and live F2.4/F2.5 relationships.
- **Remaining acceptance criteria:** exact-head review and the issue/PR merge lifecycle for #29645.
- **Unsafe route not to repeat:** Do not treat absent body as a complete live contract, rely only on cached labels/body, restore unscoped body regexes, or run duplicate legacy lifecycle passes.
- **Next safe route:** propagate body through canonical snapshots and rerun the deterministic close predicate on a fresh issue object immediately before mutation.
- **Resume condition:** target source still matches the diagnosed projection and single-pass wiring; no overlapping PR exists.
- **Owner and status:** interactive mission session; active.

### Files Scope

- `.agents/scripts/pulse-batch-prefetch-helper.sh`
- `.agents/scripts/pulse-prefetch-infra.sh`
- `.agents/scripts/pulse-issue-reconcile-actions.sh`
- `.agents/scripts/pulse-issue-reconcile.sh`
- `.agents/scripts/pulse-issue-reconcile-parent.sh`
- `.agents/scripts/tests/test-pulse-batch-prefetch-conditional-rest.sh`
- `.agents/scripts/tests/test-pulse-prefetch-canonical-snapshot.sh`
- `.agents/scripts/tests/test-pulse-reconcile-parent-task-subissue-graph.sh`
- `.agents/scripts/tests/test-pulse-issue-reconcile.sh`
- `TODO.md`
- `todo/tasks/t18206-brief.md`
- `todo/missions/m-20260804-5d06b1/mission.md`

## Acceptance Criteria

- [x] Canonical REST and owner-search issue snapshots round-trip exact multiline body strings through the versioned envelope.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-batch-prefetch-conditional-rest.sh"
  ```

- [x] A bodyless issue row cannot form a complete canonical snapshot pair.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-batch-prefetch-conditional-rest.sh && bash .agents/scripts/tests/test-pulse-prefetch-canonical-snapshot.sh"
  ```

- [x] A cached complete/empty body cannot close a parent whose fresh live body has unchecked criteria, a keep-open marker, an unfiled phase, or an unmet expected-child count; live read/body ambiguity also performs no close.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-reconcile-parent-task-subissue-graph.sh"
  ```

- [x] The active production single pass can boundedly and idempotently repair a recently closed parent with deterministic incomplete live evidence without scheduling duplicate legacy reconciliation stages.

  ```yaml
  verify:
    method: bash
    run: "bash .agents/scripts/tests/test-pulse-issue-reconcile.sh"
  ```

- [x] A live parent with all known children terminal and no incomplete close-contract evidence still closes once with the existing summary, labels, and child-source behavior.

  ```yaml
  verify:
    method: codebase
    pattern: "complete phase contract: closes parent|live.*complete.*close|issue close"
    path: ".agents/scripts/tests/test-pulse-reconcile-parent-task-subissue-graph.sh"
  ```

## Context & Decisions

- The public incident is #29541; no private paths or provider values belong in issue/PR text.
- Missing live body is ambiguity and fails closed; an explicitly empty live body remains legacy-compatible only after a successful fresh read.
- Projection mismatch is the cache migration mechanism; do not silently coerce old envelopes to the new contract.
- Repair uses the existing bounded seven-day closed-parent window and marker semantics rather than an unbounded historical sweep.

## Relevant Files

- `.agents/scripts/pulse-batch-prefetch-helper.sh:125-175,261-339,480-535,884-943` — bodyless producer paths.
- `.agents/scripts/pulse-prefetch-infra.sh:184-288` — canonical projection and item validation.
- `.agents/scripts/pulse-issue-reconcile.sh:1369-1415` — active cached-body consumer.
- `.agents/scripts/pulse-issue-reconcile-actions.sh:345-585,1134-1250` — close contract and final mutation boundary.
- `.agents/scripts/pulse-issue-reconcile-parent.sh:298-399` — bounded recently-closed scan currently confined to a legacy entrypoint.
- `.agents/scripts/tests/test-pulse-issue-reconcile.sh:437-470` — single-pass-only production wiring contract.

## Dependencies

- **Blocked by:** none.
- **Blocks:** reliable recovery/continuation of Milestone 2 parent #29541 and any parent tracker whose completion criteria live only in its body.
- **External:** GitHub issue reads/writes are exercised only through stubs in tests; no new credential, billing, provider, release, or deployment dependency.

## Estimate

~4h: 1h fixture/root-cause lock, 1h projection and validation, 1h live/scheduler repair, 1h focused/broad verification and review.
