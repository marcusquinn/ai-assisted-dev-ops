<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Plan: Personal and shared social knowledge corpora

**Parent task:** t18176
**Status:** Planning
**Created:** 2026-07-25
**Estimate:** ~22h across seven sequential implementation leaves

## 1. Objective

Add an API-first, provider-neutral social ingestion capability that lets an
authorized person query their private social-account history together with
shared team-account knowledge. Collect each shared account once, preserve exact
source and activity provenance, keep private data out of Git, and use bounded
browser automation only for data that official APIs and account archives cannot
provide.

The first provider is X through the existing guarded `xurl` surface. The data
model and query path must support later providers without adding provider-specific
columns to every shared table.

## 2. Goals

- Backfill all accessible account data while recording API/archive coverage and
  known gaps instead of claiming impossible completeness.
- Run checkpointed incremental collection through deterministic aidevops
  routines with cost, rate-limit, and retry budgets.
- Keep each personal or team corpus physically isolated and authorize corpus
  access from workspace membership rather than caller-provided IDs.
- Let a trusted user query their personal corpus plus all authorized shared
  corpora, with source citations and no cross-scope cache or annotation leaks.
- Distinguish authored statements from weak interest signals such as likes and
  bookmarks so query answers do not invent opinions.
- Reuse the knowledge, routines, Reach, RBAC, and Vault contracts rather than
  creating a parallel top-level `_social` data plane.

## 3. Non-goals

- Posting, liking, following, messaging, or any other social-platform write.
- Claiming browser view history or Highlights coverage when no verified source
  exists.
- Treating a like, bookmark, repost, follow, or list membership as proof of a
  person's opinion.
- Copying raw social data, account handles, credentials, cookies, private paths,
  or private query text into public Git, TODO entries, issues, PRs, or logs.
- Sending restricted corpora to a remote model without the existing sensitivity
  and provider-routing gates.
- Shipping multi-human Vault key management by assumption; shared access must be
  implemented and negatively tested before it is advertised as ready.

## 4. Placement in aidevops

Social is an ingestion adapter and retrieval source within the knowledge plane.
It is not a new underscore-prefixed data plane.

- Raw provider evidence and normalized indexes stay in local/Vault-managed
  knowledge corpora.
- Curated reusable summaries may be promoted into `_knowledge/collections/`.
- Qualitative audience signals may be promoted into `_feedback/` only after its
  consent, sensitivity, and retention gates.
- Owned-account analytics may be promoted into `_performance/`.
- Account-specific routines and connection mappings live in a private routines
  repo and private configuration, never the public framework repository.

The reusable framework surfaces should be a small shell CLI wrapper, Python
storage/query modules, provider adapters, tests, and progressively disclosed
reference documentation.

## 5. Tenancy and retrieval model

### 5.1 Terms

| Term | Contract |
|---|---|
| `principal` | A human, team, or non-human collector identity. |
| `workspace` | The personal or shared authorization boundary and default owner of durable records. |
| `corpus` | A physical source/index boundary owned by exactly one workspace. |
| `connection` | One provider account, auth-profile reference, target corpus, collector principal, and sync policy. |
| `object` | A provider object such as a post, user, list, message, or media item. |
| `activity` | A provenance-bearing action or observation involving an object. |

Every connection belongs to one corpus. Moving it between workspaces is an
explicit export/import operation; it is never represented as dual ownership.

### 5.2 Physical layout

```text
~/.aidevops/.agent-workspace/knowledge/
  catalog.db
  corpora/
    <opaque-corpus-id>/
      _config/
      inbox/
      sources/
        social/
          raw/<provider>/<opaque-connection-id>/<batch-id>.json.gz
          media/<sha256>
      index/
        social.db
        embeddings.db
      collections/
        social/
```

Rules:

- IDs used in paths are opaque and do not reveal people, clients, brands,
  account handles, or private repository names.
- Directories are mode `0700`; databases and private config are mode `0600`.
- Existing personal knowledge remains the default personal corpus during the
  first migration; repo-mode knowledge remains unchanged.
- High-volume social connections target personal/workspace corpora, not a
  versioned repo corpus. Promotion creates a curated repo-safe derivative.
- Raw batch hashes are computed over canonical payload bytes before compression.
- Media is content-addressed within a corpus. Cross-corpus hard links are not
  used because they couple deletion and confidentiality boundaries.

### 5.3 Catalog

`catalog.db` contains only the metadata needed to resolve authorized physical
stores:

- `principals(principal_id, kind, status)`
- `workspaces(workspace_id, kind, status)`
- `workspace_memberships(workspace_id, principal_id, role, status)`
- `corpora(corpus_id, workspace_id, location_ref, sensitivity, status)`
- `corpus_grants(corpus_id, principal_id, role, capability, scope)`
- `collector_assignments(connection_id, collector_principal_id, runner_ref)`

