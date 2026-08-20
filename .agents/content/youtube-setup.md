---
description: Configure YouTube channel and competitor tracking for research and content strategy
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Configure YouTube channel settings, competitor tracking, and niche definition for ongoing research.

Arguments: $ARGUMENTS

## Workflow

### Step 1: Test YouTube API Access

```bash
~/.aidevops/agents/scripts/youtube-helper.sh auth-test
```

On failure, guide the user to set up their service account key.

### Step 2: Gather Channel Information

Collect from $ARGUMENTS or prompt interactively:

1. **Channel handle** (e.g., @myhandle)
2. **Niche/topic** (e.g., "AI coding tools")
3. **Competitor channels** (3-5 handles)

### Step 3: Validate Channels

For each channel (yours + competitors):

```bash
~/.aidevops/agents/scripts/youtube-helper.sh channel @handle
```

Verify existence and display basic stats (subscribers, videos, total views).

### Step 4: Store Configuration in Memory

```bash
~/.aidevops/agents/scripts/memory-helper.sh store \
  --type WORKING_SOLUTION \
  --namespace youtube \
  "My channel: @myhandle. Niche: [topic]. Competitors: @comp1, @comp2, @comp3"
```

Store individual competitor profiles:

```bash
~/.aidevops/agents/scripts/memory-helper.sh store \
  --type CODEBASE_PATTERN \
  --namespace youtube \
  "Competitor @handle: [subscribers] subs, [videos] videos, [avg_views] avg views/video"
```

### Step 5: Run Initial Competitor Comparison

```bash
~/.aidevops/agents/scripts/youtube-helper.sh competitors @myhandle @comp1 @comp2 @comp3
```

Display the comparison table. Highlight: views/video ratio, views/subscriber ratio, subscriber gap.

### Step 6: Confirm Next Steps

Tell the user setup is complete and suggest:

- `/youtube research @competitor` — analyze competitor content strategy
- `/youtube research trending` — identify and validate trend candidates
- `content/distribution-youtube-pipeline.md` — set up automated monitoring
- `/youtube script "topic"` — generate first script

Configuration persists across sessions via memory.

## Options

| Command | Purpose |
|---------|---------|
| `/youtube setup` | Interactive setup (prompts for all info) |
| `/youtube setup @myhandle "niche" @comp1 @comp2` | Quick setup with args |
| `/youtube setup --reconfigure` | Update existing configuration |
| `/youtube setup --show` | Display current configuration |

## Related

- `content/distribution-youtube.md` — Main YouTube agent
- `content/distribution-youtube-channel-intel.md` — Competitor analysis
- `content/distribution-youtube-pipeline.md` — Automated monitoring
- `youtube-helper.sh` — YouTube Data API wrapper
- `memory-helper.sh` — Cross-session persistence
