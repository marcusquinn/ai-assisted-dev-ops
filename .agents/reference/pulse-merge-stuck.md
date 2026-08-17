<!-- SPDX-License-Identifier: MIT -->
<!-- SPDX-FileCopyrightText: 2025-2026 Marcus Quinn -->

# Stuck-merge detector and zero-progress circuit breaker (t3193, t3211, GH#21895, GH#21942)

The pulse merge pass historically had two narrow nudges (rebase reminders for
`origin:interactive` PRs in conflict, fix-worker dispatch for `origin:worker`
PRs in conflict) but no general detector for PRs that pass `APPROVED +
MERGEABLE` yet sit unmerged for hours. The 2026-04-30 incident in a managed
private webapp repo — 8 PRs stuck 9-29h, six sharing identical Setup-step CI
failures — is the canonical case this module addresses.

A second 2026-04-30 incident exposed a complementary failure mode: a
runner-queue saturation event (110 queued workflow runs / 3 in-progress on
`marcusquinn/aidevops`) left several PRs with `Maintainer Gate` checks
permanently in `QUEUED` state. The detector previously misclassified these
as `STUCK_OTHER` (the QUEUED state is not a FAILURE so the rollup gate did
not fire) and would have escalated each PR individually. t3211 adds the
`STUCK_RUNNER_QUEUE_SATURATION` classification + meta-issue routing so a
runner outage produces ONE investigation issue with operator-grade context,
not N noisy per-PR escalations against a cause the PR author cannot fix.

## What it does

Once per pulse cycle (~120s), per repo, after the deterministic merge pass:

1. **Classifies** every open PR that is `APPROVED + MERGEABLE + !draft +
   !hold-for-review` and idle past `AIDEVOPS_MERGE_STUCK_AGE_MINUTES` (default
   240 = 4h) into one of six classes — see "Classifications" below.
2. **Counts** stuck PRs into the `pulse_merge_eligible_stuck_pr_count` gauge.
3. **Escalates per-PR** with a single worker-ready comment on the linked
   issue (or PR if no linked issue), keyed off the
   `<!-- merge-stuck:individual -->` HTML marker so repeat cycles do not spam.
4. **Detects pattern outages** — when ≥`AIDEVOPS_MERGE_PATTERN_MIN_PRS` (default
   3) aged PRs share the same failure fingerprint (sorted set of FAILURE check
   names, hashed to 16 hex chars), files **one** investigation meta-issue per
   fingerprint dedup'd by `<!-- merge-stuck:pattern:<hash16> -->`. This
   diagnostic set includes worker-owned `CHANGES_REQUESTED` PRs without making
   them eligible for individual escalation or merge.
5. **Tracks zero-progress** across all repos. If a cycle has eligible-but-
   unmerged PRs and zero merges, the `pulse_merge_zero_progress_cycles` gauge
   increments. Reaching `AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES` (default 5
   consecutive cycles ≈ 10 minutes) files a framework-level meta-issue at
   `marcusquinn/aidevops` dedup'd by `<!-- merge-stuck:zero-progress -->`.
   A successful merge in any subsequent cycle resets the gauge to 0.

## Classifications

| Class | Trigger | Action |
| --- | --- | --- |
| `STUCK_RUNNER_QUEUE_SATURATION` | Per-cycle `_check_actions_queue_saturation` reports `saturated=1` (queued > 50 AND queued/max(in_progress,1) > 10) AND the PR's rollup contains ≥1 check with `.status=QUEUED` (not yet started) | Aggregated to a SINGLE `<!-- merge-stuck:runner-queue-saturation -->` meta-issue per repo per cycle; per-PR escalations SUPPRESSED for the duration of the outage. Takes priority over `STUCK_CHECKS_FAILING` because QUEUED checks are the proximate cause; FAILURE entries during a runner outage are downstream symptoms. |
| `STUCK_CHECKS_FAILING` | ≥1 FAILURE in `statusCheckRollup`, no conflict, repo NOT saturated | Per-PR escalation |
| `STUCK_CONFLICT_NO_NUDGE_LABEL` | `mergeable=CONFLICTING` + neither `origin:interactive` nor `origin:worker` (gap in the existing rebase-nudge family) | Idempotent rebase nudge using `<!-- pulse-rebase-nudge -->` so it cannot double-fire alongside the per-label nudges |
| `STUCK_BRANCHPROTECT_404` | Default branch has no protection rules — `_check_required_checks_passing` historically failed closed (t2922) on the 404 | Counter increment only; the actual fix is in `pulse-merge-process.sh` (see "404 distinction" below) |
| `STUCK_BRANCHPROTECT_API_ERROR` | 5xx / network from the protection API | Counter increment only — transient, retry next cycle |
| `STUCK_AUTH` | 401 / "bad credentials" from any `gh` call | Counter increment only — operator action required |
| `STUCK_OTHER` | Eligible + idle but no distinct signal | Counter increment only |

