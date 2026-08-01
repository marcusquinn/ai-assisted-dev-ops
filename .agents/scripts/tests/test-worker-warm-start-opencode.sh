#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-worker-warm-start-opencode.sh — Regression tests for t2758 (GH#20562)
#
# Verifies that the OpenCode pre-warm logic in _dlw_nohup_launch:
#   1. Runs opencode --version against the isolated DB dir before nohup launch.
#   2. Logs opencode_warm_start + opencode_warm_done lifecycle markers.
#   3. Sets AIDEVOPS_WORKER_PREWARM_DIR for the runtime invoke module.
#   4. Handles warm-up failure non-fatally (dispatch continues without prewarm).
#   5. Skips warm-up when opencode binary is absent (non-opencode runtimes).
#
# Acceptance criteria (GH#20562):
#   AC1: Worker launch runs opencode --version against worker's isolated DB dir.
#   AC2: Warm-up failure logs WARN but does NOT abort dispatch.
#   AC3: Lifecycle markers opencode_warm_start / opencode_warm_done are separate.
#   AC4: Regression test exercises: present for opencode, absent otherwise.
#   AC5: (Operational — verified via log grep, not a unit test.)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
TEST_DIR=""

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		echo "PASS $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo "FAIL $test_name"
		if [[ -n "$message" ]]; then
			echo "  $message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup() {
	TEST_DIR=$(mktemp -d)
	trap teardown EXIT
	return 0
}

teardown() {
	if [[ -n "$TEST_DIR" && -d "$TEST_DIR" ]]; then
		rm -rf "$TEST_DIR"
	fi
	return 0
}

# Create a mock opencode binary that exits 0 and prints a version.
make_mock_opencode_ok() {
	local bin_dir="$1"
	mkdir -p "$bin_dir"
	cat >"${bin_dir}/opencode" <<'MOCK'
#!/usr/bin/env bash
echo "opencode 0.0.0-mock"
exit 0
MOCK
	chmod +x "${bin_dir}/opencode"
	return 0
}

# Create a mock opencode binary that exits non-zero (simulates failure).
make_mock_opencode_fail() {
	local bin_dir="$1"
	mkdir -p "$bin_dir"
	cat >"${bin_dir}/opencode" <<'MOCK'
#!/usr/bin/env bash
exit 1
MOCK
	chmod +x "${bin_dir}/opencode"
	return 0
}

# Run the pre-warm block in isolation by sourcing just that logic.
# Returns 0 if the block completed, non-zero if it errored.
# Writes lifecycle markers + sets PREWARM_DIR_OUT.
# Args: bin_dir (directory with mock opencode, or "NONE" to hide opencode)
#       worker_log (path to write lifecycle markers)
run_prewarm_block() {
	local bin_dir="$1"    # dir with mock opencode, or "NONE" to suppress opencode
	local worker_log="$2"

	# Run the pre-warm block extracted from _dlw_nohup_launch (t2758).
	# PATH is scoped to this subshell — does not pollute the outer process.
	local prewarm_dir=""
	(
		if [[ "$bin_dir" == "NONE" ]]; then
			# Use only /bin:/usr/bin so real opencode (in /usr/local/bin etc.) is hidden
			export PATH="/bin:/usr/bin"
		elif [[ -n "$bin_dir" ]]; then
			export PATH="${bin_dir}:${PATH}"
		fi
		local worker_prewarm_dir=""
		if command -v opencode >/dev/null 2>&1; then
			worker_prewarm_dir=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-worker-auth.XXXXXX") || worker_prewarm_dir=""
			if [[ -n "$worker_prewarm_dir" ]]; then
				mkdir -p "${worker_prewarm_dir}/opencode"
				{
					echo "[lifecycle] opencode_warm_start pid=$$"
					if XDG_DATA_HOME="$worker_prewarm_dir" timeout 30 opencode --version >/dev/null 2>&1; then
						echo "[lifecycle] opencode_warm_done pid=$$"
					else
						echo "[lifecycle] WARN opencode warm-up failed or timed out — fallback to cold-start pid=$$"
						rm -rf "$worker_prewarm_dir" 2>/dev/null || true
						worker_prewarm_dir=""
					fi
				} >>"$worker_log" 2>&1
			fi
		fi
		# Signal result to outer shell via a known temp file
		printf '%s' "$worker_prewarm_dir" >"${worker_log}.prewarm_dir"
	)
	return 0
}

