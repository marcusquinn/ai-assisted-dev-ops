---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18304: Improve reliability-adjusted subagent routing observability

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `subagent routing observability pricing ai-research triage` → 5 hits — retained routing, lifecycle, and release lessons
- [x] Discovery pass: 1 intervening main commit / recent related history inspected / 0 open PR collisions found
- [x] File refs verified: 20 refs checked, all present at HEAD or explicitly declared NEW
- [x] Tier: `tier:thinking` — routing attribution, migration semantics, and a restricted execution boundary are affected
- [x] Seeded draft PR decision recorded: skipped — the authority-bearing interactive session owns implementation through release

## Origin

- **Created:** 2026-08-21
- **Session:** OpenCode:current-interactive
- **Created by:** AI DevOps (ai-interactive)
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** A measured routing review found large cost savings but stale pricing, incomplete outcome evidence, tier misattribution, and a focused-research persona collision. The maintainer authorized implementation through patch release and local update.

## What

Produce trustworthy, fail-open subagent routing evidence: current GPT-5.6 prices, explicit price-version backfill semantics, honest lifecycle outcomes, disjoint route populations, correct tier/version attribution, and a focused `ai-research` execution identity that retains triage-grade isolation. Preserve the existing model policy unless a bounded Luna candidate has an objective verifier.

## Why

Current cost totals overstate Luna and Terra spend, headless triage can record a thinking model as `standard`, and task-tool completion cannot prove semantic acceptance. The focused research helper is also converted into `triage-review`, so it declines valid research requests. These defects make optimization decisions unreliable and remove a useful low-cost research path.

## Tier

### Tier checklist (verify before assigning)

- [ ] **Exact execution contract supplied?** Additive lifecycle event design still requires implementation judgment.
- [x] **Targets and reference pattern verified?** Existing observability, routing, runtime-event, and headless patterns are identified.
- [ ] **No semantic or design decision remains?** Historical repricing and secure research-origin preservation require bounded decisions.
- [x] **Bounded, reversible, low-consequence impact?** Changes are additive/fail-open and model policy remains unchanged.
- [ ] **No stateful coordination to invent?** Lifecycle correlation spans task hooks and session events.
- [x] **Focused verification and rollback are explicit?** Existing focused test suites and config rollback are available.
- [x] **No dispatch-path risk override?** The task deliberately retains `tier:thinking` because headless dispatch is affected.

**Selected tier:** `tier:thinking`

**Tier rationale:** The work changes dispatch attribution and a restricted headless identity boundary, while preserving backward-compatible and fail-open behavior.

## PR Conventions

This is a leaf issue. The implementation PR uses `Resolves #30521`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The current interactive session has fresh implementation context and owns the complete full loop.
- **Status:** `not-created`
- **Freshness evidence:** Memory, collision discovery, file verification, and `origin/main` refresh were completed against the current branch.
- **Verification run:** Pre-edit check and hook integrity passed; implementation checks are pending.
- **Stale-assumption warning:** Revalidate `origin/main`, official prices, and exact function signatures before mutation.

## How (Approach)

### Progressive Context Plan

- **Read first:** pricing config/fallbacks, observability route joins, lifecycle tracker, and headless environment preparation — these determine the smallest compatible changes.
- **Load only if:** release or CI fails — then load the matching recovery workflow rather than broad references.
- **Why:** Preserve deterministic fallback behavior, privacy redaction, and public-triage isolation.
- **Stop when:** production paths, focused tests, migration semantics, and rollback are explicit.

### Worker Quick-Start

- Official per-million-token rates: Luna input `0.20`, output `1.20`, cached input `0.02`; Terra `2.00`, `12.00`, `0.20`; Sol remains `5.00`, `30.00`, `0.50`.
- OpenAI bills cache writes at 1.25x uncached input: Luna `0.25`, Terra `2.50`, and Sol `6.25` per million tokens.
- Honest lifecycle evidence is dispatch, child identity, terminal host status, and parent task-tool outcome. Semantic acceptance/verification/rework remains unknown unless separately exposed.
- Preserve Luna `max`, Terra `high`, Sol `medium`, the 260K cap, and Sol Pro exclusion.

### Files to Modify