Pattern-outage grouping deliberately uses a wider candidate set than the table
above. Alongside individually eligible stuck PRs, it admits aged, non-draft,
non-held PRs carrying `origin:worker` or `origin:worker-takeover` when their
review decision is `CHANGES_REQUESTED`. `_detect_pattern_outage` still requires a
terminal CI failure fingerprint and excludes per-PR review/policy-only gates.
This keeps substantive review objections blocking while allowing a shared
broken-base failure to produce one deduplicated outage issue.

## Configuration

Canonical defaults live in `.agents/configs/pulse-merge-stuck.conf`. Env vars
take precedence (set in `~/.aidevops/.env` or shell):

| Variable | Default | Purpose |
| --- | --- | --- |
| `AIDEVOPS_MERGE_STUCK_AGE_MINUTES` | `240` | Idle threshold (minutes) — only PRs idle this long are classified. |
| `AIDEVOPS_MERGE_ZERO_PROGRESS_CYCLES` | `5` | Consecutive zero-progress cycles before the framework-level meta-issue fires. |
| `AIDEVOPS_MERGE_PATTERN_MIN_PRS` | `3` | Minimum stuck PRs sharing one fingerprint before an outage meta-issue fires. |
| `AIDEVOPS_MERGE_STUCK_ENABLED` | `1` | Master kill-switch (set to `0` to disable the entire module). |
| `AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN` | `50` | Minimum absolute queued workflow runs before saturation is even considered. Set to `0` to disable saturation detection entirely (per-PR escalation behaviour for QUEUED checks reverts to pre-t3211). |
| `AIDEVOPS_ACTIONS_QUEUE_SATURATION_RATIO_MIN` | `10` | Minimum `queued / max(in_progress,1)` ratio that, combined with the absolute minimum above, classifies the repo as saturated. Both conditions must hold — either alone is a false-positive (light-load bursts hit absolute counts; healthy busy periods hit ratio with the runner pool already serving). |
| `AIDEVOPS_SKIP_ACTIONS_QUEUE_SATURATION` | unset | Emergency bypass for the per-cycle saturation probe. When `1`, the helper short-circuits to `saturated=0` without making any `gh api` call. Use only if the saturation probe itself is degrading the pulse (e.g. severe REST rate-limit pressure). |

## 404 distinction in `_check_required_checks_passing`

`pulse-merge-process.sh::_check_required_checks_passing` historically failed
closed on **any** non-zero exit from the branch-protection API call (t2922).
This silently blocked merges on repos with **no branch protection rules** —
the most common shape for personal/draft repos and the canonical `origin/main`
of every fresh aidevops-init'd repo.

t3193 tightens the failure mode: HTTP 404 (no protection) returns 0 (allow),
falling through to the actual rollup gate (`_pr_required_checks_pass`) which
already evaluates real check state. Any other failure (401, 403, 5xx, network
error) preserves the t2922 fail-closed behaviour so an auth break cannot
silently unblock a stale fork PR.

## Dedup markers

Each escalation uses an idempotent HTML marker so repeat cycles do not spam:

| Marker | Where | Lifecycle |
| --- | --- | --- |
| `<!-- merge-stuck:individual -->` | Issue (or PR) comment | One per linked issue. Survives repeat stuck cycles. A new cycle on a different stuck PR linked to the same issue will not re-fire. |
| `<!-- merge-stuck:pattern:<hash16> -->` | Outage meta-issue body | One per failure fingerprint (sorted FAILURE check names, sha256 first 16 hex chars). Different outage signatures get different issues. |
| `<!-- merge-stuck:zero-progress -->` | Framework meta-issue body | One per active streak. Reset by any successful merge. |
| `<!-- merge-stuck:runner-queue-saturation -->` | Runner-saturation meta-issue body | One per repo per saturation event. Dedup uses `gh issue list --search` against the marker so a still-saturated repo on the next cycle does not re-file. The counter `pulse_actions_queue_saturation_events` increments even on dedup-skip so operator graphs reflect the true incident count. |
| `<!-- pulse-rebase-nudge -->` | Reused from existing nudge family | Reused so `STUCK_CONFLICT_NO_NUDGE_LABEL` cannot double-fire alongside `_post_rebase_nudge_on_*`. |

