#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Wrapper Configuration -- Defaults, validation, and health counters
# =============================================================================
# All pulse-wrapper.sh configuration variables, their _validate_int validation
# calls, path constants, and per-cycle health counters. Extracted from
# pulse-wrapper.sh (GH#20781) to bring the orchestrator below the 2000-line
# file-size-debt threshold. No behavioural changes.
#
# Usage: source "${SCRIPT_DIR}/pulse-wrapper-config.sh"
#
# Dependencies:
#   - shared-constants.sh (_validate_int via worker-lifecycle-common.sh)
#   - config-helper.sh (config_get)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_WRAPPER_CONFIG_LOADED:-}" ]] && return 0
_PULSE_WRAPPER_CONFIG_LOADED=1

# Defensive SCRIPT_DIR fallback (matches issue-sync-lib.sh pattern)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

#######################################
# Configuration
#######################################
PULSE_STALE_THRESHOLD="${PULSE_STALE_THRESHOLD:-3600}"                                       # 60 min hard ceiling — workers need 10-20 min to solve issues; 15 min was killing active workers (GH#19166)
PULSE_IDLE_TIMEOUT="${PULSE_IDLE_TIMEOUT:-1800}"                                             # 30 min idle before kill — the per-worker activity watchdog (300s) is the real stall detector
PULSE_IDLE_CPU_THRESHOLD="${PULSE_IDLE_CPU_THRESHOLD:-2}"                                    # CPU% below this = idle (0-100 scale) — lowered from 5 to reduce false positives on I/O-bound work
PULSE_PROGRESS_TIMEOUT="${PULSE_PROGRESS_TIMEOUT:-1800}"                                     # 30 min no log output = stuck — was 10 min, killed workers mid-API-call
PULSE_COLD_START_TIMEOUT="${PULSE_COLD_START_TIMEOUT:-1800}"                                 # 30 min grace before first output (opencode 1.4.x cold start takes longer)
PULSE_COLD_START_TIMEOUT_UNDERFILLED="${PULSE_COLD_START_TIMEOUT_UNDERFILLED:-1200}"         # 20 min grace when below worker target
PULSE_UNDERFILLED_STALE_RECOVERY_TIMEOUT="${PULSE_UNDERFILLED_STALE_RECOVERY_TIMEOUT:-3600}" # 60 min stale-process cutoff when worker pool is underfilled — was 15 min, same problem as PULSE_STALE_THRESHOLD
PULSE_ACTIVE_REFILL_INTERVAL="${PULSE_ACTIVE_REFILL_INTERVAL:-120}"                          # Min seconds between wrapper-side refill attempts during an active pulse
PULSE_ACTIVE_REFILL_IDLE_MIN="${PULSE_ACTIVE_REFILL_IDLE_MIN:-60}"                           # Idle seconds before wrapper-side refill may intervene during monitoring sleep
PULSE_ACTIVE_REFILL_STALL_MIN="${PULSE_ACTIVE_REFILL_STALL_MIN:-120}"                        # Progress stall seconds before wrapper-side refill may intervene during an active pulse
ORPHAN_MAX_AGE="${ORPHAN_MAX_AGE:-7200}"                                                     # 2 hours — kill orphans older than this
ORPHAN_WORKTREE_GRACE_SECS="${ORPHAN_WORKTREE_GRACE_SECS:-1800}"                             # 30 min grace for 0-commit worktrees with no open PR (t1884)
RAM_PER_WORKER_MB="${RAM_PER_WORKER_MB:-512}"                                                # 512 MB per worker (opencode headless is lightweight)
RAM_RESERVE_MB="${RAM_RESERVE_MB:-6144}"                                                     # 6 GB reserved for OS + user apps
# Compute sensible default cap from total RAM (not free RAM — that's volatile).
# Formula: (total_ram_mb - reserve) / ram_per_worker, clamped to [4, 64].
# This replaces the old static default of 8 which silently throttled capable machines (t1532).
# t2950: ceiling raised 32→64; on a 64GB runner (64*1024-6144)/512=116 workers fit physically — old clamp left >70% headroom unused.
MAX_WORKERS_CAP_FLOOR=4
MAX_WORKERS_CAP_CEILING=64                                                                           # t2950: raised from 32; modern 64GB+ runners support far more concurrency
_default_cap=8
if [[ "$(uname)" == "Darwin" ]]; then
	_total_mb=$(sysctl -n hw.memsize 2>/dev/null | awk '{printf "%d", $1/1048576}')
elif [[ -f /proc/meminfo ]]; then
	_total_mb=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo 2>/dev/null)
fi
if [[ "${_total_mb:-0}" -gt 0 ]]; then
	_default_cap=$(((_total_mb - RAM_RESERVE_MB) / RAM_PER_WORKER_MB))
	[[ "$_default_cap" -lt "$MAX_WORKERS_CAP_FLOOR" ]] && _default_cap="$MAX_WORKERS_CAP_FLOOR"
	[[ "$_default_cap" -gt "$MAX_WORKERS_CAP_CEILING" ]] && _default_cap="$MAX_WORKERS_CAP_CEILING"
fi
MAX_WORKERS_CAP="${MAX_WORKERS_CAP:-$(config_get "orchestration.max_workers_cap" "$_default_cap")}"     # Derived from total RAM; override via config or env
VAULT_DEVICE_HELPER="${VAULT_DEVICE_HELPER:-${SCRIPT_DIR}/vault-device-helper.sh}"                         # Non-secret Vault fleet status helper; schedulers may call can-dispatch for Vault-sensitive work
VAULT_DEVICE_DISPATCH_PREFLIGHT="${VAULT_DEVICE_DISPATCH_PREFLIGHT:-0}"                                    # 0=disabled until task metadata requires Vault routing; 1=consult local heartbeat/trust state
VAULT_DEVICE_DISPATCH_NEEDS_UNLOCKED="${VAULT_DEVICE_DISPATCH_NEEDS_UNLOCKED:-0}"                          # 1=Vault-sensitive work requires a fresh unlocked heartbeat before local dispatch
export VAULT_DEVICE_HELPER VAULT_DEVICE_DISPATCH_PREFLIGHT VAULT_DEVICE_DISPATCH_NEEDS_UNLOCKED
DAILY_PR_CAP="${DAILY_PR_CAP:-1000}"                                                                    # Max PRs created per repo per day (GH#3821)
PRODUCT_RESERVATION_PCT="${PRODUCT_RESERVATION_PCT:-60}"                                                # % of worker slots reserved for product repos (t1423)
QUALITY_DEBT_CAP_PCT="${QUALITY_DEBT_CAP_PCT:-$(config_get "orchestration.quality_debt_cap_pct" "30")}" # % cap for quality-debt dispatch share
_pulse_legacy_model_config_files() {
	local primary_file="${HOME}/.config/aidevops/credentials.sh"
	local tenant_dir="${HOME}/.config/aidevops/tenants"
	local tenant_file=""

	if [[ -f "$primary_file" ]]; then
		printf '%s\n' "$primary_file"
	fi

	if [[ -d "$tenant_dir" ]]; then
		while IFS= read -r -d '' tenant_file; do
			printf '%s\n' "$tenant_file"
		done < <(find "$tenant_dir" -name "credentials.sh" -print0 2>/dev/null)
	fi

	return 0
}

