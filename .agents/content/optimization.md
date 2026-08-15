---
name: optimization
description: A/B testing, variant generation, analytics loops, and content performance optimization
mode: subagent
model: standard
tools:
  read: true
  write: true
  bash: true
  glob: true
  grep: true
  webfetch: true
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Content Optimization

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Optimize content via A/B testing, variant generation, and analytics-driven iteration
- **Input**: Published content, performance metrics, test hypotheses
- **Output**: Evidence-qualified candidate variants, approval-bound optimization recommendations, analytics insights
- **Related**: `content/production-*.md` (variants), `content/distribution-*.md` (platform metrics), `content/research.md` (next cycle)
- **Core rules**: Preregister hypothesis/control/metrics | Meet sample and privacy thresholds | Check guardrails and freshness | Human approval before consequential changes

<!-- AI-CONTEXT-END -->

## A/B Testing Discipline

### Testing Thresholds

| Metric | Threshold | Action |
|--------|-----------|--------|
| Variants tested | 10+ | Required before declaring winner |
| Sample size | 250+ | Minimum views/impressions per variant |
| Performance | <2% | Kill — redirect effort |
| Performance | 2-3% | Scale — produce more |
| Performance | >3% | Go aggressive — winner |

**Platform minimums**: YouTube: 250 impressions, 2% CTR, 50% retention | TikTok: 500 views, 70% completion | Blog: 100 visitors, 2min+ avg | Email: 250 sends, 20% open | Thumbnail: 1000 impressions, 5% CTR

**Statistical validity**: Preregister the primary metric, control, guardrails,
minimum sample, duration, exclusions, and stopping policy. The default decision
threshold is 95% confidence, 7+ days for day-of-week variance, and 14+ days for
audiences under 1000, but power analysis and inherited privacy minimums may
require more evidence. Do not peek, extend, or swap metrics to manufacture a
winner.

### What to Test (priority order)

1. **Hooks** (first 3s / headline / thumbnail) — 80% of performance variance
2. **Angles** (pain vs aspiration, contrarian vs consensus, before/after)
3. **Format** (long vs short, video vs text, listicle vs narrative)
4. **Thumbnails** (faces vs text, color, composition)
5. **CTAs** (placement, wording, urgency)
6. **Length** (word count, duration, scene count)
7. **Publishing time** (day, time)

**Hook types** (generate 5-10 per topic): Bold Claim, Question, Story, Contrarian, Result, Problem-Agitate, Curiosity Gap. Examples: "95% of AI influencers fail — here's why" | "I spent $10K on AI video tools — here's what worked" | "Stop using Sora for UGC content"

**Thumbnail pipeline** (`thumbnail-helper.sh`):

```bash
thumbnail-helper.sh generate "Your Video Topic" --count 10 --template high-contrast-face
thumbnail-helper.sh batch-score ~/.cache/aidevops/thumbnails/[output_dir]/
thumbnail-helper.sh ab-test VIDEO_ID ~/.cache/aidevops/thumbnails/[output_dir]/
thumbnail-helper.sh analyze VIDEO_ID
```

### Test Execution

1. **Generate**: 10+ variants via `content/production-*.md` agents
2. **Deploy**: YouTube A/B, TikTok separate videos, Google Optimize for blog, email list split
3. **Collect**: 250+ samples per variant (CTR, retention, completion, time on page)
4. **Analyze**: Use `marketing-optimization-helper.py experiment`; require preregistered sample, duration, confidence, privacy, and guardrail checks
5. **Review candidates**: Route creative changes to Content, channel/campaign changes to Marketing, and product changes to Product; preserve owner approval
6. **Batch cycle**: Week 1 produce → Week 2 collect → Week 3 analyze + kill bottom 7 → Week 4 produce from top 3

## Variant Generation

**Hook variants**: 10 per topic, all 7 types, 6-12 words each. Prompt: `Generate 10 hook variants for topic: [topic]. Use all 7 hook types, 6-12 words each. Output as table: Type | Hook | Word Count`

**Seed bracketing** (see `content/production-video.md`): Ranges — People 1000-1999, Action 2000-2999, Landscape 3000-3999, Product 4000-4999. Test 10 outputs; score: Composition 30%, Quality 30%, Style 20%, Accuracy 20%. Threshold: 4.0+ winner, 3.0-3.9 maybe, <3.0 reject. Cuts AI video costs ~60% (15% → 70%+ success).

**Scene-level testing**: Publish → analyze retention curve → identify >10% drops in <5s → generate 3-5 scene variants (B-roll, pacing, music, angle) → re-upload → compare → scale winner.

