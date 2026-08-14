<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Performance Plane — KPI, Marketing Ingest, and Result Schema

The `_performance/` plane is the canonical home for measurable outcomes across
aidevops-managed work: campaign results, case outcomes, project delivery metrics,
system health, and future result-bearing domains.

This document defines the backwards-compatible Phase 1 KPI/result schema and
the Phase 2 marketing ingest contract. Other domain ingest paths, dashboards,
and recurring review workflows remain deferred to later `_performance/` phases
tracked by parent issue #22372.

## Schema Goals

Every performance record must answer six questions without reading surrounding
prose or the upstream system that produced it:

1. **What metric is this?** Stable metric identity and human-readable label.
2. **What does it describe?** Subject and dimensions that scope the measurement.
3. **How is it measured?** Unit, aggregation, precision, and directionality.
4. **When is it valid?** Observation time, reporting period, and recording time.
5. **Where did it come from?** Source, evidence, collector, and confidence.
6. **Compared to what?** Baseline, target, or control value plus delta semantics.

The schema is representation-neutral: later phases may store records as Markdown
front matter, JSONL, or generated dashboard input. Field names and semantics below
are the contract those representations must preserve.

## Reach Attempt JSONL

`reach-helper.sh` appends privacy-safe reach/capture attempt records to
`_performance/reach-capture.jsonl` when the current repository workspace is
available. Outside a repository, records fall back to
`~/.aidevops/.agent-workspace/performance/reach-capture.jsonl` (or
`AIDEVOPS_REACH_PERFORMANCE_LOG` in tests). Each line is one JSON object so
workers and routines can mine failures without reading private artifacts.

Reach records preserve these fields:

- `timestamp`, `session_ref` — observation time and hashed/safe session ref.
- `target_key`, `target_hash` — sanitized label or hash; never raw private URLs.
- `operation`, `backend`, `agency_level`, `headed`, `mode`, `offload` — route and
  execution choice used for the attempt.
- `profile_class`, `proxy_class` — policy/class labels only; never profile paths,
  cookie values, proxy hosts, credentials, or IP addresses.
- `latency_ms`, `discovery_steps`, `token_estimate`, `bytes_in`, `bytes_out` — cost
  and efficiency dimensions for feedback mining.
- `status`, `failure_class`, `temporary`, `next_best_action` — outcome and the
  safest follow-up action.

The log is append-only. Promotion to public issues must go through feedback
thresholds and use sanitized summaries instead of raw target evidence.

## Result Record

```json
{
  "schema_version": 1,
  "metric": {
    "id": "marketing.leads.qualified",
    "label": "Qualified leads",
    "description": "Leads accepted by sales or the campaign owner",
    "domain": "marketing",
    "kind": "count",
    "owner": "campaign-owner",
    "version": 1
  },
  "subject": {
    "type": "campaign",
    "id": "campaign-2026-05-launch",
    "name": "May launch campaign"
  },
  "dimensions": {
    "channel": "linkedin",
    "audience": "founders",
    "region": "uk"
  },
  "measurement": {
    "value": 42,
    "unit": "lead",
    "aggregation": "sum",
    "period_start": "2026-05-01T00:00:00Z",
    "period_end": "2026-05-31T23:59:59Z",
    "observed_at": "2026-05-31T23:59:59Z",
    "recorded_at": "2026-06-01T09:00:00Z"
  },
  "quality": {
    "confidence": "high",
    "source_type": "api_export",
    "source_ref": "_campaigns/launched/campaign-2026-05-launch/results.md",
    "collected_by": "campaign-results-import",
    "evidence": ["export:crm-2026-06-01"],
    "notes": null
  },
  "baseline": {
    "type": "target",
    "label": "Monthly qualified-lead target",
    "value": 35,
    "unit": "lead",
    "period_start": "2026-05-01T00:00:00Z",
    "period_end": "2026-05-31T23:59:59Z",
    "delta_absolute": 7,
    "delta_relative": 0.2,
    "status": "above_target"
  }
}
```

## Metric Identity

Metric identity is stable across subjects and reporting periods. A campaign,
case, or project may emit many records for the same metric ID over time.

