#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-audit-log-helper.sh — Tests for tamper-evident audit logging (t1412.8)
#
# Exercises:
#   1. Basic logging (all event types)
#   2. Hash chain integrity (verify passes on clean log)
#   3. Tamper detection (verify fails after modification)
#   4. Chain break detection (deleted entry)
#   5. Detail key-value pairs
#   6. Invalid event type rejection
#   7. Missing arguments rejection
#   8. Rotation
#   9. Status output
#  10. Tail output
#  11. Empty log handling
#  12. Message truncation
#
# Usage: bash tests/test-audit-log-helper.sh [--verbose]
#
# Exit codes: 0 = all pass, 1 = failures found

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${REPO_DIR}/.agents/scripts/audit-log-helper.sh"
VERBOSE="${1:-}"

# =============================================================================
# Test Framework
# =============================================================================

PASS_COUNT=0
FAIL_COUNT=0
TEST_TMPDIR=""

cleanup() {
	if [[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]]; then
		rm -rf "$TEST_TMPDIR"
	fi
	return 0
}
trap cleanup EXIT

setup() {
	TEST_TMPDIR="$(mktemp -d)"
	export AUDIT_LOG_DIR="${TEST_TMPDIR}"
	export AUDIT_LOG_FILE="${TEST_TMPDIR}/audit.jsonl"
	export AUDIT_QUIET="true"
	return 0
}

pass() {
	local name="$1"
	PASS_COUNT=$((PASS_COUNT + 1))
	echo "  PASS: $name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	FAIL_COUNT=$((FAIL_COUNT + 1))
	echo "  FAIL: $name"
	if [[ -n "$detail" ]]; then
		echo "        $detail"
	fi
	return 0
}

verbose() {
	local msg="$1"
	if [[ "$VERBOSE" == "--verbose" ]]; then
		echo "  [v] $msg"
	fi
	return 0
}

# =============================================================================
# Tests
# =============================================================================

test_basic_logging() {
	echo "Test: Basic logging"
	setup

	if bash "$SCRIPT" log worker.dispatch "Test dispatch" 2>/dev/null; then
		pass "log worker.dispatch succeeds"
	else
		fail "log worker.dispatch failed"
	fi

	if [[ -f "$AUDIT_LOG_FILE" ]]; then
		pass "log file created"
	else
		fail "log file not created"
		return 0
	fi

	local line_count
	line_count="$(wc -l <"$AUDIT_LOG_FILE" | tr -d ' ')"
	if [[ "$line_count" -eq 1 ]]; then
		pass "exactly 1 entry"
	else
		fail "expected 1 entry, got $line_count"
	fi

	# Check JSON structure
	if command -v jq &>/dev/null; then
		local entry
		entry="$(head -1 "$AUDIT_LOG_FILE")"
		local has_fields
		has_fields="$(echo "$entry" | jq 'has("seq") and has("ts") and has("type") and has("msg") and has("hash") and has("prev_hash")' 2>/dev/null || echo "false")"
		if [[ "$has_fields" == "true" ]]; then
			pass "entry has all required fields"
		else
			fail "entry missing required fields"
			verbose "$entry"
		fi

		# Check genesis hash
		local prev_hash
		prev_hash="$(echo "$entry" | jq -r '.prev_hash' 2>/dev/null)"
		if [[ "$prev_hash" == "0000000000000000000000000000000000000000000000000000000000000000" ]]; then
			pass "first entry has genesis prev_hash"
		else
			fail "first entry prev_hash is not genesis: $prev_hash"
		fi
	fi

	cleanup
	return 0
}

test_all_event_types() {
	echo "Test: All event types"
	setup

	local -a types=(
		"worker.dispatch"
		"worker.complete"
		"worker.error"
		"credential.access"
		"credential.rotate"
		"config.change"
		"config.deploy"
		"security.event"
		"security.injection"
		"security.scan"
		"operation.verify"
		"operation.block"
		"system.startup"
		"system.update"
		"system.rotate"
		"testing.runtime"
	)

	local all_ok="true"
	local t
	for t in "${types[@]}"; do
		if ! bash "$SCRIPT" log "$t" "Test $t" 2>/dev/null; then
			fail "event type $t rejected"
			all_ok="false"
		fi
	done

	if [[ "$all_ok" == "true" ]]; then
		pass "all ${#types[@]} event types accepted"
	fi

	# Verify chain after all entries
	if bash "$SCRIPT" verify --quiet 2>/dev/null; then
		pass "chain intact after ${#types[@]} entries"
	else
		fail "chain broken after logging all event types"
	fi

	cleanup
	return 0
}

