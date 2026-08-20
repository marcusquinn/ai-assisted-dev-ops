---
description: "YouTube topic research - content gaps, trend detection, keyword clustering, angle generation"
mode: subagent
model: standard
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

# YouTube Topic Research

Find video topics with validated demand and a viable supply gap. Combine YouTube
search data, competitor analysis, keyword research, and dated trend evidence.

## Data Sources

| Source | What It Provides | Tool |
|--------|-----------------|------|
| YouTube Data API | Search results, video counts per topic | `youtube-helper.sh search` |
| Competitor videos | What topics are already covered | `youtube-helper.sh videos` |
| yt-dlp transcripts | Deep topic extraction from video content | `youtube-helper.sh transcript` |
| DataForSEO | Google web-search keyword estimates and related language | `keyword-research-helper.sh research` |
| Serper | Web-search context and autocomplete | `seo/serper.md` |
| Approved trend source/export | Relative interest time series with locale and window | User-provided export or verified browser source |
| Memory | Previous research, patterns, preferences | `memory-helper.sh` |

## Intent and Evidence Framing

Before clustering keywords or declaring a trend, use
`seo/conversational-search-intent.md` to identify the user job, desired outcome,
query form, constraints, provenance, and trend state. Keep YouTube/API evidence,
autocomplete suggestions, competitor titles, and model-generated ideas as
separate source classes until corroborated.

## Workflow: Content Gap Analysis

Compare what competitors cover vs what's missing. Run for 3-5 competitors.

### Step 1: Extract Competitor Topic Maps

```bash
youtube-helper.sh videos @competitor 200 json | node -e "
process.stdin.on('data', d => {
    JSON.parse(d).forEach(v => console.log(v.snippet?.title));
});
" > "${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}/competitor_titles.txt"
```

**Prompt**: "Group these [N] video titles from [competitor] into topic clusters.
For each: topic name and coverage count. If dated view metrics are also supplied,
report engagement/outlier evidence separately; do not infer a trend from titles."

### Step 2: Map Your Coverage

```bash
youtube-helper.sh videos @yourchannel 200 json | node -e "
process.stdin.on('data', d => {
    JSON.parse(d).forEach(v => console.log(v.snippet?.title));
});
" > "${AIDEVOPS_TEMP_DIR:-$HOME/.aidevops/.agent-workspace/tmp}/my_titles.txt"
```

### Step 3: Identify Gaps

Gaps are topics where: (1) multiple competitors provide a publisher-supply
signal, (2) you have zero coverage, and (3) at least one competitor video is an
outlier (3x+ their median views). Validate audience demand separately before
prioritizing production.

**Prompt**: "Compare my topic clusters vs competitors. Identify topics where 2+ competitors have videos, I have zero coverage, and at least one competitor video is an outlier (3x+ median views)."

### Step 4: Store Findings

```bash
memory-helper.sh store --type WORKING_SOLUTION --namespace youtube-topics \
  "Content gap: [topic]. Covered by @comp1 (X views), @comp2 (Y views). \
   My coverage: none. Angle opportunity: [description]."
```

## Workflow: Trend Detection

Find topics gaining momentum before saturation. Require comparable dated windows
and preferably two independent time-aware signals. A current result snapshot or
recent publisher activity alone cannot establish rising audience demand.

### Method 1: YouTube Result-Mix Captures

```bash
# Capture result mix for comparison with an earlier/later equivalent window
youtube-helper.sh search "your niche topic 2026" video 20
```

Record capture date, locale, query, result freshness, view velocity where
available, and changes from the comparison capture. Recent results can indicate
new supply without proving increased demand.

### Method 2: Supported Web-Search Demand Estimate

```bash
keyword-research-helper.sh research "topic keyword" \
  --provider dataforseo --locale us-en
```

Returns related Google web-search keywords with estimated volume and difficulty.
Treat this as an independent web-demand proxy, not YouTube-native volume or a
trend. Record provider, locale, and capture date; establish direction only from
equivalent dated captures or a comparable trend time series.

### Method 3: Competitor Upload Velocity

Multiple competitors suddenly covering a topic is a publisher-supply signal.
Look for the same topic across channels within a defined window, then corroborate
it with search interest, query data, or audience engagement.

```bash
for ch in @comp1 @comp2 @comp3; do
    echo "=== $ch ==="
    youtube-helper.sh videos "$ch" 20 | head -15
    echo ""
done
```

### Method 4: Verified Trend Time Series

**Prompt**: "Compare relative search interest for '[topic]' across the selected
locale and equivalent windows. Classify it as evergreen, seasonal, rising,
event-driven, decaying, or uncertain; report the baseline, dates, and caveats."
(requires a user-provided export or a verified browser-accessible trend source)

Do not call relative trend interest absolute search volume. Record the trend
state, comparison window, locale, supporting signals, and confidence in the
topic opportunity.

## Workflow: Keyword Clustering

Group related keywords into video topics. One video = one keyword cluster.

Start from the validated user job and outcome, then cluster wording variants that
share a retrieval objective. Do not merge distinct audience constraints merely
because they contain the same high-volume term.

### Step 1: Seed Keywords

