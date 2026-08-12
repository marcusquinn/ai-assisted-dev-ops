#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Integrated regression: a registered attempt that dies during launch
# stability validation can release its exact in-progress ownership.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
AGENT_SCRIPT_DIR="${TEST_DIR}/.."
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/aidevops-launch-recovery.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

SCRIPT_DIR="$AGENT_SCRIPT_DIR"
LOGFILE="${TEST_TMP}/pulse.log"
PULSE_LAUNCH_GRACE_SECONDS=1
PULSE_LAUNCH_STABILITY_SECONDS=1
source "${AGENT_SCRIPT_DIR}/pulse-cleanup.sh"
source "${AGENT_SCRIPT_DIR}/pulse-dispatch-engine.sh"

SCRIPT_DIR="$TEST_TMP"
cat >"${TEST_TMP}/dispatch-ledger-helper.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "check-issue" ]]; then
	printf '%s\n' '{"session_key":"issue-30029","attempt_id":"attempt-30029","lease_token":"lease-30029","runner_device":"runner-device","pid":2147483647,"owner_process_start":"start-30029","status":"in-flight","lease_phase":"prelaunch"}'
	exit 0
fi
printf '%s\n' "$*" >>"${LEDGER_CALLS_FILE:?}"
exit 0
EOF
chmod +x "${TEST_TMP}/dispatch-ledger-helper.sh"
export LEDGER_CALLS_FILE="${TEST_TMP}/ledger-calls"

issue_status="in-progress"
issue_assigned="true"
worker_checks=0
dispatch_identity='<!-- aidevops:dispatch lease_token=lease-30029 device=runner-device session=issue-30029 attempt_id=attempt-30029 claim_id=77 -->'
gh() {
	local command_name="$1"
	shift
	if [[ "$command_name" == "api" && "$1" == "user" ]]; then
		printf '%s\n' 'runner-a'
		return 0
	fi
	if [[ "$command_name" == "api" && "$1" == "repos/owner/repo/issues/30029/comments" ]]; then
		printf '%s\n' "$dispatch_identity"
		return 0
	fi
	if [[ "$command_name" == "issue" && "$1" == "view" ]]; then
		jq -cn --arg status "$issue_status" --argjson assigned "$issue_assigned" '{state:"OPEN",labels:[{name:("status:" + $status)}],assignees:(if $assigned then [{login:"runner-a"}] else [] end)}'
		return 0
	fi
	return 0
}

has_worker_for_repo_issue() {
	local issue_number="$1"
	local repo_slug="$2"
	: "$issue_number" "$repo_slug"
	worker_checks=$((worker_checks + 1))
	[[ "$worker_checks" -eq 1 ]]
}

set_issue_status() {
	local issue_number="$1"
	local repo_slug="$2"
	local target_status="$3"
	shift 3
	: "$issue_number" "$repo_slug" "$@"
	issue_status="$target_status"
	issue_assigned="false"
	return 0
}

_process_start_token() { return 1; }
aidevops_pulse_worker_log_candidates() { return 0; }
_post_launch_recovery_claim_released() { return 0; }
_post_launch_cooldown_marker() { return 0; }
_record_runner_health_zero_attempt() { return 0; }
unlock_issue_after_worker() { return 0; }
fast_fail_record() { return 0; }

if check_worker_launch 30029 owner/repo 1; then
	printf 'FAIL: disappearing worker passed launch validation\n' >&2
	exit 1
fi
[[ "$issue_status" == "available" && "$issue_assigned" == "false" ]] || {
	printf 'FAIL: exact in-progress ownership was not released\n' >&2
	exit 1
}
grep -q '^fail --session-key issue-30029 --lease-token lease-30029 --attempt-id attempt-30029$' "$LEDGER_CALLS_FILE" || {
	printf 'FAIL: exact registered attempt was not failed in the ledger\n' >&2
	exit 1
}
grep -q 'Launch recovery reset #30029' "$LOGFILE" || {
	printf 'FAIL: recovery receipt was not recorded\n' >&2
	exit 1
}

issue_status="in-progress"
issue_assigned="true"
dispatch_identity='<!-- aidevops:dispatch lease_token=lease-late device=runner-device session=issue-30029 attempt_id=attempt-late claim_id=78 -->'
recover_failed_launch_state 30029 owner/repo no_worker_process
[[ "$issue_status" == "in-progress" && "$issue_assigned" == "true" ]] || {
	printf 'FAIL: mismatched late attempt ownership was disturbed\n' >&2
	exit 1
}
[[ "$(wc -l <"$LEDGER_CALLS_FILE" | tr -d '[:space:]')" == "1" ]] || {
	printf 'FAIL: mismatched late attempt changed the ledger\n' >&2
	exit 1
}

printf 'PASS: post-launch in-progress ownership recovers only the exact registered attempt\n'
