---
description: Generate a local report of token use per AI session, including compacted sessions and MCP observations
agent: Reports
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Generate a local token-use report for AI sessions.

Arguments: `$ARGUMENTS`

## Process

1. Run `~/.aidevops/agents/scripts/report-token-use-helper.sh report $ARGUMENTS`. If the first argument is `efficiency`, use that subcommand instead of `report`; it reads the request ledger without creating report files or changing recorded costs.
2. Return the helper summary directly, including the local `file://` report link.
3. If the user passes `--open`, the helper opens the generated HTML report.

## Usage

```bash
/report-token-use
/report-token-use --limit 50
/report-token-use --session ses_abc123
/report-token-use --since 7d
/report-token-use --runtime opencode
/report-token-use --daily-days 90
/report-token-use --json
/report-token-use --open
/report-token-use efficiency --since 7d
/report-token-use efficiency --since 30d --json
```

## Output

Reports are written under `~/.aidevops/_reports/token-use/<UTC-run-id>/`:

- `report.md` — canonical Markdown review copy.
- `report.json` — machine-readable session rows.
- `report.html` — local browser review file.
- Each report includes a daily usage summary for the last 90 days by default.

## Data contract

Each session row includes session name, runtime, model(s), tokens in, tokens out,
cached-read tokens, raw token total, net token total, compaction count, configured MCPs,
observed MCPs, started time, and finished time.

Net token total is input + output + reasoning + cache-write tokens. Cache reads
are excluded from net totals and retained in raw totals for context-volume review.
OpenCode reports recursively include child sessions via `session.parent_id` so
compacted sessions are counted with their root session.

The `efficiency` scorecard separates model and reasoning effort, uncached/cache/output/reasoning tokens, median/p95 prompt size, routing metadata coverage, and parent-plus-child session families. JSON retains both recorded cost versions and a consistently repriced API-equivalent estimate. Unknown prices and unverified task completion remain explicitly unavailable, not zero. See `reference/context-efficiency.md` for interpretation and context-loading safeguards.
