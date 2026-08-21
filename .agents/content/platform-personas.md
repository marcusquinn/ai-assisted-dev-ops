---
name: platform-personas
description: Platform-specific content adaptations - voice, tone, structure, and best practices per channel
mode: subagent
model: simple
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Platform Persona Adaptations

Base voice: `context/brand-identity.toon`, then `context/brand-voice.md` or the product brief. Use `content/guidelines.md` for screen layout, not as a substitute for brand evidence. See `tools/design/brand-identity.md`.

**Workflow**: establish core voice → apply platform shift below → identity constant, delivery changes.

## Platform Quick Reference

| Platform | Register | Perspective | Cadence |
|----------|----------|-------------|---------|
| LinkedIn | Professional, thought-leadership | "I" (personal) / "We" (company) | 3-5x/week, Tue-Thu 8-10am |
| Instagram | Casual, visual-first, aspirational | "We", behind-the-scenes | Mon-Fri 11am-1pm, 7-9pm |
| YouTube | Educational, conversational | Direct "you", presenter-led | — |
| X (Twitter) | Concise, opinionated | Personality-forward | Weekdays 9-11am, 1-3pm |
| Facebook | Community-oriented, warm, local | "We" as neighbour | Wed-Fri 1-4pm |
| Blog | Expert, thorough, SEO-aware | "We" (company), "you" (reader) | — |

## LinkedIn

| Format | Length | Best For |
|--------|--------|----------|
| **Text post** | 150-300 words | Opinions, lessons, quick insights |
| **Article** | 800-2,000 words | Deep dives, case studies |
| **Carousel** | 8-12 slides, 20-40 words each | Frameworks, step-by-step guides |
| **Document** | 5-15 pages | Reports, playbooks |

- Open with a hook (question, bold claim, or surprising stat)
- One thought per line; end with question or CTA
- Hashtags: 3-5 at the end
- Avoid: corporate jargon, "excited to announce", empty self-promotion

**Example**: "We build custom timber windows that last decades." → "Most replacement windows fail within 15 years.\n\nWe engineered ours to last 30+.\n\nHere's what makes the difference (thread):"

## Instagram

| Format | Caption Length | Best For |
|--------|---------------|----------|
| **Feed post** | 50-150 words | Portfolio, finished work, tips |
| **Carousel** | 30-80 words + slide text | Tutorials, before/after, lists |
| **Story** | 1-2 sentences overlay | Daily updates, polls, BTS |
| **Reel** | 30-80 words caption | Process videos, quick tips |

- Lead with the visual — caption supports, not replaces
- First line is the hook (visible before "more" truncation)
- Emoji sparingly as visual breaks; hashtags: 5-15 (mix niche + broad), rotate sets
- Alt text on every image (accessibility + SEO)
- Place hashtags in first comment or end of caption (test both)
- Avoid: walls of text, hard-sell language, stock photo aesthetics

## YouTube

| Format | Length | Best For |
|--------|--------|----------|
| **Short** | 30-60 seconds | Quick tips, single concepts |
| **Tutorial** | 8-15 minutes | How-to, walkthroughs |
| **Deep dive** | 15-30 minutes | Case studies, comparisons |
| **Vlog** | 5-10 minutes | Behind-the-scenes, day-in-life |

- Title: keyword-front, under 60 chars, curiosity or value hook
- Description: first 2 lines visible — include keyword and value prop
- Thumbnail: high contrast, readable text, expressive face or clear subject
- Chapters: timestamps for videos over 5 minutes
- CTA: subscribe prompt at natural break, not forced intro
- Tags: 5-10 keywords (include common misspellings)
- Avoid: clickbait, long intros, "don't forget to like and subscribe" as opener

**Script tone**: "Marine-grade coatings provide superior weather resistance." → "So we coat these with marine-grade finish — the same stuff they use on boats. And that's what stops them warping in the salt air."

## X (Twitter)

| Format | Length | Best For |
|--------|--------|----------|
| **Single post** | 1-2 sentences (under 280 chars) | Hot takes, links, announcements |
| **Thread** | 3-10 posts | Breakdowns, stories, tutorials |
| **Quote post** | 1 sentence + context | Commentary, amplification |

- Front-load the value — no preamble; one idea per post
- Threads: number them (1/7) or use hook post + replies
- Avoid: hashtag spam, @-mention chains, "RT if you agree"

## Facebook

| Format | Length | Best For |
|--------|--------|----------|
| **Post** | 40-100 words | Updates, photos, community |
| **Event** | Brief description + details | Workshops, open days |
| **Album** | 5-20 photos + captions | Project showcases |

- Write like you're talking to a neighbour; respond to every comment
- Photos of real work outperform polished graphics; ask questions to drive comments
- Avoid: corporate tone, link-only posts, engagement bait

## Blog / Website

Full standards: `content/guidelines.md`. Automation: `content/social-xurl.md` (official X API), `content/social-bird.md` (fallback), `content/social-linkedin.md` (LinkedIn).

- Longer form: 1,500-3,000 words for pillar content
- H2/H3 hierarchy; internal links (3-5 per article); one sentence per paragraph
- Meta title + description: 150-160 chars, include primary keyword
- SEO: primary keyword in title + H1 + first 100 words + meta; secondary in H2s; image alt text; URL slug under 60 chars
- Structured data: Article schema, FAQ schema where applicable, breadcrumbs

## Adaptation Framework

**Constant**: brand values, key messages, spelling conventions, honesty, expertise.
**Variable**: sentence length, formality, emoji/hashtags, content structure, CTA style, detail level.

## Cross-Platform Repurposing

```text
Blog post (2,000 words)
  -> LinkedIn article (800 words, key insights)
  -> LinkedIn carousel (8 slides, framework extract)
  -> Instagram carousel (before/after or tips)
  -> X thread (5 posts, main takeaways)
  -> YouTube script (10 min tutorial version)
  -> Facebook post (community angle + link)
```

Blog original: `content/seo-writer.md`. Adapt using platform guidelines above.
