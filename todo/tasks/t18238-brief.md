<!-- aidevops:brief-schema=v2 -->

# t18238: Add social provider health rate-limit and receipt reconciliation

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: provider readiness must distinguish catalogued through usable; rate limits and ambiguous outcomes require content-free shared health evidence
- [x] Discovery pass: capability registry, social capability matrix, collector health, outbound receipts/reconciliation, and rate-limit config reviewed; no open duplicate issue
- [x] File refs verified: 10 health/queue/config/doc/test surfaces present or intentionally new at `45cd1150e`
- [x] Tier: `tier:standard` — health vocabulary and source owners are known; implementation aggregates without changing authorization
- [x] Seeded draft PR decision recorded: skipped — provider adapter files may change in predecessor phases

## Origin

- **Created:** 2026-08-13
- **Session:** OpenCode interactive branded-growth planning session
- **Created by:** ai-interactive
- **Parent task:** t18230 / GH#30136
- **Blocked by:** t18237 / #30143 and t18235 / #30141; `blocked-by:t18237,t18235`
- **Conversation context:** Make multichannel campaign planning truthful about what providers can do now, why they cannot, and whether remote outcomes are reconciled.

## What

Add one content-free social provider status/readiness surface that aggregates capability dimensions, configured/authenticated/authorized/reachable/usable state, supported read/write actions, exact selected account alias, quotas/rate resets/cooldowns, queue backlog/leases, publish job states, unresolved unknown receipts, freshness, last success/failure class, and safe fallback/next action. Add bounded reconciliation commands/routines that resolve due jobs without comment/log storms or duplicate mutation.

## Why

Provider capability facts exist across docs, registry, collectors, queue receipts, and rate-limit config. Campaign orchestration cannot safely select channels or retry failures without a normalized current-state view.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** This is aggregation and reconciliation over established state, with known privacy and retry invariants.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Wait for predecessor adapter structures, then implement against their actual exported status contracts.
- **Status:** `not-created`
- **Freshness evidence:** Current health/registry/queue surfaces inspected at `45cd1150e`.
- **Verification run:** `UNVERIFIED — planning only`
- **Stale-assumption warning:** Recheck merged Meta/TikTok/LinkedIn/YouTube adapter status schemas before implementing.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/configs/capability-registry.json`, `_knowledge_collector_health.py`, outbound runtime/reconciliation, and provider capability matrix.
- **Load only if:** a provider lacks a common status export, then inspect only that provider module.
- **Why:** Aggregate stable summaries without reading campaign content or duplicating provider logic.
- **Stop when:** Status schema, freshness, quotas, unknown reconciliation, routine bounds, and redaction are explicit.

### Worker Quick-Start

```bash
rg -n 'status|fresh|cooldown|rate|reset|unknown|receipt|reconcile' .agents/scripts/_knowledge_collector_health.py .agents/scripts/_knowledge_social_outbound*.py .agents/configs/rate-limits.json.txt
python3 -m json.tool .agents/configs/capability-registry.json >/dev/null
```

### Files to Modify

- `NEW: .agents/schemas/social-provider-health.schema.json` — normalized, content-free readiness/health output.
- `NEW: .agents/scripts/social-provider-health.py` — collect/status/reconcile/report CLI.
- `EDIT: .agents/scripts/_knowledge_collector_health.py` — expose reusable read-health records without widening collection authority.
- `EDIT: .agents/scripts/_knowledge_social_outbound_runtime.py` — bounded health/job counters.
- `EDIT: .agents/scripts/_knowledge_social_outbound_reconciliation.py` — due/unknown reconciliation interface and summary.
- `EDIT: .agents/scripts/knowledge-social-helper.sh` — route provider-health commands.
- `EDIT: .agents/configs/capability-registry.json` — social publishing/research capabilities and probes.
- `EDIT: .agents/configs/rate-limits.json.txt` — verified provider budgets and shared cooldown semantics.
- `EDIT: .agents/aidevops/knowledge-plane/06-social-provider-capabilities.md` — status output and truthful readiness contract.
- `NEW: .agents/scripts/tests/test-social-provider-health.py` — freshness, aggregation, redaction, cooldown, and reconcile fixtures.

### Complete Write Surface

- **Callers/readers:** `contract:` Campaign/channel selection, distribution preview, operators, routines, Reports, and provider adapters.
- **Writers/mutation paths:** `contract:` Health snapshots/cache, provider cooldown state, queue reconciliation attempts/receipts; no content or new publish intent.
- **Tests/fixtures:** `contract:` New health suite and all shared outbound tests; collector health tests discovered at implementation.
- **Schemas/config:** `contract:` New health schema; capability registry and rate-limit template.
- **Generated/deployed mirrors:** `contract:` `.agents/` deployment; local health state stays in agent workspace and excludes secrets/content.
- **Migrations/backfills:** `contract:` Missing provider status maps to `unknown/unconfigured`; no historical backfill required.
- **Cleanup/rollback paths:** `contract:` Atomic snapshot replacement; corrupt/stale cache is ignored and rebuilt; reconciliation receipts remain append-only/auditable.

### Implementation Steps

1. Define provider/account/action health records with capability dimensions, freshness, quota/reset, backlog, unknown count, last terminal evidence, and next safe action.
2. Add pure adapters that read existing collector/queue/provider status without importing secrets or content into output.
3. Distinguish absent configuration, invalid auth, missing authorization, unreachable, rate-limited, provider incident, unsupported action, stale data, and ambiguous remote outcome.
4. Aggregate per-provider and all-provider JSON/human summaries; channel selection consumes `usable` evidence rather than documentation presence.
5. Add bounded due/unknown reconciliation with leases, backoff, per-provider budgets, and cooldown; repeated resets pause instead of creating noise.
6. Add a routine-ready command that does not publish, approve, change account settings, or contact external recipients.
7. Test multi-account isolation, stale snapshots, secret/content redaction, partial provider failures, replay, cooldown, and unknown→terminal transitions.

### Hazards and Compatibility

- **Concurrency/atomicity:** Reconciliation uses existing leases/fencing; health snapshot writes are atomic and cannot claim freshness beyond source evidence.
- **Migration/rollback:** Additive schema; old providers without exporters show unknown, not failed or usable.
- **Mixed-version/backward compatibility:** Missing new fields default conservatively; existing queue/collector behavior is unchanged.
- **Idempotency/retry:** Health collection is read-only/idempotent; reconciliation reuses operation/job IDs and cooldown state.
- **Partial failure/recovery:** One provider error yields a partial aggregate with per-provider evidence; successful sibling states remain visible.

### Verification Before Dispatch

```bash
python3 -m unittest .agents/scripts/tests/test-social-provider-health.py
python3 -m unittest discover -s .agents/scripts/tests -p '*social*outbound*.py'
python3 -m json.tool .agents/schemas/social-provider-health.schema.json >/dev/null
python3 -m json.tool .agents/configs/capability-registry.json >/dev/null
shellcheck .agents/scripts/knowledge-social-helper.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Health tests prove aggregation/freshness/redaction/cooldown/reconciliation; shared outbound tests protect mutation/idempotency; schema/config/lint protect routing.
- **Broad verification trigger:** Not required beyond affected social/collector suites unless shared Knowledge Plane storage is changed.

