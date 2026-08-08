<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Worker Diagnostics and Architecture

<!-- AI-CONTEXT-START -->

Reference for diagnosing headless worker failures. Workers are OpenCode instances dispatched by the pulse to solve GitHub issues autonomously.

**Scripts**: `headless-runtime-helper.sh` (worker lifecycle), `pulse-wrapper.sh` (dispatch), `dispatch-dedup-helper.sh` (dedup), `dispatch-claim-helper.sh` (claims).

<!-- AI-CONTEXT-END -->

## Worker Lifecycle

```text
Pulse cycle (every 3 min, configurable)
  → Version guard (enforce OPENCODE_PINNED_VERSION)
  → Canary smoke test (cached 30 min)
  → dispatch_with_dedup (claim + dedup check)
  → nohup worker launch (survives pulse-wrapper exit)
    → DB isolation (XDG_DATA_HOME per worker)
    → Activity watchdog (standalone process, monitors output growth)
    → OpenCode run (headless, direct to the selected provider/model via OAuth or API key)
    → On completion: merge worker DB back to shared DB, cleanup
    → On failure: CLAIM_RELEASED posted, issue available for re-dispatch
```

### Preserved worktree ownership transfer

Reusing an issue worktree does not make its current registry owner stale. Fresh
dispatcher creation passes the issue identity into `worktree-helper.sh`, so the
helper's first durable owner row is already task-complete even if later setup is
interrupted. For a scheduled same-task continuation, dispatch captures the exact
owner PID, session, batch, matching task ID, and ownership timestamp without
replacing the row. An incomplete or mismatched row is never exported as a
continuation; dispatch falls through to the atomic claim/recovery path instead.
The worker verifies a complete snapshot and changes ownership with one atomic
compare-and-swap. Only that explicit continuation path may preserve dirty files
or commits ahead of the upstream branch.

Generic claims and stale-owner recovery keep their clean/zero-ahead checks.
They do not gain authority from a matching task ID alone, and unrelated live
owners remain protected. Pre-runtime classifications distinguish
`worker_worktree_continuation_task_mismatch`,
`worker_worktree_continuation_owner_mismatch`,
`worker_worktree_continuation_concurrent_mutation`, and
`worker_worktree_continuation_state_rejected`; use these instead of treating
every refusal as an opaque `worker_worktree_live_owner` retry.

Terminal continuation refusals have no runtime metric because the model was
never invoked. `pulse-diagnose-helper.sh issue <N> --repo <owner/repo>` reports
their count and reason distribution from pulse logs separately from model
attempts. Repeated `CLAIM_RELEASED` zero-attempt evidence participates in the
bounded dispatch-infrastructure hold instead of creating an unbounded claim and
release comment loop. Once zero-attempt infrastructure evidence reaches the hold
threshold, comment-bloat clean-room mode cannot bypass that hold; clean-room
fallback remains available for model/brief zero-output evidence.

### Dispatch claim comment states

Use the issue timeline to distinguish expected dispatch ownership from noisy
claim loops:

| Signal | Meaning | Expected next evidence |
|---|---|---|
| `DISPATCH_CLAIM ...` | A runner entered the cross-runner claim window. Only the winning/oldest claim remains public; losing claims are removed. | `CLAIM_WON` in pulse logs followed by a `Dispatching worker` comment. `CLAIM_DEFERRED` / `CLAIM_LOST` remain runner-log diagnostics rather than additional issue comments. |
| `Dispatching worker ...` with no later terminal marker | Active worker ownership. It blocks re-dispatch for the normal dispatch TTL, then for the extended non-terminal worker window (`DISPATCH_ACTIVE_WORKER_MAX_AGE`, default 7200s). | Worker log growth, PR creation, `MERGE_SUMMARY`, `CLAIM_RELEASED`, `Worker failed`, or watchdog output. |
| Draft/open PR or recent issue/PR timeline event after dispatch | Natural liveness signal. Prefer these durable events over synthetic heartbeat comments. | Continue from the referenced branch/PR if the worker later goes silent. Stale recovery uses the latest visible issue activity and targeted open-PR activity before reclaiming. |
| `DISPATCH_CLAIM ... reason=stale_worker_takeover prior_dispatch_age_s=<n> no_terminal=true` | A later runner is deliberately taking over after the extended non-terminal worker window expired. This is not a bare duplicate claim. | A fresh `Dispatching worker` comment or a deterministic skip/failure reason. |
| `CLAIM_RELEASED ...` / `MERGE_SUMMARY` / `Worker failed` / `Worker Watchdog Kill` / `BLOCKED` | Terminal ownership marker. Prior dispatch comments no longer block. | Re-dispatch is safe if the issue remains open and eligible. |

Headless workers should emit the smallest append-only GitHub-visible signal that
helps watchdogs and recovery. Do not post routine "still working" comments when
GitHub already has a natural event, such as a branch push reflected in an open
draft PR, PR update, check run, label/assignee transition, or useful issue/PR
comment. When silence is extraordinary, a signal comment should include only the
current mode, branch/PR/commit if known, verification state, and the next useful
recovery step.

A repeated bare `DISPATCH_CLAIM` without `Dispatching worker`,
`reason=stale_worker_takeover`, or a terminal marker is still a claim lifecycle
bug. Diagnose with `dispatch-dedup-helper.sh is-assigned <issue> <slug>
<runner>` and the pulse dispatch stage ledger before attributing a worker outage.

Stale recovery is globally bounded by the GitHub-backed recovery markers. The
default threshold of two includes silent/phantom assignments: a stale timeout is
itself terminal no-progress evidence even when a crashed launcher omitted its
terminal marker. The first recovery emits one combined recovery/tick comment;
the second applies machine-recoverable `status:blocked`. An open PR is durable progress, so
stale recovery preserves its ownership and emits no synthetic reset comment.

## Progress-Blocker Evidence

Before opening raw worker logs, inspect the bounded blocker lifecycle alongside
canonical runtime outcomes:

```bash
worker-activity-helper.sh summary --since 24h
pulse-diagnose-helper.sh issue <N> --repo <owner/repo>
```

Both commands read `~/.aidevops/logs/worker-progress-blockers.jsonl`.
`worker-activity-helper.sh` reports events in the selected window plus current
active blockers from the latest retained event per worker session.
`pulse-diagnose-helper.sh issue` filters the same records by issue/repository and
includes them in human output and JSON `progress_blockers`.

Permission blocker reasons distinguish a normal `permission_required` or
`needs_maintainer_permissions` pause from non-grantable sensitive scope,
capture/comment/label/marker persistence failures, missing or invalid signed
grants, expiry, target/request/worktree/session/branch replay mismatches, and a
successful `scoped_permission_granted` resume. A non-blocking grant event clears
the prior blocker for the same worker session even though the envelope request
ID differs from the source OpenCode request ID.

## Manual Worker Launch

Use `aidevops launch-worker` when an operator needs a controlled headless
worker launch instead of waiting for the next pulse cycle. Common cases:

- Smoke-test a newly filed issue.
- Retry after fixing a dispatch blocker.
- Validate worker-readiness for a brief.
- Start a small batch with an explicit workload tier.

Examples:

```bash
aidevops launch-worker 22259 marcusquinn/aidevops --dry-run
aidevops launch-worker 22259 marcusquinn/aidevops
aidevops launch-worker --batch 22259,22260 marcusquinn/aidevops --agent Build+
aidevops launch-worker status 22259 marcusquinn/aidevops
```

For normal routing, label each issue `tier:simple`, `tier:standard`, or
`tier:thinking` before launch. Runtime routing selects the preferred available
provider, model, and reasoning level. The underlying helper retains `--model`
only as an advanced compatibility override for exact model IDs.

The command wraps `dispatch-single-issue-helper.sh dispatch`, so it preserves the
manual-dispatch ceremony: open-issue validation, parent-task block, fail-closed
dedup check, `status:queued`, `origin:worker`, runner assignment, worktree
creation from `origin/<default>`, and ledger registration. It is not a pulse
replacement; the pulse still owns scanning, cadence, capacity, and merge flow.

## PR Repair Loop for Red or Stale Checks (t3508)

The deterministic merge pass does not leave trusted worker PRs to accumulate
when all trust/review gates pass but required checks are red or stale-pending.
It routes actionable repair context back to the linked issue and re-opens that
issue for dispatch.

Repair triggers:

- Required checks in `fail` or `cancel` buckets.
- Native auto-merge already set and the current head has a terminal required
  check failure. Pending/in-progress required checks are non-terminal and should
  continue running instead of being restarted by a branch refresh.

Safety boundaries:

- Non-collaborator PRs are still blocked by the normal maintainer/security
  gates before repair routing.
- `CHANGES_REQUESTED` still routes through review-feedback handling, not CI
  repair.
- Repair feedback is deduplicated by linked issue + PR + head SHA marker
  (`<!-- ci-feedback:PR...:SHA... -->`) so each stuck head queues at most one
  repair action.
- Required and advisory terminal failures are unioned into the same feedback
  dossier. A required failure must not hide a simultaneous advisory failure and
  force another worker/PR pass.
- Failed checks from older head SHAs are stale symptoms. Ignore them for repair
  routing and continue monitoring the latest head SHA.
- Superseded active runs may be cancelled only when the operator/helper can
  prove the run belongs to the same PR/branch, its head SHA is not the latest PR
  head SHA, and the run is still queued or in progress; otherwise leave it alone.