Human-readable private labels may exist in an encrypted local settings record;
they are not required for authorization and are not transported in public
metadata.

## 6. Per-corpus social store

Each corpus has its own `social.db`. The minimum normalized schema is:

| Table | Purpose and key invariant |
|---|---|
| `schema_meta` | Version and migration history. |
| `connections` | Provider, opaque remote account ID, auth-profile reference, enabled streams, and policy. Never stores credentials. |
| `accounts` | Provider account identity keyed by immutable remote ID; handles are mutable snapshots. |
| `objects` | Canonical post/user/list/message records keyed by `(provider, object_type, remote_id)`. |
| `activities` | Authored/replied/quoted/reposted/liked/bookmarked/followed/listed/mentioned/captured relationships with actor, object, timestamps, state, and batch provenance. |
| `media` | Object relation, provider media ID, content hash, MIME, size, local blob ref, and hydration state. |
| `fetch_batches` | Stream, request-shape hash, response hash/blob ref, resource count, budget units, timestamps, and terminal status. |
| `sync_cursors` | Independent per-connection/per-stream cursor, watermark, last success, and full-backfill coverage. |
| `sync_runs` | Run status, counts, failure class, retry-after, lease/fencing token, and privacy-safe diagnostics. |
| `tombstones` | Remote deletion/revocation evidence and retention action. |
| `annotations` | Principal-authored private or workspace-shared notes referencing stable object IDs. |
| `objects_fts` | FTS5 projection over authorized object text and normalized metadata. |

Raw responses are authoritative evidence. Normalized rows and FTS/embedding
indexes are rebuildable projections. Cursor advancement occurs in the same
transaction that commits normalized rows and a successful batch record.

Provider-specific fields stay in a versioned `provider_json` envelope or raw
batch; shared query fields remain provider-neutral.

## 7. Authorization

### 7.1 Capabilities

- `social.connection.manage`
- `social.sync.run`
- `social.content.read`
- `social.private_activity.read`
- `social.dm.read`
- `social.annotation.write`
- `social.annotation.share`
- `social.export`
- `social.purge`

Default deny applies. Workspace membership is the first gate. Collector service
accounts receive `social.sync.run` for assigned connections only and do not
receive query, export, annotation, or purge capabilities.

DMs and protected/private-account content are disabled by default. Enabling them
requires an explicitly classified child corpus or equivalent physical boundary,
the matching read capability, and local/provider-approved model routing.

### 7.2 Query scope

On a trusted user's device, default scope is:

```text
personal corpus for authenticated principal
UNION
authorized workspace corpora for active memberships
```

The resolver derives this set from authenticated context. A requested scope may
narrow the set but cannot expand it. The query engine opens only resolved corpus
paths, searches each physical index, post-validates corpus ownership, merges
rankings with reciprocal-rank fusion, and deduplicates canonical objects while
retaining every distinct activity/provenance edge.

A shared runner never implicitly receives personal corpora. Combined personal
and team queries therefore run on an authorized user's trusted device after the
team corpus has been delivered as encrypted batches and indexed locally.

### 7.3 Annotation overlay

A private annotation lives only in the author's personal corpus, even when it
references an object also present in a team corpus. Explicit sharing creates a
new audited workspace annotation. Retrieval may overlay the private annotation
at query time but must never persist the blended result into a team cache.

## 8. Ingestion contract

### 8.1 Provider adapter

Each adapter implements:

- capability discovery;
- account identity verification;
- archive import;
- stream backfill with pagination;
- cursor/watermark delta collection;
- object/media hydration;
- normalization into provider-neutral objects and activities;
- rate-limit and budget classification;
- coverage reporting and documented gaps.

The X adapter uses `.agents/scripts/xurl-helper.sh` and official read APIs. It
must verify the selected app/account identity without reading credential files.

### 8.2 Initial load

1. Import the account archive for owned authored history and owned media.
2. Backfill each enabled official API stream independently.
3. Record the earliest/latest covered timestamp, cursor exhaustion, provider
   retention limit, unavailable endpoint, and partial failure per stream.
4. Fetch text and metadata for all enabled streams. External media-binary
   hydration is controlled by a corpus policy because storage, licensing, and
   deletion needs differ from metadata coverage.
5. Repeat safely after interruption; uniqueness constraints and hashes make the
   result idempotent.

Candidate X streams include authored posts, replies, quotes, reposts, mentions,
likes, bookmarks, followers/following, lists/list membership, and owned analytics
where the configured API permits them. DMs are a separate explicit opt-in.

### 8.3 Delta and reconciliation

