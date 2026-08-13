<!-- aidevops:brief-schema=v2 -->

# t18228: Define evidence-backed brand product and offer campaign intake

## Pre-flight (auto-populated by briefing workflow)

- [x] Memory recall: `branded content campaign growth` → prior session synthesis retained; no conflicting implementation lesson
- [x] Discovery pass: current campaign, Content, Product, Marketing-Sales, Design, Legal, and provenance owners inspected; no open duplicate issue found
- [x] File refs verified: 8 target/reference surfaces present at `45cd1150e`
- [x] Tier: `tier:standard` — the canonical owners and compatibility boundary are decided; implementation details require normal schema and shell judgment
- [x] Seeded draft PR decision recorded: skipped — a worker-ready issue is preferable to an implementation seed

## Origin

- **Created:** 2026-08-13
- **Session:** OpenCode interactive branded-growth planning session
- **Created by:** ai-interactive
- **Parent task:** t18230 / GH#30136
- **Blocked by:** none
- **Conversation context:** The user wants aidevops users to supply a brand, product, and offer, then receive evidence-backed research and campaign work designed to improve reach, conversion, account growth, leads, and sales.

## What

Add a versioned, validated campaign intake contract and CLI flow that captures the user's brand/product/service, offer, objectives, audiences and buying roles, positioning, proof, claims, constraints, disclosures, channel scope, success metrics, approval policy, and canonical brand references. `campaign new` must produce a complete intake-backed campaign brief or fail with actionable missing-field diagnostics; it must reference rather than duplicate canonical brand identity data.

## Why

The campaign plane already owns lifecycle and storage, while Product, Content, Marketing-Sales, Design, Legal, and provenance owners already provide the reasoning. The missing handoff is a structured input that lets those owners collaborate without inventing incompatible briefs or generating unsupported claims.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** This extends established campaign and schema patterns without redesigning a trust boundary; the worker must coordinate a known multi-file surface and preserve version-1 campaign compatibility.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The brief supplies the verified ownership and contract, but implementation should remain unanchored until the worker inspects current helper decomposition and test seams.
- **Status:** `not-created`
- **Freshness evidence:** Repository and GitHub discovery completed against `45cd1150e` on 2026-08-13.
- **Verification run:** `UNVERIFIED — planning only`
- **Stale-assumption warning:** Recheck recent changes to `campaign-helper.sh`, campaign templates, and campaign tests before editing.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/aidevops/campaigns-plane.md:31-58,96-145,151-209` and `.agents/scripts/campaign-helper.sh` creation/brief functions — establish the current campaign write contract.
- **Load only if:** `.agents/content/research.md`, `.agents/product/validation.md`, `.agents/marketing-sales/cro-chapter-17.md`, and `.agents/marketing-sales/ad-creative-offers-landing.md` — use when defining fields for audience, buying roles, validation, offer, and proof.
- **Why:** Keep Campaigns Plane as system of record while reusing specialist reasoning.
- **Stop when:** The versioned schema, migration/default behavior, CLI inputs, validation errors, and focused tests are explicit.

### Worker Quick-Start

```bash
rg -n 'brief\.md|campaign new|success criteria|target audience|core message' .agents/scripts/campaign-helper.sh .agents/templates .agents/aidevops/campaigns-plane.md
rg -n 'brand-identity|buying committee|proof|offer|claim|disclosure' .agents/content .agents/product .agents/marketing-sales .agents/tools/design .agents/tools/security
```

### Files to Modify

- `EDIT: .agents/scripts/campaign-helper.sh` — accept, validate, persist, inspect, and safely update the versioned intake.
- `EDIT: .agents/aidevops/campaigns-plane.md` — document the canonical intake and compatibility contract.
- `NEW: .agents/schemas/campaign-intake.schema.json` — machine-readable schema; verify the parent directory and model style on an existing repository schema.
- `NEW: .agents/templates/campaign-brief.md` — render the structured fields without duplicating brand source files; model repository template style on `.agents/templates/campaign-results.md`.
- `EDIT: .agents/scripts/tests/test-campaign-status-routing.sh` — preserve current lifecycle/status behavior.
- `NEW: .agents/scripts/tests/test-campaign-intake.sh` — positive, missing-field, legacy, update, and unsafe-input fixtures.

### Complete Write Surface

- **Callers/readers:** `contract:` `campaign-helper.sh` `new`, `status`, `draft`, `launch`, `promote`; Content/Marketing agents read `_campaigns/active/<id>/brief.md` and research/creative children.
- **Writers/mutation paths:** `contract:` campaign creation/update writes `_campaigns/active/<id>/brief.md`; provisioning supplies templates/config; launch moves the active campaign to launched state.
- **Tests/fixtures:** `contract:` existing campaign status tests plus the new intake fixture suite.
- **Schemas/config:** `contract:` new intake schema; `_campaigns/_config/campaigns.json` and campaign channel specs remain compatible consumers.
- **Generated/deployed mirrors:** `contract:` `setup.sh` deploys `.agents/`; no user campaign data belongs in the framework repository.
- **Migrations/backfills:** `contract:` legacy unversioned briefs remain readable and are upgraded only on an explicit update/write; no bulk rewrite.
- **Cleanup/rollback paths:** `contract:` reject invalid writes before replacement; use staged atomic replacement; preserve the last valid brief on interruption.

### Implementation Steps

1. Define schema version 1 for identity/reference fields, offer economics/terms, objectives, ICP and buying roles, pains/jobs/outcomes, positioning, proof and claim evidence, objections, exclusions, channels, dates, KPIs, disclosures, sensitivity, and approvals.
2. Extend campaign creation with file and non-interactive inputs suitable for agents; do not require secrets or external account setup.
3. Validate slugs, scalar/array bounds, dates, channel identifiers, source references, and evidence requirements. Never infer a factual claim as approved merely because text is present.
4. Render a human-readable `brief.md` with a stable machine-readable block. Reference `context/brand-identity.toon`, `DESIGN.md`, or `_campaigns/lib/brand/` rather than copying them.
5. Preserve legacy briefs in read/status paths; require explicit migration before structured updates.
6. Add focused fixtures and update docs/routing pointers using progressive disclosure rather than expanding always-loaded guidance.

### Hazards and Compatibility

- **Concurrency/atomicity:** Two intake updates must not interleave; stage, validate, and atomically replace under the existing campaign ownership model.
- **Migration/rollback:** Version-0 briefs remain readable. Failed migration leaves the original intact and reports recovery steps.
- **Mixed-version/backward compatibility:** Draft/status/launch consumers must handle legacy and schema-v1 briefs until migration is explicit.
- **Idempotency/retry:** Replaying the same normalized intake yields the same semantic record and must not duplicate campaign directories.
- **Partial failure/recovery:** Schema or render failure must leave no half-written brief; temporary files are cleaned or recoverable.

### Complexity Impact

- **Target function:** inspect campaign creation and status functions in `.agents/scripts/campaign-helper.sh` before modification.
- **Current line count:** measure at worker start; shell complexity threshold is 100 lines.
- **Estimated growth:** likely more than 40 lines across parsing/validation/rendering.
- **Projected post-change:** unknown until current function boundaries are measured.
- **Action required:** Extract schema parsing, validation, and rendering helpers before adding branches if any target would exceed 80 lines.

### Verification Before Dispatch

```bash
bash .agents/scripts/tests/test-campaign-intake.sh
bash .agents/scripts/tests/test-campaign-status-routing.sh
shellcheck .agents/scripts/campaign-helper.sh .agents/scripts/tests/test-campaign-intake.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** Intake tests cover schema, atomic writes, legacy reads, idempotency, and rejection; status tests protect lifecycle callers; ShellCheck and changed-file lint cover code/docs/schema integration.
- **Broad verification trigger:** Not required unless the worker changes shared CLI dispatch or root schema tooling.

