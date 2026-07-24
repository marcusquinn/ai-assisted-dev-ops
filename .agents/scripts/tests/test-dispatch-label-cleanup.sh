#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR_TEST}/../shared-dispatch-label-cleanup.sh"
BLOCKER_LOGGER="${SCRIPT_DIR_TEST}/../worker-blocker-log.mjs"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
BLOCKER_LOG=""
ORIGINAL_HOME="$HOME"

print_result() {
	local name="$1"
	local passed="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_env() {
	TEST_ROOT=$(mktemp -d)
	export HOME="${TEST_ROOT}/home"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export REPOS_JSON="${TEST_ROOT}/repos.json"
	export PULSE_STALE_DISPATCH_LABEL_SWEEP_FORCE=1
	export PULSE_STALE_DISPATCH_LABEL_SWEEP_LIMIT_PER_REPO=5
	BLOCKER_LOG="${TEST_ROOT}/worker-progress-blockers.jsonl"
	export AIDEVOPS_WORKER_BLOCKER_LOG_FILE="$BLOCKER_LOG"
	export DISPATCH_LABEL_CLEANUP_BLOCKER_LOGGER="$BLOCKER_LOGGER"
	unset GH_STUB_FAIL_EDIT GH_STUB_FAIL_VIEW_ISSUE
	mkdir -p "$HOME/.aidevops/logs"
	: >"$LOGFILE"
	: >"${TEST_ROOT}/gh.log"
	cat >"$REPOS_JSON" <<'JSON'
{"initialized_repos":[{"slug":"owner/repo","pulse":true,"local_only":false},{"slug":"owner/local","pulse":true,"local_only":true},{"slug":"owner/off","pulse":false,"local_only":false}]}
JSON
	return 0
}

teardown_env() {
	export HOME="$ORIGINAL_HOME"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

install_gh_stub() {
	gh() {
		local command_name="$1"
		local subcommand_name="$2"
		local issue_number="${3:-}"
		printf '%s\n' "$*" >>"${TEST_ROOT}/gh.log"
		if [[ "$command_name" == "issue" && "$subcommand_name" == "view" ]]; then
			[[ "${GH_STUB_FAIL_VIEW_ISSUE:-}" != "$issue_number" ]] || return 1
			if [[ "$*" == *"--json state,stateReason,labels"* ]]; then
				case "$issue_number" in
				101) printf 'CLOSED\tCOMPLETED\tauto-dispatch|status:queued\n' ;;
				102) printf 'OPEN\t\tneeds-maintainer-permissions\n' ;;
				103) printf 'CLOSED\tNOT_PLANNED\t\n' ;;
				104) printf 'UNKNOWN\t\t\n' ;;
				*) printf 'CLOSED\tCOMPLETED\tauto-dispatch|status:queued\n' ;;
				esac
			else
				printf 'auto-dispatch\nstatus:queued\n'
			fi
			return 0
		fi
		if [[ "$command_name" == "issue" && "$subcommand_name" == "edit" && "${GH_STUB_FAIL_EDIT:-0}" == "1" ]]; then
			return 7
		fi
		return 0
	}
	return 0
}

append_blocker() {
	local issue_number="$1"
	local session_key="$2"
	local request_id="$3"
	if node "$BLOCKER_LOGGER" append --log-file "$BLOCKER_LOG" \
		--issue-number "$issue_number" --repo-slug owner/repo \
		--session-key "$session_key" --request-id "$request_id" \
		--event permission_request_captured --reason permission_required --source test; then
		return 0
	fi
	return 1
}

active_issues() {
	if node "$BLOCKER_LOGGER" list-active-issues --log-file "$BLOCKER_LOG" \
		--repo-slug owner/repo --limit 20; then
		return 0
	fi
	return 1
}

test_clear_terminal_labels_removes_dispatch_labels() {
	setup_env
	install_gh_stub
	# shellcheck source=../shared-dispatch-label-cleanup.sh
	source "$HELPER"
	clear_terminal_issue_dispatch_labels 42 owner/repo test-context
	local log_line
	log_line=$(tr '\n' ' ' <"${TEST_ROOT}/gh.log")
	if [[ "$log_line" == *"issue view 42 --repo owner/repo"* \
		&& "$log_line" == *"issue edit 42 --repo owner/repo"* \
		&& "$log_line" == *"--remove-label auto-dispatch"* \
		&& "$log_line" == *"--remove-label status:queued"* \
		&& "$log_line" != *"--remove-label status:in-review"* ]]; then
		print_result "terminal label cleanup strips only labels currently present" 0
	else
		print_result "terminal label cleanup strips only labels currently present" 1
	fi
	teardown_env
	return 0
}

