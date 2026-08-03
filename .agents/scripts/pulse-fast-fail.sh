#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# pulse-fast-fail.sh — Per-issue fast-fail counter with cause-aware backoff (rate-limit vs crash). t1888, GH#2076, GH#17384.
#
# Extracted from pulse-wrapper.sh in Phase 2 of the phased decomposition
# (parent: GH#18356, plan: todo/plans/pulse-wrapper-decomposition.md §6).
#
# This module is sourced by pulse-wrapper.sh. It MUST NOT be executed
# directly — it relies on the orchestrator having sourced:
#   shared-constants.sh
#   worker-lifecycle-common.sh
# and having defined all PULSE_* / FAST_FAIL_* / etc. configuration
# constants in the bootstrap section.
#
# Functions in this module (in source order):
#   - _ff_key
#   - _ff_load
#   - _ff_current_aidevops_version
#   - _ff_version_gt
#   - _ff_release_retry_reset_if_newer
#   - _ff_query_pool_retry_seconds
#   - _ff_with_lock
#   - _ff_save
#   - _ff_mark_terminal_consolidation_routed
#   - _ff_route_terminal_consolidation
#   - _ff_terminal_threshold_crossed
#   - _ff_parse_entry
#   - _ff_compute_rate_limit_strategy
#   - _ff_compute_failure_strategy
#   - fast_fail_record
#   - _fast_fail_record_locked
#   - fast_fail_reset
#   - _fast_fail_reset_locked
#   - fast_fail_age_out       (t2397 — age-based auto-recovery for HARD STOP'd issues)
#   - _fast_fail_age_out_locked
#   - fast_fail_is_skipped
#   - fast_fail_prune_expired
#   - _fast_fail_prune_expired_locked
#   - _ff_mark_enrichment_done
#
# Originally a pure move from pulse-wrapper.sh (byte-identical to pre-extraction
# form). GH#18692 decomposed _fast_fail_record_locked (115 lines) into focused
# helpers to satisfy the 100-line complexity gate.

_PFF_SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_PFF_SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && _PFF_SCRIPT_DIR="."
# shellcheck source=fast-fail-release-policy.sh
source "${_PFF_SCRIPT_DIR}/fast-fail-release-policy.sh"
unset _PFF_SCRIPT_DIR
#
# Configurable environment variables (all optional):
#   FAST_FAIL_LOCK_ORPHAN_AGE_SECONDS — seconds before an empty lockdir (no owner.pid
#     file) is treated as an orphan and cleaned. Covers the SIGKILL race window where
#     a process dies between mkdir and owner.pid write, leaving the lockdir without an
#     owner and permanently blocking all dispatch. Default: 5 (well above the normal
#     mkdir→printf window of microseconds; short enough that recovery is fast). (t2953)

# Include guard — prevent double-sourcing.
[[ -n "${_PULSE_FAST_FAIL_LOADED:-}" ]] && return 0
_PULSE_FAST_FAIL_LOADED=1
_FF_BOOL_FALSE="false"
_FF_RELEASE_RESET_POLICY_SOURCE_STATE_REQUIRED="source-state-required"

#######################################
# Return the fast-fail state key for an issue.
# Arguments: $1 issue_number, $2 repo_slug
#######################################
_ff_key() {
	local issue_number="$1"
	local repo_slug="$2"
	printf '%s/%s' "$repo_slug" "$issue_number"
	return 0
}

#######################################
# Load the fast-fail state file as JSON.
# Outputs "{}" on missing or corrupt file.
#######################################
_ff_load() {
	if [[ ! -f "$FAST_FAIL_STATE_FILE" ]]; then
		printf '{}'
		return 0
	fi
	local content
	content=$(cat "$FAST_FAIL_STATE_FILE" 2>/dev/null) || content="{}"
	# Validate JSON; reset if corrupt
	if ! printf '%s' "$content" | jq empty 2>/dev/null; then
		printf '{}'
		return 0
	fi
	printf '%s' "$content"
	return 0
}

