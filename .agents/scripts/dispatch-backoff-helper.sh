#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# dispatch-backoff-helper.sh — Per-issue rate_limit backoff gate (t2781, GH#20680)
#
# Prevents repeated dispatch of issues that repeatedly produce rate_limit exits.
# Reads headless-runtime-metrics.jsonl to count per-issue rate_limit exits within
# a lookback window, then applies a graduated cooldown.
#
# Problem being solved:
#   headless-runtime-metrics.jsonl shows 407 rate_limit events (~31.5h burn).
#   The existing fast_fail rate_limit path immediately retries when another account
#   is available — so a pool of N accounts means an issue can fail N times per
#   cycle with zero cooldown. This compounds cost at scale.
#
# Backoff schedule (tuned against observed 407-event cluster):
#   failures | cooldown
#   ---------|----------
#   1        | 5 min  (300s)   — single fluke; retry quickly
#   2        | 30 min (1800s)  — pattern emerging; cool off
#   3        | 2h     (7200s)  — systemic; wait for capacity recovery
#   4+       | 24h    (86400s) — one-shot extended-cooldown notice
#
# Subcommands:
#   check <issue_num> [<slug>]  — exit 0 if clear, exit 1 if cooldown active,
#                                 exit 2 on error (fail-open: dispatch proceeds)
#   classify-lookup-failure <signal>
#                              — print transient, persistent, or unknown
#   lookup-retry-delay <signal> <attempt>
#                              — print an evidence-aware bounded delay
#   help                        — usage information
#
# Exit codes (check):
#   0  — clear; dispatch may proceed
#   1  — cooldown active; prints "BACKOFF_ACTIVE reason=rate_limit_cooldown next=<ts>"
#        and next-eligible human timestamp to stderr
#   2  — error (fail-open: dispatch proceeds with warning logged)
#
# Environment overrides:
#   DISPATCH_BACKOFF_METRICS_FILE     — path to headless-runtime-metrics.jsonl
#                                       (default: ~/.aidevops/logs/headless-runtime-metrics.jsonl)
#   DISPATCH_BACKOFF_LOOKBACK_SECS    — how far back to count failures (default 604800 = 7 days)
#   DISPATCH_BACKOFF_NMR_THRESHOLD    — legacy-named threshold for the extended cooldown notice (default 4)
#   DISPATCH_PROVIDER_BACKOFF_WINDOW_SECS — provider/model pressure window (default 900 = 15 min)
#   DISPATCH_PROVIDER_BACKOFF_THRESHOLD   — rate_limit count that trips pressure cooldown (default 6)
#   DISPATCH_PROVIDER_BACKOFF_COOLDOWN_SECS — provider/model cooldown after last event (default 300 = 5 min)
#   AIDEVOPS_SKIP_DISPATCH_BACKOFF=1  — emergency bypass (dispatch proceeds unconditionally)
#
# Integration:
#   Sourced by pulse-dispatch-engine.sh. The check_dispatch_backoff() function
#   is called in _dispatch_should_skip_candidate() after fast_fail_is_skipped().
#   At the extended-notice threshold, the caller reads BACKOFF_NOTICE_REQUIRED
#   and posts a one-shot diagnostic. The cooldown remains the dispatch block.
#
# Counter:
#   dispatch_backoff_skipped in ~/.aidevops/logs/pulse-stats.json
#   (via pulse-stats-helper.sh / pulse_stats_increment). Surfaced by `aidevops status`.
#
# Why read JSONL instead of a separate state file:
#   The JSONL is the authoritative, tamper-evident record of per-worker outcomes.
#   A separate state file would diverge on crash, restart, or manual recovery.
#   awk processes the JSONL in O(n) with a 500K file in <10ms — cheap enough
#   for every dispatch cycle candidate.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# Source pulse-stats-helper.sh for counter support (optional — fail-open if missing).
# shellcheck source=pulse-stats-helper.sh
if [[ -f "${SCRIPT_DIR}/pulse-stats-helper.sh" ]]; then
	# shellcheck disable=SC1091
	source "${SCRIPT_DIR}/pulse-stats-helper.sh"
fi

# LOGFILE for sourced-mode usage (caller sets it; standalone mode defines a default).
LOGFILE="${LOGFILE:-${HOME}/.aidevops/logs/pulse.log}"

