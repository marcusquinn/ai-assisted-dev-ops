---
mode: subagent
---

<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18205: Implement the read-only Buzz team-interface adapter

## Pre-flight

- [x] Memory recall: `Feature 2.3 Buzz adapter provider-neutral runtime schema` → 0 hits — no reusable stored lesson found.
- [x] Discovery pass: one merged runtime-core commit/PR touches the target runtime surfaces, no open related PR exists, and the merged work deliberately leaves the built-in registry empty for this leaf.
- [x] File refs verified: 18 current aidevops runtime/schema/test/reference, Buzz source/store/type, mission, and task-publication references checked against current heads.
- [x] Tier: `tier:standard` — the inventory shape, trusted registry path, supported platform/version boundary, source projection, failure behavior, and verification contract are resolved below; implementation retains bounded I/O and fixture judgment.
- [x] Seeded draft PR decision recorded: skipped — a partial adapter without the closed inventory schema, secret-negative fixtures, and runtime semantic checks would anchor implementation to an unsafe shape.

## Origin

- **Created:** 2026-08-06
- **Session:** OpenCode interactive mission `m-20260804-5d06b1`
- **Created by:** ai-interactive under maintainer direction
- **Parent task:** t18201
- **Blocked by:** none — F2.1 / t18202 merged through PR #29619
- **Conversation context:** The read-only runtime contract is merged and the current Buzz `0.5.5` installation, source types, data stores, and unsupported external-runtime seams were refreshed. Feature 2.3 can now add the first real trusted adapter without guessing a provider write API.

## What

Add a statically registered `adapter.buzz` implementation that detects a
verified local Buzz Desktop installation and returns closed, deterministic,
read-only inventories for communities, managed agents/definitions, teams, and
referenced ACP runtimes. Extend runtime observations with one optional
provider-neutral inventory object and enforce unique, canonical, internally
referential inventory records before local state may be persisted.

The first supported reader is the verified macOS Buzz Desktop `0.5.5` layout.
It reads only application metadata, bounded local stores, read-only WebKit
SQLite, and process-liveness evidence. It never starts Buzz/ACP, probes auth,
installs software, resolves credentials, writes provider data, or exposes raw
provider records and private fields.

## Why

F2.1 has a safe runtime but no real provider adapter. Without a normalized Buzz
inventory, later setup, app-team, Matrix, compatibility, and owner-reviewed
reconciliation leaves cannot reason about actual local provider state. Reading
Buzz records directly without a closed projection would leak keys, auth tags,
environment values, prompts, local paths, and diagnostics; invoking Buzz's
internal runtime discovery would also run auth probes and unsupported side
effects. This leaf establishes the narrow observable boundary first.

## Tier

**Selected tier:** `tier:standard`

**Tier rationale:** The trust and compatibility boundaries are decided and
reversible, while safe bounded filesystem/SQLite reads, normalization, and
cross-reference tests require ordinary multi-file implementation judgment.

## PR Conventions

This is a leaf child of parent t18201. The implementation PR uses a closing
keyword for this issue and `For #29541` for the parent. It must not close the
Milestone 2 parent or implement Matrix, OpenCode overlays, Buzz provisioning,
provider writes, release, or deployment.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The complete schema, adapter, security projection, fixtures, and semantic runtime validation should land and be reviewed together.
- **Status:** `not-created`
- **Freshness evidence:** Discovery and file references were refreshed against aidevops `8fbcfb54a`, Buzz `e2796d4a`, and installed Buzz Desktop `0.5.5` on 2026-08-06.
- **Verification run:** Existing runtime tests were green in merged PR #29619; new Buzz tests are unrun before implementation.
- **Stale-assumption warning:** Recheck the runtime registry/schema and Buzz source symbols if either target advances before coding; unknown provider versions remain unknown rather than silently compatible.

## How (Approach)

### Progressive Context Plan

