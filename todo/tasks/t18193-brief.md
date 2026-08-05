---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18193: Define provider-neutral team-interface core contracts

## Pre-flight

- [x] Memory recall: `mission provider-neutral team interface contracts Buzz Matrix trust reconciliation compatibility` → 0 hits — no reusable stored lesson found.
- [x] Discovery pass: exact target paths have 0 recent commits, 0 related merged PRs, and 0 related open PRs; the existing capability registry is adjacent prior art, not an equivalent team-interface contract.
- [x] File refs verified: 8 aidevops mission, schema, fixture-test, Matrix, and Buzz baseline references checked at current HEAD; Buzz remains at `0afeac8a7c173fd3ede8a22e27919e63161bf07c`.
- [x] Tier: `tier:standard` — the provider-neutral boundary and required fields are decided below; implementation requires ordinary schema/test judgment but no unresolved trust or product decision.
- [x] Seeded draft PR decision recorded: skipped — schema, fixtures, and reference documentation form the smallest reviewable implementation checkpoint.

## Origin

- **Created:** 2026-08-04
- **Session:** OpenCode interactive mission `m-20260804-5d06b1`
- **Created by:** ai-interactive
- **Parent task:** none; this is Milestone 1 feature 1.1
- **Blocked by:** none
- **Conversation context:** The mission and source review require one provider-neutral vocabulary before Buzz, Matrix, aidevops.app, trust, app-team, reconciliation, and compatibility work can proceed.

## What

Create the version-1 core team-interface contract as a closed JSON Schema,
positive and negative fixtures, an executable Ajv test, and a concise reference
document. The contract must represent providers, capabilities, communities,
accounts, logical and provider identities, resources, normalized inbox/outbox
events, immutable correlation/idempotency, and a bounded compatibility summary.

This task defines data and ownership boundaries only. It does not add provider
detection, runtime state, planning/apply commands, Buzz writes, Matrix migration,
UI behavior, or live credentials.

## Why

Without one versioned core vocabulary, later adapters and the Integrations UI
would independently invent identifiers, resource kinds, authority inputs, and
event envelopes. That would couple the framework to Buzz or Matrix, make
cross-provider correlation unreliable, and allow display labels or mutable
provider state to become accidental authorization signals.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The schema family, file layout, identifiers, event fields,
extension boundaries, compatibility link, and verification approach are fixed in
this brief. The worker may make local JSON Schema composition choices while
preserving these decided semantics.

## PR Conventions

This is a leaf task. Use a closing keyword for its issue and reference mission
`m-20260804-5d06b1` in the PR summary. Do not claim completion for Milestone 1;
features 1.2 through 1.5 remain separate leaves.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** No implementation code exists yet, and a partial schema without its negative fixtures could misleadingly appear usable.
- **Status:** `not-created`
- **Freshness evidence:** Memory recall, exact-path duplicate discovery, current aidevops schema/test reads, and Buzz baseline verification were completed on 2026-08-04.
- **Verification run:** `node` successfully resolved Ajv 8.20.0 and exported `ajv/dist/2020.js`; implementation checks remain unrun.
- **Stale-assumption warning:** Re-run discovery if a team-interface schema or provider-core PR appears, or if the Buzz baseline changes before implementation starts.

## How (Approach)

### Progressive Context Plan

- **Read first:** `todo/missions/m-20260804-5d06b1/research/source-review.md:98-160` — architecture and normalized-event minimum.
- **Then load:** `.agents/schemas/capability-registry.schema.json:1-29` and `.agents/scripts/tests/test-config-schema-defaults.sh:12-69` — repository schema and Ajv test patterns.
- **Load only if:** provider semantics need confirmation — the bounded Buzz files listed under Relevant Files and `.agents/services/communications/matrix-bot.md:20-45,83-138`.
- **Why:** preserve provider-neutral mission decisions without rereading the full 403-line source review or importing adapter implementation into the core contract.
- **Stop when:** every required definition, closed-object boundary, fixture, and focused command below has an implementation path.

### Worker Quick-Start

