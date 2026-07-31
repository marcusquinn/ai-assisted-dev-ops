#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Worker Watchdog — Fast-Fail State Management
# =============================================================================
# Records watchdog kills in the shared fast-fail counter and triggers tier
# escalation when failure thresholds are reached. Uses the same state file
# and locking as pulse-wrapper.sh's fast_fail_record() to coordinate
# across both processes. (GH#2076, GH#17378)
#
# Functions:
#   _ff_load_state_entry             — Load and parse existing fast-fail state
#   _ff_compute_backoff_rate_limit   — Compute rate-limit backoff from account pool
#   _ff_write_state_entry            — Write updated fast-fail state atomically
#   _watchdog_record_failure_and_escalate — Record kill + trigger tier escalation
#
# Usage: source "${SCRIPT_DIR}/worker-watchdog-ff.sh"
#
# Dependencies:
#   - shared-constants.sh (escalate_issue_tier, sourced by orchestrator)
#   - Globals: FAST_FAIL_EXPIRY_SECS, FAST_FAIL_INITIAL_BACKOFF_SECS,
#       FAST_FAIL_MAX_BACKOFF_SECS, LOG_FILE
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_WORKER_WATCHDOG_FF_LOADED:-}" ]] && return 0
_WORKER_WATCHDOG_FF_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_WWFF_SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_WWFF_SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && _WWFF_SCRIPT_DIR="."
if [[ -r "${_WWFF_SCRIPT_DIR}/lib/version.sh" ]]; then
	# shellcheck source=lib/version.sh
	source "${_WWFF_SCRIPT_DIR}/lib/version.sh"
fi
# shellcheck source=fast-fail-release-policy.sh
source "${_WWFF_SCRIPT_DIR}/fast-fail-release-policy.sh"
unset _WWFF_SCRIPT_DIR

# =============================================================================
# Fast-Fail State Helpers
# =============================================================================

#######################################
# Load fast-fail state file and extract existing entry for a key.
#
# Arguments:
#   $1 - state_file path
#   $2 - key (repo_slug/issue_number)
#   $3 - expiry_secs
#   $4 - now (epoch seconds)
# Output: "state|existing_count|existing_backoff" (pipe-separated)
#######################################
_ff_load_state_entry() {
	local state_file="$1"
	local key="$2"
	local expiry_secs="$3"
	local now="$4"

	local state="{}"
	if [[ -f "$state_file" ]]; then
		state=$(cat "$state_file" 2>/dev/null) || state="{}"
		printf '%s' "$state" | jq empty 2>/dev/null || state="{}"
	fi

	local existing_ts existing_count existing_backoff
	existing_ts=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].ts // 0' 2>/dev/null) || existing_ts=0
	existing_count=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].count // 0' 2>/dev/null) || existing_count=0
	existing_backoff=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].backoff_secs // 0' 2>/dev/null) || existing_backoff=0
	[[ "$existing_ts" =~ ^[0-9]+$ ]] || existing_ts=0
	[[ "$existing_count" =~ ^[0-9]+$ ]] || existing_count=0
	[[ "$existing_backoff" =~ ^[0-9]+$ ]] || existing_backoff=0

	local age=$((now - existing_ts))
	if [[ "$age" -ge "$expiry_secs" ]]; then
		existing_count=0
		existing_backoff=0
	fi

	printf '%s|%s|%s' "$state" "$existing_count" "$existing_backoff"
	return 0
}

