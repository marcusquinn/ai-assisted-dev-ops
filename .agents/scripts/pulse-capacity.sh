#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-capacity.sh — Worker-slot capacity counters — target workers, runnable candidates, queued count, debug formatting.
#
# Extracted from pulse-wrapper.sh in Phase 3 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* configuration constants and mutable
# _PULSE_HEALTH_* counters in the bootstrap section.
#
# Functions in this module (in source order):
#   - get_max_workers_target
#   - count_runnable_candidates
#   - count_queued_without_worker
#   - pulse_count_debug_log
#   - normalize_count_output
#
# This is a pure move from pulse-wrapper.sh. The function bodies are
# byte-identical to their pre-extraction form. Any change must go in a
# separate follow-up PR after the full decomposition (Phase 12) lands.

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_CAPACITY_LOADED:-}" ]] && return 0
_PULSE_CAPACITY_LOADED=1

#######################################
# Get current max workers from pulse-max-workers file
# Returns: numeric value via stdout (defaults to 1)
#######################################
get_max_workers_target() {
	local max_workers_file="${HOME}/.aidevops/logs/pulse-max-workers"
	local max_workers
	max_workers=$(cat "$max_workers_file" 2>/dev/null || echo "1")
	[[ "$max_workers" =~ ^[0-9]+$ ]] || max_workers=1
	if [[ "$max_workers" -lt 1 ]]; then
		max_workers=1
	fi
	echo "$max_workers"
	return 0
}

#######################################
# Scale a decimal value by 100 for integer comparisons.
# Arguments:
#   $1 - decimal value
#   $2 - fallback decimal value
# Returns: scaled integer via stdout
#######################################
_pulse_capacity_float_scaled() {
	local float_value="${1:-0}"
	local fallback="${2:-0}"
	python3 - "$float_value" "$fallback" <<'PY'
import sys
try:
    print(int(float(sys.argv[1]) * 100))
except (ValueError, IndexError):
    print(int(float(sys.argv[2]) * 100))
PY
	return 0
}

#######################################
# Resolve the provider that should drive round capacity planning.
# Returns: provider token via stdout, or blank when unknown.
#######################################
_pulse_capacity_selected_provider() {
	local provider_override="${PULSE_DISPATCH_CAPACITY_PROVIDER:-}"
	if [[ -n "$provider_override" ]]; then
		printf '%s\n' "$provider_override"
		return 0
	fi

	local model="${PULSE_DISPATCH_CAPACITY_MODEL:-${PULSE_MODEL:-}}"
	if [[ "$model" == */* ]]; then
		printf '%s\n' "${model%%/*}"
		return 0
	fi

	printf '\n'
	return 0
}

#######################################
# Summarise provider account-pool availability without secrets.
# Arguments:
#   $1 - provider token
# Stdout: "<total> <available> <rate_limited> <auth_errors>".
#         available=-1 means no usable account-pool signal is configured.
#######################################
_pulse_capacity_provider_account_counts() {
	local provider="$1"
	local unavailable_counts='0 -1 0 0'
	local pool_file="${PULSE_DISPATCH_OAUTH_POOL_FILE:-${HOME}/.aidevops/oauth-pool.json}"
	if [[ -z "$provider" || ! -f "$pool_file" ]] || ! command -v jq >/dev/null 2>&1; then
		printf '%s\n' "$unavailable_counts"
		return 0
	fi

	local now_ms="" counts=""
	now_ms=$(($(date +%s) * 1000))
	counts=$(jq -r --arg provider "$provider" --argjson now "$now_ms" --argjson zero 0 --arg status_empty '' --arg status_auth_error 'auth-error' --arg status_rate_limited 'rate-limited' '
		def n: tonumber? // 0;
		def account_status: .status // $status_empty;
		def available_account:
			(account_status) as $status
			| $status != $status_auth_error
			and (($status != $status_rate_limited) or (((.cooldownUntil // 0) | n) <= $now));
		(.[$provider] // []) as $accounts
		| ($accounts | length) as $total
		| if $total == 0 then
			[$zero, -1, $zero, $zero] | @tsv
		else
			($accounts | map(select(account_status == $status_auth_error)) | length) as $auth
			| ($accounts | map(select(
				account_status == $status_rate_limited
				and (((.cooldownUntil // 0) | n) > $now)
			)) | length) as $limited
			| ($accounts | map(select(available_account)) | length) as $available
			| [$total, $available, $limited, $auth] | @tsv
		end
	' "$pool_file" 2>/dev/null) || counts="$unavailable_counts"
	[[ -n "$counts" ]] || counts="$unavailable_counts"
	printf '%s\n' "$counts"
	return 0
}

#######################################
# Return host load pressure points for capacity reduction.
# Stdout: 0, 2, or 4.
#######################################
_pulse_capacity_load_pressure_points() {
	local load_per_cpu="${PULSE_DISPATCH_STAGGER_LOAD_PER_CPU:-}"
	local metrics_file="${AIDEVOPS_HEADLESS_METRICS_FILE:-${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl}"
	if [[ -z "$load_per_cpu" && -f "$metrics_file" ]]; then
		load_per_cpu=$(awk '
			/"load_per_cpu"[[:space:]]*:/ { line = $0 }
			END {
				if (line != "") {
					sub(/^.*"load_per_cpu"[[:space:]]*:[[:space:]]*/, "", line)
					sub(/[,}].*$/, "", line)
					print line
				}
			}
		' "$metrics_file" 2>/dev/null) || load_per_cpu=""
	fi
	local load_scaled=0 high_scaled moderate_scaled
	[[ -n "$load_per_cpu" ]] && load_scaled=$(_pulse_capacity_float_scaled "$load_per_cpu" 0)
	high_scaled=$(_pulse_capacity_float_scaled "${PULSE_DISPATCH_STAGGER_LOAD_HIGH:-8}" 8)
	moderate_scaled=$(_pulse_capacity_float_scaled "${PULSE_DISPATCH_STAGGER_LOAD_MODERATE:-4}" 4)
	if ((load_scaled >= high_scaled && load_scaled > 0)); then
		printf '4\n'
		return 0
	fi
	if ((load_scaled >= moderate_scaled && load_scaled > 0)); then
		printf '2\n'
		return 0
	fi
	printf '0\n'
	return 0
}

