#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-pulse-wrapper-complexity-scan.sh — Tests for deterministic complexity scan (GH#15285)
#
# Tests:
#   - _complexity_scan_tree_hash: returns non-empty hash for a git repo
#   - _complexity_scan_tree_changed: returns 1 (unchanged) on second call with same tree
#   - _complexity_scan_tree_changed: returns 0 (changed) after file modification
#   - _complexity_llm_sweep_due: returns 1 when interval not elapsed
#   - _complexity_llm_sweep_due: returns 1 when debt count decreased
#   - _complexity_llm_sweep_due: returns 0 when interval elapsed and debt stalled
#   - _complexity_llm_sweep_due: treats in-review debt as active work
#   - _complexity_llm_sweep_due: tolerates an unset sweep interval under set -u
#   - _complexity_recent_debt_closures: tolerates empty arithmetic inputs under set -u
#   - _complexity_run_llm_sweep: creates meta reviews outside measured function debt
#   - _complexity_scan_check_interval: returns 0 when no last-run file
#   - _complexity_scan_check_interval: returns 1 when interval not elapsed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCAN_SCRIPT="${SCRIPT_DIR}/../pulse-simplification-scan.sh"
ORCHESTRATION_SCRIPT="${SCRIPT_DIR}/../pulse-simplification-orchestration.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
ORIGINAL_HOME="${HOME}"
ORIGINAL_PATH="${PATH}"
GH_GRAPHQL_LOG=""
GH_ISSUE_LIST_LOG=""
GH_CREATE_ISSUE_LOG=""

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
	local temp_base="${AIDEVOPS_TEMP_DIR:-${ORIGINAL_HOME}/.aidevops/.agent-workspace/tmp}"
	mkdir -p "$temp_base"
	TEST_ROOT=$(mktemp -d "${temp_base%/}/pulse-complexity-test.XXXXXX")
	export HOME="${TEST_ROOT}/home"
	mkdir -p "${HOME}/.aidevops/logs"
	LOGFILE="${HOME}/.aidevops/logs/pulse.log"
	GH_GRAPHQL_LOG="${TEST_ROOT}/graphql.log"
	GH_ISSUE_LIST_LOG="${TEST_ROOT}/issue-list.log"
	GH_CREATE_ISSUE_LOG="${TEST_ROOT}/create-issue.log"
	COMPLEXITY_SCAN_LAST_RUN="${HOME}/.aidevops/logs/complexity-scan-last-run"
	COMPLEXITY_SCAN_INTERVAL=900
	COMPLEXITY_SCAN_TREE_HASH_FILE="${HOME}/.aidevops/logs/complexity-scan-tree-hash"
	COMPLEXITY_LLM_SWEEP_LAST_RUN="${HOME}/.aidevops/logs/complexity-llm-sweep-last-run"
	COMPLEXITY_LLM_SWEEP_INTERVAL=21600
	COMPLEXITY_DEBT_COUNT_FILE="${HOME}/.aidevops/logs/complexity-debt-count"
	PULSE_START_EPOCH=0
	: >"$GH_GRAPHQL_LOG"
	: >"$GH_ISSUE_LIST_LOG"
	: >"$GH_CREATE_ISSUE_LOG"
	export LOGFILE GH_GRAPHQL_LOG GH_ISSUE_LIST_LOG GH_CREATE_ISSUE_LOG PULSE_START_EPOCH
	# shellcheck source=/dev/null
	source "$SCAN_SCRIPT"
	return 0
}

