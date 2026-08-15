<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Marketing Optimization Projections

`.agents/scripts/marketing-optimization-helper.py` is the provider-neutral
read/derive boundary for attribution, experiments, aggregate reports, and growth
recommendations. It reads `PerformanceReporting.event_records()`,
`subject_records()`, and `status()` only; it never ingests, reconciles, repairs,
exports audiences, or mutates providers. Live reads require `--as-of`; `--input`
accepts an equivalent hermetic snapshot. Schema v3 preserves append-only source,
lease, and governance visibility; unavailable pre-migration state fails closed.

`init` provisions without replacement:

```text
_performance/marketing/
├── _config/optimization.json
├── attribution/<typed-ref>.json
├── experiments/<typed-ref>.json
├── recommendations/<typed-ref>.json
├── index/optimization-{assignments,snapshots}/<ref>.json # private 0600
└── optimization-work/                 # gitignored local work
_reports/drafts/<report-ref>/{report.json,report.md}
```

Derived JSON uses content-derived typed references: exact replay is idempotent;
changed same-reference payload fails closed. New model/definition/assignment/
snapshot creates new artifacts while retaining evidence and owner decisions.
Experiment definitions and assignments create immutable append-time receipts;
public storage has aggregates/opaque receipts only, while pseudonymous rows and
snapshots stay owner-only under gitignored `marketing/index/`. Analysis refs
include definition identity. Report/recommendation evidence paths are selectors:
the helper validates their complete shape and safe aliases, then re-reads only
descriptor-pinned registered storage; conflicting/unregistered artifacts fail
closed.

## Analysis Rules

- Direct and last-touch attribution record version, lookback, coverage, freshness,
  refunds/costs, currency compatibility, and uncertainty. Both are
  `observational_only`; semantic changes increment `--model-version` and pass
  prior ref with `--supersedes`.
- Causal language needs an approved immutable definition and trusted local receipt
  before `data_policy.started_at`, binding owner, approval, preregistration, and
  complete definition. Changes increment `definition_version` and supersede the
  immediately previous version. A verified randomized sticky assignment snapshot
  has its own prior receipt. Never relax floors below 250 subjects, 10 conversions
  per variant, seven days, or 10 subjects per published cell; higher configured
  floors win. Insufficient sample/runtime/conversions, stopping, balance,
  contamination, privacy, freshness, confidence/completeness, practical effect, or
  guardrails fail closed. Safety looks cannot select winners; sequential looks
  recursively validate every predecessor and receipt.
- Reports are aggregate-only and separate reach, engagement, account growth,
  traffic, conversion, leads, sales, revenue/refunds, costs, outreach, and
  guardrails. Overrides cannot lower distinct-subject/aggregate thresholds;
  suppressed cells hide values, dimensions, contributing counts, and count-derived
  coverage. External artifacts meet the same invariants.
- Recommendations rank eligible causal experiments above verified/directional
  observations and include uncertainty, owner, required approval, metric-bound
  rollback comparator/threshold, retest, provenance, and supersession. They are
  handoffs only: never publish, message, spend, retarget, change offers, mutate
  accounts, or export audiences.

```bash
python3 .agents/scripts/marketing-optimization-helper.py init --repo PATH
python3 .agents/scripts/marketing-optimization-helper.py status --repo PATH
python3 .agents/scripts/marketing-optimization-helper.py attribute --repo PATH --as-of UTC --outcome-metric-id ID
python3 .agents/scripts/marketing-optimization-helper.py experiment-register --repo PATH --definition experiment.json
python3 .agents/scripts/marketing-optimization-helper.py experiment-assignment-register --repo PATH --definition experiment.json --assignment-snapshot assignments.json
python3 .agents/scripts/marketing-optimization-helper.py experiment-analyze --repo PATH --definition experiment.json --assignment-snapshot assignments.json --look-number N --look-type final --as-of UTC
python3 .agents/scripts/marketing-optimization-helper.py experiment-decide --repo PATH --experiment analysis.json --decision owner-decision.json
python3 .agents/scripts/marketing-optimization-helper.py report --repo PATH --as-of UTC --attribution attribution.json --experiment experiment.json
python3 .agents/scripts/marketing-optimization-helper.py recommend --repo PATH --report report.json --prior prior-recommendation.json
```

Analysis persists an immutable look-number reservation: exact replay is
idempotent; changed same-look snapshot fails closed. Other derive commands offer
`--dry-run`. One atomic transition serializes an owner decision against successor
looks; recommendation successors require `--prior`. Owner decisions record
supplied local approval only and never execute it. Registration times use the
local clock, never input timestamps, so late evidence is ineligible.
