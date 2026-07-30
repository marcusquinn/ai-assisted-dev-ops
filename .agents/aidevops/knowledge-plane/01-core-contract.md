# Knowledge Plane — Core Directory Contract

Parent index: `../knowledge-plane.md`.

The knowledge plane is an opt-in file staging area for AI-assisted ingestion of
external documents, data exports, and reference material into aidevops-managed
repos. Each repo can independently enable or disable the plane.

For cross-plane routing metadata, use `.agents/configs/data-planes.json` as the
canonical registry. This document owns the `_knowledge/` directory contract; the
registry owns shared facts such as default sensitivity, ingress/egress, helper,
and retrieval surfaces.

## Modes (`repos.json` field: `knowledge`)

| Value | Description |
|-------|-------------|
| `"off"` | No knowledge plane (default; backwards-compatible) |
| `"repo"` | `_knowledge/` tree inside the repo (versioned with the project) |
| `"personal"` | Shared plane at `~/.aidevops/.agent-workspace/knowledge/` (cross-repo) |

`"off"` is the default so all existing repos are unaffected until explicitly enabled.

`"personal"` mode is useful when knowledge doesn't belong to any single repo yet
(early-stage work, cross-project research, or when no target repo exists).

## Directory Layout

Repo mode retains the original tree:

```text
_knowledge/          ← repo-mode root
  inbox/             ← raw drops — gitignored, pre-review zone
  staging/           ← curated before commit — gitignored
  sources/           ← versioned originals (files ≤30MB)
  index/             ← generated search index — gitignored by default
  collections/       ← named curated subsets — versioned
  _config/
    knowledge.json   ← defaults (sensitivity, trust, ingest policy)
```

Personal mode adds a private catalog around the unchanged legacy tree:

```text
~/.aidevops/.agent-workspace/knowledge/
  catalog.db                     ← schema-v2 corpus and authorization catalog
  _config/
    principal.json               ← owner-only local authentication context
  _knowledge/                    ← personal:default (existing location)
    inbox/
    staging/
    sources/
    index/
    collections/
    _config/knowledge.json
```

Personal provisioning does not move or rewrite `_knowledge/`. It registers that
existing path once as the logical `personal:default` corpus. `catalog.db` and
`principal.json` are mode `0600`; their containing private directories are mode
`0700`.

Schema v2 implements the parent catalog contract with `principals`,
`workspaces`, `workspace_memberships`, `corpora`, `corpus_grants`, and the
reserved `collector_assignments` table. Private logical names are isolated in
`corpus_aliases`; aliases are not path components or authorization inputs by
themselves. Encrypted sharing adds an independently versioned private extension
with principal devices, per-workspace device grants, key generations, monotonic
export/import sequences, and signed grant, revocation, and import events.

The implementation keeps command dispatch, catalog transactions, and private
filesystem/authentication-context checks in separate Python modules so each
security boundary remains independently reviewable.

### Canonical evidence and source identity

Source contract v1 separates logical authority from physical storage. Every raw
item has exactly one canonical identity within its corpus:

```text
ev1:<corpus-id>:<connector-id>:sha256:<canonical-raw-sha256>
```

The corpus ID is the isolation boundary, the connector ID is stable across
restarts and credential rotation, and the digest binds immutable canonical raw
bytes. Replaying the same bytes through the same connector resolves the same ID.
Provider-native IDs remain provenance and projection identity inputs; they never
replace the raw integrity boundary. Rebinding a connector to another account or
corpus fails before persistence.

`_inbox` is disposable transit. `_knowledge` owns raw evidence. Normalized rows,
Markdown, indexes, embeddings, coverage summaries, notification state, case
timelines, and project views are derived projections. A projection carries its
canonical `evidence_id`, `corpus_id`, `canonical_plane:"_knowledge"`, and
`authority:"projection"`; it cannot be promoted into a second authoritative
copy. `_cases` and `_projects` may retain purpose-specific state around that
pointer. Cross-corpus resolution requires the authenticated catalog graph and an
explicit active grant; aliases and filesystem paths are not authority.

Connector checkpoints are projections too. A cursor advances only in the same
transaction as raw evidence, normalized rows, coverage, and the current lease
fence. Malformed pages, credential-shaped fields, identity rebinding, stale
fences, or interrupted writes preserve the previous checkpoint and evidence.
Coverage gaps are sanitized durable facts, never inferred completeness.

