#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# pulse-runner-health-helper.sh — Per-runner zero-attempt circuit breaker (t2897).
#
# When N consecutive "zero-attempt" worker dispatches happen on this runner,
# the breaker pauses dispatch on this machine and synchronously runs
# `aidevops update`. If the update leaves the deployed agents aligned with
# the local repo, the next pause check auto-resumes the breaker before pulse
# skips dispatch. If the update fails, the runner has a real local problem
# (broken install, gh auth, MCP failures, network) — stay paused and post a
# single advisory.
#
# A "zero-attempt" outcome means a dispatched worker never produced real
# work — the five signals are listed in the help text and recorded by callers.
# Workers that produce a commit, open a PR, or burn >5K tokens are real
# attempts and reset the counter — even if the work failed, the failure is
# brief/tier/codebase, not version skew.
#
# The breaker is per-runner: peer runners are unaffected. Cross-runner
# coordination already takes over naturally (no DISPATCH_CLAIM from a
# paused runner = peers see the issue as unclaimed).
#
# Subcommands:
#   record-outcome <signal> <issue>    — record a worker outcome (zero or non-zero attempt).
#   is-paused                          — exit 0 if breaker tripped, exit 1 if closed/recovered.
#   pause [--reason "<text>"]          — manually trip the breaker.
#   resume [--reason "<text>"]         — manually clear the breaker.
#   status [--json]                    — print human or JSON state summary.
#   help                               — show usage.
#
# State file: ~/.aidevops/cache/runner-health.json (v1 schema in brief).
# Advisory:   ~/.aidevops/advisories/runner-health-degraded.advisory
# Stamp:      ~/.aidevops/cache/runner-health-advisory.stamp (dedup).
#
# Environment overrides:
#   RUNNER_HEALTH_FAILURE_THRESHOLD          (default 10)
#   RUNNER_HEALTH_WINDOW_HOURS               (default 6)
#   RUNNER_HEALTH_BREAKER_RESUME_AFTER_UPDATE (default true)
#   RUNNER_HEALTH_NO_UPDATE_PAUSE_HOURS      (default 24)
#   RUNNER_HEALTH_DISABLED                   (default 0; set 1 to make all subcommands no-op)
#   RUNNER_HEALTH_TEST_NOW                   (test-only; ISO-8601 string used as "now")

set -euo pipefail

# Resolve script directory for sourcing siblings.
RUNNER_HEALTH_HELPER_DIR="${RUNNER_HEALTH_HELPER_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Source shared color/print constants when available; otherwise guard.
# shellcheck source=./shared-constants.sh
# shellcheck disable=SC1091
if [[ -r "${RUNNER_HEALTH_HELPER_DIR}/shared-constants.sh" ]]; then
	source "${RUNNER_HEALTH_HELPER_DIR}/shared-constants.sh" 2>/dev/null || true
fi
# Local fallbacks for color codes and counter helper if shared-constants didn't load.
[[ -z "${RED+x}" ]] && RED=''
[[ -z "${GREEN+x}" ]] && GREEN=''
[[ -z "${YELLOW+x}" ]] && YELLOW=''
[[ -z "${NC+x}" ]] && NC=''

# Tunables.
RUNNER_HEALTH_FAILURE_THRESHOLD="${RUNNER_HEALTH_FAILURE_THRESHOLD:-10}"
RUNNER_HEALTH_WINDOW_HOURS="${RUNNER_HEALTH_WINDOW_HOURS:-6}"
RUNNER_HEALTH_BREAKER_RESUME_AFTER_UPDATE="${RUNNER_HEALTH_BREAKER_RESUME_AFTER_UPDATE:-true}"
RUNNER_HEALTH_NO_UPDATE_PAUSE_HOURS="${RUNNER_HEALTH_NO_UPDATE_PAUSE_HOURS:-24}"
RUNNER_HEALTH_DISABLED="${RUNNER_HEALTH_DISABLED:-0}"

# Paths.
RUNNER_HEALTH_CACHE_DIR="${RUNNER_HEALTH_CACHE_DIR:-${HOME}/.aidevops/cache}"
RUNNER_HEALTH_STATE_FILE="${RUNNER_HEALTH_CACHE_DIR}/runner-health.json"
RUNNER_HEALTH_ADVISORY_DIR="${RUNNER_HEALTH_ADVISORY_DIR:-${HOME}/.aidevops/advisories}"
RUNNER_HEALTH_ADVISORY_FILE="${RUNNER_HEALTH_ADVISORY_DIR}/runner-health-degraded.advisory"
RUNNER_HEALTH_ADVISORY_STAMP="${RUNNER_HEALTH_CACHE_DIR}/runner-health-advisory.stamp"
RUNNER_HEALTH_PULSE_LOG="${RUNNER_HEALTH_PULSE_LOG:-${HOME}/.aidevops/logs/pulse-wrapper.log}"
RUNNER_HEALTH_DEPLOYED_VERSION_FILE="${RUNNER_HEALTH_DEPLOYED_VERSION_FILE:-${HOME}/.aidevops/agents/VERSION}"
RUNNER_HEALTH_DEPLOYED_SHA_FILE="${RUNNER_HEALTH_DEPLOYED_SHA_FILE:-${HOME}/.aidevops/.deployed-sha}"

# Cap on the rolling outcome ledger (per brief).
RUNNER_HEALTH_LEDGER_CAP=20