| Field | Required | Description |
|-------|----------|-------------|
| `metric.id` | Yes | Stable dotted ID: `<domain>.<object>.<measure>` |
| `metric.label` | Yes | Human-readable name used in reports |
| `metric.description` | Yes | Short definition that disambiguates counting rules |
| `metric.domain` | Yes | Domain namespace: `marketing`, `case`, `project`, `system`, or future domain |
| `metric.kind` | Yes | Measurement kind: `count`, `currency`, `duration`, `ratio`, `percentage`, `score`, `boolean`, `status`, `text` |
| `metric.owner` | Recommended | Role or system responsible for definition quality |
| `metric.version` | Yes | Integer definition version; increment when counting rules change |

Metric IDs must not encode volatile dimensions such as campaign ID, channel, or
date. Put those in `subject` and `dimensions` so reports can aggregate the same
metric across comparable slices.

## Subject and Dimensions

`subject` identifies the entity the result measures. `dimensions` describe the
slice of that entity.

### Subject Fields

| Field | Required | Description |
|-------|----------|-------------|
| `subject.type` | Yes | Entity class: `campaign`, `case`, `project`, `system`, `routine`, or future type |
| `subject.id` | Yes | Stable ID in the source plane |
| `subject.name` | Recommended | Human-readable label for reports |

### Dimension Rules

- Use lower_snake_case keys and scalar string, number, or boolean values.
- Keep dimensions orthogonal: `channel` and `region` are separate keys, not
  `linkedin_uk`.
- Prefer controlled vocabulary values where the upstream plane already has one.
- Omit unknown dimensions instead of using `unknown`, `n/a`, or empty strings.
- Put changing measurement values in `measurement`, never in `dimensions`.

Common dimensions include `channel`, `audience`, `region`, `client`, `case_type`,
`project_phase`, `environment`, `routine_id`, and `experiment_variant`.

## Units and Measurement Semantics

Measurement fields define how a value should be interpreted and aggregated.

| Field | Required | Description |
|-------|----------|-------------|
| `measurement.value` | Yes | Numeric, boolean, status, or text value matching `metric.kind` |
| `measurement.unit` | Yes | Canonical unit such as `lead`, `gbp`, `second`, `percent`, or `score` |
| `measurement.aggregation` | Yes | `sum`, `average`, `min`, `max`, `latest`, `median`, `p95`, `p99`, or `none` |
| `measurement.precision` | Optional | Decimal precision to preserve when rendering |
| `measurement.direction` | Optional | `higher_is_better`, `lower_is_better`, or `neutral` |

Unit rules:

- Store currency as decimal major units with ISO currency in `dimensions.currency`
  when the currency can vary.
- Store percentages as decimal fractions (`0.42` for 42%) and render as percent in
  reports.
- Store durations as seconds unless a later domain contract explicitly narrows the
  unit.
- For qualitative status metrics, use `metric.kind: "status"` and
  `measurement.aggregation: "latest"`.

## Timestamps and Reporting Periods

Time fields separate the measured event, the reporting period, and the act of
recording the result.

| Field | Required | Description |
|-------|----------|-------------|
| `measurement.observed_at` | Yes | Instant when the measured value was true or extracted |
| `measurement.period_start` | Required for period metrics | Inclusive start of reporting window |
| `measurement.period_end` | Required for period metrics | Inclusive end of reporting window |
| `measurement.recorded_at` | Yes | Time the performance record was written |
| `measurement.source_event_at` | Optional | Upstream event timestamp when different from observation time |

All timestamps use RFC 3339 UTC strings. Snapshot metrics may set
`period_start` and `period_end` to `null`; period metrics must set both.

## Confidence, Source, and Evidence

Performance records are decision inputs, so every value needs provenance.

| Field | Required | Description |
|-------|----------|-------------|
| `quality.confidence` | Yes | `low`, `medium`, `high`, or `verified` |
| `quality.source_type` | Yes | `manual`, `api_export`, `csv_export`, `derived`, `agent_estimate`, or `external_report` |
| `quality.source_ref` | Yes | Stable file path, export ID, or upstream record reference |
| `quality.collected_by` | Yes | Human, agent, helper, or integration that produced the record |
| `quality.evidence` | Recommended | Array of evidence refs, hashes, or source anchors |
| `quality.notes` | Optional | Short caveat; not a substitute for structured fields |