Personal add operations require `knowledge.write`; list and search require
`knowledge.read`. The resolver derives an opaque principal ID from the current
filesystem owner's non-symlink `principal.json`, then requires an active
principal, workspace, workspace membership, corpus, and explicit capability
grant. Missing or inactive edges, malformed/insecure context, forged aliases,
and paths outside the configured personal base fail closed. Callers cannot
supply a principal ID or physical corpus ID. Repo mode does not use this catalog
in Phase 1.

### Per-corpus social store

An authorized personal or workspace corpus may add a private social source and
local projection without changing repo-mode knowledge:

```text
<corpus-root>/
  sources/social/raw/<provider>/<opaque-connection-id>/<sha256>.json.gz
  index/social.db
```

`knowledge-social-helper.sh` resolves a logical corpus alias through the
authenticated catalog before it provisions schema v5, imports a provider-neutral
archive, reports per-stream coverage, or rebuilds the FTS5 projection. Mutating
operations require `knowledge.write`; coverage requires `knowledge.read`.
Coverage opens only an existing, checkpointed database through SQLite immutable
read-only mode; it never creates or migrates schema and rejects mutable journal
sidecars. Callers cannot provide a physical corpus root. Archives
contain `provider`, opaque `connection_id`, immutable remote account ID,
`exported_at`, and optional `accounts`, `objects`, `activities`, `media`, and
`coverage` arrays. Provider-only fields remain in `provider_json`; credential
keys are rejected before raw persistence.

Canonical JSON bytes are SHA-256 addressed before deterministic compression.
The raw batch is authoritative and immutable. Normalized rows, coverage, and
`objects_fts` are projections: repeat import is idempotent, and `rebuild`
recreates FTS5 from canonical object rows without changing raw evidence. The
schema-v5 `corpus_contract` and `evidence_sources` tables bind every fetch batch
to one corpus-scoped source. `canonical_evidence_projections` exposes stable
object, activity, and media projection IDs while preserving each raw pointer. The
v4-to-v5 migration is additive, transactional, replay-safe, and retains all raw
files, rows, checkpoints, coverage, and old query columns. A failed migration
rolls back without advancing `user_version`; prior readers remain usable until a
successful write-side migration.
The database is mode `0600`, containing directories are `0700`, unsafe IDs and
symlinks fail closed, and unsupported schema versions reject writes.

`knowledge-social-helper.sh query` derives the authenticated principal and
searches `personal:default` plus every active workspace corpus carrying an
explicit `knowledge.read` grant. `--alias` only narrows that resolved set.
Physical paths and caller-supplied principal/corpus IDs are not accepted. Each
store is opened independently through the immutable read-only guard; absent
social stores contribute no candidates, while symlinks, mutable journal state,
and incompatible schemas fail the whole query closed.

FTS candidates are ranked within each corpus, fused with deterministic
reciprocal-rank fusion (`k=60`), and deduplicated by provider/object type/stable
remote ID. A result retains every authorized corpus, batch, object, activity,
event-time, and observation-time citation. Query output contains logical aliases,
never physical corpus paths, and creates no cache, journal, index, or database.

Private annotations are written only to the authenticated
`personal:default` corpus through `knowledge.write`. Combined queries may
overlay those notes onto the same stable object returned from a workspace
corpus, but a team-only query never opens or emits the personal overlay. Social
query semantics permit attributed opinion only from cited `authored` evidence;
quotes without commentary, reposts, likes, bookmarks, follows, list membership,
and captured observations remain distribution, weak, relationship, or observed
signals. Generated inference remains explicitly labelled and reviewable. An
inferred object must carry a finite `provider_json.confidence` score from `0` to
`1`; malformed or missing confidence fails the query closed, and output retains
the score with a mandatory-review marker and its evidence citation count.

Encrypted sharing reuses each local Vault message device's Ed25519 signing and
X25519 encryption keys. An owner issues a signed grant to one opaque principal
and device; the recipient verifies the out-of-band owner identity and accepts
that grant into its own private catalog without copying another device's catalog
or physical paths. Export remains owner-device-only and requires the owner's
`knowledge.manage` grant until the dedicated social capability model is added.

Each snapshot contains immutable raw evidence plus normalized rows, but never
aliases, physical paths, SQLite files, FTS tables, auth-profile references, or
private annotations. A random AES-256-GCM content key encrypts the canonical
snapshot and is wrapped independently to every active recipient device with
ephemeral X25519 and HKDF-SHA256. The owner signs the public header, wraps, and
ciphertext. Recipients verify that signature and authorize the workspace,
principal, device, capability, sender, key generation, and monotonic sequence
before content-key unwrap or payload decryption, then restore raw evidence and
normalized rows and rebuild SQLite/FTS locally.