- **Read first:** this brief's Worker Quick-Start, `.agents/scripts/team-interface-adapter-runtime.mjs:7-82`, and `.agents/schemas/team-interface/runtime-v1.schema.json:89-166` — these define the read context, timeout, binding, observation, and state boundary.
- **Then load:** `.agents/scripts/team-interface-adapters.mjs:4-59` and `.agents/scripts/tests/test-team-interface-runtime.mjs:293-379,478-687` only while wiring static registration and semantic-negative tests.
- **Load only if:** provider fields are unclear — the refreshed source evidence in `todo/missions/m-20260804-5d06b1/research/source-review.md` and the exact Buzz type paths listed under Relevant Files.
- **Why:** implement one narrow adapter without importing the whole Buzz application, copying private record shapes, or widening the core provider contract.
- **Stop when:** every data source, projected field, capability state, stable ID/ref, failure mode, cancellation path, and negative write/secret guarantee maps to a focused assertion.

### Worker Quick-Start

```text
1. Register exactly adapter.buzz/provider buzz from one tracked module; config still selects only adapter IDs plus opaque settings: refs.
2. Add optional adapter_observation.inventory with required closed arrays: communities, agents, teams, runtimes. Existing observations without inventory stay valid.
3. Stable inventory IDs are deterministic hashes/prefixes of provider external identity; display labels never authorize identity or adoption.
4. The macOS defaults are /Applications/Buzz.app, the xyz.block.buzz.app application-data directory, and its WebKit WebsiteData root. Test seams may inject fixture roots; production config does not accept executable paths.
5. Read Info.plist without launching Buzz. Snapshot validated WebKit database/WAL/SHM descriptors into a private aidevops temporary directory, query only the constant buzz-communities key through sqlite3 read-only mode, clean the snapshot, and pass the runtime abort signal to child/file I/O.
6. Parse full records but emit only allowlisted IDs, labels, relationships, built-in/kind markers, and availability. Never emit token, nsec/private key, auth tag, env, prompt, model/provider, command/args/path, PID, error, log, instructions, source directory, repo root, or settings_ref.
7. Observe only runtime IDs referenced by managed-agent records. Do not call Buzz/Tauri/ACP discovery because current discovery runs auth probes and has no supported external read API.
8. Buzz 0.5.5 is compatible at this baseline; other detected versions are compatibility unknown. Non-macOS remains unavailable until verified package/data evidence exists.
9. Malformed, oversized, replaced, symlinked, unowned, or insecure existing stores degrade/fail the affected capability with sanitized diagnostics and never become an empty-success observation.
10. The adapter exposes detect/status only. Tests install mutation traps and secret canaries and assert zero provider writes/process launches.
```

### Files to Modify

