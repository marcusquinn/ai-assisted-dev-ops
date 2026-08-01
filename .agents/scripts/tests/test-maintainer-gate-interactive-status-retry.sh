#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#29128: the trusted origin:interactive fast path
# must retry commit-status publication and fail closed when it stays unavailable.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
WORKFLOW_FILE="${REPO_ROOT}/.github/workflows/maintainer-gate-reusable.yml"
TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s' "$test_name"
	if [[ -n "$detail" ]]; then
		printf ': %s' "$detail"
	fi
	printf '\n'
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT="$(mktemp -d -t maintainer-gate-interactive-status.XXXXXX)"
	mkdir -p "${TEST_ROOT}/bin"
	export GH_CALLS="${TEST_ROOT}/gh-calls.log"
	export GH_STATUS_CALLS="${TEST_ROOT}/status-call-count"
	printf '0' >"$GH_STATUS_CALLS"

	python3 - "$WORKFLOW_FILE" "${TEST_ROOT}/job.sh" <<'PY'
import pathlib
import sys
import yaml

workflow = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
steps = workflow["jobs"]["check-pr"]["steps"]
run = next(step["run"] for step in steps if "run" in step)
pathlib.Path(sys.argv[2]).write_text(run)
PY

	cat >"${TEST_ROOT}/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_CALLS"

if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
	printf 'origin:interactive\n'
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == *"/statuses/"* ]]; then
	status_calls=$(<"$GH_STATUS_CALLS")
	status_calls=$((status_calls + 1))
	printf '%s' "$status_calls" >"$GH_STATUS_CALLS"
	case "${GH_SCENARIO:-}" in
		first-post-fails) [[ "$status_calls" -gt 1 ]] ;;
		all-posts-fail) return_code=1; exit "$return_code" ;;
		*) exit 0 ;;
	esac
	exit $?
fi

printf 'unsupported gh invocation: %s\n' "$*" >&2
exit 1
GH_STUB
	chmod +x "${TEST_ROOT}/bin/gh"

	cat >"${TEST_ROOT}/bin/sleep" <<'SLEEP_STUB'
#!/usr/bin/env bash
exit 0
SLEEP_STUB
	chmod +x "${TEST_ROOT}/bin/sleep"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

run_job() {
	local scenario="$1"
	printf '0' >"$GH_STATUS_CALLS"
	: >"$GH_CALLS"
	GH_SCENARIO="$scenario" \
		PR_TITLE="fixture" \
		PR_BODY="" \
		PR_NUMBER=42 \
		PR_AUTHOR=maintainer \
		HEAD_SHA=fixture-head \
		PR_AUTHOR_ASSOCIATION=OWNER \
		REPO=owner/repo \
		REPO_OWNER=owner \
		GH_TOKEN=test-token \
		GITHUB_OUTPUT="${TEST_ROOT}/github-output" \
		PATH="${TEST_ROOT}/bin:${PATH}" \
		bash -e "${TEST_ROOT}/job.sh"
}

test_first_status_post_retries() {
	local status_calls=0
	if run_job first-post-fails >/dev/null 2>&1; then
		print_result "interactive fast path succeeds after transient status failure" 0
	else
		print_result "interactive fast path succeeds after transient status failure" 1 "job returned non-zero"
	fi
	status_calls=$(<"$GH_STATUS_CALLS")
	if [[ "$status_calls" -eq 3 ]]; then
		print_result "interactive fast path retries and publishes both status contexts" 0
	else
		print_result "interactive fast path retries and publishes both status contexts" 1 "expected 3 status calls, got $status_calls"
	fi
	if grep -qF 'context=maintainer-gate' "$GH_CALLS" &&
		grep -qF 'context=Maintainer Review & Assignee Gate' "$GH_CALLS"; then
		print_result "interactive fast path preserves stable and legacy contexts" 0
	else
		print_result "interactive fast path preserves stable and legacy contexts" 1 "expected both commit-status contexts"
	fi
	return 0
}

test_persistent_status_failure_fails_closed() {
	local status_calls=0
	if run_job all-posts-fail >/dev/null 2>&1; then
		print_result "interactive fast path fails when status publication remains unavailable" 1 "expected non-zero exit"
	else
		print_result "interactive fast path fails when status publication remains unavailable" 0
	fi
	status_calls=$(<"$GH_STATUS_CALLS")
	if [[ "$status_calls" -eq 2 ]]; then
		print_result "interactive fast path makes one bounded retry" 0
	else
		print_result "interactive fast path makes one bounded retry" 1 "expected 2 status calls, got $status_calls"
	fi
	return 0
}

main() {
	setup_test_env
	trap teardown_test_env EXIT
	test_first_status_post_retries
	test_persistent_status_failure_fails_closed
	printf '\nTests run: %d\nTests failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
