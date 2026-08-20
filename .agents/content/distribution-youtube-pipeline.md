---
description: "YouTube automated research pipeline - cron-driven competitor monitoring and content generation"
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

# YouTube Automated Pipeline

Cron-driven autonomous pipeline for YouTube competitor research and content generation. Each phase runs as an isolated worker with fresh context, storing results in memory — solves context overflow by decomposing research into independent tasks.

## Architecture

```text
Cron Trigger (daily/weekly)
    |
    v
Supervisor Pulse
    |
    +-- Worker 1: Channel Intel Scan
    |   Input:  competitor list from memory
    |   Output: channel stats, new videos, outliers -> memory
    |   Quota:  ~50 units per run
    |
    +-- Worker 2: Topic Research
    |   Input:  competitor data from memory + keyword seeds
    |   Output: content gaps, trend candidates/validated trends -> memory
    |   Quota:  ~200 units (includes search)
    |
    +-- Worker 3: Script Generation
    |   Input:  top 3 opportunities from memory
    |   Output: draft scripts -> workspace files
    |   Quota:  0 units (AI generation only)
    |
    +-- Worker 4: Optimization
    |   Input:  draft scripts from workspace
    |   Output: titles, tags, descriptions, thumbnail briefs -> workspace
    |   Quota:  ~10 units (competitor tag lookup)
    |
    +-- Notification
        Output: summary email/mailbox message
```

**Key design decisions:** API-first (YouTube Data API + yt-dlp, no browser/screenshots), each worker gets fresh context and does one job, memory persists in SQLite across sessions, cron triggers supervisor which dispatches headless workers.

## Setup

### Step 1: Store Channel Configuration

```bash
# Store your channel
memory-helper.sh store --type WORKING_SOLUTION --namespace youtube \
  "My channel: @myhandle
   Niche: [your niche description]
   Target audience: [audience description]
   Channel voice: [voice description]
   Content focus: [what topics you cover]"

# Store competitors (one entry per competitor for easy updates)
memory-helper.sh store --type WORKING_SOLUTION --namespace youtube \
  "Competitor: @competitor1 - [brief description of their content]"

memory-helper.sh store --type WORKING_SOLUTION --namespace youtube \
  "Competitor: @competitor2 - [brief description of their content]"

memory-helper.sh store --type WORKING_SOLUTION --namespace youtube \
  "Competitor: @competitor3 - [brief description of their content]"
```

### Step 2: Create Pipeline Tasks

Add to TODO.md for the supervisor:

```markdown
- [ ] yt-intel YouTube channel intel scan @runner #youtube ~30m
- [ ] yt-research YouTube topic research @runner #youtube ~45m blocked-by:yt-intel
- [ ] yt-scripts YouTube script generation @runner #youtube ~30m blocked-by:yt-research
- [ ] yt-optimize YouTube metadata optimization @runner #youtube ~20m blocked-by:yt-scripts
```

### Step 3: Add Tasks to TODO.md

Add tasks with auto-dispatch tags so the pulse picks them up:

```markdown
- [ ] yt-intel Scan competitor channels for new videos and outliers @runner #youtube #auto-dispatch ~30m
- [ ] yt-research Analyze content gaps and validate trend candidates from intel data @runner #youtube #auto-dispatch ~30m blocked-by:yt-intel
- [ ] yt-scripts Generate draft scripts for top 3 topic opportunities @runner #youtube #auto-dispatch ~30m blocked-by:yt-research
- [ ] yt-optimize Generate titles, tags, descriptions for draft scripts @runner #youtube #auto-dispatch ~20m blocked-by:yt-scripts
```

### Step 4: Enable the Pulse

```bash
# Enable the supervisor pulse (checks every 2 minutes)
aidevops pulse start

# Or add a specific YouTube pipeline cron (daily at 6 AM)
cron-helper.sh add "youtube-pipeline" \
  --schedule "0 6 * * *" \
  --command "pulse-wrapper.sh"
```

## Worker Instructions

Each worker receives these prompts via the supervisor:

### Worker 1: Channel Intel

```text
1. Recall competitor list: memory-helper.sh recall --namespace youtube "Competitor"
2. For each competitor:
   a. Run: youtube-helper.sh channel @handle json
   b. Run: youtube-helper.sh videos @handle 20 json
   c. Calculate: median views, outlier threshold (3x median)
   d. Identify new videos since last scan
   e. Flag any outlier videos
3. Store findings: memory-helper.sh store --namespace youtube
   "Intel scan [date]: @handle - [new videos count], [outlier count], [notable findings]"
4. Report via mailbox: mail-helper.sh send --type status_report
   "YouTube intel scan complete. [summary]"
```

### Worker 2: Topic Research

