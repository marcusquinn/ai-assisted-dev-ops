# Maintainer review release source manifest

The maintainer explicitly requested full-loop through release. This metadata-only
aggregate includes the verified merged review fixes and all otherwise-unreleased
PRs on the default branch since v3.32.323. It does not authorize unresolved issue
implementations, private-project hold removal, or unsafe recovery deletion.

Reviewed base: `2e46ff2281c5598057cded0d0acf4ecd4d6e3ac5`.

| PR | Verified merge commit |
| --- | --- |
| 31371 | 46b03170356d0ea7553b61aaf8d6dd7c4bf77cb4 |
| 31374 | 6477a99987a70edd69ab7bf65ed5ced6ddbabd07 |
| 31385 | 4b7dd7bebf502bb84ae71bb7a5c4266c257c4e3b |
| 31388 | 07f1b497460dd0d272561b383a1c3e7fbced5e30 |
| 31389 | 062d7b65b22d425e3b1d6bbe613e49f682fef91e |
| 31391 | 6996343dc8362149c9a1c9df7f5faa20abaf50df |
| 31393 | f283f8c9ca57bdb296f08acb5150e94b8c9404da |
| 31395 | cd79c3cdd39021a374e645e23c863d761506e8d1 |
| 31396 | f0b3d58765fc373851fa83083163675397560699 |
| 31397 | 1896442301f0f4adb35972badc25664d90a9e0aa |
| 31399 | 98d62d083dff9c5420bdcbc1418da8282c0a5ed1 |
| 31400 | e2aed0842d97edbc07da8633372d1ad697f3bcd8 |
| 31412 | 673bb029ebb889dcebc6d1ff3400b995c9c5dff2 |
| 31414 | a54ee4da71805fd8eb8cfc1903223219ce3551c1 |
| 31415 | b5d238ffc98ce7ac9bf98f9372db5e41235901e8 |
| 31417 | bb73d45088a477951b5ad06ea3d8e5ca221fa201 |
| 31418 | 2e46ff2281c5598057cded0d0acf4ecd4d6e3ac5 |

PR #31386 preserves the already-published v3.32.323 release and is not a new
implementation source. No open or unmerged PR is included.

## Verification and remaining work

GitHub confirmed each source PR merged to main with the identity above. PR #31417
passed 7 untracked-file tests, 10 changed-mode tests and scoped lint. PR #31418
passed 49 recovery lifecycle tests, scoped lint and independent safety review.
Both passed exact-head required checks and the enforced merge/review gates.

PR #31418 repairs false active-claim diagnostics only. Issue #31407 remains open
for separately verified safe reclamation; this release does not claim to recover
the reported disk backlog. Other review-batch issues may still need fresh signed
authority or implementation, and are not completed by release of these sources.

Release completion requires the canonical helper's signed tag, publication
channels, postflight and exact-tag local deployment evidence. An aggregate merge
or queued publication alone is not a completed release.
