<!-- aidevops:brief-schema=v2 -->

# t18239: Integrate an end-to-end branded growth campaign command and verification scenario

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: orchestration must call existing owners, keep lifecycle truth, approvals, receipts, resumability, and progressive disclosure; do not add a marketing-brain agent
- [x] Discovery pass: campaign CLI/plane, content orchestration/fanout, outbound queue, provider health, performance/report owners, and task command patterns reviewed; no open duplicate issue
- [x] File refs verified: likely orchestration, docs, registry, and test parent paths present at `45cd1150e`; new helper/test paths explicitly marked
- [x] Tier: `tier:standard` — predecessor phases decide schemas and trust boundaries; this phase integrates their exported contracts
- [x] Seeded draft PR decision recorded: skipped — final APIs do not exist until predecessors merge

## Origin

- **Created:** 2026-08-13
- **Session:** OpenCode interactive branded-growth planning session
- **Created by:** ai-interactive
- **Parent task:** t18230 / GH#30136
- **Blocked by:** t18240 / #30147 plus all preceding functional phases; `blocked-by:t18240`
- **Conversation context:** Give users one coherent starting point and prove the complete branded growth lifecycle without hiding domain ownership or bypassing consequential approvals.

## What

Expose one progressive-discovery `aidevops campaign grow` (or evidence-equivalent command chosen from current CLI conventions) orchestration surface that accepts or references brand/product/offer intake and goals, then coordinates existing owners for research, creative briefs, production jobs/assets, review, scheduling, approved channel distribution, provider receipts/health, outcome ingestion, reporting, and growth recommendations. Add status/plan/resume/dry-run controls and a complete hermetic fixture-backed scenario, including failure/recovery and approval boundaries.

## Why

The preceding phases create interoperable capabilities, but users need a simple entry point and auditable state machine. A full fixture verifies that all contracts compose and that no stage claims completion prematurely.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** Predecessors resolve architecture/security decisions; this phase composes stable CLIs/schemas and writes integration/recovery tests.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Wait for predecessor exported contracts; otherwise a seed would encode imaginary APIs.
- **Status:** `not-created`
- **Freshness evidence:** Current orchestration surfaces inspected at `45cd1150e`.
- **Verification run:** `UNVERIFIED — planning only`
- **Stale-assumption warning:** Replace provisional command/file choices with actual predecessor exports before coding, while preserving acceptance boundaries.

## How (Approach)

### Progressive Context Plan

- **Read first:** predecessor leaf implementation notes and exported CLI/schema help; current campaign helper and campaigns-plane lifecycle.
- **Load only if:** a stage contract fails integration, then load only that owner (Content, Knowledge/social, Performance, Reports, etc.).
- **Why:** Keep orchestration thin and avoid duplicating specialist prompts/provider logic.
- **Stop when:** State machine, dry-run plan, approvals, receipts, resume keys, fixture, and user documentation are clear.

### Worker Quick-Start

```bash
aidevops campaign --help
rg -n 'campaign\)|cmd_.*campaign|_dispatch_helper.*campaign' .agents/scripts/aidevops.sh .agents/scripts/campaign-helper.sh
rg -n 'schema_version|status|operation_id|receipt|recommendation' .agents/schemas .agents/scripts | rg 'campaign|content-production|distribution|social-provider|marketing'
```

### Files to Modify

- `NEW: .agents/scripts/campaign-growth-helper.py` — thin state-machine orchestrator over predecessor contracts.
- `EDIT: .agents/scripts/aidevops.sh` — route the chosen campaign growth subcommand if current dispatch requires it.
- `EDIT: .agents/scripts/campaign-helper.sh` — expose/route plan/status/resume without copying stage logic.
- `EDIT: .agents/aidevops/campaigns-plane.md` — end-to-end lifecycle, state truth, and recovery.
- `EDIT: .agents/content.md` — concise discoverability pointer to the campaign growth flow.
- `EDIT: .agents/configs/capability-registry.json` — aggregate campaign-growth capability and degraded fallbacks.
- `NEW: .agents/scripts/tests/test-campaign-growth-e2e.py` — complete hermetic happy/failure/recovery/approval scenarios.
- `NEW: .agents/scripts/tests/fixtures/campaign-growth/` — synthetic brand, offer, evidence, media metadata, providers, metrics, and receipts.
- `NEW: .agents/workflows/campaign-growth.md` — progressive-disclosure user/agent workflow and recovery guidance.

