<!-- aidevops:brief-schema=v2 -->

# t18232: Bridge reviewed campaign schedules into the approval-bound outbound queue

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: existing outbound queue owns approval, immutable intent hashes, leases, receipts, unknown reconciliation, and X/Reddit execution
- [x] Discovery pass: campaign/calendar/fanout/queue paths and recent X/Reddit work reviewed; no open duplicate bridge issue
- [x] File refs verified: 10 bridge, queue, docs, config, and test surfaces present at `45cd1150e`
- [x] Tier: `tier:standard` — queue remains the decided mutation boundary; implementation adds a bounded producer and status projection
- [x] Seeded draft PR decision recorded: skipped — queue schema and calendar helper complexity need worker revalidation

## Origin

- **Created:** 2026-08-13
- **Session:** OpenCode interactive branded-growth planning session
- **Created by:** ai-interactive
- **Parent task:** t18230 / GH#30136
- **Blocked by:** t18233 / #30139; `blocked-by:t18233`
- **Conversation context:** Connect approved campaign assets and schedules to the existing social mutation system without building a second scheduler or publisher.

## What

Define one canonical campaign distribution record/channel vocabulary and add an idempotent bridge from reviewed campaign production manifests and content-calendar entries into the existing Knowledge Plane outbound queue. Support preview/dry-run, explicit approval, stable schedule/operation keys, status/receipt projection back to campaign/calendar records, and safe reconciliation of unknown outcomes. Initially prove the bridge with existing X and Reddit providers; no new provider implementation belongs in this issue.

## Why

Campaigns, fanout, and content calendar currently prepare content independently from the approval-bound queue. Reusing the queue preserves its trust, lease, receipt, and reconciliation guarantees while eliminating manual re-entry and status drift.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The cross-system ownership and security boundary are already decided; implementation must adapt known schemas, IDs, and recovery paths.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** A safe implementation depends on current queue APIs and shell complexity measurements.
- **Status:** `not-created`
- **Freshness evidence:** Repository and GitHub discovery completed against `45cd1150e`.
- **Verification run:** `UNVERIFIED — planning only`
- **Stale-assumption warning:** Recheck outbound operation schema/provider actions and calendar changes before editing.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/aidevops/knowledge-plane/05-social-operations.md:276-350`, `_knowledge_social_outbound*.py`, and content calendar schema/schedule/advance paths.
- **Load only if:** campaign/fanout status mapping is unclear, then inspect `campaign-helper.sh` and `content-fanout-helper.sh:537`.
- **Why:** Treat the queue as the only social mutation executor and the campaign/calendar as producers/read models.
- **Stop when:** Distribution IDs, channel mapping, approval/dry-run, status projection, retry, and unknown reconciliation are explicit.

### Worker Quick-Start

```bash
rg -n 'OUTBOUND_PROVIDER_ACTIONS|approval|intent_hash|claim|receipt|unknown|reconcile' .agents/scripts/_knowledge_social_outbound*.py
rg -n 'CREATE TABLE|schedule|advance|publish|cadence' .agents/scripts/content-calendar-helper.sh
rg -n 'prompts_ready' .agents/scripts/content-fanout-helper.sh
```

### Files to Modify

- `NEW: .agents/schemas/campaign-distribution.schema.json` — canonical campaign/channel/asset/schedule/approval/operation/receipt projection.
- `NEW: .agents/scripts/campaign-distribution-helper.py` — validation, preview, enqueue, status, and reconciliation bridge.
- `EDIT: .agents/scripts/campaign-helper.sh` — route distribution preview/enqueue/status without provider execution.
- `EDIT: .agents/scripts/content-calendar-helper.sh` — validated schedule inputs, stable idempotency keys, bridge references, and receipt-derived status.
- `EDIT: .agents/scripts/content-fanout-helper.sh` — expose manifest references without changing `prompts_ready` semantics.
- `EDIT: .agents/configs/campaign-channel-specs.json` — canonical channel IDs/aliases shared with bridge.
- `EDIT: .agents/aidevops/knowledge-plane/05-social-operations.md` — document producer contract and unchanged approval boundary.
- `NEW: .agents/scripts/tests/test-campaign-distribution-bridge.py` — hermetic queue/calendar/campaign fixtures.
- `NEW: .agents/scripts/tests/test-content-calendar-safety.sh` — validation, duplicates, SQL safety, and status fixtures.

### Complete Write Surface

- **Callers/readers:** `contract:` Campaign CLI, content calendar, distribution-social coordinator, outbound queue operations list/status, provider phases.
- **Writers/mutation paths:** `contract:` Campaign distribution records; calendar SQLite rows; outbound operation intents/approvals/claims/receipts; projected campaign/calendar status.
- **Tests/fixtures:** `contract:` New bridge and calendar safety suites; existing outbound provider tests if present must remain green.
- **Schemas/config:** `contract:` New distribution schema and canonical channel mapping; queue operation schema remains authoritative.
- **Generated/deployed mirrors:** `contract:` `.agents/` deployment; user campaign/calendar/queue data stay in their existing local planes/databases.
- **Migrations/backfills:** `contract:` Add nullable/stable-key fields to calendar safely; existing rows remain readable and are not auto-enqueued.
- **Cleanup/rollback paths:** `contract:` Failed enqueue leaves source `approved_not_queued`; queue cancellation/rejection/unknown remain auditable and never imply publication.

### Implementation Steps

1. Define stable campaign, creative variant, destination, schedule, and operation IDs; normalize channel aliases at the bridge boundary.
2. Harden calendar date/time/content inputs and parameterize SQL; add uniqueness/idempotency constraints with safe migration.
3. Implement preview that validates approved production assets, destination capability, text/media limits, alt text/disclosures, schedule, and account alias without mutation.
4. Enqueue only after explicit queue approval requirements are satisfied; never copy secrets or provider-specific execution logic into the bridge.
5. Prove X and Reddit bridge behavior using the existing `xapi`/`reddit` actions.
6. Project status from queue evidence only: queued/claimed/unknown/failed/succeeded/remote ID; do not infer success from process exit alone.
7. Preserve unknown outcomes for reconciliation and make replay reuse the same intent hash/operation rather than duplicate publication.

### Hazards and Compatibility

- **Concurrency/atomicity:** Calendar/source projection and queue enqueue cannot be one transaction; use durable intent ID plus convergent reconciliation.
- **Migration/rollback:** Calendar schema migration is staged/backed up; old rows stay valid and never become automatically dispatchable.
- **Mixed-version/backward compatibility:** Campaigns/calendars without distribution records remain manual; queue schema remains compatible with X/Reddit.
- **Idempotency/retry:** Stable intent hashes prevent duplicate remote posts when bridge/worker retries.
- **Partial failure/recovery:** If enqueue succeeds but source projection fails, reconciliation locates operation by intent ID; `unknown` is never converted to failed/succeeded without evidence.

### Complexity Impact

- **Target function:** calendar scheduling/advance functions and campaign command dispatcher.
- **Current line count:** measure before edits; threshold 100 lines.
- **Estimated growth:** high if bridge logic is embedded.
- **Projected post-change:** likely unsafe without separate Python helper.
- **Action required:** Keep coordination in the new helper; shell functions only validate/route.

### Verification Before Dispatch

```bash
python3 -m unittest .agents/scripts/tests/test-campaign-distribution-bridge.py
bash .agents/scripts/tests/test-content-calendar-safety.sh
bash .agents/scripts/tests/test-campaign-status-routing.sh
shellcheck .agents/scripts/campaign-helper.sh .agents/scripts/content-calendar-helper.sh .agents/scripts/content-fanout-helper.sh .agents/scripts/tests/test-content-calendar-safety.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Bridge tests cover preview/approval/enqueue/idempotency/status/recovery; calendar suite covers migration/input/duplicates; status/lint protect campaign lifecycle and shell quality.
- **Broad verification trigger:** Run all social outbound tests if queue internals are modified; prefer consuming current queue APIs.