#######################################
# Query the OAuth account pool to determine retry strategy for rate limits.
#
# Checks whether any non-rate-limited accounts are available for the given
# provider. If yes, returns 0 (immediate retry with rotation). If all
# accounts are exhausted, returns the number of seconds until the earliest
# account recovers via stdout.
#
# Uses the same logic as parse_retry_after_seconds() in headless-runtime-helper.sh
# but is self-contained so the pulse can query without launching a subprocess.
#
# Arguments:
#   $1 - provider (anthropic, openai, cursor, google)
# Stdout: seconds until earliest recovery (0 = accounts available now,
#         -1 = no pool configured / query failed)
# Returns: 0 always (best-effort)
#######################################
_ff_query_pool_retry_seconds() {
	local provider="${1:-anthropic}"
	local pool_file="${HOME}/.aidevops/oauth-pool.json"

	# No pool file = no pool management = signal "no pool configured" so caller
	# falls through to exponential backoff instead of treating it as "available now".
	if [[ ! -f "$pool_file" ]]; then
		echo "-1"
		return 0
	fi

	local result
	result=$(POOL_FILE="$pool_file" PROVIDER="$provider" python3 -c "
import json, os, time, sys
try:
    pool = json.load(open(os.environ['POOL_FILE']))
    now_ms = int(time.time() * 1000)
    accounts = pool.get(os.environ['PROVIDER'], [])
    if not accounts:
        # No accounts configured for this provider — can't determine availability
        print(-1); sys.exit(0)
    min_remaining = None
    for a in accounts:
        cd = a.get('cooldownUntil')
        if cd and int(cd) > now_ms and a.get('status') == 'rate-limited':
            remaining_s = max(1, (int(cd) - now_ms) // 1000)
            min_remaining = min(min_remaining, remaining_s) if min_remaining else remaining_s
        else:
            # At least one account is available — immediate retry
            print(0); sys.exit(0)
    # All accounts rate-limited — return shortest wait
    print(min_remaining or 0)
except Exception:
    print(-1)
" 2>/dev/null) || result="-1"

	[[ "$result" =~ ^-?[0-9]+$ ]] || result="-1"
	echo "$result"
	return 0
}

#######################################
# Acquire an exclusive lock for fast-fail state read-modify-write.
# Uses mkdir atomicity (same pattern as circuit-breaker-helper.sh).
# Both pulse-wrapper.sh and worker-watchdog.sh write to the same
# state file — this prevents lost increments from concurrent updates.
# (GH#2076, CodeRabbit review)
#
# Arguments: command and arguments to run under lock
# Returns: exit code of the wrapped command
#######################################
_ff_with_lock() {
	local lock_dir="${FAST_FAIL_STATE_FILE}.lockdir"
	local retries=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		retries=$((retries + 1))
		if [[ "$retries" -ge 50 ]]; then
			echo "[pulse-wrapper] _ff_with_lock: lock acquisition timed out" >>"$LOGFILE"
			return 1
		fi
		# Stale lock detection: read the owner PID stored in the lock directory.
		# If that process is no longer running, the lock is orphaned — clear it.
		# t2421: format is "pid|argv_hash" — parse both fields.
		local _ff_owner_raw _ff_owner_pid _ff_owner_hash
		_ff_owner_raw=$(cat "${lock_dir}/owner.pid" 2>/dev/null || true)
		_ff_owner_pid="${_ff_owner_raw%%|*}"
		_ff_owner_hash="${_ff_owner_raw#*|}"
		[[ "$_ff_owner_hash" == "$_ff_owner_pid" ]] && _ff_owner_hash=""  # no | separator = legacy format
		# t2421: command-aware liveness — bare kill -0 lies on macOS PID reuse
		if [[ -n "$_ff_owner_pid" ]] && ! _is_process_alive_and_matches "$_ff_owner_pid" "${PULSE_PROCESS_PATTERN:-}" "$_ff_owner_hash"; then
			echo "[pulse-wrapper] _ff_with_lock: clearing stale lock (owner PID ${_ff_owner_pid} gone or reused, t2421)" >>"$LOGFILE"
			rm -f "${lock_dir}/owner.pid" 2>/dev/null || true
			rmdir "$lock_dir" 2>/dev/null || true
			continue
		fi
		# t2953: empty-lockdir orphan path — detect lockdirs created by processes
		# that died between mkdir and owner.pid write (SIGKILL race window).
		# When owner.pid is absent, use lockdir mtime as age proxy. The normal
		# mkdir→printf window is microseconds; a 5s threshold provides safe margin.
		if [[ -z "$_ff_owner_pid" ]]; then
			local _orphan_age_threshold="" _lock_mtime="" _lock_now="" _lock_age=""
			_orphan_age_threshold="${FAST_FAIL_LOCK_ORPHAN_AGE_SECONDS:-5}"
			_lock_mtime=$(_file_mtime_epoch "$lock_dir")
			_lock_now=$(date +%s)
			_lock_age=$((_lock_now - _lock_mtime))
			if [[ "$_lock_age" -ge "$_orphan_age_threshold" ]]; then
				echo "[pulse-wrapper] _ff_with_lock: clearing orphan lock (no owner.pid, age=${_lock_age}s >= ${_orphan_age_threshold}s, t2953)" >>"$LOGFILE"
				rmdir "$lock_dir" 2>/dev/null || true
				continue
			fi
		fi
		sleep 0.1
	done
	# Record owner PID (and argv hash for t2421 PID-reuse detection) inside lock directory.
	local _ff_argv_hash=""
	_ff_argv_hash=$(_compute_argv_hash "$$" 2>/dev/null || echo "")
	printf '%s|%s\n' "$$" "$_ff_argv_hash" >"${lock_dir}/owner.pid" 2>/dev/null || true
	local rc=0
	"$@" || rc=$?
	rm -f "${lock_dir}/owner.pid" 2>/dev/null || true
	rmdir "$lock_dir" 2>/dev/null || true
	return "$rc"
}

#######################################
# Write updated state atomically (tmp + mv).
# Arguments: $1 JSON string
#######################################
_ff_save() {
	local json="$1"
	local state_dir
	state_dir=$(dirname "$FAST_FAIL_STATE_FILE")
	mkdir -p "$state_dir" 2>/dev/null || true
	local tmp_file
	tmp_file=$(mktemp "${state_dir}/.fast-fail-counter.XXXXXX" 2>/dev/null) || return 0
	if printf '%s\n' "$json" >"$tmp_file"; then
		mv "$tmp_file" "$FAST_FAIL_STATE_FILE" || {
			rm -f "$tmp_file"
			echo "[pulse-wrapper] _ff_save: failed to move fast-fail state" >>"$LOGFILE"
		}
	else
		rm -f "$tmp_file"
		echo "[pulse-wrapper] _ff_save: failed to write fast-fail state" >>"$LOGFILE"
	fi
	return 0
}

#######################################
# Persist that the terminal fast-fail outcome has already passed through the
# idempotent consolidation dispatcher. This avoids repeated GitHub reads and
# label writes on every pulse cycle while the issue remains hard-stopped.
# Arguments: issue number, repo slug, breaker source
#######################################
_ff_mark_terminal_consolidation_routed() {
	_ff_with_lock _ff_mark_terminal_consolidation_routed_locked "$@" || return 1
	return 0
}

_ff_mark_terminal_consolidation_routed_locked() {
	local issue_number="$1"
	local repo_slug="$2"
	local breaker_source="$3"
	local key
	local state
	local now
	local updated_state

	key=$(_ff_key "$issue_number" "$repo_slug")
	state=$(_ff_load)
	now=$(date +%s)
	updated_state=$(printf '%s' "$state" | jq \
		--arg k "$key" \
		--arg source "$breaker_source" \
		--argjson ts "$now" \
		'if .[$k] then .[$k].terminal_consolidation_routed = true | .[$k].terminal_consolidation_source = $source | .[$k].terminal_consolidation_ts = $ts else . end' \
		2>/dev/null) || return 1
	_ff_save "$updated_state"
	return 0
}

#######################################
# Hand a terminal fast-fail outcome to the shared consolidation bridge after
# releasing the fast-fail state lock. Missing bridge functions are fail-open:
# fast_fail_is_skipped retries the handoff on the next main pulse cycle.
# Arguments: issue number, repo slug, breaker source, optional detail
#######################################
_ff_route_terminal_consolidation() {
	local issue_number="$1"
	local repo_slug="$2"
	local breaker_source="$3"
	local breaker_detail="${4:-}"

	if ! declare -F _route_terminal_breaker_to_consolidation >/dev/null 2>&1; then
		echo "[pulse-wrapper] fast-fail consolidation deferred for #${issue_number} in ${repo_slug}: bridge unavailable" >>"$LOGFILE"
		return 1
	fi
	if ! _route_terminal_breaker_to_consolidation \
		"$issue_number" "$repo_slug" "$breaker_source" "$breaker_detail"; then
		return 1
	fi
	_ff_mark_terminal_consolidation_routed "$issue_number" "$repo_slug" "$breaker_source" || true
	return 0
}

#######################################
# Check whether a non-rate-limit failure has just crossed the hard-stop
# threshold. Kept separate so _fast_fail_record_locked stays below the
# function-size complexity gate.
# Arguments: existing count, new count, rate-limit boolean
#######################################
_ff_terminal_threshold_crossed() {
	local existing_count="$1"
	local new_count="$2"
	local is_rate_limit="$3"
	local terminal_threshold="${FAST_FAIL_SKIP_THRESHOLD:-5}"

	[[ "$terminal_threshold" =~ ^[0-9]+$ ]] || terminal_threshold=5
	if [[ "$is_rate_limit" == "$_FF_BOOL_FALSE" \
		&& "$existing_count" -lt "$terminal_threshold" \
		&& "$new_count" -ge "$terminal_threshold" ]]; then
		return 0
	fi
	return 1
}

#######################################
# Parse an existing fast-fail entry from state, resetting fields if expired.
#
# Reads count and backoff_secs for the given key, normalises non-integer
# values to 0, and resets both to 0 when the entry age exceeds
# FAST_FAIL_EXPIRY_SECS.
#
# Arguments:
#   $1 - state JSON string
#   $2 - key (repo_slug/issue_number)
#   $3 - current timestamp (seconds since epoch)
# Stdout: TAB-delimited pair: existing_count<TAB>existing_backoff
#######################################
_ff_parse_entry() {
	local state="$1"
	local key="$2"
	local now="$3"

	local existing_ts existing_count existing_backoff
	IFS=$'\t' read -r existing_ts existing_count existing_backoff < <(
		printf '%s' "$state" | jq -r --arg k "$key" \
			'.[$k] // {} | "\(.ts // 0)\t\(.count // 0)\t\(.backoff_secs // 0)"' ||
			printf '0\t0\t0\n'
	)
	[[ "$existing_ts" =~ ^[0-9]+$ ]] || existing_ts=0
	[[ "$existing_count" =~ ^[0-9]+$ ]] || existing_count=0
	[[ "$existing_backoff" =~ ^[0-9]+$ ]] || existing_backoff=0

	local age=$((now - existing_ts))
	if [[ "$age" -ge "$FAST_FAIL_EXPIRY_SECS" ]]; then
		existing_count=0
		existing_backoff=0
	fi
	printf '%s\t%s\n' "$existing_count" "$existing_backoff"
	return 0
}

#######################################
# Compute retry strategy for rate-limit / backoff failures.
#
# Queries the OAuth account pool; picks immediate-retry (accounts available),
# no-pool exponential backoff (pool unconfigured), or pool-exhausted wait
# (all accounts rate-limited) depending on pool state.
#
# Arguments:
#   $1 - existing_count
#   $2 - existing_backoff (backoff_secs)
#   $3 - provider (e.g. anthropic)
#   $4 - current timestamp (seconds since epoch)
# Stdout: TAB-delimited: new_count<TAB>new_backoff<TAB>retry_after<TAB>log_action
#######################################
_ff_compute_rate_limit_strategy() {
	local existing_count="$1"
	local existing_backoff="$2"
	local provider="$3"
	local now="$4"

	local new_count="$existing_count"
	local new_backoff="$existing_backoff"
	local retry_after=0
	local log_action=""

	local pool_wait
	pool_wait=$(_ff_query_pool_retry_seconds "$provider")

	if [[ "$pool_wait" == "0" ]]; then
		# Other accounts available — immediate retry, no counter increment.
		# The next dispatch will rotate to a different account automatically.
		retry_after=0
		log_action="rate_limit_rotate (accounts available, immediate retry)"
	elif [[ "$pool_wait" == "-1" ]]; then
		# No pool configured or query failed — use exponential backoff.
		new_count=$((existing_count + 1))
		new_backoff=$((existing_backoff > 0 ? existing_backoff * 2 : FAST_FAIL_INITIAL_BACKOFF_SECS))
		[[ "$new_backoff" -gt "$FAST_FAIL_MAX_BACKOFF_SECS" ]] && new_backoff="$FAST_FAIL_MAX_BACKOFF_SECS"
		retry_after=$((now + new_backoff))
		log_action="rate_limit_no_pool (no pool data, backoff=${new_backoff}s)"
	else
		# All accounts exhausted — wait for earliest recovery.
		# Use pool_wait for retry_after but keep backoff_secs on the
		# exponential ladder so a subsequent failure doesn't reset to
		# a short pool cooldown value.
		new_count=$((existing_count + 1))
		retry_after=$((now + pool_wait))
		new_backoff=$((existing_backoff > 0 ? existing_backoff * 2 : FAST_FAIL_INITIAL_BACKOFF_SECS))
		[[ "$new_backoff" -gt "$FAST_FAIL_MAX_BACKOFF_SECS" ]] && new_backoff="$FAST_FAIL_MAX_BACKOFF_SECS"
		log_action="rate_limit_exhausted (all accounts rate-limited, wait=${pool_wait}s, backoff_stage=${new_backoff}s)"
	fi

	printf '%s\t%s\t%s\t%s\n' "$new_count" "$new_backoff" "$retry_after" "$log_action"
	return 0
}

#######################################
# Compute retry strategy for non-rate-limit failures (exponential backoff).
#
# Always increments the counter and doubles the backoff window, capped at
# FAST_FAIL_MAX_BACKOFF_SECS.
#
# Arguments:
#   $1 - existing_count
#   $2 - existing_backoff (backoff_secs)
#   $3 - current timestamp (seconds since epoch)
# Stdout: TAB-delimited: new_count<TAB>new_backoff<TAB>retry_after<TAB>log_action
#######################################
_ff_compute_failure_strategy() {
	local existing_count="$1"
	local existing_backoff="$2"
	local now="$3"

	local new_count=$((existing_count + 1))
	local new_backoff=$((existing_backoff > 0 ? existing_backoff * 2 : FAST_FAIL_INITIAL_BACKOFF_SECS))
	[[ "$new_backoff" -gt "$FAST_FAIL_MAX_BACKOFF_SECS" ]] && new_backoff="$FAST_FAIL_MAX_BACKOFF_SECS"
	local retry_after=$((now + new_backoff))
	local log_action="failure_backoff (count=${new_count}, backoff=${new_backoff}s)"

	printf '%s\t%s\t%s\t%s\n' "$new_count" "$new_backoff" "$retry_after" "$log_action"
	return 0
}

_ff_current_aidevops_version() {
	local version_file=""
	for version_file in \
		"${AGENTS_DIR:-${HOME}/.aidevops/agents}/VERSION" \
		"${SCRIPT_DIR:-${BASH_SOURCE[0]%/*}}/../VERSION" \
		"${SCRIPT_DIR:-${BASH_SOURCE[0]%/*}}/../../VERSION"; do
		if [[ -f "$version_file" ]]; then
			tr -d '[:space:]' <"$version_file" 2>/dev/null || true
			return 0
		fi
	done
	printf '0.0.0'
	return 0
}

_ff_version_gt() {
	local left="$1"
	local right="$2"
	local left_rest="$left"
	local right_rest="$right"
	local left_parts=(0 0 0)
	local right_parts=(0 0 0)
	local i=0

	while [[ "$i" -lt 3 && "$left_rest" =~ ([0-9]+) ]]; do
		left_parts[$i]="${BASH_REMATCH[1]}"
		left_rest="${left_rest#*"${BASH_REMATCH[1]}"}"
		i=$((i + 1))
	done

	i=0
	while [[ "$i" -lt 3 && "$right_rest" =~ ([0-9]+) ]]; do
		right_parts[$i]="${BASH_REMATCH[1]}"
		right_rest="${right_rest#*"${BASH_REMATCH[1]}"}"
		i=$((i + 1))
	done

	for i in 0 1 2; do
		if [[ $((10#${left_parts[$i]})) -gt $((10#${right_parts[$i]})) ]]; then
			return 0
		fi
		if [[ $((10#${left_parts[$i]})) -lt $((10#${right_parts[$i]})) ]]; then
			return 1
		fi
	done
	return 1
}

_ff_release_retry_reset_if_newer() {
	local issue_number="$1"
	local repo_slug="$2"
	local precomputed_state="${3:-}"
	local precomputed_current_version="${4:-}"

	[[ "${FAST_FAIL_RELEASE_RETRY_RESET_ENABLED:-1}" == "1" ]] || return 1
	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1
	[[ -n "$repo_slug" ]] || return 1

	if [[ -n "$precomputed_state" ]]; then
		local precheck_key="" precheck_current_version="" precheck_failure_version="" precheck_reset_version="" precheck_policy="" precheck_reset_count=""
		precheck_key=$(_ff_key "$issue_number" "$repo_slug")
		precheck_current_version="$precomputed_current_version"
		[[ -n "$precheck_current_version" ]] || precheck_current_version=$(_ff_current_aidevops_version)
		precheck_failure_version=$(printf '%s' "$precomputed_state" | jq -r --arg k "$precheck_key" '.[$k].aidevops_version // ""' 2>/dev/null) || precheck_failure_version=""
		precheck_reset_version=$(printf '%s' "$precomputed_state" | jq -r --arg k "$precheck_key" '.[$k].release_retry_reset_version // ""' 2>/dev/null) || precheck_reset_version=""
		precheck_policy=$(printf '%s' "$precomputed_state" | jq -r --arg k "$precheck_key" --arg default_policy "$_FF_RELEASE_RESET_POLICY_SOURCE_STATE_REQUIRED" '.[$k].release_reset_policy // $default_policy' 2>/dev/null) || precheck_policy="$_FF_RELEASE_RESET_POLICY_SOURCE_STATE_REQUIRED"
		precheck_reset_count=$(printf '%s' "$precomputed_state" | jq -r --arg k "$precheck_key" '.[$k].release_retry_reset_count // 0' 2>/dev/null) || precheck_reset_count=0
		[[ -n "$precheck_failure_version" ]] || precheck_failure_version="0.0.0"
		[[ -n "$precheck_current_version" ]] || return 1
		[[ "$precheck_policy" == "release-sensitive" ]] || return 1
		[[ "$precheck_reset_count" -lt "${FAST_FAIL_RELEASE_RETRY_MAX_RESETS:-1}" ]] || return 1
		[[ "$precheck_reset_version" != "$precheck_current_version" ]] || return 1
		_ff_version_gt "$precheck_current_version" "$precheck_failure_version" || return 1
	fi

	_ff_with_lock _ff_release_retry_reset_if_newer_locked "$issue_number" "$repo_slug" "$precomputed_current_version"
	return $?
}

_ff_release_retry_reset_if_newer_locked() {
	local issue_number="$1"
	local repo_slug="$2"
	local precomputed_current_version="${3:-}"

	local key="" state="" current_version="" failure_version="" reset_version="" reset_policy="" reset_count=""
	key=$(_ff_key "$issue_number" "$repo_slug")
	state=$(_ff_load)
	current_version="$precomputed_current_version"
	[[ -n "$current_version" ]] || current_version=$(_ff_current_aidevops_version)
	failure_version=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].aidevops_version // ""' 2>/dev/null) || failure_version=""
	reset_version=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].release_retry_reset_version // ""' 2>/dev/null) || reset_version=""
	reset_policy=$(printf '%s' "$state" | jq -r --arg k "$key" --arg default_policy "$_FF_RELEASE_RESET_POLICY_SOURCE_STATE_REQUIRED" '.[$k].release_reset_policy // $default_policy' 2>/dev/null) || reset_policy="$_FF_RELEASE_RESET_POLICY_SOURCE_STATE_REQUIRED"
	reset_count=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].release_retry_reset_count // 0' 2>/dev/null) || reset_count=0

	[[ -n "$failure_version" ]] || failure_version="0.0.0"
	[[ -n "$current_version" ]] || return 1
	[[ "$reset_policy" == "release-sensitive" ]] || return 1
	[[ "$reset_count" -lt "${FAST_FAIL_RELEASE_RETRY_MAX_RESETS:-1}" ]] || return 1
	[[ "$reset_version" != "$current_version" ]] || return 1
	_ff_version_gt "$current_version" "$failure_version" || return 1

	local now="" updated_state=""
	now=$(date +%s)
	updated_state=$(printf '%s' "$state" | jq \
		--arg k "$key" \
		--arg current "$current_version" \
		--arg previous "$failure_version" \
		--argjson ts "$now" \
		'.[$k].count = 0 | .[$k].retry_after = 0 | .[$k].release_retry_reset_version = $current | .[$k].release_retry_reset_from = $previous | .[$k].release_retry_reset_ts = $ts | .[$k].release_retry_reset_count = ((.[$k].release_retry_reset_count // 0) + 1)' \
		2>/dev/null) || return 1
	_ff_save "$updated_state"
	echo "[pulse-wrapper] fast_fail_release_retry_reset: #${issue_number} (${repo_slug}) reset stale failure from aidevops ${failure_version} under current ${current_version}" >>"$LOGFILE"
	return 0
}

#######################################
# Record a worker failure for an issue with cause-aware retry strategy.
#
# Rate-limit failures query the account pool before deciding on backoff.
# Non-rate-limit failures use exponential backoff (10m → 20m → ... → 7d).
#
# Acquires a file lock to prevent lost updates from concurrent
# pulse-wrapper and worker-watchdog writes. (GH#2076, GH#17384)
#
# Arguments:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - reason (rate_limit, backoff, stall, idle, thrash, runtime,
#                no_worker_process, cli_usage_output, local_error, etc.)
#   $4 - provider (optional, for rate-limit pool queries; default: anthropic)
#   $5 - crash_type (optional: "overwhelmed" | "no_work" | "partial" | "")
#   $6 - attempt_id (optional exact objective correlation; resolved from ledger when omitted)
#######################################
fast_fail_record() {
	local issue_number="$1"
	local repo_slug="$2"
	local reason="${3:-launch_failure}"
	local attempt_id="${6:-}"
	local record_rc=0

	if declare -F _worker_attempt_id_for_issue >/dev/null 2>&1; then
		attempt_id=$(_worker_attempt_id_for_issue "$issue_number" "$repo_slug" "$attempt_id") || attempt_id=""
	fi
	if [[ -n "$attempt_id" ]] && declare -F _objective_disposition_suppresses >/dev/null 2>&1 && \
		_objective_disposition_suppresses suppress_fast_fail "$issue_number" "$repo_slug" "$attempt_id"; then
		echo "[pulse-wrapper] fast_fail_record: #${issue_number} (${repo_slug}) suppressed by reconciled objective outcome" >>"$LOGFILE"
		return 0
	fi

	_ff_with_lock _fast_fail_record_locked "$@" || record_rc=$?
	if [[ "$record_rc" -eq 2 ]]; then
		_ff_route_terminal_consolidation "$issue_number" "$repo_slug" \
			"fast-fail-hard-stop" "reason=${reason}" || true
	fi
	return 0
}

_fast_fail_record_locked() {
	local issue_number="$1"
	local repo_slug="$2"
	local reason="${3:-launch_failure}"
	local provider="${4:-anthropic}"
	local crash_type="${5:-}"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0

	# Pre-launch/preflight failures (for example worker_launch_rc_2 and canary
	# preflight aborts) do not prove a worker reached the issue brief. Keep them
	# out of the per-issue fast-fail state so they cannot cascade into no_work or
	# stale_timeout circuit-breaker trips.
	if declare -F _worker_failure_reason_is_launch_preflight >/dev/null 2>&1; then
		if _worker_failure_reason_is_launch_preflight "$reason"; then
			echo "[pulse-wrapper] fast_fail_record: #${issue_number} (${repo_slug}) skipped launch/preflight reason=${reason}" >>"$LOGFILE"
			return 0
		fi
	fi
	if declare -F _worker_failure_reason_is_completion_infrastructure >/dev/null 2>&1; then
		if _worker_failure_reason_is_completion_infrastructure "$reason"; then
			printf '[pulse-wrapper] fast_fail_record: #%s (%s) skipped completion infrastructure reason=%s\n' \
				"$issue_number" "$repo_slug" "$reason" >>"$LOGFILE"
			return 0
		fi
	fi

	local key="" now="" state=""
	key=$(_ff_key "$issue_number" "$repo_slug")
	now=$(date +%s)
	state=$(_ff_load)

	# Parse existing entry, resetting count/backoff if the entry has expired.
	local existing_count existing_backoff
	IFS=$'\t' read -r existing_count existing_backoff \
		<<<"$(_ff_parse_entry "$state" "$key" "$now")"

	# Determine whether this is a rate-limit class failure.
	local is_rate_limit=false
	case "$reason" in
	rate_limit* | backoff) is_rate_limit=true ;;
	esac

	# ── Compute retry strategy based on failure cause ──
	local new_count new_backoff retry_after log_action
	if [[ "$is_rate_limit" == "true" ]]; then
		IFS=$'\t' read -r new_count new_backoff retry_after log_action \
			<<<"$(_ff_compute_rate_limit_strategy "$existing_count" "$existing_backoff" "$provider" "$now")"
	else
		IFS=$'\t' read -r new_count new_backoff retry_after log_action \
			<<<"$(_ff_compute_failure_strategy "$existing_count" "$existing_backoff" "$now")"
	fi

	# Write updated state (include crash_type for diagnostics).
	local updated_state="" aidevops_version="" release_reset_policy=""
	aidevops_version=$(_ff_current_aidevops_version)
	release_reset_policy=$(_fast_fail_release_reset_policy "$reason" "${crash_type:-}")
	updated_state=$(printf '%s' "$state" | jq \
		--arg k "$key" \
		--argjson count "$new_count" \
		--argjson ts "$now" \
		--arg reason "$reason" \
		--argjson retry_after "$retry_after" \
		--argjson backoff_secs "$new_backoff" \
		--arg crash_type "${crash_type:-}" \
		--arg aidevops_version "$aidevops_version" \
		--arg release_reset_policy "$release_reset_policy" \
		'.[$k] = ((.[$k] // {}) + {"count": $count, "ts": $ts, "reason": $reason, "retry_after": $retry_after, "backoff_secs": $backoff_secs, "crash_type": $crash_type, "aidevops_version": $aidevops_version, "release_reset_policy": $release_reset_policy})' 2>/dev/null) || return 0

	# Flag for enrichment on first non-rate-limit failure: a thinking-tier worker
	# will analyze the issue and add implementation guidance before re-dispatch.
	# Only set once — cleared after enrichment runs.
	if [[ "$is_rate_limit" == "$_FF_BOOL_FALSE" && "$new_count" -eq 1 ]]; then
		updated_state=$(printf '%s' "$updated_state" | jq \
			--arg k "$key" \
			'.[$k].enrichment_needed = true' 2>/dev/null) || true
	fi

	_ff_save "$updated_state"
	echo "[pulse-wrapper] fast_fail_record: #${issue_number} (${repo_slug}) ${log_action} reason=${reason} crash_type=${crash_type:-unclassified}" >>"$LOGFILE"

	# Trigger tier escalation on non-rate-limit failures only (GH#2076).
	# Rate-limit paths (rate_limit*, backoff) don't escalate — the model isn't
	# the problem, it's provider capacity. Escalating would waste a higher tier.
	# Pass crash_type to escalate_issue_tier for crash-type-aware thresholds:
	# "overwhelmed" escalates immediately, others use default threshold.
	if [[ "$is_rate_limit" == "$_FF_BOOL_FALSE" && "$new_count" -gt "$existing_count" ]]; then
		escalate_issue_tier "$issue_number" "$repo_slug" "$new_count" "$reason" "$crash_type" || true
	fi

	# Return an internal sentinel when a non-rate-limit failure first crosses
	# the hard-stop threshold. The public wrapper releases the state lock before
	# invoking GitHub-backed consolidation machinery.
	if _ff_terminal_threshold_crossed "$existing_count" "$new_count" "$is_rate_limit"; then
		return 2
	fi

	return 0
}

#######################################
# Reset the fast-fail counter for an issue.
#
# Called when an issue is confirmed resolved (PR merged, issue closed) —
# NOT on launch success. Previously this was called on launch, which
# defeated the counter entirely since every launch reset it before the
# worker could fail. (GH#2076, GH#17378)
#
# Arguments: $1 issue_number, $2 repo_slug
#######################################
fast_fail_reset() {
	_ff_with_lock _fast_fail_reset_locked "$@" || return 0
	return 0
}

_fast_fail_reset_locked() {
	local issue_number="$1"
	local repo_slug="$2"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0

	local key state updated_state
	key=$(_ff_key "$issue_number" "$repo_slug")
	state=$(_ff_load)

	# Only write if the key exists (avoid unnecessary writes)
	local existing
	existing=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k] // null' 2>/dev/null)
	if [[ "$existing" == "null" || -z "$existing" ]]; then
		return 0
	fi

	updated_state=$(printf '%s' "$state" | jq --arg k "$key" 'del(.[$k])' 2>/dev/null) || return 0
	_ff_save "$updated_state"
	echo "[pulse-wrapper] fast_fail_reset: #${issue_number} (${repo_slug}) counter cleared" >>"$LOGFILE"
	return 0
}

#######################################
# Auto-reset the fast-fail counter when an issue has been HARD STOP'd for
# longer than FAST_FAIL_AGE_OUT_SECONDS with no new failures (quiet period).
# Called BEFORE fast_fail_is_skipped in the dispatch loop so permanently-stuck
# issues auto-recover once the transient root cause is resolved upstream.
#
# Only acts on issues at or above FAST_FAIL_AGE_OUT_MIN_COUNT (same as the
# HARD STOP threshold). Issues below the threshold are dispatching normally
# under backoff and should not be interfered with.
#
# Safety ceiling (t2397): after FAST_FAIL_AGE_OUT_MAX_RESETS consecutive
# auto-resets without a successful dispatch, structurally blocks non-capacity
# failures and routes them to terminal consolidation.
#
# Arguments: $1 issue_number, $2 repo_slug
#######################################
fast_fail_age_out() {
	local issue_number="$1"
	local repo_slug="$2"
	local age_out_rc=0

	_ff_with_lock _fast_fail_age_out_locked "$@" || age_out_rc=$?
	if [[ "$age_out_rc" -eq 2 ]]; then
		_ff_route_terminal_consolidation "$issue_number" "$repo_slug" \
			"fast-fail-age-out-ceiling" "maximum automatic resets exhausted" || true
	fi
	return 0
}

_fast_fail_age_out_locked() {
	local issue_number="$1"
	local repo_slug="$2"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 0
	[[ -n "$repo_slug" ]] || return 0

	local key now state
	key=$(_ff_key "$issue_number" "$repo_slug")
	now=$(date +%s)
	state=$(_ff_load)

	local existing_ts="" existing_count="" existing_reset_count="" existing_reason="" existing_crash_type=""
	existing_ts=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].ts // 0' 2>/dev/null) || existing_ts=0
	existing_count=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].count // 0' 2>/dev/null) || existing_count=0
	existing_reset_count=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].reset_count // 0' 2>/dev/null) || existing_reset_count=0
	existing_reason=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].reason // ""' 2>/dev/null) || existing_reason=""
	existing_crash_type=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].crash_type // ""' 2>/dev/null) || existing_crash_type=""
	[[ "$existing_ts" =~ ^[0-9]+$ ]] || existing_ts=0
	[[ "$existing_count" =~ ^[0-9]+$ ]] || existing_count=0
	[[ "$existing_reset_count" =~ ^[0-9]+$ ]] || existing_reset_count=0

	# Only age-out issues at or above the HARD STOP threshold.
	local min_count="${FAST_FAIL_AGE_OUT_MIN_COUNT:-${FAST_FAIL_SKIP_THRESHOLD:-5}}"
	if [[ "$existing_count" -lt "$min_count" ]]; then
		return 0
	fi

	# Quiet-period check: last failure must be >= AGE_OUT_SECONDS ago.
	# Infra/no-work hard stops are cheaper to retry once the runner/provider
	# recovers. Use a shorter default so review-cleanup issues do not remain
	# stranded behind stale runtime failures for a full operator cycle.
	local age_out_secs="${FAST_FAIL_AGE_OUT_SECONDS:-3600}"
	case "${existing_reason}:${existing_crash_type}" in
	no_worker_process:* | worker_noop_zero_output:* | rate_limit*:* | backoff:* | stale_timeout:no_work)
		age_out_secs="${FAST_FAIL_INFRA_AGE_OUT_SECONDS:-900}"
		;;
	esac
	local age
	age=$((now - existing_ts))
	if [[ "$age" -lt "$age_out_secs" ]]; then
		return 0
	fi

	local hours
	hours=$((age / 3600))
	local new_reset_count
	new_reset_count=$((existing_reset_count + 1))
	local max_resets="${FAST_FAIL_AGE_OUT_MAX_RESETS:-3}"

	# Safety ceiling: capacity failures remain time-bounded and self-healing;
	# other repeated failures become structurally blocked and consolidated.
	if [[ "$new_reset_count" -gt "$max_resets" ]]; then
		case "$existing_reason" in
		rate_limit* | backoff)
			new_reset_count="$max_resets"
			echo "[pulse-wrapper] fast_fail_age_out: #${issue_number} (${repo_slug}) reached ${max_resets} capacity resets — retaining bounded automatic recovery" >>"$LOGFILE"
			;;
		*)
			echo "[pulse-wrapper] fast_fail_age_out: #${issue_number} (${repo_slug}) exceeded ${max_resets} auto-resets without success — applying status:blocked" >>"$LOGFILE"
			if declare -F set_issue_status >/dev/null 2>&1; then
				set_issue_status "$issue_number" "$repo_slug" "blocked" >>"$LOGFILE" 2>&1 || true
			else
				gh issue edit "$issue_number" --repo "$repo_slug" \
					--add-label "status:blocked" >>"$LOGFILE" 2>&1 || true
			fi
			return 2
			;;
		esac
	fi

	# Reset counter: count=0, retry_after=0, record reset metadata for audit.
	local updated_state
	updated_state=$(printf '%s' "$state" | jq \
		--arg k "$key" \
		--argjson ts "$now" \
		--argjson rcount "$new_reset_count" \
		'.[$k].count = 0 | .[$k].retry_after = 0 | .[$k].last_reset_ts = $ts | .[$k].reset_count = $rcount' \
		2>/dev/null) || return 0
	_ff_save "$updated_state"
	echo "[pulse-wrapper] fast_fail_age_out: reset #${issue_number} (${repo_slug}) count from ${existing_count} to 0 (last failure ${hours}h ago, auto-reset #${new_reset_count}/${max_resets})" >>"$LOGFILE"

	# Post an issue comment so operators see when auto-recovery fires.
	local comment_body
	comment_body=$(printf '<!-- fast-fail-age-out:%s -->\nFast-fail counter auto-reset after %sh quiet period (auto-reset #%s of max %s); pulse will retry dispatch.' \
		"$new_reset_count" "$hours" "$new_reset_count" "$max_resets")
	gh issue comment "$issue_number" --repo "$repo_slug" --body "$comment_body" >>"$LOGFILE" 2>&1 || true
	return 0
}