_pulse_file_has_active_legacy_model_var() {
	local file="$1"
	local var_name="$2"

	case "$var_name" in
		PULSE_MODEL | AIDEVOPS_HEADLESS_MODELS) ;;
		*) return 1 ;;
	esac

	[[ -f "$file" ]] || return 1
	grep -qE "^[[:space:]]*(export[[:space:]]+)?${var_name}=" "$file" 2>/dev/null
	return $?
}

_pulse_warn_if_legacy_model_var_from_credentials() {
	local var_name="$1"
	local var_value="$2"
	local config_file=""
	local matches=""

	[[ -n "$var_value" ]] || return 0

	while IFS= read -r config_file; do
		if _pulse_file_has_active_legacy_model_var "$config_file" "$var_name"; then
			if [[ -n "$matches" ]]; then
				matches="${matches}, ${config_file}"
			else
				matches="$config_file"
			fi
		fi
	done < <(_pulse_legacy_model_config_files)

	[[ -n "$matches" ]] || return 0
	printf '[pulse-wrapper] WARN: %s env var is deprecated (v3.7+). Model routing is now automatic via routing table + availability checks. Remove or comment this export in: %s\n' \
		"$var_name" "$matches" >&2
	return 0
}

# GH#17769: PULSE_MODEL and AIDEVOPS_HEADLESS_MODELS are deprecated.
# Model routing is now derived from the routing table at runtime and resolved
# through model-availability-helper.sh so pulse follows the same provider
# fallback logic as workers. Warn only when a currently sourced user credentials
# file still contains the active legacy setting; inherited stale process env
# alone is not actionable and caused noisy merge-routine logs (GH#24373).
MODEL_AVAILABILITY_HELPER="${MODEL_AVAILABILITY_HELPER:-${SCRIPT_DIR}/model-availability-helper.sh}"
_pulse_warn_if_legacy_model_var_from_credentials "PULSE_MODEL" "${PULSE_MODEL:-}"
_pulse_warn_if_legacy_model_var_from_credentials "AIDEVOPS_HEADLESS_MODELS" "${AIDEVOPS_HEADLESS_MODELS:-}"
if [[ -z "${PULSE_MODEL:-}" ]] && [[ -x "$MODEL_AVAILABILITY_HELPER" ]]; then
	PULSE_MODEL=$("$MODEL_AVAILABILITY_HELPER" resolve standard --quiet 2>/dev/null || true)
fi
# Absolute fallback if routing resolution fails entirely.
PULSE_MODEL="${PULSE_MODEL:-anthropic/claude-sonnet-4-6}"
PULSE_BACKFILL_MAX_ATTEMPTS="${PULSE_BACKFILL_MAX_ATTEMPTS:-3}"                                            # Additional pulse passes when below utilization target (t1453)
PULSE_LAUNCH_GRACE_SECONDS="${PULSE_LAUNCH_GRACE_SECONDS:-35}"                                             # Max grace window for worker process to appear after dispatch (t1453) — raised from 20s to 35s: sandbox-exec + opencode cold-start takes ~25-30s
PULSE_LAUNCH_SETTLE_BATCH_MAX="${PULSE_LAUNCH_SETTLE_BATCH_MAX:-5}"                                        # Dispatch count at which the full PULSE_LAUNCH_GRACE_SECONDS wait applies (t1887)
PRE_RUN_STAGE_TIMEOUT="${PRE_RUN_STAGE_TIMEOUT:-600}"                                                      # 10 min cap per pre-run stage (cleanup/prefetch)
PULSE_STAGE_TIMINGS_LOG="${PULSE_STAGE_TIMINGS_LOG:-${HOME}/.aidevops/logs/pulse-stage-timings.log}"       # Structured TSV stage timing log (GH#20025)
PULSE_LOCK_MAX_AGE_S="${AIDEVOPS_PULSE_LOCK_MAX_AGE_S:-1800}"                                              # Force-reclaim mkdir lock after this age in seconds (GH#20025)
PULSE_MIN_INTERVAL_S="${AIDEVOPS_PULSE_MIN_INTERVAL_S:-90}"                                                # Entry-point rate-limit: skip cycle if last run was less than this many seconds ago (GH#20578)
PULSE_PREFETCH_PR_LIMIT="${PULSE_PREFETCH_PR_LIMIT:-200}"                                                  # Open PR list window per repo for pre-fetched state
PULSE_PREFETCH_ISSUE_LIMIT="${PULSE_PREFETCH_ISSUE_LIMIT:-200}"                                            # Open issue list window for pulse prompt payload (keep compact)
PULSE_PREFETCH_CACHE_FILE="${PULSE_PREFETCH_CACHE_FILE:-${HOME}/.aidevops/logs/pulse-prefetch-cache.json}" # Delta prefetch state cache (GH#15286)
PULSE_RATE_LIMIT_FLAG="${PULSE_RATE_LIMIT_FLAG:-${HOME}/.aidevops/logs/pulse-graphql-rate-limited.flag}"   # GH#18979: set by prefetch on detected GraphQL rate-limit exhaustion; checked by _preflight_prefetch_and_scope to abort cycle cleanly
# Source canonical circuit-breaker threshold from conf file (GH#20638, t2768).
# Env var takes precedence; conf supplies the default; 0.30 is the hardcoded fallback
# if the conf file is missing (graceful degradation).
_PULSE_RL_CONF="${SCRIPT_DIR}/../configs/pulse-rate-limit.conf"
if [[ -z "${AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD+x}" ]] && [[ -f "$_PULSE_RL_CONF" ]]; then
	# shellcheck disable=SC1090
	source "$_PULSE_RL_CONF"
