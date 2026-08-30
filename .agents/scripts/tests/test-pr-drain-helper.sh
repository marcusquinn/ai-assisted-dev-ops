#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pr-drain-helper.sh — tests for maintainer PR drain classification.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER_SCRIPT="${SCRIPT_DIR}/../pr-drain-helper.sh"
TEST_ROOT=""
TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local passed="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
		return 0
	fi
	printf 'FAIL %s\n' "$name"
	[[ -n "$detail" ]] && printf '     %s\n' "$detail"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	cat >"${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1 $2" == "repo view" ]]; then
	printf 'owner/repo\n'
	exit 0
fi
if [[ "$1 $2" == "pr list" ]]; then
	printf '1\n2\n3\n4\n5\n'
	exit 0
fi
if [[ "$1 $2" == "pr view" ]]; then
	case "$3" in
	1)
		cat <<'JSON'
{"number":1,"title":"same repo clean","isCrossRepository":false,"isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":"APPROVED","labels":[],"statusCheckRollup":[]}
JSON
		;;
	2)
		cat <<'JSON'
{"number":2,"title":"fork pr","isCrossRepository":true,"isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":"APPROVED","labels":[],"statusCheckRollup":[]}
JSON
		;;
	3)
		cat <<'JSON'
{"number":3,"title":"dirty conflicts","isCrossRepository":false,"isDraft":false,"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","reviewDecision":"APPROVED","labels":[],"statusCheckRollup":[]}
JSON
		;;
	4)
		cat <<'JSON'
{"number":4,"title":"bot blocked","isCrossRepository":false,"isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":"APPROVED","labels":[],"statusCheckRollup":[]}
JSON
		;;
	5)
		cat <<'JSON'
{"number":5,"title":"baseline red safe","isCrossRepository":false,"isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","reviewDecision":"APPROVED","labels":[],"statusCheckRollup":[{"name":"baseline-ci","conclusion":"FAILURE"}]}
JSON
		;;
	*) exit 1 ;;
	esac
	exit 0
fi
printf 'unsupported gh call: %s\n' "$*" >&2
exit 1
STUB
	chmod +x "${TEST_ROOT}/bin/gh"
	cat >"${TEST_ROOT}/review-gate" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
pr="$2"
if [[ "$pr" == "4" ]]; then
	printf '{"status":"WAITING","state":"waiting","merge_gate":"blocked","exit_code":1}\n'
else
	printf '{"status":"PASS","state":"pass","merge_gate":"clear","exit_code":0}\n'
fi
STUB
	chmod +x "${TEST_ROOT}/review-gate"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export REVIEW_GATE_HELPER="${TEST_ROOT}/review-gate"
	export PR_DRAIN_BASELINE_CHECK_REGEX='^baseline-ci$'
	return 0
}

cleanup_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

category_for() {
	local output="$1"
	local number="$2"
	jq -r --argjson number "$number" '.prs[] | select(.number == $number) | .category' <<<"$output"
	return 0
}

run_tests() {
	local output category result human_output
	output=$("$HELPER_SCRIPT" owner/repo --json)

	category=$(category_for "$output" 1)
	result=1
	[[ "$category" == "mergeable" ]] && result=0
	print_result "same-repo clean PR is mergeable" "$result" "category=${category}"

	category=$(category_for "$output" 2)
	result=1
	[[ "$category" == "blocked" ]] && result=0
	print_result "fork PR is blocked" "$result" "category=${category}"

	category=$(category_for "$output" 3)
	result=1
	[[ "$category" == "conflict-only" ]] && result=0
	print_result "dirty PR is conflict-only" "$result" "category=${category}"

	category=$(category_for "$output" 4)
	result=1
	[[ "$category" == "blocked" ]] && result=0
	print_result "blocked bot gate is blocked" "$result" "category=${category}"

	category=$(category_for "$output" 5)
	result=1
	[[ "$category" == "mergeable" ]] && result=0
	print_result "baseline-red configured failure is mergeable" "$result" "category=${category}"

	human_output=$("$HELPER_SCRIPT" owner/repo)
	result=1
	if [[ "$human_output" == *"full-loop-helper.sh merge 1 owner/repo --admin --squash"* &&
		"$human_output" != *"gh pr merge"* ]]; then
		result=0
	fi
	print_result "human output routes merges through lifecycle helper" "$result" "$human_output"

	return 0
}

main() {
	trap cleanup_env EXIT
	setup_env
	run_tests
	printf 'Tests run: %s, failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
