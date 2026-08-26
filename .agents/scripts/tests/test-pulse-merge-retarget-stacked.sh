#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for _retarget_stacked_children (t2412 / GH#20005):
#
# Regression for: merging a PR whose head branch is the base of open stacked
# PRs caused GitHub to auto-close the children. `_retarget_stacked_children`
# runs before every pulse-merge to retarget direct children to the default branch.
#
# Test cases:
#   1. 0 children → no `gh pr edit` call (no-op)
#   2. 1 child → retargeted to default branch
#   3. 2 children → both retargeted
#   4. Idempotent: child already targeting default branch → edit call still sent
#      (GitHub accepts it silently; idempotency is on the server side)
#   5. headRefName fetch failure → graceful no-op (non-fatal)
#   6. Audit log line carries (t2412) tag for every retarget
#
# Mock pattern follows test-pulse-merge-update-branch.sh: extract the helper
# from pulse-merge.sh via awk, eval it into the test shell, substitute `gh`
# with a per-test stub on PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# _retarget_stacked_children was moved to pulse-merge-process.sh (GH#21595, t3030).
# _process_single_ready_pr stays in pulse-merge.sh — the static check below
# (test_retarget_called_before_merge) reads it from $MERGE_SCRIPT.
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"
PROCESS_SCRIPT="${SCRIPT_DIR}/../pulse-merge-process.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
LAST_GH_ARGS_FILE=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%bPASS%b %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%bFAIL%b %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	: >"$LOGFILE"
	LAST_GH_ARGS_FILE="${TEST_ROOT}/gh-args.log"
	export LAST_GH_ARGS_FILE
	: >"$LAST_GH_ARGS_FILE"

	# Shim gh_pr_list (from shared-gh-wrappers.sh) → forward to the gh stub.
	# _retarget_stacked_children was refactored to use the wrapper post-GH#21595
	# so the test must surface the same args through the gh-args.log path.
	gh_pr_list() { gh pr list "$@"; }
	gh_pr_view() { gh pr view "$@"; }
	export -f gh_pr_list 2>/dev/null || true
	export -f gh_pr_view 2>/dev/null || true
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Install a configurable gh stub.
#
# Env vars consumed by the stub:
#   GH_HEAD_REF   — what `gh pr view <N> --json headRefName` returns (default: "feature/parent")
#   GH_CHILDREN   — newline-separated child PR numbers from `gh pr list --base ...`
#                   (default: empty → no children)
#   GH_DEFAULT_BR — what `gh repo view --json defaultBranchRef` returns (default: "main")
#
# The stub records every invocation to LAST_GH_ARGS_FILE (one line per call).
install_gh_stub() {
	local head_ref="${1:-feature/parent}"
	local children="${2:-}"
	local default_br="${3:-main}"

	# Write env vars to a file so the stub can read them (avoids export escaping).
	printf '%s' "$children" >"${TEST_ROOT}/gh-children.txt"
	printf '%s' "$head_ref" >"${TEST_ROOT}/gh-head-ref.txt"
	printf '%s' "$default_br" >"${TEST_ROOT}/gh-default-br.txt"

	cat >"${TEST_ROOT}/bin/gh" <<'STUB_EOF'
#!/usr/bin/env bash
# Log every call.
printf '%s\n' "$*" >>"${LAST_GH_ARGS_FILE}"

test_root="$(dirname "$(dirname "${BASH_SOURCE[0]}")")"
head_ref_file="${test_root}/gh-head-ref.txt"
children_file="${test_root}/gh-children.txt"
default_br_file="${test_root}/gh-default-br.txt"

head_ref=""
[[ -f "$head_ref_file" ]] && head_ref="$(cat "$head_ref_file")"
default_br="main"
[[ -f "$default_br_file" ]] && default_br="$(cat "$default_br_file")"

# `gh pr view <N> --json headRefName -q ...`
if [[ "${1:-}" == "pr" && "${2:-}" == "view" && "$*" == *"headRefName"* ]]; then
	printf '%s\n' "$head_ref"
	exit 0
fi

# `gh repo view --json defaultBranchRef -q ...`
if [[ "${1:-}" == "repo" && "${2:-}" == "view" && "$*" == *"defaultBranchRef"* ]]; then
	printf '%s\n' "$default_br"
	exit 0
fi

# `gh pr list --base <ref> --state open --json number -q ...`
if [[ "${1:-}" == "pr" && "${2:-}" == "list" && "$*" == *"--state open"* ]]; then
	[[ -f "$children_file" ]] && cat "$children_file"
	exit 0
fi

# `gh pr edit <N> --repo <slug> --base <branch>` → just succeed
if [[ "${1:-}" == "pr" && "${2:-}" == "edit" ]]; then
	exit 0
fi

exit 0
STUB_EOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

# Extract `_retarget_stacked_children` from pulse-merge-process.sh (post-GH#21595)
# and eval it.
define_helper_under_test() {
	local helper_src
	helper_src=$(awk '
		/^_retarget_stacked_children\(\) \{/,/^}$/ { print }
	' "$PROCESS_SCRIPT")
	if [[ -z "$helper_src" ]]; then
		printf 'ERROR: could not extract _retarget_stacked_children from %s\n' "$PROCESS_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$helper_src"
	return 0
}

# ---------------------------------------------------------------
# Test 1: 0 children → no gh pr edit calls
# ---------------------------------------------------------------
test_zero_children_noop() {
	: >"$LOGFILE"
	: >"$LAST_GH_ARGS_FILE"
	install_gh_stub "feature/parent" "" "main"

	_retarget_stacked_children "100" "marcusquinn/aidevops"

	if grep -q "pr edit" "$LAST_GH_ARGS_FILE"; then
		print_result "0 children → no-op (no gh pr edit)" 1 \
			"gh pr edit was called when there are no children. Args: $(cat "$LAST_GH_ARGS_FILE")"
		return 0
	fi

	print_result "0 children → no-op (no gh pr edit)" 0
	return 0
}

# ---------------------------------------------------------------
# Test 2: 1 child → retargeted
# ---------------------------------------------------------------
test_one_child_retargeted() {
	: >"$LOGFILE"
	: >"$LAST_GH_ARGS_FILE"
	install_gh_stub "feature/parent" "201" "main"

	_retarget_stacked_children "100" "marcusquinn/aidevops"

	if ! grep -q "pr edit 201" "$LAST_GH_ARGS_FILE"; then
		print_result "1 child → retargeted" 1 \
			"Expected 'pr edit 201' in gh args. Got: $(cat "$LAST_GH_ARGS_FILE")"
		return 0
	fi

	if ! grep -q -- "--base main" "$LAST_GH_ARGS_FILE"; then
		print_result "1 child → retargeted" 1 \
			"Expected '--base main' in gh args. Got: $(cat "$LAST_GH_ARGS_FILE")"
		return 0
	fi

	print_result "1 child → retargeted" 0
	return 0
}

# ---------------------------------------------------------------
# Test 3: 2 children → both retargeted
# ---------------------------------------------------------------
test_two_children_both_retargeted() {
	: >"$LOGFILE"
	: >"$LAST_GH_ARGS_FILE"
	install_gh_stub "feature/parent" "$(printf '301\n302')" "main"

	_retarget_stacked_children "100" "marcusquinn/aidevops"

	local edit_count
	edit_count=$(grep -c "pr edit" "$LAST_GH_ARGS_FILE" 2>/dev/null || true)
	if [[ "$edit_count" -lt 2 ]]; then
		print_result "2 children → both retargeted" 1 \
			"Expected 2 gh pr edit calls, got ${edit_count}. Args: $(cat "$LAST_GH_ARGS_FILE")"
		return 0
	fi

	if ! grep -q "pr edit 301" "$LAST_GH_ARGS_FILE"; then
		print_result "2 children → both retargeted" 1 \
			"Expected 'pr edit 301' in gh args. Got: $(cat "$LAST_GH_ARGS_FILE")"
		return 0
	fi

	if ! grep -q "pr edit 302" "$LAST_GH_ARGS_FILE"; then
		print_result "2 children → both retargeted" 1 \
			"Expected 'pr edit 302' in gh args. Got: $(cat "$LAST_GH_ARGS_FILE")"
		return 0
	fi

	print_result "2 children → both retargeted" 0
	return 0
}

# ---------------------------------------------------------------
# Test 4: headRefName fetch failure → graceful no-op
# ---------------------------------------------------------------
test_head_ref_failure_noop() {
	: >"$LOGFILE"
	: >"$LAST_GH_ARGS_FILE"
	# Empty head ref → simulates gh failure / empty response
	install_gh_stub "" "" "main"

	_retarget_stacked_children "100" "marcusquinn/aidevops"

	if grep -q "pr edit" "$LAST_GH_ARGS_FILE"; then
		print_result "headRefName failure → graceful no-op" 1 \
			"gh pr edit was called despite empty headRefName. Args: $(cat "$LAST_GH_ARGS_FILE")"
		return 0
	fi

	print_result "headRefName failure → graceful no-op" 0
	return 0
}

# ---------------------------------------------------------------
# Test 5: Audit log line carries (t2412) tag
# ---------------------------------------------------------------
test_audit_log_carries_t2412_tag() {
	: >"$LOGFILE"
	: >"$LAST_GH_ARGS_FILE"
	install_gh_stub "feature/parent" "401" "main"

	_retarget_stacked_children "100" "marcusquinn/aidevops"

	if ! grep -q '(t2412)' "$LOGFILE"; then
		print_result "audit log carries (t2412) tag" 1 \
			"Expected '(t2412)' in LOGFILE. Contents: $(cat "$LOGFILE")"
		return 0
	fi

	print_result "audit log carries (t2412) tag" 0
	return 0
}

# ---------------------------------------------------------------
# Test 6: provided headRefName context avoids duplicate gh pr view
# ---------------------------------------------------------------
test_provided_head_ref_context_skips_view() {
	: >"$LOGFILE"
	: >"$LAST_GH_ARGS_FILE"
	install_gh_stub "feature/from-view" "501" "main"

	_retarget_stacked_children "100" "marcusquinn/aidevops" "feature/from-context"

	if grep -q "pr view" "$LAST_GH_ARGS_FILE"; then
		print_result "provided headRefName context skips gh_pr_view" 1 \
			"Unexpected gh pr view call. Args: $(cat "$LAST_GH_ARGS_FILE")"
		return 0
	fi

	if ! grep -q -- "pr list --repo marcusquinn/aidevops --base feature/from-context" "$LAST_GH_ARGS_FILE"; then
		print_result "provided headRefName context skips gh_pr_view" 1 \
			"Expected child lookup to use context branch. Args: $(cat "$LAST_GH_ARGS_FILE")"
		return 0
	fi

	print_result "provided headRefName context skips gh_pr_view" 0
	return 0
}

# ---------------------------------------------------------------
# Test 7: Static check — pre-merge retarget stage runs before merge stage.
# ---------------------------------------------------------------
test_retarget_called_before_merge() {
	local func_body
	func_body=$(awk '
		/^_pmp_stage_pre_merge\(\) \{/,/^}$/ { print }
		/^_pmp_stage_admin_merge\(\) \{/,/^}$/ { print }
	' "$MERGE_SCRIPT")

	if [[ -z "$func_body" ]]; then
		print_result "retarget called before merge in _process_single_ready_pr" 1 \
			"Could not extract pre-merge and admin-merge stages from pulse-merge.sh"
		return 0
	fi

	if [[ "$func_body" != *"_retarget_stacked_children"* ]]; then
		print_result "retarget called before merge in _process_single_ready_pr" 1 \
			"_retarget_stacked_children not found in _pmp_stage_pre_merge"
		return 0
	fi

	# Retarget must appear before the gh pr merge call.
	local retarget_pos merge_pos
	retarget_pos=$(printf '%s\n' "$func_body" | grep -n '_retarget_stacked_children' | head -1 | cut -d: -f1)
	merge_pos=$(printf '%s\n' "$func_body" | grep -n 'gh pr merge' | head -1 | cut -d: -f1)

	if [[ -z "$retarget_pos" || -z "$merge_pos" ]]; then
		print_result "retarget called before merge in _process_single_ready_pr" 1 \
			"retarget_pos=${retarget_pos}, merge_pos=${merge_pos}"
		return 0
	fi

	if [[ "$retarget_pos" -ge "$merge_pos" ]]; then
		print_result "retarget called before merge in _process_single_ready_pr" 1 \
			"_retarget_stacked_children must appear before gh pr merge (pos: ${retarget_pos} vs ${merge_pos})"
		return 0
	fi

	print_result "retarget called before merge in _process_single_ready_pr" 0
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if ! define_helper_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_zero_children_noop
	test_one_child_retargeted
	test_two_children_both_retargeted
	test_head_ref_failure_noop
	test_audit_log_carries_t2412_tag
	test_provided_head_ref_context_skips_view
	test_retarget_called_before_merge

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
