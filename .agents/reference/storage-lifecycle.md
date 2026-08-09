---
description: Ownership, safety classes, lifecycle contracts, and convergence rules for aidevops-managed storage
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Storage Lifecycle Architecture

This document defines the framework boundary for diagnosing and bounding data
created during aidevops operation. It is an architecture contract, not authority
to delete data. Store-specific helpers remain responsible for proving that an
artifact is reclaimable before any mutation.

## Design Goals

- Make framework-owned growth measurable and convergent under normal use.
- Preserve active sessions, runtime leases, rollback state, worker recovery,
  and required audit evidence regardless of configured soft limits.
- Distinguish protected, recoverable, cache, and disposable bytes in one
  read-only operator view before adding aggregate cleanup.
- Keep third-party stores visible when useful without claiming ownership or
  deleting data that aidevops cannot classify safely.
- Give leak fixes a conservative, attributable migration path for leftovers.

## Ownership Classes

| Class | Meaning | Allowed framework action |
|---|---|---|
| `framework` | Created and exclusively managed by aidevops | Report, archive, and prune under the store contract |
| `joint` | Aidevops writes or coordinates data owned by a host runtime | Report known components; mutate only through a runtime-aware contract |
| `external` | Package-manager, browser, OS, or user-owned data | Report as context only; never include in automatic reclamation |
| `unknown` | Attribution cannot be proved | Report separately and fail closed |

Path location alone never establishes ownership. For example, an npm cache may
grow because bundle installation used it, but it remains external unless the
package manager provides a scoped and safe cleanup contract.

## Safety Classes

Every reported artifact must have one safety class. When evidence overlaps, the
most protective class wins.

| Class | Examples | Default lifecycle |
|---|---|---|
| `active` | Current bundle, active OpenCode DB/WAL, live session files | Never reclaim |
| `leased` | Runtime bundle with a live process lease | Never reclaim while the lease is valid |
| `rollback` | Previous runtime bundle, most recent deploy snapshot | Retain until a newer rollback point is verified |
| `recovery` | Worker recovery DB, dirty-worktree backup, pending replay data | Retain until terminal state and recovery verification |
| `audit` | Required lifecycle/error evidence and signed operation records | Retain or compact only under an explicit audit contract |
| `archive` | Deliberately retained historical data | Apply documented age/count/byte policy; deletion remains explicit |
| `cache` | Reproducible dependencies, indexes, derived reports | Reclaim after proving no active reference |
| `scratch` | Attributable temporary files with no live owner | Reclaim after owner-death and age checks |
| `unknown` | Unclassified files or ambiguous references | Never reclaim automatically |

Age, count, or byte thresholds are soft limits: they select candidates only.
Reference, lease, recovery, and audit checks remain hard vetoes.

## Initial Store Inventory

| Store | Owner | Primary classes | Existing authority | Required next contract |
|---|---|---|---|---|
| `~/.aidevops/runtime-bundles` | framework | active, leased, rollback, cache | Deployment protects current, previous, and live-leased bundles; unreferenced bundles converge under 30-day, 30-bundle, and 8 GiB soft limits | Keep the limits operator-configurable and preserve fail-closed reporting when references or sizing are unavailable |
| `~/.aidevops/.agent-workspace/observability` | framework | audit, archive, cache | Part streams and tool metadata are bounded at ingestion; runtime events use a 30-day active candidate window, verified immutable archive partitions, compacted low-value summaries, pinned recovery state, and append-only manifests | Measure defaults across routine/high-activity installations before changing the active window or adding any archive deletion policy |
| `~/.aidevops/agents-backups` | framework | rollback, archive | Setup computes a dry-run plan under 10-snapshot, 180-day, and 4 GiB soft limits; the newest snapshot is always protected | Tune defaults from broader measurements without weakening rollback or attribution checks |
| `~/.aidevops/logs/worker-failure-excerpts` | framework | recovery, archive | Excerpts are capped at 64 KiB; each session retains its newest evidence while older duplicates converge under 3-excerpt, 30-day, and 192 KiB soft limits | Add terminal issue/PR awareness before reclaiming the newest evidence for any session |
| `~/.aidevops/recovery/worktrees` (Linux and non-macOS) | framework | recovery, unknown | Archive-first removal copies worktree and Git administrative state into an attributable bucket; exact terminal evidence supports manual plans and bounded producer-owned automatic maintenance | Preserve exact-evidence deletion, bounded scans, resumable receipts, and fail-closed handling for every protected or unknown bucket |
| Pulse active logs and `~/.aidevops/logs/pulse-archive` | framework | active, archive | Pulse preserves active descriptors while gzip-rotating 50 MiB hot/wrapper logs and 1 MiB timing logs; cold archives converge under 1 GiB | Keep rotation producer-owned and never replace it with generic unlink-by-age cleanup |
| OpenCode data under its application-data root | joint | active, recovery, archive, unknown | OpenCode owns session and DB formats; aidevops archive/maintenance helpers coordinate selected operations | Separate logical retention from WAL/fragmentation maintenance; report only classifications proven through OpenCode-aware queries |
| npm and other package-manager caches | external | cache | Package manager owns lifecycle | Context-only reporting; no aidevops aggregate deletion |
| OS temporary and Trash locations | external or joint | scratch, unknown | OS/runtime-specific | Reclaim only aidevops-attributable artifacts through an owner-aware migration; never broad-clean a directory |

