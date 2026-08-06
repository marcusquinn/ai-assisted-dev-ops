<!-- aidevops:brief-schema=v2 -->

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# t18207: Refactor Matrix behind the team-interface contracts

## Pre-flight

- [x] Memory recall: `mission Matrix adapter provider event authority room session runner` → 0 hits — no reusable stored lesson found.
- [x] Discovery pass: merged runtime PR #29619 and Buzz adapter PR #29636 provide the current static adapter pattern; no open issue or PR implements the Matrix team-interface leaf.
- [x] File refs verified: 27 runtime, schema, Matrix setup/bot/session, entity, reference, test, mission, and source-review references checked at `52773f5a9`.
- [x] Tier: `tier:thinking` — the leaf crosses conversational authority, idempotency, privacy, generated runtime, and compatibility boundaries; the brief resolves the intended architecture and non-goals below.
- [x] Seeded draft PR decision recorded: skipped — an adapter-only seed would omit normalized ingress and privacy/idempotency characterization, while a bot-only seed would bypass the provider contract.

## Origin

- **Created:** 2026-08-06
- **Session:** OpenCode interactive mission `m-20260804-5d06b1`
- **Created by:** ai-interactive under maintainer direction
- **Parent task:** t18201 / #29541
- **Blocked by:** none — F2.1 / t18202 merged through PR #29619
- **Conversation context:** The provider-neutral runtime and first static Buzz adapter are merged. Current Matrix setup, mapping, session/entity, runner fallback, and generated bot behavior were re-read before deciding the read-only observation and normalized-ingress boundary.

## What

Register a trusted static `adapter.matrix` that observes the existing local Matrix
configuration/runtime without resolving or emitting its access token, contacting
the homeserver, installing dependencies, or invoking provider/admin writes.
Refactor accepted Matrix text events through one pure provider-neutral
normalizer that emits the closed core-v1 event, actor, lineage, target,
correlation, idempotency, trust, and compatibility-authority evidence before the
existing runner dispatch path executes.

Preserve the documented setup/start/stop/status/map/unmap/session, prefix,
allowlist, runner selection/fallback, invite, reaction, response, compaction, and
Layer 0 behavior. Add characterization and security regressions for room/person
isolation and event redelivery; repair behavior that contradicts the documented
privacy boundary without deleting immutable interaction history.

## Why

Matrix currently has a mature integration but bypasses the new provider/event/
authority contracts. It relies on display-adjacent sender input, process-local
concurrency, one mutable entity per room, and entity-wide Matrix history. Without
normalization and stable evidence, later restricted OpenCode launch, delegated
work, trust policy, and app control-plane features would need Matrix-specific
authority and identity logic or could duplicate/leak conversational work.

## Tier

**Selected tier:** `tier:thinking`

**Tier rationale:** The brief fixes the trust boundary and compatibility policy,
but implementation still coordinates static observation, generated bot code,
SQLite/entity state, and exact behavior-preservation tests across stateful paths.

## PR Conventions

This is a leaf child. Its PR uses a closing keyword for the F2.4 issue and
`For #29541` for the parent. It must not close the parent or implement Matrix
provisioning, generic delegated-work authority, OpenCode overlays, or release.

## Seeded Draft PR

- **Decision:** Skipped
- **Rationale:** The static adapter, normalizer, generated-runtime integration, state repair, docs, and security tests need one coherent review bundle.
- **Status:** `not-created`
- **Freshness evidence:** Existing Matrix scripts/templates/docs, merged runtime/Buzz patterns, mission source review, and exact GitHub collision searches were refreshed on 2026-08-06.
- **Verification run:** Existing files were read; no Matrix-specific team-interface test exists yet.
- **Stale-assumption warning:** Re-run discovery if Matrix templates, entity-helper contracts, runtime inventory, or adapter registry change before coding.

## How (Approach)

### Progressive Context Plan