- Before rerunning a proven infrastructure failure, query the cached public
  GitHub Status incident feed with `gh-status-helper.sh check-actions`. An active
  Actions incident suppresses the rerun and classifies delayed queued checks as
  provider saturation; an unavailable status feed fails open. Use
  `AIDEVOPS_SKIP_GITHUB_ACTIONS_STATUS=1` only as an explicit emergency bypass.

Diagnosis commands:

```bash
pulse-diagnose-helper.sh pr <pr-number> --repo <owner/repo>
gh pr checks <pr-number> --repo <owner/repo> --required --watch=false
gh issue view <linked-issue> --repo <owner/repo> --json body --jq '.body'
```

Expected evidence after routing: the linked issue body contains a `CI Repair
Feedback` section with check names/URLs, the issue has `source:ci-feedback`, and
the stale PR has `ci-feedback-routed`.

Advisory checks should not enter this repair loop. For develop branches, keep
required checks limited to fast core gates where possible and run broad E2E at
staging/release boundaries. If advisory E2E finds a real defect, file a focused
follow-up task with the failing check/artifact evidence instead of closing the
current PR or redispatching duplicate workers. Full policy: `ci-gate-policy.md`.

### Review-thread remediation

Review-thread remediation is separate from CI repair. It preserves PR/review
context when unresolved conversations or `CHANGES_REQUESTED` feedback can be
handled on the active PR, and falls back to linked-issue redispatch only when the
merge gate cannot safely repair the thread in place.

Paths:

- **Proactive scanner**: post-dispatch housekeeping runs
  `_run_pr_review_thread_response_scanner()` via the `pr_review_thread_response`
  optional stage. It scans pulse-enabled maintainer repos only and calls
  `pr-review-thread-response-scanner.sh dispatch <repo-slug> <repo-path>`.
- **Unresolved-conversation merge blocker**: when merge output contains
  `A conversation must be resolved`, `pulse-merge.sh` calls
  `dispatch-pr` with `PR_REVIEW_THREAD_RESPONSE_INCLUDE_HUMAN=true` for that PR
  and logs `review-thread remediation queued` if a bounded response worker was
  queued.
- **Opt-in `CHANGES_REQUESTED` remediation-first**: setting
  `AIDEVOPS_CHANGES_REQUESTED_THREAD_REMEDIATION_FIRST=1` lets eligible worker or
  worker-takeover PRs try review-thread remediation before the historical
  close-and-redispatch path. PRs labelled `external-contributor`, `no-takeover`,
  or already `review-routed-to-issue` stay out of this path.
- **Fallback review-feedback routing**: if remediation is not enabled or cannot
  dispatch, `_route_pr_to_fix_worker ... review` routes worker-authored PR review
  feedback to the linked issue. `_dispatch_pr_fix_worker()` appends a `Review
  Feedback` section, sets `source:review-feedback`, closes/labels the stuck PR
  with `review-routed-to-issue`, and leaves the issue available for a fresh
  worker.

Scanner safety boundaries:

- Default scope is unresolved bot review threads on open non-draft PRs. Targeted
  merge-blocker dispatch is the only normal path that opts into human-authored
  threads with `PR_REVIEW_THREAD_RESPONSE_INCLUDE_HUMAN=true`.
- The response worker must read and verify the thread before editing code,
  commenting, resolving, or marking it complete/blocked. The scanner never
  resolves threads by itself.
- Per-repo dispatch is bounded by `PR_REVIEW_THREAD_RESPONSE_MAX_PER_REPO`
  (default `2`), same-fingerprint cooldown
  `PR_REVIEW_THREAD_RESPONSE_COOLDOWN` (default `3600` seconds), and inflight TTL
  `PR_REVIEW_THREAD_RESPONSE_INFLIGHT_TTL` (default `300` seconds).
- State is stored under
  `${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR:-$HOME/.aidevops/.agent-workspace/pr-review-thread-response}`
  so repeated attempts, cursors, and maintainer-attention blocks are durable.
- Optional-stage budget protection can defer `pr_review_thread_response` when
  GraphQL reserve mode is active. Scanner logs also report `GraphQL budget
  exhausted` or `write: skipped — GraphQL/API rate-limit remaining=<n>`; treat
  those as budget deferrals, not worker failures.

Diagnosis commands:

```bash
pulse-diagnose-helper.sh pr <pr-number> --repo <owner/repo>
pr-review-thread-response-scanner.sh scan-pr <owner/repo> <pr-number>
pr-review-thread-response-scanner.sh dispatch-pr <owner/repo> <repo-path> <pr-number>
pr-review-thread-response-scanner.sh dry-run <owner/repo> <repo-path>
```

Expected evidence after remediation routing: pulse logs contain
`PR review-thread response:`, `review-thread remediation queued`, or
`_dispatch_pr_fix_worker: routed review feedback`; active PR workers carry
thread-response state under the scanner state directory; fallback redispatch adds
`source:review-feedback` to the issue and `review-routed-to-issue` to the stale
PR.

### Failed job inside a still-running workflow

GitHub can expose a terminal failed job before its parent workflow run finishes.
In that state, `gh run view <run-id> --repo <owner/repo> --job <job-id>
--log-failed` may return only:

```text
run <run-id> is still in progress; logs will be available when it is complete
```

Do not wait or rerun blindly when job-level state is already terminal. First
verify the run/job split:

```bash
gh run view <run-id> --repo <owner/repo> --json status,conclusion,jobs
```

If the workflow `status` is still `in_progress` but the relevant job has
`status=completed` and `conclusion=failure`, fetch that job's logs directly via
the REST job-log endpoint and diagnose from the output:

```bash
gh api "repos/<owner/repo>/actions/jobs/<job-id>/logs" > failed-job.log
```

Only treat still-running CI as pending when the job itself is not terminal, or
when the job log endpoint is unavailable after the status/conclusion check. The
failure-mining helper already follows this fallback pattern in
`.agents/scripts/gh-failure-miner-helper.sh` after `gh run view --log-failed`
returns no useful failed log output.

## Architecture Decisions

### SQLite DB Isolation (v3.6.130)

**Problem**: All headless workers shared `~/.local/share/opencode/opencode.db` with `busy_timeout=0`. Concurrent writes caused `SQLITE_BUSY` which silently broke OpenCode's streaming connection handler. Workers stalled at `step_start` with zero API errors logged.

**Why it was hard to find**: Interactive sessions (single instance) never hit contention. Version bisecting was misleading — fewer workers = less contention = fewer failures, creating a false correlation with OpenCode versions.

**Fix**: Each worker gets its own DB via `XDG_DATA_HOME=/tmp/aidevops-worker-auth.XXXXXX`. After completion, `_merge_worker_db()` copies session/message rows back to the shared DB using `ATTACH DATABASE` + `INSERT OR IGNORE` with a 5s timeout.

**Diagnostic**: If workers stall at `step_start` with no API errors, check:

```bash
# Are isolated dirs being created?
ls -d /tmp/aidevops-worker-auth.* 2>/dev/null || ls -d "$TMPDIR"/aidevops-worker-auth.* 2>/dev/null
# Is OPENCODE_DB still set? (it should NOT be)
grep 'OPENCODE_DB' ~/.aidevops/agents/scripts/headless-runtime-helper.sh
```

### Activity Watchdog (v3.6.126, fixed v3.6.140)

**Problem**: The original watchdog was a bash function backgrounded with `&` inside the worker's subshell. When `nohup` launched the worker (to survive pulse-wrapper exit), the backgrounded function died with its parent context. Stalled workers sat indefinitely with no kill mechanism.

**Fix**: Watchdog launched as a standalone process that outlives the worker subshell.

**Diagnostic**: If workers stall past the 300s timeout:

```bash
# Are watchdog processes alive?
ps aux | grep 'worker-activity-watchdog\|activity_watchdog' | grep -v grep
# Check worker log for WATCHDOG_KILL marker
grep WATCHDOG_KILL /tmp/pulse-*-<issue>.log
# Check for CLAIM_RELEASED on the issue
gh api repos/<slug>/issues/<num>/comments --jq '.[] | select(.body | test("CLAIM_RELEASED")) | .created_at'
```

### Provider-scoped startup (t3420)

Headless OpenCode workers scope startup state to the selected model provider:

- The isolated `auth.json` copied into `XDG_DATA_HOME` contains only the selected provider entry (for example, `openai` for `openai/gpt-5.5`).
- Sandbox passthrough includes shared framework/runtime variables plus only the selected provider's env vars (`OPENAI_*`, `ANTHROPIC_*`/`CLAUDE_*`, or `GOOGLE_*`).
- Canary uses the same provider-scoped auth copy as the real worker, so it validates the selected model without eagerly initializing unrelated provider accounts.
- Fallback remains lazy: when retry logic selects another provider/model, the next run attempt rebuilds the isolated auth/env scope for that provider.

Diagnostic: set `AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=openai` or dispatch with `--model openai/gpt-5.5`, then inspect the worker temp auth dir in lifecycle logs (`db_isolated dir=...`). Its `opencode/auth.json` should not contain unrelated provider keys.

### Linux/OpenCode/OAuth-pool zero-worker runbook (t3476)

Use this when a runner's dashboard is fresh but **Active Workers = 0**.

1. Start with current state, not historical aggregates:

   ```bash
   pulse-current-state-helper.sh --window 15m
   ```

2. Verify provider/model selection. Fresh installs and updates use the OpenAI-first routing table unless the operator overrides with `custom/configs/model-routing-table.json` or `AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST`:

   ```bash
   headless-runtime-helper.sh select --role worker --tier standard
   AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST=openai headless-runtime-helper.sh select --role worker --tier standard
   ```

