---
description: Research YouTube competitors, trend candidates, and content opportunities
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Analyze YouTube competitors, validate trend candidates, and identify content gaps
in your niche.

Target: $ARGUMENTS

## Workflow

### Step 1: Determine Research Type

| Argument | Mode |
|----------|------|
| `@handle` | Competitor analysis |
| `trending` / `trends` | Trend candidates and validation in niche |
| `gaps` / `opportunities` | Content gap analysis |
| `video VIDEO_ID` | Analyze specific video |
| `--all` | Full research cycle (all competitors) |
| No args | Interactive (ask user) |

### Step 2: Load Configuration

```bash
~/.aidevops/agents/scripts/memory-helper.sh recall --namespace youtube "channel"
```

### Step 3: Execute Research

#### Mode A: Competitor Analysis (`@competitor`)

1. Get channel overview and recent videos:

```bash
~/.aidevops/agents/scripts/youtube-helper.sh channel @competitor
~/.aidevops/agents/scripts/youtube-helper.sh videos @competitor 50
```

2. **Identify outliers** — videos with 3x+ channel average views.
3. Get transcripts of top 3 outliers: `youtube-helper.sh transcript VIDEO_ID`
4. **Analyze patterns:** topics, title style (length, keywords, hooks), video length, upload frequency.
5. Store findings:

```bash
~/.aidevops/agents/scripts/memory-helper.sh store \
  --type WORKING_SOLUTION --namespace youtube-topics \
  "Competitor @handle outliers: [topic1], [topic2], [topic3]. \
   Sources/window: [safe IDs/date]. Evidence: [observed/supply]. \
   Confidence: [value]. Pattern hypothesis: [insight]"
```

#### Mode B: Trend Research (`trending`)

1. Read `seo/conversational-search-intent.md` and
   `content/distribution-youtube-topic-research.md`.
2. Collect trend candidates: `youtube-helper.sh trending "niche topic" 20`.
   Treat the result as current platform supply/engagement, not proven demand.
3. Cluster by validated user job and topic; retain capture date, locale, source
   class, evidence role, and source IDs.
4. Compare equivalent dated windows and corroborate with an independent demand
   signal before assigning `rising`, `seasonal`, `event-driven`, or `decaying`.
5. Cross-reference supply: which validated topics are uncovered or saturated?
6. Store opportunities:

```bash
~/.aidevops/agents/scripts/memory-helper.sh store \
  --type WORKING_SOLUTION --namespace youtube-topics \
  "Trend candidate: [topic]. State/confidence: [value]. Window: [dates]. \
   Evidence: [source IDs]. Supply gap: [description]."
```

#### Mode C: Content Gap Analysis (`gaps`)

1. Compare your videos vs competitors: topics covered/not covered, unique angles.
2. **Keyword clustering:** extract common keywords from competitor titles, group into clusters, rank by frequency and avg views.
3. **Opportunity scoring:**
   - High engagement + low competing supply = candidate; validate query demand
   - High engagement + high supply = observed performance pattern; validate demand and find a unique angle
   - Low views + low competition = risky, validate demand first

#### Mode D: Video Analysis (`video VIDEO_ID`)

1. Get details and transcript:

```bash
~/.aidevops/agents/scripts/youtube-helper.sh video VIDEO_ID
~/.aidevops/agents/scripts/youtube-helper.sh transcript VIDEO_ID
```

2. **Analyze structure:** hook (first 30s), intro (problem setup), body (solution/content), CTA.
3. **Extract reusable patterns:** title formula, hook formula, content structure, pacing (words/minute).

### Step 4: Present Findings

```text
YouTube Research: {target}

Summary:
- {key insight 1-3}

Evidence status: {candidate/validated/uncertain}
Sources: {safe source IDs + evidence state/role}
Window/locale/confidence: {values or not available}

Outlier Videos (3x+ avg views):
1. {title} - {views} views ({ratio}x avg)

Common Patterns:
- Topics: {clusters} | Title style: {pattern}
- Video length: {avg} | Upload frequency: {freq}

Content Opportunities:
1. {opportunity} - {reasoning}

Next Steps:
1. {collect missing evidence, or /youtube script "{topic}" only when validated}
2. /youtube research @handle
3. /youtube research video VIDEO_ID
```

Offer follow-up: generate a script only for a validated opportunity, collect
missing evidence for a candidate, research another competitor, set up monitoring
(`pipeline.md`), or export findings.

## Example: Competitor Analysis

```text
User: /youtube research @fireship

Channel: Fireship | 3.2M subs | 245 videos | Avg: 1.8M views

Outlier Videos (3x+ avg = 5.4M+):
1. "100+ JavaScript Concepts you Need to Know" - 12.4M (6.8x)
2. "I built the same app 10 times" - 8.9M (4.8x)
3. "JavaScript Pro Tips - Code This, NOT That" - 7.2M (3.9x)

Patterns: comparison videos, "X concepts" lists, code quality tips
Titles: numbers + actionable promise | Length: 8-12 min | Freq: 2-3/week
Hook: contrarian statement -> immediate value promise

Opportunities:
1. "100+ Python Concepts you Need to Know" - proven format, untapped niche
2. "I built the same AI app 10 times" - candidate topic requiring trend validation + proven format

Next: /youtube script "100+ Python Concepts you Need to Know"
```

## Related

- `seo/conversational-search-intent.md` - Query intent and trend evidence
- `content/distribution-youtube.md` - Main YouTube agent
- `content/distribution-youtube-channel-intel.md` - Deep competitor profiling
- `content/distribution-youtube-topic-research.md` - Advanced topic research
- `/youtube setup` - Configure tracking
- `/youtube script` - Generate scripts from research
- `youtube-helper.sh` - YouTube Data API wrapper
