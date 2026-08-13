<!-- aidevops:brief-schema=v2 -->

# t18234: Generate authentic branded campaign briefs and production manifests

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: consolidate under Content production/media routing, campaign drafts, Marketing-Sales creative, Design identity, and existing editors
- [x] Discovery pass: recent content provenance and media-provider work reviewed; no open duplicate implementation issue
- [x] File refs verified: Content, Campaign, channel specs, media router, production, editing, and provenance surfaces present at `45cd1150e`
- [x] Tier: `tier:standard` — production owners and lifecycle boundaries are known; multi-format manifests require normal implementation judgment
- [x] Seeded draft PR decision recorded: skipped — avoid anchoring the worker to one media provider

## Origin

- **Created:** 2026-08-13
- **Session:** OpenCode interactive branded-growth planning session
- **Created by:** ai-interactive
- **Parent task:** t18230 / GH#30136
- **Blocked by:** t18231 / #30137; `blocked-by:t18231`
- **Conversation context:** Convert approved intake and research into high-quality, believable, authentic, channel-native content plans and executable production jobs.

## What

Extend the existing campaign draft and Content pipeline to produce a versioned creative brief and production manifest for each campaign/channel/variant. It must define objective, audience insight, proof-linked message, hook/story/CTA, copy/script/shot/visual/audio direction, brand references, format/dimensions/duration, asset inputs, generator/editor route, disclosure/rights needs, review criteria, experiment identity, and truthful lifecycle status. It prepares executable jobs; it must not claim assets are generated or published when only prompts/briefs exist.

## Why