#######################################
# Check if an issue should be skipped due to retry backoff.
#
# An issue is skipped when EITHER condition is true:
#   1. retry_after is in the future (backoff timer hasn't expired)
#   2. count >= FAST_FAIL_SKIP_THRESHOLD (hard stop — too many failures)
#
# The distinction matters for diagnostics:
#   - Condition 1: "waiting for backoff/rate-limit to clear"
#   - Condition 2: "this issue is fundamentally broken, needs human"
#
# Exit codes:
#   0 - issue is skipped (do NOT dispatch)
#   1 - issue is not skipped (safe to dispatch)
# Arguments: $1 issue_number, $2 repo_slug
#######################################
fast_fail_is_skipped() {
	local issue_number="$1"
	local repo_slug="$2"

	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1
	[[ -n "$repo_slug" ]] || return 1

	local key
	local now
	local state
	local existing_ts
	local existing_count
	local existing_retry_after
	local existing_reason
	local consolidation_routed
	key=$(_ff_key "$issue_number" "$repo_slug")
	now=$(date +%s)
	state=$(_ff_load)
	if printf '%s' "$state" | jq -e --arg k "$key" '.[$k] != null' >/dev/null 2>&1; then
		if _ff_release_retry_reset_if_newer "$issue_number" "$repo_slug" "$state"; then
			return 1
		fi
		state=$(_ff_load)
	fi

	existing_ts=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].ts // 0' 2>/dev/null) || existing_ts=0
	existing_count=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].count // 0' 2>/dev/null) || existing_count=0
	existing_retry_after=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].retry_after // 0' 2>/dev/null) || existing_retry_after=0
	existing_reason=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].reason // ""' 2>/dev/null) || existing_reason=""
	consolidation_routed=$(printf '%s' "$state" | jq -r --arg k "$key" '.[$k].terminal_consolidation_routed // false' 2>/dev/null) || consolidation_routed=false
	[[ "$existing_ts" =~ ^[0-9]+$ ]] || existing_ts=0
	[[ "$existing_count" =~ ^[0-9]+$ ]] || existing_count=0
	[[ "$existing_retry_after" =~ ^[0-9]+$ ]] || existing_retry_after=0

	# Check overall expiry (entire entry is stale).
	# Mirror fast_fail_prune_expired(): only expire when BOTH the ts is old
	# AND the retry_after window has passed. This prevents discarding entries
	# that still have an active backoff timer (e.g., rate-limit waits).
	local age=$((now - existing_ts))
	if [[ "$age" -ge "$FAST_FAIL_EXPIRY_SECS" && "$existing_retry_after" -le "$now" ]]; then
		return 1 # Expired — not skipped
	fi

	# Hard stop: too many non-rate-limit failures
	if [[ "$existing_count" -ge "$FAST_FAIL_SKIP_THRESHOLD" ]]; then
		echo "[pulse-wrapper] fast_fail_is_skipped: #${issue_number} (${repo_slug}) HARD STOP count=${existing_count}>=${FAST_FAIL_SKIP_THRESHOLD}" >>"$LOGFILE"
		case "$existing_reason" in
		rate_limit* | backoff) ;;
		*)
			if [[ "$consolidation_routed" != "true" ]]; then
				_ff_route_terminal_consolidation "$issue_number" "$repo_slug" \
					"fast-fail-hard-stop" "reason=${existing_reason:-unknown} count=${existing_count}" || true
			fi
			;;
		esac
		return 0 # Skipped
	fi

	# Backoff timer: retry_after is in the future
	if [[ "$existing_retry_after" -gt "$now" ]]; then
		local wait_remaining=$((existing_retry_after - now))
		echo "[pulse-wrapper] fast_fail_is_skipped: #${issue_number} (${repo_slug}) BACKOFF wait=${wait_remaining}s retry_after=$(date -r "$existing_retry_after" '+%H:%M:%S' 2>/dev/null || echo "$existing_retry_after")" >>"$LOGFILE"
		return 0 # Skipped — backoff timer active
	fi

	return 1 # Safe to dispatch
}

