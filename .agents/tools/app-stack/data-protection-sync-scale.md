---
description: Data classification, privacy, offline sync, conflict handling, read models, performance, and test/demo data standards
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Data Protection, Sync, and Scale

New apps need privacy, sync, performance, and test data rules before growth makes them expensive to retrofit.

## Data classification and privacy

| Object | Purpose |
|--------|---------|
| `data_classifications` | Public/internal/confidential/restricted labels and handling rules |
| `field_sensitivity_rules` | Entity/field sensitivity, masking, export, AI exposure, retention policy |
| `consent_records` | User/customer consent purpose, source, status, expiry, withdrawal |
| `privacy_requests` | Access/export/delete/redact orchestration request and fulfilment state |
| `redaction_events` | Irreversible or reversible redaction with actor, reason, target, evidence |
| `data_exports` | Privacy/user/admin export metadata linking to export jobs/files, scope, expiry, sensitivity |

Rules:

- Classify fields at schema/metadata level, then enforce in API DTOs, exports, logs, AI prompts, search, analytics, and support tools.
- Redact or hash sensitive values in diffs, logs, job payloads, search history, and error reports.
- Export and delete requests need permission checks, retention/legal-hold checks, audit events, and expiry.
- `privacy_requests` orchestrate `export_jobs`, `deletion_requests`, `redaction_events`, and `data_exports`; they do not replace those execution records.
- AI exposure is explicit allow/deny metadata, not an afterthought.

## Offline sync and conflict handling

| Object | Purpose |
|--------|---------|
| `sync_clients` | Device/app/client installation, actor, workspace, version, last seen |
| `sync_cursors` | Per-client/provider/entity checkpoint for incremental sync |
| `change_events` | Ordered changes used for replication, cache invalidation, and search updates |
| `offline_mutations` | Client-originated writes queued for server validation/replay |
| `conflict_records` | Conflicting changes, detected policy, chosen resolution, reviewer |
| `tombstones` | Deleted/merged records retained for sync, imports, aliases, and audit references |
| `replication_batches` | Sync batch request/result, counts, duration, errors |

Rules:

- Choose conflict policy per entity/field: server wins, client wins, last writer wins, merge, or manual review.
- Use stable IDs and revision/version checks for offline writes; never trust stale client state for privileged fields.
- Tombstones outlive cache rows long enough for all sync clients and external providers to observe deletes/merges.
- Local-first caches reuse canonical schema where practical, but server validation remains authoritative.

## Read models and performance

| Object | Purpose |
|--------|---------|
| `read_models` | Derived tables/views for dashboard, list, report, or API read paths |
| `materialized_views` | Refreshable aggregate/query projections with freshness metadata |
| `counter_caches` | Denormalised counts/sums with source event and repair strategy |
| `analytics_events` | Product/business events separated from audit/security events |
| `partition_policies` | Partition/archive strategy by entity, time, workspace, or retention class |
| `query_budgets` | Expected latency/row-count/index assumptions for critical paths |

Rules:

- Source tables remain authoritative; read models must declare source events, rebuild path, freshness, and repair command.
- Add indexes from query plans and access patterns, not speculative field lists.
- Counters and aggregates need reconciliation jobs and visible freshness metadata.
- Analytics events must respect consent, privacy, retention, and workspace boundaries.

## Test, seed, and demo data (when in scope)

| Object | Purpose |
|--------|---------|
| `seed_scenarios` | Named dataset scenario: minimal, demo, load, integration, regression |
| `fixture_sets` | Deterministic records for unit/integration tests |
| `demo_workspaces` | Public-safe sample workspaces with synthetic accounts/users/content |
| `data_masks` | Rules for transforming production-like data into safe test/demo data |
| `migration_smoke_tests` | Post-migration assertions for schema, seed, permissions, and critical queries |

Rules:

- Demo and test data must be synthetic or masked; never depend on private customer/source rows.
- Seed scripts are idempotent, environment-aware, and safe to rerun locally.
- Exercise one representative standard-object path through create/read/update/delete, permissions, audit, and export in the running system. Add a fixture path only when explicitly requested or when it is the lowest-cost way to protect a material contract.
- When load/performance fixtures are explicitly in scope, include realistic relationship depth, search volume, job queues, and archival/retention edges.

## Verification

- Trace one sensitive field through schema metadata, API response, export, log, search, AI prompt, and redaction path.
- Trace one offline edit through client mutation, server validation, conflict policy, change event, and sync cursor advance.
- Trace one dashboard/read model from source write to projection update, freshness display, rebuild, and permission check.
- Prove one critical query budget with query plan/index evidence, partition/archive path, and counter reconciliation job.
- When seed or fixture support is in scope, trace one synthetic scenario from a clean database to the selected product-path or deterministic assertions without private data.
