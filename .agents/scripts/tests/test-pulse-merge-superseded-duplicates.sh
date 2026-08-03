#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-merge-superseded-duplicates.sh — GH#23105 regression guards.

set -euo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
MERGE_CONFLICT_FILE="${SCRIPT_DIR_TEST}/../pulse-merge-conflict.sh"
MERGE_FILE="${SCRIPT_DIR_TEST}/../pulse-merge.sh"
SUPERSESSION_FILE="${SCRIPT_DIR_TEST}/../pr-supersession-helper.sh"

TESTS_RUN=0
TESTS_FAILED=0
TEST_ROOT=""
TEST_VERIFY_RC=0
TEST_OVERLAP_RC=0
TEST_ISSUE_LABELS_RC=0
TEST_PARENT_LABELS=""
TEST_COMMIT_SUBJECT="t3571: merged equivalent fix (#9001)"
TEST_LINKED_ISSUE="23105"
TEST_GRAPHQL_COST="1"
TEST_GRAPHQL_HAS_NEXT_PAGE="false"
TEST_GRAPHQL_REPOSITORY="exampleorg/examplerepo"
TEST_GRAPHQL_ISSUE_STATE="CLOSED"
TEST_GRAPHQL_CLOSER_NUMBER="6130"
TEST_GRAPHQL_CLOSER_STATE="MERGED"
TEST_GRAPHQL_CLOSER_MERGED_AT="2026-06-02T14:53:00Z"

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
	if [[ -n "$detail" ]]; then
		printf '     %s\n' "$detail"
	fi
	return 0
}

