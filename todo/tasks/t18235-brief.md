<!-- aidevops:brief-schema=v2 -->

# t18235: Add approval-bound LinkedIn and YouTube publishing adapters

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: extend existing platform agents and outbound queue; preserve official API, exact identity, dry-run, receipts, and reconciliation boundaries
- [x] Discovery pass: LinkedIn/YouTube read collectors, platform docs, provider matrix, and X/Reddit outbound reference reviewed; no open duplicate issue
- [x] File refs verified: existing platform/provider/queue/registry surfaces present at `45cd1150e`
- [x] Tier: `tier:standard` — established provider adapter pattern inside a decided approval boundary
- [x] Seeded draft PR decision recorded: skipped — provider eligibility and local API/dependency symbols must be verified at worker start

## Origin

- **Created:** 2026-08-13
- **Session:** OpenCode interactive branded-growth planning session
- **Created by:** ai-interactive
- **Parent task:** t18230 / GH#30136
- **Blocked by:** t18232 / #30138; `blocked-by:t18232`
- **Conversation context:** Add official LinkedIn and YouTube publishing routes for approved branded campaigns without bypassing platform eligibility or the outbound queue.

## What

Extend existing LinkedIn and YouTube platform owners plus the social outbound queue with official, capability-gated publishing for explicitly supported post/video formats. Include account/channel identity binding, upload/session/job state, format/metadata/thumbnail/caption validation, dry-run, immutable intent mapping, approval expiry, content-free receipts, quota/rate metadata, polling/reconciliation, and explicit gated/unsupported states.

## Why

These channels are material for professional reach, search/discovery, long-form authority, and conversion. The repository has read collectors and content guidance, but not queue-backed write execution.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The trust and recovery model is inherited from the queue; workers implement verified provider contracts without live credentials.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Avoid stale assumptions about restricted LinkedIn products and resumable YouTube upload APIs.
- **Status:** `not-created`
- **Freshness evidence:** Local platform/provider surfaces inspected at `45cd1150e`.
- **Verification run:** `UNVERIFIED — planning only`
- **Stale-assumption warning:** Verify installed dependencies, current local exports, API versions, application eligibility, and scopes before implementing mappings.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/content/social-linkedin.md`, `.agents/content/social-youtube.md`, and shared outbound provider/runtime/reconciliation modules.
- **Load only if:** upload/metadata specifics are needed, then inspect current official SDK/source available locally and relevant distribution YouTube docs.
- **Why:** Preserve platform ownership and shared queue semantics.
- **Stop when:** Supported formats, eligibility/scopes, upload state, identity, idempotency, receipt, and recovery are fixed.

### Worker Quick-Start

```bash
rg -n 'posting|publish|scope|closed|restricted|identity' .agents/content/social-linkedin.md .agents/content/social-youtube.md
rg -n 'prepare_|remote_id|unknown|reconcile|receipt' .agents/scripts/_knowledge_social_outbound_provider.py .agents/scripts/_knowledge_social_outbound_runtime.py .agents/scripts/_knowledge_social_outbound_reconciliation.py
```

### Files to Modify

- `EDIT: .agents/scripts/_knowledge_social_outbound.py` — additive provider/action declarations.
- `EDIT: .agents/scripts/_knowledge_social_outbound_provider.py` — dispatch preparation.
- `EDIT: .agents/scripts/_knowledge_social_outbound_runtime.py` — resumable upload/publish job states and receipts.
- `EDIT: .agents/scripts/_knowledge_social_outbound_reconciliation.py` — unknown/remote status checks.
- `NEW: .agents/scripts/_knowledge_social_linkedin_outbound_provider.py` — official eligible LinkedIn operations.
- `NEW: .agents/scripts/_knowledge_social_youtube_outbound_provider.py` — official YouTube upload/publish operations.
- `EDIT: .agents/content/social-linkedin.md` — exact write capabilities, eligibility, and failure states.
- `EDIT: .agents/content/social-youtube.md` — exact upload/publish capabilities, metadata, quota, and identity.
- `EDIT: .agents/content/distribution-social.md` — progressive-discovery handoff.
- `EDIT: .agents/aidevops/knowledge-plane/06-social-provider-capabilities.md` — write-readiness matrix.
- `EDIT: .agents/configs/capability-registry.json` — readiness probes/fallbacks.
- `EDIT: .agents/configs/rate-limits.json.txt` — verified quota/rate budgets.
- `NEW: .agents/scripts/tests/test-social-linkedin-youtube-outbound.py` — fixtures for eligibility, upload, quota, retry, and reconciliation.

### Complete Write Surface

- **Callers/readers:** `contract:` Campaign bridge, outbound queue, provider health, LinkedIn/YouTube agents, reporting receipts.
- **Writers/mutation paths:** `contract:` Queue operation state; provider upload sessions/jobs/posts/videos; content-free local receipts/reconciliation state.
- **Tests/fixtures:** `contract:` New provider suite and shared outbound tests discovered at implementation.
- **Schemas/config:** `contract:` Provider/action maps, capability registry, rate limits, platform docs.
- **Generated/deployed mirrors:** `contract:` `.agents/` deploys; secrets/content stay outside public logs/fixtures.
- **Migrations/backfills:** `contract:` Additive providers; existing operations unchanged.
- **Cleanup/rollback paths:** `contract:` Abandoned upload sessions are expired/cleaned when supported; published remote content requires separately approved delete/unpublish, never implicit local rollback.

### Implementation Steps

1. Verify installed dependency/API versions and local exported symbols. Do not add upstream-reported error/action mappings absent from the installed version without a compatibility test or upgrade task.
2. Define the minimal officially supported LinkedIn and YouTube action/format sets and explicit eligibility/scopes; restricted products stay gated rather than emulated.
3. Validate account/channel identity, upload size/type, titles/descriptions/captions/thumbnails/tags/disclosures, audience/privacy/schedule, and provider constraints before mutation.
4. Implement dry-run and queue prepare handlers, isolating secrets and provider transport.
5. Persist resumable upload/session/job IDs before remote continuation; map terminal and ambiguous outcomes to queue receipts.
6. Enforce bounded polling, quotas/rate resets, retry-after, and unknown reconciliation; never repeat a completed or ambiguous upload blindly.
7. Add capability probes that distinguish documented capability from currently authorized/usable route.
8. Test account mismatch, eligibility denial, invalid media, expired approval, interrupted upload/resume, quota exhaustion, timeout-after-acceptance, duplicate replay, and redaction.

### Hazards and Compatibility

- **Concurrency/atomicity:** Queue lease plus persisted resumable upload ID fences one executor; duplicate claims cannot create two videos/posts.
- **Migration/rollback:** Providers are additive; no rewrite of read-collector state or X/Reddit operations.
- **Mixed-version/backward compatibility:** Missing adapters report unavailable and keep intents blocked; no fallback to browser automation.
- **Idempotency/retry:** Resume known upload/job IDs and reconcile ambiguity before any fresh create.
- **Partial failure/recovery:** Preserve uploaded bytes/session state and next safe step; remote success with local receipt failure is recoverable by stable ID.

### Verification Before Dispatch

```bash
python3 -m unittest .agents/scripts/tests/test-social-linkedin-youtube-outbound.py
python3 -m unittest discover -s .agents/scripts/tests -p '*social*outbound*.py'
python3 -m json.tool .agents/configs/capability-registry.json >/dev/null
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Fixtures prove eligibility, identity, resumable upload, idempotency, quota, redaction, receipt, and recovery; shared suite protects queue contracts.
- **Broad verification trigger:** Shared outbound modules change, so run every discovered social outbound unit suite; no live upload required.