3. Verify recent provider/model/account usage with bounded structured output before
   reading raw logs:

   ```bash
   worker-activity-helper.sh providers --since 1h
   ```

   This reads `headless-runtime-metrics.jsonl` plus a redacted aggregate of
   `oauth-pool.json` (counts only; no emails/tokens). Do not recursively search
   `~/.aidevops/logs` or OpenCode storage for routine provider/account checks.

4. Verify OAuth-pool health without printing secrets:

   ```bash
   oauth-pool-helper.sh status
   oauth-pool-helper.sh check openai
   oauth-pool-helper.sh check anthropic
   ```

   Rate-limit cooldowns derived from provider retry hints are capped at 6h by
   default (`AIDEVOPS_OAUTH_POOL_MAX_RATE_LIMIT_COOLDOWN_SECONDS`) so a stale
   multi-day `Retry-After` cannot sideline usable accounts for days. Missing or
   unparseable rate-limit retry hints still fall back to 60s; auth-error
   cooldowns remain on the separate 1h path. If status shows several accounts
   stuck behind stale `cooldownUntil` values, run
   `oauth-pool-helper.sh reset-cooldowns <provider>` after confirming the
   provider is healthy.

   Pulse capacity no longer treats a single healthy provider account as a
   low-concurrency signal by itself. By default,
   `orchestration.provider_account_slot_multiplier=24`, so one available
   OpenAI or Anthropic account may reach the configured `max_workers_cap` when
   RAM/disk and provider-health gates are clean. If the dashboard or
   `pulse.log` `Dispatch_capacity` line shows `final_max` below `raw_max`, use
   the logged fields (`account_cap`, `provider_account_slot_multiplier`,
   `rate_limits`, `service_interruptions`, `provider_5xx`, and
   `auth_error_accounts`) to identify the reducing gate. Lower concurrency
   explicitly with
   `aidevops config set orchestration.provider_account_slot_multiplier <n>` or
   `PULSE_PROVIDER_ACCOUNT_SLOT_MULTIPLIER=<n>` when a provider plan cannot
   sustain the default.

5. Read the dashboard's **Worker Dispatch Diagnostics** section. It is rendered only when Active Workers is 0 and distinguishes:
   - no eligible work (`Assigned Issues=0`, `Total Issues=0`)
   - auth/model unavailable (OpenAI/Anthropic both missing)
   - canary or worker launch failure (`Last Launch Failure`)
   - max-worker/resource gate (`Max Workers=0`, memory or disk pressure)
   - API budget/dispatch blockers (inspect `Last Dispatch Stage` and the current-state helper output)

6. Linux process counting must use the shared worker discovery path, which calls `ps axwwo pid,stat,etime,command` so long OpenCode commands are not truncated. A direct `pgrep` snapshot is not canonical because dispatch is bursty and can land between waves.

7. If the selected provider is OpenAI but the auth file contains only an Anthropic entry, model selection now treats OpenAI as unavailable rather than assuming any OpenCode `auth.json` is sufficient. Re-run OAuth pool rotation/checks and then retry selection.

### Canary Smoke Test (v3.6.123)

**Rules**:
1. Must use a **verified-working** model name (currently `anthropic/claude-sonnet-4-20250514`)
2. Must run **before** any side effects (claims, locks, ledger updates) — a failed canary must not block re-dispatch
3. Cached for 30 min (`~/.aidevops/.agent-workspace/headless-runtime/canary-last-pass`)
4. Version guard runs on every dispatch (not cached)

**Diagnostic**: If no workers dispatch at all:

```bash
# Check canary cache
cat ~/.aidevops/.agent-workspace/headless-runtime/canary-last-pass
# Clear cache to force re-test
rm -f ~/.aidevops/.agent-workspace/headless-runtime/canary-last-pass
# Test canary manually
opencode run "Reply with exactly: CANARY_OK" -m anthropic/claude-sonnet-4-20250514 --dir "$HOME"
```

### Minimum Worker Concurrency Floor (t3418)

Pulse keeps a soft minimum implementation-worker floor so transient local pressure does not reduce useful dispatch to zero. Default: `orchestration.min_worker_concurrency=6`; env override: `AIDEVOPS_MIN_WORKER_CONCURRENCY=6`.

When active workers are below the floor:

- `dispatch_max` keeps dispatch eligible up to the floor when only soft pressure is present.
- The worker canary still checks runtime/model health. CPU/load/saturation is diagnostic-only and never changes candidate eligibility, capacity, launch delay, or canary outcomes; auth checks, GraphQL circuit breaker, stop flag, memory/process failures, and other hard safety gates still apply.
- Existing max worker caps above the floor still cap runaway dispatch.

Set `orchestration.min_worker_concurrency=0` (or `AIDEVOPS_MIN_WORKER_CONCURRENCY=0`) to disable the floor, or set a higher/lower integer for a runner-specific target.

### Adaptive Worker Launch Staggering (t3482)

Pulse staggers worker launches inside the parallel `dispatch_max` loop when provider, failure, or API-budget signals show that a back-to-back batch is likely to waste capacity. The first launch in a clean round is immediate; subsequent launches remain near-zero delay unless one or more pressure signals are active.

Signals that increase the inter-launch delay:

- Recent non-success worker terminal metrics, especially clustered `rate_limit` results.
- Provider/rate-limit backoff flags.
- Low cached GraphQL remaining budget.
- Large in-flight launch bursts while pressure is already present.

Host CPU and `load_per_cpu` remain visible in runtime metrics for diagnosis, but the OS scheduler arbitrates CPU contention; those values do not block or pace dispatch.

Observability:

```bash
pulse-current-state-helper.sh --window 15m --json | jq '.dispatch_pacing'
```

Relevant tuning knobs: `PULSE_DISPATCH_STAGGER_ADAPTIVE=0` disables adaptive staggering, `PULSE_DISPATCH_STAGGER_MAX_SECONDS` caps the delay (default 20s), `PULSE_DISPATCH_STAGGER_JITTER_MAX_SECONDS` caps deterministic jitter (default 3s), and the `PULSE_DISPATCH_STAGGER_*` threshold variables override failure/GraphQL sensitivity for diagnostics.

### Version Guard

**Problem**: Something outside aidevops periodically upgrades OpenCode to latest. The version guard in `headless-runtime-helper.sh` runs on every dispatch and reinstalls `OPENCODE_PINNED_VERSION` from `shared-constants.sh` if drift is detected.

**When to pin**: Set `OPENCODE_PINNED_VERSION` in `.agents/scripts/shared-constants.sh` to a specific version when a known-broken release exists. Set to `"latest"` when no pin is needed.

## `launch_recovery:no_worker_process` Failure Mode (t2804)

**Signature**: Worker process never appears within the grace period after dispatch. The pulse posts `CLAIM_RELEASED reason=launch_recovery:no_worker_process` on the issue and returns the issue to `status:available`. No worker log at `/tmp/pulse-*-<issue>.log`.

**Log message**:

```text
[pulse-wrapper] Launch validation failed for issue #N (slug) — no active worker process within Xs
```

**GitHub audit trail**:

```text
CLAIM_RELEASED reason=launch_recovery:no_worker_process runner=<login> ts=<ISO>
```

**Observed pattern (2026-04-20 to 2026-04-24 data, t2812)**:
- Occurs in **time-correlated clusters**, not random transients. A single runner experiences 30+ failures across many issues within a 2–4 hour window, then recovers.
- **Self-heals**: the underlying infrastructure issue (canary auth expiry, session lock collision) typically clears within minutes. The issue retries at the same tier — cascade tier escalation is NOT used for `no_worker_process` failures (t2815). 63/65 affected issues in the observed window resolved within the same day.
- **Runner-specific**: 82% of events attributed to one runner (`alex-solovyev`), 17% to the other (`marcusquinn`). Likely reflects resource constraints on the failing runner at time of cluster.
- **Cross-repo**: affects all pulse-enabled repos simultaneously (observed in `marcusquinn/aidevops` ~112 events, `exampleorg/examplerepo` ~130 events in 5-day window).

**Mitigation already in place**:
- After 3 consecutive `no_worker_process` failures in a round, the canary cache is invalidated — next dispatch re-runs the canary to detect broken runtimes.
- `no_worker_process` failures are classified as `crash_type=no_work` (t2815) — cascade tier escalation is **skipped** (t2387). The issue retries at the same tier so the next attempt runs cheaply once the infrastructure issue clears.
- After `NO_WORK_NMR_THRESHOLD` (legacy variable name; default 3) consecutive infra failures per issue, the per-issue no_work circuit breaker (t2769) applies `status:blocked`, posts the backward-compatible `cost-circuit-breaker:no_work_loop` marker, and files a root-cause meta-issue.
- `fast_fail_record` increments the per-issue failure counter for backoff.

**Diagnostic**:

```bash
# Check if this is happening right now
grep "no active worker process" ~/.aidevops/logs/pulse-wrapper.log | tail -20

# Count failures in last hour
grep "$(date -u +%Y-%m-%dT%H)" ~/.aidevops/logs/pulse-wrapper.log | grep -c "no active worker process" || true

# Check canary cache freshness (stale cache may mask broken runtime)
cat ~/.aidevops/.agent-workspace/headless-runtime/canary-last-pass

# Is the CLI itself broken? Test outside of pulse:
opencode run "Reply with exactly: CANARY_OK" -m anthropic/claude-sonnet-4-20250514 --dir "$HOME"

# Check system load at failure time
uptime
```