- NEW: `.agents/scripts/team-interface-buzz-adapter.mjs` — static adapter definition, capability/compatibility mapping, observation assembly, and injectable test seams.
- NEW: `.agents/scripts/team-interface-buzz-command.mjs` — bounded no-shell child execution with optional inherited source descriptors.
- NEW: `.agents/scripts/team-interface-buzz-path.mjs` — full component device/inode capture and replacement detection for source and snapshot paths.
- NEW: `.agents/scripts/team-interface-buzz-source.mjs` — bounded plist, JSON, and read-only WebKit SQLite source readers.
- NEW: `.agents/scripts/team-interface-buzz-safe-read.mjs` — non-symlink descriptor validation, ownership/mode checks, bounded reads, and cancellation.
- NEW: `.agents/scripts/team-interface-buzz-snapshot.mjs` — bounded private copies of validated SQLite database/WAL/SHM descriptors and guaranteed cleanup.
- NEW: `.agents/scripts/team-interface-buzz-inventory.mjs` — strict allowlisted projection, stable identities, canonical ordering, and relationship normalization.
- EDIT: `.agents/scripts/team-interface-adapters.mjs:4-59` — import and register the frozen built-in Buzz adapter.
- EDIT: `.agents/scripts/team-interface-adapter-runtime.mjs:15-53,72-82` — validate inventory uniqueness, canonical ordering, and internal references after schema validation.
- EDIT: `.agents/scripts/team-interface-diagnostics.mjs:7-14` — retain fixed runtime-owned categories for non-canonical and dangling inventory failures.
- EDIT: `.agents/schemas/team-interface/runtime-v1.schema.json:89-166` — add optional closed provider-neutral community/agent/team/runtime inventory definitions.
- NEW: `.agents/scripts/tests/test-team-interface-buzz-adapter.mjs` — installation, projection, ordering, cancellation, malformed input, unsupported platform/version, and no-side-effect tests.
- NEW: `.agents/scripts/tests/fixtures/team-interface/buzz-managed-agents.json` — synthetic records containing safe identities plus secret/path/error canaries that must never escape.
- NEW: `.agents/scripts/tests/fixtures/team-interface/buzz-teams.json` — synthetic built-in/custom team relationships and private-field canaries.
- EDIT: `.agents/scripts/tests/test-team-interface-runtime.mjs:143-177,293-379,478-517` — generic inventory schema/binding negatives and built-in registry assertions.
- EDIT: `.agents/reference/team-interface-runtime.md:6-12,63-91,159-182` — replace the empty-registry statement and document provider-neutral inventory validation plus Buzz reference.
- NEW: `.agents/reference/team-interface-buzz.md` — supported baseline, paths, mappings, redaction, capability degradation, rollback, and verification.
- EDIT: `todo/missions/m-20260804-5d06b1/mission.md:167-179,336-357` — bind F2.3 task/status/estimate and completion evidence.
- EDIT: `todo/missions/m-20260804-5d06b1/research/source-review.md:394-451` — preserve the refreshed upstream baseline and decided adapter boundary.
- EDIT: `TODO.md` and NEW `todo/tasks/t18205-brief.md` — durable task identity and worker-ready implementation contract.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/team-interface-runtime-commands.mjs` selects the built-in registry and invokes Buzz through the existing adapter runtime; setup/user callers continue through `.agents/scripts/team-interface-helper.sh`; later setup/UI/reconciliation leaves consume only normalized observations.
- **Writers/mutation paths:** Buzz readers never write provider data. The SQLite reader creates mode-0600 files in a random mode-0700 directory below the private aidevops temporary root, queries that snapshot read-only, and removes it in `finally`. Existing `detect` remains the sole durable writer and may persist only the schema-valid normalized observation to `${AIDEVOPS_STATE_DIR}/team-interface/state-v1.json`; `status` performs no durable mutation.
- **Tests/fixtures:** `.agents/scripts/tests/test-team-interface-buzz-adapter.mjs` owns source projection and side-effect negatives using the synthetic `.agents/scripts/tests/fixtures/team-interface/buzz-managed-agents.json` and `buzz-teams.json` fixtures; `.agents/scripts/tests/test-team-interface-runtime.mjs` owns schema, binding, timeout, prior-state, and CLI behavior; fixtures contain no real user/provider values.
- **Schemas/config:** runtime-v1 gains only an optional closed `inventory`; `configs/team-interface-config.json.txt`, global `config.jsonc`, and the aidevops config schema remain unchanged and disabled by default.
- **Generated/deployed mirrors:** tracked `.agents/scripts/team-interface-*.mjs`, schemas, fixtures, and references deploy through the normal atomic agents bundle. No generated provider record, static roster copy, or application-data mirror is created.
- **Migrations/backfills:** N/A because `.agents/schemas/team-interface/runtime-v1.schema.json` keeps inventory optional, so existing observations remain valid without migration. The first selected Buzz detect writes an additive inventory observation; no provider store is migrated or adopted. Rolling back to the pre-F2.3 validator may require explicit archival of local team-interface state before use.
- **Cleanup/rollback paths:** remove/disable the `adapter.buzz` selection and run detect to clear its selected observation, or revert the static registry/module/schema together. Never delete or rewrite Buzz application data, WebKit storage, keys, teams, agents, or runtimes as cleanup.

### Implementation Steps

1. Extend runtime-v1 with closed inventory records for communities, agents, teams, and runtimes. Reuse core stable/external ID and availability concepts; bound every array/string; make inventory optional for old observations but require all four arrays when present.
2. Add semantic validation after Ajv: category IDs and member refs are unique, arrays use locale-independent canonical ID order, agent community/runtime/team refs resolve when supplied, and every team member ref resolves to an observed agent. Reject, do not sort, untrusted adapter output.
3. Implement `createBuzzAdapter(dependencies)` plus the default `buzzAdapter`. Keep the returned definition limited to the six allowed adapter properties and use dependency injection only as a test seam, never config-supplied executable loading.
4. Resolve verified macOS paths from the current home directory. Open bounded regular files without following symlinks, capture and revalidate every path component's device/inode around descriptor/directory use, check ownership/permissions appropriate to each source, pass cancellation through reads, and sanitize every thrown error at the runtime boundary.
5. Read the app version from `Info.plist` without executing Buzz. Copy validated WebKit database and present WAL/SHM descriptors into a bounded private temporary snapshot, query it read-only with a constant statement, decode UTF-8/UTF-16LE values, and clean it on every exit. Bound directory traversal, combined snapshot bytes, database output, records, and file sizes.
6. Normalize projected records with deterministic IDs/order and references. Derive agent availability from active/stored process evidence without emitting PID/errors; derive runtime inventory only from referenced runtime IDs; use actual agent `team_id` relationships rather than treating persona IDs as deployed instances.
7. Build complete fixed capability declarations for installation, communities, agents, teams, and runtimes. Observation availability may degrade per source, but operations/resource kinds/review policy remain exactly bound to the registered definition.
8. Return unavailable/empty inventory on unsupported platforms or absent installation; return compatibility unknown for versions other than `0.5.5`; fail/degrade safely for an existing malformed or unsafe source instead of masking it as zero records.
9. Add fixture tests for definitions and instances, relay/community matching, teams, unique/canonical IDs, process states, absent stores, malformed/oversized/symlinked files, abort propagation, unknown versions/platforms, and secret/path/error canary exclusion.
10. Add runtime semantic negatives, update references/mission evidence, then run focused suites and changed-file quality gates. Create a WIP checkpoint after focused tests before independent exact-head review.

### Hazards and Compatibility

- **Concurrency/atomicity:** Buzz may update JSON or SQLite while read. Readers open one descriptor, bound bytes, revalidate every path component plus descriptor identity, and treat replacement/parse races as degraded. SQLite copies the validated database and present WAL/SHM descriptors into a component-bound private snapshot before `sqlite3 -readonly` consumes its relative database name, so provider/parent path swaps cannot select query content and no provider checkpoint or journal write occurs. Cleanup unlinks only known snapshot files after identity revalidation and never recursively follows a replacement path.
- **Migration/rollback:** The schema extension is optional for existing state and performs no provider migration. A pre-F2.3 runtime does not understand inventory, so downgrade instructions explicitly archive local runtime state after disabling the adapter; Buzz data remains untouched.
- **Mixed-version/backward compatibility:** Only current `0.5.5` is known compatible. Unknown versions retain detected identity/inventory where safely parseable but never inherit compatibility. Non-macOS reports unavailable rather than guessing package paths.
- **Idempotency/retry:** Stable IDs/order derive from provider identity, never display labels. Repeated reads of unchanged source produce equivalent inventory apart from observation time; retries execute only bounded reads and cannot create provider effects.
- **Partial failure/recovery:** A malformed existing source degrades its capability and emits no records from that source; unrelated safe inventories may remain visible. Abort/timeouts stop pending file/subprocess work. Fix the source or disable the adapter, preserving the last valid persisted observation under existing runtime rules.

### Verification Before Dispatch

```bash
node .agents/scripts/tests/test-team-interface-buzz-adapter.mjs
node .agents/scripts/tests/test-team-interface-runtime.mjs
node .agents/scripts/tests/test-team-interface-core-schema.mjs
node --check .agents/scripts/team-interface-buzz-adapter.mjs
node --check .agents/scripts/team-interface-buzz-command.mjs
node --check .agents/scripts/team-interface-buzz-path.mjs
node --check .agents/scripts/team-interface-buzz-source.mjs
node --check .agents/scripts/team-interface-buzz-safe-read.mjs
node --check .agents/scripts/team-interface-buzz-snapshot.mjs
node --check .agents/scripts/team-interface-buzz-inventory.mjs
.agents/scripts/tests/test-team-interface-runtime-deps.sh
.agents/scripts/qlty-new-file-gate-helper.sh new-files --base origin/main --head HEAD
.agents/scripts/qlty-regression-helper.sh --base origin/main --head HEAD
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** The Buzz suite proves source projection, compatibility, ordering, cancellation, degradation, and zero effects; the runtime suite proves closed schema and semantic binding; core-schema protects composed refs; dependency deployment compiles the changed runtime schema; syntax/lint cover JavaScript, JSON, Markdown, licensing, and secrets.
- **Broad verification trigger:** Full application E2E is not required because the adapter is disabled unless explicitly selected and does not alter setup/global config/dependencies/provider helpers. Mandatory Qlty new-file/regression ratchets and focused runtime/deployment suites cover the changed source and shared contract.