```text
1. Recall intel data: memory-helper.sh recall --namespace youtube "Intel scan"
2. Recall my channel topics: memory-helper.sh recall --namespace youtube "My channel"
3. Read: seo/conversational-search-intent.md and classify source/evidence roles
4. Extract user-job/topic clusters from competitor videos; label them supply
5. Identify gaps: topics competitors cover that I don't
6. Find trend candidates from recent publisher activity; label this supply
7. For each candidate, collect an independent demand source: a supported Google
   web-search estimate (`keyword-research-helper.sh research`) with provider,
   locale, and date; a privacy-approved first-party YouTube Analytics export; or
   an approved trend export with comparable windows
8. Treat one estimated-volume snapshot as demand evidence, not trend evidence;
   when demand or time-series evidence is unavailable, mark the candidate
   `uncertain` and do not call it validated
9. Run: youtube-helper.sh search "[topic]" video 10, then assess supply,
   competition, demand evidence, trend state, business fit, and confidence
10. Store only safe aggregates and source IDs: memory-helper.sh store
    --namespace youtube-topics "Opportunity [date]: [topic] - [source IDs],
    [state/role], [window/locale], [demand], [supply], [trend/confidence], [angle]"
11. Report validated opportunities separately from uncertain candidates
```

### Worker 3: Script Generation

```text
1. Recall opportunities: memory-helper.sh recall --namespace youtube-topics "Opportunity"
2. Recall channel voice: memory-helper.sh recall --namespace youtube "Channel voice"
3. Select top 3 validated opportunities by evidence-weighted demand, supply gap,
   and business fit; skip uncertain or unvalidated candidates
4. For each opportunity:
   a. Get competitor transcript if available: youtube-helper.sh transcript VIDEO_ID
   b. Choose storytelling framework based on content type
   c. Generate full script with hooks, pattern interrupts, CTA
   d. Save to workspace: ~/.aidevops/.agent-workspace/work/youtube/scripts/
5. Store script metadata in memory
6. Report via mailbox with script summaries
```

### Worker 4: Optimization

```text
1. Read draft scripts from: ~/.aidevops/.agent-workspace/work/youtube/scripts/
2. For each script:
   a. Generate 5 title options with CTR signals
   b. Generate 20-30 tags across all categories
   c. Write SEO-optimized description with timestamps
   d. Create thumbnail brief
   e. Save alongside script file
3. Store successful patterns in memory
4. Report via mailbox with final deliverables summary
```

## Monitoring

```bash
# Pipeline status and quota
aidevops pulse status
youtube-helper.sh quota
mail-helper.sh check

# View results
memory-helper.sh recall --namespace youtube "Intel scan" --recent
memory-helper.sh recall --namespace youtube-topics "Opportunity" --recent
memory-helper.sh recall --namespace youtube-patterns --recent
ls ~/.aidevops/.agent-workspace/work/youtube/scripts/
```

## Frequency Recommendations

| Pipeline | Frequency | Quota Budget | Best For |
|----------|-----------|-------------|----------|
| **Intel scan only** | Daily | ~50 units | Monitoring competitor uploads |
| **Full pipeline** | Weekly | ~300 units | Complete research + script cycle |
| **Trending check** | 2x/week | ~200 units | Fast-moving niches |
| **Deep analysis** | Monthly | ~1000 units | Comprehensive competitor review |

With 10,000 daily quota units, the full pipeline can run daily with ~9,700 units remaining for ad-hoc research.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Worker fails to start | Check `aidevops pulse status` for error messages |
| Quota exceeded | Check `youtube-helper.sh quota`, reduce search calls |
| Memory not persisting | Verify `memory-helper.sh stats` shows entries |
| Stale competitor data | Run `youtube-helper.sh channel @handle` manually to verify API access |
| Cron not triggering | Check `cron-helper.sh list` and system cron logs |
| Worker context overflow | Reduce video count per competitor (50 instead of 200) |

## Workspace Structure

```text
~/.aidevops/.agent-workspace/work/youtube/
├── scripts/
│   ├── 2026-02-09-topic-name/
│   │   ├── script.md           # Full script
│   │   ├── titles.md           # Title options
│   │   ├── tags.txt            # Tag list
│   │   ├── description.md      # YouTube description
│   │   └── thumbnail-brief.md  # Thumbnail design brief
│   └── ...
├── intel/
│   ├── latest-scan.json        # Most recent competitor scan
│   └── history/                # Historical scan data
└── reports/
    └── weekly-summary.md       # Pipeline summary reports
```

## Related

- `youtube.md` — Main YouTube orchestrator
- `channel-intel.md` — Worker 1 detailed instructions
- `topic-research.md` — Worker 2 detailed instructions
- `script-writer.md` — Worker 3 detailed instructions
- `optimizer.md` — Worker 4 detailed instructions
- `tools/ai-assistants/headless-dispatch.md` — Supervisor architecture
- `tools/automation/cron-agent.md` — Cron job configuration
- `scripts/pulse-wrapper.sh` — Pulse orchestration CLI reference
