#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for t2104 / GH#19040 and t3514: pulse-merge-process.sh
# _pr_required_checks_pass must delegate to REST-backed required-context
# verification rather than `gh pr view --json statusCheckRollup` (all checks
# attached to the PR head), so that:
#
#   1. Post-merge advisory failures (e.g. "Sync Issue Hygiene on PR Merge"
#      which is expected to fail under the t2029 protected-main limitation)
#      do NOT block the merge pass.
#   2. Non-required advisory checks are ignored.
#   3. Required failures still correctly block the merge.
#   4. Pending/queued/expected required checks are non-terminal for CI repair
#      routing; skipped required checks still allow the merge.
#   5. API errors fail-closed (a bubbling gh failure must never auto-merge).
#   6. Merge-read gh calls are routed through the timeout wrapper.
#
# Regression root cause: PR #19023 (GH#18787) had all required checks green
# but statusCheckRollup contained a FAILURE entry from the post-merge
# "Sync Issue Hygiene on PR Merge" workflow — the deterministic merge pass
# skipped the PR and required manual maintainer intervention.
#
# Strategy: extract _pr_required_checks_pass plus its required-context helpers
# from pulse-merge-process.sh, eval them, and exercise against a mock `gh` stub
# keyed on $MOCK_GH_MODE.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# _pr_required_checks_pass was moved to pulse-merge-process.sh
# (GH#21595, t3030).
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge-process.sh"
REQUIRED_CHECKS_SCRIPT="${SCRIPT_DIR}/../pulse-merge-required-checks.sh"

readonly TEST_RED=$'\033[0;31m'
readonly TEST_GREEN=$'\033[0;32m'
readonly TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$test_name"
		return 0
	fi

	printf '%sFAIL%s %s\n' "$TEST_RED" "$TEST_RESET" "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

# Prepare a mock `gh` on PATH that records every invocation and returns canned
# REST branch-protection/check-run responses keyed on $MOCK_GH_MODE:
#   all_pass        — required check-runs conclude success
#   one_fail        — one required check-run concludes failure
#   one_cancel      — one required check-run concludes cancelled
#   action_required — one required check-run requires action
#   empty_required  — branch protection has no required contexts
#   pending_only    — required check-run has no conclusion yet
#   queued_only     — required check-run is queued with no conclusion yet
#   expected_only   — required status context is expected/not reported yet
#   skipping_only   — required check-run concludes skipped
#   empty_required_pending_fallback — branch/ruleset APIs expose no contexts,
#      but `gh pr checks --required` reports a pending required check
#   empty_required_stale_maintainer_gate_fallback — branch/ruleset APIs expose
#      no contexts, `gh pr checks --required` has a stale pending maintainer-gate
#      status, and the current head's maintainer-gate CheckRun is successful
#   pr_checks_empty_failure — PR-level required checks exits non-zero with no JSON
#   ruleset_review_malformed_optional — ruleset detail has unexpected shapes
#   ruleset_review_latest_changes_requested — latest review revokes approval
#   ruleset_review_paginated_approved — later REST page restores approval
#   ruleset_review_author_only — only the PR author approved
#   ruleset_review_malformed_response — REST reviews payload is not page arrays
#   ruleset_review_malformed_element — a REST reviews page contains a non-object
#   ruleset_review_fetch_error — REST reviews endpoint fails
#   error           — branch-protection API exits non-zero
setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export GH_CALL_LOG="${TEST_ROOT}/gh-calls.log"
	export MOCK_GH_MODE="all_pass"
	: >"$LOGFILE"
	: >"$GH_CALL_LOG"

	cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
# Mock gh for test-pulse-merge-required-checks-filter.sh
# Records every top-level invocation and returns canned REST responses for
# branch-protection required-context verification.
printf '%s\n' "$*" >>"${GH_CALL_LOG}"

apply_jq() {
	local json="$1"
	shift
	jq_expr=""
	prev=""
	for arg in "$@"; do
		if [[ "$prev" == "--jq" ]]; then
			jq_expr="$arg"
			break
		fi
		prev="$arg"
	done
	if [[ -n "$jq_expr" ]]; then
		printf '%s' "$json" | jq -r "$jq_expr"
		return 0
	fi
	printf '%s\n' "$json"
	return 0
}