# ---------------------------------------------------------------------------
# Test: warm-up runs and lifecycle markers are written when opencode is present
# ---------------------------------------------------------------------------
test_warm_up_present_on_opencode() {
	local bin_dir="${TEST_DIR}/bin_ok"
	local worker_log="${TEST_DIR}/worker.log"
	: >"$worker_log"
	make_mock_opencode_ok "$bin_dir"

	run_prewarm_block "$bin_dir" "$worker_log"

	local rc=0

	# Check lifecycle markers appear in worker_log
	if ! grep -q "opencode_warm_start" "$worker_log"; then
		print_result "warm_start_marker_present" 1 "opencode_warm_start not found in worker_log"
		rc=1
	else
		print_result "warm_start_marker_present" 0
	fi

	if ! grep -q "opencode_warm_done" "$worker_log"; then
		print_result "warm_done_marker_present" 1 "opencode_warm_done not found in worker_log"
		rc=1
	else
		print_result "warm_done_marker_present" 0
	fi

	# WARN marker must NOT appear on success
	if grep -q "WARN.*warm-up" "$worker_log"; then
		print_result "no_warn_on_success" 1 "WARN marker unexpectedly present in worker_log"
		rc=1
	else
		print_result "no_warn_on_success" 0
	fi

	# Pre-warmed dir must have been created
	local prewarm_dir=""
	prewarm_dir=$(cat "${worker_log}.prewarm_dir" 2>/dev/null || true)
	if [[ -z "$prewarm_dir" ]]; then
		print_result "prewarm_dir_created" 1 "prewarm_dir not set (expected non-empty)"
		rc=1
	else
		print_result "prewarm_dir_created" 0
	fi

	# Cleanup
	[[ -n "$prewarm_dir" && -d "$prewarm_dir" ]] && rm -rf "$prewarm_dir"
	if [[ "$rc" -eq 0 ]]; then return 0; fi
	return 1
}

# ---------------------------------------------------------------------------
# Test: warm-up absent when opencode binary is not in PATH
# ---------------------------------------------------------------------------
test_warm_up_absent_without_opencode() {
	local worker_log="${TEST_DIR}/worker_no_oc.log"
	: >"$worker_log"

	# Run with a minimal PATH that excludes opencode (regardless of install state)
	run_prewarm_block "NONE" "$worker_log"

	local rc=0

	# No lifecycle markers should appear
	if grep -q "opencode_warm_start" "$worker_log"; then
		print_result "no_warm_start_without_opencode" 1 "opencode_warm_start unexpectedly present"
		rc=1
	else
		print_result "no_warm_start_without_opencode" 0
	fi

	if grep -q "opencode_warm_done" "$worker_log"; then
		print_result "no_warm_done_without_opencode" 1 "opencode_warm_done unexpectedly present"
		rc=1
	else
		print_result "no_warm_done_without_opencode" 0
	fi

	# prewarm_dir must be empty (no opencode → no dir created)
	local prewarm_dir=""
	prewarm_dir=$(cat "${worker_log}.prewarm_dir" 2>/dev/null || true)
	if [[ -n "$prewarm_dir" ]]; then
		print_result "no_prewarm_dir_without_opencode" 1 "prewarm_dir unexpectedly set: $prewarm_dir"
		rc=1
	else
		print_result "no_prewarm_dir_without_opencode" 0
	fi

	if [[ "$rc" -eq 0 ]]; then return 0; fi
	return 1
}

