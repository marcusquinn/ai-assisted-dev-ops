# Quota health release source manifest

The user explicitly authorizes release of the Pulse productivity fixes and all
otherwise-unreleased merged sources. This metadata-only aggregate preserves the
source set after a TODO synchronization merged during the signed release queue.
It changes no implementation, permission, quota, or publication policy.

| PR | Verified merge commit |
| --- | --- |
| 31365 | 462a1d1672d3f6f83eb80063add4aa38813fbfe0 |
| 31368 | 5192241aea9bf6226c46f42f6f760fbf862be99a |
| 31362 | 464e5b8011e42bdb6951e32380ac1c7b0ed1ea4c |

The original v3.32.321 source is PR 31368. Its signed tree differs from the
protected main tree by the task-status update from PR 31362. PR 31365 also merged
after v3.32.320 and is included explicitly. Release provenance PR 31373 preserves
the original signed version commit; it is not an additional implementation source.

Verification: all three source PRs have observed merge identities; PR 31368 has
terminal-success required checks, a passing review gate, ShellCheck, the existing
budget suite and 19 producer/consumer cycle-state assertions. The aggregate is
reviewed as metadata only. Publication requires canonical transactional aggregate
recovery, signed-tag verification, successful package channels, postflight and
exact-tag local deployment. Neither this merge nor a queued tag proves completion.
