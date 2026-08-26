#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for native GitHub auto-merge fast-track (t3070).
#
# Verifies the 4 decision-tree branches of _set_native_auto_merge_or_skip
# from `_repo_allows_auto_merge` + `_set_native_auto_merge_or_skip`
# (pulse-merge-process.sh):
#
#   Case (A): CI pending + repo allows auto-merge
#             → returns 0; `gh pr merge --auto --squash` invoked
#   Case (B): CI green (no required-bucket pending)
#             → returns 1; no `gh pr merge --auto` invocation (caller
#               falls through to immediate --admin merge for speed)
#   Case (C): PR already has autoMergeRequest set
#             → returns 0; no new `gh pr merge --auto` invocation
#               (deferred to GitHub)
#   Case (D): Repo allow_auto_merge=false
#             → returns 1; no `gh pr merge --auto` invocation
#   Case (E): autoMergeRequest pending past threshold
#             → returns 0 and keeps deferring because pending checks are non-terminal
#   Case (F): autoMergeRequest + MERGEABLE + BEHIND + green required checks
#             → update-branch succeeds and caller defers to the next cycle
#   Case (G): no autoMergeRequest + MERGEABLE + BEHIND + green required checks
#             → update-branch succeeds and caller defers to the next cycle
#   Case (H): stale autoMergeRequest + green required checks
#             → disables stale auto-merge and falls through
#   Case (I): REST auto_merge omits enabled_at
#             → unavailable exact fallback keeps wedge age unknown and defers
#   Case (J): REST auto_merge omits enabled_at, exact GraphQL fallback has it
#             → stale wedge recovery remains available
#
# Also verifies the caller contract: native auto-merge defer returns 4 from
# _process_single_ready_pr and _merge_ready_prs_for_repo does not count that as
# a completed merge. This keeps zero-progress telemetry tied to real merges.
#
# No real repository is touched. The `gh` binary is replaced with a mock
# stub that serves canned responses from TEST_ROOT fixture files and logs
# every invocation so we can assert on call shape.
#
# Pattern mirrors: test-pulse-merge-worker-briefed.sh (helper extraction
# via awk + eval into the test shell, gh mocking via PATH manipulation).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
PROCESS_SCRIPT="${SCRIPT_DIR}/../pulse-merge-process.sh"
REST_STATE_SCRIPT="${SCRIPT_DIR}/../pulse-merge-rest-state.sh"
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_LOG=""

initialize_native_auto_fixtures() {
	printf '{"auto_merge":null,"mergeable_state":"blocked","mergeable":true,"head":{"sha":"default-head-sha"}}' \
		>"${TEST_ROOT}/auto_merge_request.txt"
	printf 'true' >"${TEST_ROOT}/allow_auto_merge.txt"
	printf '1' >"${TEST_ROOT}/pending_count.txt"
	printf '[]' >"${TEST_ROOT}/reviews.json"
	return 0
}

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
	GH_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$GH_LOG"
	export TEST_ROOT GH_LOG

	# Default fixtures are overridden per test before invocation.
	initialize_native_auto_fixtures

	# Cache dir is keyed on PID — wipe between tests so allow_auto_merge
	# fixture changes are honoured (otherwise Case D inherits Case A).
	rm -rf "${TMPDIR:-/tmp}/aidevops-pulse-allow-auto-merge-$$" 2>/dev/null || true

	# Mock gh: logs every call, dispatches by argument shape.
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"

# Exact single-PR REST merge-state projection.
if [[ "$1" == "api" && "$2" == repos/*/pulls/*/reviews\?* ]]; then
	cat "${TEST_ROOT}/reviews.json"
	echo
	exit 0
