<!-- aidevops:brief-schema=v2 -->

# t18230: End-to-end branded growth operating system

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: prior capability audit retained — consolidate around existing Campaign, Content, Knowledge, Performance, Marketing-Sales, Product, and Reports owners
- [x] Discovery pass: no open duplicate roadmap; completed campaign/performance parents and recent social-provider work reviewed
- [x] File refs verified: parent scope and every named phase owner exist at `45cd1150e`
- [x] Tier: `tier:thinking` — roadmap coordination spans trust, identity, attribution, and cross-plane contracts
- [x] Seeded draft PR decision recorded: skipped — parent is never implemented directly

## Origin

- **Created:** 2026-08-13
- **Session:** OpenCode interactive branded-growth planning session
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** Build a complete, high-quality business-development system where a user supplies a brand, product/service, offer, and goals; aidevops researches and briefs authentic content and campaigns, coordinates approved execution across relevant channels, measures outcomes, and improves reach, conversion, account growth, leads, and sales.

## What

Roadmap the smallest set of extensions that connect existing aidevops owners into an end-to-end branded growth operating system. The parent is planning-only: implementation occurs through worker-ready children, reusing first-party agents and deterministic helpers rather than adding duplicate general agents.

## Why

Aidevops already contains strong but fragmented capabilities for brand identity, audience/competitor research, copy/media production, campaigns, calendars, social knowledge, outbound X/Reddit operations, CRM/outreach, commerce, performance schemas, reporting, provenance, and approvals. Users need one coherent, truthful, resumable lifecycle with safe provider adapters and measurable feedback loops.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** This parent records the cross-system architecture and ordered trust boundaries. Each child carries an implementation-ready standard or thinking contract.

## PR Conventions

This issue retains `parent-task` and is never closed by an individual child PR. Child PRs resolve only their leaf issues; the final integration phase may close this parent after every declared phase is complete.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Planning-only parent; implementation seeds belong on leaf issues only.
- **Status:** `not-created`
- **Freshness evidence:** Repository and GitHub discovery completed against `45cd1150e`.
- **Verification run:** Completed 2026-08-15 — all phase issues closed; campaign-growth 6/6 and status-routing 2/2 tests pass; corrective PR #30282 passed every required gate.
- **Stale-assumption warning:** Reconcile child order if provider APIs or prerequisite contracts change.

## Phases

- Phase 1 - t18228 — define evidence-backed brand, product, and offer campaign intake #30135
- Phase 2 - t18231 — build structured audience, competitor, creator, trend, and channel research dossiers [auto-fire:on-prior-merge] #30137
- Phase 3 - t18234 — generate authentic branded campaign briefs and production manifests [auto-fire:on-prior-merge] #30140
- Phase 4 - t18233 — harden campaign asset provenance, review, and production gates [auto-fire:on-prior-merge] #30139
- Phase 5 - t18232 — bridge reviewed campaign schedules into the approval-bound outbound queue [auto-fire:on-prior-merge] #30138
- Phase 6A - t18237 — add approval-bound Meta and TikTok publishing adapters [auto-fire:on-prior-merge] #30143
- Phase 6B - t18235 — add approval-bound LinkedIn and YouTube publishing adapters [auto-fire:on-prior-merge] #30141
- Phase 7 - t18238 — add provider health, rate-limit, and receipt reconciliation [auto-fire:on-prior-merge] #30144
- Phase 8 - t18236 — implement normalized performance, lead, and revenue ingestion [auto-fire:on-prior-merge] #30142
- Phase 9 - t18240 — add privacy-safe attribution, experiments, reporting, and growth recommendations [auto-fire:on-prior-merge] #30147
- Phase 10 - t18239 — integrate the end-to-end command and fixture-backed verification scenario [auto-fire:on-prior-merge] #30146

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/aidevops/campaigns-plane.md`, `.agents/aidevops/knowledge-plane/05-social-operations.md`, and `.agents/aidevops/performance.md` — canonical state and mutation boundaries.
- **Load only if:** the leaf brief for the active phase and its named owner documents.
- **Why:** Avoid loading every domain into each worker and preserve progressive discovery.
- **Stop when:** The current leaf's inputs, outputs, approvals, receipts, failure states, and verification are clear.

### Files to Modify

- `EDIT: TODO.md` — roadmap and child task projections.
- `NEW: todo/tasks/t18230-brief.md` — canonical roadmap brief.
- `NEW/EDIT: todo/tasks/t18228-brief.md` through `todo/tasks/t18240-brief.md` — leaf implementation contracts.

### Complete Write Surface

- **Callers/readers:** `contract:` Maintainers, Pulse, issue sync, auto-dispatch workers, and parent close guards read the parent/children graph.
- **Writers/mutation paths:** `contract:` Planning publication projects TODO/brief intent to GitHub; workers mutate only their assigned leaf surfaces.
- **Tests/fixtures:** `contract:` Brief readiness and task dispatchability checks cover planning quality; implementation tests live in leaves.
- **Schemas/config:** `contract:` Parent introduces no runtime schema.
- **Generated/deployed mirrors:** `contract:` GitHub issue bodies mirror canonical default-branch planning files.
- **Migrations/backfills:** `contract:` No runtime migration; existing campaign/performance data remains authoritative.
- **Cleanup/rollback paths:** `contract:` Close or supersede only a falsified leaf; never erase completed campaign-plane history.

### Implementation Steps

1. Publish this parent and each schema-v2 leaf brief.
2. Link every leaf as a native sub-issue of #30136.
3. Establish native blocked-by edges; permit only #30135 to become initially available.
4. Keep provider phases parallel only after the queue bridge is merged; keep final integration blocked by all functional prerequisites.
5. Reconcile issue labels and parent body as children ship; do not duplicate implementation under this parent.

### Hazards and Compatibility

- **Concurrency/atomicity:** Planning publication must not expose incomplete child briefs to workers.
- **Migration/rollback:** Existing campaign and performance contracts are extended compatibly by leaves; the parent performs no migration.
- **Mixed-version/backward compatibility:** Leaf briefs require compatibility with existing campaigns, providers, and result schema.
- **Idempotency/retry:** Relationship and issue publication may replay without duplicate children.
- **Partial failure/recovery:** Unpublished or unlinked leaves remain `publication:pending`/blocked until repaired.

### Verification Before Dispatch

```bash
for brief in todo/tasks/t182{28,30,31,32,33,34,35,36,37,38,39,40}-brief.md; do .agents/scripts/verify-brief-helper.sh check-readiness "$brief"; done
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Readiness validates every worker contract; changed-file lint validates planning Markdown/TODO syntax.
- **Broad verification trigger:** Not required; runtime changes occur only in children.

