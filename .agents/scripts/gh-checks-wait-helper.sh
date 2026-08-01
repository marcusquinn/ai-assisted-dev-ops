#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# gh-checks-wait-helper.sh - Delta-aware required-check polling for AI sessions

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

LOG_PREFIX="GH-CHECKS-WAIT"
_GCW_DEFAULT_TIMEOUT="${AIDEVOPS_GH_CHECKS_TIMEOUT_SECONDS:-1800}"
_GCW_DEFAULT_INITIAL_INTERVAL="${AIDEVOPS_GH_CHECKS_INITIAL_INTERVAL_SECONDS:-15}"
_GCW_DEFAULT_MAX_INTERVAL="${AIDEVOPS_GH_CHECKS_MAX_INTERVAL_SECONDS:-120}"
_GCW_DEFAULT_HEARTBEAT_INTERVAL="${AIDEVOPS_GH_CHECKS_HEARTBEAT_SECONDS:-120}"
readonly _GCW_BUCKET_PASS="pass" _GCW_BUCKET_PENDING="pending" _GCW_BUCKET_SKIPPING="skipping"

usage() {
	cat <<'EOF'
Usage:
  gh-checks-wait-helper.sh wait PR_NUMBER [options]

Options:
  --repo OWNER/REPO          Repository (auto-detected when omitted)
  --all                      Include optional checks (default: required only)
  --timeout SECONDS          Overall timeout (default: 1800)
  --initial-interval SECONDS First and post-transition poll interval (default: 15)
  --max-interval SECONDS     Maximum unchanged-state interval (default: 120)
  --heartbeat SECONDS        Sparse unchanged-state message interval (default: 120)

The initial state is printed once. Later polls emit only state transitions,
sparse heartbeats, and the terminal result. Pending timeouts return exit 8,
terminal failures return exit 1, and indeterminate API failures return exit 2.
EOF
	return 0
}

validate_nonnegative_integer() {
	local value="$1"
	[[ "$value" =~ ^[0-9]+$ ]]
	return $?
}

validate_positive_integer() {
	local value="$1"
	[[ "$value" =~ ^[1-9][0-9]*$ ]]
	return $?
}

resolve_repo() {
	local repo="$1"
	if [[ -n "$repo" ]]; then
		printf '%s\n' "$repo"
		return 0
	fi
	gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null
	return $?
}

fixture_for_poll() {
	local fixture_dir="$1"
	local poll_number="$2"
	local requested="${fixture_dir}/poll-${poll_number}.json"
	if [[ -f "$requested" ]]; then
		printf '%s\n' "$requested"
		return 0
	fi
	local candidate=""
	local path=""
	for path in "${fixture_dir}"/poll-*.json; do
		[[ -f "$path" ]] || continue
		candidate="$path"
	done
	[[ -n "$candidate" ]] || return 1
	printf '%s\n' "$candidate"
	return 0
}

