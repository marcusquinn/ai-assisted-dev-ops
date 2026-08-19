#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
MERGE_SCRIPT="${SCRIPT_DIR}/../pulse-merge.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
PMRC_BLOCKER_REVIEW_BOT_THREADS="review-bot-threads"
PMRC_BLOCKER_REQUIRED_REVIEW_THREADS="required-review-threads"

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi
	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '     %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

setup_test_env() {
	TEST_ROOT="$(mktemp -d -t pulse-review-remediation.XXXXXX)"
	mkdir -p "${TEST_ROOT}/scripts" "${TEST_ROOT}/repo" "${TEST_ROOT}/config" "${TEST_ROOT}/state"
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export SCANNER_LOG="${TEST_ROOT}/scanner.log"
	export AIDEVOPS_REPOS_JSON="${TEST_ROOT}/config/repos.json"
	export AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR="${TEST_ROOT}/state"
	printf '{"initialized_repos":[{"slug":"owner/repo","path":"%s"}]}\n' "${TEST_ROOT}/repo" >"$AIDEVOPS_REPOS_JSON"
	cat >"${TEST_ROOT}/scripts/pr-review-thread-response-scanner.sh" <<'SCANNER'
#!/usr/bin/env bash
printf 'include_human=%s args=%s\n' "${PR_REVIEW_THREAD_RESPONSE_INCLUDE_HUMAN:-false}" "$*" >>"${SCANNER_LOG:?}"
if [[ -n "${SCANNER_ATTENTION_REASON:-}" ]]; then
	safe_slug="$(printf '%s' "$2" | tr '/:' '--')"
	printf 'analysis_complete=true\nmaintainer_attention=true\nblocker_reason=%s\n' "$SCANNER_ATTENTION_REASON" \
		>"${AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR:?}/${safe_slug}-${4}.state"
fi
exit "${SCANNER_RC:-0}"
SCANNER
	chmod +x "${TEST_ROOT}/scripts/pr-review-thread-response-scanner.sh"
	: >"$LOGFILE"
	: >"$SCANNER_LOG"
	_PULSE_MERGE_DIR="${TEST_ROOT}/scripts"
	_OW_LABEL_PAT=",origin:worker,"
	export SCANNER_RC=0
	PULSE_REVIEW_REMEDIATION_DEFERRED_RC=10
	PULSE_REVIEW_REMEDIATION_NO_MATCH_RC=11
	PULSE_REVIEW_REMEDIATION_MAINTAINER_ATTENTION_RC=12
	PULSE_REVIEW_REMEDIATION_RETRYABLE_FAILURE_RC=13
	PULSE_REVIEW_REMEDIATION_REPEAT_EXHAUSTED="repeat_exhausted"
	PULSE_MERGE_BOOL_TRUE="true"
	_PULSE_MERGE_REMEDIATION_OUTCOME=""
	_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND=""
	unset AIDEVOPS_CHANGES_REQUESTED_THREAD_REMEDIATION_FIRST
	unset SCANNER_ATTENTION_REASON
	unset DRY_RUN
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	TEST_ROOT=""
	return 0
}