#######################################
# Count recent terminal worker-role provider/load health signals. Continuation
# events remain progress evidence but never become failure/capacity pressure.
# Stdout: "<failures> <rate_limits> <service_interruptions> <provider_5xx> <progress_heartbeats>".
#######################################
_pulse_capacity_recent_health_counts() {
	local failure_override="${PULSE_DISPATCH_CAPACITY_RECENT_FAILURES:-${PULSE_DISPATCH_STAGGER_RECENT_FAILURES:-}}"
	local rate_limit_override="${PULSE_DISPATCH_CAPACITY_RECENT_RATE_LIMITS:-${PULSE_DISPATCH_STAGGER_RECENT_RATE_LIMITS:-}}"
	local service_override="${PULSE_DISPATCH_CAPACITY_RECENT_SERVICE_INTERRUPTS:-}"
	local provider_5xx_override="${PULSE_DISPATCH_CAPACITY_RECENT_PROVIDER_5XX:-}"
	local progress_override="${PULSE_DISPATCH_CAPACITY_RECENT_PROGRESS_HEARTBEATS:-}"
	if [[ "$failure_override" =~ ^[0-9]+$ || "$rate_limit_override" =~ ^[0-9]+$ || "$service_override" =~ ^[0-9]+$ || "$provider_5xx_override" =~ ^[0-9]+$ || "$progress_override" =~ ^[0-9]+$ ]]; then
		[[ "$failure_override" =~ ^[0-9]+$ ]] || failure_override=0
		[[ "$rate_limit_override" =~ ^[0-9]+$ ]] || rate_limit_override=0
		[[ "$service_override" =~ ^[0-9]+$ ]] || service_override=0
		[[ "$provider_5xx_override" =~ ^[0-9]+$ ]] || provider_5xx_override=0
		[[ "$progress_override" =~ ^[0-9]+$ ]] || progress_override=0
		printf '%s %s %s %s %s\n' "$failure_override" "$rate_limit_override" "$service_override" "$provider_5xx_override" "$progress_override"
		return 0
	fi

	local metrics_file="${AIDEVOPS_HEADLESS_METRICS_FILE:-${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl}"
	local ttl_seconds="${PULSE_DISPATCH_CAPACITY_HEALTH_WINDOW_SECONDS:-900}"
	[[ "$ttl_seconds" =~ ^[0-9]+$ ]] || ttl_seconds=900
	[[ -f "$metrics_file" ]] || { printf '0 0 0 0 0\n'; return 0; }
	python3 - "$metrics_file" "$ttl_seconds" <<'PY'
import json
import sys
import time

path, ttl = sys.argv[1], int(sys.argv[2])
since = time.time() - ttl
failures = rate_limits = service_interruptions = provider_5xx = progress = 0
try:
    with open(path, 'r', encoding='utf-8', errors='replace') as handle:
        rows = handle.readlines()[-1000:]
    for raw in rows:
        try:
            item = json.loads(raw)
        except json.JSONDecodeError:
            continue
        try:
            ts = float(item.get("ts") or 0)
        except (TypeError, ValueError):
            ts = 0
        if ts < since:
            continue
        if str(item.get('role') or '') != 'worker':
            continue
        result = str(item.get('result') or '')
        failure_reason = str(item.get('failure_reason') or '')
        provider_type = str(item.get('provider_error_type') or '')
        provider_status = str(item.get('provider_status') or '')
        exit_code = item.get('exit_code')
        is_nonterminal = result.endswith('_continue') or result == 'brief_recovery'
        if result in {'watchdog_stall_continue', 'service_interruption_continue'} or str(item.get('activity_detected') or '0') == '1':
            progress += 1
        if is_nonterminal:
            continue
        is_rate_limited = (
            result in {'rate_limit', 'rate_limit_fast'}
            or provider_type == 'rate_limit'
            or provider_status == '429'
            or 'rate_limit' in failure_reason
        )
        is_service_interruption = result == 'service_interruption_exhausted'
        is_provider_5xx = provider_type == 'server_error' or provider_status in {'500', '502', '503', '504'}
        if is_rate_limited:
            rate_limits += 1
        if is_service_interruption:
            service_interruptions += 1
        if is_provider_5xx:
            provider_5xx += 1
        if not (result == 'success' and exit_code == 0) and result not in {'worker_noop', 'no_work', 'noop'}:
            failures += 1
except (OSError, ValueError):
    pass
print(f"{failures} {rate_limits} {service_interruptions} {provider_5xx} {progress}")
PY
	return 0
}