### Recoverability Checkpoint

- [ ] Focused tests pass: `bash .agents/scripts/tests/test-campaign-intake.sh && bash .agents/scripts/tests/test-campaign-status-routing.sh`
- [ ] WIP commit created before broad gates: `wip: add campaign intake contract`
- [ ] Evidence-triggered broad verification then run: `.agents/scripts/linters-local.sh --changed`

### Files Scope

- `.agents/scripts/campaign-helper.sh`
- `.agents/aidevops/campaigns-plane.md`
- `.agents/schemas/campaign-intake.schema.json`
- `.agents/templates/campaign-brief.md`
- `.agents/scripts/tests/test-campaign-status-routing.sh`
- `.agents/scripts/tests/test-campaign-intake.sh`

## Acceptance Criteria

- [ ] A user or agent can create a campaign from a valid structured brand/product/offer input and inspect a schema-versioned brief containing objectives, audiences, proof-linked claims, channels, KPIs, disclosures, and approval policy.
- [ ] Invalid or incomplete intake fails before mutation with field-level diagnostics, and unsupported claims are never silently marked approved.
- [ ] Legacy campaign briefs remain readable by status/draft/launch paths and are not rewritten without explicit migration.
- [ ] Replaying the same intake is idempotent and interrupted writes preserve the previous valid brief.
- [ ] Focused tests and changed-file lint pass.

## Context & Decisions

- Extend Campaigns Plane and existing domain owners; do not add a generic brand, ICP, or marketing-brain agent.
- Brand identity remains canonical in Design/Campaign library sources and is referenced, not duplicated.
- Raw competitive intelligence remains local/sensitive under `_campaigns/intel/`.
- Publishing credentials and account setup are outside this phase.

## Relevant Files

- `.agents/aidevops/campaigns-plane.md:31-58` — canonical directory and lifecycle contract.
- `.agents/scripts/campaign-helper.sh` — campaign creation, draft, launch, and promotion mutations.
- `.agents/tools/design/brand-identity.md:15-139` — brand identity authority.
- `.agents/content/research.md:77-103,163-186,239-289` — audience and competitor research owner.
- `.agents/product/validation.md:50-108` — product/market validation owner.
- `.agents/marketing-sales/cro-chapter-17.md:40-66` — buying-committee guidance.
- `.agents/tools/security/content-provenance.md:24-72` — claim/provenance boundary.

## Dependencies

- **Blocked by:** none
- **Blocks:** t18231 and t18234
- **External:** none; account credentials are explicitly out of scope

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Research/read | 45m | Inspect helper seams and schema conventions |
| Implementation | 3h | Schema, CLI, rendering, migration |
| Testing | 1h | Positive/negative/legacy/idempotency fixtures |
| **Total** | **~5h** | |
