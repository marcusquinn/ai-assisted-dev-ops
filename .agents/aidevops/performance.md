<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Performance Plane

`_performance/` is the canonical, privacy-safe home for measurable campaign,
case, project, system, and future result-bearing outcomes. This index keeps the
contract discoverable; chapters retain the full Phase 1 schema, Phase 2 marketing
ingest contract, and derived optimization rules. Later domain ingest paths,
dashboards, and recurring reviews remain deferred under parent issue #22372.

## Chapters

| Chapter | Scope |
|---|---|
| [01-result-schema.md](performance/01-result-schema.md) | Representation-neutral Phase 1 result schema, reach JSONL, provenance, and comparisons |
| [02-marketing-ingest.md](performance/02-marketing-ingest.md) | Privacy-safe normalized event history, governance, source coverage, and CLI |
| [03-optimization-projections.md](performance/03-optimization-projections.md) | Attribution, experiments, reports, recommendations, and optimization CLI |
| [04-deferred-work.md](performance/04-deferred-work.md) | Explicitly deferred performance-plane work |

All chapters preserve the existing field names and semantics. Implementations
must keep Phase 1 result fields readable and require an explicit migration for
unsupported write versions.