**When to escalate to Phase 2 analysis**: If clusters recur with the same runner >3 times per day, or if the cascade escalation to `tier:thinking` fails to resolve the issue, investigate runtime-level causes (resource exhaustion, auth token expiry, network drop) on the failing runner.

### Root Cause Analysis (Phase 2 — t2813)

**Root cause class**: Worker process exits before `check_worker_launch` observes it. Not a
single bug but a **class of early-exit paths** in the worker startup sequence, combined with
a **diagnostic gap** that prevents the pulse from determining WHY the worker exited.

#### Dispatch → spawn → detection chain

The chain has three stages with a critical timing dependency between them:

1. **Dispatch stage** (pulse-dispatch-engine.sh:519–522 subshell):
   - `dispatch_with_dedup` → 9-layer dedup check → `_dispatch_launch_worker`
   - `_dlw_exec_detached` (pulse-dispatch-worker-launch.sh:395–418): launches worker via
     `setsid nohup env ... headless-runtime-helper.sh run ... &` — returns immediately with `$!` PID.
   - `_dlw_post_launch_hooks` (pulse-dispatch-worker-launch.sh:535–580): **sleeps 8 seconds**
     (stagger delay), posts dispatch comment. Total subshell time: ~15–20s.

2. **Worker startup** (headless-runtime-helper.sh `cmd_run`, runs in parallel after nohup):
   - Arg parsing, `choose_model` (~instant)
   - `_enforce_opencode_version_pin` (headless-runtime-lib.sh:808–831, ~1–2s)
   - `_run_canary_test` (headless-runtime-lib.sh:833–951): instant if cached, up to 60s if
     running fresh. **If canary fails → process exits immediately** (return 1 at line 950).
   - `_acquire_session_lock` (headless-runtime-lib.sh:733–767): **if lock collision → exit 0**
     (returns 2, which `cmd_run` treats as clean exit at line 1447–1448).
   - `_execute_run_attempt` → `_invoke_opencode` → actual OpenCode binary.

3. **Detection stage** (pulse-dispatch-engine.sh:534):
   - `check_worker_launch` polls `has_worker_for_repo_issue` every 2s for up to 35s
     (`PULSE_LAUNCH_GRACE_SECONDS`).
   - `has_worker_for_repo_issue` (pulse-dispatch-core.sh:113–165) → `list_active_worker_processes`
     (worker-lifecycle-common.sh:730–747) → `ps axwwo pid,stat,etime,command | awk -f
     list_active_workers.awk`.
   - Awk matches: `headless-runtime-helper.sh` + `run` + `--role worker` + `/full-loop`.

#### Why workers disappear before detection

The 8-second stagger delay inside the dispatch subshell (step 1) means `check_worker_launch`
starts polling ~15–20 seconds after the worker was nohup'd. If the worker exits within those
first 15–20 seconds (e.g., canary failure at 8s, model selection failure at 1s), the process
is already dead by the time the first poll runs. All 17 subsequent polls (every 2s for 35s)
find nothing → `no_worker_process`.

#### Identified early-exit paths (ranked by likelihood)

**Path 1 — Canary test failure (PRIMARY)**: `headless-runtime-lib.sh:833–951`
- When the canary test runs a fresh OpenCode invocation (not cached), and the API call
  fails (auth token expired, rate limit, provider outage), the canary returns 1.
  `cmd_run` (headless-runtime-helper.sh:1432–1434) exits immediately.
- **Why it matches Phase 1 clusters**: Each runner has its own auth tokens (isolated via
  `XDG_DATA_HOME`). Auth token expiry affects one runner at a time. The canary cache
  (30-min TTL) means: a passed canary protects subsequent dispatches, but a failed canary
  has **no negative cache** — each dispatch attempt re-runs it.
- **Why cascade escalation "works"**: The escalation delay (~5–10 min) allows time for
  tokens to refresh. Different tier → different model → potentially different API
  key/provider. The delay alone is often sufficient for recovery.

**Path 2 — Model selection failure**: `headless-runtime-helper.sh:1418–1422`
- `choose_model` returns non-zero → `cmd_run` calls `_cmd_run_finish` and exits.
  Caused by: all providers in backoff, model routing table empty, config corruption.

**Path 3 — Session lock collision**: `headless-runtime-lib.sh:742–757`
- If a previous dispatch's lock file exists with a PID that `_is_process_alive_and_matches`
  considers alive (PID reuse on macOS — mitigated by t2421 argv hash, but not eliminated),
  the worker exits cleanly (exit 0, invisible to fast-fail counters).

**Path 4 — File descriptor exhaustion (SUSPECTED but unconfirmed)**:
- `_dlw_exec_detached` (pulse-dispatch-worker-launch.sh:402) launches the worker via
  `setsid nohup ... &`. The `setsid` creates a new session but does NOT close inherited
  file descriptors. If the pulse process has accumulated many open FDs (from GitHub API
  calls, log files, temp files), the worker inherits them and may hit `EMFILE` when
  trying to open new connections.
- This would explain runner-specific clusters (FD accumulation depends on runner's pulse
  uptime and workload) and self-healing (pulse restart resets FDs).
- **Cannot confirm without data**: FD counts were not logged during the observed clusters.

#### Investigation candidates assessment

**(a) Worker launch script exits 0 without spawning — CONFIRMED (Path 3)**

`headless-runtime-helper.sh` CAN exit 0 without spawning a worker when
`_acquire_session_lock` detects a lock collision (headless-runtime-lib.sh:753, return 1
→ `cmd_run:1447` `prepare_exit=2` → `return 0`). The nohup wrapper `_dlw_exec_detached`
always returns 0 (line 417), so `dispatch_with_dedup` returns 0 regardless of what happens
inside the worker process — the "dispatch succeeded" signal is emitted before the worker
has finished starting.

**(b) Spawn races with dedup guard — RULED OUT by design**

The 7-layer dedup chain (`check_dispatch_dedup`, pulse-dispatch-core.sh:172–188) and the
per-session-key lock file (`_acquire_session_lock`, headless-runtime-lib.sh:733) together
prevent duplicate spawns. No code path was found that bypasses both layers. The session
lock is acquired inside the worker process (not the dispatcher), which means a race between
two workers for the same session key would be caught by the lock.

**(c) Canary check passes but exec into runtime silently fails — PARTIALLY CONFIRMED**

The canary test uses a SEPARATE OpenCode invocation with its own isolated DB dir
(headless-runtime-lib.sh:884–891). The worker process uses a DIFFERENT isolated DB dir
(headless-runtime-helper.sh:421). Both copy the same `auth.json`, but the canary validates
model connectivity only — it does not test the full worker exec chain (sandbox, worktree,
plugin loading). A canary pass does not guarantee the worker's OpenCode will succeed.
However, the more impactful failure mode is the canary FAILING (Path 1), not passing-then-failing.

**(d) Cascade escalation on missing worker — FIXED by t2815**

`recover_failed_launch_state` (pulse-cleanup.sh) now maps `no_worker_process` to
`crash_type=no_work` before calling `fast_fail_record`. This routes through the t2387
infra-failure guard in `escalate_issue_tier`, which skips tier escalation and keeps
the issue at its current tier. Same-tier retry applies; after `NO_WORK_NMR_THRESHOLD`
(legacy variable name; default 3) consecutive failures the t2769 no_work circuit breaker applies
`status:blocked` and files a root-cause meta-issue. The cascade no longer fires on infrastructure failures where
the worker never spawned.

#### Diagnostic gap (the core infrastructure finding)

The pulse has no visibility into WHY a worker exited early. The gaps:

1. **Worker log exists but is not read during recovery**: `_dlw_setup_worker_log` creates
   `/tmp/pulse-${safe_slug}-${issue_number}.log`. The nohup'd process writes to this log
   (stdout/stderr). But `recover_failed_launch_state` (pulse-cleanup.sh:728) never reads
   it — the exit reason is lost.

2. **Canary output is discarded**: The canary test writes diagnostics to a temp file
   (headless-runtime-lib.sh:850) and logs the last 20 lines to stderr (line 948). This
   output goes to the worker log (via nohup stderr redirection), but again, nobody reads
   the worker log during recovery.

3. **`check_worker_launch` discards its own output**: Line 534 in pulse-dispatch-engine.sh:
   `check_worker_launch "$issue_number" "$repo_slug" >/dev/null 2>&1`. The launch check's
   diagnostic messages (including the specific failure reason) are thrown away.

4. **No spawn-time exit code capture**: `_dlw_exec_detached` captures `$!` (nohup PID) but
   never waits for it or checks its exit code. The dispatch subshell exits before the worker
   does. When the worker dies, its exit code is reaped by init (PID 1) and lost.

#### Recommended Phase 3 fix targets

1. **Read worker log tail during recovery**: In `recover_failed_launch_state`
   (pulse-cleanup.sh), after confirming the worker is gone, read the last 20 lines of the
   worker log and include them in the `CLAIM_RELEASED` comment and `$LOGFILE` entry. This
   turns every `no_worker_process` event into a diagnosed failure.

2. **Add spawn-time exit monitoring**: After `_dlw_exec_detached` returns, start a
   lightweight background monitor that waits for the nohup'd PID (or its child, since
   `setsid` may fork) and logs the exit code. This captures fast failures synchronously.

3. **Close inherited FDs before exec**: In `_dlw_exec_detached`, close FDs >2 before
   the `setsid nohup` invocation to prevent FD leak from the pulse into workers:
   `for fd in /proc/self/fd/*; do fd_num=${fd##*/}; [[ $fd_num -gt 2 ]] && exec {fd_num}>&-; done`