```text
1. Use JSON Schema draft 2020-12 and stable $id `urn:aidevops:team-interface:core:v1`.
2. Use `schema_version: 1`; reject missing or unknown versions.
3. Keep internal IDs stable and provider external IDs opaque; names are display only.
4. Close every object with `additionalProperties: false` unless the brief explicitly names a bounded metadata map.
5. Represent credentials only as secret-reference identifiers; never accept token, password, private-key, or credential-value properties.
6. Keep requested authority and verified actor context as broker inputs; model output cannot mint or widen either.
7. Test valid Buzz and Matrix-shaped records plus malformed, secret-bearing, and display-name-only negatives.
```

### Files to Modify

- `NEW: .agents/schemas/team-interface/core-v1.schema.json` — draft-2020-12 schema and reusable core definitions.
- `NEW: .agents/reference/team-interfaces.md` — versioning, ownership, identifier, event, configuration-placement, and extension rules.
- `NEW: .agents/scripts/tests/test-team-interface-core-schema.mjs` — Ajv 8 test runner and semantic assertions.
- `NEW: .agents/scripts/tests/fixtures/team-interface/core-valid.json` — provider-neutral Buzz and Matrix-shaped positive records.
- `NEW: .agents/scripts/tests/fixtures/team-interface/core-invalid-secret-value.json` — forbidden secret-value fields.
- `NEW: .agents/scripts/tests/fixtures/team-interface/core-invalid-identity.json` — display-name-only or unverified identity input.
- `NEW: .agents/scripts/tests/fixtures/team-interface/core-invalid-event.json` — missing correlation, authority, or idempotency input.

### Complete Write Surface

- **Callers/readers:** Future provider registry, Buzz/Matrix adapters, aidevops.app API types, and the four remaining Milestone 1 schemas will consume `NEW: .agents/schemas/team-interface/core-v1.schema.json`; `NEW: .agents/scripts/tests/test-team-interface-core-schema.mjs` is the only caller added now.
- **Writers/mutation paths:** Not applicable because discovery found no current team-interface runtime writer; this task adds contract files and fixtures only. Future writers must validate `core-v1.schema.json` before persistence and are explicitly deferred to Milestone 2.
- **Tests/fixtures:** `NEW: .agents/scripts/tests/test-team-interface-core-schema.mjs` reads the four named fixtures and recursively checks that schema properties do not expose secret-value fields.
- **Schemas/config:** `NEW: .agents/schemas/team-interface/core-v1.schema.json` is the sole schema change. The reference decides that rich provider/team state lives in dedicated versioned documents; the existing `config.jsonc` may later contain only enablement and path/reference settings.
- **Generated/deployed mirrors:** Tracked `.agents/` files deploy through the existing setup copy path; no generated or separately maintained mirror exists for these new files, so no mirror edit is required.
- **Migrations/backfills:** Not applicable because new-file-only contract work has no persisted state to migrate. Version 1 must reject unsupported versions rather than silently reinterpret them.
- **Cleanup/rollback paths:** Reverting `.agents/schemas/team-interface/core-v1.schema.json` and its additive reference/test/fixtures restores the prior state; no provider record, credential, or user configuration is created or deleted.

### Implementation Steps

1. Create `core-v1.schema.json` with closed definitions and a discriminated root for `registry` and `event` documents. Require `schema_version`, `document_type`, and the relevant payload.
2. Define the following bounded records and minimum fields:
   - provider: `provider_id`, `adapter_id`, `adapter_version`, observed `provider_version`, capability records, and a compatibility summary/reference;
   - capability: stable `capability_id`, supported resource kinds and operations, availability state, and owner-review requirement;
   - community/account: stable internal ID, provider ID, opaque provider external ID, account references, and non-authoritative display label;
   - identity: logical subject ID/type, provider identity ID, community, opaque external ID, verification status/method/evidence reference, and optional secret reference;
   - resource: stable resource ID, provider/community IDs, opaque external ID, kind, optional parent, display label, management owner, and compatibility reference;
   - event: direction, provider/version, community/conversation/thread/event lineage, verified actor subject/type/roles, signature status, target agent and app team references, bounded content and attachment metadata/digests, requested operation, authority scope, trust-profile and scan-verdict references, correlation ID, idempotency key, and occurrence time.
