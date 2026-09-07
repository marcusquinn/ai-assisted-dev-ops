<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# SEO/GEO Experiment Design

Use when testing entity wording, contextual links, topical expansion, markup, or
external mentions. This is a measurement reference for `geo-strategy.md`, not
authority to publish, purchase domains, pay for placements, or conduct outreach.
Placement-specific disclosure rules remain in
`youtube-description-link-acquisition.md`.

## Pre-register the decision

Before changing a page, record:

| Field | Required record |
|-------|-----------------|
| Hypothesis | One intervention, expected mechanism (labelled hypothesis), primary outcome, and decision threshold |
| Scope | Query/intent cohort, audience, locale, target URLs, owner, and business relevance |
| Baseline | Dated observations, index status, available crawl evidence, rankings, and relevant conversions |
| Comparison | Comparable untreated pages/queries or an untreated period; differences and limitations |
| Intervention | Exact changed URLs/content/links, deployment time, and revision identifier |
| Sampling | Prompt variants, repeats per variant, measurement dates, review window, and stop/rollback rule |
| Confounders | Concurrent site work, indexing latency, competitors, seasonality, model/search updates, and instrumentation changes |

Change one factor where practical. If changes are bundled, report the bundle's
association rather than attributing movement to one ingredient. Define the sample
and review window before seeing results; avoid stopping at the first favourable
answer. Low-volume or invented queries can be useful pilots, but neither low
competition nor low noise follows from volume alone. Pilot success needs a second
test on relevant buyer queries before commercial generalisation.

## Capture each engine and mode separately

Record engine/product, model/version where exposed (otherwise unknown), date/time,
locale, language, exact prompt, session/history conditions, personalisation where
known, and live-search/retrieval mode. Use fresh sessions for baseline comparisons
unless conversation history is an intentional variable. Separate branded prompts
from unbranded discovery and recommendation prompts; do not seed the target brand
into a purported unaided recommendation test.

Preserve answer captures, visible cited URLs, accessible query/tool traces, and
failures with source IDs. Keep AIO, AI Mode, Gemini, ChatGPT, Claude, Perplexity, or
other tested products on separate lines. A model answering without live search is
not the same measurement as its search-enabled mode. A newly repeated claim in a
retrieved answer does not demonstrate training-data inclusion or permanent learning.

Distinguish crawl/index eligibility, observed search rank, accurate recognition,
citation, independent corroboration, unbranded recommendation, and qualified
traffic/conversion. None guarantees the next. Conventional ranking is neither a
universal prerequisite nor a guarantee of AI citation. A citation shows source
selection, not necessarily claim verification or endorsement.

## Analyse without inventing observability

- Report counts and denominators, sample size, dates, failures, and missing data.
  Keep failed requests separate from valid answers without a mention/citation;
  show completion coverage to expose selection bias.
- Retrieval candidate sets are often hidden. Mark cited/retrieved selection rate
  unavailable unless both numerator and denominator are observed over the same
  scope. A visible citation list is not the retrieval denominator.
- Compare repeated baseline and post-change observations with the comparison
  group. Report variation and uncertainty; justify statistical methods and avoid
  treating repeated answers as independent users or independent sources.
- Record observed recrawl/index timing when available. Minutes-to-hours movement
  or a 24-hour snapshot is not a universal response window, durable improvement,
  or proof of causality. An inconclusive window stays inconclusive.
- Preserve null, negative, and contradictory results alongside gains. Distinguish
  correlation from causation and do not infer proprietary algorithm weights.

## Decision and verification

Use `ai-search-kpi-template.md` for baseline/current/delta and evidence. Report
retain, revise, stop, or inconclusive against the predeclared threshold; include
business outcomes where measurable, costs, limitations, next review date, and
rollback owner. Retest promising pilot findings on representative competitive
queries. A methodological walkthrough validates the experiment plan, not the
claimed SEO/GEO effectiveness of an intervention.