### Recoverability Checkpoint

- [x] Focused tests pass: `node .agents/scripts/tests/test-team-interface-buzz-adapter.mjs && node .agents/scripts/tests/test-team-interface-runtime.mjs`
- [x] WIP commit created before broad gates: `wip: add read-only Buzz team-interface adapter` is present in the current branch history.
- [x] Quality verification run: the first new-file scan identified three complexity smells; the adapter was split into bounded static modules, then successive Qlty findings were repaired until the new-file gate passed at 0 smells. Qlty regression passed at delta 0, and runtime dependency/changed-file gates passed.

### Safety-Stop Recovery

- **Original objective:** Implement read-only Buzz installation/runtime, community, agent, team, and capability observation through the provider-neutral runtime.
- **Preserved user directions:** Keep the adapter trusted, static, non-mutating, cancellation-aware, deterministic, credential-safe, and limited to Feature 2.3; continue through the no-release full loop.
- **Trigger and evidence:** not triggered
- **Completed and verified:** F2.1 dependency, current runtime contract, Buzz `0.5.5` source/install/store evidence, collision checks, task allocation, every declared schema/module/test/reference surface, and focused/dependency/Qlty/changed-file gates.
- **Remaining acceptance criteria:** Obtain independent exact-head review, merge the leaf PR, record no release, and clean session worktrees.
- **Unsafe route not to repeat:** Do not execute Buzz Desktop for version discovery, run Buzz/Tauri/ACP auth/runtime discovery, use cargo metadata that installs a toolchain, expose live stores, or treat malformed data as empty success.
- **Next safe route:** Narrow to synthetic fixtures and verified read-only metadata; preserve prior runtime state and resume only the failing source reader or contract check.
- **Resume condition:** Current runtime/Buzz symbols still match the brief and no overlapping adapter PR appears.
- **Owner and status:** Interactive mission session; not-triggered.

