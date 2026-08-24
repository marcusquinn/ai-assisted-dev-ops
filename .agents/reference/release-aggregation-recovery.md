<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Unpublished Release Aggregation Recovery

## Stale reviewed aggregation successor

When `main` advances after a metadata-only aggregation PR has entered review or
CI, keep that PR immutable and create or adopt one successor at the new exact
tip:

```bash
aidevops release refresh-aggregate <stale-aggregation-pr>
```

The command verifies the stale PR's terminal trailer block, the persisted
release authorization, and every newly merged `main` commit. Each new commit
must map uniquely to a merged-main PR at its immutable merge SHA. It then claims
the repository release lane with compare-and-swap, creates an exact-tip empty
branch commit, opens one draft PR to allocate its number, and only then appends
one immutable terminal trailer commit bound to that number and complete source
set. Retries adopt the same branch, PR, and lane transaction.

The successor remains draft. Review, required checks, ready-for-review, guarded
merge, signing, tagging, and publication are separate explicit operations. If
`main` advances again, run the same command against the now-stale successor; the
ancestry/tree fence is not bypassed.

Use this path only when a protected-main release created a signed local tag but
publication stopped before the tag reached any remote or package channel. It is
not a remote-tag rewrite mechanism.

## Command

After the complete source set is merged through an exact-tip reviewed aggregation:

```bash
aidevops release recover-aggregate <original-source-pr> --tag <vX.Y.Z> \
  --expected-sources <pr[,pr...]>
```

The original source PR must own the active release lane. Every expected source
must appear once in the aggregate commit trailers at its verified merge SHA.

## Preconditions

- The existing tag is an annotated, locally verifiable signed tag for the same
  semantic version and active source operation.
- The tag is absent from every remote, GitHub Releases, npm, and the Homebrew tap.
- No terminal release receipt exists.
- `origin/main` is the reviewed aggregation merge itself, not an arbitrary
  descendant.
- The persisted authorization is an exact subset of the reviewed aggregate.
- The lane is in `remote-publication` or `reconcile-required` for the same source
  and tag, or it contains one valid interrupted `aggregation-recovery` or
  `aggregation-recovery-refresh` transaction, or an owned
  `aggregate-publication-committing` transaction whose provisional tag and exact
  snapshots remain unchanged.

Any unavailable channel read is uncertainty, not absence, and blocks recovery.

## Transaction

1. Verify the provisional tag and all channel-absence evidence.
2. Resolve the exact aggregate and normalize every source to `PR@MERGE_SHA`.
3. Rotate the release-lane token into `aggregation-recovery-refresh`, fencing the
   prior process before authorization broadens. Persist the expanded
   authorization, then advance the same owned lane to `aggregation-recovery`.
   Both records embed their exact pre-transaction JSON for compare-and-swap
   restoration.
4. Claim `aggregate-publication-committing` with the same token, then create an
   empty `chore(release): bump version to X.Y.Z` commit whose parent is
   the exact aggregate. The tree and semantic version do not change.
5. Replace only the local tag with a newly signed aggregate-bound tag and run the
   ordinary protected-main publication queue.
6. Record `.aggregate-recovery.json` evidence and retain the committing phase
   while a protected-main PR is open. Only after the exact release commit is
   reachable from `origin/main` may the lane enter `remote-publication` for
   normal reconciliation.

The earlier side-effect-free reserved-lane normalization uses the same ordering:
rotate into `reserved-authorization-refresh`, persist the exact authorization,
then return to `reserved`. A retry must inspect this phase even when the requested
and persisted PR sets already match, because the authorization write may have
completed before the prior process finished the lane transition.

### Tagless preflight retry

A normal `aidevops release` retry may also reopen a same-source
`reconcile-required` lane after `version-manager.sh` failed before publication.
This is narrower than signed-tag aggregate recovery: the lane must have no tag or
terminal receipt, tag discovery must confirm no matching signed tag, and the
local receipt must remain empty, failed, or `not-requested`. The attempted tag is
read from new failure evidence or reconstructed from the immutable failed source
and its recorded bump type. Legacy evidence without a recorded type is accepted
only for the historical patch path; minor and major retries fail closed. That exact
version must be absent from every remote, GitHub Releases, npm, and Homebrew. Exact failure
evidence must bind the requested PR and merge to the prior direct source or
immutable aggregate merge, whose manifest must equal the persisted and lane
authorization and remain an ancestor of the reviewed retry. The retry may remain
direct when main is still at that exact source, or resolve through a newer
reviewed exact-tip aggregate after intervening merges.

After those checks, a compare-and-swap lane write rotates the fencing token,
records the failed source merge, and returns the lane to `reserved` with a durable
`prepublication_recovery` marker. That marker binds the failed and current
authorization manifests, blocks generic stale reservation reclaim, and forces any
crash retry—including an interrupted authorization refresh—to repeat the evidence,
channel-absence, and token-rotation checks. Any required authorization expansion then uses the existing
`reserved-authorization-refresh` transaction before the ordinary release path
starts again. The marker is cleared only when the ordinary path enters `preparing`,
so any later failure records fresh release evidence. Missing or mismatched evidence, an ambiguous remote state, a tag,
terminal receipt, competing owner, or any other lane phase fails closed. No
manual lane or receipt edit is a supported recovery path.

## Failure and interruption

An initial failure before authorization changes may restore the exact prior lane
snapshot. Once authorization has expanded, recovery does not independently
restore the authorization and lane records: that two-write rollback would expose
another crash window. It retains the fenced transaction for an idempotent retry.
A refreshed aggregate first rotates the lane into
`aggregation-recovery-refresh`, then writes authorization, and finally returns to
`aggregation-recovery`. If a provisional-tag attempt fails after claiming the
committing phase, a retry may rotate that unchanged, unpublished transaction into
a newer reviewed refresh. Recovery uses compare-and-swap lane writes, so a
concurrent owner change fails closed rather than being overwritten.

Before local tag replacement or any direct push, protected recovery-branch push,
PR mutation, merge queue request, or final tag push, version-manager rereads the
remote lane and requires the exact repository, source, tag, manifest, operation
token, and `aggregate-publication-committing` phase. A stale process cannot
publish after its token is rotated; ambiguous claim writes are accepted only
after an exact remote reread.

Once the protected release PR or remote tag is durable, do not restore or mutate
the provisional state. While the PR remains open, rerun the same
`recover-aggregate` command to repair or observe its exact queue; generic
reconciliation leaves the committing fence unchanged. After the release commit
reaches `main`, recovery transitions to `remote-publication` and the normal
reconciliation and channel convergence gates own completion.

Rerunning `recover-aggregate` after an interruption reloads the persisted
snapshots. If the replacement aggregate-bound tag already exists, the command
resumes its exact protected queue from the persisted aggregate before resolving
the newer `main`; it does not replace the tag or create another bump commit. The
recovered-tag validator checks the tag's direct aggregate parent and immutable
source manifest rather than requiring that parent to remain the current main tip.
Once that release commit reaches `main`, recovery enters normal reconciliation.
If `main` advanced before the provisional tag changed, a newer reviewed exact-tip
aggregate may refresh the fenced transaction. The refresh must be a strict
authorization superset, preserve the original snapshots, and rotate the lane
token without nesting recovery state. Ordinary merges remain blocked during
every recovery and committing phase. Inconsistent state fails closed.

The recovery command never force-pushes, rewrites a remote tag, increments the
version, or infers publication authority from commit ancestry.
