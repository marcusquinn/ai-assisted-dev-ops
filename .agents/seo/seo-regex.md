---
description: Regex patterns for Google Search Console filtering and SEO analysis
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  grep: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# SEO Regex Patterns

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Purpose**: Regex patterns for GSC query filtering, URL analysis, and SEO data processing
- **GSC syntax**: RE2 — no lookaheads/lookbehinds/backreferences. Apply via Performance > Filter > Query/Page > Matches regex.
- **Helpers**: `scripts/seo-analysis-helper.sh`, `scripts/keyword-research-helper.sh`
- **Interpretation**: `seo/conversational-search-intent.md`; regex finds
  candidates but cannot prove intent or AI-surface attribution

<!-- AI-CONTEXT-END -->

## GSC Query Filters

Copy one expression at a time; comments label separate filters. Review matched
queries only in an authorized private workspace and assign a privacy status.
Sanitize or aggregate samples before reports/exports. Starter words are
heuristic candidates, not surface attribution or complete intent labels.

```regex
# --- Brand vs Non-Brand ---
# Brand queries (replace with your brand)
(?i)\b(brand|brandname|brand\.com)\b
# Non-brand: apply the same pattern with GSC's "Does not match regex" operator

# --- Question Queries ---
# All questions
(?i)^(what|how|why|when|where|who|which|can|could|do|does|did|is|are|should|would|will)\b.*
# How-to
(?i)^how (to|do|does|can|could|should)\b.*
# Comparisons
(?i)\b(vs|versus|compared (with|to)|better than|difference between)\b

# --- Conversational Candidate Segments ---
# Task/decision directives
(?i)^(please\s+)?(act as|pretend|compare|recommend|suggest|explain|find|show|tell|give|list|plan|make|organize|estimate|optimi[sz]e|summari[sz]e|write|draft|generate|rewrite|translate|help)\b.*
# Context-dependent refinements; antecedent remains unknown in GSC
(?i)^((what|how) about|more|others?|another|next|continue|go on|show (me )?(more|map)|any other|only|instead|again|shorter|longer|fix it|compare (them|those)|why (that|this)|where else|anything else|is that all|sources?)\b.*
# Dialogue/control candidates — analyse separately from SEO opportunities
(?i)^(hi|hello|hey|good (morning|afternoon|evening)|how are you|thanks?|thank you|cheers|sorry|yes|yep|yeah|no|nope|ok|okay|perfect|great|stop|cancel|restart|try again|done|bye)[.!?]*$

# --- Intent Classification ---
# Informational
(?i)^(what|how|why|guide|tutorial|learn|example|definition)\b
# Transactional
(?i)\b(buy|price|pricing|cost|cheap|deal|discount|coupon|order|purchase|shop)\b
# Navigational
(?i)\b(login|sign in|dashboard|account|support|contact|official site)\b
# Commercial investigation
(?i)\b(best|top|review|reviews|compare|comparison|alternative|alternatives|vs|versus)\b

# --- Long-Tail ---
# 4+ words
^\S+\s+\S+\s+\S+\s+\S+
# 6+ words
^\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+\S+
```

## GSC Page Filters

```regex
# Blog posts
/blog/
# Product pages
/products?/
# Category pages
/category/|/collections?/
# Paginated pages
/page/[0-9]+
# Specific language
/en/|/en-us/
# Exclude certain paths — use "Does not match" with:
/(admin|api|staging)/
```

## URL Analysis & Keyword Grouping

```bash
# --- URL Analysis ---
# Extract slugs from URLs
echo "$urls" | sed 's|.*/||' | sort | uniq -c | sort -rn
# Find duplicate content patterns
rg -o '/[^/]+/[^/]+/$' urls.txt | sort | uniq -d
# Identify thin content URLs (short slugs)
rg '/[a-z]{1,3}/$' urls.txt
# Find non-canonical patterns
rg '(index\.html|index\.php|\?|#)' urls.txt

# --- Keyword Grouping (pipe GSC export) ---
rg -i 'docker|container|kubernetes' keywords.csv
rg -i 'deploy|deployment|ci.?cd|pipeline' keywords.csv
rg -i 'monitor|alert|log|observ' keywords.csv
# Extract modifiers
rg -o '\b(best|top|free|open.?source|enterprise)\b' keywords.csv | sort | uniq -c | sort -rn

# --- Integration with aidevops ---
seo-analysis-helper.sh striking-distance example.com | rg "^how"
keyword-research-helper.sh research "devops tools" --filter "^(best|top)"
```

## Related

- `seo/conversational-search-intent.md` - Multi-axis intent interpretation
- `seo/google-search-console.md` - GSC API integration
- `seo/keyword-research.md` - Keyword research workflows
- `seo/ranking-opportunities.md` - Ranking opportunity analysis
- `scripts/seo-analysis-helper.sh` - SEO data analysis CLI
