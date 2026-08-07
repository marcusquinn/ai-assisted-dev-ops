<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Milestone 2 final-leaf source review

This focused review preserves the implementation evidence for Feature 2.4
Matrix normalization and Feature 2.5 restricted OpenCode overlays. The
mission-wide architecture remains in [source-review.md](source-review.md).

## Feature 2.4 refreshed Matrix evidence

The existing Matrix integration remains a generated Node runtime behind
`.agents/scripts/matrix-dispatch-helper.sh`. Its setup, map/unmap, session,
start/stop, invite, prefix, runner fallback, reaction, compaction, and response
behavior are compatibility surfaces rather than a new provider API.

- F2.4 registers a static read-only `adapter.matrix` that reads the existing
  mode-0600 `matrix-bot.json` through bounded local I/O, projects no access
  token or private path, reports remote compatibility as unknown without an
  authenticated network probe, and never invokes setup/install/admin APIs.
- The existing bot normalizes accepted text events into the closed core-v1
  event contract before dispatch. Configured allowlists, room mappings,
  prefix handling, and runner selection remain the compatibility policy; the
  normalized authority reference records that decision but does not create
  broader authority or implement the later generic broker.
- Provider event IDs, room IDs, sender IDs, and homeserver identity become
  deterministic hashed stable IDs. Display names never authorize identity.
- Current room session state has cross-room and multi-user ambiguity because
  recent interactions are entity-wide and one mutable entity is stored per
  room. F2.4 adds characterization coverage and binds context to the current
  room/conversation without deleting immutable Layer 0 interactions.
- Process-local active-dispatch suppression is not durable idempotency. The
  normalized Matrix event ID/idempotency key is persisted or checked at the
  existing session boundary so redelivery cannot create a second dispatch.
- Existing write-capable Matrix setup/admin helpers remain outside the adapter.
  F2.4 introduces no provisioning, dependency installation, credential lookup,
  community writes, or unattended permission widening.

## Feature 2.5 refreshed OpenCode evidence

The canonical roster now supplies stable agent IDs, source digests, and
`simple|standard|thinking` workload tiers but deliberately excludes model IDs,
prompts, provider IDs, permissions, and launch configuration. OpenCode launch
overlays therefore consume roster evidence without mutating persistent config.

- F2.5 adds a closed schema-backed ephemeral descriptor containing only roster
  identity/digest, selected agent/source digest, workload tier, a fixed
  `conversation_read_only_v1` permission profile, bounded provider/community/
  conversation/app-team/actor/trust/correlation references, and a context
  digest. Raw messages, instructions, credentials, paths, models, shell text,
  arbitrary environment, and authority grants are forbidden.
- Effective OpenCode configuration disables sharing, snapshots, formatters,
  LSP, MCPs, subagents, custom/network tools, and every mutating tool. The
  selected primary profile receives only credential-filtered local
  `read`/`grep`/`glob` access.
- Conversation isolation is applied after plugin agent/MCP/tool/grant and
  managed-directory mutation so later config hooks cannot widen the profile.
- Workload tier is resolved to the runtime's current provider-specific variant
  at root chat-parameter time. No concrete model ID is persisted in the
  overlay, and unknown roster agents/digests fail closed.
- A dedicated fixed-argv ACP/conversation launcher uses verified `--cwd`,
  rejects arbitrary passthrough and `--auto`, and supplies only the validated
  overlay context. Persistent `opencode.json` and canonical agent generation
  remain unchanged.

### Feature 2.5 implementation and verification

- `.agents/schemas/team-interface/opencode-launch-overlay-v1.schema.json`,
  `.agents/plugins/opencode-aidevops/team-interface-overlay-contract.mjs`, and
  `.agents/scripts/team-interface-opencode-overlay.mjs` implement the closed
  contract, canonical digests, source binding, deterministic generation, and
  atomic output.
- `.agents/plugins/opencode-aidevops/team-interface-context.mjs`,
  `.agents/plugins/opencode-aidevops/config-safety-guards.mjs`, and
  `.agents/plugins/opencode-aidevops/config-hook.mjs` inject bounded context,
  route workload tiers, and apply conversation isolation after every managed
  configuration mutation.
- `.agents/scripts/team-interface-opencode-effective-config.mjs` verifies the
  merged runtime configuration, while
  `.agents/scripts/opencode-launcher-helper.sh conversation` enforces canonical
  overlay/cwd inputs and launches fixed `opencode acp --cwd` arguments.
- Focused overlay, context, source-verification, effective-config, workload,
  plugin, and launcher tests pass. Broad team-interface, trust, runtime,
  compatibility, and subagent regressions pass; the plugin suite reports 556
  passing tests under `umask 0022`, and the launcher suite reports 16 passing
  cases.
- Isolated installed-runtime smoke preserves the exact generated descriptor
  digest in `opencode debug config` and reaches healthy ACP startup until the
  bounded timeout. No persistent OpenCode configuration is changed.
- `.agents/reference/team-interface-opencode-overlays.md` documents selection,
  context propagation, guarantees, launch, verification, and rollback.