Signed revocation disables the local membership, grants, and device wraps and
advances the key generation before later snapshots are accepted. Recipients
apply contiguous signed generations so an out-of-order record cannot skip an
earlier local revocation. Revocation prevents local cached queries and future key
delivery but cannot erase plaintext or old content keys already delivered to a
malicious, offline, or rollback-controlled device. Multi-human sharing therefore
remains opt-in pending the external Vault crypto/security review; one trusted
team runner remains the default documented deployment.

Provider extensions and browser-gap ingestion follow
`05-social-operations.md`. The provider contract permits no platform writes and
fixes collection priority at API, archive, then browser gap. A browser artifact
requires an explicit API/archive coverage gap, matching tested selector version,
private mode-0600 inputs, hard item/byte limits, and a resumable checkpoint.
Canonical replay is idempotent and consumes no provider request budget.

**Provision:** `aidevops knowledge init repo` or `aidevops knowledge init personal`.
**Repair:** `aidevops knowledge provision` is idempotent — safe to re-run.

Reach-captured web/app evidence enters knowledge only through `_knowledge/inbox/`
or `_knowledge/staging/`. `reach capture --dest knowledge-inbox` writes raw
artifacts under `_knowledge/inbox/web/` with `sensitivity:"unverified"`,
`trust:"unverified"`, and `review_required:true`; promotion into `sources/` or
`collections/` requires a separate review path. The capture command also appends
an `_inbox/triage.log` audit row with `source:"reach-capture"` so provenance is
visible before durable knowledge-plane ingestion.

## .gitignore Rules

The provisioner writes two sets of `.gitignore` rules:

1. **`_knowledge/.gitignore`** — ignores `inbox/`, `staging/`, and `index/` within the
   knowledge root. `sources/` and `collections/` are intentionally NOT ignored —
   versioned originals belong in git.

2. **Repo root `.gitignore`** — appends a `# knowledge-plane-rules` block with
   `_knowledge/inbox/`, `_knowledge/staging/`, `_knowledge/index/` for belt-and-
   suspenders coverage.

## Source `meta.json` Schema

Each ingested source should have a `meta.json` alongside its content in `sources/`:

```json
{
  "version": 2,
  "contract_version": 1,
  "id": "unique-kebab-id",
  "corpus_id": "repo:default",
  "evidence_id": "ev1:repo:default:local-file:sha256:<digest>",
  "authority": "raw",
  "plane": "_knowledge",
  "projection": false,
  "kind": "document|dataset|export|reference|email|attachment",
  "source_uri": "https://source.example/path-or-local:filename",
  "sha256": "hex-hash-of-original-file",
  "ingested_at": "2026-04-25T00:00:00Z",
  "ingested_by": "local-operator",
  "sensitivity": "public|internal|pii|sensitive|privileged",
  "trust": "unverified|reviewed|trusted|authoritative",
  "blob_path": null,
  "size_bytes": 12345,
  "connector": {"id": "local-file", "native_id": "unique-kebab-id"},
  "provenance": {
    "captured_at": "2026-04-25T00:00:00Z",
    "source_uri": "https://source.example/path-or-local:filename",
    "content_sha256": "hex-hash-of-original-file"
  }
}
```

Version-1 manifests remain readable. New ingestion writes version 2 and deduplicates
by raw SHA-256 before creating a source directory. `source_uri` removes local
operator paths, URL credentials, query strings, and fragments. Large-file
`blob_path` values are opaque digest references rather than host paths.

## Recursive folder snapshots

`knowledge-helper.sh folder import <directory>` inventories one explicitly
allowed root without following symlinks. Defaults bound depth, visited node count,
file count, total bytes, item size, and elapsed time; `--exclude`, `--max-depth`,
`--max-nodes`, `--max-files`, `--max-bytes`, `--max-item-bytes`, and
`--max-seconds` can tighten those limits.
Use `--dry-run` to produce planned and coverage counts without writing evidence.

Folder identity derives from the root filesystem object and does not expose the
operator's absolute path. Private, versioned manifests live under
`_knowledge/index/folder-imports/<root-id>/manifest.json`. Each item records its
relative-path observation, digest, canonical source/evidence pointer, aliases,
processor disposition, and a sanitized terminal state: `imported`, `unchanged`,
`skipped`, `unsupported`, `failed`, or `budget-stopped`. The index is a disposable
projection; canonical raw bytes remain in `sources/` or the blob store.

