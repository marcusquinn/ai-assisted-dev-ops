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

- **Assignment policy**: `reference/task-taxonomy.md` is canonical. Default to `standard`; use the lowest tier with a credible one-pass path to safe completion.
- **Spectrum**: `simple` → `standard` → `thinking`.
- **Frontmatter**: `model: simple|standard|thinking`. Do not put provider names, model families, or reasoning variants in tier fields.
- **Vault metadata**: `data_classification`, `runtime_policy`, `needs_vault`, `needs_collections`, `needs_device`, and `needs_remote_unlock` can restrict dispatch before a prompt leaves the device.

## Model Tiers

| Tier | Current ordered mapping | Use When |
|------|-------|----------|
| `simple` | openai/gpt-5.6-luna → anthropic/claude-haiku-4-5 | Complete low-consequence execution contracts |
| `standard` | openai/gpt-5.6-terra → zai-coding-plan/glm-5.2 → anthropic/claude-sonnet-4-6 | Established-pattern implementation with normal judgment and recovery |
| `thinking` | openai/gpt-5.6-sol → anthropic/claude-opus-4-6 | Consequential unresolved decisions, novel design, and synthesis-heavy work |

**Model IDs**: Always fully-qualified (`claude-sonnet-4-6`, not `claude-sonnet-4`). Short-form → `ProviderModelNotFoundError`. CLI prefix: `anthropic/`, `google/`, `openai/`.

Only `simple`, `standard`, and `thinking` are valid authored tiers. Concrete models and provider reasoning levels are resolved from the active routing table at execution time.

**Local execution** is a provider/runtime policy, not a workload tier. A local model may be placed in any canonical tier's ordered model list. Privacy policy still fails closed when no approved local runtime is available.

## Decision Flowchart

```text
Privacy/on-device or Vault local-only? → YES → approved local mapping available? → use mapped model | NO: FAIL
  NO → consequential unresolved decision or dispatch-path override? → YES: thinking
    NO → complete verified low-consequence execution contract? → YES: simple
      NO → standard
```

Tier selection never bypasses permission, secret, policy, billing, or destructive
operation gates. Security-sensitive implementation inside a decided boundary is
normally standard; deciding that boundary is thinking.

## Fallback Routing

| Tier | Fallback behavior | Trigger |
|------|----------|---------|
| `simple` | next configured simple-tier provider | Primary unavailable or provider-disallowed |
| `standard` | next configured standard-tier provider | Primary unavailable or provider-disallowed |
| `thinking` | next configured thinking-tier provider | Primary unavailable or provider-disallowed |

Supervisor and OpenCode subagents resolve the first connected same-tier candidate
at request time. Interactive diagnostics: `compare-models-helper.sh discover`.

## Headless Dispatch

