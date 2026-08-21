---
name: writing
description: Scripts, copy, captions, and text content production across all formats
mode: subagent
model: standard
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Writing - Multi-Format Text Production

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Transform story packages into platform-ready scripts, copy, and text content
- **Input**: Story package (from `content/story.md`) or direct brief
- **Output**: Long-form scripts, short-form scripts, social copy, blog drafts, email copy, captions
- **Key Principle**: Same narrative, different delivery -- adapt voice, length, and structure per format

**Critical Rules**:

- **Earn attention immediately** -- A hook, useful fact, or direct promise must suit the format
- **8-second dialogue chunks** for AI video -- Longer blocks cause unnatural pacing
- **Platform-native voice** -- No cross-posting smell (each platform has distinct expectations)
- **At most one genuine CTA** -- Omit it when no action is useful
- **Scene-by-scene for video** -- Include B-roll directions, not just dialogue

<!-- AI-CONTEXT-END -->

## Pre-flight Questions

Before generating any content:

1. What should the reader understand, decide, or do? Do not invent an action.
2. Is value front-loaded -- useful from the first paragraph alone?
3. Is every section earning its place, or padding?
4. Does the tone match the context deliberately, not by default?
5. Which verified product detail, decision, trade-off, or approved point of view makes this unmistakably ours?
6. Could a competitor publish it unchanged? If so, make it product-specific or cut it.

## Medium-aware layout

| Medium | Adaptable default |
|--------|-------------------|
| Screen marketing copy — websites, blogs, social posts, customer email | One sentence per paragraph to avoid walls of text |
| Academic or formal documents and letters | Average about three sentences per paragraph; follow argument, quotation, and document conventions |
| Spoken scripts | Break around breath, pauses, emphasis, beats, and content-appropriate pacing rather than a sentence quota |
| Graphical text | Balance hierarchy, canvas, surrounding elements, text as a graphical element, and whitespace; no paragraph quota |

Project, brand, accessibility, and publication requirements may override these defaults.

## Output Formats

### Long-Form Script (YouTube, Podcast)

Target: 8-15 min (1,200-2,200 words); example timeline below runs ~11 min. Every scene needs narration + visual direction. B-roll must be specific ("show screen recording of tool X dashboard", not "show relevant footage"). Mark emotional beats: [PAUSE], [EMPHASIS], [LOWER VOICE].

```text
# [Title]

## HOOK (0:00-0:15)
[Opening line -- pattern interrupt or bold claim]
[Visual: B-roll description or camera direction]

## SCENE 1: [Setup] (0:15-2:00)
[Narration -- 8-second chunks max]
[Visual: B-roll / screen recording / graphic]
[Transition: bridge sentence to next scene]

## SCENE 2: [Problem/Story] (2:00-5:00)
[Narration]  [Visual: ...]

## SCENE 3: [Solution/Insight] (5:00-8:00)
[Narration]  [Visual: ...]

## SCENE 4: [Proof/Examples] (8:00-10:00)
[Narration]  [Visual: ...]

## CTA (optional, 10:00-10:30)
[If useful: soft sell -- natural transition from content]
[Visual: end screen, subscribe animation]

## END SCREEN (10:30-11:00)
[Suggested video tease]
```

### Short-Form Script (TikTok, Reels, Shorts)

Target: 30-60 sec (75-150 words). Hook in first 1-3 seconds. Fast cuts (1-3s per shot). Captions mandatory (80%+ watch silent). Single idea, no tangents. End with loop potential (last frame connects to first).

```text
# [Hook -- first 1-3 seconds]

[Setup -- 5-12 seconds]
[Payoff -- 10-20 seconds]
[Twist or reinforcement -- 5-10 seconds]
[Optional CTA -- 3 seconds, only when the piece has a genuine next action]

CAPTION: [Full text for silent viewers]
SOUND: [Mood/genre suggestion]
CUTS: [Cut timing -- e.g., "cut every 1.5s"]
```

### Social Copy

#### X (Twitter)

**Thread**: POST 1 (HOOK, under 280 chars, standalone value) → POST 2 (expand) → POST 3-7 (one point per post, each standalone) → final post (genuine CTA or final useful point).

**Single post**: Under 280 chars. Front-load value. Personality-forward.

#### LinkedIn

Target: 1,200-1,500 characters. Professional but not corporate.