#######################################
# Apply a provider/account/load-aware cap to the raw dispatch target.
# Arguments:
#   $1 - raw max workers
#   $2 - active workers
#   $3 - minimum worker floor
# Stdout: "<final_max_workers> <floor_active>".
#######################################
pulse_apply_provider_load_capacity_cap() {
	local raw_max_workers="$1"
	local active_workers="$2"
	local min_worker_floor="$3"
	[[ "$raw_max_workers" =~ ^[0-9]+$ ]] || raw_max_workers=1
	[[ "$active_workers" =~ ^[0-9]+$ ]] || active_workers=0
	[[ "$min_worker_floor" =~ ^[0-9]+$ ]] || min_worker_floor=6

	local provider="" account_total="" account_available="" account_limited="" account_auth_errors=""
	provider=$(_pulse_capacity_selected_provider)
	read -r account_total account_available account_limited account_auth_errors <<<"$(_pulse_capacity_provider_account_counts "$provider")"
	[[ "$account_total" =~ ^[0-9]+$ ]] || account_total=0
	[[ "$account_available" =~ ^-?[0-9]+$ ]] || account_available=-1
	[[ "$account_limited" =~ ^[0-9]+$ ]] || account_limited=0
	[[ "$account_auth_errors" =~ ^[0-9]+$ ]] || account_auth_errors=0

	local load_points="" failures="" rate_limits="" service_interruptions="" provider_5xx="" progress_heartbeats=""
	load_points=$(_pulse_capacity_load_pressure_points)
	read -r failures rate_limits service_interruptions provider_5xx progress_heartbeats <<<"$(_pulse_capacity_recent_health_counts)"
	[[ "$load_points" =~ ^[0-9]+$ ]] || load_points=0
	[[ "$failures" =~ ^[0-9]+$ ]] || failures=0
	[[ "$rate_limits" =~ ^[0-9]+$ ]] || rate_limits=0
	[[ "$service_interruptions" =~ ^[0-9]+$ ]] || service_interruptions=0
	[[ "$provider_5xx" =~ ^[0-9]+$ ]] || provider_5xx=0
	[[ "$progress_heartbeats" =~ ^[0-9]+$ ]] || progress_heartbeats=0

	local account_multiplier="${PULSE_PROVIDER_ACCOUNT_SLOT_MULTIPLIER:-}" account_multiplier_source="env:PULSE_PROVIDER_ACCOUNT_SLOT_MULTIPLIER"
	if [[ -z "$account_multiplier" ]] && declare -F config_get >/dev/null 2>&1; then
		account_multiplier=$(config_get "orchestration.provider_account_slot_multiplier" "24")
		account_multiplier_source="config:orchestration.provider_account_slot_multiplier"
	elif [[ -z "$account_multiplier" ]]; then
		account_multiplier_source="default:24"
	fi
	[[ "$account_multiplier" =~ ^[0-9]+$ ]] || account_multiplier=24
	((account_multiplier < 1)) && account_multiplier=1
	local account_cap=-1
	if ((account_available >= 0)); then
		account_cap=$((account_available * account_multiplier))
	fi

	local floor_allowed=1 final_max="$raw_max_workers" floor_active=0
	if ((load_points >= 4 || rate_limits > 0 || service_interruptions > 0 || provider_5xx > 0 || failures >= 3)); then
		floor_allowed=0
	fi
	if ((account_cap >= 0 && min_worker_floor > 0 && account_cap < min_worker_floor)); then
		floor_allowed=0
	fi

	if ((floor_allowed == 1 && min_worker_floor > 0 && active_workers < min_worker_floor)); then
		floor_active=1
		if ((final_max < min_worker_floor)); then
			final_max="$min_worker_floor"
		fi
	fi

	if ((account_cap >= 0 && final_max > account_cap)); then
		final_max="$account_cap"
	fi
	if ((load_points >= 4 && final_max > 1)); then
		final_max=$(((final_max + 1) / 2))
	elif ((load_points >= 2 && final_max > 1)); then
		final_max=$(((final_max * 3 + 3) / 4))
	fi
	if ((rate_limits > 0 || service_interruptions > 0 || provider_5xx > 0 || failures >= 3)); then
		if ((final_max > 1)); then
			final_max=$(((final_max + 1) / 2))
		fi
	fi
	if ((active_workers > 0 && progress_heartbeats > 0)); then
		if ((load_points >= 4 || rate_limits > 0 || service_interruptions > 0 || provider_5xx > 0 || failures >= 3)); then
			if ((final_max > active_workers)); then
				final_max="$active_workers"
			fi
		elif ((load_points >= 2 && final_max > active_workers + 1)); then
			final_max=$((active_workers + 1))
		fi
	fi
	if ((final_max < 0)); then
		final_max=0
	fi
	if ((floor_active == 1 && final_max < min_worker_floor)); then
		floor_active=0
	fi

	if declare -F _dispatch_stats_gauge >/dev/null 2>&1; then
		_dispatch_stats_gauge "dispatch_capacity_provider_accounts_available" "$((account_available < 0 ? 0 : account_available))"
		_dispatch_stats_gauge "dispatch_capacity_load_pressure_points" "$load_points"
		_dispatch_stats_gauge "dispatch_capacity_recent_failures" "$failures"
		_dispatch_stats_gauge "dispatch_capacity_recent_worker_terminal_failures" "$failures"
		_dispatch_stats_gauge "dispatch_capacity_final_max_workers" "$final_max"
	fi
	local health_window_seconds="${PULSE_DISPATCH_CAPACITY_HEALTH_WINDOW_SECONDS:-900}"
	[[ "$health_window_seconds" =~ ^[0-9]+$ ]] || health_window_seconds=900
	printf '[pulse-wrapper] Dispatch_capacity: capacity_unit=simultaneous_workers simultaneous_target_raw=%s simultaneous_target_final=%s active_workers=%s provider=%s provider_accounts_total=%s provider_accounts_available=%s account_cap=%s provider_account_slot_multiplier=%s provider_account_slot_multiplier_source=%s override_hint="lower orchestration.provider_account_slot_multiplier or PULSE_PROVIDER_ACCOUNT_SLOT_MULTIPLIER if provider plan cannot sustain this concurrency" rate_limited_accounts=%s auth_error_accounts=%s load_points=%s worker_terminal_failures=%s rate_limits=%s service_interruptions=%s provider_5xx=%s worker_progress_heartbeats=%s failure_observation_window_seconds=%s task_duration_limit=none min_floor=%s floor_allowed=%s floor_active=%s\n' \
		"$raw_max_workers" "$final_max" "$active_workers" "${provider:-unknown}" "$account_total" "$account_available" "$account_cap" "$account_multiplier" "$account_multiplier_source" "$account_limited" "$account_auth_errors" "$load_points" "$failures" "$rate_limits" "$service_interruptions" "$provider_5xx" "$progress_heartbeats" "$health_window_seconds" "$min_worker_floor" "$floor_allowed" "$floor_active" >>"${LOGFILE:-/dev/null}" 2>/dev/null || true
	printf '%s %s\n' "$final_max" "$floor_active"
	return 0
}