### Complete Write Surface

- **Callers/readers:** `contract:` Users/agents, Campaigns Plane, Content, campaign research/production, outbound queue/provider health, Performance, Reports, recommendations.
- **Writers/mutation paths:** `contract:` Orchestrator state/checkpoint only; stage owners write campaign research/assets/distribution/receipts/performance/reports. The orchestrator must not write provider internals directly.
- **Tests/fixtures:** `contract:` New full E2E suite plus focused predecessor suites selected by changed contracts.
- **Schemas/config:** `contract:` Consume predecessor schemas and capability registry; add only orchestration checkpoint schema if current implementation needs one.
- **Generated/deployed mirrors:** `contract:` `.agents/` deploys; fixture artifacts remain synthetic; user campaign data stays in user planes.
- **Migrations/backfills:** `contract:` Existing campaigns can opt into orchestration by validation/import without rewrite; unsupported predecessor schema versions block with upgrade guidance.
- **Cleanup/rollback paths:** `contract:` Resume from durable stage/operation IDs; generated drafts may be rejected/archived; accepted remote actions are never undone implicitly.

### Implementation Steps

1. Inventory actual predecessor command/schema exports and define a thin stage graph: intake→research→brief/jobs→production/review→distribution plan/approval→queue/receipts→performance ingest→report/recommendation.
2. Define checkpoint/state truth: `not_started`, `ready`, `blocked`, `running`, `partial`, `review_required`, `approved`, `succeeded`, `failed`, `unknown`; each transition cites owner evidence.
3. Implement `plan`/dry-run that checks capabilities, sources, accounts, approvals, costs if known, missing inputs, channel rationale, and fallbacks without side effects.
4. Implement start/status/resume by invoking existing stage commands/helpers; never reproduce their research, creative, provider, or analysis logic.
5. Stop at review/approval gates. Publishing/outreach/budget/audience/offer/account mutations remain separately approved; absence of approval is a normal blocked state.
6. Build a hermetic synthetic fixture: supplied brand/offer → cited research → several channel-native creative jobs → synthetic approved assets → X/Reddit plus fixture new-provider queue receipts → reach/conversion/lead/sale/revenue/refund/cost metrics → report/recommendation.
7. Add negative scenarios: missing evidence, unlicensed asset, unsupported provider, expired approval, rate limit, accepted-but-unknown publish, duplicate resume, partial metrics, suppression, insufficient experiment evidence.
8. Document user inputs, expected artifacts, human decisions, degraded operation, resume/reconcile, and where each specialist owner is discovered.

### Hazards and Compatibility

- **Concurrency/atomicity:** One campaign orchestration lease/checkpoint generation owns transitions; stage operations use stable IDs and their own fences.
- **Migration/rollback:** Existing campaigns remain usable manually; checkpoint migration is versioned and stage outputs remain authoritative.
- **Mixed-version/backward compatibility:** Detect predecessor schema/capability versions and block unsupported automation without corrupting manual workflows.
- **Idempotency/retry:** Resume invokes/reconciles existing operation IDs and source hashes; it never repeats a remote mutation or duplicates assets/events.
- **Partial failure/recovery:** Preserve successful stages/siblings, explicit blockers/unknowns, and next safe action; a stopped route does not close the objective.

### Verification Before Dispatch

