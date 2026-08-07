---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18209: Implement provider-neutral routing, observability, and completion feedback

## Pre-flight

- [x] Memory recall: `provider-neutral model routing observability completion feedback` → 0 hits — no prior reusable task record matched.
- [x] Discovery pass: 6 recent commits, 0 related merged PRs, and 0 related open PRs touched the core routing targets.
- [x] File refs verified: routing table, shell resolver, headless runtime, OpenCode hooks, observability schema, cron/runner dispatch, feedback, and focused test paths exist at current HEAD.
- [x] Tier: `tier:thinking` — the task changes the worker dispatch path and coordinates routing state across shell, JavaScript, SQLite, cron, and runner boundaries.
- [x] Seeded draft PR decision recorded: skipped — the implementation and focused verification already exist in the session-owned linked worktree.

## Origin

- **Created:** 2026-08-07
- **Session:** OpenCode interactive full-loop session
- **Created by:** ai-interactive
- **Parent task:** none
- **Blocked by:** none
- **Conversation context:** The maintainer requested one provider-neutral routing policy across interactive, headless, and scheduled execution, with joined outcome evidence and conservative feedback. The same session explicitly authorized a patch release, incremental deployment, local update, and post-release worker smoke test.

## What

Provide one layered routing contract for OpenCode profiles, subagents, headless
workers, cron jobs, and named runners. A workload tier resolves to an ordered
same-tier provider/model candidate list and provider-specific reasoning variant.
Only an exact model-authored capability-limit marker may advance to the next
configured tier.

Persist routing decisions with runtime outcomes, tokens, and cost; join child
sessions to their canonical parent work session; and expose conservative feedback
in interactive idle notifications, routine tracking bodies, and deterministic
closeout summaries.

## Why

Before this change, execution surfaces could resolve tiers differently, scheduled
jobs could freeze stale concrete models, and generic blockers could be confused
with model-capability limits. Routing and cost evidence also lived in separate
records, preventing reliable completion recommendations. The result was wasted
provider retries, unsafe escalation semantics, and no closed feedback loop.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** This is self-hosting dispatch-path work with cross-runtime
state, fallback, retry, and observability semantics. The behavior is now decided,
but implementation must preserve trust boundaries and mixed-version recovery.

## PR Conventions