test_hash_chain_integrity() {
	echo "Test: Hash chain integrity"
	setup

	# Log multiple entries
	bash "$SCRIPT" log worker.dispatch "Entry 1" 2>/dev/null
	bash "$SCRIPT" log credential.access "Entry 2" 2>/dev/null
	bash "$SCRIPT" log config.change "Entry 3" 2>/dev/null
	bash "$SCRIPT" log security.event "Entry 4" 2>/dev/null
	bash "$SCRIPT" log worker.complete "Entry 5" 2>/dev/null

	if bash "$SCRIPT" verify --quiet 2>/dev/null; then
		pass "5-entry chain verifies"
	else
		fail "5-entry chain verification failed"
	fi

	# Check that each entry's prev_hash matches previous entry's hash
	if command -v jq &>/dev/null; then
		local prev_hash=""
		local line_num=0
		local chain_ok="true"
		while IFS= read -r line; do
			line_num=$((line_num + 1))
			local current_prev
			current_prev="$(echo "$line" | jq -r '.prev_hash')"
			local current_hash
			current_hash="$(echo "$line" | jq -r '.hash')"

			if [[ $line_num -gt 1 ]] && [[ "$current_prev" != "$prev_hash" ]]; then
				fail "entry $line_num prev_hash doesn't match entry $((line_num - 1)) hash"
				chain_ok="false"
			fi
			prev_hash="$current_hash"
		done <"$AUDIT_LOG_FILE"

		if [[ "$chain_ok" == "true" ]]; then
			pass "prev_hash chain links correctly"
		fi
	fi

	cleanup
	return 0
}

test_tamper_detection() {
	echo "Test: Tamper detection"
	setup

	bash "$SCRIPT" log worker.dispatch "Original entry 1" 2>/dev/null
	bash "$SCRIPT" log credential.access "Original entry 2" 2>/dev/null
	bash "$SCRIPT" log worker.complete "Original entry 3" 2>/dev/null

	# Verify clean state
	if ! bash "$SCRIPT" verify --quiet 2>/dev/null; then
		fail "chain should be valid before tampering"
		cleanup
		return 0
	fi

	# Tamper with entry 2 (modify message)
	sed -i '' 's/Original entry 2/TAMPERED entry 2/' "$AUDIT_LOG_FILE" 2>/dev/null ||
		sed -i 's/Original entry 2/TAMPERED entry 2/' "$AUDIT_LOG_FILE"

	# Verify should now fail
	if bash "$SCRIPT" verify --quiet 2>/dev/null; then
		fail "verify should detect tampered entry"
	else
		pass "tampered entry detected"
	fi

	cleanup
	return 0
}

test_deletion_detection() {
	echo "Test: Deletion detection"
	setup

	bash "$SCRIPT" log worker.dispatch "Entry 1" 2>/dev/null
	bash "$SCRIPT" log credential.access "Entry 2" 2>/dev/null
	bash "$SCRIPT" log worker.complete "Entry 3" 2>/dev/null

	# Delete entry 2 (middle of chain)
	if [[ "$(uname)" == "Darwin" ]]; then
		sed -i '' '2d' "$AUDIT_LOG_FILE"
	else
		sed -i '2d' "$AUDIT_LOG_FILE"
	fi

	# Verify should fail (chain broken)
	if bash "$SCRIPT" verify --quiet 2>/dev/null; then
		fail "verify should detect deleted entry"
	else
		pass "deleted entry detected (chain break)"
	fi

	cleanup
	return 0
}

