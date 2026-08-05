<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Team-interface canonical agent roster

The version-1 roster is the provider-neutral discovery boundary between
canonical aidevops agent sources and team-interface consumers. Generate it with:

```bash
.agents/scripts/team-interface-agent-roster.py --agents-dir .agents
```

The command emits canonical JSON to stdout. `--output PATH` atomically replaces
only that explicit caller-owned cache. It never edits OpenCode or Claude
configuration, creates provider agents, resolves a concrete model, or copies
instruction bodies into portable manifests.

## Identity and inclusion

`.agents/scripts/lib/agent_config.py::iter_primary_agent_sources()` remains the
single inclusion and ordering implementation: root-level Markdown excluding
`SKIP_FILES`, with `AGENT_ORDER` first and remaining display names sorted
case-insensitively. Runtime discovery consumes that same iterator.

Each portable primary requires an explicit frontmatter `name`. Its stable ID is
`agent.<name>`; display names and filenames are presentation and source-location
metadata, not identity. `.agents/aidevops.md` is registered separately as the
`agent.aidevops-guide` framework guide. Duplicate, missing, or invalid names
fail the complete generation.

## Workload and provenance

Frontmatter `model` values represent only the `simple`, `standard`, or
`thinking` workload tier. An absent tier defaults to `standard`; any other value
fails closed. Runtime routing remains responsible for selecting a provider,
model, and reasoning variant.

Every record contains an `agents:<filename>` deployment-relative source
reference and a SHA-256 digest of the exact source bytes. It contains a bounded
description, not instructions, absolute host paths, credentials, provider IDs,
or model IDs. `roster_digest` hashes canonical JSON for the complete unsigned
document, so unchanged sources and metadata produce byte-identical output.

## Consumers and compatibility

Buzz, Matrix, aidevops.app, app-team manifests, and launch-overlay generators
may cache or compare this document, but must resolve `agent_id` against current
canonical discovery before acting. A source-name change is an identity
migration and requires explicit alias/migration data; changing only display
name or filename while preserving `name` keeps the stable identity.

Existing custom discovery fixtures without `name` continue to work through the
filename fallback in runtime discovery. Portable roster generation is stricter:
it rejects missing names, unreadable sources, unknown tiers, duplicate IDs,
absolute/parent source references, unsupported formats, and output paths that
alias agent source files. Any failure leaves a previous explicit output intact.
