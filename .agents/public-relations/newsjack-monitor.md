---
description: Monitor current news for credible newsjacking opportunities using direct sources
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Newsjack Monitor

Find timely public stories the client can credibly comment on. Monitoring collects evidence; PR judgment decides whether to act.

## Profile fields

- Company, website, one-sentence description.
- 6-8 broad beat topics.
- Competitors/adjacent platforms/regulators.
- Standing areas and proof assets.
- Spokespeople.
- Source feeds/search terms.
- Audience question and search-intent clusters when relevant, sourced through
  `seo/conversational-search-intent.md` with locale and recency window.
- Client exclusions and “never pitch” preferences.

## Direct-source pipeline

1. Collect recent articles from RSS/Atom, outlet pages, public search, regulator feeds, and user-provided sources.
2. Deduplicate by canonical URL, title similarity, outlet/date, and source-of-record.
3. Filter obvious non-news: docs, SEO pages, product pages, press-release wires unless explicitly relevant.
4. Run `newsworthiness-check.md` and story-origin freshness checks.
5. Triage into `pitch_ready`, `big_story_watch`, or `watch_context`.
6. Run `reactive-comment.md` or `media-list-builder.md` only for pitch-ready items.

Search interest and conversational query growth can prioritize monitoring, but
neither establishes that a story is true, newsworthy, or within the client's
standing. Keep query evidence separate from article evidence.

## Report sections

- Pitch-ready: fresh, standing, source-backed angle.
- Big stories worth watching: important but no confirmed standing.
- Watch/context: stale, weak, off-brief, or unverified.

Disclose what was searched, what could not be verified, and any collapsed duplicates.
