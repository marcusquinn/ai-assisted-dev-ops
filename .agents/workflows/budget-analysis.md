---
description: Analyse budget feasibility and recommend tiered outcomes
agent: Build+
mode: subagent
model: simple
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

## Modes

Run `~/.aidevops/agents/scripts/budget-analysis-helper.sh` with:

- `analyse --budget <USD> [--hours <H>] --json` — comparison table: tokens,
  tasks, and messages at `simple`/`standard`/`thinking` workload tiers
- `recommend --goal "<description>" --json` — three tiers (MVP, Production-Ready, Polished) with costs, time, and inclusions
- `estimate --task "<description>" [--tier <tier>] --json` — estimate range (0.5x-2x) and alternative tier costs; recommend tier if unspecified
- `forecast --days <N> --json` — spend forecast with confidence interval; warn if <7 days history

## Presentation Guidelines

- Costs in USD (2 decimal places); tokens with thousand separators.
- Be direct: "I recommend Tier 2 (Production-Ready) because...".
- Calibrate against historical spend patterns; flag high uncertainty.
- `/mission` integration: run `recommend` first, then `analyse` with chosen budget.