This is a leaf task. The implementation PR uses a closing keyword for GitHub
issue `#29674` and records runtime verification plus the authorized release path.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The current linked worktree already contains the complete implementation and focused regression evidence; a partial seed would not reduce discovery.
- **Status:** `not-created`
- **Freshness evidence:** Exact target review, duplicate discovery, focused tests, and the changed-file local quality gate ran against the current worktree.
- **Verification run:** 31 focused Node tests, the full 573-test OpenCode plugin suite, 12 focused shell suites (including production parallel/xargs generated-agent and OAuth-pool selector paths), ShellCheck/Bash syntax, and `.agents/scripts/linters-local.sh` pass.
- **Stale-assumption warning:** Rebuild evidence if `origin/main` changes any routing, observability, release, or worker-dispatch target during rebase.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/tools/context/model-routing.md` — workload-tier, candidate, override, and capability-escalation contract.
- **Then load:** `.agents/scripts/shared-model-tier.sh`, `.agents/plugins/opencode-aidevops/model-routing.mjs`, and `.agents/scripts/headless-runtime-run.sh` — shell/JavaScript parity and retry orchestration.
- **Load only if:** `.agents/workflows/full-loop.md` and `.agents/workflows/release.md` — PR merge or publication recovery is required.
- **Why:** keep provider selection declarative while deterministic code owns availability, retries, persistence, and trust boundaries.
- **Stop when:** every execution surface consumes the same layered table and routing/outcome evidence joins under one canonical session key.

### Worker Quick-Start

```text
1. Tier names are provider-neutral: simple, standard, thinking.
2. Explicit full model IDs remain authoritative user overrides.
3. An explicit empty models array disables only that tier.
4. An explicit empty reasoning value clears inherited framework reasoning.
5. OpenCode subagents select the first connected same-tier candidate at request time; generated profiles preserve tier intent rather than pinning candidate zero.
6. Same-tier retry and capability-escalation selectors cannot apply pattern-driven downgrade; an initial adaptive downgrade realigns tier, variant, retry budget, candidate index, and telemetry to the selected model.
7. Only model text matching `BLOCKED: capability limit - <non-empty evidence>` authorizes tier escalation, including genuinely non-JSON runtime output but excluding mixed tool streams.
8. Permission, authentication, secrets, policy, trust, locality, and rate limits never authorize capability escalation.
9. Root profile telemetry must not shadow richer AIDEVOPS_DISPATCH_TIER environment metadata.
```

### Files to Modify

- `EDIT: .agents/configs/model-routing-table.json` — canonical candidates, variants, and escalation order.
- `EDIT/NEW: .agents/plugins/opencode-aidevops/*.mjs` — layered routing, generated profiles, root/child decisions, joined observability, and idle feedback.
- `EDIT/NEW: .agents/scripts/shared-model-tier.sh`, `.agents/scripts/fallback-chain-helper.sh`, `.agents/scripts/headless-runtime-*.sh` — shell parity, availability, retries, and exact capability escalation.
- `EDIT: .agents/scripts/cron-*.sh`, `.agents/scripts/runner-helper.sh` — preserve tier/provider intent and resolve at execution.
- `EDIT/NEW: .agents/scripts/routing-feedback.mjs`, `.agents/scripts/routine-log-helper.sh`, `.agents/scripts/pulse-merge.sh` — shared completion feedback surfaces.
- `EDIT/NEW: .agents/plugins/opencode-aidevops/tests/*routing*.mjs`, `.agents/scripts/tests/*routing*.sh`, and named scheduling/feedback tests — positive and negative regressions.
- `EDIT: .agents/tools/context/model-routing.md`, `.agents/prompts/worker-efficiency-protocol.md`, `.agents/workflows/full-loop.md` — operator and worker contracts.

### Complete Write Surface

- **Callers/readers:** OpenCode config/profile hooks, subagent effort hooks, headless model selection, fallback chains, cron dispatch, named runners, routine logging, and merge closeout read routing state.
- **Writers/mutation paths:** OpenCode observability inserts routing columns; headless metrics append attempts/outcomes; cron/runner config stores tier/provider intent; feedback fingerprinting stores emitted-summary state.
- **Tests/fixtures:** Node routing/observability/feedback tests and shell routing/retry/scheduling/closeout tests encode inheritance, disabled tiers, exact markers, and canonical joins.
- **Schemas/config:** `model-routing-table.json` and SQLite `llm_requests` routing columns are the canonical configuration and persistence changes.
- **Generated/deployed mirrors:** `generate-runtime-config-agents.sh` preserves provider-neutral tier metadata for request-time OpenCode selection while retaining explicit full-model pins, exports the restrictive-copy helper into parallel generator children, and the authorized release performs incremental deployment to `~/.aidevops/agents/`.
- **Migrations/backfills:** SQLite initialization adds nullable routing columns idempotently before creating their indexes; historical requests remain valid and feedback ignores absent routing evidence.
- **Cleanup/rollback paths:** Reverting the routing/observability changes restores prior per-surface resolution; queued jobs retain compatible tier/model strings, and feedback is silent without joined evidence.

### Implementation Steps

1. Load and merge custom and framework routing tables in JavaScript and shell, preserving explicit disabled tiers and empty variant overrides.
2. Resolve ordered same-tier candidates, full model/provider overrides, candidate index, and current variants at execution time, including connected-provider selection for OpenCode child requests.
3. Retry availability/provider/runtime failures within a tier; advance tiers only after the exact trusted capability-limit marker.
4. Persist routing metadata beside requests and headless attempts, canonicalize parent/child session identity, and join tokens/cost/outcomes.
5. Emit changed, evidence-backed feedback through interactive, routine, and deterministic closeout surfaces without comment or toast noise.
6. Preserve tier intent in generated profiles, resolve the connected model/variant in request hooks, and retain restrictive source-agent guards.
7. Add focused positive and negative regressions, run the changed-file quality gate, then complete the canonical PR/release/deploy lifecycle.

### Hazards and Compatibility

- **Concurrency/atomicity:** Observability initialization remains lock-guarded and additive; concurrent initializers must create all routing columns without SQLite lock errors.
- **Migration/rollback:** New columns are nullable and idempotent, and routing indexes are created only after legacy schemas gain those columns. No historical row rewrite or destructive migration is allowed.
- **Mixed-version/backward compatibility:** Explicit full-model overrides and legacy tier strings remain accepted. OpenCode provider-state read failures preserve the inherited request model for non-empty tiers, while explicit empty tiers fail closed before fallible session/provider lookups. Missing routing metadata fails silent rather than fabricating recommendations.
- **Idempotency/retry:** Same-tier retry budgets are bounded and use exact-tier selection; capability escalation exercises the next configured tier without adaptive downgrade. Initial adaptive downgrade realigns all routing metadata to the actual selected tier. Release and feedback fingerprints are replay-safe; cron/runner resolution happens once per execution.
- **Partial failure/recovery:** Provider/auth/rate-limit failures remain same-tier or terminal as classified. Capability escalation requires model text, exact syntax, and non-empty evidence.

### Verification Before Dispatch

```bash
node --test .agents/plugins/opencode-aidevops/tests/test-model-routing.mjs .agents/plugins/opencode-aidevops/tests/test-observability-routing-join.mjs .agents/plugins/opencode-aidevops/tests/test-routing-feedback-handler.mjs .agents/plugins/opencode-aidevops/tests/test-routing-feedback.mjs .agents/plugins/opencode-aidevops/tests/test-subagent-effort.mjs
npm --prefix .agents/plugins/opencode-aidevops test
bash .agents/scripts/tests/test-headless-routing-retry.sh
bash .agents/scripts/tests/test-model-routing-overlay.sh
bash .agents/scripts/tests/test-opencode-subagent-runtime-guards.sh
bash .agents/scripts/tests/test-scheduled-model-tier-preservation.sh
bash .agents/scripts/tests/test-routine-routing-feedback.sh
bash .agents/scripts/tests/test-routing-feedback-closeout.sh
bash .agents/scripts/tests/test-observability-concurrent-init.sh
bash .agents/scripts/tests/test-headless-openai-routing.sh
bash .agents/scripts/tests/test-headless-runtime-contract-tests.sh
bash .agents/scripts/tests/test-headless-runtime-provider-tests.sh
bash .agents/scripts/tests/test-worker-diagnostic-evidence.sh
.agents/scripts/linters-local.sh
```

- **Surface mapping:** Node tests cover table overlays, connected-provider fallback, actual child-model replacement, explicit pins/disabled tiers, root/child telemetry, SQLite joins, CLI selectors, and idle feedback. Shell suites cover exact-tier retry/escalation despite a proposed lower-tier pattern route, adaptive-downgrade telemetry alignment, candidate exhaustion, JSON and plain-text exact escalation markers, mixed-stream rejection, generated tier metadata through the real parallel/xargs child-shell boundary, scheduling, routine/closeout output, and Bash compatibility. The local gate covers whitespace, repeated literals, complexity, ShellCheck, secrets, Markdown, portability, and changed-file quality.
- **Broad verification trigger:** The routing work changes shared dispatch and observability contracts, so the repository changed-file gate is required. The monolithic headless helper suite is additionally compared with clean `HEAD` when unrelated baseline failures appear.

### Recoverability Checkpoint

- [x] Focused tests pass: Node and focused shell matrix listed above.
- [x] WIP commit created before publication gates: `feat: implement provider-neutral routing and feedback`.
- [x] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh` passed.

### Safety-Stop Recovery

- **Original objective:** Merge, release, update, and smoke-test provider-neutral routing with one real worker dispatch.
- **Preserved user directions:** Continue through patch publication, incremental deployment, local update, and monitored worker execution.
- **Trigger and evidence:** Monolithic headless tests exposed PR-state/worktree-output failures; the same failures reproduced from clean `HEAD` and are baseline defects.
- **Completed and verified:** Source implementation, focused tests, local quality gate, and baseline isolation.
- **Remaining acceptance criteria:** Commit, PR, exact-head CI/review, merge, release convergence, local update, and monitored worker result.
- **Unsafe route not to repeat:** Do not treat pending CI or clean-HEAD test failures as routing regressions; do not create another version when release reconciliation is pending.
- **Next safe route:** Use full-loop wrappers and canonical release status/reconcile commands, then manual worker launcher and structured diagnostics.
- **Resume condition:** The current linked worktree and issue #29674 remain owned by this session.
- **Owner and status:** Interactive session; recovering through the audited full loop.

### Files Scope

- `TODO.md`
- `todo/tasks/t18209-brief.md`
- `.agents/configs/model-routing-table.json`
- `.agents/plugins/opencode-aidevops/*.mjs`
- `.agents/plugins/opencode-aidevops/tests/*.mjs`
- `.agents/prompts/worker-efficiency-protocol.md`
- `.agents/scripts/cron-dispatch.sh`
- `.agents/scripts/cron-helper.sh`
- `.agents/scripts/fallback-chain-helper.sh`
- `.agents/scripts/generate-runtime-config-agents.sh`
- `.agents/scripts/headless-runtime-*.sh`
- `.agents/scripts/model-availability-*.sh`
- `.agents/scripts/pulse-merge.sh`
- `.agents/scripts/routine-log-helper.sh`
- `.agents/scripts/routing-feedback.mjs`
- `.agents/scripts/runner-helper.sh`
- `.agents/scripts/shared-model-tier.sh`
- `.agents/scripts/tests/*.sh`
- `.agents/tools/context/model-routing.md`
- `.agents/workflows/full-loop.md`

## Acceptance Criteria

- [x] All interactive, headless, cron, runner, and generated-profile routes consume the same layered provider-neutral table.
- [x] OpenCode child requests choose the first registered connected same-tier candidate without replacing explicit full-model pins; disabled tiers fail closed even when child-session metadata is unavailable.
- [x] Explicit empty tiers/variants preserve operator intent, while partial overlays inherit only unspecified framework values.
- [x] Same-tier candidates exhaust before capability escalation, and generic permission/auth/provider/rate-limit/policy/trust blockers cannot trigger a stronger tier.
- [x] Retry and capability-escalation selection cannot silently downgrade; any initial adaptive downgrade reports the selected model's actual tier, variant, candidate index, and telemetry.
- [x] Routing decisions join canonical work sessions to outcomes, tokens, and cost without accidental session IDs being treated as model IDs.
- [x] Interactive, routine, and closeout feedback remains silent without routed evidence and deduplicates unchanged summaries.
- [x] Existing pre-routing observability databases add routing columns before their indexes without losing historical requests.
- [x] Parallel generated-agent children preserve restrictive permissions and tier metadata instead of losing an unexported helper dependency.
- [x] Focused Node/shell regressions and `.agents/scripts/linters-local.sh` pass.

## Context & Decisions

- Provider neutrality belongs in declarative workload tiers; concrete provider/model/variant resolution belongs at the latest safe execution boundary.
- Runtime environment metadata is more specific than generic root-profile inference and therefore takes precedence in observability.
- Exact model-authored capability evidence is the only safe cross-tier signal; infrastructure and authority failures remain separate terminal classifications.
- Pattern-driven downgrade is an initial-dispatch optimization only; retries and capability escalation use exact-tier selection, while initial selection reconciles routing metadata to the concrete model's configured tier.
- Feedback recommendations require repeated evidence and canonical parent-session grouping to avoid noisy or misleading optimization advice.
- Disabled-tier validation precedes fallible OpenCode session/provider discovery so metadata failures cannot silently inherit a model for a route the operator explicitly disabled.
- Restrictive generated profiles use a helper dependency across an exported xargs shell boundary, so that dependency is explicitly exported and verified through the production parallel path rather than only by parent-shell unit calls.
- The maintainer explicitly authorized a patch release and incremental local deployment in this session; publication still uses only the canonical release helper.

## Relevant Files

- `.agents/configs/model-routing-table.json` — canonical candidates, variants, and escalation order.
- `.agents/scripts/shared-model-tier.sh` — shell overlay, candidate, variant, and escalation APIs.
- `.agents/plugins/opencode-aidevops/model-routing.mjs` — JavaScript overlay and route resolution.
- `.agents/scripts/headless-runtime-run.sh` — same-tier retry and capability escalation orchestration.
- `.agents/plugins/opencode-aidevops/observability.mjs` — routing/outcome/token/cost persistence and joins.
- `.agents/scripts/routing-feedback.mjs` — shared analyzer and deterministic CLI.
- `.agents/scripts/tests/test-headless-routing-retry.sh` — trust-boundary and retry regressions.
- `.agents/plugins/opencode-aidevops/tests/test-routing-feedback.mjs` — canonical feedback-session and recommendation regressions.

## Dependencies

- **Blocked by:** none
- **Blocks:** provider-neutral runtime tuning based on joined production outcomes.
- **External:** Authenticated GitHub release channels and at least one worker provider account are required only after merge.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Review and gap repair | 1h 30m | Cross-runtime routing, telemetry, and feedback review |
| Focused verification | 1h | Node/shell matrix and clean-HEAD isolation |
| Quality/refactor | 30m | Repeated-literal and function-complexity ratchets |
| Full-loop release/runtime validation | 1h | PR, CI, patch release, update, worker smoke test |
| **Total** | **4h** | |