test_detail_pairs() {
	echo "Test: Detail key-value pairs"
	setup

	bash "$SCRIPT" log worker.dispatch "Test with details" \
		--detail repo=aidevops \
		--detail task_id=t1412.8 \
		--detail branch=feature/test 2>/dev/null

	if command -v jq &>/dev/null; then
		local entry
		entry="$(head -1 "$AUDIT_LOG_FILE")"
		local repo
		repo="$(echo "$entry" | jq -r '.detail.repo' 2>/dev/null)"
		local task_id
		task_id="$(echo "$entry" | jq -r '.detail.task_id' 2>/dev/null)"

		if [[ "$repo" == "aidevops" ]] && [[ "$task_id" == "t1412.8" ]]; then
			pass "detail key-value pairs stored correctly"
		else
			fail "detail values wrong: repo=$repo task_id=$task_id"
		fi
	else
		pass "detail pairs logged (jq not available for deep check)"
	fi

	cleanup
	return 0
}

test_invalid_event_type() {
	echo "Test: Invalid event type rejection"
	setup

	if bash "$SCRIPT" log "invalid.type" "Should fail" 2>/dev/null; then
		fail "invalid event type should be rejected"
	else
		pass "invalid event type rejected"
	fi

	cleanup
	return 0
}

test_missing_arguments() {
	echo "Test: Missing arguments rejection"
	setup

	# Missing event type
	if bash "$SCRIPT" log 2>/dev/null; then
		fail "missing event type should be rejected"
	else
		pass "missing event type rejected"
	fi

	# Missing message
	if bash "$SCRIPT" log worker.dispatch 2>/dev/null; then
		fail "missing message should be rejected"
	else
		pass "missing message rejected"
	fi

	cleanup
	return 0
}

test_rotation() {
	echo "Test: Log rotation"
	setup

	# Create a log with a few entries
	bash "$SCRIPT" log worker.dispatch "Entry 1" 2>/dev/null
	bash "$SCRIPT" log worker.complete "Entry 2" 2>/dev/null

	# Rotate with a tiny threshold (0 MB = always rotate)
	if bash "$SCRIPT" rotate --max-size 0 2>/dev/null; then
		pass "rotation command succeeds"
	else
		fail "rotation command failed"
		cleanup
		return 0
	fi

	# Check that rotated file exists
	local rotated_count
	rotated_count="$(find "$TEST_TMPDIR" -name 'audit.*.jsonl' 2>/dev/null | wc -l | tr -d ' ')"
	if [[ "$rotated_count" -ge 1 ]]; then
		pass "rotated file created"
	else
		fail "no rotated file found"
	fi

	# New log should have the rotation event
	if [[ -f "$AUDIT_LOG_FILE" ]]; then
		local new_count
		new_count="$(wc -l <"$AUDIT_LOG_FILE" | tr -d ' ')"
		if [[ "$new_count" -ge 1 ]]; then
			pass "rotation event logged in new file"
		else
			fail "new log file is empty after rotation"
		fi
	else
		fail "new log file not created after rotation"
	fi

	cleanup
	return 0
}

test_status_output() {
	echo "Test: Status output"
	setup

	bash "$SCRIPT" log worker.dispatch "Status test" 2>/dev/null

	local status_output
	status_output="$(bash "$SCRIPT" status 2>/dev/null)"

	if grep -q "Entries:" <<<"$status_output"; then
		pass "status shows entry count"
	else
		fail "status missing entry count"
	fi

	if grep -q "INTACT" <<<"$status_output"; then
		pass "status shows chain status"
	else
		fail "status missing chain status"
	fi

	cleanup
	return 0
}

test_tail_output() {
	echo "Test: Tail output"
	setup

	bash "$SCRIPT" log worker.dispatch "Tail entry 1" 2>/dev/null
	bash "$SCRIPT" log worker.complete "Tail entry 2" 2>/dev/null
	bash "$SCRIPT" log config.change "Tail entry 3" 2>/dev/null

	local tail_output
	tail_output="$(bash "$SCRIPT" tail 2 2>/dev/null)"
	local tail_lines
	tail_lines="$(echo "$tail_output" | wc -l | tr -d ' ')"

	if [[ "$tail_lines" -eq 2 ]]; then
		pass "tail 2 returns 2 entries"
	else
		fail "tail 2 returned $tail_lines entries (expected 2)"
	fi

	cleanup
	return 0
}

