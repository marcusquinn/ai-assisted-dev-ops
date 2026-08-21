---
name: email
description: Email distribution - newsletters, sequences, and automated campaigns
mode: subagent
model: standard
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Email - Newsletter and Sequence Distribution

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Distribute content via email newsletters, automated sequences, and campaigns
- **Formats**: Weekly newsletter, welcome sequence, launch sequence, nurture sequence
- **Key Principle**: Permission-based, value-first, relationship-building
- **Success Metrics**: Open rate, click rate, reply rate, unsubscribe rate
- **CRM Integration**: FluentCRM via `marketing-sales.md` and `services/crm/fluentcrm.md`

**Critical Rules**:

- **Subject line is the hook** — 80% of email success; under 50 chars for mobile
- **One CTA per email** — multiple CTAs reduce click-through rate
- **Mobile-first** — 60%+ opens on mobile; 600px max width, 16px+ body font
- **Value before ask** — minimum 3:1 value-to-promotion ratio
- **Segment aggressively** — personalized emails outperform broadcasts 6x

<!-- AI-CONTEXT-END -->

## Email Types

### Weekly Newsletter

**Structure**: (1) Subject line — curiosity hook or value promise, under 50 chars. (2) Preview text — extends the hook, under 90 chars. (3) Personal opener (2-3 sentences). (4) Main content (200-400 words) — one key insight. (5) Content roundup (3-5 links). (6) CTA — one clear action. (7) PS line — secondary offer (highest-read section after subject).

**Cadence**: Weekly, same day and time (consistency builds habit).

**Example**:

```text
Subject: The 5 mistakes killing AI influencers
Preview: I studied 50 creators for 6 months. Here's what I found.

Hey [Name],

I spent the last 6 months studying 50 AI content creators.
The pattern was brutal: 95% making the same 5 mistakes.

The one that surprised me most: they chase tools instead of problems.

The creators actually growing? They research their audience
obsessively, edit AI output ruthlessly, and test 10 variants
before committing.

I broke down all 5 mistakes in this week's video: [link]

What's your biggest challenge with AI content?
Hit reply - I read every response.

[Name]

PS - Reply "GUIDE" for early access to my free AI content system guide.
```

### Welcome Sequence (5-7 emails)

Onboard new subscribers, establish value, segment by interest.

| Email | Timing | Purpose | Content |
|-------|--------|---------|---------|
| **1** | Immediate | Deliver lead magnet + set expectations | Welcome, download link, what to expect |
| **2** | Day 1 | Quick win | One actionable tip they can use today |
| **3** | Day 3 | Story + credibility | Your journey, results, why you're qualified |
| **4** | Day 5 | Deep value | Best framework or methodology |
| **5** | Day 7 | Social proof | Case study or testimonial |
| **6** | Day 10 | Soft pitch | Introduce paid offering with value framing |
| **7** | Day 14 | Direct pitch | Clear CTA with urgency or bonus |

Each email stands alone. Build trust before asking. Segment based on clicks. Remove non-openers after email 3.

### Launch Sequence (5-7 emails)

| Email | Timing | Purpose | Content |
|-------|--------|---------|---------|
| **1** | Day -3 | Anticipation | Problem awareness, hint at solution |
| **2** | Day -1 | Story | Your journey solving this problem |
| **3** | Day 0 | Launch | Product reveal, benefits, early-bird offer |
| **4** | Day 1 | Social proof | Testimonials, case studies, results |
| **5** | Day 3 | FAQ | Objection handling, common questions |
| **6** | Day 5 | Scarcity | Deadline reminder, bonus expiring |
| **7** | Day 7 | Last chance | Final call, urgency, FOMO |

### Nurture Sequence

Weekly or bi-weekly for subscribers who didn't convert. Content mix: 60% educational (tips, frameworks) · 20% story-driven (experiences, case studies) · 10% curated (resources, tools) · 10% promotional (soft pitches).

## Subject Line Formulas

