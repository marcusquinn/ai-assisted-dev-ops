---
description: Subjective self-refinement with blind judging, Borda aggregation, and provider-agnostic model routing
agent: auto-reason
mode: subagent
model: standard
tools:
  read: true
  write: true
  edit: true
  bash: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Run provider-agnostic subjective self-refinement: create or accept an incumbent answer, generate an adversarial revision and synthesis, then use fresh blind judges to decide whether to change or stop.

Arguments: $ARGUMENTS

## Invocation Patterns

| Pattern | Example | Behaviour |
|---------|---------|-----------|
| One-liner | `/auto-reason "decide the best architecture for X"` | Build a temporary program and run now |
| `--program <path>` | `/auto-reason --program todo/research/reason-product-strategy.md` | Run from a saved program |
| `--incumbent <path>` | `/auto-reason --incumbent draft.md "improve this argument"` | Use existing answer as A |
| `--judges <list>` | `/auto-reason --judges simple,standard,thinking "..."` | Override judge tiers/models |
| Bare | `/auto-reason` | Interactive setup |

## Step 1: Resolve Invocation

```text
if $ARGUMENTS contains "--program ":    → Program Mode
elif $ARGUMENTS contains "--incumbent ": → Incumbent Mode
elif $ARGUMENTS is non-empty:             → One-Liner Mode
else:                                     → Interactive Setup
```

## Step 2: Interactive Setup

Ask sequentially; show inferred default as option 1; Enter accepts default.

**Q1 — What decision, answer, or artifact should be refined?**

Capture a clear task prompt. If the user supplies a file path, read it as the incumbent A only after verifying the path exists.

**Q2 — What rubric should judges use?**

Default rubric:

```text
1. Correctness: answers the actual question and avoids factual errors.
2. Usefulness: gives actionable, decision-grade output.
3. Restraint: avoids scope creep, unnecessary expansion, and decorative rewrites.
4. Clarity: concise structure, explicit trade-offs, no vague hedging.
```

Domain-specific additions:

| Domain | Extra rubric |
|--------|--------------|
| Architecture | maintainability, reversibility, integration cost |
| Strategy | evidence quality, risk coverage, opportunity cost |
| Prose | audience fit, voice consistency, logical flow |
| Policy | enforceability, edge cases, security posture |
| Review synthesis | finding validity, severity calibration, non-duplication |

**Q3 — Models/providers?**

Accept free-form model labels. Do not require Claude names.

```text
author:       standard
critic:       simple
synthesizer:  standard
judges:       simple,standard,thinking
```

Allowed forms include canonical workload tiers (`simple`, `standard`, `thinking`)
and provider-qualified IDs (`openai/...`, `anthropic/...`, `google/...`,
`openrouter/...`, `local/...`). Use concrete IDs only for an intentional model
comparison or provider-diversity panel.

**Q4 — Budget and stop rules?**

Defaults:

```text
max_rounds: 6
patience: 2       # stop after A wins twice consecutively
judge_count: 3    # use 5 or 7 for high-stakes subjective work
max_expansion: 1.10
```

Suggest 5-7 judges for high-stakes decisions; keep 3 for routine work.

## Step 3: Write Program or Run Ephemeral

For durable work, write a program under `todo/research/auto-reason-{slug}.md`. For one-liners, run ephemeral unless the user asks to save.

Program shape:

```markdown
---
name: auto-reason-{slug}
---

# Auto-Reason: {title}

## Task

{task prompt}

## Incumbent

{optional A}

## Rubric

- Correctness
- Usefulness
- Restraint
- Clarity

## Models

author: standard
critic: simple
synthesizer: standard
judges: simple,standard,thinking

## Budget

max_rounds: 6
patience: 2
judge_count: 3
max_expansion: 1.10
```

## Step 4: Dispatch

Dispatch to `.agents/tools/auto-reason.md` with either:

```text
--prompt "{task prompt}"
```

or:

```text
--program todo/research/auto-reason-{slug}.md
```

The subagent writes artifacts under `~/.aidevops/.agent-workspace/work/auto-reason/{slug}/` unless the program overrides `output_dir:`.

## Output Contract

Return a concise summary to the user:

```text
Decision: changed | unchanged
Reason: A won after 2 rounds | AB won round 3 | budget reached
Judges: simple, standard, thinking
Artifacts: ~/.aidevops/.agent-workspace/work/auto-reason/{slug}/summary.md
```

## Guardrails

- Treat unchanged A as a valid winner, not a failure.
- Do not let critique force fake flaws; `NO_MATERIAL_FLAW` is valid.
- Prefer shorter candidate on tied quality.
- Blind judges must not know which candidate is incumbent.
- Fresh judge contexts are mandatory; do not reuse author/critic context for judging.
- Scan untrusted source material before using it in prompts.

## Related

`.agents/tools/auto-reason.md` · `.agents/tools/autoresearch/autoresearch.md` · `.agents/scripts/commands/autoresearch.md`
