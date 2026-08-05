---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18202: Implement the read-only team-interface core and deterministic planner

## Pre-flight

- [x] Memory recall: `team-interface provider registry config state deterministic planner` → 0 hits — no reusable stored lesson found.
- [x] Discovery pass: 0 commits, 0 merged PRs, and 0 open PRs touch the exact new runtime targets; exact title searches found no provider-registry or dry-run-planner issue collision.
- [x] File refs verified: 10 merged core/reconciliation schema, reference, fixture-test, config-pattern, state-path, architecture, mission, and source-review references checked against current merged source.
- [x] Tier: `tier:standard` — configuration ownership, adapter loading, state location, locking, deterministic planning, failure behavior, and non-mutation boundaries are decided below; implementation retains bounded local judgment.
- [x] Seeded draft PR decision recorded: skipped — a partial runtime seed without state locking, canonical hashing, and negative provider-write tests could anchor a worker to an unsafe shape.

## Origin

- **Created:** 2026-08-05
- **Session:** OpenCode interactive mission `m-20260804-5d06b1`
- **Created by:** ai-interactive under maintainer direction
- **Parent task:** t18201
- **Blocked by:** none — F1.1 and F1.4 merged through PRs #29505 and #29528
- **Conversation context:** The versioned provider and reconciliation contracts now exist. Milestone 2 needs the first executable core, but provider writes and runtime-specific adapters remain out of scope.

## What

Add a provider-neutral runtime core and shell CLI that load a dedicated versioned
team-interface configuration, register trusted in-tree adapters, validate and
atomically persist local observation state, report providers/status/doctor
results, and generate deterministic reconciliation dry-run plans.

The core may read providers through adapter `detect` and `status` methods and may
write only its own local state. It exposes no provider create, update, delete,
apply, send, invite, or publication command. F2.3 and F2.4 add the first real
Buzz and Matrix adapters after this interface merges.

## Why

The merged schemas are currently record formats only. Without one executable
core, each provider and UI would invent its own configuration, state, hashing,
ownership, and failure behavior. A read-only implementation unlocks adapters
and diagnostics while keeping provider mutations behind later reviewed
ownership/CAS and authority work.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The consequential architecture is resolved in this brief:
dedicated config, static trusted adapter registry, guarded local state, canonical
reconciliation output, and no provider-write surface. The worker still needs
normal implementation judgment across shell, Node, JSON Schema, and fixtures.

## PR Conventions

This is a leaf child of parent t18201. Use a closing keyword for this issue and
a non-closing parent reference. Do not close the parent or file F2.3/F2.4 from
this implementation branch.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** State concurrency, canonical plan hashing, adapter trust, and negative mutation coverage must land as one verified implementation.
- **Status:** `not-created`
- **Freshness evidence:** Exact-path discovery and merged contract/config/state/runtime source reads completed on 2026-08-05; target refs are unchanged between the inspected recent worktree and current `origin/main`.
- **Verification run:** Contract suites were already green at the Milestone 1 gate; new runtime tests are unrun before implementation.
- **Stale-assumption warning:** Re-check the merged core/reconciliation schemas and any in-flight team-interface PR before coding; do not edit an adapter contract that changed after this brief.

## How (Approach)

### Progressive Context Plan

- **Read first:** this brief's Worker Quick-Start, `.agents/reference/team-interfaces.md:12-28`, and `.agents/reference/team-interface-reconciliation.md:49-118` — these settle configuration ownership, secret boundaries, planning, and replay.
- **Then load:** `.agents/schemas/team-interface/reconciliation-v1.schema.json:189-430` and `.agents/scripts/tests/test-team-interface-reconciliation-schema.mjs:26-99` only while mapping plan input/output fields.
- **Load only if:** shell/config conventions are unclear — `.agents/aidevops/architecture.md:21-36,135-149`; state concurrency needs a local precedent — `.agents/scripts/lib/discovery_utils.py:16-33` for atomic replacement.
- **Why:** implement one exact non-mutating runtime without rereading all mission research or duplicating schema semantics.
- **Stop when:** every CLI command, adapter method, state write, planner field, failure state, and negative provider-write criterion maps to code and a focused test.