The inventory is intentionally conservative. A child implementation may split a
row when one path contains artifacts with different owners or safety classes.

### Recoverable Worktree Archives

Recoverable worktree archives are coupled safety snapshots rather than generic
discarded files. On macOS their default root remains `$HOME/.Trash`, where that
path has OS Trash semantics. On Linux and other platforms the default is the
framework-owned `$HOME/.aidevops/recovery/worktrees`; normal “Empty Trash” must
not silently delete these recovery snapshots. Operators can continue to select
an absolute root with `AIDEVOPS_WORKTREE_TRASH_ROOT` (or the legacy
`AIDEVOPS_ORPHAN_TRASH_ROOT` fallback).

New buckets use the additive `aidevops-worktree-recovery-v2` evidence contract.
Alongside stable Git identity, each records creation time, producer/context,
optional runtime session identity, archive completion, source-removal outcome,
`framework` ownership, the `recovery` safety class, and a `manual-review`
policy. The completion marker is written only after archive integrity and source
identity validation; successful native removal then atomically advances the
source outcome from `pending` to `removed`.

The bucket-level `manual-review` value is retained for v2 producer-format
compatibility and grants no deletion authority. Manual confirmation or a
separate policy-bound automatic plan must still revalidate the exact bucket.

Readers remain compatible with complete v1 buckets from the platform-storage
transition and markerless legacy v1 buckets whose original Git recovery
structure still validates. Partial v2 evidence is never reinterpreted as v1.
Older readers reject v2 and therefore fail closed without damaging an archive.

Run `worktree-helper.sh recovery` for a read-only count/byte report with
protected/unknown reasons. The same producer summary appears as one
`worktree-recovery` record in shared storage status; `reclaimable_bytes` remains
zero because that aggregate report grants no deletion authority. On non-macOS systems, inventory also includes attributable
legacy `$HOME/.Trash/aidevops-worktree-cleanup-*` buckets. Framework-owned
default roots remain distinct from joint OS Trash or operator-selected roots.
Incomplete, symlinked, unrecognised, or unsized buckets are `unknown`; inventory
never migrates, rewrites, or deletes them.

Run `worktree-helper.sh recovery plan --output <absolute-path>` to persist a
versioned `aidevops.worktree-recovery-plan/v2` JSON review artifact. The output
path must be new, absolute, non-symlinked, and writable. The helper builds the
complete document in a mode-0600 temporary file beside the destination and
publishes it atomically without replacing an existing path. Plan generation is
read-only for every recovery root and archive; it never moves, rewrites, or
deletes a bucket.

The envelope records its producer, generation time, deterministic plan ID,
inventory completeness/error state, source roots, reconciled entry/byte totals,
and ordered `candidate`, `protected`, and `unknown` entries. An incomplete global
inventory produces no candidates; a partial report downgrades its reported
entries to unknown. Each attributable entry binds the exact physical bucket and
archive paths to its format, Git HEAD/branch, source/admin/common identity,
archive index and completion-marker digests, expected allocated bytes, observed
local/remote evidence, disposition, and reason codes. Unchanged evidence yields
the same entries and plan ID; the generation timestamp remains observational.
The v2 confirmation token binds that plan ID to the exact candidate count,
expected allocated bytes, schema, and permanent-delete action. Earlier or
tokenless plan versions are never upgraded into destructive authorization.

