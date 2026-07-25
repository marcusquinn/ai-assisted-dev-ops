#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for stuck auto_merge fallback (t3192).
#
# Verifies _set_native_auto_merge_or_skip extends t3070's "auto_merge already
# set, defer to GitHub" branch with stuck-state detection. When GitHub wedges a
# PR in `mergeStateStatus=BLOCKED` despite all required checks SUCCESS and
# `mergeable=MERGEABLE` for >threshold seconds, the helper falls through to
# the caller's --admin merge path instead of letting the PR sit indefinitely.
#
#   Case (1): stuck >threshold + green + BLOCKED + MERGEABLE
#             → returns 1; t3192 audit log line written
#   Case (2): auto_merge set, under threshold (2 min ago)
#             → returns 0; t3070 deferring log line; no t3192 fallback
#   Case (3): auto_merge set, CI still pending (real wait)
#             → returns 0; deferring (legitimate)
#   Case (4): auto_merge set, reviewDecision=CHANGES_REQUESTED
#             → returns 0; deferring (review block, not our problem)
#
# Pattern mirrors test-pulse-merge-native-auto.sh — extracts the helpers
# from pulse-merge-process.sh via awk and evals them into the test shell so
# we can stub gh and assert on call shape without touching a real repo.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
PROCESS_SCRIPT="${SCRIPT_DIR}/../pulse-merge-process.sh"
REST_STATE_SCRIPT="${SCRIPT_DIR}/../pulse-merge-rest-state.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
GH_LOG=""

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

	# Default fixtures — Case (1) shape: stuck, green, BLOCKED, MERGEABLE.
	# Each test overrides the relevant fixture before invoking the helper.
	local enabled_at_default
	# 1 hour ago in UTC ISO-8601; resilient to either GNU `date -d` or
	# BSD `date -v`.
	enabled_at_default=$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| echo '2026-04-30T05:00:00Z')

	cat >"${TEST_ROOT}/pr_state.json" <<JSONEOF
{
  "autoMergeRequest": {"enabledAt": "${enabled_at_default}", "mergeMethod": "SQUASH"},
  "mergeStateStatus": "BLOCKED",
  "mergeable": "MERGEABLE",
  "headRefOid": "stuck-head",
  "reviewDecision": "APPROVED"
}
JSONEOF
	# Default required-checks state: 0 non-pass/skipping (i.e. all green).
	printf '0' >"${TEST_ROOT}/non_ok_count.txt"
	printf 'true' >"${TEST_ROOT}/allow_auto_merge.txt"
	printf '%s' '[{"id":1,"user":{"login":"reviewer"},"state":"APPROVED","submitted_at":"2026-07-25T12:00:00Z"}]' \
		>"${TEST_ROOT}/reviews.json"

	# Cache dir is keyed on PID — wipe between tests so allow_auto_merge
	# fixture changes are honoured.
	rm -rf "${TMPDIR:-/tmp}/aidevops-pulse-allow-auto-merge-$$" 2>/dev/null || true

	# Mock gh: logs every call, dispatches by argument shape.
	cat >"${TEST_ROOT}/bin/gh" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "gh $*" >>"${GH_LOG:-/dev/null}"

# Exact single-PR REST merge-state projection.
if [[ "$1" == "api" && "$2" == repos/*/pulls/*/reviews\?* ]]; then
	[[ "${FAIL_REVIEWS:-0}" == "1" ]] && exit 1
	cat "${TEST_ROOT}/reviews.json"
	exit 0
