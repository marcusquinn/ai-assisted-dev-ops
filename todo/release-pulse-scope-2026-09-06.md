# Pulse scope release aggregation

## Purpose

Bind the next release to the reviewed default-branch tip after the Pulse scope
producer fix and browser bootstrap guidance both merged. This is release
provenance bookkeeping, not evidence that useful worker concurrency recovered.

## Verified source manifest

- PR #31394: `63067df4455cb286ed7e482d691fe6a6ec594bc4` — canonical scope
  production and executable Pulse self-improvement findings.
- PR #31424: `3124acdfdb262045fda899653a7d833696f1a233` — bounded,
  explicitly approved browser bootstrap guidance and existing regression checks.

The preceding release-preservation PR #31423 has the same tree as v3.32.325;
it introduces no additional unpublished source changes.

## Verification and boundaries

Both source PRs are merged to main with verified immutable merge SHAs. PR #31394
passed 258 focused assertions, local lint, independent scope review and required
remote checks. PR #31424 reports 27 focused activation tests and local lint;
the aggregation review inspected its complete two-file diff.

The aggregate introduces only this manifest. Preserve signed release trailers
in its exact reviewed head and squash merge body. Use the canonical release
entrypoint and existing reserved-lane recovery; never bypass provenance, quota,
permission, ownership or exact-tag deployment gates.

Keep the broader recovery assessment on #31401 open pending deployed outcomes.
