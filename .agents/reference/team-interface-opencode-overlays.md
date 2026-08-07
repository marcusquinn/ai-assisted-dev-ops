<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Restricted OpenCode conversation overlays

The version-1 OpenCode launch overlay is the ephemeral boundary between a
verified canonical aidevops roster entry, bounded team-interface correlation
references, and one locally read-only OpenCode ACP session. It does not grant
actor authority, persist a model selection, or modify `opencode.json`.

The closed descriptor schema is
`schemas/team-interface/opencode-launch-overlay-v1.schema.json`. Generate and
validate descriptors with `scripts/team-interface-opencode-overlay.mjs`; launch
them only through the dedicated `aidevops opencode conversation` path.

## Generate an overlay

Generate the canonical roster first:

```bash
umask 077
.agents/scripts/team-interface-agent-roster.py \
  --agents-dir .agents \
  --output roster.json
```

Prepare a closed context document containing references only:

```json
{
  "actor_ref": "actor:synthetic-owner",
  "app_team_ref": "app-team:synthetic-team",
  "community_ref": "community:synthetic-community",
  "conversation_ref": "conversation:synthetic-thread",
  "correlation_ref": "correlation:synthetic-correlation",
  "provider_ref": "provider:synthetic-provider",
  "trust_ref": "trust:synthetic-verified"
}
```

Then select one stable roster ID and optionally override its portable workload
tier:

```bash
node .agents/scripts/team-interface-opencode-overlay.mjs generate \
  --roster roster.json \
  --agent-id agent.build-plus \
  --context context.json \
  --workload-tier standard \
  --output overlay.json

node .agents/scripts/team-interface-opencode-overlay.mjs validate \
  --overlay overlay.json
```

Identical canonical inputs produce byte-identical output and digests. Explicit
output uses atomic mode-0600 replacement. The descriptor includes only roster,
agent/source, context, config, and overlay evidence; raw messages,
instructions, credentials, host paths, provider/model IDs, shell fragments,
arbitrary environment values, and authority grants are rejected.

`agent.aidevops-guide` is supported explicitly as the restricted `AI DevOps`
framework guide. It is never substituted with Build+.

## Launch the conversation

The launcher requires an absolute non-symlink overlay path and a bounded project
directory:

```bash
aidevops opencode conversation \
  --overlay "$PWD/overlay.json" \
  --dir "$PWD"
```

Use `--dry-run` to validate and print the redacted fixed command without
starting ACP. Real launch validates the canonical descriptor, creates an
isolated OpenCode data directory, evaluates `opencode debug config`, verifies
the complete merged restriction profile, and only then executes fixed argv:

```text
opencode acp --cwd <verified-project-directory>
```

Conversation mode rejects `--auto`, passthrough arguments, root/home cwd,
relative or symlinked overlays, server-auth variables, and inherited
config/plugin/model overrides. The caller cannot select an executable,
provider, model, plugin, or arbitrary environment value through the overlay.

## Enforced profile

The selected root profile permits only credential-filtered local `read`,
`grep`, and `glob`. It denies every unknown tool by wildcard and explicitly
denies Bash, edits/writes/patches, tasks and subagents, skills, questions,
todos, web/network tools, MCP/custom tools, and managed-directory widening.

The final plugin isolation pass runs after normal agent, MCP, tool, grant, and
managed-directory configuration. It also:

- disables every unselected primary and built-in agent;
- disables sharing, snapshots, LSP, formatter, MCPs, and subagent depth;
- verifies the selected source bytes against the roster source digest;
- injects the seven immutable context references as a bounded system block;
- rejects nested sessions or a root-session agent mismatch; and
- resolves only the portable `simple`, `standard`, or `thinking` variant from
  current runtime routing policy.

The context block is identity and correlation evidence, not authorization.
User or provider message content cannot widen the enforced profile.

## Compatibility, failure, and rollback

Missing source bytes, digest drift, malformed/non-canonical input, unknown
fields, unsupported runtime hooks, widened effective config, or failed OpenCode
debug evaluation blocks launch. There is no fallback to a persistent
write-capable profile.

Overlays are opt-in and ephemeral. Existing TUI, server, attach, Desktop, and
headless launch paths are unchanged. To roll back or end access, stop the ACP
process and remove the caller-owned roster, context, and overlay files; no user
configuration migration or provider cleanup is required.

## Verification

```bash
node .agents/scripts/tests/test-team-interface-opencode-overlay.mjs
node --test .agents/plugins/opencode-aidevops/tests/test-team-interface-conversation-profile.mjs
bash .agents/scripts/tests/test-opencode-launcher-helper.sh
node .agents/scripts/tests/test-team-interface-agent-roster.mjs
bash .agents/scripts/tests/test-opencode-subagent-runtime-guards.sh
bash .agents/scripts/tests/test-agent-discovery-smoke.sh
bash .agents/scripts/tests/test-canonical-model-tiers.sh
bash .agents/scripts/tests/test-opencode-server-launcher.sh
npm test --prefix .agents/plugins/opencode-aidevops
```
