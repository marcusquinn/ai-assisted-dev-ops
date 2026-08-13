<!-- aidevops:brief-schema=v2 -->

# t18231: Build structured audience competitor and channel research dossiers

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: prior audit says extend Content Research, Product validation/growth, campaign intel, social collectors, SEO, and PR rather than add a viral-content agent
- [x] Discovery pass: no open duplicate issue; existing read-only social provider work and campaign intel contract reviewed
- [x] File refs verified: 9 owner/config/helper surfaces present at `45cd1150e`
- [x] Tier: `tier:standard` — the research boundary and output destination are decided; source adapters require bounded implementation judgment
- [x] Seeded draft PR decision recorded: skipped — issue-only avoids anchoring source selection before worker rechecks provider readiness

## Origin

- **Created:** 2026-08-13
- **Session:** OpenCode interactive branded-growth planning session
- **Created by:** ai-interactive
- **Parent task:** t18230 / GH#30136
- **Blocked by:** t18228 / #30135; `blocked-by:t18228`
- **Conversation context:** Turn a validated brand/product/offer campaign intake into cited, actionable evidence for content and campaign strategy across relevant channels.

## What

Add a campaign research command and versioned dossier contract that produces: ICP and buying-role refinement; jobs, pains, objections, language, and desired outcomes; competitor positioning/creative/channel observations; creator and partner candidates; trends and content opportunities; channel fit; search/social demand evidence; risks; hypotheses; and a source/provenance ledger. Outputs must live under the campaign research/intel boundaries and be directly consumable by the campaign brief phase.

## Why

Existing research agents explain how to investigate, and Knowledge Plane collectors can retrieve authorized evidence, but no deterministic campaign handoff packages the evidence into one comparable, freshness-aware dossier. Without it, creative work is either generic or based on unsupported assumptions.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The contract, owners, safety boundaries, and output location are resolved; workers adapt existing research and collector patterns without deciding a new privacy boundary.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Provider readiness is dynamic and must be checked at implementation time.
- **Status:** `not-created`
- **Freshness evidence:** Repository and GitHub discovery completed against `45cd1150e`.
- **Verification run:** `UNVERIFIED — planning only`
- **Stale-assumption warning:** Recheck social provider capabilities and recent collector changes before selecting executable sources.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/content/research.md:77-103,163-186,239-289`, `.agents/product/validation.md:50-108`, and `.agents/aidevops/campaigns-plane.md:31-58,65-83`.
- **Load only if:** `.agents/aidevops/knowledge-plane/06-social-provider-capabilities.md` for provider routes; SEO/PR/Product Growth docs for a selected source class.
- **Why:** Keep Content Research as coordinator and use platform collectors only where authorized.
- **Stop when:** Dossier schema, source classes, budgets, freshness, evidence ledger, and failure behavior are fixed.

### Worker Quick-Start

```bash
rg -n 'audience|competitor|trend|viral|ICP|buying|creator|influencer' .agents/content/research.md .agents/product .agents/marketing-sales
rg -n '^\| (X|Reddit|YouTube|LinkedIn|Facebook|Instagram|Threads)' .agents/aidevops/knowledge-plane/06-social-provider-capabilities.md
```

### Files to Modify

- `EDIT: .agents/content/research.md` — add the structured campaign dossier handoff and source selection guidance.
- `NEW: .agents/schemas/campaign-research-dossier.schema.json` — versioned evidence and insight contract.
- `NEW: .agents/scripts/campaign-research-helper.py` — bounded orchestration/normalization over explicit source artifacts and authorized collectors.
- `EDIT: .agents/scripts/campaign-helper.sh` — route `campaign research <id>` without embedding provider logic.
- `EDIT: .agents/aidevops/campaigns-plane.md` — document dossier paths, sensitivity, freshness, and consumption.
- `EDIT: .agents/configs/capability-registry.json` — catalogue campaign research readiness/fallback without claiming configured providers.
- `NEW: .agents/scripts/tests/test-campaign-research-helper.py` — fixture, budget, provenance, privacy, and replay tests.

### Complete Write Surface

- **Callers/readers:** `contract:` Campaign brief/content agents consume `_campaigns/active/<id>/research/dossier.json` and a human-readable summary; reports may read promoted public learnings, not raw intel.
- **Writers/mutation paths:** `contract:` New helper writes campaign research; authorized Knowledge Plane collectors write their own corpus and are read through bounded queries/exports rather than bypassed.
- **Tests/fixtures:** `contract:` New hermetic fixture suite; existing social-provider tests remain owners of collection behavior.
- **Schemas/config:** `contract:` New dossier schema and capability registry entry; provider capability matrix stays canonical for live/gated/no routes.
- **Generated/deployed mirrors:** `contract:` `.agents/` deploys via setup; `_campaigns/intel/` and active research are user data and remain outside framework git.
- **Migrations/backfills:** `contract:` No bulk migration; old research prose remains readable, with dossier generated on explicit command.
- **Cleanup/rollback paths:** `contract:` Stage dossier outputs, validate schema, atomically replace; preserve prior valid dossier on source failure.

### Implementation Steps

1. Define source observations separately from synthesized insights/hypotheses. Require source type, reference/hash, capture time, freshness, authorization mode, confidence, and sensitivity.
2. Normalize intake audiences and buying roles into research questions and channel/source plans with explicit budgets.
3. Support supplied files/exports, authorized Knowledge Plane queries, public search/SEO evidence, and manual evidence. Never invent an unavailable collector or treat a publishing token as read authority.
4. Generate comparable competitor, creator, trend, audience-language, channel-fit, and opportunity records plus contradictions/gaps.
5. Store sensitive raw competitor evidence under `_campaigns/intel/`; keep the active dossier reference-oriented and redact private identifiers from publishable summaries.
6. Make empty, gated, stale, partial, and rate-limited source outcomes truthful; never turn missing evidence into a positive finding.
7. Add deterministic fixtures for source deduplication, freshness, budgets, replay, prompt-injection-like content isolation, and privacy.

### Hazards and Compatibility

- **Concurrency/atomicity:** One campaign research run owns a run ID/lease; concurrent runs cannot replace a newer dossier.
- **Migration/rollback:** Schema-versioned outputs preserve earlier valid dossiers; unsupported versions fail closed.
- **Mixed-version/backward compatibility:** Campaigns without dossiers remain usable; consumers degrade to explicit `research_unavailable`, not fabricated defaults.
- **Idempotency/retry:** Same intake and source snapshot produce the same semantic dossier/hash; retries do not duplicate observations.
- **Partial failure/recovery:** Record per-source partial/gated status and preserve successful evidence; never advance freshness for failed sources.

### Verification Before Dispatch

```bash
python3 -m unittest .agents/scripts/tests/test-campaign-research-helper.py
python3 -m json.tool .agents/schemas/campaign-research-dossier.schema.json >/dev/null
bash .agents/scripts/tests/test-campaign-status-routing.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Unit fixtures prove schema/source/privacy/replay behavior; campaign test protects routing; JSON/lint checks validate schema and docs/config.
- **Broad verification trigger:** Run relevant Knowledge Plane provider suites only if provider implementation files are changed; this issue should normally consume, not alter, them.