fi
AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD="${AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD:-0.30}"              # t2690/t2768: canonical default in .agents/configs/pulse-rate-limit.conf. Set to 0 to disable.
export AIDEVOPS_PULSE_CIRCUIT_BREAKER_THRESHOLD
# t2770/GH#20640: cross-issue no_work rate circuit breaker thresholds.
# Conf file (sourced above) sets NO_WORK_WINDOW_SECS/NO_WORK_WINDOW_MAX if not already in env.
# Triple-expansion: env var override > conf file value > hardcoded default.
NO_WORK_WINDOW_SECS="${AIDEVOPS_NO_WORK_WINDOW_SECS:-${NO_WORK_WINDOW_SECS:-600}}"    # Rolling window in seconds (default 10 min)
NO_WORK_WINDOW_MAX="${AIDEVOPS_NO_WORK_WINDOW_MAX:-${NO_WORK_WINDOW_MAX:-10}}"         # Max no_work events in window before trip
PULSE_PREFETCH_FULL_SWEEP_INTERVAL="${PULSE_PREFETCH_FULL_SWEEP_INTERVAL:-14400}"                          # Full sweep interval in seconds (default 4h) (GH#15286, GH#18979: reduced from 24h to prevent stale-cache drift on active repos)
PULSE_RUNNABLE_PR_LIMIT="${PULSE_RUNNABLE_PR_LIMIT:-200}"                                                  # Open PR sample size for runnable-candidate counting
PULSE_RUNNABLE_ISSUE_LIMIT="${PULSE_RUNNABLE_ISSUE_LIMIT:-1000}"                                           # Open issue sample size for runnable-candidate counting
PULSE_DISPATCH_AGE_BONUS_PER_DAY="${PULSE_DISPATCH_AGE_BONUS_PER_DAY:-25}"                                 # Fairness boost per full day an eligible issue has waited
PULSE_DISPATCH_AGE_BONUS_CAP="${PULSE_DISPATCH_AGE_BONUS_CAP:-900}"                                        # Keep age below the 1000-point major priority step
AIDEVOPS_PULSE_CAMPAIGN_SHADOW_ENABLED="${AIDEVOPS_PULSE_CAMPAIGN_SHADOW_ENABLED:-0}"                      # GH#27939: default-off repository campaign projection; legacy dispatch remains authoritative
PULSE_CAMPAIGN_HORIZON="${AIDEVOPS_PULSE_CAMPAIGN_HORIZON:-10}"                                           # Oldest-ready issues retained in the campaign frontier
PULSE_CAMPAIGN_CHECKPOINT_TTL_SECONDS="${AIDEVOPS_PULSE_CAMPAIGN_CHECKPOINT_TTL_SECONDS:-3600}"             # Renewable local projection lifetime
PULSE_CAMPAIGN_TIMEOUT_SECONDS="${AIDEVOPS_PULSE_CAMPAIGN_TIMEOUT_SECONDS:-5}"                              # Diagnostic planner timeout; failure falls back to legacy JSON
PULSE_QUEUED_SCAN_LIMIT="${PULSE_QUEUED_SCAN_LIMIT:-1000}"                                                 # Queued/in-progress scan window per repo
UNDERFILL_RECYCLE_DEFICIT_MIN_PCT="${UNDERFILL_RECYCLE_DEFICIT_MIN_PCT:-25}"                               # Run worker recycler when underfill reaches this threshold
UNDERFILL_RECYCLE_THROTTLE_SECS="${UNDERFILL_RECYCLE_THROTTLE_SECS:-300}"                                  # Min seconds between recycler runs when candidates are scarce (t1885)
UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD="${UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD:-3}"                # Candidate count at or below which throttle applies (t1885)
UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT="${UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT:-75}"                         # Deficit % at or above which throttle is bypassed (t1885)
PULSE_PR_BACKLOG_HEAVY_THRESHOLD="${PULSE_PR_BACKLOG_HEAVY_THRESHOLD:-100}"                                # Stronger PR-first mode when open backlog reaches this size
PULSE_PR_BACKLOG_CRITICAL_THRESHOLD="${PULSE_PR_BACKLOG_CRITICAL_THRESHOLD:-175}"                          # Merge-first mode when open backlog becomes severe
PULSE_READY_PR_MERGE_HEAVY_THRESHOLD="${PULSE_READY_PR_MERGE_HEAVY_THRESHOLD:-10}"                         # Merge-first when enough PRs are ready immediately
PULSE_FAILING_PR_HEAVY_THRESHOLD="${PULSE_FAILING_PR_HEAVY_THRESHOLD:-25}"                                 # PR-first when failing/review-blocked queue is large
GH_FAILURE_PREFETCH_HOURS="${GH_FAILURE_PREFETCH_HOURS:-24}"                                               # Window for failed-notification mining summary
GH_FAILURE_PREFETCH_LIMIT="${GH_FAILURE_PREFETCH_LIMIT:-100}"                                              # Notification page size for failed-notification mining
GH_FAILURE_SYSTEMIC_THRESHOLD="${GH_FAILURE_SYSTEMIC_THRESHOLD:-3}"                                        # Cluster threshold for systemic-failure flag
GH_FAILURE_MAX_RUN_LOGS="${GH_FAILURE_MAX_RUN_LOGS:-6}"                                                    # Max failed workflow runs to sample for signatures per pulse
FOSS_SCAN_TIMEOUT="${FOSS_SCAN_TIMEOUT:-30}"                                                               # Timeout for FOSS contribution scan prefetch (t1702)
FOSS_MAX_DISPATCH_PER_CYCLE="${FOSS_MAX_DISPATCH_PER_CYCLE:-2}"                                            # Max FOSS contribution workers per pulse cycle (t1702)
PULSE_TRIAGE_BUDGET_PER_CYCLE="${PULSE_TRIAGE_BUDGET_PER_CYCLE:-2}"                                        # Independent synchronous triage attempts per cycle; never consumes implementation slots
PULSE_TRIAGE_KNOWN_CONTRIBUTORS="${PULSE_TRIAGE_KNOWN_CONTRIBUTORS:-$(config_get "orchestration.triage_known_contributors" "")}" # Private CSV; review priority only, never authority
PULSE_TRIAGE_REFRESH_INTERVAL_SECONDS="${PULSE_TRIAGE_REFRESH_INTERVAL_SECONDS:-$(config_get "orchestration.triage_refresh_interval_seconds" "300")}" # Refresh stale triage state within long cycles while budget remains
PULSE_BATCH_PREFETCH_ENABLED="${PULSE_BATCH_PREFETCH_ENABLED:-1}"                                          # GH#19963: Enable batch prefetch via org-level gh search (L3 cache layer). Set to 0 for safe rollback.
PULSE_BATCH_PREFETCH_CACHE_DIR="${PULSE_BATCH_PREFETCH_CACHE_DIR:-${HOME}/.aidevops/logs/batch-prefetch}"  # GH#19963: Directory for batch prefetch per-slug cache files
PULSE_BATCH_SEARCH_LIMIT="${PULSE_BATCH_SEARCH_LIMIT:-200}"                                                # GH#19963: Max results per gh search call (Search API --limit cap)