4. **Negative canary cache with short TTL**: When the canary fails, cache the failure for
   60–120 seconds. This prevents N consecutive dispatch attempts from each spending up to
   60 seconds on canary runs that will all fail for the same reason. The batch throttle
   (pulse-dispatch-engine.sh:559) partially addresses this but only after 80% failure ratio.

### Phase 3 — Fixes Landed (t2814)

All four Phase 2 recommended fixes are deployed. Regression coverage:
`.agents/scripts/tests/test-no-worker-process-fix.sh` (15 assertions).

#### Fix 1 — Worker-log tail in `CLAIM_RELEASED` comment

`_post_launch_recovery_claim_released` (pulse-cleanup.sh) now reads the
worker log at `/tmp/pulse-${safe_slug}-${issue_number}.log`, takes the
last 20 lines (capped at 4KB to stay under GitHub's body limit and limit
credential-leak surface), and embeds them in a `<details>` block on the
`CLAIM_RELEASED` comment. Closes the diagnostic gap: every
`no_worker_process` event now ships its own canary diagnostics in the
audit trail. No log forensics required.

#### Fix 2 — Spawn-time exit monitor

`_dlw_exec_detached` (pulse-dispatch-worker-launch.sh) forks a detached
`bash -c` watcher (`_dlw_spawn_early_exit_monitor`) that polls the
nohup'd worker PID for the first `DLW_EARLY_EXIT_WINDOW_SECONDS`
(default 20s, override via env). On early death, the watcher appends a
`[t2814:early_exit] worker PID N for issue #M exited within Ks spawn
window at <ts>` marker to the worker log — which Fix 1 then includes in
the `CLAIM_RELEASED` comment.

The watcher is itself wrapped in `setsid nohup` so it survives pulse
exit; it self-terminates after the window regardless of worker outcome.
Cost: ~5 sleep iterations of 4s each, near-zero CPU.

#### Fix 3 — Close inherited FDs before exec

Both the `setsid nohup` path and the fallback `nohup` path in
`_dlw_exec_detached` now include explicit `3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&-`
redirections after the standard `</dev/null >>"$worker_log" 2>&1`.
Closes the suspected FD-leak path that may have caused `EMFILE`
early-exit clusters on long-running pulse instances. Bash 3.2 compatible
(no `{fd}>&-` syntax). No-op when the FDs are not open.

#### Fix 4 — Negative canary cache

`_run_canary_test` (headless-runtime-lib.sh) now stamps a
`canary-last-fail` cache file on failure and short-circuits subsequent
calls within `CANARY_NEGATIVE_TTL_SECONDS` (default 90s, override via
env or `AIDEVOPS_SKIP_CANARY_NEG_CACHE=1` to bypass). Success clears the
file. Cuts the wasted-canary cost during a 90s auth/rate-limit blip from
N × `CANARY_TIMEOUT_SECONDS` (default 60s each) to a single failure plus
N short-circuit returns.

#### Verification

```bash
# Unit + behavioural regression test (15 assertions)
bash .agents/scripts/tests/test-no-worker-process-fix.sh

# After deploy: confirm subsequent no_worker_process events carry log tails
gh api repos/<slug>/issues/<num>/comments --jq \
  '.[] | select(.body | test("CLAIM_RELEASED.*no_worker_process")) | .body' | head -50
```

If a fresh `no_worker_process` event appears without a `<details>` block
on the `CLAIM_RELEASED` comment, the worker log was missing at recovery
time — investigate _dlw_setup_worker_log creation order.

#### Phase 4 fix applied — t2815

**Prevent cascade tier escalation on `no_worker_process` failures** (shipped):

In `recover_failed_launch_state` (pulse-cleanup.sh), when `failure_reason == "no_worker_process"`
and no explicit `crash_type` was provided, the effective crash type is now forced to `"no_work"`.
This routes through the t2387 infra-failure guard in `escalate_issue_tier`, which skips tier
escalation entirely. Observable change:
- Before: 2 consecutive `no_worker_process` → tier:standard upgraded to tier:thinking → opus dispatch → same infra failure.
- After: 2 consecutive `no_worker_process` → same-tier retry (no tier change). After `NO_WORK_NMR_THRESHOLD` (legacy variable name; default 3) failures, the t2769 no_work circuit breaker applies `status:blocked` and files a root-cause meta-issue.

**Crash type classification for `recover_failed_launch_state`**:

| `failure_reason` | Effective `crash_type` | Cascade escalation? | Notes |
|-----------------|------------------------|---------------------|-------|
| `no_worker_process` | `no_work` (t2815) | No | Worker never spawned — infra failure |
| `cli_usage_output` | caller-supplied (empty→unclassified) | Yes (at threshold) | CLI invoked incorrectly |
| `premature_exit` | caller-supplied (explicit crash type from watchdog) | Depends on crash_type | Worker exited during execution |
| `stale_timeout` | caller-supplied (from stale-recovery) | Depends on crash_type | Worker was stalled |

#### Phase 5 — `worker_failed` reclassification via log tail (t2820)

**Problem.** Phases 3-4 fixed the `no_worker_process` slice — the worker
never spawned. The remaining `worker_failed` bucket conflates two distinct
modes that demand opposite responses:

- **Real coding failure** — worker spawned, loaded context, executed tool
  calls, produced bad code. Escalation to opus-4-7 is correct.
- **Late infra failure** — worker spawned, ran canary OK, hit a mid-session
  blip (auth refresh timeout, plugin hook deadlock, provider rate limit)
  BEFORE producing tool calls. Escalation wastes opus tokens.

**Fix.** `escalate_issue_tier` (worker-lifecycle-common.sh) now consults
the worker-log tail (Phase 3 t2814 collection) BEFORE deciding between
escalation and skip. When `crash_type` is empty AND `reason` matches a
generic worker-failure bucket (`worker_failed`, `premature_exit`,
`worker_noop_zero_output`), the helper `_maybe_reclassify_worker_failed_as_no_work`
inspects the log tail and applies one of these rules:

| Log tail signal | Subtype assigned | Cascade fires? | Skip-comment marker |
|-----------------|------------------|----------------|---------------------|
| `[t2814:early_exit]` marker OR `canary` keyword | `canary_post_spawn_failure` | No (skip via t2387 path) | `<!-- no-work-escalation-skip -->` |
| No tool-use markers AND log age ≤ `NO_WORK_RECLASS_ELAPSED_MAX` (default 180s) | `no_tool_calls_in_log` | No | `<!-- no-work-escalation-skip -->` |
| Tool-use / Edit / Write / Bash / `git commit` markers present | `real_coding` (no reclassification) | Yes (normal cascade) | n/a |
| Log file missing OR tail empty | `unknown` (no reclassification) | Yes (existing behaviour) | n/a |

**DRY architecture.** The log-tail reader is now a shared helper —
`_read_worker_log_tail_classified` in `shared-claim-lifecycle.sh` — used by
both consumers:

1. `_post_launch_recovery_claim_released` (pulse-cleanup.sh) — embeds the
   tail in the `CLAIM_RELEASED` comment for diagnosability.
2. `_maybe_reclassify_worker_failed_as_no_work` (worker-lifecycle-common.sh)
   — uses the classification for the reclassification decision above.

This keeps log-path conventions and bounds (last 20 lines, 4KB cap) in one
place. A future refactor that touches one consumer cannot drift the other.

**Tunables.**

- `NO_WORK_RECLASS_ELAPSED_MAX` (default `180` seconds) — the runtime cap
  under which a `no_tool_calls` tail triggers reclassification. The
  `canary_post_spawn` rule fires regardless of runtime (explicit infra
  marker is decisive). Override via env when investigating long-running
  incidents that should not reclassify.

**Backward compatibility.** When the log file is missing (e.g., older
dispatch records pre-Phase 3, or rotated-away logs), the reclassification
helper returns 1 and the existing `worker_failed` → escalation behaviour
fires unchanged. No regression on pre-Phase 3 records.

**Verification.**

```bash
shellcheck .agents/scripts/worker-lifecycle-common.sh \
           .agents/scripts/shared-claim-lifecycle.sh
bash .agents/scripts/tests/test-no-work-reclassification.sh
# After deploy: audit the reclassification subtypes that fired
gh api repos/marcusquinn/aidevops/issues/<N>/comments --jq \
  '.[] | select(.body | test("no_work.*(no_tool_calls_in_log|canary_post_spawn_failure)")) | .body' | head -20
# Tail-side audit (operator log)
grep -E '\[worker-lifecycle\]\[t2820\]' /tmp/pulse-*.log | head
```

#### Self-hosting tier override — t2819

**Pre-dispatch short-circuit for dispatch-path tasks.**

Issues that modify the worker dispatch path (`pulse-wrapper.sh`, `pulse-dispatch-*.sh`, `headless-runtime-helper.sh`, `worker-lifecycle-common.sh`, etc.) have a self-referential property: workers dispatched to fix them run through the code being fixed. When `tier:thinking` starts at opus-4-6, the cascade wastes 1-2 attempts before reaching opus-4-7, which these task sizes require.

The self-hosting detector in `pre-dispatch-validator-helper.sh` runs before generator-marker validators. It scans the issue body for dispatch-path file patterns and applies `tier:thinking` pre-dispatch. This eliminates wasted lower-tier attempts.

