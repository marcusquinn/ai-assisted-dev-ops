<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# FOSS Contributions

> t1697 — repos.json schema extension + budget controls

## Quick Start

1. Enable globally in `~/.config/aidevops/config.jsonc`:

```jsonc
{ "foss": { "enabled": true, "max_daily_tokens": 200000, "max_concurrent_contributions": 2 } }
```

2. Register a FOSS repo in `~/.config/aidevops/repos.json` (WordPress plugin example):

```json
{
  "path": "/Users/you/Git/wpallstars/some-plugin",
  "slug": "wpallstars/some-plugin",
  "foss": true,
  "app_type": "wordpress-plugin",
  "foss_config": {
    "max_prs_per_week": 1,
    "token_budget_per_issue": 8000,
    "blocklist": false,
    "disclosure": true,
    "labels_filter": ["help wanted", "bug", "needs-patch"]
  },
  "pulse": false,
  "contributed": true,
  "priority": "product",
  "maintainer": "upstream-maintainer"
}
```

3. Check eligibility, then contribute:

```bash
foss-contribution-helper.sh check wpallstars/some-plugin
foss-contribution-helper.sh scan --dry-run
```

## repos.json FOSS Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `foss` | bool | — | Mark repo as a FOSS contribution target. Required. |
| `app_type` | string | `"generic"` | App type: `wordpress-plugin` \| `php-composer` \| `node` \| `python` \| `go` \| `macos-app` \| `browser-extension` \| `cli-tool` \| `electron` \| `cloudron-package` \| `generic` |
| `foss_config.max_prs_per_week` | int | `2` | Max PRs to open per week. |
| `foss_config.token_budget_per_issue` | int | `10000` | Max tokens per contribution attempt. |
| `foss_config.blocklist` | bool | `false` | Set `true` if maintainer asked us to stop. `scan`/`check` refuse all attempts. |
| `foss_config.disclosure` | bool | `true` | Include AI assistance footer in PRs: *"This PR was prepared with AI assistance (aidevops.sh). All changes have been reviewed for correctness."* |
| `foss_config.labels_filter` | array | `["help wanted", "good first issue", "bug"]` | Issue labels to scan for. |

## Global Config (`config.jsonc` `foss` section)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `foss.enabled` | bool | `false` | Master switch. All contributions refused when `false`. |
| `foss.max_daily_tokens` | int | `200000` | Daily token ceiling across all repos. Resets at UTC midnight. |
| `foss.max_concurrent_contributions` | int | `2` | Max simultaneous contribution workers. |

**Env overrides**: `AIDEVOPS_FOSS_ENABLED`, `AIDEVOPS_FOSS_MAX_DAILY_TOKENS`, `AIDEVOPS_FOSS_MAX_CONCURRENT`

## CLI: `foss-contribution-helper.sh`

```text
scan [--dry-run]         Scan FOSS repos for contribution opportunities
check <slug> [tokens]    Check eligibility (exit 0 = eligible, 1 = blocked)
budget                   Show daily token usage vs ceiling
record <slug> <tokens>   Record token usage after a contribution attempt
reset                    Reset daily token counter (testing only)
status                   Show all FOSS repos and their config
```

**`check` gate order** (run before dispatching any worker):

1. `foss.enabled` is `true` globally
2. Repo has `foss: true` in repos.json
3. Repo is not `blocklist: true`
4. Daily token budget has headroom for `token_budget_per_issue`
5. Weekly PR count is below `max_prs_per_week`

```bash
foss-contribution-helper.sh check owner/repo          # default 10000 tokens
foss-contribution-helper.sh check owner/repo 8000     # custom estimate
foss-contribution-helper.sh record owner/repo 7500    # post-contribution accounting
foss-contribution-helper.sh budget                    # daily usage summary
```

## Contribution Workflow

```text
1. foss-contribution-helper.sh check <slug>            ← gate: eligible?
2. Dispatch contribution worker                        ← /full-loop or headless
3. Worker implements fix, opens PR                     ← disclosure footer if disclosure: true
4. foss-contribution-helper.sh record <slug> <tokens>  ← accounting
```

## State File

Budget state: `~/.aidevops/cache/foss-contribution-state.json`. Daily counter resets at UTC midnight. Use `reset` subcommand to clear manually (testing only).

## Related

- `contribution-watch-helper.sh` — monitors external issues/PRs for reply (read-only, no contribution dispatch)
- `reference/external-repo-submissions.md` — etiquette for external repo submissions
- `reference/services.md` — Contribution Watch service docs