### Recoverability Checkpoint

- [ ] Focused tests pass: LinkedIn/YouTube and shared outbound suites
- [ ] WIP commit created before broad gates: `wip: add LinkedIn and YouTube outbound adapters`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Deliver fixture-backed official provider adapters without live side effects.
- **Preserved user directions:** Safe end-to-end branded growth across relevant channels.
- **Trigger and evidence:** `not triggered`
- **Completed and verified:** none at dispatch
- **Remaining acceptance criteria:** all below
- **Unsafe route not to repeat:** live upload without explicit test-account authority or browser emulation of restricted APIs
- **Next safe route:** local API symbol verification, fixtures, dry-run, and reconciliation tests
- **Resume condition:** supported product/scope evidence is available
- **Owner and status:** dispatched worker; `not-triggered`

### Files Scope

- `.agents/scripts/_knowledge_social_outbound.py`
- `.agents/scripts/_knowledge_social_outbound_provider.py`
- `.agents/scripts/_knowledge_social_outbound_runtime.py`
- `.agents/scripts/_knowledge_social_outbound_reconciliation.py`
- `.agents/scripts/_knowledge_social_linkedin_outbound_provider.py`
- `.agents/scripts/_knowledge_social_youtube_outbound_provider.py`
- `.agents/content/social-linkedin.md`
- `.agents/content/social-youtube.md`
- `.agents/content/distribution-social.md`
- `.agents/aidevops/knowledge-plane/06-social-provider-capabilities.md`
- `.agents/configs/capability-registry.json`
- `.agents/configs/rate-limits.json.txt`
- `.agents/scripts/tests/test-social-linkedin-youtube-outbound.py`

## Acceptance Criteria

- [ ] Fixture-backed approved intents complete/reconcile explicitly supported LinkedIn/YouTube formats with exact destination identity and content-free receipts.
- [ ] Restricted/ineligible, unapproved, expired, account-mismatched, invalid, or capability-unready intents make zero remote mutation attempts.
- [ ] Interrupted/ambiguous uploads resume or reconcile by stable session/job/video/post ID and never blindly duplicate content.
- [ ] Existing read collectors and X/Reddit outbound behavior remain unchanged.
- [ ] No credentials or campaign content leak into logs, fixtures, errors, or receipts beyond approved bounded metadata.

## Context & Decisions

- Extend existing LinkedIn/YouTube agents and queue; no duplicate publisher agent.
- Official API unavailability is a truthful gated state, not authorization for browser automation.
- Runtime accounts/scopes are readiness data and can be absent while fixture implementation remains complete.

## Relevant Files

- `.agents/content/social-linkedin.md:63-153`
- `.agents/content/social-youtube.md`
- `.agents/scripts/_knowledge_social_linkedin.py`
- `.agents/scripts/_knowledge_social_youtube.py`
- `.agents/scripts/_knowledge_social_outbound_provider.py`
- `.agents/aidevops/knowledge-plane/06-social-provider-capabilities.md:35-36,117-133`

## Dependencies

- **Blocked by:** t18232 / #30138
- **Blocks:** t18238 / #30144
- **External:** Live provider accounts/eligibility/scopes are optional runtime gates; tests are hermetic.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Research/read | 1.5h | Eligibility/version/upload contracts |
| Implementation | 6h | Two adapters and queue routing |
| Testing | 2.5h | Resume/quota/identity/recovery matrix |
| **Total** | **~10h** | |
