---
description: Write SEO-optimized long-form content with keyword integration
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Topic/Keyword: $ARGUMENTS

## Workflow

1. **Research**: Determine search intent for the target keyword

   ```bash
   python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py intent "$ARGUMENTS"
   ```

2. **Context**: Check for project context files; read any that exist before writing

   ```bash
   ls context/brand-voice.md context/style-guide.md context/internal-links-map.md context/target-keywords.md 2>/dev/null
   ls .aidevops/context/brand-voice.md .aidevops/context/style-guide.md 2>/dev/null
   ```

3. **Write**: Follow `content/seo-writer.md` guidelines:
   - 2,000-3,000+ words
   - Primary keyword in H1, first 100 words, 2-3 H2s
   - 1-2% keyword density
   - 3-5 internal links, 2-3 external links
   - Meta title (50-60 chars) and description (150-160 chars)
   - Grade 8-10 reading level

4. **Analyze**: Run content analysis and fix any critical issues

   ```bash
   python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py analyze draft.md \
     --keyword "primary keyword" --secondary "kw1,kw2"
   ```

5. **Output**: Save to `drafts/[topic]-[date].md` or current directory

## Related

- `content/seo-writer.md` — Writing guidelines
- `content/humanise.md` — Final product-copy pass after metadata and link adaptation
- `seo/content-analyzer.md` — Analysis details
- `seo/transcript-seo.md` — Convert video/audio transcripts into SEO-optimised articles