**Thumbnail scoring**: CTR 50%, Text readability 20%, Face prominence 15%, Contrast 10%, Emotion 5%. Style template (Nanobanana Pro JSON): define palette/font/composition/lighting, swap subject, keep style constant. Test 10 thumbnails across 10 videos at 1000+ impressions.

## Analytics — Platform Metrics & Thresholds

| Platform | Metric | Bad | Good | Great | Action |
|----------|--------|-----|------|-------|--------|
| YouTube | CTR | <2% | 2-5% | >5% | Test thumbnails/titles → scale → replicate |
| YouTube | Retention | <30% | 30-50% | >50% | Test hooks → optimize pacing → replicate format |
| TikTok/Reels/Shorts | Completion | <50% | 50-70% | >70% | Fix hook → optimize → replicate |
| TikTok/Reels/Shorts | Shares | — | — | >3% | Viral potential — go aggressive |
| TikTok/Reels/Shorts | Saves | — | — | >5% | High value — make more |
| Blog/SEO | Time on page | <1min | 1-3min | >3min | Content thin → decent → resonates |
| Blog/SEO | Scroll depth | <50% | — | >50% | Hook failed or too long |
| Blog/SEO | Bounce rate | >70% | — | <70% | Wrong audience or poor hook |
| Email | Open rate | <15% | 15-25% | >25% | Test subject lines → good → replicate |
| Email | Click rate | <2% | 2-5% | >5% | CTA failed → decent → offer works |

**Retention analysis**: YouTube Studio → Analytics → Retention → Export CSV. Identify >10% drops in <5s. Categorize: Hook failure (0:00-0:10), Pacing issue (gradual), Scene failure (sharp), Natural exit (gradual at end). Hypothesize → test fixes → compare.

**Content calendar**:

```bash
content-calendar-helper.sh cadence --weeks 1    # last week performance
content-calendar-helper.sh gaps --days 7        # missing next week
content-calendar-helper.sh due --days 7         # upcoming
content-calendar-helper.sh stats                # overall health
```

**Cadence**: YouTube 2-3/week | Shorts/TikTok/Reels daily | Blog 1-2/week | Email 1/week | Social daily

**Seasonality**: Q4 (Oct-Dec) highest buying intent → reviews, comparisons, affiliate. Q1 educational/how-to. Q2-Q3 experiment + build backlog.

**Feedback loop**: Publish with approval → collect normalized evidence → build a
freshness-aware aggregate report → analyze the preregistered test → review the
candidate recommendation → retest. Observational attribution can suggest a test,
but cannot justify a causal winner.

## Performance Evidence Handoff

Consume only privacy-safe projections from the Performance Plane. A usable
handoff includes source snapshot and coverage, attribution model/window/version,
experiment analysis ID, primary and guardrail metrics, aggregate sample sizes,
confidence, freshness, caveats, and any contradicting evidence. Sparse cohorts
remain suppressed and raw journeys or subject IDs do not enter content briefs.

Recommendations must name the observed problem, target metric, expected impact
range, confidence, owner, required approval, rollback, and retest date. They are
decision inputs only: this agent does not autonomously publish, message, change
spend, retarget, change audiences/offers, or mutate provider accounts.

## Proven First, Original Second

1. Find proven content: top YouTube videos, viral TikToks, high-traffic posts (Ahrefs/SEMrush)
2. Replicate structure (same hook type, different topic) — copy format, not content
3. Add 3% twist: different personality, visual style, examples, or contrarian take
4. Test 10 variants → scale winner. Example: "I spent $10K testing every AI video tool" (1M views) → twist: "free ones that beat paid" / "why I refunded 90%"

## Tools & Integration

**Analytics**: YouTube Studio, TikTok Analytics, Google Analytics, Google Search Console (`seo/google-search-console.md`), DataForSEO (`seo/dataforseo.md`)

**A/B testing**: YouTube Studio (thumbnails), Google Optimize (website), VWO, Optimizely

**Scripts**: `content-calendar-helper.sh` (calendar/cadence/gaps, t208) | `analytics-helper.sh` (cross-platform reports) | `variant-generator-helper.sh` (10 variants) | `seed-bracket-helper.sh` (AI video seed testing) | `thumbnail-factory-helper.sh` (thumbnail variants, t207)

**Feeds into**: `content/research.md` (next research), `content/production-*.md` (next batch). **Uses from**: `content/distribution-*.md` (analytics), `content/production-*.md` (variants). **Related**: `tools/task-management/beads.md`, `reference/memory.md`.

**After optimization**: Promote only reviewed, privacy-safe validated learning.
Keep the experiment and decision references, note novelty/seasonality limits,
and supersede prior recommendations instead of erasing their audit trail.
