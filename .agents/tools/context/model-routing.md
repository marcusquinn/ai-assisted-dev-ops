---
description: Quality- and security-aware model routing across canonical workload tiers
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: false
  grep: false
  webfetch: false
  task: false
model: simple
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Quality- and Security-Aware Model Routing

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Default**: `standard`. **Rule**: use the lowest tier that safely and reliably completes the task.
- **Spectrum**: `simple` → `standard` → `thinking`.
- **Frontmatter**: `model: simple|standard|thinking`. Do not put provider names, model families, or reasoning variants in tier fields.
- **Vault metadata**: `data_classification`, `runtime_policy`, `needs_vault`, `needs_collections`, `needs_device`, and `needs_remote_unlock` can restrict dispatch before a prompt leaves the device.

## Model Tiers

| Tier | Current ordered mapping | Use When |
|------|-------|----------|
| `simple` | openai/gpt-5.6-luna → anthropic/claude-haiku-4-5 | Classification, search, triage, formatting, and bounded transforms |
| `standard` | openai/gpt-5.6-sol → zai-coding-plan/glm-5.2 → anthropic/claude-sonnet-4-6 | Code, review, debugging, docs, and most development tasks |
| `thinking` | openai/gpt-5.6-sol → anthropic/claude-opus-4-6 | Architecture, novel problems, security audits, and complex trade-offs |

**Model IDs**: Always fully-qualified (`claude-sonnet-4-6`, not `claude-sonnet-4`). Short-form → `ProviderModelNotFoundError`. CLI prefix: `anthropic/`, `google/`, `openai/`.

Only `simple`, `standard`, and `thinking` are valid authored tiers. Concrete models and provider reasoning levels are resolved from the active routing table at execution time.

**Local execution** is a provider/runtime policy, not a workload tier. A local model may be placed in any canonical tier's ordered model list. Privacy policy still fails closed when no approved local runtime is available.

## Decision Flowchart

```text
Privacy/on-device or Vault local-only? → YES → approved local mapping available? → use mapped model | NO: FAIL
  NO → simple classification/search/formatting? → YES: simple
    NO → novel architecture or complex security reasoning? → YES: thinking
      NO → standard
```

## Fallback Routing

| Tier | Fallback behavior | Trigger |
|------|----------|---------|
| `simple` | next configured simple-tier provider | Primary unavailable or provider-disallowed |
| `standard` | next configured standard-tier provider | Primary unavailable or provider-disallowed |
| `thinking` | next configured thinking-tier provider | Primary unavailable or provider-disallowed |

Supervisor resolves automatically. Interactive: `compare-models-helper.sh discover`.

## Headless Dispatch