- `EDIT: .agents/configs/model-pricing.json` — current Luna/Terra rates and pricing metadata.
- `EDIT: .agents/plugins/opencode-aidevops/observability-pricing.mjs` — matching fail-open fallbacks and pricing version.
- `EDIT: .agents/plugins/opencode-aidevops/observability-cost-backfill.mjs` — idempotent stale-estimate repricing without rewriting provider-supplied costs.
- `EDIT: .agents/plugins/opencode-aidevops/observability*.mjs` — additive lifecycle/route population/version evidence as required.
- `EDIT: .agents/plugins/opencode-aidevops/subagent-*.mjs` — correlate task hooks with child host lifecycle evidence.
- `EDIT: .agents/scripts/runtime-events*.mjs` — permit bounded lifecycle payload keys only if required.
- `EDIT: .agents/scripts/pulse-ancillary-dispatch*.sh` — propagate the canonical tier with explicit model selection.
- `EDIT: .agents/scripts/headless-runtime-run.sh` — preserve a validated native research identity while retaining triage isolation.
- `EDIT: .opencode/lib/ai-research-runtime.ts` — supply the explicit restricted research marker/contract.
- `EDIT: focused existing tests under plugin, script, and .opencode test directories` — encode positive and regression behavior.

### Complete Write Surface

- **Callers/readers:** plugin `index.mjs`, quality hooks, subagent effort escalation, `ai-research-runtime.ts`, pulse ancillary dispatch.
- **Writers/mutation paths:** observability request/route/runtime-event writers and deterministic cost backfill.
- **Existing verification/tests:** observability pricing/routing, subagent effort/cancellation, runtime-events, headless routing, GPT-5.6 pricing, and ai-research tests.
- **Schemas/config:** additive SQLite/runtime-event data only; existing request/routing columns remain readable.
- **Generated/deployed mirrors:** repository `.agents/` and `.opencode/` deploy through normal release setup; never edit `~/.aidevops` directly.
- **Migrations/backfills:** repricing is idempotent and limited to aidevops-estimated rows whose stored price version is stale or absent.
- **Cleanup/rollback paths:** revert additive writers and pricing metadata; old readers ignore additive events/columns and config rollback restores prior estimates.

### Implementation Steps

1. Update official pricing in both config and deterministic fallback paths. Add explicit pricing provenance/version so a bounded backfill can distinguish provider cost from aidevops estimates.
2. Persist redacted subagent lifecycle evidence using existing task-call/session correlation. Record host/tool outcome categories only; do not infer semantic parent acceptance.
3. Add a stable route-kind/population classification for interactive child, headless, top-level profile, and compaction evidence while preserving existing joins.
4. Pass both the resolved model and canonical tier into triage workers; ensure new routing rows retain current aidevops version attribution.
5. Preserve `ai-research` as a validated native identity through environment preparation while retaining triage-grade no-tools, provider-egress, authentication, and sandbox controls.
6. Run focused tests, changed-file lint, independent closeout review, and the authorized full-loop release/update path.

### Hazards and Compatibility

- **Concurrency/atomicity:** SQLite writes remain transaction-bounded and fail-open; lifecycle maps stay bounded and task-call keyed.
- **Migration/rollback:** Additive schema/config changes must tolerate partially migrated databases and rollback to older readers.
- **Mixed-version/backward compatibility:** Existing rows without new metadata remain queryable and explicitly unknown; new writers must not require new readers.
- **Idempotency/retry:** Backfill updates only stale aidevops estimates and records the applied pricing version; repeated startup cannot compound costs.
- **Partial failure/recovery:** Pricing/schema/event failures must not block provider requests, task completion, triage, or research execution.

### Complexity Impact

- **Target function:** `_prepare_cmd_run_environment` in `.agents/scripts/headless-runtime-run.sh`
- **Current line count:** approximately 28 lines (threshold: 100 lines)
- **Estimated growth:** +10 lines
- **Projected post-change:** approximately 38 lines (38% of threshold)
- **Action required:** None; use a small validation helper if branching grows materially.

### Verification Before Dispatch

