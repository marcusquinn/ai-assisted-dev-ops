---
description: Memory template directory documentation
mode: subagent
tools:
  read: true
  write: false
  edit: false
  bash: true
  glob: true
  grep: true
  webfetch: false
  task: true
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Memory System

Cross-session memory using a canonical observation contract with SQLite FTS5 as its retrieval projection. **Requires**: `sqlite3` CLI (`brew install sqlite3` / `sudo apt install sqlite3`).

**Motto**: "Compound, then clear" — sessions build on each other.

**Architecture**: SQLite FTS5 over PostgreSQL — no external server, no connection management, FTS5 provides fast full-text search out of the box.

## Slash Commands

| Command | Purpose |
|---------|---------|
| `/remember {content}` | Store with AI-assisted categorization |
| `/recall {query}` | Search by keyword |
| `/recall --recent` | Show 10 most recent |
| `/recall --auto-only` | Auto-captured memories only |
| `/recall --stats` | Memory statistics |
| `/memory-log` | Recent auto-captured memories |

See `scripts/commands/remember.md` and `scripts/commands/recall.md`.

## Memory Types

| Type | Use For |
|------|---------|
| `WORKING_SOLUTION` | Fixes that worked |
| `FAILED_APPROACH` | What didn't work (avoid repeating) |
| `CODEBASE_PATTERN` | Project conventions |
| `USER_PREFERENCE` | Developer preferences |
| `TOOL_CONFIG` | Tool setup notes |
| `DECISION` | General project decisions |
| `CONTEXT` | Background info |
| `ARCHITECTURAL_DECISION` | System-level architecture choices |
| `ERROR_FIX` | Bug fixes and patches |
| `OPEN_THREAD` | Unresolved questions or follow-ups |
| `SUCCESS_PATTERN` | Approaches that consistently work |
| `FAILURE_PATTERN` | Approaches that consistently fail |

## Auto-Recall

Surfaces at: interactive session start (last 5, via `conversation-starter.md`), session resume, and runner dispatch (recent + task-specific). Silent if no memories found; namespace-isolated for runners.

## Auto-Capture

Agents store automatically via `--auto` flag. Works with any AI tool that reads AGENTS.md. Privacy filters strip `<private>...</private>` blocks and reject secret patterns (API keys, tokens).

## Relation Types

| Relation | Meaning | Example |
|----------|---------|---------|
| `updates` | New info supersedes old | "Favorite color is now green" updates "...is blue" |
| `extends` | Adds detail, no contradiction | Adding job title to existing employment memory |
| `derives` | Second-order inference | Inferring "works remotely" from location + job info |
| `debunks` | Evidence marks old memory false | "Current source disproves the outage myth" debunks the stale claim |

Truth maintenance is append-only: debunk/retraction state is recorded in
`learning_truth_events` and linked to evidence memories instead of editing or
deleting the original FTS5 row. Default recall hides debunked/retracted memories
and hides memories superseded by `updates`; use `history <id>` when you need the
audit chain.

## Dual Timestamps

`created_at` = when stored in DB. `event_date` = when the event actually occurred.

## Deduplication

On store: checks exact and near-duplicates (normalized case/punctuation/whitespace). Increments access count on match instead of creating new entry.

## Canonical Observations

`observations` is the authoritative additive envelope. It records stable observation, source, and session IDs; kind and owner/subject; user/project/organization/framework scope; explicit versus inferred state; confidence; sensitivity and consent; effective/review/expiry time; destination and lifecycle status. `observation_sources` preserves evidence and provenance with one unique source record per legacy or native source, so replay cannot create independent evidence. `observation_relations` records supersession, debunking, correction, revocation, extension, and derivation. `observation_outcomes` records retrieval usefulness and operational/review outcomes. Qualifying outcomes require an `outcome_verifications` row naming an independent verifier, an attributable non-learning evidence source, and verification provenance. `observation_promotions` attributes generated guidance to its source and verified outcome, deduplicates each destination, and records correction or revocation without deleting audit evidence.

Existing `learnings` remain the FTS retrieval projection. Database initialization idempotently backfills safely derivable learning, entity-profile, capability-gap, truth/relation, access/usefulness, and graduation history using deterministic IDs such as `obs_learning_<legacy-id>` and `src_learning_<legacy-id>`.

## Auto-Pruning

Runs on every `store` (at most once per 24h). The `learnings` FTS retrieval projection is bounded by hard creation age, row count (`AIDEVOPS_MEMORY_MAX_COUNT`, default 10,000), and logical row bytes (`AIDEVOPS_MEMORY_MAX_BYTES`, default 50 MiB). Access cannot exempt a row from the age bound. Logical bytes are the UTF-8 byte lengths of every projected field: `id`, `session_id`, `content`, `type`, `tags`, `confidence`, `created_at`, `event_date`, `project_path`, and `source`. This is not the SQLite file size or canonical audit-table size. Pruning preserves canonical observations, sources, outcomes, relations, verification, and promotion records. Use `--max-count` and `--max-bytes` for explicit maintenance limits.

## Semantic Search (Opt-in)