_print_supersession_graphql_response() {
	printf '{"data":{"repository":{"nameWithOwner":"%s","issue":{"state":"%s","closedByPullRequestsReferences":{"nodes":[{"number":%s,"state":"%s","mergedAt":"%s","repository":{"nameWithOwner":"%s"}}],"pageInfo":{"hasNextPage":%s}}}},"rateLimit":{"cost":%s}}}\n' \
		"$TEST_GRAPHQL_REPOSITORY" \
		"$TEST_GRAPHQL_ISSUE_STATE" \
		"$TEST_GRAPHQL_CLOSER_NUMBER" \
		"$TEST_GRAPHQL_CLOSER_STATE" \
		"$TEST_GRAPHQL_CLOSER_MERGED_AT" \
		"$TEST_GRAPHQL_REPOSITORY" \
		"$TEST_GRAPHQL_HAS_NEXT_PAGE" \
		"$TEST_GRAPHQL_COST"
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	export LOGFILE="${TEST_ROOT}/pulse.log"
	export GH_CALL_LOG="${TEST_ROOT}/gh-calls.log"
	export ROUTE_LOG="${TEST_ROOT}/routes.log"
	export SOLVED_LABEL_LOG="${TEST_ROOT}/solved-labels.log"
	export AGENTS_DIR="${TEST_ROOT}/agents"
	mkdir -p "${AGENTS_DIR}/scripts"
	: >"$LOGFILE"
	: >"$GH_CALL_LOG"
	: >"$ROUTE_LOG"
	: >"$SOLVED_LABEL_LOG"
	cat >"${AGENTS_DIR}/scripts/verify-issue-close-helper.sh" <<'EOF'
#!/usr/bin/env bash
printf 'verify-helper %s\n' "$*" >>"${GH_CALL_LOG}"
exit "${TEST_VERIFY_RC:-0}"
EOF
	chmod +x "${AGENTS_DIR}/scripts/verify-issue-close-helper.sh"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

define_functions_under_test() {
	local fn_src
	fn_src=$(awk '
		/^_parse_squash_merge_pr\(\) \{/,/^}$/ { print }
		/^_verify_superseding_pr_for_issue\(\) \{/,/^}$/ { print }
		/^_close_superseded_duplicate_issue_if_verified\(\) \{/,/^}$/ { print }
		/^_find_task_id_match_on_main\(\) \{/,/^}$/ { print }
		/^_close_conflicting_pr_check_ownership_guard\(\) \{/,/^}$/ { print }
		/^_close_conflicting_pr_skip_protected_precheck\(\) \{/,/^}$/ { print }
		/^_close_conflicting_pr_classify_landed\(\) \{/,/^}$/ { print }
		/^_close_conflicting_pr_comment_landed\(\) \{/,/^}$/ { print }
		/^_close_conflicting_pr_comment_not_landed\(\) \{/,/^}$/ { print }
		/^_close_conflicting_pr\(\) \{/,/^}$/ { print }
	' "$MERGE_CONFLICT_FILE")
	fn_src="${fn_src}
$(awk '
		/^_psh_find_merged_closer_for_closed_issue\(\) \{/,/^}$/ { print }
	' "$SUPERSESSION_FILE")
$(awk '
		/^_pm_pr_labels_mark_intentional_followup\(\) \{/,/^}$/ { print }
		/^_pm_close_superseded_duplicate_pr_if_issue_solved\(\) \{/,/^}$/ { print }
	' "$MERGE_FILE")"
	if [[ -z "$fn_src" ]]; then
		printf 'ERROR: could not extract conflict functions from %s\n' "$MERGE_CONFLICT_FILE" >&2
		return 1
	fi
	eval "$fn_src"
	return 0
}

install_stubs() {
	gh() {
		local command="${1:-}"
		local subcommand="${2:-}"
		printf '%s\n' "$*" >>"$GH_CALL_LOG"
		if [[ "$command" == "api" && "$subcommand" == "graphql" ]]; then
			printf 'graphql-env route=%s response-cost=%s\n' \
				"${AIDEVOPS_GH_ROUTE_DECISION:-}" \
				"${AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE:-}" >>"$GH_CALL_LOG"
			_print_supersession_graphql_response
			return 0
		fi
		if [[ "$1" == "pr" && "$2" == "view" && "$*" == *"--json labels,author"* && "$*" != *"authorAssociation"* ]]; then
			printf '{"labels":[{"name":"origin:worker"}],"author":{"login":"aidevops-worker[bot]"}}\n'
			return 0
		fi
		if [[ "$1" == "pr" && "$2" == "view" && "$3" == "6130" && "$*" == *"state"* ]]; then
			printf 'MERGED\n'
			return 0
		fi
		if [[ "$1" == "pr" && "$2" == "view" && "$3" == "6130" && "$*" == *"mergedAt"* ]]; then
			printf '2026-06-02T14:53:00Z\n'
			return 0
		fi
		if [[ "$1" == "pr" && "$2" == "view" && "$*" == *"--jq"* ]]; then
			printf 'origin:worker\n'
			return 0
		fi
		if [[ "$1" == "issue" && "$2" == "view" && "$3" == "6125" ]]; then
			printf '{"state":"CLOSED","closedByPullRequestsReferences":[{"number":6130}]}\n'
			return 0
		fi
		if [[ "$1" == "api" && "$2" == *"/commits" ]]; then
			printf '[{"sha":"abc123","subject":"%s"}]\n' "$TEST_COMMIT_SUBJECT"
			return 0
		fi
		if [[ "$1" == "api" && "$2" == *"/issues/"* ]]; then
			if [[ "$*" == *"--jq"* ]]; then
				if [[ "${TEST_ISSUE_LABELS_RC:-0}" -ne 0 ]]; then
					printf 'label lookup failed\n' >&2
					return "$TEST_ISSUE_LABELS_RC"
				fi
				printf '%s\n' "$TEST_PARENT_LABELS"
			else
				printf '{"labels":[]}\n'
			fi
			return 0
		fi
		return 0
	}
	_extract_linked_issue() {
		local pr_number="$1"
		local repo_slug="$2"
		printf '%s' "$TEST_LINKED_ISSUE"
		return 0
	}
	_verify_pr_overlaps_commit() {
		local pr_number="$1"
		local repo_slug="$2"
		local commit_sha="$3"
		return "$TEST_OVERLAP_RC"
	}
	_route_pr_to_fix_worker() {
		local pr_number="$1"
		local repo_slug="$2"
		local linked_issue="$3"
		local kind="$4"
		printf '%s %s %s %s\n' "$pr_number" "$repo_slug" "$linked_issue" "$kind" >>"$ROUTE_LOG"
		return 0
	}
	_get_pr_branch_refs_for_conflict_comment() {
		local pr_number="$1"
		printf 'feature/pr-%s\tmain\n' "$pr_number"
		return 0
	}
	_gh_with_timeout() {
		local operation_class="$1"
		shift
		[[ -n "$operation_class" ]] || return 1
		"$@"
		return $?
	}
	_post_rebase_nudge_on_worker_conflicting() { return 0; }
	_carry_forward_pr_diff() { return 0; }
	set_solved_label() {
		local issue="$1"
		local repo="$2"
		local actor="$3"
		printf '%s %s %s\n' "$issue" "$repo" "$actor" >>"$SOLVED_LABEL_LOG"
		return 0
	}
	fast_fail_reset() { return 0; }
	unlock_issue_after_worker() { return 0; }
	return 0
}

reset_case() {
	: >"$GH_CALL_LOG"
	: >"$ROUTE_LOG"
	: >"$SOLVED_LABEL_LOG"
	export TEST_VERIFY_RC=0
	export TEST_OVERLAP_RC=0
	export TEST_ISSUE_LABELS_RC=0
	export TEST_PARENT_LABELS=""
	export TEST_COMMIT_SUBJECT="t3571: merged equivalent fix (#9001)"
	export TEST_LINKED_ISSUE="23105"
	export TEST_GRAPHQL_COST="1"
	export TEST_GRAPHQL_HAS_NEXT_PAGE="false"
	export TEST_GRAPHQL_REPOSITORY="exampleorg/examplerepo"
	export TEST_GRAPHQL_ISSUE_STATE="CLOSED"
	export TEST_GRAPHQL_CLOSER_NUMBER="6130"
	export TEST_GRAPHQL_CLOSER_STATE="MERGED"
	export TEST_GRAPHQL_CLOSER_MERGED_AT="2026-06-02T14:53:00Z"
	return 0
}

assert_log_contains() {
	local file="$1"
	local pattern="$2"
	local label="$3"
	if grep -q -- "$pattern" "$file"; then
		pass "$label"
	else
		fail "$label" "Expected pattern '$pattern' in $file"
	fi
	return 0
}

assert_log_not_contains() {
	local file="$1"
	local pattern="$2"
	local label="$3"
	if grep -q -- "$pattern" "$file"; then
		fail "$label" "Unexpected pattern '$pattern' in $file"
	else
		pass "$label"
	fi
	return 0
}

test_verified_supersession_closes_issue() {
	reset_case
	_close_conflicting_pr "4555" "marcusquinn/aidevops" "t3571: duplicate worker PR"
	assert_log_contains "$GH_CALL_LOG" "pr close 4555" "verified supersession closes duplicate PR"
	assert_log_contains "$GH_CALL_LOG" "issue close 23105" "verified supersession closes linked issue"
	assert_log_contains "$GH_CALL_LOG" "verify-helper check 23105 9001" "verified supersession uses issue-close helper"
	return 0
}

test_unrelated_conflict_routes_worker() {
	reset_case
	TEST_OVERLAP_RC=1
	_close_conflicting_pr "4556" "marcusquinn/aidevops" "t3571: unrelated conflicting PR"
	assert_log_not_contains "$GH_CALL_LOG" "pr close 4556" "unrelated conflict leaves PR open"
	assert_log_contains "$ROUTE_LOG" "4556 marcusquinn/aidevops 23105 conflict" "unrelated conflict routes fix worker"
	return 0
}

test_empty_branch_after_upstream_fix_closes_issue() {
	reset_case
	TEST_COMMIT_SUBJECT="t3571: upstream fix made branch empty (#4570)"
	_close_conflicting_pr "4557" "marcusquinn/aidevops" "t3571: empty branch after upstream fix"
	assert_log_contains "$GH_CALL_LOG" "pr close 4557" "empty branch duplicate closes PR"
	assert_log_contains "$GH_CALL_LOG" "issue close 23105" "empty branch duplicate closes linked issue"
	assert_log_contains "$GH_CALL_LOG" "Superseded by merged PR #4570" "empty branch comment cites merged PR"
	return 0
}

test_ambiguous_same_file_change_routes_worker() {
	reset_case
	TEST_VERIFY_RC=1
	_close_conflicting_pr "4558" "marcusquinn/aidevops" "t3571: ambiguous same-file change"
	assert_log_not_contains "$GH_CALL_LOG" "pr close 4558" "ambiguous same-file change leaves PR open"
	assert_log_contains "$ROUTE_LOG" "4558 marcusquinn/aidevops 23105 conflict" "ambiguous same-file change routes fix worker"
	return 0
}

test_parent_research_comment_avoids_closing_keywords() {
	reset_case
	TEST_PARENT_LABELS="parent-task,research"
	_close_conflicting_pr "4559" "marcusquinn/aidevops" "t3571: parent duplicate PR"
	assert_log_not_contains "$GH_CALL_LOG" "issue close 23105" "parent research issue left open"
	assert_log_not_contains "$GH_CALL_LOG" "Resolves #23105\|Closes #23105\|Fixes #23105" "parent research comment avoids closing keywords"
	return 0
}

test_label_lookup_failure_skips_issue_closure() {
	reset_case
	TEST_ISSUE_LABELS_RC=1
	_close_conflicting_pr "4560" "marcusquinn/aidevops" "t3571: label lookup failure"
	assert_log_not_contains "$GH_CALL_LOG" "issue close 23105" "label lookup failure skips linked issue close"
	assert_log_contains "$LOGFILE" "failed to fetch labels for issue #23105" "label lookup failure is logged"
	return 0
}

test_protected_precheck_skips_draft_interactive_without_metadata_fetch() {
	reset_case
	local pr_obj
	pr_obj='{"number":4265,"isDraft":true,"labels":[{"name":"origin:interactive"},{"name":"no-auto-dispatch"}]}'
	if _close_conflicting_pr_skip_protected_precheck "4265" "exampleorg/examplerepo" "$pr_obj"; then
		pass "protected draft interactive PR precheck skips close"
	else
		fail "protected draft interactive PR precheck skips close" "Expected precheck to return 0 for draft origin:interactive no-auto-dispatch PR"
	fi
	assert_log_not_contains "$GH_CALL_LOG" "pr view 4265" "protected precheck uses existing PR object without gh metadata fetch"
	assert_log_not_contains "$LOGFILE" "failed to fetch metadata" "protected precheck avoids noisy metadata-fetch failure log"
	return 0
}

test_merge_ready_duplicate_pr_closed_before_merge() {
	reset_case
	_pm_close_superseded_duplicate_pr_if_issue_solved "6131" "exampleorg/examplerepo" "6125" "origin:worker"
	assert_log_contains "$GH_CALL_LOG" "pr close 6131" "merge-ready duplicate closes current PR"
	assert_log_contains "$GH_CALL_LOG" "api graphql" "merge-ready duplicate uses fixed GraphQL closer query"
	assert_log_contains "$GH_CALL_LOG" "graphql-env route=pulse-supersession-closing-pr-exact-cost response-cost=1" "merge-ready duplicate attributes response-owned GraphQL cost"
	assert_log_not_contains "$GH_CALL_LOG" "issue view 6125" "merge-ready duplicate avoids native issue view"
	assert_log_not_contains "$GH_CALL_LOG" "pr view 6130" "merge-ready duplicate avoids native closer PR views"
	assert_log_contains "$GH_CALL_LOG" "merged PR #6130" "merge-ready duplicate comment cites merged PR"
	return 0
}

test_supersession_graphql_fail_closed_guards() {
	reset_case
	TEST_GRAPHQL_CLOSER_NUMBER="6131"
	if _psh_find_merged_closer_for_closed_issue "exampleorg/examplerepo" "6125" "6131" >/dev/null; then
		fail "supersession ignores current PR as closer" "Expected current PR reference to be excluded"
	else
		pass "supersession ignores current PR as closer"
	fi

	reset_case
	TEST_GRAPHQL_CLOSER_STATE="OPEN"
	TEST_GRAPHQL_CLOSER_MERGED_AT=""
	if _psh_find_merged_closer_for_closed_issue "exampleorg/examplerepo" "6125" "6131" >/dev/null; then
		fail "supersession ignores unmerged closer" "Expected open PR reference to be excluded"
	else
		pass "supersession ignores unmerged closer"
	fi

	reset_case
	TEST_GRAPHQL_ISSUE_STATE="OPEN"
	if _psh_find_merged_closer_for_closed_issue "exampleorg/examplerepo" "6125" "6131" >/dev/null; then
		fail "supersession requires closed issue" "Expected open issue to fail closed"
	else
		pass "supersession requires closed issue"
	fi

	reset_case
	TEST_GRAPHQL_COST="0"
	if _psh_find_merged_closer_for_closed_issue "exampleorg/examplerepo" "6125" "6131" >/dev/null; then
		fail "supersession rejects invalid GraphQL cost" "Expected zero response-owned cost to fail closed"
	else
		pass "supersession rejects invalid GraphQL cost"
	fi

	reset_case
	TEST_GRAPHQL_HAS_NEXT_PAGE="true"
	if _psh_find_merged_closer_for_closed_issue "exampleorg/examplerepo" "6125" "6131" >/dev/null; then
		fail "supersession rejects truncated closer connection" "Expected hasNextPage=true to fail closed"
	else
		pass "supersession rejects truncated closer connection"
	fi

	reset_case
	TEST_GRAPHQL_REPOSITORY="untrusted/example"
	if _psh_find_merged_closer_for_closed_issue "exampleorg/examplerepo" "6125" "6131" >/dev/null; then
		fail "supersession rejects mismatched repository" "Expected repository mismatch to fail closed"
	else
		pass "supersession rejects mismatched repository"
	fi
	return 0
}

test_followup_label_preserves_duplicate_guard() {
	reset_case
	if _pm_close_superseded_duplicate_pr_if_issue_solved "6132" "exampleorg/examplerepo" "6125" "origin:worker,follow-up"; then
		fail "follow-up label is not auto-closed" "Expected guard to skip explicit follow-up"
	else
		pass "follow-up label is not auto-closed"
	fi
	assert_log_not_contains "$GH_CALL_LOG" "pr close 6132" "follow-up label avoids close write"
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env
	define_functions_under_test
	install_stubs

	test_verified_supersession_closes_issue
	test_unrelated_conflict_routes_worker
	test_empty_branch_after_upstream_fix_closes_issue
	test_ambiguous_same_file_change_routes_worker
	test_parent_research_comment_avoids_closing_keywords
	test_label_lookup_failure_skips_issue_closure
	test_protected_precheck_skips_draft_interactive_without_metadata_fetch
	test_merge_ready_duplicate_pr_closed_before_merge
	test_supersession_graphql_fail_closed_guards
	test_followup_label_preserves_duplicate_guard

	printf '\nTests run: %s, failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -eq 0 ]]; then
		return 0
	fi
	return 1
}

main "$@"
