<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18192: Pulse: refill all available worker slots immediately after worker exit

## Pre-flight

- [x] Memory recall: `Pulse event-driven refill parallel full-loop claim release architecture implementation` → 0 hits; current-session evidence retained.
- [x] Discovery pass: recent dispatch changes reviewed; 0 merged or open PRs implement worker-exit-triggered refill.
- [x] File refs verified: lifecycle observer, wrapper mode dispatch, parallel capacity fill, and focused test surfaces exist at current HEAD.
- [x] Tier: `tier:thinking` — this changes the self-hosting dispatch path and concurrent scheduler state.
- [x] Seeded draft PR decision recorded: skipped — runtime-safe coordination must be implemented and tested first.

## Origin

- **Created:** 2026-08-04
- **Session:** OpenCode interactive session for GH#29448
- **Created by:** AI DevOps (ai-interactive)
- **Parent task:** none; this is a leaf implementation issue.
- **Blocked by:** none.
- **Conversation context:** The user confirmed that Pulse must run several isolated `/full-loop` sessions in parallel, preserve claim/release comments, and continue through an aidevops release.

## What

Add a coalesced event-driven Pulse refill path. When a detached worker terminates,
signal Pulse immediately and fill every currently available local worker slot
through the existing parallel `dispatch_max` path. Keep the periodic Pulse cycle
as reconciliation fallback.

## Why

Production evidence on 2026-08-03 showed 24 configured slots, 21 free, two
eligible issues, and zero launches in 15 minutes. Worker execution was healthy
(14/15 terminal sessions reached runtime handoff), while initial dispatch
p50/p95 was about 324s/1548s and refill p95 about 1979s. The lifecycle observer
detects exits every five seconds but currently only appends a log line.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** The behavior is decided, but this is a high-risk scheduler
state-machine change in the self-hosting dispatch path. Concurrency, retry,
mixed-version, and crash-recovery behavior require runtime verification.

## PR Conventions

This is a leaf issue. The implementation PR uses `Resolves #29448`.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** A seed would anchor the worker before lock and trigger behavior is verified.
- **Status:** `not-created`
- **Freshness evidence:** Memory, issue/PR discovery, recent commits, and file references checked against current HEAD.
- **Verification run:** Focused event-refill, lifecycle, wrapper, concurrency, ShellCheck, portability, and changed-file gates pass; release gates remain pending.
- **Stale-assumption warning:** Recheck the lifecycle observer and `dispatch_max` call path after any rebase touching Pulse dispatch files.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/pulse-dispatch-worker-launch.sh:1283-1389`, `.agents/scripts/pulse-wrapper.sh:1463-1516,1753-1905`, and `.agents/scripts/pulse-dispatch-engine.sh:502-643` — these define the terminal event, wrapper mode, and parallel-fill boundaries.
- **Load only if:** `.agents/reference/cross-runner-coordination.md` when distributed claim behavior changes; `.agents/reference/auto-dispatch.md` when lifecycle labels change.
- **Why:** The refill path must reuse existing authority and ownership gates instead of creating a direct-spawn scheduler.
- **Stop when:** one terminal event can safely request a full capacity refill without bypassing `dispatch_max` or GitHub claims.

### Worker Quick-Start

```bash
rg -n '_dlw_spawn_lifecycle_observer|worker_exited' .agents/scripts/pulse-dispatch-worker-launch.sh
rg -n '_pulse_setup_merge_only_mode|_pulse_run_merge_only|main\(\)' .agents/scripts/pulse-wrapper-bootstrap.sh .agents/scripts/pulse-wrapper.sh
rg -n 'dispatch_max\(\)|apply_dispatch_max' .agents/scripts/pulse-dispatch-engine.sh
```

### Files to Modify

- `EDIT: .agents/scripts/pulse-dispatch-worker-launch.sh:1283-1389` — publish a durable refill trigger after observing worker termination and invoke lightweight refill mode.
- `EDIT: .agents/scripts/pulse-wrapper.sh:1463-1516,1753-1905` — recognize refill-only mode and drain pending triggers under the Pulse instance lock.
- `NEW: .agents/scripts/pulse-event-refill.sh` — implement parsing, atomic trigger state, wake coalescing, lock-safe refill execution, recovery, and telemetry.
- `EDIT: .agents/scripts/pulse-wrapper-config.sh` — define the default-enabled feature gate and bounded wait/pass settings.
- `REFERENCE: .agents/scripts/pulse-dispatch-engine.sh:502-643` — reuse existing parallel capacity fill; do not add a direct-spawn bypass.
- `NEW: .agents/scripts/tests/test-pulse-event-refill.sh` — event, coalescing, full-deficit fill, stop-gate, and stale-trigger coverage.
- `EDIT: CHANGELOG.md` — record the user-visible throughput improvement under Unreleased.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/pulse-dispatch-worker-launch.sh` writes the trigger; `.agents/scripts/pulse-wrapper.sh` refill-only and normal Pulse paths drain it; operators read Pulse logs and stats.
- **Writers/mutation paths:** `.agents/scripts/pulse-dispatch-worker-launch.sh` writes one machine-local trigger under the existing aidevops cache root; `.agents/scripts/pulse-wrapper.sh` removes it only while holding the Pulse instance lock. No repository or GitHub state is mutated directly by the trigger.
- **Dispatch lifecycle:** `dispatch_max` continues through `dispatch_with_dedup`, distributed claims, assignment/status updates, worker launch, release cleanup, and completion/blocker comments.
- **Tests/fixtures:** `NEW: .agents/scripts/tests/test-pulse-event-refill.sh`; existing wrapper characterization, worker-detection, minimum-concurrency, claim, and release tests remain regression coverage.
- **Schemas/config:** `N/A because` the trigger is presence-only disposable state; the environment escape hatch in `.agents/scripts/pulse-wrapper-config.sh` disables event refill while periodic scheduling remains active.
- **Generated/deployed mirrors:** `setup.sh --non-interactive` deploys `.agents/scripts/` only after the authorized release converges.
- **Migrations/backfills:** `N/A because` no durable schema is introduced; stale trigger state under the existing cache root is disposable and self-draining.
- **Cleanup/rollback paths:** `.agents/scripts/pulse-wrapper.sh` drains stale triggers; disabling the event-refill gate or reverting the change restores timer-only behavior.