#######################################
# UTC ISO-8601 timestamp. Honours RUNNER_HEALTH_TEST_NOW for deterministic tests.
#######################################
_rh_now() {
	if [[ -n "${RUNNER_HEALTH_TEST_NOW:-}" ]]; then
		printf '%s\n' "$RUNNER_HEALTH_TEST_NOW"
	else
		date -u '+%Y-%m-%dT%H:%M:%SZ'
	fi
	return 0
}

#######################################
# Convert an ISO-8601 UTC timestamp to epoch seconds. Handles both BSD
# (macOS) and GNU date variants. Falls back to printing 0 on parse failure
# so callers can detect bad data with an explicit zero check.
# Args: $1 = ISO-8601 string
# Stdout: epoch seconds (or 0 on failure)
#######################################
_rh_iso_to_epoch() {
	local iso="${1:-}"
	[[ -z "$iso" ]] && {
		printf '0\n'
		return 0
	}
	local epoch=""
	# BSD date (macOS).
	epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$iso" '+%s' 2>/dev/null || true)
	# GNU date (Linux).
	[[ -z "$epoch" ]] && epoch=$(date -u -d "$iso" '+%s' 2>/dev/null || true)
	[[ -z "$epoch" ]] && epoch="0"
	printf '%s\n' "$epoch"
	return 0
}

#######################################
# Detect the local runner login. Used as a tag in state files so a shared
# state file (unlikely but possible across tooling) can be partitioned.
#######################################
_rh_self_login() {
	if command -v gh >/dev/null 2>&1; then
		local login
		login=$(gh api user --jq '.login' 2>/dev/null || true)
		if [[ -n "$login" ]]; then
			printf '%s\n' "$login"
			return 0
		fi
	fi
	printf '%s\n' "${USER:-unknown}"
	return 0
}

#######################################
# Ensure cache + advisory directories exist with safe perms.
#######################################
_rh_ensure_dirs() {
	mkdir -p "$RUNNER_HEALTH_CACHE_DIR" "$RUNNER_HEALTH_ADVISORY_DIR" 2>/dev/null || return 1
	return 0
}

#######################################
# Initialise an empty state file. Idempotent — won't overwrite existing.
#######################################
_rh_init_state() {
	[[ -f "$RUNNER_HEALTH_STATE_FILE" ]] && return 0
	_rh_ensure_dirs || return 1
	local self_login
	self_login=$(_rh_self_login)
	local now
	now=$(_rh_now)
	cat >"$RUNNER_HEALTH_STATE_FILE" <<EOF
{
  "version": 1,
  "self_login": "${self_login}",
  "consecutive_zero_attempts": 0,
  "window_started_at": "${now}",
  "last_outcomes": [],
  "circuit_breaker": {
    "state": "closed",
    "tripped_at": null,
    "last_update_attempt_at": null,
    "last_update_outcome": null,
    "reason": null
  }
}
EOF
	return 0
}

#######################################
# Read a top-level field from the state file via jq. Returns empty string
# if the file doesn't exist or jq is missing or the field is null.
# Args: $1 = jq path expression (e.g. ".consecutive_zero_attempts")
#######################################
_rh_get_field() {
	local jq_path="$1"
	[[ -f "$RUNNER_HEALTH_STATE_FILE" ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0
	jq -r "${jq_path} // empty" <"$RUNNER_HEALTH_STATE_FILE" 2>/dev/null || true
	return 0
}

#######################################
# Read a small single-line file with whitespace removed. Missing files
# return an empty string so callers can choose fail-open/fail-closed.
# Args: $1 = file path
#######################################
_rh_read_token_file() {
	local token_file="$1"
	[[ -r "$token_file" ]] || return 0
	tr -d '[:space:]' <"$token_file" || true
	return 0
}

#######################################
# Return the agents directory that contains this helper.
#######################################
_rh_agents_dir() {
	local agents_dir
	agents_dir=$(cd "${RUNNER_HEALTH_HELPER_DIR}/.." 2>/dev/null && pwd) || agents_dir=""
	printf '%s\n' "$agents_dir"
	return 0
}

#######################################
# Determine whether a successful update left the deployed runner healthy.
# The deterministic recovery gate is deliberately conservative:
# - last_update_outcome must be `ran`;
# - deployed VERSION must match the helper's agents/VERSION;
# - when a deployment SHA stamp and git checkout are available, the stamp
#   must also match repo HEAD (the t2706 drift detector's source of truth).
# Args: $1 = last_update_outcome
#######################################
_rh_update_recovery_healthy() {
	local update_outcome="$1"
	[[ "$RUNNER_HEALTH_BREAKER_RESUME_AFTER_UPDATE" == "true" ]] || return 1
	[[ "$update_outcome" == "ran" ]] || return 1

	local agents_dir="" repo_root="" repo_version="" deployed_version=""
	agents_dir=$(_rh_agents_dir)
	[[ -n "$agents_dir" ]] || return 1
	repo_root="${agents_dir%/.agents}"
	repo_version=$(_rh_read_token_file "${agents_dir}/VERSION")
	if [[ -z "$repo_version" ]]; then
		repo_version=$(_rh_read_token_file "${repo_root}/VERSION")
	fi
	deployed_version=$(_rh_read_token_file "$RUNNER_HEALTH_DEPLOYED_VERSION_FILE")
	[[ -n "$repo_version" && -n "$deployed_version" ]] || return 1
	[[ "$repo_version" == "$deployed_version" ]] || return 1

	if [[ -r "$RUNNER_HEALTH_DEPLOYED_SHA_FILE" && -d "${repo_root}/.git" ]]; then
		local deployed_sha="" head_sha=""
		deployed_sha=$(_rh_read_token_file "$RUNNER_HEALTH_DEPLOYED_SHA_FILE")
		head_sha=$(git -C "$repo_root" rev-parse HEAD 2>/dev/null || true)
		[[ -n "$deployed_sha" && -n "$head_sha" ]] || return 1
		[[ "$deployed_sha" == "$head_sha" ]] || return 1
	fi
	return 0
}

#######################################
# Clear a tripped breaker after a verified successful update/deploy.
# Args: $1 = reason string
#######################################
_rh_auto_resume() {
	local reason="$1"
	_rh_init_state || return 1
	local now
	now=$(_rh_now)
	# shellcheck disable=SC2016 # $reason and $now are jq variables supplied by --arg.
	_rh_state_apply \
		'.circuit_breaker.state = "closed"
		| .circuit_breaker.tripped_at = null
		| .circuit_breaker.reason = $reason
		| .consecutive_zero_attempts = 0
		| .window_started_at = $now' \
		--arg reason "$reason" \
		--arg now "$now" || return 1
	rm -f "$RUNNER_HEALTH_ADVISORY_FILE" "$RUNNER_HEALTH_ADVISORY_STAMP" 2>/dev/null || true
	return 0
}

#######################################
# Atomic write: render JSON via jq pipeline, write to tmp, mv into place.
# Args: $1 = jq filter (operates on existing state)
#       remaining args = optional jq arguments (for example --arg name value)
#######################################
_rh_state_apply() {
	local jq_filter="$1"
	shift
	_rh_init_state || return 1
	local tmp
	tmp="${RUNNER_HEALTH_STATE_FILE}.tmp.$$"
	if jq ${@+"$@"} "$jq_filter" <"$RUNNER_HEALTH_STATE_FILE" >"$tmp" 2>/dev/null; then
		mv "$tmp" "$RUNNER_HEALTH_STATE_FILE"
		return 0
	fi
	rm -f "$tmp"
	return 1
}

#######################################
# Recognised zero-attempt signals. Anything else is treated as a real
# attempt (resets counter).
#######################################
_rh_is_zero_attempt_signal() {
	local signal="$1"
	case "$signal" in
	no_worker_process | no_branch_created | low_token_usage | watchdog_killed_no_commit | worker_signing_unavailable)
		return 0
		;;
	*)
		return 1
		;;
	esac
}