# Per-repo activity tier classification (t2831)
#
# Classifies repos into hot/warm/cold based on rolling 7-day event count.
# Controls prefetch cadence: hot=every cycle, warm=every ~3 cycles, cold=every ~10 cycles.
# Tier cache refreshed hourly by pulse-repo-tier-classifier-routine.sh (launchd).
#
# Intervals are minimum seconds between full prefetches per tier.
# Hot (interval=0) repos are never skipped — they always get a fresh prefetch.
PULSE_TIER_CLASSIFICATION_ENABLED="${PULSE_TIER_CLASSIFICATION_ENABLED:-1}"                               # t2831: 1=enable, 0=disable tier-based cadence (rollback switch)
PULSE_TIER_HOT_INTERVAL="${PULSE_TIER_HOT_INTERVAL:-0}"                                                   # t2831: hot repos: 0=never skip (check every cycle)
PULSE_TIER_WARM_INTERVAL="${PULSE_TIER_WARM_INTERVAL:-180}"                                               # t2831: warm repos: skip if last check < 180s ago (~3 cycles at 60s base)
PULSE_TIER_COLD_INTERVAL="${PULSE_TIER_COLD_INTERVAL:-600}"                                               # t2831: cold repos: skip if last check < 600s ago (~10 cycles at 60s base)
export PULSE_TIER_CLASSIFICATION_ENABLED PULSE_TIER_HOT_INTERVAL PULSE_TIER_WARM_INTERVAL PULSE_TIER_COLD_INTERVAL

# Per-issue retry state (t1888, GH#2076, GH#17384)
#
# Cause-aware retry backoff per issue. Different failure types get
# different retry strategies:
#
#   RATE LIMIT (reason starts with "rate_limit"):
#     1. Query oauth pool — are other accounts available for this provider?
#     2. YES → retry_after = now (immediate retry on next pulse with rotated account)
#              Do NOT increment the failure counter.
#     3. NO  → retry_after = earliest account recovery time from pool cooldowns.
#              Increment counter (all accounts exhausted = genuine capacity failure).
#
#   NON-RATE-LIMIT (crash, context overflow, local_error, etc.):
#     1. Exponential backoff: FAST_FAIL_INITIAL_BACKOFF_SECS doubled each failure.
#     2. Cap at FAST_FAIL_MAX_BACKOFF_SECS (7 days).
#     3. retry_after = now + backoff_seconds.
#     4. Counter increments. At ESCALATION_FAILURE_THRESHOLD → cascade escalation
#        (tier:simple → tier:standard → tier:thinking).
#
# State file format:
#   { "slug/number": {
#       "count": N,           # consecutive non-rate-limit failures
#       "ts": epoch,          # last update timestamp
#       "reason": "...",      # last failure reason
#       "retry_after": epoch, # earliest next dispatch time (0 = immediate)
#       "backoff_secs": N     # current backoff interval (doubles each failure)
#   }}
#
# The dispatch check (fast_fail_is_skipped) returns "skip" when:
#   - retry_after is in the future, OR
#   - count >= FAST_FAIL_SKIP_THRESHOLD (hard stop regardless of retry_after)
#
# All functions are best-effort — failures are logged but never fatal.
FAST_FAIL_SKIP_THRESHOLD="${FAST_FAIL_SKIP_THRESHOLD:-5}"               # Hard stop after N non-rate-limit failures
FAST_FAIL_EXPIRY_SECS="${FAST_FAIL_EXPIRY_SECS:-604800}"                # 7-day expiry (matches max backoff)
FAST_FAIL_INITIAL_BACKOFF_SECS="${FAST_FAIL_INITIAL_BACKOFF_SECS:-600}" # 10 min initial backoff
FAST_FAIL_MAX_BACKOFF_SECS="${FAST_FAIL_MAX_BACKOFF_SECS:-604800}"      # 7-day max backoff
FAST_FAIL_AGE_OUT_SECONDS="${FAST_FAIL_AGE_OUT_SECONDS:-86400}"         # Auto-reset HARD STOP after 24h quiet period (t2397)
FAST_FAIL_AGE_OUT_MIN_COUNT="${FAST_FAIL_AGE_OUT_MIN_COUNT:-5}"         # Only age-out issues at/above HARD STOP threshold (t2397)
FAST_FAIL_AGE_OUT_MAX_RESETS="${FAST_FAIL_AGE_OUT_MAX_RESETS:-3}"       # Max auto-resets before NMR escalation (t2397)

EVER_NMR_CACHE_FILE="${EVER_NMR_CACHE_FILE:-${HOME}/.aidevops/.agent-workspace/supervisor/ever-nmr-cache.json}"
EVER_NMR_NEGATIVE_CACHE_TTL_SECS="${EVER_NMR_NEGATIVE_CACHE_TTL_SECS:-300}" # Recheck negative results after 5 min

# Process guard limits (t1398)
CHILD_RSS_LIMIT_KB="${CHILD_RSS_LIMIT_KB:-2097152}"           # 2 GB default — kill child if RSS exceeds this
CHILD_RUNTIME_LIMIT="${CHILD_RUNTIME_LIMIT:-1800}"            # 30 min default — raised from 10 min (GH#2958, quality scans need time)
SHELLCHECK_RSS_LIMIT_KB="${SHELLCHECK_RSS_LIMIT_KB:-1048576}" # 1 GB — ShellCheck-specific (lower due to exponential expansion)
SHELLCHECK_RUNTIME_LIMIT="${SHELLCHECK_RUNTIME_LIMIT:-300}"   # 5 min — ShellCheck-specific
SESSION_COUNT_WARN="${SESSION_COUNT_WARN:-5}"                 # Warn when >N concurrent sessions detected
# GH#20681: Per-session watchdog stall caps passed to headless-runtime-helper.sh workers.
WORKER_STALL_CONTINUE_MAX="${WORKER_STALL_CONTINUE_MAX:-3}"        # max stall-continue events before hard-kill
WORKER_STALL_CUMULATIVE_MAX_S="${WORKER_STALL_CUMULATIVE_MAX_S:-1800}" # max cumulative stall time (s)