Existing agents can write, direct, generate, edit, and repurpose media, but campaign handoffs are largely prose and `content-fanout-helper.sh` stops at `prompts_ready`. A common manifest lets each specialist work independently while preserving brand, evidence, variant identity, and quality expectations.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** This adapts existing campaign/content patterns and provider routing; provider/model choice remains runtime capability-based, not an unresolved architecture decision.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The correct provider and media path depend on runtime capabilities and campaign inputs.
- **Status:** `not-created`
- **Freshness evidence:** Repository and GitHub discovery completed against `45cd1150e`.
- **Verification run:** `UNVERIFIED — planning only`
- **Stale-assumption warning:** Recheck recent media provider, provenance, and campaign draft changes before implementing.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/content.md:70-110,140-157`, `.agents/scripts/campaign-helper.sh` draft paths, and `.agents/scripts/content-fanout-helper.sh:500-650`.
- **Load only if:** selected asset class requires `production-image.md`, `production-video.md`, `production-audio.md`, or `tools/video/video-editor.md`.
- **Why:** Keep Content as orchestrator and avoid duplicating operation-specific instructions.
- **Stop when:** One manifest can hand work to each existing owner with evidence, status, and acceptance checks intact.

### Worker Quick-Start

```bash
rg -n 'draft|reviewed|promoted|provenance|channel' .agents/scripts/campaign-helper.sh .agents/configs/campaign-channel-specs.json
rg -n 'prompts_ready|ALL_CHANNELS|output' .agents/scripts/content-fanout-helper.sh
```

### Files to Modify

- `NEW: .agents/schemas/campaign-creative-brief.schema.json` — creative strategy and claim/evidence linkage.
- `NEW: .agents/schemas/content-production-manifest.schema.json` — job, variants, assets, runtime route, status, outputs, review, and experiment IDs.
- `EDIT: .agents/scripts/campaign-helper.sh` — create/list/validate creative briefs and production manifests from intake/research.
- `EDIT: .agents/scripts/content-fanout-helper.sh` — emit/import manifest-ready channel jobs while retaining `prompts_ready` truthfulness.
- `EDIT: .agents/configs/campaign-channel-specs.json` — align canonical channel IDs and requirements with calendar/social/short-form owners.
- `EDIT: .agents/content.md` — concise progressive-discovery pointer to campaign production handoff.
- `EDIT: .agents/content/media-generation-providers.md` — consume capability-aware job requirements without hardcoding one provider.
- `NEW: .agents/scripts/tests/test-campaign-production-manifest.sh` — schema, status, channel, claim, and replay fixtures.

### Complete Write Surface

- **Callers/readers:** `contract:` Campaign draft/production, Content writing/image/video/audio, Design, editors, distribution, and later review/publishing bridge.
- **Writers/mutation paths:** `contract:` Campaign helper writes `_campaigns/active/<id>/drafts/` and manifest records; fanout writes channel prompt/job directories.
- **Tests/fixtures:** `contract:` New manifest suite plus campaign status tests; provider-specific tests remain separate.
- **Schemas/config:** `contract:` Two new schemas and aligned channel specs; capability registry/provider router determine usable execution route.
- **Generated/deployed mirrors:** `contract:` `.agents/` deployment; generated user assets/manifests remain in campaign workspace.
- **Migrations/backfills:** `contract:` Existing markdown drafts remain readable; new manifests are generated explicitly, not bulk backfilled.
- **Cleanup/rollback paths:** `contract:` Invalid job/brief never replaces a valid manifest; generated output is attached only after hash/type/status validation.

### Implementation Steps

1. Define creative brief fields separating evidence, strategy, creative hypothesis, factual claims, and stylistic direction.
2. Define production job states such as `brief_ready`, `prompts_ready`, `queued`, `running`, `generated`, `edited`, `review_required`, `approved`, `rejected`, and `failed`; forbid status promotion without required evidence.
3. Align channel vocabulary across campaign specs and fanout while retaining compatibility aliases.
4. Extend campaign drafting to generate channel-native variants grounded in intake/research/brand sources, with explicit authenticity and disclosure requirements for synthetic people, voices, testimonials, or UGC-style creative.
5. Emit jobs for existing writing/image/video/audio/editor owners and select providers only through the current media router/capability evidence.
6. Record output IDs/paths/hashes only after actual completion; a prompt file is never a completed asset.
7. Add fixture tests for cross-channel variants, unsupported capabilities, missing claim evidence, reruns, and negative status transitions.

### Hazards and Compatibility

- **Concurrency/atomicity:** Jobs and status transitions require stable IDs and compare-current-state semantics so concurrent workers cannot overwrite outputs.
- **Migration/rollback:** Existing drafts and fanout directories remain valid; schema jobs are additive and reversible.
- **Mixed-version/backward compatibility:** Consumers accept legacy drafts but require schema manifests for automated downstream handoff.
- **Idempotency/retry:** Same campaign/channel/variant/source hash reuses a job or creates a new explicit revision; it never silently duplicates the same variant.
- **Partial failure/recovery:** Per-job failure preserves successful sibling variants and input/output evidence for resume.

### Complexity Impact

- **Target function:** campaign draft functions and fanout manifest writer must be measured before edits.
- **Current line count:** measure at worker start; threshold 100 lines.
- **Estimated growth:** substantial multi-schema plumbing.
- **Projected post-change:** likely over threshold if embedded.
- **Action required:** Add small schema/job helpers or modules; do not grow existing orchestrators beyond repository limits.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-campaign-production-manifest.sh
bash .agents/scripts/tests/test-campaign-status-routing.sh
shellcheck .agents/scripts/campaign-helper.sh .agents/scripts/content-fanout-helper.sh .agents/scripts/tests/test-campaign-production-manifest.sh
python3 -m json.tool .agents/schemas/campaign-creative-brief.schema.json >/dev/null
python3 -m json.tool .agents/schemas/content-production-manifest.schema.json >/dev/null
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Focused tests cover schemas, channel mapping, lifecycle truth, claims, and replay; ShellCheck/lint cover orchestrators/docs/config.
- **Broad verification trigger:** Run provider-specific tests only if provider implementations change; this phase should route rather than implement providers.

### Recoverability Checkpoint

- [ ] Focused tests pass: `bash .agents/scripts/tests/test-campaign-production-manifest.sh`
- [ ] WIP commit created before broad gates: `wip: add campaign production manifests`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Files Scope

- `.agents/schemas/campaign-creative-brief.schema.json`
- `.agents/schemas/content-production-manifest.schema.json`
- `.agents/scripts/campaign-helper.sh`
- `.agents/scripts/content-fanout-helper.sh`
- `.agents/configs/campaign-channel-specs.json`
- `.agents/content.md`
- `.agents/content/media-generation-providers.md`
- `.agents/scripts/tests/test-campaign-production-manifest.sh`

## Acceptance Criteria

- [ ] Valid intake/research generates schema-valid, brand-referenced, proof-linked creative briefs and channel-native production jobs for selected channels and variants.
- [ ] UGC-style, testimonial, synthetic person/voice, and other authenticity-sensitive content carries source, consent, disclosure, and review requirements rather than implying a real endorsement.
- [ ] Prompt preparation remains `prompts_ready`; no code path labels prompts or queued jobs as generated, approved, published, or measured.
- [ ] Unsupported provider/runtime capability yields an explicit blocked/fallback state without silently switching to an unauthorized route.
- [ ] Reruns preserve stable variant identity and successful sibling outputs.

## Context & Decisions

- Extend Content, Campaign, Marketing-Sales, Design, provider router, and editors; do not add product-video, UGC-ad, carousel, caption, or generic media-library agents.
- “Authentic” means credible, brand-consistent, evidence-backed, appropriately disclosed work—not manufactured customer testimony or hidden impersonation.
- Media generation and deterministic post-production remain separate owners connected by manifests.

## Relevant Files

- `.agents/content.md:70-110`
- `.agents/scripts/content-fanout-helper.sh:537` — current truthful `prompts_ready` state.
- `.agents/scripts/campaign-helper.sh` — draft generation and review metadata.
- `.agents/content/media-generation-providers.md`
- `.agents/content/production-video.md`
- `.agents/tools/video/video-editor.md`
- `.agents/tools/security/content-provenance.md:24-72`

## Dependencies

- **Blocked by:** t18231 / #30137
- **Blocks:** t18233 / #30139
- **External:** Runtime media providers are optional capability routes, not implementation prerequisites.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Research/read | 1h | Existing job/draft/provider patterns |
| Implementation | 5h | Schemas, jobs, mappings, routing |
| Testing | 1.5h | Lifecycle, variants, claims, replay |
| **Total** | **~7.5h** | |
