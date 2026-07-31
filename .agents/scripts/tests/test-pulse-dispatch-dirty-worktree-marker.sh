#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for dirty-worktree recovery dispatch holds.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
LIB_SCRIPT="${SCRIPT_DIR}/../pulse-dispatch-lib.sh"
WORKER_LAUNCH_SCRIPT="${SCRIPT_DIR}/../pulse-dispatch-worker-launch.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0
TEST_GH_POST_COUNT=0

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

gh() {
	local subcommand="$1"
	local endpoint="${2:-}"
	if [[ "$subcommand" == "api" && "$endpoint" == "repos/marcusquinn/aidevops/issues/26635/comments" && "$*" == *"--method POST"* ]]; then
		TEST_GH_POST_COUNT=$((TEST_GH_POST_COUNT + 1))
		return 0
	fi
	if [[ "$subcommand" != "api" || "$endpoint" != "repos/marcusquinn/aidevops/issues/26635/comments?per_page=100" ]]; then
		printf 'unexpected gh call: %s\n' "$*" >&2
		return 1
	fi
	printf '%s\n' "${TEST_GH_COMMENTS_JSON:-[]}"
	return 0
}

load_lib() {
	LOGFILE="${TMPDIR:-/tmp}/test-pulse-dispatch-dirty-worktree-marker.log"
	: >"$LOGFILE"
	# shellcheck disable=SC1090 # test sources the library under test by path.
	source "$LIB_SCRIPT"
	# shellcheck disable=SC1090 # test sources the worker launch helper by path.
	source "$WORKER_LAUNCH_SCRIPT"
	_dispatch_stats_increment() { return 0; }
	return 0
}

test_recent_marker_blocks_dispatch() {
	local comments_json='[{"created_at":"2026-07-05T22:22:12Z","body":"WORKER_DIRTY_WORKTREE branch=feature/auto-20260706-000537-gh26635 runner_key=runner-other"}]'
	TEST_GH_COMMENTS_JSON="$comments_json" \
		AIDEVOPS_DIRTY_WORKTREE_NOW_EPOCH="1783291032" \
		DISPATCH_DIRTY_WORKTREE_HOLD_SECONDS="21600" \
		_dispatch_recent_dirty_worktree_marker_active "26635" "marcusquinn/aidevops"
	local rc=$?
	if [[ "$rc" -eq 0 ]]; then
		print_result "recent dirty marker blocks dispatch" 0
		return 0
	fi
	print_result "recent dirty marker blocks dispatch" 1 "expected active marker to block"
	return 0
}

test_same_runner_marker_allows_resume() {
	local comments_json='[{"created_at":"2026-07-05T22:22:12Z","body":"WORKER_DIRTY_WORKTREE branch=feature/auto-20260706-000537-gh26635 runner_key=runner-test"}]'
	AIDEVOPS_RUNNER_IDENTITY_KEY="runner-test" \
		TEST_GH_COMMENTS_JSON="$comments_json" \
		AIDEVOPS_DIRTY_WORKTREE_NOW_EPOCH="1783291032" \
		DISPATCH_DIRTY_WORKTREE_HOLD_SECONDS="21600" \
		_dispatch_recent_dirty_worktree_marker_active "26635" "marcusquinn/aidevops"
	local rc=$?
	local marker_runner_key="${_DISPATCH_DIRTY_MARKER_STATE##*runner_key=}"
	if [[ "$rc" -eq 0 && "$marker_runner_key" == "runner-test" ]]; then
		print_result "active marker identifies owning runner for resume" 0
		return 0
	fi
	print_result "active marker identifies owning runner for resume" 1 "state=${_DISPATCH_DIRTY_MARKER_STATE} rc=${rc}"
	return 0
}

test_same_runner_skip_gate_proceeds() {
	local comments_json='[{"created_at":"2026-07-05T22:22:12Z","body":"WORKER_DIRTY_WORKTREE branch=feature/auto-20260706-000537-gh26635 runner_key=runner-test"}]'
	set +e
	AIDEVOPS_RUNNER_IDENTITY_KEY="runner-test" \
		TEST_GH_COMMENTS_JSON="$comments_json" \
		AIDEVOPS_DIRTY_WORKTREE_NOW_EPOCH="1783291032" \
		DISPATCH_DIRTY_WORKTREE_HOLD_SECONDS="21600" \
		_dispatch_skip_for_dirty_worktree_recovery "26635" "marcusquinn/aidevops"
	local rc=$?
	set -e
	if [[ "$rc" -eq 1 ]]; then
		print_result "same-runner dirty marker proceeds to worker resume" 0
		return 0
	fi
	print_result "same-runner dirty marker proceeds to worker resume" 1 "rc=${rc}"
	return 0
}