# Validate numeric configuration (uses _validate_int from worker-lifecycle-common.sh)
PULSE_STALE_THRESHOLD=$(_validate_int PULSE_STALE_THRESHOLD "$PULSE_STALE_THRESHOLD" 3600)
PULSE_IDLE_TIMEOUT=$(_validate_int PULSE_IDLE_TIMEOUT "$PULSE_IDLE_TIMEOUT" 300 60)
PULSE_IDLE_CPU_THRESHOLD=$(_validate_int PULSE_IDLE_CPU_THRESHOLD "$PULSE_IDLE_CPU_THRESHOLD" 5)
PULSE_PROGRESS_TIMEOUT=$(_validate_int PULSE_PROGRESS_TIMEOUT "$PULSE_PROGRESS_TIMEOUT" 600 120)
PULSE_COLD_START_TIMEOUT=$(_validate_int PULSE_COLD_START_TIMEOUT "$PULSE_COLD_START_TIMEOUT" 1200 300)
PULSE_COLD_START_TIMEOUT_UNDERFILLED=$(_validate_int PULSE_COLD_START_TIMEOUT_UNDERFILLED "$PULSE_COLD_START_TIMEOUT_UNDERFILLED" 600 120)
PULSE_UNDERFILLED_STALE_RECOVERY_TIMEOUT=$(_validate_int PULSE_UNDERFILLED_STALE_RECOVERY_TIMEOUT "$PULSE_UNDERFILLED_STALE_RECOVERY_TIMEOUT" 900 300)
ORPHAN_MAX_AGE=$(_validate_int ORPHAN_MAX_AGE "$ORPHAN_MAX_AGE" 7200)
ORPHAN_WORKTREE_GRACE_SECS=$(_validate_int ORPHAN_WORKTREE_GRACE_SECS "$ORPHAN_WORKTREE_GRACE_SECS" 1800 60)
RAM_PER_WORKER_MB=$(_validate_int RAM_PER_WORKER_MB "$RAM_PER_WORKER_MB" 512 1)
RAM_RESERVE_MB=$(_validate_int RAM_RESERVE_MB "$RAM_RESERVE_MB" 6144)
MAX_WORKERS_CAP=$(_validate_int MAX_WORKERS_CAP "$MAX_WORKERS_CAP" "${_default_cap:-8}")
DAILY_PR_CAP=$(_validate_int DAILY_PR_CAP "$DAILY_PR_CAP" 5 1)
PRODUCT_RESERVATION_PCT=$(_validate_int PRODUCT_RESERVATION_PCT "$PRODUCT_RESERVATION_PCT" 60 0)
QUALITY_DEBT_CAP_PCT=$(_validate_int QUALITY_DEBT_CAP_PCT "$QUALITY_DEBT_CAP_PCT" 30 0)
if [[ "$QUALITY_DEBT_CAP_PCT" -gt 100 ]]; then
	QUALITY_DEBT_CAP_PCT=100
fi
PULSE_BACKFILL_MAX_ATTEMPTS=$(_validate_int PULSE_BACKFILL_MAX_ATTEMPTS "$PULSE_BACKFILL_MAX_ATTEMPTS" 3 0)
PULSE_LAUNCH_GRACE_SECONDS=$(_validate_int PULSE_LAUNCH_GRACE_SECONDS "$PULSE_LAUNCH_GRACE_SECONDS" 35 5)
PULSE_LAUNCH_SETTLE_BATCH_MAX=$(_validate_int PULSE_LAUNCH_SETTLE_BATCH_MAX "$PULSE_LAUNCH_SETTLE_BATCH_MAX" 5 1)
PRE_RUN_STAGE_TIMEOUT=$(_validate_int PRE_RUN_STAGE_TIMEOUT "$PRE_RUN_STAGE_TIMEOUT" 600 30)
PULSE_PREFETCH_PR_LIMIT=$(_validate_int PULSE_PREFETCH_PR_LIMIT "$PULSE_PREFETCH_PR_LIMIT" 200 1)
PULSE_PREFETCH_ISSUE_LIMIT=$(_validate_int PULSE_PREFETCH_ISSUE_LIMIT "$PULSE_PREFETCH_ISSUE_LIMIT" 200 1)
PULSE_RUNNABLE_PR_LIMIT=$(_validate_int PULSE_RUNNABLE_PR_LIMIT "$PULSE_RUNNABLE_PR_LIMIT" 200 1)
PULSE_RUNNABLE_ISSUE_LIMIT=$(_validate_int PULSE_RUNNABLE_ISSUE_LIMIT "$PULSE_RUNNABLE_ISSUE_LIMIT" 1000 1)
PULSE_DISPATCH_AGE_BONUS_PER_DAY=$(_validate_int PULSE_DISPATCH_AGE_BONUS_PER_DAY "$PULSE_DISPATCH_AGE_BONUS_PER_DAY" 25 0)
PULSE_DISPATCH_AGE_BONUS_CAP=$(_validate_int PULSE_DISPATCH_AGE_BONUS_CAP "$PULSE_DISPATCH_AGE_BONUS_CAP" 900 0)
case "$AIDEVOPS_PULSE_CAMPAIGN_SHADOW_ENABLED" in
1 | true | TRUE | yes | YES | on | ON) AIDEVOPS_PULSE_CAMPAIGN_SHADOW_ENABLED=1 ;;
*) AIDEVOPS_PULSE_CAMPAIGN_SHADOW_ENABLED=0 ;;
esac
PULSE_CAMPAIGN_HORIZON=$(_validate_int PULSE_CAMPAIGN_HORIZON "$PULSE_CAMPAIGN_HORIZON" 10 1)
if [[ "$PULSE_CAMPAIGN_HORIZON" -gt 100 ]]; then
	PULSE_CAMPAIGN_HORIZON=100
fi
PULSE_CAMPAIGN_CHECKPOINT_TTL_SECONDS=$(_validate_int PULSE_CAMPAIGN_CHECKPOINT_TTL_SECONDS "$PULSE_CAMPAIGN_CHECKPOINT_TTL_SECONDS" 3600 60)
PULSE_CAMPAIGN_TIMEOUT_SECONDS=$(_validate_int PULSE_CAMPAIGN_TIMEOUT_SECONDS "$PULSE_CAMPAIGN_TIMEOUT_SECONDS" 5 1)
PULSE_QUEUED_SCAN_LIMIT=$(_validate_int PULSE_QUEUED_SCAN_LIMIT "$PULSE_QUEUED_SCAN_LIMIT" 1000 1)
UNDERFILL_RECYCLE_DEFICIT_MIN_PCT=$(_validate_int UNDERFILL_RECYCLE_DEFICIT_MIN_PCT "$UNDERFILL_RECYCLE_DEFICIT_MIN_PCT" 25 1)
if [[ "$UNDERFILL_RECYCLE_DEFICIT_MIN_PCT" -gt 100 ]]; then
	UNDERFILL_RECYCLE_DEFICIT_MIN_PCT=100
fi
UNDERFILL_RECYCLE_THROTTLE_SECS=$(_validate_int UNDERFILL_RECYCLE_THROTTLE_SECS "$UNDERFILL_RECYCLE_THROTTLE_SECS" 300 0)
UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD=$(_validate_int UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD "$UNDERFILL_RECYCLE_LOW_CANDIDATE_THRESHOLD" 3 0)
UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT=$(_validate_int UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT "$UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT" 75 1)
if [[ "$UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT" -gt 100 ]]; then
	UNDERFILL_RECYCLE_SEVERE_DEFICIT_PCT=100
