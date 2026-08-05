---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18196: Define isolated app-team manifest contracts

## Pre-flight

- [x] Memory recall: `app team manifest dedicated cloned shared specialists identity memory workspace credential isolation workload tiers provider-neutral contracts` → 0 hits — no reusable stored lesson found.
- [x] Discovery pass: exact app-team schema targets have 0 recent commits, 0 related merged PRs, and 0 related open PRs; current agent discovery and memory namespace behavior are implementation precedents, not a portable team manifest.
- [x] File refs verified: 8 mission, source-review, agent-discovery, workload-tier, memory-isolation, and agent-frontmatter references checked at current HEAD; Buzz evidence remains pinned to `0afeac8a7c173fd3ede8a22e27919e63161bf07c`.
- [x] Tier: `tier:standard` — all three specialist modes, isolation defaults, forbidden sharing, reference boundaries, and failure behavior are decided below; implementation follows the established schema/test pattern.
- [x] Seeded draft PR decision recorded: skipped — a partial manifest without cross-team collision and shared-state negative fixtures would be unsafe to reuse.

## Origin

- **Created:** 2026-08-04
- **Session:** OpenCode interactive mission `m-20260804-5d06b1`
- **Created by:** ai-interactive
- **Parent task:** none; this is Milestone 1 feature 1.3
- **Blocked by:** t18193 / #29494 — app-team records reference the versioned core identity, resource, capability, and secret-reference definitions
- **Conversation context:** The mission requires reusable app-specific teams without identity, memory, workspace, credential, authority, or publication-context leakage. Canonical agent discovery and runtime workload routing must remain authoritative.

## What

Add a version-1 app-team manifest schema, positive fixtures for dedicated,
cloned, and shared specialists, cross-app isolation and forbidden-state
fixtures, executable schema/semantic tests, and reference documentation.

This leaf defines portable desired-state records only. It does not generate the
canonical aidevops roster, create provider teams or identities, resolve secret
references, start runners, create memory databases, or change runtime agent
configuration.

## Why

Reusing one long-lived agent identity or process across applications would mix
reputation, conversations, memory, credentials, roots, and authority. At the
other extreme, duplicating concrete provider/model configuration into every
team would drift from canonical aidevops discovery. A strict manifest contract
is needed so dedicated and cloned teammates remain isolated while shared
specialists behave as stateless capabilities under caller context.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The consequential isolation choices are resolved in this
brief. The worker implements a closed additive schema, fixtures, semantic
assertions, and documentation with normal bounded judgment.

## PR Conventions

This is a leaf task. Use a closing keyword for its issue and reference mission
`m-20260804-5d06b1` plus blocker #29494. Do not modify or close the core-contract
issue from this task.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** All three modes and the cross-app negative invariants must land together for the contract to be safely reusable.
- **Status:** `not-created`
- **Freshness evidence:** Memory recall, exact-path discovery, current agent discovery, model-tier, memory namespace, mission, and source-review reads completed on 2026-08-04.
- **Verification run:** Unrun before implementation; the core schema dependency is not merged yet.
- **Stale-assumption warning:** Re-run canonical primary-agent discovery and re-check the merged core definitions if #29494 or agent frontmatter changes before implementation starts.

## How (Approach)

### Progressive Context Plan

- **Read first:** this brief's Worker Quick-Start and mode matrix; they are the authoritative isolation decisions.
- **Then load:** `todo/missions/m-20260804-5d06b1/research/source-review.md:239-259`, `.agents/scripts/lib/agent_config.py:246-278`, and the merged `core-v1.schema.json` definitions.
- **Load only if:** workload-tier semantics are unclear — `.agents/configs/model-routing-table.json:6-19`; memory namespace behavior is unclear — `.agents/reference/memory.md:153-161`.
- **Why:** define a portable contract without hard-coding the current 13-agent roster, provider models, host paths, or runtime implementation details.
- **Stop when:** every specialist mode, isolation axis, reference-only boundary, collision negative, and regression criterion maps to a schema field and test.

### Worker Quick-Start

```text
1. Reference the merged core contract by stable $id; do not duplicate identities, capabilities, resources, or secret-reference definitions.
2. Store canonical workload tiers (`simple|standard|thinking`), never concrete provider or model IDs.
3. Dedicated and cloned instances require app/team-scoped identity, memory namespace, workspace-root references, credentials, and audit context.
4. Cloning reuses versioned specialist instructions/capabilities, never the source agent's signing identity, memory, workspace, credentials, or mutable runtime state.
5. Shared specialists are stateless capabilities: no persistent teammate identity or conversation memory; caller/team context publishes and owns each result.
6. Manifests contain stable registered references, not secret values or private host paths.
7. Reject cross-app collisions in mutable identity, memory, and workspace scopes unless a later brokered shared-capability request supplies isolated context.
```