## Counters added

All four are written to `~/.aidevops/logs/pulse-stats.json`:

| Counter | Type | Reset condition |
| --- | --- | --- |
| `pulse_merge_eligible_stuck_pr_count` | Gauge | Overwritten each cycle |
| `pulse_merge_zero_progress_cycles` | Gauge | Reset to 0 on any successful merge |
| `pulse_merge_branchprotect_404_skips` | Event counter | 24h rolling window (per t2424 pattern) |
| `pulse_merge_stuck_escalations_filed` | Event counter | 24h rolling window |
| `pulse_actions_queue_saturation_events` | Event counter | 24h rolling window (per t2424 pattern). Increments once per repo per cycle that classifies as saturated, including cycles where the meta-issue is dedup-suppressed. Use this to graph saturation duration; pair with `pulse_merge_stuck_escalations_filed` to see what fraction of stuck PRs the saturation suppression caught. |

The first two use the new `pulse_stats_set_gauge` / `pulse_stats_get_gauge`
functions in `pulse-stats-helper.sh` — gauges store under `.gauges.<name>`
and represent a single current value, distinct from the per-event counter
namespace.

## Suppression: pulse circuit breaker interaction

When `pulse_dispatch_circuit_broken` (the t2690 GraphQL emergency floor) has
fired in the last 24h, the zero-progress meta-issue is **suppressed** —
filing a "pulse made no progress" investigation when the circuit breaker is
already advertising its own cause would only create noise. The per-PR
escalations and pattern-outage meta-issues are NOT suppressed; they remain
useful even during a rate-limit event.

## Suppression: runner-queue saturation (t3211)

When a repo is classified as saturated (per `_check_actions_queue_saturation`
in `pulse-rate-limit-circuit-breaker.sh`), per-PR escalation is suppressed
for every PR whose stuck class is `STUCK_RUNNER_QUEUE_SATURATION`. Instead,
the matching PR numbers are aggregated into a single repo-level meta-issue
filed via `_pms_file_runner_saturation_issue`. Rationale:

- The cause is **infrastructure-side** (GitHub Actions hosted-runner
  contention or workflow-level concurrency dynamics), not anything the PR
  authors can fix on their PR. Per-PR comments would be misleading
  ("rebuild your branch" / "fix your tests" guidance is wrong here).