# ---------------------------------------------------------------------------
# Test: warm-up failure is non-fatal; WARN is logged; prewarm_dir cleared
# ---------------------------------------------------------------------------
test_warm_up_failure_nonfatal() {
	local bin_dir="${TEST_DIR}/bin_fail"
	local worker_log="${TEST_DIR}/worker_fail.log"
	: >"$worker_log"
	make_mock_opencode_fail "$bin_dir"

	run_prewarm_block "$bin_dir" "$worker_log"

	local rc=0

	# warm_start should appear (was logged before the failure)
	if ! grep -q "opencode_warm_start" "$worker_log"; then
		print_result "warm_start_logged_before_failure" 1 "opencode_warm_start not found"
		rc=1
	else
		print_result "warm_start_logged_before_failure" 0
	fi

	# WARN marker must appear
	if ! grep -q "WARN.*warm-up" "$worker_log"; then
		print_result "warn_marker_on_failure" 1 "WARN marker not found in worker_log"
		rc=1
	else
		print_result "warn_marker_on_failure" 0
	fi

	# opencode_warm_done must NOT appear on failure
	if grep -q "opencode_warm_done" "$worker_log"; then
		print_result "no_warm_done_on_failure" 1 "opencode_warm_done unexpectedly present"
		rc=1
	else
		print_result "no_warm_done_on_failure" 0
	fi

	# prewarm_dir must be cleared on failure (so dispatch falls back to mktemp)
	local prewarm_dir=""
	prewarm_dir=$(cat "${worker_log}.prewarm_dir" 2>/dev/null || true)
	if [[ -n "$prewarm_dir" ]]; then
		print_result "prewarm_dir_cleared_on_failure" 1 "prewarm_dir not cleared: $prewarm_dir"
		rc=1
	else
		print_result "prewarm_dir_cleared_on_failure" 0
	fi

	if [[ "$rc" -eq 0 ]]; then return 0; fi
	return 1
}

# ---------------------------------------------------------------------------
# Test: the runtime invoke module honours AIDEVOPS_WORKER_PREWARM_DIR
# ---------------------------------------------------------------------------
test_headless_runtime_honours_prewarm_dir() {
	# Verify the extracted OpenCode invoke source contains the t2758 prewarm check.
	local invoke_path="$SCRIPT_DIR/../headless-runtime-invoke.sh"
	if [[ ! -f "$invoke_path" ]]; then
		print_result "prewarm_dir_check_in_invoke" 1 "headless-runtime-invoke.sh not found at $invoke_path"
		return 1
	fi

	local rc=0
	# Check for the t2758 env var reuse block
	if ! grep -q "AIDEVOPS_WORKER_PREWARM_DIR" "$invoke_path"; then
		print_result "prewarm_env_var_in_invoke" 1 "AIDEVOPS_WORKER_PREWARM_DIR not found in headless-runtime-invoke.sh"
		rc=1
	else
		print_result "prewarm_env_var_in_invoke" 0
	fi

	# Check for the opencode_warm_done lifecycle marker in the invoke module
	if ! grep -q "opencode_warm_done" "$invoke_path"; then
		print_result "warm_done_marker_in_invoke" 1 "opencode_warm_done not found in headless-runtime-invoke.sh"
		rc=1
	else
		print_result "warm_done_marker_in_invoke" 0
	fi

	if [[ "$rc" -eq 0 ]]; then return 0; fi
	return 1
}