Canonical mode behavior:

| Mode | Persistent identity/memory | Workspace and credentials | Publication/audit identity |
|---|---|---|---|
| `dedicated` | Unique app/team/community identity and memory namespace | Explicit registered app root references and app/team secret references | Dedicated agent plus initiating actor |
| `cloned` | New isolated identity and memory namespace; versioned source-template reference only | New app root and secret references; no inherited mutable source state | Cloned app agent plus initiating actor |
| `shared` | No persistent teammate identity; memory is `none` or request-scoped | Request-supplied scoped roots and capability-specific credential broker | Caller/team identity plus capability and actor |

### Files to Modify

- `NEW: .agents/schemas/team-interface/app-team-v1.schema.json` — app-team manifest and discriminated specialist-mode records.
- `NEW: .agents/reference/team-interface-app-teams.md` — mode selection, isolation, references, publication identity, ownership boundaries, and failure behavior.
- `NEW: .agents/scripts/tests/test-team-interface-app-team-schema.mjs` — Ajv validation plus cross-document isolation assertions.
- `NEW: .agents/scripts/tests/fixtures/team-interface/app-team-valid-modes.json` — one manifest exercising all three modes.
- `NEW: .agents/scripts/tests/fixtures/team-interface/app-team-valid-isolation.json` — two app teams with distinct mutable namespaces and references.
- `NEW: .agents/scripts/tests/fixtures/team-interface/app-team-invalid-shared-state.json` — persistent identity/memory/static-root leakage in shared mode.
- `NEW: .agents/scripts/tests/fixtures/team-interface/app-team-invalid-isolation.json` — cross-app mutable identity, memory, or workspace collision.
- `NEW: .agents/scripts/tests/fixtures/team-interface/app-team-invalid-secret-model.json` — secret-value, private-path, or concrete-model fields.

### Complete Write Surface

- **Callers/readers:** Future canonical-roster generation, desired-state planning, provider adapters, and aidevops.app APIs will consume `NEW: .agents/schemas/team-interface/app-team-v1.schema.json`; the new Node test is the only runtime reader added now. The schema references t18193 core records and uses opaque references for later trust/reconciliation contracts.
- **Writers/mutation paths:** Not applicable because this contract-only leaf creates no team, agent, identity, memory namespace, root, credential, or provider record. Milestone 2 and 5 writers must validate manifests and resolve references before any mutation.
- **Tests/fixtures:** `NEW: .agents/scripts/tests/test-team-interface-app-team-schema.mjs` reads two valid and three invalid fixture families, compiles core plus app-team schemas, and checks cross-document uniqueness beyond structural validation.
- **Schemas/config:** `NEW: .agents/schemas/team-interface/app-team-v1.schema.json` is the sole schema/config change. Existing `config.jsonc`, runtime agent configuration, model routing, and primary-agent frontmatter remain unchanged; later configuration stores only enablement/path references.
- **Generated/deployed mirrors:** Tracked `.agents/` sources deploy through the existing setup copy path. No generated primary-agent registry, provider team, runtime overlay, or separately maintained mirror is produced by this task.
- **Migrations/backfills:** Not applicable because no prior app-team manifest exists. Unknown schema versions, unresolved stable references, and legacy ad hoc team data fail validation rather than receiving inferred identities or scopes.
- **Cleanup/rollback paths:** Reverting `.agents/schemas/team-interface/app-team-v1.schema.json`, `.agents/reference/team-interface-app-teams.md`, `.agents/scripts/tests/test-team-interface-app-team-schema.mjs`, and the `app-team-*.json` fixtures removes the additive contract without deleting provider state or local namespaces. No generated roster or external resource needs cleanup.

### Implementation Steps

