---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18201: Coordinate Milestone 2 read-only team-interface delivery

## Pre-flight

- [x] Memory recall: `team-interface Milestone 2 provider registry canonical agent roster` → 0 hits — no reusable stored lesson found.
- [x] Discovery pass: 0 target-file commits, 0 related merged PRs, and 0 related open PRs implement the Milestone 2 runtime core or canonical roster; exact GitHub title searches also returned no open issue or PR collision.
- [x] File refs verified: 12 mission, source-review, merged contract, discovery, runtime, configuration, and parent-lifecycle references checked against current merged source; the planning worktree remains intentionally separate.
- [x] Tier: `tier:thinking` — this is a non-dispatchable architectural parent coordinating five implementation boundaries and dependency gates; each filed child receives its own execution tier.
- [x] Seeded draft PR decision recorded: skipped — a parent tracker owns no implementation code, and only independently validated leaves may receive worker branches.

## Origin

- **Created:** 2026-08-05
- **Session:** OpenCode interactive mission `m-20260804-5d06b1`
- **Created by:** ai-interactive under maintainer direction
- **Parent task:** none; this is the Milestone 2 tracker
- **Blocked by:** none — Milestone 1 contracts merged through PRs #29505, #29518, #29510, #29528, and #29526
- **Conversation context:** Milestone 1 is complete and verified. The next safe stage is the read-only provider core and canonical agent roster; provider/runtime adapters remain unfiled until those interfaces merge.

## What

Coordinate Milestone 2 of mission `m-20260804-5d06b1`: deliver a provider-neutral,
non-mutating team-interface core, generate the canonical aidevops roster from
source metadata, then add read-only Buzz, Matrix, and OpenCode adapters behind
those stable interfaces.

This parent is a roadmap and dependency tracker only. It never receives
`auto-dispatch`, owns no implementation branch, and stays open until all five
features merge and the integrated Milestone 2 validation passes.

## Why

Buzz, Matrix, OpenCode, and future interfaces must consume one contract rather
than each reimplementing provider discovery, identity, state, planning, agent
selection, and workload routing. Filing downstream adapters before the runtime
and roster interfaces exist would force workers to invent overlapping APIs and
would violate the mission's staged-briefing rule.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** The parent records cross-feature architecture and sequencing
but does not dispatch. F2.1 and F2.2 have resolved execution contracts and use
`tier:standard`; later children will be classified only after their blockers
produce current interfaces.

## PR Conventions

This issue carries `parent-task`. Planning and intermediate child PRs use a
non-closing `For` or `Ref` parent reference. Leaf PRs close only their own child
issue. The final Milestone 2 PR may close this parent only after every child and
the parent acceptance criteria are verified.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The parent has no code write surface; sharing a seed branch across independent children would create collisions.
- **Status:** `not-created`
- **Freshness evidence:** Memory, exact target discovery, merged contracts, source review, runtime seams, and GitHub duplicate checks were refreshed on 2026-08-05.
- **Verification run:** Planning readiness and source verification only; implementation commands live in child briefs.
- **Stale-assumption warning:** Re-run discovery before each later adapter brief because Buzz, Matrix, OpenCode, and the merged F2.1/F2.2 interfaces may change.

## Children

- **F2.1 / t18202 — filed now:** provider registry, dedicated config loader, local state store, status/doctor commands, and deterministic read-only planner.
- **F2.2 / t18203 — filed now:** canonical 13-agent roster plus the framework guide, generated from discovery metadata with stable IDs and workload tiers.
- **F2.3 — deliberately unfiled:** read-only Buzz adapter; brief only after t18202 merges and its adapter contract is current.
- **F2.4 — deliberately unfiled:** Matrix normalization adapter; brief only after t18202 merges and current Matrix behavior is rechecked.
- **F2.5 — deliberately unfiled:** restricted OpenCode launch overlays; brief only after t18203 merges and runtime model/variant seams are rechecked.

No sequential phase auto-file markers are used. Native GitHub sub-issue links
identify filed children, while the mission remains the source of truth for
unfiled features.

## How (Approach)

### Progressive Context Plan

- **Read first:** `todo/missions/m-20260804-5d06b1/mission.md:149-180,252-270` and the two filed child briefs — these define stage order and current implementation contracts.
- **Load only if:** parent or child state needs repair — `.agents/reference/parent-task-lifecycle.md:58-76` and `.agents/workflows/brief.md:95-151` define dispatch and relationship gates.
- **Why:** preserve staged issue creation, permanent parent blocking, and native child relationships without pre-briefing unstable adapters.
- **Stop when:** t18202 and t18203 are valid, linked, independently available, and F2.3-F2.5 remain unfiled with explicit resume conditions.

