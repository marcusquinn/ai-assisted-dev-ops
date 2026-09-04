---
description: Recovery archive evidence, planning, apply, and automatic maintenance contracts
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Recoverable Worktree Archives

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
never migrates, rewrites, or deletes them. Entry-local sizing failures are
reported in `sizing_error` and do not become structural `error` failures. The
aggregate byte totals remain unavailable when any entry is unsized, while
independently exact entries retain their own evidence.

Run `worktree-helper.sh recovery plan --output <absolute-path>` to persist a
versioned `aidevops.worktree-recovery-plan/v2` JSON review artifact. The output
path must be new, absolute, non-symlinked, and writable. The helper builds the
complete document in a mode-0600 temporary file beside the destination and
publishes it atomically without replacing an existing path. Plan generation is
read-only for every recovery root and archive; it never moves, rewrites, or
deletes a bucket.

Manual planning classifies at most 100 entries per invocation by default. It
first inventories archive structure without running an exact size probe for
every bucket, then performs the full evidence and one final exact-size check
only for the selected window. Use `--max-classify <1-1000>` to tune that bound
and `--offset <non-negative-integer>` to continue from a prior plan's
`next_classification_offset`. A 120-second between-entry deadline bounds each
pass further; tune it with `--deadline-seconds <1-3600>`. Entries outside the
window or beyond the deadline remain visible as `unknown` with
`classification-deferred` or `classification-deadline-exhausted`; they gain no
deletion authority. The plan records classification completeness,
classified/deferred counts, deadline state, and both cursor offsets. Repeated
bounded plans can therefore inspect or reclaim independent windows without an
unbounded pass or an authoritative size cache.

The envelope records its producer, generation time, deterministic plan ID,
inventory completeness/error state, source roots, reconciled entry/byte totals,
and ordered `candidate`, `protected`, and `unknown` entries. An incomplete global
inventory produces no candidates; an entry-local sizing failure downgrades only
that entry. Each attributable entry binds the exact physical bucket and
archive paths to its format, Git HEAD/branch, source/admin/common identity,
archive index and completion-marker digests, expected allocated bytes, observed
local/remote evidence, disposition, and reason codes. Unchanged evidence yields
the same entries and plan ID; the generation timestamp remains observational.
The v2 confirmation token binds that plan ID to the exact candidate count,
expected allocated bytes, schema, and permanent-delete action. Earlier or
tokenless plan versions are never upgraded into destructive authorization.

Candidate status requires a valid complete archive, completed source removal,
a clean tracked/untracked/user-ignored Git state, an exact merged commit, a
closed linked task, no open pull request, no live Git
worktree/registry/claim/process reference, and exact readable sizing. Ignored,
untracked directories with recognised regenerable-cache identities
(`node_modules`, `.pnpm-store`, `.yarn/cache`, `.next/cache`, `.nuxt/cache`,
`.turbo`, `.parcel-cache`, `.vite`, `__pycache__`, and `.pytest_cache` at any
depth, plus `.codegraph` only at the repository root) do not make an otherwise
clean archive dirty; new archives omit only those directory roots after proving
they contain no tracked files. Other ignored content remains protected. Positive live or
unfinished evidence is `protected`. Missing APIs, process visibility, identity,
validation, or sizing is `unknown`. Identity and allocated bytes are read again
immediately before an entry is emitted, so concurrent drift downgrades only
that entry. Age, size, and OpenCode or Claude session history never prove
reclaimability. Plan files grant no deletion authority by themselves.

Automatic maintenance may reclaim those same approved cache roots from an
otherwise protected mixed archive without deleting the archive. This narrower
path applies only when the archive is protected solely by a dirty Git state,
source removal is complete, and commit, task, pull-request, worktree, registry,
claim, and process evidence is terminal and clear. Each selected root must be
an exact ignored and untracked approved directory with no symlink component,
tracked path, or hard-linked regular file. A bounded manifest records its
device/inode identity and allocated bytes; uncertainty, deadline exhaustion,
Git output beyond the fixed capture ceiling, or drift preserves the root.
Ordinary recovery planning short-circuits once dirty; automatic maintenance completes
downstream evidence, and cache apply repeats the snapshot. Terminal commit evidence
must match the exact merged PR head OID, not only its branch; root sizing waits until eligible.

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
free space is below 10 percent. If bounded aggregate sizing times out, the pass
enters conservative pressure mode with `aggregate-size-unavailable` rather than
silently disabling the store limit; exact per-bucket sizing and all terminal
evidence remain mandatory before deletion. One pass cheaply enumerates paths,
then validates and classifies at most 50 rotating inventory entries inside a
120-second deadline, and applies at most 20 candidates or 5 GiB. Expensive
per-archive Git validation is limited to that cursor window and bounded by the
same deadline. Both the initial size probe and its mandatory drift-detection
remeasurement use the remaining pass budget rather than the shorter global
reporting timeout. Final exact archive sizing is candidate-only; protected and
unknown entries retain their existing inventory observation without that probe.
A persistent cursor advances after a deadline stop so large inventories cannot
starve later entries. Operators may tune these soft limits with:

- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_RETENTION_DAYS`
- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_SCAN`
- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_CANDIDATES`
- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_BYTES`
- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MAX_STORE_BYTES`
- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_KB`
- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_MIN_FREE_PERCENT`
- `AIDEVOPS_WORKTREE_RECOVERY_AGGREGATE_SIZE_TIMEOUT_TENTHS`
- `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_DEADLINE_SECONDS`
- `AIDEVOPS_WORKTREE_RECOVERY_CACHE_PRUNE_MAX_ROOTS`
- `AIDEVOPS_WORKTREE_RECOVERY_CACHE_PRUNE_MAX_BYTES`

Set `AIDEVOPS_WORKTREE_RECOVERY_MAINTENANCE_ENABLED=0` to disable the automatic
pass. Invalid limits fall back to defaults. Maintenance uses a separate
owner-validated lock and records a policy-bound `automatic-sha256:` authority in
its plan, journal, and receipt; it never synthesizes the manual confirmation
token. Pending transactions under the maintenance state directory resume before
new inventory is scanned, while completed plans and receipts remain available
for audit. Each run result includes bounded diagnostics outside the signed v1
automatic-policy object: inventory/scanned counts, cursor movement, deadline
state, pass coverage, and fixed-cardinality reason counts for unknown and
protected entries.
Exact safe reason buckets distinguish sizing, identity drift, unavailable
evidence, live references, unfinished tasks, retention policy, and selection
limits without exposing archive paths. A private state record accumulates those
counts across bounded cursor windows and resets if the inventory or pressure
state changes.

When protected mixed archives contain approved cache roots, one pass selects at
most 100 roots and 5 GiB by default inside the same scan and deadline budget.
Cache pruning takes precedence over whole-bucket deletion for that pass and uses
its own `aidevops.worktree-recovery-cache-prune-plan/v1` plan and
`cache-automatic-sha256:` authority. Apply revalidates archive and root
identities, ignored/untracked state, allocated bytes, symlink and hard-link
safety, and all terminal claim, process, task, pull-request, and commit evidence
both before the transaction and immediately before each rename. The initial
apply receives the scan's absolute deadline rather than starting a new budget;
an exhausted pass defers every selected cache root without mutation. A pending
transaction receives one fresh bounded deadline only when a later maintenance
pass resumes it. Apply stages only the exact root into an archive-local
`.retention-trash` transaction. Its journal survives interruption before or
after rename or bounded removal. A `removing` journal state permits a timed-out
delete to continue only while the isolated root identity and remaining
allocation stay within the original bound. Pending cache plans resume before
new inventory. Receipts retain the expected allocation, an independent exact
staged-root measurement, and a zero post-delete allocation observation before
reporting those namespace bytes as reclaimed; they do not infer global
filesystem free-space changes from concurrent `df` activity. Run outcomes report
`cache-pruned` or `resumed-and-pruned`. User files and the protected archive
remain untouched.

When a stable inventory completes a full pressure-active scan cycle with zero
candidates, the result retains `outcome:"no-candidates"` and sets
`escalation.required:true`. Its fixed command array directs the operator to run
`worktree-helper.sh recovery plan --output <absolute-new-path>`. Planning is the
bounded, read-only remediation path described above; it grants no deletion
authority. Protected and uncertain buckets remain untouched, and only a
separately reviewed manual plan can proceed to the existing confirmation-bound
apply path. A maintenance failure leaves the affected archive intact and does
not turn a successful broader cleanup cycle into a failure.

An originating OpenCode or Claude session identifier is recovery guidance, not
deletion proof. Session history can reconstruct text edits and intent but may be
archived, unavailable, or incomplete and does not prove preservation of ignored
or binary files, permissions, symlinks, index state, or detached Git metadata.
Existing archive integrity, lock, identity, late-write, detached-HEAD, and
interruption checks remain authoritative.
