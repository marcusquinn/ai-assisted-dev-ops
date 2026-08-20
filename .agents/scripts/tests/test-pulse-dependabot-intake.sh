#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
INTAKE_SCRIPT="${SCRIPT_DIR}/../pulse-dependabot-intake.sh"
TEST_ROOT=""
OPEN_ISSUES_JSON="[]"
CLOSED_ISSUES_JSON="[]"
AUTHENTIC=1
PR_LABELS=""
PR_FINAL_JSON='{"state":"OPEN","headRefOid":"head-current","labels":[{"name":"needs-maintainer-review"}]}'
PR_VIEW_FAIL=0
SUPERSEDING_PR=""

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export AIDEVOPS_TEMP_DIR="${TEST_ROOT}/tmp"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	mkdir -p "$AIDEVOPS_TEMP_DIR"
	: >"$LOGFILE"
	export TEST_ROOT
	return 0
}

teardown_test_env() {
	[[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]] && rm -rf "$TEST_ROOT"
	return 0
}

_is_authentic_dependabot_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_author="$3"
	local expected_head_sha="$4"
	[[ "$AUTHENTIC" -eq 1 && "$pr_number" == "30038" && "$repo_slug" == "owner/repo" \
		&& "$pr_author" == "app/dependabot" && "$expected_head_sha" == "head-current" ]]
	return $?
}

gh_issue_list() {
	local args=" $* "
	if [[ "$args" == *" --state closed "* ]]; then
		printf '%s\n' "$CLOSED_ISSUES_JSON"
	else
		printf '%s\n' "$OPEN_ISSUES_JSON"
	fi
	return 0
}

gh_pr_view() {
	[[ "$PR_VIEW_FAIL" -eq 0 ]] || return 1
	if [[ " $* " == *" --json state,headRefOid,labels "* ]]; then
		printf '%s\n' "$PR_FINAL_JSON"
	else
		printf '%s\n' "$PR_LABELS"
	fi
	return 0
}