#######################################
# Resolve the trip threshold for a zero-attempt signal. Deterministic signing
# preflight failure proves this runner cannot launch any worker, so one outcome
# must pause it immediately while healthy peers remain eligible.
# Args: $1 = outcome signal
# Outputs: positive integer threshold
#######################################
_rh_failure_threshold_for_signal() {
	local signal="$1"
	case "$signal" in
	worker_signing_unavailable)
		printf '1\n'
		;;
	*)
		printf '%s\n' "$RUNNER_HEALTH_FAILURE_THRESHOLD"
		;;
	esac
	return 0
}

#######################################
# Determine if a window is expired vs the recorded window_started_at.
# Returns 0 (expired) if more than RUNNER_HEALTH_WINDOW_HOURS have passed.
#######################################
_rh_window_expired() {
	local started
	started=$(_rh_get_field '.window_started_at')
	[[ -z "$started" ]] && return 0
	local started_epoch now_epoch
	started_epoch=$(_rh_iso_to_epoch "$started")
	now_epoch=$(_rh_iso_to_epoch "$(_rh_now)")
	[[ "$started_epoch" -eq 0 ]] && return 0
	local age=$((now_epoch - started_epoch))
	local window_seconds=$((RUNNER_HEALTH_WINDOW_HOURS * 3600))
	[[ "$age" -gt "$window_seconds" ]] && return 0
	return 1
}

