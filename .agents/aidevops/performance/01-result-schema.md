<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Phase 1 Result Schema

Every record answers: metric identity, measured subject/dimensions, measurement
semantics, validity time, provenance, and baseline/target/control comparison. The
representation is neutral: Markdown front matter, JSONL, and dashboard inputs
must preserve these field names and semantics.

## Reach Attempt JSONL

`reach-helper.sh` appends one privacy-safe JSON object per attempt to
`_performance/reach-capture.jsonl` in a repository, otherwise to
`~/.aidevops/.agent-workspace/performance/reach-capture.jsonl`; tests may set
`AIDEVOPS_REACH_PERFORMANCE_LOG`. Keep `timestamp`, `session_ref`, `target_key`,
`target_hash`, `operation`, `backend`, `agency_level`, `headed`, `mode`,
`offload`, `profile_class`, `proxy_class`, `latency_ms`, `discovery_steps`,
`token_estimate`, `bytes_in`, `bytes_out`, `status`, `failure_class`,
`temporary`, and `next_best_action`. Session and target values are hashed or
sanitized: never record private URLs, profile paths, cookies, proxy hosts,
credentials, or IP addresses. The append-only log may promote only sanitized
summaries after feedback thresholds.

## Result Shape

```json
{"schema_version":1,"metric":{"id":"marketing.leads.qualified","label":"Qualified leads","description":"Leads accepted by sales or the campaign owner","domain":"marketing","kind":"count","owner":"campaign-owner","version":1},"subject":{"type":"campaign","id":"campaign-2026-05-launch","name":"May launch campaign"},"dimensions":{"channel":"linkedin","audience":"founders","region":"uk"},"measurement":{"value":42,"unit":"lead","aggregation":"sum","period_start":"2026-05-01T00:00:00Z","period_end":"2026-05-31T23:59:59Z","observed_at":"2026-05-31T23:59:59Z","recorded_at":"2026-06-01T09:00:00Z"},"quality":{"confidence":"high","source_type":"api_export","source_ref":"_campaigns/launched/campaign-2026-05-launch/results.md","collected_by":"campaign-results-import","evidence":["export:crm-2026-06-01"],"notes":null},"baseline":{"type":"target","label":"Monthly qualified-lead target","value":35,"unit":"lead","period_start":"2026-05-01T00:00:00Z","period_end":"2026-05-31T23:59:59Z","delta_absolute":7,"delta_relative":0.2,"status":"above_target"}}
```

## Contract

| Area | Required contract |
|---|---|
| Metric | `id` is stable `<domain>.<object>.<measure>`; `label`, `description`, `domain`, `kind`, and integer `version` are required; `owner` is recommended. Domains include `marketing`, `case`, `project`, and `system`; kinds include `count`, `currency`, `duration`, `ratio`, `percentage`, `score`, `boolean`, `status`, and `text`. Never encode campaign, channel, or date in `id`. |
| Subject | `subject.type` and stable `subject.id` are required; `subject.name` is recommended. Types include `campaign`, `case`, `project`, `system`, and `routine`. |
| Dimensions | Use lower_snake_case keys and scalar string/number/boolean values. Keep keys orthogonal, prefer upstream controlled vocabularies, omit unknown/empty values, and keep changing values in `measurement`. Common keys include `channel`, `audience`, `region`, `client`, `case_type`, `project_phase`, `environment`, `routine_id`, and `experiment_variant`. |
| Measurement | `value`, canonical `unit`, and `aggregation` are required; `precision` and `direction` (`higher_is_better`, `lower_is_better`, `neutral`) are optional. Aggregation is `sum`, `average`, `min`, `max`, `latest`, `median`, `p95`, `p99`, or `none`. Currency uses decimal major units plus `dimensions.currency`; percentage uses decimal fraction; duration uses seconds; qualitative status uses kind `status` and aggregation `latest`. |
| Time | `observed_at` and `recorded_at` are required; `period_start`/`period_end` are required for period metrics and nullable together for snapshots; `source_event_at` is optional. Use RFC 3339 UTC strings. |
| Quality | Required: `confidence` (`low`, `medium`, `high`, `verified`), `source_type` (`manual`, `api_export`, `csv_export`, `derived`, `agent_estimate`, `external_report`), `source_ref`, and `collected_by`. `evidence` is recommended and `notes` optional. Derived records cite input metric IDs and source refs. Confidence progresses from estimate/incomplete, plausible unchecked, direct trusted export, to independently checked evidence. |
| Baseline | Optional `type` is `previous_period`, `target`, `control`, `forecast`, `industry`, or `custom`; `value` and matching `unit` are required when present. `label`, periods, and `source_ref` are optional; absolute/relative deltas and status are recommended. Calculate only compatible units, retain baseline provenance, interpret sign via direction, use `control` plus `experiment_variant` for experiments, and use `previous_period` when no target exists. |