test_empty_log() {
	echo "Test: Empty log handling"
	setup

	# Verify on non-existent log
	if bash "$SCRIPT" verify 2>/dev/null; then
		pass "verify on empty log succeeds"
	else
		fail "verify on empty log should succeed"
	fi

	# Status on non-existent log
	local status_output
	status_output="$(bash "$SCRIPT" status 2>/dev/null)"
	if grep -q "No log file" <<<"$status_output"; then
		pass "status reports no log file"
	else
		fail "status should report no log file"
	fi

	# Tail on non-existent log
	if bash "$SCRIPT" tail 2>/dev/null; then
		pass "tail on empty log succeeds"
	else
		fail "tail on empty log should succeed"
	fi

	cleanup
	return 0
}

test_message_with_special_chars() {
	echo "Test: Messages with special characters"
	setup

	# Test with quotes, newlines, backslashes
	bash "$SCRIPT" log security.event 'Message with "quotes" and backslash\n and tab\t' 2>/dev/null

	if bash "$SCRIPT" verify --quiet 2>/dev/null; then
		pass "special characters handled correctly"
	else
		fail "special characters broke the chain"
	fi

	cleanup
	return 0
}

test_sequence_numbers() {
	echo "Test: Sequence numbers"
	setup

	bash "$SCRIPT" log worker.dispatch "Seq 1" 2>/dev/null
	bash "$SCRIPT" log worker.complete "Seq 2" 2>/dev/null
	bash "$SCRIPT" log config.change "Seq 3" 2>/dev/null

	if command -v jq &>/dev/null; then
		local seq1 seq2 seq3
		seq1="$(sed -n '1p' "$AUDIT_LOG_FILE" | jq -r '.seq')"
		seq2="$(sed -n '2p' "$AUDIT_LOG_FILE" | jq -r '.seq')"
		seq3="$(sed -n '3p' "$AUDIT_LOG_FILE" | jq -r '.seq')"

		if [[ "$seq1" -eq 1 ]] && [[ "$seq2" -eq 2 ]] && [[ "$seq3" -eq 3 ]]; then
			pass "sequence numbers are monotonic (1, 2, 3)"
		else
			fail "sequence numbers wrong: $seq1, $seq2, $seq3"
		fi
	else
		pass "sequence test skipped (no jq)"
	fi

	cleanup
	return 0
}

test_help_output() {
	echo "Test: Help output"
	setup

	local help_output
	help_output="$(bash "$SCRIPT" help 2>/dev/null)"

	if grep -qi "tamper-evident" <<<"$help_output"; then
		pass "help mentions tamper-evident"
	else
		fail "help missing tamper-evident description"
	fi

	if grep -q "worker.dispatch" <<<"$help_output"; then
		pass "help lists event types"
	else
		fail "help missing event types"
	fi

	cleanup
	return 0
}

test_input_validation() {
	echo "Test: Input validation (security)"
	setup

	# Tail with non-numeric input should be rejected
	if bash "$SCRIPT" log worker.dispatch "Setup entry" 2>/dev/null; then
		if bash "$SCRIPT" tail "abc" 2>/dev/null; then
			fail "tail should reject non-numeric count"
		else
			pass "tail rejects non-numeric count"
		fi

		if bash "$SCRIPT" tail "1 /etc/passwd" 2>/dev/null; then
			fail "tail should reject count with spaces"
		else
			pass "tail rejects count with injection attempt"
		fi
	fi

	# Rotate with non-numeric max-size should be rejected
	if bash "$SCRIPT" rotate --max-size "abc" 2>/dev/null; then
		fail "rotate should reject non-numeric max-size"
	else
		pass "rotate rejects non-numeric max-size"
	fi

	if bash "$SCRIPT" rotate --max-size '$(id)' 2>/dev/null; then
		fail "rotate should reject command injection in max-size"
	else
		pass "rotate rejects command injection in max-size"
	fi

	cleanup
	return 0
}

