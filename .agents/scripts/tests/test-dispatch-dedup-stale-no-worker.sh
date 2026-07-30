#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression guard for GH#4011/GH#4012 and a private app meta issue's t2769
# no_work false trips.
#
# A stale active label + assignee with no dispatch claim comment can be cleaned
# up by stale recovery, but it is not evidence that a worker ever started. That
# recovery must not record stale_timeout/no_work fast-fails, or pre-launch
# canary failures can trip the t2769 no_work circuit breaker without worker
# evidence.

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_DIR}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$name"
	[[ -n "$detail" ]] && printf '  %s\n' "$detail"
	return 0
}

TMP_DIR="$(mktemp -d -t stale-no-worker.XXXXXX)" || exit 1
trap 'rm -rf "$TMP_DIR"' EXIT

export LOGFILE="${TMP_DIR}/pulse.log"
SCRIPT_DIR="$TMP_DIR"
HELPER_PATH="${TMP_DIR}/dispatch-dedup-helper.sh"

cat >"$HELPER_PATH" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail

cmd="${1:-}"
shift || true

if [[ "$cmd" == "is-assigned" ]]; then
	case "${TEST_STALE_MODE:-no_worker}" in
	no_worker)
		printf '%s\n' 'STALE_RECOVERED: issue #2905 in exampleorg/examplerepo - unassigned runner (no dispatch claim comment found, no recent activity (threshold=600s, interactive=false))'
		exit 1
		;;
	prelaunch_canary)
		printf '%s\n' 'STALE_RECOVERED: issue #2905 in exampleorg/examplerepo - unassigned runner (no dispatch claim comment found, worker canary preflight failed before worktree pre-creation; will retry next cycle)'
		exit 1
		;;
	worker)
		printf '%s\n' 'STALE_RECOVERED: issue #2905 in exampleorg/examplerepo - unassigned runner (dispatch claim 900s old, last activity 900s old (threshold=600s, interactive=false))'
		exit 1
		;;
	blocked_by)
		printf '%s\n' 'STALE_BLOCKED_BY_DEPENDENCY: issue #2905 in exampleorg/examplerepo - unassigned runner but kept status:blocked due to unresolved blocked-by (no_work)'
		exit 1
		;;
	terminal)
		printf '%s\n' 'STALE_ESCALATED: issue #2905 in exampleorg/examplerepo — unassigned runner, applied needs-maintainer-review'
		exit 1
		;;
	terminal_pr)
		printf '%s\n' 'STALE_PR_ESCALATED: issue #2905 in exampleorg/examplerepo — PR #456 preserved, applied needs-maintainer-review'
		exit 1
		;;
	*)
		printf '%s\n' 'ASSIGNED: issue #2905 in exampleorg/examplerepo is assigned to runner'
		exit 0
		;;
	esac
fi

if [[ "$cmd" == "classify-blocker" ]]; then
	printf 'assigned\n'
	exit 0
fi

exit 1
EOF
chmod +x "$HELPER_PATH"

# shellcheck source=../pulse-dispatch-dedup-layers.sh
source "${SCRIPTS_DIR}/pulse-dispatch-dedup-layers.sh"
# shellcheck source=../pulse-dispatch-core.sh
source "${SCRIPTS_DIR}/pulse-dispatch-core.sh"
# Sourced modules use SCRIPT_DIR for their own bootstrap; restore the fixture
# helper directory used by the Layer 6 tests below.
SCRIPT_DIR="$TMP_DIR"

FAST_FAIL_CALLS=0
LAST_FAST_FAIL=""
CLASSIFY_LOG="${TMP_DIR}/classify.log"
CONSOLIDATION_CALLS=0
LAST_CONSOLIDATION=""

reset_observations() {
	FAST_FAIL_CALLS=0
	LAST_FAST_FAIL=""
	CONSOLIDATION_CALLS=0
	LAST_CONSOLIDATION=""
	: >"$LOGFILE"
	: >"$CLASSIFY_LOG"
	return 0
}

_route_terminal_breaker_to_consolidation() {
	local issue_number="$1"
	local repo_slug="$2"
	local breaker_source="$3"
	local breaker_detail="${4:-}"
	CONSOLIDATION_CALLS=$((CONSOLIDATION_CALLS + 1))
	LAST_CONSOLIDATION="${issue_number}|${repo_slug}|${breaker_source}|${breaker_detail}"
	return 0
}

fast_fail_record() {
	local issue_number="$1"
	local repo_slug="$2"
	local reason="$3"
	local provider="$4"
	local crash_type="$5"
	FAST_FAIL_CALLS=$((FAST_FAIL_CALLS + 1))
	LAST_FAST_FAIL="${issue_number}|${repo_slug}|${reason}|${provider}|${crash_type}"
	return 0
}