#######################################
# cmd_record_outcome — record a worker outcome. Caller passes the signal
# string and the issue identifier for the audit ledger.
#
# Increments `consecutive_zero_attempts` for zero-attempt signals; resets
# to 0 for any other signal (real-attempt outcomes). When the counter
# reaches RUNNER_HEALTH_FAILURE_THRESHOLD inside the rolling window, the
# breaker trips and `aidevops update` runs synchronously.
#######################################
cmd_record_outcome() {
	local signal="${1:-}"
	local issue="${2:-unknown}"
	if [[ -z "$signal" ]]; then
		echo "Usage: $0 record-outcome <signal> <issue-id>" >&2
		return 1
	fi
	[[ "$RUNNER_HEALTH_DISABLED" == "1" ]] && return 0
	_rh_init_state || return 1
	command -v jq >/dev/null 2>&1 || return 0

	local now
	now=$(_rh_now)
	local is_zero=0
	if _rh_is_zero_attempt_signal "$signal"; then is_zero=1; fi

	# Window expiry: if the rolling window has elapsed without tripping,
	# zero out the counter and re-anchor the window. Done BEFORE applying
	# the new outcome so a stale window doesn't carry an old counter.
	if _rh_window_expired; then
		# shellcheck disable=SC2016 # $now is a jq variable supplied by --arg.
		_rh_state_apply '.consecutive_zero_attempts = 0 | .window_started_at = $now' --arg now "$now" || true
	fi

	# Append outcome to ledger and update counter.
	local new_counter="" signal_threshold=""
	if [[ "$is_zero" -eq 1 ]]; then
		# Counter increments; the window may need to be re-anchored if it
		# was idle through expiry above (already done) — otherwise keep it.
		_rh_state_apply ".consecutive_zero_attempts += 1" || true
	else
		# shellcheck disable=SC2016 # $now is a jq variable supplied by --arg.
		_rh_state_apply '.consecutive_zero_attempts = 0 | .window_started_at = $now' --arg now "$now" || true
	fi

	# Append outcome with rolling cap. jq idiom: keep last N entries.
	local outcome_entry
	outcome_entry=$(jq -n \
		--arg issue "$issue" \
		--arg signal "$signal" \
		--arg ts "$now" \
		--argjson zero "$is_zero" \
		'{issue:$issue, signal:$signal, ts:$ts, zero_attempt:($zero==1)}')
	# shellcheck disable=SC2016 # $outcome_entry and $ledger_cap are jq variables supplied by --argjson.
	_rh_state_apply '.last_outcomes += [$outcome_entry] | .last_outcomes = (.last_outcomes | .[-$ledger_cap:])' \
		--argjson outcome_entry "$outcome_entry" \
		--argjson ledger_cap "$RUNNER_HEALTH_LEDGER_CAP" || true

	# Trip evaluation. Only zero-attempt outcomes can trip the breaker
	# (real-attempt outcomes already reset the counter above).
	new_counter=$(_rh_get_field '.consecutive_zero_attempts')
	[[ -z "$new_counter" ]] && new_counter=0
	signal_threshold=$(_rh_failure_threshold_for_signal "$signal")
	local current_state
	current_state=$(_rh_get_field '.circuit_breaker.state')
	[[ -z "$current_state" ]] && current_state="closed"

	if [[ "$is_zero" -eq 1 ]] \
		&& [[ "$current_state" == "closed" ]] \
		&& [[ "$new_counter" -ge "$signal_threshold" ]]; then
		_rh_trip_breaker "$issue" "signal=${signal} consecutive_zero_attempts=${new_counter}"
	fi
	return 0
}

#######################################
# Trip the breaker: write `tripped` state, post an advisory, and
# synchronously run `aidevops update`. If the update changed VERSION
# (exit 0 from cmd_check) the t2579 restart hook fires and the next
# cycle will pick up new code; we leave the state as `tripped` and let
# the resume path (next cmd_record_outcome non-zero) reopen it.
# Args: $1 = triggering issue (audit only)
#       $2 = reason string
#######################################
_rh_trip_breaker() {
	local triggering_issue="$1"
	local reason="$2"
	local now
	now=$(_rh_now)

	# Mark tripped first so concurrent paths see the breaker open.
	# shellcheck disable=SC2016 # $now and $reason are jq variables supplied by --arg.
	_rh_state_apply \
		'.circuit_breaker.state = "tripped"
		| .circuit_breaker.tripped_at = $now
		| .circuit_breaker.reason = $reason' \
		--arg now "$now" \
		--arg reason "$reason" || true

	# Write/refresh the advisory (deduped) so the operator sees this on
	# the next session greeting.
	_rh_post_advisory "tripped" "$reason" "$triggering_issue"

	# Synchronous update. Run via the deployed helper to avoid spawning
	# a separate shell when the canonical install is missing.
	local update_helper="${HOME}/.aidevops/agents/scripts/auto-update-helper.sh"
	local update_outcome="error"
	if [[ -x "$update_helper" ]]; then
		# Run check synchronously. Output to log only — never the user's
		# session — to avoid noise from a per-issue trigger.
		local update_log="${HOME}/.aidevops/logs/runner-health-update.log"
		mkdir -p "$(dirname "$update_log")" 2>/dev/null || true
		local update_rc=0
		"$update_helper" check >>"$update_log" 2>&1 || update_rc=$?
		if [[ "$update_rc" -eq 0 ]]; then
			update_outcome="ran"
		else
			update_outcome="failed"
		fi
	else
		update_outcome="helper_missing"
	fi

	# shellcheck disable=SC2016 # $now and $update_outcome are jq variables supplied by --arg.
	_rh_state_apply \
		'.circuit_breaker.last_update_attempt_at = $now
		| .circuit_breaker.last_update_outcome = $update_outcome' \
		--arg now "$(_rh_now)" \
		--arg update_outcome "$update_outcome" || true
	return 0
}

#######################################
# Write the advisory file with dedup. Re-emit only when:
#   (a) breaker first trips (no stamp file yet);
#   (b) update outcome differs from prior;
#   (c) more than 24h since last advisory.
# Args: $1 = state ("tripped" | "resumed")
#       $2 = reason
#       $3 = triggering issue (audit)
#######################################
_rh_post_advisory() {
	local state="$1"
	local reason="$2"
	local triggering="$3"
	_rh_ensure_dirs || return 1

	local now
	now=$(_rh_now)
	local now_epoch
	now_epoch=$(_rh_iso_to_epoch "$now")
	local should_emit=1

	if [[ -f "$RUNNER_HEALTH_ADVISORY_STAMP" ]]; then
		# Stamp file holds prior state + last_emit_ts on two lines.
		local prior_state prior_ts prior_epoch
		prior_state=$(sed -n 1p "$RUNNER_HEALTH_ADVISORY_STAMP" 2>/dev/null || echo "")
		prior_ts=$(sed -n 2p "$RUNNER_HEALTH_ADVISORY_STAMP" 2>/dev/null || echo "")
		prior_epoch=$(_rh_iso_to_epoch "$prior_ts")
		# If state unchanged AND less than 24h elapsed, skip.
		if [[ "$prior_state" == "$state" ]]; then
			if [[ "$prior_epoch" -gt 0 ]]; then
				local age=$((now_epoch - prior_epoch))
				if [[ "$age" -lt $((24 * 3600)) ]]; then
					should_emit=0
				fi
			fi
		fi
	fi

	if [[ "$should_emit" -eq 1 ]]; then
		cat >"$RUNNER_HEALTH_ADVISORY_FILE" <<EOF
Runner-health circuit breaker is currently ${state}.

Reason:           ${reason}
Triggering issue: ${triggering}
Updated:          ${now}

Diagnose: pulse-runner-health-helper.sh status
Resume:   pulse-runner-health-helper.sh resume --reason "<text>"
Background: reference/cross-runner-coordination.md §4.4
EOF
		printf '%s\n%s\n' "$state" "$now" >"$RUNNER_HEALTH_ADVISORY_STAMP"
	fi
	return 0
}

