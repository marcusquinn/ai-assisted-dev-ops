#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
PROCESS_SCRIPT="${SCRIPT_DIR}/../pulse-merge-process.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""

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
	[[ -n "$detail" ]] && printf '     %s\n' "$detail"
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export GH_CALL_LOG="${TEST_ROOT}/gh-calls.log"
	: >"$LOGFILE"
	: >"$GH_CALL_LOG"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

define_functions_under_test() {
	local fn_src=""
	fn_src=$(awk '
		/^_attempt_pr_ci_rebase_retry\(\) \{/,/^}$/ { print }
		/^_dispatch_pr_repair_by_kind\(\) \{/,/^}$/ { print }
		/^_route_issue_origin_is_trusted\(\) \{/,/^}$/ { print }
		/^_route_pr_issue_labels_for_dispatch\(\) \{/,/^}$/ { print }
		/^_route_pr_feedback_terminal_guard\(\) \{/,/^}$/ { print }
		/^_route_pr_to_fix_worker\(\) \{/,/^}$/ { print }
	' "$PROCESS_SCRIPT")
	if [[ -z "$fn_src" ]]; then
		printf 'ERROR: could not extract functions from %s\n' "$PROCESS_SCRIPT" >&2
		return 1
	fi
	_OW_LABEL_PAT=',origin:worker,'
	eval "$fn_src"
	return 0
}

install_stubs() {
	ISSUE_LABELS="origin:worker,status:in-review"
	ISSUE_METADATA_FAIL=0
	PR_AUTHOR="maintainer"
	ROUTE_GUARD_RC=0
	COMPARE_FAIL=0
	COMPARE_BEHIND=1
	TERMINAL_CHECK_RC=0
	PENDING_CHECK_RC=1
	ADMIN_SAFETY_RC=0
	UPDATE_BRANCH_RC=0
	gh() {
		local arg1="${1:-}"
		local arg2="${2:-}"
		local args="$*"
		printf 'gh %s\n' "$args" >>"$GH_CALL_LOG"
		if [[ "$arg1" == "api" && "$args" == *"/compare/"* ]]; then
			[[ "${COMPARE_FAIL:-0}" == "1" ]] && return 1
			printf '%s\n' "${COMPARE_BEHIND:-1}"
			return 0
		fi
		if [[ "$arg1" == "api" && "$args" == *"repos/owner/repo/issues/456"* ]]; then
			[[ "${ISSUE_METADATA_FAIL:-0}" == "1" ]] && return 1
			printf '%s\n' "${ISSUE_LABELS:-origin:worker,status:in-review}"
			return 0
		fi
		if [[ "$arg1" == "pr" && "$arg2" == "update-branch" ]]; then
			return 1
		fi
		return 0
	}
	gh_pr_view() {
		local args="$*"
		printf 'gh_pr_view %s\n' "$args" >>"$GH_CALL_LOG"
		if [[ "$args" == *"baseRefName,headRefOid"* ]]; then
			printf 'main abc123\n'
			return 0
		fi
		if [[ "$args" == *"labels"* ]]; then
			printf 'origin:worker\n'
			return 0
		fi
		if [[ "$args" == *"author"* ]]; then
			printf '%s\n' "${PR_AUTHOR:-maintainer}"
			return 0
		fi
		return 0
	}
	_dispatch_ci_fix_worker() { local pr_number="$1"; local repo_slug="$2"; local linked_issue="$3"; printf 'dispatch-ci %s %s %s\n' "$pr_number" "$repo_slug" "$linked_issue" >>"$GH_CALL_LOG"; return 0; }
	_dispatch_pr_fix_worker() { local pr_number="$1"; local repo_slug="$2"; local linked_issue="$3"; printf 'dispatch-review %s %s %s\n' "$pr_number" "$repo_slug" "$linked_issue" >>"$GH_CALL_LOG"; return 0; }
	_dispatch_conflict_fix_worker() { local pr_number="$1"; local repo_slug="$2"; local linked_issue="$3"; printf 'dispatch-conflict %s %s %s\n' "$pr_number" "$repo_slug" "$linked_issue" >>"$GH_CALL_LOG"; return 0; }
	_check_required_checks_has_terminal_failure() { local repo_slug="$1"; local pr_number="$2"; local expected_head_sha="${3:-}"; printf 'terminal-check %s %s %s\n' "$repo_slug" "$pr_number" "$expected_head_sha" >>"$GH_CALL_LOG"; return "$TERMINAL_CHECK_RC"; }
	_check_required_checks_have_pending_or_in_progress() { local repo_slug="$1"; local pr_number="$2"; local expected_head_sha="${3:-}"; printf 'pending-check %s %s %s\n' "$repo_slug" "$pr_number" "$expected_head_sha" >>"$GH_CALL_LOG"; return "$PENDING_CHECK_RC"; }
	_pulse_merge_admin_safety_check() { local pr_number="$1"; local repo_slug="$2"; local expected_head_sha="${3:-}"; printf 'admin-safety %s %s %s\n' "$pr_number" "$repo_slug" "$expected_head_sha" >>"$GH_CALL_LOG"; return "$ADMIN_SAFETY_RC"; }
	_pmp_update_branch_rest() { local pr_number="$1"; local repo_slug="$2"; local head_oid="$3"; printf 'update-branch %s %s %s\n' "$pr_number" "$repo_slug" "$head_oid" >>"$GH_CALL_LOG"; return "$UPDATE_BRANCH_RC"; }
	_feedback_route_guard_existing_terminal_label() { local pr_number="$1"; local repo_slug="$2"; local linked_issue="$3"; local kind="$4"; printf 'route-guard %s %s %s %s\n' "$pr_number" "$repo_slug" "$linked_issue" "$kind" >>"$GH_CALL_LOG"; return "$ROUTE_GUARD_RC"; }
	_interactive_pr_is_stale() { return 1; }
	_is_collaborator_author() { local author="$1"; [[ "$author" == "maintainer" ]]; return $?; }
	return 0
}

test_ci_rebase_uses_provided_context() {
	: >"$GH_CALL_LOG"
	export COMPARE_BEHIND=0
	_attempt_pr_ci_rebase_retry "123" "owner/repo" "main" "deadbeef" || true

	if grep -q "gh_pr_view" "$GH_CALL_LOG"; then
		fail "CI rebase uses provided PR context" "Unexpected gh_pr_view call: $(cat "$GH_CALL_LOG")"
		return 0
	fi
	if ! grep -q "compare/main...deadbeef" "$GH_CALL_LOG"; then
		fail "CI rebase uses provided PR context" "Expected compare to use provided refs: $(cat "$GH_CALL_LOG")"
		return 0
	fi
	pass "CI rebase uses provided PR context"
	return 0
}

test_ci_rebase_fetches_when_context_missing() {
	: >"$GH_CALL_LOG"
	export COMPARE_BEHIND=0
	_attempt_pr_ci_rebase_retry "123" "owner/repo" || true

	if ! grep -q "gh_pr_view 123" "$GH_CALL_LOG"; then
		fail "CI rebase falls back to volatile refetch" "Expected fallback gh_pr_view: $(cat "$GH_CALL_LOG")"
		return 0
	fi
	pass "CI rebase falls back to volatile refetch"
	return 0
}

test_review_repair_rebase_requires_explicit_behind_evidence() {
	install_stubs
	: >"$GH_CALL_LOG"
	COMPARE_FAIL=1
	local rc=0
	_attempt_pr_ci_rebase_retry "123" "owner/repo" "main" "deadbeef" "review-repair" || rc=$?

	if [[ "$rc" -ne 1 ]] || grep -q '^update-branch ' "$GH_CALL_LOG"; then
		fail "review-repair rebase requires explicit behind evidence" "rc=${rc}; calls=$(tr '\n' ';' <"$GH_CALL_LOG")"
		return 0
	fi
	pass "review-repair rebase fails closed without explicit behind evidence"
	return 0
}

test_review_repair_rebase_waits_for_active_checks() {
	install_stubs
	: >"$GH_CALL_LOG"
	COMPARE_BEHIND=1
	PENDING_CHECK_RC=0
	local rc=0
	_attempt_pr_ci_rebase_retry "123" "owner/repo" "main" "deadbeef" "review-repair" || rc=$?

	if [[ "$rc" -ne 1 ]] || grep -q '^update-branch ' "$GH_CALL_LOG"; then
		fail "review-repair rebase waits for active checks" "rc=${rc}; calls=$(tr '\n' ';' <"$GH_CALL_LOG")"
		return 0
	fi
	pass "review-repair rebase does not restart active required checks"
	return 0
}

test_review_repair_rebase_revalidates_live_pr_authority() {
	install_stubs
	: >"$GH_CALL_LOG"
	COMPARE_BEHIND=1
	TERMINAL_CHECK_RC=0
	PENDING_CHECK_RC=1
	ADMIN_SAFETY_RC=1
	local rc=0
	_attempt_pr_ci_rebase_retry "123" "owner/repo" "main" "deadbeef" "review-repair" || rc=$?

	if [[ "$rc" -ne 1 ]] || grep -q '^update-branch ' "$GH_CALL_LOG" \
		|| ! grep -qF 'admin-safety 123 owner/repo deadbeef' "$GH_CALL_LOG"; then
		fail "review-repair rebase revalidates live PR authority" "rc=${rc}; calls=$(tr '\n' ';' <"$GH_CALL_LOG")"
		return 0
	fi
	pass "review-repair rebase preserves PR-level maintainer holds before update"
	return 0
}

test_review_repair_rebase_updates_when_strictly_eligible() {
	install_stubs
	: >"$GH_CALL_LOG"
	COMPARE_BEHIND=1
	TERMINAL_CHECK_RC=0
	PENDING_CHECK_RC=1
	UPDATE_BRANCH_RC=0
	local rc=0
	_attempt_pr_ci_rebase_retry "123" "owner/repo" "main" "deadbeef" "review-repair" || rc=$?

	if [[ "$rc" -ne 0 ]] || ! grep -q '^update-branch 123 owner/repo deadbeef$' "$GH_CALL_LOG" \
		|| ! grep -qF 'terminal-check owner/repo 123 deadbeef' "$GH_CALL_LOG" \
		|| ! grep -qF 'pending-check owner/repo 123 deadbeef' "$GH_CALL_LOG" \
		|| ! grep -qF 'admin-safety 123 owner/repo deadbeef' "$GH_CALL_LOG"; then
		fail "review-repair rebase updates when strictly eligible" "rc=${rc}; calls=$(tr '\n' ';' <"$GH_CALL_LOG")"
		return 0
	fi
	pass "review-repair rebase updates only after settled terminal failure and behind evidence"
	return 0
}

test_route_uses_provided_labels() {
	: >"$GH_CALL_LOG"
	_route_pr_to_fix_worker "123" "owner/repo" "456" "ci" "origin:worker" || true

	if grep -q "gh_pr_view" "$GH_CALL_LOG"; then
		fail "fix-worker route uses provided labels" "Unexpected label refetch: $(cat "$GH_CALL_LOG")"
		return 0
	fi
	if ! grep -q "dispatch-ci 123 owner/repo 456" "$GH_CALL_LOG"; then
		fail "fix-worker route uses provided labels" "Expected CI dispatch: $(cat "$GH_CALL_LOG")"
		return 0
	fi
	pass "fix-worker route uses provided labels"
	return 0
}

test_route_falls_back_to_linked_worker_issue_for_ci() {
	: >"$GH_CALL_LOG"
	export ISSUE_LABELS="origin:worker,status:in-review"
	export PR_AUTHOR="maintainer"
	_route_pr_to_fix_worker "8614" "owner/repo" "456" "ci" "status:in-review" || true

	if ! grep -q "dispatch-ci 8614 owner/repo 456" "$GH_CALL_LOG"; then
		fail "fix-worker route falls back to linked worker issue for CI" "Expected CI dispatch: $(cat "$GH_CALL_LOG")"
		return 0
	fi
	if ! grep -q "repos/owner/repo/issues/456" "$GH_CALL_LOG"; then
		fail "fix-worker route falls back to linked worker issue for CI" "Expected linked issue label fetch: $(cat "$GH_CALL_LOG")"
		return 0
	fi
	pass "fix-worker route falls back to linked worker issue for CI"
	return 0
}

test_route_falls_back_to_linked_worker_issue_for_conflict() {
	: >"$GH_CALL_LOG"
	export ISSUE_LABELS="origin:worker,status:in-review"
	export PR_AUTHOR="maintainer"
	_route_pr_to_fix_worker "8592" "owner/repo" "456" "conflict" "status:in-review" "dirty PR" || true

	if ! grep -q "dispatch-conflict 8592 owner/repo 456" "$GH_CALL_LOG"; then
		fail "fix-worker route falls back to linked worker issue for conflict" "Expected conflict dispatch: $(cat "$GH_CALL_LOG")"
		return 0
	fi
	pass "fix-worker route falls back to linked worker issue for conflict"
	return 0
}

test_issue_origin_fallback_requires_collaborator_pr_author() {
	: >"$GH_CALL_LOG"
	export ISSUE_LABELS="origin:worker,status:in-review"
	export PR_AUTHOR="external"
	_route_pr_to_fix_worker "8613" "owner/repo" "456" "conflict" "status:in-review" "dirty PR" || true

	if grep -q "dispatch-conflict" "$GH_CALL_LOG"; then
		fail "issue-origin fallback requires collaborator PR author" "Unexpected dispatch: $(cat "$GH_CALL_LOG")"
		return 0
	fi
	pass "issue-origin fallback requires collaborator PR author"
	return 0
}

test_fresh_interactive_pr_is_not_routed() {
	install_stubs
	: >"$GH_CALL_LOG"
	_route_pr_to_fix_worker "9001" "owner/repo" "456" "review" "origin:interactive" || true
	if grep -q "dispatch-" "$GH_CALL_LOG"; then
		fail "fresh interactive PR is not routed" "Unexpected dispatch: $(cat "$GH_CALL_LOG")"
		return 0
	fi
	pass "fresh interactive PR is not routed"
	return 0
}

test_interactive_route_requires_confirmed_handover() {
	install_stubs
	_interactive_pr_is_stale() { return 0; }
	_interactive_pr_trigger_handover() { return 1; }
	: >"$GH_CALL_LOG"
	_route_pr_to_fix_worker "9002" "owner/repo" "456" "review" "origin:interactive" || true
	if grep -q "dispatch-" "$GH_CALL_LOG"; then
		fail "interactive route requires confirmed handover" "Unexpected dispatch: $(cat "$GH_CALL_LOG")"
		return 0
	fi
	pass "interactive route requires confirmed handover"
	return 0
}

test_interactive_route_dispatches_after_confirmed_takeover() {
	install_stubs
	_interactive_pr_is_stale() { return 0; }
	_interactive_pr_trigger_handover() { return 0; }
	gh_pr_view() {
		printf 'origin:interactive,origin:worker-takeover\n'
		return 0
	}
	: >"$GH_CALL_LOG"
	_route_pr_to_fix_worker "9003" "owner/repo" "456" "review" "origin:interactive" || true
	if ! grep -q "dispatch-review 9003 owner/repo 456" "$GH_CALL_LOG"; then
		fail "interactive route dispatches after confirmed takeover" "Expected dispatch: $(cat "$GH_CALL_LOG")"
		return 0
	fi
	pass "interactive route dispatches after confirmed takeover"
	return 0
}

test_missing_pr_label_metadata_fails_closed() {
	install_stubs
	gh_pr_view() { return 1; }
	: >"$GH_CALL_LOG"
	_route_pr_to_fix_worker "9004" "owner/repo" "456" "review" "" || true
	if grep -q "dispatch-" "$GH_CALL_LOG"; then
		fail "missing PR label metadata fails closed" "Unexpected dispatch: $(cat "$GH_CALL_LOG")"
		return 0
	fi
	pass "missing PR label metadata fails closed"
	return 0
}

test_explicit_ownership_labels_block_route_recovery() {
	local labels=""
	for labels in "origin:worker,no-takeover,review-routed-to-issue" \
		"origin:worker,external-contributor,review-routed-to-issue" \
		"origin:worker,needs-maintainer-review,review-routed-to-issue"; do
		install_stubs
		: >"$GH_CALL_LOG"
		_route_pr_to_fix_worker "9010" "owner/repo" "456" "review" "$labels" || true
		if grep -Eq 'route-guard|dispatch-' "$GH_CALL_LOG"; then
			fail "explicit ownership labels block route recovery" \
				"labels=${labels}; calls=$(tr '\n' ';' <"$GH_CALL_LOG")"
			return 0
		fi
	done
	pass "no-takeover, external, and maintainer holds precede route recovery"
	return 0
}

test_linked_issue_maintainer_hold_blocks_route_recovery() {
	install_stubs
	ISSUE_LABELS="origin:worker,status:in-review,needs-maintainer-review"
	: >"$GH_CALL_LOG"
	_route_pr_to_fix_worker "9011" "owner/repo" "456" "ci" \
		"origin:worker,ci-feedback-routed" || true
	if grep -Eq 'route-guard|dispatch-' "$GH_CALL_LOG"; then
		fail "linked issue maintainer hold blocks route recovery" \
			"calls=$(tr '\n' ';' <"$GH_CALL_LOG")"
		return 0
	fi
	pass "linked issue maintainer hold blocks route recovery"
	return 0
}

test_linked_issue_metadata_failure_is_retryable() {
	install_stubs
	ISSUE_METADATA_FAIL=1
	: >"$GH_CALL_LOG"
	local route_rc=0
	_route_pr_to_fix_worker "9014" "owner/repo" "456" "conflict" \
		"origin:worker" || route_rc=$?
	if [[ "$route_rc" -ne 75 ]] || grep -Eq 'route-guard|dispatch-' "$GH_CALL_LOG"; then
		fail "linked issue metadata failure is retryable" \
			"rc=${route_rc}; calls=$(tr '\n' ';' <"$GH_CALL_LOG")"
		return 0
	fi
	pass "linked issue metadata failure preserves destructive routes for retry"
	return 0
}

test_fresh_interactive_route_does_not_enter_terminal_guard() {
	install_stubs
	: >"$GH_CALL_LOG"
	_route_pr_to_fix_worker "9012" "owner/repo" "456" "review" \
		"origin:interactive,review-routed-to-issue" || true
	if grep -Eq 'route-guard|dispatch-' "$GH_CALL_LOG"; then
		fail "fresh interactive route does not enter terminal guard" \
			"calls=$(tr '\n' ';' <"$GH_CALL_LOG")"
		return 0
	fi
	pass "fresh interactive ownership is checked before route recovery"
	return 0
}

test_review_terminal_label_rechecks_current_evidence() {
	install_stubs
	: >"$GH_CALL_LOG"
	local route_rc=0
	_route_pr_to_fix_worker "9015" "owner/repo" "456" "review" \
		"origin:worker,review-routed-to-issue" || route_rc=$?
	if [[ "$route_rc" -ne 0 ]] \
		|| ! grep -qF 'dispatch-review 9015 owner/repo 456' "$GH_CALL_LOG" \
		|| grep -qF 'route-guard 9015 owner/repo 456 review' "$GH_CALL_LOG"; then
		fail "review terminal label delegates to evidence-aware dispatcher" \
			"rc=${route_rc}; calls=$(tr '\n' ';' <"$GH_CALL_LOG")"
		return 0
	fi
	pass "review terminal label delegates to evidence-aware dispatcher"
	return 0
}

test_trusted_worker_terminal_guard_outcome_propagates() {
	install_stubs
	ROUTE_GUARD_RC=75
	: >"$GH_CALL_LOG"
	local route_rc=0
	_route_pr_to_fix_worker "9013" "owner/repo" "456" "ci" \
		"origin:worker,ci-feedback-routed" || route_rc=$?
	if [[ "$route_rc" -ne 75 ]] || ! grep -qF 'route-guard 9013 owner/repo 456 ci' "$GH_CALL_LOG" \
		|| grep -qF 'dispatch-ci' "$GH_CALL_LOG"; then
		fail "trusted worker terminal guard outcome propagates" \
			"rc=${route_rc}; calls=$(tr '\n' ';' <"$GH_CALL_LOG")"
		return 0
	fi
	pass "trusted worker partial-route outcome propagates without dispatch"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env
	define_functions_under_test
	install_stubs
	test_ci_rebase_uses_provided_context
	test_ci_rebase_fetches_when_context_missing
	test_review_repair_rebase_requires_explicit_behind_evidence
	test_review_repair_rebase_waits_for_active_checks
	test_review_repair_rebase_revalidates_live_pr_authority
	test_review_repair_rebase_updates_when_strictly_eligible
	test_route_uses_provided_labels
	test_route_falls_back_to_linked_worker_issue_for_ci
	test_route_falls_back_to_linked_worker_issue_for_conflict
	test_issue_origin_fallback_requires_collaborator_pr_author
	test_fresh_interactive_pr_is_not_routed
	test_interactive_route_requires_confirmed_handover
	test_interactive_route_dispatches_after_confirmed_takeover
	test_missing_pr_label_metadata_fails_closed
	test_explicit_ownership_labels_block_route_recovery
	test_linked_issue_maintainer_hold_blocks_route_recovery
	test_linked_issue_metadata_failure_is_retryable
	test_fresh_interactive_route_does_not_enter_terminal_guard
	test_review_terminal_label_rechecks_current_evidence
	test_trusted_worker_terminal_guard_outcome_propagates
	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	[[ "$TESTS_FAILED" -eq 0 ]]
	return $?
}

main "$@"