### Files to Modify

- EDIT: `TODO.md` — record this parent and each filed child with mission, tier, dispatch, and hierarchy metadata.
- EDIT: `todo/missions/m-20260804-5d06b1/mission.md` — record task IDs, staged status, decisions, and verified issue references.
- NEW: `todo/tasks/t18201-brief.md` — permanent parent decomposition and closure contract.
- NEW: `todo/tasks/t18202-brief.md` — worker-ready F2.1 runtime-core contract.
- NEW: `todo/tasks/t18203-brief.md` — worker-ready F2.2 canonical-roster contract.

### Complete Write Surface

- **Callers/readers:** `TODO.md`, `todo/missions/m-20260804-5d06b1/mission.md`, GitHub parent/sub-issue views, Pulse relationship reconciliation, maintainers, and future child brief authors consume this decomposition.
- **Writers/mutation paths:** `claim-task-id.sh`, `.agents/scripts/issue-sync-helper.sh`, and this interactive session write task mappings and native issue relationships; the parent writes no runtime/provider state.
- **Tests/fixtures:** `.agents/scripts/verify-brief-helper.sh` validates each schema-v2 child; GitHub GraphQL sub-issue reads and issue label reads verify the published hierarchy.
- **Schemas/config:** `todo/tasks/t18202-brief.md` and `todo/tasks/t18203-brief.md` own runtime and roster schemas; this parent changes no schema or runtime config directly.
- **Generated/deployed mirrors:** GitHub issue bodies are generated from the three local briefs by `.agents/scripts/issue-sync-helper.sh`; no deployed agent/runtime mirror is generated by the parent.
- **Migrations/backfills:** No existing Milestone 2 task exists, so `TODO.md` and GitHub receive new mappings; relationship sync is the idempotent backfill path if a native link is initially unavailable.
- **Cleanup/rollback paths:** `TODO.md`, the mission progress log, and GitHub issues preserve allocated IDs permanently; a duplicate or invalid issue is closed with evidence rather than deleting or reusing its task ID.

### Implementation Steps

1. Publish this parent with `parent-task` and `no-auto-dispatch`, preserving the `## Children` decomposition without sequential auto-file markers.
2. Publish t18202 and t18203 only after their schema-v2 readiness checks pass; both are independent and may use `status:available`.
3. Link both leaves as native sub-issues, verify labels/assignees/body mappings, and keep the parent open.
4. After t18202 merges, refresh and brief F2.3/F2.4 separately. After t18203 merges, refresh and brief F2.5 separately.
5. Close the parent only after all five leaves merge and the integrated non-mutating Buzz/Matrix/OpenCode validation passes.

### Hazards and Compatibility

- **Concurrency/atomicity:** Fresh task IDs and exact single-task issue-sync calls prevent duplicate filing; native relationship mutations are idempotent and verified immediately.
- **Migration/rollback:** This is additive planning state. Incorrect issue metadata is corrected in place; allocated IDs and public audit history are never rewritten or reused.
- **Mixed-version/backward compatibility:** F2.3-F2.5 are withheld until their dependencies merge, so adapter briefs target one current interface rather than guessing across versions.
- **Idempotency/retry:** Re-running readiness, issue push, or relationship sync for one exact `tNNN` must reuse the established mapping and skip existing native links.
- **Partial failure/recovery:** If issue creation or relationship mutation fails, preserve local briefs and mappings, keep unverified leaves out of the available queue, and resume from the exact failed task only.

### Verification Before Dispatch

```bash
.agents/scripts/verify-brief-helper.sh check-readiness todo/tasks/t18202-brief.md
.agents/scripts/verify-brief-helper.sh check-readiness todo/tasks/t18203-brief.md
.agents/scripts/issue-sync-helper.sh relationships t18202 --dry-run
.agents/scripts/issue-sync-helper.sh relationships t18203 --dry-run
```

- **Surface mapping:** Readiness checks prove the two leaves contain complete write, hazard, verification, and acceptance contracts; exact relationship dry-runs prove task hierarchy without scanning the full backlog.
- **Broad verification trigger:** No source-code gate is required for this non-dispatchable planning parent; each child owns focused source checks and changed-file lint.