teardown_test_env() {
	export HOME="$ORIGINAL_HOME"
	export PATH="$ORIGINAL_PATH"
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Disposable fixture repositories bypass the production canonical-repository shim.
_fixture_git() {
	/usr/bin/git "$@"
	return $?
}

gh_issue_list() {
	printf '%s\n' "$*" >>"$GH_ISSUE_LIST_LOG"
	gh issue list "$@"
	return $?
}

gh_create_issue() {
	printf '%s\n' "$*" >"$GH_CREATE_ISSUE_LOG"
	return 0
}

make_test_repo() {
	local repo_path="$1"
	mkdir -p "${repo_path}/.agents/scripts"
	_fixture_git -C "$repo_path" init -q --initial-branch=test-fixture 2>/dev/null
	printf '#!/usr/bin/env bash\n# test file\necho hello\n' >"${repo_path}/.agents/scripts/test.sh"
	_fixture_git -C "$repo_path" add . 2>/dev/null
	GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.invalid" \
		GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.invalid" \
		_fixture_git -C "$repo_path" commit -q -m "init" 2>/dev/null
	return 0
}

install_fake_gh_for_sweep() {
	local stub_dir="${TEST_ROOT}/stub-bin"
	mkdir -p "$stub_dir"
	cat >"${stub_dir}/gh" <<'EOF'
#!/usr/bin/env bash
cmd="$1"
subcmd="${2:-}"
args="$*"
case "$cmd" in
	api)
		if [[ "$subcmd" == "graphql" ]]; then
			printf '%s|%s|%s\n' \
				"${AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE:-}" \
				"${AIDEVOPS_GH_ROUTE_DECISION:-}" "$args" >>"${GH_GRAPHQL_LOG}"
			if [[ "$args" == *"search(query"* ]]; then
				printf '{"data":{"search":{"issueCount":%s},"rateLimit":{"cost":1}}}\n' \
					"${GH_RECENT_CLOSURES:-0}"
			else
				printf '{"data":{"repository":{"issues":{"totalCount":%s}},"rateLimit":{"cost":1}}}\n' \
					"${GH_OPEN_DEBT_COUNT:-0}"
			fi
			exit 0
		fi
		;;
	issue)
		if [[ "$subcmd" == "list" ]]; then
			printf '%s\n' "${GH_ISSUE_LIST_JSON:-[]}"
			exit 0
		fi
		;;
esac
exit 0
EOF
	chmod +x "${stub_dir}/gh"
	export PATH="${stub_dir}:${ORIGINAL_PATH}"
	return 0
}

test_graphql_reads_report_operation_owned_cost() {
	install_fake_gh_for_sweep
	: >"$GH_GRAPHQL_LOG"
	export GH_RECENT_CLOSURES=2 GH_OPEN_DEBT_COUNT=0
	local recent_closures=""
	recent_closures=$(_complexity_recent_debt_closures "100000" "test/repo" "3600")
	rm -f "$COMPLEXITY_LLM_SWEEP_LAST_RUN"
	_complexity_llm_sweep_due "100000" "test/repo" >/dev/null 2>&1 || true
	_complexity_scan_check_open_cap "test/repo" "10" "test" >/dev/null 2>&1 || true
	if [[ "$recent_closures" == "2" ]] \
		&& grep -qF '1|pulse-complexity-closures-exact-cost|api graphql' "$GH_GRAPHQL_LOG" \
		&& grep -qF '1|pulse-complexity-open-count-exact-cost|api graphql' "$GH_GRAPHQL_LOG" \
		&& grep -qF '1|pulse-complexity-cap-exact-cost|api graphql' "$GH_GRAPHQL_LOG" \
		&& grep -qF 'rateLimit { cost }' "$GH_GRAPHQL_LOG"; then
		print_result "complexity GraphQL reads report operation-owned cost" 0
	else
		print_result "complexity GraphQL reads report operation-owned cost" 1 \
			"value=${recent_closures}; calls=$(<"$GH_GRAPHQL_LOG")"
	fi
	unset GH_RECENT_CLOSURES GH_OPEN_DEBT_COUNT
	return 0
}

# =============================================================================
# Tests: _complexity_scan_tree_hash
# =============================================================================

test_tree_hash_returns_nonempty() {
	local repo_path="${TEST_ROOT}/repo-hash"
	make_test_repo "$repo_path"
	local hash
	hash=$(_complexity_scan_tree_hash "$repo_path")
	if [[ -n "$hash" ]]; then
		print_result "_complexity_scan_tree_hash: returns non-empty hash" 0
	else
		print_result "_complexity_scan_tree_hash: returns non-empty hash" 1 "hash was empty"
	fi
	return 0
}

test_tree_hash_stable() {
	local repo_path="${TEST_ROOT}/repo-stable"
	make_test_repo "$repo_path"
	local hash1 hash2
	hash1=$(_complexity_scan_tree_hash "$repo_path")
	hash2=$(_complexity_scan_tree_hash "$repo_path")
	if [[ "$hash1" == "$hash2" && -n "$hash1" ]]; then
		print_result "_complexity_scan_tree_hash: stable across calls" 0
	else
		print_result "_complexity_scan_tree_hash: stable across calls" 1 "hash1='$hash1' hash2='$hash2'"
	fi
	return 0
}

# =============================================================================
# Tests: _complexity_scan_tree_changed
# =============================================================================

test_tree_changed_first_call_returns_changed() {
	local repo_path="${TEST_ROOT}/repo-first"
	make_test_repo "$repo_path"
	# No cache file — should return 0 (changed)
	if _complexity_scan_tree_changed "$repo_path"; then
		print_result "_complexity_scan_tree_changed: first call returns changed (0)" 0
	else
		print_result "_complexity_scan_tree_changed: first call returns changed (0)" 1 "expected 0 (changed)"
	fi
	return 0
}

