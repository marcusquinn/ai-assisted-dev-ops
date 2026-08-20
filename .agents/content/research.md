---
name: research
description: Audience research, niche validation, and competitor analysis for content strategy
mode: subagent
model: standard
tools:
  read: true
  write: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Content Research

Pre-writing research to validate niches, understand audiences, and analyse competitors before content production.

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Audience research, niche validation, competitor content analysis
- **Input**: Topic, niche, or URL(s) to analyse
- **Output**: Research brief with audience profile, niche viability score, competitor gaps
- **Related**: `seo/conversational-search-intent.md` (query/user-job evidence),
  `content/seo-writer.md` (uses research output), `content/context-templates.md`
  (stores findings), `content/content-calendar.md` (prioritises topics)

<!-- AI-CONTEXT-END -->

## Pre-flight

Apply first-principles thinking, bias checks (confirmation, anchoring, availability, survivorship), and evidence evaluation per `AGENTS.md` "Scientific reasoning". Ask: what would disprove this conclusion?

## Workflow

### 1. Audience Research

**Data sources** (priority order):

1. **Reddit Deep Research** — 11-Dimension Framework (below)
2. **Google Search Console** (`seo/google-search-console.md`)
3. **Competitor audiences** — who engages with competitor content
4. **Creator Brain Clone** — bulk transcript ingestion (below, references t201)
5. **Cross-platform signals** — TikTok/X/IG/Reddit format migration patterns
6. **Web search** — industry reports, surveys, forum threads
7. **DataForSEO** (`seo/dataforseo.md`) — keyword volume and demographics

When research includes GSC rows, autocomplete, natural-language prompts,
internal search, or trend/news queries, build an intent ledger with
`seo/conversational-search-intent.md`. Preserve whether each phrase was observed,
measured, suggested, inferred, or generated and whether it evidences demand,
supply, language, an event, context, or only a hypothesis before combining it
with audience evidence.

#### 11-Dimension Reddit Research Framework

Use Perplexity (or similar AI search) with this mega-prompt:

```text
Analyze Reddit discussions about [TOPIC/PRODUCT/NICHE] across all relevant subreddits. Provide a comprehensive report covering these 11 dimensions:

1. SENTIMENT ANALYSIS — Overall sentiment, common praise/complaints, emotional tone
2. USER EXPERIENCE PATTERNS — Typical user journey, learning curve, common use cases, workflow integration
3. COMPETITOR COMPARISONS — Alternatives mentioned, head-to-head comparisons, migration patterns, feature gaps
4. PRICING & VALUE PERCEPTION — Price sensitivity, tier preferences, ROI discussions, deal-seeking behavior
5. USE CASES & APPLICATIONS — Primary use cases, creative/unexpected uses, industry-specific, beginner vs advanced
6. SUPPORT & COMMUNITY — Support quality, community helpfulness, documentation quality, onboarding
7. PERFORMANCE & RELIABILITY — Speed/performance, reliability issues, scalability, technical limitations
8. UPDATES & DEVELOPMENT — Feature request patterns, update frequency perception, breaking changes, roadmap transparency
9. POWER USER TIPS — Advanced techniques, workflow optimizations, hidden features, integration hacks
10. RED FLAGS & DEAL-BREAKERS — Reasons people quit, unresolved pain points, trust/security concerns, lock-in fears
11. DECISION SUMMARY — Who should use this, who should avoid it, key decision factors, alternatives

For each dimension, provide: direct quotes (exact user language), frequency indicators, subreddit sources, recency.
Focus on EXACT user language — their words, not marketing speak.
```

Replace `[TOPIC/PRODUCT/NICHE]`, run in Perplexity Pro, store raw output in `context/reddit-research-[topic].md`.

#### 30-Minute Expert Method

1. **Reddit Scraping** (10 min) — 3-5 subreddits. Search "best [topic]", "vs", "alternative to", "frustrated with", "how to". Top 20-30 threads.
2. **NotebookLM Ingestion** (5 min) — Upload Reddit threads + competitor sites + existing research.
3. **AI Analysis** (15 min) — Extract: top 10 pain points, failed solutions, user language, objections, ideal customer profile.

Save to `context/expert-brief-[niche].md`.

#### Pain Point Extraction

Extract pain points in EXACT audience language (critical for hooks, copy, resonance).

**Sources:** Reddit ("frustrated with", "problem with", "why does", "hate that") → Forums (Quora, Facebook groups) → Product reviews (Amazon, G2, Capterra 1-3 star) → YouTube comments → Social media.

```markdown
## Pain Point: [Short Label]

**Exact Quote**: "[User's exact words]"
**Source**: [Platform + URL]
**Frequency**: [Common / Occasional / Rare]
**Severity**: [Deal-breaker / Major annoyance / Minor friction]
**Failed Solutions Tried**: [What they tried, why it failed]
**Desired Outcome**: [What they wish existed, how they'd know it's solved]
**Purchase Trigger**: [What would make them buy NOW]
```