### Files Scope

- `TODO.md`
- `todo/tasks/t18228-brief.md`
- `todo/tasks/t18230-brief.md`
- `todo/tasks/t18231-brief.md`
- `todo/tasks/t18232-brief.md`
- `todo/tasks/t18233-brief.md`
- `todo/tasks/t18234-brief.md`
- `todo/tasks/t18235-brief.md`
- `todo/tasks/t18236-brief.md`
- `todo/tasks/t18237-brief.md`
- `todo/tasks/t18238-brief.md`
- `todo/tasks/t18239-brief.md`
- `todo/tasks/t18240-brief.md`

## Completion Evidence

- All 11 declared phases are native sub-issues of #30136 and are closed with no active dependency blockers.
- Phase 9's original delivery in PR #30266 was completed by the privacy-safe corrective implementation in #30275 / PR #30282.
- Final integration shipped in PR #30272; its hermetic campaign-growth and status-routing suites pass against the corrected Phase 9 head.
- Required CI, Qlty, SonarCloud, maintainer, and review-bot gates passed for the corrective implementation without quality overrides.

## Acceptance Criteria

- [x] Every phase has a substantive schema-v2 leaf brief, native parent linkage, and verifiable dependency state.
- [x] The parent never receives `auto-dispatch`; only ready leaves are available.
- [x] The roadmap reuses existing first-party owners and does not introduce duplicate generic media, UGC, scheduler, publisher, CRM, or analytics agents.
- [x] The final system preserves human approval for publishing, outreach, budget, audience, offer, and other consequential mutations.
- [x] The final integration scenario proves intake → research → brief → production → review → approved distribution → receipt → outcomes → recommendation, including negative and recovery paths.

## Context & Decisions

- Outcome parity is the goal; no external source or brand name belongs in public issues.
- Official APIs and explicit exports are preferred; browser/persona automation is not a substitute for unavailable write authority.
- Creative quality means brand-consistent, proof-linked, channel-native, believable, and authentic—not deceptive impersonation or undisclosed synthetic endorsement.
- Campaigns Plane owns lifecycle, Knowledge Plane owns approval-bound social mutation, Performance Plane owns normalized outcomes, Reports interprets, and domain agents supply specialist judgment.

## Relevant Files

- `.agents/aidevops/campaigns-plane.md:5-26,31-58,202-230`
- `.agents/aidevops/knowledge-plane/05-social-operations.md:276-350`
- `.agents/aidevops/knowledge-plane/06-social-provider-capabilities.md:33-46,105-150`
- `.agents/aidevops/performance.md:4-28,55-107,246-257`
- `.agents/content.md:70-110`
- `.agents/reports/marketing.md`

## Dependencies

- **Blocked by:** none
- **Blocks:** none outside declared children
- **External:** Official provider accounts/scopes are runtime gates, not planning blockers; adapters must remain testable with fixtures and dry runs.

## Estimate Breakdown

| Phase group | Time | Notes |
|---|---:|---|
| Foundation and research | ~10h | Intake and evidence dossier |
| Creative and production | ~10h | Briefs, manifests, gates |
| Distribution | ~18h | Queue bridge, adapters, health |
| Measurement and optimization | ~16h | Ingest, attribution, experiments |
| Integration | ~6h | Orchestration and full fixture |
| **Total** | **~60h** | Parallelism possible after foundational dependencies |