test_tree_changed_second_call_returns_unchanged() {
	local repo_path="${TEST_ROOT}/repo-second"
	make_test_repo "$repo_path"
	# First call populates cache
	_complexity_scan_tree_changed "$repo_path" >/dev/null 2>&1 || true
	# Second call with same tree — should return 1 (unchanged)
	if ! _complexity_scan_tree_changed "$repo_path"; then
		print_result "_complexity_scan_tree_changed: second call returns unchanged (1)" 0
	else
		print_result "_complexity_scan_tree_changed: second call returns unchanged (1)" 1 "expected 1 (unchanged)"
	fi
	return 0
}

test_tree_changed_after_commit_returns_changed() {
	local repo_path="${TEST_ROOT}/repo-commit"
	make_test_repo "$repo_path"
	# Populate cache
	_complexity_scan_tree_changed "$repo_path" >/dev/null 2>&1 || true
	# Modify and commit a file
	printf '#!/usr/bin/env bash\n# modified\necho world\n' >"${repo_path}/.agents/scripts/test.sh"
	_fixture_git -C "$repo_path" add . 2>/dev/null
	GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.invalid" \
		GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.invalid" \
		_fixture_git -C "$repo_path" commit -q -m "modify" 2>/dev/null
	# Should return 0 (changed)
	if _complexity_scan_tree_changed "$repo_path"; then
		print_result "_complexity_scan_tree_changed: returns changed after commit" 0
	else
		print_result "_complexity_scan_tree_changed: returns changed after commit" 1 "expected 0 (changed)"
	fi
	return 0
}

# =============================================================================
# Tests: _complexity_llm_sweep_due
# =============================================================================

test_llm_sweep_not_due_when_interval_not_elapsed() {
	# Set last-run to now — interval not elapsed
	local now_epoch
	now_epoch=$(date +%s)
	printf '%s\n' "$now_epoch" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
	# Should return 1 (not due)
	if ! _complexity_llm_sweep_due "$now_epoch" "test/repo" 2>/dev/null; then
		print_result "_complexity_llm_sweep_due: not due when interval not elapsed" 0
	else
		print_result "_complexity_llm_sweep_due: not due when interval not elapsed" 1 "expected 1 (not due)"
	fi
	return 0
}

test_llm_sweep_check_interval_guard() {
	# Verify interval guard works: set last-run to 1h ago, interval is 6h
	local now_epoch
	now_epoch=$(date +%s)
	local one_hour_ago=$((now_epoch - 3600))
	printf '%s\n' "$one_hour_ago" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
	# Should return 1 (not due — only 1h elapsed of 6h interval)
	if ! _complexity_llm_sweep_due "$now_epoch" "test/repo" 2>/dev/null; then
		print_result "_complexity_llm_sweep_due: interval guard blocks early sweep" 0
	else
		print_result "_complexity_llm_sweep_due: interval guard blocks early sweep" 1 "expected 1 (not due)"
	fi
	return 0
}

test_llm_sweep_skips_when_recent_closures_exist() {
	install_fake_gh_for_sweep
	local now_epoch
	now_epoch=$(date +%s)
	local old_epoch=$((now_epoch - ${COMPLEXITY_LLM_SWEEP_INTERVAL:-0} - 60))
	printf '%s\n' "$old_epoch" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
	printf '10\n' >"$COMPLEXITY_DEBT_COUNT_FILE"
	export GH_OPEN_DEBT_COUNT=10
	export GH_RECENT_CLOSURES=2
	export GH_ISSUE_LIST_JSON='[]'

	if ! _complexity_llm_sweep_due "$now_epoch" "test/repo" 2>/dev/null; then
		print_result "_complexity_llm_sweep_due: active throughput suppresses stall sweep" 0
	else
		print_result "_complexity_llm_sweep_due: active throughput suppresses stall sweep" 1 "expected 1 (not due)"
	fi
	unset GH_OPEN_DEBT_COUNT GH_RECENT_CLOSURES GH_ISSUE_LIST_JSON
	return 0
}

