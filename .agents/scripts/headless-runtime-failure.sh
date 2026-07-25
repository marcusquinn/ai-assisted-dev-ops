#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Headless Runtime Failure — Dispatch Claim & Fast-Fail (GH#19699)
# =============================================================================
# Failure reporting functions extracted from headless-runtime-lib.sh to reduce
# file size. Handles dispatch claim release and fast-fail counter management.
#
# Covers:
#   1. Dispatch claim release — post CLAIM_RELEASED comments to unblock re-dispatch
#   2. Fast-fail state      — acquire locks, read/write counter state, report
#                              failures with exponential backoff and tier escalation
#
# Usage: source "${SCRIPT_DIR}/headless-runtime-failure.sh"
#
# Dependencies:
#   - shared-constants.sh (print_warning, print_info)
#   - worker-lifecycle-common.sh (escalate_issue_tier)
#   - gh CLI, jq
#   - bash 3.2+
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_FAILURE_LOADED:-}" ]] && return 0
readonly _HEADLESS_RUNTIME_FAILURE_LOADED=1

_HRFF_SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
if [[ -r "${_HRFF_SCRIPT_DIR}/lib/version.sh" ]]; then
	# shellcheck source=lib/version.sh
	source "${_HRFF_SCRIPT_DIR}/lib/version.sh"
fi
if [[ -r "${_HRFF_SCRIPT_DIR}/gh-signature-helper-detect.sh" ]]; then
	# shellcheck source=gh-signature-helper-detect.sh
	source "${_HRFF_SCRIPT_DIR}/gh-signature-helper-detect.sh"
fi
if [[ -r "${_HRFF_SCRIPT_DIR}/shared-repo-state-guard.sh" ]]; then
	# shellcheck source=shared-repo-state-guard.sh
	source "${_HRFF_SCRIPT_DIR}/shared-repo-state-guard.sh"
fi
unset _HRFF_SCRIPT_DIR
: "${AIDEVOPS_UNKNOWN_VERSION:=unknown}"

# Fallback exit reason — backward-compatible value used when classify_worker_exit
# cannot determine the actual cause (missing sqlite3, corrupt DB, unexpected format).
# Recognised by dispatch-dedup-helper.sh: any CLAIM_RELEASED is treated as
# authoritative regardless of reason value.
readonly _HRFF_FALLBACK_EXIT="process_exit"
readonly _HRFF_PRELAUNCH_NOT_INVOKED="worker_runtime_not_invoked"

# Per-issue transient rate-limit release circuit breaker (t3570 / GH#23102).
# These defaults intentionally keep the first transient failures visible while
# suppressing repeated CLAIM_RELEASED storms during provider capacity outages.
: "${AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_THRESHOLD:=3}"
: "${AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_LOOKBACK_SECS:=86400}"
: "${AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_COOLDOWN_SECS:=1800}"

#######################################
# Convert an epoch to a UTC-ish human timestamp for audit comments.
#
# Args:
#   $1 = epoch seconds
#######################################
_hrff_epoch_to_utc() {
	local epoch="$1"
	date -u -r "$epoch" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
		date -u -d "@${epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
		printf 'epoch:%s' "$epoch"
	return 0
}

#######################################
# Return recent issue comments needed by the rate-limit release breaker.
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
#######################################
_hrff_rate_limit_release_comments_json() {
	local issue_number="$1"
	local repo_slug="$2"

	gh api "repos/${repo_slug}/issues/${issue_number}/comments?per_page=100" \
		--jq '[.[] | {created_at: .created_at, body: (.body // "")}]' 2>/dev/null || return 1
	return 0
}

#######################################
# Check whether the transient rate-limit release breaker is currently active.
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
#   $3 = now_epoch
#   $4 = comments_json
# Returns: 0 active, 1 inactive.
#######################################
_hrff_rate_limit_release_circuit_active() {
	local issue_number="$1"
	local repo_slug="$2"
	local now_epoch="$3"
	local comments_json="$4"

	if [[ "${AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_OVERRIDE:-0}" == "1" ]]; then
		return 1
	fi

	local latest_override=""
	latest_override=$(printf '%s' "$comments_json" | jq -r \
		'[.[] | select((.body // "") | test("rate-limit-release-circuit-breaker:override")) | .created_at] | max // ""' \
		2>/dev/null) || latest_override=""

	local marker_line=""
	marker_line=$(printf '%s' "$comments_json" | jq -r \
		'[.[] | select((.body // "") | contains("rate-limit-release-circuit-breaker")) | .body] | last // ""' \
		2>/dev/null | grep -oE '<!-- rate-limit-release-circuit-breaker[^>]*-->' | tail -1) || marker_line=""

	[[ -n "$marker_line" ]] || return 1

	local next_epoch=""
	next_epoch=$(printf '%s' "$marker_line" | grep -oE 'next_epoch=[0-9]+' | cut -d= -f2 || true)
	[[ "$next_epoch" =~ ^[0-9]+$ ]] || return 1

	if [[ -n "$latest_override" ]]; then
		local marker_created=""
		marker_created=$(printf '%s' "$comments_json" | jq -r --arg marker "$marker_line" \
			'[.[] | select((.body // "") | contains($marker)) | .created_at] | last // ""' \
			2>/dev/null) || marker_created=""
		if [[ -n "$marker_created" && "$latest_override" > "$marker_created" ]]; then
			return 1
		fi
	fi

	if [[ "$now_epoch" -lt "$next_epoch" ]]; then
		print_info "Transient rate-limit release circuit active for #${issue_number} (${repo_slug}); suppressing duplicate CLAIM_RELEASED until $(_hrff_epoch_to_utc "$next_epoch")"
		return 0
	fi

	return 1
}