Confidence ladder:

| Value | Meaning |
|-------|---------|
| `low` | Estimate, incomplete data, or unreviewed manual entry |
| `medium` | Plausible source but not independently checked |
| `high` | Direct export or deterministic derivation from trusted source |
| `verified` | Independently checked against source evidence or signed-off report |

Derived records must cite the input metric IDs and source refs in `evidence` so a
future reporting CLI can explain how the value was produced.

## Baseline and Comparison Model

Baselines make a result meaningful without hardcoding dashboard logic.

| Field | Required | Description |
|-------|----------|-------------|
| `baseline.type` | Optional | `previous_period`, `target`, `control`, `forecast`, `industry`, or `custom` |
| `baseline.label` | Optional | Human-readable comparison label |
| `baseline.value` | Required when baseline exists | Baseline value in the same unit as measurement |
| `baseline.unit` | Required when baseline exists | Must match `measurement.unit` unless conversion is explicit |
| `baseline.period_start` | Optional | Baseline reporting-window start |
| `baseline.period_end` | Optional | Baseline reporting-window end |
| `baseline.source_ref` | Optional | Provenance for target, control, forecast, or external benchmark |
| `baseline.delta_absolute` | Recommended | `measurement.value - baseline.value` after unit normalization |
| `baseline.delta_relative` | Recommended | Relative delta as decimal fraction of baseline value |
| `baseline.status` | Recommended | `above_target`, `below_target`, `on_track`, `regressed`, `improved`, or `neutral` |

Comparison rules:

- Compute deltas only when measurement and baseline units are compatible.
- Preserve the baseline source; do not overwrite a target with the latest result.
- Interpret positive or negative delta using `measurement.direction`, not by sign
  alone.
- Use `baseline.type: "control"` for experiments and include
  `dimensions.experiment_variant` on both treatment and control records.
- Use `baseline.type: "previous_period"` for trend reporting when no explicit
  target exists.

## Marketing Ingest Contract

Marketing ingest converts source-specific observations into immutable,
provider-neutral event history and rebuildable Phase 1 result projections. It
does not grant outreach, targeting, spend, account mutation, or publishing
authority.

### Directory Layout

`aidevops performance init` provisions this layout without overwriting existing
campaign result files:

```text
_performance/
├── .gitignore
└── marketing/
    ├── README.md
    ├── _config/plane.json
    ├── summaries/<account>/       # account-isolated public-safe projections
    ├── raw/                       # gitignored source evidence
    ├── index/performance.sqlite   # gitignored local projection/index
    ├── exports/                   # gitignored explicit exports
    └── quarantine/                # gitignored rejected source references
```

Raw provider exports and direct identifiers remain in `raw/` or their
authoritative source system. The SQLite store contains only bounded source and
account aliases, keyed evidence digests, HMAC-pseudonymous event and subject
references, normalized measurements, and append-only governance evidence.

### Event and Result Ownership

- `.agents/schemas/marketing-performance-event.schema.json` is the normalized,
  privacy-safe event contract.
- `.agents/schemas/marketing-subject.schema.json` is the subject, consent,
  suppression, and identity-link projection contract.
- Source systems own raw observations. `_performance/marketing/` owns normalized
  projections and source coverage state, not provider credentials or raw PII.
- Stable event identity is isolated by source and local account alias. A retry
  with the same source event and revision is idempotent. A changed payload at the
  same identity is quarantined rather than replacing history.
- Higher revisions and explicit corrections append new rows. Effective views use
  the latest revision and omit explicitly superseded events. Corrections require
  an existing source/account-local target with matching subject, scope, metric,
  unit, currency, aggregation, and reporting period; refunds and costs remain
  separate compensating outcomes.
- Every accepted event can project to the Phase 1 result shape. Metric IDs,
  units, dimensions, confidence, source refs, reporting periods, and timestamp
  semantics above stay backwards compatible.
