---
name: social
description: Social media distribution - approval-bound platform-native content
mode: subagent
model: standard
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Social Distribution

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Distribute content across X, LinkedIn, Reddit, and YouTube with platform-native tone and format
- **Key Principle**: Same story, different delivery — adapt voice and format per platform
- **Metrics**: Engagement rate, shares, profile visits, link clicks

**Critical Rules**:

- **Platform-native tone** — cross-posting identical content underperforms
- **No promotional language on Reddit** — community-first or get downvoted
- **Hook-first on X** — front-load value in first line (visible before truncation)
- **Professional framing on LinkedIn** — thought leadership, not sales pitch
- **One idea per post** — clarity beats comprehensiveness

**Platform Tools**: `content/social-xurl.md` (official X API),
`content/social-linkedin.md`, `content/social-reddit.md`, `content/social-meta.md`,
`content/social-tiktok.md`, and `content/social-youtube.md`. Meta, TikTok,
LinkedIn, and YouTube writes require the approved outbound queue; unavailable
capability states do not permit browser fallbacks.

<!-- AI-CONTEXT-END -->

## Platform Profiles

### X (Twitter)

**Voice**: Concise, opinionated, personality-forward. Sharpest of all platforms.

| Format | Length | Best For |
|--------|--------|----------|
| **Single post** | Under 280 chars | Hot takes, links, announcements |
| **Thread** | 3-10 posts | Breakdowns, stories, tutorials |
| **Quote post** | 1 sentence + context | Commentary, amplification |
| **Poll** | Question + 2-4 options | Engagement, audience research |

**Thread structure**: Hook (bold claim/stat/question) → Context (why it matters) → Body (3-7 posts, one insight each) → Summary (one sentence) → CTA (follow/repost/bookmark/link). Number posts (1/7).

**Rules**: No preamble. Line breaks for scannability. 0-2 hashtags max (X penalizes spam). Best times: weekdays 9-11am, 1-3pm local.

**Example adaptation**:

```text
Story: "Why 95% of AI influencers fail"

X Thread (7 posts):
1/ 95% of AI influencers will fail this year. Not because the tech is bad. Because they're making the same 5 mistakes.
2/ Mistake 1: They chase tools, not problems. Nobody cares about your Sora 2 demo. They care about solving their video production bottleneck.
3/ Mistake 2: They post AI-generated content without editing. Your audience can tell. They always can.
...
7/ The 5% who succeed? They research first, create second, and optimize third. That's the entire playbook. Follow for the deep dive.
```

### LinkedIn

**Voice**: Professional, authoritative, thought-leadership. More formal than X, less formal than whitepaper.

| Format | Length | Best For |
|--------|--------|----------|
| **Text post** | 150-300 words | Opinions, lessons, quick insights |
| **Article** | 800-2,000 words | Deep dives, case studies |
| **Carousel** | 8-12 slides, 20-40 words each | Frameworks, step-by-step guides |
| **Document** | 5-15 pages | Reports, playbooks |
| **Poll** | Question + 4 options | Engagement, market research |

**Post structure**: Hook line (visible before "see more") → Line break → Body (one thought per line) → Key insight → CTA (question or link).

**Rules**: Liberal line breaks. 3-5 hashtags at end. Personal stories outperform corporate announcements. Avoid: corporate jargon, "excited to announce", empty self-promotion. Best times: Tue-Thu 8-10am local. Reply to every comment (algorithm boost).

**Example adaptation**:

```text
Story: "Why 95% of AI influencers fail"

LinkedIn Post:
Most AI influencers will fail this year.

Not because the technology isn't good enough.

Because they're solving the wrong problem.

I spent 6 months studying the top 50 AI content creators.
The pattern was clear:

The ones who succeed don't talk about tools.
They talk about outcomes.

Here's what separates the 5% who make it:

1. They research their audience before creating content
2. They edit AI output ruthlessly (your audience can always tell)
3. They optimize based on data, not gut feeling
4. They build systems, not one-off posts
5. They solve real problems, not demo features

The AI content gold rush is real.
But the winners won't be the ones with the best tools.

They'll be the ones who understand their audience best.

What's your biggest challenge with AI content? Drop it below.

#AIContent #ContentStrategy #CreatorEconomy
```

### Reddit

**Voice**: Community-native, authentic, anti-promotional. Reddit users detect and punish marketing instantly.