### Worker Quick-Start

```text
1. The working config is ~/.config/aidevops/team-interface.json by default, overridden only by AIDEVOPS_TEAM_INTERFACE_CONFIG; the committed template is configs/team-interface-config.json.txt.
2. Rich provider/team records stay in dedicated versioned documents. Do not add them to config.jsonc or aidevops-config.schema.json.
3. Trusted adapters are imported only from the in-tree static registry. Config selects registered adapter IDs and settings references; it never supplies executable module paths.
4. AIDEVOPS_STATE_DIR defaults to ~/.aidevops/state. Team-interface state lives below its own 0700 directory and 0600 JSON file.
5. providers, detect, status, doctor, and plan are the complete initial command set. There is no apply or provider-write command.
6. plan consumes an explicit version-1 plan request and emits a reconciliation-v1 plan. IDs, decisions, timestamps, expiry, and SHA-256 plan hash are deterministic functions of the request.
7. State updates use an exclusive bounded lock, expected generation, temporary file, fsync, atomic rename, and stale-lock recovery that never deletes a live owner's lock.
8. Output is JSON by default for machine consumers; diagnostics redact home-directory prefixes and never print secret values or unrestricted provider payloads.
```

### Files to Modify

- NEW: `.agents/scripts/team-interface-helper.sh` — thin agent-callable command wrapper following shared-constants and explicit-return shell conventions.
- NEW: `.agents/scripts/team-interface-core.mjs` — config/schema loading, adapter orchestration, state store, status/doctor, canonical JSON, and deterministic planner implementation.
- NEW: `.agents/scripts/team-interface-adapters.mjs` — static trusted adapter registry with validation and an initially empty built-in set for later Buzz/Matrix leaves.
- NEW: `.agents/schemas/team-interface/runtime-v1.schema.json` — closed runtime config, state, adapter observation, and plan-request documents.
- NEW: `configs/team-interface-config.json.txt` — disabled-by-default valid config template containing only enablement, document paths, adapter IDs, and settings references.
- EDIT: `.agents/reference/team-interfaces.md:6-28,53-65` — link the executable runtime while preserving the provider-neutral ownership and secret boundaries.
- NEW: `.agents/reference/team-interface-runtime.md` — command, adapter, configuration, state, locking, planning, redaction, and failure contracts.
- NEW: `.agents/scripts/tests/test-team-interface-runtime.mjs` — schema, mock-adapter, state/CAS, deterministic plan, CLI, and non-mutation tests.
- NEW: `.agents/scripts/tests/fixtures/team-interface/runtime-valid.json` — valid config, state, observation, and plan-request documents.
- NEW: `.agents/scripts/tests/fixtures/team-interface/runtime-invalid.json` — executable adapter path, secret value, malformed state, stale generation, and unsupported command cases.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/team-interface-helper.sh` calls `.agents/scripts/team-interface-core.mjs`; future Buzz/Matrix adapters, aidevops.app APIs, setup diagnostics, and roster/launch work consume the exported adapter registry, config, state, status, and planner interfaces.
- **Writers/mutation paths:** `.agents/scripts/team-interface-core.mjs` is the only new writer and may atomically update `${AIDEVOPS_STATE_DIR}/team-interface/state-v1.json`; provider adapters expose read-only `detect` and `status` methods and receive no write-capable runtime API.
- **Tests/fixtures:** `.agents/scripts/tests/test-team-interface-runtime.mjs` and the two `runtime-*.json` fixtures cover schema validation, trusted registration, lock/CAS behavior, deterministic output, redaction, unsupported commands, and mock provider mutation traps.
- **Schemas/config:** `.agents/schemas/team-interface/runtime-v1.schema.json` validates runtime documents; `configs/team-interface-config.json.txt` is the committed template and `~/.config/aidevops/team-interface.json` is the default ignored/user-owned working config.
- **Generated/deployed mirrors:** `.agents/scripts/team-interface-*.{sh,mjs}`, schemas, and references deploy through normal `setup.sh`; no generated provider record or `config.jsonc` mirror is written by this task.
- **Migrations/backfills:** No prior team-interface runtime state exists, so `.agents/schemas/team-interface/runtime-v1.schema.json` makes the first valid write generation 1; unknown versions, malformed legacy files, or missing expected generations fail closed and require explicit repair rather than inferred migration.
- **Cleanup/rollback paths:** Reverting `.agents/scripts/team-interface-core.mjs` and its additive runtime surfaces disables the feature; a user may archive `${AIDEVOPS_STATE_DIR}/team-interface` after verifying no active adapter process, while rollback never deletes provider resources, credentials, registries, or user configuration.

### Implementation Steps

1. Define a closed runtime-v1 schema for `runtime_config`, `runtime_state`, `adapter_observation`, and `plan_request`. Reuse core stable/reference IDs and reconciliation capability/precondition/audit definitions by `$ref`; reject secret-value property names, executable module paths, unknown versions, and unknown fields.
2. Add a disabled-by-default config template. Permit only schema version, document type, enablement, registry/policy/app-team document paths, selected registered adapter IDs, settings references, and bounded plan/state options. Do not add rich provider records or credentials.
3. Implement a static adapter registry whose entries require stable adapter/provider IDs, version, declared capabilities, and async `detect(context)` plus `status(context)` functions. Reject duplicates, unknown configured IDs, dynamic paths, missing methods, and mutation-shaped exports.
4. Implement config/document loading with explicit path expansion, schema validation before use, bounded file sizes, actionable sanitized errors, and no logging of file contents. An absent config is a diagnosed disabled state, not permission to infer defaults.
5. Implement state reads/writes below `${AIDEVOPS_STATE_DIR:-$HOME/.aidevops/state}/team-interface`. Validate the complete next document, acquire an exclusive bounded lock, compare expected generation, write a 0600 temporary file, fsync file and directory, atomically rename, then release. Recover a stale lock only when age and process-liveness evidence both prove it abandoned.
6. Implement `providers`, `detect`, `status`, and `doctor`. `detect` calls only trusted read methods, validates observations before state writes, and preserves prior valid state on one adapter failure. `status` and `doctor` do not mutate state.
7. Implement `plan --request PATH`. Derive one field decision per reconciliation input using the exact ownership table, derive outcome from decisions and capability evidence, derive stable IDs from canonical request SHA-256, preserve request-supplied created/expiry and actor/authorization/audit refs, and compute `plan_hash` over canonical JSON with only the hash field omitted.
8. Make the shell helper a thin dependency/argument wrapper with explicit returns in every function. Reject unknown commands including `apply`, `create`, `update`, `delete`, `send`, and `invite` before invoking Node.
9. Add mock-adapter tests proving deterministic ordering, valid state creation, generation conflicts, concurrent lock exclusion, stale-lock safety, partial adapter failure preservation, path/output redaction, identical-plan replay, changed-input hash changes, and zero provider mutation calls.
10. Run the focused runtime and merged contract suites, ShellCheck, syntax checks, and changed-file lint. Create a WIP checkpoint after focused tests before the broader changed-file gate.

### Hazards and Compatibility

- **Concurrency/atomicity:** Multiple readers are safe; writers serialize through one bounded lock and expected generation. Atomic rename prevents truncation, while liveness-plus-age checks prevent stealing a live process lock.
- **Migration/rollback:** Version 1 has no implicit migration. Unknown/malformed config or state is retained and diagnosed; rollback removes executable code without touching provider resources and requires explicit archival of local state.
- **Mixed-version/backward compatibility:** Existing direct aidevops, Matrix, Buzz, OpenCode, and `config.jsonc` behavior remains unchanged. New adapters must declare supported runtime/schema versions, and unsupported combinations report unavailable rather than widening capability.
- **Idempotency/retry:** Identical observations and plan requests produce stable digests/IDs; replay either returns equivalent output or a generation conflict. Adapter errors do not erase prior valid observations or trigger provider retries with side effects.
- **Partial failure/recovery:** Config/schema/lock/adapter/planner failures retain the last valid state and return a sanitized nonzero diagnosis. Resume after fixing the exact failed input; never create a partial registry, infer ownership, or mark missing evidence compatible.

### Verification Before Dispatch

```bash
node .agents/scripts/tests/test-team-interface-runtime.mjs
node .agents/scripts/tests/test-team-interface-core-schema.mjs
node .agents/scripts/tests/test-team-interface-reconciliation-schema.mjs
bash -n .agents/scripts/team-interface-helper.sh
shellcheck .agents/scripts/team-interface-helper.sh
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The runtime test covers config/state/adapter/planner behavior and all negative boundaries; merged schema tests guard contract compatibility; Bash and ShellCheck cover the wrapper; changed-file lint covers JSON, JavaScript, Markdown, licensing, and secrets.
- **Broad verification trigger:** Not required — the task adds isolated runtime surfaces and one reference link without changing setup, global configuration, provider helpers, runtime dispatch, dependencies, or release infrastructure.