# ---------------------------------------------------------------------------
# Test: pulse-dispatch-worker-launch.sh contains the warm-up logic
# ---------------------------------------------------------------------------
test_launch_script_has_prewarm() {
	local launch_path="$SCRIPT_DIR/../pulse-dispatch-worker-launch.sh"
	if [[ ! -f "$launch_path" ]]; then
		print_result "launch_script_found" 1 "pulse-dispatch-worker-launch.sh not found at $launch_path"
		return 1
	fi

	local rc=0
	if ! grep -q "opencode_warm_start" "$launch_path"; then
		print_result "warm_start_in_launch_script" 1 "opencode_warm_start not found in pulse-dispatch-worker-launch.sh"
		rc=1
	else
		print_result "warm_start_in_launch_script" 0
	fi

	if ! grep -q "AIDEVOPS_WORKER_PREWARM_DIR" "$launch_path"; then
		print_result "prewarm_env_var_in_launch_script" 1 "AIDEVOPS_WORKER_PREWARM_DIR not found in pulse-dispatch-worker-launch.sh"
		rc=1
	else
		print_result "prewarm_env_var_in_launch_script" 0
	fi

	local renew_line prewarm_line
	# shellcheck disable=SC2016 # Match literal runtime variables in helper source.
	renew_line=$(grep -n '_dlw_renew_prelaunch_lease "\$issue_number"' "$launch_path" | tail -1 | cut -d: -f1)
	# shellcheck disable=SC2016 # Match literal runtime variables in helper source.
	prewarm_line=$(grep -n '_dlw_prewarm_opencode_db "\$worker_log"' "$launch_path" | tail -1 | cut -d: -f1)
	if [[ -z "$renew_line" || -z "$prewarm_line" || "$renew_line" -ge "$prewarm_line" ]]; then
		print_result "prelaunch_lease_renewed_before_prewarm" 1 \
			"renew_line=${renew_line:-missing}, prewarm_line=${prewarm_line:-missing}"
		rc=1
	else
		print_result "prelaunch_lease_renewed_before_prewarm" 0
	fi

	if [[ "$rc" -eq 0 ]]; then return 0; fi
	return 1
}

# ---------------------------------------------------------------------------
# Test: canary preflight runs before expensive worktree pre-creation
# ---------------------------------------------------------------------------
test_launch_script_fast_fails_before_prewarm() {
	local launch_path="$SCRIPT_DIR/../pulse-dispatch-worker-launch.sh"
	local helper_path="$SCRIPT_DIR/../headless-runtime-helper.sh"
	if [[ ! -f "$launch_path" || ! -f "$helper_path" ]]; then
		print_result "canary_preflight_files_found" 1 "launch/helper script missing"
		return 1
	fi

	local rc=0
	if ! grep -q "canary_preflight" "$launch_path"; then
		print_result "canary_preflight_stage_present" 1 "canary_preflight stage not found"
		rc=1
	else
		print_result "canary_preflight_stage_present" 0
	fi

	local canary_line precreate_line
	canary_line=$(grep -n "_dlw_canary_preflight" "$launch_path" | tail -1 | cut -d: -f1)
	precreate_line=$(grep -n "_dlw_precreate_worktree" "$launch_path" | tail -1 | cut -d: -f1)
	if [[ -z "$canary_line" || -z "$precreate_line" || "$canary_line" -ge "$precreate_line" ]]; then
		print_result "canary_before_worktree_precreate" 1 "canary_line=${canary_line:-missing}, precreate_line=${precreate_line:-missing}"
		rc=1
	else
		print_result "canary_before_worktree_precreate" 0
	fi

	if ! grep -q "cmd_canary" "$helper_path"; then
		print_result "headless_canary_command_present" 1 "cmd_canary not found in headless-runtime-helper.sh"
		rc=1
	else
		print_result "headless_canary_command_present" 0
	fi

	if [[ "$rc" -eq 0 ]]; then return 0; fi
	return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
	setup

	echo "=== test-worker-warm-start-opencode.sh (t2758 / GH#20562) ==="

	test_warm_up_present_on_opencode
	test_warm_up_absent_without_opencode
	test_warm_up_failure_nonfatal
	test_headless_runtime_honours_prewarm_dir
	test_launch_script_has_prewarm
	test_launch_script_fast_fails_before_prewarm

	echo ""
	echo "Results: ${TESTS_PASSED}/${TESTS_RUN} passed, ${TESTS_FAILED} failed"

	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