#######################################
# Count recent transient rate-limit release comments for an issue.
#
# Args:
#   $1 = comments_json
#   $2 = since_epoch
#######################################
_hrff_count_recent_rate_limit_releases() {
	local comments_json="$1"
	local since_epoch="$2"

	printf '%s' "$comments_json" | jq -r --argjson since "$since_epoch" '
		[.[]
		 | select((.body // "") | contains("CLAIM_RELEASED reason=rate_limit_transient"))
		 | select(((.created_at // "1970-01-01T00:00:00Z") | fromdateiso8601? // 0) >= $since)
		] | length' 2>/dev/null || printf '0'
	return 0
}

#######################################
# Post one consolidated audit comment once the threshold is crossed.
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
#   $3 = count_after_increment
#   $4 = next_epoch
#######################################
_hrff_post_rate_limit_release_circuit_comment() {
	local issue_number="$1"
	local repo_slug="$2"
	local count_after_increment="$3"
	local next_epoch="$4"

	local next_human=""
	next_human=$(_hrff_epoch_to_utc "$next_epoch")
	local cooldown_secs="$AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_COOLDOWN_SECS"
	local body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
<!-- rate-limit-release-circuit-breaker issue=${issue_number} count=${count_after_increment} next_epoch=${next_epoch} -->
RATE_LIMIT_RELEASE_CIRCUIT active=true count=${count_after_increment} cooldown=${cooldown_secs}s next=${next_human}

Repeated transient provider rate-limit releases for this issue reached the circuit-breaker threshold. Further duplicate \`CLAIM_RELEASED reason=rate_limit_transient\` audit comments are suppressed until ${next_human} to reduce comment storms and wasted dispatch cycles.

Dispatch resumes after the cooldown expires. Maintainers can override early by posting a comment containing \`rate-limit-release-circuit-breaker:override\`.
<!-- ops:end -->"

	gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
		--method POST \
		--field body="$body" \
		>/dev/null 2>&1 || print_warning "Failed to post rate-limit release circuit comment on #${issue_number} (non-fatal)"
	return 0
}

#######################################
# Evaluate the transient rate-limit release breaker before posting a release.
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
# Returns: 0 post normal release, 1 suppress duplicate release comment.
#######################################
_hrff_handle_rate_limit_release_circuit() {
	local issue_number="$1"
	local repo_slug="$2"

	local now_epoch=""
	now_epoch=$(date +%s 2>/dev/null) || now_epoch=0
	[[ "$now_epoch" =~ ^[0-9]+$ ]] || now_epoch=0

	local comments_json=""
	comments_json=$(_hrff_rate_limit_release_comments_json "$issue_number" "$repo_slug") || comments_json=""
	[[ -n "$comments_json" ]] || return 0

	if _hrff_rate_limit_release_circuit_active "$issue_number" "$repo_slug" "$now_epoch" "$comments_json"; then
		return 1
	fi

	local threshold="$AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_THRESHOLD"
	local lookback="$AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_LOOKBACK_SECS"
	local cooldown="$AIDEVOPS_RATE_LIMIT_RELEASE_CIRCUIT_COOLDOWN_SECS"
	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=3
	[[ "$lookback" =~ ^[0-9]+$ ]] || lookback=86400
	[[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown=1800
	[[ "$threshold" -gt 0 ]] || return 0

	local since_epoch=$(( now_epoch - lookback ))
	[[ "$since_epoch" -lt 0 ]] && since_epoch=0
	local previous_count=""
	previous_count=$(_hrff_count_recent_rate_limit_releases "$comments_json" "$since_epoch") || previous_count=0
	[[ "$previous_count" =~ ^[0-9]+$ ]] || previous_count=0
	local count_after_increment=$(( previous_count + 1 ))

	if [[ "$count_after_increment" -ge "$threshold" ]]; then
		local next_epoch=$(( now_epoch + cooldown ))
		_hrff_post_rate_limit_release_circuit_comment "$issue_number" "$repo_slug" "$count_after_increment" "$next_epoch"
	fi

	return 0
}

#######################################
# Return success when a GitHub issue unlock failure is benign.
#
# GitHub treats unlocking an already-unlocked issue as a failed mutation in some
# gh/API paths. Release cleanup calls unlock defensively after active-state
# cleanup, so that already-clean state should not produce pulse warnings.
#
# Args:
#   $1 = gh failure output
#######################################
_hrff_unlock_failure_is_benign() {
	local unlock_output="$1"

	if [[ "$unlock_output" =~ [Aa]lready[[:space:]-]+unlocked ]] || \
		[[ "$unlock_output" =~ [Nn]ot[[:space:]-]+locked ]] || \
		[[ "$unlock_output" =~ [Cc]onversation[[:space:]]+is[[:space:]]+not[[:space:]]+locked ]] || \
		[[ "$unlock_output" =~ [Ii]ssue[[:space:]]+is[[:space:]]+not[[:space:]]+locked ]]; then
		return 0
	fi
	return 1
}

#######################################
# Unlock the issue once a worker releases its dispatch claim.
#
# Worker dispatch locks the issue before launch. Release paths already clear
# active labels/assignees; they must also clear the conversation lock so the
# public issue state matches the released claim and future workers/maintainers
# do not see `status:available` on a locked issue.
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
#######################################
_unlock_issue_after_dispatch_release() {
	local issue_number="$1"
	local repo_slug="$2"
	local unlock_output=""

	[[ -n "$issue_number" && -n "$repo_slug" ]] || return 0
	if [[ "$issue_number" =~ ^0[0-9]+$ ]]; then
		print_info "Skipping release unlock for local task ID ${issue_number} in ${repo_slug}: not a GitHub issue number"
		return 0
	fi

	unlock_output=$(gh issue unlock "$issue_number" --repo "$repo_slug" 2>&1) || {
		if _hrff_unlock_failure_is_benign "$unlock_output"; then
			print_info "Release unlock skipped for GitHub issue #${issue_number} in ${repo_slug}: already unlocked"
			return 0
		fi
		print_warning "Failed to unlock released GitHub issue #${issue_number} in ${repo_slug} (non-fatal): ${unlock_output:-unknown error}"
	}
	return 0
}

#######################################
# Check whether dispatch release may mutate issue state for a repo.
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
#######################################
_hrff_release_repo_state_is_managed() {
	local issue_number="$1"
	local repo_slug="$2"

	if declare -F aidevops_can_manage_repo_issue_state >/dev/null 2>&1; then
		if ! aidevops_can_manage_repo_issue_state "$repo_slug"; then
			print_info "Skipping CLAIM_RELEASED for #${issue_number} in ${repo_slug}: repo state is not managed by this account"
			return 1
		fi
	fi
	return 0
}

#######################################
# Resolve the issue number for a dispatch claim release.
#
# Args:
#   $1 = session_key
# Outputs:
#   Issue number when available.
#######################################
_hrff_release_issue_number() {
	local session_key="$1"

	# Extract issue number from the explicit worker contract first, then fall back
	# only to canonical issue-scoped session keys. Non-task sessions can
	# legitimately end in digits (for example validation timestamps); treating
	# arbitrary trailing digits as issue numbers causes fake GitHub cleanup writes.
	if [[ "${WORKER_ISSUE_NUMBER:-}" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$WORKER_ISSUE_NUMBER"
		return 0
	fi
	if [[ "$session_key" =~ ^issue-([0-9]+)$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi

	return 0
}

#######################################
# Validate whether claim release has enough context to proceed.
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
#######################################
_hrff_release_context_is_valid() {
	local issue_number="$1"
	local repo_slug="$2"

	if [[ -z "$issue_number" && -z "$repo_slug" ]]; then
		return 1
	fi
	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		print_warning "Cannot release claim: missing issue=$issue_number repo=$repo_slug"
		return 1
	fi

	return 0
}

#######################################
# Clear active state without posting a duplicate rate-limit release comment.
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
#######################################
_hrff_release_rate_limit_circuit_cleanup() {
	local issue_number="$1"
	local repo_slug="$2"
	local runner_name=""

	runner_name=$(_hrff_resolve_release_runner_login)
	if declare -F clear_active_status_on_release >/dev/null 2>&1; then
		clear_active_status_on_release "$issue_number" "$repo_slug" "$runner_name" \
			|| print_warning "Failed to clear active status on #${issue_number} (non-fatal)"
	fi
	_unlock_issue_after_dispatch_release "$issue_number" "$repo_slug"
	return 0
}

#######################################
# Build the machine-readable claim release audit line.
#
# Args:
#   $1 = reason
#   $2 = runner_name
#   $3 = exit_code
#   $4 = session_count
# Outputs:
#   CLAIM_RELEASED line.
#######################################
_hrff_build_claim_released_line() {
	local reason="$1"
	local runner_name="$2"
	local exit_code_arg="$3"
	local session_count_arg="$4"
	local aidevops_version="${AIDEVOPS_UNKNOWN_VERSION:-}"
	local opencode_version="${AIDEVOPS_UNKNOWN_VERSION:-}"
	local release_ts=""
	local machine_readable_part=""

	if declare -F aidevops_find_version >/dev/null 2>&1; then
		aidevops_version=$(aidevops_find_version 2>/dev/null || printf '%s' "$AIDEVOPS_UNKNOWN_VERSION")
	fi
	if declare -F _detect_opencode_version >/dev/null 2>&1; then
		opencode_version=$(_detect_opencode_version 2>/dev/null || printf '%s' "")
		opencode_version="${opencode_version:-$AIDEVOPS_UNKNOWN_VERSION}"
	fi

	release_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	machine_readable_part="CLAIM_RELEASED reason=${reason} runner=${runner_name} ts=${release_ts} aidevops_version=${aidevops_version} opencode_version=${opencode_version}"
	if [[ -n "$exit_code_arg" ]]; then
		machine_readable_part+=" exit=${exit_code_arg}"
	fi
	if [[ -n "$session_count_arg" ]]; then
		machine_readable_part+=" session_count=${session_count_arg}"
	fi

	printf '%s\n' "$machine_readable_part"
	return 0
}

#######################################
# Post the CLAIM_RELEASED audit comment.
#
# Args:
#   $1 = issue_number
#   $2 = repo_slug
#   $3 = comment_body
#######################################
_hrff_post_claim_released_comment() {
	local issue_number="$1"
	local repo_slug="$2"
	local comment_body="$3"
	local attempts="${AIDEVOPS_CLAIM_RELEASE_POST_ATTEMPTS:-3}"
	local retry_delay="${AIDEVOPS_CLAIM_RELEASE_POST_RETRY_DELAY:-1}"
	local attempt=1
	local post_error=""

	[[ "$attempts" =~ ^[1-9][0-9]*$ ]] || attempts=3
	[[ "$retry_delay" =~ ^[0-9]+$ ]] || retry_delay=1
	while [[ "$attempt" -le "$attempts" ]]; do
		if post_error=$(gh api "repos/${repo_slug}/issues/${issue_number}/comments" \
			--method POST \
			--field body="$comment_body" \
			2>&1 >/dev/null); then
			return 0
		fi
		post_error="${post_error//$'\n'/ }"
		post_error="${post_error:0:240}"
		if [[ "$attempt" -lt "$attempts" ]]; then
			print_warning "CLAIM_RELEASED persistence failed on #${issue_number} (attempt ${attempt}/${attempts}): ${post_error:-unknown}; retrying"
			[[ "$retry_delay" -eq 0 ]] || sleep "$retry_delay"
		fi
		attempt=$((attempt + 1))
	done

	print_warning "Failed to post CLAIM_RELEASED on #${issue_number} after ${attempts} attempt(s): ${post_error:-unknown}"
	return 1
}

#######################################
# Release a dispatch claim by posting a CLAIM_RELEASED comment.
# The dedup guard recognises this and allows immediate re-dispatch
# instead of waiting for the 30-min TTL to expire.
#
# Args:
#   $1 = session_key (contains issue number and repo slug)
#   $2 = reason (logged in the comment for debugging)
#   $3 = exit_code (optional — included in comment when provided by exit trap)
#   $4 = session_count (optional — session_count from worker DB for exit trap)
#######################################
_release_dispatch_claim() {
	local session_key="$1"
	local reason="${2:-worker_failed}"
	local exit_code_arg="${3:-}"
	local session_count_arg="${4:-}"
	local issue_number=""
	local repo_slug="${DISPATCH_REPO_SLUG:-}"
	local runner_name=""
	local machine_readable_part=""
	local comment_body=""

	issue_number=$(_hrff_release_issue_number "$session_key")
	if [[ -z "$issue_number" && -z "${WORKER_ISSUE_NUMBER:-}" ]]; then
		return 0
	fi

	# Supervisor/pulse cleanup paths can source this module and run the generic
	# EXIT cleanup without ever having claimed a worker issue. With no issue and
	# no repo there is no real claim to release; treat that exact empty-context
	# case as a benign caller-boundary no-op. Keep warning on partial context
	# because issue-without-repo or repo-without-issue can strand a real claim.
	if ! _hrff_release_context_is_valid "$issue_number" "$repo_slug"; then
		return 0
	fi
	_hrff_release_repo_state_is_managed "$issue_number" "$repo_slug" || return 0

	if [[ "$reason" == "rate_limit_transient" ]]; then
		if ! _hrff_handle_rate_limit_release_circuit "$issue_number" "$repo_slug"; then
			# The per-issue breaker is already active. Keep state cleanup so the
			# GitHub issue is not stranded in an active lifecycle state, but skip
			# the duplicate CLAIM_RELEASED audit comment that caused storms.
			_hrff_release_rate_limit_circuit_cleanup "$issue_number" "$repo_slug"
			return 0
		fi
	fi

	runner_name=$(_hrff_resolve_release_runner_login)
	machine_readable_part=$(_hrff_build_claim_released_line "$reason" "$runner_name" "$exit_code_arg" "$session_count_arg")
	comment_body="<!-- ops:start — workers: skip this comment, it is audit trail not implementation context -->
${machine_readable_part}
<!-- ops:end -->"

	if ! _hrff_post_claim_released_comment "$issue_number" "$repo_slug" "$comment_body"; then
		print_warning "Claim release for #${issue_number} remains unpersisted and retryable; retaining issue lifecycle state"
		return 1
	fi
	print_info "Released claim on #${issue_number} (reason: ${reason})"
	if [[ "$reason" == "${_HRW_REASON_OWNERSHIP_LOST:-worker_ownership_lost}" ]]; then
		print_info "Preserving live issue ownership for #${issue_number} after worker ownership loss"
		return 0
	fi

	# t2420: clear active-lifecycle status labels + worker assignment so the
	# pulse's combined-signal dedup guard (t1996) doesn't treat the issue
	# as active after release. Without this, orphan labels pin the issue
	# as "active" for the full 30-min TTL even though no worker holds the
	# claim, blocking re-dispatch. Preserves terminal states (done, blocked)
	# set by authoritative paths. Defensive skip if origin:interactive.
	# Non-fatal: failure does not block the release comment path.
	if declare -F clear_active_status_on_release >/dev/null 2>&1; then
		clear_active_status_on_release "$issue_number" "$repo_slug" "$runner_name" \
			|| print_warning "Failed to clear active status on #${issue_number} (non-fatal)"
	fi
	_unlock_issue_after_dispatch_release "$issue_number" "$repo_slug"
	return 0
}

#######################################
# Resolve the GitHub login whose dispatch claim should be released.
# Prefer the identity captured by the dispatcher because the local OS user can
# differ from the GitHub assignee in bot/cross-account worker setups (GH#23854).
# Globals:
#   WORKER_GITHUB_LOGIN, AIDEVOPS_WORKER_GITHUB_LOGIN
# Outputs:
#   GitHub login or OS username fallback.
#######################################
_hrff_resolve_release_runner_login() {
	local runner_login="${WORKER_GITHUB_LOGIN:-${AIDEVOPS_WORKER_GITHUB_LOGIN:-}}"
	if [[ -n "$runner_login" ]]; then
		printf '%s\n' "$runner_login"
		return 0
	fi

	if command -v gh >/dev/null 2>&1; then
		runner_login=$(gh api user --jq '.login // ""' || true)
		if [[ "$runner_login" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
			printf '%s\n' "$runner_login"
			return 0
		fi
	fi

	runner_login=$(whoami)
	printf '%s\n' "$runner_login"
	return 0
}

#######################################
# Classify worker termination reason for CLAIM_RELEASED audit lines.
# Called from _exit_trap_handler before posting the claim release.
#
# Args:
#   $1 = wait_status  (bash exit status; >128 means signal N = wait_status - 128)
#   $2 = start_epoch_ms (milliseconds epoch when worker was prepared; 0 = unknown)
#
# Globals (optional, set by _invoke_opencode / _cmd_run_prepare):
#   _WORKER_ISOLATED_DB_PATH  — path to isolated worker opencode.db (if active)
#
# Returns classification string via stdout:
#   "clean"                   — exit status 0 (unexpected in EXIT trap context)
#   "signal_killed:<signum>"  — received signal N (wait_status > 128)
#   "crash_during_startup"    — non-zero exit, no OpenCode session found in DB
#   "crash_during_execution"  — non-zero exit, session(s) present in worker DB
#   "process_exit"            — fallback when classifier cannot determine reason
#
# Exit: always 0
#######################################
classify_worker_exit() {
	local wait_status="$1"
	local start_epoch_ms="${2:-0}"

	# Signal detection: bash encodes signal N as exit status 128+N
	if [[ "$wait_status" =~ ^[0-9]+$ ]] && (( wait_status > 128 )); then
		printf '%s' "signal_killed:$((wait_status - 128))"
		return 0
	fi

	# Clean exit (unusual in EXIT trap context — trap is normally cleared on success).
	# t3050: a clean exit with zero opencode sessions means the wrapper returned 0
	# cleanly but the worker never produced model output. This is a startup-phase
	# failure (sandbox crash, OpenCode init failure, prompt parse error before
	# tool use), not a successful run. The worker_noop_zero_output reason is
	# already recognised by _maybe_reclassify_worker_failed_as_no_work in
	# worker-lifecycle-common.sh and by escalate_issue_tier — emitting it
	# directly here ensures the reason is authoritative from the trap rather
	# than inferred later from orphan-worktree state.
	if [[ "$wait_status" == "0" ]]; then
		local _shared_db_zo="${HOME}/.local/share/opencode/opencode.db"
		local _db_zo="${_WORKER_ISOLATED_DB_PATH:-}"
		[[ -z "$_db_zo" || ! -f "$_db_zo" ]] && _db_zo="$_shared_db_zo"
		if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$_db_zo" \
			&& "$start_epoch_ms" =~ ^[0-9]+$ && "$start_epoch_ms" -gt 0 ]]; then
			local _cnt_zo=""
			_cnt_zo=$(sqlite3 "$_db_zo" \
				"SELECT count(*) FROM session WHERE time_created >= ${start_epoch_ms}" \
				2>/dev/null) || _cnt_zo=""
			if [[ "$_cnt_zo" =~ ^[0-9]+$ && "$_cnt_zo" -eq 0 ]]; then
				printf '%s' "worker_noop_zero_output"
				return 0
			fi
		fi
		printf '%s' "clean"
		return 0
	fi

	# Session creation check: count sessions created since worker started.
	# Primary: isolated worker DB (still present when EXIT fires during _invoke_opencode).
	# Fallback: shared DB (~/.local/share/opencode/opencode.db) after merge completes.
	local session_count=0
	local shared_db_path="${HOME}/.local/share/opencode/opencode.db"
	local isolated_db="${_WORKER_ISOLATED_DB_PATH:-}"
	local active_db=""

	if [[ -n "$isolated_db" && -f "$isolated_db" ]]; then
		active_db="$isolated_db"
	elif [[ -f "$shared_db_path" ]]; then
		active_db="$shared_db_path"
	fi

	if ! command -v sqlite3 >/dev/null 2>&1 || [[ -z "$active_db" ]]; then
		# sqlite3 unavailable or no DB found — cannot classify by session
		print_warning "[exit-classifier] sqlite3 unavailable or DB missing (isolated=${isolated_db:-none} shared=${shared_db_path}) — using ${_HRFF_FALLBACK_EXIT} fallback"
		printf '%s' "$_HRFF_FALLBACK_EXIT"
		return 0
	fi

	local query=""
	if [[ "$start_epoch_ms" =~ ^[0-9]+$ ]] && (( start_epoch_ms > 0 )); then
		# Count sessions created at or after worker start time (ms epoch)
		query="SELECT count(*) FROM session WHERE time_created >= ${start_epoch_ms}"
	else
		# No start time: count all sessions (crude fallback — may over-count)
		query="SELECT count(*) FROM session"
	fi

	local raw_count=""
	raw_count=$(sqlite3 "$active_db" "$query" 2>/dev/null) || raw_count=""

	if [[ ! "$raw_count" =~ ^[0-9]+$ ]]; then
		# sqlite3 returned non-numeric output (e.g. error or corrupt DB)
		print_warning "[exit-classifier] sqlite3 query failed for ${active_db} — using ${_HRFF_FALLBACK_EXIT} fallback"
		printf '%s' "$_HRFF_FALLBACK_EXIT"
		return 0
	fi
	session_count="$raw_count"

	if (( session_count == 0 )); then
		printf '%s' "crash_during_startup"
	else
		printf '%s' "crash_during_execution"
	fi
	return 0
}

#######################################
# Classify worker kill_reason for the [lifecycle] worker_exited log line.
#
# t3063: surfaces the kill PATH on the same line as wait_status so Phase 2
# log aggregation finds the reason class without a PID-join across scripts.
# Complementary to classify_worker_exit (which classifies CRASH vs CLEAN);
# this answers "if killed, which kill path fired the SIGTERM/SIGKILL?".
#
# Sentinel precedence (highest to lowest):
#   1. ${exit_code_file}.kill_reason — explicit class written by kill site
#      (PR #21784/t3056 sites: hard_kill_stall, no_output_stall,
#      phase1_zero_output, wall_clock_stale, cold_start_timeout,
#      progress_timeout, idle_timeout, stop_flag, stage_timeout_*,
#      process_guard_*, wait_loop_timeout_*).
#   2. ${exit_code_file}.watchdog_stall_killed → hard_kill_stall
#      (worker exceeded HARD_KILL_SECONDS, t2956 / Issue #21231).
#   3. ${exit_code_file}.watchdog_killed → no_output_stall
#      (legacy passive watchdog kill — output file silent).
#   4. ${exit_code_file}.rate_limit_fast → rate_limit_fast
#      (30s fast-exit monitor caught 429/overload, GH#21578 / t3021).
#   5. wait_status > 128 with no sentinel → unknown
#      (signal-killed but kill path unidentified — acceptance target: 0%).
#   6. otherwise → natural
#      (clean exit or voluntary failure exit).
#
# The .kill_reason sentinel is the forward-compatible extension point: any
# kill site that adds a new class only needs to write its class string to
# ${exit_code_file}.kill_reason; this classifier picks it up without code
# changes here.
#
# Args:
#   $1 = exit_code_file path (sentinel files are checked at ${path}.<class>)
#   $2 = wait_status integer ($? from `wait`)
#
# Returns 0 always; outputs kill_reason class string on stdout.
#######################################
classify_worker_kill_reason() {
	local exit_code_file="${1:-}"
	local wait_status="${2:-0}"

	# Highest-precedence path: explicit class written by a kill site.
	if [[ -n "$exit_code_file" && -f "${exit_code_file}.kill_reason" ]]; then
		local _explicit
		_explicit=$(<"${exit_code_file}.kill_reason")
		# Strip CR/LF; bail to inference path if file is empty or whitespace-only.
		_explicit="${_explicit//$'\r'/}"
		_explicit="${_explicit//$'\n'/}"
		# Trim leading/trailing spaces and tabs (bash 3.2 compatible).
		_explicit="${_explicit#"${_explicit%%[![:space:]]*}"}"
		_explicit="${_explicit%"${_explicit##*[![:space:]]}"}"
		if [[ -n "$_explicit" ]]; then
			printf '%s' "$_explicit"
			return 0
		fi
	fi

	# Inferred classification from existing watchdog sentinels.
	# Precedence: stall_killed (hard kill) → watchdog_killed (passive stall)
	# → rate_limit_fast. The watchdog writes both .watchdog_killed and
	# .watchdog_stall_killed on a hard kill, so stall_killed must be checked first.
	if [[ -n "$exit_code_file" ]]; then
		if [[ -f "${exit_code_file}.watchdog_stall_killed" ]]; then
			printf '%s' "hard_kill_stall"
			return 0
		fi
		if [[ -f "${exit_code_file}.watchdog_killed" ]]; then
			printf '%s' "no_output_stall"
			return 0
		fi
		if [[ -f "${exit_code_file}.rate_limit_fast" ]]; then
			printf '%s' "rate_limit_fast"
			return 0
		fi
	fi

	# No sentinel — signal-killed (wait_status > 128) is "unknown"
	# (acceptance target: 0% of these); voluntary exits are "natural".
	if [[ "$wait_status" =~ ^[0-9]+$ ]] && (( wait_status > 128 )); then
		printf '%s' "unknown"
		return 0
	fi

	printf '%s' "natural"
	return 0
}

#######################################
# Preserve and push any worker WIP before worker exits.
# Best-effort, fail-open — never blocks claim release or shutdown.
#
# t2923: Prevents workers dying mid-implementation from abandoning
# unreachable commits. Next dispatch can continue from the pushed branch
# instead of rewriting the same code from scratch.
#
# GH#22965: Dirty worktrees with no local-only commits must also be
# preserved. Create a normal WIP commit from tracked/untracked work and push it;
# if commit/push cannot complete, archive a binary patch locally and mark the
# failure as worker_dirty_work_preserved so zero-output retry holds do not
# misclassify the issue as a malformed brief.
#
# Globals consumed:
#   _WORKER_WORKTREE_PATH  — set by _cmd_run_prepare in headless-runtime-helper.sh
#   WORKER_NO_EXIT_PUSH    — escape hatch: set to "1" to disable push
#######################################
_push_wip_commits_on_exit() {
	# Escape hatch: WORKER_NO_EXIT_PUSH=1 disables the push (e.g. in tests)
	[[ "${WORKER_NO_EXIT_PUSH:-0}" == "1" ]] && return 0
	_WORKER_DIRTY_WORK_PRESERVED=0

	local work_dir="${_WORKER_WORKTREE_PATH:-}"
	if [[ -z "$work_dir" || ! -d "$work_dir" ]]; then
		return 0
	fi

	# Get the branch name — skip if detached HEAD or default branch
	local branch_name=""
	branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 0
	case "$branch_name" in
	HEAD | main | master | "")
		return 0
		;;
	esac

	local dirty_status=""
	dirty_status=$(git -C "$work_dir" status --porcelain 2>/dev/null || true)
	if [[ -n "$dirty_status" ]]; then
		print_info "[lifecycle] worker_exit_preserving_dirty_work branch=${branch_name}"
		git -C "$work_dir" add -A >/dev/null 2>&1 || true
		if ! git -C "$work_dir" diff --cached --quiet --exit-code >/dev/null 2>&1; then
			if git -C "$work_dir" commit -m "wip: preserve worker changes on abnormal exit" >/dev/null 2>&1; then
				_WORKER_DIRTY_WORK_PRESERVED=1
				print_info "[lifecycle] worker_exit_committed_dirty_work branch=${branch_name}"
			else
				_worker_archive_dirty_worktree_patch "$work_dir" "$branch_name"
			fi
		else
			_worker_archive_dirty_worktree_patch "$work_dir" "$branch_name"
		fi
	fi

	# Count commits ahead of origin/main (or origin/master) — fail-open
	local ahead_count=0
	ahead_count=$(git -C "$work_dir" rev-list --count "origin/main..HEAD" 2>/dev/null || true)
	[[ "$ahead_count" =~ ^[0-9]+$ ]] || ahead_count=0
	if [[ "$ahead_count" -eq 0 ]]; then
		ahead_count=$(git -C "$work_dir" rev-list --count "origin/master..HEAD" 2>/dev/null || true)
		[[ "$ahead_count" =~ ^[0-9]+$ ]] || ahead_count=0
	fi
	if [[ "$ahead_count" -eq 0 ]]; then
		return 0
	fi

	# Push best-effort — never block exit on push failure
	print_info "[lifecycle] worker_exit_pushing_wip branch=${branch_name} ahead=${ahead_count}"
	if git -C "$work_dir" push -u origin "${branch_name}" 2>/dev/null; then
		print_info "[lifecycle] worker_exit_pushed_wip branch=${branch_name} ahead=${ahead_count}"
	else
		print_warning "[lifecycle] worker_exit_push_failed branch=${branch_name} ahead=${ahead_count}"
		_worker_archive_dirty_worktree_patch "$work_dir" "$branch_name"
	fi
	return 0
}

#######################################
# Archive dirty worktree changes as a local binary patch.
# Best-effort fallback when exit-time commit/push cannot preserve the work.
#
# Args:
#   $1 = worktree path
#   $2 = branch name
# Globals updated:
#   _WORKER_DIRTY_WORK_PRESERVED — set to 1 when an archive is written
#######################################
_worker_archive_dirty_worktree_patch() {
	local work_dir="$1"
	local branch_name="$2"
	local archive_root="${AIDEVOPS_WORKER_DIRTY_ARCHIVE_DIR:-${HOME}/.aidevops/.agent-workspace/work/dirty-worktrees}"
	local safe_branch="${branch_name//[^A-Za-z0-9._-]/_}"
	local stamp=""
	stamp=$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || printf '%s' "unknown-time")
	local archive_dir="${archive_root}/${safe_branch}-${stamp}"

	mkdir -p "$archive_dir" 2>/dev/null || return 0
	git -C "$work_dir" status --short --branch >"${archive_dir}/status.txt" 2>/dev/null || true
	if git -C "$work_dir" diff --binary --cached >"${archive_dir}/changes.patch" 2>/dev/null \
		&& [[ -s "${archive_dir}/changes.patch" ]]; then
		_WORKER_DIRTY_WORK_PRESERVED=1
		print_warning "[lifecycle] worker_dirty_work_preserved archive=${archive_dir}"
		return 0
	fi
	if git -C "$work_dir" diff --binary >"${archive_dir}/changes.patch" 2>/dev/null \
		&& [[ -s "${archive_dir}/changes.patch" ]]; then
		_WORKER_DIRTY_WORK_PRESERVED=1
		print_warning "[lifecycle] worker_dirty_work_preserved archive=${archive_dir}"
		return 0
	fi
	return 0
}

#######################################
# Finalize an EXIT-trap classification: preserve work, emit terminal evidence,
# release the claim/lock, and force a non-zero process exit when preparation
# ended cleanly before runtime invocation.
# Args: $1=session, $2=reason, $3=exit status, $4=session count, $5=force nonzero
#######################################
_hrff_finalize_exit_trap() {
	local session_key="$1"
	local reason="$2"
	local exit_status="$3"
	local session_count="$4"
	local force_nonzero_exit="$5"
	local checkpoint_reason="${_HRW_REASON_DRAFT_CHECKPOINT:-worker_draft_checkpoint}"

	print_info "[exit-trap] session=$session_key exit=$exit_status reason=$reason session_count=$session_count"
	_push_wip_commits_on_exit
	if [[ "${_WORKER_DIRTY_WORK_PRESERVED:-0}" == "1" ]]; then
		if _recover_dirty_worker_pr "$session_key"; then
			reason="$checkpoint_reason"
		else
			reason="worker_dirty_work_preserved"
		fi
	fi
	if declare -F _emit_worker_runtime_event >/dev/null 2>&1; then
		if [[ "$reason" == "worker_complete" ]]; then
			_emit_worker_runtime_event "worker.completed" "recovered" "$reason"
		elif [[ "$reason" == "$checkpoint_reason" ]]; then
			_emit_worker_runtime_event "worker.deferred" "checkpointed" "$reason"
		else
			_emit_worker_runtime_event "worker.failed" "failed" "$reason"
		fi
	fi
	if declare -F _hrw_record_terminal_outcome >/dev/null 2>&1; then
		local terminal_outcome="failed"
		local complete_reason="${_HRW_REASON_WORKER_COMPLETE:-worker_complete}"
		[[ "$reason" == "$complete_reason" ]] && terminal_outcome="success"
		[[ "$reason" == "$checkpoint_reason" ]] && terminal_outcome="deferred"
		_hrw_record_terminal_outcome "$session_key" "$terminal_outcome" "$reason"
	fi
	if declare -F _cleanup_headless_runtime_temp_paths >/dev/null 2>&1; then
		_cleanup_headless_runtime_temp_paths
	fi
	if ! _release_dispatch_claim "$session_key" "$reason" "$exit_status" "$session_count"; then
		print_warning "[exit-trap] claim release persistence remains retryable for session=${session_key} reason=${reason}"
	fi
	_release_session_lock "$session_key"
	_update_dispatch_ledger "$session_key" "fail"
	aidevops_runtime_bundle_lease_release || print_warning "Failed to release the worker runtime bundle lease"
	if [[ "$force_nonzero_exit" -eq 1 ]]; then
		trap - EXIT
		exit "$exit_status"
	fi
	return 0
}

#######################################
# Classify worker termination and post CLAIM_RELEASED. Falls back to
# process_exit when runtime/session evidence cannot identify the cause.
# Args: $1=session_key (baked into the EXIT trap at registration time)
# Globals: _WORKER_START_EPOCH_MS, _WORKER_ISOLATED_DB_PATH,
# _WORKER_WORKTREE_PATH, _WORKER_EXIT_CODE_FILE, _WORKER_RUNTIME_LAUNCH_STARTED
#######################################
_exit_trap_handler() {
	local session_key="$1"
	# Capture exit status immediately — any subsequent command will overwrite $?
	local exit_status=$?

	# t3050: prefer the worker's actual wait_status (persisted by _invoke_opencode
	# at ${exit_code_file}.wait_status) over $?. By the time EXIT fires, the
	# wrapper functions have cleanly returned 0 even when the worker subshell
	# was SIGTERM'd. Without this override, classify_worker_exit reads $?=0
	# from the trap and emits reason=clean for SIGTERM/SIGKILL kills (canonical
	# failure: GH#21707 — 6+ workers all reported reason=clean session_count=0
	# despite wait_status=143).
	local _wait_file="${_WORKER_EXIT_CODE_FILE:-}.wait_status"
	if [[ -n "${_WORKER_EXIT_CODE_FILE:-}" && -f "$_wait_file" ]]; then
		local _w=""
		_w=$(<"$_wait_file") || _w=""
		# Trim CR/LF/whitespace (bash 3.2 compatible).
		_w="${_w//$'\r'/}"
		_w="${_w//$'\n'/}"
		_w="${_w#"${_w%%[![:space:]]*}"}"
		_w="${_w%"${_w##*[![:space:]]}"}"
		if [[ "$_w" =~ ^[0-9]+$ && "$_w" -gt 0 ]]; then
			exit_status="$_w"
		fi
		rm -f "$_wait_file" 2>/dev/null || true
	fi

	local reason="$_HRFF_FALLBACK_EXIT"
	local session_count=0
	local ledger_terminal_reason=""
	local force_nonzero_exit=0
	if [[ -x "${DISPATCH_LEDGER_HELPER:-}" && -n "${AIDEVOPS_DISPATCH_LEASE_TOKEN:-}" ]]; then
		ledger_terminal_reason=$("$DISPATCH_LEDGER_HELPER" terminal-reason --session-key "$session_key" \
			--lease-token "$AIDEVOPS_DISPATCH_LEASE_TOKEN" 2>/dev/null) || ledger_terminal_reason=""
	fi
	if [[ "${_WORKER_RUNTIME_LAUNCH_STARTED:-0}" != "1" ]]; then
		reason="${_WORKER_PRELAUNCH_FAILURE_REASON:-$_HRFF_PRELAUNCH_NOT_INVOKED}"
		print_warning "[exit-trap] runtime invocation never started after worker preparation; reason=${reason}"
		if [[ ! "$exit_status" =~ ^[1-9][0-9]*$ ]]; then
			exit_status=1
			force_nonzero_exit=1
		fi
	elif [[ -n "$ledger_terminal_reason" ]]; then
		reason="$ledger_terminal_reason"
		print_info "[exit-trap] using dispatch ledger terminal reason: $reason"
	elif [[ -n "${_WORKER_PRELAUNCH_FAILURE_REASON:-}" ]]; then
		reason="$_WORKER_PRELAUNCH_FAILURE_REASON"
		print_info "[exit-trap] using prelaunch failure reason: $reason"
	else
		if declare -F classify_worker_exit >/dev/null 2>&1; then
			local _start_ms="${_WORKER_START_EPOCH_MS:-0}"
			local _classified=""
			_classified=$(classify_worker_exit "$exit_status" "$_start_ms" 2>/dev/null) || true
			if [[ -n "$_classified" ]]; then
				reason="$_classified"
			else
				print_warning "[exit-trap] classify_worker_exit returned empty — using process_exit fallback"
			fi

			# Re-read session count for the enriched comment (best-effort)
			local _db="${_WORKER_ISOLATED_DB_PATH:-}"
			local _shared="${HOME}/.local/share/opencode/opencode.db"
			[[ -z "$_db" || ! -f "$_db" ]] && _db="$_shared"
			if command -v sqlite3 >/dev/null 2>&1 && [[ -f "$_db" && "$_start_ms" =~ ^[0-9]+$ ]] && (( _start_ms > 0 )); then
				local _cnt=""
				_cnt=$(sqlite3 "$_db" \
					"SELECT count(*) FROM session WHERE time_created >= ${_start_ms}" \
					2>/dev/null) || _cnt=""
				[[ "$_cnt" =~ ^[0-9]+$ ]] && session_count="$_cnt"
			fi
		else
			print_warning "[exit-trap] classify_worker_exit not available — using process_exit fallback"
		fi
	fi

	# t2923/GH#22965: Preserve WIP before releasing the claim so re-dispatch can
	# continue from the pushed branch instead of starting over. Dirty preserved
	# work is reported distinctly to avoid zero-output brief-rewrite holds.
	_hrff_finalize_exit_trap "$session_key" "$reason" "$exit_status" "$session_count" "$force_nonzero_exit"
	return 0
}

_recover_dirty_worker_pr() {
	local session_key="$1"
	local work_dir="${_WORKER_WORKTREE_PATH:-}"
	local repo_slug="${DISPATCH_REPO_SLUG:-}"
	local branch_name=""

	[[ -n "$work_dir" && -d "$work_dir" && -n "$repo_slug" ]] || return 1
	branch_name=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	case "$branch_name" in
	HEAD | main | master | "") return 1 ;;
	esac
	if declare -F _attempt_orphan_recovery_pr >/dev/null 2>&1; then
		_attempt_orphan_recovery_pr "$session_key" "$work_dir" "$branch_name" "$repo_slug" "draft"
		return $?
	fi
	return 1
}

#######################################
# Acquire the fast-fail mkdir lock with retries.
#
# Args:
#   $1 - lock_dir path
#   $2 - issue_number (for warning message)
#   $3 - repo_slug (for warning message)
# Returns: 0=acquired, 1=timed out
#######################################
_fast_fail_acquire_lock() {
	local lock_dir="$1"
	local issue_number="$2"
	local repo_slug="$3"
	local retries=0
	while ! mkdir "$lock_dir" 2>/dev/null; do
		retries=$((retries + 1))
		if [[ "$retries" -ge 50 ]]; then
			print_warning "[fast-fail] lock timeout for #${issue_number} (${repo_slug})"
			return 1
		fi
		sleep 0.1
	done
	return 0
}

#######################################
# Read existing count and backoff from fast-fail state file.
# Stale entries (older than expiry_secs) are treated as absent.
#
# Args:
#   $1 - state_file path
#   $2 - key (repo_slug/issue_number)
#   $3 - now (epoch seconds)
#   $4 - expiry_secs
# Sets globals: _FAST_FAIL_EXISTING_COUNT, _FAST_FAIL_EXISTING_BACKOFF
#######################################
_fast_fail_read_state() {
	local state_file="$1"
	local key="$2"
	local now="$3"
	local expiry_secs="$4"
	_FAST_FAIL_EXISTING_COUNT=0
	_FAST_FAIL_EXISTING_BACKOFF=0
	if [[ ! -f "$state_file" ]]; then
		return 0
	fi
	local entry=""
	entry=$(jq -r --arg k "$key" '.[$k] // empty' "$state_file" 2>/dev/null) || entry=""
	if [[ -z "$entry" ]]; then
		return 0
	fi
	local entry_ts=""
	entry_ts=$(printf '%s' "$entry" | jq -r '.ts // 0' 2>/dev/null) || entry_ts=0
	# Expire stale entries
	if [[ $((now - entry_ts)) -ge "$expiry_secs" ]]; then
		return 0
	fi
	_FAST_FAIL_EXISTING_COUNT=$(printf '%s' "$entry" | jq -r '.count // 0' 2>/dev/null) || _FAST_FAIL_EXISTING_COUNT=0
	_FAST_FAIL_EXISTING_BACKOFF=$(printf '%s' "$entry" | jq -r '.backoff_secs // 0' 2>/dev/null) || _FAST_FAIL_EXISTING_BACKOFF=0
	return 0
}

#######################################
# Write updated fast-fail state atomically via tmp+mv.
#
# Args:
#   $1  - state_file path
#   $2  - state_dir path
#   $3  - key (repo_slug/issue_number)
#   $4  - new_count
#   $5  - now (epoch seconds)
#   $6  - reason
#   $7  - retry_after (epoch seconds)
#   $8  - new_backoff (seconds)
#   $9  - crash_type (may be empty)
#######################################
_fast_fail_write_state() {
	local state_file="$1"
	local state_dir="$2"
	local key="$3"
	local new_count="$4"
	local now="$5"
	local reason="$6"
	local retry_after="$7"
	local new_backoff="$8"
	local crash_type="$9"
	local updated_state=""
	if [[ -f "$state_file" ]]; then
		updated_state=$(jq --arg k "$key" \
			--argjson count "$new_count" \
			--argjson ts "$now" \
			--arg reason "$reason" \
			--argjson retry_after "$retry_after" \
			--argjson backoff_secs "$new_backoff" \
			--arg crash_type "${crash_type:-}" \
			'.[$k] = {"count": $count, "ts": $ts, "reason": $reason, "retry_after": $retry_after, "backoff_secs": $backoff_secs, "crash_type": $crash_type}' \
			"$state_file") || {
			echo "Error: Failed to update $state_file" >&2
			updated_state=""
		}
	else
		updated_state=$(printf '{}' | jq --arg k "$key" \
			--argjson count "$new_count" \
			--argjson ts "$now" \
			--arg reason "$reason" \
			--argjson retry_after "$retry_after" \
			--argjson backoff_secs "$new_backoff" \
			--arg crash_type "${crash_type:-}" \
			'.[$k] = {"count": $count, "ts": $ts, "reason": $reason, "retry_after": $retry_after, "backoff_secs": $backoff_secs, "crash_type": $crash_type}' \
			2>/dev/null) || updated_state=""
	fi
	if [[ -z "$updated_state" ]]; then
		return 0
	fi
	local tmp_file=""
	tmp_file=$(mktemp "${state_dir}/.fast-fail-counter.XXXXXX" 2>/dev/null) || tmp_file=""
	if [[ -z "$tmp_file" ]]; then
		return 0
	fi
	printf '%s\n' "$updated_state" >"$tmp_file" 2>/dev/null &&
		mv "$tmp_file" "$state_file" 2>/dev/null || rm -f "$tmp_file" 2>/dev/null
	return 0
}

#######################################
# Report worker failure to the shared fast-fail counter and trigger
# tier escalation when threshold is reached.
#
# Previously, only the pulse (recover_failed_launch_state) and launchd
# watchdog wrote to the counter -- both asynchronous, discovering failures
# 10-30 minutes after the worker died. This function lets the worker
# self-report immediately on exit, so escalation fires within seconds
# instead of 60-90+ minutes. The pulse path remains as a backup for
# workers that crash hard before reaching this function.
#
# Uses the same state file and locking as pulse-wrapper.sh and
# worker-watchdog.sh (fast-fail-counter.json + mkdir lock).
#
# Args:
#   $1 - session_key (e.g., "issue-marcusquinn-aidevops-17642")
#   $2 - failure reason (premature_exit, rate_limit, etc.)
#   $3 - crash_type (optional, e.g., "overwhelmed")
#######################################
_report_failure_to_fast_fail() {
	local session_key="$1"
	local reason="${2:-worker_failed}"
	local crash_type="${3:-}"

	# Extract issue number from session key (last numeric segment)
	local issue_number=""
	issue_number=$(printf '%s' "$session_key" | grep -oE '[0-9]+$' || true)
	local repo_slug="${DISPATCH_REPO_SLUG:-}"

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		return 0
	fi

	# Only report for worker role (not pulse/triage sessions)
	if [[ "$session_key" != issue-* ]]; then
		return 0
	fi
	if declare -F _objective_disposition_suppresses >/dev/null 2>&1 && \
		_objective_disposition_suppresses suppress_fast_fail "$issue_number" "$repo_slug" "${AIDEVOPS_ATTEMPT_ID:-}"; then
		print_info "[fast-fail] suppressed reconciled non-failure #${issue_number} (${repo_slug})"
		return 0
	fi

	# Launch/preflight aborts happen before a worker reaches the brief. They are
	# useful launch diagnostics, but they must not accrue as per-issue fast-fail
	# / no_work circuit-breaker evidence.
	if declare -F _worker_failure_reason_is_launch_preflight >/dev/null 2>&1; then
		if _worker_failure_reason_is_launch_preflight "$reason"; then
			print_info "[fast-fail] skipped launch/preflight failure #${issue_number} (${repo_slug}) reason=${reason}"
			return 0
		fi
	fi
	if declare -F _worker_failure_reason_is_completion_infrastructure >/dev/null 2>&1; then
		if _worker_failure_reason_is_completion_infrastructure "$reason"; then
			print_info "[fast-fail] skipped completion infrastructure failure #${issue_number} (${repo_slug}) reason=${reason}"
			return 0
		fi
	fi

	local state_file="${HOME}/.aidevops/.agent-workspace/supervisor/fast-fail-counter.json"
	local state_dir
	state_dir=$(dirname "$state_file")
	mkdir -p "$state_dir" 2>/dev/null || true

	# Acquire lock (shared with pulse-wrapper.sh and worker-watchdog.sh)
	local lock_dir="${state_file}.lockdir"
	_fast_fail_acquire_lock "$lock_dir" "$issue_number" "$repo_slug" || return 0

	local key now
	key="${repo_slug}/${issue_number}"
	now=$(date +%s)

	local initial_backoff="${FAST_FAIL_INITIAL_BACKOFF_SECS:-600}"
	local max_backoff="${FAST_FAIL_MAX_BACKOFF_SECS:-604800}"
	local expiry_secs="${FAST_FAIL_EXPIRY_SECS:-604800}"

	# Read current state -- sets _FAST_FAIL_EXISTING_COUNT and _FAST_FAIL_EXISTING_BACKOFF
	_fast_fail_read_state "$state_file" "$key" "$now" "$expiry_secs"
	local existing_count="$_FAST_FAIL_EXISTING_COUNT"
	local existing_backoff="$_FAST_FAIL_EXISTING_BACKOFF"

	# Non-rate-limit failures: increment + exponential backoff
	local new_count=$((existing_count + 1))
	local new_backoff=$((existing_backoff > 0 ? existing_backoff * 2 : initial_backoff))
	[[ "$new_backoff" -gt "$max_backoff" ]] && new_backoff="$max_backoff"
	local retry_after=$((now + new_backoff))

	# Write updated state atomically (tmp + mv)
	_fast_fail_write_state "$state_file" "$state_dir" "$key" "$new_count" "$now" \
		"$reason" "$retry_after" "$new_backoff" "$crash_type"

	# Release lock
	rmdir "$lock_dir" 2>/dev/null || true

	print_info "[fast-fail] #${issue_number} (${repo_slug}) count=${new_count} backoff=${new_backoff}s reason=${reason} crash_type=${crash_type:-unclassified}"

	# Trigger tier escalation (escalate_issue_tier from worker-lifecycle-common.sh)
	# Only fires when new_count == threshold -- not on every failure.
	# Pass crash_type so escalation uses crash-type-aware thresholds:
	# "overwhelmed" escalates immediately (threshold=1).
	if [[ "$new_count" -gt "$existing_count" ]]; then
		escalate_issue_tier "$issue_number" "$repo_slug" "$new_count" "$reason" "$crash_type" || true
	fi

	return 0
}