fi
if [[ "$1" == "api" && "$2" == repos/*/pulls/* && "$2" != */update-branch ]]; then
	filter=""
	while [[ $# -gt 0 ]]; do
		if [[ "$1" == "--jq" && $# -ge 2 ]]; then
			filter="$2"
			break
		fi
		shift
	done
	if [[ -n "$filter" ]]; then
		jq -c "$filter" "${TEST_ROOT}/auto_merge_request.txt"
	else
		cat "${TEST_ROOT}/auto_merge_request.txt"
		echo
	fi
	exit 0
fi

# Fixed-cost GraphQL fallback for REST's missing auto_merge.enabled_at field.
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
	[[ -f "${TEST_ROOT}/graphql_auto_merge_response.txt" ]] || exit 1
	cat "${TEST_ROOT}/graphql_auto_merge_response.txt"
	echo
	exit "${GRAPHQL_AUTO_EXIT:-0}"
fi

# `gh api repos/<slug> --jq '.allow_auto_merge // false'`
if [[ "$1" == "api" && "$2" == repos/* && "$*" == *"allow_auto_merge"* ]]; then
	cat "${TEST_ROOT}/allow_auto_merge.txt"
	echo
	exit 0
fi

# `gh pr checks <N> --repo <slug> --required --json bucket --jq '...'`
if [[ "$1" == "pr" && "$2" == "checks" && "$*" == *"--required"* ]]; then
	cat "${TEST_ROOT}/pending_count.txt"
	echo
	exit 0
fi

# `gh pr merge <N> --repo <slug> --auto --squash`
if [[ "$1" == "pr" && "$2" == "merge" && "$*" == *"--auto"* ]]; then
	exit 0
fi

# `gh pr merge <N> --repo <slug> --disable-auto`
if [[ "$1" == "pr" && "$2" == "merge" && "$*" == *"--disable-auto"* ]]; then
	[[ "${FAIL_DISABLE_AUTO:-0}" == "1" ]] && exit 1
	exit 0
fi

if [[ "$1" == "pr" && "$2" == "ready" && "$*" == *"--undo"* ]]; then
	[[ "${FAIL_DRAFT_HOLD:-0}" == "1" ]] && exit 1
	exit 0
fi

# REST update-a-pull-request-branch endpoint.
if [[ "$1" == "api" && "$2" == "--method" && "$3" == "PUT" && "$4" == repos/*/pulls/*/update-branch ]]; then
	exit 0
fi

# Default: succeed silently for any other call shape.
exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

teardown_test_env() {
	# Wipe cache dir for next test.
	rm -rf "${TMPDIR:-/tmp}/aidevops-pulse-allow-auto-merge-$$" 2>/dev/null || true
	unset GRAPHQL_AUTO_EXIT
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Extract the helpers under test from pulse-merge-process.sh and eval them
# into the test shell. _set_native_auto_merge_or_skip calls
# _auto_merge_stuck_seconds (t3192), so we extract that too.
define_helpers_under_test() {
	local src_stuck src_repo_allow src_existing_green_behind src_green_behind
	local src_stop_external src_enable_native src_handle_existing src_set_native
	# shellcheck source=/dev/null
	source "$REST_STATE_SCRIPT"
	src_stuck=$(awk '
		/^_auto_merge_stuck_seconds\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$PROCESS_SCRIPT")
	src_repo_allow=$(awk '
		/^_repo_allows_auto_merge\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$PROCESS_SCRIPT")
	src_existing_green_behind=$(awk '
		/^_attempt_existing_auto_merge_behind_update_branch\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$PROCESS_SCRIPT")
	src_green_behind=$(awk '
		/^_attempt_green_behind_update_branch\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$PROCESS_SCRIPT")
	src_set_native=$(awk '
		/^_set_native_auto_merge_or_skip\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$PROCESS_SCRIPT")
	src_stop_external=$(awk '
		/^_stop_external_native_auto_merge\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$PROCESS_SCRIPT")
	src_enable_native=$(awk '
		/^_enable_native_auto_merge_for_head\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$PROCESS_SCRIPT")
	src_handle_existing=$(awk '
		/^_handle_existing_native_auto_merge\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$PROCESS_SCRIPT")
	if [[ -z "$src_stuck" || -z "$src_repo_allow" || -z "$src_existing_green_behind" \
		|| -z "$src_green_behind" || -z "$src_stop_external" || -z "$src_enable_native" \
		|| -z "$src_handle_existing" || -z "$src_set_native" ]] \
		|| ! declare -F _pmp_extract_update_branch_state >/dev/null 2>&1 \
		|| ! declare -F _pmp_rest_pr_merge_state >/dev/null 2>&1 \
		|| ! declare -F _pmp_update_branch_rest >/dev/null 2>&1; then
		printf 'ERROR: could not extract helpers from %s\n' "$PROCESS_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$src_stuck"
	# shellcheck disable=SC1090
	eval "$src_repo_allow"
	eval "$src_existing_green_behind"
	# shellcheck disable=SC1090
	eval "$src_green_behind"
	# shellcheck disable=SC1090
	eval "$src_stop_external"
	# shellcheck disable=SC1090
	eval "$src_enable_native"
	# shellcheck disable=SC1090
	eval "$src_handle_existing"
	# shellcheck disable=SC1090
	eval "$src_set_native"
	_pmp_normalize_mergeable_state_into() {
		local __target_var="$1"
		local __value="$2"
		case "$__value" in
			MERGEABLE | CONFLICTING | UNKNOWN) ;;
			*) __value="UNKNOWN" ;;
		esac
		printf -v "$__target_var" '%s' "$__value"
		return 0
	}
	_check_required_checks_passing() {
		local _repo_slug="$1"
		local _pr_number="$2"
		local pending_count
		pending_count=$(cat "${TEST_ROOT}/pending_count.txt")
		[[ "$pending_count" == "0" ]]
		return $?
	}
	return 0
}

assert_gh_call_shape() {
	local pattern="$1"
	local should_match="$2"  # 0=must match, 1=must NOT match
	local description="$3"

	if grep -qE "$pattern" "$GH_LOG"; then
		if [[ "$should_match" -eq 0 ]]; then
			return 0
		fi
		printf '       gh log: %s\n' "$(cat "$GH_LOG")" >&2
		print_result "${description} (expected NO match for: ${pattern})" 1
		return 1
	fi
	if [[ "$should_match" -eq 1 ]]; then
		return 0
	fi
	printf '       gh log: %s\n' "$(cat "$GH_LOG")" >&2
	print_result "${description} (expected match for: ${pattern})" 1
	return 1
}

# =============================================================================
# Case (A): CI pending + repo allows auto-merge → set --auto, return 0
# =============================================================================
test_case_a_pending_ci_sets_auto_merge() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	# Defaults already match: auto_merge_request empty, allow_auto_merge=true,
	# pending_count=1.

	local result=0
	_set_native_auto_merge_or_skip "100" "owner/repo" "0" "NONE" "case-a-head-sha" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (A): CI pending + repo allows → returns 0" 1 \
			"Expected exit 0, got ${result}"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'gh pr merge 100 --repo owner/repo --auto --squash --match-head-commit case-a-head-sha$' "$GH_LOG"; then
		print_result "Case (A): CI pending + repo allows → invokes gh pr merge --auto" 1 \
			"gh log: $(cat "$GH_LOG")"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'native auto-merge set.*t3070' "$LOGFILE"; then
		print_result "Case (A): CI pending → audit log line written" 1 \
			"pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	print_result "Case (A): CI pending + repo allows → returns 0 + invokes --auto" 0
	teardown_test_env
	return 0
}

test_case_a_missing_head_does_not_set_auto_merge() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	local result=0
	_set_native_auto_merge_or_skip "101" "owner/repo" "0" "NONE" || result=$?
	if [[ "$result" -eq 1 ]] \
		&& ! grep -qE 'gh pr merge 101 .*--auto' "$GH_LOG" \
		&& grep -qF 'gated head SHA is unavailable' "$LOGFILE"; then
		print_result "Case (A2): missing gated head never enables native auto-merge" 0
	else
		print_result "Case (A2): missing gated head never enables native auto-merge" 1 \
			"rc=${result}; gh log: $(cat "$GH_LOG"); pulse log: $(cat "$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (B): CI green (no pending bucket) → returns 1, no --auto invocation
# =============================================================================
test_case_b_ci_green_falls_through() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '0' >"${TEST_ROOT}/pending_count.txt"

	local result=0
	_set_native_auto_merge_or_skip "200" "owner/repo" || result=$?

	if [[ "$result" -ne 1 ]]; then
		print_result "Case (B): CI green → returns 1 (fall-through)" 1 \
			"Expected exit 1, got ${result}"
		teardown_test_env
		return 0
	fi
	if grep -qE 'gh pr merge 200 .*--auto' "$GH_LOG"; then
		print_result "Case (B): CI green → no gh pr merge --auto invocation" 1 \
			"gh log: $(cat "$GH_LOG")"
		teardown_test_env
		return 0
	fi
	print_result "Case (B): CI green → returns 1, no --auto invocation" 0
	teardown_test_env
	return 0
}

# =============================================================================
# Case (C): PR already has autoMergeRequest → returns 0, no new --auto call
# =============================================================================
test_case_c_already_set_no_op() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	# Non-empty autoMergeRequest payload — what GitHub returns when --auto
	# was previously requested. Since t3192, the helper fetches the full PR
	# state in a single call to evaluate stuck-state heuristics, so the
	# fixture must include mergeStateStatus, mergeable, and reviewDecision.
	# enabledAt is recent (now) so the stuck-state check returns 1 (defer)
	# and we fall through to the t3070 "auto_merge already set" path.
	local enabled_at_now
	enabled_at_now=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '2026-04-30T16:00:00Z')
	printf '{"auto_merge":{"enabled_at":"%s"},"mergeable_state":"blocked","mergeable":true,"head":{"sha":"case-c-head"}}' \
		"$enabled_at_now" >"${TEST_ROOT}/auto_merge_request.txt"

	local result=0
	_set_native_auto_merge_or_skip "300" "owner/repo" "0" "NONE" "case-c-head" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (C): auto_merge already set → returns 0 (no-op)" 1 \
			"Expected exit 0, got ${result}"
		teardown_test_env
		return 0
	fi
	if grep -qE 'gh pr merge 300 .*--auto' "$GH_LOG"; then
		print_result "Case (C): auto_merge already set → no NEW --auto invocation" 1 \
			"gh log: $(cat "$GH_LOG")"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'auto_merge already set.*t3070' "$LOGFILE"; then
		print_result "Case (C): already-set audit log line written" 1 \
			"pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	print_result "Case (C): auto_merge already set → returns 0 (deferred to GitHub)" 0
	teardown_test_env
	return 0
}

test_case_c2_existing_auto_head_mismatch_is_disarmed() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	local enabled_at_now
	enabled_at_now=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo '2026-04-30T16:00:00Z')
	printf '{"auto_merge":{"enabled_at":"%s"},"mergeable_state":"blocked","mergeable":true,"head":{"sha":"new-live-head"}}' \
		"$enabled_at_now" >"${TEST_ROOT}/auto_merge_request.txt"

	local result=0
	_set_native_auto_merge_or_skip "301" "owner/repo" "0" "NONE" "previous-gated-head" || result=$?
	if [[ "$result" -eq 2 ]] \
		&& grep -qE 'gh pr merge 301 --repo owner/repo --disable-auto' "$GH_LOG" \
		&& grep -qF 'existing native auto-merge head no longer matches the gated head' "$LOGFILE"; then
		print_result "Case (C2): existing auto-merge is disarmed after a head race" 0
	else
		print_result "Case (C2): existing auto-merge is disarmed after a head race" 1 \
			"rc=${result}; gh log: $(cat "$GH_LOG"); pulse log: $(cat "$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (D): allow_auto_merge=false → returns 1, no --auto call
# =============================================================================
test_case_d_repo_disallows_falls_through() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf 'false' >"${TEST_ROOT}/allow_auto_merge.txt"

	local result=0
	_set_native_auto_merge_or_skip "400" "owner/repo" || result=$?

	if [[ "$result" -ne 1 ]]; then
		print_result "Case (D): allow_auto_merge=false → returns 1 (fall-through)" 1 \
			"Expected exit 1, got ${result}"
		teardown_test_env
		return 0
	fi
	if grep -qE 'gh pr merge 400 .*--auto' "$GH_LOG"; then
		print_result "Case (D): allow_auto_merge=false → no --auto invocation" 1 \
			"gh log: $(cat "$GH_LOG")"
		teardown_test_env
		return 0
	fi
	print_result "Case (D): allow_auto_merge=false → returns 1, no --auto invocation" 0
	teardown_test_env
	return 0
}

# =============================================================================
# Case (E): PR already has autoMergeRequest but required checks are stale-pending
# =============================================================================
test_case_e_stale_pending_defers() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	local old_enabled_at
	old_enabled_at=$(date -u -v-30M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| date -u -d '30 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| echo '2026-04-30T16:00:00Z')
	printf '{"auto_merge":{"enabled_at":"%s"},"mergeable_state":"blocked","mergeable":true,"head":{"sha":"case-e-head"}}' \
		"$old_enabled_at" >"${TEST_ROOT}/auto_merge_request.txt"
	printf '1' >"${TEST_ROOT}/pending_count.txt"
	export AIDEVOPS_PULSE_AUTO_MERGE_STUCK_SECONDS=60

	local result=0
	_set_native_auto_merge_or_skip "500" "owner/repo" "0" "NONE" "case-e-head" || result=$?
	unset AIDEVOPS_PULSE_AUTO_MERGE_STUCK_SECONDS

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (E): stale pending auto_merge → returns 0 (defer)" 1 \
			"Expected exit 0, got ${result}"
		teardown_test_env
		return 0
	fi
	if grep -qE 'gh pr merge 500 .*--auto' "$GH_LOG"; then
		print_result "Case (E): stale pending auto_merge → no new --auto invocation" 1 \
			"gh log: $(cat "$GH_LOG")"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'required check\(s\) pending.*t3567' "$LOGFILE"; then
		print_result "Case (E): stale pending auto_merge → defer audit log written" 1 \
			"pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	print_result "Case (E): stale pending auto_merge → returns 0 and defers" 0
	teardown_test_env
	return 0
}

# =============================================================================
# Case (H): PR already has autoMergeRequest, is stale, and checks are green
# =============================================================================
test_case_h_stuck_green_disables_auto_before_fallthrough() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	local old_enabled_at
	old_enabled_at=$(date -u -v-30M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| date -u -d '30 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| echo '2026-04-30T16:00:00Z')
	printf '{"auto_merge":{"enabled_at":"%s"},"mergeable_state":"blocked","mergeable":true,"head":{"sha":"case-h-head"}}' \
		"$old_enabled_at" >"${TEST_ROOT}/auto_merge_request.txt"
	printf '0' >"${TEST_ROOT}/pending_count.txt"
	export AIDEVOPS_PULSE_AUTO_MERGE_STUCK_SECONDS=60

	local result=0
	_set_native_auto_merge_or_skip "800" "owner/repo" "0" "NONE" "case-h-head" || result=$?
	unset AIDEVOPS_PULSE_AUTO_MERGE_STUCK_SECONDS

	if [[ "$result" -ne 1 ]]; then
		print_result "Case (H): stuck green auto_merge → returns 1 (fall-through)" 1 \
			"Expected exit 1, got ${result}"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'gh pr merge 800 --repo owner/repo --disable-auto' "$GH_LOG"; then
		print_result "Case (H): stuck green auto_merge → disables stale auto-merge" 1 \
			"gh log: $(cat "$GH_LOG")"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'disabled stale native auto-merge.*GH#26897' "$LOGFILE"; then
		print_result "Case (H): stuck green auto_merge → disable audit log written" 1 \
			"pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	print_result "Case (H): stuck green auto_merge → disables stale auto-merge and falls through" 0
	teardown_test_env
	return 0
}

test_case_h2_stale_disarm_failure_applies_hold() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	local old_enabled_at
	old_enabled_at=$(date -u -v-30M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| date -u -d '30 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| echo '2026-04-30T16:00:00Z')
	printf '{"auto_merge":{"enabled_at":"%s"},"mergeable_state":"blocked","mergeable":true,"head":{"sha":"case-h2-head"}}' \
		"$old_enabled_at" >"${TEST_ROOT}/auto_merge_request.txt"
	printf '0' >"${TEST_ROOT}/pending_count.txt"
	export AIDEVOPS_PULSE_AUTO_MERGE_STUCK_SECONDS=60 FAIL_DISABLE_AUTO=1

	local result=0
	_set_native_auto_merge_or_skip "801" "owner/repo" "0" "NONE" "case-h2-head" || result=$?
	unset AIDEVOPS_PULSE_AUTO_MERGE_STUCK_SECONDS FAIL_DISABLE_AUTO
	if [[ "$result" -eq 2 ]] \
		&& grep -qE 'gh pr merge 801 --repo owner/repo --disable-auto' "$GH_LOG" \
		&& grep -qE 'gh pr ready 801 --repo owner/repo --undo' "$GH_LOG"; then
		print_result "Case (H2): stale-auto disable failure applies a draft hold" 0
	else
		print_result "Case (H2): stale-auto disable failure applies a draft hold" 1 \
			"rc=${result}; gh log: $(cat "$GH_LOG"); pulse log: $(cat "$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (I): REST auto_merge without enabled_at keeps wedge recovery fail-closed
# =============================================================================
test_case_i_missing_enabled_at_defers() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '%s' '{"auto_merge":{"enabled_by":{"login":"maintainer"}},"mergeable_state":"blocked","mergeable":true,"head":{"sha":"case-i-head"}}' \
		>"${TEST_ROOT}/auto_merge_request.txt"
	printf '0' >"${TEST_ROOT}/pending_count.txt"

	local result=0
	_set_native_auto_merge_or_skip "850" "owner/repo" "0" "NONE" "case-i-head" || result=$?

	if [[ "$result" -eq 0 ]] \
		&& grep -qE 'gh api repos/owner/repo/pulls/850 --jq' "$GH_LOG" \
		&& ! grep -qE 'gh pr view|gh pr merge 850 .*--disable-auto' "$GH_LOG" \
		&& grep -qE 'auto_merge already set.*t3070' "$LOGFILE"; then
		print_result "Case (I): missing REST enabled_at keeps wedge recovery fail-closed" 0
	else
		print_result "Case (I): missing REST enabled_at keeps wedge recovery fail-closed" 1 \
			"rc=${result}; gh log: $(cat "$GH_LOG"); pulse log: $(cat "$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (J): exact GraphQL enabledAt fallback preserves stale-wedge recovery
# =============================================================================
test_case_j_graphql_enabled_at_restores_wedge_recovery() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '%s' '{"auto_merge":{"enabled_by":{"login":"maintainer"}},"mergeable_state":"blocked","mergeable":true,"head":{"sha":"case-j-head"}}' \
		>"${TEST_ROOT}/auto_merge_request.txt"
	printf '%s' '{"data":{"repository":{"pullRequest":{"autoMergeRequest":{"enabledAt":"2026-06-15T14:00:00Z"}}},"rateLimit":{"cost":1}}}' \
		>"${TEST_ROOT}/graphql_auto_merge_response.txt"
	printf '0' >"${TEST_ROOT}/pending_count.txt"

	local result=0
	_set_native_auto_merge_or_skip "851" "owner/repo" "0" "NONE" "case-j-head" || result=$?

	if [[ "$result" -eq 1 ]] \
		&& grep -qE '^gh api graphql ' "$GH_LOG" \
		&& grep -qF 'rateLimit { cost }' "$GH_LOG" \
		&& grep -qE 'gh pr merge 851 --repo owner/repo --disable-auto' "$GH_LOG" \
		&& grep -qE 'disabled stale native auto-merge.*GH#26897' "$LOGFILE"; then
		print_result "Case (J): exact enabledAt fallback restores stale-wedge recovery" 0
	else
		print_result "Case (J): exact enabledAt fallback restores stale-wedge recovery" 1 \
			"rc=${result}; gh log: $(cat "$GH_LOG"); pulse log: $(cat "$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (F): existing auto-merge is green but behind → update branch and defer
# =============================================================================
test_case_f_green_behind_updates_branch() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"auto_merge":{"enabled_at":"2026-06-15T14:00:00Z"},"mergeable_state":"behind","mergeable":true,"head":{"sha":"case-f-head-sha"}}' \
		>"${TEST_ROOT}/auto_merge_request.txt"
	printf '0' >"${TEST_ROOT}/pending_count.txt"

	local result=0
	_attempt_existing_auto_merge_behind_update_branch "600" "owner/repo" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (F): green BEHIND auto_merge → update-branch returns 0" 1 \
			"Expected exit 0, got ${result}"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'gh api --method PUT repos/owner/repo/pulls/600/update-branch -f expected_head_sha=case-f-head-sha' "$GH_LOG"; then
		print_result "Case (F): green BEHIND auto_merge → invokes update-branch" 1 \
			"gh log: $(cat "$GH_LOG")"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'green but BEHIND.*update-branch succeeded.*GH#24839' "$LOGFILE"; then
		print_result "Case (F): green BEHIND auto_merge → audit log written" 1 \
			"pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	print_result "Case (F): green BEHIND auto_merge → updates branch and defers" 0
	teardown_test_env
	return 0
}

# =============================================================================
# Case (G): no native auto-merge request, green but behind → update branch/defer
# =============================================================================
test_case_g_green_behind_without_auto_merge_updates_branch() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	printf '{"auto_merge":null,"mergeable_state":"behind","mergeable":true,"head":{"sha":"case-g-head-sha"}}' \
		>"${TEST_ROOT}/auto_merge_request.txt"
	printf '0' >"${TEST_ROOT}/pending_count.txt"

	local result=0
	_attempt_green_behind_update_branch "700" "owner/repo" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (G): green BEHIND without auto_merge → update-branch returns 0" 1 \
			"Expected exit 0, got ${result}"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'gh api --method PUT repos/owner/repo/pulls/700/update-branch -f expected_head_sha=case-g-head-sha' "$GH_LOG"; then
		print_result "Case (G): green BEHIND without auto_merge → invokes update-branch" 1 \
			"gh log: $(cat "$GH_LOG")"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'green but BEHIND without native auto-merge.*update-branch succeeded.*GH#26659' "$LOGFILE"; then
		print_result "Case (G): green BEHIND without auto_merge → audit log written" 1 \
			"pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	print_result "Case (G): green BEHIND without auto_merge → updates branch and defers" 0
	teardown_test_env
	return 0
}

test_native_auto_defer_not_counted_as_completed_merge() {
	local process_src merge_src
	process_src=$(awk '
		/^_pmp_record_processed_pr_result\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$PROCESS_SCRIPT")
	merge_src=$(awk '
		/^_pmp_stage_pre_merge\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$MERGE_SCRIPT")

	if [[ -z "$process_src" || -z "$merge_src" ]]; then
		print_result "Native auto defer contract is inspectable" 1 \
			"Could not extract merge process functions"
		return 0
	fi

	if [[ "$merge_src" != *'return 4'* ]]; then
		print_result "Native auto defer returns distinct non-merged code" 1 \
			"Expected _pmp_stage_pre_merge native-auto branch to return 4"
		return 0
	fi

	if [[ "$process_src" != *'4) outcome="deferred" ;;'* ]]; then
		print_result "Native auto defer is not counted as completed merge" 1 \
			"Expected _pmp_record_processed_pr_result to record rc=4 as deferred without merged++"
		return 0
	fi

	print_result "Native auto defer is not counted as completed merge" 0
	return 0
}

test_external_pending_ci_never_sets_deferred_auto_merge() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	local result=0
	_set_native_auto_merge_or_skip "900" "owner/repo" "1" || result=$?
	if [[ "$result" -eq 2 ]] && ! grep -qE 'gh pr merge 900 .*--auto' "$GH_LOG"; then
		print_result "External approval state with pending CI defers without native auto-merge" 0
	else
		print_result "External approval state with pending CI defers without native auto-merge" 1 \
			"rc=${result}; gh log: $(cat "$GH_LOG")"
	fi
	teardown_test_env
	return 0
}

test_external_existing_auto_merge_is_disabled() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	printf '%s' '{"auto_merge":{"enabled_at":"2026-07-14T12:00:00Z"},"mergeable_state":"blocked","mergeable":true}' \
		>"${TEST_ROOT}/auto_merge_request.txt"

	local result=0
	_set_native_auto_merge_or_skip "901" "owner/repo" "1" || result=$?
	if [[ "$result" -eq 2 ]] && grep -qE 'gh pr merge 901 --repo owner/repo --disable-auto' "$GH_LOG"; then
		print_result "External approval state disables previously deferred auto-merge" 0
	else
		print_result "External approval state disables previously deferred auto-merge" 1 \
			"rc=${result}; gh log: $(cat "$GH_LOG")"
	fi
	teardown_test_env
	return 0
}

test_external_auto_merge_disable_failure_applies_draft_hold() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	printf '%s' '{"auto_merge":{"enabled_at":"2026-07-14T12:00:00Z"},"mergeable_state":"blocked","mergeable":true}' \
		>"${TEST_ROOT}/auto_merge_request.txt"
	export FAIL_DISABLE_AUTO=1
	local result=0
	_set_native_auto_merge_or_skip "902" "owner/repo" "1" || result=$?
	unset FAIL_DISABLE_AUTO
	if [[ "$result" -eq 2 ]] && grep -qE 'gh pr ready 902 --repo owner/repo --undo' "$GH_LOG"; then
		print_result "External auto-merge disable failure applies a server-side draft hold" 0
	else
		print_result "External auto-merge disable failure applies a server-side draft hold" 1 \
			"rc=${result}; gh log: $(cat "$GH_LOG")"
	fi
	teardown_test_env
	return 0
}

test_protected_release_pr_uses_exact_merge_owner() {
	# shellcheck source=../pulse-merge-process.sh
	source "$PROCESS_SCRIPT"
	if _pmp_is_protected_release_pr \
		"chore/release-v1.2.3-provenance" "origin:worker,release,status:in-review" &&
		! _pmp_is_protected_release_pr \
			"chore/release-v1.2.3-provenance" "origin:worker,status:in-review" &&
		! _pmp_is_protected_release_pr \
			"feature/release-lookalike" "origin:worker,release,status:in-review"; then
		print_result "Protected release PRs remain owned by exact-merge reconciliation" 0
	else
		print_result "Protected release PRs remain owned by exact-merge reconciliation" 1
	fi
	return 0
}

main() {
	test_case_a_pending_ci_sets_auto_merge
	test_case_a_missing_head_does_not_set_auto_merge
	test_case_b_ci_green_falls_through
	test_case_c_already_set_no_op
	test_case_c2_existing_auto_head_mismatch_is_disarmed
	test_case_d_repo_disallows_falls_through
	test_case_e_stale_pending_defers
	test_case_h_stuck_green_disables_auto_before_fallthrough
	test_case_h2_stale_disarm_failure_applies_hold
	test_case_i_missing_enabled_at_defers
	test_case_j_graphql_enabled_at_restores_wedge_recovery
	test_case_f_green_behind_updates_branch
	test_case_g_green_behind_without_auto_merge_updates_branch
	test_native_auto_defer_not_counted_as_completed_merge
	test_external_pending_ci_never_sets_deferred_auto_merge
	test_external_existing_auto_merge_is_disabled
	test_external_auto_merge_disable_failure_applies_draft_hold
	test_protected_release_pr_uses_exact_merge_owner

	printf '\n=================================\n'
	printf 'Tests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	printf '=================================\n'

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