test_sweep_reconciles_closed_active_blocker_candidates() {
	setup_env
	install_gh_stub
	# shellcheck source=../shared-dispatch-label-cleanup.sh
	source "$HELPER"
	append_blocker 101 issue-101-a request-a
	append_blocker 101 issue-101-b request-b
	append_blocker 102 issue-102 request-open
	append_blocker 103 issue-103 request-not-planned
	sweep_closed_auto_dispatch_issues
	local edit_count list_count view_count active terminal_count
	edit_count=$(grep -c 'issue edit' "${TEST_ROOT}/gh.log" || true)
	list_count=$(grep -c 'issue list' "${TEST_ROOT}/gh.log" || true)
	view_count=$(grep -c 'issue view' "${TEST_ROOT}/gh.log" || true)
	active=$(active_issues | tr '\n' ' ')
	terminal_count=$(jq -s '[.[] | select(.event == "issue_terminal_reconciled")] | length' "$BLOCKER_LOG")
	if [[ "$edit_count" == "1" && "$list_count" == "0" && "$view_count" == "3" \
		&& "$active" == "102 " && "$terminal_count" == "3" ]] &&
		grep -q 'reason":"issue_closed_not_planned"' "$BLOCKER_LOG" &&
		grep -q 'blocker sweep resolved=2 checked=3 open=1 ambiguous=0 logger_failed=0' "$LOGFILE"; then
		print_result "closed blocker sweep resolves every identity without label-dependent discovery" 0
	else
		print_result "closed blocker sweep resolves every identity without label-dependent discovery" 1
	fi
	local before_count="$terminal_count"
	sweep_closed_auto_dispatch_issues
	terminal_count=$(jq -s '[.[] | select(.event == "issue_terminal_reconciled")] | length' "$BLOCKER_LOG")
	if [[ "$terminal_count" == "$before_count" ]]; then
		print_result "closed blocker sweep is idempotent" 0
	else
		print_result "closed blocker sweep is idempotent" 1
	fi
	teardown_env
	return 0
}

test_sweep_preserves_blockers_on_api_ambiguity() {
	setup_env
	install_gh_stub
	# shellcheck source=../shared-dispatch-label-cleanup.sh
	source "$HELPER"
	append_blocker 104 issue-104 request-ambiguous
	sweep_closed_auto_dispatch_issues
	local active=""
	active=$(active_issues | tr '\n' ' ')
	if [[ "$active" == "104 " ]] && grep -q 'ambiguous=1' "$LOGFILE"; then
		print_result "closed blocker sweep preserves state on API ambiguity" 0
	else
		print_result "closed blocker sweep preserves state on API ambiguity" 1
	fi
	teardown_env
	return 0
}

test_sweep_preserves_blockers_on_logger_failure() {
	setup_env
	install_gh_stub
	# shellcheck source=../shared-dispatch-label-cleanup.sh
	source "$HELPER"
	append_blocker 101 issue-101 request-logger-failure
	local failing_logger="${TEST_ROOT}/failing-worker-blocker-log.mjs"
	cat >"$failing_logger" <<'JS'
if (process.argv[2] === "list-active-issues") {
  process.stdout.write("101\n");
  process.exit(0);
}
process.exit(1);
JS
	DISPATCH_LABEL_CLEANUP_BLOCKER_LOGGER="$failing_logger"
	sweep_closed_auto_dispatch_issues
	DISPATCH_LABEL_CLEANUP_BLOCKER_LOGGER="$BLOCKER_LOGGER"
	local active=""
	active=$(active_issues | tr '\n' ' ')
	if [[ "$active" == "101 " ]] && grep -q 'logger_failed=1' "$LOGFILE"; then
		print_result "closed blocker sweep preserves state on logger failure" 0
	else
		print_result "closed blocker sweep preserves state on logger failure" 1
	fi
	teardown_env
	return 0
}

test_clear_terminal_labels_propagates_edit_failures() {
	setup_env
	install_gh_stub
	export GH_STUB_FAIL_EDIT=1
	# shellcheck source=../shared-dispatch-label-cleanup.sh
	source "$HELPER"
	local exit_code=0
	clear_terminal_issue_dispatch_labels 42 owner/repo test-context || exit_code=$?
	unset GH_STUB_FAIL_EDIT
	local log_line=""
	log_line=$(tr '\n' ' ' <"$LOGFILE")
	if [[ "$exit_code" == "7" && "$log_line" == *"[exit: 7]"* ]]; then
		print_result "terminal label cleanup propagates edit failures" 0
	else
		print_result "terminal label cleanup propagates edit failures" 1
	fi
	teardown_env
	return 0
}

test_clear_terminal_labels_removes_dispatch_labels
test_sweep_reconciles_closed_active_blocker_candidates
test_sweep_preserves_blockers_on_api_ambiguity
test_sweep_preserves_blockers_on_logger_failure
test_clear_terminal_labels_propagates_edit_failures

printf 'Tests run: %s\n' "$TESTS_RUN"
printf 'Tests failed: %s\n' "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
