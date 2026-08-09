<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Unpublished Release Aggregation Recovery

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
  and tag.

Any unavailable channel read is uncertainty, not absence, and blocks recovery.

## Transaction

1. Verify the provisional tag and all channel-absence evidence.
2. Resolve the exact aggregate and normalize every source to `PR@MERGE_SHA`.
3. Persist the expanded authorization and rotate the release-lane token into
   `aggregation-recovery`, fencing the prior process. Both records embed their
   exact pre-transaction JSON for compare-and-swap restoration.
4. Create an empty `chore(release): bump version to X.Y.Z` commit whose parent is
   the exact aggregate. The tree and semantic version do not change.
5. Replace only the local tag with a newly signed aggregate-bound tag and run the
   ordinary protected-main publication queue.
6. Record `.aggregate-recovery.json` evidence and return the lane to
   `remote-publication` for normal reconciliation.

## Rollback and interruption

Before a durable queue exists, any failure restores the exact original tag
object, authorization manifest, and release-lane JSON. Recovery uses compare-and-
swap lane writes, so a concurrent owner change fails closed rather than being
overwritten.

Once the protected release PR or remote tag is durable, do not restore or mutate
the provisional state. Resume with `aidevops release reconcile <source-pr>`; the
normal verifier and channel convergence gates own completion.

Rerunning `recover-aggregate` after an interruption reloads the persisted
snapshots. If the replacement aggregate-bound tag already exists, the command
enters normal reconciliation without replacing the tag or creating another bump
commit. Inconsistent or incomplete recovery state fails closed.

The recovery command never force-pushes, rewrites a remote tag, increments the
version, or infers publication authority from commit ancestry.
