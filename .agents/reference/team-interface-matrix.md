<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Matrix team-interface adapter and ingress

`adapter.matrix` is the trusted, in-tree, read-only adapter for the existing
Matrix dispatch integration. It observes bounded local configuration and
process state. It does not resolve credentials, contact a homeserver, install
dependencies, invoke Matrix setup/admin APIs, dispatch a runner, or mutate
provider/local configuration.

The generated Matrix bot separately passes accepted events through the pure
provider-neutral ingress normalizer before its existing runner path. That
normalization does not add authority: it records the configured legacy
allowlist and room/runner decision as explicit compatibility evidence.

## Static selection and local sources

The built-in registry freezes `adapter.matrix` with provider ID `matrix`.
Runtime configuration may select it with an opaque `settings:` reference; the
adapter never resolves or emits that reference. Production paths remain fixed:

- configuration: `~/.config/aidevops/matrix-bot.json` or the current
  `XDG_CONFIG_HOME` equivalent;
- process receipt: `~/.aidevops/.agent-workspace/matrix-bot/bot.pid`.

`createMatrixAdapter(dependencies)` exposes replacement paths, clock, liveness,
and read primitives only as in-process test seams. Runtime configuration cannot
supply an executable module, source path, credential resolver, provider client,
or mutation callback.

The configuration must be a current-user-owned mode-0600 regular file reached
through a non-symlink component path. The PID source must be current-user-owned
and non-group/world-writable. Both reads are descriptor-bound, size-limited,
revalidate path/device/inode identity, and receive the runtime abort signal.
Malformed, oversized, replaced, symlinked, unowned, or insecure sources degrade
closed. A missing config makes the adapter unavailable; a missing/stale PID
keeps local inventory observable but makes event receipt unavailable.

## Projection and compatibility

The adapter emits a closed observation containing:

- installation, community, configured-runtime, and event-receipt capabilities;
- one SHA-256-derived community ID and hashed display label;
- one hashed bot-runtime record with local liveness;
- deduplicated SHA-256-derived configured-runner records with unknown liveness;
- fixed local-observation evidence; and
- `unknown` Matrix compatibility with provider version `unprobed`.

No authenticated versions request is made, so local configuration never implies
remote compatibility. Empty `allowedUsers` or `defaultRunner` remains supported
legacy behavior but degrades event-receipt policy evidence. The observation
excludes access tokens, homeserver/room/user/runner values, process IDs, prompts,
responses, errors, paths, arbitrary config fields, provider payloads, and
`settings_ref`.

## Normalized event boundary

`team-interface-matrix-ingress.mjs` accepts only bounded `m.text` events after
all of these existing policy checks pass:

1. own-message suppression;
2. configured prefix and non-empty prompt;
3. inbound prompt bound;
4. explicit allowlist or documented open legacy policy;
5. room mapping or configured default runner; and
6. valid provider event ID and provider timestamp.

Own, non-text, wrong-prefix, empty, oversized, unauthorized, malformed, and
unmapped events return an explicit ignored result and produce no normalized
envelope. Display names are never accepted as identity evidence.

Accepted events validate against the closed core-v1 `event` document. Stable
event, actor, community, room-plus-actor conversation, runner, correlation, and
idempotency IDs are SHA-256-derived from typed provider values. The raw Matrix
event ID is retained only in the core lineage field required for provider retry
evidence; raw homeserver, room, sender, and runner values are not emitted as
normalized identities.

The verified actor records the authenticated Matrix provider session with no
provider signature. The fixed trust/authority references distinguish explicit
allowlist policy from open legacy policy and grant only the already-selected
runner receive/dispatch path. They are compatibility evidence, not the generic
signed authority broker.

## Durable deduplication and context isolation

Before typing indicators, reactions, replies, entity mutation, or runner/API
dispatch, the generated bot inserts the normalized idempotency key into
`matrix_event_receipts`. Its primary key provides atomic first-seen behavior
across concurrent delivery and process restart. A duplicate returns without a
second provider or runner effect. A failed first dispatch is not automatically
replayed, preserving at-most-once execution.

`matrix_room_sessions` gains an additive `actor_id` migration. Room state is
bound to the normalized actor and room-plus-actor conversation. Switching actor
or conversation clears mutable entity/upstream session/message-count state;
switching runners clears the upstream session. Neither operation deletes Layer
0 interactions.

Recent context requires the exact entity, Matrix channel, room ID, and
conversation ID. Layer 1 summaries additionally require the matching entity and
room. Historical records that used broader channel identifiers remain immutable
but are not reintroduced into a different room/person prompt. Compaction resets
only mutable session state and preserves Layer 0.

Matrix-facing dispatch failures are generic. Runner stderr, provider errors,
tokens, paths, and raw diagnostic messages are not posted into rooms.

## Compatibility and rollback

Setup, start/stop/status, map/unmap, sessions, invite handling, prefix,
allowlist, runner selection/fallback, typing, reactions, replies, response
truncation, idle compaction, and shutdown remain on the existing Matrix helper
surface. Write-capable setup and admin helpers remain outside `adapter.matrix`.

To stop read-only observation, remove `adapter.matrix` from the team-interface
runtime selection and run `detect` to clear stale selected state. Reverting the
adapter/registry/normalizer/template/session migration leaves Matrix rooms,
messages, config, mappings, receipts, and immutable interactions intact. An old
session-store implementation ignores the additive table/column.

## Verification

```bash
node .agents/scripts/tests/test-team-interface-matrix-adapter.mjs
node .agents/scripts/tests/test-team-interface-matrix-ingress.mjs
node .agents/scripts/tests/test-matrix-session-store.mjs
node .agents/scripts/tests/test-team-interface-runtime.mjs
node .agents/scripts/tests/test-team-interface-core-schema.mjs
bash tests/test-entity-memory-integration.sh
bash tests/test-conversation-helper.sh
.agents/scripts/qlty-new-file-gate-helper.sh new-files --base origin/main --head HEAD
.agents/scripts/qlty-regression-helper.sh --base origin/main --head HEAD
.agents/scripts/linters-local.sh --changed
```