#######################################
# Count runnable backlog candidates across pulse scope
# Heuristic for t1453 utilization loop:
# - open issues passing default-open candidate filter
#   (non-needs-* and non-management labels)
# - open PRs with failing checks or changes requested
# Returns: count via stdout
#######################################
count_runnable_candidates() {
	local repos_json="${REPOS_JSON}"
	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		echo "0"
		return 0
	fi

	local total=0
	while IFS='|' read -r slug _path; do
		[[ -n "$slug" ]] || continue

		local issue_count
		issue_count=$(list_dispatchable_issue_candidates "$slug" "$PULSE_RUNNABLE_ISSUE_LIMIT" | wc -l | tr -d ' ') || issue_count=0
		[[ "$issue_count" =~ ^[0-9]+$ ]] || issue_count=0

		# GH#21799: drop heavy GraphQL statusCheckRollup; fetch headRefOid
		# instead and resolve PASS/FAIL/PENDING via REST check-suites
		# (separate budget pool, ~15x smaller payload).
		local pr_json pr_rc_err
		pr_rc_err=$(mktemp)
		pr_json=$(pulse_pr_list_get --repo "$slug" --state open --json number,headRefOid --limit "$PULSE_RUNNABLE_PR_LIMIT" 2>"$pr_rc_err") || pr_json="[]"
		if [[ -z "$pr_json" || "$pr_json" == "null" ]]; then
			local _pr_rc_err_msg
			_pr_rc_err_msg=$(cat "$pr_rc_err" 2>/dev/null || echo "unknown error")
			echo "[pulse-wrapper] count_runnable_candidates: gh_pr_list FAILED for ${slug}: ${_pr_rc_err_msg}" >>"$LOGFILE"
			pr_json="[]"
		fi
		rm -f "$pr_rc_err"
		if declare -F _pmp_enrich_prs_with_review_decisions >/dev/null 2>&1; then
			pr_json=$(_pmp_enrich_prs_with_review_decisions "$slug" "$pr_json")
		fi

		# Enrich with REST check status, then count "runnable" PRs:
		# CHANGES_REQUESTED OR aggregate check status == FAIL.
		local pr_checks_json=""
		pr_checks_json=$(gh_pr_check_status_rest_batch "$slug" "$pr_json" 2>/dev/null) || pr_checks_json="[]"
		[[ -n "$pr_checks_json" && "$pr_checks_json" != "null" ]] || pr_checks_json="[]"

		local pr_count
		pr_count=$(jq -n --argjson prs "$pr_json" --argjson checks "$pr_checks_json" '
			($checks | map({(.number | tostring): .status}) | add // {}) as $check_map |
			[$prs[] | (.number | tostring) as $n | select(.reviewDecision == "CHANGES_REQUESTED" or ($check_map[$n] // "none") == "FAIL")] | length
		' 2>/dev/null) || pr_count=0
		[[ "$pr_count" =~ ^[0-9]+$ ]] || pr_count=0
		pulse_count_debug_log "count_runnable_candidates repo=${slug} issues=${issue_count} prs=${pr_count} total=$((issue_count + pr_count))"

		total=$((total + issue_count + pr_count))
	done < <(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") | "\(.slug)|\(.path)"' "$repos_json" 2>/dev/null)

	echo "$total"
	return 0
}

#######################################
# Count queued issues that do not have an active worker process
# This is a launch-validation signal: queued labels imply dispatch,
# but no matching worker indicates startup failure or immediate exit.
# Returns: count via stdout
#######################################
count_queued_without_worker() {
	local repos_json="${REPOS_JSON}"
	if [[ ! -f "$repos_json" ]] || ! command -v jq &>/dev/null; then
		echo "0"
		return 0
	fi

	local self_login
	self_login=$(gh api user --jq '.login' 2>/dev/null || echo "")

	local total=0
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue
		local queued_json queued_err
		queued_err=$(mktemp)
		queued_json=$(gh_issue_list --repo "$slug" --state open --label "status:queued" --json number,assignees --limit "$PULSE_QUEUED_SCAN_LIMIT" 2>"$queued_err") || queued_json="[]"
		if [[ -z "$queued_json" || "$queued_json" == "null" ]]; then
			local _queued_err_msg
			_queued_err_msg=$(cat "$queued_err" 2>/dev/null || echo "unknown error")
			echo "[pulse-wrapper] count_queued_without_worker: gh_issue_list FAILED for ${slug}: ${_queued_err_msg}" >>"$LOGFILE"
			queued_json="[]"
		fi
		rm -f "$queued_err"

		local queued_count
		queued_count=$(echo "$queued_json" | jq 'length' 2>/dev/null) || queued_count=0
		[[ "$queued_count" =~ ^[0-9]+$ ]] || queued_count=0
		pulse_count_debug_log "count_queued_without_worker repo=${slug} queued=${queued_count}"
		if [[ "$queued_count" -eq 0 ]]; then
			continue
		fi

		while IFS='|' read -r issue_num assigned_to_other; do
			[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

			# Cross-runner safety: queued issues assigned to another login are not
			# counted as "without worker" because the worker may be running on that
			# runner's machine and invisible to local process inspection.
			if [[ "$assigned_to_other" == "true" ]]; then
				continue
			fi

			if ! has_worker_for_repo_issue "$issue_num" "$slug"; then
				total=$((total + 1))
				pulse_count_debug_log "count_queued_without_worker repo=${slug} issue=${issue_num} missing_worker=true"
			fi
		done < <(echo "$queued_json" | jq -r --arg self "$self_login" '.[] | .number as $n | ((.assignees | length) > 0 and (([.assignees[].login] | index($self)) == null)) as $assigned_other | "\($n)|\($assigned_other)"' 2>/dev/null)
	done < <(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null)

	echo "$total"
	return 0
}

#######################################
# Emit debug logs for pulse count helpers without polluting stdout.
#
# Debug logs are opt-in via PULSE_DEBUG and always go to stderr so helpers that
# are consumed numerically keep a strict stdout contract.
#
# Arguments:
#   $1 - message to log
# Returns: 0 always
#######################################
pulse_count_debug_log() {
	local message="$1"
	case "${PULSE_DEBUG:-}" in
	1 | true | TRUE | yes | YES | on | ON)
		printf '[pulse-wrapper] DEBUG: %s\n' "$message" >&2
		;;
	esac
	return 0
}

#######################################
# Normalize noisy helper stdout to a numeric count.
#
# Some count helpers may emit diagnostic lines before their final numeric
# result. Accept the last line that is purely an integer; otherwise fail closed
# to 0.
#
# Arguments:
#   $1 - raw helper stdout
# Returns: normalized integer via stdout
#######################################
normalize_count_output() {
	local raw_output="$1"
	local normalized
	normalized=$(printf '%s\n' "$raw_output" | awk '
		/^[[:space:]]*[0-9]+[[:space:]]*$/ {
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
			last = $0
		}
		END {
			if (last != "") {
				print last
			}
		}
	')

	if [[ "$normalized" =~ ^[0-9]+$ ]]; then
		echo "$normalized"
		return 0
	fi

	echo "0"
	return 0
}