### Files Scope

- `TODO.md`
- `todo/tasks/t18205-brief.md`
- `todo/missions/m-20260804-5d06b1/mission.md`
- `todo/missions/m-20260804-5d06b1/research/source-review.md`
- `.agents/scripts/team-interface-buzz-adapter.mjs`
- `.agents/scripts/team-interface-buzz-command.mjs`
- `.agents/scripts/team-interface-buzz-path.mjs`
- `.agents/scripts/team-interface-buzz-source.mjs`
- `.agents/scripts/team-interface-buzz-safe-read.mjs`
- `.agents/scripts/team-interface-buzz-snapshot.mjs`
- `.agents/scripts/team-interface-buzz-inventory.mjs`
- `.agents/scripts/team-interface-adapters.mjs`
- `.agents/scripts/team-interface-adapter-runtime.mjs`
- `.agents/scripts/team-interface-diagnostics.mjs`
- `.agents/schemas/team-interface/runtime-v1.schema.json`
- `.agents/scripts/tests/test-team-interface-buzz-adapter.mjs`
- `.agents/scripts/tests/test-team-interface-runtime.mjs`
- `.agents/scripts/tests/fixtures/team-interface/buzz-managed-agents.json`
- `.agents/scripts/tests/fixtures/team-interface/buzz-teams.json`
- `.agents/reference/team-interface-runtime.md`
- `.agents/reference/team-interface-buzz.md`