define_helpers_under_test() {
	local src_repo_path="" src_repeat_exhausted="" src_dispatch="" src_maybe_dispatch="" src_preflight_dispatch="" src_enabled="" src_changes_gate=""
	src_repo_path=$(awk '
		/^_pulse_merge_repo_path_for_slug\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$MERGE_SCRIPT")
	src_repeat_exhausted=$(awk '
		/^_pulse_merge_review_thread_repeat_exhausted\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$MERGE_SCRIPT")
	src_dispatch=$(awk '
		/^_pulse_merge_dispatch_review_thread_remediation\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$MERGE_SCRIPT")
	src_maybe_dispatch=$(awk '
		/^_pulse_merge_maybe_dispatch_review_thread_remediation\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$MERGE_SCRIPT")
	src_preflight_dispatch=$(awk '
		/^_pulse_merge_maybe_dispatch_preflight_remediation\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$MERGE_SCRIPT")
	src_enabled=$(awk '
		/^_pulse_merge_changes_requested_thread_remediation_first_enabled\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$MERGE_SCRIPT")
	src_changes_gate=$(awk '
		/^_handle_changes_requested_review_gate\(\)[[:space:]]*\{[[:space:]]*$/, /^\}[[:space:]]*$/ { print }
	' "$MERGE_SCRIPT")
	if [[ -z "$src_repo_path" || -z "$src_repeat_exhausted" || -z "$src_dispatch" || -z "$src_maybe_dispatch" || -z "$src_preflight_dispatch" || -z "$src_enabled" || -z "$src_changes_gate" ]]; then
		printf 'ERROR: could not extract helpers from %s\n' "$MERGE_SCRIPT" >&2
		return 1
	fi
	# shellcheck disable=SC1090
	eval "$src_repo_path"
	# shellcheck disable=SC1090
	eval "$src_repeat_exhausted"
	# shellcheck disable=SC1090
	eval "$src_dispatch"
	# shellcheck disable=SC1090
	eval "$src_maybe_dispatch"
	# shellcheck disable=SC1090
	eval "$src_preflight_dispatch"
	# shellcheck disable=SC1090
	eval "$src_enabled"
	# shellcheck disable=SC1090
	eval "$src_changes_gate"
	return 0
}

test_review_bot_preflight_blocker_dispatches_and_is_consumed() {
	setup_test_env
	define_helpers_under_test || {
		teardown_test_env
		return 0
	}
	_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_REVIEW_BOT_THREADS"

	_pulse_merge_maybe_dispatch_preflight_remediation 77 owner/repo

	if grep -q 'include_human=true args=dispatch-pr owner/repo' "$SCANNER_LOG" &&
		grep -q ' 77$' "$SCANNER_LOG" &&
		grep -q 'after unresolved review-bot thread preflight blocker' "$LOGFILE" &&
		[[ -z "$_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND" ]]; then
		print_result "typed review-bot preflight blocker queues and consumes remediation" 0
	else
		print_result "typed review-bot preflight blocker queues and consumes remediation" 1 \
			"marker=${_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND:-<none>}, scanner=$(tr '\n' ';' <"$SCANNER_LOG"), log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_required_review_thread_preflight_blocker_dispatches() {
	setup_test_env
	define_helpers_under_test || {
		teardown_test_env
		return 0
	}
	_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_REQUIRED_REVIEW_THREADS"

	_pulse_merge_maybe_dispatch_preflight_remediation 77 owner/repo

	if grep -q 'include_human=true args=dispatch-pr owner/repo' "$SCANNER_LOG" &&
		grep -q 'after required unresolved review-thread preflight blocker' "$LOGFILE" &&
		[[ -z "$_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND" ]]; then
		print_result "typed required-thread preflight blocker queues remediation" 0
	else
		print_result "typed required-thread preflight blocker queues remediation" 1 \
			"marker=${_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND:-<none>}, scanner=$(tr '\n' ';' <"$SCANNER_LOG"), log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_unrelated_preflight_blocker_does_not_dispatch() {
	setup_test_env
	define_helpers_under_test || {
		teardown_test_env
		return 0
	}
	_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="required-checks"

	_pulse_merge_maybe_dispatch_preflight_remediation 77 owner/repo

	if [[ ! -s "$SCANNER_LOG" && -z "$_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND" ]]; then
		print_result "unrelated preflight blocker is consumed without review remediation" 0
	else
		print_result "unrelated preflight blocker is consumed without review remediation" 1 \
			"marker=${_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND:-<none>}, scanner=$(tr '\n' ';' <"$SCANNER_LOG")"
	fi
	teardown_test_env
	return 0
}

test_failed_preflight_dispatch_stays_blocked_and_consumes_marker() {
	setup_test_env
	export SCANNER_RC=13
	define_helpers_under_test || {
		teardown_test_env
		return 0
	}
	_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_REQUIRED_REVIEW_THREADS"

	_pulse_merge_maybe_dispatch_preflight_remediation 77 owner/repo

	if grep -q 'review-thread remediation scan/launch failed for PR #77 in owner/repo' "$LOGFILE" &&
		! grep -q 'review-thread remediation queued for PR #77 in owner/repo' "$LOGFILE" &&
		[[ -z "$_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND" ]]; then
		print_result "failed preflight dispatch consumes typed marker" 0
	else
		print_result "failed preflight dispatch consumes typed marker" 1 \
			"marker=${_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND:-<none>}, log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_no_match_preflight_dispatch_converges_and_consumes_marker() {
	setup_test_env
	export SCANNER_RC=11
	define_helpers_under_test || {
		teardown_test_env
		return 0
	}
	_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_REQUIRED_REVIEW_THREADS"

	_pulse_merge_maybe_dispatch_preflight_remediation 77 owner/repo

	if [[ "$_PULSE_MERGE_REMEDIATION_OUTCOME" == "converged" && -z "$_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND" ]] &&
		grep -q 'review-thread remediation converged for PR #77 in owner/repo' "$LOGFILE" &&
		! grep -q 'review-thread remediation queued for PR #77 in owner/repo' "$LOGFILE"; then
		print_result "no-match preflight outcome converges and consumes typed marker" 0
	else
		print_result "no-match preflight outcome converges and consumes typed marker" 1 \
			"outcome=${_PULSE_MERGE_REMEDIATION_OUTCOME:-<none>}, marker=${_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND:-<none>}, log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_terminal_attention_preflight_dispatch_stays_fail_closed() {
	setup_test_env
	export SCANNER_RC=12
	define_helpers_under_test || {
		teardown_test_env
		return 0
	}
	_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_REQUIRED_REVIEW_THREADS"

	_pulse_merge_maybe_dispatch_preflight_remediation 77 owner/repo

	if [[ "$_PULSE_MERGE_REMEDIATION_OUTCOME" == "maintainer_attention" && -z "$_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND" ]] &&
		grep -q 'review-thread remediation reached terminal maintainer attention for PR #77 in owner/repo' "$LOGFILE" &&
		! grep -q 'review-thread remediation queued for PR #77 in owner/repo' "$LOGFILE"; then
		print_result "terminal-attention preflight outcome remains fail-closed" 0
	else
		print_result "terminal-attention preflight outcome remains fail-closed" 1 \
			"outcome=${_PULSE_MERGE_REMEDIATION_OUTCOME:-<none>}, marker=${_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND:-<none>}, log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_dry_run_preflight_blocker_never_dispatches() {
	setup_test_env
	DRY_RUN=1
	define_helpers_under_test || {
		teardown_test_env
		return 0
	}
	_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND="$PMRC_BLOCKER_REVIEW_BOT_THREADS"

	_pulse_merge_maybe_dispatch_preflight_remediation 77 owner/repo

	if [[ ! -s "$SCANNER_LOG" && -z "$_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND" ]]; then
		print_result "dry-run consumes preflight blocker without write dispatch" 0
	else
		print_result "dry-run consumes preflight blocker without write dispatch" 1 \
			"marker=${_PULSE_MERGE_PREFLIGHT_BLOCKER_KIND:-<none>}, scanner=$(tr '\n' ';' <"$SCANNER_LOG")"
	fi
	teardown_test_env
	return 0
}

test_unresolved_conversation_dispatches_targeted_human_thread_remediation() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	_pulse_merge_maybe_dispatch_review_thread_remediation 77 owner/repo 'GraphQL: A conversation must be resolved before merging'

	if grep -q 'include_human=true args=dispatch-pr owner/repo' "$SCANNER_LOG" \
		&& grep -q ' 77$' "$SCANNER_LOG" \
		&& grep -q 'review-thread remediation queued for PR #77 in owner/repo' "$LOGFILE"; then
		print_result "unresolved conversation queues targeted human-thread remediation" 0
	else
		print_result "unresolved conversation queues targeted human-thread remediation" 1 \
			"scanner=$(tr '\n' ';' <"$SCANNER_LOG"), log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_repo_path_lookup_ignores_slug_case() {
	setup_test_env
	printf '{"initialized_repos":[{"slug":"Owner/Repo","path":"%s"}]}\n' "${TEST_ROOT}/repo" >"$AIDEVOPS_REPOS_JSON"
	define_helpers_under_test || { teardown_test_env; return 0; }

	local repo_path=""
	repo_path=$(_pulse_merge_repo_path_for_slug owner/repo 2>/dev/null) || repo_path=""
	_pulse_merge_maybe_dispatch_review_thread_remediation 77 owner/repo 'GraphQL: A conversation must be resolved before merging'

	if [[ "$repo_path" == "${TEST_ROOT}/repo" ]] \
		&& grep -q 'include_human=true args=dispatch-pr owner/repo' "$SCANNER_LOG" \
		&& grep -q ' 77$' "$SCANNER_LOG"; then
		print_result "repo path lookup ignores slug case" 0
	else
		print_result "repo path lookup ignores slug case" 1 \
			"repo_path=${repo_path}, scanner=$(tr '\n' ';' <"$SCANNER_LOG"), log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_other_merge_failures_do_not_dispatch_review_thread_remediation() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }

	_pulse_merge_maybe_dispatch_review_thread_remediation 77 owner/repo 'GraphQL: required status check is expected'

	if [[ ! -s "$SCANNER_LOG" ]]; then
		print_result "non-conversation merge failures do not dispatch remediation" 0
	else
		print_result "non-conversation merge failures do not dispatch remediation" 1 "scanner=$(tr '\n' ';' <"$SCANNER_LOG")"
	fi
	teardown_test_env
	return 0
}

test_changes_requested_routes_by_default() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	local route_log="${TEST_ROOT}/route.log"
	: >"$route_log"
	_route_pr_to_fix_worker() {
		local pr_number="$1"
		local repo_slug="$2"
		printf 'route %s %s\n' "$pr_number" "$repo_slug" >>"$route_log"
		return 0
	}
	_pulse_merge_dismiss_coderabbit_nits() { return 1; }

	if _handle_changes_requested_review_gate 77 owner/repo CHANGES_REQUESTED 42 "origin:worker"; then
		print_result "CHANGES_REQUESTED routes by default" 1 \
			"Expected gate to skip merge after default routing"
	elif [[ ! -s "$SCANNER_LOG" ]] && grep -q 'route 77 owner/repo' "$route_log"; then
		print_result "CHANGES_REQUESTED routes by default" 0
	else
		print_result "CHANGES_REQUESTED routes by default" 1 \
			"scanner=$(tr '\n' ';' <"$SCANNER_LOG"), route=$(tr '\n' ';' <"$route_log"), log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_changes_requested_translates_maintainer_route_outcome() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	local route_log="${TEST_ROOT}/route.log"
	: >"$route_log"
	_route_pr_to_fix_worker() {
		printf 'route\n' >>"$route_log"
		return 76
	}
	_pulse_merge_dismiss_coderabbit_nits() { return 1; }

	_handle_changes_requested_review_gate 77 owner/repo CHANGES_REQUESTED 42 "origin:worker" || true
	if grep -q '^route$' "$route_log" \
		&& grep -qF 'feedback finalization for PR #77 in owner/repo requires maintainer review' "$LOGFILE"; then
		print_result "CHANGES_REQUESTED translates maintainer route outcome" 0
	else
		print_result "CHANGES_REQUESTED translates maintainer route outcome" 1 \
			"route=$(tr '\n' ';' <"$route_log"), log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_changes_requested_translates_deferred_route_outcome() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	local route_log="${TEST_ROOT}/route.log"
	: >"$route_log"
	_route_pr_to_fix_worker() {
		printf 'route\n' >>"$route_log"
		return 75
	}
	_pulse_merge_dismiss_coderabbit_nits() { return 1; }

	_handle_changes_requested_review_gate 77 owner/repo CHANGES_REQUESTED 42 "origin:worker" || true
	if grep -q '^route$' "$route_log" \
		&& grep -qF 'feedback finalization deferred for PR #77 in owner/repo; preserving retryable route state' "$LOGFILE"; then
		print_result "CHANGES_REQUESTED translates deferred route outcome" 0
	else
		print_result "CHANGES_REQUESTED translates deferred route outcome" 1 \
			"route=$(tr '\n' ';' <"$route_log"), log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_changes_requested_opt_in_dispatches_remediation_without_routing() {
	setup_test_env
	export AIDEVOPS_CHANGES_REQUESTED_THREAD_REMEDIATION_FIRST=1
	define_helpers_under_test || { teardown_test_env; return 0; }
	local route_log="${TEST_ROOT}/route.log"
	: >"$route_log"
	_route_pr_to_fix_worker() {
		local pr_number="$1"
		local repo_slug="$2"
		printf 'route %s %s\n' "$pr_number" "$repo_slug" >>"$route_log"
		return 0
	}
	_pulse_merge_dismiss_coderabbit_nits() { return 1; }

	if _handle_changes_requested_review_gate 77 owner/repo CHANGES_REQUESTED 42 "origin:worker"; then
		print_result "opt-in CHANGES_REQUESTED remediation keeps PR open before routing" 1 \
			"Expected gate to skip merge after queuing remediation"
	elif grep -q 'include_human=true args=dispatch-pr owner/repo' "$SCANNER_LOG" \
		&& grep -q ' 77$' "$SCANNER_LOG" \
		&& [[ ! -s "$route_log" ]] \
		&& grep -q 'review-thread remediation queued for PR #77 in owner/repo after CHANGES_REQUESTED review gate' "$LOGFILE"; then
		print_result "opt-in CHANGES_REQUESTED remediation keeps PR open before routing" 0
	else
		print_result "opt-in CHANGES_REQUESTED remediation keeps PR open before routing" 1 \
			"scanner=$(tr '\n' ';' <"$SCANNER_LOG"), route=$(tr '\n' ';' <"$route_log"), log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_changes_requested_routes_when_remediation_unavailable() {
	setup_test_env
	export AIDEVOPS_CHANGES_REQUESTED_THREAD_REMEDIATION_FIRST=1
	chmod -x "${TEST_ROOT}/scripts/pr-review-thread-response-scanner.sh"
	define_helpers_under_test || { teardown_test_env; return 0; }
	local route_log="${TEST_ROOT}/route.log"
	: >"$route_log"
	_route_pr_to_fix_worker() {
		local pr_number="$1"
		local repo_slug="$2"
		printf 'route %s %s\n' "$pr_number" "$repo_slug" >>"$route_log"
		return 0
	}
	_pulse_merge_dismiss_coderabbit_nits() { return 1; }

	if _handle_changes_requested_review_gate 77 owner/repo CHANGES_REQUESTED 42 "origin:worker"; then
		print_result "CHANGES_REQUESTED falls back to routing when remediation unavailable" 1 \
			"Expected gate to skip merge after fallback routing"
	elif grep -q 'route 77 owner/repo' "$route_log" \
		&& grep -q 'review-thread remediation skipped for PR #77 in owner/repo: scanner missing or not executable' "$LOGFILE"; then
		print_result "CHANGES_REQUESTED falls back to routing when remediation unavailable" 0
	else
		print_result "CHANGES_REQUESTED falls back to routing when remediation unavailable" 1 \
			"route=$(tr '\n' ';' <"$route_log"), log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_changes_requested_active_remediation_preserves_pr_without_routing() {
	setup_test_env
	export AIDEVOPS_CHANGES_REQUESTED_THREAD_REMEDIATION_FIRST=1
	export SCANNER_RC=10
	define_helpers_under_test || { teardown_test_env; return 0; }
	local route_log="${TEST_ROOT}/route.log"
	: >"$route_log"
	_route_pr_to_fix_worker() {
		local pr_number="$1"
		local repo_slug="$2"
		printf 'route %s %s\n' "$pr_number" "$repo_slug" >>"$route_log"
		return 0
	}
	_pulse_merge_dismiss_coderabbit_nits() { return 1; }

	if _handle_changes_requested_review_gate 77 owner/repo CHANGES_REQUESTED 42 "origin:worker"; then
		print_result "active response-worker remediation preserves CHANGES_REQUESTED PR" 1 \
			"Expected gate to skip merge while preserving the active remediation"
	elif [[ ! -s "$route_log" ]] \
		&& grep -q 'review-thread remediation deferred for PR #77 in owner/repo' "$LOGFILE" \
		&& grep -q 'response remediation already active/deferred, preserving PR' "$LOGFILE"; then
		print_result "active response-worker remediation preserves CHANGES_REQUESTED PR" 0
	else
		print_result "active response-worker remediation preserves CHANGES_REQUESTED PR" 1 \
			"route=$(tr '\n' ';' <"$route_log"), log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_changes_requested_converged_remediation_exposes_repair_only_mode() {
	setup_test_env
	export AIDEVOPS_CHANGES_REQUESTED_THREAD_REMEDIATION_FIRST=1
	export SCANNER_RC=11
	define_helpers_under_test || {
		teardown_test_env
		return 0
	}
	local route_log="${TEST_ROOT}/route.log"
	: >"$route_log"
	_route_pr_to_fix_worker() {
		local pr_number="$1"
		local repo_slug="$2"
		printf 'route %s %s\n' "$pr_number" "$repo_slug" >>"$route_log"
		return 0
	}
	_pulse_merge_dismiss_coderabbit_nits() {
		return 1
	}
	local review_gate_mode="merge"
	local gate_rc=0

	_handle_changes_requested_review_gate 77 owner/repo CHANGES_REQUESTED 42 "origin:worker" "" review_gate_mode || gate_rc=$?
	if [[ "$gate_rc" -eq 1 && "$review_gate_mode" == "ci-rebase-only" && ! -s "$route_log" ]] &&
		grep -q 'preserving the review block while allowing trust-gated CI-drift repair evaluation' "$LOGFILE"; then
		print_result "converged response remediation exposes repair-only mode" 0
	else
		print_result "converged response remediation exposes repair-only mode" 1 \
			"gate_rc=${gate_rc}, mode=${review_gate_mode}, route=$(tr '\n' ';' <"$route_log"), log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_changes_requested_terminal_attention_preserves_pr_without_routing() {
	setup_test_env
	export AIDEVOPS_CHANGES_REQUESTED_THREAD_REMEDIATION_FIRST=1
	export SCANNER_RC=12
	define_helpers_under_test || {
		teardown_test_env
		return 0
	}
	local route_log="${TEST_ROOT}/route.log"
	: >"$route_log"
	_route_pr_to_fix_worker() {
		local pr_number="$1"
		local repo_slug="$2"
		printf 'route %s %s\n' "$pr_number" "$repo_slug" >>"$route_log"
		return 0
	}
	_pulse_merge_dismiss_coderabbit_nits() {
		return 1
	}

	_handle_changes_requested_review_gate 77 owner/repo CHANGES_REQUESTED 42 "origin:worker" || true
	if [[ ! -s "$route_log" ]] &&
		grep -q 'terminal review-thread maintainer attention pending, preserving PR' "$LOGFILE"; then
		print_result "terminal-attention remediation preserves CHANGES_REQUESTED PR" 0
	else
		print_result "terminal-attention remediation preserves CHANGES_REQUESTED PR" 1 \
			"route=$(tr '\n' ';' <"$route_log"), log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_changes_requested_repeat_exhaustion_routes_through_fix_worker() {
	setup_test_env
	export AIDEVOPS_CHANGES_REQUESTED_THREAD_REMEDIATION_FIRST=1
	export SCANNER_RC=12
	export SCANNER_ATTENTION_REASON="same_unresolved_thread_fingerprint"
	define_helpers_under_test || {
		teardown_test_env
		return 0
	}
	local route_log="${TEST_ROOT}/route.log"
	: >"$route_log"
	_route_pr_to_fix_worker() {
		local pr_number="$1"
		local repo_slug="$2"
		local linked_issue="$3"
		local route_kind="$4"
		printf '%s|%s|%s|%s\n' "$pr_number" "$repo_slug" "$linked_issue" "$route_kind" >>"$route_log"
		return 0
	}
	_pulse_merge_dismiss_coderabbit_nits() {
		return 1
	}

	_handle_changes_requested_review_gate 77 owner/repo CHANGES_REQUESTED 42 "origin:worker" || true
	if grep -q '^77|owner/repo|42|review$' "$route_log" &&
		grep -q 'same unresolved thread fingerprint exhausted bounded response remediation' "$LOGFILE"; then
		print_result "same-fingerprint response exhaustion routes through trust-gated fix worker" 0
	else
		print_result "same-fingerprint response exhaustion routes through trust-gated fix worker" 1 \
			"route=$(tr '\n' ';' <"$route_log"), log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_changes_requested_hard_dispatch_failure_still_routes() {
	setup_test_env
	export AIDEVOPS_CHANGES_REQUESTED_THREAD_REMEDIATION_FIRST=1
	export SCANNER_RC=13
	define_helpers_under_test || { teardown_test_env; return 0; }
	local route_log="${TEST_ROOT}/route.log"
	: >"$route_log"
	_route_pr_to_fix_worker() {
		local pr_number="$1"
		local repo_slug="$2"
		printf 'route %s %s\n' "$pr_number" "$repo_slug" >>"$route_log"
		return 0
	}
	_pulse_merge_dismiss_coderabbit_nits() { return 1; }

	_handle_changes_requested_review_gate 77 owner/repo CHANGES_REQUESTED 42 "origin:worker" || true
	if grep -q 'route 77 owner/repo' "$route_log" \
		&& grep -q 'review-thread remediation scan/launch failed for PR #77 in owner/repo' "$LOGFILE"; then
		print_result "hard response-worker dispatch failure retains fix-worker fallback" 0
	else
		print_result "hard response-worker dispatch failure retains fix-worker fallback" 1 \
			"route=$(tr '\n' ';' <"$route_log"), log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_changes_requested_skips_remediation_for_external_contributor() {
	setup_test_env
	export AIDEVOPS_CHANGES_REQUESTED_THREAD_REMEDIATION_FIRST=1
	define_helpers_under_test || { teardown_test_env; return 0; }
	local route_log="${TEST_ROOT}/route.log"
	: >"$route_log"
	_route_pr_to_fix_worker() {
		local pr_number="$1"
		local repo_slug="$2"
		printf 'route %s %s\n' "$pr_number" "$repo_slug" >>"$route_log"
		return 0
	}
	_pulse_merge_dismiss_coderabbit_nits() { return 1; }

	if _handle_changes_requested_review_gate 77 owner/repo CHANGES_REQUESTED 42 "origin:worker,external-contributor"; then
		print_result "external contributor CHANGES_REQUESTED skips remediation" 1 \
			"Expected gate to skip merge"
	elif [[ ! -s "$SCANNER_LOG" ]] && grep -q 'route 77 owner/repo' "$route_log"; then
		print_result "external contributor CHANGES_REQUESTED skips remediation" 0
	else
		print_result "external contributor CHANGES_REQUESTED skips remediation" 1 \
			"scanner=$(tr '\n' ';' <"$SCANNER_LOG"), route=$(tr '\n' ';' <"$route_log")"
	fi
	teardown_test_env
	return 0
}

test_changes_requested_empty_worker_label_pattern_does_not_match_every_label() {
	setup_test_env
	export AIDEVOPS_CHANGES_REQUESTED_THREAD_REMEDIATION_FIRST=1
	_OW_LABEL_PAT=""
	define_helpers_under_test || { teardown_test_env; return 0; }
	local route_log="${TEST_ROOT}/route.log"
	: >"$route_log"
	_route_pr_to_fix_worker() {
		local pr_number="$1"
		local repo_slug="$2"
		printf 'route %s %s\n' "$pr_number" "$repo_slug" >>"$route_log"
		return 0
	}
	_pulse_merge_dismiss_coderabbit_nits() { return 1; }

	if _handle_changes_requested_review_gate 77 owner/repo CHANGES_REQUESTED 42 "origin:interactive"; then
		print_result "empty worker label pattern does not match every PR label" 1 \
			"Expected gate to skip merge after fallback routing"
	elif [[ ! -s "$SCANNER_LOG" ]] && grep -q 'route 77 owner/repo' "$route_log"; then
		print_result "empty worker label pattern does not match every PR label" 0
	else
		print_result "empty worker label pattern does not match every PR label" 1 \
			"scanner=$(tr '\n' ';' <"$SCANNER_LOG"), route=$(tr '\n' ';' <"$route_log"), log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_changes_requested_refreshes_empty_caller_labels() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	local route_log="${TEST_ROOT}/route.log"
	: >"$route_log"
	gh_pr_view() { printf 'origin:interactive\n'; return 0; }
	_route_pr_to_fix_worker() {
		local pr_number="$1"
		local repo_slug="$2"
		local linked_issue="$3"
		local kind="$4"
		local labels="$5"
		printf '%s|%s|%s|%s|%s\n' "$pr_number" "$repo_slug" "$linked_issue" "$kind" "$labels" >>"$route_log"
		return 1
	}
	_pulse_merge_dismiss_coderabbit_nits() { return 1; }

	_handle_changes_requested_review_gate 77 owner/repo CHANGES_REQUESTED 42 "" || true
	if grep -q '77|owner/repo|42|review|origin:interactive' "$route_log"; then
		print_result "CHANGES_REQUESTED refreshes empty caller labels" 0
	else
		print_result "CHANGES_REQUESTED refreshes empty caller labels" 1 \
			"route=$(tr '\n' ';' <"$route_log"), log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

test_changes_requested_label_read_failure_does_not_route() {
	setup_test_env
	define_helpers_under_test || { teardown_test_env; return 0; }
	local route_log="${TEST_ROOT}/route.log"
	: >"$route_log"
	gh_pr_view() { return 1; }
	_route_pr_to_fix_worker() { printf 'route\n' >>"$route_log"; return 0; }
	_pulse_merge_dismiss_coderabbit_nits() { return 1; }

	_handle_changes_requested_review_gate 77 owner/repo CHANGES_REQUESTED 42 "" || true
	if [[ ! -s "$route_log" ]] && grep -q 'current PR labels unavailable' "$LOGFILE"; then
		print_result "CHANGES_REQUESTED label read failure does not route" 0
	else
		print_result "CHANGES_REQUESTED label read failure does not route" 1 \
			"route=$(tr '\n' ';' <"$route_log"), log=$(tr '\n' ';' <"$LOGFILE")"
	fi
	teardown_test_env
	return 0
}

main() {
	test_review_bot_preflight_blocker_dispatches_and_is_consumed
	test_required_review_thread_preflight_blocker_dispatches
	test_unrelated_preflight_blocker_does_not_dispatch
	test_failed_preflight_dispatch_stays_blocked_and_consumes_marker
	test_no_match_preflight_dispatch_converges_and_consumes_marker
	test_terminal_attention_preflight_dispatch_stays_fail_closed
	test_dry_run_preflight_blocker_never_dispatches
	test_unresolved_conversation_dispatches_targeted_human_thread_remediation
	test_repo_path_lookup_ignores_slug_case
	test_other_merge_failures_do_not_dispatch_review_thread_remediation
	test_changes_requested_routes_by_default
	test_changes_requested_translates_maintainer_route_outcome
	test_changes_requested_translates_deferred_route_outcome
	test_changes_requested_opt_in_dispatches_remediation_without_routing
	test_changes_requested_routes_when_remediation_unavailable
	test_changes_requested_active_remediation_preserves_pr_without_routing
	test_changes_requested_converged_remediation_exposes_repair_only_mode
	test_changes_requested_terminal_attention_preserves_pr_without_routing
	test_changes_requested_repeat_exhaustion_routes_through_fix_worker
	test_changes_requested_hard_dispatch_failure_still_routes
	test_changes_requested_skips_remediation_for_external_contributor
	test_changes_requested_empty_worker_label_pattern_does_not_match_every_label
	test_changes_requested_refreshes_empty_caller_labels
	test_changes_requested_label_read_failure_does_not_route
	printf '\nTests run: %d\n' "$TESTS_RUN"
	printf 'Tests failed: %d\n' "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
