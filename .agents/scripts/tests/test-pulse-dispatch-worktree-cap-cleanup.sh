#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for guarded cleanup at the Pulse worktree cap (GH#30032).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
CORE_SCRIPT="${SCRIPT_DIR}/../pulse-dispatch-core.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
LOGFILE="${TEST_ROOT}/pulse.log"
AIDEVOPS_WORKTREE_HELPER="${TEST_ROOT}/worktree-helper.sh"
FAKE_ARGS_FILE="${TEST_ROOT}/helper.args"
FAKE_COUNT_FILE="${TEST_ROOT}/worktree.count"
# shellcheck disable=SC2016 # The generated fixture expands these variables when executed.
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >"$FAKE_ARGS_FILE"\nif [[ "${FAKE_REMOVE_COUNT:-0}" == "1" ]]; then rm -f "$FAKE_COUNT_FILE"; elif [[ -n "${FAKE_AFTER_COUNT:-}" ]]; then printf "%%s\\n" "$FAKE_AFTER_COUNT" >"$FAKE_COUNT_FILE"; fi\nexit 0\n' >"$AIDEVOPS_WORKTREE_HELPER"
chmod +x "$AIDEVOPS_WORKTREE_HELPER"
export FAKE_ARGS_FILE FAKE_COUNT_FILE

TESTS_RUN=0
TESTS_FAILED=0
COUNT_FAIL=0
GIT_MODE="valid"
STAGE_TIMEOUT=""
STAGE_RC=0
DISK_MODE="blocked"
CLEANUP_RUNS=0

print_result() {
	local name="$1"
	local status="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		printf 'PASS %s\n' "$name"
	else
		printf 'FAIL %s\n' "$name"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

extract_helper() {
	local name="$1"
	awk -v function_name="$name" '
		$0 ~ "^" function_name "\\(\\) \\{" { capture=1 }
		capture { print }
		capture && /^}$/ { exit }
	' "$CORE_SCRIPT"
	return 0
}

PRODUCTION_COUNT_HELPER=$(extract_helper _dispatch_registered_worktree_count)
eval "$PRODUCTION_COUNT_HELPER"
eval "${PRODUCTION_COUNT_HELPER/_dispatch_registered_worktree_count/_production_dispatch_registered_worktree_count}"
eval "$(extract_helper _dispatch_run_guarded_worktree_cleanup)"
eval "$(extract_helper _dispatch_cleanup_worktree_capacity)"
eval "$(extract_helper _dispatch_worktree_capacity_gate)"
eval "$(extract_helper _dispatch_run_guarded_disk_cleanup)"
eval "$(extract_helper _dispatch_cleanup_disk_pressure)"

git() {
	case "$GIT_MODE" in
	nonzero) return 2 ;;
	empty) return 0 ;;
	valid) printf '/repo/main\n/repo/linked\n' ;;
	*) return 3 ;;
	esac
}

_dispatch_registered_worktree_count() {
	[[ "$COUNT_FAIL" -eq 0 ]] || return 1
	[[ -f "$FAKE_COUNT_FILE" ]] || return 1
	local count=""
	count=$(<"$FAKE_COUNT_FILE")
	printf '%s\n' "$count"
	return 0
}

run_stage_with_timeout() {
	local stage_name="$1"
	local rc=0
	STAGE_TIMEOUT="$2"
	shift 2
	[[ "$stage_name" == "dispatch_worktree_capacity_cleanup" || "$stage_name" == "dispatch_disk_pressure_cleanup" ]] || return 2
	[[ "$STAGE_RC" -eq 0 ]] || return "$STAGE_RC"
	"$@" || rc=$?
	return "$rc"
}

cleanup_worktrees() {
	CLEANUP_RUNS=$((CLEANUP_RUNS + 1))
	if [[ "$DISK_MODE" == "recover" ]]; then
		DISK_MODE="available"
	fi
	return 0
}

aidevops_worktree_capacity_check() {
	case "$DISK_MODE" in
	available)
		AIDEVOPS_DISK_CAPACITY_REASON="available"
		AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB=6291456
		AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT=6
		return 0
		;;
	unknown)
		AIDEVOPS_DISK_CAPACITY_REASON="capacity-unknown"
		AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB=0
		AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT=0
		return 2
		;;
	*)
		AIDEVOPS_DISK_CAPACITY_REASON="below-minimum-percent"
		AIDEVOPS_DISK_CAPACITY_AVAILABLE_KB=4194304
		AIDEVOPS_DISK_CAPACITY_AVAILABLE_PERCENT=4
		return 1
		;;
	esac
}