Search YouTube for 5-10 broad niche keywords.

```bash
for kw in "keyword1" "keyword2" "keyword3"; do
    echo "=== $kw ==="
    youtube-helper.sh search "$kw" video 10
    echo ""
done
```

### Step 2: Extract Related Terms

From search results, extract video titles (natural keyword variations), tags, and description keywords.

```bash
youtube-helper.sh video VIDEO_ID json | node -e "
process.stdin.on('data', d => {
    const tags = JSON.parse(d).items?.[0]?.snippet?.tags || [];
    tags.forEach(t => console.log(t));
});
"
```

### Step 3: Cluster with AI

**Prompt**: "Group these [N] keywords into clusters (one cluster = one video).
For each: (1) candidate primary keyword by intent fit, with volume unknown until
validated, (2) supporting keywords (2-5), (3) suggested video title, and (4)
estimated supply/competition based on existing video count."

### Step 4: Validate with Search Volume

```bash
keyword-research-helper.sh research "primary keyword" \
  --provider dataforseo --locale us-en
```

This supported route estimates Google web-search demand. For YouTube-native
demand, use an authorized first-party YouTube Analytics export; otherwise label
platform demand `uncertain`.

## Workflow: Angle Generation

Find the unique take that has not been done on a validated topic.

### Step 1: Analyze Existing Coverage

Get transcripts of top 3 videos to understand their angle.

```bash
youtube-helper.sh search "topic" video 20
youtube-helper.sh transcript VIDEO_ID_1
youtube-helper.sh transcript VIDEO_ID_2
youtube-helper.sh transcript VIDEO_ID_3
```

### Step 2: Angle Types Reference

| Angle Type | Example | When It Works |
|-----------|---------|---------------|
| **Contrarian** | "Why [popular opinion] is wrong" | Established topics with consensus |
| **Personal experience** | "I tried [thing] for 30 days" | Lifestyle, health, tech |
| **Comparison** | "[A] vs [B] — which is actually better?" | Products, tools, methods |
| **Deep dive** | "The science behind [thing]" | Topics with surface-level coverage |
| **Beginner-friendly** | "[Topic] explained in 5 minutes" | Complex topics |
| **Update** | "[Topic] in 2026 — what changed" | Evergreen topics with new developments |
| **Case study** | "How [person/company] did [thing]" | Business, strategy, marketing |
| **Mistakes** | "5 [topic] mistakes everyone makes" | How-to niches |
| **Hidden/secret** | "[Topic] features nobody talks about" | Tech, tools, platforms |
| **Cost breakdown** | "The real cost of [thing]" | Finance, lifestyle, business |

### Step 3: Generate Unique Angles

**Prompt**: "Topic: [topic]. Existing angles in top 10 videos: [list]. My channel voice: [from memory]. My audience: [from memory]. Generate 5 unique angles that: (1) aren't covered by top 10, (2) match my voice, (3) appeal to my audience, (4) have a clear hook for the first 30 seconds."

## Output Format

```markdown
## Topic Opportunity: [Topic Name]

**Intent cluster**: [user job + desired outcome + constraints]
**Demand evidence**: [search volume, first-party evidence, trend direction]
**Supply signal**: [competitor coverage and publication velocity]
**Competition**: [low/medium/high] — [X] existing videos, [Y] in last 30 days
**Gap type**: [uncovered / underserved / new angle needed]
**Trend evidence**: [state, locale, captured/comparison windows, confidence]
**Source IDs**: [source class + evidence state/role]

### Existing Coverage
- @competitor1: "[title]" — [views] views, [angle used]
- @competitor2: "[title]" — [views] views, [angle used]

### Recommended Angle
**[Angle type]**: [description]
**Working title**: "[suggested title]"
**Hook**: [first 30 seconds concept]
**Why this works**: [reasoning based on gap + audience]

### Keywords to Target
- Primary: [keyword] ([volume])
- Supporting: [kw1], [kw2], [kw3]
```

## Memory Integration

```bash
# Store a validated topic opportunity
memory-helper.sh store --type WORKING_SOLUTION --namespace youtube-topics \
  "Topic: [name]. Sources: [safe IDs]. Evidence: [state/role]. \
   Window/locale: [value]. Demand: [signal]. Supply: [signal]. \
   Trend/confidence: [value]. Privacy/export: [status]. \
   Best angle: [type] — [description]."

# Recall previous research
memory-helper.sh recall --namespace youtube-topics "content gap"

# Store a failed topic idea (avoid revisiting)
memory-helper.sh store --type FAILED_APPROACH --namespace youtube-topics \
  "Topic [name] rejected: [reason — e.g., too saturated, no search volume]"
```

## Related

- `seo/conversational-search-intent.md` — Query intent and trend evidence framing
- `channel-intel.md` — Competitor data feeds into gap analysis
- `script-writer.md` — Turn validated topics into scripts
- `optimizer.md` — Optimize titles/tags for chosen keywords
- `seo/keyword-research.md` — Deep keyword volume and competition data
- `seo/dataforseo.md` — Provider reference; use only implemented helper routes
- `seo/serper.md` — Web-search context and autocomplete
