<!-- aidevops:brief-schema=v2 -->

# t18237: Add approval-bound Meta and TikTok publishing adapters

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: provider adapters extend platform owners and the existing queue; official APIs, exact identity, dry-run, receipts, and reconciliation are mandatory
- [x] Discovery pass: Meta read collector, provider capability matrix, outbound X/Reddit pattern, and channel docs reviewed; no open duplicate write-adapter issue
- [x] File refs verified: existing Meta/provider/queue/registry/test parent paths present; TikTok executable paths are intentionally new
- [x] Tier: `tier:standard` — write authority stays inside the existing queue and provider contract; live credentials are not required for fixture implementation
- [x] Seeded draft PR decision recorded: skipped — installed provider dependencies and current API symbols must be checked before implementation

## Origin

- **Created:** 2026-08-13
- **Session:** OpenCode interactive branded-growth planning session
- **Created by:** ai-interactive
- **Parent task:** t18230 / GH#30136
- **Blocked by:** t18232 / #30138; `blocked-by:t18232`
- **Conversation context:** Add official, safe publishing breadth for Meta products and TikTok while preserving campaign approvals and queue evidence.

## What

Extend the social outbound provider contract with capability-gated official publishing for eligible Instagram/Facebook/Threads destinations and TikTok. Implement account/identity discovery and binding, destination-specific media/text validation, container/upload/publish job orchestration where required, dry-run/preflight, immutable intent mapping, content-free receipts, rate/cooldown metadata, polling/reconciliation, and explicit unsupported/gated states. Add a first-party TikTok platform subagent discovered through social distribution; extend the existing Meta owner rather than adding duplicate Meta agents.

## Why

The queue currently executes only X and Reddit. Branded short-form and visual campaigns need official Meta/TikTok routes, but provider-specific semantics must not leak into campaign/calendar orchestration or bypass approvals.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The trust boundary and queue semantics are established. The worker adapts provider contracts and must verify current local dependency/API symbols before coding.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Provider API/version facts must be verified at implementation time; a seed risks stale endpoint assumptions.
- **Status:** `not-created`
- **Freshness evidence:** Local provider and queue patterns inspected at `45cd1150e`.
- **Verification run:** `UNVERIFIED — planning only`
- **Stale-assumption warning:** Verify official API versions, installed dependencies, local exported symbols, permissions, and publishing prerequisites first.

## How (Approach)

### Progressive Context Plan

- **Read first:** `_knowledge_social_outbound_provider.py`, `_knowledge_social_outbound_runtime.py`, `_knowledge_social_outbound_reconciliation.py`, and `.agents/content/social-meta.md`.
- **Load only if:** implementing TikTok routes, then read the new platform doc/source contract and official provider docs available through verified local/upstream references.
- **Why:** Model queue behavior on X/Reddit while keeping provider-specific job state isolated.
- **Stop when:** Exact supported destinations/actions/media, identity binding, terminal/unknown states, retries, and fixtures are clear.

### Worker Quick-Start

```bash
rg -n 'PROVIDERS|prepare_|remote_id|unknown|reconcile|receipt' .agents/scripts/_knowledge_social_outbound_provider.py .agents/scripts/_knowledge_social_outbound_runtime.py .agents/scripts/_knowledge_social_outbound_reconciliation.py
rg -n 'Facebook|Instagram|Threads|identity|permission|write' .agents/content/social-meta.md .agents/scripts/_knowledge_social_meta*
```

### Files to Modify

