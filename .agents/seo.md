---
name: seo
description: SEO and GEO analysis - search intent, keyword research, Search Console, and site crawling
mode: subagent
subagents:
  - keyword-research
  - conversational-search-intent
  - google-search-console
  - gsc-sitemaps
  - dataforseo
  - serper
  - ahrefs
  - semrush
  - site-crawler
  - screaming-frog
  - eeat-score
  - contentking
  - domain-research
  - pagespeed
  - google-analytics
  - data-export
  - ranking-opportunities
  - analytics-tracking
  - rich-results
  - debug-opengraph
  - debug-favicon
  - programmatic-seo
  - image-seo
  - moondream
  - upscale
  - content-analyzer
  - seo-optimizer
  - keyword-mapper
  - geo-strategy
  - sro-grounding
  - query-fanout-research
  - ai-hallucination-defense
  - ai-agent-discovery
  - ai-search-readiness
  - general
  - explore
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# SEO - Main Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Tools**: Google Search Console, Ahrefs, Semrush, DataForSEO, Serper, PageSpeed Insights, Google Analytics, Context7
- **MCP**: GSC, DataForSEO, Serper, Google Analytics, Context7
- **Commands**: `/keyword-research`, `/autocomplete-research`, `/keyword-research-extended`, `/seo-export`, `/seo-analyze`, `/seo-opportunities`, `/seo-write`, `/seo-optimize`, `/seo-analyze-content`, `/seo-fanout`, `/seo-geo`, `/seo-sro`, `/seo-hallucination-defense`, `/seo-agent-discovery`, `/seo-ai-readiness`, `/seo-ai-baseline`

**Subagents** (`seo/` and `services/analytics/`):

- **Research**: `conversational-search-intent` (user jobs, query forms, provenance, trends) | `keyword-research` (SERP weakness, 17 types, KeywordScore 0-100) | `ranking-opportunities` (quick wins, striking distance, cannibalization) | `query-fanout-research` (thematic fan-out) | `keyword-mapper` (placement/density) | `domain-research`
- **Data providers**: `google-search-console` (queries, performance, index) | `dataforseo` (SERP, keywords, backlinks, on-page REST API) | `serper` (Google Search API) | `ahrefs` (backlinks, DR, REST API v3) | `semrush` (domain analytics, competitor research)
- **Analytics**: `google-analytics` (GA4 reporting) | `analytics-tracking` (GA4 setup, events, UTM, attribution)
- **Technical**: `site-crawler` (links, meta, redirects) | `screaming-frog` (SEO Spider CLI) | `contentking` (real-time monitoring) | `pagespeed`
- **Content**: `content-analyzer` (readability, keywords, quality) | `seo-optimizer` (on-page audit) | `eeat-score` (7 criteria, 1-10) | `programmatic-seo` (pages at scale)
- **AI search**: `geo-strategy` (criteria extraction, retrieval-first) | `sro-grounding` (snippet selection) | `ai-hallucination-defense` (claim-evidence audits) | `ai-agent-discovery` (discoverability) | `ai-search-readiness` (end-to-end orchestration)
- **Media/debug**: `image-seo` (alt text, Moondream) | `upscale` | `moondream` | `rich-results` (browser automation) | `debug-opengraph` | `debug-favicon`
- **Export**: `data-export` (GSC, Bing, Ahrefs, DataForSEO → TOON) | `gsc-sitemaps` (Playwright submission)

**Content analysis** ([SEO Machine](https://github.com/TheCraigHewitt/seomachine)): `seo-content-analyzer.py {analyze|readability|keywords|quality|intent} <file|query> [--keyword "kw"]`

<!-- AI-CONTEXT-END -->

## SEO Workflow

**Keyword and intent research**: Frame ambiguous, conversational, market, trend, or log-derived seeds with `seo/conversational-search-intent.md`, then run `/keyword-research "seed"` | `/autocomplete-research "question"` | `/keyword-research-extended "top keywords"`. Domain/Competitor/Gap modes: `seo/keyword-research.md`. GSC query evidence: `seo/google-search-console.md`.

**AI search (GEO/SRO)**: intent evidence → baseline → fanout → GEO → SRO → hallucination defense → agent discovery. Focus: deterministic retrieval signals (clarity, structure, consistency, discoverability). Scorecard: `seo/ai-search-readiness.md`.

**SERP/backlinks/technical**: SERP via DataForSEO (comprehensive) or Serper (quick) | Backlinks via DataForSEO or Ahrefs | PageSpeed/CWV: `tools/browser/pagespeed.md` | On-page: DataForSEO | Crawling: `seo/site-crawler.md` | Real-time monitoring: `seo/contentking.md`.

**Site audit** (output: `~/Downloads/{domain}/{datestamp}/` CSV/XLSX):

```bash
site-crawler-helper.sh {crawl|audit-links|audit-meta|audit-redirects} https://example.com
```

**E-E-A-T scoring** (7 criteria, 1-10: Authorship, Citation, Effort, Originality, Intent, Subjective Quality, Writing; output: `{domain}-eeat-score-{date}.xlsx`):

```bash
eeat-score-helper.sh analyze ~/Downloads/example.com/_latest/crawl-data.json
eeat-score-helper.sh score https://example.com/article
```

**Sitemap submission** (Playwright + persistent Chrome; first-time: `gsc-sitemap-helper.sh login`):

```bash
gsc-sitemap-helper.sh submit example.com [example.net ...]  # or --file domains.txt
gsc-sitemap-helper.sh status example.com
```

**Opportunities**: Quick Wins (pos 4-20), Striking Distance (pos 11-30), Low CTR, Cannibalization → `~/.aidevops/.agent-workspace/work/seo-data/{domain}/`.

**Image SEO**: AI-powered alt text (WCAG-compliant, Moondream), SEO filenames, keyword tags, upscaling — `seo/image-seo.md`.

**Content**: Integrate with `content.md` (calendar, writing, meta, internal linking). Per-project config: `content/context-templates.md`. Workflow: Plan → Research → Write → Analyze → Optimize (`seo/seo-optimizer.md`) → Edit → Publish.

## Tool Comparison

| Feature | GSC | DataForSEO | Serper | Ahrefs | Semrush |
|---------|-----|------------|--------|--------|---------|
| Search Performance | Yes | No | No | No | No |
| SERP Data | No | Yes | Yes | Yes | Yes |
| Keyword Research | Limited | Yes | No | Yes | Yes |
| Backlinks | No | Yes | No | Yes | Yes |
| On-Page Analysis | No | Yes | No | Yes | Yes (Site Audit) |
| Local/Places | No | Yes | Yes | No | No |
| News Search | No | Yes | Yes | No | No |
| Competitor Analysis | No | Yes | No | Yes | Yes (Domain vs Domain) |
| Position Tracking | No | No | No | No | Yes (Projects API) |
| Pricing | Free | Subscription | Pay-per-search | Subscription | Unit-based |
