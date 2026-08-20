---
description: Run GEO strategy workflow for AI search visibility
agent: SEO
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Run GEO strategy for:

Target: $ARGUMENTS

## Process

1. Read `~/.aidevops/agents/seo/conversational-search-intent.md` and establish
   the intent ledger, provenance, constraints, and grounding hypotheses
2. Read `~/.aidevops/agents/seo/geo-strategy.md`
3. Build criteria coverage matrix for target intents/pages
4. Identify strong/partial/missing criteria with evidence references
5. Produce prioritized implementation plan for retrieval-first improvements

## Usage

```bash
# GEO strategy for a domain
/seo-geo example.com

# GEO strategy for specific page set
/seo-geo "example.com /services/injury-law /services/work-accident"
```

## Related

- `seo/conversational-search-intent.md`
- `seo/geo-strategy.md`
- `commands/seo-sro.md`
- `commands/seo-fanout.md`
- `seo/transcript-seo.md` — transcript paragraphs as GEO snippet candidates for video/audio content