- `EDIT: .agents/scripts/_knowledge_social_outbound.py` — provider/action capability declarations.
- `EDIT: .agents/scripts/_knowledge_social_outbound_provider.py` — prepare/execute provider dispatch without embedding secrets.
- `EDIT: .agents/scripts/_knowledge_social_outbound_runtime.py` — async job/container/poll state and receipt mapping.
- `EDIT: .agents/scripts/_knowledge_social_outbound_reconciliation.py` — provider-specific unknown/remote reconciliation.
- `NEW: .agents/scripts/_knowledge_social_meta_outbound_provider.py` — bounded official Meta operations.
- `NEW: .agents/scripts/_knowledge_social_tiktok_outbound_provider.py` — bounded official TikTok operations.
- `NEW: .agents/content/social-tiktok.md` — first-party platform capabilities, policy, identity, formats, collection/write boundaries.
- `EDIT: .agents/content/social-meta.md` — official outbound capabilities and gates.
- `EDIT: .agents/content/distribution-social.md` — progressive-discovery links and platform-native handoff.
- `EDIT: .agents/aidevops/knowledge-plane/06-social-provider-capabilities.md` — read/write readiness matrix.
- `EDIT: .agents/configs/capability-registry.json` — catalogued/deployed/configured/authenticated/authorized/reachable/usable probes and fallbacks.
- `EDIT: .agents/configs/rate-limits.json.txt` — provider budgets only when verified.
- `NEW: .agents/scripts/tests/test-social-meta-tiktok-outbound.py` — hermetic provider/job/retry/receipt tests.

### Complete Write Surface

- **Callers/readers:** `contract:` Campaign distribution bridge, outbound queue, provider health phase, platform agents, capability registry.
- **Writers/mutation paths:** `contract:` Queue intents/claims/receipts; provider upload/container/publish jobs; local content-free reconciliation state. No provider call before approval/identity recheck.
- **Tests/fixtures:** `contract:` New Meta/TikTok suite plus existing outbound queue/provider tests discovered at implementation.
- **Schemas/config:** `contract:` Queue provider/action maps, capability registry, rate limits, provider capability docs.
- **Generated/deployed mirrors:** `contract:` `.agents/` deploys; secrets remain in aidevops secret storage/environment and never fixtures/docs.
- **Migrations/backfills:** `contract:` Existing X/Reddit operations remain unchanged; new providers are additive and gated by capability readiness.
- **Cleanup/rollback paths:** `contract:` Expired uploads/containers may be cleaned when officially supported; accepted remote publishes are not “rolled back” locally—record remote identity and require an explicit delete operation if supported/approved.

### Implementation Steps

1. Verify installed dependency versions/local exports and current official API capabilities before defining action maps; add compatibility tests or a separate upgrade if symbols are unavailable.
2. Define exact supported account types, products/actions, media constraints, captions/alt text/disclosures, schedules, and required permissions; unsupported combinations fail before mutation.
3. Bind every intent to an allowlisted provider account and recheck identity/authority immediately before remote execution.
4. Implement dry-run validation and queue prepare handlers; isolate provider credentials and redact content from logs/receipts.
5. Implement asynchronous upload/container/publish polling with bounded backoff, rate resets, terminal failure classes, and `unknown` on ambiguous acceptance.
6. Reconcile by stable provider job/post IDs; retries use idempotency/intent evidence and never blindly republish after timeout.
7. Add platform docs and capability probes that distinguish catalogued/deployed from configured/authenticated/authorized/usable.
8. Test media variants, account mismatch, expired approval, rate limit, 4xx validation, 5xx/timeout, accepted-but-unknown, polling recovery, duplicate replay, and secret/content redaction.

### Hazards and Compatibility

- **Concurrency/atomicity:** Queue leases fence execution; provider job IDs are persisted before polling; concurrent retries cannot both publish.
- **Migration/rollback:** Additive providers require no existing operation migration; remote deletion is a separately approved action, not automatic rollback.
- **Mixed-version/backward compatibility:** Nodes without new adapters report unavailable and keep operations blocked; X/Reddit behavior is unchanged.
- **Idempotency/retry:** Use provider-supported idempotency or durable intent/job reconciliation; timeout never authorizes a second blind publish.
- **Partial failure/recovery:** Upload succeeded/container failed/publish unknown each retain durable state and next safe action.

### Verification Before Dispatch

