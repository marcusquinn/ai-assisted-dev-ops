---
description: Canonical purpose and decision criteria for AI DevOps
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: false
  glob: true
  grep: true
  webfetch: false
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# AI DevOps Purpose

This document owns the framework's operating purpose and the decisions that
follow from it. Entry points should retain only the applicable invariant and a
pointer here rather than copy this policy.

## Purpose

Aidevops layers value and automation onto information flows. It is not a Q&A
entertainment product: work in every covered domain can be codified,
systemised, and improved with DevOps principles and tool leverage.

The aim is to compound user value without compounding their time, supervision,
or attention. Time and money are the ultimate value measures; token use, tool
calls, checks, and task counts are supporting diagnostics. Helping a user become
100x more capable at value generation is an ambition to substantiate, not a
guaranteed or measured result.

## Ownership and continuity

Tasks, TODOs/Beads, plans, material decisions, evidence, and progress belong in
durable repository knowledge. GitHub, GitLab, Gitea, and Forgejo provide
portable execution conversations; they must not be the only record of plans or
progress. This is the intended ownership contract, not a claim that every
forge-loss recovery path is already proven; `t18404` owns that validation and
any implementation gaps.

Build+ is the default for development, systems, and apps. Domain primaries add
focus rather than define a weaker class of work. Delegation may use a relevant
primary or a lighter profile with narrower scope, while retaining the same
applicable safety, authority, and verification boundaries. No covered
non-coding domain is outside DevOps.

## Decision criteria

- Preserve hard-won lessons, provenance, and intentional boundary reinforcement.
  Improve delivery and activation rather than reducing knowledge volume or
  instruction counts for their own sake.
- Make organisational sources of truth structural: explicit ownership, generated
  views, consistency checks, and verified migration or fallback behaviour—not
  reminders to update copied prose.
- Keep repository knowledge and forge conversations distinct but linked, so a
  forge can be replaced without redefining the work's identity or authority.
- Use model judgment for prioritisation, economics, semantic decisions, and
  trade-offs. Use deterministic tooling for reproducible mechanics and
  invariants.

See `.agents/aidevops/architecture.md` for framework structure and
`.agents/reference/self-improvement.md` for the operating lifecycle that applies
these criteria during ordinary work.