- Daily `sync-due` collects normal deltas for every due private connection.
- A designated team runner owns shared connections; leases and fencing tokens
  ensure only one live collector writes a connection.
- Failures do not advance cursors. Terminal rate-limit reset information schedules
  one bounded retry instead of creating a retry storm.
- Weekly reconciliation detects mutable metrics, missing objects, unlikes,
  unfollows, and deletions where provider evidence permits.
- Remote absence is first marked `missing`; destructive local purge follows the
  configured retention policy and an auditable deletion path.

The routine definition is generic and versioned in a private routines repo. It
contains no account handles or credentials; the deterministic helper reads
private connection configuration at runtime.

## 9. Query and knowledge semantics

FTS5 keyword retrieval is mandatory and local. Optional semantic retrieval uses
the existing sensitivity-aware local embedding path. Results are merged per
corpus rather than copied into a global index.

Every answer cites:

- provider and stable object/activity ID;
- source account and activity type when authorized;
- content/event timestamp and observation timestamp;
- corpus scope;
- authored, quoted, inferred, or weak-signal evidence class;
- source batch or archive provenance.

Interpretation rules:

| Evidence | Allowed statement |
|---|---|
| Authored post/reply/quote commentary | “The account expressed … at this time,” with citation. |
| Repost or quote without commentary | “The account distributed this content,” not endorsement. |
| Like or bookmark | “The account liked/bookmarked this,” not agreement or opinion. |
| Follow or list membership | Relationship/organization signal only. |
| Captured timeline item | “Present in a captured timeline,” not proof a human read it. |
| Generated claim | Must be labelled inferred, confidence-scored, reviewable, and linked to evidence. |

Promoting a generated claim into canonical memory or durable curated knowledge
requires an explicit review/promotion event. Social ingestion itself never
silently turns weak signals into user preferences or beliefs.

## 10. Vault and encrypted sharing

- Social corpora inherit the stricter applicable Vault label; derived summaries,
  embeddings, filenames, and metadata are not automatically declassified.
- Helpers call the existing Vault storage gate before opening protected stores
  when Vault is configured or required.
- Sync transports contain encrypted raw/content batches, signed manifests,
  tombstones, and opaque IDs only. Plaintext FTS/vector indexes are rebuilt on
  each authorized device and are never transport payloads.
- Shared collection keys are wrapped only for active authorized principals or
  devices. Revocation stops new key grants, rejects new writes from revoked
  collectors, rotates/rewraps affected keys, and preserves minimal audit evidence.
- Until multi-human membership/key distribution is implemented and tested, the
  supported shared deployment is one trusted team runner. Documentation must not
  imply broader team readiness.

## 11. Browser fallback

Reach/browser capture is a per-stream fallback, never the default collector.

- Use it only after the adapter reports an explicit API/archive gap.
- Read-only operation; no platform writes or engagement actions.
- Use an approved private browser profile and existing cookie/profile broker.
- Persist sanitized provenance and a raw capture under the same corpus policy.
- Add X-specific checkpoint, pacing, selector-drift, and resume tests before any
  unattended browser routine is enabled.
- Treat captured content as untrusted input and scan it before agent action.

## 12. Sequential implementation leaves

| Phase | Deliverable | Primary verification |
|---|---|---|
| 1 | Corpus catalog, personal/workspace corpus contract, authorization resolver, legacy personal alias | Cross-corpus negative tests; existing repo/personal knowledge tests unchanged |
| 2 | Provider-neutral social schema, raw batch store, archive importer, FTS projection | Fixture import is idempotent; hashes and coverage survive restart |
| 3 | Read-only X adapter with account verification, backfill/delta cursors, cost/rate budgets | Pagination/resume/429 fixtures; no mutating `xurl` command reachable |
| 4 | Federated query, RRF/dedup, citations, private annotation overlays, opinion semantics | Personal data absent from team-only query; weak signals never become opinions |
| 5 | Deterministic routines, collector leases/fencing, weekly reconciliation, run receipts | Two competing collectors yield one writer; stale lease cannot advance a cursor |
| 6 | Shared workspace grants, encrypted batch distribution, local reindex, revocation | Ciphertext transport contains no plaintext/private paths; revoked member cannot query |
| 7 | Bounded browser-gap adapter, provider extension contract, user/operator docs | API-first route remains default; browser failures resume without duplicate capture |

Each child issue must re-run memory/discovery/file-reference checks, carry its own
complete write surface and narrow files scope, and use focused verification plus
changed-file lint. Later phases remain blocked on the prior phase so schema and
security contracts converge before automation expands.

## 13. Verification matrix

### Isolation and authorization

- User A cannot resolve, open, query, export, annotate, or purge User B's corpus.
- A team member can query the team corpus but not another member's personal
  corpus.