test_llm_sweep_due_when_zero_recent_closures() {
	install_fake_gh_for_sweep
	local now_epoch
	now_epoch=$(date +%s)
	local old_epoch=$((now_epoch - ${COMPLEXITY_LLM_SWEEP_INTERVAL:-0} - 60))
	printf '%s\n' "$old_epoch" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
	printf '10\n' >"$COMPLEXITY_DEBT_COUNT_FILE"
	export GH_OPEN_DEBT_COUNT=10
	export GH_RECENT_CLOSURES=0
	export GH_ISSUE_LIST_JSON='[]'

	if _complexity_llm_sweep_due "$now_epoch" "test/repo" 2>/dev/null; then
		print_result "_complexity_llm_sweep_due: zero recent closures allows stall sweep" 0
	else
		print_result "_complexity_llm_sweep_due: zero recent closures allows stall sweep" 1 "expected 0 (due)"
	fi
	unset GH_OPEN_DEBT_COUNT GH_RECENT_CLOSURES GH_ISSUE_LIST_JSON
	return 0
}

test_llm_sweep_skips_when_all_debt_is_in_review() {
	install_fake_gh_for_sweep
	local now_epoch
	now_epoch=$(date +%s)
	local old_epoch=$((now_epoch - ${COMPLEXITY_LLM_SWEEP_INTERVAL:-0} - 60))
	printf '%s\n' "$old_epoch" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
	printf '1\n' >"$COMPLEXITY_DEBT_COUNT_FILE"
	export GH_OPEN_DEBT_COUNT=1
	export GH_RECENT_CLOSURES=0
	export GH_ISSUE_LIST_JSON='[{"number":42,"title":"simplification: active debt","labels":[{"name":"function-complexity-debt"},{"name":"status:in-review"}]}]'

	if ! _complexity_llm_sweep_due "$now_epoch" "test/repo" 2>/dev/null; then
		print_result "_complexity_llm_sweep_due: in-review debt suppresses stall sweep" 0
	else
		print_result "_complexity_llm_sweep_due: in-review debt suppresses stall sweep" 1 "expected 1 (not due)"
	fi
	unset GH_OPEN_DEBT_COUNT GH_RECENT_CLOSURES GH_ISSUE_LIST_JSON
	return 0
}

test_llm_sweep_meta_review_is_not_measured_debt() {
	install_fake_gh_for_sweep
	: >"$GH_ISSUE_LIST_LOG"
	: >"$GH_CREATE_ISSUE_LOG"
	export GH_ISSUE_LIST_JSON='[]'
	export _COMPLEXITY_SCAN_SKIP_REVIEW_GATE=true

	_complexity_run_llm_sweep "test/repo" "100000" "maintainer"

	local list_args create_args
	list_args=$(<"$GH_ISSUE_LIST_LOG")
	create_args=$(<"$GH_CREATE_ISSUE_LOG")
	if [[ "$list_args" == *'in:title "simplification debt stalled" OR in:title "LLM complexity sweep"'* ]] &&
		[[ "$list_args" != *'--label function-complexity-debt'* ]] &&
		[[ "$create_args" == *'--label quality-debt'* ]] &&
		[[ "$create_args" != *'--label function-complexity-debt'* ]] &&
		[[ "$create_args" == *'local_capacity_gate'* ]] &&
		[[ "$create_args" == *'aidevops:generator=complexity-stall-sweep stall_hours=6'* ]]; then
		print_result "_complexity_run_llm_sweep: meta review stays outside measured debt" 0
	else
		print_result "_complexity_run_llm_sweep: meta review stays outside measured debt" 1 \
			"list=${list_args}; create=${create_args}"
	fi
	unset GH_ISSUE_LIST_JSON _COMPLEXITY_SCAN_SKIP_REVIEW_GATE
	return 0
}

test_both_stall_issue_creators_use_meta_label() {
	local old_inline_label="--label \"function-complexity-debt\" \$sweep_review_label --label \"tier:thinking\" --label \"worker-ready\""
	local old_helper_label='--label "function-complexity-debt" --label "auto-dispatch" --label "tier:thinking" --label "worker-ready"'
	local new_helper_label='--label "quality-debt" --label "auto-dispatch" --label "tier:thinking" --label "worker-ready"'

	if ! grep -qF -- "$old_inline_label" "$SCAN_SCRIPT" \
		&& ! grep -qF -- "$old_helper_label" "$ORCHESTRATION_SCRIPT" \
		&& grep -qF -- "$new_helper_label" "$ORCHESTRATION_SCRIPT"; then
		print_result "complexity stall creators label reviews as meta quality debt" 0
	else
		print_result "complexity stall creators label reviews as meta quality debt" 1
	fi
	return 0
}

