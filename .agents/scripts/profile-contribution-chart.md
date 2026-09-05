<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Profile Total Contributions chart

`profile-readme-helper.sh update` generates `assets/contributions/total-light.svg`,
`total-dark.svg`, and `total.json` in its isolated profile publication worktree.
The README and these three explicit asset paths are published in one commit.
The existing hourly profile scheduler attempts a refresh once per UTC day; a
successful current-date asset set avoids further API calls that day. No new timer
or third-party image service is required.

## Data definition

The chart uses GitHub's canonical `contributionCalendar.totalContributions`,
covering all contribution types rather than reconstructing a total from
viewer-dependent public/restricted buckets. Windows are disjoint calendar months from account creation through
the prior UTC day's final second. The current month is partial; today is excluded.
Only month totals and their running cumulative sum are published. No repository
identities, event details, credentials, or separate private contribution buckets
are written to assets.

Queries use the authenticated `gh` CLI, with at most 12 monthly aliases per
request and a bounded 400-month history. A typical 13-year history needs about
14 requests per daily refresh, including identity lookup. Missing months, null
counts, API errors, and unavailable credentials retain the last successful chart.
Rendering and README migration finish before writing. Local I/O errors abort the
publisher so a partial asset set is not pushed. Commit/push failures do not mark
the remote profile as refreshed; the next isolated run starts from remote state.

## Verification link and freshness

The chart and visible verification link open the user's `commit-history.com`
Total view. That independent service may have a different refresh cutoff, so the
README explains why totals can differ. Compatible HTML renderers receive
`target="_blank" rel="noopener noreferrer"`; GitHub's Markdown API strips these
attributes. GitHub users can Ctrl/Cmd-click the link to open a new tab.

Each SVG includes an updated date and data-through date. GitHub's image cache can
delay the display after a new commit. If the scheduler host is asleep/offline,
the next successful scheduled invocation catches up; this is not a hosted uptime
guarantee.

## Verification commands

```bash
python3 .agents/scripts/tests/test-profile-contribution-chart.py
bash .agents/scripts/tests/test-profile-readme-boundary.sh
bash .agents/scripts/tests/test-profile-readme-contributions-fail-closed.sh
shellcheck .agents/scripts/profile-readme-helper.sh
bash .agents/scripts/profile-readme-helper.sh update --dry-run
```
