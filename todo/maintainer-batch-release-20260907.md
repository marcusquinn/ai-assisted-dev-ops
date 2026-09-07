<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2026 Marcus Quinn -->

# Maintainer batch release aggregation

Baseline publication: v3.32.329. The user explicitly authorized the interactive
maintainer-review batch through release. Every included source must be verified
merged before this aggregation can publish; a listed PR is not evidence of merge.

## Source set

| PR | Change |
|---|---|
| #31416 | Bound binary review evidence to exact Git targets and preserve unusual filenames |
| #31438 | Scope legacy task identities by verified repository and fix CLI/mapping verification |
| #31446 | Document multisite cron readiness checks |
| #31448 | Start source-access grant lifetime at human confirmation |
| #31449 | Resume bounded cleanup safely across interrupted repository operations |
| #31451 | Bound and validate source-request descriptor reads |

The authoritative SHA-pinned manifest is recorded in the reviewed aggregation
squash-merge commit with `Aidevops-Release-Aggregator-PR` and one
`Aidevops-Release-Aggregates: PR@MERGE_SHA` trailer per source. The release helper
must match that set exactly against the explicit expected-source manifest and
the current main tip before changing a version or publishing a tag.

## Verification and exclusions

- Source PRs retain their runtime/test evidence and exact-head review/check gates.
- This aggregation changes release bookkeeping only, not production behavior.
- Release publication, package channels, postflight and exact-tag deployment must
  produce terminal receipts before the release is reported complete.
- The remaining historical recovery backlog in #31407 and remote wrong-parent
  ownership evidence in #31405 are not permission to remove protected archives.
  They remain separate from the verified code fixes in this release.