_psh_find_merged_closer_for_closed_issue() {
	local repo_slug="$1"
	local issue_number="$2"
	local current_pr="$3"
	[[ "$repo_slug" == "owner/repo" && "$issue_number" == "42" && "$current_pr" == "30038" ]] || return 1
	[[ "$SUPERSEDING_PR" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$SUPERSEDING_PR"
	return 0
}

gh_pr_close_safe() {
	printf '%s\n' "$@" >"${TEST_ROOT}/pr-close-args"
	return 0
}

gh_create_issue() {
	local arg=""
	local body_file=""
	local args_file="${TEST_ROOT}/create-args"
	printf '%s\n' "$@" >"$args_file"
	while [[ "$#" -gt 0 ]]; do
		arg="$1"
		shift
		if [[ "$arg" == "--body-file" && "$#" -gt 0 ]]; then
			body_file="$1"
			shift
		fi
	done
	[[ -n "$body_file" && -f "$body_file" ]] || return 1
	cp "$body_file" "${TEST_ROOT}/created-body"
	printf 'https://github.com/owner/repo/issues/42\n'
	return 0
}

assert_file_contains() {
	local description="$1"
	local file_path="$2"
	local expected="$3"
	if grep -qF -- "$expected" "$file_path"; then
		printf 'PASS %s\n' "$description"
		return 0
	fi
	printf 'FAIL %s\n' "$description" >&2
	return 1
}

test_creates_worker_ready_issue() {
	rm -f "${TEST_ROOT}/create-args" "${TEST_ROOT}/created-body"
	OPEN_ISSUES_JSON="[]"
	CLOSED_ISSUES_JSON="[]"
	AUTHENTIC=1
	PR_LABELS=""
	PR_VIEW_FAIL=0
	_pulse_route_dependabot_pr_to_worker_issue "30038" "owner/repo" "app/dependabot" "head-current" "policy-ineligible"
	[[ -f "${TEST_ROOT}/create-args" ]] || return 1
	assert_file_contains "worker issue has auto-dispatch ownership" "${TEST_ROOT}/create-args" "auto-dispatch,origin:worker,tier:standard,dependencies"
	assert_file_contains "worker issue cites source PR" "${TEST_ROOT}/created-body" "Source PR: https://github.com/owner/repo/pull/30038"
	assert_file_contains "worker issue carries idempotency marker" "${TEST_ROOT}/created-body" "aidevops:dependabot-pr-intake repo=owner/repo pr=30038"
	return 0
}

test_reuses_existing_issue() {
	rm -f "${TEST_ROOT}/create-args"
	OPEN_ISSUES_JSON='[{"number":42,"url":"https://github.com/owner/repo/issues/42","body":"<!-- aidevops:dependabot-pr-intake repo=owner/repo pr=30038 -->"}]'
	_pulse_route_dependabot_pr_to_worker_issue "30038" "owner/repo" "app/dependabot" "head-current" "terminal-ci-failure"
	[[ ! -e "${TEST_ROOT}/create-args" ]]
	return $?
}

test_rejects_unverified_author() {
	rm -f "${TEST_ROOT}/create-args"
	OPEN_ISSUES_JSON="[]"
	AUTHENTIC=0
	if _pulse_route_dependabot_pr_to_worker_issue "30038" "owner/repo" "app/dependabot" "head-current" "policy-ineligible"; then
		return 1
	fi
	[[ ! -e "${TEST_ROOT}/create-args" ]]
	return $?
}

test_preserves_explicit_maintainer_hold() {
	local route_rc=0

	rm -f "${TEST_ROOT}/create-args"
	OPEN_ISSUES_JSON="[]"
	CLOSED_ISSUES_JSON="[]"
	AUTHENTIC=1
	PR_LABELS="needs-maintainer-review"
	PR_VIEW_FAIL=0
	_pulse_route_dependabot_pr_to_worker_issue "30038" "owner/repo" "app/dependabot" "head-current" "policy-ineligible" || route_rc=$?
	[[ "$route_rc" -eq 3 ]] || return 1
	[[ ! -e "${TEST_ROOT}/create-args" ]] || return 1
	assert_file_contains "explicit hold is preserved" "$LOGFILE" "preserving explicit needs-maintainer-review hold; no worker issue created"
	PR_LABELS=""
	return 0
}

test_closes_held_source_after_verified_replacement() {
	local route_rc=0

	rm -f "${TEST_ROOT}/create-args" "${TEST_ROOT}/pr-close-args"
	OPEN_ISSUES_JSON="[]"
	CLOSED_ISSUES_JSON='[{"number":42,"body":"<!-- aidevops:dependabot-pr-intake repo=owner/repo pr=30038 -->","labels":[{"name":"origin:worker"},{"name":"status:done"},{"name":"solved:worker"}]}]'
	AUTHENTIC=1
	PR_LABELS="needs-maintainer-review"
	PR_FINAL_JSON='{"state":"OPEN","headRefOid":"head-current","labels":[{"name":"needs-maintainer-review"}]}'
	PR_VIEW_FAIL=0
	SUPERSEDING_PR="99"
	_pulse_route_dependabot_pr_to_worker_issue "30038" "owner/repo" "app/dependabot" "head-current" "policy-ineligible" || route_rc=$?
	[[ "$route_rc" -eq 4 ]] || return 1
	assert_file_contains "superseded source PR is closed" "${TEST_ROOT}/pr-close-args" "30038"
	assert_file_contains "source close names verified replacement" "${TEST_ROOT}/pr-close-args" "verified merged replacement PR #99"
	assert_file_contains "source close is diagnosed" "$LOGFILE" "closed as superseded by merged PR #99 for completed intake #42"
	CLOSED_ISSUES_JSON="[]"
	PR_LABELS=""
	SUPERSEDING_PR=""
	return 0
}

test_preserves_hold_when_terminal_issue_has_no_merged_replacement() {
	local route_rc=0

	rm -f "${TEST_ROOT}/pr-close-args"
	OPEN_ISSUES_JSON="[]"
	CLOSED_ISSUES_JSON='[{"number":42,"body":"<!-- aidevops:dependabot-pr-intake repo=owner/repo pr=30038 -->","labels":[{"name":"origin:worker"},{"name":"status:done"},{"name":"solved:worker"}]}]'
	AUTHENTIC=1
	PR_LABELS="needs-maintainer-review"
	SUPERSEDING_PR=""
	_pulse_route_dependabot_pr_to_worker_issue "30038" "owner/repo" "app/dependabot" "head-current" "policy-ineligible" || route_rc=$?
	[[ "$route_rc" -eq 3 ]] || return 1
	[[ ! -e "${TEST_ROOT}/pr-close-args" ]] || return 1
	CLOSED_ISSUES_JSON="[]"
	PR_LABELS=""
	return 0
}

test_preserves_hold_without_worker_solution_attribution() {
	local route_rc=0

	rm -f "${TEST_ROOT}/pr-close-args"
	OPEN_ISSUES_JSON="[]"
	CLOSED_ISSUES_JSON='[{"number":42,"body":"<!-- aidevops:dependabot-pr-intake repo=owner/repo pr=30038 -->","labels":[{"name":"origin:worker"},{"name":"status:done"},{"name":"solved:interactive"}]}]'
	AUTHENTIC=1
	PR_LABELS="needs-maintainer-review"
	SUPERSEDING_PR="99"
	_pulse_route_dependabot_pr_to_worker_issue "30038" "owner/repo" "app/dependabot" "head-current" "policy-ineligible" || route_rc=$?
	[[ "$route_rc" -eq 3 ]] || return 1
	[[ ! -e "${TEST_ROOT}/pr-close-args" ]] || return 1
	CLOSED_ISSUES_JSON="[]"
	PR_LABELS=""
	SUPERSEDING_PR=""
	return 0
}

test_preserves_hold_when_source_head_drifted() {
	local route_rc=0

	rm -f "${TEST_ROOT}/pr-close-args"
	OPEN_ISSUES_JSON="[]"
	CLOSED_ISSUES_JSON='[{"number":42,"body":"<!-- aidevops:dependabot-pr-intake repo=owner/repo pr=30038 -->","labels":[{"name":"origin:worker"},{"name":"status:done"},{"name":"solved:worker"}]}]'
	AUTHENTIC=1
	PR_LABELS="needs-maintainer-review"
	PR_FINAL_JSON='{"state":"OPEN","headRefOid":"head-changed","labels":[{"name":"needs-maintainer-review"}]}'
	SUPERSEDING_PR="99"
	_pulse_route_dependabot_pr_to_worker_issue "30038" "owner/repo" "app/dependabot" "head-current" "policy-ineligible" || route_rc=$?
	[[ "$route_rc" -eq 3 ]] || return 1
	[[ ! -e "${TEST_ROOT}/pr-close-args" ]] || return 1
	CLOSED_ISSUES_JSON="[]"
	PR_FINAL_JSON='{"state":"OPEN","headRefOid":"head-current","labels":[{"name":"needs-maintainer-review"}]}'
	PR_LABELS=""
	SUPERSEDING_PR=""
	return 0
}

test_dry_run_reports_supersession_without_close() {
	local route_rc=0

	rm -f "${TEST_ROOT}/pr-close-args"
	OPEN_ISSUES_JSON="[]"
	CLOSED_ISSUES_JSON='[{"number":42,"body":"<!-- aidevops:dependabot-pr-intake repo=owner/repo pr=30038 -->","labels":[{"name":"origin:worker"},{"name":"status:done"},{"name":"solved:worker"}]}]'
	AUTHENTIC=1
	PR_LABELS="needs-maintainer-review"
	SUPERSEDING_PR="99"
	DRY_RUN=1 _pulse_route_dependabot_pr_to_worker_issue "30038" "owner/repo" "app/dependabot" "head-current" "policy-ineligible" || route_rc=$?
	[[ "$route_rc" -eq 4 ]] || return 1
	[[ ! -e "${TEST_ROOT}/pr-close-args" ]] || return 1
	assert_file_contains "dry-run reports verified source supersession" "$LOGFILE" "would close as superseded by merged PR #99"
	CLOSED_ISSUES_JSON="[]"
	PR_LABELS=""
	SUPERSEDING_PR=""
	return 0
}

test_fails_closed_when_hold_state_is_unavailable() {
	local route_rc=0

	rm -f "${TEST_ROOT}/create-args"
	OPEN_ISSUES_JSON="[]"
	CLOSED_ISSUES_JSON="[]"
	AUTHENTIC=1
	PR_LABELS=""
	PR_VIEW_FAIL=1
	_pulse_route_dependabot_pr_to_worker_issue "30038" "owner/repo" "app/dependabot" "head-current" "policy-ineligible" || route_rc=$?
	[[ "$route_rc" -eq 1 ]] || return 1
	[[ ! -e "${TEST_ROOT}/create-args" ]] || return 1
	assert_file_contains "unavailable hold state fails closed" "$LOGFILE" "live maintainer-review hold state unavailable; failing closed"
	PR_VIEW_FAIL=0
	return 0
}

test_dry_run_has_no_write() {
	rm -f "${TEST_ROOT}/create-args"
	OPEN_ISSUES_JSON="[]"
	CLOSED_ISSUES_JSON="[]"
	AUTHENTIC=1
	DRY_RUN=1 _pulse_route_dependabot_pr_to_worker_issue "30038" "owner/repo" "app/dependabot" "head-current" "merge-conflict"
	[[ ! -e "${TEST_ROOT}/create-args" ]]
	return $?
}

test_concurrent_routes_create_once() {
	local worker_script="${TEST_ROOT}/concurrent-worker.sh"
	local shared_state="${TEST_ROOT}/concurrent-state"
	local create_count="${TEST_ROOT}/concurrent-create-count"
	local worker_one=""
	local worker_two=""

	mkdir -p "$shared_state"
	cat >"$worker_script" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

INTAKE_SCRIPT="$1"
TEST_ROOT="$2"
SHARED_STATE="$3"
CREATE_COUNT="$4"
export AIDEVOPS_TEMP_DIR="${TEST_ROOT}/concurrent-tmp"
export LOGFILE="${TEST_ROOT}/concurrent-pulse.log"
mkdir -p "$AIDEVOPS_TEMP_DIR"

_is_authentic_dependabot_pr() {
	local pr_number="$1"
	local repo_slug="$2"
	local pr_author="$3"
	local expected_head_sha="$4"
	[[ "$pr_number" == "30038" && "$repo_slug" == "owner/repo" \
		&& "$pr_author" == "app/dependabot" && "$expected_head_sha" == "head-current" ]]
	return $?
}

gh_issue_list() {
	if [[ -f "${SHARED_STATE}/created" ]]; then
		printf '%s\n' '[{"number":42,"url":"https://github.com/owner/repo/issues/42","body":"<!-- aidevops:dependabot-pr-intake repo=owner/repo pr=30038 -->"}]'
	else
		printf '%s\n' '[]'
	fi
	return 0
}

gh_create_issue() {
	printf '%s\n' "$$" >>"$CREATE_COUNT"
	sleep 1
	: >"${SHARED_STATE}/created"
	printf '%s\n' 'https://github.com/owner/repo/issues/42'
	return 0
}

gh_pr_view() {
	printf '%s\n' ''
	return 0
}

# shellcheck source=../pulse-dependabot-intake.sh
source "$INTAKE_SCRIPT"
_pulse_route_dependabot_pr_to_worker_issue "30038" "owner/repo" "app/dependabot" "head-current" "policy-ineligible"
exit 0
EOF
	chmod 700 "$worker_script"
	"$worker_script" "$INTAKE_SCRIPT" "$TEST_ROOT" "$shared_state" "$create_count" &
	worker_one=$!
	"$worker_script" "$INTAKE_SCRIPT" "$TEST_ROOT" "$shared_state" "$create_count" &
	worker_two=$!
	wait "$worker_one"
	wait "$worker_two"
	[[ "$(wc -l <"$create_count" | tr -d ' ')" == "1" ]]
	return $?
}

main() {
	setup_test_env
	trap teardown_test_env EXIT
	# shellcheck source=../pulse-dependabot-intake.sh
	source "$INTAKE_SCRIPT"
	test_creates_worker_ready_issue
	test_reuses_existing_issue
	printf 'PASS existing intake is idempotent\n'
	test_rejects_unverified_author
	printf 'PASS unverified authors fail closed\n'
	test_preserves_explicit_maintainer_hold
	test_closes_held_source_after_verified_replacement
	test_preserves_hold_when_terminal_issue_has_no_merged_replacement
	test_preserves_hold_without_worker_solution_attribution
	test_preserves_hold_when_source_head_drifted
	test_dry_run_reports_supersession_without_close
	test_fails_closed_when_hold_state_is_unavailable
	test_dry_run_has_no_write
	printf 'PASS dry-run performs no GitHub write\n'
	test_concurrent_routes_create_once
	printf 'PASS concurrent routes converge on one issue\n'
	return 0
}

main "$@"