test_cleanup_recovers_capacity() {
	printf '200\n' >"$FAKE_COUNT_FILE"
	FAKE_AFTER_COUNT=199
	FAKE_REMOVE_COUNT=0
	export FAKE_AFTER_COUNT FAKE_REMOVE_COUNT
	COUNT_FAIL=0
	STAGE_TIMEOUT=""
	STAGE_RC=0
	rm -f "$FAKE_ARGS_FILE"
	AIDEVOPS_DISPATCH_WORKTREE_CLEANUP_TIMEOUT=17
	if _dispatch_worktree_capacity_gate "$TEST_ROOT" 30032 "owner/repo" 200 &&
		[[ "$STAGE_TIMEOUT" == "17" ]] &&
		[[ "$(<"$FAKE_ARGS_FILE")" == "clean --auto --force-merged" ]] &&
		[[ "$(<"$FAKE_COUNT_FILE")" == "199" ]] &&
		grep -q "recovered dispatch capacity.*200 -> 199" "$LOGFILE"; then
		print_result "cap gate invokes guarded cleanup and proceeds after recount" 0
	else
		print_result "cap gate invokes guarded cleanup and proceeds after recount" 1
	fi
	return 0
}

test_cleanup_fails_closed_without_reduction() {
	printf '200\n' >"$FAKE_COUNT_FILE"
	FAKE_AFTER_COUNT=200
	FAKE_REMOVE_COUNT=0
	export FAKE_AFTER_COUNT FAKE_REMOVE_COUNT
	COUNT_FAIL=0
	STAGE_RC=0
	if _dispatch_worktree_capacity_gate "$TEST_ROOT" 30032 "owner/repo" 200; then
		print_result "cleanup remains fail-closed when count stays at cap" 1
	elif grep -q "could not recover dispatch capacity.*200 -> 200.*safety gates preserved" "$LOGFILE"; then
		print_result "cleanup remains fail-closed when count stays at cap" 0
	else
		print_result "cleanup remains fail-closed when count stays at cap" 1
	fi
	return 0
}

test_timeout_remains_fail_closed() {
	printf '200\n' >"$FAKE_COUNT_FILE"
	FAKE_AFTER_COUNT=""
	FAKE_REMOVE_COUNT=0
	export FAKE_AFTER_COUNT FAKE_REMOVE_COUNT
	COUNT_FAIL=0
	STAGE_RC=124
	if _dispatch_worktree_capacity_gate "$TEST_ROOT" 30032 "owner/repo" 200; then
		print_result "timed-out cleanup remains fail-closed" 1
	elif grep -q "cleanup_rc=124" "$LOGFILE"; then
		print_result "timed-out cleanup remains fail-closed" 0
	else
		print_result "timed-out cleanup remains fail-closed" 1
	fi
	STAGE_RC=0
	return 0
}

test_production_count_probe_validation() {
	local count=""
	GIT_MODE="valid"
	count=$(_production_dispatch_registered_worktree_count "$TEST_ROOT") || count="failed"
	if [[ "$count" == "2" ]]; then
		print_result "production counter counts verified Git inventory" 0
	else
		print_result "production counter counts verified Git inventory" 1
	fi
	GIT_MODE="empty"
	if _production_dispatch_registered_worktree_count "$TEST_ROOT" >/dev/null; then
		print_result "production counter rejects empty Git inventory" 1
	else
		print_result "production counter rejects empty Git inventory" 0
	fi
	GIT_MODE="nonzero"
	if _production_dispatch_registered_worktree_count "$TEST_ROOT" >/dev/null; then
		print_result "production counter propagates Git failure" 1
	else
		print_result "production counter propagates Git failure" 0
	fi
	GIT_MODE="valid"
	return 0
}

test_post_cleanup_recount_failure_remains_fail_closed() {
	printf '200\n' >"$FAKE_COUNT_FILE"
	FAKE_AFTER_COUNT=""
	FAKE_REMOVE_COUNT=1
	export FAKE_AFTER_COUNT FAKE_REMOVE_COUNT
	COUNT_FAIL=0
	STAGE_RC=0
	if _dispatch_worktree_capacity_gate "$TEST_ROOT" 30032 "owner/repo" 200; then
		print_result "post-cleanup recount failure remains fail-closed" 1
	elif grep -q "could not verify the post-cleanup worktree count" "$LOGFILE"; then
		print_result "post-cleanup recount failure remains fail-closed" 0
	else
		print_result "post-cleanup recount failure remains fail-closed" 1
	fi
	FAKE_REMOVE_COUNT=0
	export FAKE_REMOVE_COUNT
	return 0
}