### Recoverability Checkpoint

- [ ] Focused tests pass: `python3 -m unittest .agents/scripts/tests/test-campaign-research-helper.py`
- [ ] WIP commit created before broad gates: `wip: add campaign research dossiers`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Files Scope

- `.agents/content/research.md`
- `.agents/schemas/campaign-research-dossier.schema.json`
- `.agents/scripts/campaign-research-helper.py`
- `.agents/scripts/campaign-helper.sh`
- `.agents/aidevops/campaigns-plane.md`
- `.agents/configs/capability-registry.json`
- `.agents/scripts/tests/test-campaign-research-helper.py`

## Acceptance Criteria

- [ ] Given valid campaign intake and fixture evidence, the command emits a schema-valid dossier with audience, buying roles, competitors, creators, trends, channel fit, opportunities, contradictions, and a provenance ledger.
- [ ] Gated, absent, stale, partial, or rate-limited sources remain explicit and never become fabricated evidence or `complete` coverage.
- [ ] Sensitive raw intel and private identifiers never appear in publishable summaries or Git-tracked framework files.
- [ ] Replaying an unchanged source snapshot is idempotent and a failed refresh preserves the previous valid dossier.
- [ ] Campaign brief consumers can locate and verify the dossier without parsing unstructured provider output.

## Context & Decisions

- Extend Content Research and existing Product/SEO/PR/platform owners; do not add a generic viral lab or marketing brain.
- Use official APIs, authorized exports, and public lawful sources only; no unofficial scraping or browser workaround for gated account data.
- Research observations inform hypotheses; they do not autonomously authorize outreach, publishing, targeting, or spend.

## Relevant Files

- `.agents/content/research.md:77-103,163-186,239-289`
- `.agents/product/validation.md:50-108`
- `.agents/product/growth.md`
- `.agents/aidevops/campaigns-plane.md:31-83`
- `.agents/aidevops/knowledge-plane/05-social-operations.md:212-350`
- `.agents/aidevops/knowledge-plane/06-social-provider-capabilities.md:33-46`
- `.agents/content/distribution-youtube-channel-intel.md:2-155`

## Dependencies

- **Blocked by:** t18228 / #30135
- **Blocks:** t18234 / #30140
- **External:** Optional provider credentials/exports affect live coverage only; fixture-backed implementation remains dispatchable.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Research/read | 1h | Owner/source and schema patterns |
| Implementation | 4h | Contract, helper, campaign routing |
| Testing | 1.5h | Fixtures, privacy, replay, partials |
| **Total** | **~6.5h** | |