#######################################
# cmd_is_paused — exit 0 if breaker is tripped, exit 1 otherwise.
# Pulse calls this before the dispatch evaluation step; this is the safe
# auto-recovery point after a successful update/deploy.
#######################################
cmd_is_paused() {
	[[ "$RUNNER_HEALTH_DISABLED" == "1" ]] && return 1
	[[ -f "$RUNNER_HEALTH_STATE_FILE" ]] || return 1
	local state="" update_outcome=""
	state=$(_rh_get_field '.circuit_breaker.state')
	if [[ "$state" == "tripped" ]]; then
		update_outcome=$(_rh_get_field '.circuit_breaker.last_update_outcome')
		if _rh_update_recovery_healthy "$update_outcome"; then
			_rh_auto_resume "auto resume after successful update/deploy" || return 0
			return 1
		fi
		return 0
	fi
	return 1
}

#######################################
# cmd_pause — manually trip the breaker. For operator use; not called
# from the auto-trip path (that uses _rh_trip_breaker directly).
#######################################
cmd_pause() {
	local reason="manual pause"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--reason)
			reason="${2:-manual pause}"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done
	_rh_init_state || return 1
	local now
	now=$(_rh_now)
	# shellcheck disable=SC2016 # $now and $reason are jq variables supplied by --arg.
	_rh_state_apply \
		'.circuit_breaker.state = "tripped"
		| .circuit_breaker.tripped_at = $now
		| .circuit_breaker.reason = $reason' \
		--arg now "$now" \
		--arg reason "$reason" || return 1
	_rh_post_advisory "tripped" "$reason" "manual"
	printf '%bPaused%b: runner-health breaker tripped (%s)\n' \
		"$YELLOW" "$NC" "$reason" >&2
	return 0
}

#######################################
# cmd_resume — manually clear the breaker. Logs reason in the audit ledger.
#######################################
cmd_resume() {
	local reason="manual resume"
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--reason)
			reason="${2:-manual resume}"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done
	_rh_init_state || return 1
	local now
	now=$(_rh_now)
	# shellcheck disable=SC2016 # $reason and $now are jq variables supplied by --arg.
	_rh_state_apply \
		'.circuit_breaker.state = "closed"
		| .circuit_breaker.tripped_at = null
		| .circuit_breaker.reason = $reason
		| .consecutive_zero_attempts = 0
		| .window_started_at = $now' \
		--arg reason "$reason" \
		--arg now "$now" || return 1
	# Clear the advisory file and stamp so the next trip can post fresh.
	rm -f "$RUNNER_HEALTH_ADVISORY_FILE" "$RUNNER_HEALTH_ADVISORY_STAMP" 2>/dev/null || true
	printf '%bResumed%b: runner-health breaker cleared (%s)\n' \
		"$GREEN" "$NC" "$reason" >&2
	return 0
}

#######################################
# cmd_status — print state. Default human-readable; --json emits raw JSON.
#######################################
cmd_status() {
	local emit_json=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json)
			emit_json=1
			shift
			;;
		*)
			shift
			;;
		esac
	done

	if [[ ! -f "$RUNNER_HEALTH_STATE_FILE" ]]; then
		if [[ "$emit_json" -eq 1 ]]; then
			printf '{"state":"uninitialized"}\n'
		else
			printf 'state: uninitialized (no record-outcome calls yet)\n'
		fi
		return 0
	fi

	if [[ "$emit_json" -eq 1 ]]; then
		cat "$RUNNER_HEALTH_STATE_FILE"
		return 0
	fi

	# Human format.
	local state counter window_started tripped_at update_at update_outcome reason
	state=$(_rh_get_field '.circuit_breaker.state')
	counter=$(_rh_get_field '.consecutive_zero_attempts')
	window_started=$(_rh_get_field '.window_started_at')
	tripped_at=$(_rh_get_field '.circuit_breaker.tripped_at')
	update_at=$(_rh_get_field '.circuit_breaker.last_update_attempt_at')
	update_outcome=$(_rh_get_field '.circuit_breaker.last_update_outcome')
	reason=$(_rh_get_field '.circuit_breaker.reason')

	printf 'state:               %s\n' "${state:-unknown}"
	printf 'consecutive zero:    %s / %s threshold\n' "${counter:-0}" "$RUNNER_HEALTH_FAILURE_THRESHOLD"
	printf 'window started:      %s\n' "${window_started:-n/a}"
	if [[ "$state" == "tripped" ]]; then
		printf 'tripped at:          %s\n' "${tripped_at:-n/a}"
		printf 'last update run:     %s (%s)\n' "${update_at:-never}" "${update_outcome:-n/a}"
		printf 'reason:              %s\n' "${reason:-n/a}"
	fi
	return 0
}

