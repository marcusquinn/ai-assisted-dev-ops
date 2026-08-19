---
description: Probing questions for feature tasks — surfaces latent requirements before implementation
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Feature Probes

Use this file as a candidate pool during `/define` for **feature** tasks. Ask only about unanswered points whose resolution could materially change scope, architecture, trust boundaries, user-visible behaviour, or acceptance criteria.

**Defaults** (apply unless overridden): minimal footprint, follow existing patterns, verify new behaviour through the existing production-facing path, no breaking API changes. Do not add tests by default; apply `reference/ci-gate-policy.md`.

## Sufficiency Test

Before generating the brief, verify you can answer all four:

- What does the user see/experience when done?
- What existing code does this touch?
- What would a code reviewer reject?
- What's the one edge case most likely missed?

If an unknown is consequential and repository evidence or a safe default cannot resolve it, ask one targeted question. Otherwise record the assumption when useful and continue.

## Decision-Relevant Candidates

**Scope & Integration** — Where does this feature live in the user's workflow?
Options: Standalone menu/command/button (recommended) · Inline in existing flow · Background automatic · Describe integration point

**Data & State** — Does this feature need to persist state?
Options: No — stateless, computed on demand (recommended) · Yes — local storage/file system · Yes — database/API · Not sure yet

## Optional Probes

**Pre-mortem** — Feature ships, user reports a problem in week one. Most likely complaint?
Options: Inferred from description (recommended) · Performance too slow for large inputs · UI confusing or hard to discover · Conflicts with existing feature

**Backcasting** — Working backwards from "done", what's the last thing you'd verify?
Options: Feature works through the real user/API/CLI path with realistic data (recommended) · Existing required checks pass · Existing features still work · Specify

**Domain Grounding** — Similar features follow [detected pattern]. Should this feature:
Options: Follow the same pattern (recommended — consistency) · Diverge — explain why · Not sure — show me the pattern

**Negative Space** — What makes a technically correct implementation unacceptable?
Options: Too slow (>Xs response time) · Requires migration or breaking change · Adds significant bundle size/dependencies · Nothing — correctness is sufficient

**Outside View** — Features of this scope typically take [estimated time]. Match your expectation?
Options: Yes — about right · No — should be simpler (~Xh) · No — more complex (~Xh) · No estimate yet