- Bounded Phase 1 scalar dimensions are retained. Controlled public dimensions
  keep validated aliases/numbers/booleans; all other analytical values are
  store-local HMAC pseudonyms. Keys or values that identify contact destinations,
  credentials, payloads, or similar direct data are rejected before persistence.
- Normalized event JSON uses integers for safe whole values and canonical decimal
  strings for fractional measurements, avoiding binary rounding. Phase 1 result
  projections restore those validated decimals as exact JSON-number tokens.

### Subject Identity and Governance

Source contact, lead, account, and audience identifiers are transformed with a
per-plane random HMAC salt before they enter the index. Normalized records never
contain email addresses, phone numbers, remote account IDs, provider payloads,
or contact destinations.

Identity links are versioned owner decisions:

- `isolated` is the default for one pseudonymous source subject.
- `linked` requires an explicit reconciliation record naming only pseudonymous
  subject IDs and evidence.
- `split` appends a reversal; it never deletes the historical link.
- `ambiguous` source records are quarantined and cannot produce a verified
  metric or audience export.

Consent and suppression are independent append-only ledgers. Each entry records
purpose, state, source/account alias, effective time, observation time, lawful
basis when supplied, and an evidence digest. Audience export requires current
`audience` consent to be `granted`, no current suppression, and an unambiguous
subject. Measurement ingest itself never makes a subject eligible for outreach.

### Source Coverage, Freshness, and Recovery

Each source/account pair has its own lease, cursor, freshness budget, coverage
state, and missing-scope list. Ingest follows these rules:

1. Acquire the exact source/account lease.
2. Persist immutable raw evidence by digest.
3. Validate and append normalized events plus governance ledgers.
4. Commit the cursor only when the batch is complete and every record is durable.
5. Leave partial or invalid batches replayable; successful sibling events remain
   idempotently committed while rejected references remain quarantined.

The index stores only an HMAC checkpoint reference. File/live source adapters own
their private resume token; an older observation can append late events but cannot
replace a newer source checkpoint or freshness watermark. Content-addressed raw
evidence is retained after a failed transaction so an expired worker cannot
delete an artifact a newly fenced worker is about to reference.

Expired leases are recoverable. Missing scopes, partial coverage, stale evidence,
invalid units/currencies, same-revision conflicts, and identity ambiguity stay
explicit in `status`; they never become `verified` through inference. Rebuilding
projections reads immutable event and reconciliation history rather than editing
source observations.

Missing, symlinked, uninitialized, or corrupt index files fail closed once a local
index directory exists; read or ingest commands do not silently replace history or
its pseudonymization salt. Exact-byte campaign replays can finish a prose promotion
that was interrupted after the database commit, while changed prose without a new
accepted metric revision remains blocked.

### Adapter Availability

`normalized` provider-neutral JSON and manual campaign `results.md` imports are
the initial executable write surfaces. Social, analytics, CRM, commerce/payment,
and outreach adapters ship with synthetic fixture contracts so normalization can
be tested without credentials or customer data. Those fixture adapters are
disabled unless `AIDEVOPS_TEST_MODE=1`; documentation or an API wrapper alone is
not represented as live ingest capability.

### CLI

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

`backfill` is the explicit, checkpointed migration path for existing Phase 1
marketing result JSONL. It preserves supported reporting periods and currency,
uses deterministic event identities, rejects incompatible metric/unit semantics,
and never treats legacy result data as audience consent. `rebuild` regenerates
account-isolated campaign summaries from immutable event and reconciliation
history.

`/performance <URL>` remains the separate web-performance audit command.

## Deferred Beyond Marketing Ingest

- Provider-authenticated live marketing adapters and scheduled collectors.
- Promotion paths from `_cases/` and `_projects/`.
- Dashboard generation and recurring review cadence.
- Attribution, experiment assignment, and optimization decisions.
- Cross-plane lesson promotion back to `_knowledge/insights/`.

Later phases may extend these schemas, but they must keep Phase 1 result fields
readable and require an explicit migration for unsupported write versions.
