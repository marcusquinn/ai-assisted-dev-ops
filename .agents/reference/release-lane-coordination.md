<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Release-lane merge coordination

## Publisher isolation, not a merge freeze

GH#31472 replaces the exact-tip merge fence introduced by GH#31377 with
immutable snapshot releases. Ordinary PRs may merge in every release phase,
including failed or unavailable publication state. Their existing collaborator,
review and exact-head CI checks remain mandatory. Merge queues are not a
dependency of publisher reservation.

The remote lane still serializes **release publishers**. Competing sources
cannot reserve another version, overwrite the active transaction, replace a tag,
or bypass publication authorization. Source ownership and compare-and-swap
fencing remain independent of main branch activity.

## Snapshot contract

1. After publisher reservation, fetch main and select its commit SHA. Pin that
   SHA and the baseline release tag name, tag-object SHA and peeled commit using
   the lane's ownership token before worktree creation or source discovery.
2. Build the detached worktree from the pinned SHA, not a subsequently refreshed
   `origin/main`. Reclaimed reserved retries reuse the same pin and baseline.
3. Verify the baseline tag through GitHub's signed-tag identity and derive the
   merged-PR manifest over the immutable baseline-to-snapshot range. For each
   first-parent commit, verify GitHub's introducing-PR association and its merged
   tip within the range. Rebase-merged commits deduplicate to one verified PR.
   Unknown, unmerged, foreign-base, conflicting, or incomplete records stop
   publication rather than silently omitting changes.
4. Include all those merged PRs automatically after explicit release consent.
   An explicit `--expected-sources` remains an exact integrity assertion, not an
   allowlist that silently drops other merged changes.
5. The signed bump tag binds the source SHA, full manifest, and
   `Aidevops-Snapshot-Base`. Its release commit stays a direct child of the
   snapshot. A protected-main integration PR preserves that commit and normal
   merge gates; it never rebases or retags the published artifact.
6. A cryptographically verified snapshot tag may publish after main gains a
   different descendant tree. The tag must still be reachable from main, and
   package publication repeats provenance verification. Deployment uses the exact
   tag, not the current main tree. Later PR merges are included in the next release.

The baseline can be a signed bump commit preserved as a merge's second parent.
The range excludes all commits already reachable from that baseline; it does
not require the tag itself to be on main's first-parent chain.

## Bounded recovery owner

Existing release reconciliation remains the recovery owner. Historical tags
without snapshot provenance retain their original direct/aggregation semantics
and exact-tree protected-publication check. Never reinterpret or rewrite them
as snapshot releases. A failed legacy lane may still require its authorized
owner to complete recovery, but it no longer freezes ordinary PR merges.

For a stale, open, reviewed aggregation, the existing
`aidevops release refresh-aggregate STALE_AGGREGATION_PR` operation performs one
bounded successor transaction in `scripts/full-loop-release-aggregate-recovery.sh`:

1. Verify the reviewed manifest against reserved intent and the current main tip.
2. Allocate/reuse one lane-CAS successor slot and deterministic exact-tip branch.
3. Create/reuse one draft metadata-only PR with immutable source trailers.
4. Stop for independent review and guarded merge. It neither publishes nor
   recursively creates successors. A changed tip or competing transaction must
   be reconciled, not overwritten or retried in an unbounded loop.

The already-authorized release owner uses `recover-aggregate` only with validated
source evidence and its existing publication authority. An implementation brief
does not grant that authority. Never mutate an already published immutable tag
to repair drift. A terminal receipt releases the publisher lane through the
existing finalization contract.

## Executor liveness and abandoned reservations (GH#31464)

An active publisher lane is **not** evidence of an active release executor. Status
and competing-release diagnostics report `RELEASE_EXECUTOR` separately: `live`,
`dead`, or `unknown`. A matching host digest, PID and process start time establish
local process identity; a reused PID is not the original executor. Foreign hosts,
legacy records, missing dependencies or permission failures remain unknown.
Process liveness alone does not prove useful progress; retain phase/PR evidence.