fi
PULSE_PR_BACKLOG_HEAVY_THRESHOLD=$(_validate_int PULSE_PR_BACKLOG_HEAVY_THRESHOLD "$PULSE_PR_BACKLOG_HEAVY_THRESHOLD" 100 1)
PULSE_PR_BACKLOG_CRITICAL_THRESHOLD=$(_validate_int PULSE_PR_BACKLOG_CRITICAL_THRESHOLD "$PULSE_PR_BACKLOG_CRITICAL_THRESHOLD" 175 1)
PULSE_READY_PR_MERGE_HEAVY_THRESHOLD=$(_validate_int PULSE_READY_PR_MERGE_HEAVY_THRESHOLD "$PULSE_READY_PR_MERGE_HEAVY_THRESHOLD" 10 1)
PULSE_FAILING_PR_HEAVY_THRESHOLD=$(_validate_int PULSE_FAILING_PR_HEAVY_THRESHOLD "$PULSE_FAILING_PR_HEAVY_THRESHOLD" 25 1)
if [[ "$PULSE_PR_BACKLOG_CRITICAL_THRESHOLD" -lt "$PULSE_PR_BACKLOG_HEAVY_THRESHOLD" ]]; then
	PULSE_PR_BACKLOG_CRITICAL_THRESHOLD="$PULSE_PR_BACKLOG_HEAVY_THRESHOLD"
fi
GH_FAILURE_PREFETCH_HOURS=$(_validate_int GH_FAILURE_PREFETCH_HOURS "$GH_FAILURE_PREFETCH_HOURS" 24 1)
GH_FAILURE_PREFETCH_LIMIT=$(_validate_int GH_FAILURE_PREFETCH_LIMIT "$GH_FAILURE_PREFETCH_LIMIT" 100 1)
GH_FAILURE_SYSTEMIC_THRESHOLD=$(_validate_int GH_FAILURE_SYSTEMIC_THRESHOLD "$GH_FAILURE_SYSTEMIC_THRESHOLD" 3 1)
GH_FAILURE_MAX_RUN_LOGS=$(_validate_int GH_FAILURE_MAX_RUN_LOGS "$GH_FAILURE_MAX_RUN_LOGS" 6 0)
FOSS_SCAN_TIMEOUT=$(_validate_int FOSS_SCAN_TIMEOUT "$FOSS_SCAN_TIMEOUT" 30 5)
FOSS_MAX_DISPATCH_PER_CYCLE=$(_validate_int FOSS_MAX_DISPATCH_PER_CYCLE "$FOSS_MAX_DISPATCH_PER_CYCLE" 2 0)
PULSE_TRIAGE_BUDGET_PER_CYCLE=$(_validate_int PULSE_TRIAGE_BUDGET_PER_CYCLE "$PULSE_TRIAGE_BUDGET_PER_CYCLE" 2 0)
PULSE_TRIAGE_REFRESH_INTERVAL_SECONDS=$(_validate_int PULSE_TRIAGE_REFRESH_INTERVAL_SECONDS "$PULSE_TRIAGE_REFRESH_INTERVAL_SECONDS" 300 30)
PULSE_TRIAGE_KNOWN_CONTRIBUTORS=$(printf '%s' "$PULSE_TRIAGE_KNOWN_CONTRIBUTORS" | tr -d '[:space:]')
case "$PULSE_TRIAGE_KNOWN_CONTRIBUTORS" in
*[!A-Za-z0-9,-]*)
	echo "[pulse-wrapper] Invalid private triage contributor priority configuration — ignoring value" >>"$LOGFILE"
	PULSE_TRIAGE_KNOWN_CONTRIBUTORS=""
	;;
esac
PULSE_PREFETCH_FULL_SWEEP_INTERVAL=$(_validate_int PULSE_PREFETCH_FULL_SWEEP_INTERVAL "$PULSE_PREFETCH_FULL_SWEEP_INTERVAL" 86400 60)
CHILD_RSS_LIMIT_KB=$(_validate_int CHILD_RSS_LIMIT_KB "$CHILD_RSS_LIMIT_KB" 2097152 1)
CHILD_RUNTIME_LIMIT=$(_validate_int CHILD_RUNTIME_LIMIT "$CHILD_RUNTIME_LIMIT" 1800 1)
SHELLCHECK_RSS_LIMIT_KB=$(_validate_int SHELLCHECK_RSS_LIMIT_KB "$SHELLCHECK_RSS_LIMIT_KB" 1048576 1)
SHELLCHECK_RUNTIME_LIMIT=$(_validate_int SHELLCHECK_RUNTIME_LIMIT "$SHELLCHECK_RUNTIME_LIMIT" 300 1)
SESSION_COUNT_WARN=$(_validate_int SESSION_COUNT_WARN "$SESSION_COUNT_WARN" 5 1)
EVER_NMR_NEGATIVE_CACHE_TTL_SECS=$(_validate_int EVER_NMR_NEGATIVE_CACHE_TTL_SECS "$EVER_NMR_NEGATIVE_CACHE_TTL_SECS" 300 0)
# GH#20681: Per-session stall caps validated here so pulse exports sane values to workers.
WORKER_STALL_CONTINUE_MAX=$(_validate_int WORKER_STALL_CONTINUE_MAX "$WORKER_STALL_CONTINUE_MAX" 3 1)
WORKER_STALL_CUMULATIVE_MAX_S=$(_validate_int WORKER_STALL_CUMULATIVE_MAX_S "$WORKER_STALL_CUMULATIVE_MAX_S" 1800 60)
export WORKER_STALL_CONTINUE_MAX WORKER_STALL_CUMULATIVE_MAX_S

# _sanitize_markdown and _sanitize_log_field provided by worker-lifecycle-common.sh

