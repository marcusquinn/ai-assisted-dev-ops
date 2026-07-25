---
description: Probing questions for documentation tasks — surfaces audience, accuracy, and maintenance concerns
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Docs Probes

Use this candidate pool for `/define` tasks classified as **docs**. Reuse known audience and format context; ask only when an answer could materially change scope, reader outcome, accuracy verification, or acceptance criteria.

## Defaults

- Follow existing documentation patterns and style in the project
- Accurate and verifiable — no speculative claims
- Concise — prefer examples over lengthy explanations
- Maintainable — don't document implementation details that change frequently

## Decision-Relevant Candidates

**Audience** — Who is the primary reader?
1. Developers using this project (recommended)
2. Contributors to this project
3. End users (non-technical)
4. AI agents / automated systems

**Format** — What format should this take?
1. Inline code comments / docstrings
2. Markdown file (README, guide, reference) (recommended)
3. API documentation (OpenAPI, JSDoc, etc.)
4. Tutorial / walkthrough with examples

## Optional Probes

**Accuracy Verification** — How will you verify the documentation is accurate?
1. Run the examples / commands described (recommended)
2. Cross-reference with source code
3. Review by someone who uses the feature
4. It's conceptual — accuracy is about clarity, not runnable examples

**Staleness Risk** — How likely is this documentation to become stale?
1. Low — documents stable interfaces or concepts (recommended)
2. Medium — documents features that evolve quarterly
3. High — documents implementation details that change frequently
4. Not sure

**Negative Space** — Most common mistake someone would make after reading this?
1. Misunderstanding the scope — thinking it covers more than it does
2. Missing a prerequisite or setup step
3. Using an outdated example
4. Nothing obvious — the topic is straightforward

**Backcasting** — After reading this, what should the reader be able to do?
1. [Inferred from task description] (recommended)
2. Understand the concept but not necessarily implement it
3. Follow step-by-step to a working result
4. Let me specify the learning outcome

## Sufficiency Test

Before generating the brief, verify you can answer:
- Who reads this and what do they need to do afterwards?
- What existing docs does this complement or replace?
- How will accuracy be verified?
- What's the maintenance burden?

Ask one targeted question only when an unknown is consequential and source evidence or a safe default cannot resolve it.