### Recoverability Checkpoint

- [ ] Focused tests pass: bridge and calendar safety suites
- [ ] WIP commit created before broad gates: `wip: bridge campaign schedules to outbound queue`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Files Scope

- `.agents/schemas/campaign-distribution.schema.json`
- `.agents/scripts/campaign-distribution-helper.py`
- `.agents/scripts/campaign-helper.sh`
- `.agents/scripts/content-calendar-helper.sh`
- `.agents/scripts/content-fanout-helper.sh`
- `.agents/configs/campaign-channel-specs.json`
- `.agents/aidevops/knowledge-plane/05-social-operations.md`
- `.agents/scripts/tests/test-campaign-distribution-bridge.py`
- `.agents/scripts/tests/test-content-calendar-safety.sh`

## Acceptance Criteria

- [ ] An approved X or Reddit campaign/calendar item can be previewed and enqueued into the existing outbound queue with stable source/intent IDs and no provider execution in the bridge.
- [ ] Replaying enqueue or recovering after a projection failure does not create a duplicate operation or remote post.
- [ ] Unreviewed, rights-ineligible, invalid, unsupported, or expired items fail before enqueue and remain non-published.
- [ ] Campaign/calendar status is derived from queue receipts/reconciliation; queued or unknown operations are never shown as published.
- [ ] Existing manual calendar rows and X/Reddit queue operations remain compatible after migration.

## Context & Decisions

- Extend Campaigns, content calendar, distribution-social, and Knowledge Plane; do not create another scheduler or generic publisher.
- The queue owns approvals, identity binding, leases, provider execution, receipts, and reconciliation.
- New provider adapters follow in separate phases after this bridge proves the contract.

## Relevant Files

- `.agents/aidevops/knowledge-plane/05-social-operations.md:276-350`
- `.agents/scripts/_knowledge_social_outbound.py:19-274`
- `.agents/scripts/_knowledge_social_outbound_runtime.py`
- `.agents/scripts/_knowledge_social_outbound_reconciliation.py`
- `.agents/scripts/content-calendar-helper.sh`
- `.agents/scripts/content-fanout-helper.sh:537`
- `.agents/scripts/campaign-helper.sh`

## Dependencies

- **Blocked by:** t18233 / #30139
- **Blocks:** t18237 / #30143 and t18235 / #30141
- **External:** Existing test fixtures only; live X/Reddit credentials are not required.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Research/read | 1h | Queue/calendar schemas and tests |
| Implementation | 5h | Schema, migration, bridge, projections |
| Testing | 2h | Idempotency and failure/recovery matrix |
| **Total** | **~8h** | |
