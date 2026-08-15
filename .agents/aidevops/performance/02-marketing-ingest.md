<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Marketing Ingest Contract

Marketing ingest turns source-specific observations into immutable,
provider-neutral event history and rebuildable Phase 1 projections. It grants no
outreach, targeting, spend, account mutation, or publishing authority.

## Storage and Ownership

`aidevops performance init` creates, without overwriting campaign result files:

```text
_performance/marketing/
├── README.md
├── _config/plane.json
├── summaries/<account>/       # account-isolated public-safe projections
├── raw/                       # gitignored source evidence
├── index/performance.sqlite   # gitignored local projection/index
├── exports/                   # gitignored explicit exports
└── quarantine/                # gitignored rejected source references
```

`.agents/schemas/marketing-performance-event.schema.json` defines normalized
privacy-safe events; `.agents/schemas/marketing-subject.schema.json` defines the
subject, consent, suppression, and identity-link projection. Source systems own
raw observations; this plane owns projections and coverage state, never provider
credentials or raw PII. SQLite stores only bounded aliases, keyed evidence
digests, HMAC-pseudonymous event/subject references, normalized measurements, and
append-only governance evidence.

## Event Rules

- Identity is isolated by source and local account alias. Same source event and
  revision is idempotent; changed same-identity payloads quarantine rather than
  replace history.
- Higher revisions and explicit corrections append rows; effective views select
  latest non-superseded events. Corrections need a matching existing local
  subject, scope, metric, unit, currency, aggregation, and reporting period.
  Refunds and costs are compensating outcomes.
- Events project to the Phase 1 shape without changing metric IDs, units,
  dimensions, confidence, source refs, period, or timestamp semantics.
- Retain bounded scalar dimensions only: validated aliases/numbers/booleans may
  be public; other analytical values are local HMAC pseudonyms. Reject keys or
  values identifying destinations, credentials, payloads, or direct data.
- JSON stores safe whole values as integers and fractional measurements as
  canonical decimal strings; projections restore validated decimals as exact JSON
  number tokens.

## Identity and Governance

Source contact, lead, account, and audience IDs use a per-plane random HMAC salt;
normalized records never contain email, phone, remote account IDs, provider
payloads, or contact destinations. Identity links are versioned owner decisions:
`isolated` is default, `linked` requires pseudonymous IDs plus evidence, `split`
appends a reversal, and `ambiguous` records quarantine and cannot yield verified
metrics or audience exports.

Consent and suppression are separate append-only ledgers recording purpose,
state, source/account alias, effective/observation time, supplied lawful basis,
and evidence digest. Audience export requires current `audience` consent
`granted`, no current suppression, and an unambiguous subject. Measurement ingest
never authorizes outreach.

## Coverage, Recovery, and Adapters

Each source/account has its own lease, cursor, freshness budget, coverage state,
and missing scopes. Ingest acquires that lease, persists raw evidence by digest,
validates/appends events and ledgers, and commits the cursor only after a complete
durable batch. Partial/invalid batches remain replayable; successful siblings are
idempotent and rejected references quarantine. The index stores only HMAC
checkpoint references; adapters own private tokens. Late observations append but
cannot replace a newer checkpoint/watermark; retained content-addressed evidence
survives failed transactions.

Expired leases recover. Missing scopes, partial coverage, stale evidence, invalid
units/currencies, same-revision conflicts, and ambiguity remain explicit status,
never inferred `verified`. Rebuilds use immutable event/reconciliation history.
When an index directory exists, missing, symlinked, uninitialized, or corrupt
indexes fail closed. Exact-byte campaign replay can finish a post-commit prose
promotion; changed prose needs a new accepted metric revision.

Initial executable write surfaces are provider-neutral `normalized` JSON and
manual campaign `results.md`. Social, analytics, CRM, commerce/payment, and
outreach adapters are synthetic fixtures, disabled unless `AIDEVOPS_TEST_MODE=1`;
documentation/API wrappers do not imply live ingest capability.

```bash
aidevops performance init [--repo PATH]
aidevops performance validate --adapter normalized --input batch.json
aidevops performance ingest --adapter normalized --input batch.json [--dry-run]
aidevops performance ingest-campaign --campaign-id ID --results results.md
aidevops performance backfill --input phase1-results.jsonl [--dry-run]
aidevops performance list [--source SOURCE] [--history|--subjects]
aidevops performance status [--json]
aidevops performance reconcile --input owner-decisions.json
aidevops performance rebuild
aidevops performance export --purpose measurement|audience --output FILE
```

`backfill` is explicit/checkpointed for existing Phase 1 JSONL: it preserves
supported periods/currency, uses deterministic identities, rejects incompatible
metric/unit semantics, and never treats legacy results as audience consent.
`rebuild` regenerates account-isolated summaries. `/performance <URL>` remains the
separate web-performance audit command.