Collect 20-30 pain points → cluster by theme → rank by frequency + severity → map to content opportunities. Store in `context/pain-points-[niche].md`.

#### Creator Brain Clone Pattern

Bulk ingest competitor channel transcripts for queryable competitive intelligence (references t201).

```bash
# Download transcripts
yt-dlp-helper.sh transcripts @channelhandle --limit 50

# Store in memory with namespace
memory-helper.sh store --namespace youtube-[niche] --file transcripts/*.txt --auto

# Query for insights
memory-helper.sh recall --namespace youtube-[niche] "most common topics"
memory-helper.sh recall --namespace youtube-[niche] "video opening hooks"
memory-helper.sh recall --namespace youtube-[niche] "audience problems"
```

**Extracts:** Topic coverage, hook patterns, storytelling frameworks, pain points, language patterns, content gaps. Store in namespace `youtube-[niche]` + `context/creator-intel-[niche].md`.

#### Gemini 3 Video Reverse-Engineering

Feed competitor videos to Gemini 3 to extract reproducible prompts for video generation.

1. Identify high-performing competitor videos (top views, viral short-form, long-running ads)
2. Upload to Gemini 3:

```text
Analyze this video and provide:
1. VISUAL STYLE — Camera angles, lighting, color grading, composition
2. SCENE BREAKDOWN — Shot-by-shot with timestamps, B-roll, text overlays, transitions
3. AUDIO DESIGN — Voice style, background music, sound effects, audio mixing
4. PACING & EDITING — Average shot length, cut frequency, retention hooks
5. REPRODUCIBLE PROMPT — Generate a Sora 2 / Veo 3.1 prompt that would recreate this style
```

3. Save prompts to `context/video-styles/[style-name].md` (tagged by niche, format, production value, emotion).

**Related:** `content/production-video.md`, `tools/video/video-prompt-design.md`.

#### Cross-Platform Research

| Platform | Research Focus |
|----------|---------------|
| Reddit | Pain points, product discussions, buying intent |
| TikTok | Trending formats, viral hooks, short-form patterns |
| X (Twitter) | Real-time trends, hot takes, thread structures |
| Instagram | Visual trends, carousel formats, Reels patterns |
| YouTube | Long-form depth, tutorial formats, retention patterns |
| LinkedIn | B2B angles, professional pain points, case studies |

Watch for content performing well on one platform that hasn't migrated to others. Use the migration matrix below to track coverage:

| Topic | Reddit | TikTok | X | IG | YouTube | LinkedIn | Blog |
|-------|--------|--------|---|----|---------|---------| ------|
| [topic] | ✓/○/✗ | ✓/○/✗ | ✓/○/✗ | ✓/○/✗ | ✓/○/✗ | ✓/○/✗ | ✓/○/✗ |

`✓` = exists, `○` = opportunity, `✗` = poor fit. **Related:** `content/distribution-*.md`.

#### Audience Profile Template

```markdown
## Audience Profile: [Segment Name]

- **Who**: [Job title / role / demographic]
- **Pain points**: [Top 3 — use exact language from research]
- **Failed solutions**: [What they've tried that didn't work]
- **Goals**: [What success looks like]
- **Knowledge level**: [Beginner / Intermediate / Expert]
- **Where they hang out**: [Platforms, forums, communities]
- **Content preferences**: [Format: video, long-form, quick tips, tools]
- **Search behaviour**: [Question-style, comparison, how-to]
- **Buying triggers**: [What moves them from research to action]
- **Exact language**: [Key phrases they use repeatedly]
```

#### Validation Signals

Require at least one demand or first-party behavioural signal plus one independent
corroborating source class before proceeding. Two community, competitor, or
publisher-supply signals do not establish audience demand.

| Signal | Source | Threshold |
|--------|--------|-----------|
| Search evidence | DataForSEO / GSC | Estimated market demand or owned-site exposure; record provider, locale, window, and observed/estimated status |
| Community problem evidence | Reddit, Quora, niche forums | Active, dated discussion; corroborates language/pain, not market size |
| Publisher supply | SERP analysis | 3+ competitors publishing on topic; evidence of coverage/competition only |
| Social engagement | LinkedIn, X | Dated engagement with platform and sampling caveats |
| Community depth | 11-Dimension analysis | 5+ dimensions with active discussion; retain source IDs and evidence role |

### 2. Niche Validation

**Formula**: `Viability = (0.30 × Demand) + (0.30 × Buying Intent) + (0.25 × Competition Advantage) + (0.15 × Business Fit)`

**Scoring (1-5):**

| Factor | Weight | Signals |
|--------|--------|---------|
| Demand | 30% | Provider-estimated query volume with locale/window, comparable dated trend series, or first-party behaviour; use community, seller, and publisher activity only as corroboration |
| Buying Intent | 30% | Transactional/comparison query evidence, first-party conversion or sales, or customer research; marketplace offers and ads are commercial-supply proxies only |
| Competition Advantage | 25% | SERP DA: 5=DA<40, 4=DA 40-60, 3=DA 60-70, 2=DA 70-85, 1=DA 85+ |
| Business Fit | 15% | Affiliates (easiest), info products $5-$27, courses $100-$5K, SaaS $10-$100/mo, services $500+ |

