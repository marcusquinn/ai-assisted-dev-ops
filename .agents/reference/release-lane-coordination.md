<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Release-lane merge coordination

## Proven defect and ownership

GH#31377 independently reproduced ordinary TODO merge admission during an active
`reserved`, `preparing`, or `reconcile-required` lane. The shared
`release_lane_merge_guard` in `scripts/release-lane-helper.sh` owns the correction;
Full-loop and Pulse already consume it. The historical initiating caller of
PR #31362 remains unknown. Fixture evidence is not historical attribution.

Active ownership now fences ordinary main merges from reservation until the
lane is explicitly inactive. An unknown active phase or inconsistent terminal
label fails closed. Source, provenance, and metadata-only aggregation exceptions
retain their existing phase restrictions and downstream authorization checks.
Other repositories and non-main bases are not fenced by this guard.

## Previously admitted work and remaining race

Before creating a new reservation, `_release_lane_queue_preflight` enumerates
open main PRs using GitHub's `autoMergeRequest` and `mergeQueueEntry` fields with
pagination. Queued work, partial enumeration, missing fields, or API uncertainty
returns 75 **before reservation writes**. The helper does not cancel or mutate
queued work. Existing owners can still adopt/resume their lane during an API
outage; competing sources cannot displace them.

This is not an atomic GitHub lock. A queue entry admitted after the snapshot,
an already-running merge, direct REST/GraphQL writes, an unwrapped CLI, or a
manual host action can still advance main. Neither this guard nor the PATH shim
can revoke those actions. Do not claim that an enqueue-time check proves main
will remain stable. Do not install a blanket repository freeze or weaken branch
protection to compensate.

## Bounded recovery owner

The existing release reconciliation and authorized aggregation helpers remain
the recovery owner, not the TODO producer or an ordinary implementation worker.
Keep exact-tree/provenance checks ahead of tag/package publication. A mismatch
must stop publication, retain the lane, and require reviewed immutable source
evidence; queued work is not itself publication authorization.

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
to repair drift. A terminal receipt releases ordinary work through the existing
lane finalization contract.

## Executor liveness and abandoned reservations (GH#31464)

An active merge fence is **not** evidence of an active release executor. Status
and blocked merge diagnostics report `RELEASE_EXECUTOR` separately: `live`,
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
Ordinary Full-loop/Pulse merge guards and competing release starts use the same
bounded recovery for eligible reservations; status remains read-only.

Age alone never unlocks a lane. Live/recent reservations, legacy/foreign owners,
preparing/publication phases and aggregation recovery are not automatically
released. For a reservation without a recorded tag, tag-based `reconcile` may
have nothing to resume: the authorized release owner must restart the same
source with its original increment and persisted intent. This does not grant a
new session publication authority. Do not report background progress without
an observed executor or current recovery evidence. A resumed legacy transaction
does not gain automatic-recovery eligibility merely by acquiring new metadata.

## Verification

Run from the repository root:

```bash
bash .agents/scripts/tests/test-release-lane-reservation.sh
bash .agents/scripts/tests/test-release-lane.sh
python3 .agents/scripts/tests/test-release-lane-owner.py
bash .agents/scripts/tests/test-release-lane-liveness.sh
bash .agents/scripts/tests/test-full-loop-release-aggregate-recovery.sh
bash .agents/scripts/tests/test-full-loop-release-reconcile.sh
shellcheck .agents/scripts/release-lane-helper.sh .agents/scripts/tests/test-release-lane-reservation.sh
```

Reservation fixtures exercise both queue mechanisms, later pages, partial/API
failure, competing actors, same-source resume, and terminal recovery. Existing
lane/aggregation fixtures cover permitted provenance and metadata-only recovery,
CAS ownership, exact-tip/source-manifest rejection, and successor convergence.
No live release or package writes are needed to verify these contracts.