3. Use explicit enums for document type, event direction, subject type, resource kind, capability operation, verification state, and compatibility state. Keep provider-specific fields outside the core; adapters retain them in opaque source evidence, not arbitrary schema extensions.
4. Prohibit unknown fields and secret-value property names. Permit only identifiers such as `credential_ref` or `secret_ref`, with documentation that values resolve through approved secret storage outside this contract.
5. Document that dedicated versioned team-interface documents are authoritative; `config.jsonc` receives only minimal enable/path references in a later task. Also document stable-ID, display-name, provider-capability, schema-evolution, and adapter-extension rules.
6. Build fixtures that exercise at least two providers, nested resources, inbox and outbox events, event lineage, compatibility references, and negative identity/secret/idempotency cases.
7. Compile the schema with Ajv 8.20.0, validate every fixture, assert invalid fixtures fail for the intended keyword/path, and run changed-file quality checks.

### Hazards and Compatibility

- **Concurrency/atomicity:** This task has no runtime writer. The contract requires immutable event IDs, correlation IDs, and idempotency keys so later writers can implement atomic inbox/outbox handling without deriving identity from mutable labels.
- **Migration/rollback:** Version 1 is additive and has no migration. Unsupported versions fail closed; later schema versions require explicit read compatibility or a migration plan rather than in-place reinterpretation.
- **Mixed-version/backward compatibility:** Existing Matrix and direct aidevops behavior is untouched. Provider/adapter versions are observed data, while `schema_version` controls the normalized contract; adapters must not confuse these version axes.
- **Idempotency/retry:** Event retries reuse the same provider event ID, correlation ID, and idempotency key. The schema test must reject events missing immutable dedup inputs.
- **Partial failure/recovery:** Invalid or unknown records are rejected before persistence. Compatibility state may be `unknown` or `unsupported`, but that state cannot broaden capabilities or authority.

### Verification Before Dispatch

```bash
node .agents/scripts/tests/test-team-interface-core-schema.mjs
node --input-type=module -e 'import Ajv2020 from "ajv/dist/2020.js"; const ajv = new Ajv2020(); process.exit(typeof ajv.compile === "function" ? 0 : 1)'
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The focused Node test compiles the only new schema and validates all positive/negative fixtures; the import probe verifies the locally locked Ajv export used by the test; changed-file lint covers JSON, JavaScript, Markdown, licensing, and secret scanning.
- **Broad verification trigger:** Not required — the task adds isolated schema/reference/test files and does not change root dependencies, runtime code, setup routing, or shared configuration.

### Recoverability Checkpoint

- [ ] Focused tests pass: `node .agents/scripts/tests/test-team-interface-core-schema.mjs`
- [ ] WIP commit created before broad gates: `wip: add team-interface core contract`
- [ ] Evidence-triggered broad verification then run: not required; run `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Define the complete provider-neutral core contract for Milestone 1 feature 1.1.
- **Preserved user directions:** Work only on Milestone 1, keep provider logic neutral, create no live provider writes, and preserve implementation-ready issue ordering.
- **Trigger and evidence:** not triggered
- **Completed and verified:** Mission/source evidence and the complete execution contract are preserved in this brief.
- **Remaining acceptance criteria:** Implement and verify every schema, fixture, test, and reference criterion below.
- **Unsafe route not to repeat:** Do not hard-code Buzz or Matrix as the core model, accept display names as identity, or store secret values.
- **Next safe route:** Narrow implementation to one missing definition or fixture while retaining the full contract and failing unsupported records closed.
- **Resume condition:** The worker has the current mission brief and no in-flight PR touching the declared files.
- **Owner and status:** Assigned implementation worker; not-triggered

### Files Scope

- `.agents/schemas/team-interface/core-v1.schema.json`
- `.agents/reference/team-interfaces.md`
- `.agents/scripts/tests/test-team-interface-core-schema.mjs`
- `.agents/scripts/tests/fixtures/team-interface/core-*.json`

## Acceptance Criteria

