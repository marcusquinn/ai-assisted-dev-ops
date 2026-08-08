#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# core-routines.sh — Core routine definitions for seeding into routines repos.
# Sourced by init-routines-helper.sh. Do not execute directly.
#
# Each describe_* function accepts $1 = OS name (darwin|linux) and outputs
# OS-appropriate markdown to stdout. The TODO entry format and metadata
# are returned by get_core_routine_entries().

# ---------------------------------------------------------------------------
# get_core_routine_entries
# Outputs one line per core routine in pipe-delimited format:
#   id|enabled|title|schedule|estimate|script|type|timezone (optional)
# ---------------------------------------------------------------------------
get_core_routine_entries() {
	cat <<'ENTRIES'
r901|x|Supervisor pulse — dispatch tasks across repos|repeat:persistent|~1m|scripts/pulse-wrapper.sh|script
r902|x|Auto-update — check for framework updates|repeat:cron(*/10 * * * *)|~30s|bin/aidevops-auto-update|script
r903|x|Process guard — kill runaway processes|repeat:cron(*/1 * * * *)|~5s|scripts/process-guard-helper.sh kill-runaways|script
r904|x|Worker watchdog — monitor headless workers|repeat:cron(*/2 * * * *)|~10s|scripts/worker-watchdog.sh --check|script
r905|x|Memory pressure monitor|repeat:cron(*/1 * * * *)|~5s|scripts/memory-pressure-monitor.sh|script
r906|x|Repo sync — pull latest across repos|repeat:daily(@19:00)|~5m|bin/aidevops-repo-sync|script
r907|x|Contribution watch — monitor FOSS activity|repeat:cron(0 * * * *)|~30s|scripts/contribution-watch-helper.sh scan|script
r908|x|Profile README update|repeat:cron(0 * * * *)|~30s|scripts/profile-readme-helper.sh update|script
r909|x|Screen time snapshot|repeat:cron(0 */6 * * *)|~10s|scripts/screen-time-helper.sh snapshot|script
r910|x|Skills sync — refresh agent skills|repeat:cron(*/5 * * * *)|~15s|bin/aidevops-skills-sync|script
r911|x|OAuth token refresh|repeat:cron(*/30 * * * *)|~10s|scripts/oauth-pool-helper.sh refresh|script
r912| |Dashboard server|repeat:persistent|~0s|server/index.ts|service
r913|x|Weekly opencode DB maintenance|repeat:weekly(sun@04:00)|~2m|scripts/opencode-db-maintenance-helper.sh auto|script
r914|x|Repo aidevops health — bump stale .aidevops.json, detect drift|repeat:daily(@03:30)|~2m|scripts/repo-aidevops-health-helper.sh run|script
r915|x|Pulse check — worker utilisation and self-improvement recommendations|repeat:daily(@06:20)|~5m|scripts/pulse-check-helper.sh apply|script
r916|x|Cloudron packages — check upstream releases|repeat:daily(@01:30)|~2m|scripts/cloudron-package-monitor-helper.sh upstream --apply|script|UTC
r917|x|Cloudron packages — audit compatibility|repeat:weekly(sun@07:40)|~5m|scripts/cloudron-package-monitor-helper.sh compatibility --apply|script
ENTRIES
	return 0
}

# ---------------------------------------------------------------------------
# _is_darwin_os <os>
# Returns 0 when the routine description target is macOS.
# ---------------------------------------------------------------------------
_is_darwin_os() {
	local os="$1"
	if [[ "$os" == "darwin" ]]; then
		return 0
	fi
	return 1
}

