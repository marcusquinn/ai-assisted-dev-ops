<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# AI Search KPI Scorecard Template

Use one scorecard per AI-search cycle. Record baseline, current, delta,
target, and evidence for each material change.

## Cycle Metadata

- Project:
- Date:
- Owner:
- Scope (domain/pages):
- Intent clusters:
- Competitor set:
- Engine/product, model/version (or unknown), retrieval mode, locale, language:
- Prompt cohort/variants, branded versus unbranded, session conditions:
- Capture dates, sample size, completed/failed requests, evidence source IDs:

Keep one snapshot per engine/mode/cohort. Define every rate's numerator,
denominator, and observation window; show counts alongside percentages. Unknown
or unobservable values are unavailable, not zero. Failed requests are not valid
negative answers; report them separately. Follow `seo-geo-experiment-design.md`
for controlled re-tests and `entity-evidence-audit.md` for source independence.

## KPI Snapshot

| KPI | Baseline | Current | Delta | Target | Notes |
|-----|----------|---------|-------|--------|-------|
| Grounding eligibility rate (%) | | | | | |
| Fan-out coverage (high-priority branches, %) | | | | | |
| Criteria coverage strong (%) | | | | | |
| Selection rate (cited/retrieved, %; only with observed retrieval denominator) | | | | | |
| Snippet fitness pass rate (%) | | | | | |
| Critical contradiction count | | | | | |
| Autonomous discovery success (%) | | | | | |
| Citation confidence (avg) | | | | | |
| Citation stability (variance) | | | | | |
| Crawl/index eligibility (audited URLs; not proof of retrieval) | | | | | |
| Observed search visibility (query set, rank/source, and date) | | | | | |
| Accurate entity/category recognition (valid answers, n/N) | | | | | |
| Citation frequency (valid answers citing target, n/N) | | | | | |
| Independent supporting sources (ownership and derivation deduplicated) | | | | | |
| Unbranded recommendation frequency (valid answers, n/N) | | | | | |
| Qualified referral sessions / conversions (attribution limits) | | | | | |

Recognition requires an accurate identity/category association, not a name match;
recommendation requires an actual recommendation, not any mention. Preserve answer
captures for coding decisions. Citation does not prove endorsement or verification.
Do not derive a retrieval denominator from the citation list. These outcomes need
not follow a linear sequence and should not be collapsed into one authority score.

## Diagnostic Evidence

| Area | Record |
|------|--------|
| Grounding eligibility | Queries tested; predicted-to-ground queries; confirmed grounded queries; key blockers |
| Fan-out and criteria gaps | Missing high-priority branches; partial branches; missing decision criteria |
| SRO and snippet findings | Low-survival sections; high-survival sections; sentence-level edits to test |
| Integrity and hallucination risk | Conflicting facts; unsupported claims; canonical source gaps |
| Agent discoverability | Task set used; completion failures; navigation/comprehension blockers |

## Prioritized Backlog

<!-- Add items as: 1. [ ] Description -->

## Re-test Plan

- Next run date:
- Intents to re-test:
- Pages changed since last run:
- Expected movement:
- Hypothesis, primary outcome, predeclared threshold:
- Comparison group/period, intervention revision and deployment time:
- Sampling/review window, observed recrawl/index timing, confounders:
- Null/negative results, uncertainty, commercial-query validation:
- Decision (retain/revise/stop/inconclusive), rollback owner:
