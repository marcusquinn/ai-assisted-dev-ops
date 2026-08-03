# Knowledge Plane — Enrichment, Indexing, and Review

Parent index: `../knowledge-plane.md`.

## Structured Field Extraction / Enrichment (t2849)

After a source is promoted to `sources/`, the enrichment pipeline extracts structured
fields from the OCR text and writes `_knowledge/sources/<id>/extracted.json` with
per-field provenance.

### What Enrichment Produces

```json
{
  "version": 1,
  "source_id": "my-invoice",
  "kind": "invoice",
  "schema_version": 1,
  "schema_hash": "a3f2c1d4e5b6",
  "enriched_at": "2026-04-27T10:00:00Z",
  "fields": {
    "invoice_number": { "value": "INV-2026-001", "confidence": "high", "source": "regex", "evidence_excerpt": "Invoice Number: INV-2026-001", "page": null },
    "supplier_name":  { "value": "Acme Corp Ltd", "confidence": "high", "source": "llm",   "evidence_excerpt": "Supplier: Acme Corp Ltd", "page": null }
  }
}
```

### Schemas

Seven extraction schemas live in `.agents/tools/document/extraction-schemas/`:

| Kind | Schema | Sensitivity |
|------|--------|-------------|
| `invoice` | `invoice.json` | `internal` |
| `contract` | `contract.json` | `internal`/`sensitive` |
| `bank_statement` | `bank_statement.json` | `pii` |
| `financial_statement` | `financial_statement.json` | `internal`/`sensitive` |
| `payment_receipt` | `payment_receipt.json` | `pii` |
| `email` | `email.json` | `pii` |
| `generic` | `generic.json` | `internal` (fallback) |

Each field declares `extractor: "regex"` (fast, deterministic) or `extractor: "llm"`
(flexible). LLM fields route through `llm-routing-helper.sh` with the source's
`sensitivity` tier — PII documents stay local.

### CLI

```bash
# Enrich a specific source (kind from meta.json)
aidevops knowledge enrich <source-id>

# Override kind when meta.json has wrong value
document-enrich-helper.sh enrich <source-id> --kind contract

# Batch: enrich all sources without extracted.json (same as r041)
document-enrich-helper.sh tick

# Dry-run — show what would be extracted without writing
document-enrich-helper.sh enrich <source-id> --dry-run

# Force re-extract even if extracted.json exists
document-enrich-helper.sh enrich <source-id> --force-refresh

# Show enrichment status across sources
document-enrich-helper.sh status
```

### Idempotency

Tracks a 12-char schema hash in `extracted.json::schema_hash`. Same hash → skip
(no LLM calls, no file write). Schema changed → re-extract. `--force-refresh` → always.

### Mixed-media folder scheduling

Folder ingestion writes a source-local `enrichment.json` projection for each
supported item. It records the validated media type and deterministic processor
dispositions without making generated output authoritative:

| Input | Immediate projection | Optional queued projection |
|-------|----------------------|----------------------------|
| UTF-8/structured document | raw metadata, `text.txt` when directly decodable | document extraction |
| Image | media metadata | OCR |
| Audio | media metadata | transcription |
| Video | media metadata | transcription and bounded keyframes |
| Email/mailbox | parsed body, message, and attachment relationships | attachment-specific extraction |

Missing helpers or local binaries produce `unavailable`, not false completion.
Processor failures do not roll back committed raw evidence or successful sibling
items; their coverage remains replayable from the folder manifest.

### Routine r041

```text
- [x] r041 Knowledge enrichment — extract structured fields from freshly-promoted sources repeat:cron(*/30 * * * *) ~2m run:scripts/document-enrich-helper.sh tick
```

### Schema Authoring

Create `.agents/tools/document/extraction-schemas/<kind>.json` with the format shown
in `10-classification.md §Extraction Schemas`. The helper auto-discovers schemas by
filename — no registration step needed.

---

## Corpus Index (t2850)

The pulse-driven `r042` routine runs hourly, incrementally rebuilds per-source
PageIndex trees and aggregates them into a corpus-wide tree for vectorless RAG.

### How It Works

1. **Per-source tree** (`build-source <id>`): reads `_knowledge/sources/<id>/text.txt`,
   calls `pageindex-generator.py` with the source's sensitivity-based LLM tier, writes
   `_knowledge/sources/<id>/tree.json`.
2. **Corpus aggregation** (`build`): groups source trees by kind (invoices, contracts, …),
   builds a meta-tree with root `corpus` and children grouped by kind, writes
   `_knowledge/index/tree.json`.
3. **Incremental rebuild**: hashes source IDs + tree.json mtimes; skips if hash matches
   `_knowledge/index/.tree-hash`. Only newly-added or changed sources are rebuilt.
4. **LLM routing**: each source's sensitivity field maps to an `llm-routing-helper.sh`
   tier (`public/internal/sensitive/privileged`). Routing decisions are audited to
   `_knowledge/index/llm-audit.log` (JSONL, hashed — no raw content).

### Query

```bash
# Query via CLI
aidevops knowledge search "all invoices over £5k"

# Direct invocation
knowledge-index-helper.sh query "all invoices over £5k"
```

Returns JSON: `{"matches": [{"source_id": "…", "score": 4, "anchor": "…", "excerpt": "…"}]}`

`aidevops knowledge search` auto-routes to `knowledge-index-helper.sh query` when the
corpus tree exists; falls back to grep over `text.txt` files otherwise.

### Routine r042

```text
- [x] r042 Knowledge index build — incremental PageIndex tree across corpus repeat:cron(*/60 * * * *) ~2m run:scripts/knowledge-index-helper.sh build
```

To disable: change `[x]` to `[ ]` in `TODO.md` and commit.

The disabled r047 collector routine calls enrichment and incremental index build
only after a successful collector emits a positive content-free changed count.
Empty polls, manual/archive status, and failed collectors do not trigger a full
corpus rebuild. The existing r041/r042 routines remain independent recovery
passes and retain their current review and sensitivity routing.

### Helper CLI

```bash
# Build corpus index (same as r042 routine)
~/.aidevops/agents/scripts/knowledge-index-helper.sh build

# Build tree for one source
~/.aidevops/agents/scripts/knowledge-index-helper.sh build-source <source-id>

# Query the corpus
~/.aidevops/agents/scripts/knowledge-index-helper.sh query "invoice 2026"

# Show index state
~/.aidevops/agents/scripts/knowledge-index-helper.sh status
```

### Files

| File | Description |
|------|-------------|
| `.agents/scripts/knowledge-index-helper.sh` | Shell orchestrator — build, query, status |
| `.agents/scripts/knowledge_index_helpers.py` | Python helper — aggregate + keyword-score query |
| `_knowledge/sources/<id>/tree.json` | Per-source PageIndex tree |
| `_knowledge/index/tree.json` | Corpus meta-tree (aggregated) |
| `_knowledge/index/.tree-hash` | Incremental rebuild cache |
| `_knowledge/index/llm-audit.log` | LLM routing audit (JSONL) |

---

## Review Gate (t2845)

The pulse-driven `r040` routine runs every 15 minutes, scans
`_knowledge/inbox/` for pending sources, and classifies them using the trust
ladder defined in `_knowledge/_config/knowledge.json`.

### Trust Ladder

Three trust classes determine what happens to each inbox item:

| Class | Trigger | Action |
|-------|---------|--------|
| `auto_promote` | `meta.json` `trust: "trusted"\|"authoritative"`, OR `ingested_by` matches a configured bot/email, OR `source_uri` starts with a trusted path | Direct promotion: inbox → staging → sources + audit entry |
| `review_gate` | `ingested_by` matches `trust.review_gate.from_emails` | Staged + `kind:knowledge-review` issue filed with `auto-dispatch` (light review, worker-handled) |
| `untrusted` | Default (`"*"`) | Staged + `kind:knowledge-review` issue filed with `hold-for-review` for manual content inspection |

### Trust Config

Defined in `_knowledge/_config/knowledge.json` (written at provision time from
`.agents/templates/knowledge-config.json`):

```json
{
  "trust": {
    "auto_promote": {
      "from_paths": ["~/Drops/maintainer-knowledge/"],
      "from_emails": ["you@yourdomain.com"],
      "from_bots":   ["my-internal-bot"]
    },
    "review_gate": {
      "from_emails": ["partner@example.com"]
    },
    "untrusted": "*"
  }
}
```

Override per-repo after provisioning: edit `_knowledge/_config/knowledge.json`
directly. The config is versioned in `sources/` — changes are tracked in git.

### Review Issues

Untrusted and review_gate sources produce `kind:knowledge-review` GitHub
issues. Each issue body includes:

- Source ID, kind, SHA256, size, ingested_by, sensitivity
- Trust class and review instructions
- Text preview (first 500 chars) of the source content

**Untrusted**: issues carry `hold-for-review`. After inspecting the staged source, promote it with:

```bash
knowledge-review-helper.sh promote <source-id>
```

The command moves the source from `_knowledge/staging/` to
`_knowledge/sources/`, updates `meta.json` with `state: "promoted"`, and writes
the audit entry. Close the review issue after promotion succeeds. This is a
content-safety hold, not an external-author authority gate, so no cryptographic
self-approval is required.

**Review-gate**: issues carry `auto-dispatch`. A worker reviews and can promote
by calling the same `promote` subcommand.

### Audit Log

Every action is appended to `_knowledge/index/audit.log` (JSONL):

```json
{"ts":"2026-04-27T00:00:00Z","action":"auto_promoted","source_id":"my-doc","actor":"tick","extra":"actor:tick"}
{"ts":"2026-04-27T00:01:00Z","action":"nmr_filed","source_id":"ext-doc","actor":"tick","extra":"issue:https://github.com/… trust_class:untrusted"}
{"ts":"2026-04-27T12:00:00Z","action":"promoted","source_id":"ext-doc","actor":"maintainer","extra":"actor:maintainer path:approve_hook"}
```

`_knowledge/index/` is gitignored — the audit log is local only. The legacy
`nmr_filed` action/state name remains for compatibility with existing source
metadata; newly filed issues use `hold-for-review`.

### Routine r040

```text
- [x] r040 Knowledge review gate — classify inbox items by trust, auto-promote or review-file repeat:cron(*/15 * * * *) ~1m run:scripts/knowledge-review-helper.sh tick
```

To disable: change `[x]` to `[ ]` in `TODO.md` and commit.

### Helper CLI

```bash
# Manual tick (same as r040 routine)
~/.aidevops/agents/scripts/knowledge-review-helper.sh tick

# Explicit promotion after reviewing staged content
~/.aidevops/agents/scripts/knowledge-review-helper.sh promote <source-id>

# Manual audit entry
~/.aidevops/agents/scripts/knowledge-review-helper.sh audit-log <action> <source-id> [extra]
```

---
