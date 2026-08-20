---
name: context-templates
description: Context file templates for SEO content creation (brand voice, style guide, keywords, links)
mode: subagent
model: simple
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Content Context Templates

Optional project-level `context/*.md` files for SEO content creation. Adapted from [TheCraigHewitt/seomachine](https://github.com/TheCraigHewitt/seomachine) (MIT License). Setup: `mkdir -p context`, copy the templates you need — auto-detected by `seo-writer.md`, `editor.md`, and `internal-linker.md`.

### context/brand-voice.md

```markdown
# Brand Voice Guide
## Voice Pillars
- **[Pillar 1]**: [Description]
- **[Pillar 2]**: [Description]
- **[Pillar 3]**: [Description]
## Tone by Content Type
| Content Type | Tone | Example |
|---|---|---|
| Blog posts | [conversational, expert] | "Here's what we found..." |
| Landing pages | [confident, direct] | "Get started in minutes" |
| Documentation | [clear, helpful] | "Follow these steps..." |
## Core Messages
1. [Primary value proposition]
2. [Secondary message]
3. [Differentiator]
## Writing Style
- **Sentence length**: [Mix of short and medium]
- **Vocabulary level**: [Professional but accessible]
- **Contractions**: [Yes/No]
- **Person**: ["We" for company, "You" for reader]
- **Preferred / Avoided terms**: [List here]
```

### context/style-guide.md

```markdown
# Style Guide
## Grammar and Formatting
- **Oxford comma**: [Yes/No]
- **Capitalization**: [Title case / Sentence case for headings]
- **Numbers**: [Spell out under 10 / Always digits]
- **Dates**: [January 15, 2026]
- **Headings**: [H2 main sections, H3 subsections]
- **Lists**: [Bullet unordered, numbered for steps]
- **Emphasis**: [Bold for key terms, backticks for code]
## Terminology
| Use | Don't Use |
|---|---|
| [preferred term] | [avoided term] |
## Content Structure
- Introduction: [Hook + context + promise]
- Body: [H2 sections every 300-400 words]
- Conclusion: [Summary + CTA]
```

### context/target-keywords.md

```markdown
# Target Keywords
## Pillar Topics
### [Topic Cluster Name]
- **Pillar keyword**: [main keyword] (volume: X, difficulty: Y)
- **Cluster keywords**: [subtopic 1] (vol: X), [subtopic 2] (vol: X)
- **Long-tail variations**: [long-tail 1], [long-tail 2]
- **User job / desired outcome**: [what the audience needs to complete]
- **Classic search intent**: [informational/navigational/commercial/transactional]
- **Journey state**: [discover/understand/evaluate/act/use-resolve/monitor]
- **Material constraints**: [audience/location/budget/time/risk/format/exclusions]
- **Query evidence**: [source IDs; source class; evidence state/role; captured window]
- **Privacy/export status**: [public/internal/sensitive/redacted]
- **Trend state**: [evergreen/seasonal/rising/event-driven/decaying/uncertain]
Repeat structure per cluster.
## Current Rankings
| Keyword | Position | URL | Opportunity |
|---|---|---|---|
| [keyword] | [pos] | [url] | [action needed] |
```

### context/internal-links-map.md

```markdown
# Internal Links Map
## Product/Feature Pages
- [/features](/features) - Main features overview (anchor: "our features")
- [/pricing](/pricing) - Pricing plans (anchor: "pricing", "plans")
## Pillar & Top Content
- [/blog/guide-to-X](/blog/guide-to-X) - Primary pillar (anchor: "complete guide to X")
- [/blog/how-to-Z](/blog/how-to-Z) - High traffic (anchor: "how to Z")
## Topic Clusters
### Cluster: [Topic A]
- Pillar: /blog/topic-a-guide
- Cluster: /blog/topic-a-subtopic-1, /blog/topic-a-subtopic-2
```

### context/competitor-analysis.md

```markdown
# Competitor Analysis
## Primary Competitors
| Competitor | Domain | Strengths | Weaknesses |
|---|---|---|---|
| [Name] | [domain.com] | [what they do well] | [gaps we can exploit] |
## Content Strategy Comparison
| Topic | Us | Competitor A | Competitor B | Gap |
|---|---|---|---|---|
| [topic] | [our coverage] | [their coverage] | [their coverage] | [opportunity] |
## Keyword Gaps
- [keyword] - [competitor] ranks #[X], we don't rank
```

### context/seo-guidelines.md

```markdown
# SEO Guidelines
## Content Requirements
- Minimum word count: 2,000 (optimal: 2,500-3,000)
- Primary keyword density: 1-2%
- Reading level: Grade 8-10
## On-Page SEO
- Meta title: 50-60 chars, keyword near front
- Meta description: 150-160 chars, keyword + CTA
- H1: single, includes primary keyword
- H2: 4+ sections, 2-3 include keyword variations
- Internal links: 3-5 per article
- External links: 2-3 to authoritative sources
## Technical
- URL slug: lowercase, hyphens, include keyword
- Image alt text: descriptive, include keyword variation
- Schema markup: Article, FAQ, HowTo as appropriate
```
