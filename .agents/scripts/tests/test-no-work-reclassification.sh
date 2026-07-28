#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for t2820 (Phase 5): no_work reclassification via log tail.
#
# This test asserts that escalate_issue_tier reclassifies generic
# `worker_failed`-class events as `no_work` when the Phase 3 worker-log tail
# (t2814) shows no implementation evidence — preventing wasteful tier
# escalation to opus on infrastructure failures the worker never recovered
# from.
#
# Coverage:
#   1. _read_worker_log_tail_classified — exists in shared-claim-lifecycle.sh
#      and produces the documented caller-scope variables.
#   2. Classification correctness across the 4 documented log shapes:
#        a. real_coding         — tool-use frames present → no reclass
#        b. no_tool_calls       — log content but no tool markers → reclass
#        c. canary_post_spawn   — explicit canary failure OR t2814 marker → reclass
#        d. unknown             — missing log → fall-through (no reclass)
#   3. _maybe_reclassify_worker_failed_as_no_work — fires on the expected
#      reason buckets (worker_failed, premature_exit, worker_noop_zero_output)
#      and is a no-op for unrelated reasons (rate_limit, etc.).
#   4. NO_WORK_RECLASS_ELAPSED_MAX env var honoured — stale logs do NOT
#      reclassify on the no_tool_calls path (only canary_post_spawn fires
#      regardless of age).
#   5. Pre-Phase 3 records (no log file) do NOT regress — function returns 1
#      so caller falls through to existing escalation behaviour unchanged.
#
# Test strategy: structural greps + behavioural unit tests against the real
# functions sourced from the actual shell libraries. Stubs out gh CLI and
# _log_no_work_skip_escalation to capture invocations without network calls.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
AGENT_SCRIPT_DIR="${SCRIPT_DIR}/.."
SHARED_CLAIM_LIFECYCLE="${AGENT_SCRIPT_DIR}/shared-claim-lifecycle.sh"
WORKER_LIFECYCLE="${AGENT_SCRIPT_DIR}/worker-lifecycle-common.sh"
PULSE_CLEANUP="${AGENT_SCRIPT_DIR}/pulse-cleanup.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

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

# ---------------------------------------------------------------------------
# Static structural checks
# ---------------------------------------------------------------------------

test_shared_helper_exists() {
	if grep -q '^_read_worker_log_tail_classified()' "$SHARED_CLAIM_LIFECYCLE"; then
		print_result "shared: _read_worker_log_tail_classified() defined" 0
	else
		print_result "shared: _read_worker_log_tail_classified() defined" 1 \
			"Expected function in $SHARED_CLAIM_LIFECYCLE"
	fi
	return 0
}

test_reclassify_helper_exists() {
	if grep -q '^_maybe_reclassify_worker_failed_as_no_work()' "$WORKER_LIFECYCLE"; then
		print_result "worker: _maybe_reclassify_worker_failed_as_no_work() defined" 0
	else
		print_result "worker: _maybe_reclassify_worker_failed_as_no_work() defined" 1 \
			"Expected function in $WORKER_LIFECYCLE"
	fi
	return 0
}

test_escalate_calls_reclassify() {
	# Assert the reclassify call appears inside escalate_issue_tier — the
	# only safe place where the empty-crash_type branch should fire.
	if awk '/^escalate_issue_tier\(\)/,/^}$/' "$WORKER_LIFECYCLE" \
		| grep -q '_maybe_reclassify_worker_failed_as_no_work'; then
		print_result "wired: escalate_issue_tier() calls _maybe_reclassify_..." 0
	else
		print_result "wired: escalate_issue_tier() calls _maybe_reclassify_..." 1 \
			"Reclassification call missing from escalate_issue_tier in $WORKER_LIFECYCLE"
	fi
	return 0
}