- **Read first:** `.agents/scripts/team-interface-buzz-adapter.mjs`, `.agents/scripts/team-interface-adapter-runtime.mjs`, and `.agents/scripts/matrix-bot.mjs.template:362-527`.
- **Then load:** `.agents/scripts/matrix-session-store.mjs.template:198-385`, `.agents/schemas/team-interface/core-v1.schema.json:182-313`, and the current config writer in `.agents/scripts/matrix-dispatch-setup.sh`.
- **Load only if:** setup/API compatibility is unclear — Matrix helper submodules and `.agents/services/communications/matrix-bot.md`.
- **Why:** keep the provider observation and pure ingress seam narrow while preserving existing operational behavior.
- **Stop when:** every accepted/ignored event, stable ID, configured policy decision, source field, dispatch dedupe, room/entity state, provider effect, and regression maps to a focused assertion.

### Worker Quick-Start

1. Register exactly `adapter.matrix` / provider `matrix` with immutable detect/status capabilities and no mutation method.
2. Read only the existing `matrix-bot.json` and local process/session metadata through bounded, descriptor-safe, owner/mode-checked paths. Never emit token, host path, raw room/user ID, errors, prompts, responses, or provider payloads.
3. Report homeserver/community and configured runner/runtime identities as deterministic hashes; compatibility remains unknown without a separately authorized authenticated versions probe.
4. Normalize only accepted `m.text` events after own-message, prefix, allowlist, and runner mapping checks. Ignored events produce no envelope and no new side effect.
5. Stable event, actor, community, conversation, correlation, and idempotency IDs derive from provider IDs, never display names. Configured legacy policy produces explicit compatibility authority/trust references but grants nothing beyond current dispatch.
6. Persist/check provider event idempotency at the existing session boundary so restart/redelivery cannot dispatch the same event twice.
7. Bind recent context and session entity state to room plus current actor/conversation. Preserve immutable Layer 0 interactions; do not preserve cross-room leakage as compatibility.
8. Preserve all documented Matrix CLI and bot behavior unrelated to those security repairs. Existing provider/admin/setup writes remain outside `adapter.matrix`.
9. Sanitize outbound errors and test secret/path/token canaries. Do not add live Matrix tests or require credentials.

### Files to Modify

- NEW: `.agents/scripts/team-interface-matrix-adapter.mjs` — frozen static definition, capability/compatibility mapping, observation assembly, injectable local test seams.
- NEW: `.agents/scripts/team-interface-matrix-source.mjs` — bounded configuration/process/session observation with explicit secret projection.
- NEW: `.agents/scripts/team-interface-matrix-ingress.mjs` — pure event acceptance/normalization and stable evidence derivation.
- EDIT: `.agents/scripts/team-interface-adapters.mjs` — register Matrix beside Buzz.
- EDIT: `.agents/scripts/matrix-bot.mjs.template` — call the pure normalizer before existing dispatch, use stable idempotency, and sanitize response failures.
- EDIT: `.agents/scripts/matrix-session-store.mjs.template` — persist event dedupe and bind context/entity/session state to room/conversation without deleting Layer 0.
- EDIT: `.agents/scripts/matrix-dispatch-helper.sh` and setup generation only as needed to deploy updated tracked templates deterministically; preserve command/config compatibility.
- NEW: `.agents/scripts/tests/test-team-interface-matrix-adapter.mjs` — read-only source, projection, compatibility, cancellation, malformed/insecure input, and no-effect tests.
- NEW: `.agents/scripts/tests/test-team-interface-matrix-ingress.mjs` — accepted/ignored/spoofed/duplicate event and deterministic normalized-contract tests.
- NEW: `.agents/scripts/tests/test-matrix-session-store.mjs` — room/actor isolation, remap, dedupe, compaction, legacy fallback, and Layer 0 preservation.
- NEW: `.agents/scripts/tests/fixtures/team-interface/matrix-config.json` and `matrix-events.json` — synthetic token/path/error canaries only.
- EDIT: `.agents/scripts/tests/test-team-interface-runtime.mjs` — built-in registry and binding assertions.
- NEW: `.agents/reference/team-interface-matrix.md`; EDIT team-interface and Matrix operator references/README where behavior is user-visible.
- EDIT: `TODO.md`, mission/source-review, and this brief for task/completion evidence.