| Formula | Example | Why It Works |
|---------|---------|-------------|
| **Number + benefit** | "[Verified number] tools that save [verified time]" | Specific, scannable |
| **Question** | "Are you making this AI content mistake?" | Curiosity gap |
| **How-to** | "How to reach [verified output] with [method]" | Clear value |
| **Contrarian** | "Stop using ChatGPT for content" | Pattern interrupt |
| **Personal** | "I tested [verified sample] so you don't have to" | Authenticity |
| **Urgency** | "Last chance: AI content guide (free until Friday)" | Scarcity |
| **Curiosity** | "The AI video secret nobody talks about" | Open loop |
| **Social proof** | "How [Name] reached [verified result] with [method]" | Aspirational |

Bracketed claims require source evidence, and personal subject lines require real first-person experience. No ALL CAPS or excessive punctuation (spam triggers). Use personalization tokens. A/B test 2-3 variants per send.

## Email Design

**Mobile-first layout**: 600px max width · 16px+ body font · 22px+ headings · 44px min CTA button height, high contrast · images optional · single column only.

| Format | Best For | Open Rate Impact |
|--------|----------|-----------------|
| **Plain text** | Personal newsletters, B2B | Higher (feels personal) |
| **Light HTML** | Branded newsletters, B2C | Moderate (professional) |
| **Heavy HTML** | E-commerce, promotions | Lower (feels promotional) |

## Segmentation

| Segment | Criteria | Content Strategy |
|---------|----------|-----------------|
| **Engaged** | Opened 3+ of last 5 | Full content, early access, premium offers |
| **Casual** | Opened 1-2 of last 5 | Re-engagement, best-of content, surveys |
| **Cold** | No opens in 30+ days | Win-back sequence, then remove |
| **Buyers** | Purchased any product | Upsell, loyalty, exclusive content |
| **Clickers** | Clicked specific topic links | Topic-specific content and offers |

Tag subscribers by: lead magnet downloaded, links clicked, survey responses, purchase history.

## FluentCRM Automation

**Integration**: `marketing-sales.md` and `services/crm/fluentcrm.md` for contact management, segmentation, sequence creation, and analytics.

**Triggers**: New subscriber → welcome sequence · Link click → tag + segment · Purchase → buyer sequence · No open 30 days → win-back · Unsubscribe → exit survey.

## Analytics and Optimization

| Metric | Target | Action if Below |
|--------|--------|----------------|
| **Open rate** | 30%+ | Improve subject lines, clean list |
| **Click rate** | 3%+ | Improve CTA, content relevance |
| **Reply rate** | 1%+ | More personal tone, ask questions |
| **Unsubscribe rate** | Under 0.5% | Check frequency, content quality |
| **Spam complaint rate** | Under 0.1% | Review opt-in process, add unsubscribe |

**A/B Testing**: See `content/optimization.md` for full methodology. Test subject lines (2-3 variants), send times (4-week cycles), CTA placement, content length. Minimum 250 subscribers per variant.

## Related Agents and Tools

**Content Pipeline**: `content/research.md` (audience research) · `content/story.md` (hooks, narrative) · `content/guidelines.md` (standards) · `content/optimization.md` (A/B testing, analytics)

**CRM and Marketing**: `marketing-sales.md` (orchestrator) · `services/crm/fluentcrm.md` (CRM ops)

**Email Services**: `tools/accessibility/accessibility-audit.md` (WCAG compliance) · `services/email/email-health-check.md` (DNS, deliverability) · `services/email/email-testing.md` (rendering, delivery overview) · `services/email/email-design-test.md` (cross-client rendering) · `services/email/email-delivery-test.md` (inbox placement, spam scoring)

**Pre-Send Testing** (via `email-test-suite-helper.sh`):

1. Content checks — subject, preheader, accessibility, links, spam words (`email-health-check-helper.sh`)
2. Design rendering — cross-client screenshots (`email-design-test-helper.sh`)
3. Delivery testing — inbox placement, spam score, auth (`email-delivery-test-helper.sh`)