1. Create a closed draft-2020-12 schema with stable `$id` `urn:aidevops:team-interface:app-team:v1`, `schema_version: 1`, and root `document_type: app_team_manifest`.
2. Require stable `manifest_id`, `app_id`, `team_id`, source/version metadata, provider/community/resource binding references, trust-policy reference, authority-policy reference, reconciliation-policy reference, runner/local-model eligibility, and a non-empty specialist list. Treat display labels as non-authoritative.
3. Define common specialist fields: stable `instance_id`, canonical `template_agent_id` or capability reference, template source revision/digest, canonical workload tier, resource-binding references, and audit context requirements. Do not embed provider/model IDs or instruction copies whose provenance cannot be checked.
4. Use a discriminated `oneOf` for `dedicated`, `cloned`, and `shared`. Dedicated/cloned records require scoped identity, memory namespace, registered workspace-root references, secret references, and caller-aware audit publication. Cloned records additionally require an immutable template source and prohibit inherited mutable source state.
5. Make shared mode require `stateless: true`, `memory_mode: none|request_scoped`, `publication_mode: caller`, request-context axes, workspace-policy reference, and credential-broker reference. Prohibit persistent identity, memory namespace, fixed app workspace roots, direct team credential references, or representation as a persistent teammate.
6. Keep field-ownership semantics in feature 1.4: this manifest carries only a stable `reconciliation_policy_ref`. Keep trust behavior in feature 1.2: this manifest carries only policy/profile references. Do not duplicate either contract.
7. Add semantic assertions across manifests: stable IDs are unique; dedicated/cloned identity, memory, and mutable workspace scopes do not collide across apps/teams; shared capabilities retain app/team/community/project/actor/audit context; tiers are only `simple|standard|thinking`.
8. Recursively reject secret-value property names, raw host paths, concrete model/provider fields, display-name identity, and unknown properties. Confirm valid fixtures use only registered IDs and approved secret references.
9. Document mode-selection guidance, ownership and publication semantics, canonical discovery boundary, reference resolution, invalid/unresolved behavior, and the future composition points with trust/reconciliation contracts.
10. Run the focused test and changed-file gates without generating agents, provisioning Buzz/Matrix, or editing runtime configuration.

### Hazards and Compatibility

- **Concurrency/atomicity:** This task adds no writer. Later planners must validate one complete manifest revision atomically and reject duplicate stable IDs or namespace ownership before creating any partial team state.
- **Migration/rollback:** There is no prior manifest migration. A future schema version requires explicit migration; rollback removes only additive contract files and never deletes identities, memory, roots, or provider records.
- **Mixed-version/backward compatibility:** Existing direct OpenCode, Matrix, and Buzz behavior remains unchanged. Unsupported manifest versions or unresolved core/policy references fail closed instead of inheriting global defaults.
- **Idempotency/retry:** A manifest is identified by stable ID plus source revision/digest. Retrying validation is side-effect free; later provisioning must use those values and provider external IDs rather than display names.
- **Partial failure/recovery:** If any specialist mode, template digest, identity, namespace, root, secret reference, or policy reference is invalid, reject the manifest as a unit. A model or adapter cannot silently downgrade isolation or substitute a shared global context.

### Verification Before Dispatch

```bash
node .agents/scripts/tests/test-team-interface-app-team-schema.mjs
node --input-type=module -e 'import Ajv2020 from "ajv/dist/2020.js"; const ajv = new Ajv2020(); process.exit(typeof ajv.addSchema === "function" ? 0 : 1)'
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The Node test compiles core and app-team schemas, validates all fixture families, and checks mode, isolation, tier, path, model, and secret invariants; the Ajv probe confirms multi-schema support; changed-file lint covers JSON, JavaScript, Markdown, licensing, and secret detection.
- **Broad verification trigger:** Not required — this leaf adds isolated contract/test files and does not alter discovery, runtime config, setup, memory storage, provider state, or dependencies.

### Recoverability Checkpoint

- [ ] Focused tests pass: `node .agents/scripts/tests/test-team-interface-app-team-schema.mjs`
- [ ] WIP commit created before broad gates: `wip: add isolated app-team manifest contract`
- [ ] Evidence-triggered broad verification then run: not required; run `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Define isolated app-team manifest contracts for Milestone 1 feature 1.3.
- **Preserved user directions:** Support dedicated, cloned, and shared specialists without leaking identity, memory, workspace, credentials, authority, or publication context; keep runtime model routing provider-neutral.
- **Trigger and evidence:** not triggered
- **Completed and verified:** Mission/source evidence, all three mode decisions, and implementation boundaries are preserved in this brief.
- **Remaining acceptance criteria:** Implement and verify every schema, fixture, semantic invariant, and reference criterion below.
- **Unsafe route not to repeat:** Do not reuse signing identities or persistent memory across apps, encode concrete models, store secret values/private paths, or represent shared capabilities as persistent teammates.
- **Next safe route:** Reject the whole manifest and report the exact invalid reference/collision without provisioning partial provider or local state.
- **Resume condition:** t18193 is merged and no in-flight PR touches the declared app-team paths.
- **Owner and status:** Assigned implementation worker; blocked by t18193

### Files Scope

- `.agents/schemas/team-interface/app-team-v1.schema.json`
- `.agents/reference/team-interface-app-teams.md`
- `.agents/scripts/tests/test-team-interface-app-team-schema.mjs`
- `.agents/scripts/tests/fixtures/team-interface/app-team-*.json`

