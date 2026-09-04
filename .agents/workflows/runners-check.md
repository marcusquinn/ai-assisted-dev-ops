---
description: Quick health check of worker status, PRs, TODO queue, and system resources
agent: Build+
mode: subagent
---

<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

Quick diagnostic of the dispatch system. Run in parallel, present a unified report.

Arguments: $ARGUMENTS

## Steps

```bash
# 1. Active workers (grep approximation — pulse deduplicates by issue+dir; use pulse logs for authoritative count)
MAX_WORKERS=$(test -r ~/.aidevops/logs/pulse-max-workers && cat ~/.aidevops/logs/pulse-max-workers || echo 4)
WORKER_COUNT=$(ps axo command | grep '/full-loop' | grep -v grep | wc -l | tr -d ' ')
AVAILABLE=$((MAX_WORKERS - WORKER_COUNT))
echo "=== Worker Status ==="
echo "Running: $WORKER_COUNT / $MAX_WORKERS (available slots: $AVAILABLE)"

# 2. TODO.md queue analysis (subtask-aware)
TODO_FILE="$(git rev-parse --show-toplevel 2>/dev/null)/TODO.md"
if [[ -f "$TODO_FILE" ]]; then
  total_open=$(grep -c '^[[:space:]]*- \[ \]' "$TODO_FILE" 2>/dev/null || echo 0)
  parent_open=$(grep -c '^- \[ \]' "$TODO_FILE" 2>/dev/null || echo 0)
  subtask_open=$((total_open - parent_open))
  # Dispatchable: open, has #auto-dispatch (or parent does), not blocked, not claimed
  dispatchable=$(grep -E '^[[:space:]]*- \[ \] t[0-9]+' "$TODO_FILE" 2>/dev/null | \
    grep -v 'assignee:\|started:' | \
    grep -v 'blocked-by:' | \
    grep -c '#auto-dispatch' 2>/dev/null || echo 0)
  # Subtasks whose parent has #auto-dispatch (inherited dispatchability)
  inherited=0
  while IFS= read -r line; do
    task_id=$(echo "$line" | grep -oE 't[0-9]+\.[0-9]+' | head -1)
    if [[ -n "$task_id" ]]; then
      parent_id=$(echo "$task_id" | sed 's/\.[0-9]*$//')
      if grep -qE "^- \[.\] ${parent_id} .*#auto-dispatch" "$TODO_FILE" 2>/dev/null; then
        if ! echo "$line" | grep -qE 'assignee:|started:'; then
          if ! echo "$line" | grep -qE 'blocked-by:'; then
            inherited=$((inherited + 1))
          fi
        fi
      fi
    fi
  done < <(grep -E '^[[:space:]]+- \[ \] t[0-9]+\.[0-9]+' "$TODO_FILE" 2>/dev/null | grep -v '#auto-dispatch')
  total_dispatchable=$((dispatchable + inherited))
  blocked=$(grep -E '^[[:space:]]*- \[ \]' "$TODO_FILE" 2>/dev/null | grep -c 'blocked-by:' || echo 0)
  claimed=$(grep -E '^[[:space:]]*- \[ \]' "$TODO_FILE" 2>/dev/null | grep -cE 'assignee:|started:' || echo 0)
  echo "=== TODO.md Queue ==="
  echo "Total open: $total_open ($parent_open parents, $subtask_open subtasks)"
  echo "Dispatchable: $total_dispatchable (tagged: $dispatchable, inherited: $inherited)"
  echo "Blocked: $blocked"
  echo "Claimed/in-progress: $claimed"
fi

# 3. Open PRs (need merge/review)
gh pr list --state open --json number,title,headRefName,createdAt,statusCheckRollup \
  --jq '.[] | "\(.number) [\(.headRefName)] \(.title) checks:\(.statusCheckRollup | map(.conclusion // .state) | join(","))"' 2>/dev/null

# 4. Active worktrees
git worktree list 2>/dev/null

# 5. Pulse scheduler status
if [[ "$(uname)" == "Darwin" ]]; then
  launchctl list | grep -i 'aidevops.*pulse' || echo "No launchd pulse found"
else
  crontab -l | grep -i 'pulse' || echo "No cron pulse found"
fi
```

## Report Format

Concise dashboard, anomalies first:

- **Worker Status** — `Running: X / Y max (Z slots)`. Flag: all slots full; 0 workers + dispatchable tasks.
- **Queue Depth** — `Total open: X (Y parents, Z subtasks). Dispatchable: N. Blocked: B. Claimed: C.` Flag: dispatchable=0 but open count high (queue stall).
- **Action Items**: PRs ready to merge → PRs with CI failures → stale worktrees → subtasks missing `#auto-dispatch` → pulse not running.
- **System Health** — pulse scheduler (launchd/macOS, cron/Linux), recent log: `tail -20 ~/.aidevops/logs/pulse.log`

## Arguments

- No arguments: current system status
- `--fix`: auto-fix simple issues (merge green PRs, clean stale worktrees) and,
  only when configured by the operator, invoke bounded broker recovery below.

## GitHub Actions broker health

Keep this separate from worker-dispatch health. Diagnose false-healthy
self-hosted Actions runners with:

```bash
BROKER_HEALTH_REPO=<OWNER>/<REPO> github-runner-broker-health-helper.sh diagnose
```

Report its classification and action verbatim. `UNKNOWN_PERMISSION`,
`UNKNOWN_NETWORK`, `UNKNOWN_LOCAL`, `NO_MATCHING_RUNNER`, and `BUSY_CAPACITY`
are read-only outcomes and must never cause a restart. `active`, `running`, and
`Listening for Jobs` are insufficient without compatible GitHub queue evidence.

For `$ARGUMENTS == --fix`, run `repair` only when the operator has configured an
executable `BROKER_HEALTH_RESTART_ADAPTER`. The helper re-checks evidence under
a host lock, restarts at most one proven-idle candidate, enforces a cooldown,
and requires both a fresh runner registration and queue movement:

```bash
BROKER_HEALTH_REPO=<OWNER>/<REPO> \
  BROKER_HEALTH_RESTART_ADAPTER=<APPROVED_LOCAL_ADAPTER> \
  github-runner-broker-health-helper.sh repair
```