Providers: `local` (all-MiniLM-L6-v2, 384d, Python 3.9+ sentence-transformers ~90MB) or `openai` (text-embedding-3-small, 1536d, requires API key). Search modes: keyword (default, FTS5 BM25), `--semantic` (vector similarity), `--hybrid` (keyword + semantic via RRF). Semantic and hybrid results exclude debunked, retracted, and superseded memories. Until their query engine supports the keyword path's scope filters, combining semantic/hybrid mode with `--type`, `--project`, `--entity`, `--max-age-days`, capture-source filters, or `--shared` fails closed; use keyword recall for those queries. Hybrid is recommended for unscoped natural-language queries. New memories auto-indexed once configured. See CLI Reference for setup commands.

## Retrieval Feedback Loop

Inspired by [Ori Mnemos](https://github.com/aayoawoyemi/Ori-Mnemos) Q-value system. Tracks whether recalled memories led to downstream actions — proven-useful memories rank higher.

| Signal | Reward | When |
|--------|--------|------|
| `cited` | +1.0 | Referenced in new content |
| `led_to_new` | +0.6 | New memory created after retrieval |
| `edited` | +0.5 | Memory edited after retrieval |
| `reused` | +0.4 | Recalled across different queries |
| `dead_end` | -0.15 (floor: -1.0) | Retrieved but not used |
| `false` / `debunked` | -2.0 (floor: -5.0) | Retrieved memory was false or myth-like |

**Ranking:** FTS5 blended score = `bm25(learnings) - (usefulness_score * 0.3)`. Hybrid (RRF): usefulness added as third signal. Default recall excludes debunked/retracted and superseded rows before access tracking, so simply seeing a false memory no longer keeps it fresh. Call `feedback` after tasks where recalled memories contributed; use `feedback <id> --signal false` when a retrieved memory is disproven.

## Pattern Tracking

Handled by cross-session memory and pulse supervisor outcome observation (Step 2a). Pulse observes success/failure from GitHub PR state (merged vs closed-without-merge) and files improvement issues when patterns emerge. Commands: `/patterns refactor|report|recommend <type>`, `/route "task description"`. Note: `pattern-tracker-helper.sh` archived; pattern data in `memory.db` remains accessible.

## Memory Graduation

Graduate live, unsuperseded local memories only after an independently verified `test_passed`, `pr_merged`, `operational_verified`, or `verified_reuse` outcome. The outcome command requires verifier identity, a same-observation `test_result`, `pull_request`, `operation`, or `review` source, and verification provenance; the original learning source and self assertions do not qualify. Access count ranks eligible candidates but never qualifies one. Promotion also requires an allowed privacy classification, consent that is not denied, and no later rejection/correction/privacy escape. Generated destination blocks have exact begin/end markers: revocation removes only that block, and correction additionally records a `corrects` relation while retaining audit evidence.

## Memory Audit Pulse

Phase 9 of supervisor pulse cycle (self-throttled to once per 24h). Phases: Dedup → Prune → Graduate → Consolidate → Scan → File opportunities → Report. Commands: `memory-audit-pulse.sh run [--force|--dry-run]`, `memory-audit-pulse.sh status`.

The opportunity scan is actionable in live mode: repeated failures, popular low-confidence memories, untagged-memory debt, superseded-memory cleanup, high growth, and session-metadata noise are converted into worker-ready tasks through `claim-task-id.sh`. Dry-run is report-only and records `would-file` actions without creating issues. Duplicate suppression uses source-detail fingerprints in `~/.aidevops/.agent-workspace/work/memory-audit/opportunity-state.tsv`, so the same opportunity is not filed every 24h. Inspect `last-opportunity-details.txt`, `last-opportunity-actions.txt`, `opportunity-state.tsv`, and `audit-*.txt` in that directory to see what was found, filed, skipped, or failed.

## Memory Consolidation

A `simple`-tier LLM call scans unconsolidated memories, discovers cross-cutting
connections, and stores synthesized insights. Runtime routing determines its
provider and cost. Inspired by Google's [always-on-memory-agent](https://github.com/GoogleCloudPlatform/generative-ai/tree/main/gemini/agents/always-on-memory-agent).
Insights live in `memory_consolidations`; connections use `derives` relations in
`learning_relations`. The scan skips gracefully if `ai-research-helper.sh` or an
approved model route is unavailable. Manual: `memory-helper.sh insights [--dry-run]`.
Daily cron: `0 4 * * * ~/.aidevops/agents/scripts/memory-audit-pulse.sh run --quiet`.

## Entity Memory System

Tracks relationships with people, agents, and services across communication channels. Enables relationship continuity across session resets and context compaction.

**Architecture:** Three-layer design sharing `memory.db`. Full details: `reference/entity-memory-architecture.md`.

| Layer | Purpose | Script | Tables |
|-------|---------|--------|--------|
| Layer 0 | Raw interaction log (immutable, append-only) | `entity-helper.sh` | `interactions`, `interactions_fts` |
| Layer 1 | Per-conversation context (tactical summaries) | `conversation-helper.sh` | `conversations`, `conversation_summaries` |
| Layer 2 | Entity relationship model (strategic profiles) | `entity-helper.sh` | `entities`, `entity_channels`, `entity_profiles`, `capability_gaps` |
| Loop | Self-evolution (gap detection → TODO → upgrade) | `self-evolution-helper.sh` | `capability_gaps`, `gap_evidence` |

**Key concepts:** Entities are people/agents/services. Cross-channel identity links Matrix/SimpleX/email/CLI to the same entity (confidence: confirmed/suggested/inferred). Profiles versioned via `supersedes_id` chain and project into canonical observations; they are never updated in place. Layer 0 is append-only; all other layers are derived from observations and source evidence.

## Namespaces (Per-Runner Isolation)

Use `--namespace <name>` with any `memory-helper.sh` command for per-runner isolation. Add `--shared` to also search global. `memory-helper.sh namespaces` lists all. Namespace DBs: `memory/namespaces/<name>/memory.db`. Global DB: `memory/memory.db`.

## Storage Location

`~/.aidevops/.agent-workspace/memory/`: `memory.db` (global SQLite FTS5 — tables: learnings, learning_access, learning_relations, entities, entity_channels, entity_profiles, interactions, interactions_fts, conversations, conversation_summaries, capability_gaps, gap_evidence, memory_consolidations (t1413)), `embeddings.db` (optional vectors), `namespaces/` (per-runner), `preferences/` (optional markdown).

## CLI Reference

```bash
# Store
memory-helper.sh store --type "WORKING_SOLUTION" --content "Fixed CORS with nginx headers" --tags "cors,nginx"
memory-helper.sh store --content "Deployed v2.0" --event-date "2024-01-15T10:00:00Z"
memory-helper.sh store --content "New info" --supersedes mem_xxx --relation updates
memory-helper.sh store --content "Evidence disproving old claim" --debunks mem_xxx --evidence "Verified current source"
memory-helper.sh store --content "Replacement truth" --supersedes mem_old --relation updates

# Recall
memory-helper.sh recall "cors"
memory-helper.sh recall --recent
memory-helper.sh recall "query" --type WORKING_SOLUTION --project myapp --limit 20
memory-helper.sh recall "query" --semantic   # Vector search
memory-helper.sh recall "query" --hybrid     # FTS5 + semantic (RRF)
memory-helper.sh recall "query" --auto-only  # Auto-captured only
memory-helper.sh recall "query" --manual-only

# Feedback
memory-helper.sh feedback mem_xxx --signal cited
memory-helper.sh feedback mem_xxx --signal dead_end
memory-helper.sh feedback mem_xxx --signal false
memory-helper.sh feedback mem_xxx --value 0.8   # Custom reward

# Version history
memory-helper.sh history mem_xxx   # Ancestors and descendants
memory-helper.sh latest mem_xxx    # Latest in chain

# Maintenance
memory-helper.sh stats
memory-helper.sh validate
memory-helper.sh dedup --dry-run && memory-helper.sh dedup
memory-helper.sh dedup --exact-only
memory-helper.sh prune --older-than-days 60 --dry-run
memory-helper.sh prune --older-than-days 60
memory-helper.sh prune --older-than-days 180 --include-accessed
memory-helper.sh prune --older-than-days 90 --max-count 10000 --max-bytes 52428800
memory-helper.sh log   # Recent auto-captures

# Export
memory-helper.sh export --format json
memory-helper.sh export --format toon

# Entity operations
entity-helper.sh create --name "Marcus" --type person --channel matrix --channel-id "@marcus:server.com"
entity-helper.sh link ent_xxx --channel email --channel-id "marcus@example.com" --verified
entity-helper.sh log-interaction ent_xxx --channel matrix --content "How's the deployment going?"
conversation-helper.sh create --entity ent_xxx --channel matrix --channel-id "!room:server" --topic "Deployment"
conversation-helper.sh context conv_xxx --recent-messages 10
self-evolution-helper.sh pulse-scan --auto-todo-threshold 3

# Graduation
memory-graduate-helper.sh candidates
memory-graduate-helper.sh graduate --dry-run
memory-graduate-helper.sh graduate
memory-graduate-helper.sh outcome mem_xxx test_passed --verifier ci-run-123 --source-id src_test_123 --provenance ci:test-suite
memory-graduate-helper.sh revoke mem_xxx --reason "later evidence disproved guidance"
memory-graduate-helper.sh revoke mem_old --corrected-by mem_new --reason "replacement verified"

# Embeddings
memory-embeddings-helper.sh setup --provider local
memory-embeddings-helper.sh index
memory-embeddings-helper.sh status
```

## Developer Preferences

Structured preference files at `~/.aidevops/.agent-workspace/memory/preferences/`: `coding-style.md`, `documentation.md`, `workflow.md`, `tools.md`, `project-specific/{project}.md`. Check before starting work; update on feedback; check project-specific files when switching projects.

## Security

- Never store credentials or API keys — use configuration references; keep secrets in `~/.config/aidevops/credentials.sh`
- No PII in shareable templates; regular cleanup of outdated information
- **This directory is version controlled** — keep it clean; use `~/.aidevops/.agent-workspace/memory/` for all actual operations