## Acceptance Criteria

- [x] Selecting `adapter.buzz` on a supported synthetic `0.5.5` installation returns one schema-valid observation with deterministic community, agent, team, runtime, and capability identities.

  ```yaml
  verify:
    method: bash
    run: "node .agents/scripts/tests/test-team-interface-buzz-adapter.mjs && node .agents/scripts/tests/test-team-interface-runtime.mjs"
  ```

- [x] Secret/path/error canaries present in synthetic Buzz records never appear in the observation or diagnostics, and no Buzz/ACP/package/auth/provider mutation process is called.

  ```yaml
  verify:
    method: codebase
    pattern: "secret|private|auth|env|prompt|path|mutation|spawn|canary"
    path: ".agents/scripts/tests/test-team-interface-buzz-adapter.mjs"
  ```

- [x] Missing installation/stores, unsupported platforms, unknown versions, unsafe files, malformed JSON/SQLite, dangling refs, duplicate IDs, and adapter timeouts fail or degrade closed without changing Buzz data or corrupting prior runtime state.

  ```yaml
  verify:
    method: codebase
    pattern: "missing|unsupported|unknown|symlink|malformed|dangling|duplicate|abort|prior"
    path: ".agents/scripts/tests/test-team-interface-buzz-adapter.mjs"
  ```

- [x] Existing mock observations without inventory and all F2.1 commands/state/planner behavior remain valid.

  ```yaml
  verify:
    method: bash
    run: "node .agents/scripts/tests/test-team-interface-runtime.mjs && node .agents/scripts/tests/test-team-interface-core-schema.mjs"
  ```

- [x] Existing global config, Buzz compatibility helper, Matrix helper, OpenCode launcher, headless runtime, and provider stores remain unchanged.

  ```yaml
  verify:
    method: bash
    run: "git diff --exit-code origin/main -- .agents/configs/aidevops-config.schema.json configs/team-interface-config.json.txt .agents/scripts/buzz-desktop-helper.sh .agents/scripts/matrix-dispatch-helper.sh .agents/scripts/opencode-launcher-helper.sh .agents/scripts/headless-runtime-helper.sh"
  ```

- [x] JavaScript, JSON Schema, Markdown, deployment dependency, license, secret, Qlty new-file/regression, and changed-file quality gates pass.

  ```yaml
  verify:
    method: bash
    run: "node --check .agents/scripts/team-interface-buzz-adapter.mjs && node --check .agents/scripts/team-interface-buzz-command.mjs && node --check .agents/scripts/team-interface-buzz-path.mjs && node --check .agents/scripts/team-interface-buzz-source.mjs && node --check .agents/scripts/team-interface-buzz-safe-read.mjs && node --check .agents/scripts/team-interface-buzz-snapshot.mjs && node --check .agents/scripts/team-interface-buzz-inventory.mjs && .agents/scripts/tests/test-team-interface-runtime-deps.sh && .agents/scripts/qlty-new-file-gate-helper.sh new-files --base origin/main --head HEAD && .agents/scripts/qlty-regression-helper.sh --base origin/main --head HEAD && .agents/scripts/linters-local.sh --changed"
  ```

## Context & Decisions