test_count_probe_failure_remains_fail_closed() {
	COUNT_FAIL=1
	if _dispatch_worktree_capacity_gate "$TEST_ROOT" 30032 "owner/repo" 200; then
		print_result "worktree count probe failure remains fail-closed" 1
	elif grep -q "unable to verify registered worktree count" "$LOGFILE"; then
		print_result "worktree count probe failure remains fail-closed" 0
	else
		print_result "worktree count probe failure remains fail-closed" 1
	fi
	COUNT_FAIL=0
	return 0
}

test_missing_bounded_runner_fails_closed() {
	local runner_definition
	runner_definition=$(declare -f run_stage_with_timeout)
	unset -f run_stage_with_timeout
	printf '200\n' >"$FAKE_COUNT_FILE"
	if _dispatch_cleanup_worktree_capacity "$TEST_ROOT" 30032 "owner/repo" 200 200; then
		print_result "missing bounded runner fails closed" 1
	elif grep -q "bounded stage runner missing" "$LOGFILE"; then
		print_result "missing bounded runner fails closed" 0
	else
		print_result "missing bounded runner fails closed" 1
	fi
	eval "$runner_definition"
	return 0
}

test_disk_cleanup_recovers_capacity_once() {
	AIDEVOPS_DISPATCH_DISK_PRESSURE_CLEANUP_ATTEMPTED=0
	AIDEVOPS_DISPATCH_DISK_CLEANUP_TIMEOUT=19
	DISK_MODE="recover"
	CLEANUP_RUNS=0
	STAGE_TIMEOUT=""
	STAGE_RC=0
	if _dispatch_cleanup_disk_pressure 30886 "owner/repo" "$TEST_ROOT" "below-minimum-percent" 4194304 4 &&
		[[ "$CLEANUP_RUNS" -eq 1 ]] &&
		[[ "$STAGE_TIMEOUT" == "19" ]] &&
		grep -q "recovered dispatch capacity.*4194304KB/4% -> 6291456KB/6%" "$LOGFILE"; then
		print_result "disk gate invokes one guarded cleanup and proceeds after capacity recheck" 0
	else
		print_result "disk gate invokes one guarded cleanup and proceeds after capacity recheck" 1
	fi
	return 0
}

test_disk_cleanup_remains_fail_closed_and_is_cycle_scoped() {
	AIDEVOPS_DISPATCH_DISK_PRESSURE_CLEANUP_ATTEMPTED=0
	DISK_MODE="blocked"
	CLEANUP_RUNS=0
	STAGE_RC=0
	if _dispatch_cleanup_disk_pressure 30886 "owner/repo" "$TEST_ROOT" "below-minimum-percent" 4194304 4; then
		print_result "disk cleanup remains fail-closed when capacity stays blocked" 1
	elif _dispatch_cleanup_disk_pressure 30887 "owner/repo" "$TEST_ROOT" "below-minimum-percent" 4194304 4; then
		print_result "disk cleanup runs only once per Pulse cycle" 1
	elif [[ "$CLEANUP_RUNS" -eq 1 ]] &&
		grep -q "cleanup_rc=0, capacity_rc=1" "$LOGFILE" &&
		grep -q "already attempted this Pulse cycle" "$LOGFILE"; then
		print_result "disk cleanup remains fail-closed and runs only once per Pulse cycle" 0
	else
		print_result "disk cleanup remains fail-closed and runs only once per Pulse cycle" 1
	fi
	STAGE_RC=0
	return 0
}

main() {
	test_cleanup_recovers_capacity
	test_cleanup_fails_closed_without_reduction
	test_timeout_remains_fail_closed
	test_production_count_probe_validation
	test_post_cleanup_recount_failure_remains_fail_closed
	test_count_probe_failure_remains_fail_closed
	test_missing_bounded_runner_fails_closed
	test_disk_cleanup_recovers_capacity_once
	test_disk_cleanup_remains_fail_closed_and_is_cycle_scoped

	printf 'Ran %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi
	return 1
}

main "$@"