### Complete Write Surface

- **Callers/readers:** `.agents/scripts/team-interface-runtime-commands.mjs` selects the built-in adapter; the generated Matrix bot calls the normalizer; runner/entity/session helpers retain their current public entry points; later F2.5/F6.2 consume only normalized evidence.
- **Writers/mutation paths:** `adapter.matrix` and status perform no durable/provider writes. Existing detect may persist only schema-valid normalized state. The existing bot still writes typing/reactions/replies and Layer 0/session state; the new session write is a bounded idempotency record. Setup/admin APIs remain unchanged and outside adapter calls.
- **Tests/fixtures:** `.agents/scripts/tests/fixtures/team-interface/matrix-config.json` and `matrix-events.json` contain no real URL/token/user/room/path; mutation traps prevent network, package, Matrix, runner, or provider calls during adapter tests. Bot/session tests use stubs and temporary SQLite only.
- **Schemas/config:** reuse core-v1 event and runtime-v1 observation/inventory shapes. Keep `matrix-bot.json` authoritative and referenced by opaque settings; do not duplicate access tokens or mappings into team-interface config.
- **Generated/deployed mirrors:** tracked `.agents/scripts/matrix-*.template` files and modules deploy atomically through setup. Existing generated user runtime is refreshed through the normal helper path; never edit the deployed workspace directly.
- **Migrations/backfills:** `.agents/scripts/matrix-session-store.mjs.template` adds idempotency/session columns with idempotent SQLite migration. Existing config and session rows remain readable; legacy DB fallback remains supported.
- **Cleanup/rollback paths:** disable/remove `adapter.matrix`, revert normalizer/template/session changes, and regenerate the bot. Preserve provider rooms/messages, local config, immutable interactions, and user mappings.

### Implementation Steps

1. Add Matrix source projection with constant config path, owner/mode/size checks, cancellation, sanitized diagnostics, and deterministic hashed community/runtime inventory.
2. Define/register the frozen adapter with complete immutable installation/community/runtime/event-read capability declarations and compatibility unknown.
3. Implement pure event normalization with strict bounds and core schema validation; return an explicit ignored result for own/non-text/prefix/empty/unauthorized/unmapped events.
4. Map configured allowlist/mapping decisions into fixed compatibility trust/authority references without asserting cryptographic Matrix identity or admin authority.
5. Add persistent provider-event dedupe and atomic first-seen semantics before runner dispatch; duplicate events acknowledge/ignore without a second runner call.
6. Repair room/entity context selection so recent history cannot cross rooms and a second sender cannot inherit the first sender's mutable session identity. Preserve Layer 0 and documented compaction.
7. Integrate the normalizer into the generated bot while keeping typing/reaction/reply, runner fallback, timeout, truncation, invite, and shutdown behavior covered by characterization tests.
8. Sanitize Matrix-facing errors and ensure no runner error, token, path, or raw diagnostic canary is posted.
9. Add adapter/ingress/session/runtime tests and docs, then run entity/conversation regressions and changed-file quality gates.

### Hazards and Compatibility

- **Concurrency/atomicity:** Matrix may redeliver events and multiple processes may race. Use a unique provider event key in SQLite and one transaction/insert-first decision before dispatch; process-local sets remain a secondary flood guard.
- **Migration/rollback:** SQLite migration is additive/idempotent and preserves interactions. Rollback ignores the new table/columns; no provider data migration occurs.
- **Mixed-version/backward compatibility:** Old generated bots remain operational until regenerated but lack normalization/dedupe. New templates must read old config/session rows and preserve all public commands.
- **Idempotency/retry:** Stable IDs derive from immutable provider identifiers. Repeated detect is observational; duplicate event delivery cannot create a second runner dispatch.
- **Partial failure/recovery:** Unsafe/malformed config degrades adapter capability and blocks normalized dispatch rather than widening authority. Session DB failure leaves provider messages untouched and fails before runner execution.

### Complexity Impact