## Acceptance Criteria

- [ ] Valid fixtures for dedicated, cloned, and shared modes compile against core and app-team schema version 1 and exhibit the exact isolation/publication behavior in the mode matrix.

  ```yaml
  verify:
    method: bash
    run: "node .agents/scripts/tests/test-team-interface-app-team-schema.mjs"
  ```

- [ ] Two app-team fixtures cannot collide on dedicated/cloned signing identity, memory namespace, or mutable workspace scope, while shared capability requests retain separate app, team, community, project, actor, and audit context.

  ```yaml
  verify:
    method: codebase
    pattern: "invalid-isolation|identity.*collision|memory.*collision|workspace.*collision|community.*project.*actor.*audit"
    path: ".agents/scripts/tests/test-team-interface-app-team-schema.mjs"
  ```

- [ ] Shared mode rejects persistent teammate identity, conversation memory, static app roots, direct team credentials, and self-publication; cloned mode rejects inherited mutable source state.

  ```yaml
  verify:
    method: codebase
    pattern: "invalid-shared-state|stateless|request_scoped|publication_mode|inherited"
    path: ".agents/scripts/tests/test-team-interface-app-team-schema.mjs"
  ```

- [ ] Secret values, raw private host paths, concrete model/provider IDs, display-name authority, unknown schema versions, and unknown properties are rejected without inferred fallback.

  ```yaml
  verify:
    method: codebase
    pattern: "invalid-secret-model|secret|private.*path|concrete.*model|display.*author|unknown"
    path: ".agents/reference/team-interface-app-teams.md"
  ```

- [ ] Existing canonical agent discovery, workload routing, memory storage, runtime configuration, Matrix, and Buzz behavior remains unchanged by this contract-only leaf.

  ```yaml
  verify:
    method: bash
    run: "git diff --exit-code -- .agents/scripts/lib/agent_config.py .agents/configs/model-routing-table.json .agents/reference/memory.md .agents/configs/aidevops-config.schema.json .agents/services/communications/matrix-bot.md"
  ```

- [ ] Changed-file quality and secret scans pass.

  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/linters-local.sh --changed"
  ```

## Context & Decisions

- The manifest references canonical specialist IDs and source revisions; feature 2.2 owns live roster generation and must not hard-code the current count here.
- Dedicated and cloned specialists are persistent app teammates with isolated mutable state. Shared specialists are request-scoped capabilities and publish through caller/team identity.
- Use registered workspace-root IDs and approved secret references, not host paths or secret values, so manifests remain portable and privacy-safe.
- Store workload tiers only. Runtime routing resolves concrete models and reasoning variants at execution time.
- Trust-policy behavior and field-ownership/reconciliation semantics remain separate versioned documents; this manifest stores stable references so features 1.2-1.4 can implement in parallel after the core contract.

## Relevant Files

- `todo/missions/m-20260804-5d06b1/mission.md:113-135,141-153` — app-team model and Milestone 1 feature boundary.
- `todo/missions/m-20260804-5d06b1/research/source-review.md:17-49,84-96,239-259` — canonical discovery, Buzz team boundary, community scope, and isolation defaults.
- `.agents/scripts/lib/agent_config.py:246-278` — canonical root-level primary-agent discovery path.
- `.agents/configs/model-routing-table.json:6-19` — provider-neutral workload-tier source of truth.
- `.agents/reference/memory.md:153-161` — per-runner namespace isolation and storage precedent.
- `.agents/build-plus.md:1-25` — default-tier canonical agent frontmatter example.
- `.agents/content.md:1-25` — explicit thinking-tier canonical agent frontmatter example.
- `.agents/aidevops.md:1-22` — framework specialist source that later roster generation exposes as `aidevops-guide` rather than a primary agent.

## Dependencies

- **Blocked by:** t18193 / #29494 — core identity, capability, resource, stable-ID, and secret-reference definitions.
- **Blocks:** Milestone 2 canonical roster generation, Milestone 3 team/mapping management, Milestone 5 app-team instantiation and shared capabilities, and the optional private local persona.
- **External:** No credential, provider account, live runtime, or application choice is required. Feature 1.2 trust and feature 1.4 reconciliation contracts are referenced by stable IDs but not duplicated or required to implement this isolated schema leaf.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| App-team schema | 1h 15m | Common fields and three discriminated modes |
| Fixtures and semantic tests | 1h 20m | Positive modes, cross-app isolation, forbidden state |
| Reference documentation | 35m | Selection, isolation, references, failure behavior |
| Focused verification/review | 20m | Node test and changed-file lint |
| **Total** | **3h 30m** | |