test_testing_runtime_event() {
	echo "Test: testing.runtime event type"
	setup

	# Log a passing test run with structured detail fields
	if bash "$SCRIPT" log testing.runtime "Runtime test suite passed" \
		--detail suite=test-audit-log-helper \
		--detail result=pass \
		--detail tests_run=17 \
		--detail tests_failed=0 \
		--detail runtime_ms=1234 2>/dev/null; then
		pass "testing.runtime event accepted"
	else
		fail "testing.runtime event rejected"
		cleanup
		return 0
	fi

	# Log a failing test run
	if bash "$SCRIPT" log testing.runtime "Runtime test suite failed" \
		--detail suite=test-worker-sandbox \
		--detail result=fail \
		--detail tests_run=5 \
		--detail tests_failed=2 2>/dev/null; then
		pass "testing.runtime fail result accepted"
	else
		fail "testing.runtime fail result rejected"
	fi

	# Log a skipped test run
	if bash "$SCRIPT" log testing.runtime "Runtime test skipped (no docker)" \
		--detail suite=test-container-helper \
		--detail result=skip \
		--detail reason=docker_unavailable 2>/dev/null; then
		pass "testing.runtime skip result accepted"
	else
		fail "testing.runtime skip result rejected"
	fi

	# Verify chain integrity after all three entries
	if bash "$SCRIPT" verify --quiet 2>/dev/null; then
		pass "chain intact after testing.runtime entries"
	else
		fail "chain broken after testing.runtime entries"
	fi

	# Verify detail fields are stored correctly
	if command -v jq &>/dev/null; then
		local entry
		entry="$(head -1 "$AUDIT_LOG_FILE")"
		local suite result tests_run
		suite="$(echo "$entry" | jq -r '.detail.suite' 2>/dev/null)"
		result="$(echo "$entry" | jq -r '.detail.result' 2>/dev/null)"
		tests_run="$(echo "$entry" | jq -r '.detail.tests_run' 2>/dev/null)"

		if [[ "$suite" == "test-audit-log-helper" ]] &&
			[[ "$result" == "pass" ]] &&
			[[ "$tests_run" == "17" ]]; then
			pass "testing.runtime detail fields stored correctly"
		else
			fail "testing.runtime detail fields wrong: suite=$suite result=$result tests_run=$tests_run"
		fi
	else
		pass "testing.runtime detail check skipped (no jq)"
	fi

	cleanup
	return 0
}

# Build a minimal PATH with jq excluded, using a shadow directory of symlinks.
# Populates caller variables with the PATH and shadow directory so the caller
# can keep the directory alive for every fallback subtest and clean it afterward.
_build_no_jq_path() {
	local path_output_var="$1"
	local shadow_output_var="$2"
	local built_shadow_dir
	built_shadow_dir="$(mktemp -d)"

	local needed_tools=(bash basename cat chmod cut date dirname env flock grep
		head hostname ln ls mkdir mktemp mv printf pwd rm rmdir sed shasum
		sha256sum sleep source stat tail tr uname wc)
	local tool tool_path
	for tool in "${needed_tools[@]}"; do
		tool_path="$(command -v "$tool" 2>/dev/null || true)"
		if [[ -n "$tool_path" ]] && [[ -x "$tool_path" ]]; then
			ln -sf "$tool_path" "${built_shadow_dir}/${tool}" 2>/dev/null || true
		fi
	done

	local built_minimal_path="${built_shadow_dir}"
	local saved_ifs="$IFS"
	IFS=':'
	local dir
	for dir in $PATH; do
		if [[ -d "$dir" ]] && ! [[ -x "${dir}/jq" ]]; then
			built_minimal_path="${built_minimal_path}:${dir}"
		fi
	done
	IFS="$saved_ifs"

	printf -v "$path_output_var" '%s' "$built_minimal_path"
	printf -v "$shadow_output_var" '%s' "$built_shadow_dir"
	return 0
}