- [ ] A valid fixture containing Buzz- and Matrix-shaped providers, capabilities, communities, identities, resources, and both event directions validates against schema version 1.

  ```yaml
  verify:
    method: bash
    run: "node .agents/scripts/tests/test-team-interface-core-schema.mjs"
  ```

- [ ] Secret-value fields, display-name-only identity, unknown schema versions, unknown properties, and events missing immutable authority/correlation/idempotency inputs are rejected without permissive fallback.

  ```yaml
  verify:
    method: codebase
    pattern: "core-invalid-(secret-value|identity|event)"
    path: ".agents/scripts/tests/test-team-interface-core-schema.mjs"
  ```

- [ ] The reference defines dedicated versioned documents, stable internal versus opaque external IDs, non-authoritative display labels, capability negotiation, and the boundary between core and provider-specific evidence.

  ```yaml
  verify:
    method: codebase
    pattern: "dedicated versioned|display.*author|opaque external|capability negotiation|provider-specific"
    path: ".agents/reference/team-interfaces.md"
  ```

- [ ] Existing Matrix, direct aidevops, and provider runtime behavior remains unchanged because this leaf adds contracts/tests only and performs no provider or configuration writes.

  ```yaml
  verify:
    method: bash
    run: "git diff --exit-code -- .agents/services/communications/matrix-bot.md .agents/scripts/matrix-dispatch-helper.sh .agents/configs/aidevops-config.schema.json"
  ```

- [ ] Changed-file quality and secret scans pass.

  ```yaml
  verify:
    method: bash
    run: ".agents/scripts/linters-local.sh --changed"
  ```

## Context & Decisions

- Use a dedicated versioned team-interface schema family. Do not nest rich provider, team, policy, reconciliation, or compatibility state inside `config.jsonc`.
- The core owns normalized identifiers, resources, capabilities, and event envelopes; provider adapters own source-specific extraction and preserve raw evidence outside the normalized contract.
- Display names are presentation fields only. Deterministic identity and authority use stable IDs, verified provenance, roles, and broker-supplied scopes.
- Compatibility detail is a separate feature 1.5 contract; the core carries only a bounded summary and stable reference.
- Ajv 8.20.0 and its draft-2020-12 export are present through the locked repository dependency graph and already have a repository test precedent; do not add or upgrade dependencies in this leaf.

## Relevant Files

- `todo/missions/m-20260804-5d06b1/mission.md:141-153` — Milestone 1 scope and feature boundaries.
- `todo/missions/m-20260804-5d06b1/research/source-review.md:98-160` — target architecture and normalized event minimum.
- `.agents/schemas/capability-registry.schema.json:1-29` — existing draft-2020-12 schema pattern.
- `.agents/configs/capability-registry.json:1-26` — versioned registry and capability shape precedent.
- `.agents/scripts/tests/test-config-schema-defaults.sh:12-69` — current Ajv compile/validation pattern.
- `.agents/services/communications/matrix-bot.md:20-45,83-138` — existing Matrix provider/session/state behavior to preserve.
- `desktop/src-tauri/src/managed_agents/types/requests.rs:132-256` in Buzz baseline `0afeac8a7c173fd3ede8a22e27919e63161bf07c` — current managed-agent request surface and missing external-management metadata.
- `crates/buzz-acp/src/config.rs:421-467,497-571` in the same Buzz baseline — current model/title/permission/author-gate fields that remain adapter inputs rather than core authority.

## Dependencies

- **Blocked by:** none
- **Blocks:** Milestone 1 features 1.2 adaptive trust, 1.3 app-team manifests, 1.4 reconciliation, and 1.5 compatibility metadata.
- **External:** No credential, account, provider installation, or live service is required. Buzz evidence is pinned to the reviewed local baseline and must be rechecked if that baseline changes.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Schema and field definitions | 1h 30m | Closed core records and version boundary |
| Fixtures and Ajv test | 1h 15m | Positive plus three negative families |
| Reference documentation | 45m | Ownership, IDs, events, configuration placement |
| Focused verification/review | 30m | Node test and changed-file lint |
| **Total** | **4h** | |