# Configuration (overridable via environment).
DISPATCH_BACKOFF_METRICS_FILE="${DISPATCH_BACKOFF_METRICS_FILE:-${HOME}/.aidevops/logs/headless-runtime-metrics.jsonl}"
DISPATCH_BACKOFF_LOOKBACK_SECS="${DISPATCH_BACKOFF_LOOKBACK_SECS:-604800}"  # 7 days
DISPATCH_BACKOFF_NMR_THRESHOLD="${DISPATCH_BACKOFF_NMR_THRESHOLD:-4}"       # legacy name: 4+ failures → extended notice
DISPATCH_PROVIDER_BACKOFF_WINDOW_SECS="${DISPATCH_PROVIDER_BACKOFF_WINDOW_SECS:-900}"
DISPATCH_PROVIDER_BACKOFF_THRESHOLD="${DISPATCH_PROVIDER_BACKOFF_THRESHOLD:-6}"
DISPATCH_PROVIDER_BACKOFF_COOLDOWN_SECS="${DISPATCH_PROVIDER_BACKOFF_COOLDOWN_SECS:-300}"
: "${AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_OVERRIDE:=0}"

# Backoff intervals in seconds (indexed by failure count; index 0 unused).
# Index >= the extended-notice threshold uses the last entry (86400 = 24h).
readonly _BACKOFF_SCHEDULE=(0 300 1800 7200 86400)  # [0]=unused [1]=5m [2]=30m [3]=2h [4+]=24h

# Log prefix for all messages from this module.
_DB_LOG_PREFIX="[dispatch-backoff]"

#######################################
# Classify a dispatch lookup failure without weakening fail-closed callers.
# Persistent local/data failures must never be retried. Network/provider
# failures are transient only when the signal contains concrete evidence.
#
# Args: $1 - failure signal
# Stdout: transient, persistent, or unknown
#######################################
_db_classify_lookup_failure() {
	local signal="$1"
	local normalized=""
	normalized=$(printf '%s' "$signal" | tr '[:upper:]' '[:lower:]')

	case "$normalized" in
	*jq-failure* | *malformed* | *invalid-json* | *"invalid json"* | *auth-failure* | *unauthorized* | *forbidden* | *not-found* | *"not found"* | *" 401"* | *" 403"* | *" 404"*)
		printf 'persistent\n'
		;;
	*rate-limit* | *"rate limit"* | *retry-after* | *reset=* | *timeout* | *"timed out"* | *temporary* | *temporarily* | *"connection reset"* | *"connection closed"* | *"connection refused"* | *" 502"* | *" 503"* | *" 504"*)
		printf 'transient\n'
		;;
	*gh-api-failure*rc=[1-9]*)
		printf 'transient\n'
		;;
	*)
		printf 'unknown\n'
		;;
	esac
	return 0
}

#######################################
# Derive a non-immediate retry delay from Retry-After/reset evidence or use a
# small bounded delay for another explicitly transient signal.
#
# Args: $1 - failure signal, $2 - retry attempt (1-based)
# Stdout: delay seconds
# Returns: 0 when delay is within the configured bound, 1 otherwise
#######################################
_db_lookup_retry_delay() {
	local signal="$1"
	local attempt="$2"
	local delay=""
	local now=""
	local reset_epoch=""
	local max_delay="${AIDEVOPS_DSI_MAX_RETRY_DELAY_SECONDS:-60}"

	if [[ "$signal" =~ [Rr]etry-[Aa]fter[^0-9]*([0-9]+) ]]; then
		delay="${BASH_REMATCH[1]}"
	elif [[ "$signal" =~ reset[^0-9]*([0-9]{10}) ]]; then
		reset_epoch="${BASH_REMATCH[1]}"
		now=$(date +%s)
		delay=$((reset_epoch - now))
	else
		delay="$attempt"
	fi

	[[ "$delay" =~ ^[0-9]+$ ]] || return 1
	[[ "$max_delay" =~ ^[0-9]+$ ]] || max_delay=60
	((delay < 1)) && delay=1
	if ((delay > max_delay)); then
		return 1
	fi
	printf '%s\n' "$delay"
	return 0
}