One fenced lease serializes scans of a root. Evidence is committed before the
item checkpoint, and the manifest is atomically replaced after every item. A
replay after interruption therefore resolves already committed bytes and resumes
without duplicate authority. Renames add aliases. Only a complete, unexcluded
inventory can infer disappearance; it adds a deletion observation and never
purges canonical evidence.

Supported inputs include UTF-8 text and structured documents, validated document
containers, images, audio, video, `.eml`/`.emlx`, and mbox exports. Email bodies,
mailbox messages, and exactly decoded attachments become canonical child evidence
with explicit relationships. Nested `message/rfc822` parts that the parser can
only reserialize remain unsupported projections rather than claiming raw
authority. Media enrichment is a projection: local metadata completes
immediately while OCR, transcription, document extraction, and keyframes are
queued or marked unavailable according to local capability. Unsupported and
malformed inputs remain visible coverage instead of being reported as success.

## 30MB Blob Threshold

Files ≥30MB are NOT stored in-repo. Instead:

1. The original is moved to `~/.aidevops/.agent-workspace/knowledge-blobs/<repo>/<source-id>/`.
2. `meta.json` stores only `"blob_path": "knowledge-blobs:sha256:<digest>"`; the
   standard blob layout resolves that opaque reference locally.
3. Only the `meta.json` is committed.

**Rationale:** git performance degrades with large binaries; LFS is optional and
complicates cloning; the agent-workspace path is local and survives repo clones.
30MB is the threshold where git's pack performance starts to noticeably degrade
for typical document files (PDFs, exports, dumps).

## `_config/knowledge.json` Defaults

Written at provision time from `.agents/templates/knowledge-config.json`:

```json
{
  "version": 1,
  "sensitivity_default": "internal",
  "trust_default": "unverified",
  "blob_threshold_bytes": 31457280,
  "trust_ladder": ["unverified", "reviewed", "trusted", "authoritative"],
  "sensitivity_levels": ["public", "internal", "pii", "sensitive", "privileged"],
  "ingest_policy": {
    "auto_sha256": true,
    "require_meta": true
  }
}
```

Override per-repo by editing `_knowledge/_config/knowledge.json` after provisioning.

## Personal vs Repo Plane

| Aspect | `repo` | `personal` |
|--------|--------|------------|
| Location | `<repo>/_knowledge/` | `~/.aidevops/.agent-workspace/knowledge/_knowledge/` (`personal:default`) |
| Versioned | Yes (with repo) | No (local only) |
| Scope | Single repo | All repos on this machine |
| Use case | Project-specific docs | Early-stage, cross-project |
| Gitignore | Patched in repo | Not applicable |

## CLI

```bash
# Provisioning
aidevops knowledge init repo           # Provision _knowledge/ in current repo
aidevops knowledge init personal       # Provision at ~/.aidevops/.agent-workspace/knowledge/

# Bounded mixed-media folder snapshots
aidevops knowledge folder import path/to/folder --dry-run
aidevops knowledge folder import path/to/folder --max-nodes 5000 --max-files 1000 --max-bytes 1073741824
aidevops knowledge folder status path/to/folder --json
aidevops knowledge init off            # Disable knowledge plane for current repo
aidevops knowledge status              # Show provisioning state + item counts
aidevops knowledge provision [path]    # Re-provision / repair (idempotent)

# Ingest a local file (auto-classifies sensitivity)
aidevops knowledge add path/to/file.pdf

# Ingest from a URL (downloads to inbox, moves to sources)
aidevops knowledge add https://example.com/report.pdf

# Ingest large file (>30MB) — routed to blob store, stub in _knowledge/sources/
aidevops knowledge add https://example.com/large-dataset.zip --allow-large

# Ingest with explicit ID and sensitivity override
aidevops knowledge add path/to/file.pdf --id my-doc --sensitivity privileged

# List all known sources (inbox + staging + sources)
aidevops knowledge list

# Filter by state or kind
aidevops knowledge list --state staging
aidevops knowledge list --state sources --kind document

# Search across sources
aidevops knowledge search "invoice 2026"

# Manual sensitivity correction after ingestion
aidevops knowledge sensitivity override <source-id> privileged --reason "Legal advice per review"

# Show current tier + audit trail for a source
aidevops knowledge sensitivity show <source-id>
```

The helper: `.agents/scripts/knowledge-helper.sh`.
