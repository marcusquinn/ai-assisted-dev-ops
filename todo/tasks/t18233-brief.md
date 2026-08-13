<!-- aidevops:brief-schema=v2 -->

# t18233: Harden campaign asset provenance review and production gates

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: preserve original bytes/provenance, fail closed on missing manifest tooling, and enforce review/rights before distribution
- [x] Discovery pass: current campaign asset, launch, Remotion, provenance, and recent provenance PR reviewed; no open duplicate issue
- [x] File refs verified: 10 target/test/reference surfaces present at `45cd1150e`
- [x] Tier: `tier:standard` — provenance and approval policies are decided; implementation coordinates existing asset/render surfaces
- [x] Seeded draft PR decision recorded: skipped — worker must first measure current helper complexity and package tests

## Origin

- **Created:** 2026-08-13
- **Session:** OpenCode interactive branded-growth planning session
- **Created by:** ai-interactive
- **Parent task:** t18230 / GH#30136
- **Blocked by:** t18234 / #30140; `blocked-by:t18234`
- **Conversation context:** Make generated and edited campaign assets safely reviewable, reproducible, rights-aware, and impossible to publish from incomplete lifecycle states.

## What

Version and harden campaign asset/render manifests so every original and derivative records source lineage, hashes, dimensions/duration, recipe/tool/provider, brand/style references, rights/license/consent/territory/expiry, synthetic-content disclosure, review decision, experiment/variant identity, and output status. Enforce fail-closed review, provenance, integrity, and deterministic render gates before promotion or distribution.

## Why

The current asset helper records basic asset metadata and previews, while campaign launch/promotion and render paths do not consistently enforce rights, review, deterministic output, or lifecycle truth. These are prerequisites for believable high-quality production and safe automation.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The trust policy is defined by existing provenance and human-review guidance; implementation requires bounded coordination and recovery design.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** Current helper/function complexity and render package test seams need worker verification first.
- **Status:** `not-created`
- **Freshness evidence:** Repository and GitHub discovery completed against `45cd1150e`.
- **Verification run:** `UNVERIFIED — planning only`
- **Stale-assumption warning:** Recheck campaign asset and provenance changes after PR #30064.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/campaign-asset-helper.sh`, campaign launch/promote paths in `.agents/scripts/campaign-helper.sh`, and `.agents/tools/security/content-provenance.md:24-72`.
- **Load only if:** video jobs are in fixtures, then inspect Remotion `types.ts`, `render.mjs`, and `FullVideo.tsx`.
- **Why:** Enforce one asset contract across current owners without creating a new media library.
- **Stop when:** Schema migration, original/derivative lineage, review gate, deterministic output, atomicity, and rollback are fixed.

### Worker Quick-Start

```bash
rg -n 'manifest|jq|preview|sha|blob|symlink' .agents/scripts/campaign-asset-helper.sh
rg -n 'reviewed|promoted|launch|in-progress|results' .agents/scripts/campaign-helper.sh
rg -n 'timestamp|caption|objectFit|scene|warn' .agents/scripts/higgsfield/remotion/render.mjs .agents/scripts/higgsfield/remotion/src
```

### Files to Modify

- `EDIT: .agents/scripts/campaign-asset-helper.sh` — schema-v2 writes, locking/atomicity, duplicate IDs, lineage, integrity, cleanup, and fail-closed dependencies.
- `EDIT: .agents/scripts/campaign-helper.sh` — review/provenance/rights gate before promotion/launch/distribution eligibility.
- `NEW: .agents/schemas/campaign-asset-manifest.schema.json` — versioned original and derivative contract.
- `EDIT: .agents/scripts/higgsfield/remotion/src/types.ts` — timed captions and render/output manifest types.
- `EDIT: .agents/scripts/higgsfield/remotion/render.mjs` — deterministic names/hashes, hard validation, output manifest.
- `EDIT: .agents/scripts/higgsfield/remotion/src/FullVideo.tsx` — explicit crop/fit policy from manifest.
- `EDIT: .agents/aidevops/campaigns-plane.md` — align preview limits, manifest version, and gate behavior.
- `NEW: .agents/scripts/tests/test-campaign-asset-manifest.sh` — shell asset/atomicity/cleanup fixtures.
- `NEW: .agents/scripts/higgsfield/remotion/render.test.mjs` — render manifest/caption/crop/determinism fixtures.

### Complete Write Surface

- **Callers/readers:** `contract:` Campaign asset add/list/manifest/preview; content production; campaign review/launch; distribution bridge; Remotion renderer.
- **Writers/mutation paths:** `contract:` Manifest JSON, blob store, symlinks, previews, generated render outputs/manifests, campaign review metadata, active→launched movement.
- **Tests/fixtures:** `contract:` New shell and Node tests plus campaign status routing and provenance agent review test.
- **Schemas/config:** `contract:` New asset schema; campaign config blob threshold and preview limit; production manifest from t18234 is a reader/writer dependency.
- **Generated/deployed mirrors:** `contract:` `.agents/` deploys; user binaries remain in campaign/blob workspaces and must never be committed accidentally.
- **Migrations/backfills:** `contract:` Read schema v1; write schema v2; explicit migrate/repair command or lazy migration only after complete validation.
- **Cleanup/rollback paths:** `contract:` Remove staged preview/blob/symlink/manifest additions on failure; preserve original bytes and last valid manifest.