# Run the no-jq fallback tests inside a subshell with jq removed from PATH
_run_no_jq_subtests() {
	# 1. Basic logging (exercises manual JSON construction + escaping)
	setup
	if bash "$SCRIPT" log worker.dispatch "No-jq test entry" 2>/dev/null; then
		if [[ -s "$AUDIT_LOG_FILE" ]]; then
			local line_count
			line_count="$(wc -l <"$AUDIT_LOG_FILE" | tr -d ' ')"
			if [[ "$line_count" -eq 1 ]]; then
				echo "  PASS: no-jq: basic logging produces 1 entry"
			else
				echo "  FAIL: no-jq: expected 1 entry, got $line_count"
				exit 1
			fi
		else
			echo "  FAIL: no-jq: log file is empty"
			exit 1
		fi
	else
		echo "  FAIL: no-jq: log command failed"
		exit 1
	fi
	cleanup

	# 2. Hash chain integrity (exercises sed-based hash extraction in verify)
	setup
	bash "$SCRIPT" log worker.dispatch "Chain entry 1" 2>/dev/null
	bash "$SCRIPT" log credential.access "Chain entry 2" 2>/dev/null
	bash "$SCRIPT" log config.change "Chain entry 3" 2>/dev/null
	if bash "$SCRIPT" verify --quiet 2>/dev/null; then
		echo "  PASS: no-jq: 3-entry chain verifies"
	else
		echo "  FAIL: no-jq: chain verification failed without jq"
		exit 1
	fi
	cleanup

	# 3. Tamper detection (exercises sed-based verify fallback)
	setup
	bash "$SCRIPT" log worker.dispatch "Original 1" 2>/dev/null
	bash "$SCRIPT" log credential.access "Original 2" 2>/dev/null
	bash "$SCRIPT" log worker.complete "Original 3" 2>/dev/null
	sed -i '' 's/Original 2/TAMPERED 2/' "$AUDIT_LOG_FILE" 2>/dev/null ||
		sed -i 's/Original 2/TAMPERED 2/' "$AUDIT_LOG_FILE"
	if bash "$SCRIPT" verify --quiet 2>/dev/null; then
		echo "  FAIL: no-jq: verify should detect tampered entry"
		exit 1
	else
		echo "  PASS: no-jq: tampered entry detected without jq"
	fi
	cleanup

	# 4. Special characters (exercises _audit_json_escape fallback)
	setup
	bash "$SCRIPT" log security.event 'Msg with "quotes" and back\\slash' 2>/dev/null
	if bash "$SCRIPT" verify --quiet 2>/dev/null; then
		echo "  PASS: no-jq: special characters handled in fallback"
	else
		echo "  FAIL: no-jq: special characters broke chain in fallback"
		exit 1
	fi
	cleanup

	exit 0
}

test_no_jq_fallback() {
	echo "Test: No-jq fallback code paths"

	# Skip if jq is not installed (fallback is already the default path)
	if ! command -v jq &>/dev/null; then
		pass "jq not installed — fallback is already the default path, skipping"
		return 0
	fi

	# Run a representative subset of tests in a subshell with jq hidden from
	# PATH. This exercises the manual JSON construction, sed-based hash
	# extraction, and manual JSON escaping fallback code paths.
	#
	# Strategy: build a minimal PATH containing symlinks to only the tools
	# the script needs, explicitly excluding jq. This avoids symlinking all
	# of /usr/bin (which has 1000+ entries on macOS and is very slow).
	(
		local minimal_path shadow_dir
		_build_no_jq_path minimal_path shadow_dir
		trap 'rm -rf "$shadow_dir"' EXIT
		export PATH="$minimal_path"

		# Verify jq is actually gone
		if command -v jq &>/dev/null; then
			echo "  WARN: Could not remove jq from PATH (found at $(command -v jq)), skipping"
			exit 0
		fi

		_run_no_jq_subtests
	)

	local subshell_exit=$?
	if [[ $subshell_exit -eq 0 ]]; then
		pass "no-jq fallback code paths work correctly"
	else
		fail "no-jq fallback code paths have failures"
	fi

	return 0
}

# =============================================================================
# Run all tests
# =============================================================================

echo "=== audit-log-helper.sh tests (t1412.8) ==="
echo ""

test_basic_logging
test_all_event_types
test_hash_chain_integrity
test_tamper_detection
test_deletion_detection
test_detail_pairs
test_invalid_event_type
test_missing_arguments
test_rotation
test_status_output
test_tail_output
test_empty_log
test_message_with_special_chars
test_sequence_numbers
test_help_output
test_input_validation
test_testing_runtime_event
test_no_jq_fallback

echo ""
echo "=== Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed ==="

if [[ $FAIL_COUNT -gt 0 ]]; then
	exit 1
fi

exit 0
