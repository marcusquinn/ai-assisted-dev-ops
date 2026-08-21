---
name: story
description: Narrative design, hooks, angles, and frameworks for platform-agnostic storytelling
mode: subagent
model: standard
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Story - Narrative Design and Hook Engineering

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Input**: Research brief (`content/research.md`) or topic + audience
- **Output**: Story package — hook variants, narrative arc, transformation framework, angle selection
- **Earn attention early** — use a 6-12 word hook when it suits the format; direct usefulness can be the hook
- **Proven structure, genuine twist** — use a suitable scaffold, then require a product-specific angle, insight, tension, example, or point of view
- **One transformation per story** — before → struggle → after

<!-- AI-CONTEXT-END -->

## Pre-flight Checklist

1. **Theme** — universal truth explored?
2. **Takeaway** — audience thinks, feels, or does what differently?
3. **Story** — tension, transformation, resolution present?
4. **Protagonist** — audience, character, or brand?
5. **Offer clarity** — value in one sentence?
6. **Urgency** — real reason to act now?
7. **Pain angle** — specific pain addressed?
8. **Hook + visual alignment** — hook matches thumbnail/preview?
9. **Test readiness** — 3+ variants for A/B?
10. **Evidence** — every statistic, result, timeframe, comparison, and first-person claim sourced?

## 7 Hook Formulas

| # | Formula | Example | Best For |
|---|---------|---------|----------|
| 1 | **Bold Claim** | "[Verified percentage] of [audience] hit [specific problem]" | YouTube, blog, LinkedIn |
| 2 | **Question** | "Why do [audience] stop after [verified timeframe]?" | Social, email, podcast |
| 3 | **Story** | "I spent [verified amount] testing [category] — here's what changed" | YouTube, podcast, blog |
| 4 | **Contrarian** | "Why we stopped recommending [common approach]" | X, Reddit, short-form |
| 5 | **Result** | "How [subject] reached [verified result] with [constraint]" | YouTube, short-form, social |
| 6 | **Problem-Agitate** | "You're losing [verified time or cost] to [specific problem]" | Email, LinkedIn, blog |
| 7 | **Curiosity Gap** | "The [specific setting] most teams overlook" | Short-form, X, email |

Bracketed values require source evidence before publication. If no reliable number exists, make the claim concrete without one. Never invent first-person experience.

**Hook process**: Write 10 variants → score specificity/emotion/curiosity (1-5 each) → top 3 for A/B → archive rest.

**Pattern interrupts**: Contrast ("[Verified low-cost option] beat [verified comparison]") · Extremes ("We analysed [verified sample] and found [result]") · Unexpected combinations ("What [relevant outside field] taught us about [topic]")

## 4-Part Script Framework

| Part | Weight | Content |
|------|--------|---------|
| **Hook** | first 5-10s | Pattern interrupt or value promise. Standalone-capable (previews, thumbnails, subject lines). |
| **Story** | 60-70% | Before state (pain) → Struggle (failed attempts) → After state (transformation) |
| **Soft Sell** | 15-20% | Natural story-to-CTA transition. Frame as next step, not pitch. |
| **Visual Cues** | throughout | B-roll directions, image suggestions, tone shifts, formatting cues |

**Story frameworks**: AIDA · Three-Act · Hero's Journey · Problem-Solution-Result · Listicle with Stakes. Use them as internal scaffolds, not as the brand voice; adapt or discard any framework that forces the story.

## Angle Selection

| Angle | When to Use | Platforms |
|-------|-------------|-----------|
| **Pain** | Audience frustrated, seeking solutions | Blog, email, YouTube |
| **Aspiration** | Audience wants to level up | Short-form, social, YouTube |
| **Contrarian** | Conventional wisdom wrong | X, Reddit, podcast |
| **Educational** | Audience needs a skill | Blog, YouTube, podcast |
| **Hot take** | Trending conversation | X, short-form, Reddit |
| **Behind the scenes** | Audience wants authenticity | YouTube, podcast, social |

## Story Package Output

```text
# Story Package: [Topic]
## Hook Variants (scored) — min 5: [Hook] — Formula: [name] — Score: S/E/C = total
## Narrative Arc — Before / Struggle / Transformation / After
## Angle — Primary: [name] — Rationale: [why]
## Script Skeleton — Hook / Story / Soft Sell / Visual Cues
## Platform Adaptation — YouTube / Short-form / Social / Blog / Email / Podcast
```

## UGC Brief Storyboard

### Input Brief

```text
Business:   [Company + what they do]
Product:    [Product/service featured]
Audience:   [Target customer — demographics, pain points]
Presenter:  [Character — 15+ attributes per video-prompt-design.md]
Tone:       [warm | energetic | authoritative | casual | inspirational]
Platform:   [TikTok/Reels (9:16) | YouTube (16:9) | both]
Duration:   [15s | 30s | 60s]
CTA:        [Viewer action]
```

### Duration-Based Storyboard Structure (3/5/7-8 shots)

The table below is a base template — adapt shot count to duration. Suggested variations derived from this template:
- **15s** → 3 shots (merge Hook+Before, Transformation, CTA)
- **30s** → 5 shots (standard — use all rows as-is)
- **60s** → 7-8 shots (split Transformation into 2-3 demo + testimonial)

| Shot | Role | Duration | Purpose |
|------|------|----------|---------|
| 1 | **Hook** | 2-3s | Pattern interrupt — bold claim or question |
| 2 | **Before State** | 3-5s | Show pain/frustration |
| 3 | **Transformation** | 5-8s | Product hero — demonstrate solution |
| 4 | **After State** | 3-5s | Result proof — show outcome |
| 5 | **Soft Sell + CTA** | 2-3s | Direct CTA, presenter to camera |

### Per-Shot Format (7 components — `video-prompt-design.md`)

```text
## Shot [N]: [FRAMEWORK_ROLE]
Subject:   [Presenter — identical across shots]
Action:    [Movements, gestures, micro-expressions]
Scene:     [Environment, props, lighting]
Style:     [Camera: type, angle, movement | Palette | DOF]
Dialogue:  (Presenter): "[8s-rule: 12-15 words max]" (Tone: [from brief])
Sounds:    [Diegetic only — no score, no stock music]
Technical: [Negatives: subtitles, watermark, text overlays, amateur quality]
```

### Generation Process

1. Fill brief → select hook formula → generate shots per duration
2. Score 5+ hook variants (Shot 1) on specificity/emotion/curiosity
3. Image keyframes → `content/production-image.md`; video → Sora 2 Pro (UGC) or Veo 3.1 (cinematic)
4. Assemble; add text overlays in post (not in generation)

## Related

- `content.md` — parent orchestrator (diamond pipeline)
- `content/research.md` — audience data, pain points → story input
- `content/production-writing.md` — story → full scripts and copy
- `content/production-image.md` — per-shot keyframes
- `content/production-video.md` — video generation (Sora 2 Pro for UGC)
- `content/production-audio.md` — UGC audio (diegetic only)
- `content/production-characters.md` — presenter consistency
- `content/optimization.md` — A/B tests hooks and angles
- `content/distribution-short-form.md` — platform specs
- `tools/video/video-prompt-design.md` — 7-component shot format