- A collector can sync its assigned connection but cannot query/export content.
- Revocation removes access before any locally cached query is served.
- Forged corpus IDs and path traversal attempts are rejected before file access.

### Idempotency and recovery

- Re-importing the same archive or API page changes no canonical rows.
- A crash after raw write but before normalization resumes the same batch.
- A crash after row commit cannot leave the cursor ahead of committed content.
- Replaying an old/stale collector lease fails its fencing-token check.
- A schema migration can roll back or rebuild projections from raw evidence.

### Privacy and provenance

- Credentials, cookies, auth tokens, account handles, private paths, and raw
  private content are absent from public output and sanitized diagnostics.
- Encrypted transport contains no plaintext FTS/vector index or revealing names.
- Every returned claim has at least one authorized evidence citation.
- Team query caches never contain private annotations or personal-only activity.

### API and browser safety

- Adapter fixtures cover pagination exhaustion, partial pages, 401/403, 404,
  429/reset, 5xx, malformed payload, and interrupted media hydration.
- Budget exhaustion and repeated rate-limit resets pause only the unsafe route;
  checkpoints preserve remaining acceptance criteria.
- Browser fallback cannot execute a platform write and remains disabled when an
  API/archive route exists.

## 14. Migration and compatibility

- Do not add a new required `repos.json` knowledge value in Phase 1.
- Register the existing personal root as an alias to `personal:default`; do not
  move user files automatically.
- Existing `aidevops knowledge add/list/search`, review, enrichment, PageIndex,
  email, and repo-mode behavior must remain valid.
- Corpus-aware commands are additive. A command with no explicit scope preserves
  current single-corpus behavior until the user enables additional corpora.
- Schema versions and migrations are per corpus. Mixed versions fail closed for
  writes but may retain read-only compatibility where tested.

## 15. Decision log

| Date | Decision | Rationale |
|---|---|---|
| 2026-07-25 | Social is a knowledge ingress/retrieval adapter, not `_social` | Reuses existing promotion, sensitivity, and retrieval contracts without creating a parallel plane. |
| 2026-07-25 | Physical SQLite/index boundary per corpus | Prevents a missing SQL predicate from becoming a personal/team data leak. |
| 2026-07-25 | Shared accounts use one collector | Avoids duplicate API cost, cursor races, and inconsistent snapshots. |
| 2026-07-25 | Combined personal/team retrieval runs on the trusted user device | A central team runner must not receive personal corpora merely to answer a federated query. |
| 2026-07-25 | Raw evidence is authoritative; indexes and Markdown are projections | Enables deterministic rebuilds, schema migration, and citation verification. |
| 2026-07-25 | DMs/private content are separate opt-in scope | Their sensitivity and authorization needs are materially stricter than public/owned activity. |
| 2026-07-25 | Browser collection is a bounded gap adapter | Official APIs and archives are more stable, auditable, and cost/rate predictable. |

## 16. Relevant existing contracts

- `.agents/aidevops/knowledge-plane/01-core-contract.md` — current repo/personal
  roots, source metadata, and index contract.
- `.agents/aidevops/knowledge-plane/03-platform-and-policy.md` — sensitivity and
  LLM routing.
- `.agents/aidevops/knowledge-plane/04-enrichment-index-review.md` — current
  projection/index routines.
- `.agents/content/social-xurl.md` — X auth profiles, multi-account selection, and
  read/write safety boundary.
- `.agents/tools/app-stack/workspace-model.md` — workspace tenancy root.
- `.agents/tools/app-stack/rbac-permissions.md` — default-deny capabilities.
- `.agents/tools/database/vector-search/per-tenant-rag.md` — physical retrieval
  isolation and cross-tenant tests.
- `.agents/reference/routines.md` — deterministic routine and scheduler contract.
- `.agents/reference/vault.md` and `.agents/workflows/vault-fleet.md` — protected
  stores, encrypted transport, local index rebuild, and revocation limits.
- `.agents/aidevops/reach-capture.md` — bounded authenticated browser capture.

## 17. Open implementation questions

These are bounded child-level choices, not blockers to the parent architecture:

1. Whether the first catalog implementation is SQLite-only or a private JSON
   bootstrap plus SQLite migration. SQLite is preferred if focused migration
   tests remain small.
2. Whether external media defaults to metadata-only, owned-and-bookmarked, or
   all-binaries. The schema supports every policy; storage/rights evidence should
   select the default in Phase 2.
3. Whether semantic retrieval reuses the memory embedding engine directly or a
   knowledge-specific shared library. FTS5 remains the mandatory baseline.
4. Which multi-human key-wrapping primitive extends Vault in Phase 6. Do not
   invent cryptography or claim team sync before this decision is implemented
   and externally reviewed where required.