New reservations record an executor and the `fenced-prepublication/v1` contract.
For an untouched `reserved` lane older than the existing five-minute grace period,
with a verifiably dead local executor, no tag, no terminal receipt and no recovery
transaction, the write-authorized recovery operation is:

```bash
aidevops release recover-reservation SOURCE_PR
```

It re-reads remote state and verifies write authority, then uses the existing
compare-and-swap to persist `abandoned-prepublication` and make the lane inactive.
It does not publish, alter tags, or change the source PR's release receipt. A
concurrent transition to preparing/adoption wins the CAS and blocks recovery.
The publisher must enter preparing successfully before invoking publication.
Competing release starts use the same bounded recovery for eligible reservations;
ordinary merge guards do not read or mutate publisher ownership. Status remains read-only.

Age alone never unlocks a lane. Live/recent reservations, legacy/foreign owners,
publication phases and aggregation recovery are not automatically released. A
stale `preparing` lane is resumable only by the exact same authorized source and
increment when the local executor is verifiably dead, its deterministic detached
worktree remains isolated at the pinned snapshot, no release process survives,
the persisted source manifest still matches, and the intended tag, protected
release branch, GitHub release, npm version, and Homebrew version are all proven
absent. The publisher rotates the operation token through the lane compare-and-swap,
retains durable `preparing_recovery` evidence, and restarts from a fresh copy of
the pinned commit; lookup uncertainty or any existing artifact refuses recovery.
For a reservation without a recorded tag, tag-based `reconcile` may
have nothing to resume: the authorized release owner must restart the same
source with its original increment and persisted intent. This does not grant a
new session publication authority. Do not report background progress without
an observed executor or current recovery evidence. A resumed legacy transaction
does not gain automatic-recovery eligibility merely by acquiring new metadata.

### Legacy authorization on a pinned snapshot (GH#31479)

An authorized same-source retry may encounter an implicit singleton authorization
record from before snapshot support. When the lane is pinned, reserved, tagless
and nonterminal with no legacy recovery transaction, capture verifies the complete
snapshot and requires the old immutable source set to be a compatible subset.
It binds the complete manifest through the publisher CAS before migrating the
local authorization, retaining the previous authorization in its existing recovery
audit record. If local persistence fails, retry the same command: the identical
lane-bound snapshot resumes without rollback or selecting a newer main tip.

Current explicit `--expected-sources` remains an exact assertion; it is never
silently widened. Conflicting source SHAs, stale owner tokens, mismatched pins,
publication state and uncertain reads fail closed. This migration changes neither
signed tags nor an established snapshot range and adds no publication authority.

## Verification

Run from the repository root:

```bash
bash .agents/scripts/tests/test-release-snapshot-helper.sh
bash .agents/scripts/tests/test-release-snapshot-migration.sh
bash .agents/scripts/tests/test-release-lane-reservation.sh
bash .agents/scripts/tests/test-release-lane.sh
python3 .agents/scripts/tests/test-release-lane-owner.py
bash .agents/scripts/tests/test-release-lane-liveness.sh
bash .agents/scripts/tests/test-full-loop-release-aggregate-recovery.sh
bash .agents/scripts/tests/test-full-loop-release-reconcile.sh
shellcheck .agents/scripts/release-lane-helper.sh .agents/scripts/tests/test-release-lane-reservation.sh
```

Snapshot fixtures exercise frozen range discovery, rebase associations, signed
publication after main changes, idempotent pins and stale-owner rejection.
Reservation fixtures exercise queue independence, competing actors, same-source
resume, and terminal recovery. Existing
lane/aggregation fixtures cover permitted provenance and metadata-only recovery,
CAS ownership, exact-tip/source-manifest rejection, and successor convergence.
No live release or package writes are needed to verify these contracts.