| Format | Best For |
|--------|----------|
| **Text post** | Discussions, questions, sharing experiences |
| **Link post** | Sharing resources (with genuine context) |
| **Comment** | Adding value to existing discussions |
| **AMA** | Building authority in a niche |

**Subreddit strategy**: Identify target subreddits → Lurk to learn norms → Add value (answer questions, share experiences) → Build karma → Share content only when genuinely relevant.

**Rules**: Never lead with self-promotion. Write like a community member. Use subreddit language/conventions. Follow self-promotion rules (typically 10:1 ratio). Respond to comments. Best times: weekday mornings US time.

**Example adaptation**:

```text
Story: "Why 95% of AI influencers fail"

Reddit Post (r/artificial):
Title: After studying 50 AI content creators for 6 months, here's what separates the ones who make it

I've been tracking AI content creators since mid-2025. Not as a fan - as someone trying to understand what actually works.

The short version: most of them are doing the same thing wrong.

They demo tools instead of solving problems. Their audience doesn't care about Sora 2 Pro's new features. They care about making better videos faster.

The creators who are actually growing:
- Research their audience obsessively (Reddit is a goldmine for this)
- Edit AI output until it doesn't feel like AI
- Test 10 variants before committing to one approach
- Build repeatable systems instead of one-off viral attempts

Happy to share more details on the research methodology if anyone's interested.

[No links, no self-promotion, genuine discussion starter]
```

## Cross-Platform Strategy

### Content Adaptation Matrix

| Source Asset | X | LinkedIn | Reddit |
|-------------|---|----------|--------|
| **YouTube video** | Key insight thread (5-7 posts) | Case study post (200-300 words) | Discussion post with learnings |
| **Blog post** | Thread with main takeaways | Article repost or summary | Link post with genuine context |
| **Short-form video** | Embed with hook text | Native video upload | Link to YouTube (if allowed) |
| **Research finding** | Single punchy post | Data-driven thought piece | Detailed methodology share |
| **Case study** | Before/after thread | Full narrative post | Experience-sharing post |

### Posting Cadence

| Platform | Frequency | Best Times | Content Mix |
|----------|-----------|------------|-------------|
| **X** | 3-5/day | 9-11am, 1-3pm | 50% value, 30% engagement, 20% promotion |
| **LinkedIn** | 1-2/day | Tue-Thu 8-10am | 60% thought leadership, 30% stories, 10% promotion |
| **Reddit** | 2-3/week | Weekday mornings | 90% value/discussion, 10% content sharing |

### Batch Workflow

1. Start with story from `content/story.md`
2. Generate platform variants using adaptation matrix
3. Review tone against platform profiles
4. Schedule using platform tools or Buffer/Hootsuite
5. Monitor engagement and iterate

## Engagement

| Platform | Daily Actions |
|----------|--------------|
| **X** | Reply to comments within 1hr. Quote-repost industry posts with your take. Engage 10-20 niche accounts. Pin best thread. |
| **LinkedIn** | Reply to every comment (algorithm boost). Comment on 5-10 network posts. Share others' content with added perspective. |
| **Reddit** | Answer niche subreddit questions. Upvote quality posts. Build genuine relationships. Never argue — provide evidence and move on. |

## Analytics

| Platform | Primary Metric | Secondary Metrics |
|----------|---------------|-------------------|
| **X** | Impressions + engagement rate | Profile visits, link clicks, follower growth |
| **LinkedIn** | Engagement rate + reach | Profile views, connection requests, article reads |
| **Reddit** | Upvotes + comment quality | Karma growth, cross-post performance |

**A/B testing** (details in `content/optimization.md`): Test 3-5 hook variants per topic. 250-impression minimum before judging. Below 2% engagement = revise. Above 3% = scale and repurpose.

## Related

**Content Pipeline**: `content/research.md` (audience research), `content/story.md` (hooks/narrative), `content/platform-personas.md` (legacy voice), `content/optimization.md` (A/B testing)

**Distribution**: `content/distribution/youtube/`, `content/distribution/short-form.md`, `content/distribution/blog.md`, `content/distribution/email.md`, `content/distribution/podcast.md`

**Tools**: `content/social-xurl.md` (official X API), `content/social-bird.md` (fallback), `content/social-linkedin.md`, `content/social-reddit.md`, `content/humanise.md` (AI pattern removal)

**Approval-bound publishing**: `content/social-meta.md`, `content/social-tiktok.md`, and the outbound queue. Verify capability readiness, product identity, media rights, and an unexpired exact-intent approval before scheduling.
