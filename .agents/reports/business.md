---
description: Business, finance, operations, and company runner report routing
agent: Reports
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Business Reports

Use this doc for operations reports, finance reviews, subscription audits,
receipt or invoice summaries, company-runner status, and cross-function business
reviews. Route business analysis to business agents; this doc keeps reports
decision-ready, auditable, and safe to share.

## Domain Routing

- Use `business.md` for company orchestration and runner patterns.
- Use `business/accounting.md` for bookkeeping, reconciliation, AR/AP,
  management accounts, statutory-return workpapers, and cash-flow forecasts.
- Use `business/accounting-software.md` to select or assess provider adapters.
- Use `business/accounts-receipt-ocr.md` for receipt evidence and OCR review.
- Use `business/accounts-subscription-audit.md` for recurring cost reviews.
- Use `business/company-runners.md` for runner status and operational handoffs.
- Use `marketing-sales.md`, `legal.md`, or finance-specific runners when the
  report spans departments.

## Report Sections

1. Scope: business function, period, entities, currency, accounting basis,
   systems, reconciliation cut-off, and confidentiality.
2. Executive summary: decision, financial or operational impact, next action.
3. Method: source systems, exports, OCR steps, reconciliation rules, caveats.
4. Findings: costs, anomalies, risks, blockers, opportunities, and owners.
5. Control checks: approvals, evidence completeness, privacy, and audit trail.
6. Recommendations: stop/start/continue, owner, due date, verification.
7. Handoff: runner task, recurring routine, approval queue, or client report.

## Evidence Rules

- Never expose secrets, account numbers, private paths, or private repo names.
- Cite source IDs for each material cost, operational state, or approval claim.
- Mark OCR-derived values as observed, verified, inferred, or unsupported.
- Separate financial facts from recommendations and assumptions.
- Mark accounting adjustments as proposed, approved, posted, or verified.
- Preserve an audit trail: source, capture date, command or export, and reviewer.

## Export Notes

- Keep sensitive drafts in `_reports/drafts/` and publish only sanitized bundles.
- Use `reports/citations.md` for source IDs and optional `citations.json`.
- Use `reports/exporters.md` for Markdown-first client or board outputs.
- Use `tools/design/report-presentation.md` for risk notes, priority groups,
  financial tables, and print-safe appendices.