test_marker_without_runner_key_stays_blocked() {
	_dispatch_recent_dirty_worktree_marker_active() {
		_DISPATCH_DIRTY_MARKER_STATE="block:age=0"
		return 0
	}
	set +e
	AIDEVOPS_RUNNER_IDENTITY_KEY="block:age=0" \
		_dispatch_skip_for_dirty_worktree_recovery "26635" "marcusquinn/aidevops"
	local rc=$?
	set -e
	unset -f _dispatch_recent_dirty_worktree_marker_active
	if [[ "$rc" -eq 0 ]]; then
		print_result "marker without runner key cannot impersonate owning runner" 0
		return 0
	fi
	print_result "marker without runner key cannot impersonate owning runner" 1 "state=${_DISPATCH_DIRTY_MARKER_STATE} rc=${rc}"
	return 0
}

test_dirty_worktree_reuse_preserves_edits() {
	git() { /usr/bin/git "$@"; }
	local fixture_root=""
	fixture_root=$(mktemp -d)
	fixture_root=$(cd "$fixture_root" && pwd -P)
	local origin_dir="${fixture_root}/origin.git"
	local repo_dir="${fixture_root}/repo"
	local worktree_dir="${fixture_root}/dirty-worktree"
	git init --bare "$origin_dir" >/dev/null 2>&1
	git clone "$origin_dir" "$repo_dir" >/dev/null 2>&1
	git -C "$repo_dir" config user.email "worker@example.invalid"
	git -C "$repo_dir" config user.name "Worker Test"
	git -C "$repo_dir" config commit.gpgsign false
	git -C "$repo_dir" checkout -b main >/dev/null 2>&1
	printf 'base\n' >"${repo_dir}/tracked.txt"
	git -C "$repo_dir" add tracked.txt
	git -C "$repo_dir" commit -m "test: seed" >/dev/null 2>&1
	git -C "$repo_dir" push -u origin main >/dev/null 2>&1
	git -C "$repo_dir" worktree add -b "feature/auto-test-gh26635" "$worktree_dir" main >/dev/null 2>&1
	printf 'staged\n' >"${worktree_dir}/tracked.txt"
	git -C "$worktree_dir" add tracked.txt
	printf 'unstaged\n' >>"${worktree_dir}/tracked.txt"
	printf 'untracked\n' >"${worktree_dir}/new.txt"
	local status_before=""
	status_before=$(git -C "$worktree_dir" status --porcelain)

	local test_script_dir="$SCRIPT_DIR"
	SCRIPT_DIR="${test_script_dir}/.."
	_dlw_precreate_worktree "26635" "$repo_dir"
	SCRIPT_DIR="$test_script_dir"
	local status_after=""
	status_after=$(git -C "$worktree_dir" status --porcelain)
	local result=0
	[[ "$_DLW_WORKTREE_REUSED" == "1" && "$_DLW_WORKTREE_PATH" == "$worktree_dir" && "$status_after" == "$status_before" ]] || result=1
	print_result "same-runner worktree reuse preserves staged, unstaged, and untracked edits" "$result" "before='${status_before}' after='${status_after}' reused=${_DLW_WORKTREE_REUSED}"
	rm -rf "$fixture_root"
	unset -f git
	return 0
}

test_later_resolution_clears_marker() {
	local comments_json='[{"created_at":"2026-07-05T22:22:12Z","body":"WORKER_DIRTY_WORKTREE branch=feature/auto-20260706-000537-gh26635"},{"created_at":"2026-07-05T22:40:00Z","body":"<!-- worker-dirty-worktree:resolved --> recovered into PR #26666"}]'
	set +e
	TEST_GH_COMMENTS_JSON="$comments_json" \
		AIDEVOPS_DIRTY_WORKTREE_NOW_EPOCH="1783291032" \
		DISPATCH_DIRTY_WORKTREE_HOLD_SECONDS="21600" \
		_dispatch_recent_dirty_worktree_marker_active "26635" "marcusquinn/aidevops"
	local rc=$?
	set -e
	if [[ "$rc" -eq 1 ]]; then
		print_result "later resolution clears dirty marker" 0
		return 0
	fi
	print_result "later resolution clears dirty marker" 1 "expected resolved marker to fail open"
	return 0
}

test_expired_marker_does_not_block() {
	local comments_json='[{"created_at":"2026-07-05T22:22:12Z","body":"WORKER_DIRTY_WORKTREE branch=feature/auto-20260706-000537-gh26635"}]'
	set +e
	TEST_GH_COMMENTS_JSON="$comments_json" \
		AIDEVOPS_DIRTY_WORKTREE_NOW_EPOCH="1783377432" \
		DISPATCH_DIRTY_WORKTREE_HOLD_SECONDS="21600" \
		_dispatch_recent_dirty_worktree_marker_active "26635" "marcusquinn/aidevops"
	local rc=$?
	set -e
	if [[ "$rc" -eq 1 ]]; then
		print_result "expired dirty marker does not block" 0
		return 0
	fi
	print_result "expired dirty marker does not block" 1 "expected expired marker to allow dispatch"
	return 0
}

