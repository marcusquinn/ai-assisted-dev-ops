<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Dispatch Ceremony Timing — Per-Stage Instrumentation (t3034)

After t3026 raised the per-candidate timeout floor to 360s, fresh
`exceeded 360s` events still appeared. This instrumentation captures
elapsed time for each sub-stage of the `dispatch_with_dedup` ceremony
so tail latencies (p95/p99) can be identified and optimized.

## Architecture

The instrumentation follows the same pattern as `gh-api-instrument.sh`
(t2902): a sourceable helper with a fail-open TSV append per stage.

```text
dispatch-stage-instrument.sh       — helper (sourceable + CLI)
pulse-dispatch-core.sh             — high-level stages instrumented
pulse-dispatch-worker-launch.sh    — launch sub-stages instrumented
~/.aidevops/logs/dispatch-stages.tsv — TSV log (append-only)
```

## Instrumented Stages

### High-level stages (in `dispatch_with_dedup`)

| Stage name           | What it covers                                      |
|----------------------|-----------------------------------------------------|
| `gh_issue_view`      | Single canonical metadata fetch (t2996 bundle)      |
| `dedup_check`        | All 9 dedup layers (`_dispatch_dedup_check_layers`)  |
| `brief_freshness`    | Brief-body freshness guard (`_ensure_issue_body_has_brief`) |
| `tier_body_shape`    | explicit tier:simple execution-contract guard        |
| `predispatch_validator` | Generator-tagged premise validation (GH#19118)    |
| `eligibility_gate`   | Generic eligibility gate (CLOSED, status:done, recent-merge) |
| `worker_launch_total` | Full `_dispatch_launch_worker` call                 |
| `ceremony_total`     | End-to-end `dispatch_with_dedup` from metadata fetch to launch |

### Launch sub-stages (in `_dispatch_launch_worker`)

| Stage name            | What it covers                                     |
|-----------------------|----------------------------------------------------|
| `assign_and_label`    | Issue edit: swap assignees + status:queued + origin:worker |
| `resolve_tier_model`  | Label-based tier resolution + round-robin model select |
| `lock_issue`          | Issue + linked PR lock (t1894/t1934)                |
| `precreate_worktree`  | Git worktree pre-creation (or reuse) + dep restore  |
| `worker_spawn`        | DB prewarm + setsid/nohup launch + early-exit monitor |
| `post_launch_hooks`   | Stagger delay + ledger + dispatch comment + claim audit |

## TSV Log Format

```text
<ISO8601_UTC>\t#<issue_number>\t<repo_slug>\t<stage_name>\t<elapsed_ms>
```

Example:

```text
2026-04-29T01:15:30Z	#21500	marcusquinn/aidevops	gh_issue_view	1250
2026-04-29T01:15:32Z	#21500	marcusquinn/aidevops	dedup_check	2100
2026-04-29T01:15:33Z	#21500	marcusquinn/aidevops	brief_freshness	45
```

## CLI Usage

```bash
# Print per-stage p50/p95/p99 from the last 24h of data:
dispatch-stage-instrument.sh report

# Custom time window (1h = 3600s):
dispatch-stage-instrument.sh report 3600

# Rotate log if it exceeds 50k lines:
dispatch-stage-instrument.sh trim

# Wipe the log:
dispatch-stage-instrument.sh clear
```

## Manual p95 Computation

After 50+ dispatches, compute per-stage percentiles:

```bash
awk -F'\t' '{print $4 "\t" $5}' ~/.aidevops/logs/dispatch-stages.tsv | \
    sort -k1,1 -k2,2n | \
    awk -F'\t' '
    { stage[$1]=stage[$1] " " $2; count[$1]++ }
    END { for (s in stage) {
      n=split(stage[s], arr, " "); p95_idx=int(n*0.95);
      print s, "p95=" arr[p95_idx] "ms (n=" count[s] ")"
    }}'
```

## Env Vars

| Variable | Default | Description |
|----------|---------|-------------|
| `AIDEVOPS_DISPATCH_STAGES_LOG` | `~/.aidevops/logs/dispatch-stages.tsv` | Log file path |
| `AIDEVOPS_DISPATCH_STAGES_LOG_MAX_LINES` | `50000` | Trim threshold |
| `AIDEVOPS_DISPATCH_STAGES_DISABLE` | `0` | Set `1` to no-op all recording |

## Hypotheses (from t3034 issue)

1. **Primary**: `gh issue view` + `gh api` rate-limit retries stack into
   the 360s envelope when GraphQL is exhausted (REST fallback also has
   retry+backoff). The `gh_issue_view` and `dedup_check` stages are the
   most likely culprits.

2. **Secondary**: `_dlw_prewarm_opencode_db` migration step on cold
   isolated DB adds 10-20s that compounds with retry-heavy gh calls.

3. **Tertiary**: `post_launch_hooks` includes a configurable stagger
   delay (`PULSE_DISPATCH_STAGGER_SECONDS`, default 8s) that contributes
   to ceremony overhead in batch dispatch scenarios.

## Follow-Up Tasks

After accumulating 50+ dispatches:

1. Identify stages with p95 > 60s.
2. File follow-up optimization tasks for each.
3. If sum of medians < 360s but tail behaviour pushes above, document
   and size the timeout floor accordingly.