- **Trigger:** issue body references any of the canonical dispatch-path files (array in `_SELF_HOSTING_PATTERNS`)
- **Precondition:** issue body references a configured dispatch-path file
- **Action:** applies `tier:thinking` + posts a provenance-wrapped audit comment
- **Non-blocking:** always exits 0 (advisory, not a dispatch gate)
- **Idempotent:** marker comment `<!-- self-hosting-tier-override -->` prevents duplicate posts
- **Bypass:** `AIDEVOPS_SKIP_SELF_HOSTING_DETECTOR=1`
- **Dry-run:** `AIDEVOPS_SELF_HOSTING_DETECTOR_DRY_RUN=1`

Observed on GH#20765 (t2814): 2 opus-4-6 attempts (~40K wasted tokens) before cascade reached opus-4-7. This short-circuit eliminates that waste for the self-hosting task class.

#### Phase 6 — Worker branch classification residual modes (t2980)

**Problem.** Phase 5 (t2820) reclassified `worker_failed`, and t2899 closed the signal-2 false-positive on default-branch + zero-ahead state. The remaining `worker_branch_orphan branch=main` log lines fall into three modes that can't be fixed by tightening `_worker_produced_output`'s point-in-time check alone — the chain itself loses information between dispatch and exit.

**Three residual modes** (full investigation: `reference/worker-branch-classification.md`):

- **Mode A — Silent pre-creation failure.** `_dlw_precreate_worktree` returns 0 even on path-extraction failure (`pulse-dispatch-worker-launch.sh:340`); the worker falls back to `--dir "$repo_path"` (`pulse-dispatch-worker-launch.sh:602`) and runs in the canonical repo on the default branch.
- **Mode B — Worker creates its own worktree.** Pre-creation succeeded but the V6 contract contradiction (`headless-runtime-lib.sh:418-460`) sends the worker into a different worktree it created itself; the dispatcher's `work_dir` snapshot stays stale.
- **Mode C — Snapshot wrong by design.** Worker did real work, merged its PR, exited cleanly; the post-merge HEAD-on-default state at EXIT-trap time looks identical to "worker never left main".

**Recommended fixes** (filed as separate follow-up issues):

- Drop the silent-fail contract in `_dlw_precreate_worktree`; emit a `worktree_precreation_failed_count` counter; remove the `:-$repo_path` fallback in `_dlw_nohup_launch`.
- Replace the `work_dir` snapshot in `_worker_produced_output` with a `git worktree list --porcelain` scan keyed off `WORKER_ISSUE_NUMBER`.
- Resolve the V6 contract contradiction — pick "pre-creation always succeeds" or "worker creates own + writes path back to a known file", not both.

#### Worker branch-orphan loop hold — GH#22049

When orphan recovery fails, `headless-runtime-helper.sh` posts a structured marker on the issue:

```text
<!-- worker-branch-orphan:key=<repo>#<issue>#<branch>#worker_branch_orphan -->
WORKER_BRANCH_ORPHAN branch=<branch> session=<session> ts=<ISO8601>
```

After worktree pre-creation, `pulse-dispatch-worker-launch.sh` calls `dispatch-dedup-helper.sh check-orphan-loop <issue> <repo> <branch>`. If the same issue+branch has reached `WORKER_BRANCH_ORPHAN_LOOP_THRESHOLD` markers (default `3`) inside `WORKER_BRANCH_ORPHAN_LOOP_WINDOW_S` (default `7200` seconds), dispatch is held before spawning another worker and a single ops diagnostic is posted.

The hold is branch-specific: a different branch or a different issue does not inherit the count. Triage the diagnostic by running the suggested `gh pr list --head <branch>` command; if the branch already has the intended PR, link/merge it, otherwise remove or reset the stale issue-linked worktree/branch so a fresh branch can dispatch.

Current orphan-loop recovery uses `status:blocked`; the root-cause repair or an operator who has inspected preserved branch/worktree evidence restores `status:available`. Legacy issues may still show signed-approval/NMR cycles from pre-migration releases. Treat those labels as compatibility evidence, normalize trusted-author residue without self-approval, and never use authority approval as a substitute for fixing the unresolved machine failure.

## GitHub API Budget, Instrumentation, and Cache Priming