```bash
python3 -m unittest .agents/scripts/tests/test-social-meta-tiktok-outbound.py
python3 -m unittest discover -s .agents/scripts/tests -p '*social*outbound*.py'
python3 -m json.tool .agents/configs/capability-registry.json >/dev/null
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Provider fixtures prove validation, identity, jobs, idempotency, rate limits, redaction, and reconciliation; existing outbound suite protects queue semantics; registry/lint cover routing/docs/config.
- **Broad verification trigger:** Run full relevant social provider tests if shared outbound modules change (expected here); no live provider mutation is a required gate.

### Recoverability Checkpoint

- [ ] Focused tests pass: Meta/TikTok and shared outbound suites
- [ ] WIP commit created before broad gates: `wip: add Meta and TikTok outbound adapters`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Implement safe fixture-backed official provider adapters and queue integration.
- **Preserved user directions:** End-to-end branded growth with authentic content and approved multichannel distribution.
- **Trigger and evidence:** `not triggered`
- **Completed and verified:** none at dispatch
- **Remaining acceptance criteria:** all below
- **Unsafe route not to repeat:** live mutation without explicit test account approval or retrying ambiguous publish acceptance blindly
- **Next safe route:** fixtures/mocks, dry-run, local symbol verification, and reconciliation contract
- **Resume condition:** official capability and local dependency evidence are available
- **Owner and status:** dispatched worker; `not-triggered`

### Files Scope

- `.agents/scripts/_knowledge_social_outbound.py`
- `.agents/scripts/_knowledge_social_outbound_provider.py`
- `.agents/scripts/_knowledge_social_outbound_runtime.py`
- `.agents/scripts/_knowledge_social_outbound_reconciliation.py`
- `.agents/scripts/_knowledge_social_meta_outbound_provider.py`
- `.agents/scripts/_knowledge_social_tiktok_outbound_provider.py`
- `.agents/content/social-tiktok.md`
- `.agents/content/social-meta.md`
- `.agents/content/distribution-social.md`
- `.agents/aidevops/knowledge-plane/06-social-provider-capabilities.md`
- `.agents/configs/capability-registry.json`
- `.agents/configs/rate-limits.json.txt`
- `.agents/scripts/tests/test-social-meta-tiktok-outbound.py`

## Acceptance Criteria

- [ ] Fixture-backed approved intents publish/reconcile the explicitly supported Meta/TikTok formats with exact account binding and content-free receipts.
- [ ] Unapproved, expired, account-mismatched, unsupported, rights-ineligible, or capability-unready operations make zero remote mutation attempts.
- [ ] Timeouts and ambiguous acceptance become `unknown` and reconcile by stable job/post ID; replay never blindly duplicates a remote post.
- [ ] Existing X/Reddit queue behavior and operation records remain backward compatible.
- [ ] Logs, errors, fixtures, and receipts contain no credentials and no campaign content beyond approved bounded metadata.

## Context & Decisions

- New first-party TikTok platform agent is justified; Meta extends its existing agent.
- Use official APIs only and do not imitate browser/persona automation for unavailable write routes.
- Account setup/permissions are runtime readiness gates, not reasons to weaken fixtures or auto-dispatch.

## Relevant Files

- `.agents/scripts/_knowledge_social_outbound.py:19-274`
- `.agents/scripts/_knowledge_social_outbound_provider.py`
- `.agents/scripts/_knowledge_social_outbound_reconciliation.py`
- `.agents/content/social-meta.md`
- `.agents/aidevops/knowledge-plane/06-social-provider-capabilities.md:37-39,133-150`
- `.agents/configs/capability-registry.json:1-76`

## Dependencies

- **Blocked by:** t18232 / #30138
- **Blocks:** t18238 / #30144
- **External:** Live accounts/scopes are optional runtime gates; implementation and verification use fixtures/dry-run only.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Research/read | 1.5h | API/version/symbol and queue patterns |
| Implementation | 6h | Two provider adapters and routing |
| Testing | 2.5h | Async/retry/identity/redaction matrix |
| **Total** | **~10h** | |