PIDFILE="${HOME}/.aidevops/logs/pulse.pid"
LOCKDIR="${HOME}/.aidevops/logs/pulse-wrapper.lockdir"
# GH#18264: tracks whether this process successfully acquired the instance lock.
# release_instance_lock() checks this flag so it only removes LOCKDIR when
# this process actually owns the lock.
_LOCK_OWNED=false
LOGFILE="${HOME}/.aidevops/logs/pulse.log"
WRAPPER_LOGFILE="${HOME}/.aidevops/logs/pulse-wrapper.log"
SESSION_FLAG="${HOME}/.aidevops/logs/pulse-session.flag"
STOP_FLAG="${HOME}/.aidevops/logs/pulse-session.stop"
OPENCODE_BIN="${OPENCODE_BIN:-$(command -v opencode 2>/dev/null || echo "opencode")}"
# PULSE_DIR: working directory for the supervisor pulse session.
# Defaults to a neutral workspace path so pulse sessions are not associated
# with any specific managed repo in the host app's session database.
# Previously defaulted to ~/Git/aidevops, which caused 155+ orphaned sessions
# to accumulate under that project even when it had pulse:false (GH#5136).
# Override via env var if a specific directory is needed.
PULSE_DIR="${PULSE_DIR:-${HOME}/.aidevops/.agent-workspace}"
# PULSE_MODEL is derived from routing table above (GH#17769) — no longer user-configurable
HEADLESS_RUNTIME_HELPER="${HEADLESS_RUNTIME_HELPER:-${SCRIPT_DIR}/headless-runtime-helper.sh}"
MODEL_AVAILABILITY_HELPER="${MODEL_AVAILABILITY_HELPER:-${SCRIPT_DIR}/model-availability-helper.sh}"
REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"
STATE_FILE="${HOME}/.aidevops/logs/pulse-state.txt"
QUEUE_METRICS_FILE="${HOME}/.aidevops/logs/pulse-queue-metrics"
SCOPE_FILE="${HOME}/.aidevops/logs/pulse-scope-repos"
COMPLEXITY_SCAN_LAST_RUN="${HOME}/.aidevops/logs/complexity-scan-last-run"
COMPLEXITY_SCAN_INTERVAL="${COMPLEXITY_SCAN_INTERVAL:-900}"                       # 15 min — runs each pulse cycle, per-run cap governs throughput
COMPLEXITY_SCAN_TREE_HASH_FILE="${HOME}/.aidevops/logs/complexity-scan-tree-hash" # cached git tree hash for skip-if-unchanged
COMPLEXITY_LLM_SWEEP_LAST_RUN="${HOME}/.aidevops/logs/complexity-llm-sweep-last-run"
COMPLEXITY_LLM_SWEEP_INTERVAL="${COMPLEXITY_LLM_SWEEP_INTERVAL:-21600}"   # 6h — daily LLM sweep when debt is stalled
COMPLEXITY_DEBT_COUNT_FILE="${HOME}/.aidevops/logs/complexity-debt-count" # tracks open function-complexity-debt count for stall detection
DEDUP_CLEANUP_LAST_RUN="${HOME}/.aidevops/logs/dedup-cleanup-last-run"
DEDUP_CLEANUP_INTERVAL="${DEDUP_CLEANUP_INTERVAL:-86400}"  # 1 day in seconds
DEDUP_CLEANUP_BATCH_SIZE="${DEDUP_CLEANUP_BATCH_SIZE:-50}" # Max issues to close per run
CODERABBIT_REVIEW_LAST_RUN="${HOME}/.aidevops/logs/coderabbit-review-last-run"
CODERABBIT_REVIEW_INTERVAL="${CODERABBIT_REVIEW_INTERVAL:-86400}" # 1 day in seconds
CODERABBIT_REVIEW_ISSUE="2632"                                    # Issue where CodeRabbit full reviews are requested
POST_MERGE_SCANNER_LAST_RUN="${HOME}/.aidevops/logs/post-merge-scanner-last-run"
POST_MERGE_SCANNER_INTERVAL="${POST_MERGE_SCANNER_INTERVAL:-86400}"             # 1 day in seconds
# t2949: parent-task nudge/re-file gate thresholds (reduced from 24h/86400 to 4h/14400).
# PARENT_TASK_NUDGE_SECONDS drives SCANNER_NUDGE_AGE_HOURS and SCANNER_FRESH_PARENT_HOURS.
# PARENT_TASK_REFILE_GATE_SECONDS drives AUTO_DECOMPOSER_INTERVAL.
# Both default to 4h (14400s). Override per t2942/t2947 pattern.
PARENT_TASK_NUDGE_SECONDS="${PARENT_TASK_NUDGE_SECONDS:-14400}"            # 4h (was 86400/24h)
PARENT_TASK_REFILE_GATE_SECONDS="${PARENT_TASK_REFILE_GATE_SECONDS:-14400}" # 4h (was 86400/604800)
AUTO_DECOMPOSER_INTERVAL="${AUTO_DECOMPOSER_INTERVAL:-${PARENT_TASK_REFILE_GATE_SECONDS}}"  # 4h per-parent re-file interval (t2949; was 604800/7d since t2573, global 24h gate before t2442)
AUTO_DECOMPOSER_PARENT_STATE="${HOME}/.aidevops/logs/auto-decomposer-parent-state.json" # per-parent last-filed epochs (t2573)
COMPLEXITY_FUNC_LINE_THRESHOLD="${COMPLEXITY_FUNC_LINE_THRESHOLD:-100}"         # Functions longer than this are violations
COMPLEXITY_FILE_VIOLATION_THRESHOLD="${COMPLEXITY_FILE_VIOLATION_THRESHOLD:-1}" # Files with >= this many violations get an issue (was 5)
COMPLEXITY_MD_MIN_LINES="${COMPLEXITY_MD_MIN_LINES:-500}"                       # Agent docs shorter than this are not actionable for simplification
WORKER_WATCHDOG_HELPER="${SCRIPT_DIR}/worker-watchdog.sh"
PULSE_HEALTH_FILE="${HOME}/.aidevops/logs/pulse-health.json"
FAST_FAIL_STATE_FILE="${HOME}/.aidevops/.agent-workspace/supervisor/fast-fail-counter.json"
DEP_GRAPH_CACHE_FILE="${DEP_GRAPH_CACHE_FILE:-${HOME}/.aidevops/.agent-workspace/supervisor/dep-graph-cache.json}" # Dependency graph cache (t1935)
DEP_GRAPH_CACHE_TTL_SECS="${DEP_GRAPH_CACHE_TTL_SECS:-300}"                                                        # Rebuild graph if older than 5 min (t1935)

# Log sharding: hot/cold split + append-only cycle index (t1886)
#
# Hot log (pulse.log): active writes, capped at PULSE_LOG_HOT_MAX_BYTES.
#   When the hot log exceeds the cap, it is gzip-compressed and moved to
#   the cold archive directory before the next cycle begins. This keeps
#   the hot log small for fast tail/grep operations.
#
# Cold archive (pulse-archive/): compressed rotated logs, total size capped
#   at PULSE_LOG_COLD_MAX_BYTES. Oldest archives are pruned when the cap is
#   exceeded. Archives are named pulse-YYYYMMDD-HHMMSS.log.gz.
#
# Cycle index (pulse-cycle-index.jsonl): append-only JSONL file. One record
#   per cycle with timestamp, duration, dispatch/merge/kill counters, and
#   worker utilisation. Enables fast cycle-level analytics without parsing
#   the full log. Capped at PULSE_CYCLE_INDEX_MAX_LINES lines; oldest lines
#   are pruned when the cap is exceeded.
PULSE_LOG_HOT_MAX_BYTES="${PULSE_LOG_HOT_MAX_BYTES:-52428800}"     # 50 MB hot log cap
PULSE_LOG_COLD_MAX_BYTES="${PULSE_LOG_COLD_MAX_BYTES:-1073741824}" # 1 GB cold archive cap
PULSE_LOG_ARCHIVE_DIR="${PULSE_LOG_ARCHIVE_DIR:-${HOME}/.aidevops/logs/pulse-archive}"
PULSE_CYCLE_INDEX_FILE="${PULSE_CYCLE_INDEX_FILE:-${HOME}/.aidevops/logs/pulse-cycle-index.jsonl}"
PULSE_CYCLE_INDEX_MAX_LINES="${PULSE_CYCLE_INDEX_MAX_LINES:-10000}" # ~10k cycles ≈ ~14 days at 2-min intervals