#######################################
# Compute cooldown seconds for a given failure count.
#
# Args:
#   $1 - failure_count (integer >= 1)
# Stdout: cooldown in seconds
#######################################
_db_cooldown_for_count() {
	local count="$1"
	local max_idx=$(( ${#_BACKOFF_SCHEDULE[@]} - 1 ))
	local idx="$count"
	[[ "$idx" -gt "$max_idx" ]] && idx="$max_idx"
	[[ "$idx" -lt 1 ]] && idx=1
	printf '%s\n' "${_BACKOFF_SCHEDULE[$idx]}"
	return 0
}

#######################################
# Count rate_limit exits for an issue in the metrics JSONL within the lookback window.
#
# Uses jq for JSONL parsing — select() filters matching entries in a single
# pass. BSD awk (macOS default) does not support capture groups in match(),
# so awk-based parsing would fail silently. jq is a hard framework dependency.
#
# Returns two values on stdout: "<count> <last_ts>"
#   count   — number of rate_limit entries in the lookback window
#   last_ts — epoch of the most recent rate_limit entry (0 if count=0)
#
# Args:
#   $1 - issue_number (integer)
#   $2 - since_epoch  (only count entries with ts >= this)
# Stdout: "count last_ts"
#######################################
_db_count_rate_limit_events() {
	local issue_number="$1"
	local since_epoch="$2"
	local session_key="issue-${issue_number}"
	local metrics_file="$DISPATCH_BACKOFF_METRICS_FILE"

	if [[ ! -f "$metrics_file" ]]; then
		printf '0 0\n'
		return 0
	fi

	# jq JSONL parser: select matching entries (session_key, rate-limit-equivalent
	# signal, ts >= since), emit ts values, collect count and max. Single pass over
	# the file.
	# --slurp reads all lines into an array for aggregate operations.
	# Fallback: if jq fails, return "0 0" (fail-open).
	local result
	result=$(jq -r --arg sk "$session_key" --argjson since "$since_epoch" \
		'select(
			.session_key == $sk
			and (
				(.result // "") == "rate_limit"
				or (.result // "") == "rate_limit_fast"
				or (.provider_error_type // "") == "rate_limit"
				or ((.provider_status // "") | tostring) == "429"
			)
			and (.ts // 0) >= $since
		) | .ts' \
		"$metrics_file" 2>/dev/null \
		| awk 'BEGIN{count=0;last=0} {count++; if($1+0>last+0)last=$1+0} END{printf "%d %d\n",count,last}' \
		2>/dev/null) || result="0 0"

	[[ -n "$result" ]] || result="0 0"
	printf '%s\n' "$result"
	return 0
}

#######################################
# Count recent provider/model-wide rate_limit pressure.
#
# Stdout: "<count> <last_ts> <provider> <model>" for the hottest provider/model,
# or "0 0 unknown unknown" when no pressure exists. This protects the pool from
# launching many different issues into the same constrained provider account.
#
# Args:
#   $1 - since_epoch
#######################################
_db_count_provider_rate_limit_pressure() {
	local since_epoch="$1"
	local metrics_file="$DISPATCH_BACKOFF_METRICS_FILE"

	if [[ ! -f "$metrics_file" ]]; then
		printf '0 0 unknown unknown\n'
		return 0
	fi

	local result
	result=$(jq -rs --argjson since "$since_epoch" '
		map(select((((.result // "") == "rate_limit" or (.result // "") == "rate_limit_fast" or (.provider_error_type // "") == "rate_limit" or ((.provider_status // "") | tostring) == "429") and (.ts // 0) >= $since)))
		| group_by([.provider // "unknown", .model // "unknown"])
		| map({provider: (.[0].provider // "unknown"), model: (.[0].model // "unknown"), count: length, last: (map(.ts // 0) | max)})
		| sort_by(.count, .last)
		| last // {provider:"unknown", model:"unknown", count:0, last:0}
		| "\(.count) \(.last) \(.provider) \(.model)"
	' "$metrics_file" 2>/dev/null) || result="0 0 unknown unknown"

	[[ -n "$result" ]] || result="0 0 unknown unknown"
	printf '%s\n' "$result"
	return 0
}

#######################################
# Check provider/model-wide pressure backoff.
#
# Args:
#   $1 - now epoch
#######################################
_db_check_provider_pressure_backoff() {
	local now="$1"
	local threshold="$DISPATCH_PROVIDER_BACKOFF_THRESHOLD"
	local window_secs="$DISPATCH_PROVIDER_BACKOFF_WINDOW_SECS"
	local cooldown_secs="$DISPATCH_PROVIDER_BACKOFF_COOLDOWN_SECS"

	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=6
	[[ "$window_secs" =~ ^[0-9]+$ ]] || window_secs=900
	[[ "$cooldown_secs" =~ ^[0-9]+$ ]] || cooldown_secs=300
	if [[ "$threshold" -le 0 || "$window_secs" -le 0 || "$cooldown_secs" -le 0 ]]; then
		return 0
	fi

	local since=$(( now - window_secs ))
	[[ "$since" -lt 0 ]] && since=0

	local pressure_result
	pressure_result=$(_db_count_provider_rate_limit_pressure "$since") || pressure_result="0 0 unknown unknown"

	local count last_ts provider model
	read -r count last_ts provider model <<<"$pressure_result"
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	[[ "$last_ts" =~ ^[0-9]+$ ]] || last_ts=0

	if [[ "$count" -lt "$threshold" ]]; then
		return 0
	fi

	local next_eligible=$(( last_ts + cooldown_secs ))
	if [[ "$now" -ge "$next_eligible" ]]; then
		return 0
	fi

	local wait_remaining=$(( next_eligible - now ))
	local next_human
	next_human=$(date -r "$next_eligible" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || \
		date -d "@${next_eligible}" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || \
		printf 'epoch:%s' "$next_eligible")

	printf 'BACKOFF_ACTIVE reason=provider_rate_limit_pressure provider=%s model=%s count=%s window=%ss cooldown=%ss wait=%ss next=%s\n' \
		"$provider" "$model" "$count" "$window_secs" "$cooldown_secs" "$wait_remaining" "$next_human" >&2
	echo "${_DB_LOG_PREFIX} BACKOFF_ACTIVE provider_pressure provider=${provider} model=${model} count=${count} window=${window_secs}s cooldown=${cooldown_secs}s wait=${wait_remaining}s next=${next_human}" >>"$LOGFILE"
	if declare -F pulse_stats_increment >/dev/null 2>&1; then
		pulse_stats_increment "dispatch_provider_backoff_skipped" 2>/dev/null || true
	fi
	return 1
}

#######################################
# Check comment-based transient rate-limit release circuit state.
#
# The release path posts a consolidated marker after repeated
# `CLAIM_RELEASED reason=rate_limit_transient` comments. This dispatch-side
# gate honours that marker so the issue is paused until cooldown expiry or an
# explicit maintainer override comment.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - now epoch
# Returns: 0 clear, 1 cooldown active, 2 error/fail-open.
#######################################
_db_check_rate_limit_release_circuit_comment() {
	local issue_number="$1"
	local repo_slug="$2"
	local now="$3"

	if [[ "$AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_OVERRIDE" == "1" ]]; then
		return 0
	fi

	local comments_json=""
	comments_json=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments?per_page=100" \
		--jq '[.[] | {created_at: .created_at, body: (.body // "")}]' 2>/dev/null) || return 2
	[[ -n "$comments_json" ]] || return 0

	local circuit_data=""
	circuit_data=$(printf '%s' "$comments_json" | jq -c '
		{
			marker: ([.[] | select((.body // "") | contains("rate-limit-release-circuit-breaker"))] | last // null),
			override: ([.[] | select((.body // "") | contains("rate-limit-release-circuit-breaker:override")) | .created_at] | max // "")
		}
	') || return 2

	local marker_json=""
	marker_json=$(printf '%s' "$circuit_data" | jq -c '.marker // empty') || return 2
	[[ -n "$marker_json" ]] || return 0

	local latest_override=""
	latest_override=$(printf '%s' "$circuit_data" | jq -r '.override // ""') || return 2

	local marker_created=""
	marker_created=$(printf '%s' "$marker_json" | jq -r '.created_at // ""') || return 2
	if [[ -n "$latest_override" && -n "$marker_created" && "$latest_override" > "$marker_created" ]]; then
		return 0
	fi

	local marker_line=""
	marker_line=$(printf '%s' "$marker_json" | jq -r '.body // ""' | grep -oE '<!-- rate-limit-release-circuit-breaker[^>]*-->' | tail -1) || marker_line=""
	[[ -n "$marker_line" ]] || return 0

	local next_epoch=""
	next_epoch=$(printf '%s' "$marker_line" | grep -oE 'next_epoch=[0-9]+' | cut -d= -f2 || true)
	[[ "$next_epoch" =~ ^[0-9]+$ ]] || return 0

	if [[ "$now" -ge "$next_epoch" ]]; then
		return 0
	fi

	local wait_remaining=$(( next_epoch - now ))
	local next_human
	next_human=$(date -r "$next_epoch" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || \
		date -d "@${next_epoch}" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || \
		printf 'epoch:%s' "$next_epoch")

	printf 'BACKOFF_ACTIVE reason=rate_limit_release_circuit wait=%ss next=%s\n' \
		"$wait_remaining" "$next_human" >&2
	echo "${_DB_LOG_PREFIX} BACKOFF_ACTIVE #${issue_number} (${repo_slug}) rate_limit_release_circuit wait=${wait_remaining}s next=${next_human}" >>"$LOGFILE"
	if declare -F pulse_stats_increment >/dev/null 2>&1; then
		pulse_stats_increment "dispatch_backoff_skipped" 2>/dev/null || true
	fi
	return 1
}

#######################################
# Check whether dispatch backoff is active for an issue.
#
# Reads headless-runtime-metrics.jsonl for recent rate_limit events,
# applies the graduated cooldown schedule, and returns exit 1 if
# the cooldown window is still active.
#
# Called from _dispatch_should_skip_candidate() in pulse-dispatch-engine.sh
# immediately after fast_fail_is_skipped().
#
# Exit codes:
#   0 — clear; dispatch may proceed
#   1 — cooldown active; prints BACKOFF_ACTIVE line to stderr
#   2 — error; fail-open (caller should log warning and proceed)
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug (informational only — JSONL does not include slug)
#######################################
check_dispatch_backoff() {
	local issue_number="$1"
	local repo_slug="${2:-unknown}"

	# Emergency bypass.
	if [[ "${AIDEVOPS_SKIP_DISPATCH_BACKOFF:-0}" == "1" ]]; then
		echo "${_DB_LOG_PREFIX} AIDEVOPS_SKIP_DISPATCH_BACKOFF=1 — bypassing rate-limit backoff check" >>"$LOGFILE"
		return 0
	fi

	# Validate input.
	if [[ ! "$issue_number" =~ ^[0-9]+$ ]]; then
		echo "${_DB_LOG_PREFIX} WARNING: invalid issue_number '${issue_number}' — proceeding (fail-open)" >>"$LOGFILE"
		return 2
	fi

	local now
	now=$(date +%s 2>/dev/null) || now=0
	if [[ "$now" -eq 0 ]]; then
		echo "${_DB_LOG_PREFIX} WARNING: could not get current epoch — proceeding (fail-open)" >>"$LOGFILE"
		return 2
	fi

	local since=$(( now - DISPATCH_BACKOFF_LOOKBACK_SECS ))
	[[ "$since" -lt 0 ]] && since=0

	local provider_pressure_rc=0
	_db_check_provider_pressure_backoff "$now" || provider_pressure_rc=$?
	if [[ "$provider_pressure_rc" -eq 1 ]]; then
		return 1
	fi

	local release_circuit_rc=0
	_db_check_rate_limit_release_circuit_comment "$issue_number" "$repo_slug" "$now" || release_circuit_rc=$?
	if [[ "$release_circuit_rc" -eq 1 ]]; then
		return 1
	fi
	if [[ "$release_circuit_rc" -eq 2 ]]; then
		echo "${_DB_LOG_PREFIX} WARNING: rate-limit release circuit comment check failed for #${issue_number} (${repo_slug}) — proceeding (fail-open)" >>"$LOGFILE"
	fi

	# Count recent rate_limit events.
	local count_result
	count_result=$(_db_count_rate_limit_events "$issue_number" "$since") || count_result="0 0"

	local count last_ts
	read -r count last_ts <<<"$count_result"
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	[[ "$last_ts" =~ ^[0-9]+$ ]] || last_ts=0

	if [[ "$count" -eq 0 ]]; then
		# No recent rate_limit events — clear for dispatch.
		return 0
	fi

	# Compute cooldown window.
	local cooldown_secs
	cooldown_secs=$(_db_cooldown_for_count "$count")
	local next_eligible=$(( last_ts + cooldown_secs ))

	if [[ "$now" -lt "$next_eligible" ]]; then
		# Cooldown still active.
		local wait_remaining=$(( next_eligible - now ))
		local next_human
		next_human=$(date -r "$next_eligible" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || \
			date -d "@${next_eligible}" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || \
			printf 'epoch:%s' "$next_eligible")

		local notice_flag=""
		if [[ "$count" -ge "$DISPATCH_BACKOFF_NMR_THRESHOLD" ]]; then
			notice_flag=" BACKOFF_NOTICE_REQUIRED"
		fi

		printf 'BACKOFF_ACTIVE reason=rate_limit_cooldown count=%s cooldown=%ss wait=%ss next=%s%s\n' \
			"$count" "$cooldown_secs" "$wait_remaining" "$next_human" "$notice_flag" >&2

		echo "${_DB_LOG_PREFIX} BACKOFF_ACTIVE #${issue_number} (${repo_slug}) count=${count} cooldown=${cooldown_secs}s wait=${wait_remaining}s next=${next_human}${notice_flag}" >>"$LOGFILE"

		# Increment stats counter.
		if declare -F pulse_stats_increment >/dev/null 2>&1; then
			pulse_stats_increment "dispatch_backoff_skipped" 2>/dev/null || true
		fi

		return 1
	fi

	# Cooldown has elapsed — clear for dispatch.
	echo "${_DB_LOG_PREFIX} backoff elapsed for #${issue_number} (${repo_slug}) count=${count} last_rate_limit=$(date -r "$last_ts" '+%H:%M:%S' 2>/dev/null || printf '%s' "$last_ts") — dispatch may proceed" >>"$LOGFILE"
	return 0
}

#######################################
# Post a one-shot diagnostic when rate_limit failures exceed the extended
# backoff threshold. The time-bounded cooldown remains the machine-recoverable
# dispatch block; no maintainer trust label is applied.
#
# Idempotent: only posts the notice once per issue (uses a marker comment).
# Best-effort: failures are logged but never fatal.
#
# Args:
#   $1 - issue_number
#   $2 - repo_slug
#   $3 - failure_count
#######################################
_db_record_extended_backoff_notice() {
	local issue_number="$1"
	local repo_slug="$2"
	local failure_count="$3"

	local notice_marker="<!-- dispatch-backoff:extended_cooldown -->"

	# Idempotency check.
	local existing_notice=""
	existing_notice=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--jq "[.[] | select(.body | contains(\"dispatch-backoff:extended_cooldown\"))] | length" \
		2>/dev/null) || existing_notice=""
	if [[ "$existing_notice" =~ ^[1-9][0-9]*$ ]]; then
		echo "${_DB_LOG_PREFIX} extended-backoff notice already posted for #${issue_number} (${repo_slug}) — skipping" >>"$LOGFILE"
		return 0
	fi

	# Post diagnostic comment.
	local body="${notice_marker}
## Rate-Limit Backoff Circuit Breaker (t2781)

**Trigger:** ${failure_count} rate_limit failure(s) for this issue within the lookback window (threshold: ${DISPATCH_BACKOFF_NMR_THRESHOLD}).
**Action:** Extended the machine-managed cooldown to 24h. Dispatch resumes automatically after capacity recovers and the cooldown elapses.

**Why this remains a cooldown:** Worker rate_limit failures are NOT a problem with author authority, issue content, or model tier — they indicate provider capacity exhaustion specific to this issue's account/provider pairing. Escalating to a higher tier would not help.

**Possible causes:**
- Provider rate limits for the account(s) dispatching this issue are exhausted
- The issue's model/tier routing hits a heavily contended capacity tier
- Multiple concurrent dispatches competing for the same limited capacity

**Recommended actions:**
1. Check \`aidevops status\` for current GraphQL budget and account pool state
2. Rotate or add accounts via \`model-accounts-pool-helper.sh\`
3. Wait for provider rate-limit reset (typically 1h for Anthropic, 24h for OpenAI tier limits)
4. No trust approval is needed; the next eligible pulse retries automatically

_Per-issue rate_limit backoff circuit breaker (t2781). The cooldown state, not a review label, is the dispatch fuse._"

	if declare -F gh_issue_comment >/dev/null 2>&1; then
		gh_issue_comment "$issue_number" --repo "$repo_slug" --body "$body" 2>/dev/null || true
	else
		gh issue comment "$issue_number" --repo "$repo_slug" --body "$body" 2>/dev/null || true
	fi

	echo "${_DB_LOG_PREFIX} extended-backoff notice posted for #${issue_number} (${repo_slug}) count=${failure_count}" >>"$LOGFILE"
	return 0
}

#######################################
# Standalone CLI entry point.
#######################################
_main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	classify-lookup-failure)
		local failure_signal="${1:-}"
		_db_classify_lookup_failure "$failure_signal"
		return 0
		;;
	lookup-retry-delay)
		local failure_signal="${1:-}"
		local retry_attempt="${2:-1}"
		_db_lookup_retry_delay "$failure_signal" "$retry_attempt"
		return $?
		;;
	check)
			local issue_number="${1:-}"
			local slug="${2:-unknown}"

			if [[ -z "$issue_number" ]]; then
				printf 'Error: issue_number required\n' >&2
				printf 'Usage: dispatch-backoff-helper.sh check <issue_number> [<slug>]\n' >&2
				return 1
			fi

			local backoff_stderr_output=""
			local backoff_rc=0
			backoff_stderr_output=$(check_dispatch_backoff "$issue_number" "$slug" 2>&1 >/dev/null) || backoff_rc=$?

			case "$backoff_rc" in
				0)
					printf 'CLEAR: no active rate_limit backoff for issue #%s\n' "$issue_number"
					return 0
					;;
				1)
					printf '%s\n' "$backoff_stderr_output"

					# Post the extended-cooldown notice once at the threshold.
					if printf '%s' "$backoff_stderr_output" | grep -q 'BACKOFF_NOTICE_REQUIRED'; then
						local count_field
						count_field=$(printf '%s' "$backoff_stderr_output" | grep -oE 'count=[0-9]+' | head -1 | cut -d= -f2)
						[[ "$count_field" =~ ^[0-9]+$ ]] || count_field="$DISPATCH_BACKOFF_NMR_THRESHOLD"
						_db_record_extended_backoff_notice "$issue_number" "$slug" "$count_field"
					fi
					return 1
					;;
				*)
					printf 'WARNING: backoff check error (fail-open)\n' >&2
					return 2
					;;
			esac
			;;
		help | --help | -h)
			printf 'dispatch-backoff-helper.sh — Per-issue rate_limit backoff gate (t2781)\n\n'
			printf 'Usage:\n'
			printf '  dispatch-backoff-helper.sh check <issue_num> [<slug>]  # exit 0=clear, 1=backoff active, 2=error\n'
			printf '  dispatch-backoff-helper.sh classify-lookup-failure <signal>\n'
			printf '  dispatch-backoff-helper.sh lookup-retry-delay <signal> <attempt>\n'
			printf '\n'
			printf 'Environment:\n'
			printf '  DISPATCH_BACKOFF_METRICS_FILE      path to headless-runtime-metrics.jsonl\n'
			printf '  DISPATCH_BACKOFF_LOOKBACK_SECS     lookback window in seconds (default 604800 = 7 days)\n'
			printf '  DISPATCH_BACKOFF_NMR_THRESHOLD     legacy name: failure count triggering extended notice (default 4)\n'
			printf '  AIDEVOPS_SKIP_DISPATCH_BACKOFF=1   emergency bypass\n'
			return 0
			;;
		*)
			printf 'Unknown command: %s\n' "$cmd" >&2
			printf 'Run: dispatch-backoff-helper.sh help\n' >&2
			return 1
			;;
	esac
}

# Only run _main when executed directly (not sourced).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	_main "$@"
fi