_classify_stale_recovery_crash_type() {
	local issue_number="$1"
	local repo_slug="$2"
	: "$issue_number" "$repo_slug"
	printf '%s|%s\n' "$issue_number" "$repo_slug" >>"$CLASSIFY_LOG"
	printf 'no_work'
	return 0
}

test_stale_recovery_without_claim_skips_fast_fail() {
	export TEST_STALE_MODE="no_worker"
	reset_observations
	local rc=0
	_dedup_layer6_assignee_and_stale "2905" "exampleorg/examplerepo" "runner" || rc=$?

	if [[ "$rc" -ne 1 ]]; then
		fail "no-worker stale recovery continues dispatch" "expected rc=1, got rc=${rc}"
		return 0
	fi
	if [[ "$FAST_FAIL_CALLS" -ne 0 ]]; then
		fail "no-worker stale recovery skips fast-fail" "fast_fail_record called ${FAST_FAIL_CALLS} time(s): ${LAST_FAST_FAIL}"
		return 0
	fi
	if [[ -s "$CLASSIFY_LOG" ]]; then
		fail "no-worker stale recovery skips classifier" "classifier log: $(tr '\n' ' ' <"$CLASSIFY_LOG")"
		return 0
	fi
	if ! grep -q 'without worker evidence' "$LOGFILE" 2>/dev/null; then
		fail "no-worker stale recovery logs skip reason" "log: $(tr '\n' ' ' <"$LOGFILE")"
		return 0
	fi
	pass "no-worker stale recovery skips no_work fast-fail"
	return 0
}

test_prelaunch_canary_stale_recovery_skips_fast_fail() {
	export TEST_STALE_MODE="prelaunch_canary"
	reset_observations
	local rc=0
	_dedup_layer6_assignee_and_stale "2905" "exampleorg/examplerepo" "runner" || rc=$?

	if [[ "$rc" -ne 1 ]]; then
		fail "prelaunch canary stale recovery continues dispatch" "expected rc=1, got rc=${rc}"
		return 0
	fi
	if [[ "$FAST_FAIL_CALLS" -ne 0 ]]; then
		fail "prelaunch canary stale recovery skips fast-fail" "fast_fail_record called ${FAST_FAIL_CALLS} time(s): ${LAST_FAST_FAIL}"
		return 0
	fi
	if [[ -s "$CLASSIFY_LOG" ]]; then
		fail "prelaunch canary stale recovery skips classifier" "classifier log: $(tr '\n' ' ' <"$CLASSIFY_LOG")"
		return 0
	fi
	if ! grep -q 'without worker evidence' "$LOGFILE" 2>/dev/null; then
		fail "prelaunch canary stale recovery logs skip reason" "log: $(tr '\n' ' ' <"$LOGFILE")"
		return 0
	fi
	pass "prelaunch canary stale recovery skips no_work fast-fail"
	return 0
}

test_stale_recovery_with_dispatch_claim_records_fast_fail() {
	export TEST_STALE_MODE="worker"
	reset_observations
	local rc=0
	_dedup_layer6_assignee_and_stale "2905" "exampleorg/examplerepo" "runner" || rc=$?

	if [[ "$rc" -ne 1 ]]; then
		fail "worker stale recovery continues dispatch" "expected rc=1, got rc=${rc}"
		return 0
	fi
	if [[ "$(tr '\n' ' ' <"$CLASSIFY_LOG")" != "2905|exampleorg/examplerepo " ]]; then
		fail "worker stale recovery classifies crash type" "classifier log: $(tr '\n' ' ' <"$CLASSIFY_LOG")"
		return 0
	fi
	if [[ "$FAST_FAIL_CALLS" -ne 1 ]]; then
		fail "worker stale recovery records fast-fail" "fast_fail_record called ${FAST_FAIL_CALLS} time(s)"
		return 0
	fi
	if [[ "$LAST_FAST_FAIL" != "2905|exampleorg/examplerepo|stale_timeout||no_work" ]]; then
		fail "worker stale recovery fast-fail payload" "payload: ${LAST_FAST_FAIL}"
		return 0
	fi
	pass "worker stale recovery still records no_work fast-fail"
	return 0
}

test_stale_recovery_blocked_by_dependency_blocks_redispatch() {
	export TEST_STALE_MODE="blocked_by"
	reset_observations
	local rc=0
	_dedup_layer6_assignee_and_stale "2905" "exampleorg/examplerepo" "runner" || rc=$?

	if [[ "$rc" -ne 0 ]]; then
		fail "blocked-by stale recovery blocks redispatch" "expected rc=0, got rc=${rc}"
		return 0
	fi
	if [[ "$FAST_FAIL_CALLS" -ne 0 ]]; then
		fail "blocked-by stale recovery skips fast-fail" "fast_fail_record called ${FAST_FAIL_CALLS} time(s): ${LAST_FAST_FAIL}"
		return 0
	fi
	if ! grep -q 'unresolved blocked-by dependency' "$LOGFILE" 2>/dev/null; then
		fail "blocked-by stale recovery logs redispatch block" "log: $(tr '\n' ' ' <"$LOGFILE")"
		return 0
	fi
	pass "blocked-by stale recovery blocks redispatch"
	return 0
}