- Provider-neutral observation inventories belong in runtime-v1, not the core desired registry: observations may be incomplete/degraded and must not imply verified identity, credentials, management ownership, or reconciliation authority.
- The inventory extension is optional for backward compatibility; when present it is complete and closed across four arrays with semantic reference validation.
- Community relay URLs and agent pubkeys are used only to derive/match stable identities. The normalized surface minimizes provider detail and excludes invite/auth/private/workspace data.
- Runtime inventory describes runtime IDs already referenced by managed-agent records. Calling Buzz's internal runtime catalog is ruled out because it performs auth probes and has no reviewed external read contract.
- The existing `buzz-desktop-helper.sh` is write-capable compatibility tooling and is intentionally neither imported nor invoked by this adapter.
- No live provider store values enter fixtures, durable state, issue text, logs,
  or public review evidence. A validated SQLite database/WAL/SHM copy exists only
  inside a private temporary directory for the read-only query and is removed
  on every normal error, abort, and success path.

## Relevant Files

- `.agents/scripts/team-interface-adapters.mjs:4-59` — sole trusted static registry and selection path.
- `.agents/scripts/team-interface-adapter-runtime.mjs:7-82` — frozen read context, timeout/abort, schema validation, and binding checks.
- `.agents/schemas/team-interface/runtime-v1.schema.json:89-166` — closed capability, observation, and persisted-state contract.
- `.agents/scripts/tests/test-team-interface-runtime.mjs:293-379,478-687` — adapter trust, timeout, binding, partial-failure, and prior-state patterns.
- `.agents/reference/team-interface-runtime.md:63-122,159-182` — adapter/state/diagnostic/deployment contract.
- `.agents/scripts/buzz-desktop-helper.sh:13-18,50-107,110-137` — verified macOS version/store and private-file precedents; do not reuse its mutation paths.
- `todo/missions/m-20260804-5d06b1/research/source-review.md:394-449` — refreshed source baseline and F2.3 boundary.
- Buzz `desktop/src-tauri/src/managed_agents/types.rs:212-440,493-569,629-674,761-786` — record, summary, runtime-catalog, and team fields.
- Buzz `desktop/src-tauri/src/managed_agents/storage.rs:35-47,237-276` — app-data store path and instance/definition split.
- Buzz `desktop/src-tauri/src/managed_agents/teams.rs:12-24,154-206` — team path, sort, read-only load, and write-on-normal-load distinction.
- Buzz `desktop/src/features/communities/communityStorage.ts:5-86` and `types.ts:1-27` — local-storage key, migration, and secret/private community fields.
- Buzz `desktop/src-tauri/src/commands/legacy_storage.rs:48-149` — WebKit database discovery, read-only SQLite query, and UTF-8/UTF-16LE decoding precedent.
- Buzz `desktop/src-tauri/src/managed_agents/discovery.rs:1422-1589` — internal runtime discovery and auth-probe behavior that the adapter must not invoke.

## Dependencies

- **Blocked by:** none — F2.1 merged through PR #29619; current Buzz source/install evidence is available without credentials.
- **Blocks:** F4.5 owner-reviewed Buzz onboarding, F6.6 project-scoped Buzz channels, F7.1/F7.2 compatibility monitoring, and provider-aware setup/status UI work.
- **External:** Node 20-compatible APIs, macOS `plutil`/`sqlite3`, and synthetic fixtures. No provider account, key, token, package installation, network write, Buzz process launch, release, or deployment is required.

## Estimate Breakdown

| Phase | Time | Notes |
|---|---:|---|
| Schema/runtime semantics | 45m | Closed inventory records, unique/order/ref checks, compatibility |
| Safe Buzz readers/normalization | 2h | plist, bounded JSON, read-only WebKit SQLite, projection, IDs/capabilities |
| Fixtures and focused tests | 1h 15m | positive, malformed, cancellation, secret and no-effect cases |
| References/mission and gates | 1h | docs, WIP checkpoint, lint/Qlty, independent review, PR evidence |
| **Total** | **5h** | |