# ---------------------------------------------------------------------------
# _platform_footnote <os>
# Outputs a cross-platform reference footnote for the other OS.
# ---------------------------------------------------------------------------
_platform_footnote() {
	local os="$1"
	if _is_darwin_os "$os"; then
		cat <<'FOOT'

---

> **Cross-platform note (Linux):** On Linux, this routine runs as a systemd
> timer/service unit instead of a launchd plist. Use `systemctl --user status`
> and `journalctl --user -u` for diagnostics. Timer units are in
> `~/.config/systemd/user/`. See `setup.sh` for the systemd installation path.
FOOT
	else
		cat <<'FOOT'

---

> **Cross-platform note (macOS):** On macOS, this routine runs as a launchd
> plist instead of a systemd unit. Use `launchctl list` and check
> `~/Library/LaunchAgents/` for diagnostics. Plist names follow the
> `sh.aidevops.*` or `com.aidevops.*` convention.
FOOT
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _scheduler_row <os> <interval_sec> <plist_label> <systemd_unit>
# Outputs the Scheduler row for the Schedule table.
# ---------------------------------------------------------------------------
_scheduler_row() {
	local os="$1"
	local interval_sec="$2"
	local plist_label="$3"
	local systemd_unit="$4"
	if _is_darwin_os "$os"; then
		echo "| Scheduler | launchd \`${plist_label}\` (StartInterval: ${interval_sec}) |"
	else
		echo "| Scheduler | systemd \`${systemd_unit}.timer\` (OnUnitActiveSec=${interval_sec}s) |"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _scheduler_row_calendar <os> <calendar_desc> <plist_label> <systemd_unit>
# Outputs the Scheduler row for calendar-based schedules.
# ---------------------------------------------------------------------------
_scheduler_row_calendar() {
	local os="$1"
	local calendar_desc="$2"
	local plist_label="$3"
	local systemd_unit="$4"
	if _is_darwin_os "$os"; then
		echo "| Scheduler | launchd \`${plist_label}\` (${calendar_desc}) |"
	else
		echo "| Scheduler | systemd \`${systemd_unit}.timer\` (OnCalendar=${calendar_desc}) |"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _scheduler_row_pulse <repeat_expression>
# Outputs the scheduler row for routines evaluated by the supervisor Pulse.
# ---------------------------------------------------------------------------
_scheduler_row_pulse() {
	local repeat_expression="$1"
	echo "| Scheduler | Supervisor Pulse evaluates version-controlled \`${repeat_expression}\` |"
	return 0
}

# ---------------------------------------------------------------------------
# _pulse_diag_commands <os>
# Outputs diagnostics for the real shared Pulse scheduler and routine state.
# ---------------------------------------------------------------------------
_pulse_diag_commands() {
	local os="$1"
	if _is_darwin_os "$os"; then
		cat <<'EOF'
- `launchctl print "gui/${UID}/com.aidevops.aidevops-supervisor-pulse"` — shared Pulse service health
EOF
	else
		cat <<'EOF'
- `systemctl --user status sh.aidevops.pulse` — shared Pulse service health
EOF
	fi
	cat <<'EOF'
- `jq '.r916, .r917' ~/.aidevops/.agent-workspace/pulse/routine-state.json` — last-run state
- `aidevops status` — framework and supervisor overview
EOF
	return 0
}

# ---------------------------------------------------------------------------
# _diag_commands <os> <plist_label> <systemd_unit>
# Outputs OS-specific diagnostic commands.
# ---------------------------------------------------------------------------
_diag_commands() {
	local os="$1"
	local plist_label="$2"
	local systemd_unit="$3"
	if _is_darwin_os "$os"; then
		cat <<EOF
- \`launchctl list | grep ${plist_label##*.}\` — PID and exit status
- \`log show --predicate 'subsystem == "com.apple.launchd"' --last 5m | grep ${plist_label##*.}\` — recent launches
EOF
	else
		cat <<EOF
- \`systemctl --user status ${systemd_unit}\` — unit status and recent logs
- \`journalctl --user -u ${systemd_unit} --since '5 min ago'\` — recent output
EOF
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Core routine descriptions — one function per routine.
# Each accepts $1 = OS (darwin|linux) and outputs markdown to stdout.
# ---------------------------------------------------------------------------

describe_r901() {
	local os="${1:-darwin}"
	cat <<EOF
# r901: Supervisor pulse

## Overview

The heartbeat of aidevops autonomous operations. Every 2 minutes, the pulse
scans all \`pulse: true\` repos in \`repos.json\`, evaluates open tasks and issues,
and dispatches headless workers to implement them.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Every 2 minutes |
| Type | script |
| Expected duration | ~1 minute |
| Script | \`scripts/pulse-wrapper.sh\` |
$(_scheduler_row "$os" 120 "com.aidevops.aidevops-supervisor-pulse" "sh.aidevops.supervisor-pulse")

## What it does

1. Reads \`repos.json\` for pulse-enabled repos (respects \`pulse_hours\`, \`pulse_expires\`)
2. For each repo: checks open GitHub issues, TODO.md tasks, and enabled routines
3. Applies tier routing (\`tier:simple\` → Haiku, \`tier:standard\` → Sonnet, \`tier:thinking\` → Opus)
4. Dispatches headless workers via \`headless-runtime-helper.sh\`
5. Enforces concurrency limits (max workers per repo, global cap)
6. Evaluates and dispatches due routines from \`## Routines\` sections

## What to check

- \`~/.aidevops/.agent-workspace/cron/pulse/\` — execution logs
$(_diag_commands "$os" "com.aidevops.aidevops-supervisor-pulse" "sh.aidevops.supervisor-pulse")
- \`gh pr list\` across pulse repos — PRs being created by workers
- \`routine-log-helper.sh status\` — last run metrics
$(_platform_footnote "$os")
EOF
	return 0
}

describe_r902() {
	local os="${1:-darwin}"
	cat <<EOF
# r902: Auto-update

## Overview

Keeps the aidevops framework current by checking for new versions every
10 minutes. When an update is available, runs \`setup.sh --non-interactive\`
to deploy new agents, scripts, and configurations without interrupting
active sessions.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Every 10 minutes |
| Type | script |
| Expected duration | ~30 seconds (check only), ~2 minutes (when updating) |
| Script | \`bin/aidevops-auto-update\` (wraps \`aidevops auto-update check\`) |
$(_scheduler_row "$os" 600 "com.aidevops.aidevops-auto-update" "sh.aidevops.auto-update")

## What it does

1. Runs \`git fetch\` on the aidevops repo
2. Compares local HEAD with remote HEAD
3. If behind: pulls changes and runs \`setup.sh --non-interactive\`
4. Deploys updated agents, scripts, configs to \`~/.aidevops/agents/\`
5. Reports update status in the session greeting cache

## What to check

- Session greeting shows current version
- \`~/.aidevops/agents/VERSION\` — deployed version
$(_diag_commands "$os" "com.aidevops.aidevops-auto-update" "sh.aidevops.auto-update")
- \`git -C ~/Git/aidevops log --oneline -3\` — recent updates
$(_platform_footnote "$os")
EOF
	return 0
}

describe_r903() {
	local os="${1:-darwin}"
	cat <<EOF
# r903: Process guard

## Overview

Prevents runaway AI processes from consuming excessive resources. Checks
every 30 seconds for processes that exceed time or memory limits and
terminates them gracefully.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Every 30 seconds |
| Type | script |
| Expected duration | ~5 seconds |
| Script | \`scripts/process-guard-helper.sh kill-runaways\` |
$(_scheduler_row "$os" 30 "sh.aidevops.process-guard" "sh.aidevops.process-guard")

## What it does

1. Scans for AI runtime processes (opencode, shellcheck, node workers) using \`pgrep\`
2. Skips TTY-attached processes (interactive user sessions are never killed)
3. Checks wall-clock runtime against configurable limits per process type
4. Checks RSS memory usage against configurable thresholds
5. Sends SIGTERM to processes exceeding limits (graceful shutdown)
6. Escalates to SIGKILL after 1 second if process does not exit
7. Reaps orphan shellcheck processes (ppid=1, alive >120s)
8. Logs kills to \`~/.aidevops/logs/process-guard.log\`

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| \`CHILD_RSS_LIMIT_KB\` | 8388608 (8GB) | Max RSS per child process |
| \`CHILD_RUNTIME_LIMIT\` | 7200 (2h) | Max runtime in seconds |
| \`SHELLCHECK_RSS_LIMIT_KB\` | 524288 (512MB) | ShellCheck-specific RSS limit |
| \`SHELLCHECK_RUNTIME_LIMIT\` | 120 (2min) | ShellCheck-specific runtime limit |
| \`SESSION_COUNT_WARN\` | 5 | Warn when interactive session count exceeds this |

## What to check

- \`~/.aidevops/logs/process-guard.log\` — kill log (stdout + stderr)
$(_diag_commands "$os" "sh.aidevops.process-guard" "sh.aidevops.process-guard")
- \`process-guard-helper.sh scan\` — one-shot scan showing monitored processes
- \`process-guard-helper.sh sessions\` — count of interactive sessions
$(_platform_footnote "$os")
EOF
	return 0
}

describe_r904() {
	local os="${1:-darwin}"
	cat <<EOF
# r904: Worker watchdog

## Overview

Monitors headless worker sessions dispatched by the pulse. Detects stalled,
crashed, or zombie workers and takes corrective action. Ensures workers
don't hold worktree locks indefinitely.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Every 2 minutes |
| Type | script |
| Expected duration | ~10 seconds |
| Script | \`scripts/worker-watchdog.sh --check\` |
$(_scheduler_row "$os" 120 "sh.aidevops.worker-watchdog" "sh.aidevops.worker-watchdog")

## What it does

1. Reads active worker state from \`~/.aidevops/.agent-workspace/tmp/\`
2. Checks if worker PIDs are still alive
3. Detects stalled workers (no output for configurable timeout)
4. Cleans up orphaned worktree locks
5. Posts kill/timeout comments on GitHub issues for failed workers
6. Updates dispatch state so the pulse can retry

## Failure modes detected

| Mode | Signal | Action |
|------|--------|--------|
| CPU idle | Tree CPU < threshold for idle timeout (default 5 min) | Kill — worker stuck in file-watcher |
| Progress stall | No log growth for progress timeout (default 10 min) | Kill — worker stuck on API or rate-limited |
| Zero-commit thrash | Running >1h with >120 messages but 0 commits | Kill + \`status:blocked\` |
| Runtime ceiling | Elapsed > max runtime (default 3h) | Kill — prevents infinite loops |
| Provider backoff | Provider hit auth_error or rate-limit | Kill immediately |

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| \`WORKER_IDLE_TIMEOUT\` | 300 | Seconds of low CPU before idle kill |
| \`WORKER_IDLE_CPU_THRESHOLD\` | 5 | CPU% below this = idle |
| \`WORKER_PROGRESS_TIMEOUT\` | 600 | Seconds without log growth = stuck |
| \`WORKER_THRASH_ELAPSED_THRESHOLD\` | 3600 | Min runtime before zero-commit thrash check |
| \`WORKER_THRASH_MESSAGE_THRESHOLD\` | 120 | Min messages for thrash check |
| \`WORKER_MAX_RUNTIME\` | 10800 | Hard ceiling in seconds (3h) |
| \`WORKER_DRY_RUN\` | false | Log but don't kill (for testing) |

## What to check

- \`~/.aidevops/.agent-workspace/tmp/session-*\` — active worker sessions
$(_diag_commands "$os" "sh.aidevops.worker-watchdog" "sh.aidevops.worker-watchdog")
- \`~/.aidevops/logs/worker-watchdog.log\` — watchdog action log
- GitHub issue comments — kill notifications from watchdog
- \`routine-log-helper.sh status\` — watchdog run history
$(_platform_footnote "$os")
EOF
	return 0
}

describe_r905() {
	local os="${1:-darwin}"
	local mem_check_cmd mem_monitor
	if _is_darwin_os "$os"; then
		mem_check_cmd="\`memory_pressure\` command — current system pressure"
		mem_monitor="Activity Monitor → Memory tab — pressure graph"
	else
		mem_check_cmd="\`free -h\` — current memory usage"
		mem_monitor="\`htop\` or \`cat /proc/meminfo\` — detailed memory stats"
	fi
	cat <<EOF
# r905: Memory pressure monitor

## Overview

Tracks system memory pressure to prevent OOM conditions during heavy
AI workloads. Logs memory snapshots and can trigger worker throttling
when pressure is high.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Every 60 seconds |
| Type | script |
| Expected duration | ~5 seconds |
| Script | \`scripts/memory-pressure-monitor.sh\` |
$(_scheduler_row "$os" 60 "sh.aidevops.memory-pressure-monitor" "sh.aidevops.memory-pressure-monitor")

## What it does

1. Reads system memory pressure level (nominal/warn/critical)
2. Logs memory statistics (free, active, wired/cached, compressed/swap)
3. At warn level: reduces pulse concurrency limits
4. At critical level: pauses new worker dispatches
5. Writes pressure state for other routines to read

## What to check

- ${mem_check_cmd}
- ${mem_monitor}
$(_diag_commands "$os" "sh.aidevops.memory-pressure-monitor" "sh.aidevops.memory-pressure-monitor")
- \`~/.aidevops/.agent-workspace/cron/memory-pressure/\` — pressure logs
$(_platform_footnote "$os")
EOF
	return 0
}

describe_r906() {
	local os="${1:-darwin}"
	cat <<EOF
# r906: Repo sync

## Overview

Keeps all registered repos up to date by pulling latest changes daily.
Runs at 19:00 local time to sync before overnight pulse operations.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Daily at 19:00 |
| Type | script |
| Expected duration | ~5 minutes (depends on repo count) |
| Script | \`bin/aidevops-repo-sync\` (wraps \`aidevops repo-sync check\`) |
$(_scheduler_row_calendar "$os" "StartCalendarInterval: Hour=19, Minute=0" "sh.aidevops.repo-sync" "sh.aidevops.repo-sync")

## What it does

1. Reads all repos from \`~/.config/aidevops/repos.json\`
2. Reads each default remote branch with \`git ls-remote\`
3. Reports repos that differ from their remote default branch
4. Leaves canonical HEAD, index, refs, tracked and untracked files unchanged
5. Skips repos with uncommitted changes (safety)

## What to check

$(_diag_commands "$os" "sh.aidevops.repo-sync" "sh.aidevops.repo-sync")
- \`git -C <repo> status --short --branch\` — local state and reported drift
- \`~/.config/aidevops/repos.json\` — registered repos
- Repos with \`local_only: true\` are still synced locally (no fetch)
$(_platform_footnote "$os")
EOF
	return 0
}

describe_r907() {
	local os="${1:-darwin}"
	cat <<EOF
# r907: Contribution watch

## Overview

Monitors external FOSS repos where we've contributed (issues, PRs, comments).
Detects new activity that needs a reply — review requests, comment threads,
merge notifications.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Every hour |
| Type | script |
| Expected duration | ~30 seconds |
| Script | \`scripts/contribution-watch-helper.sh scan\` |
$(_scheduler_row "$os" 3600 "sh.aidevops.contribution-watch" "sh.aidevops.contribution-watch")

## What it does

1. Reads repos with \`contributed: true\` from \`repos.json\`
2. Checks GitHub notifications for those repos
3. Filters for actionable items (review requests, mentions, replies)
4. Excludes managed \`pulse: true\` repos (handled by the pulse)
5. Reports items needing attention

## What to check

- \`gh notification list\` — pending notifications
$(_diag_commands "$os" "sh.aidevops.contribution-watch" "sh.aidevops.contribution-watch")
- Repos with \`contributed: true\` in \`repos.json\`
- \`~/.aidevops/.agent-workspace/cron/contribution-watch/\` — scan logs
$(_platform_footnote "$os")
EOF
	return 0
}

describe_r908() {
	local os="${1:-darwin}"
	cat <<EOF
# r908: Profile README update

## Overview

Keeps the GitHub profile README current with recent activity, stats,
and project highlights. Runs hourly to reflect latest contributions.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Every hour |
| Type | script |
| Expected duration | ~30 seconds |
| Script | \`scripts/profile-readme-helper.sh update\` |
$(_scheduler_row "$os" 3600 "sh.aidevops.profile-readme-update" "sh.aidevops.profile-readme-update")

## What it does

1. Collects recent commit activity across repos
2. Gathers GitHub stats (contributions, streaks, languages)
3. Updates the profile README with current data
4. Commits and pushes if content changed

## What to check

- GitHub profile page — README content
$(_diag_commands "$os" "sh.aidevops.profile-readme-update" "sh.aidevops.profile-readme-update")
- \`git -C ~/Git/<username> log --oneline -3\` — recent README updates
$(_platform_footnote "$os")
EOF
	return 0
}

describe_r909() {
	local os="${1:-darwin}"
	local screen_time_check
	if _is_darwin_os "$os"; then
		screen_time_check="System Settings → Screen Time — raw data"
	else
		screen_time_check="\`~/.aidevops/.agent-workspace/cron/screen-time/\` — snapshot data (no native Screen Time on Linux)"
	fi
	cat <<EOF
# r909: Screen time snapshot

## Overview

Captures periodic screen time data for productivity tracking and
session analytics. Runs every 6 hours.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Every 6 hours |
| Type | script |
| Expected duration | ~10 seconds |
| Script | \`scripts/screen-time-helper.sh snapshot\` |
$(_scheduler_row "$os" 21600 "sh.aidevops.screen-time-snapshot" "sh.aidevops.screen-time-snapshot")

## What it does

1. Captures active app usage durations (macOS Screen Time API or process sampling)
2. Logs development tool usage (IDE, terminal, browser)
3. Stores snapshots for trend analysis
4. Data stays local — never uploaded

## What to check

- ${screen_time_check}
$(_diag_commands "$os" "sh.aidevops.screen-time-snapshot" "sh.aidevops.screen-time-snapshot")
- \`~/.aidevops/.agent-workspace/cron/screen-time/\` — snapshot logs
$(_platform_footnote "$os")
EOF
	return 0
}

describe_r910() {
	local os="${1:-darwin}"
	cat <<EOF
# r910: Skills sync

## Overview

Refreshes agent skill definitions every 5 minutes. Ensures newly added
or updated skills are available to all runtimes without requiring a
full setup run.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Every 5 minutes |
| Type | script |
| Expected duration | ~15 seconds |
| Script | \`bin/aidevops-skills-sync\` (wraps \`aidevops skill generate\`) |
$(_scheduler_row "$os" 300 "sh.aidevops.skills-sync" "sh.aidevops.skills-sync")

## What it does

1. Checks for new or modified skill definitions in \`~/.aidevops/agents/\`
2. Regenerates SKILL.md files if source agents changed
3. Updates skill symlinks for runtime discovery
4. Lightweight — only processes changed files

## What to check

$(_diag_commands "$os" "sh.aidevops.skills-sync" "sh.aidevops.skills-sync")
- \`~/.config/Claude/skills/\` — skill symlinks
- \`ls ~/.aidevops/agents/*/SKILL.md\` — generated skill files
$(_platform_footnote "$os")
EOF
	return 0
}

describe_r911() {
	local os="${1:-darwin}"
	cat <<EOF
# r911: OAuth token refresh

## Overview

Refreshes OAuth tokens for AI provider accounts (Anthropic, OpenAI) to
maintain authenticated sessions. Runs every 30 minutes to stay ahead
of token expiry.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Every 30 minutes |
| Type | script |
| Expected duration | ~10 seconds |
| Script | \`scripts/oauth-pool-helper.sh refresh\` |
$(_scheduler_row "$os" 1800 "sh.aidevops.token-refresh" "sh.aidevops.token-refresh")

## What it does

1. Iterates through configured provider accounts
2. Checks token expiry timestamps
3. Refreshes tokens that are within the renewal window
4. Rotates to next account in pool if refresh fails
5. Updates credential store with new tokens

## What to check

- \`oauth-pool-helper.sh status\` — account pool health
$(_diag_commands "$os" "sh.aidevops.token-refresh" "sh.aidevops.token-refresh")
- \`~/.aidevops/.agent-workspace/cron/token-refresh/\` — refresh logs
$(_platform_footnote "$os")
EOF
	return 0
}

describe_r912() {
	local os="${1:-darwin}"
	local status_cmd
	if _is_darwin_os "$os"; then
		status_cmd="\`launchctl list | grep dashboard\` — process status"
	else
		status_cmd="\`systemctl --user status sh.aidevops.dashboard\` — service status"
	fi
	cat <<EOF
# r912: Dashboard server

## Overview

Persistent web dashboard providing a real-time view of aidevops operations —
repo health, worker status, routine metrics, and task progress.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Persistent (always running) |
| Type | service |
| Expected duration | Continuous |
| Script | \`server/index.ts\` |
$(_scheduler_row_calendar "$os" "KeepAlive: true" "com.aidevops.dashboard" "sh.aidevops.dashboard")

## What it does

1. Serves a web UI on localhost
2. Aggregates data from repos.json, routine state, worker sessions
3. Displays real-time worker activity and pulse dispatch status
4. Shows routine execution history and health metrics
5. Provides quick links to GitHub issues and PRs

## What to check

- Browser: \`http://localhost:<port>\` — dashboard UI
- ${status_cmd}
$(_platform_footnote "$os")
EOF
	return 0
}

describe_r913() {
	local os="${1:-darwin}"
	cat <<EOF
# r913: Weekly opencode DB maintenance

## Overview

Periodic SQLite maintenance for the opencode session database
(\`~/.local/share/opencode/opencode.db\`) to reduce "database is locked"
errors under concurrent session load.

opencode stores session state in SQLite with WAL journaling. Each process
opens multiple DB connections (read-pool + writer), so even a single TUI
already creates multi-writer contention at the SQLite layer. As the DB
grows (1 GB+ is common for active users), individual write transactions
exceed the compiled busy_timeout (5s) and surface as session-halting
\`SQLITE_BUSY\` errors.

This routine cannot fix the architectural problem — that requires upstream
changes in opencode (tracked in anomalyco/opencode #21215, #20935, #21579).
It DOES minimise lock-hold time by keeping the DB compact and the WAL
truncated.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Weekly, Sunday 04:00 local |
| Type | script |
| Expected duration | ~2 minutes (when VACUUM runs) |
| Script | \`scripts/opencode-db-maintenance-helper.sh auto\` |
$(_scheduler_row_calendar "$os" "StartCalendarInterval: Weekday=0, Hour=4, Minute=0" "sh.aidevops.opencode-db-maintenance" "sh.aidevops.opencode-db-maintenance")

## What it does

1. Checks if opencode is installed (\`~/.local/share/opencode/opencode.db\` exists)
   — silent no-op if not, so users who don't use opencode see no errors
2. Refuses to run if any opencode processes are active (safety)
3. Runs \`PRAGMA wal_checkpoint(TRUNCATE)\` — folds pending writes into main DB
4. Runs \`PRAGMA optimize\` — refreshes query planner statistics
5. Runs \`VACUUM\` if free-page fraction >10% or DB larger than 500 MB
6. Records outcome in state file for throttling next run

## Safety

- **Never runs with active opencode processes** — maintenance requires
  exclusive DB access. If the Sunday 04:00 slot has live sessions, the
  run is skipped with a log entry.
- **Throttled** — \`auto\` mode skips if the last successful run was less
  than 6 days ago (\`AUTO_MIN_SECONDS_BETWEEN\`).
- **No data loss** — VACUUM rewrites the DB file but preserves all rows.
  Failure mid-VACUUM is recovered by SQLite's journal.

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| \`VACUUM_FREELIST_THRESHOLD\` | 0.10 | Fraction of free pages triggering VACUUM |
| \`FORCE_VACUUM_SIZE_MB\` | 500 | Always VACUUM above this size (MB) |
| \`AUTO_MIN_SECONDS_BETWEEN\` | 518400 | Seconds between auto runs (6 days) |

## Manual invocation

\`\`\`bash
# See current DB stats without mutating:
opencode-db-maintenance-helper.sh report

# Dry check — is maintenance safe to run now?
opencode-db-maintenance-helper.sh check

# Run now (only if no opencode sessions active):
opencode-db-maintenance-helper.sh maintain

# Run now even with active sessions (risks SQLITE_BUSY in those sessions):
opencode-db-maintenance-helper.sh maintain --force
\`\`\`

## What to check

- \`~/.aidevops/.agent-workspace/work/opencode-maintenance/last-run.json\` —
  last run outcome, duration, bytes reclaimed
- \`~/.aidevops/.agent-workspace/work/opencode-maintenance/maintenance.log\` —
  run history
$(_diag_commands "$os" "sh.aidevops.opencode-db-maintenance" "sh.aidevops.opencode-db-maintenance")
- \`opencode-db-maintenance-helper.sh report\` — current DB state

## Related upstream issues

- anomalyco/opencode #21215 — SQLITE_BUSY on concurrent sessions
- anomalyco/opencode #21000 — Bash tool hangs on massive output, locks DB
- anomalyco/opencode #20935 — Per-session-tree sharding (architectural fix)
- anomalyco/opencode #21579 — Harden per-session SQLite sharding (PR)
$(_platform_footnote "$os")
EOF
	return 0
}

describe_r914() {
	local os="${1:-darwin}"
	cat <<EOF
# r914: Repo aidevops health keeper

## Overview

Daily drift-keeper for the \`~/.config/aidevops/repos.json\` registry.

Three drift classes are silent by default — they only surface when someone
audits by hand. r914 closes that gap:

1. **Stale-version bump** (autonomous, safe). Repos whose \`.aidevops.json\`
   is older than the currently-installed framework get a one-commit version
   bump on their default branch.
2. **Missing-folder detection** (human-gated). Registry entries pointing at
   deleted folders are surfaced as \`needs-maintainer-review\` issues for
   re-clone / removal / archival.
3. **No-init detection** (human-gated). Git repos in \`git_parent_dirs[]\`
   that are not in \`initialized_repos[]\` and have no \`.aidevops.json\`
   or \`.aidevops-skip\` marker are surfaced the same way.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Daily at 03:30 |
| Type | script |
| Expected duration | ~2 minutes (depends on repo count) |
| Script | \`scripts/repo-aidevops-health-helper.sh run\` |
$(_scheduler_row_calendar "$os" "StartCalendarInterval: Hour=3, Minute=30" "sh.aidevops.repo-aidevops-health" "sh.aidevops.repo-aidevops-health")

## What it does

1. Reads \`~/.config/aidevops/repos.json\` and the current framework \`VERSION\`.
2. For each \`initialized_repos[]\` entry whose path exists and \`.aidevops.json\`
   is older than the installed framework: rewrite with \`jq\`, commit on the
   default branch with message \`chore: bump .aidevops.json to v<new> (r914)\`,
   push (skipped when \`local_only: true\`).
3. For each entry whose path is missing and not \`archived: true\`: flag for
   human triage (MVP logs only; issue filing in follow-up).
4. For each untracked git repo in \`git_parent_dirs[]\` without a
   \`.aidevops-skip\` marker or \`.aidevops.json\`: flag for human triage.

## Safety rails

- Skips any repo with uncommitted changes (\`git status --porcelain\`).
- Skips repos not on their default branch (no branch-switching).
- Atomic \`jq\` rewrite with \`mktemp\` + \`mv\` — never edits JSON with \`sed\`.
- Dry-run mode via \`AIDEVOPS_REPO_HEALTH_DRY_RUN=1\` (detect-only).
- Disable via \`aidevops config set orchestration.repo_aidevops_health false\`
  or \`AIDEVOPS_REPO_HEALTH=false\` in the environment.

## What to check

$(_diag_commands "$os" "sh.aidevops.repo-aidevops-health" "sh.aidevops.repo-aidevops-health")
- \`~/.aidevops/logs/repo-aidevops-health.log\` — per-run detections and commits.
- \`~/.aidevops/cache/repo-aidevops-health-state.json\` — last run summary.
- \`.aidevops/agents/VERSION\` — current framework version (bump target).
- Drift issues on \`marcusquinn/aidevops\` labelled \`repos-drift\` or \`no-init\`.
$(_platform_footnote "$os")
EOF
	return 0
}

describe_r915() {
	local os="${1:-}"
	if [[ -z "$os" ]]; then
		os="$(uname -s | tr '[:upper:]' '[:lower:]')"
	fi
	cat <<EOF
# r915: Pulse check

## Overview

Daily bounded diagnostics for pulse and worker productivity. It compares
current worker capacity, recent terminal worker metrics, provider/API budget,
and repos.json auto-dispatch queue depth, then files deduplicated
self-improvement issues only for high-confidence productivity gaps.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Daily at 06:20 |
| Type | script |
| Expected duration | ~5 minutes |
| Script | \`scripts/pulse-check-helper.sh apply\` |
$(_scheduler_row_calendar "$os" "StartCalendarInterval: Hour=6, Minute=20" "sh.aidevops.pulse-check" "sh.aidevops.pulse-check")

## What it does

1. Runs \`pulse-current-state-helper.sh --window 15m --json\` for live
   dispatch, worker launch, guardrail, and API-budget evidence.
2. Runs \`worker-activity-helper.sh summary --since 1h/24h --json --no-pr-check\`
   for canonical recent and historical worker outcomes.
3. Scans pulse-enabled repos in \`repos.json\` for open \`auto-dispatch\`
   issues using aggregate counts only; repo names, local paths, and issue titles
   are intentionally omitted from output and filed issues.
4. Files or reuses self-improvement issues marked with
   \`<!-- aidevops:generator=pulse-check finding=... -->\` when a finding is
   high-confidence and worker-dispatchable.

## Safety rails

- Uses aggregate queue metrics to preserve private repo/path confidentiality.
- Uses wrapper-created issues with \`--body-file\` and dedupe markers.
- Does not increase concurrency by itself; recommendations must cite evidence.
- JSON output removes raw worker examples that may contain repo slugs or paths.

## What to check

$(_diag_commands "$os" "sh.aidevops.pulse-check" "sh.aidevops.pulse-check")
- \`pulse-check-helper.sh report\` — ad-hoc interactive report.
- \`pulse-check-helper.sh json\` — machine-readable evidence.
- Open issues carrying \`source:pulse-check\` — deduplicated improvements.
$(_platform_footnote "$os")
EOF
	return 0
}

describe_r916() {
	local os="${1:-}"
	[[ -n "$os" ]] || os="$(uname -s | tr '[:upper:]' '[:lower:]')"
	cat <<EOF
# r916: Cloudron package upstream releases

## Overview

Daily read-only comparison of registered Cloudron package upstream versions at 01:30 UTC.
New releases become deduplicated, worker-ready issues in the package repository.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Daily at 01:30 UTC |
| Type | script |
| Expected duration | ~2 minutes |
| Script | \`scripts/cloudron-package-monitor-helper.sh upstream --apply\` |
$(_scheduler_row_pulse "repeat:daily(@01:30) timezone:UTC")

Pulse reads the enabled routine from registered \`TODO.md\` files and evaluates
the version-controlled \`repeat:daily(@01:30) timezone:UTC\` contract; r916 has no
dedicated platform unit.

## Safety rails

- Reads only registrations with \`app_type: cloudron-package\` and explicit upstream metadata.
- Requires ADMIN or MAINTAIN authority before creating a target-local issue.
- Never changes package source, tags, releases, catalogs, images, or deployments.
$(_pulse_diag_commands "$os")
$(_platform_footnote "$os")
EOF
	return 0
}

describe_r917() {
	local os="${1:-}"
	[[ -n "$os" ]] || os="$(uname -s | tr '[:upper:]' '[:lower:]')"
	cat <<EOF
# r917: Cloudron package compatibility audit

## Overview

Weekly validation of registered Cloudron manifests and final pinned base images.
Stable finding fingerprints prevent repeated issues for an already handled audit.

## Schedule

| Field | Value |
|-------|-------|
| Frequency | Weekly on Sunday at 07:40 |
| Type | script |
| Expected duration | ~5 minutes |
| Script | \`scripts/cloudron-package-monitor-helper.sh compatibility --apply\` |
$(_scheduler_row_pulse "repeat:weekly(sun@07:40)")

Pulse reads the enabled routine from registered \`TODO.md\` files and evaluates
the version-controlled \`repeat:\` expression; r917 has no dedicated platform unit.

## Safety rails

- Audits local package files without building or executing upstream content.
- Creates issues only after target-local deduplication and authority checks.
- Never acknowledges a finding when GitHub/API operations fail.
$(_pulse_diag_commands "$os")
$(_platform_footnote "$os")
EOF
	return 0
}