### Implementation Steps

1. Record a refill trigger before the lifecycle observer exits.
2. Invoke a lightweight `--refill-only` Pulse path that skips full preflight and LLM work.
3. Serialize refill against the main Pulse instance lock and coalesce simultaneous worker exits.
4. Drain the trigger and call existing `apply_dispatch_max`/`dispatch_max`, so one event can replace every missing worker within configured capacity and parallelism.
5. If a normal Pulse cycle owns the lock, retain the trigger and let that cycle drain it before expensive optional work or at its final deterministic refill boundary.
6. Preserve claim/release comments and status transitions by never bypassing `dispatch_with_dedup` or worker lifecycle cleanup.
7. Add structured trigger, refill, coalesced, disabled, and blocked telemetry with a safe environment escape hatch.

### Hazards and Compatibility

- **Concurrency/atomicity:** simultaneous exits must not oversubscribe capacity or launch duplicate issues. Pulse lock ownership plus existing distributed GitHub claims remain mandatory.
- **Migration/rollback:** no migration. Disabling event refill immediately restores timer-only behavior.
- **Mixed-version/backward compatibility:** old workers omit triggers, so periodic scheduling remains fallback; new observers tolerate an older wrapper without refill mode.
- **Idempotency/retry:** repeated triggers may cause repeated capacity checks but never duplicate ownership. A trigger arriving during a refill remains pending for another pass.
- **Partial failure/recovery:** retain trigger evidence when lock acquisition or dispatch fails. Stop flags, provider/rate limits, runner health, trust, dependency, and circuit breakers still block launch.
- **Portability:** preserve Bash 3.2 and macOS/Linux behavior; do not introduce `flock` or `wait -n` outside existing compatibility wrappers.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-pulse-event-refill.sh
bash .agents/scripts/tests/test-pulse-wrapper-characterization.sh
bash .agents/scripts/tests/test-pulse-wrapper-worker-detection.sh
bash .agents/scripts/tests/test-dispatch-min-concurrency.sh
shellcheck .agents/scripts/pulse-dispatch-worker-launch.sh .agents/scripts/pulse-event-refill.sh .agents/scripts/pulse-wrapper-config.sh .agents/scripts/pulse-wrapper.sh .agents/scripts/tests/test-pulse-event-refill.sh
.agents/scripts/linters-local.sh --changed
```

- **Runtime verification:** terminate several fake detached workers, verify one coalesced trigger invokes the existing parallel dispatch path once, fills the full configured deficit, and does not directly spawn or bypass claim functions.
- **Surface mapping:** `test-pulse-event-refill.sh` covers trigger writers/readers and lock recovery; wrapper characterization covers CLI mode parsing; worker-detection and minimum-concurrency tests protect existing lifecycle and parallel-capacity dispatch.
- **Broad gate trigger:** shared Pulse and release-deployed shell paths change, so run the repository-required release preflight after focused checks.
- **Recoverability checkpoint:** create a WIP commit after focused runtime tests pass and before broad gates.

### Safety-Stop Recovery

- **Original objective:** event-driven parallel refill with existing claim/release audit behavior.
- **Preserved user directions:** complete full-loop through merge, patch release, incremental deployment, and cleanup.
- **Unsafe route not to repeat:** do not call worker launch directly from the lifecycle observer and do not bypass GitHub claim fencing.
- **Next safe route after a fuse:** keep the trigger pending, retain periodic fallback, reduce test concurrency, and resume from the WIP commit.

### Files Scope

- `.task-counter` (synchronize the already-claimed `origin/task-id-counter` state through `t18192`)
- `.agents/scripts/pulse-dispatch-worker-launch.sh`
- `.agents/scripts/pulse-event-refill.sh`
- `.agents/scripts/pulse-wrapper-config.sh`
- `.agents/scripts/pulse-wrapper.sh`
- `.agents/scripts/tests/test-pulse-event-refill.sh`
- `.agents/scripts/tests/test-pulse-wrapper-characterization.sh`
- `.agents/scripts/tests/test-pulse-wrapper-dry-run-bootstrap.sh`
- `.agents/scripts/tests/test-worker-lifecycle-exit-emit.sh`
- `CHANGELOG.md`
- `TODO.md`
- `todo/tasks/t18192-brief.md`

## Acceptance Criteria

- [x] A worker terminal event requests refill without waiting for the 180-second scheduler interval.
- [x] One refill pass targets all free slots through existing bounded parallel dispatch.
- [x] Simultaneous exit events coalesce and cannot oversubscribe configured capacity.
- [x] GitHub claim/release comments, assignment/status transitions, trust checks, dependency checks, and circuit breakers remain mandatory.
- [x] A busy Pulse lock, stopped Pulse, unavailable GitHub, or disabled feature produces no unsafe launch and retains recoverable trigger evidence.
- [x] Periodic Pulse scheduling remains a compatibility and crash-recovery fallback.
- [ ] Focused runtime, ShellCheck, changed-file, CI, review, release, publication, and deployment gates pass.

## Verification Evidence

- Event-refill regression suite: 26/26 assertions pass, including burst coalescing, full-deficit delegation, stale processing/wake recovery, stop/circuit retention, and real `--refill-only` CLI short-circuiting.
- Worker lifecycle observer: 5/5 assertions pass; wrapper characterization: 42/42 assertions pass.
- Existing parallel-dispatch (24/24), singleton-lock (8/8), dry-run bootstrap (7/7), and minimum-concurrency (24/24) suites pass.
- Direct `bash -n`, ShellCheck, `git diff --check`, Bash 3.2 diff ratchet, shell portability, complexity diff ratchets, secret scanning, and changed-file lint pass.
- Full repository lint reaches pre-existing global ratchet-schema, complexity-debt, and nesting-debt failures; the diff-scoped gates report zero new regressions.
- Three successful-dispatch fixtures in `test-pulse-wrapper-worker-detection.sh` also fail on an archived clean base revision, so they are recorded as baseline failures rather than event-refill regressions.

## Context & Decisions

- Keep persistent deterministic scheduler state separate from ephemeral per-issue LLM context.
- This leaf delivers event-driven capacity refill; revision-keyed ready projections and authoritative cross-runner campaign lanes remain separable future improvements.
- GitHub claims remain the distributed safety kernel and audit authority.
- Local terminal evidence may trigger scheduling immediately, but an issue cannot launch until its remote claim is confirmed.

## Dependencies

- **Blocked by:** none.
- **Blocks:** authoritative campaign dispatch and fleet-wide work stealing can build on this event path.
- **External:** existing Bash, GitHub CLI, jq, and local scheduler services; no new dependency or secret.