### Recoverability Checkpoint

- [ ] Focused tests pass: `node .agents/scripts/tests/test-team-interface-runtime.mjs`
- [ ] WIP commit created before broad gates: `wip: add read-only team-interface runtime core`
- [ ] Evidence-triggered broad verification then run: not required; run `.agents/scripts/linters-local.sh --changed`

### Safety-Stop Recovery

- **Original objective:** Implement a non-mutating provider core with deterministic plans and safe local state.
- **Preserved user directions:** Keep provider neutrality, fail closed, protect secrets/private paths, preserve existing interfaces, and do not enable write-capable Buzz or ACP behavior.
- **Trigger and evidence:** not triggered
- **Completed and verified:** Merged contracts, runtime/config/state precedents, target discovery, and all architecture decisions are captured here.
- **Remaining acceptance criteria:** Implement and verify every declared file, command, state invariant, plan invariant, and negative provider-write guarantee.
- **Unsafe route not to repeat:** Do not dynamically import config-supplied code, store secret values, add provider mutation commands, steal live locks, or infer valid state from malformed files.
- **Next safe route:** Preserve the last valid state and resume the exact config, adapter, lock, or plan step after bounded diagnostics identify the cause.
- **Resume condition:** No overlapping target PR exists and the merged core/reconciliation schemas still match the verified references.
- **Owner and status:** Assigned implementation worker; not-triggered.

