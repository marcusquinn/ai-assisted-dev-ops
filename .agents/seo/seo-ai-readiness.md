---
description: Run end-to-end AI search readiness workflow across GEO, SRO, fan-out, consistency, and discoverability
agent: SEO
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Run AI search readiness workflow for:

Target: $ARGUMENTS

## Process

1. Read `~/.aidevops/agents/seo/ai-search-readiness.md`
2. Execute chained phases:
   - Conversational search-intent evidence and grounding classification
   - Fan-out decomposition
   - GEO criteria alignment
   - Page-type tactic weighting for PDP, category, homepage, article, local,
     SaaS feature, pricing, comparison, glossary, use-case, and
     research/report pages
   - SRO snippet optimization
   - Hallucination defense
   - Agent discoverability validation
3. Score material recommendations with `~/.aidevops/agents/seo/ai-search-scoring.md`
4. Return report-ready output using `~/.aidevops/agents/seo/ai-search-report-template.md`:
   executive summary, method, weighted scorecard, page-type findings, evidence
   ledger, roadmap, verification, and custom-agent/routine handoff
5. Require source IDs for material recommendations and show AIO, Gemini,
   ChatGPT, AI Mode, and Perplexity as per-engine lines before any aggregate
   visibility summary

## Usage

```bash
# Full readiness cycle for a domain
/seo-ai-readiness example.com

# Full cycle for priority pages
/seo-ai-readiness "example.com /pricing /services/injury-law /about"
```

## Related

- `seo/conversational-search-intent.md`
- `seo/ai-search-readiness.md`
- `seo/ai-search-scoring.md`
- `seo/ai-search-report-template.md`
- `seo/seo-audit-skill/aeo-geo-patterns/04-page-type-tactic-matrix.md`
- `commands/seo-fanout.md`
- `commands/seo-geo.md`
- `commands/seo-sro.md`
- `commands/seo-hallucination-defense.md`
- `commands/seo-agent-discovery.md`
- `seo/video-seo.md` — video readiness for LLM answer engine surfaces
