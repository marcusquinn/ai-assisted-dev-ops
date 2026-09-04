---
description: Accounting software catalogue and adapter-readiness policy for provider-neutral bookkeeping workflows
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

# Accounting Software Catalogue

Use this catalogue to choose a truthful execution path. A product being listed does
not mean its API, MCP, credentials, permissions, or requested operation are usable.
Run capability readiness probes and inspect the installed adapter before routing a
live operation.

## Support States

| State | Meaning | Allowed behaviour |
|-------|---------|-------------------|
| `catalogued` | Product and likely interchange paths are known | Give provider-neutral guidance; verify current product behaviour |
| `candidate` | A first-party or reviewed-looking adapter exists but is not integrated | Research and review only; do not install or claim support automatically |
| `deployed` | Aidevops guidance or adapter is present | Probe every required readiness dimension |
| `ready` | Installed, configured, authenticated, authorized, reachable, compatible, and tool-visible for the requested scope | Execute through the documented preview/approval/read-back lifecycle |
| `export-based` | No reviewed live adapter is available | Use authorized exports/imports and private workpapers |

Readiness is action- and account-specific. A provider can be ready for reports but
not attachments, journals, contacts, tax submissions, or forecast drafts.

## Current Catalogue

| Product | Aidevops state | Preferred path | Important boundary |
|---------|-----------------|----------------|--------------------|
| QuickFile | Deployed reference adapter | `services/accounting/quickfile.md` and `quickfile-accounting` readiness | UK-oriented; current tools cover core invoices, purchases, banking, reports, and documents, not every bookkeeping workflow |
| QuickBooks Online | Candidate | Review the Intuit-owned MCP at https://github.com/intuit/quickbooks-online-mcp-server before optional integration | Do not equate repository availability with configured company access |
| Xero | Candidate | Review the Xero-owned MCP at https://github.com/xeroapi/xero-mcp-server before optional integration | Tenant, scopes, region, and operation support require live verification |
| Microsoft Dynamics 365 / Dataverse | Candidate | Evaluate https://github.com/microsoft/Dataverse-skills and https://github.com/microsoft/pp-mcp against the requested Finance/Business Central surface | Generic Dataverse access is not proof of accounting-ledger capability |
| Sage | Export-based | Use documented API/export paths only after product and edition discovery | Sage products and regional editions have materially different interfaces |
| FreeAgent | Export-based | Authorized API or CSV workflow after current capability review | Tax features and filing authority are jurisdiction/account specific |
| KashFlow | Export-based | Authorized exports/imports or reviewed API adapter | Verify edition, VAT behaviour, and attachment support |
| Clear Books | Export-based | Authorized exports/imports or reviewed API adapter | Verify current product scope, tax behavior, and import identifiers |
| FreshBooks | Export-based | Authorized API/export workflow | Separate invoicing/project records from complete ledger assumptions |
| Wave | Export-based | Authorized exports and private workpapers | Verify regional product/API availability before planning automation |
| Zoho Books | Export-based | Authorized API/export workflow | Confirm organization, region, scopes, rate limits, and tax edition |
| ZipBooks | Export-based | Authorized exports/imports | Do not assume a public write API or complete ledger coverage |
| 17hats | Export-based | Treat as CRM/client-operations evidence feeding accounting workpapers | Do not treat workflow or invoice records as a reconciled general ledger |
| Akaunting | Export-based | Review deployment version and available API before adapting | Self-hosted customization and plugins can change the contract |
| Odoo | Export-based | Review installed edition/modules and API contract | Accounting behaviour depends on localization, modules, and customizations |
| ERPNext | Export-based | Review installed version, doctypes, roles, and API contract | Respect workflow states and immutable submitted-document rules |
| Manager.io | Export-based | Use authorized native exports/imports after edition review | Desktop, server, and cloud capabilities differ |
| NetSuite, SAP, Oracle, MYOB, GnuCash, hledger, and other systems | Catalogued | Apply the provider-neutral workflow and perform a bounded adapter/export discovery | Never invent endpoints, schemas, permissions, or product support |

Community adapters can inform research but remain unreviewed until provenance,
license, maintenance, security, credential handling, operation coverage, and exact
installed-version behaviour are verified.

## Provider-Neutral Coverage Matrix

Assess each provider/account/action independently:

| Capability | Minimum evidence before use |
|------------|-----------------------------|
| Entity/account identity | Read-back of legal entity and selected account alias |
| Chart of accounts | Stable IDs, types, status, effective dates, mappings, and update semantics |
| Statement import | Accepted formats/API schema, idempotency key, duplicate handling, and import receipt |
| Transactions/journals | Draft/post states, balancing rules, locked periods, correction/reversal semantics |
| Reconciliation | Source and ledger balances, match states, exceptions, and close/reopen behaviour |
| Invoices, bills, debtors, creditors | Document state model, allocations, ageing, currencies, tax, and communication/payment boundaries |
| Contacts | Master/field ownership, deduplication, merge behaviour, bank-detail controls |
| Evidence attachments | File limits, immutable source retention, malware/privacy controls, stable linkage |
| Tax/statutory reports | Jurisdiction, calculation basis, workpaper traceability, submission authority, filing receipt |
| Cash-flow/budget | Dedicated forecast support or provably isolated non-posting draft entries |
| Audit and rollback | Event log, operation IDs, read-back fields, reversal/correction path, rate limits |

Unknown mandatory evidence means fallback, not optimistic execution.

## Adapter Admission Checklist

Before adding a service subagent or MCP:

1. Verify first-party documentation, ownership/provenance, license, active
   maintenance, and installed version/exported tools.
2. Build a capability matrix from actual schemas; do not copy marketing claims.
3. Model authentication, organization/entity selection, least privilege, rate
   limits, pagination, idempotency, concurrency, locked periods, and error mapping.
4. Separate read, draft, write, send, submit, delete, payment, and administrative
   operations. Default to read-only and hide tools outside the owning agent.
5. Require previews and explicit approval for consequential writes; verify exact
   provider state afterward and retain a redacted receipt.
6. Test duplicate imports, partial failure, retries, stale reads, multi-currency,
   period locks, attachment failure, correction, and revocation.
7. Add capability-registry probes and a manual export fallback before describing
   the adapter as supported.

Prefer one provider-neutral Accounting agent plus focused executable service
adapters. Do not create a strategic agent for every software brand.

## Universal Export Fallback

When no adapter is ready:

1. Ask the product for the minimum authorized export needed for the task; prefer
   stable IDs and machine-readable data over screenshots or re-keying.
2. Preserve and hash the export privately, document its cutoff and filters, then
   normalize into a staging workpaper.
3. Apply `business/accounting.md` validation, reconciliation, classification,
   approval, reporting, and ambient-learning rules.
4. Produce an import-ready file or decision pack only after validating the target
   product's current import contract. Keep the source and transformation traceable.
5. If no safe import exists, deliver reviewed manual-entry instructions plus
   deterministic control totals and a post-entry reconciliation checklist.

Private or organization-specific adapters belong in sourced/custom agent packs
until their schemas, safety controls, and shareable boundaries are stable.
