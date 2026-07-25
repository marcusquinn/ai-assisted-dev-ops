---
description: Lightweight model for triage, classification, and simple transforms
mode: subagent
model: anthropic/claude-haiku-4-5-20251001
model-tier: simple
model-fallback: google/gemini-2.5-flash-preview-05-20
fallback-chain:
  - anthropic/claude-haiku-4-5-20251001
  - google/gemini-2.5-flash-preview-05-20
  - openrouter/anthropic/claude-haiku-4-5
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: false
  grep: false
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Anthropic Haiku Model Profile

Concrete model profile that the runtime routing table may select for `simple`
work. Task and agent authors request a workload tier, never this provider family.

## Routing Rules

- Map this profile only into `simple` when current cost, availability, and
  equivalent-workload evidence support it.
- Route implementation and review work through `standard`.
- Route architecture decisions and novel problems through `thinking`.

## Use For

- Classification and triage (bug vs feature, priority assignment)
- Simple text transforms (rename, reformat, extract fields)
- Commit message generation from diffs
- Routing decisions (which subagent to use)

## Constraints

- Keep responses under 500 tokens when possible.
- Do not attempt unresolved implementation or architecture decisions — escalate
  to `standard` or `thinking`.
- Prioritize speed over thoroughness.

## Model Details

| Field | Value |
|-------|-------|
| Provider | Anthropic |
| Model | claude-haiku-4-5 |
| Context | 200K tokens |
| Max output | 64K tokens |
| Training cutoff | July 2025 ([Anthropic models overview](https://docs.anthropic.com/en/docs/about-claude/models)) |
| Input cost | $1.00/1M tokens |
| Output cost | $5.00/1M tokens |
| Workload tier | Candidate for `simple` |
