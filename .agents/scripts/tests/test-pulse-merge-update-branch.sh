#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for the t2116 CONFLICTING-close hardening in pulse-merge.sh:
#
#   1. `_attempt_pr_update_branch` — invokes `gh pr update-branch`, returns 0
#      on success and 1 on failure, logs to LOGFILE.
#   2. `_resolve_pr_mergeable_status` — retries UNKNOWN and empty mergeable
#      states, logging the original state clearly when still not mergeable.
#   3. CONFLICTING-close skip for PRs whose linked issue carries
#      `needs-maintainer-review` — verified indirectly via a smoke test that
#      drives `_process_single_ready_pr` through a mocked `gh` binary and
#      asserts the close path is NOT taken.
#   4. GH#24634: UNKNOWN mergeable is refreshed before the CONFLICTING branch
#      so REST-first list metadata cannot make conflict remediation unreachable.
#
# Mock pattern follows test-pulse-merge-rebase-nudge.sh: extract the helper
# source from the real pulse-merge.sh via awk, eval it into the test shell,
# and substitute `gh` with a stub on PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# _attempt_pr_update_branch was moved to pulse-merge-process.sh (GH#21595, t3030).
# _process_single_ready_pr stays in pulse-merge.sh — the static checks below
# (test_nmr_guard_exists_before_close, test_mergeable_refetch_after_update_branch)
# read it from $MERGE_SCRIPT.
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"
PROCESS_SCRIPT="${SCRIPT_DIR}/../pulse-merge-process.sh"
REST_STATE_SCRIPT="${SCRIPT_DIR}/../pulse-merge-rest-state.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
LAST_GH_ARGS_FILE=""
LAST_GH_QUOTA_FILE=""

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
	export AIDEVOPS_UPDATE_BRANCH_CONFLICT_COOLDOWN_DIR="${TEST_ROOT}/update-branch-conflicts"
	export AIDEVOPS_UPDATE_BRANCH_CONFLICT_COOLDOWN_SECONDS=3600
	: >"$LOGFILE"
	LAST_GH_ARGS_FILE="${TEST_ROOT}/gh-args.log"
	LAST_GH_QUOTA_FILE="${TEST_ROOT}/gh-quota.log"
	export LAST_GH_ARGS_FILE LAST_GH_QUOTA_FILE
	: >"$LAST_GH_ARGS_FILE"
	: >"$LAST_GH_QUOTA_FILE"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

# Install a gh stub that:
#   - logs every invocation to LAST_GH_ARGS_FILE (one line per call, tab-joined)
#   - REST update-branch endpoint → exit code controlled by GH_UB_EXIT
#   - `gh pr view <N> --repo <slug> --json mergeable --jq ...` → emits
#     GH_VIEW_MERGEABLE (default MERGEABLE)
#   - every other gh call → exit 0, no output
install_gh_stub() {
	cat >"${TEST_ROOT}/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${LAST_GH_ARGS_FILE}"
if [[ "${1:-}" == "api" && "${2:-}" == "--method" && "${3:-}" == "PUT" && "${4:-}" == repos/*/pulls/*/update-branch ]]; then
	printf '%s|%s|%s\n' "${AIDEVOPS_GH_QUOTA_COST:-}" \
		"${AIDEVOPS_GH_ROUTE_DECISION:-}" "$*" >>"${LAST_GH_QUOTA_FILE}"
	if [[ -n "${GH_UB_STATUS:-}" ]]; then
		printf 'gh: HTTP %s: update branch rejected\n' "$GH_UB_STATUS" >&2
	fi
	exit "${GH_UB_EXIT:-0}"
fi
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
	if [[ "$*" == *"--json labels"* ]]; then
		printf '%s\n' "${GH_PR_LABELS:-}"
		exit 0
	fi
	printf '%s\n' "${GH_VIEW_MERGEABLE:-MERGEABLE}"
	exit "${GH_VIEW_EXIT:-0}"
fi
exit 0
EOF
	chmod +x "${TEST_ROOT}/bin/gh"
	return 0
}

gh_pr_view() {
	gh pr view "$@"
	return $?
}

