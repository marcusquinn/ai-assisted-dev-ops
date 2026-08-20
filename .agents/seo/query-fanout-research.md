---
name: query-fanout-research
description: Model thematic fan-out sub-queries and map content coverage across priority intent clusters
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Query Fan-Out Research

- **Purpose**: expose hidden sub-query themes behind one user intent
- **Inputs**: normalized intent packet, market context, existing page set, source IDs
- **Outputs**: fan-out map, priority tiers, coverage matrix, remediation backlog
- **Retrieval model**: broad discovery → domain deep-dive → third-party validation

## Workflow

**0) Normalize the seed** — when the input is conversational, ambiguous,
trend/news-led, or log-derived, use `conversational-search-intent.md` to preserve
the raw query and identify the user job, outcome, constraints, provenance, and
grounding hypothesis. If no observed evidence exists, label the seed as a
hypothesis.

**1) Build theme branches** — one core intent → 3-7 branches (selection criteria, trust, risk, alternatives, constraints). Each branch is a distinct retrieval objective.

**2) Generate sub-queries** — write sub-queries per branch with a purpose tag; assign priority (high/medium/low); include modifiers where relevant (location, budget, urgency, compliance, integration).

**3) Classify retrieval stage and scope** — frontier models generate 10+ sub-queries per prompt, including `site:` lookups. Treat fan-out as 3 stages:

1. **Broad discovery**: open-web category/comparison queries (e.g. `best ATS for SMB [year]`)
2. **Domain deep-dive**: `site:brand.com` queries (e.g. `site:brand.com pricing`)
3. **Third-party validation**: `site:g2.com`, `site:capterra.com`, `site:trustradius.com` — independent corroboration

| Scope | Meaning |
|-------|---------|
| **Open-web** | Model uncommitted to a domain; SERP ranking matters |
| **Domain-scoped** | Model extracting detail from a chosen domain; page architecture > SERP position |
| **Third-party** | Model seeking corroboration from review platforms |

Predict stages before content work: product-detail branches → stage 2; trust/risk branches → stage 3.

**4) Map coverage** — link each sub-query to the best existing page or proof source; mark coverage (complete/partial/missing); flag overloaded pages; branch is incomplete if your site covers it but review-platform evidence does not.

**5) Remediate and validate** — add concise sections for partial high-priority branches; create focused pages only for genuinely missing high-priority branches; add internal links mirroring fan-out relationships; re-run fan-out prompts and stage-specific retrieval checks; record match quality, citation mix changes, and unresolved branches for the next sprint.

## Coverage Rules

- Domain-scoped branches need individually addressable pages with self-contained answers (model queries your site like a database)
- Pages should match `site:yourdomain.com [category] [feature] [year]` patterns
- Third-party branches need current review-platform profiles with canonical facts matching the primary site

## Guardrails

- Optimize for thematic completeness, not maximal query count
- Keep generated branches separate from observed demand until corroborated by
  search metrics, first-party language, or other dated evidence
- Avoid duplicate pages for near-identical branches
- Keep branch language aligned with real user phrasing
- Re-baseline when SERP intent or product positioning changes

## Related Subagents

- `conversational-search-intent.md` — normalize intent and preserve provenance
- `geo-strategy.md` — criteria-led optimization strategy
- `sro-grounding.md` — snippet and selection tuning
- `keyword-mapper.md` — keyword-to-section placement
