#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#27611: collaborator permission API failures must
# not be coerced into external-author remediation and permanent ever-NMR state.

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
	TEST_ROOT="$(mktemp -d -t maintainer-gate-origin-worker.XXXXXX)"
	mkdir -p "${TEST_ROOT}/bin"
	export GH_CALLS="${TEST_ROOT}/gh-calls.log"
	: >"$GH_CALLS"

	python3 - "$WORKFLOW_FILE" "${TEST_ROOT}/job.sh" <<'PY'
import pathlib
import sys
import yaml

workflow = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
steps = workflow["jobs"]["protect-origin-worker-label"]["steps"]
run = next(step["run"] for step in steps if "run" in step)
pathlib.Path(sys.argv[2]).write_text(run)
PY

	cat >"${TEST_ROOT}/bin/gh" <<'GH_STUB'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$GH_CALLS"
if [[ "${1:-}" == "api" && "${2:-}" == */collaborators/*/permission ]]; then
	case "${GH_SCENARIO:-}" in
		api-failure) exit 1 ;;
		trusted) printf 'write\n'; exit 0 ;;
		external|unknown-association) printf 'none\n'; exit 0 ;;
	esac
fi
if [[ "${1:-}" == "issue" && "${2:-}" == "edit" ]]; then
	exit 0
fi
if [[ "${1:-}" == "api" && "${2:-}" == */comments ]]; then
	printf '1\n'
	exit 0
fi
printf 'unsupported gh invocation: %s\n' "$*" >&2
exit 1
GH_STUB
	chmod +x "${TEST_ROOT}/bin/gh"
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
	local author_association="$2"
	local action="${3:-labeled}"
	local issue_author="${4:-runner}"
	GH_SCENARIO="$scenario" \
		ISSUE_NUMBER=42 \
		ACTION="$action" \
		ACTOR=runner \
		REPO=owner/repo \
		REPO_OWNER=owner \
		ISSUE_AUTHOR="$issue_author" \
		ISSUE_AUTHOR_ASSOC="$author_association" \
		GH_TOKEN=test-token \
		PATH="${TEST_ROOT}/bin:${PATH}" \
		bash -e "${TEST_ROOT}/job.sh"
}

assert_no_label_mutation() {
	local test_name="$1"
	if grep -q '^issue edit ' "$GH_CALLS"; then
		print_result "$test_name" 1 "unexpected issue edit: $(grep '^issue edit ' "$GH_CALLS")"
		return 0
	fi
	print_result "$test_name" 0
	return 0
}

test_api_failure_is_non_mutating() {
	: >"$GH_CALLS"
	if run_job api-failure COLLABORATOR >/dev/null 2>&1; then
		print_result "permission API failure fails the protection job" 1 "expected non-zero exit"
	else
		print_result "permission API failure fails the protection job" 0
	fi
	assert_no_label_mutation "permission API failure leaves labels unchanged"
	return 0
}

test_trusted_collaborator_is_allowed() {
	: >"$GH_CALLS"
	if run_job trusted COLLABORATOR >/dev/null 2>&1; then
		print_result "write collaborator is allowed" 0
	else
		print_result "write collaborator is allowed" 1 "job returned non-zero"
	fi
	assert_no_label_mutation "write collaborator does not trigger remediation"
	return 0
}

test_confirmed_external_is_remediated() {
	: >"$GH_CALLS"
	if run_job external NONE >/dev/null 2>&1; then
		print_result "confirmed external actor completes remediation" 0
	else
		print_result "confirmed external actor completes remediation" 1 "job returned non-zero"
	fi
	if grep -q '^issue edit .*--add-label needs-maintainer-review' "$GH_CALLS"; then
		print_result "confirmed external actor receives NMR gate" 0
	else
		print_result "confirmed external actor receives NMR gate" 1 "expected NMR issue edit"
	fi
	return 0
}

test_read_only_collaborator_author_is_remediated() {
	: >"$GH_CALLS"
	if run_job external COLLABORATOR >/dev/null 2>&1; then
		print_result "read-only collaborator author completes external remediation" 0
	else
		print_result "read-only collaborator author completes external remediation" 1 "job returned non-zero"
	fi
	if grep -q '^issue edit .*--add-label needs-maintainer-review' "$GH_CALLS"; then
		print_result "read-only collaborator author receives NMR gate" 0
	else
		print_result "read-only collaborator author receives NMR gate" 1 "expected NMR issue edit"
	fi
	return 0
}

test_unknown_author_association_is_non_mutating() {
	: >"$GH_CALLS"
	if run_job unknown-association API_ERROR >/dev/null 2>&1; then
		print_result "unknown author association fails the protection job" 1 "expected non-zero exit"
	else
		print_result "unknown author association fails the protection job" 0
	fi
	assert_no_label_mutation "unknown author association leaves labels unchanged"
	return 0
}

test_owner_authored_unlabel_is_restored_from_webhook() {
	: >"$GH_CALLS"
	if run_job external OWNER unlabeled owner >/dev/null 2>&1; then
		print_result "owner-authored origin label removal completes restoration" 0
	else
		print_result "owner-authored origin label removal completes restoration" 1 "job returned non-zero"
	fi
	if grep -q '^issue edit .*--add-label origin:worker' "$GH_CALLS"; then
		print_result "owner-authored origin label is restored" 0
	else
		print_result "owner-authored origin label is restored" 1 "expected origin:worker issue edit"
	fi
	if grep -q '^api .*issues/42 ' "$GH_CALLS"; then
		print_result "owner-authored restoration avoids redundant issue lookup" 1 "unexpected issue metadata API call"
	else
		print_result "owner-authored restoration avoids redundant issue lookup" 0
	fi
	return 0
}

main() {
	setup_test_env
	trap teardown_test_env EXIT
	test_api_failure_is_non_mutating
	test_trusted_collaborator_is_allowed
	test_confirmed_external_is_remediated
	test_read_only_collaborator_author_is_remediated
	test_unknown_author_association_is_non_mutating
	test_owner_authored_unlabel_is_restored_from_webhook
	printf '\nTests run: %d\nTests failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
