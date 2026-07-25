---
description: Provider-agnostic subjective self-refinement loop with blind judging, Borda aggregation, and a first-class do-nothing option
mode: subagent
model: standard
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: false
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Auto-Reason Subagent

Runs subjective-domain self-refinement: incumbent answer A → adversarial revision B → synthesis AB → fresh blind judge panel → Borda winner → repeat until A wins enough times or budget ends.

Arguments: `--prompt <text>` or `--program <path>`.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Use for**: subjective reasoning, strategy, prose, architecture, policy, review synthesis, ambiguous decisions.
- **Do not use for**: deterministic code optimization with numeric metrics; use `/auto-research` or `/autoresearch` for that.
- **Core rule**: keeping the incumbent unchanged is always a first-class candidate.
- **Provider stance**: provider/model strings are free-form; never assume Claude-only APIs.
- **Output**: final answer, round ledger, judge ledger, convergence reason, dissent notes.

<!-- AI-CONTEXT-END -->

## Method

Inspired by NousResearch/autoreason's public README: iterative refinement fails when critique prompts force hallucinated flaws, revisions expand scope, and the loop never stops. This agent prevents that by comparing three candidates every round:

| Candidate | Meaning | Constraint |
|-----------|---------|------------|
| A | incumbent answer, unchanged | Must remain eligible to win |
| B | adversarial revision | Must improve a specific flaw without scope creep |
| AB | synthesis | Must merge only demonstrable improvements from B into A |

Fresh judges rank A/B/AB blind. Aggregate rankings with Borda count. If A wins `patience` rounds, stop with no further changes.

## Step 0: Parse Arguments

Accept either direct prompt mode or program-file mode.

| Variable | Source | Default |
|----------|--------|---------|
| `TASK_PROMPT` | `--prompt` or program `## Task` | required |
| `RUBRIC` | program `## Rubric` | correctness, usefulness, restraint, clarity |
| `PROVIDERS` | program `## Models` | runtime workload tiers or explicit benchmark models |
| `AUTHOR_MODEL` | `author:` | `standard` |
| `CRITIC_MODEL` | `critic:` | `simple` |
| `SYNTHESIZER_MODEL` | `synthesizer:` | `standard` |
| `JUDGE_MODELS` | `judges:` comma list | `simple,simple,standard` |
| `JUDGE_COUNT` | `judge_count:` | length of `JUDGE_MODELS`, minimum 3 |
| `PATIENCE` | `patience:` | 2 A-wins |
| `MAX_ROUNDS` | `max_rounds:` | 6 |
| `MAX_EXPANSION` | `max_expansion:` | 1.10× incumbent length |
| `OUTPUT_DIR` | `output_dir:` | `~/.aidevops/.agent-workspace/work/auto-reason/{slug}` |

Provider/model values may be canonical workload tiers or provider-qualified
identifiers used for an intentional comparison:

```text
simple
standard
thinking
openai/gpt-5.5
anthropic/claude-sonnet-4-6
google/gemini-pro
openrouter/deepseek-r1
local/ollama-qwen3
```

Treat workload tiers as the normal authoring interface. Runtime routing resolves
them for the active runtime, `ai-research` tool, MCP model router, or future model
adapter. Do not hardcode provider SDK syntax in this agent doc.

## Step 1: Establish Incumbent A

If the program supplies `## Incumbent`, use it as A. Otherwise call `AUTHOR_MODEL` once to produce A from `TASK_PROMPT` and `RUBRIC`.

Store:

```text
round_00_incumbent.md
ledger.jsonl  # event=start, model, prompt hash, output path
```

## Step 2: Refinement Round

For each round:

1. **Critic** receives only `TASK_PROMPT`, `RUBRIC`, and A. It must identify at most 3 concrete flaws and may answer `NO_MATERIAL_FLAW`.
2. **Author B** receives the critic output and A. It creates a challenger that fixes only cited flaws.
3. **Synthesizer AB** receives A, B, and critique. It merges improvements while preserving A's correct material.
4. **Length/scope guard** rejects B or AB when they exceed `MAX_EXPANSION` without an explicit rubric reason.
5. **Blind judge packet** anonymizes candidates as X/Y/Z with randomized order per judge.

Critic anti-bias rule: a critic is allowed to say no material flaw exists. A forced criticism is lower-quality than restraint.

## Step 3: Blind Judge Panel

Each judge is a fresh context with no round history. Give only:

- original task
- rubric
- anonymized candidates
- instruction to rank all candidates and explain decisive differences

Judge output schema:

```json
{
  "ranking": ["Y", "X", "Z"],
  "scores": {"X": 2, "Y": 3, "Z": 1},
  "reason": "...",
  "red_flags": ["scope creep in Z"]
}
```

Use Borda aggregation: 3 points for first, 2 for second, 1 for third. For ties, prefer the shortest candidate, then A, then AB, then B. This makes restraint the default when quality is indistinguishable.

## Step 4: Convergence and Stop Rules

Stop when any condition holds:

- A wins `PATIENCE` consecutive rounds.
- `MAX_ROUNDS` reached.
- All judges flag B and AB as scope creep.
- Critic returns `NO_MATERIAL_FLAW` and A wins the same round.
- Budget or runtime limit reached.

If A wins, keep A exactly. Do not rewrite for style.

## Step 5: Output Artifacts

Write a compact artifact bundle:

```text
auto-reason-{slug}/
  final.md
  round-ledger.jsonl
  judge-ledger.jsonl
  candidates/
    r01-A.md
    r01-B.md
    r01-AB.md
  summary.md
```

`summary.md` must include:

- convergence reason
- final candidate lineage
- judge vote table
- strongest dissent
- whether output changed from the initial incumbent
- provider/model mix used

## Provider Diversity Guidance

Prefer at least two independent model families in the judge panel when available. Example:

```text
author: openai/gpt-5.5
critic: anthropic/claude-haiku-4-5
synthesizer: openai/gpt-5.5
judges: anthropic/claude-haiku-4-5,google/gemini-pro,openai/gpt-5.5
```

If only one provider is configured, proceed with same-provider fresh contexts and state the limitation in `summary.md`.

## Relationship to Other Research Commands

| Command | Purpose | Stop criterion |
|---------|---------|----------------|
| `/auto-reason` | subjective answer refinement | blind judges choose A or budget ends |
| `/auto-research` / `/autoresearch` | code/agent experiment loop | numeric metric improves |
| `/deep-research` | cited research deliverable | source/claim coverage complete |

## Related

`.agents/scripts/commands/auto-reason.md` · `.agents/tools/autoresearch/autoresearch.md` · `.agents/research.md`