#######################################
# Compute backoff for rate-limit kills by querying the account pool.
#
# Arguments:
#   $1 - provider (e.g., "anthropic")
#   $2 - existing_count
#   $3 - existing_backoff
#   $4 - now (epoch seconds)
#   $5 - initial_backoff
#   $6 - max_backoff
# Output: "new_count|new_backoff|retry_after|log_action" (pipe-separated)
#######################################
_ff_compute_backoff_rate_limit() {
	local provider="$1"
	local existing_count="$2"
	local existing_backoff="$3"
	local now="$4"
	local initial_backoff="$5"
	local max_backoff="$6"

	local pool_file="${HOME}/.aidevops/oauth-pool.json"
	local pool_wait="-1"
	if [[ -f "$pool_file" ]]; then
		pool_wait=$(POOL_FILE="$pool_file" PROVIDER="$provider" python3 -c "
import json, os, time, sys
try:
    with open(os.environ['POOL_FILE']) as f:
        pool = json.load(f)
    now_ms = int(time.time() * 1000)
    accounts = pool.get(os.environ['PROVIDER'], [])
    if not accounts: print(-1); sys.exit(0)
    min_remaining = None
    for a in accounts:
        cd = a.get('cooldownUntil')
        if cd and int(cd) > now_ms and a.get('status') == 'rate-limited':
            remaining_s = max(1, (int(cd) - now_ms) // 1000)
            min_remaining = min(min_remaining, remaining_s) if min_remaining else remaining_s
        else:
            print(0); sys.exit(0)
    print(min_remaining or 0)
except Exception: print(-1)
" 2>/dev/null) || pool_wait="-1"
	fi
	[[ "$pool_wait" =~ ^-?[0-9]+$ ]] || pool_wait="-1"

	local new_count="$existing_count"
	local new_backoff="$existing_backoff"
	local retry_after=0
	local log_action=""

	if [[ "$pool_wait" == "0" ]]; then
		retry_after=0
		log_action="rate_limit_rotate (accounts available)"
	elif [[ "$pool_wait" == "-1" ]]; then
		new_count=$((existing_count + 1))
		new_backoff=$((existing_backoff > 0 ? existing_backoff * 2 : initial_backoff))
		[[ "$new_backoff" -gt "$max_backoff" ]] && new_backoff="$max_backoff"
		retry_after=$((now + new_backoff))
		log_action="rate_limit_no_pool (backoff=${new_backoff}s)"
	else
		# All accounts exhausted — wait for earliest recovery.
		# Keep backoff_secs on the exponential ladder (not pool_wait).
		new_count=$((existing_count + 1))
		retry_after=$((now + pool_wait))
		new_backoff=$((existing_backoff > 0 ? existing_backoff * 2 : initial_backoff))
		[[ "$new_backoff" -gt "$max_backoff" ]] && new_backoff="$max_backoff"
		log_action="rate_limit_exhausted (wait=${pool_wait}s, backoff_stage=${new_backoff}s)"
	fi

	printf '%s|%s|%s|%s' "$new_count" "$new_backoff" "$retry_after" "$log_action"
	return 0
}

#######################################
# Write updated fast-fail state atomically (tmp + mv).
#
# Arguments:
#   $1 - state (current JSON string)
#   $2 - state_file path
#   $3 - state_dir path
#   $4 - lock_dir path
#   $5 - key
#   $6 - new_count
#   $7 - now
#   $8 - reason
#   $9 - retry_after
#   $10 - new_backoff
#   $11 - crash_type
# Returns: 0 on success, releases lock on failure
#######################################
_ff_write_state_entry() {
	local state="$1"
	local state_file="$2"
	local state_dir="$3"
	local lock_dir="$4"
	local key="$5"
	local new_count="$6"
	local now="$7"
	local reason="$8"
	local retry_after="$9"
	local new_backoff="${10}"
	local crash_type="${11:-}"
	local aidevops_version="${AIDEVOPS_UNKNOWN_VERSION:-unknown}"
	local release_reset_policy=""
	if declare -F aidevops_find_version >/dev/null 2>&1; then
		aidevops_version=$(aidevops_find_version 2>/dev/null || printf '%s' "${AIDEVOPS_UNKNOWN_VERSION:-unknown}")
	fi
	release_reset_policy=$(_fast_fail_release_reset_policy "$reason" "$crash_type")

	local updated_state
	updated_state=$(printf '%s' "$state" | jq \
		--arg k "$key" \
		--argjson count "$new_count" \
		--argjson ts "$now" \
		--arg reason "$reason" \
		--argjson retry_after "$retry_after" \
		--argjson backoff_secs "$new_backoff" \
		--arg crash_type "$crash_type" \
		--arg aidevops_version "$aidevops_version" \
		--arg release_reset_policy "$release_reset_policy" \
		'.[$k] = ((.[$k] // {}) + {"count": $count, "ts": $ts, "reason": $reason, "retry_after": $retry_after, "backoff_secs": $backoff_secs, "crash_type": $crash_type, "aidevops_version": $aidevops_version, "release_reset_policy": $release_reset_policy})' 2>/dev/null) || {
		rmdir "$lock_dir" 2>/dev/null || true
		return 1
	}

	local tmp_file
	tmp_file=$(mktemp "${state_dir}/.fast-fail-counter.XXXXXX" 2>/dev/null) || {
		rmdir "$lock_dir" 2>/dev/null || true
		return 1
	}
	if printf '%s\n' "$updated_state" >"$tmp_file"; then
		mv "$tmp_file" "$state_file" || {
			rm -f "$tmp_file"
			rmdir "$lock_dir" 2>/dev/null || true
			return 1
		}
	else
		rm -f "$tmp_file"
		rmdir "$lock_dir" 2>/dev/null || true
		return 1
	fi

	return 0
}

# =============================================================================
# Failure Recording and Tier Escalation
# =============================================================================

#######################################
# Record a watchdog kill in the shared fast-fail state and trigger
# tier escalation when threshold is reached.
#
# Uses the same state file and locking as pulse-wrapper.sh's
# fast_fail_record(). The watchdog writes cause-aware entries with
# the same format: { count, ts, reason, retry_after, backoff_secs }.
#
# Rate-limit kills (reason=backoff) query the account pool to decide
# whether to back off or allow immediate retry with a rotated account.
# Non-rate-limit kills use exponential backoff. (GH#2076, GH#17378)
#
# Arguments:
#   $1 - issue number
#   $2 - repo slug
#   $3 - kill reason (idle, stall, thrash, runtime, backoff, etc.)
#   $4 - provider (anthropic, openai, cursor, google; default: anthropic)
#   $5 - crash_type (no_work|overwhelmed|""; for tier escalation)
#   $6 - attempt_id (optional exact objective correlation)
#######################################
_watchdog_record_failure_and_escalate() {
	local issue_number="$1"
	local repo_slug="$2"
	local reason="$3"
	local provider="${4:-anthropic}"
	local crash_type="${5:-}"
	local attempt_id="${6:-}"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0
	if declare -F _worker_attempt_id_for_issue >/dev/null 2>&1; then
		attempt_id=$(_worker_attempt_id_for_issue "$issue_number" "$repo_slug" "$attempt_id") || attempt_id=""
	fi
	if [[ -n "$attempt_id" ]] && declare -F _objective_disposition_suppresses >/dev/null 2>&1 && \
		_objective_disposition_suppresses suppress_fast_fail "$issue_number" "$repo_slug" "$attempt_id"; then
		log_msg "Fast-fail suppressed for #${issue_number} (${repo_slug}) by reconciled objective outcome"
		return 0
	fi

	local state_file="${HOME}/.aidevops/.agent-workspace/supervisor/fast-fail-counter.json"
	local state_dir
	state_dir=$(dirname "$state_file")
	mkdir -p "$state_dir" 2>/dev/null || true

	# Acquire lock (shared with pulse-wrapper.sh's _ff_with_lock)
	local lock_dir="${state_file}.lockdir"
	local retries=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		retries=$((retries + 1))
		if [[ "$retries" -ge 50 ]]; then
			log_msg "Fast-fail lock timeout for #${issue_number} (${repo_slug})"
			return 0
		fi
		sleep 0.1
	done

	local key now
	key="${repo_slug}/${issue_number}"
	now=$(date +%s)

	local expiry_secs="${FAST_FAIL_EXPIRY_SECS:-604800}"
	local initial_backoff="${FAST_FAIL_INITIAL_BACKOFF_SECS:-600}"
	local max_backoff="${FAST_FAIL_MAX_BACKOFF_SECS:-604800}"

	# Load state and existing entry
	local load_result state existing_count existing_backoff
	load_result=$(_ff_load_state_entry "$state_file" "$key" "$expiry_secs" "$now")
	state="${load_result%%|*}"
	local load_rest="${load_result#*|}"
	existing_count="${load_rest%%|*}"
	existing_backoff="${load_rest##*|}"

	# Cause-aware backoff (mirrors pulse-wrapper.sh logic)
	local new_count new_backoff retry_after log_action
	case "$reason" in
	backoff | rate_limit*)
		local rl_result
		rl_result=$(_ff_compute_backoff_rate_limit "$provider" "$existing_count" "$existing_backoff" "$now" "$initial_backoff" "$max_backoff")
		new_count="${rl_result%%|*}"
		local rl_rest="${rl_result#*|}"
		new_backoff="${rl_rest%%|*}"
		local rl_rest2="${rl_rest#*|}"
		retry_after="${rl_rest2%%|*}"
		log_action="${rl_rest2#*|}"
		;;
	*)
		new_count=$((existing_count + 1))
		new_backoff=$((existing_backoff > 0 ? existing_backoff * 2 : initial_backoff))
		[[ "$new_backoff" -gt "$max_backoff" ]] && new_backoff="$max_backoff"
		retry_after=$((now + new_backoff))
		log_action="failure_backoff (count=${new_count}, backoff=${new_backoff}s)"
		;;
	esac

	# Write updated state and release lock
	if ! _ff_write_state_entry "$state" "$state_file" "$state_dir" "$lock_dir" \
		"$key" "$new_count" "$now" "$reason" "$retry_after" "$new_backoff" "$crash_type"; then
		log_msg "Fast-fail write failed for #${issue_number} (${repo_slug}); skipping escalation"
		rmdir "$lock_dir" 2>/dev/null || true
		return 0
	fi
	rmdir "$lock_dir" 2>/dev/null || true

	log_msg "Fast-fail: #${issue_number} (${repo_slug}) ${log_action} reason=${reason} crash_type=${crash_type:-unclassified}"

	# Trigger tier escalation on non-rate-limit failures.
	# Pass crash_type for crash-type-aware thresholds.
	if [[ "$new_count" -gt "$existing_count" ]]; then
		escalate_issue_tier "$issue_number" "$repo_slug" "$new_count" "$reason" "$crash_type"
	fi

	return 0
}