**Automatic model derivation (GH#17769):** Headless routing is derived at runtime — no model-ID env var configuration needed:

1. **Routing table** (`configs/model-routing-table.json`, or local override at `custom/configs/model-routing-table.json`) → ordered models per tier
2. **Provider filter** (`AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST`) → optional local pinning such as `openai`
3. **Auth + availability checks** (`headless-runtime-helper.sh`, `model-availability-helper.sh`) → providers/models that can actually run now
4. **Result**: pulse resolves a standard-tier model; workers round-robin across the filtered standard-tier list

Before the selected worker launches, `vault-data-policy-helper.sh` evaluates the
task title/prompt metadata. Remote providers are denied for `local-only` and
`local-LLM-only`; `confidential` and `client-confidential` require
`provider-allowed`, `runtime_policy: provider-ai-approved`, or the explicit
`AIDEVOPS_VAULT_PROVIDER_AI_APPROVED=1` dispatch gate. `secret` classification
is always denied because secrets must flow through secret tooling, not prompts.

- **Shared default**: The framework routing table lists smoke-tested OpenAI models first so workers can continue during Anthropic cooldowns. Anthropic remains the fallback, and local custom routing can still reorder or replace these defaults.
- **Pulse**: Resolves `standard` through `model-availability-helper.sh resolve standard`, so it follows routing-table order, health checks, local routing-table overrides, and `AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST`.
- **Workers**: Round-robin across canonical `simple`, `standard`, or `thinking` routes after allowlist filtering and auth checks.
- **Local switch**: Set `AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=openai` to force both pulse and workers onto the default OpenAI fallbacks. If you want OpenAI primary but Anthropic fallback, reorder `custom/configs/model-routing-table.json` and omit the allowlist.
- **Current default mapping**: The active routing table currently maps `simple` to OpenAI Luna then Anthropic Haiku, `standard` to OpenAI Sol then Z.AI GLM then Anthropic Sonnet, and `thinking` to OpenAI Sol then Anthropic Opus. Availability and provider policy decide the exact model at execution time.
- **Reasoning mapping**: The routing table maps OpenAI `simple`, `standard`, and `thinking` to Luna `max`, Sol `high`, and Sol `max`. Other providers use their provider/runtime defaults unless configured explicitly.
- **Capability escalation**: A Luna `max` worker that reports a capability-related `BLOCKED` outcome resumes once at Sol `high`; a Sol `high` blocker resumes once at Sol `max`. Sol `max` is terminal. Permission, authentication, provider, rate-limit, policy, and trust-boundary failures retain dedicated fail-closed handling and never escalate reasoning to bypass controls.
- **OpenAI tier rationale**: The automatic ladder prioritizes quality and security over minimum token cost: Luna `max` handles bounded work, Sol `high` handles general implementation, and Sol `max` handles deep reasoning. Terra remains available for explicit use or future evidence-based routing, but is not in the automatic default chain.
- **OpenAI pro caveat**: `openai/gpt-5.6-sol-pro` passed a live OpenCode ChatGPT OAuth smoke test on 2026-07-10, but OpenAI publishes neither an API price nor comparative Sol Pro benchmarks. It remains excluded from automatic workers pending repository-specific completion-rate evidence. Historical `gpt-5.5-pro` and older `*-pro`/`o3-pro` IDs remain excluded.
- **GPT-5.5 standard workers**: aidevops omits env-derived standard-tier variants so OpenCode sends no explicit thinking override. Explicit CLI `--variant` still wins.
- **GLM-5.2 option**: Standard routing may use `zai-coding-plan/glm-5.2` when that OpenCode provider is authenticated. Direct `zai/glm-5.2` is intentionally excluded.
- **Tier-aware effort**: `AIDEVOPS_HEADLESS_VARIANT_SIMPLE`, `AIDEVOPS_HEADLESS_VARIANT_STANDARD`, and `AIDEVOPS_HEADLESS_VARIANT_THINKING` can temporarily override routing-table reasoning.
- **Fallback**: If routed resolution fails entirely, pulse falls back to `anthropic/claude-sonnet-4-6`; workers fall back to `DEFAULT_HEADLESS_MODELS` when no allowlist is forcing a subset.
- **Deprecated**: `PULSE_MODEL` and `AIDEVOPS_HEADLESS_MODELS` env vars are respected as overrides for one release cycle with deprecation warnings. Remove from `credentials.sh`.

### Per-user override that survives auto-update

Auto-update overwrites `~/.aidevops/agents/configs/*.json` and `~/.aidevops/agents/scripts/*`, so user-specific routing must live outside those paths.

- Put persistent model-order overrides in `~/.aidevops/agents/custom/configs/model-routing-table.json`
- Put the provider pin in `~/.config/aidevops/credentials.sh`
- Do not rely on `.bashrc`, `.zshrc`, or `.profile` for pulse/worker provider pins; scheduled daemons intentionally do not source interactive shell startup files.

Example custom override for OpenAI-capable headless routing:

```json
{
  "tiers": {
    "standard": { "models": ["openai/gpt-5.6-sol", "anthropic/claude-sonnet-4-6"] },
    "thinking": { "models": ["openai/gpt-5.6-sol", "anthropic/claude-opus-4-6"] }
  }
}
```

Example hard pin:

```bash
export AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST="openai"
```

Example reasoning effort override, including an explicit opt-in above the shared
thinking default:

```bash
export AIDEVOPS_HEADLESS_VARIANT_STANDARD="high"
export AIDEVOPS_HEADLESS_VARIANT_THINKING="max"
```

Role-specific overrides still exist when needed:

```bash
export AIDEVOPS_HEADLESS_PULSE_VARIANT="high"
export AIDEVOPS_HEADLESS_WORKER_VARIANT="max"
```

## CLI Tools

```bash
compare-models-helper.sh discover [--probe|--list-models|--json]
compare-models-helper.sh list|capabilities|compare|recommend "task"
local-model-helper.sh status|models
model-availability-helper.sh check|resolve  # Exit: 0=ok, 1=unavail, 2=rate-limited, 3=bad-key
```

Interactive: `/compare-models`, `/compare-models-free`, `/route <task>`

## Bundle Presets (t1364.6)

```json
{ "model_defaults": { "implementation": "standard", "review": "standard", "triage": "simple",
    "architecture": "thinking", "verification": "standard", "documentation": "simple" } }
```

**Precedence** (highest wins): `model:` in TODO.md → subagent frontmatter → bundle `model_defaults` → default `standard`. Multiple bundles → most-capable required tier wins. CLI: `bundle-helper.sh get|resolve`. Integration: `cron-dispatch.sh`, pulse `agent_routing`, `linters-local.sh` `skip_gates`.

## Failure-Based Escalation (t1416 + GH#14964)

After 2 failed attempts, escalate from `standard` to `thinking`. Dispatch/kill comments must include the canonical tier for escalation auditing.

**Worker BLOCKED policy (GH#14964 — MANDATORY):** Attempt model escalation before exiting `BLOCKED`. Review-policy metadata, nominal GitHub states, and lower-tier model limits are NOT valid blockers on their own — a genuine blocker must persist after escalation. See `prompts/worker-efficiency-protocol.md` "Model escalation before BLOCKED".

## Tier Drift Detection (t1191)

`budget-tracker-helper.sh tier-drift [--json|--summary]` or `/patterns report|recommend "task type"`. Pulse Phase 12b checks hourly: >25% escalation → notice; >50% → warning.

## Prompt Version Tracking (t1396)

`observability-helper.sh record --model <id> --input-tokens N --output-tokens N --prompt-file <path>`. Results: `compare-models-helper.sh results --prompt-version <hash>`.

<!-- AI-CONTEXT-END -->

## Related

- `tools/local-models/local-models.md` — Local model setup (llama.cpp)
- `tools/ai-assistants/compare-models.md` — Full model comparison subagent
- `scripts/compare-models-helper.sh` — Provider discovery and comparison
- `scripts/commands/route.md` — `/route` command
