#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
INTAKE_SCRIPT="${SCRIPT_DIR}/../pulse-dependabot-intake.sh"
TEST_ROOT=""
ISSUES_JSON="[]"
AUTHENTIC=1

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
	printf '%s\n' "$ISSUES_JSON"
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
	ISSUES_JSON="[]"
	AUTHENTIC=1
	_pulse_route_dependabot_pr_to_worker_issue "30038" "owner/repo" "app/dependabot" "head-current" "policy-ineligible"
	[[ -f "${TEST_ROOT}/create-args" ]] || return 1
	assert_file_contains "worker issue has auto-dispatch ownership" "${TEST_ROOT}/create-args" "auto-dispatch,origin:worker,tier:standard,dependencies"
	assert_file_contains "worker issue cites source PR" "${TEST_ROOT}/created-body" "Source PR: https://github.com/owner/repo/pull/30038"
	assert_file_contains "worker issue carries idempotency marker" "${TEST_ROOT}/created-body" "aidevops:dependabot-pr-intake repo=owner/repo pr=30038"
	return 0
}

test_reuses_existing_issue() {
	rm -f "${TEST_ROOT}/create-args"
	ISSUES_JSON='[{"number":42,"url":"https://github.com/owner/repo/issues/42","body":"<!-- aidevops:dependabot-pr-intake repo=owner/repo pr=30038 -->"}]'
	_pulse_route_dependabot_pr_to_worker_issue "30038" "owner/repo" "app/dependabot" "head-current" "terminal-ci-failure"
	[[ ! -e "${TEST_ROOT}/create-args" ]]
	return $?
}

test_rejects_unverified_author() {
	rm -f "${TEST_ROOT}/create-args"
	ISSUES_JSON="[]"
	AUTHENTIC=0
	if _pulse_route_dependabot_pr_to_worker_issue "30038" "owner/repo" "app/dependabot" "head-current" "policy-ineligible"; then
		return 1
	fi
	[[ ! -e "${TEST_ROOT}/create-args" ]]
	return $?
}

test_dry_run_has_no_write() {
	rm -f "${TEST_ROOT}/create-args"
	ISSUES_JSON="[]"
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
	test_dry_run_has_no_write
	printf 'PASS dry-run performs no GitHub write\n'
	test_concurrent_routes_create_once
	printf 'PASS concurrent routes converge on one issue\n'
	return 0
}

main "$@"