fetch_checks() {
	local pr_number="$1"
	local repo="$2"
	local required_only="$3"
	local poll_number="$4"
	local fixture_dir="${AIDEVOPS_GH_CHECKS_FIXTURE_DIR:-}"
	if [[ -n "$fixture_dir" ]]; then
		local fixture=""
		fixture=$(fixture_for_poll "$fixture_dir" "$poll_number") || return 1
		python3 - "$fixture" <<'PY'
import sys
with open(sys.argv[1], encoding="utf-8") as source:
    sys.stdout.write(source.read())
PY
		return 0
	fi
	local selection_mode="all"
	if [[ "$required_only" -eq 1 ]]; then
		selection_mode="required"
	fi
	local rc=0
	local checks=""
	local checks_stderr=""
	local checks_stderr_file=""
	checks_stderr_file=$(mktemp "${TMPDIR:-/tmp}/aidevops-gh-checks-wait.XXXXXX") || return 1
	checks=$(gh_pr_checks_exact_json "$repo" "$pr_number" "$selection_mode" \
		2>"$checks_stderr_file") || rc=$?
	checks_stderr=$(<"$checks_stderr_file")
	rm -f "$checks_stderr_file"
	if [[ "$required_only" -eq 1 && "$rc" -eq 1 && -z "$checks" && "$checks_stderr" =~ ^no\ required\ checks\ reported\ on\ the\ \'[^\']+\'\ branch$ ]]; then
		printf '[]\n'
		return 0
	fi
	if [[ -n "$checks_stderr" ]]; then
		return 1
	fi
	if [[ "$rc" -eq 0 || "$rc" -eq 1 || "$rc" -eq 8 ]]; then
		printf '%s' "$checks"
		return 0
	fi
	return "$rc"
}

canonicalize_checks() {
	local raw="$1"
	printf '%s' "$raw" | jq -c '
		if type != "array" then error("checks result is not an array") else . end
		| map({name:(.name // "unnamed"), workflow:(.workflow // ""), state:(.state // "unknown"), bucket:(.bucket // "unknown"), link:(.link // "")})
		| sort_by(.workflow, .name, .link)
	' 2>/dev/null
	return $?
}

state_counts() {
	local checks="$1"
	printf '%s' "$checks" | jq -r '
		group_by(.bucket)
		| map("\(.[0].bucket)=\(length)")
		| if length == 0 then "none=0" else join(" ") end
	'
	return 0
}

emit_initial_state() {
	local checks="$1"
	printf 'CI wait started: %s\n' "$(state_counts "$checks")"
	printf '%s' "$checks" | jq -r '.[] | "  \(.name): \(.bucket)"'
	return 0
}

emit_transitions() {
	local previous="$1"
	local current="$2"
	jq -nr --argjson previous "$previous" --argjson current "$current" '
		def keyed:
			map(. + {key: ((.workflow // "") + "|" + .name + "|" + (.link // ""))})
			| map({key:.key, value:.}) | from_entries;
		($previous | keyed) as $before
		| ($current | keyed) as $after
		| (($before | keys) + ($after | keys) | unique[]) as $key
		| ($before[$key] // null) as $old
		| ($after[$key] // null) as $new
		| if $old == null then "+ \($new.name): added as \($new.bucket)"
		  elif $new == null then "- \($old.name): removed"
		  elif $old.bucket != $new.bucket or $old.state != $new.state then
			"+ \($new.name): \($old.bucket) -> \($new.bucket)"
		  else empty end
	'
	return 0
}

classify_state() {
	local checks="$1"
	local count=""
	count=$(printf '%s' "$checks" | jq 'length')
	if [[ "$count" -eq 0 ]]; then
		printf 'success\n'
		return 0
	fi
	if printf '%s' "$checks" | jq -e --arg pass "$_GCW_BUCKET_PASS" --arg pending "$_GCW_BUCKET_PENDING" --arg skipping "$_GCW_BUCKET_SKIPPING" \
		'any(.[]; .bucket != $pass and .bucket != $pending and .bucket != $skipping)' >/dev/null; then
		printf 'failure\n'
		return 0
	fi
	if printf '%s' "$checks" | jq -e --arg pass "$_GCW_BUCKET_PASS" --arg skipping "$_GCW_BUCKET_SKIPPING" \
		'all(.[]; .bucket == $pass or .bucket == $skipping)' >/dev/null; then
		printf 'success\n'
		return 0
	fi
	printf 'pending\n'
	return 0
}

emit_failure_details() {
	local checks="$1"
	printf 'FAIL: required checks reached a terminal failure\n'
	printf '%s' "$checks" | jq -r --arg pass "$_GCW_BUCKET_PASS" --arg pending "$_GCW_BUCKET_PENDING" --arg skipping "$_GCW_BUCKET_SKIPPING" \
		'.[] | select(.bucket != $pass and .bucket != $pending and .bucket != $skipping) | "  \(.name): \(.bucket)\(if .link == "" then "" else " " + .link end)"'
	return 0
}

read_head_sha() {
	local pr_number="$1"
	local repo="$2"
	if [[ -n "${AIDEVOPS_GH_CHECKS_TEST_HEAD+x}" ]]; then
		printf '%s\n' "$AIDEVOPS_GH_CHECKS_TEST_HEAD"
		return 0
	fi
	gh pr view "$pr_number" --repo "$repo" --json headRefOid --jq '.headRefOid // empty' 2>/dev/null
	return $?
}

write_runtime_heartbeat() {
	local heartbeat_file="${AIDEVOPS_FULL_LOOP_HEARTBEAT_FILE:-}"
	[[ -n "$heartbeat_file" ]] || return 0
	local run_id="${AIDEVOPS_FULL_LOOP_RUN_ID:-gh-checks-wait}"
	local timestamp=""
	timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
	printf '%s %s\n' "$run_id" "$timestamp" >"${heartbeat_file}.tmp.$$" 2>/dev/null || return 0
	mv "${heartbeat_file}.tmp.$$" "$heartbeat_file" 2>/dev/null || true
	return 0
}

poll_sleep() {
	local seconds="$1"
	if [[ "${AIDEVOPS_GH_CHECKS_TEST_NO_SLEEP:-0}" == "1" ]]; then
		return 0
	fi
	sleep "$seconds"
	return 0
}

next_interval() {
	local current="$1"
	local maximum="$2"
	local next=$((current * 2))
	[[ "$next" -le "$maximum" ]] || next="$maximum"
	printf '%s\n' "$next"
	return 0
}

wait_for_checks() {
	local pr_number="$1" repo="$2" required_only="$3" timeout="$4"
	local initial_interval="$5" max_interval="$6" heartbeat_interval="$7"
	local start_epoch=""
	start_epoch=$(date +%s)
	local next_heartbeat=$((start_epoch + heartbeat_interval))
	local interval="$initial_interval" previous="" initial_head=""
	initial_head=$(read_head_sha "$pr_number" "$repo" 2>/dev/null || true)
	if [[ -z "$initial_head" ]]; then
		printf 'INDETERMINATE: PR head could not be verified before required-check observation\n' >&2
		return 2
	fi
	local poll_number=0 valid_state_seen=0 api_error_visible=0
	while true; do
		poll_number=$((poll_number + 1))
		write_runtime_heartbeat
		local raw="" fetch_rc=0 current="" now_epoch="" elapsed=0 changed=0 classification="" final_head=""
		raw=$(fetch_checks "$pr_number" "$repo" "$required_only" "$poll_number") || fetch_rc=$?
		if [[ "$fetch_rc" -eq 0 ]]; then
			current=$(canonicalize_checks "$raw" 2>/dev/null || true)
		fi
		now_epoch=$(date +%s)
		elapsed=$((now_epoch - start_epoch))
		if [[ -z "$current" ]]; then
			if [[ "$api_error_visible" -eq 0 ]]; then
				printf 'WARN: required-check state unavailable; retaining the last verified state and retrying\n' >&2
				api_error_visible=1
			fi
			if [[ "$elapsed" -ge "$timeout" ]]; then
				printf 'INDETERMINATE: required-check state unavailable after %ss\n' "$elapsed" >&2
				return 2
			fi
			poll_sleep "$interval"
			interval=$(next_interval "$interval" "$max_interval")
			continue
		fi
		if [[ "$api_error_visible" -eq 1 ]]; then
			printf 'API state recovered: %s\n' "$(state_counts "$current")"
			api_error_visible=0
		fi
		valid_state_seen=1
		if [[ -z "$previous" ]]; then
			emit_initial_state "$current"
			changed=1
		elif [[ "$current" != "$previous" ]]; then
			emit_transitions "$previous" "$current"
			changed=1
		elif [[ "$heartbeat_interval" -gt 0 && "$now_epoch" -ge "$next_heartbeat" ]]; then
			printf 'heartbeat: required checks unchanged for %ss (%s)\n' "$elapsed" "$(state_counts "$current")"
			next_heartbeat=$((now_epoch + heartbeat_interval))
		fi
		if [[ "$changed" -eq 1 ]]; then
			next_heartbeat=$((now_epoch + heartbeat_interval))
		fi

		classification=$(classify_state "$current")
		case "$classification" in
		failure)
			emit_failure_details "$current"
			return 1
			;;
		success)
			final_head=$(read_head_sha "$pr_number" "$repo" 2>/dev/null || true)
			if [[ -z "$final_head" ]]; then
				printf 'INDETERMINATE: PR head could not be verified after required checks completed\n' >&2
				return 2
			fi
			if [[ -n "$initial_head" && -n "$final_head" && "$initial_head" != "$final_head" ]]; then
				printf '+ PR head changed while waiting; restarting required-check observation\n'
				initial_head="$final_head"
				previous=""
				interval="$initial_interval"
				poll_sleep "$interval"
				continue
			fi
			printf 'PASS: required checks completed in %ss (%s)\n' "$elapsed" "$(state_counts "$current")"
			return 0
			;;
		pending | indeterminate) ;;
		esac
		if [[ "$elapsed" -ge "$timeout" ]]; then
			if [[ "$valid_state_seen" -eq 1 ]]; then
				printf 'TIMEOUT: required checks remain non-terminal after %ss (%s)\n' "$elapsed" "$(state_counts "$current")" >&2
				return 8
			fi
			return 2
		fi
		previous="$current"
		if [[ "$changed" -eq 1 ]]; then
			interval="$initial_interval"
		else
			interval=$(next_interval "$interval" "$max_interval")
		fi
		poll_sleep "$interval"
	done
}

cmd_wait() {
	local pr_number="${1:-}"
	[[ "$pr_number" =~ ^[0-9]+$ ]] || {
		log_error "wait requires a numeric PR number"
		return 1
	}
	shift
	local repo=""
	local required_only=1
	local timeout="$_GCW_DEFAULT_TIMEOUT"
	local initial_interval="$_GCW_DEFAULT_INITIAL_INTERVAL"
	local max_interval="$_GCW_DEFAULT_MAX_INTERVAL"
	local heartbeat_interval="$_GCW_DEFAULT_HEARTBEAT_INTERVAL"
	while [[ $# -gt 0 ]]; do
		local opt="$1"
		case "$opt" in
		--repo) local repo_value="$2"; repo="$repo_value"; shift 2 ;;
		--all) required_only=0; shift ;;
		--timeout) local timeout_value="$2"; timeout="$timeout_value"; shift 2 ;;
		--initial-interval) local initial_value="$2"; initial_interval="$initial_value"; shift 2 ;;
		--max-interval) local max_value="$2"; max_interval="$max_value"; shift 2 ;;
		--heartbeat) local heartbeat_value="$2"; heartbeat_interval="$heartbeat_value"; shift 2 ;;
		*) log_error "Unknown wait option: $opt"; return 1 ;;
		esac
	done
	if ! validate_nonnegative_integer "$timeout" || ! validate_nonnegative_integer "$heartbeat_interval" || \
		! validate_positive_integer "$initial_interval" || ! validate_positive_integer "$max_interval"; then
		log_error "timeout/heartbeat must be non-negative and poll intervals must be positive integers"
		return 1
	fi
	if [[ "$initial_interval" -gt "$max_interval" ]]; then
		log_error "initial interval cannot exceed maximum interval"
		return 1
	fi
	repo=$(resolve_repo "$repo") || {
		log_error "Cannot resolve repository; pass --repo OWNER/REPO"
		return 2
	}
	wait_for_checks "$pr_number" "$repo" "$required_only" "$timeout" "$initial_interval" "$max_interval" "$heartbeat_interval"
	return $?
}

main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	wait) cmd_wait "$@" ;;
	help | --help | -h) usage ;;
	*) log_error "Unknown command: $command"; usage; return 1 ;;
	esac
	return $?
}

main "$@"
