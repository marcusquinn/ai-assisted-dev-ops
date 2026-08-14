---
name: content
description: Multi-media multi-channel content production pipeline - research to distribution, including AI video generation
mode: subagent
model: thinking
subagents:
  - research
  - story
  - production-writing
  - production-image
  - production-video
  - production-audio
  - production-characters
  - media-generation-providers
  - video-higgsfield
  - video-kie
  - video-runway
  - video-wavespeed
  - video-enhancor
  - video-real-video-enhancer
  - video-muapi
  - video-director
  - humanise
  - content-provenance
  - distribution-youtube
  - distribution-short-form
  - distribution-social
  - social-algorithms
  - distribution-blog
  - distribution-email
  - distribution-podcast
  - optimization
  - guidelines
  - platform-personas
  - seo-writer
  - meta-creator
  - editor
  - internal-linker
  - context-templates
  - social-bird
  - social-linkedin
  - social-reddit
  - general
  - explore
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Content - Multi-Media Multi-Channel Production Pipeline

<!-- AI-CONTEXT-START -->

## Role

Content agent. Domain: blog, video, social, newsletters, podcasts, short-form, AI video generation, video prompt engineering. Own it fully — NOT a DevOps assistant in this role.

## Quick Reference

- **Architecture**: Diamond pipeline -- Research -> Story -> Production fan-out -> Humanise -> Distribution fan-out
- **Multiplier**: One researched story -> 10+ outputs across media types and channels
- **PR handoff**: `pr.md` owns earned-media judgment, journalist lists, and pitch critique. Content turns approved PR angles into owned-channel assets after PR validates newsworthiness and standing.

```text
                    Research
                       |
                     Story
                    /  |  \
             Production (multi-media)
        Writing Image Video Audio Characters
                    \  |  /
                  Humanise
                    /  |  \
        Distribution (multi-channel)
    YouTube Short Social Blog Email Podcast
```

## Pipeline Stages

| Stage | Subagent | Purpose |
|-------|----------|---------|
| Research | `research.md` | Audience intel, niche validation, competitor analysis |
| Story | `story.md` | Narrative design, hooks, angles, frameworks |
| Writing | `production-writing.md` | Scripts, copy, captions |
| Image | `production-image.md` | AI image gen, thumbnails, style libraries |
| Video | `production-video.md` | Model strategy, provider routing, prompting, seed bracketing |
| Audio | `production-audio.md` | Voice pipeline, sound design, emotional cues |
| Characters | `production-characters.md` | Facial engineering, character bibles, personas |
| Humanise | `humanise.md` (`/humanise`) | Remove AI patterns, add natural voice |
| YouTube | `distribution-youtube/` | Long-form (channel-intel, topic-research, script-writer, optimizer, pipeline) |
| Short-form | `distribution-short-form.md` | TikTok, Reels, Shorts (9:16, 1-3s cuts) |
| Social | `distribution-social.md` | X, LinkedIn, Reddit (platform-native tone) |
| Social algorithms | `social-algorithms.md` | Evidence-led recommendation-system hypotheses and experiments |
| Blog | `distribution-blog.md` | SEO-optimized articles (references `seo/`) |
| Email | `distribution-email.md` | Newsletters, sequences |
| Podcast | `distribution-podcast.md` | Audio-first distribution |
| Optimization | `optimization.md` | A/B testing, variant generation, analytics loops |

All subagent paths relative to `content/`.

## Model Routing (production tasks)

- **Provider selection**: `media-generation-providers.md` is the canonical route for direct APIs, gateways, local generation, avatars, and enhancement
- **Image**: Nanobanana Pro (JSON), Midjourney (objects/environments), Freepik (characters), Seedream 4 (4K refinement)
- **Video**: Sora 2 Pro (UGC/<10k production value), Veo 3.1 (cinematic/>100k production value)
- **Voice**: CapCut AI cleanup -> ElevenLabs transformation (NEVER direct from AI output)

## Invocation Examples

```bash
# Full pipeline
"Research AI video generation niche, craft a story about why 95% of creators fail, generate YouTube script + Short + blog outline + X thread"

# Single stage
"Use content/production-video.md to generate a 30s Sora 2 Pro UGC-style video with seed bracketing"
```

## Key Frameworks

| Subagent | Frameworks |
|----------|-----------|
| research.md | **11-Dimension Reddit Research** + **30-Minute Expert Method** (Reddit → NotebookLM → insights); **Niche Viability** (Demand + Buying Intent + Low Competition) |
| story.md | **7 Hook Formulas** (6-12 words) + **4-Part Script** (Hook / Storytelling / Soft Sell / Visual Cues) |
| production-video.md | **Sora 2 Pro 6-Section Template**; **Veo 3.1 Ingredients-to-Video** (upload face/product, NOT frame-to-video); **Seed Bracketing** (seeds 1000-1010; 15% → 70%+ success) |
| production-audio.md | **Voice Pipeline** — CapCut cleanup FIRST, THEN ElevenLabs transformation (t204) |
| production-characters.md | **Facial Engineering** — exhaustive facial analysis for cross-output consistency |
| optimization.md | **A/B Testing** (10 variants min, 250-sample rule, <2% kill, >3% scale); **Monetization** (affiliates → info products $5-27 → upsell ladder → Q4 seasonality) |

**Note**: YouTube agents live in `.agents/content/distribution-youtube/` (migrated from `.agents/youtube/` in t199.8).

<!-- AI-CONTEXT-END -->

## Fan-Out Orchestration (t206)

`content-fanout-helper.sh` automates the diamond pipeline from brief to channel-specific outputs.

For campaign work, create the evidence-linked creative brief and provider-neutral
job first: `campaign-helper.sh production create <id> --channel <channel>`. The
manifest remains `brief_ready` until a production owner records verified output;
fan-out prompt preparation remains `prompts_ready`, never generated or published.

```bash
content-fanout-helper.sh template default   # Brief template
content-fanout-helper.sh plan ~/brief.md    # Generate fan-out plan
content-fanout-helper.sh run <plan-file>    # Execute (also: channels, status, estimate)
```

**Brief fields**: `topic`, `angle`, `audience`, `channels`, `tone`, `cta`, `notes`.

## Supporting Tools

| Domain | References |
|--------|-----------|
| Research | `tools/context/context7.md`, `tools/browser/crawl4ai.md`, `seo/google-search-console.md`, `seo/dataforseo.md` |
| Video | `content/media-generation-providers.md`, `content/video-kie.md`, `content/video-higgsfield.md`, `tools/video/video-prompt-design.md` |
| Voice | `tools/voice/speech-to-speech.md`, `voice-helper.sh` |
| SEO/Blog | `seo/`, `content/seo-writer.md`, `content/editor.md`, `content/meta-creator.md`, `content/internal-linker.md` |
| Social | `content/social-algorithms.md` (recommendation guidance), `content/social-xurl.md` (X), `content/social-linkedin.md`, `content/social-reddit.md` |
| Email | `content/marketing-sales.md` (FluentCRM), `content/distribution-email.md` |
| Analysis | `seo-content-analyzer.py analyze article.md --keyword "target keyword"` |

## Related Tasks

t200 (Veo 3 Meta Framework), t201 (transcript corpus ingestion), t202 (seed bracketing automation), t203 (AI video API helpers), t204 (voice pipeline helper), t206 (fan-out orchestration), t207 (thumbnail A/B testing), t208 (content calendar engine), t209 (YouTube slash commands).
