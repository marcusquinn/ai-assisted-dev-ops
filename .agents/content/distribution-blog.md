---
name: blog
description: Blog distribution - SEO-optimized articles from content pipeline assets
mode: subagent
model: standard
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Blog - SEO-Optimized Article Distribution

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Turn content pipeline assets into SEO blog posts
- **Default length**: Pillar 2,000–3,000 words; supporting 800–1,500; listicle 1,000–2,000
- **Primary rule**: One validated primary keyword per article
- **Voice**: Run drafts through `content/editor.md` and `content/humanise.md`
- **Links**: Add 3–5 internal links via `content/internal-linker.md`
- **Metadata**: Generate title tag, meta description, and OG fields via `content/meta-creator.md`
- **Style**: One sentence per paragraph per `content/guidelines.md`

<!-- AI-CONTEXT-END -->

## Article Types

| Type | Length | Target | Structure |
|------|--------|--------|-----------|
| **Pillar** | 2,000–3,000 words | High-volume keywords, link hubs | Title (keyword-front, under 60 chars) → Meta (150–160 chars) → Intro (100–150 words) → TOC → H2/H3 body → Key takeaways → CTA → FAQ |
| **Supporting** | 800–1,500 words | Long-tail keywords, link to pillar | Title → Intro (50–100 words) → 3–5 H2 sections → Internal link to pillar → CTA |
| **Listicle** | 1,000–2,000 words | "best", "top", "how to" keywords | Number + keyword + year title → Selection criteria → Numbered H2 items → Comparison table → Verdict |

## SEO Workflow

### Keyword Research

```bash
keyword-research-helper.sh research "<keyword>" \
  --provider dataforseo --locale us-en
keyword-research-helper.sh extended "<keyword>" \
  --provider dataforseo --locale us-en
```

Frame the user job, constraints, query provenance, and evidence role with
`seo/conversational-search-intent.md`. Record provider, locale, and capture date;
keyword metrics are estimates, not universal thresholds.

| Factor | Target |
|--------|--------|
| Monthly volume | Market-relative opportunity with provider, locale, and capture date |
| Keyword difficulty | Relative to site authority and inspected SERP; no universal cutoff |
| Search intent | Informational or commercial investigation |
| SERP features | Prioritize only when the retrieval opportunity and business fit align |

**Content brief**: Include primary keyword, 3–5 secondary keywords, search intent, SERP-derived word count, competitor gaps, unique angle, and internal link targets.

### Writing Pipeline

1. `content/story.md` — narrative framework
2. `content/research.md` — data and insights
3. `content/seo-writer.md` — keyword-optimized draft
4. `content/editor.md` — human voice pass
5. `content/humanise.md` — remove AI patterns
6. `content/meta-creator.md` — title tag and meta description
7. `content/internal-linker.md` — strategic internal links

### On-Page Optimization

- [ ] Primary keyword in title tag (first 60 chars), H1, first 100 words, meta description
- [ ] Secondary keywords in H2 headings
- [ ] Alt text on all images (include keyword where natural)
- [ ] 3–5 internal links; 2–3 external links to authoritative sources
- [ ] URL slug contains primary keyword
- [ ] Schema markup (Article, FAQ, HowTo as applicable)

### Content Analysis

```bash
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py analyze article.md --keyword "<keyword>"
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py readability article.md
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py keywords article.md --keyword "<keyword>"
python3 ~/.aidevops/agents/scripts/seo-content-analyzer.py quality article.md
```

## Content from Pipeline Assets

| Source | Workflow |
|--------|----------|
| **YouTube** | Extract transcript with `youtube-helper.sh transcript VIDEO_ID` → restructure for reading → add SEO elements → expand with research → add visuals |
| **Research** | Use brief as foundation → structure around findings → add original analysis → include data → link sources |
| **Short-form** | Expand high-performing short → add context, examples, methodology → target related long-tail keywords → embed original video |

## Publishing Workflow

**WordPress**: Draft via WP REST API or WP-CLI; assign categories and tags; upload featured image; set Yoast/RankMath SEO fields; schedule. See `tools/wordpress/wp-dev.md`.

**Content calendar**: Pillar 1–2/month · Supporting 2–4/week · Listicles 1–2/month · Refresh top performers quarterly

**Post-Publish Checklist**:

- [ ] Verify indexing (Google Search Console)
- [ ] Share on social (`content/distribution-social.md`)
- [ ] Include in next newsletter (`content/distribution-email.md`)
- [ ] Internal link from 2–3 existing articles
- [ ] Monitor target keyword rankings weekly for first month

## Related

**Content pipeline**: `content/research.md` · `content/story.md` · `content/guidelines.md` · `content/optimization.md`

**SEO**: `seo.md` · `seo/keyword-research.md` · `seo/dataforseo.md` · `seo/google-search-console.md` · `seo/content-analyzer.md`

**Distribution**: `content/distribution-youtube.md` · `content/distribution-short-form.md` · `content/distribution-social.md` · `content/distribution-email.md` · `content/distribution-podcast.md`

**WordPress**: `tools/wordpress/wp-dev.md` · `tools/wordpress/mainwp.md`
