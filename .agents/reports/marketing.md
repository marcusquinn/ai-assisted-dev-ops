---
description: Marketing, content, CRO, paid ads, and sales report routing
agent: Reports
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Marketing Reports

Use this doc for campaign reviews, content performance reports, funnel reviews,
CRO reports, paid media reports, newsletter performance, and sales pipeline
summaries. Route marketing analysis to the marketing, content, SEO, and analytics
agents; this doc owns report structure and handoff.

## Domain Routing

- Use `marketing-sales.md` for campaign, paid ads, CRO, email, CRM, and sales
  pipeline analysis.
- Use `content.md` for content production, distribution, and multi-channel
  performance interpretation.
- Use `seo.md` and `reports/seo-geo.md` when organic search, GEO, or AI-search
  visibility is material.
- Use `services/analytics/google-analytics.md` when GA4 evidence is required.
- Use `marketing-sales/meta-ads.md`, `marketing-sales/cro.md`, and
  `marketing-sales/direct-response-copy.md` for specialist campaign reviews.

## Report Sections

1. Scope: account/campaign, date range, as-of boundary, currency, and goals.
2. Evidence quality: freshness, coverage, missing scopes, suppressed cells, and
   confidence.
3. Outcome view: reach, engagement, account growth, traffic, conversions, leads,
   sales, revenue/refunds, costs, outreach, and guardrails as distinct categories.
4. Attribution: model/window/version, visible aggregate allocations, costs/refunds,
   uncertainty, and an explicit observational-only statement.
5. Experiment log: preregistered variants, assignment integrity, sample/runtime,
   effect interval, guardrails, causal status, and owner decision eligibility.
6. Recommendations: evidence rank, target metric, expected impact, confidence,
   owner/approval, rollback, falsifier, and retest date.
7. Handoff: owner-reviewed campaign/content task, instrumentation task, client
   report, or worker-ready backlog.

## Canonical Optimization Report

Run `.agents/scripts/marketing-optimization-helper.py report` against an explicit
normalized snapshot or live `--as-of` boundary. Supply immutable attribution and
experiment artifacts explicitly. The command writes canonical JSON plus a
reviewable Markdown draft under `_reports/drafts/<report-ref>/`; exact replay is
idempotent and changed evidence produces a new reference.

The report is aggregate-only. Below-threshold cells hide values and dimensions,
and stale/partial/missing evidence remains visible in `quality.reasons` instead of
being inferred away. ROI is shown only when outcome/refund/cost currencies are
compatible. Payback remains unavailable without valid time-to-recovery evidence.

Attribution is always observational. Only an eligible verified experiment may
support causal wording, and then only for its measured population and window.
`insufficient_evidence`, invalid assignment, guardrail breach, or an ineligible
look must not be rendered as a winner.

## Evidence Rules

- Separate platform-reported metrics from CRM, analytics, and revenue metrics.
- State attribution limits; do not overclaim causality from correlation.
- Cite dashboards, exports, screenshots, source tables, or tool outputs.
- Record currency, time zone, date range, and data freshness.
- Preserve report, attribution, experiment-run, and source-snapshot references;
  do not embed raw provider payloads or subject-level rows.
- Make recommendations measurable with owner, required approval, target metric,
  expected-impact status/range, rollback, falsifier, and retest date.
- Rank causal experiments above observations. Observational signals may propose a
  controlled test but must not carry an estimated causal impact.

## Decision Outputs and Authority

`recommend` emits immutable, supersedable records. A recommendation may prepare a
content iteration, propose a controlled experiment, or request instrumentation;
it cannot publish, message, spend, retarget, change an offer, mutate an account,
or export an audience. `approval_status: not_requested` remains unchanged until a
separate owner decision exists, and recording that decision still does not
execute it.

## Export Notes

- Use `reports/citations.md` for dashboard snapshots and source tables.
- Use `reports/exporters.md` for client-facing Markdown, HTML, PDF, or archive
  bundles.
- Use `tools/design/report-presentation.md` for charts, KPI strips, source
  cards, recommendations, and print-safe campaign appendices.
- Review `_reports/drafts/<report-ref>/` before any client-facing or published
  export; derived optimization output does not grant publishing authority.