test_recent_closures_defaults_empty_arithmetic_inputs() {
	install_fake_gh_for_sweep
	export GH_RECENT_CLOSURES=0
	local recent_closures
	recent_closures=$(_complexity_recent_debt_closures "" "test/repo" "")
	if [[ "$recent_closures" == "0" ]]; then
		print_result "_complexity_recent_debt_closures: defaults empty arithmetic inputs" 0
	else
		print_result "_complexity_recent_debt_closures: defaults empty arithmetic inputs" 1 "expected 0, got '$recent_closures'"
	fi
	unset GH_RECENT_CLOSURES
	return 0
}

test_llm_sweep_unset_interval_does_not_trip_strict_mode() {
	install_fake_gh_for_sweep
	local previous_interval="${COMPLEXITY_LLM_SWEEP_INTERVAL:-}"
	local now_epoch
	now_epoch=$(date +%s)
	printf '%s\n' "$now_epoch" >"$COMPLEXITY_LLM_SWEEP_LAST_RUN"
	export GH_OPEN_DEBT_COUNT=10
	export GH_RECENT_CLOSURES=1
	export GH_ISSUE_LIST_JSON='[]'
	unset COMPLEXITY_LLM_SWEEP_INTERVAL

	if _complexity_llm_sweep_due "$now_epoch" "test/repo" >/dev/null 2>&1 || [[ $? -eq 1 ]]; then
		print_result "_complexity_llm_sweep_due: unset interval is strict-mode safe" 0
	else
		print_result "_complexity_llm_sweep_due: unset interval is strict-mode safe" 1 "function errored with interval unset"
	fi

	COMPLEXITY_LLM_SWEEP_INTERVAL="$previous_interval"
	unset GH_OPEN_DEBT_COUNT GH_RECENT_CLOSURES GH_ISSUE_LIST_JSON
	return 0
}

# =============================================================================
# Tests: _complexity_scan_check_interval
# =============================================================================

test_check_interval_due_when_no_last_run() {
	rm -f "$COMPLEXITY_SCAN_LAST_RUN"
	local now_epoch
	now_epoch=$(date +%s)
	if _complexity_scan_check_interval "$now_epoch"; then
		print_result "_complexity_scan_check_interval: due when no last-run file" 0
	else
		print_result "_complexity_scan_check_interval: due when no last-run file" 1 "expected 0 (due)"
	fi
	return 0
}

test_check_interval_not_due_when_recent() {
	local now_epoch
	now_epoch=$(date +%s)
	printf '%s\n' "$now_epoch" >"$COMPLEXITY_SCAN_LAST_RUN"
	if ! _complexity_scan_check_interval "$now_epoch"; then
		print_result "_complexity_scan_check_interval: not due when just ran" 0
	else
		print_result "_complexity_scan_check_interval: not due when just ran" 1 "expected 1 (not due)"
	fi
	return 0
}

test_check_interval_due_when_elapsed() {
	local now_epoch
	now_epoch=$(date +%s)
	# Set last-run to 2x the interval ago
	local old_epoch=$((now_epoch - COMPLEXITY_SCAN_INTERVAL * 2))
	printf '%s\n' "$old_epoch" >"$COMPLEXITY_SCAN_LAST_RUN"
	if _complexity_scan_check_interval "$now_epoch"; then
		print_result "_complexity_scan_check_interval: due when interval elapsed" 0
	else
		print_result "_complexity_scan_check_interval: due when interval elapsed" 1 "expected 0 (due)"
	fi
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	setup_test_env

	echo "=== Complexity scan deterministic tests (GH#15285) ==="
	echo ""

	test_tree_hash_returns_nonempty
	test_tree_hash_stable
	test_tree_changed_first_call_returns_changed
	test_tree_changed_second_call_returns_unchanged
	test_tree_changed_after_commit_returns_changed
	test_graphql_reads_report_operation_owned_cost
	test_llm_sweep_not_due_when_interval_not_elapsed
	test_llm_sweep_check_interval_guard
	test_llm_sweep_skips_when_recent_closures_exist
	test_llm_sweep_due_when_zero_recent_closures
	test_llm_sweep_skips_when_all_debt_is_in_review
	test_llm_sweep_meta_review_is_not_measured_debt
	test_both_stall_issue_creators_use_meta_label
	test_recent_closures_defaults_empty_arithmetic_inputs
	test_llm_sweep_unset_interval_does_not_trip_strict_mode
	test_check_interval_due_when_no_last_run
	test_check_interval_not_due_when_recent
	test_check_interval_due_when_elapsed

	echo ""
	echo "Results: ${TESTS_RUN} run, $((TESTS_RUN - TESTS_FAILED)) passed, ${TESTS_FAILED} failed"

	teardown_test_env

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