#######################################
# Prune expired entries from the fast-fail state file.
# An entry is expired when its ts is older than FAST_FAIL_EXPIRY_SECS
# AND its retry_after has passed (we don't prune entries that still
# have an active backoff timer, even if they're old).
# Called periodically to keep the file small.
#######################################
fast_fail_prune_expired() {
	_ff_with_lock _fast_fail_prune_expired_locked || return 0
	return 0
}

_fast_fail_prune_expired_locked() {
	local now state pruned
	now=$(date +%s)
	state=$(_ff_load)

	pruned=$(printf '%s' "$state" | jq \
		--argjson now "$now" \
		--argjson expiry "$FAST_FAIL_EXPIRY_SECS" \
		'with_entries(select(
			(($now - (.value.ts // 0)) < $expiry) or
			((.value.retry_after // 0) > $now)
		))' 2>/dev/null) || return 0

	local before_count after_count
	before_count=$(printf '%s' "$state" | jq 'length' 2>/dev/null) || before_count=0
	after_count=$(printf '%s' "$pruned" | jq 'length' 2>/dev/null) || after_count=0

	if [[ "$before_count" -ne "$after_count" ]]; then
		_ff_save "$pruned"
		echo "[pulse-wrapper] fast_fail_prune_expired: pruned $((before_count - after_count)) expired entries" >>"$LOGFILE"
	fi
	return 0
}

# Mark enrichment as done in the fast-fail state (called under lock).
_ff_mark_enrichment_done() {
	local issue_number="$1"
	local repo_slug="$2"
	local key state

	key=$(_ff_key "$issue_number" "$repo_slug")
	state=$(_ff_load)

	local updated_state
	updated_state=$(printf '%s' "$state" | jq \
		--arg k "$key" \
		'if .[$k] then .[$k].enrichment_needed = false | .[$k].enrichment_done = true else . end' \
		2>/dev/null) || return 0

	_ff_save "$updated_state"
	return 0
}
