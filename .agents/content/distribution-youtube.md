---
name: youtube
description: YouTube competitor research, content strategy, and video production automation
mode: subagent
model: standard
subagents: [channel-intel, topic-research, script-writer, optimizer, pipeline]
tools: {read: true, write: false, edit: false, bash: true, glob: true, grep: true, webfetch: true, task: true}
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# YouTube - Main Agent

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: YouTube competitor research, content ideation, script generation, and channel optimization
- **Tools**: YouTube Data API v3 (via service account), yt-dlp, DataForSEO, Serper, Outscraper
- **Helper**: `youtube-helper.sh` — channel lookup, video enumeration, search, transcripts, competitor comparison
- **Memory**: Cross-session persistence via `memory-helper.sh` (namespace: `youtube`)
- **Commands**: `/youtube setup`, `/youtube research`, `/youtube competitors`, `/youtube script`, `/youtube pipeline`

| Subagent | Purpose |
|----------|---------|
| `channel-intel` | Channel profiling, competitor analysis, outlier detection |
| `topic-research` | Niche trends, content gaps, keyword clustering, angle generation |
| `script-writer` | Script generation with hooks, retention curves, remix mode |
| `optimizer` | Title, tags, description, hook, and thumbnail optimization |
| `pipeline` | Automated cron-driven research pipeline |

<!-- AI-CONTEXT-END -->

## Architecture

Subagent docs: `content/distribution-youtube/`. Helpers: `scripts/youtube-helper.sh` (API wrapper), `yt-dlp-helper.sh` (transcripts), `keyword-research-helper.sh` (SEO), `memory-helper.sh` (persistence).

## Data Sources

| Source | Provides | Quota/Cost |
|--------|----------|------------|
| YouTube Data API v3 | Channel metadata, video stats, playlists | 10,000 units/day free |
| yt-dlp | Transcripts, full metadata, downloads | Unlimited (local) |
| DataForSEO | Google web-search keyword estimates and related terms | Per-request pricing |
| Serper | Web-search context and autocomplete | Per-request pricing |
| Approved trend source/export | Relative interest time series | Source-dependent |
| Outscraper | YouTube comments, sentiment | Per-request pricing |

Most research needs no browser automation — API + yt-dlp avoids context-filling screenshots.

## Quick Start

```bash
# 1. Setup (one-time)
youtube-helper.sh auth-test
memory-helper.sh store --type WORKING_SOLUTION --namespace youtube \
  "My channel: @myhandle. Niche: [topic]. Competitors: @comp1, @comp2, @comp3"

# 2. Research a competitor
youtube-helper.sh channel @competitor
youtube-helper.sh videos @competitor 100
youtube-helper.sh competitors @me @comp1 @comp2 @comp3
youtube-helper.sh transcript VIDEO_ID

# 3. Find opportunities
youtube-helper.sh trending "your niche topic" 20
youtube-helper.sh search "topic keyword" video 20

# 4. Check quota
youtube-helper.sh quota
```

`trending` returns candidates from the current platform view; it does not prove a
durable audience trend. Validate with `seo/conversational-search-intent.md` and
the dated evidence workflow in `distribution-youtube-topic-research.md`.

## Quota Management

Daily limit: 10,000 units. **Search costs 100 units** — prefer `playlistItems` (1 unit/50 videos). Transcripts via yt-dlp cost 0 units.

| Operation | Cost | Budget for 10k |
|-----------|------|----------------|
| Channel lookup | 1 unit | 10,000 lookups |
| Video details (batch of 50) | 1 unit | 500,000 videos |
| Playlist items (50 per page) | 1 unit | 500,000 videos |
| **Search** | **100 units** | **100 searches** |
| Transcript (via yt-dlp) | 0 units | Unlimited |

## Memory Namespaces

| Namespace | Content |
|-----------|---------|
| `youtube` | Channel profiles, competitor data, niche definition |
| `youtube-topics` | Research findings, content gaps, trend candidates, validated trends |
| `youtube-scripts` | Generated scripts, outlines, hooks |
| `youtube-patterns` | What titles/hooks/topics performed well |

```bash
memory-helper.sh store --type WORKING_SOLUTION --namespace youtube-topics \
  "Content gap: No one covers [topic] from [angle] perspective"
memory-helper.sh recall --namespace youtube "competitor analysis"
```

## Workflow: Full Research Cycle

1. **Channel Intel** (`channel-intel.md`) — profile 3-5 competitors, identify outlier videos (3x+ avg views), extract content DNA
2. **Topic Research** (`topic-research.md`) — content gap analysis, keyword clustering, trend detection, angle generation
3. **Script Writing** (`script-writer.md`) — hook → intro → body → CTA scripts, remix mode, retention curve optimization
4. **Optimization** (`optimizer.md`) — title variants with CTR signals, tag generation, SEO descriptions, thumbnail briefs
5. **Pipeline** (`pipeline.md`) — automated daily/weekly cron research, isolated workers, cross-session memory persistence

## Related Agents

| Agent | When to Use |
|-------|-------------|
| `seo/conversational-search-intent.md` | User jobs, query provenance, and trend evidence |
| `seo.md` | Deep keyword research, SERP analysis, backlink data |
| `content.md` | General content writing, video production (Remotion, HeyGen), cross-platform promotion |
| `research.md` | Broad web research beyond YouTube |