# Extract helpers from pulse-merge-process.sh (post-GH#21595)
# and eval it into the test shell. Matches the define_helper_under_test
# pattern used by test-pulse-merge-rebase-nudge.sh.
define_helper_under_test() {
	local helper_src
	# shellcheck source=/dev/null
	source "$REST_STATE_SCRIPT"
	helper_src=$(awk '
		/^_pmp_update_branch_conflict_cooldown_file\(\) \{/,/^}$/ { print }
		/^_pmp_update_branch_conflict_cooldown_active\(\) \{/,/^}$/ { print }
		/^_pmp_record_update_branch_conflict_cooldown\(\) \{/,/^}$/ { print }
		/^_attempt_pr_update_branch\(\) \{/,/^}$/ { print }
		/^_resolve_pr_mergeable_status\(\) \{/,/^}$/ { print }
	' "$PROCESS_SCRIPT")
	if [[ -z "$helper_src" || "$helper_src" != *"_pmp_record_update_branch_conflict_cooldown"* || "$helper_src" != *"_attempt_pr_update_branch"* || "$helper_src" != *"_resolve_pr_mergeable_status"* ]] \
		|| ! declare -F _pmp_update_branch_rest >/dev/null 2>&1 \
		|| ! declare -F _pmp_refresh_unknown_mergeable_state_into >/dev/null 2>&1; then
		printf 'ERROR: could not extract pulse-merge-process helpers from %s\n' "$PROCESS_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$helper_src"
	return 0
}

test_update_branch_success_returns_zero() {
	install_gh_stub
	GH_UB_EXIT=0 _attempt_pr_update_branch "18988" "marcusquinn/aidevops" "0123456789abcdef"
	local rc=$?

	if [[ $rc -ne 0 ]]; then
		print_result "update-branch success → return 0" 1 \
			"Expected return 0 on gh success, got ${rc}"
		return 0
	fi

	# Verify gh was called with the expected arguments.
	if ! grep -qE '^api --method PUT repos/marcusquinn/aidevops/pulls/18988/update-branch -f expected_head_sha=0123456789abcdef$' "$LAST_GH_ARGS_FILE"; then
		print_result "update-branch success → return 0" 1 \
			"Expected exact REST update-branch endpoint in gh args. Got: $(cat "$LAST_GH_ARGS_FILE")"
		return 0
	fi

	# Log should record success.
	if ! grep -q "update-branch succeeded" "$LOGFILE"; then
		print_result "update-branch success → return 0" 1 \
			"Expected 'update-branch succeeded' in LOGFILE"
		return 0
	fi

	print_result "update-branch success → return 0" 0
	return 0
}

test_update_branch_missing_head_fails_before_write() {
	install_gh_stub
	: >"$LAST_GH_ARGS_FILE"
	local output="" rc=0
	output=$(_pmp_update_branch_rest "18988" "marcusquinn/aidevops" 2>&1) || rc=$?

	if [[ "$rc" -eq 2 && ! -s "$LAST_GH_ARGS_FILE" && "$output" == *"expected head SHA is required"* ]]; then
		print_result "update-branch without expected head fails before write" 0
	else
		print_result "update-branch without expected head fails before write" 1 \
			"rc=${rc}; output=${output}; calls=$(cat "$LAST_GH_ARGS_FILE")"
	fi
	return 0
}

test_update_branch_failure_returns_one() {
	install_gh_stub
	# gh returns non-zero (true semantic conflict). `set -e` is active so
	# we MUST guard the failing call with a conditional to capture rc.
	local rc=0
	GH_UB_EXIT=1 _attempt_pr_update_branch "19094" "marcusquinn/aidevops" "fedcba9876543210" || rc=$?

	if [[ $rc -ne 1 ]]; then
		print_result "update-branch failure → return 1" 1 \
			"Expected return 1 on gh failure, got ${rc}"
		return 0
	fi

	# Log should record the fallthrough.
	if ! grep -q "update-branch failed, falling through to close" "$LOGFILE"; then
		print_result "update-branch failure → return 1" 1 \
			"Expected 'update-branch failed' in LOGFILE"
		return 0
	fi

	print_result "update-branch failure → return 1" 0
	return 0
}

test_update_branch_http_422_records_known_cost() {
	install_gh_stub
	: >"$LAST_GH_QUOTA_FILE"
	local rc=0
	GH_UB_EXIT=1 GH_UB_STATUS=422 \
		_pmp_update_branch_rest "19094" "marcusquinn/aidevops" "fedcba9876543210" \
		>/dev/null 2>&1 || rc=$?

	local expected="1|pulse-update-branch-rest|api --method PUT repos/marcusquinn/aidevops/pulls/19094/update-branch -f expected_head_sha=fedcba9876543210"
	if [[ "$rc" -eq 1 ]] && grep -Fqx "$expected" "$LAST_GH_QUOTA_FILE"; then
		print_result "update-branch HTTP 422 carries explicit one-request cost" 0
	else
		print_result "update-branch HTTP 422 carries explicit one-request cost" 1 \
			"rc=${rc}; quota=$(cat "$LAST_GH_QUOTA_FILE")"
	fi
	return 0
}

test_semantic_conflict_cooldown_skips_duplicate_write() {
	install_gh_stub
	: >"$LAST_GH_ARGS_FILE"
	: >"$LOGFILE"

	local rc=0
	GH_UB_EXIT=1 GH_UB_STATUS=422 GH_PR_LABELS=origin:interactive \
		_attempt_pr_update_branch "19094" "marcusquinn/aidevops" "fedcba9876543210" || rc=$?
	if [[ "$rc" -ne 1 ]]; then
		print_result "semantic conflict cooldown skips duplicate update-branch write" 1 \
			"Expected semantic conflict to return 1, got ${rc}"
		return 0
	fi

	: >"$LAST_GH_ARGS_FILE"
	: >"$LOGFILE"
	rc=0
	_attempt_pr_update_branch "19094" "marcusquinn/aidevops" "fedcba9876543210" || rc=$?
	if [[ "$rc" -ne 1 ]]; then
		print_result "semantic conflict cooldown skips duplicate update-branch write" 1 \
			"Expected cooldown skip to return 1, got ${rc}"
		return 0
	fi

	if [[ -s "$LAST_GH_ARGS_FILE" ]] || ! grep -q "semantic conflict cooldown active" "$LOGFILE"; then
		print_result "semantic conflict cooldown skips duplicate update-branch write" 1 \
			"Expected no gh call and a cooldown log. Calls: $(cat "$LAST_GH_ARGS_FILE"); log: $(cat "$LOGFILE")"
		return 0
	fi

	: >"$LAST_GH_ARGS_FILE"
	: >"$LOGFILE"
	rc=0
	GH_UB_EXIT=0 _attempt_pr_update_branch "19094" "marcusquinn/aidevops" "0123456789abcdef" || rc=$?
	if [[ "$rc" -ne 0 ]] || ! grep -q "update-branch" "$LAST_GH_ARGS_FILE"; then
		print_result "semantic conflict cooldown skips duplicate update-branch write" 1 \
			"Expected a changed head to bypass cooldown. rc=${rc}; calls: $(cat "$LAST_GH_ARGS_FILE")"
		return 0
	fi

	print_result "semantic conflict cooldown skips duplicate update-branch write" 0
	return 0
}

test_update_branch_tags_log_with_task_id() {
	install_gh_stub
	: >"$LOGFILE"
	GH_UB_EXIT=0 _attempt_pr_update_branch "12345" "marcusquinn/aidevops" "1234567890abcdef"

	# All t2116 log entries must carry the (t2116) tag for later audit.
	if ! grep -q '(t2116)' "$LOGFILE"; then
		print_result "log entries carry (t2116) audit tag" 1 \
			"Expected '(t2116)' in LOGFILE. Contents: $(cat "$LOGFILE")"
		return 0
	fi

	print_result "log entries carry (t2116) audit tag" 0
	return 0
}

test_resolve_mergeable_retries_unknown() {
	install_gh_stub
	: >"$LOGFILE"
	local rc=0
	GH_VIEW_MERGEABLE=MERGEABLE _resolve_pr_mergeable_status "21950" "marcusquinn/aidevops" "UNKNOWN" || rc=$?

	if [[ $rc -ne 0 ]]; then
		print_result "UNKNOWN mergeable retry can resolve to MERGEABLE" 1 \
			"Expected return 0 after retry, got ${rc}"
		return 0
	fi

	if ! grep -qE '^pr view 21950 --repo marcusquinn/aidevops --json mergeable --jq' "$LAST_GH_ARGS_FILE"; then
		print_result "UNKNOWN mergeable retry can resolve to MERGEABLE" 1 \
			"Expected gh pr view retry in args. Got: $(cat "$LAST_GH_ARGS_FILE")"
		return 0
	fi

	if ! grep -q "mergeable resolved to MERGEABLE after retry" "$LOGFILE"; then
		print_result "UNKNOWN mergeable retry can resolve to MERGEABLE" 1 \
			"Expected retry success log. Contents: $(cat "$LOGFILE")"
		return 0
	fi

	print_result "UNKNOWN mergeable retry can resolve to MERGEABLE" 0
	return 0
}

test_resolve_mergeable_accepts_boolean_true() {
	install_gh_stub
	: >"$LOGFILE"
	local rc=0
	_resolve_pr_mergeable_status "21950" "marcusquinn/aidevops" "true" || rc=$?

	if [[ $rc -ne 0 ]]; then
		print_result "boolean true mergeable normalizes to MERGEABLE" 1 \
			"Expected return 0 for boolean true, got ${rc}"
		return 0
	fi

	if [[ -s "$LOGFILE" ]]; then
		print_result "boolean true mergeable normalizes to MERGEABLE" 1 \
			"Expected no skip log for boolean true. Contents: $(cat "$LOGFILE")"
		return 0
	fi

	print_result "boolean true mergeable normalizes to MERGEABLE" 0
	return 0
}

test_resolve_mergeable_retries_boolean_true() {
	install_gh_stub
	: >"$LOGFILE"
	local rc=0
	GH_VIEW_MERGEABLE=true _resolve_pr_mergeable_status "21950" "marcusquinn/aidevops" "UNKNOWN" || rc=$?

	if [[ $rc -ne 0 ]]; then
		print_result "UNKNOWN retry boolean true normalizes to MERGEABLE" 1 \
			"Expected return 0 after retry emitted true, got ${rc}"
		return 0
	fi

	if ! grep -q "mergeable resolved to MERGEABLE after retry" "$LOGFILE"; then
		print_result "UNKNOWN retry boolean true normalizes to MERGEABLE" 1 \
			"Expected retry success log. Contents: $(cat "$LOGFILE")"
		return 0
	fi

	print_result "UNKNOWN retry boolean true normalizes to MERGEABLE" 0
	return 0
}

test_resolve_mergeable_retries_empty_and_logs_empty() {
	install_gh_stub
	: >"$LOGFILE"
	: >"$LAST_GH_ARGS_FILE"
	local rc=0
	GH_VIEW_MERGEABLE=UNKNOWN _resolve_pr_mergeable_status "21950" "marcusquinn/aidevops" "" || rc=$?

	if [[ $rc -ne 1 ]]; then
		print_result "empty mergeable retry logs original empty state" 1 \
			"Expected return 1 when retry remains UNKNOWN, got ${rc}"
		return 0
	fi

	if ! grep -qE '^pr view 21950 --repo marcusquinn/aidevops --json mergeable --jq' "$LAST_GH_ARGS_FILE"; then
		print_result "empty mergeable retry logs original empty state" 1 \
			"Expected gh pr view retry in args. Got: $(cat "$LAST_GH_ARGS_FILE")"
		return 0
	fi

	if ! grep -q "was empty, still not MERGEABLE after retry" "$LOGFILE"; then
		print_result "empty mergeable retry logs original empty state" 1 \
			"Expected empty-state retry log. Contents: $(cat "$LOGFILE")"
		return 0
	fi

	print_result "empty mergeable retry logs original empty state" 0
	return 0
}

test_refresh_unknown_mergeable_surfaces_conflicting() {
	install_gh_stub
	: >"$LAST_GH_ARGS_FILE"
	local pr_mergeable="UNKNOWN"
	local rc=0
	GH_VIEW_MERGEABLE=CONFLICTING _pmp_refresh_unknown_mergeable_state_into pr_mergeable "24658" "marcusquinn/aidevops" "$pr_mergeable" || rc=$?

	if [[ $rc -ne 0 || "$pr_mergeable" != "CONFLICTING" ]]; then
		print_result "UNKNOWN refresh surfaces CONFLICTING before conflict handler" 1 \
			"Expected pr_mergeable=CONFLICTING and rc=0, got pr_mergeable=${pr_mergeable}, rc=${rc}"
		return 0
	fi

	if ! grep -qE '^pr view 24658 --repo marcusquinn/aidevops --json mergeable --jq' "$LAST_GH_ARGS_FILE"; then
		print_result "UNKNOWN refresh surfaces CONFLICTING before conflict handler" 1 \
			"Expected gh pr view refresh in args. Got: $(cat "$LAST_GH_ARGS_FILE")"
		return 0
	fi

	print_result "UNKNOWN refresh surfaces CONFLICTING before conflict handler" 0
	return 0
}

# ---------------------------------------------------------------
# Static analysis of the t2116 block in _process_single_ready_pr.
# The full control-flow of _process_single_ready_pr depends on many
# helpers that are too heavy to mock reliably; instead we assert the
# exact structural properties that must hold for the fix to work:
#
#   1. A `needs-maintainer-review` guard exists and runs before
#      `_close_conflicting_pr` in the CONFLICTING branch.
#   2. `_attempt_pr_update_branch` is called from the CONFLICTING branch
#      before close.
#   3. After update-branch, mergeable state is re-fetched.
#   4. Protected PRs are skipped before _close_conflicting_pr.
# ---------------------------------------------------------------

test_nmr_guard_exists_before_close() {
	# Extract the CONFLICTING handling block from _process_single_ready_pr.
	local block
	block=$(awk '
		/^_process_single_ready_pr\(\) \{/,/^}$/ {
			if ($0 ~ /pr_mergeable.*CONFLICTING/) { capturing=1 }
			if (capturing) print
			if (capturing && /^	fi$/ && ++fi_count == 3) { exit }
		}
	' "$MERGE_SCRIPT")

	if [[ -z "$block" ]]; then
		print_result "NMR guard + update-branch structure present" 1 \
			"Could not extract CONFLICTING block from _process_single_ready_pr"
		return 0
	fi

	if [[ "$block" != *"needs-maintainer-review"* ]]; then
		print_result "NMR guard + update-branch structure present" 1 \
			"CONFLICTING block missing 'needs-maintainer-review' guard"
		return 0
	fi

	if [[ "$block" != *"_attempt_pr_update_branch"* ]]; then
		print_result "NMR guard + update-branch structure present" 1 \
			"CONFLICTING block missing _attempt_pr_update_branch call"
		return 0
	fi

	# NMR guard must appear BEFORE the _close_conflicting_pr call.
	local nmr_pos close_pos
	nmr_pos=$(printf '%s\n' "$block" | grep -n 'needs-maintainer-review' | head -1 | cut -d: -f1)
	close_pos=$(printf '%s\n' "$block" | grep -n '_close_conflicting_pr' | head -1 | cut -d: -f1)
	if [[ -z "$nmr_pos" || -z "$close_pos" ]] || [[ "$nmr_pos" -ge "$close_pos" ]]; then
		print_result "NMR guard + update-branch structure present" 1 \
			"NMR guard must appear before _close_conflicting_pr (nmr_pos=${nmr_pos}, close_pos=${close_pos})"
		return 0
	fi

	# update-branch must also appear BEFORE the final close.
	local ub_pos
	ub_pos=$(printf '%s\n' "$block" | grep -n '_attempt_pr_update_branch' | head -1 | cut -d: -f1)
	if [[ -z "$ub_pos" ]] || [[ "$ub_pos" -ge "$close_pos" ]]; then
		print_result "NMR guard + update-branch structure present" 1 \
			"update-branch must appear before _close_conflicting_pr (ub_pos=${ub_pos}, close_pos=${close_pos})"
		return 0
	fi

	print_result "NMR guard + update-branch structure present" 0
	return 0
}

test_stale_route_runs_before_protected_precheck() {
	local block
	block=$(awk '
		/^_process_single_ready_pr\(\) \{/ { in_fn=1 }
		in_fn && /_attempt_pr_update_branch/ { capturing=1 }
		capturing { print }
		capturing && /^[[:space:]]*_close_conflicting_pr "/ { exit }
	' "$MERGE_SCRIPT")

	local precheck_pos close_pos route_pos
	precheck_pos=$(printf '%s\n' "$block" | awk '/_close_conflicting_pr_skip_protected_precheck/ { print NR; exit }')
	close_pos=$(printf '%s\n' "$block" | awk '/^[[:space:]]*_close_conflicting_pr "/ { print NR; exit }')
	route_pos=$(printf '%s\n' "$block" | awk '/_route_pr_to_fix_worker/ { print NR; exit }')

	if [[ -z "$precheck_pos" || -z "$close_pos" || -z "$route_pos" ]]; then
		print_result "stale route runs before protected PR precheck" 1 \
			"Expected precheck, route, and close calls in CONFLICTING block (precheck=${precheck_pos}, route=${route_pos}, close=${close_pos})"
		return 0
	fi

	if [[ "$route_pos" -ge "$precheck_pos" || "$precheck_pos" -ge "$close_pos" ]]; then
		print_result "stale route runs before protected PR precheck" 1 \
			"Route must appear before protected precheck, and precheck before close (route=${route_pos}, precheck=${precheck_pos}, close=${close_pos})"
		return 0
	fi

	print_result "stale route runs before protected PR precheck" 0
	return 0
}

test_mergeable_refetch_after_update_branch() {
	# After update-branch succeeds the code must re-read pr_mergeable
	# via another `gh pr view --json mergeable` call, otherwise the
	# stale CONFLICTING value falls straight through to close.
	local block
	block=$(awk '
		/_attempt_pr_update_branch/,/_close_conflicting_pr/ { print }
	' "$MERGE_SCRIPT")

	if [[ "$block" != *"gh pr view"*"--json mergeable"* && "$block" != *"gh_pr_view"*"--json mergeable"* ]]; then
		print_result "mergeable re-fetched after successful update-branch" 1 \
			"Expected 'gh pr view/gh_pr_view ... --json mergeable' between update-branch and close"
		return 0
	fi

	print_result "mergeable re-fetched after successful update-branch" 0
	return 0
}

test_unknown_mergeable_refreshed_before_conflict_handler() {
	local function_src refresh_pos conflict_pos
	function_src=$(awk '
		/^_process_single_ready_pr\(\) \{/ { in_fn=1 }
		in_fn { print }
		in_fn && /^\}$/ { exit }
	' "$MERGE_SCRIPT")

	refresh_pos=$(printf '%s\n' "$function_src" | awk '/GH#24634/ { print NR; exit }')
	conflict_pos=$(printf '%s\n' "$function_src" | awk '/if \[\[ "\$pr_mergeable" == "CONFLICTING"/ { print NR; exit }')

	if [[ -z "$refresh_pos" || -z "$conflict_pos" ]]; then
		print_result "UNKNOWN mergeable refresh precedes CONFLICTING branch" 1 \
			"Expected GH#24634 refresh and CONFLICTING branch in _process_single_ready_pr (refresh=${refresh_pos}, conflict=${conflict_pos})"
		return 0
	fi

	if [[ "$refresh_pos" -ge "$conflict_pos" ]]; then
		print_result "UNKNOWN mergeable refresh precedes CONFLICTING branch" 1 \
			"Refresh must run before CONFLICTING branch (refresh=${refresh_pos}, conflict=${conflict_pos})"
		return 0
	fi

	if [[ "$function_src" != *"_pmp_refresh_unknown_mergeable_state_into pr_mergeable"* ]]; then
		print_result "UNKNOWN mergeable refresh precedes CONFLICTING branch" 1 \
			"Refresh must use helper to bypass stale PR-view cache and normalize into pr_mergeable"
		return 0
	fi

	local helper_src
	helper_src=$(awk '
		/^_pmp_refresh_unknown_mergeable_state_into\(\) \{/ { in_fn=1 }
		in_fn { print }
		in_fn && /^\}$/ { exit }
	' "$REST_STATE_SCRIPT")
	if [[ "$helper_src" != *"AIDEVOPS_GH_REST_FIRST_READS=1"* || "$helper_src" != *"AIDEVOPS_GH_PR_VIEW_CACHE_DISABLE=1"* || "$helper_src" != *"_pmp_normalize_mergeable_state_into refreshed_mergeable"* || "$helper_src" != *"printf -v \"\$dest_var\""* ]]; then
		print_result "UNKNOWN mergeable refresh precedes CONFLICTING branch" 1 \
			"Helper must bypass cache, normalize refreshed state, and write caller variable"
		return 0
	fi

	print_result "UNKNOWN mergeable refresh precedes CONFLICTING branch" 0
	return 0
}

test_ci_rebase_update_branch_has_active_check_guard() {
	local helper_src guard_pos update_pos terminal_pos
	helper_src=$(awk '
		/^_attempt_pr_ci_rebase_retry\(\) \{/ { in_fn=1 }
		in_fn { print }
		in_fn && /^}$/ { exit }
	' "$PROCESS_SCRIPT")

	terminal_pos=$(printf '%s\n' "$helper_src" | awk '/_check_required_checks_has_terminal_failure/ { print NR; exit }')
	guard_pos=$(printf '%s\n' "$helper_src" | awk '/_check_required_checks_have_pending_or_in_progress/ { print NR; exit }')
	update_pos=$(printf '%s\n' "$helper_src" | awk '/_ub_output=\$\(_pmp_update_branch_rest/ { print NR; exit }')

	if [[ -z "$terminal_pos" || -z "$guard_pos" || -z "$update_pos" ]]; then
		print_result "CI-drift update-branch checks current-head required state first" 1 \
			"Expected terminal check, active-check guard, and update-branch call (terminal=${terminal_pos}, guard=${guard_pos}, update=${update_pos})"
		return 0
	fi

	if [[ "$terminal_pos" -ge "$guard_pos" || "$guard_pos" -ge "$update_pos" ]]; then
		print_result "CI-drift update-branch checks current-head required state first" 1 \
			"Expected terminal check before active guard before update-branch (terminal=${terminal_pos}, guard=${guard_pos}, update=${update_pos})"
		return 0
	fi

	if [[ "$helper_src" != *"required checks are active on the current head"* || "$helper_src" != *"stale/non-required failure ignored"* ]]; then
		print_result "CI-drift update-branch checks current-head required state first" 1 \
			"Expected audit logs for active checks and stale/non-current failures"
		return 0
	fi

	print_result "CI-drift update-branch checks current-head required state first" 0
	return 0
}

test_required_check_pending_classifier_exists() {
	local helper_src
	helper_src=$(awk '
		/^_check_required_checks_have_pending_or_in_progress\(\) \{/ { in_fn=1 }
		in_fn { print }
		in_fn && /^}$/ { exit }
	' "${SCRIPT_DIR}/../pulse-merge-required-checks.sh")

	if [[ -z "$helper_src" ]]; then
		print_result "required-check pending classifier is available" 1 \
			"Could not extract _check_required_checks_have_pending_or_in_progress"
		return 0
	fi

	if [[ "$helper_src" != *"headRefOid"* || "$helper_src" != *"gh_pr_check_runs_rest"* ]]; then
		print_result "required-check pending classifier is available" 1 \
			"Classifier must use current headRefOid and REST check-runs"
		return 0
	fi

	if [[ "$helper_src" != *"queued"* || "$helper_src" != *"in_progress"* || "$helper_src" != *"waiting"* ]]; then
		print_result "required-check pending classifier is available" 1 \
			"Classifier must recognise queued/in_progress/waiting active states"
		return 0
	fi

	print_result "required-check pending classifier is available" 0
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	if ! define_helper_under_test; then
		printf 'FATAL: helper extraction failed\n' >&2
		return 1
	fi

	test_update_branch_success_returns_zero
	test_update_branch_missing_head_fails_before_write
	test_update_branch_failure_returns_one
	test_update_branch_http_422_records_known_cost
	test_semantic_conflict_cooldown_skips_duplicate_write
	test_update_branch_tags_log_with_task_id
	test_resolve_mergeable_retries_unknown
	test_resolve_mergeable_accepts_boolean_true
	test_resolve_mergeable_retries_boolean_true
	test_resolve_mergeable_retries_empty_and_logs_empty
	test_refresh_unknown_mergeable_surfaces_conflicting
	test_nmr_guard_exists_before_close
	test_stale_route_runs_before_protected_precheck
	test_mergeable_refetch_after_update_branch
	test_unknown_mergeable_refreshed_before_conflict_handler
	test_ci_rebase_update_branch_has_active_check_guard
	test_required_check_pending_classifier_exists

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