### Safety-Stop Recovery

- **Original objective:** Deliver Milestone 2 through one permanent parent and dependency-safe worker-ready leaves.
- **Preserved user directions:** Continue autonomously, use parent/child issue structure, avoid bulk dispatch, and do not file feature 6.6 early.
- **Trigger and evidence:** not triggered
- **Completed and verified:** Milestone 1 closure, M2 source discovery, duplicate checks, and t18201-t18203 allocation.
- **Remaining acceptance criteria:** Publish and link the parent plus ready children, then later deliver and validate all five feature leaves.
- **Unsafe route not to repeat:** Do not run unscoped relationship sync or file F2.3-F2.5 from speculative pre-dependency interfaces.
- **Next safe route:** Resume from the exact unpublished or unlinked task using its local brief and immutable task ID.
- **Resume condition:** GitHub identity/quota checks are healthy and the exact brief still passes readiness.
- **Owner and status:** Interactive mission session, then child workers and Pulse; not-triggered.

### Files Scope

- `TODO.md`
- `todo/missions/m-20260804-5d06b1/mission.md`
- `todo/tasks/t18201-brief.md`
- `todo/tasks/t18202-brief.md`
- `todo/tasks/t18203-brief.md`

## Acceptance Criteria

- [ ] The parent is open with `parent-task` and `no-auto-dispatch`, and t18202 plus t18203 appear as native GitHub sub-issues with worker-ready bodies.

  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/issue-sync-helper.sh relationships t18202 --dry-run && .agents/scripts/issue-sync-helper.sh relationships t18203 --dry-run"
  ```

- [ ] t18202 and t18203 are independently available for dispatch after readiness validation, while no F2.3, F2.4, F2.5, or F6.6 implementation issue is created prematurely.

  ```yaml
  verify:
    method: codebase
    pattern: "t18202|t18203|F2.3.*unfiled|F2.4.*unfiled|F2.5.*unfiled"
    path: "todo/tasks/t18201-brief.md"
  ```

- [ ] The parent never receives `auto-dispatch` and must not close before all five Milestone 2 leaves and integrated validation are complete.

  ```yaml
  verify:
    method: codebase
    pattern: "never receives.*auto-dispatch|stays open until all five"
    path: "todo/tasks/t18201-brief.md"
  ```

## Context & Decisions

- Milestone 1 is complete, so F2.1 and F2.2 have no open blockers and can run in parallel.
- F2.3/F2.4 consume the F2.1 adapter/runtime contract; F2.5 consumes the F2.2 roster contract. Their issue bodies are intentionally deferred until those interfaces merge.
- `## Children` is used instead of `## Phases` so the sequential auto-file mechanism cannot invent downstream child briefs.
- Feature 6.6 remains planning-only until all seven dependencies named in the mission are complete.

## Relevant Files

- `todo/missions/m-20260804-5d06b1/mission.md:149-180,252-270` — milestone table, staged briefing protocol, and open decisions.
- `todo/missions/m-20260804-5d06b1/research/source-review.md:394-438` — proposed runtime surfaces and current recommendation.
- `.agents/reference/parent-task-lifecycle.md:58-76,120-128` — child dispatch, sequential filing, close guard, and parent use cases.
- `.agents/workflows/brief.md:95-151` — schema-v2 readiness and ordered-work publication contract.
- `todo/tasks/t18202-brief.md` — F2.1 implementation authority.
- `todo/tasks/t18203-brief.md` — F2.2 implementation authority.

## Dependencies

- **Blocked by:** none; all Milestone 1 contract leaves are closed through merged PRs.
- **Blocks:** Milestone 2 completion and staged creation of F2.3, F2.4, and F2.5.
- **External:** No credentials, live provider account, installation, release, or publication is required to manage this tracker.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| F2.1 read-only core | 6h | Runtime config/state, adapter registry, planner, CLI, tests, docs |
| F2.2 canonical roster | 3.5h | Discovery metadata, stable IDs, schema, generator, tests, docs |
| F2.3 read-only Buzz adapter | 3.5h provisional | Re-estimate after F2.1 merges |
| F2.4 Matrix adapter | 4h provisional | Re-estimate after F2.1 merges |
| F2.5 OpenCode launch overlay | 3h provisional | Re-estimate after F2.2 merges |
| **Total** | **20h provisional** | First 9.5h briefed; downstream estimates are planning bounds only |
