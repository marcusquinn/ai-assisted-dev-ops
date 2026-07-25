---
description: Dispatch the same prompt to multiple AI models, diff results, and optionally auto-score via a judge model
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

## Usage

```bash
~/.aidevops/agents/scripts/compare-models-helper.sh cross-review \
  --prompt "your prompt here" \
  [--models "provider/model-a,provider/model-b"] \
  [--score] [--judge thinking]
```

Present response summaries, diff (2-model), judge scores+winner if `--score` used, note failures. Scores → model-comparisons DB → `/route`, `/patterns`.

For broad evaluation, compare the same prompt, context, tools, timeout, and
verification across concrete models configured in one workload tier. With no
`--models`, the helper loads every model from the active `standard` routing tier.
Use an explicit cross-tier list only when the research question is the capability
boundary itself, and label that result as non-like-for-like.

## Options

| Option | Default | Description |
|--------|---------|-------------|
| `--models` | configured `standard`-tier models | Comma-separated fully qualified model IDs or canonical tiers |
| `--score` | off | Auto-score outputs via judge model |
| `--judge` | `thinking` | Judge workload tier or explicit model (used with `--score`) |
| `--timeout` | `600` | Seconds per model |
| `--output` | auto | Directory for raw outputs |
| `--workdir` | `pwd` | Working directory for model context |

## Scoring Criteria (judge model, 1-10)

`correctness` · `completeness` · `quality` · `clarity` · `adherence`

## Examples

```bash
# Compare all configured standard-tier models on a code review task
/cross-review "Review this function for bugs and suggest improvements: $(cat src/auth.ts)"

# Explicit cross-tier comparison of a capability boundary (not like-for-like)
/cross-review "Design a rate limiting strategy for a REST API" \
  --models standard,thinking --score

# Explicit same-tier concrete-model comparison with custom timeout
/cross-review "Summarize the key changes in this diff" \
  --models openai/gpt-5.6-sol,anthropic/claude-sonnet-4-6 --timeout 120

# View scoring results after a cross-review
/score-responses --leaderboard
```

## Related

- `/compare-models` — Compare model capabilities and pricing (no live dispatch)
- `/score-responses` — View and manage response scoring history
- `/route` — Get model routing recommendations based on pattern data
- `/patterns` — View model performance patterns
