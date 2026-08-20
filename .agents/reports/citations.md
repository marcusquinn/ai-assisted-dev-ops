---
description: Inline citation and citations.json contract for reports
agent: Reports
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Report Citation Contract

Reports are only as useful as their evidence trail. Use stable source IDs in the
Markdown report and optionally mirror the ledger in `citations.json` for tools,
exporters, or client portals.

## Inline Citation Rules

- Assign each source a stable ID: `S001`, `S002`, `S003`.
- Cite material claims inline with source IDs, for example: `[S001]`.
- Put citations at the sentence or bullet where the claim appears.
- Use multiple IDs when a claim depends on multiple sources: `[S001, S004]`.
- Use evidence labels when helpful: `[S002 observed]`, `[S003 verified]`.
- If a claim is useful but not proven, label it `unsupported` and move it to a
  risk, assumption, or backlog section.
- Do not cite private local paths, private repository names, or secrets in public
  reports; use placeholders and keep raw source mapping private.

## Evidence Ledger Fields

Include a Markdown table in the report appendix when the report has material
recommendations. Version 2 separates claim/source relationship from evidence
quality and aligns names with `reference/report-component-taxonomy.md`:

| Field | Required | Notes |
|-------|----------|-------|
| `source_id` | Yes | Stable ID used inline, such as `S001`. |
| `source_type` | Yes | `first_party`, `third_party`, `benchmark`, `model`, `manual_review`, or `generated_artifact`. |
| `source_title` | Yes | Human-readable source title. |
| `locator` | Yes | URL, file path placeholder, command, PR, issue, or dashboard name. |
| `observed_date` | Yes | ISO date or date-time. |
| `claim_supported` | Yes | What the source proves. |
| `evidence_label` | Yes | Claim/source relationship: `observed`, `verified`, `inferred`, `unsupported`, or `benchmark`. |
| `evidence_state` | No | Domain state such as observed, measured, suggested, inferred, generated, or unsupported. |
| `evidence_role` | No | Domain role such as demand, supply, language, event, context, or hypothesis. |
| `confidence` | Yes | Evidence quality: `high`, `medium`, or `low`. |
| `sensitivity` | Yes | `public`, `internal`, `confidential`, or `redacted`. |
| `freshness_risk` | No | Low, medium, high, or a review date. |
| `notes` | No | Caveats, filters, sample size, or access constraints. |

Version 1 ledgers remain readable: normalize `type` to `source_type`, `title` to
`source_title`, `captured_at` to `observed_date`, and the legacy evidence-label
value in `confidence` to `evidence_label` before combining it with version 2
records. Do not invent a quality confidence during migration.

## Optional citations.json

Create `citations.json` beside `report.md` when an exporter, portal, or routine
needs machine-readable sources:

```json
{
  "version": 2,
  "report": "report.md",
  "sources": [
    {
      "source_id": "S001",
      "source_type": "first_party",
      "source_title": "Crawl summary",
      "locator": "_reports/drafts/example/crawl-summary.json",
      "observed_date": "2026-05-23",
      "claim_supported": "The crawl found 12 missing meta descriptions.",
      "evidence_label": "observed",
      "evidence_state": "observed",
      "evidence_role": "context",
      "confidence": "high",
      "sensitivity": "internal",
      "freshness_risk": "medium",
      "notes": "Sanitized path for public bundle."
    }
  ]
}
```

## Validation Checklist

- Every `source_id` used inline appears in the evidence ledger.
- Every material recommendation cites at least one source with an `observed` or
  `verified` evidence label, or explicitly names the assumption being tested.
- Public reports contain no secrets, private basenames, private repo names, or
  machine-specific local paths.
- Derived HTML/PDF exports preserve citation labels and source visibility.

## Related

- `tools/design/report-presentation.md` -- evidence badges and source cards.
- `reports/exporters.md` -- export bundles must preserve citations.
- `reports/outputs.md` -- `_reports/` output directory contract.
