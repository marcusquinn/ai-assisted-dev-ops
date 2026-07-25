<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Concrete Model Profiles

These provider-named files describe concrete model capabilities and compatibility
behaviour. They are runtime mapping inputs, not workload tiers for tasks, briefs,
agents, or research programs.

## Core Rules

- **Canonical authoring interface:** use only `simple`, `standard`, or `thinking`
  in task labels, agent `model:` fields, briefs, and research role fields.
- **Central mapping:** `configs/model-routing-table.json` owns each tier's ordered
  provider/model list. Runtime availability, provider policy, and local overrides
  choose the concrete model at execution time.
- **Concrete profile exception:** provider profile files may contain fully
  qualified `model:`, fallback, capability, cost, and compatibility evidence
  because their purpose is to inform runtime mapping.
- **Legacy filenames are provenance:** names such as `models-haiku.md` identify
  the concrete family documented; they do not create an authored `haiku` tier.

## Workload Mapping

| Workload tier | Authored request | Concrete source of truth |
|---------------|------------------|--------------------------|
| `simple` | Bounded mechanical work | `.tiers.simple.models` in `configs/model-routing-table.json` |
| `standard` | General implementation and review | `.tiers.standard.models` in `configs/model-routing-table.json` |
| `thinking` | Architecture and complex trade-offs | `.tiers.thinking.models` in `configs/model-routing-table.json` |

## Resolution Flow

**Deploy-time:** generated runtime adapters resolve canonical workload tiers through
`model-routing-table.json` where the runtime requires a fully qualified ID.

**In-session (runtime-dependent):**
- **OpenCode:** generated agents receive the routed provider/model ID where model
  switching is supported.
- **Claude Code:** `Task(subagent_type="general", ...)` — ignores `model:` frontmatter; subagents run on the session model.

**Headless:** task metadata supplies `simple`, `standard`, or `thinking`; the
runtime helper resolves the active routing table and passes the selected concrete
ID to the runtime CLI.

## Fallback Chains (t132.4)

The routing table defines ordered provider/model chains for API errors, timeouts,
rate limits, and policy exclusions. Resolution walks the requested workload tier's
chain until a healthy approved provider is found.

```yaml
fallback-chain:
  - anthropic/claude-sonnet-4-6
  - openai/gpt-5.4
  - google/gemini-2.5-pro
  - openrouter/anthropic/claude-sonnet-4-6
```

> **Note:** codex/code-completion models (gpt-5.3-codex, gpt-5.4-codex) are NOT agentic and must never appear in fallback chains. See `configs/model-routing-table.json` for the canonical tier→model mappings.

- **Per-profile compatibility:** Concrete profile frontmatter may document a
  model-specific fallback.
- **Canonical route:** Edit the ordered tier mapping in
  `configs/model-routing-table.json` or the documented local override.
- **Docs:** `tools/ai-assistants/fallback-chains.md`.

## Adding or Updating a Concrete Model

1. Update `configs/model-routing-table.json` with the fully qualified model ID in
   the appropriate canonical workload tier.
2. Edit or create a provider profile only when durable capability, compatibility,
   cost, or context-limit evidence is needed.
3. Update mapping evidence in `tools/context/model-routing.md`.
4. Update `compare-models-helper.sh` `MODEL_DATA` if applicable.
5. Run `model-registry-helper.sh sync --force && model-registry-helper.sh check`.

## Model Registry

`model-registry-helper.sh` maintains `~/.aidevops/.agent-workspace/model-registry.db`. Syncs on `aidevops update`.

```bash
model-registry-helper.sh sync          # Sync all sources
model-registry-helper.sh status        # Health and tier mapping
model-registry-helper.sh check         # Verify models exist
model-registry-helper.sh suggest       # New model suggestions
model-registry-helper.sh deprecations  # Unavailable models
model-registry-helper.sh diff          # Registry vs local config
```

## Related

- `tools/ai-assistants/fallback-chains.md` — fallback config
- `tools/context/model-routing.md` — cost-aware routing
- `scripts/compare-models-helper.sh discover --probe` — discovery
- `model-registry-helper.sh` — maintenance
- `fallback-chain-helper.sh` — resolution
- `tools/ai-assistants/headless-dispatch.md` — CLI dispatch