test_large_comment_payload_uses_stream_transport() {
	local padding=""
	padding=$(python3 -c 'print("x" * 150000)')
	TEST_GH_COMMENTS_JSON="[{\"created_at\":\"2026-07-05T22:22:12Z\",\"body\":\"WORKER_DIRTY_WORKTREE runner_key=runner-large ${padding}\"}]"
	set +e
	AIDEVOPS_DIRTY_WORKTREE_NOW_EPOCH="1783291032" \
		DISPATCH_DIRTY_WORKTREE_HOLD_SECONDS="21600" \
		_dispatch_recent_dirty_worktree_marker_active "26635" "marcusquinn/aidevops"
	local rc=$?
	set -e
	TEST_GH_COMMENTS_JSON="[]"
	if [[ "$rc" -eq 0 && "$_DISPATCH_DIRTY_MARKER_STATE" == *"runner_key=runner-large" ]]; then
		print_result "large comment payload avoids exec environment limits" 0
		return 0
	fi
	print_result "large comment payload avoids exec environment limits" 1 \
		"state=${_DISPATCH_DIRTY_MARKER_STATE} rc=${rc}"
	return 0
}

test_prelaunch_lease_failure_logs_durable_reason() {
	local fixture_dir=""
	fixture_dir=$(mktemp -d)
	local worker_log="${fixture_dir}/worker.log"
	local pulse_log="${fixture_dir}/pulse.log"
	local original_logfile="$LOGFILE"
	cat >"${fixture_dir}/dispatch-claim-helper.sh" <<'STUB'
#!/usr/bin/env bash
exit 7
STUB
	chmod +x "${fixture_dir}/dispatch-claim-helper.sh"
	local original_script_dir="$SCRIPT_DIR"
	SCRIPT_DIR="$fixture_dir"
	LOGFILE="$pulse_log"
	_claim_lease_token="secret-token-must-not-appear"
	_claim_lease_device="test-device"
	set +e
	_dlw_renew_prelaunch_lease "26635" "marcusquinn/aidevops" \
		"session-test" "$worker_log"
	local rc=$?
	set -e
	SCRIPT_DIR="$original_script_dir"
	LOGFILE="$original_logfile"
	unset _claim_lease_token _claim_lease_device
	local result=0
	[[ "$rc" -eq 1 ]] || result=1
	grep -q 'issue=26635 repo=marcusquinn/aidevops session=session-test helper_rc=7' \
		"$worker_log" || result=1
	grep -q 'issue=26635 repo=marcusquinn/aidevops session=session-test helper_rc=7' \
		"$pulse_log" || result=1
	if grep -q 'secret-token-must-not-appear' "$worker_log" "$pulse_log"; then
		result=1
	fi
	print_result "prelaunch lease failure is durable without token disclosure" \
		"$result" "rc=${rc}"
	rm -rf "$fixture_dir"
	return 0
}

test_expired_marker_clears_once_with_audit() {
	local marker='{"created_at":"2026-07-05T22:22:12Z","body":"WORKER_DIRTY_WORKTREE branch=feature/auto-20260706-000537-gh26635 runner_key=runner-other"}'
	TEST_GH_POST_COUNT=0
	set +e
	TEST_GH_COMMENTS_JSON="[${marker}]" \
		AIDEVOPS_DIRTY_WORKTREE_NOW_EPOCH="1783377432" \
		DISPATCH_DIRTY_WORKTREE_HOLD_SECONDS="21600" \
		_dispatch_skip_for_dirty_worktree_recovery "26635" "marcusquinn/aidevops"
	local first_rc=$?
	set -e
	local resolution='{"created_at":"2026-07-07T22:40:00Z","body":"<!-- worker-dirty-worktree:resolved --> WORKER_DIRTY_WORKTREE_RESOLVED"}'
	set +e
	TEST_GH_COMMENTS_JSON="[${marker},${resolution}]" \
		AIDEVOPS_DIRTY_WORKTREE_NOW_EPOCH="1783377432" \
		DISPATCH_DIRTY_WORKTREE_HOLD_SECONDS="21600" \
		_dispatch_skip_for_dirty_worktree_recovery "26635" "marcusquinn/aidevops"
	local second_rc=$?
	set -e
	if [[ "$first_rc" -eq 1 && "$second_rc" -eq 1 && "$TEST_GH_POST_COUNT" -eq 1 ]]; then
		print_result "expired unrecoverable marker clears once with audit evidence" 0
		return 0
	fi
	print_result "expired unrecoverable marker clears once with audit evidence" 1 "first=${first_rc} second=${second_rc} posts=${TEST_GH_POST_COUNT}"
	return 0
}

main() {
	load_lib
	test_recent_marker_blocks_dispatch
	test_same_runner_marker_allows_resume
	test_same_runner_skip_gate_proceeds
	test_dirty_worktree_reuse_preserves_edits
	test_later_resolution_clears_marker
	test_expired_marker_does_not_block
	test_large_comment_payload_uses_stream_transport
	test_prelaunch_lease_failure_logs_durable_reason
	test_expired_marker_clears_once_with_audit
	test_marker_without_runner_key_stays_blocked

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