- **Target functions:** generated Matrix message handler and session-store helpers.
- **Current risk:** the message callback already coordinates many concerns.
- **Estimated growth:** reduce callback logic by moving acceptance/normalization to a pure module; add bounded state helpers rather than extending one orchestration function.
- **Action required:** keep new modules below quality thresholds and do not inline schema/hash/authority logic into the callback.

### Verification Before Dispatch

```bash
node .agents/scripts/tests/test-team-interface-matrix-adapter.mjs
node .agents/scripts/tests/test-team-interface-matrix-ingress.mjs
node .agents/scripts/tests/test-matrix-session-store.mjs
node .agents/scripts/tests/test-team-interface-runtime.mjs
node .agents/scripts/tests/test-team-interface-core-schema.mjs
bash tests/test-entity-helper.sh
bash tests/test-entity-memory-integration.sh
bash tests/test-conversation-helper.sh
bash -n .agents/scripts/matrix-dispatch-helper.sh .agents/scripts/matrix-dispatch-setup.sh .agents/scripts/matrix-dispatch-sessions.sh .agents/scripts/matrix-dispatch-api.sh .agents/scripts/matrix-dispatch-auto-setup.sh
shellcheck .agents/scripts/matrix-dispatch-helper.sh .agents/scripts/matrix-dispatch-setup.sh .agents/scripts/matrix-dispatch-sessions.sh .agents/scripts/matrix-dispatch-api.sh .agents/scripts/matrix-dispatch-auto-setup.sh
.agents/scripts/qlty-new-file-gate-helper.sh new-files --base origin/main --head HEAD
.agents/scripts/qlty-regression-helper.sh --base origin/main --head HEAD
.agents/scripts/linters-local.sh --changed
```

- **Surface mapping:** adapter tests prove read-only projection; ingress tests prove normalized trust/authority/idempotency; session/entity tests prove privacy and migration; runtime/core tests prove static registration and schema binding; existing entity/conversation tests protect compatibility.
- **Broad verification trigger:** required because generated conversational dispatch and shared entity/session state change. Run focused Matrix, runtime/core, and entity/conversation suites plus quality gates.

### Recoverability Checkpoint

- [ ] Focused adapter/ingress/session/runtime tests pass.
- [ ] WIP commit created before broad gates: `wip: normalize Matrix team-interface ingress`.
- [ ] Existing Matrix CLI/entity/session behavior and exact-head review evidence recorded.

### Safety-Stop Recovery

- **Original objective:** Put existing Matrix observation and conversational ingress behind the provider-neutral contracts without behavior regression or new provider writes.
- **Preserved user directions:** Continue autonomously through the no-release full loop; keep Matrix setup/behavior compatible and authority fail-closed.
- **Trigger and evidence:** not triggered.
- **Completed and verified:** current Matrix entry points, gaps, runtime patterns, dependencies, write surfaces, and verification families are mapped.
- **Remaining acceptance criteria:** implementation, migration fixtures, focused/broad verification, PR review/merge, and parent bookkeeping.
- **Unsafe route not to repeat:** Do not duplicate tokens/mappings, infer identity from display names, call setup/admin APIs from the adapter, preserve cross-room leakage, or dispatch before durable event dedupe.
- **Next safe route:** pure normalization plus bounded local observation and additive session migration under synthetic fixtures.
- **Resume condition:** runtime registry/core schemas and Matrix templates still match this brief; no overlapping PR exists.
- **Owner and status:** interactive mission session; briefed.

### Files Scope

- `.agents/scripts/team-interface-matrix-adapter.mjs`
- `.agents/scripts/team-interface-matrix-source.mjs`
- `.agents/scripts/team-interface-matrix-ingress.mjs`
- `.agents/scripts/team-interface-adapters.mjs`
- `.agents/scripts/matrix-bot.mjs.template`
- `.agents/scripts/matrix-session-store.mjs.template`
- `.agents/scripts/matrix-dispatch-helper.sh`
- `.agents/scripts/tests/test-team-interface-matrix-adapter.mjs`
- `.agents/scripts/tests/test-team-interface-matrix-ingress.mjs`
- `.agents/scripts/tests/test-matrix-session-store.mjs`
- `.agents/scripts/tests/fixtures/team-interface/matrix-config.json`
- `.agents/scripts/tests/fixtures/team-interface/matrix-events.json`
- `.agents/scripts/tests/test-team-interface-runtime.mjs`
- `.agents/reference/team-interface-matrix.md`
- `.agents/reference/team-interface-runtime.md`
- `.agents/reference/team-interfaces.md`
- `.agents/services/communications/matrix-bot.md`
- `README.md`
- `TODO.md`
- `todo/tasks/t18207-brief.md`
- `todo/missions/m-20260804-5d06b1/mission.md`
- `todo/missions/m-20260804-5d06b1/research/source-review.md`