### Files Scope

- `.agents/scripts/team-interface-helper.sh`
- `.agents/scripts/team-interface-core.mjs`
- `.agents/scripts/team-interface-adapters.mjs`
- `.agents/schemas/team-interface/runtime-v1.schema.json`
- `configs/team-interface-config.json.txt`
- `.agents/reference/team-interfaces.md`
- `.agents/reference/team-interface-runtime.md`
- `.agents/scripts/tests/test-team-interface-runtime.mjs`
- `.agents/scripts/tests/fixtures/team-interface/runtime-valid.json`
- `.agents/scripts/tests/fixtures/team-interface/runtime-invalid.json`

## Acceptance Criteria

- [ ] A valid disabled or enabled runtime config, trusted mock adapter observation, local state generation, and reconciliation plan all validate and produce stable machine-readable output.

  ```yaml
  verify:
    method: bash
    run: "node .agents/scripts/tests/test-team-interface-runtime.mjs"
  ```

- [ ] Repeating one plan request byte-for-byte produces the same IDs, decisions, timestamps, and plan hash; changing a decision input changes the hash without order-dependent output.

  ```yaml
  verify:
    method: codebase
    pattern: "deterministic|canonical|plan_hash|idempotency"
    path: ".agents/scripts/tests/test-team-interface-runtime.mjs"
  ```

- [ ] Concurrent or stale-generation state writes never overwrite newer state, and stale-lock recovery must not remove a lock whose owner is still live.

  ```yaml
  verify:
    method: codebase
    pattern: "generation|lock|live|stale|atomic"
    path: ".agents/scripts/tests/test-team-interface-runtime.mjs"
  ```