### Recoverability Checkpoint

- [x] Focused tests pass: health and shared outbound suites
- [x] WIP commit created before broad gates: `276ac4c45` (`wip: add social provider health`)
- [x] Evidence-triggered broad verification run: `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Provide truthful provider readiness and bounded reconciliation.
- **Preserved user directions:** Reliable end-to-end multichannel growth operations.
- **Trigger and evidence:** `not triggered`
- **Completed and verified:** none at dispatch
- **Remaining acceptance criteria:** all below
- **Unsafe route not to repeat:** unbounded polling, bypassing rate resets, or retrying ambiguous mutations
- **Next safe route:** cooldown, bounded provider-specific reconciliation, and partial health reporting
- **Resume condition:** rate/reset or provider reachability permits another bounded attempt
- **Owner and status:** dispatched worker; `not-triggered`

### Files Scope

- `.agents/schemas/social-provider-health.schema.json`
- `.agents/scripts/social-provider-health.py`
- `.agents/scripts/_knowledge_collector_health.py`
- `.agents/scripts/_knowledge_social_outbound_runtime.py`
- `.agents/scripts/_knowledge_social_outbound_reconciliation.py`
- `.agents/scripts/knowledge-social-helper.sh`
- `.agents/configs/capability-registry.json`
- `.agents/configs/rate-limits.json.txt`
- `.agents/aidevops/knowledge-plane/06-social-provider-capabilities.md`
- `.agents/scripts/tests/test-social-provider-health.py`

## Acceptance Criteria

- [ ] JSON and human status accurately distinguish documented, configured, authenticated, authorized, reachable, rate-limited, stale, and usable provider/action/account states.
- [ ] Outputs and logs contain no credentials or campaign content and do not mix account aliases or receipts across accounts.
- [ ] Due/unknown reconciliation is bounded, lease-safe, cooldown-aware, and never creates a second publish intent.
- [ ] One failed provider produces a truthful partial aggregate without hiding healthy siblings or reporting global success.
- [ ] Campaign distribution can select only currently usable actions and explain a blocked/fallback decision from health evidence.

## Context & Decisions

- Health aggregation is a helper/service capability, not a new social strategy agent.
- Readiness is multidimensional; deployed documentation is not equivalent to authenticated, authorized, reachable, or usable.
- Repeated rate-limit resets pause work; they never justify comment/log storms or bypasses.

## Relevant Files

- `.agents/configs/capability-registry.json:1-76`
- `.agents/configs/rate-limits.json.txt`
- `.agents/scripts/_knowledge_collector_health.py`
- `.agents/scripts/_knowledge_social_outbound_runtime.py`
- `.agents/scripts/_knowledge_social_outbound_reconciliation.py`
- `.agents/aidevops/knowledge-plane/06-social-provider-capabilities.md`

## Dependencies

- **Blocked by:** t18237 / #30143 and t18235 / #30141
- **Blocks:** t18236 / #30142
- **External:** No live credentials required; fixture status providers prove behavior.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Research/read | 1h | Status exports and registry patterns |
| Implementation | 4h | Schema, aggregation, routing, reconciliation |
| Testing | 1.5h | Multi-provider/cooldown/redaction matrix |
| **Total** | **~6.5h** | |
