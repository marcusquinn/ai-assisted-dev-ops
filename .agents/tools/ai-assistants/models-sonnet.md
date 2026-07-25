---
description: Balanced model for code implementation, review, and most development tasks
mode: subagent
model: anthropic/claude-sonnet-4-6
model-tier: standard
model-fallback: openai/gpt-5.4
fallback-chain:
  - anthropic/claude-sonnet-4-6
  - openai/gpt-5.4
  - google/gemini-2.5-pro
  - openrouter/anthropic/claude-sonnet-4-6
tools:
  read: true
  write: true
  edit: true
  bash: true
  glob: false
  grep: true
  webfetch: false
  task: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Anthropic Sonnet Model Profile

Concrete model profile that the runtime routing table may select for `standard`
work. Task and agent authors request a workload tier, never this provider family.

## Use For

- Code writing, debugging, review, and test authoring
- Documentation derived from code
- Interactive development tasks

## Routing Rules

- Map this profile into a tier only when current capability, cost, availability,
  and equivalent-workload evidence support it.
- Route bounded classification and formatting through `simple`.
- Route architecture decisions and novel problems through `thinking`.
- Treat large-context requirements as routing evidence, not a provider-named tier.

## Constraints

- Do not use for work classified as `simple` when a cheaper routed model is reliable.
- Do not use for `thinking` work unless the active routing table selects it.

## Model Details

| Field | Value |
|-------|-------|
| Provider | Anthropic |
| Model | claude-sonnet-4-6 |
| Context | 200K tokens (1M beta) |
| Max output | 64K tokens |
| Training cutoff | January 2026 |
| Input cost | $3.00/1M tokens |
| Output cost | $15.00/1M tokens |
| Workload tier | Candidate for `standard` |