- N comments on N PRs all naming the same operator action ("triage Actions
  queue") wastes operator attention and PR thread space.
- The meta-issue body lists every saturation-stuck PR for that cycle, the
  operator runbook, and the verification command — a single triageable
  artifact instead of an N-tab cleanup.

Saturation detection uses an integer ratio (Bash 3.2 has no float arith);
precision floor is "ratio≥1", well below the threshold of 10. The check is
called once per cycle per repo (NOT once per PR) so REST-budget cost is
2 cheap calls per repo with `per_page=1`.

### Runbook

When the meta-issue fires, the operator triage steps are:

```bash
# 1. Confirm the saturation reading.
gh api "repos/${repo_slug}/actions/runs?status=queued&per_page=1" --jq '.total_count'
gh api "repos/${repo_slug}/actions/runs?status=in_progress&per_page=1" --jq '.total_count'

# 2. List the queued runs grouped by workflow to find the runaway pattern.
gh api "repos/${repo_slug}/actions/runs?status=queued&per_page=100" \
  --jq '[.workflow_runs[] | .name] | group_by(.) | map({workflow:.[0], queued:length}) | sort_by(-.queued)'

# 3. Cancel a runaway workflow's queued runs (one example).
gh api "repos/${repo_slug}/actions/runs?status=queued&per_page=100" \
  --json databaseId,workflowName --jq '.[] | select(.workflowName=="<runaway>") | .databaseId' \
  | xargs -I {} gh api -X POST "repos/${repo_slug}/actions/runs/{}/cancel"
```

Saturation ends when both `gh api ".../actions/runs?status=queued&per_page=1" --jq '.total_count'`
falls back below `AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN` (default 50)
**and** the `queued / in_progress` ratio falls below
`AIDEVOPS_ACTIONS_QUEUE_SATURATION_RATIO_MIN` (default 10). At that point
the next cycle classifies the repo as not-saturated, per-PR escalation
resumes for any genuinely-stuck PRs, and the saturation meta-issue can be
closed.

## Disabling

Set `AIDEVOPS_MERGE_STUCK_ENABLED=0` in your env. The module's entry point
`pulse_merge_stuck_run_pass` short-circuits on the disabled flag.

## Test surface

`.agents/scripts/tests/test-pulse-merge-stuck.sh` covers:

- conf file integrity (4 entries present)
- defaults applied as positive integers post-source
- `_pms_iso_to_epoch` round-trip + garbage rejection
- `_pms_hash_fingerprint` 16-char hex output, deterministic, distinct inputs
- separate pattern-candidate admission for worker-owned `CHANGES_REQUESTED` PRs,
  including draft, hold, ownership, and age exclusions
- `pulse_stats_set_gauge` / `pulse_stats_get_gauge` round-trip + non-numeric
  rejection + gauge isolation
- `pulse_merge_zero_progress_record` state transitions (reset on merge,
  no-op on idle, increment on stuck cycle)
- shellcheck cleanliness on the module + the stats helper

`.agents/scripts/tests/test-actions-queue-saturation.sh` covers (t3211):

- `_check_actions_queue_saturation` boundary cases against canonical incident
  shape (110q/3ip), light load, busy/healthy ratio, threshold edges,
  zero-in_progress denominator clamp
- fail-open semantics on gh-api error (rc=2, saturated=0)
- bypass + disable controls (`AIDEVOPS_SKIP_ACTIONS_QUEUE_SATURATION=1`,
  `AIDEVOPS_ACTIONS_QUEUE_SATURATION_QUEUED_MIN=0`)
- env-var threshold overrides take precedence over conf defaults
- `_classify_stuck_pr` returns `STUCK_RUNNER_QUEUE_SATURATION` when
  `is_saturated=1` AND rollup contains a QUEUED check; falls through to
  `STUCK_CHECKS_FAILING` when saturation absent and FAILURE present;
  saturation classification takes priority over FAILURE in mixed rollups
- shellcheck cleanliness on `pulse-rate-limit-circuit-breaker.sh`

The test uses a `gh` PATH shim that emulates `gh api` and `gh pr view` —
the shim respects `--jq` filters via local `jq` evaluation so the helper's
own jq pipeline behaves identically to a real-API call. Implementation
notes (avoid the same footguns when extending the test): (1) shim env vars
must be **exported** before the function call, not prefix-assigned via
`VAR=val out=$(fn)`; (2) `eval "export VAR=$value"` mangles JSON values via
brace-expansion — split on `=` and call `export "$key"="$val"` directly;
(3) `${VAR:-{}}` collides with parameter-expansion delimiters — use an
intermediate `default='{}'; "${VAR:-$default}"`; (4) source the helper
then `set +e` because `set -euo pipefail` is inherited and aborts the
test process on deliberate non-zero return codes.

Functions that require live GitHub API (`_escalate_individual_stuck_pr`,
`pulse_merge_stuck_run_pass`, `_pms_count_eligible_unmerged_for_repo`,
`_pms_file_runner_saturation_issue`) are not unit-tested — they're
integration-level and exercise live PRs each pulse cycle.

## Related

- `pulse-merge-process.sh` — the deterministic merge pass; the module hooks
  in via `merge_ready_prs_all_repos`.
- `pulse-merge-conflict.sh` — the existing per-label rebase-nudge family.
- `pulse-merge-feedback.sh` — the conflict-feedback dispatch path.
- `pulse-rate-limit-circuit-breaker.sh` — hosts `_check_actions_queue_saturation`
  (t3211); also home of the GraphQL rate-limit breaker (t2690).
- `reference/auto-merge.md` — full merge-gate semantics.
- `reference/cross-runner-coordination.md` — pulse cycle infrastructure.
- t2922 — the original fail-closed change in `_check_required_checks_passing`
  that t3193 partially tightens.
- t2690 — the pulse dispatch circuit breaker that suppresses the
  zero-progress meta-issue.
- t3193 — the parent stuck-merge detector that t3211 extends.
- t3211 / GH#21942 — runner-queue saturation classification + meta-issue
  routing (this section).
- t2574 / t2689 / t2902 — REST-fallback layers that run alongside the
  saturation check; both helpers live in the same module.
