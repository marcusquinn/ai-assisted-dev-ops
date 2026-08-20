---
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->
# Keyword Research

<!-- AI-CONTEXT-START -->

## Quick Reference

- **Providers**: DataForSEO (primary), Serper (alternative), Ahrefs (optional DR/UR)
- **Webmaster Tools**: Google Search Console, Bing Webmaster Tools (owned sites)
- **Config**: `~/.config/aidevops/keyword-research.json`
- **Intent framing**: `conversational-search-intent.md` for user jobs, query
  forms, constraints, provenance, and trend state before or after collection

| Mode | Command/Flag | Purpose |
|------|-------------|---------|
| Keyword Research | `/keyword-research` | Expand seed keywords |
| Autocomplete | `/autocomplete-research` | Google long-tail expansion |
| Domain Research | `--domain` | Keywords for a domain's niche |
| Competitor Research | `--competitor` | Keywords a competitor ranks for |
| Keyword Gap | `--gap` | Competitor keywords you don't rank for |
| Webmaster Tools | `webmaster <url>` | Keywords from GSC + Bing |

| Level | Flag | Data |
|-------|------|------|
| Quick | `--quick` | Volume, CPC, KD, Intent |
| Full | `--full` (default for extended) | + KeywordScore, Domain Score, 17 weaknesses |

<!-- AI-CONTEXT-END -->

## Intent Interpretation

Use `conversational-search-intent.md` before expansion when a seed is ambiguous,
prompt-shaped, multi-step, trend/news-led, or taken from query logs. Use it after
collection to cluster observed and suggested language by user job, outcome,
journey state, constraints, and evidence confidence.

The provider `Intent` field and `--intent` filter are four-class lexical/SERP
signals. They do not capture conversational form, follow-up context, topic
velocity, or attribution to an AI-search surface. Preserve source and raw query;
label autocomplete and model-generated variants as hypotheses until metrics or
first-party evidence corroborate them.

## Commands

### /keyword-research

```bash
/keyword-research "best seo tools, keyword research"
/keyword-research "best * for dogs"   # wildcard support
```

**Options**: `--limit N` (default: 100, max: 10,000) · `--provider dataforseo|serper|both` · `--csv` · `--min-volume N` · `--max-difficulty N` · `--intent informational|commercial|transactional|navigational` · `--contains "term"` · `--excludes "term"`

### /autocomplete-research

```bash
/autocomplete-research "how to lose weight"
```

### /keyword-research-extended

Full SERP analysis with weakness detection and KeywordScore.

```bash
/keyword-research-extended "best seo tools"
```

**Additional options**: `--quick` · `--full` (default) · `--ahrefs` · `--domain example.com` · `--competitor example.com` · `--gap yourdomain.com,competitor.com`

## Output Format

```text
# Basic
| Keyword                  | Volume  | CPC    | KD  | Intent        |
| best seo tools 2025      | 12,100  | $4.50  | 45  | Commercial    |

# Extended
| Keyword          | Vol   | KD  | KS  | Weaknesses | Weakness Types              | DS  | PS  | DR  |
| best seo tools   | 12.1K | 45  | 72  | 5          | Low DS, Old Content, ...    | 23  | 15  | 31  |

# Competitor/Gap
| Keyword          | Vol   | KD  | Position | Est Traffic | Ranking URL                |
| best seo tools   | 12.1K | 45  | 3        | 2,450       | example.com/blog/seo-tools |
```

**CSV columns** — Basic: `Keyword,Volume,CPC,Difficulty,Intent` · Extended: adds `KeywordScore,DomainScore,PageScore,WeaknessCount,Weaknesses,DR,UR` · Competitor/Gap: adds `Position,EstTraffic,RankingURL`

Default export path: `~/Downloads/keyword-research-YYYYMMDD-HHMMSS.csv`

## KeywordScore Algorithm

KeywordScore (0–100) measures ranking opportunity from SERP weaknesses.

| Component | Points |
|-----------|--------|
| Standard weaknesses (13 types) | +1 each |
| Unmatched Intent (1 word missing) | +4 |
| Unmatched Intent (2+ words missing) | +7 |
| Search Volume 101–1,000 / 1,001–5,000 / 5,000+ | +1 / +2 / +3 |
| Keyword Difficulty 0 / 1–15 / 16–30 | +3 / +2 / +1 |
| Low Average Domain Score | Variable |
| Individual Low DS (position-weighted) | Variable |
| SERP Features (non-organic) | −1 each (max −3) |

| Score | Opportunity |
|-------|-------------|
| 90–100 | Exceptional |
| 70–89 | Strong |
| 50–69 | Moderate |
| 30–49 | Challenging |
| 0–29 | Very difficult |

## SERP Weakness Detection (17 Types)