Candidate status requires a valid complete archive, completed source removal,
a clean tracked/untracked/ignored Git state, an exact merged commit, a closed
linked task, no open pull request, no live Git worktree/registry/claim/process
reference, and exact readable sizing. Positive live or unfinished evidence is
`protected`. Missing APIs, process visibility, identity, validation, or sizing
is `unknown`. Identity and allocated bytes are read again immediately before an
entry is emitted, so concurrent drift downgrades only that entry. Age, size, and
OpenCode or Claude session history never prove reclaimability. Plan files grant
no deletion authority by themselves.

After reviewing a v2 plan, an operator may run:

```bash
worktree-helper.sh recovery apply \
  --plan <absolute-path> \
  --receipt <absolute-new-path> \
  --confirm <manifest-token>
```

Apply accepts only the exact supported producer manifest and its bound token.
It rejects relative or symlinked inputs, existing mismatched receipts or
reservations,
unsupported schemas, duplicate paths or identities, candidates outside an
attributable recovery root, and any summary or digest mismatch. Archive creation
and apply contend on the same exclusive producer lock. The lock records PID,
process start time, and an owner token; live, malformed, ambiguous, or
unverifiable ownership blocks mutation, while only conclusively stale ownership
may be reclaimed.

Under the lock, apply first creates or validates a mode-0600, plan-bound
`aidevops.worktree-recovery-apply-reservation/v1` at the requested receipt path.
This reservation prevents a concurrent plan from deleting data and then losing
its receipt to a path collision. The reservation binds a uniquely allocated
mode-0600 completion file created before mutation; receipt publication never
claims or removes a predictable adjacent path. An exact retry may resume an incomplete
reservation; a different plan or replaced completion file fails before mutation. Apply then revalidates every
candidate and all mutable evidence before moving any candidate. It rechecks each
exact identity and allocated byte count immediately before a same-filesystem
rename into that recovery root's `.retention-trash/<transaction-id>/` directory.
An atomically replaced journal lists every permitted original and staged path;
removal operates only on those journal entries, never a wildcard or a newly
discovered archive. Empty initialization directories and deterministic
journal-next files are recoverable, while any unrelated transaction artifact
fails closed. Interrupted initialization, rename, journal update, or removal
windows remain attributable and can resume only from the exact plan and journal.

Success atomically replaces the exact reservation with a mode-0600
`aidevops.worktree-recovery-apply-receipt/v1` receipt containing the plan and
transaction identities, confirmation binding, times, exact paths and archive
identities, expected/observed bytes, and terminal outcomes. Replaying the same
complete receipt is a no-op; a conflicting receipt or reservation fails closed. Protected,
unknown, unrelated Trash, and newly created content remain untouched. This
explicit command remains the operator-reviewed apply path.

Bounded automatic maintenance runs once after each successful asynchronous
worktree cleanup cycle. It applies only to the default framework-owned recovery
root on Linux and other non-macOS systems. macOS Trash, configured roots, and
attributable legacy Trash buckets remain outside automatic mutation. The
maintenance pass uses the same exact candidate classifier and apply transaction
as the manual path; age or disk pressure only selects among candidates that have
already satisfied every terminal, clean-state, identity, reference, and sizing
requirement above.

The default policy selects exact candidates after seven days, or earlier while
the store exceeds 5 GiB, filesystem free space is below 10 GiB, or filesystem
free space is below 10 percent. One pass scans at most 50 rotating inventory
entries and applies at most 20 candidates or 5 GiB. A persistent cursor prevents
large inventories from starving later entries. Operators may tune these soft
limits with:

- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_RETENTION_DAYS`
- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_SCAN`
- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_CANDIDATES`
- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_BYTES`
- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_STORE_BYTES`
- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB`
- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT`

Set `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_ENABLED=0` to disable the automatic
pass. Invalid limits fall back to defaults. Maintenance uses a separate
owner-validated lock and records a policy-bound `automatic-sha256:` authority in
its plan, journal, and receipt; it never synthesizes the manual confirmation
token. Pending transactions under the maintenance state directory resume before
new inventory is scanned, while completed plans and receipts remain available
for audit. A maintenance failure leaves the affected archive intact and does not
turn a successful broader cleanup cycle into a failure.

An originating OpenCode or Claude session identifier is recovery guidance, not
deletion proof. Session history can reconstruct text edits and intent but may be
archived, unavailable, or incomplete and does not prove preservation of ignored
or binary files, permissions, symlinks, index state, or detached Git metadata.
Existing archive integrity, lock, identity, late-write, detached-HEAD, and
interruption checks remain authoritative.

### Runtime Bundle Retention Overrides

The 30-day, 30-bundle, and 8 GiB runtime-bundle limits are project defaults, not
universal recommendations. Operators can set integer environment overrides for
the update or setup process without changing framework policy:

```bash
AIDEVOPS_RUNTIME_BUNDLE_RETENTION_SECONDS=604800 \
AIDEVOPS_RUNTIME_BUNDLE_MAX_COUNT=5 \
AIDEVOPS_RUNTIME_BUNDLE_MAX_BYTES=1073741824 \
aidevops update
```

Invalid values fall back to the project defaults. These remain soft candidate
limits: the active bundle, previous rollback bundle, Pulse-pinned bundle, and
every live-leased bundle remain protected even when an override is lower than
the protected bundle count or bytes.

On macOS, persist these values for scheduled updates under the
`com.aidevops.aidevops-auto-update` label in
`~/.config/aidevops/plist-env-overrides.json`; the generated auto-update
LaunchAgent injects them into its environment. See
`reference/plist-env-overrides.md` for the file format and setup steps.

### Runtime Bundle Dependency Decision

Runtime activation continues to verify the OpenCode host's existing dependency
tree first and installs declared dependencies inside a staged bundle only when
that verification fails. A new lock-keyed shared dependency store is deferred:
it would introduce shared mutable ownership, concurrent-install locking, cache
integrity, and offline rollback dependencies into otherwise immutable bundles.
The measured duplication is instead bounded by pruning unreferenced bundles.
This preserves atomic activation and makes each retained rollback bundle
self-verifying without making npm's global cache framework-owned.

### Explicit Runtime Bundle Rollback

Normal setup remains monotonic: it rejects an older framework version or a
strict ancestor of the active source commit. Operators can inspect eligible
retained bundles and perform the separate audited transition with:

```bash
aidevops runtime-bundle list
aidevops runtime-bundle rollback --bundle-id <id> --reason "<operator reason>"
```

The command accepts a bundle ID from the managed inventory, never a path. It
requires matching validated manifests, a manifest-bound bundle ID, the retained
source commit, matching version and runtime sentinel hashes, and CLI/plugin
integrity before taking the same mutation lock as setup. The active link,
previous-runtime link, and deployed-SHA stamp are then changed atomically per
file and verified as one transaction. Any post-switch failure restores the
captured active root, previous link, and stamp.

The former active bundle becomes the new rollback point. Existing process
leases and the bounded Pulse runtime pin continue naming their immutable roots;
rollback neither deletes nor rewrites them. Every allowed or blocked attempt is
recorded in the hash-chained runtime-bundle rollback audit log with the operator
reason, outcome, mode, and source/target bundle IDs, versions, and Git SHAs.
Retention can remove an unreferenced bundle before an operator selects it, so
`runtime-bundle list` is the authoritative eligibility inventory at execution
time. A later successful setup or update may move the global link forward again.

### Coordinated Backup and Log Policies

Setup, headless-runtime failure evidence, and Pulse remain separate storage
producers. Coordination means they publish compatible inventory records; it does
not grant a generic helper authority to delete across `~/.aidevops`.

- Setup accepts only timestamp-named snapshot directories that it created. It
  measures all candidates, protects the newest rollback snapshot, computes an
  oldest-first dry run, validates a producer-specific confirmation token, and
  stages exact paths in `.retention-trash` before removal. A symlink, unexpected
  name, sizing failure, or metadata failure preserves every snapshot.
- Headless runtime applies the same plan/confirm/stage sequence only to older
  excerpts for the same sanitized session key. The newest excerpt is unresolved
  recovery evidence and remains protected regardless of age or size. Ambiguous
  names and symlinks are unknown rather than cleanup candidates.
- Pulse retains its descriptor-preserving gzip-and-truncate implementation.
  Active files are never unlinked, so concurrent writers retain valid file
  descriptors, and its existing combined cold-archive byte cap remains the only
  cleanup authority for Pulse logs.

An interrupted staged cleanup leaves either the original or an attributable
producer-local trash copy. Inventory includes trash bytes as protected until a
producer can complete or an operator can diagnose the interrupted action.

## Store Lifecycle Contract

Each framework-owned store must eventually publish the following information to
a shared read-only reporting surface:

1. Stable store and producer identifiers.
2. Root path or runtime-aware query used for inventory.
3. Ownership class and rationale.
4. Artifact safety class and the evidence that established it.
5. Total, protected, reclaimable, and unknown byte counts.
6. Existing age/count/byte limits and the next evaluation time, where relevant.
7. Protection reasons such as current target, previous target, live lease,
   active session, pending replay, or audit requirement.
8. Dry-run candidate details and a store-specific cleanup command, if one exists.
9. Migration marker or version when a fixed leak leaves attributable leftovers.

Inventory failures must leave artifacts `unknown`; they must not turn an
unreadable or unavailable reference into a reclaimable candidate.

## Convergence Contract

A store is bounded when a synthetic steady workload reaches a stable envelope
after its retention window while protected references remain unchanged.
Convergence tests must specify workload, elapsed policy time, protected set,
candidate set, and measured bytes. A passing test demonstrates all of these:

- unreferenced framework-owned artifacts eventually fall within the selected
  age/count/byte policy;
- exceeding a soft limit does not remove active, leased, rollback, recovery, or
  required audit artifacts;
- a failed ownership/reference query produces unknown bytes and no deletion;
- repeated dry runs are idempotent and explain the same candidate decisions;
- cleanup interruption is recoverable or leaves the original artifact intact;
- Linux and macOS fixtures make the same policy decision without relying on
  GNU-only filesystem output.

Defaults should be selected from measurements across both routine and
high-activity installations. Until that evidence exists, implementations may
add reporting and opt-in limits but must not infer aggressive defaults from one
installation.

## Operator Surface

The first cross-store feature is a read-only report, integrated into an existing
status or maintenance path unless implementation evidence justifies a new
command. It should show:

- store, producer, owner, safety class, and policy;
- total, protected, reclaimable, and unknown bytes;
- the exact reason protected data is not reclaimable;
- whether sizing is exact, sampled, estimated, or unavailable;
- a non-destructive next action owned by the responsible subsystem.

Aggregate cleanup is explicitly deferred. A future coordinator may invoke
store-specific dry-run/apply contracts, but it must not implement a generic
filesystem age or size deletion loop.

## Implementation Sequence

1. Build the shared read-only inventory/report contract and fixtures.
2. Bound runtime bundles and evaluate lock-keyed dependency reuse while retaining
   current, previous, and live-leased protections.
3. Define observability audit retention, payload limits, and archival or
   partitioning semantics before compacting append-only evidence. The initial
   contract is implemented by `runtime-events-retention.mjs`; future changes
   must preserve its dry-run, integrity, interruption, and protected-envelope
   tests.
4. Maintain coordinated policies for framework backups, Pulse logs, and worker
   failure excerpts, including conservative attributable-only migration.
5. Coordinate OpenCode-owned storage through runtime-aware reporting and
   maintenance; keep logical session deletion out of framework cleanup.

These are separate child tasks. The parent architecture issue remains open until
the accepted child set is complete or explicitly re-scoped by a maintainer.

## Non-Goals

- A generic disk cleaner or recursive home-directory scanner.
- Automatic deletion of OpenCode sessions or unknown runtime data.
- Limits that override leases, rollback, recovery, or audit invariants.
- Making aidevops responsible for npm, uv, Playwright, browser, or OS caches.
- Content-addressed dependency storage before measurements show that its
  complexity is justified.