```text
[Hook line -- bold or surprising]

[2-3 short paragraphs -- insight, story, or data]

[Key takeaway -- one sentence]

[Optional CTA -- a genuine question or useful next action]

#hashtag1 #hashtag2 #hashtag3
```

#### Reddit

No self-promotion. Value-first. Community-native tone.

```text
Title: [Curiosity-driven, not clickbait]

Body:
[Context -- why you're posting, what you found]
[Value -- the insight, data, or resource]
[Discussion prompt -- genuine question for the community]
```

### Blog Draft

**SEO rules**: Target keyword in H1, first paragraph, and 1-2 H2s. 1,500-2,500 words. 3-5 internal links. Meta title under 60 chars (keyword-front-loaded). Meta description under 155 chars with clear value; add a CTA only when useful.

```text
# [H1 -- Target keyword, under 60 chars]

[Intro paragraph -- hook + promise + what they'll learn]

## [H2 -- Section 1]
[Content -- 200-400 words]

## [H2 -- Section 2]
[Content -- 200-400 words]

### [H3 -- Subsection if needed]

## [H2 -- Section 3]

## Key Takeaways
[Aim for three concise takeaways; use fewer or more when the substance warrants it]
- [Bullet 1]
- [Bullet 2]
- [Bullet 3]

## [Optional CTA Section]
[Include only when there is a useful offer or next step]
```

### Email Copy

**Newsletter**: 300-500 word body, single narrative thread.

```text
SUBJECT: [5 variants for A/B testing]
PREVIEW: [Under 90 chars -- extends the subject line]

[Opening hook -- personal, story-driven]

[Body -- single narrative thread]

[Optional CTA -- one clear action, button, or link when the email needs one]

P.S. [Secondary hook or bonus value]
```

**Sequence**:

```text
EMAIL 1 (Day 0): Welcome + immediate value
EMAIL 2 (Day 1): Story + pain point
EMAIL 3 (Day 3): Solution + social proof
EMAIL 4 (Day 5): Offer + urgency
EMAIL 5 (Day 7): Last chance + FAQ
```

### Podcast Script

```text
# Episode: [Title]

## INTRO (0:00-1:00)
- [Hook -- why this matters today]
- [What they'll learn]
- [Sponsor read if applicable]

## SEGMENT 1: [Topic] (1:00-5:00)
- [Talking point 1]
- [Talking point 2]
- [Anecdote or example]

## SEGMENT 2: [Topic] (5:00-10:00)
- [Talking points]

## SEGMENT 3: [Topic] (10:00-15:00)
- [Key insight]

## OUTRO (15:00-16:00)
- [Summary -- one sentence]
- [Optional CTA -- subscribe, review, or share when useful]
- [Next episode tease]

## SHOW NOTES
- [Timestamps]
- [Links mentioned]
- [Resources]
```

## Voice and Tone Adaptation

| Platform | Voice | Pacing | Formality |
|----------|-------|--------|-----------|
| YouTube | Conversational, energetic | Medium (150 wpm) | Low-medium |
| Short-form | Punchy, direct | Fast (170 wpm) | Low |
| X | Sharp, opinionated | Rapid | Low |
| LinkedIn | Thoughtful, professional | Measured | Medium-high |
| Reddit | Authentic, helpful | Natural | Low |
| Blog | Authoritative, clear | Steady | Medium |
| Email | Personal, direct | Conversational | Low-medium |
| Podcast | Warm, storytelling | Natural (140 wpm) | Low |

## Quality Checklist

- [ ] Hook in first line/sentence
- [ ] Voice matches platform (see table above)
- [ ] Layout follows the medium-aware default or a documented override
- [ ] At most one useful CTA; omitted when no action is needed
- [ ] Platform-native language (no cross-posting smell)
- [ ] Video: dialogue chunks under 8s, captions included, B-roll directions present
- [ ] Blog: SEO elements present (meta title, description, keywords)
- [ ] Email: subject line variants included
- [ ] Final product-facing copy receives one `content/humanise.md` pass after channel adaptation

## Related

- `content/story.md` -- Narrative framework and hook variants
- `content/production-image.md` -- Visual assets referenced in scripts
- `content/production-video.md` -- Video production specs for script adaptation
- `content/production-audio.md` -- Voice pipeline for script delivery
- `content/distribution-*.md` -- Channel-specific conventions for final adaptation
- `content/humanise.md` -- Final product-copy pass
- `content.md` -- Parent orchestrator (diamond pipeline)