test_pulse_cleanup_uses_shared_reader() {
	# Confirm _post_launch_recovery_claim_released no longer duplicates
	# the log-tail reading logic — DRY with shared helper (acceptance #4).
	if awk '/_post_launch_recovery_claim_released\(\)/,/^}$/' "$PULSE_CLEANUP" \
		| grep -q '_read_worker_log_tail_classified'; then
		print_result "DRY: pulse-cleanup uses _read_worker_log_tail_classified" 0
	else
		print_result "DRY: pulse-cleanup uses _read_worker_log_tail_classified" 1 \
			"Expected pulse-cleanup.sh to delegate log-tail reading to shared helper"
	fi
	return 0
}

test_env_override_documented() {
	if grep -q 'NO_WORK_RECLASS_ELAPSED_MAX' "$WORKER_LIFECYCLE"; then
		print_result "env: NO_WORK_RECLASS_ELAPSED_MAX referenced" 0
	else
		print_result "env: NO_WORK_RECLASS_ELAPSED_MAX referenced" 1 \
			"Expected NO_WORK_RECLASS_ELAPSED_MAX env var in $WORKER_LIFECYCLE"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Behavioural — _read_worker_log_tail_classified classification matrix
# ---------------------------------------------------------------------------

# Source the shared helper directly. The include guard makes this safe to
# repeat across tests.
# shellcheck source=../shared-claim-lifecycle.sh
source "$SHARED_CLAIM_LIFECYCLE"

# Helper: write a fake log to the per-user pulse temp path the reader scans,
# invoke the reader, capture classification + content.
_run_classifier_with_log() {
	local issue_number="$1"
	local repo_slug="$2"
	local log_content="$3"
	local log_file=""
	log_file=$(aidevops_pulse_worker_log_path "$repo_slug" "$issue_number")
	# Clean any prior fixture
	rm -f "$log_file" "$(aidevops_pulse_worker_log_fallback_path "$issue_number")" 2>/dev/null || true
	if [[ -n "$log_content" ]]; then
		printf '%s\n' "$log_content" >"$log_file"
	fi
	# Reset before invocation
	_WORKER_LOG_TAIL_FILE=""
	_WORKER_LOG_TAIL_CONTENT=""
	_WORKER_LOG_TAIL_CLASS="unknown"
	_WORKER_LOG_TAIL_AGE_SECS=""
	_read_worker_log_tail_classified "$issue_number" "$repo_slug"
	# Cleanup
	rm -f "$log_file" 2>/dev/null || true
	return 0
}

test_classify_real_coding() {
	# Realistic OpenCode tool-call frame fragment
	_run_classifier_with_log 90001 "test/repo-real" '[2026-04-25T00:00:00Z] starting opencode run
{"type":"tool_use","name":"Edit","input":{"file":"foo.sh"}}
{"type":"step","name":"Bash","input":{"command":"git commit -m wip"}}
git commit succeeded'
	if [[ "$_WORKER_LOG_TAIL_CLASS" == "real_coding" ]]; then
		print_result "classify: real_coding (tool-use markers)" 0
	else
		print_result "classify: real_coding (tool-use markers)" 1 \
			"Expected real_coding, got: $_WORKER_LOG_TAIL_CLASS"
	fi
	return 0
}

test_classify_no_tool_calls() {
	# Log that has content but no tool calls (e.g. session setup messages
	# repeating without ever reaching exec)
	_run_classifier_with_log 90002 "test/repo-noop" '[2026-04-25T00:00:00Z] session init
[2026-04-25T00:00:01Z] loading plugins
[2026-04-25T00:00:02Z] waiting for stream
[2026-04-25T00:00:30Z] still waiting
[2026-04-25T00:00:45Z] connection refused'
	if [[ "$_WORKER_LOG_TAIL_CLASS" == "no_tool_calls" ]]; then
		print_result "classify: no_tool_calls (content but no tool markers)" 0
	else
		print_result "classify: no_tool_calls (content but no tool markers)" 1 \
			"Expected no_tool_calls, got: $_WORKER_LOG_TAIL_CLASS"
	fi
	return 0
}

test_classify_canary_post_spawn() {
	_run_classifier_with_log 90003 "test/repo-canary" '[2026-04-25T00:00:00Z] starting canary test
[2026-04-25T00:00:05Z] [t2814:early_exit] worker PID 12345 for issue #90003 exited within 4s spawn window at 2026-04-25T00:00:04Z
[2026-04-25T00:00:05Z] cleanup'
	if [[ "$_WORKER_LOG_TAIL_CLASS" == "canary_post_spawn" ]]; then
		print_result "classify: canary_post_spawn (t2814 marker)" 0
	else
		print_result "classify: canary_post_spawn (t2814 marker)" 1 \
			"Expected canary_post_spawn, got: $_WORKER_LOG_TAIL_CLASS"
	fi
	return 0
}

test_classify_canary_text_marker() {
	# Explicit canary failure variant (no t2814 marker).
	_run_classifier_with_log 90004 "test/repo-canary2" '[2026-04-25T00:00:00Z] running canary
[2026-04-25T00:00:01Z] canary returned 1, aborting'
	if [[ "$_WORKER_LOG_TAIL_CLASS" == "canary_post_spawn" ]]; then
		print_result "classify: canary_post_spawn (canary text marker)" 0
	else
		print_result "classify: canary_post_spawn (canary text marker)" 1 \
			"Expected canary_post_spawn, got: $_WORKER_LOG_TAIL_CLASS"
	fi
	return 0
}

test_classify_successful_canary_lifecycle() {
	_run_classifier_with_log 90006 "test/repo-canary-success" '[lifecycle] pre_canary session=issue-90006 model=openai/test
[lifecycle] post_canary session=issue-90006 model=openai/test
[lifecycle] pre_worker_prepare session=issue-90006
[lifecycle] post_worker_prepare session=issue-90006'
	if [[ "$_WORKER_LOG_TAIL_CLASS" == "no_tool_calls" ]]; then
		print_result "classify: successful canary lifecycle is not a canary failure" 0
	else
		print_result "classify: successful canary lifecycle is not a canary failure" 1 \
			"Expected no_tool_calls, got: $_WORKER_LOG_TAIL_CLASS"
	fi
	return 0
}

test_classify_unknown_missing_log() {
	# No log file at all
	_run_classifier_with_log 90005 "test/repo-missing" ""
	if [[ "$_WORKER_LOG_TAIL_CLASS" == "unknown" && -z "$_WORKER_LOG_TAIL_FILE" ]]; then
		print_result "classify: unknown (missing log → no reclass)" 0
	else
		print_result "classify: unknown (missing log → no reclass)" 1 \
			"Expected unknown + empty file, got: class=$_WORKER_LOG_TAIL_CLASS file=$_WORKER_LOG_TAIL_FILE"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Behavioural — _maybe_reclassify_worker_failed_as_no_work decision matrix
# ---------------------------------------------------------------------------

# Source worker-lifecycle-common.sh to bring _maybe_reclassify... and the
# stubbable _log_no_work_skip_escalation into scope.
# shellcheck source=../worker-lifecycle-common.sh
source "$WORKER_LIFECYCLE"

# Stub _log_no_work_skip_escalation: capture all invocations to a tmpfile.
RECLASS_CAPTURE="$(mktemp "${TMPDIR:-/tmp}/aidevops-t2820-capture.XXXXXX")"
trap 'rm -f "$RECLASS_CAPTURE" 2>/dev/null || true' EXIT

_log_no_work_skip_escalation() {
	# Args: issue_number, repo_slug, failure_count, reason
	printf 'CALLED: issue=%s repo=%s count=%s reason=%s\n' \
		"$1" "$2" "$3" "$4" >>"$RECLASS_CAPTURE"
	return 0
}

# Fixture with tool-call markers — real_coding → return 1 (no reclass)
test_reclassify_real_coding_no_op() {
	: >"$RECLASS_CAPTURE"
	local log_file=""
	log_file=$(aidevops_pulse_worker_log_path "test/repo-r1" "91001")
	printf 'tool_use Edit foo.sh\ngit commit succeeded\n' >"$log_file"
	# Make the log "young" so the no_tool_calls timing path is irrelevant
	if _maybe_reclassify_worker_failed_as_no_work 91001 "test/repo-r1" 1 "worker_failed"; then
		print_result "reclass: real_coding falls through (returns 1)" 1 \
			"Expected return 1 for real_coding, but reclassification fired"
	else
		# Confirm no skip-escalation call happened
		if [[ -s "$RECLASS_CAPTURE" ]]; then
			print_result "reclass: real_coding falls through (returns 1)" 1 \
				"Expected no _log_no_work_skip_escalation call. Got: $(cat "$RECLASS_CAPTURE")"
		else
			print_result "reclass: real_coding falls through (returns 1)" 0
		fi
	fi
	rm -f "$log_file"
	return 0
}

# Fixture with no tool calls + young log → reclass with no_tool_calls_in_log
test_reclassify_no_tool_calls_fires() {
	: >"$RECLASS_CAPTURE"
	local log_file=""
	log_file=$(aidevops_pulse_worker_log_path "test/repo-r2" "91002")
	printf 'session init\nwaiting for stream\nconnection refused\n' >"$log_file"
	# Force a young mtime (now)
	touch "$log_file"
	if _maybe_reclassify_worker_failed_as_no_work 91002 "test/repo-r2" 1 "worker_failed"; then
		# Confirm capture contains the subtype marker
		if grep -q 'reason=no_work:no_tool_calls_in_log' "$RECLASS_CAPTURE"; then
			print_result "reclass: no_tool_calls (young log) → fires with subtype" 0
		else
			print_result "reclass: no_tool_calls (young log) → fires with subtype" 1 \
				"Reclass returned 0 but capture missing subtype. Got: $(cat "$RECLASS_CAPTURE")"
		fi
	else
		print_result "reclass: no_tool_calls (young log) → fires with subtype" 1 \
			"Expected return 0 (reclassified) for young no_tool_calls log"
	fi
	rm -f "$log_file"
	return 0
}

# Fixture with canary marker → reclass with canary_post_spawn_failure
test_reclassify_canary_fires() {
	: >"$RECLASS_CAPTURE"
	local log_file=""
	log_file=$(aidevops_pulse_worker_log_path "test/repo-r3" "91003")
	printf '[t2814:early_exit] worker PID 12345 exited\ncanary diagnostics\n' >"$log_file"
	if _maybe_reclassify_worker_failed_as_no_work 91003 "test/repo-r3" 1 "worker_failed"; then
		if grep -q 'reason=no_work:canary_post_spawn_failure' "$RECLASS_CAPTURE"; then
			print_result "reclass: canary_post_spawn → fires with subtype" 0
		else
			print_result "reclass: canary_post_spawn → fires with subtype" 1 \
				"Reclass returned 0 but capture missing subtype. Got: $(cat "$RECLASS_CAPTURE")"
		fi
	else
		print_result "reclass: canary_post_spawn → fires with subtype" 1 \
			"Expected return 0 (reclassified) for canary log"
	fi
	rm -f "$log_file"
	return 0
}

# NO_WORK_RECLASS_ELAPSED_MAX honoured — old log + no_tool_calls → no reclass
test_reclassify_old_no_tool_calls_skipped() {
	: >"$RECLASS_CAPTURE"
	local log_file=""
	log_file=$(aidevops_pulse_worker_log_path "test/repo-r4" "91004")
	printf 'session init\nwaiting\n' >"$log_file"
	# Use a low elapsed-max, then backdate the log to exceed it.
	local saved_max="$NO_WORK_RECLASS_ELAPSED_MAX"
	NO_WORK_RECLASS_ELAPSED_MAX=10
	# Backdate mtime by 60s
	touch -d '60 seconds ago' "$log_file" 2>/dev/null || \
		touch -t "$(date -d '60 seconds ago' '+%Y%m%d%H%M.%S' 2>/dev/null || echo '202604250000.00')" "$log_file" 2>/dev/null || true
	if _maybe_reclassify_worker_failed_as_no_work 91004 "test/repo-r4" 1 "worker_failed"; then
		print_result "reclass: old no_tool_calls log → no reclass (elapsed cap)" 1 \
			"Expected return 1 for old log but reclassification fired. Capture: $(cat "$RECLASS_CAPTURE")"
	else
		if [[ -s "$RECLASS_CAPTURE" ]]; then
			print_result "reclass: old no_tool_calls log → no reclass (elapsed cap)" 1 \
				"Expected no skip-escalation call. Got: $(cat "$RECLASS_CAPTURE")"
		else
			print_result "reclass: old no_tool_calls log → no reclass (elapsed cap)" 0
		fi
	fi
	NO_WORK_RECLASS_ELAPSED_MAX="$saved_max"
	rm -f "$log_file"
	return 0
}

# Pre-Phase 3 records (no log file) → fall-through (no regression)
test_reclassify_no_log_falls_through() {
	: >"$RECLASS_CAPTURE"
	# Ensure no log file exists for this issue
	rm -f "$(aidevops_pulse_worker_log_path "test/repo-r5" "91005")" "$(aidevops_pulse_worker_log_fallback_path "91005")" 2>/dev/null || true
	if _maybe_reclassify_worker_failed_as_no_work 91005 "test/repo-r5" 1 "worker_failed"; then
		print_result "reclass: no log file → fall-through (no regression)" 1 \
			"Expected return 1 (fall-through) for missing log"
	else
		if [[ -s "$RECLASS_CAPTURE" ]]; then
			print_result "reclass: no log file → fall-through (no regression)" 1 \
				"Expected no skip-escalation call. Got: $(cat "$RECLASS_CAPTURE")"
		else
			print_result "reclass: no log file → fall-through (no regression)" 0
		fi
	fi
	return 0
}

# Reasons that should NOT reclassify (rate_limit, etc.)
test_reclassify_skips_rate_limit() {
	: >"$RECLASS_CAPTURE"
	local log_file=""
	log_file=$(aidevops_pulse_worker_log_path "test/repo-r6" "91006")
	# Even with a no_tool_calls log, rate_limit should fall through.
	printf 'session init\nwaiting\n' >"$log_file"
	touch "$log_file"
	if _maybe_reclassify_worker_failed_as_no_work 91006 "test/repo-r6" 1 "rate_limit"; then
		print_result "reclass: rate_limit reason → fall-through (out of scope)" 1 \
			"Expected return 1 for rate_limit reason but reclassification fired"
	else
		if [[ -s "$RECLASS_CAPTURE" ]]; then
			print_result "reclass: rate_limit reason → fall-through (out of scope)" 1 \
				"Expected no skip-escalation call. Got: $(cat "$RECLASS_CAPTURE")"
		else
			print_result "reclass: rate_limit reason → fall-through (out of scope)" 0
		fi
	fi
	rm -f "$log_file"
	return 0
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------

printf 'Running t2820 no_work reclassification regression tests\n\n'

# Static checks
test_shared_helper_exists
test_reclassify_helper_exists
test_escalate_calls_reclassify
test_pulse_cleanup_uses_shared_reader
test_env_override_documented

# Classification matrix
test_classify_real_coding
test_classify_no_tool_calls
test_classify_canary_post_spawn
test_classify_canary_text_marker
test_classify_successful_canary_lifecycle
test_classify_unknown_missing_log

# Reclassification decision matrix
test_reclassify_real_coding_no_op
test_reclassify_no_tool_calls_fires
test_reclassify_canary_fires
test_reclassify_old_no_tool_calls_skipped
test_reclassify_no_log_falls_through
test_reclassify_skips_rate_limit

printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%bAll %d tests passed%b\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
fi
printf '%b%d/%d tests failed%b\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
exit 1