fi
if [[ "$1" == "api" && "$2" == repos/*/pulls/* ]]; then
	cat "${TEST_ROOT}/pr_state.json"
	exit 0
fi

# `gh api repos/<slug> --jq '.allow_auto_merge // false'`
if [[ "$1" == "api" && "$2" == repos/* && "$*" == *"allow_auto_merge"* ]]; then
	cat "${TEST_ROOT}/allow_auto_merge.txt"
	echo
	exit 0
fi

# `gh pr checks <N> --repo <slug> --required --json bucket --jq ...`
# Returns the count of non-pass/non-skipping required checks (stuck
# detector's safety check).
if [[ "$1" == "pr" && "$2" == "checks" && "$*" == *"--required"* ]]; then
	cat "${TEST_ROOT}/non_ok_count.txt"
	echo
	exit 0
fi

# `gh pr merge <N> --repo <slug> --auto --squash`
if [[ "$1" == "pr" && "$2" == "merge" && "$*" == *"--auto"* ]]; then
	exit 0
fi

# Default: succeed silently.
exit 0
GHEOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

teardown_test_env() {
	unset FAIL_REVIEWS
	rm -rf "${TMPDIR:-/tmp}/aidevops-pulse-allow-auto-merge-$$" 2>/dev/null || true
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Extract the three helpers from pulse-merge-process.sh and eval them into
# the test shell. _auto_merge_stuck_seconds is the new t3192 helper;
# _repo_allows_auto_merge and _set_native_auto_merge_or_skip are the
# pre-existing t3070 helpers we extend.
define_helpers_under_test() {
	local src_stuck src_repo_allow src_stop_external src_handle_existing src_set_native
	# shellcheck source=/dev/null
	source "$REST_STATE_SCRIPT"
	src_stuck=$(awk '
		/^_auto_merge_stuck_seconds\(\) \{/,/^\}$/ { print }
	' "$PROCESS_SCRIPT")
	src_repo_allow=$(awk '
		/^_repo_allows_auto_merge\(\) \{/,/^\}$/ { print }
	' "$PROCESS_SCRIPT")
	src_set_native=$(awk '
		/^_set_native_auto_merge_or_skip\(\) \{/,/^\}$/ { print }
	' "$PROCESS_SCRIPT")
	src_handle_existing=$(awk '
		/^_handle_existing_native_auto_merge\(\) \{/,/^\}$/ { print }
	' "$PROCESS_SCRIPT")
	src_stop_external=$(awk '
		/^_stop_external_native_auto_merge\(\) \{/,/^\}$/ { print }
	' "$PROCESS_SCRIPT")
	if [[ -z "$src_stuck" || -z "$src_repo_allow" || -z "$src_stop_external" \
		|| -z "$src_handle_existing" || -z "$src_set_native" ]] \
		|| ! declare -F _pmp_rest_pr_merge_state >/dev/null 2>&1; then
		printf 'ERROR: could not extract helpers from %s\n' "$PROCESS_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$src_stuck"
	# shellcheck disable=SC1090
	eval "$src_repo_allow"
	# shellcheck disable=SC1090
	eval "$src_stop_external"
	# shellcheck disable=SC1090
	eval "$src_handle_existing"
	# shellcheck disable=SC1090
	eval "$src_set_native"
	_check_required_checks_passing() {
		local repo_slug="$1"
		local pr_number="$2"
		local non_ok_count=""
		[[ -n "$repo_slug$pr_number" ]] || return 1
		non_ok_count=$(<"${TEST_ROOT}/non_ok_count.txt")
		[[ "$non_ok_count" == "0" ]]
		return $?
	}
	return 0
}

# =============================================================================
# Case (1): stuck >threshold + green + BLOCKED + MERGEABLE → return 1 (t3192)
# =============================================================================
test_case_1_stuck_falls_through() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	# Defaults already match: enabled 1h ago, BLOCKED, MERGEABLE, APPROVED,
	# 0 non-ok checks. Threshold default is 300s, 1h >> 300s → stuck.

	local result=0
	_set_native_auto_merge_or_skip "100" "owner/repo" "0" "APPROVED" "stuck-head" || result=$?

	if [[ "$result" -ne 1 ]]; then
		print_result "Case (1): stuck → returns 1 (fall-through to --admin)" 1 \
			"Expected exit 1, got ${result}. pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'auto_merge stuck.*t3192' "$LOGFILE"; then
		print_result "Case (1): stuck → t3192 audit log line written" 1 \
			"pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	if grep -qE 'gh pr merge 100 .*--auto' "$GH_LOG"; then
		print_result "Case (1): stuck → no NEW --auto invocation" 1 \
			"gh log: $(cat "$GH_LOG")"
		teardown_test_env
		return 0
	fi
	print_result "Case (1): stuck >threshold + green + BLOCKED → returns 1, t3192 logged" 0
	teardown_test_env
	return 0
}

# =============================================================================
# Case (2): auto_merge set 2 min ago, under threshold → return 0 (defer)
# =============================================================================
test_case_2_under_threshold_defers() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	# enabledAt 2 min ago → 120s < 300s default threshold → defer.
	local enabled_at_recent
	enabled_at_recent=$(date -u -d '2 minutes ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| date -u -v-2M '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| echo '2026-04-30T15:58:00Z')
	cat >"${TEST_ROOT}/pr_state.json" <<JSONEOF
{
  "autoMergeRequest": {"enabledAt": "${enabled_at_recent}", "mergeMethod": "SQUASH"},
  "mergeStateStatus": "BLOCKED",
  "mergeable": "MERGEABLE",
  "headRefOid": "stuck-head",
  "reviewDecision": "APPROVED"
}
JSONEOF

	local result=0
	_set_native_auto_merge_or_skip "200" "owner/repo" "0" "APPROVED" "stuck-head" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (2): under threshold → returns 0 (defer)" 1 \
			"Expected exit 0, got ${result}. pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	if grep -qE 'auto_merge stuck.*t3192' "$LOGFILE"; then
		print_result "Case (2): under threshold → no t3192 fallback log" 1 \
			"pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	if ! grep -qE 'auto_merge already set.*t3070' "$LOGFILE"; then
		print_result "Case (2): t3070 defer log line written" 1 \
			"pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	print_result "Case (2): under threshold → returns 0, t3070 deferring path" 0
	teardown_test_env
	return 0
}

# =============================================================================
# Case (3): auto_merge set, CI still pending → return 0 (legitimate defer)
# =============================================================================
test_case_3_pending_ci_defers() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	# Stuck duration would qualify (1h ago by default), but a required
	# check is still pending → not stuck, defer is correct.
	printf '1' >"${TEST_ROOT}/non_ok_count.txt"

	local result=0
	_set_native_auto_merge_or_skip "300" "owner/repo" "0" "APPROVED" "stuck-head" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (3): pending CI → returns 0 (defer)" 1 \
			"Expected exit 0, got ${result}. pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	if grep -qE 'auto_merge stuck.*t3192' "$LOGFILE"; then
		print_result "Case (3): pending CI → no t3192 fallback log" 1 \
			"pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	print_result "Case (3): pending CI → returns 0, defers (legitimate wait)" 0
	teardown_test_env
	return 0
}

# =============================================================================
# Case (4): auto_merge set, CHANGES_REQUESTED → return 0 (review block, defer)
# =============================================================================
test_case_4_changes_requested_defers() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	# Stuck duration qualifies; checks are green; but reviewDecision is
	# CHANGES_REQUESTED. Falling through to --admin would bypass a real
	# human review signal — defer is correct.
	local enabled_at_old
	enabled_at_old=$(date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| date -u -v-1H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| echo '2026-04-30T05:00:00Z')
	cat >"${TEST_ROOT}/pr_state.json" <<JSONEOF
{
  "autoMergeRequest": {"enabledAt": "${enabled_at_old}", "mergeMethod": "SQUASH"},
  "mergeStateStatus": "BLOCKED",
  "mergeable": "MERGEABLE",
  "headRefOid": "stuck-head",
  "reviewDecision": "CHANGES_REQUESTED"
}
JSONEOF

	local result=0
	_set_native_auto_merge_or_skip "400" "owner/repo" "0" "CHANGES_REQUESTED" "stuck-head" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (4): CHANGES_REQUESTED → returns 0 (defer, not our problem)" 1 \
			"Expected exit 0, got ${result}. pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	if grep -qE 'auto_merge stuck.*t3192' "$LOGFILE"; then
		print_result "Case (4): CHANGES_REQUESTED → no t3192 fallback log" 1 \
			"pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	print_result "Case (4): CHANGES_REQUESTED → returns 0, defers (review block respected)" 0
	teardown_test_env
	return 0
}

# =============================================================================
# Case (4b): unknown review state cannot authorize wedge bypass
# =============================================================================
test_case_4b_unknown_review_defers() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	local result=0
	_set_native_auto_merge_or_skip "401" "owner/repo" "0" "UNKNOWN" "stuck-head" || result=$?

	if [[ "$result" -eq 0 ]] && ! grep -qE 'auto_merge stuck.*t3192' "$LOGFILE"; then
		print_result "Case (4b): UNKNOWN review state defers wedge recovery" 0
	else
		print_result "Case (4b): UNKNOWN review state defers wedge recovery" 1 \
			"rc=${result}; pulse log: $(cat "$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_case_4c_fresh_changes_requested_defers() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	printf '%s' '[{"id":2,"user":{"login":"reviewer"},"state":"CHANGES_REQUESTED","submitted_at":"2026-07-25T12:01:00Z"}]' \
		>"${TEST_ROOT}/reviews.json"

	local result=0
	_set_native_auto_merge_or_skip "402" "owner/repo" "0" "APPROVED" "stuck-head" || result=$?
	if [[ "$result" -eq 0 ]] \
		&& grep -qE 'pulls/402/reviews\?per_page=100&page=1' "$GH_LOG" \
		&& ! grep -qE 'gh pr merge 402 .*--disable-auto' "$GH_LOG"; then
		print_result "Case (4c): fresh CHANGES_REQUESTED blocks stale wedge recovery" 0
	else
		print_result "Case (4c): fresh CHANGES_REQUESTED blocks stale wedge recovery" 1 \
			"rc=${result}; gh log: $(cat "$GH_LOG"); pulse log: $(cat "$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_case_4d_unavailable_review_refresh_defers() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	export FAIL_REVIEWS=1

	local result=0
	_set_native_auto_merge_or_skip "403" "owner/repo" "0" "APPROVED" "stuck-head" || result=$?
	if [[ "$result" -eq 0 ]] \
		&& grep -qE 'pulls/403/reviews\?per_page=100&page=1' "$GH_LOG" \
		&& ! grep -qE 'gh pr merge 403 .*--disable-auto' "$GH_LOG"; then
		print_result "Case (4d): unavailable fresh review evidence blocks wedge recovery" 0
	else
		print_result "Case (4d): unavailable fresh review evidence blocks wedge recovery" 1 \
			"rc=${result}; gh log: $(cat "$GH_LOG"); pulse log: $(cat "$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

# =============================================================================
# Case (5): threshold override via env → larger threshold defers a 1h-stuck PR
# =============================================================================
test_case_5_env_threshold_override() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	# Defaults give us a 1h-stuck PR. With default threshold (300s) it
	# would fall through; with threshold=7200 (2h) it should defer.
	local result=0
	AIDEVOPS_PULSE_AUTO_MERGE_STUCK_SECONDS=7200 \
		_set_native_auto_merge_or_skip "500" "owner/repo" "0" "APPROVED" "stuck-head" || result=$?

	if [[ "$result" -ne 0 ]]; then
		print_result "Case (5): env threshold override → defer when raised above stuck duration" 1 \
			"Expected exit 0, got ${result}. pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	if grep -qE 'auto_merge stuck.*t3192' "$LOGFILE"; then
		print_result "Case (5): env threshold override → no fallback when raised" 1 \
			"pulse log: $(cat "$LOGFILE")"
		teardown_test_env
		return 0
	fi
	print_result "Case (5): AIDEVOPS_PULSE_AUTO_MERGE_STUCK_SECONDS override defers when raised" 0
	teardown_test_env
	return 0
}

main() {
	test_case_1_stuck_falls_through
	test_case_2_under_threshold_defers
	test_case_3_pending_ci_defers
	test_case_4_changes_requested_defers
	test_case_4b_unknown_review_defers
	test_case_4c_fresh_changes_requested_defers
	test_case_4d_unavailable_review_refresh_defers
	test_case_5_env_threshold_override

	printf '\n=================================\n'
	printf 'Tests run: %d, failed: %d\n' "$TESTS_RUN" "$TESTS_FAILED"
	printf '=================================\n'

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		exit 1
	fi
	exit 0
}

main "$@"