### Implementation Steps

1. Define schema-v2 entries for originals, derivatives, rights/provenance, review, recipe/tool/provider, hashes, dimensions/timing, captions, variants, and disclosure.
2. Make missing required tools (including manifest JSON tooling) a non-zero failure before mutation; optional preview dependencies may produce explicit `preview_unavailable` only when policy permits.
3. Add lock/staging/atomic replacement and collision-safe IDs; validate symlink destination and blob integrity.
4. Add review commands/state transitions and make campaign launch/distribution eligibility require approved assets with valid rights/provenance and completed outputs.
5. Preserve word/segment timing in captions, record crop/fit choices, reject scene/input mismatches, and emit deterministic render recipes/output hashes.
6. Align documented preview maximum with implementation and screenshot safety limits.
7. Test interruption at each mutation boundary and legacy-manifest reads.

### Hazards and Compatibility

- **Concurrency/atomicity:** Manifest updates and blob ingestion require locking and atomic replacement; concurrent duplicate content must converge safely.
- **Migration/rollback:** Schema-v1 reads remain; failed migration or render never destroys original bytes or valid metadata.
- **Mixed-version/backward compatibility:** Old consumers can still list core fields; automated distribution requires schema-v2 readiness.
- **Idempotency/retry:** Content-addressed original ingestion and recipe hashes prevent duplicate derivatives on replay.
- **Partial failure/recovery:** Cleanup staged files/symlinks/previews and expose repair diagnostics; never leave `approved` after output integrity failure.

### Complexity Impact

- **Target function:** asset ingestion/manifest mutation and campaign launch functions.
- **Current line count:** measure at worker start; threshold 100 lines.
- **Estimated growth:** high if embedded.
- **Projected post-change:** likely over limits without decomposition.
- **Action required:** Extract schema, transaction, rights validation, and review helpers before extending orchestrators.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-campaign-asset-manifest.sh
node --test .agents/scripts/higgsfield/remotion/render.test.mjs
bash .agents/scripts/tests/test-campaign-status-routing.sh
bash .agents/scripts/tests/test-agent-review-provenance.sh
shellcheck .agents/scripts/campaign-asset-helper.sh .agents/scripts/campaign-helper.sh .agents/scripts/tests/test-campaign-asset-manifest.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Asset fixtures prove migration, atomicity, rights/review, cleanup, and integrity; Node tests prove render determinism/timing/crop; status/provenance tests protect launch and metadata contracts.
- **Broad verification trigger:** If Remotion dependencies or package scripts change, run the affected package typecheck/build in addition to Node tests.

### Recoverability Checkpoint

- [ ] Focused tests pass: asset and render test commands above
- [ ] WIP commit created before broad gates: `wip: harden campaign asset manifests`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Files Scope

- `.agents/scripts/campaign-asset-helper.sh`
- `.agents/scripts/campaign-helper.sh`
- `.agents/schemas/campaign-asset-manifest.schema.json`
- `.agents/scripts/higgsfield/remotion/src/types.ts`
- `.agents/scripts/higgsfield/remotion/render.mjs`
- `.agents/scripts/higgsfield/remotion/src/FullVideo.tsx`
- `.agents/aidevops/campaigns-plane.md`
- `.agents/scripts/tests/test-campaign-asset-manifest.sh`
- `.agents/scripts/higgsfield/remotion/render.test.mjs`

## Acceptance Criteria

- [ ] Original and derivative assets have schema-valid lineage, integrity, rights/consent, disclosure, review, recipe, and variant metadata.
- [ ] Campaign launch or distribution eligibility rejects missing/unapproved/expired/unlicensed/incomplete assets and never promotes `in-progress` output.
- [ ] Missing required tooling, interrupted writes, collisions, and render mismatches fail non-zero while preserving originals and the prior valid manifest.
- [ ] Repeating unchanged ingestion/render produces stable identity/output evidence rather than duplicates or timestamp-only names.
- [ ] Timed captions and explicit crop/fit policy survive the production manifest into rendered-output evidence.

## Context & Decisions

- Extend existing Campaign Asset, Content, editor, Remotion, and provenance owners; do not add a duplicate media-library agent.
- Preserve originals and authenticity metadata; transformations create linked derivatives.
- Rights/consent and disclosure are machine-enforced eligibility data, not advisory prose.

## Relevant Files

- `.agents/scripts/campaign-asset-helper.sh`
- `.agents/scripts/campaign-helper.sh:532-598,900-937`
- `.agents/tools/security/content-provenance.md:24-72`
- `.agents/scripts/higgsfield/remotion/render.mjs`
- `.agents/scripts/higgsfield/remotion/src/types.ts`
- `.agents/scripts/higgsfield/remotion/src/FullVideo.tsx`
- `.agents/aidevops/campaigns-plane.md:65-83,172-205`

## Dependencies

- **Blocked by:** t18234 / #30140
- **Blocks:** t18232 / #30138
- **External:** Optional render tools/providers are fixture-gated; no production account required.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Research/read | 1h | Mutation and render seams |
| Implementation | 5h | Schema, transactions, gates, manifests |
| Testing | 2h | Failure injection, migration, rendering |
| **Total** | **~8h** | |
