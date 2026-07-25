---
description: Probing questions for refactor tasks — surfaces behaviour preservation constraints and migration risks
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Refactor Probes

Use this file as a candidate pool during `/define` for **refactor** tasks. Ask only when an unanswered point can materially change scope, behaviour-preservation boundaries, migration risk, or acceptance criteria.

**Defaults** (apply unless overridden): zero behaviour changes, all existing tests pass unchanged, no new dependencies, improve one primary goal (readability/maintainability/performance), no tests → add before refactoring.

## Decision-Relevant Candidates

**Primary Goal** — What's the main reason for this refactor?
1. Readability — code is hard to understand or maintain (recommended)
2. Performance — current implementation is too slow
3. Extensibility — need to add features and current structure blocks it
4. Duplication — same logic exists in multiple places
5. Let me explain

**Scope Boundary** — How far should this refactor go?
1. Minimal — only the specific file/function mentioned (recommended)
2. Module-level — refactor the entire module for consistency
3. Cross-cutting — follow the pattern change across the codebase
4. Let me specify the boundary

## Optional Probes

**Behaviour Preservation** — How will you verify that behaviour hasn't changed?
1. Existing tests cover it — they must all pass (recommended)
2. No tests exist — I'll add them before refactoring
3. Manual testing against specific scenarios
4. Type system / compiler will catch regressions

**Outside View** — Refactors of this scope typically follow [detected pattern]. Should this refactor:
1. Follow the same approach (recommended — consistency)
2. Establish a new pattern — here's why: [user explains]
3. I'm not sure what the existing pattern is

**Pre-mortem** — Refactor is merged and something breaks in production. Most likely cause?
1. A code path that wasn't covered by tests (recommended)
2. Subtle behaviour change in edge cases
3. Performance regression under load
4. Downstream consumers that depend on internal implementation details

**Assumption Surfacing** — This refactor should NOT change the public API / interface. Correct?
1. Correct — internal changes only (recommended)
2. No — the API should change too (this might be a feature, not a refactor)
3. The API can change if callers are updated in the same PR

**Domain Grounding** — The [language/framework] community typically recommends [pattern] for this kind of restructuring. Does that apply here?
1. Yes — follow the standard approach (recommended)
2. Partially — adapt it because [reason]
3. No — this codebase has its own conventions

## Sufficiency Test

Before generating the brief, confirm you can answer:
- What tests exist for the code being refactored?
- What's the public API that must not change?
- What's the primary metric that improves (readability/performance/extensibility)?
- What would a reviewer check to verify behaviour preservation?

Ask one targeted question only when an unknown is consequential and repository evidence or a safe default cannot resolve it.