```bash
python3 -m unittest .agents/scripts/tests/test-campaign-growth-e2e.py
bash .agents/scripts/tests/test-campaign-status-routing.sh
python3 -m json.tool .agents/configs/capability-registry.json >/dev/null
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** E2E fixtures prove composition, state truth, approvals, receipts, outcomes, recommendations, idempotent resume, and recovery; status/registry/lint protect routing/docs/config.
- **Broad verification trigger:** Run every predecessor focused suite whose exported contract is changed during integration; avoid a generic full-repository gate unless shared root CLI/config requires it.

### Recoverability Checkpoint

- [ ] Focused E2E and campaign status tests pass
- [ ] WIP commit created before broad gates: `wip: integrate campaign growth workflow`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed` plus changed predecessor suites

### Safety-Stop Recovery

- **Original objective:** Deliver and prove the complete end-to-end branded growth system.
- **Preserved user directions:** High-quality, believable, authentic business development across relevant sales and marketing channels, optimizing reach, conversion, account growth, leads, and sales.
- **Trigger and evidence:** `not triggered`
- **Completed and verified:** none at dispatch
- **Remaining acceptance criteria:** all below
- **Unsafe route not to repeat:** bypassing approvals, repeating unknown remote mutations, or reporting partial stages as complete
- **Next safe route:** checkpoint, reconcile owner evidence, use dry-run/degraded fallback, and resume the blocked stage
- **Resume condition:** blocker is resolved or a safe alternate capability is selected
- **Owner and status:** dispatched worker; `not-triggered`

### Files Scope

- `.agents/scripts/campaign-growth-helper.py`
- `.agents/scripts/aidevops.sh`
- `.agents/scripts/campaign-helper.sh`
- `.agents/aidevops/campaigns-plane.md`
- `.agents/content.md`
- `.agents/configs/capability-registry.json`
- `.agents/scripts/tests/test-campaign-growth-e2e.py`
- `.agents/scripts/tests/fixtures/campaign-growth/*`
- `.agents/workflows/campaign-growth.md`

## Acceptance Criteria

- [ ] One dry-run plan accepts/references a brand/product/offer and reports proposed research, channels, creative variants, capabilities, human approvals, artifacts, metrics, and fallbacks without mutation.
- [ ] The hermetic happy-path fixture completes intake→research→creative/production→review→approved distribution receipts→performance/report→recommendation with every stage backed by owner evidence.
- [ ] Missing evidence, unlicensed assets, unsupported/unhealthy providers, absent/expired approval, suppression, or insufficient outcome evidence halt only the affected route and never become false success.
- [ ] Re-running/resuming after interruption or unknown provider outcome reuses/reconciles stable operation IDs and creates no duplicate remote action, asset, event, report, or recommendation.
- [ ] The orchestrator remains thin: specialist logic stays in existing owners and no duplicate generic growth, media, scheduler, publisher, CRM, or analytics agent is introduced.

## Context & Decisions

- One user-facing orchestration surface, many progressively discovered specialist owners.
- Dry-run and fixture verification are required; live provider credentials/actions are not.
- Full completion means business-outcome learning, not merely generated prompts, assets, or scheduled posts.

## Relevant Files

- `.agents/aidevops/campaigns-plane.md:14-29,31-58,151-230`
- `.agents/scripts/campaign-helper.sh`
- `.agents/content.md:70-110`
- `.agents/aidevops/knowledge-plane/05-social-operations.md:276-350`
- `.agents/aidevops/performance.md:4-28,55-107`
- `.agents/reports/marketing.md`
- `.agents/configs/capability-registry.json`

## Dependencies

- **Blocked by:** t18240 / #30147 and all predecessor functional phases
- **Blocks:** parent closeout after verified completion
- **External:** No live providers required for acceptance; hermetic fixtures prove orchestration.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Research/read | 1.5h | Map actual predecessor exports |
| Implementation | 5h | State machine, routing, docs |
| Testing | 3h | Full happy/negative/recovery fixtures |
| **Total** | **~9.5h** | |
