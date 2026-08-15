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

1. Scope: campaign, channel, audience, offer, date range, spend, and goals.
2. Executive summary: performance, constraint, opportunity, and decision.
3. Funnel view: reach/impressions, engagement, account growth, traffic,
   conversion, leads/stages, sales, revenue/refunds, costs, and ROI/payback only
   where units and coverage make them valid.
4. Creative/content findings: message, hook, offer, channel fit, and evidence.
5. Experiment log: preregistered hypothesis/control, variants, assignment,
   sample/privacy thresholds, window, exclusions, primary/guardrail outcomes,
   confidence, decision, and next test.
6. Recommendations: evidence refs, expected impact range, confidence, owner,
   required approval, rollback, retest date, and supersession status.
7. Handoff: campaign routine, client report agent, or worker-ready backlog.

## Evidence Rules

- Separate platform-reported metrics from CRM, analytics, and revenue metrics.
- State attribution limits; do not overclaim causality from correlation.
- Cite dashboards, exports, screenshots, source tables, or tool outputs.
- Record currency, time zone, date range, and data freshness.
- Make recommendations measurable with owner, target metric, and re-test date.
- Name the attribution model, lookback window, model/window versions, coverage,
  unknown identity, and unattributed outcomes. Observational credit is not
  incremental lift.
- Suppress cohorts below the inherited privacy/minimum-sample threshold. Never
  include subject-level journeys, direct identifiers, or raw private evidence.
- Mark missing, partial, stale, contradictory, novelty-sensitive, or seasonal
  evidence explicitly. Do not infer values for a missing funnel stage.
- Keep platform reach/engagement/account-growth metrics distinct from CRM leads,
  commerce sales/revenue/refunds, and costs.

## Freshness and Publication

`marketing-optimization-helper.py report` creates a deterministic aggregate
draft. Every source records observed time, age, coverage, and `fresh` or `stale`
status. Stale evidence can preserve historical context but cannot silently drive
a current recommendation. No-data is a valid report state.

Drafts follow `_reports/drafts` → review → published bundle. Atomic publication
must leave the previous report available on partial failure. A report records its
source snapshot, projection/analysis IDs, caveats, suppression count, and
decision outputs so model-version recomputes remain auditable.

Report generation and recommendation generation do not grant authority to
publish content, send messages, change budgets/audiences/offers, retarget, or
mutate provider accounts. Route those proposals to the domain owner and preserve
the required approval in the recommendation record.

## Export Notes

- Use `reports/citations.md` for dashboard snapshots and source tables.
- Use `reports/exporters.md` for client-facing Markdown, HTML, PDF, or archive
  bundles.
- Use `tools/design/report-presentation.md` for charts, KPI strips, source
  cards, recommendations, and print-safe campaign appendices.
