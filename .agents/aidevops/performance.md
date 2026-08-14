<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Performance Plane — KPI, Ingest, and Result Schema

The `_performance/` plane is the canonical home for measurable outcomes across
aidevops-managed work: campaign results, case outcomes, project delivery metrics,
system health, and future result-bearing domains.

The Phase 1 KPI/result schema remains backward compatible. The marketing ingest
layer adds provider-neutral events and pseudonymous subject records, then rebuilds
Phase 1-compatible result projections without changing existing result records.

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

Marketing data uses these versioned schemas:

- `schemas/marketing-performance-event.schema.json` — touchpoints, outcomes,
  corrections, refunds, costs, source evidence, freshness, and coverage.
- `schemas/marketing-subject.schema.json` — pseudonymous people, accounts, and
  audiences plus source/time-bound consent, suppression, and merge/split evidence.

Source providers retain private raw exports and provider identifiers. Normalized
records contain an evidence reference and a pre-hashed source subject identifier,
never an email address, phone number, access token, or provider payload. Stable
event IDs derive from provider + account + source event ID. Stable subject IDs
derive from provider + account + caller-generated source hash. Cross-source
identity links are never inferred; merge and split entries require explicit
evidence and `automatic: false`.

### Directory and durability model

```text
_performance/marketing/
├── config.json                  # plane schema and stale threshold
├── raw/events.jsonl             # append-only normalized observations
├── raw/subjects.jsonl           # append-only identity/consent ledger records
├── projections/results.jsonl    # rebuildable Phase 1-compatible results
├── state/sources.json           # per-provider/account cursor and coverage
├── state/leases/                # bounded concurrent writer exclusion
├── quarantine/records.jsonl     # content-free invalid-record references
└── <campaign-id>.md             # backward-compatible manual campaign result
```

Ingest validates the complete batch before mutation, obtains a per-source lease,
appends normalized records, rebuilds projections, and only then commits the source
cursor. Stable IDs make retries and replay idempotent. Late and out-of-order events
are sorted during rebuild. Corrections and refunds are compensating append-only
events; history is never overwritten. A failed projection leaves the cursor
unchanged, so source-specific replay remains safe.

Backfill is explicit: run `validate`, then `ingest --dry-run`, then `ingest` for a
legacy campaign or provider export. Back up `config.json` and `state/` before a
schema migration. Rollback restores those files and runs `reconcile`; raw
normalized evidence remains immutable. Unsupported schema versions reject writes.

### Source adapters and quality

The initial bounded adapters are campaign/manual, social metric or receipt,
analytics conversion, CRM lead/stage, commerce/payment sale/refund, and outreach
outcome envelopes. They normalize supplied local exports; they do not claim a
provider API exists and do not fetch remote data. Source service helpers continue
to own credentials, scopes, pagination, and provider-specific semantics.

Each source checkpoint records provider/account isolation, cursor, capture time,
scope status, and coverage. `status` compares capture time with the configured
freshness threshold. Missing scopes, partial coverage, stale evidence, identity
ambiguity, invalid units, and missing ISO currency cannot produce verified
projections. Counts, currency, percentages, and ratios retain explicit units and
dimensions; currency records never aggregate across currency codes.

### Consent and authority boundary

Measurement consent and marketing activation are separate purposes. Ingest may
record lawful-basis evidence but never performs outreach, targeting, publishing,
spend, or account mutation. Audience export fails closed unless the latest
marketing consent is `granted`; an active `all` or channel suppression excludes
the subject. Suppression and consent changes are time-bound ledger entries rather
than destructive updates.

### CLI

`performance-helper.py` provides `init`, `validate`, `ingest`, `list`, `status`,
`reconcile`, and `export`. `validate` and `ingest --dry-run` do not write. `list`
reads normalized events or projections, `reconcile` rebuilds projections and
records content-free quarantine references, and `export` emits results or
consent-safe pseudonymous audience IDs. Existing campaign promotion still writes
`_performance/marketing/<campaign-id>.md` and now ingests its numeric metric table
through the same event contract.

Dashboard generation, recurring review cadence, non-marketing promotion paths,
cross-plane lesson promotion, and attribution/experiment assignment remain later
phases. They must consume these records without weakening source, consent, or
verification semantics.