## Acceptance Criteria

- [ ] Selecting `adapter.matrix` against a synthetic secure local config returns a schema-valid deterministic read-only observation and never exposes token/path/error canaries or invokes network/provider/package/setup operations.

  ```yaml
  verify:
    method: bash
    run: "node .agents/scripts/tests/test-team-interface-matrix-adapter.mjs && node .agents/scripts/tests/test-team-interface-runtime.mjs"
  ```

- [ ] Accepted Matrix text events normalize into the closed core-v1 event with stable actor/lineage/target/authority/trust/correlation/idempotency evidence, while own, non-text, wrong-prefix, empty, unauthorized, and unmapped events produce no dispatch envelope.

  ```yaml
  verify:
    method: bash
    run: "node .agents/scripts/tests/test-team-interface-matrix-ingress.mjs && node .agents/scripts/tests/test-team-interface-core-schema.mjs"
  ```

- [ ] Duplicate provider event delivery, including after session-store restart, performs at most one runner dispatch; room and actor context cannot leak across rooms or senders, and immutable Layer 0 history survives compaction/migration.

  ```yaml
  verify:
    method: bash
    run: "node .agents/scripts/tests/test-matrix-session-store.mjs && bash tests/test-entity-memory-integration.sh && bash tests/test-conversation-helper.sh"
  ```

- [ ] Existing Matrix setup/start/stop/status/map/unmap/session, prefix, allowlist, runner fallback, typing/reaction/reply, invite, truncation, compaction, shutdown, and legacy-store contracts remain covered without adding provider writes to the adapter.

  ```yaml
  verify:
    method: codebase
    pattern: "setup|start|stop|status|map|unmap|session|prefix|allow|runner|reaction|compaction|legacy"
    path: ".agents/scripts/tests/test-team-interface-matrix-ingress.mjs"
  ```

## Context & Decisions

- F2.4 supplies a compatibility authority façade, not the generic signed broker owned by F6.2.
- Existing `matrix-bot.json` remains authoritative; team-interface config stores only an opaque settings reference.
- Empty `allowedUsers` and `defaultRunner` are surfaced as degraded legacy policy, not silently reclassified as trusted-owner authority.
- No live Matrix/homeserver version claim is made; compatibility remains unknown without an authorized probe.
- Privacy defects are not compatibility promises. Fix cross-room/person leakage while preserving intended user-facing commands and immutable history.

## Relevant Files

- `.agents/scripts/matrix-dispatch-helper.sh:35-129,877-903` — public config and command surface.
- `.agents/scripts/matrix-bot.mjs.template:362-527` — current event/dispatch orchestration.
- `.agents/scripts/matrix-session-store.mjs.template:198-385` — current room/entity/session behavior.
- `.agents/schemas/team-interface/core-v1.schema.json:182-313` — normalized event contract.
- `.agents/scripts/team-interface-buzz-adapter.mjs` — trusted static adapter pattern.
- `todo/missions/m-20260804-5d06b1/research/source-review.md` — decided F2.4 boundary.

## Dependencies

- **Blocked by:** none; F2.1 / #29542 is closed through PR #29619.
- **Blocks:** Milestone 2 integrated validation and later F3/F6 Matrix control/authority work.
- **External:** no Matrix credentials, homeserver write, dependency install, provider account, release, or deployment is required for fixture implementation.

## Estimate

~6h: 1h characterization, 1.5h adapter/source, 1.5h normalization/dedupe/session repair, 1h tests/docs, 1h broad verification/review.
