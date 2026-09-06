<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Context efficiency without guidance loss

Optimise verified outcomes per resource budget, not cache percentage or prompt
length in isolation. Framework guidance is hard-won: preserve its meaning,
authority, safety constraints and availability. Load full domain instructions
when their trigger applies; never remove them merely to meet a token target.

## OpenCode loading contract

- `context-catalogue.mjs` shares the identical explicit-request trigger for
  generated aidevops command-skill wrappers. Every name and source location stays
  advertised; full skill bodies, discovery and invocation permissions are unchanged.
  Specialist descriptions, custom triggers, extra metadata and unknown formats
  stay verbatim. This is deterministic lossless metadata factoring, not a keyword
  classifier deciding which guidance an agent deserves to see.
- Only separately supplied `Instructions from:` system blocks with byte-identical
  bodies share an already loaded copy. Differing scoped instructions remain intact,
  including whitespace differences. Provenance and applicability remain explicit.
  Native Read reminders are not stripped; their ordering relative to plugin hooks
  is a separate runtime boundary. No stored conversation history is rewritten.
- OpenAI/non-Anthropic one-shot startup guidance follows the durable system prefix.
  The greeting text, authority and root-session-only gate are unchanged. Anthropic
  compatibility ordering is deliberately untouched.
- Keep stable instruction/tool ordering. Do not add timestamps, per-request
  randomness, or quota state ahead of reusable guidance. Do not force cache
  retention parameters onto an OAuth endpoint without validating support.
- Successful verbose test/build receipts already use `output-compaction.mjs`.
  Do not discard failure diagnostics or blindly summarise source files. Read
  targeted ranges and load retained evidence when needed.

## Astra compaction

`registerAstraContextLimits` defaults to 400,000 usable input tokens. To opt into
a lower budget, run `aidevops astra-context enable`: it persists a 240,000 target
and enables the managed Astra cap. `aidevops astra-context disable` restores the
400,000 target, preserving an existing native-metadata opt-out. `status` reports
the selection and nonce-bound fresh-process plugin/config evidence; unavailable,
old or failed probes are not reported as applied. If automatic compaction is
disabled in OpenCode, status reports that separately.

With OpenCode's default 20,000-token reserve, 240K advertises input 260,000;
400K advertises input 420,000. Managed context also accommodates output.
An explicit `compaction.reserved` (including zero) is honoured without changing
the global setting. GPT-5.6 retains its separate ~240K target. These are operational
budgets, not provider capacity claims or measured subscription savings. Earlier
compaction may add summary overhead and lose information; judge total outcomes.

Set `runtime.opencode.astra_context_cap` to `false` in aidevops settings to leave
Astra metadata untouched; `enable` explicitly clears that opt-out. The target is
stored separately as `runtime.opencode.astra_compaction_target` and survives normal
updates. Restart OpenCode after changing the selection or deploying plugin changes.
The running process retains its original loaded plugin/config. Custom upstream
output-token ceilings can affect the default reserve; an explicit reserve makes
the arithmetic unambiguous. Compaction can occur slightly beyond the target due
to a completed response/tool step; do not issue synthetic 400K-token paid requests
merely to verify this arithmetic.

## Efficiency scorecard

Run `/report-token-use efficiency --since 7d` or the helper's `efficiency`
subcommand; add `--json` for the full evidence contract. It queries SQLite in
read-only mode and never rewrites historical costs. It includes reasoning,
median/p95 prompt sizes by model/effort, current-table repricing, historical price
versions, routing observation coverage and parent-plus-child session families.
Session output uses fingerprints rather than titles, paths or raw session IDs.

Cache hits remain billable for many APIs. A smaller useful prompt may reduce the
hit percentage while saving money. API-equivalent estimates are not subscription
allowance measurements or invoices; long-context/service-tier uplifts are outside
the flat pricing table. Unknown prices and verified completion stay unavailable
until authoritative evidence exists. Do not label host termination as success.

Compare matched task classes with parent and child work included: accepted result,
repair/escalation, human intervention, elapsed time and consistently priced tokens.
Retain the previous route if cheaper calls create extra repair or lose required
guidance. Existing lean-delegation rules remain in `reference/agent-routing.md`.