if [[ "$1" == "api" && "$2" == repos/* && "$*" == *"/rulesets/"* ]]; then
	branch_identity='"id":101,"target":"branch","enforcement":"active"'
	case "${MOCK_GH_MODE:-all_pass}" in
	ruleset_review_only_missing | ruleset_review_only_approved | ruleset_review_latest_changes_requested | ruleset_review_paginated_approved | ruleset_review_author_only | ruleset_review_malformed_response | ruleset_review_malformed_element | ruleset_review_fetch_error)
		apply_jq "{${branch_identity},\"conditions\":{\"ref_name\":{\"include\":[\"refs/heads/main\"]}},\"rules\":[{\"type\":\"pull_request\",\"parameters\":{\"required_approving_review_count\":1}}]}" "$@"
		;;
	ruleset_mixed_review_status)
		apply_jq "{${branch_identity},\"conditions\":{\"ref_name\":{\"include\":[\"refs/heads/main\"]}},\"rules\":[{\"type\":\"pull_request\",\"parameters\":{\"required_approving_review_count\":1}},{\"type\":\"required_status_checks\",\"parameters\":{\"required_status_checks\":[{\"context\":\"required-a\"}]}}]}" "$@"
		;;
	ruleset_review_zero)
		apply_jq "{${branch_identity},\"conditions\":{\"ref_name\":{\"include\":[\"refs/heads/main\"]}},\"rules\":[{\"type\":\"pull_request\",\"parameters\":{\"required_approving_review_count\":0}}]}" "$@"
		;;
	ruleset_review_malformed_optional)
		apply_jq "{${branch_identity},\"conditions\":{\"ref_name\":\"unexpected\"},\"rules\":[{\"type\":\"pull_request\",\"parameters\":\"unexpected\"}]}" "$@"
		;;
	*)
		apply_jq "{${branch_identity},\"conditions\":{\"ref_name\":{\"include\":[]}},\"rules\":[]}" "$@"
		;;
	esac
	exit 0
fi

if [[ "$1" == "api" && "$2" == repos/* && "$*" == *"/rulesets"* ]]; then
	case "${MOCK_GH_MODE:-all_pass}" in
	ruleset_review_only_missing | ruleset_review_only_approved | ruleset_mixed_review_status | ruleset_review_zero | ruleset_review_malformed_optional | ruleset_review_latest_changes_requested | ruleset_review_paginated_approved | ruleset_review_author_only | ruleset_review_malformed_response | ruleset_review_malformed_element | ruleset_review_fetch_error)
		apply_jq '[{"id":101,"enforcement":"active","target":"branch"}]' "$@"
		;;
	*)
		apply_jq '[]' "$@"
		;;
	esac
	exit 0
fi

if [[ "$1" == "api" && "$2" == repos/*/pulls/*/reviews* ]]; then
	case "${MOCK_GH_MODE:-all_pass}" in
	ruleset_review_only_approved | ruleset_mixed_review_status)
		printf '%s\n' '[[{"id":1,"state":"APPROVED","submitted_at":"2026-06-01T00:00:00Z","user":{"login":"reviewer"}}]]'
		;;
	ruleset_review_latest_changes_requested)
		printf '%s\n' '[[{"id":1,"state":"APPROVED","submitted_at":"2026-06-01T00:00:00Z","user":{"login":"reviewer"}}],[{"id":2,"state":"CHANGES_REQUESTED","submitted_at":"2026-06-02T00:00:00Z","user":{"login":"reviewer"}}]]'
		;;
	ruleset_review_paginated_approved)
		printf '%s\n' '[[{"id":1,"state":"CHANGES_REQUESTED","submitted_at":"2026-06-01T00:00:00Z","user":{"login":"reviewer"}}],[{"id":2,"state":"APPROVED","submitted_at":"2026-06-02T00:00:00Z","user":{"login":"reviewer"}}]]'
		;;
	ruleset_review_author_only)
		printf '%s\n' '[[{"id":1,"state":"APPROVED","submitted_at":"2026-06-01T00:00:00Z","user":{"login":"author"}}]]'
		;;
	ruleset_review_malformed_response)
		printf '%s\n' '{"reviews":[]}'
		;;
	ruleset_review_malformed_element)
		printf '%s\n' '[[{"id":1,"state":"APPROVED","submitted_at":"2026-06-01T00:00:00Z","user":{"login":"reviewer"}},null]]'
		;;
	ruleset_review_fetch_error)
		printf 'gh: mock reviews endpoint error\n' >&2
		exit 1
		;;
	*)
		printf '%s\n' '[[]]'
		;;
	esac
	exit 0
fi

if [[ "$1" == "api" && "$2" == repos/* && "$*" != *"/branches/"* \
	&& "$*" != *"/commits/"* && "$*" != *"/rulesets"* ]]; then
	apply_jq '{"default_branch":"main"}' "$@"
	exit 0
fi

if [[ "$1" == "api" && "$*" == *"protection/required_status_checks"* ]]; then
	case "${MOCK_GH_MODE:-all_pass}" in
	empty_required | empty_required_pending_fallback | empty_required_stale_maintainer_gate_fallback | empty_required_current_pending_maintainer_gate_fallback)
		apply_jq '{"contexts":[]}' "$@"
		exit 0
		;;
	error)
		printf 'gh: mock branch-protection error\n' >&2
		exit 1
		;;
	*)
		apply_jq '{"contexts":["required-a","required-b"]}' "$@"
		exit 0
		;;
	esac
fi

if [[ "$1" == "pr" && "$2" == "view" && "$*" == *"headRefOid"* ]]; then
	apply_jq '{"headRefOid":"abc123def456789000000000000000000000abcd"}' "$@"
	exit 0
fi

if [[ "$1" == "pr" && "$2" == "checks" && "$*" == *"--required"* ]]; then
	case "${MOCK_GH_MODE:-all_pass}" in
	empty_required_pending_fallback)
		apply_jq '[
			{"name":"ShellCheck (macos-latest)","state":"PENDING","bucket":"pending"},
			{"name":"maintainer-gate","state":"SUCCESS","bucket":"pass"}
		]' "$@"
		exit 2
		;;
	empty_required_stale_maintainer_gate_fallback | empty_required_current_pending_maintainer_gate_fallback)
		apply_jq '[
			{"name":"Complexity Analysis","state":"SUCCESS","bucket":"pass"},
			{"name":"maintainer-gate","state":"PENDING","bucket":"pending"}
		]' "$@"
		exit 1
		;;
	pr_checks_empty_failure)
		exit 1
		;;
	*)
		apply_jq '[]' "$@"
		exit 0
		;;
	esac
fi

if [[ "$1" == "api" && "$*" == *"/check-runs"* ]]; then
	local_json=""
	case "${MOCK_GH_MODE:-all_pass}" in
	all_pass | empty_required)
		local_json='{"check_runs":[
			{"name":"required-a","conclusion":"success","status":"completed"},
			{"name":"required-b","conclusion":"success","status":"completed"},
			{"name":"Sync Issue Hygiene on PR Merge","conclusion":"failure","status":"completed"}
		]}'
		;;
	empty_required_stale_maintainer_gate_fallback | empty_required_current_pending_maintainer_gate_fallback)
		local_json='{"check_runs":[
			{"name":"gate / Maintainer Review & Assignee Gate","conclusion":"success","status":"completed"},
			{"name":"Complexity Analysis","conclusion":"success","status":"completed"}
		]}'
		;;
	one_fail)
		local_json='{"check_runs":[
			{"name":"required-a","conclusion":"success","status":"completed"},
			{"name":"required-b","conclusion":"failure","status":"completed"}
		]}'
		;;
	one_cancel)
		local_json='{"check_runs":[
			{"name":"required-a","conclusion":"success","status":"completed"},
			{"name":"required-b","conclusion":"cancelled","status":"completed"}
		]}'
		;;
	action_required)
		local_json='{"check_runs":[
			{"name":"required-a","conclusion":"success","status":"completed"},
			{"name":"required-b","conclusion":"action_required","status":"completed"}
		]}'
		;;
	pending_only)
		local_json='{"check_runs":[
			{"name":"required-a","conclusion":null,"status":"in_progress"},
			{"name":"required-b","conclusion":"success","status":"completed"}
		]}'
		;;
	queued_only)
		local_json='{"check_runs":[
			{"name":"required-a","conclusion":null,"status":"queued"},
			{"name":"required-b","conclusion":"success","status":"completed"}
		]}'
		;;
	expected_only)
		local_json='{"check_runs":[
			{"name":"required-b","conclusion":"success","status":"completed"}
		]}'
		;;
	skipping_only)
		local_json='{"check_runs":[
			{"name":"required-a","conclusion":"skipped","status":"completed"},
			{"name":"required-b","conclusion":"success","status":"completed"}
		]}'
		;;
	*)
		local_json='{"check_runs":[]}'
		;;
	esac
	apply_jq "$local_json" "$@"
	exit 0
fi

if [[ "$1" == "api" && "$*" == *"/commits/"* && "$*" == *"/status"* ]]; then
	if [[ "${MOCK_GH_MODE:-all_pass}" == "empty_required_current_pending_maintainer_gate_fallback" ]]; then
		apply_jq '{"statuses":[{"context":"maintainer-gate","state":"pending"}]}' "$@"
		exit 0
	fi
	apply_jq '{"statuses":[]}' "$@"
	exit 0
fi

# Unhandled gh invocations: silent success (we don't care about them here)
exit 0
EOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

test_required_checks_gh_reads_are_timeout_wrapped() {
	local required_checks_script="${REQUIRED_CHECKS_SCRIPT:-}"

	if [[ -z "$required_checks_script" ]]; then
		printf 'ERROR: REQUIRED_CHECKS_SCRIPT is empty or not set\n' >&2
		print_result "required-check gh reads use timeout wrapper" 1
		return 0
	fi

	if [[ ! -f "$required_checks_script" ]]; then
		printf 'ERROR: REQUIRED_CHECKS_SCRIPT file does not exist or is not a regular file: %s\n' "$required_checks_script" >&2
		print_result "required-check gh reads use timeout wrapper" 1
		return 0
	fi

	if { awk '{ if (sub(/\\$/, "")) { printf "%s", $0 } else { print } }' "$required_checks_script" |
		sed -E 's/_pmrc_gh_read[[:space:]]+gh[[:space:]]+(api|pr[[:space:]]+checks)//g' |
		grep -nE '^[[:space:]]*[^#]*(^|[[:space:]])gh[[:space:]]+(api|pr[[:space:]]+checks)([[:space:]]|$)'; } >/dev/null 2>&1; then
		print_result "required-check gh reads use timeout wrapper" 1
	else
		print_result "required-check gh reads use timeout wrapper" 0
	fi
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

eval_function_from_file() {
	local fn_name="$1"
	local source_file="$2"
	local fn_src=""
	fn_src=$(awk -v name="$fn_name" '
		$0 ~ "^" name "\\(\\) \\{" { capture = 1 }
		capture { print }
		capture && /^}$/ { capture = 0; exit }
	' "$source_file")
	if [[ -z "$fn_src" ]]; then
		printf 'ERROR: could not extract %s from %s\n' "$fn_name" "$source_file" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from extracted helper
	eval "$fn_src"
	return 0
}

# Extract _pr_required_checks_pass plus its helper stack into the current shell.
define_function_under_test() {
	local checks_lib="${SCRIPT_DIR}/../shared-gh-wrappers-checks.sh"
	if [[ ! -f "$checks_lib" ]]; then
		printf 'ERROR: shared-gh-wrappers-checks.sh not found at %s\n' "$checks_lib" >&2
		return 1
	fi
	# shellcheck disable=SC1090  # dynamic source from sibling lib
	source "$checks_lib"
	# Load the required-check module constants before evaluating selected
	# functions in isolation; extracted functions reference the PMRC_* contract.
	# shellcheck disable=SC1090  # dynamic source from sibling lib
	source "$REQUIRED_CHECKS_SCRIPT"
	gh_pr_view() {
		if gh pr view "$@"; then
			return 0
		fi
		return 1
	}

	eval_function_from_file _check_required_checks_passing "$MERGE_SCRIPT" || return 1
	eval_function_from_file _pr_required_checks_pass "$MERGE_SCRIPT" || return 1
	eval_function_from_file _pmrc_gh_read "$REQUIRED_CHECKS_SCRIPT" || return 1
	eval_function_from_file _check_required_pr_checks_passing_fallback "$REQUIRED_CHECKS_SCRIPT" || return 1
	eval_function_from_file _ruleset_required_review_count_for_default_branch "$REQUIRED_CHECKS_SCRIPT" || return 1
	eval_function_from_file _check_ruleset_required_reviews_passing "$REQUIRED_CHECKS_SCRIPT" || return 1
	eval_function_from_file _check_required_checks_has_terminal_failure "$REQUIRED_CHECKS_SCRIPT" || return 1
	return 0
}

assert_function_returns() {
	local expected_rc="$1"
	local label="$2"
	local actual_rc=0
	_pr_required_checks_pass "19023" "marcusquinn/aidevops" || actual_rc=$?
	if [[ "$actual_rc" -eq "$expected_rc" ]]; then
		print_result "$label" 0
	else
		print_result "$label" 1 "Expected rc=$expected_rc, got rc=$actual_rc"
	fi
	return 0
}

assert_passing_check_returns() {
	local expected_rc="$1"
	local label="$2"
	local actual_rc=0
	_check_required_checks_passing "marcusquinn/aidevops" "19023" || actual_rc=$?
	if [[ "$actual_rc" -eq "$expected_rc" ]]; then
		print_result "$label" 0
	else
		print_result "$label" 1 "Expected rc=$expected_rc, got rc=$actual_rc"
	fi
	return 0
}

assert_pr_checks_fallback_returns() {
	local expected_rc="$1"
	local expected_output="$2"
	local label="$3"
	local actual_rc=0
	local actual_output=""
	actual_output=$(_check_required_pr_checks_passing_fallback "marcusquinn/aidevops" "19023") || actual_rc=$?
	if [[ "$actual_rc" -eq "$expected_rc" && "$actual_output" == "$expected_output" ]]; then
		print_result "$label" 0
	else
		print_result "$label" 1 "Expected rc=$expected_rc output='$expected_output', got rc=$actual_rc output='$actual_output'"
	fi
	return 0
}

assert_ruleset_review_gate_returns() {
	local expected_rc="$1"
	local label="$2"
	local actual_rc=0
	_check_ruleset_required_reviews_passing "marcusquinn/aidevops" "19023" "author" || actual_rc=$?
	if [[ "$actual_rc" -eq "$expected_rc" ]]; then
		print_result "$label" 0
	else
		print_result "$label" 1 "Expected rc=$expected_rc, got rc=$actual_rc"
	fi
	return 0
}

assert_ruleset_review_count_output() {
	local expected_output="$1"
	local label="$2"
	local rulesets_json="${3:-}"
	local actual_output=""
	actual_output=$(_ruleset_required_review_count_for_default_branch "marcusquinn/aidevops" "main" "$rulesets_json") || actual_output="ERR"
	if [[ "$actual_output" == "$expected_output" ]]; then
		print_result "$label" 0
	else
		print_result "$label" 1 "Expected output='$expected_output', got output='$actual_output'"
	fi
	return 0
}

assert_gh_call_absent() {
	local pattern="$1"
	local label="$2"
	if grep -Fxq -- "$pattern" "$GH_CALL_LOG" 2>/dev/null; then
		print_result "$label" 1 "Unexpected gh invocation: $pattern"
	else
		print_result "$label" 0
	fi
	return 0
}

assert_gh_call_contains() {
	local pattern="$1"
	local label="$2"
	if grep -Fq -- "$pattern" "$GH_CALL_LOG" 2>/dev/null; then
		print_result "$label" 0
	else
		print_result "$label" 1 "Expected gh invocation containing: $pattern"
	fi
	return 0
}

assert_ruleset_contexts_output() {
	local expected_output="$1"
	local label="$2"
	local actual_output=""
	actual_output=$(_required_contexts_from_rulesets_for_default_branch "marcusquinn/aidevops" "main") || actual_output="ERR"
	if [[ "$actual_output" == "$expected_output" ]]; then
		print_result "$label" 0
	else
		print_result "$label" 1 "Expected output='$expected_output', got output='$actual_output'"
	fi
	return 0
}

assert_log_contains() {
	local pattern="$1"
	local label="$2"
	if grep -q -- "$pattern" "$LOGFILE" 2>/dev/null; then
		print_result "$label" 0
	else
		print_result "$label" 1 "Expected log line matching: $pattern"
	fi
	return 0
}

assert_log_empty() {
	local label="$1"
	if [[ ! -s "$LOGFILE" ]]; then
		print_result "$label" 0
	else
		local contents
		contents=$(cat "$LOGFILE")
		print_result "$label" 1 "Expected empty log, got: $contents"
	fi
	return 0
}

assert_gh_call_uses_rest_check_runs() {
	local label="$1"
	if grep -q -- "/check-runs" "$GH_CALL_LOG" 2>/dev/null; then
		print_result "$label" 0
	else
		print_result "$label" 1 "Expected REST check-runs invocation"
	fi
	return 0
}

test_all_pass_allows_merge() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="all_pass"
	assert_function_returns 0 "all required checks passing → merge allowed"
	assert_gh_call_uses_rest_check_runs "all_pass: REST check-runs called"
	assert_log_contains "no terminal failed required contexts" \
		"all_pass: pass message logged"
	return 0
}

test_post_merge_advisory_failure_ignored() {
	# Simulates the GH#18787 regression: statusCheckRollup would have
	# flagged "Sync Issue Hygiene on PR Merge" as FAILURE, but
	# branch-protection required contexts exclude that advisory workflow, so it
	# is invisible to the required-context gate.
	# all_pass mock represents that state: two required checks, both pass.
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="all_pass"
	assert_function_returns 0 "post-merge advisory failure (outside required set) → merge allowed (GH#18787 regression)"
	return 0
}

test_required_failure_blocks_merge() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="one_fail"
	assert_function_returns 1 "one required check-run failure → merge blocked"
	assert_log_contains "terminal failed required context" \
		"one_fail: required-context failure logged"
	assert_log_contains "REST required checks have terminal failure" \
		"one_fail: wrapper skip reason logged"
	return 0
}

test_required_cancel_blocks_merge() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="one_cancel"
	assert_function_returns 1 "required check-run cancelled → merge blocked"
	assert_log_contains "terminal failed required context" \
		"one_cancel: required-context failure logged"
	return 0
}

test_required_action_required_is_non_terminal() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="action_required"
	assert_function_returns 0 "required check-run action_required → no CI repair routing"
	assert_log_contains "no terminal failed required contexts" \
		"action_required: non-terminal classification logged"
	return 0
}

test_empty_required_set_allows_merge() {
	# Repo has no required checks defined in branch protection — nothing
	# is failing, so the gate must allow the merge.
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="empty_required"
	assert_function_returns 0 "empty required-checks set → merge allowed"
	assert_log_contains "no required contexts" \
		"empty_required: empty-context pass logged"
	return 0
}

test_empty_required_pending_fallback_blocks_ready_merge() {
	# GH#24311: branch/ruleset APIs can expose no contexts while GitHub's
	# PR-level required-check view still has pending required checks. The strict
	# passing gate must not count such a PR as merge-ready / zero-progress-eligible.
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="empty_required_pending_fallback"
	assert_passing_check_returns 1 "empty branch contexts + pending PR required check → strict passing gate blocks"
	assert_log_contains "PR-level required checks are not passing" \
		"empty_required_pending_fallback: fallback skip reason logged"
	return 0
}

test_empty_required_stale_maintainer_gate_fallback_allows_merge() {
	# GH#26894: maintainer-gate can leave a legacy commit status pending after
	# its current-head CheckRun has completed successfully. That stale alias must
	# not hold an otherwise ready worker PR in the zero-progress denominator.
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="empty_required_stale_maintainer_gate_fallback"
	assert_passing_check_returns 0 "empty branch contexts + stale maintainer-gate status with passing CheckRun → allowed"
	return 0
}

test_empty_required_current_pending_maintainer_gate_fallback_blocks_merge() {
	# GH#26899: if the current head still has a pending maintainer-gate status
	# context, GitHub can reject admin merge even though the maintainer-gate
	# CheckRun succeeded. Treat that as active, not stale, so pulse defers instead
	# of counting repeated failed admin merge attempts as zero-progress cycles.
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="empty_required_current_pending_maintainer_gate_fallback"
	assert_passing_check_returns 1 "empty branch contexts + current pending maintainer-gate status → strict passing gate blocks"
	assert_log_contains "PR-level required checks are not passing" \
		"current pending maintainer-gate: fallback skip reason logged"
	return 0
}

test_pr_checks_empty_success_outputs_json_array() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="all_pass"
	assert_pr_checks_fallback_returns 0 "[]" "empty PR required-checks success → fallback emits JSON array"
	return 0
}

test_pr_checks_empty_failure_fails_closed() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="pr_checks_empty_failure"
	assert_pr_checks_fallback_returns 2 "" "empty PR required-checks failure → fallback fails closed"
	return 0
}

test_pending_required_blocks_merge() {
	# t3567 semantics: pending required checks are not terminal failures, so the
	# CI repair/close/requeue gate must not fire while GitHub is still running CI.
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="pending_only"
	assert_function_returns 0 "pending required check → no CI repair routing"
	assert_log_contains "no terminal failed required contexts" \
		"pending_required: non-terminal classification logged"
	return 0
}

test_queued_required_is_non_terminal() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="queued_only"
	assert_function_returns 0 "queued required check → no CI repair routing"
	assert_log_contains "no terminal failed required contexts" \
		"queued_required: non-terminal classification logged"
	return 0
}

test_expected_required_is_non_terminal() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="expected_only"
	assert_function_returns 0 "expected required check → no CI repair routing"
	assert_log_contains "no terminal failed required contexts" \
		"expected_required: non-terminal classification logged"
	return 0
}

test_skipping_required_allows_merge() {
	# Skipping = the required check didn't run (conditional job skipped).
	# Not a failure, not counted.
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="skipping_only"
	assert_function_returns 0 "skipping required check → merge allowed"
	return 0
}

test_ruleset_review_only_missing_blocks_merge() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="ruleset_review_only_missing"
	assert_ruleset_review_count_output "1" "ruleset-only pull_request approval count extracted"
	assert_ruleset_review_gate_returns 1 "ruleset-only missing approval → merge blocked (GH#24577)"
	assert_log_contains "0/1 ruleset-required approval" \
		"ruleset-only missing approval: skip reason logged"
	return 0
}

test_ruleset_review_count_accepts_prefetched_rulesets_json() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="ruleset_review_only_missing"
	assert_ruleset_review_count_output "1" \
		"pre-fetched rulesets JSON skips rulesets list fetch" \
		'[{"id":101,"enforcement":"active","target":"branch"}]'
	assert_gh_call_absent "api repos/marcusquinn/aidevops/rulesets" \
		"pre-fetched rulesets JSON avoids redundant rulesets list API call"
	return 0
}

test_ruleset_review_only_approved_allows_merge() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="ruleset_review_only_approved"
	assert_ruleset_review_gate_returns 0 "ruleset-only satisfied approval → merge allowed (GH#24577)"
	assert_log_contains "satisfies 1/1 ruleset-required approval" \
		"ruleset-only satisfied approval: pass logged"
	assert_gh_call_contains "pulls/19023/reviews?per_page=100 --paginate --slurp" \
		"ruleset approval gate uses paginated REST reviews endpoint"
	assert_gh_call_absent "pr view 19023 --repo marcusquinn/aidevops --json reviews" \
		"ruleset approval gate avoids GraphQL review fetch"
	return 0
}

test_ruleset_latest_review_state_controls_approval() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="ruleset_review_latest_changes_requested"
	assert_ruleset_review_gate_returns 1 "latest CHANGES_REQUESTED revokes prior approval"
	assert_log_contains "0/1 ruleset-required approval" \
		"latest review state: revoked approval logged"
	return 0
}

test_ruleset_paginated_latest_approval_allows_merge() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="ruleset_review_paginated_approved"
	assert_ruleset_review_gate_returns 0 "later REST page approval supersedes prior change request"
	return 0
}

test_ruleset_author_approval_does_not_count() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="ruleset_review_author_only"
	assert_ruleset_review_gate_returns 1 "PR author approval does not satisfy ruleset"
	return 0
}

test_ruleset_malformed_reviews_fail_closed() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="ruleset_review_malformed_response"
	assert_ruleset_review_gate_returns 1 "malformed REST review pages fail closed"
	assert_log_contains "review parse failed" \
		"malformed REST review pages: parse failure logged"
	return 0
}

test_ruleset_malformed_review_element_fails_closed() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="ruleset_review_malformed_element"
	assert_ruleset_review_gate_returns 1 "non-object REST review element fails closed"
	assert_log_contains "review parse failed" \
		"non-object REST review element: parse failure logged"
	return 0
}

test_ruleset_review_fetch_error_fails_closed() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="ruleset_review_fetch_error"
	assert_ruleset_review_gate_returns 1 "REST review fetch error fails closed"
	assert_log_contains "review fetch failed" \
		"REST review fetch error: failure logged"
	return 0
}

test_ruleset_mixed_review_status_preserves_both_gates() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="ruleset_mixed_review_status"
	assert_ruleset_review_count_output "1" "mixed ruleset review count extracted"
	assert_ruleset_contexts_output "required-a" "mixed ruleset status context still extracted"
	assert_ruleset_review_gate_returns 0 "mixed ruleset satisfied approval → review gate allows"
	return 0
}

test_ruleset_review_zero_does_not_require_approval() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="ruleset_review_zero"
	assert_ruleset_review_count_output "0" "ruleset pull_request count zero extracted as no gate"
	assert_ruleset_review_gate_returns 0 "ruleset approval count zero → merge allowed (GH#24577)"
	return 0
}

test_ruleset_review_malformed_optional_does_not_fail_parse() {
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="ruleset_review_malformed_optional"
	assert_ruleset_review_count_output "0" "malformed optional ruleset fields parse as no review gate"
	assert_ruleset_review_gate_returns 0 "malformed optional ruleset fields do not fail closed"
	return 0
}

test_gh_api_error_fails_closed() {
	# gh exits 1 → the function MUST return 1 (fail-closed). A bubbling
	# gh error must never auto-merge when --admin would bypass branch
	# protection.
	: >"$GH_CALL_LOG"
	: >"$LOGFILE"
	export MOCK_GH_MODE="error"
	assert_function_returns 1 "required-context API error → merge blocked (fail-closed)"
	assert_log_contains "branch protection API failed" \
		"error: skip reason logged"
	assert_log_contains "REST required checks could not be classified" \
		"error: wrapper skip reason logged"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if ! define_function_under_test; then
		printf 'FATAL: function extraction failed\n' >&2
		return 1
	fi

	test_all_pass_allows_merge
	test_post_merge_advisory_failure_ignored
	test_required_failure_blocks_merge
	test_required_cancel_blocks_merge
	test_required_action_required_is_non_terminal
	test_empty_required_set_allows_merge
	test_empty_required_pending_fallback_blocks_ready_merge
	test_pr_checks_empty_success_outputs_json_array
	test_pr_checks_empty_failure_fails_closed
	test_pending_required_blocks_merge
	test_queued_required_is_non_terminal
	test_expected_required_is_non_terminal
	test_skipping_required_allows_merge
	test_ruleset_review_only_missing_blocks_merge
	test_ruleset_review_count_accepts_prefetched_rulesets_json
	test_ruleset_review_only_approved_allows_merge
	test_ruleset_latest_review_state_controls_approval
	test_ruleset_paginated_latest_approval_allows_merge
	test_ruleset_author_approval_does_not_count
	test_ruleset_malformed_reviews_fail_closed
	test_ruleset_malformed_review_element_fails_closed
	test_ruleset_review_fetch_error_fails_closed
	test_ruleset_mixed_review_status_preserves_both_gates
	test_ruleset_review_zero_does_not_require_approval
	test_ruleset_review_malformed_optional_does_not_fail_parse
	test_gh_api_error_fails_closed
	test_required_checks_gh_reads_are_timeout_wrapped
	test_empty_required_stale_maintainer_gate_fallback_allows_merge
	test_empty_required_current_pending_maintainer_gate_fallback_blocks_merge

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