# Per-cycle health counters — incremented by merge/cleanup/dispatch functions
# and flushed to PULSE_HEALTH_FILE by write_pulse_health_file() at cycle end.
_PULSE_HEALTH_PRS_MERGED=0
_PULSE_HEALTH_PRS_CLOSED_CONFLICTING=0
_PULSE_HEALTH_STALLED_KILLED=0
_PULSE_HEALTH_PREFETCH_ERRORS=0
_PULSE_HEALTH_IDLE_REPO_SKIPS=0 # GH#18984 (t2098): repos skipped due to cache-hit idle detection
_PULSE_HEALTH_BATCH_SEARCH_CALLS=0 # GH#19963: Search API calls made by batch prefetch
_PULSE_HEALTH_BATCH_CACHE_HITS=0   # GH#19963: per-repo batch cache hits (avoided GraphQL calls)
_PULSE_HEALTH_EVENTS_TICKLE_FRESH=0 # GH#20868 (t2830): owners skipped via L1 ETag tickle (304 hits)
_PULSE_HEALTH_EVENTS_TICKLE_STALE=0 # GH#20868 (t2830): owners that had event changes (200 responses)
_PULSE_HEALTH_PREFETCH_THROTTLED=0  # GH#21584 (t3027): cycles where prefetch was skipped due to GraphQL budget gate
_PULSE_HEALTH_IDLE_CYCLE_SKIPPED=0  # GH#21584 (t3027): cycles where idle-backoff skipped the cycle entirely
_PULSE_HEALTH_CONDITIONAL_304=0     # GH#22481: per-repo conditional REST 304 cache hits
_PULSE_HEALTH_CONDITIONAL_REFRESHES=0 # GH#22481: per-repo conditional REST refreshed caches
_PULSE_HEALTH_CONDITIONAL_MISSES=0  # GH#22481: per-repo conditional REST requests without ETags

# t2433/GH#20071: Cycle-scoped repo refresh sentinel.
# Keyed by repo_path; set to "1" once the repo has been pulled this cycle.
# Prevents multiple git fetch+pull calls for the same repo within one
# dispatch cycle (dispatch loop + triage re-evaluation can both touch the
# same repo). Bash 4+ associative array — safe because shared-constants.sh
# re-execs this script under modern bash when invoked with bash 3.2.
declare -A _PULSE_REFRESHED_THIS_CYCLE=()

# Validate complexity scan configuration (defined above, validated here)
COMPLEXITY_SCAN_INTERVAL=$(_validate_int COMPLEXITY_SCAN_INTERVAL "$COMPLEXITY_SCAN_INTERVAL" 900 300)
COMPLEXITY_LLM_SWEEP_INTERVAL=$(_validate_int COMPLEXITY_LLM_SWEEP_INTERVAL "$COMPLEXITY_LLM_SWEEP_INTERVAL" 21600 3600)
COMPLEXITY_FUNC_LINE_THRESHOLD=$(_validate_int COMPLEXITY_FUNC_LINE_THRESHOLD "$COMPLEXITY_FUNC_LINE_THRESHOLD" 100 50)
COMPLEXITY_FILE_VIOLATION_THRESHOLD=$(_validate_int COMPLEXITY_FILE_VIOLATION_THRESHOLD "$COMPLEXITY_FILE_VIOLATION_THRESHOLD" 1 1)
COMPLEXITY_MD_MIN_LINES=$(_validate_int COMPLEXITY_MD_MIN_LINES "$COMPLEXITY_MD_MIN_LINES" 500 10)
CODERABBIT_REVIEW_INTERVAL=$(_validate_int CODERABBIT_REVIEW_INTERVAL "$CODERABBIT_REVIEW_INTERVAL" 86400 3600)
POST_MERGE_SCANNER_INTERVAL=$(_validate_int POST_MERGE_SCANNER_INTERVAL "$POST_MERGE_SCANNER_INTERVAL" 86400 3600)
AUTO_DECOMPOSER_INTERVAL=$(_validate_int AUTO_DECOMPOSER_INTERVAL "$AUTO_DECOMPOSER_INTERVAL" 14400 3600)
FAST_FAIL_SKIP_THRESHOLD=$(_validate_int FAST_FAIL_SKIP_THRESHOLD "$FAST_FAIL_SKIP_THRESHOLD" 5 1)
FAST_FAIL_EXPIRY_SECS=$(_validate_int FAST_FAIL_EXPIRY_SECS "$FAST_FAIL_EXPIRY_SECS" 604800 60)
FAST_FAIL_INITIAL_BACKOFF_SECS=$(_validate_int FAST_FAIL_INITIAL_BACKOFF_SECS "$FAST_FAIL_INITIAL_BACKOFF_SECS" 600 60)
FAST_FAIL_MAX_BACKOFF_SECS=$(_validate_int FAST_FAIL_MAX_BACKOFF_SECS "$FAST_FAIL_MAX_BACKOFF_SECS" 604800 600)
FAST_FAIL_AGE_OUT_SECONDS=$(_validate_int FAST_FAIL_AGE_OUT_SECONDS "$FAST_FAIL_AGE_OUT_SECONDS" 86400 3600)
FAST_FAIL_AGE_OUT_MIN_COUNT=$(_validate_int FAST_FAIL_AGE_OUT_MIN_COUNT "$FAST_FAIL_AGE_OUT_MIN_COUNT" 5 1)
FAST_FAIL_AGE_OUT_MAX_RESETS=$(_validate_int FAST_FAIL_AGE_OUT_MAX_RESETS "$FAST_FAIL_AGE_OUT_MAX_RESETS" 3 1)

# Validate log sharding configuration (t1886)
PULSE_LOG_HOT_MAX_BYTES=$(_validate_int PULSE_LOG_HOT_MAX_BYTES "$PULSE_LOG_HOT_MAX_BYTES" 52428800 1048576)
PULSE_LOG_COLD_MAX_BYTES=$(_validate_int PULSE_LOG_COLD_MAX_BYTES "$PULSE_LOG_COLD_MAX_BYTES" 1073741824 10485760)
PULSE_CYCLE_INDEX_MAX_LINES=$(_validate_int PULSE_CYCLE_INDEX_MAX_LINES "$PULSE_CYCLE_INDEX_MAX_LINES" 10000 100)
