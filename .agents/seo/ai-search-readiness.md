---
name: ai-search-readiness
description: "Orchestrate end-to-end AI search readiness across seven phases: grounding eligibility, query decomposition, criteria alignment (GEO), snippet survivability (SRO), integrity hardening, autonomous discoverability, and citation monitoring."
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

# AI Search Readiness

Run a complete, high-signal workflow to improve AI search citations and answer quality.

## Quick Reference

- **Inputs**: target intents, priority pages, fact inventory, competitor set
- **Outputs**: prioritized fixes with measurable readiness deltas
- **Scorecard**: `seo/ai-search-kpi-template.md`
- **Cadence**: monthly baseline; sprint-level re-tests after content changes

## Execution Sequence

| Phase | Name | Action |
|-------|------|--------|
| 0 | Intent evidence and grounding gate | `conversational-search-intent.md` → normalize user jobs, provenance, constraints, and grounding likelihood; validate crawler/bot accessibility via `site:yourdomain.com [category]` checks |
| 1 | Query decomposition | `query-fanout-research.md` → thematic branches and sub-query map per intent |
| 2 | Criteria alignment | `geo-strategy.md` → criteria matrix and page-level strong/partial/missing coverage map |
| 3 | Snippet survivability | `sro-grounding.md` → top-of-page and sentence-level changes that improve selection likelihood |
| 4 | Integrity hardening | `ai-hallucination-defense.md` → contradiction fixes, claim-evidence alignment, canonical fact hygiene |
| 5 | Autonomous discoverability | `ai-agent-discovery.md` → task-completion diagnostics and discoverability gap remediation |
| 6 | Citation and volatility monitoring | Track citation frequency by intent cluster; audit third-party profiles (G2/Capterra/TrustRadius) quarterly; use UTM-tagged links for measurable citation sessions |

## Readiness Scorecard

| Metric | Definition |
|--------|-----------|
| Fan-out coverage | % of high-priority branches fully covered |
| Grounding eligibility | % of target intents likely to trigger retrieval |
| Criteria coverage | % of required criteria marked strong |
| Snippet fitness | % of intents with high-quality selected snippets |
| Fact integrity | Count of critical contradictions unresolved |
| Discovery success | % of tasks completed by autonomous exploration |
| Citation stability | Variance in citation frequency over repeated runs |
| Site-query readiness | % of priority pages retrievable via `site:yourdomain.com [category]` |
| Third-party profile currency | % of review platform profiles updated within last 90 days |

## Prioritization Rules

- Fix critical fact contradictions before expanding content
- Prioritize pages that already rank and convert
- Prefer focused section updates before creating new URLs
- Keep evidence traceable for every important claim
- Re-validate key pages after major model updates or indexing shifts