**Automatic model derivation (GH#17769):** Headless routing is derived at runtime — no model-ID env var configuration needed:

1. **Routing table** (`configs/model-routing-table.json`, or local override at `custom/configs/model-routing-table.json`) → ordered models per tier
2. **Provider filter** (`AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST`) → optional local pinning such as `openai`
3. **Auth + availability checks** (`headless-runtime-helper.sh`, `model-availability-helper.sh`) → providers/models that can actually run now
4. **Result**: dispatch selects the first healthy allowed candidate; availability failures move right within the same tier

Before the selected worker launches, `vault-data-policy-helper.sh` evaluates the
task title/prompt metadata. Remote providers are denied for `local-only` and
`local-LLM-only`; `confidential` and `client-confidential` require
`provider-allowed`, `runtime_policy: provider-ai-approved`, or the explicit
`AIDEVOPS_VAULT_PROVIDER_AI_APPROVED=1` dispatch gate. `secret` classification
is always denied because secrets must flow through secret tooling, not prompts.

- **Shared default**: The framework routing table lists smoke-tested OpenAI models first so workers can continue during Anthropic cooldowns. Anthropic remains the fallback, and local custom routing can still reorder or replace these defaults.
- **Pulse**: Resolves `standard` through `model-availability-helper.sh resolve standard`, so it follows routing-table order, health checks, local routing-table overrides, and `AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST`.
- **Workers**: Follow configured candidate order within canonical `simple`, `standard`, or `thinking` routes after allowlist filtering and auth checks.
- **Local switch**: Set `AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=openai` to force both pulse and workers onto the default OpenAI fallbacks. If you want OpenAI primary but Anthropic fallback, reorder `custom/configs/model-routing-table.json` and omit the allowlist.
- **Current default mapping**: The active routing table maps `simple` to OpenAI Luna then Anthropic Haiku, `standard` to OpenAI Terra then Z.AI GLM then Anthropic Sonnet, and `thinking` to OpenAI Sol then Anthropic Opus. Availability and provider policy decide the exact model at execution time.
- **Reasoning mapping**: The routing table maps OpenAI `simple`, `standard`, and `thinking` to Luna `medium`, Terra `high`, and Sol `medium`. Other providers use their provider/runtime defaults unless configured explicitly.
- **Capability escalation**: The exact structured marker `BLOCKED: capability limit - <evidence>` advances through `escalation_order` and resolves that tier's current first healthy candidate without pattern-driven downgrade. Headless dispatch starts another bounded route attempt. Interactive OpenCode re-prompts the same child session only when the child identity is known and it has attempted no side effects. Generic `BLOCKED` outcomes and the terminal configured tier remain terminal. Permission, authentication, provider, rate-limit, secret, policy, trust-boundary, locality, and billing failures retain dedicated fail-closed handling and never escalate capability to bypass controls.
- **OpenAI tier rationale**: The automatic ladder prioritizes verified completion and measured cost: Luna handles bounded work, Terra handles general implementation, and Sol handles synthesis-heavy work. Routing telemetry supports evidence-based reordering without hardcoding provider assumptions.
- **OpenAI pro caveat**: `openai/gpt-5.6-sol-pro` passed a live OpenCode ChatGPT OAuth smoke test on 2026-07-10, but OpenAI publishes neither an API price nor comparative Sol Pro benchmarks. It remains excluded from automatic workers pending repository-specific completion-rate evidence. Historical `gpt-5.5-pro` and older `*-pro`/`o3-pro` IDs remain excluded.
- **GLM-5.2 option**: Standard routing may use `zai-coding-plan/glm-5.2` when that OpenCode provider is authenticated. Direct `zai/glm-5.2` is intentionally excluded.
- **Tier-aware effort**: `AIDEVOPS_HEADLESS_VARIANT_SIMPLE`, `AIDEVOPS_HEADLESS_VARIANT_STANDARD`, and `AIDEVOPS_HEADLESS_VARIANT_THINKING` can temporarily override routing-table reasoning.
- **Fallback**: If routed resolution fails entirely, the framework uses the active table's ordered candidates and then its shipped deterministic table. An explicit provider allowlist fails closed when no listed candidate is usable.
- **Deprecated**: `PULSE_MODEL` and `AIDEVOPS_HEADLESS_MODELS` env vars are respected as overrides for one release cycle with deprecation warnings. Remove from `credentials.sh`.

### Practical model and effort selection

The September 2026 defaults are an educated, reversible operating choice, not a
benchmark superiority claim: Luna medium avoids blanket maximum reasoning for
bounded work; Terra high retains headroom for normal judgment and recovery; Sol
medium keeps synthesis cheaper than routinely duplicating a flagship parent.
Use ordinary completion, verification, retries and parent repair to improve these
choices, following `reference/agent-routing.md` "Improve efficiency during ordinary
work". Historical replay remains opt-in for material unresolved comparisons, not
a prerequisite for building with the framework.

GPT-6 Astra medium is a reasonable explicitly selected interactive daily driver
when its judgment saves human intervention. It does not replace the shared worker
ladder or change other models' reasoning. Reserve Astra or higher effort for a
specific difficult decision rather than routine second opinions. Same-model
OpenCode children cannot exceed their parent's known reasoning setting; use an
explicit parent effort change when genuinely needed, not a bypass of that cap.

Pricing source: [OpenAI Standard pricing](https://developers.openai.com/api/docs/pricing?latest-pricing=standard),
checked 2026-09-05. Per million short-context input/cached-input/output tokens:
Luna $0.20/$0.02/$1.20; Terra $2/$0.20/$12; Sol $4/$0.40/$20; Astra $10/$1/$50.
Sol's promotional rates are available at least through 2026-11-21. The shared flat
pricing table provides API-equivalent estimates: it does not model long-context
rates, Fast mode or regional uplifts. With ChatGPT OAuth, use API prices only as
directional resource-cost signals, never an exact subscription allowance percentage
or cash charge. Preserve recorded pricing versions when comparing outcomes; this
refresh does not reprice already-versioned historical requests.

### Per-user override that survives auto-update

Auto-update overwrites `~/.aidevops/agents/configs/*.json` and `~/.aidevops/agents/scripts/*`, so user-specific routing must live outside those paths.

- Put persistent model-order overrides in `~/.aidevops/agents/custom/configs/model-routing-table.json`
- Put the provider pin in `~/.config/aidevops/credentials.sh`
- Do not rely on `.bashrc`, `.zshrc`, or `.profile` for pulse/worker provider pins; scheduled daemons intentionally do not source interactive shell startup files.

Example custom override for OpenAI-capable headless routing:

```json
{
  "tiers": {
    "standard": { "models": ["openai/gpt-5.6-terra", "anthropic/claude-sonnet-4-6"] },
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

### Scheduled jobs and completion feedback

`cron-helper.sh` and `runner-helper.sh` store canonical tier intent and resolve
the active candidate and variant when execution starts. This keeps scheduled
work aligned with routing-table updates instead of freezing an obsolete model.

Routing decisions are recorded with tier, candidate index, route attempt, reason,
escalation, model, variant, aidevops version, outcome, token, and cost evidence
where available. Ordinary child conversation turns retain one route-attempt
number; only a real retry or capability transition increments it. This keeps
version-segmented routing comparisons from counting conversation length as
retries.
Interactive sessions receive a duplicate-suppressed completion toast; routine
tracking bodies and deterministic PR/issue closeouts receive the same bounded
analysis. Recommendations are advisory and require repeated evidence before a
lower-tier trial is suggested.

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

Availability, authentication, rate-limit, and runtime failures retry configured
same-tier candidates. Only `BLOCKED: capability limit - <evidence>` advances to
the next entry in `escalation_order`. Interactive retries reuse the child session
and stop before another tier when any side effect was attempted; headless workers
retain their existing bounded redispatch path. Dispatch metrics include the canonical tier,
candidate index, route attempt, reason, and escalation flag for auditing. Pattern-backed
lower-tier optimization is limited to initial automatic selection; when used, the
active tier, variant, retry budget, candidate index, and telemetry follow the model
actually selected. Retry and escalation selectors never cross tier boundaries.

**Worker BLOCKED policy (GH#14964 — MANDATORY):** Emit `BLOCKED: capability limit - <evidence>` only when model capability is the sole remaining blocker; runtime routing then attempts the next configured tier. Use generic `BLOCKED` for evidenced terminal non-capability blockers. Review-policy metadata and nominal GitHub states are not blockers. See `prompts/worker-efficiency-protocol.md` "Model escalation before BLOCKED".

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