**Thresholds:** 4.0+ = pillar + cluster | 3.5-3.9 = 2-3 test pieces | 3.0-3.4 = only if Business Fit = 5 | 2.5-2.9 = deprioritise | <2.5 = skip.

**Seasonality adjustment:** apply only when dated search, conversion, or sales
evidence shows a repeatable market-specific pattern. Never apply a blanket Q4
bonus across niches.

**Validation steps:**

1. Frame the user job and evidence provenance with
   `seo/conversational-search-intent.md`, then pull the primary query and 10-20
   related terms with volume and difficulty (`seo/keyword-research.md`)
2. SERP analysis: top 10 results — DA, word count, content type, freshness, gaps
3. Content quality audit: top 3 results — coverage, gaps, depth, freshness, format
4. Funnel mapping: Awareness ("what is [topic]") → Consideration ("best [topic] tools") → Decision ("[your product] for [topic]")

### 3. Competitor Content Analysis

Identify 3-5 direct competitors from primary keyword SERP (positions 1-10) and `context/competitor-analysis.md`.

```markdown
## Competitor: [Name] ([domain.com])

- **Publishing frequency**: [X posts/month]
- **Primary topics**: [top 3-5 clusters]
- **Content types**: [blog, video, podcast, tools, templates]
- **Average word count**: [X words]
- **Estimated organic traffic**: [if available]
- **Strengths**: [what they do well]
- **Weaknesses**: [what they miss or do poorly]
- **Content Gaps We Can Exploit**: [topics, angles, formats, audience segments they miss]
```

**Content matrix** — Status: `none`, `thin` (<500w), `basic` (500-1500w), `comprehensive` (1500-2999w), `pillar` (3000+w):

| Topic | Us | Competitor A | Competitor B | Competitor C | Gap? |
|-------|-----|-------------|-------------|-------------|------|
| [topic] | [status] | [status] | [status] | [status] | [Y/N] |

### 4. Research Brief Output

```markdown
# Content Research Brief: [Topic/Niche]

**Date**: [YYYY-MM-DD]  **Researcher**: [agent/human]  **Niche score**: [X.X/5.0]

## Audience
[Audience profile from step 1]

## Niche Viability
[Scorecard from step 2]

## Query and Keyword Targets
| Intent cluster | User job | Primary query | Volume | Difficulty | Classic intent | Trend state | Source IDs | Priority |
|----------------|----------|---------------|--------|------------|----------------|-------------|------------|----------|
| [cluster] | [outcome] | [primary] | [vol/none] | [diff/none] | [intent] | [state] | [IDs] | P0 |

Attach the canonical ledger from `seo/conversational-search-intent.md` for every
source ID. Preserve its locator, capture window/locale, supported claim,
evidence state/role, privacy status, metrics, and evidence confidence; the
summary table does not replace that ledger.

## Competitor Landscape
[Summary from step 3]

## Content Opportunities
1. [Highest-priority gap with rationale]
2. [Second gap]
3. [Third gap]

## Recommended Content Plan
| Priority | Title | Type | Target Keyword | Word Count | Funnel Stage |
|----------|-------|------|----------------|------------|--------------|
| P0 | [title] | [pillar/cluster/satellite] | [keyword] | [count] | [stage] |

## Next Steps
- [ ] Populate `context/target-keywords.md`
- [ ] Update `context/competitor-analysis.md`
- [ ] Add topics to content calendar
- [ ] Brief writer with this research for first article
```

## Storage and Integration

### Campaign research dossier handoff

For an intake-backed campaign, run `aidevops campaign research <id> --source
<evidence.json>` after collecting only authorized exports, Knowledge Plane
results, manual evidence, or lawful public research. It normalizes evidence into
`_campaigns/active/<id>/research/dossier.json`; use that contract rather than
copying provider output into a campaign brief. Treat observations as hypotheses:
gated, stale, partial, absent, and rate-limited sources are evidence gaps, not
findings. The human-readable `dossier.md` intentionally contains references and
redacted insights only; preserve raw sensitive competitive artifacts under
`_campaigns/intel/`.

Save to the project's `context/` directory (see `content/context-templates.md`):

- `context/audience-profiles.md` — audience segments and personas
- `context/competitor-analysis.md` — competitor content matrix
- `context/target-keywords.md` — validated keyword targets
- `context/niche-scorecards.md` — niche validation results

Read automatically by `content/seo-writer.md` and `content/editor.md`.

- **Feeds into**: `content/seo-writer.md`, `content/content-calendar.md`, `content/context-templates.md`
- **Uses data from**: `seo/conversational-search-intent.md`,
  `seo/dataforseo.md`, `seo/google-search-console.md`, `seo/keyword-research.md`
- **Related**: `research.md` (general research agent), `seo/content-analyzer.md` (post-writing analysis)
