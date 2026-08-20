---
description: Run thematic query fan-out research for AI search coverage planning
agent: SEO
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Run fan-out research for:

Target: $ARGUMENTS

## Process

1. Read `~/.aidevops/agents/seo/conversational-search-intent.md` and normalize
   ambiguous, conversational, trend-led, or log-derived inputs with provenance
2. Read `~/.aidevops/agents/seo/query-fanout-research.md`
3. Generate thematic branches and prioritized sub-queries
4. Map existing pages to branch coverage
5. Produce remediation backlog for missing/partial high-priority branches

## Usage

```bash
# Fan-out map for one intent
/seo-fanout "best personal injury lawyer chicago"

# Fan-out map for a domain and intent cluster
/seo-fanout "example.com personal injury services"
```

## Related

- `seo/conversational-search-intent.md`
- `seo/query-fanout-research.md`
- `commands/seo-geo.md`
- `commands/seo-ai-readiness.md`