#######################################
# Count `recover_failed_launch_state` invocations recorded with
# `failure_reason=no_worker_process` in the local pulse-wrapper log. The
# log line format (set in pulse-cleanup.sh::recover_failed_launch_state)
# is:
#
#   [pulse-wrapper] Launch recovery reset #<N> (<slug>) after no_worker_process crash_type=...
#
# These lines lack timestamps, so the diagnose function uses the total
# count in the current log file as a proxy for "events the recorder
# should have observed". On a fresh log (post-rotation) this matches the
# rolling window naturally; on a long-uptime log it may overcount, in
# which case `--reset-window` (a future operator escape hatch) would
# truncate. For wiring-gap detection an overcount only strengthens the
# delta and the conclusion ("recorder is being skipped") remains correct.
# Stdout: integer count of matching events.
#######################################
_rh_count_log_no_worker_events() {
	local log_file="${RUNNER_HEALTH_PULSE_LOG}"
	if [[ ! -r "$log_file" ]]; then
		printf '0\n'
		return 0
	fi
	# Counter safety per t2763: avoid `grep -c | echo "0"` stack on no-match.
	local count
	count=$(grep -c 'Launch recovery reset.*after no_worker_process' "$log_file" 2>/dev/null || true)
	[[ "$count" =~ ^[0-9]+$ ]] || count=0
	printf '%s\n' "$count"
	return 0
}

#######################################
# Pure classification: maps observed state to a finding category. Inputs
# are pre-extracted strings/numbers so the function is unit-testable
# without any state file.
#
# Args:
#   $1 = recorded counter (integer)
#   $2 = expected counter from log (integer)
#   $3 = breaker state ("closed" | "tripped" | "")
#   $4 = tripped age in hours (integer or empty)
#   $5 = last_update_outcome ("ran" | "failed" | "helper_missing" | "")
#   $6 = update/deploy health ("healthy" | "")
# Stdout: one of HEALTHY | BUILDING | WIRING_GAP | TRIGGER_MISSED | RECOVERABLE_TRIPPED | STUCK_TRIPPED
#######################################
_rh_classify_diagnose() {
	local recorded="${1:-0}"
	local expected="${2:-0}"
	local state="${3:-closed}"
	local tripped_age_h="${4:-}"
	local update_outcome="${5:-}"
	local update_health="${6:-}"
	local threshold="${RUNNER_HEALTH_FAILURE_THRESHOLD:-10}"

	# Guard: numeric coercion. Empty/non-numeric inputs treated as zero.
	[[ "$recorded" =~ ^[0-9]+$ ]] || recorded=0
	[[ "$expected" =~ ^[0-9]+$ ]] || expected=0

	if [[ "$state" == "tripped" ]]; then
		# Successful update/deploy with matching local artifacts is recoverable:
		# the next `is-paused` call will clear the breaker instead of blocking
		# dispatch indefinitely.
		if [[ "$update_outcome" == "ran" && "$update_health" == "healthy" ]]; then
			printf 'RECOVERABLE_TRIPPED\n'
			return 0
		fi
		# STUCK_TRIPPED: tripped >24h AND update never succeeded. The breaker
		# fired but the synchronous `aidevops update` failed, so resume hook
		# can't fire. Operator must manually resume after fixing the install.
		if [[ "$tripped_age_h" =~ ^[0-9]+$ ]] && [[ "$tripped_age_h" -gt 24 ]] \
			&& [[ "$update_outcome" == "failed" || "$update_outcome" == "helper_missing" ]]; then
			printf 'STUCK_TRIPPED\n'
			return 0
		fi
		# Tripped but recent or not yet verified healthy: the breaker is doing
		# its job. Map to BUILDING for transient state rather than manual action.
		printf 'BUILDING\n'
		return 0
	fi

	# state == closed (or unknown). Order of checks matters:
	#  1. WIRING_GAP wins over TRIGGER_MISSED when both apply (deeper bug).
	#  2. TRIGGER_MISSED only fires when expected ~ recorded (counter is fine).
	#  3. BUILDING when counter is between 0 and threshold and matches log.
	local delta=$((expected - recorded))
	if [[ "$delta" -gt 2 ]]; then
		printf 'WIRING_GAP\n'
		return 0
	fi
	if [[ "$recorded" -ge "$threshold" ]]; then
		printf 'TRIGGER_MISSED\n'
		return 0
	fi
	if [[ "$recorded" -gt 0 ]]; then
		printf 'BUILDING\n'
		return 0
	fi
	printf 'HEALTHY\n'
	return 0
}

#######################################
# One-line operator advice keyed off the finding category. Kept separate
# so cmd_diagnose stays under the function-complexity gate.
#######################################
_rh_diagnose_advice() {
	case "${1:-HEALTHY}" in
	HEALTHY) printf 'no action — runner is healthy\n' ;;
	BUILDING) printf 'monitor — counter is collecting evidence within the rolling window\n' ;;
	RECOVERABLE_TRIPPED) printf 'auto-resume ready — next pulse pause check will clear the breaker after verified successful update/deploy\n' ;;
	WIRING_GAP)
		printf 'check that pulse-cleanup.sh::_record_runner_health_zero_attempt is being called from recover_failed_launch_state — the log shows events the counter never saw\n'
		;;
	TRIGGER_MISSED)
		printf 'breaker did NOT trip at threshold — inspect _rh_trip_breaker call site and is_zero_attempt_signal predicate\n'
		;;
	STUCK_TRIPPED)
		printf 'manual resume required: pulse-runner-health-helper.sh resume --reason "<text>" after fixing the underlying install/auth/network issue\n'
		;;
	*) printf 'unknown finding\n' ;;
	esac
	return 0
}