- [ ] Unknown adapters, executable config paths, secret values, malformed documents, unsupported commands, and provider mutation methods are rejected without changing prior valid state.

  ```yaml
  verify:
    method: codebase
    pattern: "unknown.*adapter|executable|secret|unsupported.*command|mutation|prior.*state"
    path: ".agents/scripts/tests/test-team-interface-runtime.mjs"
  ```

- [ ] Existing `config.jsonc`, aidevops configuration schema, Buzz helper, Matrix helper, OpenCode launcher, and runtime dispatch paths remain unchanged.

  ```yaml
  verify:
    method: bash
    run: "git diff --exit-code origin/main -- .agents/configs/aidevops-config.schema.json .agents/scripts/buzz-desktop-helper.sh .agents/scripts/matrix-dispatch-helper.sh .agents/scripts/opencode-launcher-helper.sh .agents/scripts/headless-runtime-helper.sh"
  ```

- [ ] Shell, Node, JSON, Markdown, license, and secret quality gates pass.

  ```yaml
  verify:
    method: bash
    run: "bash -n .agents/scripts/team-interface-helper.sh && shellcheck .agents/scripts/team-interface-helper.sh && .agents/scripts/linters-local.sh --changed"
  ```

## Context & Decisions

- The dedicated config path resolves the mission's configuration decision: `config.jsonc` may gain a later enablement/path pointer, but rich provider/team state stays in versioned documents.
- The runtime uses Node because the repository already supplies Ajv 2020 and the merged contract tests use it; a thin shell wrapper preserves the framework's agent-callable helper convention.
- Adapters are statically registered in tracked code. User config selects stable IDs and settings references but cannot execute arbitrary modules.
- Provider read-only does not mean filesystem read-only: validated local observations may be stored, but provider systems are never mutated.
- F2.1 implements the merged reconciliation algorithm rather than inventing a parallel plan shape.

## Relevant Files

- `.agents/reference/team-interfaces.md:6-28,43-65` — provider-neutral ownership, config, capability, event, and secret boundaries.
- `.agents/schemas/team-interface/core-v1.schema.json:10-180,282-313` — stable IDs, provider registry, resources, and normalized events.
- `.agents/reference/team-interface-reconciliation.md:49-118` — exact decisions, capability fallback, canonical hash, CAS, and retry behavior.
- `.agents/schemas/team-interface/reconciliation-v1.schema.json:189-430` — reconciliation input, field decisions, capability evidence, and plan document.
- `.agents/scripts/tests/test-team-interface-reconciliation-schema.mjs:26-99` — Ajv composition and semantic fixture pattern.
- `.agents/aidevops/architecture.md:21-36,135-149` — helper/config/runtime and shell initialization conventions.
- `.agents/scripts/lib/discovery_utils.py:16-33` — atomic JSON write precedent.
- `todo/missions/m-20260804-5d06b1/research/source-review.md:394-438` — proposed first commands, surfaces, verification families, and non-mutating recommendation.

## Dependencies

- **Blocked by:** none — F1.1 core contracts and F1.4 reconciliation contracts merged through #29505 and #29528.
- **Blocks:** F2.3 read-only Buzz adapter, F2.4 Matrix normalization, F3.2 setup flows, F5.1 app-team instantiation, and F6.4 release announcements.
- **External:** Node and repository-pinned Ajv are already present. No provider account, credential, network mutation, package installation, or live Buzz/Matrix instance is required.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Contract/source read | 45m | Reconfirm schema fields, config/state patterns, and adapter boundaries |
| Runtime schema/config/registry | 1h 15m | Closed documents, trusted registry, and template |
| State store and planner | 2h | Lock/CAS, atomic writes, canonical decisions and hash |
| CLI/status/doctor | 45m | Thin wrapper, diagnostics, redaction, failures |
| Fixtures and focused tests | 1h | Positive, concurrency, deterministic, and mutation-negative cases |
| Documentation and gates | 15m | Runtime reference, core link, ShellCheck, changed lint |
| **Total** | **6h** | |