```bash
node --test .agents/plugins/opencode-aidevops/tests/test-observability-pricing.mjs .agents/plugins/opencode-aidevops/tests/test-observability-routing-join.mjs .agents/plugins/opencode-aidevops/tests/test-subagent-effort.mjs
bash .agents/scripts/tests/test-model-pricing-gpt56.sh
bash .agents/scripts/tests/test-headless-routing-retry.sh
bun test .opencode/lib/ai-research.test.ts
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Plugin tests cover cost, route joins, lifecycle, and version; shell tests cover pricing fallbacks and tier propagation; Bun covers research identity; changed lint covers all writes.
- **Broad verification trigger:** Shared plugin/headless execution paths require the repository's normal PR CI, but no extra local full-repository scan beyond evidence-triggered gates.

### Recoverability Checkpoint

- [ ] Focused functional verification passes: commands above
- [ ] WIP commit created before broad gates: `wip: improve routing evidence integrity`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Improve reliability-adjusted subagent routing observability through release and update.
- **Preserved user directions:** Keep Luna/max, exclude Pro for coding, prioritize reliability over latency, and down-route only with objective evidence.
- **Trigger and evidence:** not triggered
- **Completed and verified:** worktree, issue claim, memory, collision, and implementation discovery.
- **Remaining acceptance criteria:** implementation, focused verification, PR, merge, release, update, and telemetry readiness.
- **Unsafe route not to repeat:** treating tool completion as semantic success or weakening triage isolation to restore research.
- **Next safe route:** additive fail-open evidence and explicitly validated identity markers.
- **Resume condition:** continue from the latest verified WIP commit.
- **Owner and status:** current interactive session; recovering

### Files Scope

- `TODO.md`
- `todo/tasks/t18304-brief.md`
- `.agents/configs/model-pricing.json`
- `.agents/plugins/opencode-aidevops/observability*.mjs`
- `.agents/plugins/opencode-aidevops/index.mjs`
- `.agents/plugins/opencode-aidevops/subagent-*.mjs`
- `.agents/plugins/opencode-aidevops/quality-hooks.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-observability-*.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-subagent-*.mjs`
- `.agents/plugins/opencode-aidevops/tests/test-routing-feedback.mjs`
- `.agents/scripts/shared-model-tier.sh`
- `.agents/scripts/runtime-events*.mjs`
- `.agents/scripts/routing-feedback*.mjs`
- `.agents/scripts/pulse-ancillary-dispatch*.sh`
- `.agents/scripts/headless-runtime-run.sh`
- `.agents/scripts/tests/test-model-pricing-gpt56.sh`
- `.agents/scripts/tests/test-headless-routing-retry.sh`
- `.agents/scripts/tests/test-observability-runtime-events.sh`
- `.opencode/lib/ai-research-runtime.ts`
- `.opencode/lib/ai-research.test.ts`

## Acceptance Criteria

- [ ] Luna and Terra costs use current official API rates in config, fallbacks, new rows, and idempotent aidevops-estimate backfill.
- [ ] Child telemetry records redacted route population, dispatch/identity, host terminal status, and parent task-tool outcome without claiming semantic acceptance.
- [ ] Interactive child, headless, top-level model-profile, and compaction populations can be queried separately without breaking existing route joins.
- [ ] Explicit thinking-model triage records `tier:thinking`, and new routed rows include the current aidevops version.
- [ ] Focused `ai-research` retains its research-only persona and output contract while public-triage authentication, no-tools, provider-egress, and sandbox restrictions remain enforced.
- [ ] Luna remains at max reasoning, Sol Pro remains excluded from coding routes, and no Terra workload moves to Luna without an objective verifier and rollback.
- [ ] Existing databases, mixed-version processes, and provider requests remain compatible and fail-open.
- [ ] Focused tests and `.agents/scripts/linters-local.sh --changed` pass.

## Context & Decisions

- Cost is secondary to verified throughput and reliability; async latency is not an optimization target.
- The measured baseline is useful for cost and mechanical failure rates but cannot establish semantic quality.
- A concentrated single-parent sample is insufficient evidence for a broad Terra-to-Luna policy change.
- Prefer runtime events/additive metadata over destructive schema reinterpretation.
- Official model pages and the API pricing page are the pricing sources; no guessed URLs or third-party rates are accepted.

## Relevant Files

- `.agents/plugins/opencode-aidevops/observability.mjs` — request, route, runtime-event, and version persistence.
- `.agents/plugins/opencode-aidevops/subagent-lifecycle-tracker.mjs` — bounded child identity and terminal evidence.
- `.agents/scripts/headless-runtime-run.sh` — tier defaulting and session-origin preparation.
- `.opencode/lib/ai-research-runtime.ts` — native focused-research invocation.
- `.agents/scripts/pulse-ancillary-dispatch.sh` — canonical triage route selection.

## Dependencies

- **Blocked by:** none
- **Blocks:** trustworthy post-release routing comparisons and any future bounded Terra-to-Luna experiment.
- **External:** official OpenAI model/pricing documentation and existing GitHub release infrastructure; no new credentials or purchases.

## Estimate Breakdown

| Phase | Time | Notes |
|-------|------|-------|
| Research/read | 45m | Completed implementation and boundary mapping |
| Implementation | 3h | Pricing, observability, and restricted routing fixes |
| Verification | 1h | Focused tests, changed lint, PR gates, release/update |
| **Total** | **4h 45m** | |