#######################################
# Read all state fields needed by diagnose in one jq pass. Result is
# returned via name-ref out-parameters (bash 4.3+ via declare -n). Falls
# back to per-field reads when declare -n is unavailable. Tab-separated
# output makes the read split deterministic regardless of value contents.
# Args (out, by name): state recorded window_started tripped_at update_outcome reason
#######################################
_rh_diagnose_read_state() {
	local _state_var="$1" _recorded_var="$2" _window_var="$3"
	local _tripped_var="$4" _update_var="$5" _reason_var="$6"
	local _state="" _recorded="" _window="" _tripped="" _update="" _reason=""
	if [[ -f "$RUNNER_HEALTH_STATE_FILE" ]] && command -v jq >/dev/null 2>&1; then
		# Single jq pass: emit tab-separated values for atomic split.
		# `// ""` collapses null to empty so read doesn't choke.
		local row
		row=$(jq -r '.circuit_breaker as $cb | [
				($cb.state // ""),
				(.consecutive_zero_attempts // 0 | tostring),
				(.window_started_at // ""),
				($cb.tripped_at // ""),
				($cb.last_update_outcome // ""),
				($cb.reason // "")
			] | @tsv' <"$RUNNER_HEALTH_STATE_FILE" 2>/dev/null || true)
		if [[ -n "$row" ]]; then
			IFS=$'\t' read -r _state _recorded _window _tripped _update _reason <<<"$row"
		fi
	fi
	# Use printf -v + eval so we don't require declare -n (bash 3.2 safe).
	printf -v "$_state_var" '%s' "$_state"
	printf -v "$_recorded_var" '%s' "$_recorded"
	printf -v "$_window_var" '%s' "$_window"
	printf -v "$_tripped_var" '%s' "$_tripped"
	printf -v "$_update_var" '%s' "$_update"
	printf -v "$_reason_var" '%s' "$_reason"
	return 0
}

#######################################
# cmd_diagnose — cross-check recorded breaker state against observed
# pulse-wrapper.log evidence and surface wiring gaps before the operator
# notices the symptom. Read-only — never mutates the state file. (t3198)
#
# Output: human-readable table by default; structured JSON with --json.
#######################################
cmd_diagnose() {
	local emit_json=0
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--json)
			emit_json=1
			shift
			;;
		*) shift ;;
		esac
	done

	# Read all state fields in one jq pass. Cuts six literal jq paths down
	# to one and matches the existing _rh_state_apply / _rh_get_field
	# convention. Empty bundle when the state file or jq is unavailable.
	local state="" recorded="" window_started="" tripped_at=""
	local update_outcome="" reason=""
	_rh_diagnose_read_state state recorded window_started tripped_at \
		update_outcome reason
	[[ -n "$state" ]] || state="closed"
	[[ -n "$recorded" ]] || recorded=0

	# Compute tripped age (hours) when state=tripped.
	local tripped_age_h=""
	if [[ "$state" == "tripped" && -n "$tripped_at" ]]; then
		local tripped_epoch="" now_epoch=""
		tripped_epoch=$(_rh_iso_to_epoch "$tripped_at")
		now_epoch=$(_rh_iso_to_epoch "$(_rh_now)")
		if [[ "$tripped_epoch" -gt 0 && "$now_epoch" -gt "$tripped_epoch" ]]; then
			tripped_age_h=$(((now_epoch - tripped_epoch) / 3600))
		fi
	fi

	# Observe log evidence.
	local expected
	expected=$(_rh_count_log_no_worker_events)

	# Classify and produce advice.
	local update_health=""
	if _rh_update_recovery_healthy "$update_outcome"; then
		update_health="healthy"
	fi

	local finding="" advice=""
	finding=$(_rh_classify_diagnose "$recorded" "$expected" "$state" "$tripped_age_h" "$update_outcome" "$update_health")
	advice=$(_rh_diagnose_advice "$finding")

	if [[ "$emit_json" -eq 1 ]]; then
		_rh_emit_diagnose_json "$finding" "$state" "$recorded" "$expected" \
			"$window_started" "$tripped_at" "$tripped_age_h" "$update_outcome" \
			"$reason" "$advice"
	else
		_rh_emit_diagnose_human "$finding" "$state" "$recorded" "$expected" \
			"$window_started" "$tripped_at" "$tripped_age_h" "$update_outcome" \
			"$reason" "$advice"
	fi
	return 0
}

#######################################
# Human-readable diagnose output. All inputs pre-formatted by cmd_diagnose.
#######################################
_rh_emit_diagnose_human() {
	local finding="$1" state="$2" recorded="$3" expected="$4"
	local window_started="$5" tripped_at="$6" tripped_age_h="$7"
	local update_outcome="$8" reason="$9" advice="${10}"
	local threshold="${RUNNER_HEALTH_FAILURE_THRESHOLD:-10}"
	local delta=$((expected - recorded))

	printf 'finding:             %s\n' "$finding"
	printf 'state:               %s\n' "$state"
	printf 'recorded counter:    %s / %s threshold\n' "$recorded" "$threshold"
	printf 'observed in log:     %s no_worker_process events\n' "$expected"
	printf 'delta (obs-rec):     %s\n' "$delta"
	printf 'window started:      %s\n' "${window_started:-n/a}"
	if [[ "$state" == "tripped" ]]; then
		printf 'tripped at:          %s\n' "${tripped_at:-n/a}"
		printf 'tripped age (h):     %s\n' "${tripped_age_h:-n/a}"
		printf 'last update:         %s\n' "${update_outcome:-n/a}"
		printf 'reason:              %s\n' "${reason:-n/a}"
	fi
	printf 'advice: %s\n' "$advice"
	return 0
}

#######################################
# JSON diagnose output. Schema is documented in the helper header.
#######################################
_rh_emit_diagnose_json() {
	local finding="$1" state="$2" recorded="$3" expected="$4"
	local window_started="$5" tripped_at="$6" tripped_age_h="$7"
	local update_outcome="$8" reason="$9" advice="${10}"
	local threshold="${RUNNER_HEALTH_FAILURE_THRESHOLD:-10}"
	local delta=$((expected - recorded))

	# jq -n composes the object in a single pass so missing fields stay null.
	if command -v jq >/dev/null 2>&1; then
		jq -n \
			--arg finding "$finding" \
			--arg state "$state" \
			--argjson recorded "$recorded" \
			--argjson expected "$expected" \
			--argjson delta "$delta" \
			--argjson threshold "$threshold" \
			--arg window_started "${window_started:-}" \
			--arg tripped_at "${tripped_at:-}" \
			--arg tripped_age_h "${tripped_age_h:-}" \
			--arg update_outcome "${update_outcome:-}" \
			--arg reason "${reason:-}" \
			--arg advice "${advice:-}" \
			'{
				finding: $finding,
				state: $state,
				recorded_counter: $recorded,
				expected_counter: $expected,
				delta: $delta,
				threshold: $threshold,
				window_started_at: (if $window_started == "" then null else $window_started end),
				tripped_at: (if $tripped_at == "" then null else $tripped_at end),
				tripped_age_hours: (if $tripped_age_h == "" then null else ($tripped_age_h | tonumber) end),
				last_update_outcome: (if $update_outcome == "" then null else $update_outcome end),
				reason: (if $reason == "" then null else $reason end),
				advice: $advice
			}'
		return 0
	fi
	# jq is required for JSON output. Diagnose without jq still works in
	# the human path (the state-read helper degrades gracefully); ask the
	# caller to install jq for structured output.
	printf '{"error":"jq required for --json output"}\n' >&2
	return 1
}

#######################################
# Help text.
#######################################
cmd_help() {
	cat <<'EOF'
pulse-runner-health-helper.sh — Per-runner zero-attempt circuit breaker.

USAGE:
  pulse-runner-health-helper.sh record-outcome <signal> <issue-id>
  pulse-runner-health-helper.sh is-paused
  pulse-runner-health-helper.sh pause [--reason "<text>"]
  pulse-runner-health-helper.sh resume [--reason "<text>"]
  pulse-runner-health-helper.sh status [--json]
  pulse-runner-health-helper.sh diagnose [--json]
  pulse-runner-health-helper.sh help

DIAGNOSE FINDINGS (categories surfaced for operator action):
  HEALTHY          — counter at zero, no recent zero-attempt events.
  BUILDING         — counter > 0 and matches log evidence (or breaker
                     recently tripped and not yet verified); no action needed.
  RECOVERABLE_TRIPPED
                   — breaker is tripped, update ran, and deployed artifacts
                     match the local repo; the next pause check auto-resumes.
  WIRING_GAP       — log shows zero-attempt events the counter never saw
                     (recorder being skipped — likely caller-side bug).
  TRIGGER_MISSED   — counter reached threshold but breaker stayed closed
                     (trip path or signal predicate broken).
  STUCK_TRIPPED    — breaker tripped >24h ago and last update failed;
                     manual resume required after fixing the install.

ZERO-ATTEMPT SIGNALS (reset counter when not one of these):
  no_worker_process          — worker process never spawned.
  no_branch_created          — worker dispatched but no git branch in target repo.
  low_token_usage            — worker exited with <ZERO_ATTEMPT_TOKEN_FLOOR tokens.
  watchdog_killed_no_commit  — watchdog killed worker before any commit.

ENVIRONMENT:
  RUNNER_HEALTH_FAILURE_THRESHOLD          (default 10)
  RUNNER_HEALTH_WINDOW_HOURS               (default 6)
  RUNNER_HEALTH_BREAKER_RESUME_AFTER_UPDATE (default true)
  RUNNER_HEALTH_NO_UPDATE_PAUSE_HOURS      (default 24)
  RUNNER_HEALTH_DISABLED                   (default 0; set 1 to no-op all subcommands)

EXIT CODES:
  is-paused:  0 = breaker tripped (do NOT dispatch)
              1 = breaker closed/recovered (safe to dispatch)
EOF
	return 0
}

#######################################
# Dispatch.
#######################################
main() {
	local cmd="${1:-help}"
	shift || true
	case "$cmd" in
	record-outcome) cmd_record_outcome "$@" ;;
	is-paused) cmd_is_paused ;;
	pause) cmd_pause "$@" ;;
	resume) cmd_resume "$@" ;;
	status) cmd_status "$@" ;;
	diagnose) cmd_diagnose "$@" ;;
	help | -h | --help) cmd_help ;;
	*)
		printf 'Unknown subcommand: %s\n' "$cmd" >&2
		cmd_help
		return 1
		;;
	esac
	return $?
}

# Only run if invoked directly (sourcing exposes functions for tests).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