test_terminal_stale_recovery_routes_consolidation_and_blocks() {
	export TEST_STALE_MODE="terminal"
	reset_observations
	local rc=0
	_dedup_layer6_assignee_and_stale "2905" "exampleorg/examplerepo" "runner" || rc=$?

	if [[ "$rc" -ne 0 ]]; then
		fail "terminal stale recovery blocks redispatch" "expected rc=0, got rc=${rc}"
		return 0
	fi
	if [[ "$CONSOLIDATION_CALLS" -ne 1 || "$LAST_CONSOLIDATION" != 2905\|exampleorg/examplerepo\|stale-recovery-threshold\|STALE_ESCALATED:* ]]; then
		fail "terminal stale recovery routes consolidation once" \
			"calls=${CONSOLIDATION_CALLS} payload=${LAST_CONSOLIDATION}"
		return 0
	fi
	pass "terminal stale recovery routes consolidation once and blocks redispatch"
	return 0
}

test_terminal_pr_checkpoint_routes_existing_consolidation_guard() {
	export TEST_STALE_MODE="terminal_pr"
	reset_observations
	local rc=0
	_dedup_layer6_assignee_and_stale "2905" "exampleorg/examplerepo" "runner" || rc=$?

	if [[ "$rc" -ne 0 ]]; then
		fail "terminal PR checkpoint blocks redispatch" "expected rc=0, got rc=${rc}"
		return 0
	fi
	if [[ "$CONSOLIDATION_CALLS" -ne 1 || "$LAST_CONSOLIDATION" != 2905\|exampleorg/examplerepo\|stale-pr-checkpoint\|STALE_PR_ESCALATED:* ]]; then
		fail "terminal PR checkpoint routes existing consolidation guard" \
			"calls=${CONSOLIDATION_CALLS} payload=${LAST_CONSOLIDATION}"
		return 0
	fi
	pass "terminal PR checkpoint routes consolidation guard and blocks redispatch"
	return 0
}

test_worker_draft_checkpoint_reaches_stale_guard_and_stays_blocked() {
	local result=""
	result=$(
		(
			local calls=""
			_dedup_layer1_ledger_check() { return 1; }
			_dedup_layer2_process_match() { return 1; }
			_dedup_layer3_title_match() { return 1; }
			_dedup_layer4_pr_evidence() { calls="${calls}4,"; return 2; }
			_dedup_layer5_dispatch_comment() { calls="${calls}5,"; return 1; }
			_dedup_layer6_assignee_and_stale() { calls="${calls}6,"; return 1; }

			local rc=0
			check_dispatch_dedup "2905" "exampleorg/examplerepo" "Issue #2905" "stale draft" "runner" || rc=$?
			printf '%s|%s' "$rc" "$calls"
		)
	)

	if [[ "$result" == "0|4,5,6," ]]; then
		pass "worker draft checkpoint reaches stale guard and cannot redispatch"
	else
		fail "worker draft checkpoint reaches stale guard and cannot redispatch" "result=${result}"
	fi
	return 0
}

test_protected_draft_remains_immediate_pr_block() {
	local result=""
	result=$(
		(
			local calls=""
			_dedup_layer1_ledger_check() { return 1; }
			_dedup_layer2_process_match() { return 1; }
			_dedup_layer3_title_match() { return 1; }
			_dedup_layer4_pr_evidence() { calls="${calls}4,"; return 0; }
			_dedup_layer5_dispatch_comment() { calls="${calls}5,"; return 1; }
			_dedup_layer6_assignee_and_stale() { calls="${calls}6,"; return 1; }

			local rc=0
			check_dispatch_dedup "2905" "exampleorg/examplerepo" "Issue #2905" "protected draft" "runner" || rc=$?
			printf '%s|%s' "$rc" "$calls"
		)
	)

	if [[ "$result" == "0|4," ]]; then
		pass "protected draft remains an immediate PR evidence block"
	else
		fail "protected draft remains an immediate PR evidence block" "result=${result}"
	fi
	return 0
}

test_stale_recovery_without_claim_skips_fast_fail
test_prelaunch_canary_stale_recovery_skips_fast_fail
test_stale_recovery_with_dispatch_claim_records_fast_fail
test_stale_recovery_blocked_by_dependency_blocks_redispatch
test_terminal_stale_recovery_routes_consolidation_and_blocks
test_terminal_pr_checkpoint_routes_existing_consolidation_guard
test_worker_draft_checkpoint_reaches_stale_guard_and_stays_blocked
test_protected_draft_remains_immediate_pr_block

printf '\nTests run: %s failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
