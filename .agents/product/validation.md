---
description: Product idea validation - market research, competitive analysis, and feature scoping for any app type
mode: subagent
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

# Product Validation - Idea to Specification

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Validate product ideas, research markets, analyse competitors, scope features
- **Output**: Validated idea + feature spec + design brief ready for development
- **Tools**: Browser (store research), web search (market data), crawl4ai (review scraping)
- **Applies to**: Mobile apps, browser extensions, desktop apps, web apps, SaaS
- **Search demand**: `seo/conversational-search-intent.md` for user-job/query
  evidence; keyword providers for estimated volume; trend data for direction

<!-- AI-CONTEXT-END -->

## Idea Validation Framework

### Painkiller vs Vitamin Test

**Painkiller criteria** (need 3+):

- Solves something uncomfortable or embarrassing
- Problem occurs daily or multiple times per week
- People already trying to fix it (workarounds, other products, manual effort)
- Creates emotional urgency (guilt, fear, frustration, shame)
- People would pay to make it go away

**Red flags** (likely a vitamin):

- "It would be cool if..."
- No existing solutions (may mean no real demand)
- Solves a problem the builder has but nobody else mentions
- Requires educating users about why they need it

### Market Research Process

1. **Search relevant stores** — App Store, Play Store, Chrome Web Store, Firefox Add-ons, Product Hunt, AlternativeTo, Setapp, Mac App Store
2. **Read 1-2 star reviews** — collect candidate unmet needs
3. **Read 5-star reviews** — collect candidate valued outcomes
4. **Check download counts and ratings** — competitor-adoption and supply proxies;
   do not equate them with total market size
5. **Search social media** for complaints about the problem domain
6. **Frame search demand** — classify observed and proposed query language,
   desired outcomes, and evidence provenance with
   `seo/conversational-search-intent.md`
7. **Validate demand** — use a keyword provider for estimated volume and dated
   trend data for relative direction and seasonality

### Competitive Analysis Template

| Field | What to Record |
|-------|---------------|
| Name | Product name and developer |
| Rating | Average rating and review count |
| Price | Free, freemium, paid, subscription |
| Core feature | The one thing it does best |
| Top complaints | From 1-2 star reviews |
| Missing features | What users ask for but don't get |
| UI quality | Screenshots, design quality assessment |
| Last updated | Active development signal |
| Growth channels | How they acquire users |

### Competitor Onboarding as Benchmark Evidence

If reliable evidence shows competitor adoption or revenue, study its onboarding
as a supply/benchmark signal. Public screens do not prove why the flow performs
or that it fits your audience.

1. **Select 3-5 competitors** with the strongest verified adoption or revenue
   evidence available
2. **Screenshot every onboarding screen** — first launch to paywall
3. **Map the structure**: Questions asked, value promised, paywall placement
4. **Identify hypotheses**: Record repeated structures without claiming unseen
   A/B-test evidence
5. **Test structure, not copied content**: Validate candidate patterns with your
   users, product, and brand

Competitor pricing proves an offer exists, not willingness-to-pay or your optimal
price. Validate pricing with customer research, conversion data, or a bounded
experiment.

### Feature Scoping

**MVP rules**: One core daily action, one clean onboarding (3-5 screens), one monetisation path. No social/settings/accounts in v1 unless core to the product.

**Speed over perfection**: Ship in days, not months. Iterate on real user data.

| Priority | Criteria | Example |
|----------|----------|---------|
| P0 - Must have | Product doesn't work without it | Core action, navigation |
| P1 - Should have | Significantly improves core | Streaks, notifications |
| P2 - Nice to have | Enhances but not essential | Themes, sharing, export |
| P3 - Future | Save for v2+ | Social, integrations, widgets |

### Output: Product Specification

1. **Problem statement**: One paragraph on the pain point
2. **Target user**: Demographics, psychographics, usage context
3. **Core daily action**: The one thing users repeat
4. **Feature list**: Prioritised P0-P3
5. **Monetisation**: Revenue model (see `product/monetisation.md`)
6. **Platform**: Target platforms and rationale
7. **Design brief**: Colours, typography, mood, references
8. **Growth strategy**: Discovery channels (see `product/growth.md`)
9. **Success metrics**: Downloads, retention, revenue targets
10. **Validation evidence**: Attached intent ledger/source IDs with supported
    claims, state/role, privacy status, measured window, and evidence confidence

## Design Research

See `tools/design/design-inspiration.md` for 60+ resources. Quick workflow:

1. **Mobbin** (https://mobbin.com) — onboarding flows, navigation, paywalls
2. **Screenlane** (https://screenlane.com) — free UI screenshots by component
3. **Pinterest** — mood boards: "minimal app UI", "dark onboarding", "paywall design"
4. **Select 4-5 components** you like and capture screenshots for reference

## Store Research Techniques

### Store URLs

- App Store: `https://apps.apple.com/search?term={query}`
- Play Store: `https://play.google.com/store/search?q={query}`
- Chrome Web Store: `https://chromewebstore.google.com/search/{query}`
- Product Hunt: `https://www.producthunt.com/search?q={query}`
- AlternativeTo: `https://alternativeto.net/software/{app-name}/`
- Setapp: `https://setapp.com/search?query={query}`

### Review Extraction

Use crawl4ai or browser tools. Focus on: pain points, feature requests, praise patterns, pricing complaints.

### Trend Analysis

Record locale and comparable windows. Use trend data for relative interest,
seasonality, acceleration, and decay—not absolute search volume. Combine it with
keyword estimates, first-party query evidence, store/download signals,
community sentiment, and reviewer priorities. Classify query evidence through
`seo/conversational-search-intent.md` before turning it into product claims.

## Related

- `product/onboarding.md` - Onboarding flow design
- `product/monetisation.md` - Revenue models
- `product/growth.md` - User acquisition channels
- `product/ui-design.md` - Design standards
- `product/analytics.md` - Metrics and iteration
- `tools/mobile/app-dev.md` - Mobile development
- `tools/browser/extension-dev.md` - Extension development