| Category | Weakness | Threshold |
|----------|----------|-----------|
| **Domain & Authority** | Low Domain Score | DS ≤ 10 |
| | Low Page Score | PS ≤ 0 |
| | No Backlinks | 0 backlinks |
| **Technical SEO** | Slow Page Speed | > 3000ms |
| | High Spam Score | ≥ 50 |
| | Non-HTTPS | HTTP only |
| | Broken Page | 4xx/5xx |
| | Flash Code | Present |
| | Frames | Present |
| | Non-Canonical | Missing |
| **Content Quality** | Old Content | > 2 years |
| | Title-Content Mismatch | Detected |
| | Keyword Not in Headings | Missing |
| | No Heading Tags | None |
| **SERP Composition** | UGC-Heavy Results | 3+ UGC sites |
| **Intent** | Unmatched Intent | Title analysis |

## Location & Language

First run: confirm locale (default US/English). Subsequent runs: use saved preference. Override with `--location`.

| Code | Location | Language |
|------|----------|----------|
| `us-en` | United States | English |
| `uk-en` | United Kingdom | English |
| `ca-en` | Canada | English |
| `au-en` | Australia | English |
| `de-de` | Germany | German |
| `fr-fr` | France | French |
| `es-es` | Spain | Spanish |
| `custom` | Enter location code | Any |

Config (`~/.config/aidevops/keyword-research.json`): `default_locale`, `default_provider`, `default_limit` (100), `include_ahrefs` (false), `csv_directory` (`~/Downloads`).

## Provider Configuration

| Provider | Role | Credentials | Endpoints |
|----------|------|-------------|-----------|
| **DataForSEO** | Primary | `DATAFORSEO_USERNAME` + `DATAFORSEO_PASSWORD` | `keyword_suggestions/live`, `ranked_keywords/live`, `domain_intersection/live`, `backlinks/summary/live`, `serp/google/organic/live`, `onpage/instant_pages` |
| **Serper** | Alternative (faster) | `SERPER_API_KEY` | `search`, `autocomplete` |
| **Ahrefs** | Optional DR/UR | `AHREFS_API_KEY` | `domain-rating`, `url-rating` |

## Recommended Workflow

1. **Intent frame**: identify user job, desired outcome, locale, audience, and
   material constraints with `conversational-search-intent.md`
2. **Discovery**: `/keyword-research` — broad expansion
3. **Long-tail**: `/autocomplete-research` — suggested question/query language
4. **Competition**: `/keyword-research-extended --competitor` — rival keywords
5. **Gaps**: `/keyword-research-extended --gap` — opportunities
6. **Analysis**: `/keyword-research-extended` — full SERP data on top candidates
7. **Cluster**: merge metrics with the intent ledger while retaining provenance
8. **Export**: `--csv` — content planning spreadsheets

```bash
/keyword-research "dog training" --min-volume 1000 --max-difficulty 40 --csv
/autocomplete-research "how to train a puppy"
/keyword-research-extended --competitor petco.com
/keyword-research-extended --gap mydogsite.com,petco.com
/keyword-research-extended "dog training tips" --ahrefs
```

## Result Limits

Default: 100 results. Prompts to retrieve more (max 10,000) before continuing.

| Results | Approx. Cost |
|---------|-------------|
| 100 | 1 credit |
| 1,000 | 10 credits |
| 10,000 | 100 credits |

## Webmaster Tools Integration

GSC + Bing keywords enriched with DataForSEO volume/difficulty data.

```bash
keyword-research-helper.sh sites
keyword-research-helper.sh webmaster https://example.com            # last 30 days
keyword-research-helper.sh webmaster https://example.com --days 90
keyword-research-helper.sh webmaster https://example.com --no-enrich
keyword-research-helper.sh webmaster https://example.com --csv
```

**Output columns**: Keyword, Clicks, Impressions, CTR, Position, Volume, KD, CPC, Sources (GSC/Bing/Both)

**GSC setup**: Cloud Console → enable "Search Console API" → create Service Account → download JSON key → add service account email to GSC with "Full" permissions → set `GOOGLE_APPLICATION_CREDENTIALS="/path/to/key.json"`.

**Bing setup**: [bing.com/webmasters](https://www.bing.com/webmasters) → add/verify site → Settings → API Access → Generate API Key → set `BING_WEBMASTER_API_KEY`.

## Troubleshooting

| Issue | Solution |
|-------|----------|
| "API key not found" | Run `/list-keys` to check credentials |
| "Rate limit exceeded" | Wait or switch provider with `--provider` |
| "No results found" | Try broader seeds or different locale |
| "Timeout" | Reduce `--limit` or use `--quick` |

Check availability: `/list-keys --service dataforseo|serper|ahrefs`