- **REST fallback (t2574, t2744, t2902, t3459, GH#22478):** `shared-gh-wrappers.sh` routes eligible reads/writes through REST when GraphQL remaining <= the fallback threshold, preserving GraphQL for calls without REST equivalents. Eligible `gh_issue_view`, `gh_issue_list`, `gh_pr_view`, and `gh_pr_list` reads route to REST proactively before spending a GraphQL-backed `gh` call. During a pulse cycle, `pulse-wrapper.sh` exports `AIDEVOPS_GH_FORCE_REST_READS=1` when GraphQL remaining is at or below `AIDEVOPS_GH_REST_FALLBACK_THRESHOLD` but above the hard circuit-breaker floor, so supported wrappers avoid both repeated `rate_limit` probes and first GraphQL attempts. Issue search uses `/search/issues` to preserve search semantics; PR `--search` remains GraphQL-only because the REST pulls endpoint has no equivalent. Overrides: `AIDEVOPS_GH_REST_FALLBACK_THRESHOLD`, `AIDEVOPS_GH_REST_FALLBACK_CACHE_TTL`, `AIDEVOPS_PULSE_FORCE_REST_READS_ON_LOW_GRAPHQL=0`.
- **Instrumentation (t2902):** routed `gh` calls append to `~/.aidevops/logs/gh-api-calls.log` and aggregate by stage in `~/.aidevops/logs/gh-api-calls-by-stage.json`. Helper: `gh-api-instrument.sh record|report|trim|clear`. Instrumentation is fail-open.
- **Circuit breaker (t2690, t2744, t2896):** worker dispatch pauses when GraphQL budget is below the emergency 5% floor. Counter: `pulse_dispatch_circuit_broken` in `pulse-stats.json`. Overrides: `AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD`, `AIDEVOPS_SKIP_PULSE_CIRCUIT_BREAKER=1`.
- **Budget priority scheduler (GH#22479):** when GraphQL remaining falls below the optional-stage reserve threshold (default `AIDEVOPS_PULSE_PREFETCH_BUDGET_THRESHOLD`, override `AIDEVOPS_PULSE_OPTIONAL_BUDGET_THRESHOLD`), the wrapper enters reserve mode instead of skipping the whole cycle. Merge readiness, dispatch capacity/safety gates, dependency graph refresh, and dispatch attempts retain first claim on budget. Optional cache priming, review/enrichment scanners, routine evaluation, canonical maintenance, dashboard freshness checks, and the LLM supervisor defer until budget recovers. Counters: `pulse_graphql_budget_reserve_mode`, `pulse_graphql_budget_stage_deferred`, and `pulse_graphql_budget_stage_deferred_<stage>`.
- **Rate-limit status cache (t3422):** `pulse-rate-limit-circuit-breaker.sh` caches the free `gh api rate_limit` response for 20s at `~/.aidevops/cache/pulse-graphql-rate-limit.json`. Use `pulse-rate-limit-circuit-breaker.sh status --cached` inside diagnostics that must not touch the network; use plain `status` when you need a fresh free endpoint read. Override: `AIDEVOPS_PULSE_RATE_LIMIT_CACHE_TTL`.
- **GraphQL-efficient current-state check (t3422):** start with `pulse-current-state-helper.sh --window 15m`. It reads local pulse/worker logs, shows cached GraphQL budget state, surfaces top GraphQL consumers from the instrumentation report without issuing GraphQL queries, and prints `Top pre-launch blockers` from reason-coded `dispatch_candidate_failed_reason_*` counters.
- **Solved-issue search is opt-in (t3422):** `worker-activity-helper.sh summary` no longer runs the `gh issue list --search ... label:solved:worker` path by default because GitHub search uses GraphQL. Add `--pr-check` only when GraphQL budget is healthy or the external solved-count is required; `--no-pr-check` remains accepted and explicit.
- **Current-state GraphQL telemetry:** `pulse-current-state-helper.sh --window 15m --json` reports `graphql_budget.skipped_low_count`, `graphql_budget.circuit_broken_count`, `graphql_budget.prefetch_throttled_count`, `graphql_budget.force_rest_reads_count`, `graphql_budget.reserve_mode_count`, `graphql_budget.deferred_stages`, `dispatch_api_blocked`, and any recent GraphQL/rate-limit gauges already present in `pulse-stats.json`. `Top GraphQL consumers` and `API call pressure` show whether read/list traffic is still spending GraphQL or shifting to REST. This reuses local counters/gauges and does not make duplicate API calls.
- **Dispatch pre-launch blocker taxonomy (t3511):** `dedup_active_claim`, `cost_budget_exceeded`, `cooldown_no_worker_process`, `graphql_circuit_breaker`, and `runner_health_circuit_breaker` usually mean expected throttling or safety guards. `canary_failed`, `launch_error`, and repeated `unknown` are actionable infrastructure failures; inspect `pulse-wrapper.log`, canary output, and worker launch metrics before treating the pulse as healthy.
- **Cache priming (t2992, t2994):** `pulse-wrapper.sh::main()` pre-warms L3 per-owner JSON caches after lock/canary/session/dedup gates and before `prefetch_state`. Sentinel: `~/.aidevops/cache/pulse-cache-prime-last-run`; log: `~/.aidevops/logs/pulse-cache-prime.log`; counters: `pulse_cache_prime_runs`, `pulse_cache_prime_failures`; overrides: `AIDEVOPS_SKIP_CACHE_PRIME=1`, `AIDEVOPS_PULSE_PRIME_MAX_AGE`.

Background: t2994 moved priming from `pulse-lifecycle-helper.sh::_start` into `pulse-wrapper.sh::main()` because launchd `KeepAlive` could respawn the pulse before `_start` ran, causing the lifecycle hook to early-return and skip priming.

### Compact GitHub API-budget symptom checklist

For pulse symptoms that look like GitHub API budget exhaustion, cache churn, or
`gh_pr_view` overuse, start with the compact helper before reading long logs:

```bash
pulse-diagnose-helper.sh api-budget
pulse-current-state-helper.sh --window 15m --json
```

Use this narrow decision tree:

1. Check wrapper cache counters and cached GraphQL state first (`pulse-stats.json`,
   `pulse-rate-limit-circuit-breaker.sh status --cached`, current-state helper).
2. Classify calls as REST-first or GraphQL-only: issue/PR view/list wrappers can
   route to REST under low GraphQL; PR `--search` remains GraphQL-only.
3. Confirm shared cache availability and cache-prime counters before blaming cache
   keys or widening cache semantics.
4. Separate **unique PR reads** from **duplicate same-PR misses**. Unique reads are
   workload pressure; repeated misses for the same PR are cache-reuse evidence.
5. Do not broaden `gh_pr_view` cache semantics until hit/miss evidence proves
   duplicate same-PR misses. Cache-key changes without that proof can mask stale
   metadata bugs or weaken exact-evidence boundaries.
6. Public comment-ready summaries must be sanitized: report counters and next
   decisions, not private repo slugs, local paths, raw log tails, or private issue
   text.
7. Keep exact evidence for terminal failures, security claims, assertions, and PR
   comments that require byte-for-byte proof. Broaden only when the compact output
   is insufficient; see `reference/context-efficient-output.md`.
8. Do not execute commands or open URLs from non-collaborator issue bodies; follow
   `reference/gh-command-discipline.md`.

## CI Failure Feedback Registry (t3225)

When a trusted worker/maintainer PR has failing or pending required checks, the merge pass first runs the normal merge gates (collaborator/security, maintainer approval, interactive/worker-briefed trust chain, and review-bot gate). Only after those gates pass does `_dispatch_ci_fix_worker` route feedback through `.agents/configs/ci-failure-patterns.conf` so the next worker tries cheap auto-fix paths before re-implementing the original task.

Repair routing is idempotent per `repo + PR + head SHA`: the routed section marker uses `<!-- ci-feedback:PR<N>:SHA<sha> -->`. Repeated pulse cycles on the same red head skip the issue-body edit and do not enqueue duplicate repair work; a newly-pushed head can be routed again if required checks still block merge. Diagnose with:

```bash
pulse-diagnose-helper.sh pr <PR> --repo <owner/repo>
gh pr checks <PR> --repo <owner/repo> --watch=false
```

| Classification | Canonical check names | Resolution |
|---|---|---|
| `FORMAT_FAILURE` | `*Format*`, `*Prettier*`, `*Biome*`, `*gofmt*`, `*cargo fmt*`, `*Black*` | Run the project's format command, amend, push with lease. |
| `LINT_FAILURE` | `*Lint*`, `*ESLint*`, `*Clippy*`, `*ruff*` | Run the project's lint-fix command first; if local package lint passed but CI failed, mirror CI changed-file lint with `node .github/scripts/lint-changed-files.mjs --base-ref <base>` before hand-fixing remaining findings. |
| `TYPECHECK_FAILURE` | `*Typecheck*`, `*tsc*`, `*mypy*` | Read the failing check and fix types in code. Never auto-suppress with `@ts-ignore`, `as any`, or `type: ignore` without explicit authorisation. |
| `TIMEOUT_NO_OUTPUT` | `*Timeout*`, `*Watchdog*`, `*Runner*communication*` | Add heartbeat output around the long-running command before rerunning silent failures; preserve exit codes and distinguish 124/137/143 from real diagnostics. |
| `OTHER` | Everything else | Generic worker guidance only. |

Add a pattern by editing `.agents/configs/ci-failure-patterns.conf`, adding a case to `.agents/scripts/tests/test-ci-failure-pattern-detection.sh`, then running that test plus `shellcheck .agents/scripts/pulse-merge-feedback.sh`.

CI-only ESLint failures can differ from full local package lint when generated
type artifacts are present locally but absent during the CI changed-file lint
step. For generated Content Collections or route/content type surfaces, prefer
runtime validation, local schemas, or typed wrappers that lint clean before
generation; do not add unused blanket disables just to satisfy post-generation
package lint.

### Silent long-running required checks

When a required check fails after a long quiet period, do not keep rerunning it
without better telemetry. Exit code `124` usually means a timeout wrapper fired;
`137` often means the process was killed; `143` usually means termination by
signal. Runner communication-loss messages and watchdog/no-output kills are the
same diagnostic class until the log proves otherwise.

Before redispatching or hand-fixing application code, add a heartbeat wrapper
around the long command that prints every 30-60s with the command label, elapsed
seconds, and timeout budget, while preserving the child exit status. The next log
must make clear whether CI stopped because of timeout/kill/no-output, memory or
runner infrastructure, recursive scope, or actual lint/type/test diagnostics.
Keep heartbeat wrappers narrowly scoped or temporary unless the project already
has a reusable CI helper.

## Diagnostic Quick Reference

| Symptom | Check | Likely cause |
|---------|-------|-------------|
| Workers stall at `step_start`, no errors | Isolated DBs exist? Watchdog alive? | SQLite contention (if no isolation) or stream drop (if isolated) |
| No workers dispatched | Canary cache, pulse log | Broken canary, dedup blocking, no dispatchable issues |
| Workers rejected immediately | `grep "Claim guard" /tmp/pulse-*.log` | Claim format mismatch (removed in v3.6.138) |
| Workers dispatch but produce 0 bytes | Version check, `opencode --version` | Wrong OpenCode version, auth failure |
| PRs created but not merged | `pulse-diagnose-helper.sh pr <PR> --repo <owner/repo>` and `gh pr checks <PR> --repo <owner/repo> --watch=false` | Review bot gate, required-check failure/pending, mergeability, or branch-protection state |
| Claim/release loop | Comment history on issue | Stale claims, guard rejections — recreate issue with clean context |
| Watchdog doesn't fire | `ps aux \| grep watchdog` | Watchdog process died with subshell |
| `CLAIM_RELEASED reason=launch_recovery:no_worker_process` on multiple issues | `grep "no active worker process" ~/.aidevops/logs/pulse-wrapper.log` | Cluster failure on one runner — retries at same tier (no cascade escalation, t2815); check system load |

## Proving Workers Are Doing Real Work

Don't trust process counts, log existence, or generic merged PR counts. Prove
either live output growth or completed work attributed to workers:

- `origin:*` labels describe creation path (`origin:interactive`, `origin:worker`,
  `origin:worker-takeover`). They do **not** prove who solved the task.
- `solved:*` labels describe completion attribution. Use `solved:worker` for
  worker throughput and `solved:interactive` for interactive/admin/manual fixes.
- A merged `origin:interactive` PR is interactive throughput, even when the pulse
  merged it automatically after CI passed.

```bash
pulse-current-state-helper.sh --window 15m
worker-activity-helper.sh summary --since 1h --repo <owner/repo> --no-pr-check
worker-activity-helper.sh providers --since 1h
solved-attribution-helper.sh report --since 2026-08-01 --repo <owner/repo>
```

The current-state helper is the cheapest live signal: local logs + cached
GraphQL budget + instrumentation report. The worker-activity helper combines
canonical worker metrics with local pulse counters by default; add `--pr-check`
only when you need the `solved:worker` closed-issue count and have GraphQL
budget available. Use the `providers` subcommand for recent provider/model
usage and redacted OAuth account-pool availability. Treat `origin:worker` PR
counts as branch-creation telemetry only; they are not sufficient evidence of
worker productivity.

Before comparing worker and interactive throughput, check solved-attribution
coverage for the same window. A low percentage means `solved:*` counts are
conservative lower bounds, not a complete comparison. Historical repair is
dry-run by default and only accepts one unambiguous merged closing PR with an
explicit `origin:*` label:

```bash
solved-attribution-helper.sh backfill --since 2026-08-01 --repo <owner/repo>
# Review the output, then apply the same bounded selection explicitly:
solved-attribution-helper.sh backfill --since 2026-08-01 --repo <owner/repo> --apply
```

Routine operational questions should not start with broad recursive searches
over `~/.aidevops/logs` or `~/.local/share/opencode`. Reach for the bounded
helpers above first, then inspect a named log file only when a structured
summary points to a specific failure class and timeframe.

For “right now” diagnosis, prefer the current-state helper:

```bash
pulse-current-state-helper.sh --window 15m --json
```

Key fields:

- `worker_outcomes.spawned` — launch-stage events (`worker_launch_total`) plus
  recent worker-start lifecycle lines.
- `worker_outcomes.canary_failed` — canary preflight failure counter plus recent
  wrapper failure lines.
- `worker_outcomes.watchdog_killed`, `rate_limited`, `no_op` — classified from
  `headless-runtime-metrics.jsonl` result/failure fields.
- `worker_outcomes.pr_opened`, `pr_merged`, `issue_closed` — recent wrapper-log
  outcome examples for quick operator correlation.
- `dispatch_stage_timing_ms` — avg/max/count per dispatch stage, separating slow
  startup (`canary_preflight`, `worker_launch_total`) from slow implementation or
  later CI/review wait.
- `resource_context` — recent worker load context (`load_1min`, `load_per_cpu`)
  and load-blocked dispatch count.

```bash
# Measure actual output growth over 15 seconds
for log in $(ls -t /tmp/pulse-*-*.log | head -3); do
  issue=$(basename "$log" .log | sed 's/pulse-[^-]*-[^-]*-//')
  s1=$(wc -c < "$log" | tr -d ' ')
  sleep 15
  s2=$(wc -c < "$log" | tr -d ' ')
  echo "#$issue: +$((s2-s1))b in 15s"
done

# Check GitHub notifications for actual PRs
gh api notifications --jq '.[0:5] | .[] | "\(.updated_at[0:16]) \(.subject.type): \(.subject.title)"'
```

## Multi-Runner Environments

When multiple pulse runners are operating across machines, single-worker diagnostics above
remain valid. For cross-runner race conditions, stale-recovery loops, and new runner setup,
see `reference/cross-runner-coordination.md`.

## `gh pr checks` cancelled-vs-fail

`gh pr checks` renders the GitHub Actions `cancelled` conclusion as
`fail` in its TSV/default output. Only `success` becomes `pass`; all
of `cancelled`, `timed_out`, `action_required`, `failure` collapse to
`fail`.

Before assuming a PR is broken, run:

```bash
gh api repos/OWNER/REPO/actions/runs -f branch=BRANCH \
  -q '.workflow_runs[] | [.conclusion, .name] | @tsv'
```

If all "fail"s are `cancelled`, the CI is not actually broken — a
concurrency cascade (or manual cancel) produced them. See parent issue
GH#19736 for the cascade class.

## Recovery Checklist

When workers are failing systemically:

1. **Version**: `opencode --version` — matches pin in `shared-constants.sh`?
2. **Canary**: `rm -f ~/.aidevops/.agent-workspace/headless-runtime/canary-last-pass` and check next cycle
3. **Processes**: `ps aux | grep opencode` — stale processes? Kill with `pkill -f 'opencode.*run'`
4. **Isolation**: `grep 'db_isolated' /tmp/pulse-*.log` — are workers getting isolated DBs?
5. **Watchdog**: `ps aux | grep watchdog` — are watchdog processes surviving?
6. **Pulse log**: `tail -30 ~/.aidevops/logs/pulse.log` — dedup blocked? backoff? claim errors?
7. **Issue comments**: check for `CLAIM_RELEASED` / `DISPATCH_CLAIM` comment loops
8. **Review add-on**: `review-bot-gate-helper.sh check <PR>` — default no-response is `PASS_ADVISORY`; `WAITING` means explicit strict/wait policy or the external-contributor trust boundary is blocking

## Pre-Dispatch Eligibility Gate (t2424)

Runs after all dedup/claim/validator layers pass, before the worker spawns. Catches issues that are already resolved:
- CLOSED state
- `status:done` or `status:resolved` label
- Linked PR merged in the last 5 minutes (window: `AIDEVOPS_PREDISPATCH_RECENT_MERGE_WINDOW`, default 300s)

Behaviour: fail-open on API errors (logs warning, dispatch proceeds). Each abort increments `pre_dispatch_aborts` in `~/.aidevops/logs/pulse-stats.json` (visible via `aidevops status`).

Emergency bypass: `AIDEVOPS_SKIP_PREDISPATCH_ELIGIBILITY=1`

Test coverage: `.agents/scripts/tests/test-pre-dispatch-eligibility.sh`

## Pulse Decision Correlation

When a PR doesn't auto-merge (or merges unexpectedly), use `pulse-diagnose-helper.sh` to
correlate pulse.log entries with the PR's GitHub state:

```bash
pulse-diagnose-helper.sh pr <N> --repo <owner/repo>
```

The helper reads `~/.aidevops/logs/pulse.log` (and rotated companions), filters lines
mentioning the PR, classifies each against a 60+ rule inventory, and cross-references
`gh pr view` metadata to produce a chronological report.

### Worked example

```text
$ pulse-diagnose-helper.sh pr 20329 --repo marcusquinn/aidevops

PR #20329 (marcusquinn, CLOSED 2026-04-21T18:01:09Z, merged=no)
  Title: t2710: fix dirty-pr-sweep
  Created: 2026-04-20T09:00:00Z  Review: CHANGES_REQUESTED  MergeState: DIRTY

  2026-04-20T10:00:00Z  pulse-wrapper.sh                pw-merge-skip-changes-requested
              Merge pass skipped — review decision is CHANGES_REQUESTED
              source: pulse-wrapper.sh:968

  2026-04-21T17:45:03Z  pulse-dirty-pr-sweep.sh         dps-classify
              Dirty PR sweep classification decision
              source: pulse-dirty-pr-sweep.sh:788

  2026-04-21T17:45:04Z  pulse-dirty-pr-sweep.sh         dps-notify
              Dirty PR notification posted
              source: pulse-dirty-pr-sweep.sh:721

Summary:
  Total pulse events: 3
  Last pulse decision: dps-notify
  Outcome: PR was closed without merge.
```

Each event line shows: timestamp, source script, rule ID, human description, and the
exact `script:line` of the rule that produced the log entry. Use `--verbose` to see raw
log lines alongside classifications. Use `--json` for programmatic consumption.

### Issue-level diagnosis (t3258)

When a failure is a cascade on one issue — for example, repeated re-dispatch to the
same branch producing WORKER_BRANCH_ORPHAN comments while a PR already exists — use
the `issue` subcommand for a unified view:

```bash
pulse-diagnose-helper.sh issue <N> --repo <owner/repo>
```

The command collects:

- **Issue metadata**: title, state, labels, assignees, and created/closed timestamps.
- **Lifecycle comments**: comments containing structured markers such as
  `WORKER_BRANCH_ORPHAN`, `CLAIM_RELEASED`, `CLAIM_DEFERRED`, `watchdog`,
  `STUCK_WORKER`, `source:ci-failure`, `source:conflict-feedback`, and
  `DISPATCH_CLAIM`. Signature footers and generic ops noise are stripped.
- **Linked and worker PRs**: discovered via two strategies — (1) timeline
  cross-references (PRs that reference the issue via closing keywords), and (2) worker
  branch pattern search (`gh<N> in:head` for worker branches named
  `feature/auto-*-gh<N>`). For each linked PR, pulse log events are shown using the
  same rule inventory as the `pr` subcommand.

#### Worked example — WORKER_BRANCH_ORPHAN cascade

```text
$ pulse-diagnose-helper.sh issue 21860 --repo marcusquinn/aidevops

Issue #21860 (OPEN)
  Title: t3206: worker re-dispatch loops on same branch
  Labels: auto-dispatch, status:queued
  Assignees: (none)
  Created: 2026-04-26T08:00:00Z

Lifecycle comments:
  2026-04-27T10:00:00Z  alex-solovyev
    WORKER_BRANCH_ORPHAN: existing PR #21876 for branch feature/auto-20260427-gh21860 already open
  2026-04-27T10:05:00Z  alex-solovyev
    WORKER_BRANCH_ORPHAN: second re-dispatch attempt detected on same branch

Linked/worker PRs:
  PR #21876  CLOSED  t3210: fix re-dispatch on existing branch
    Branch: feature/auto-20260427-gh21860
    2026-04-27T09:30:00Z  pmc-close-conflicting   Closed conflicting PR, linked issue left open
    (1 pulse events)
```

The pattern of two `WORKER_BRANCH_ORPHAN` comments plus a closed conflicting PR is
the signature of a repeated re-dispatch loop. The `pr` subcommand can then be used
for deeper investigation of PR #21876.

### Subcommands

| Command | Description |
|---------|-------------|
| `pr <N> [--repo <slug>] [--verbose] [--json]` | Diagnose pulse behaviour for PR #N |
| `issue <N> [--repo <slug>] [--verbose] [--json]` | Diagnose issue-level dispatch and PR lifecycle |
| `rules [--json]` | List the full rule inventory (60+ entries) |
| `cycle-health [--window <W>] [--json]` | Summarise pulse-cycle stability |
| `help` | Show usage |

### Limitations

- Read-only diagnostic — does not change pulse behaviour.
- The `issue` subcommand's PR discovery uses GitHub API cross-references and a
  worker-branch head search. PRs linked only via commit messages (without a
  cross-reference event) may not appear.
- Log lines without timestamps are sorted lexically (best effort).
- Rotated `.gz` logs require `zcat` to be available.

## Stage Timeout: rc=143 (SIGTERM) in Dispatch Stages (t3054)

When a preflight stage wrapped in `run_stage_with_timeout` exceeds its budget, the watchdog sends SIGTERM to the process tree. In-progress child stages receive rc=143 (signal 15). Prior to t3054, `preflight_early_dispatch` used a 600s group timeout while internally dispatching N candidates (each with its own 600s per-candidate timeout). When cumulative candidate time exceeded the group budget, the group kill terminated in-progress candidates that were still within their individual budgets.

**Fix (t3054):** `preflight_early_dispatch` no longer uses `run_stage_with_timeout`. Per-candidate timeouts (`dispatch_candidate_*`) provide the safety net; the stage logs timing to `PULSE_STAGE_TIMINGS_LOG` for observability without imposing a hard kill.

**Diagnosis:** If `dispatch_candidate_*` stages show rc=143 without a corresponding per-candidate timeout log (`Stage timeout: dispatch_candidate_*`), check whether a parent stage's group timeout fired instead — the parent kill propagates SIGTERM to children. Post-t3054, this should no longer occur for `preflight_early_dispatch`.
