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

## Verification

Run from the repository root:

```bash
bash .agents/scripts/tests/test-release-lane-reservation.sh
bash .agents/scripts/tests/test-release-lane.sh
bash .agents/scripts/tests/test-full-loop-release-aggregate-recovery.sh
bash .agents/scripts/tests/test-full-loop-release-reconcile.sh
shellcheck .agents/scripts/release-lane-helper.sh .agents/scripts/tests/test-release-lane-reservation.sh
```

Reservation fixtures exercise both queue mechanisms, later pages, partial/API
failure, competing actors, same-source resume, and terminal recovery. Existing
lane/aggregation fixtures cover permitted provenance and metadata-only recovery,
CAS ownership, exact-tip/source-manifest rejection, and successor convergence.
No live release or package writes are needed to verify these contracts.
