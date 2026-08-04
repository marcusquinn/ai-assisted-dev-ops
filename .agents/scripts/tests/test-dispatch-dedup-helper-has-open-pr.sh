#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
HELPER_SCRIPT="${SCRIPT_DIR}/../dispatch-dedup-helper.sh"

readonly TEST_RED='\033[0;31m'
readonly TEST_GREEN='\033[0;32m'
readonly TEST_RESET='\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

TEST_ROOT=""
GH_FIXTURE_FILE=""
GH_PR_VIEW_FIXTURE_FILE=""
GH_GRAPHQL_CALL_LOG=""

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

# GH#18644: extracted from setup_test_env so the latter stays under the
# 100-line function complexity gate. The stub handles `gh pr list` (by
# repo/state/search key) and `gh pr view` (by PR number + json field).
_write_gh_stub() {
	local stub_path="$1"
	cat >"$stub_path" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Response-metered GraphQL replacements for the two rich native PR-list shapes.
if [[ "${1:-}" == "api" && "${2:-}" == "graphql" ]]; then
	if [[ "${GH_PR_LIST_FAIL:-0}" == "1" ]]; then
		exit 1
	fi
	query_text=""
	query_string=""
	query_owner=""
	query_name=""
	shift 2
	for argument in "$@"; do
		case "$argument" in
		query=*) query_text="${argument#query=}" ;;
		queryString=*) query_string="${argument#queryString=}" ;;
		owner=*) query_owner="${argument#owner=}" ;;
		name=*) query_name="${argument#name=}" ;;
		esac
	done
	if [[ -n "${GH_GRAPHQL_CALL_LOG:-}" ]]; then
		printf '%s|%s|%s\n' \
			"${AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE:-}" \
			"${AIDEVOPS_GH_ROUTE_DECISION:-}" \
			"$query_text" >>"$GH_GRAPHQL_CALL_LOG"
	fi
	graphql_cost="2"
	if [[ "${GH_GRAPHQL_MISSING_COST:-0}" == "1" ]]; then
		graphql_cost="null"
	fi

	if [[ "$query_text" == *"search(type: ISSUE"* ]]; then
		local_repo="${query_string#repo:}"
		local_repo="${local_repo%% *}"
		local_search=""
		if [[ "$query_string" =~ \#([0-9]+) ]]; then
			local_search="#${BASH_REMATCH[1]}"
		fi
		fixture_payload="[]"
		compound_key="${local_repo}|open|${local_search}"
		while IFS= read -r line; do
			[[ -n "$line" ]] || continue
			fixture_key="${line%|*}"
			if [[ "$fixture_key" == "$compound_key" ]]; then
				fixture_payload="${line##*|}"
				break
			fi
		done <"${GH_FIXTURE_FILE}"
		jq -cn --argjson nodes "$fixture_payload" --argjson cost "$graphql_cost" '
			{
				data: {
					search: {
						nodes: ($nodes | map(. as $pr | {
							__typename: "PullRequest",
							number: $pr.number,
							title: ($pr.title // null),
							body: ($pr.body // null),
							isDraft: ($pr.isDraft // false),
							reviewDecision: ($pr.reviewDecision // null),
							mergeStateStatus: ($pr.mergeStateStatus // null),
							mergeable: ($pr.mergeable // null),
							changedFiles: ($pr.changedFiles // 0),
							files: {
								nodes: ($pr.files // []),
								pageInfo: {hasNextPage: ($pr.filesHasNextPage // false)}
							},
							labels: {
								nodes: ($pr.labels // []),
								pageInfo: {hasNextPage: ($pr.labelsHasNextPage // false)}
							}
						}))
					},
					rateLimit: {cost: $cost}
				}
			}'
		exit 0
	fi
EOF
	_append_gh_stub_graphql_tail "$stub_path"
	_append_gh_stub_native_reads "$stub_path"
	chmod +x "$stub_path"
	return 0
}

_append_gh_stub_graphql_tail() {
	local stub_path="$1"
	cat >>"$stub_path" <<'EOF'
	if [[ "$query_text" == *"commits(first: 100)"* ]]; then
		jq -cn --argjson nodes "${GH_OPEN_COMMITS_JSON:-[]}" --argjson cost "$graphql_cost" '
			{
				data: {
					repository: {
						pullRequests: {
							nodes: ($nodes | map(. as $pr | {
								number: $pr.number,
								title: ($pr.title // null),
								isDraft: ($pr.isDraft // false),
								commits: {
									nodes: [($pr.commits // [])[] | {commit: {messageHeadline: (.messageHeadline // "")}}],
									pageInfo: {hasNextPage: false}
								}
							}))
						}
					},
					rateLimit: {cost: $cost}
				}
			}'
		exit 0
	fi

	printf 'unsupported GraphQL query in test stub for %s/%s\n' "$query_owner" "$query_name" >&2
	exit 1
fi
EOF
	return 0
}

_append_gh_stub_native_reads() {
	local stub_path="$1"
	cat >>"$stub_path" <<'EOF'
# gh pr list — returns fixture JSON for (repo, state, search) lookup.
if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
	if [[ "${GH_PR_LIST_FAIL:-0}" == "1" ]]; then
		exit 1
	fi
	local_repo=""
	local_state=""
	local_search=""
	shift 2
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo) local_repo="${2:-}"; shift 2 ;;
		--state) local_state="${2:-}"; shift 2 ;;
		--search) local_search="${2:-}"; shift 2 ;;
		*) shift ;;
		esac
	done
	if [[ -z "$local_repo" || -z "$local_state" || -z "$local_search" ]]; then
		printf '[]\n'
		exit 0
	fi
	compound_key="${local_repo}|${local_state}|${local_search}"
	while IFS= read -r line; do
		[[ -n "$line" ]] || continue
		fixture_key="${line%|*}"
		fixture_payload="${line##*|}"
		if [[ "$fixture_key" == "$compound_key" ]]; then
			printf '%s\n' "$fixture_payload"
			exit 0
		fi
	done <"${GH_FIXTURE_FILE}"
	printf '[]\n'
	exit 0
fi

# gh pr view <number> --repo R --json body|title --jq '.body|.title'
# Fixture line format: "<pr_number>|<field>|<payload>". Payload may
# contain '|' — we split on the first two delimiters only.
if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
	pr_num="${3:-}"
	field=""
	shift 3 2>/dev/null || true
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--json) field="${2:-}"; shift 2 ;;
		--jq) shift 2 ;;
		--repo) shift 2 ;;
		*) shift ;;
		esac
	done
	[[ -z "$pr_num" || -z "$field" ]] && exit 1
	if [[ -f "${GH_PR_VIEW_FIXTURE_FILE}" ]]; then
		while IFS= read -r line; do
			[[ -n "$line" ]] || continue
			fixture_pr="${line%%|*}"
			rest="${line#*|}"
			fixture_field="${rest%%|*}"
			fixture_payload="${rest#*|}"
			if [[ "$fixture_pr" == "$pr_num" && "$fixture_field" == "$field" ]]; then
				printf '%s\n' "$fixture_payload"
				exit 0
			fi
		done <"${GH_PR_VIEW_FIXTURE_FILE}"
	fi
	printf '\n'
	exit 0
fi

printf 'unsupported gh invocation in test stub: %s\n' "$*" >&2
exit 1
EOF
	return 0
}

setup_test_env() {
	TEST_ROOT=$(mktemp -d)
	GH_FIXTURE_FILE="${TEST_ROOT}/gh-pr-list-fixtures.txt"
	GH_PR_VIEW_FIXTURE_FILE="${TEST_ROOT}/gh-pr-view-fixtures.txt"
	GH_GRAPHQL_CALL_LOG="${TEST_ROOT}/gh-graphql-calls.log"

	mkdir -p "${TEST_ROOT}/bin"
	export PATH="${TEST_ROOT}/bin:${PATH}"
	export GH_FIXTURE_FILE
	export GH_PR_VIEW_FIXTURE_FILE
	export GH_GRAPHQL_CALL_LOG

	_write_gh_stub "${TEST_ROOT}/bin/gh"

	printf '' >"${GH_FIXTURE_FILE}"
	printf '' >"${GH_PR_VIEW_FIXTURE_FILE}"
	printf '' >"${GH_GRAPHQL_CALL_LOG}"
	return 0
}

teardown_test_env() {
	if [[ -n "$TEST_ROOT" && -d "$TEST_ROOT" ]]; then
		rm -rf "$TEST_ROOT"
	fi
	return 0
}

set_gh_fixtures() {
	local fixtures="$1"
	printf '%s\n' "$fixtures" >"${GH_FIXTURE_FILE}"
	return 0
}

set_gh_pr_view_fixtures() {
	local fixtures="$1"
	printf '%s\n' "$fixtures" >"${GH_PR_VIEW_FIXTURE_FILE}"
	return 0
}

test_has_open_pr_detects_closing_keyword() {
	# Check 2 (body search): fetch up to 20 PRs with "#N in:body" and
	# filter locally. Body is included in the pr list JSON; no gh pr view call.
	set_gh_fixtures 'marcusquinn/aidevops|merged|#4527 in:body|[{"number":1145,"body":"Closes #4527. Implements the fix."}]'

	local output=""
	if output=$("$HELPER_SCRIPT" has-open-pr 4527 marcusquinn/aidevops 't4527: prevent duplicate dispatch'); then
		case "$output" in
		*'merged PR #1145 references issue #4527 via keyword'*)
			print_result "has-open-pr detects merged PR via closing keyword" 0
			return 0
			;;
		esac
		print_result "has-open-pr detects merged PR via closing keyword" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "has-open-pr detects merged PR via closing keyword" 1 "Expected merged PR evidence for issue #4527"
	return 0
}

test_has_open_pr_detects_task_id_fallback() {
	# Check 3 (task-id title match) now requires the merged PR body to
	# contain a closing-keyword reference to our specific issue number.
	# Bare "#NNN" body references are no longer sufficient (GH#18641).
	# Body must be included in the pr list JSON (no separate gh pr view call).
	set_gh_fixtures 'marcusquinn/aidevops|merged|t063.1 in:title|[{"number":1059,"body":"Closes #9999. The webapp duplicate-dispatch guard."}]'

	local output=""
	if output=$("$HELPER_SCRIPT" has-open-pr 9999 marcusquinn/aidevops 't063.1: fix webapp duplicate PR dispatch'); then
		case "$output" in
		*'merged PR #1059 found by task id t063.1 in title'*)
			print_result "has-open-pr detects merged PR via task-id fallback" 0
			return 0
			;;
		esac
		print_result "has-open-pr detects merged PR via task-id fallback" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "has-open-pr detects merged PR via task-id fallback" 1 "Expected merged PR evidence via task-id fallback"
	return 0
}

test_has_open_pr_detects_response_metered_commit_reference() {
	local output=""
	export GH_OPEN_COMMITS_JSON='[{"number":1060,"title":"Implement exact quota attribution","isDraft":false,"commits":[{"messageHeadline":"Fixes #10000 with response-owned cost"}]}]'
	printf '' >"$GH_GRAPHQL_CALL_LOG"

	if output=$("$HELPER_SCRIPT" has-open-pr 10000 marcusquinn/aidevops 't10000: exact quota attribution'); then
		unset GH_OPEN_COMMITS_JSON
		if [[ "$output" == *"open PR #1060 has commits targeting issue #10000"* ]] && \
			grep -qF '1|dispatch-dedup-open-commits-exact-cost|' "$GH_GRAPHQL_CALL_LOG" && \
			grep -qF 'rateLimit { cost }' "$GH_GRAPHQL_CALL_LOG"; then
			print_result "has-open-pr meters open-commit GraphQL from its response" 0
			return 0
		fi
		print_result "has-open-pr meters open-commit GraphQL from its response" 1 \
			"output=${output}"
		return 0
	fi

	unset GH_OPEN_COMMITS_JSON
	print_result "has-open-pr meters open-commit GraphQL from its response" 1 \
		"Expected commit evidence for issue #10000"
	return 0
}

test_has_open_pr_returns_nonzero_without_match() {
	set_gh_fixtures ''
	set_gh_pr_view_fixtures ''

	if "$HELPER_SCRIPT" has-open-pr 7777 marcusquinn/aidevops 't7777: no merged pr yet'; then
		print_result "has-open-pr returns nonzero when no evidence exists" 1 "Expected nonzero exit when no merged PR evidence exists"
		return 0
	fi

	print_result "has-open-pr returns nonzero when no evidence exists" 0
	return 0
}

# GH#18641: planning-only PR bodies use `For #NNN` instead of `Closes #NNN`
# so the brief PR does NOT auto-close the real implementation issue. Check 3
# must NOT treat `For #NNN` as dispatch-blocking evidence, otherwise every
# brief PR permanently blocks dispatch on its own follow-up issue.
test_has_open_pr_ignores_planning_for_reference() {
	# Body is included in the pr list JSON (no separate gh pr view call).
	set_gh_fixtures 'marcusquinn/aidevops|merged|t2047 in:title|[{"number":18627,"body":"Files the brief for **t2047**. Pure planning, no code changes.\n\nFor #18624\nFor #18599"}]'

	if "$HELPER_SCRIPT" has-open-pr 18624 marcusquinn/aidevops 't2047: task-id collision guard'; then
		print_result "has-open-pr ignores planning-only 'For #NNN' reference" 1 \
			"Expected exit 1: brief PR with 'For #18624' must not block dispatch"
		return 0
	fi

	print_result "has-open-pr ignores planning-only 'For #NNN' reference" 0
	return 0
}

# GH#18641: same convention with `Ref #NNN` phrasing must also be ignored.
test_has_open_pr_ignores_planning_ref_reference() {
	# Body is included in the pr list JSON (no separate gh pr view call).
	set_gh_fixtures 'marcusquinn/aidevops|merged|t2038 in:title|[{"number":18524,"body":"Research brief for t2038.\n\nRef #18521\nRef #18522"}]'

	if "$HELPER_SCRIPT" has-open-pr 18522 marcusquinn/aidevops 't2038: research branch protection bypass'; then
		print_result "has-open-pr ignores planning-only 'Ref #NNN' reference" 1 \
			"Expected exit 1: research brief with 'Ref #18522' must not block dispatch"
		return 0
	fi

	print_result "has-open-pr ignores planning-only 'Ref #NNN' reference" 0
	return 0
}

# GH#18641: a PR whose body contains BOTH a closing keyword for a different
# issue AND a planning reference for ours must still NOT block dispatch on
# ours — the closing keyword must match OUR issue number specifically.
test_has_open_pr_requires_close_keyword_for_our_issue() {
	# Body is included in the pr list JSON (no separate gh pr view call).
	set_gh_fixtures 'marcusquinn/aidevops|merged|t2037 in:title|[{"number":18524,"body":"Files briefs.\n\nCloses #18521\nFor #18522"}]'

	if "$HELPER_SCRIPT" has-open-pr 18522 marcusquinn/aidevops 't2037: inline gate refactor'; then
		print_result "has-open-pr requires close keyword for OUR issue, not another" 1 \
			"Expected exit 1: 'Closes #18521' closes a different issue; 'For #18522' is planning-only for ours"
		return 0
	fi

	print_result "has-open-pr requires close keyword for OUR issue, not another" 0
	return 0
}

# t2085: Layer 4 dedup must detect OPEN PRs that put `Resolves #N` in the
# PR body (the framework convention via full-loop-helper.sh commit-and-pr).
# Without this check, the dedup helper is blind to every routine
# implementation PR — Check 1 matches commit subjects + PR title, neither
# of which carries the closing keyword under the framework convention.
# Trigger incident: cross-runner race on issue #18779 → PR #18906.
test_has_open_pr_detects_open_body_closing_keyword() {
	# Check 1b: "#N in:body" search with body in the pr list JSON.
	# No separate gh pr view call; jq filters locally with the closing regex.
	set_gh_fixtures 'marcusquinn/aidevops|open|#18779 in:body|[{"number":18906,"body":"Resolves #18779. Decompose four interconnected opencode plugin files."}]'

	local output=""
	if output=$("$HELPER_SCRIPT" has-open-pr 18779 marcusquinn/aidevops 't2071: decompose opencode plugin cluster'); then
		case "$output" in
		*'open PR #18906 closes issue #18779 via keyword in body'*)
			print_result "has-open-pr detects OPEN PR via body closing keyword (t2085)" 0
			return 0
			;;
		esac
		print_result "has-open-pr detects OPEN PR via body closing keyword (t2085)" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "has-open-pr detects OPEN PR via body closing keyword (t2085)" 1 "Expected open PR evidence for issue #18779"
	return 0
}

test_has_open_pr_blocks_draft_body_closing_keyword() {
	set_gh_fixtures 'marcusquinn/aidevops|open|#18779|[{"number":18906,"title":"Worker checkpoint for #18779","body":"Resolves #18779. Incomplete worker checkpoint.","isDraft":true,"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"UNKNOWN"}]
marcusquinn/aidevops|open|#18779 in:body|[{"number":18906,"body":"Resolves #18779. Incomplete worker checkpoint.","isDraft":true}]'

	local output=""
	if output=$("$HELPER_SCRIPT" has-open-pr 18779 marcusquinn/aidevops 't2071: incomplete checkpoint'); then
		if [[ "$output" == *"draft PR #18906 is a durable checkpoint"* ]]; then
			print_result "has-open-pr blocks competing dispatch for draft checkpoint" 0
			return 0
		fi
		print_result "has-open-pr blocks competing dispatch for draft checkpoint" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "has-open-pr blocks competing dispatch for draft checkpoint" 1 \
		"Expected durable draft checkpoint to block ordinary redispatch"
	return 0
}

test_has_open_pr_marks_worker_draft_for_stale_routing() {
	set_gh_fixtures 'marcusquinn/aidevops|open|#18780|[{"number":18907,"title":"Worker checkpoint for #18780","body":"Resolves #18780. Incomplete worker checkpoint.","isDraft":true,"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"UNKNOWN","labels":[{"name":"origin:worker"}]}]'

	local output=""
	if output=$("$HELPER_SCRIPT" has-open-pr 18780 marcusquinn/aidevops 'worker draft checkpoint'); then
		if [[ "$output" == WORKER_DRAFT_CHECKPOINT:* ]]; then
			print_result "has-open-pr marks worker draft for stale routing" 0
			return 0
		fi
		print_result "has-open-pr marks worker draft for stale routing" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "has-open-pr marks worker draft for stale routing" 1 \
		"Expected worker draft checkpoint to block ordinary redispatch"
	return 0
}

test_has_open_pr_keeps_protected_draft_unroutable() {
	set_gh_fixtures 'marcusquinn/aidevops|open|#18781|[{"number":18908,"title":"Interactive checkpoint for #18781","body":"Resolves #18781. Held for review.","isDraft":true,"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"UNKNOWN","labels":[{"name":"origin:interactive"}]}]'

	local output=""
	if output=$("$HELPER_SCRIPT" has-open-pr 18781 marcusquinn/aidevops 'protected draft checkpoint'); then
		if [[ "$output" == *"draft PR #18908 is a durable checkpoint"* && "$output" != WORKER_DRAFT_CHECKPOINT:* ]]; then
			print_result "has-open-pr keeps protected draft out of stale routing" 0
			return 0
		fi
		print_result "has-open-pr keeps protected draft out of stale routing" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "has-open-pr keeps protected draft out of stale routing" 1 \
		"Expected protected draft checkpoint to block ordinary redispatch"
	return 0
}

test_has_open_pr_fails_closed_when_sibling_lookup_fails() {
	export GH_PR_LIST_FAIL=1
	local output=""
	local rc=0
	output=$("$HELPER_SCRIPT" has-open-pr 18782 marcusquinn/aidevops 'lookup uncertainty') || rc=$?
	unset GH_PR_LIST_FAIL

	if [[ "$rc" -eq 0 && "$output" == PR_LOOKUP_UNCERTAIN:* ]]; then
		print_result "has-open-pr fails closed when sibling lookup is uncertain" 0
		return 0
	fi

	print_result "has-open-pr fails closed when sibling lookup is uncertain" 1 \
		"rc=${rc} output=${output}"
	return 0
}

test_has_open_pr_fails_closed_without_response_owned_cost() {
	export GH_GRAPHQL_MISSING_COST=1
	local output=""
	local rc=0
	output=$("$HELPER_SCRIPT" has-open-pr 18783 marcusquinn/aidevops 'missing response-owned cost') || rc=$?
	unset GH_GRAPHQL_MISSING_COST

	if [[ "$rc" -eq 0 && "$output" == PR_LOOKUP_UNCERTAIN:* ]]; then
		print_result "has-open-pr fails closed without response-owned GraphQL cost" 0
		return 0
	fi

	print_result "has-open-pr fails closed without response-owned GraphQL cost" 1 \
		"rc=${rc} output=${output}"
	return 0
}

test_has_open_pr_fails_closed_on_partial_sibling_connections() {
	local fixture='marcusquinn/aidevops|open|#18784|[{"number":18909,"title":"Interactive checkpoint for #18784","body":"For #18784","isDraft":true,"labels":[{"name":"origin:interactive"}],"labelsHasNextPage":true}]'
	set_gh_fixtures "$fixture"
	local output=""
	local rc=0
	output=$("$HELPER_SCRIPT" has-open-pr 18784 marcusquinn/aidevops 'partial sibling labels') || rc=$?
	if [[ "$rc" -ne 0 || "$output" != PR_LOOKUP_UNCERTAIN:* ]]; then
		print_result "has-open-pr rejects partial sibling labels" 1 "rc=${rc} output=${output}"
		return 0
	fi

	fixture='marcusquinn/aidevops|open|#18785|[{"number":18910,"title":"Checkpoint for #18785","body":"For #18785","isDraft":true,"filesHasNextPage":true}]'
	set_gh_fixtures "$fixture"
	rc=0
	output=$("$HELPER_SCRIPT" has-open-pr 18785 marcusquinn/aidevops 'partial sibling files') || rc=$?
	if [[ "$rc" -eq 0 && "$output" == PR_LOOKUP_UNCERTAIN:* ]]; then
		print_result "has-open-pr rejects partial sibling connections" 0
	else
		print_result "has-open-pr rejects partial sibling connections" 1 "rc=${rc} output=${output}"
	fi
	return 0
}

# t2085: planning-only OPEN PR bodies use `For #N` / `Ref #N` instead of a
# closing keyword. The new open-body check must NOT treat those as evidence,
# matching the existing planning-aware semantics already enforced by
# Check 3 for merged PRs (GH#18641).
test_has_open_pr_ignores_open_body_planning_for_reference() {
	# No keyword-search hits at all — the brief PR body uses "For #18779" not
	# any closing keyword, so the gh search-by-keyword stage finds nothing.
	# Verify that none of the keyword variants produce a positive match.
	set_gh_fixtures ''
	set_gh_pr_view_fixtures ''

	if "$HELPER_SCRIPT" has-open-pr 18779 marcusquinn/aidevops 't2071: planning brief'; then
		print_result "has-open-pr ignores OPEN PR with planning-only 'For #N' (t2085)" 1 \
			"Expected exit 1: a brief PR with only 'For #18779' must not block dispatch"
		return 0
	fi

	print_result "has-open-pr ignores OPEN PR with planning-only 'For #N' (t2085)" 0
	return 0
}

# t2085: a PR whose body contains a closing keyword for a DIFFERENT issue
# but mentions our issue without a closing keyword must NOT block dispatch
# on our issue. The post-filter regex must match OUR issue number
# specifically. (Mirrors GH#18641 semantics for the open-state code path.)
test_has_open_pr_requires_open_close_keyword_for_our_issue() {
	# GitHub full-text search may return a PR that mentions #18779 in context
	# but closes a different issue. The fixture simulates this: body contains
	# "Closes #18999" and references #18779 in passing. The jq post-filter
	# must reject it because no closing keyword targets #18779 specifically.
	set_gh_fixtures 'marcusquinn/aidevops|open|#18779 in:body|[{"number":18950,"body":"Closes #18999. This PR is unrelated to #18779; the search just full-text matched."}]'

	if "$HELPER_SCRIPT" has-open-pr 18779 marcusquinn/aidevops 't2071: opencode decomposition'; then
		print_result "has-open-pr requires open-PR close keyword for OUR issue (t2085)" 1 \
			"Expected exit 1: PR closes #18999, not #18779; full-text search hit must be filtered"
		return 0
	fi

	print_result "has-open-pr requires open-PR close keyword for OUR issue (t2085)" 0
	return 0
}

test_has_open_pr_blocks_approved_mergeable_sibling() {
	# Check 0: a ready sibling PR may reference the issue with `For #N`
	# instead of a closing keyword (common for parent/phase work). When it is
	# approved and mergeable, redispatch would only create a duplicate worker.
	set_gh_fixtures 'marcusquinn/aidevops|open|#23250|[{"number":23288,"title":"Implement dispatch dedup sibling guard","body":"For #23250. Adds the worker redispatch guard.","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN"}]'

	local output=""
	if output=$("$HELPER_SCRIPT" has-open-pr 23250 marcusquinn/aidevops 't3500: dispatch sibling dedup'); then
		case "$output" in
		*'open PR #23288 is approved or mergeable for issue #23250'*)
			print_result "has-open-pr blocks approved mergeable sibling PR" 0
			return 0
			;;
		esac
		print_result "has-open-pr blocks approved mergeable sibling PR" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "has-open-pr blocks approved mergeable sibling PR" 1 "Expected approved/mergeable sibling PR to block redispatch"
	return 0
}

test_has_open_pr_allows_healthy_planning_only_sibling() {
	set_gh_fixtures 'marcusquinn/aidevops|open|#23257|[{"number":23299,"title":"Publish planning brief","body":"For #23257. Planning only.","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN","changedFiles":2,"files":[{"path":"TODO.md"},{"path":"todo/tasks/t23257-brief.md"}]}]'

	if "$HELPER_SCRIPT" has-open-pr 23257 marcusquinn/aidevops 't3507: implement planned work'; then
		print_result "has-open-pr allows dispatch past healthy planning-only sibling" 1 \
			"Expected complete TODO.md/todo/** file scope to remain non-owning"
		return 0
	fi

	print_result "has-open-pr allows dispatch past healthy planning-only sibling" 0
	return 0
}

test_has_open_pr_blocks_mixed_or_incomplete_sibling_scope() {
	set_gh_fixtures 'marcusquinn/aidevops|open|#23258|[{"number":23300,"title":"Mixed implementation","body":"For #23258.","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN","changedFiles":2,"files":[{"path":"TODO.md"},{"path":".agents/scripts/fix.sh"}]},{"number":23301,"title":"Incomplete metadata","body":"For #23258.","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN","changedFiles":2,"files":[{"path":"TODO.md"}]}]'

	local output=""
	if output=$("$HELPER_SCRIPT" has-open-pr 23258 marcusquinn/aidevops 't3508: preserve implementation ownership'); then
		if [[ "$output" == *"open PR #23300 is approved or mergeable"* ]]; then
			print_result "has-open-pr blocks mixed implementation and incomplete scope" 0
			return 0
		fi
	fi

	print_result "has-open-pr blocks mixed implementation and incomplete scope" 1 "Unexpected output: ${output}"
	return 0
}

test_has_open_pr_blocks_approved_sibling_without_merge_state() {
	# Approved siblings can briefly have UNKNOWN merge state while GitHub computes
	# mergeability. They should still suppress redispatch unless explicitly
	# blocked/conflicting, because an approved sibling is already in the merge path.
	set_gh_fixtures 'marcusquinn/aidevops|open|#23255|[{"number":23295,"title":"Approved sibling","body":"For #23255. Adds the worker redispatch guard.","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"UNKNOWN"}]'

	local output=""
	if output=$("$HELPER_SCRIPT" has-open-pr 23255 marcusquinn/aidevops 't3505: approved sibling dedup'); then
		case "$output" in
		*'open PR #23295 is approved or mergeable for issue #23255'*)
			print_result "has-open-pr blocks approved sibling while merge state computes" 0
			return 0
			;;
		esac
		print_result "has-open-pr blocks approved sibling while merge state computes" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "has-open-pr blocks approved sibling while merge state computes" 1 "Expected approved sibling PR to block redispatch"
	return 0
}

test_has_open_pr_blocks_mergeable_sibling_without_approval() {
	# A clean/mergeable sibling is already healthy enough for normal review/merge
	# progression. Dispatching another worker would race the in-flight PR.
	set_gh_fixtures 'marcusquinn/aidevops|open|#23256|[{"number":23296,"title":"Mergeable sibling","body":"For #23256. Adds the worker redispatch guard.","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"CLEAN","mergeable":"MERGEABLE"}]'

	local output=""
	if output=$("$HELPER_SCRIPT" has-open-pr 23256 marcusquinn/aidevops 't3506: mergeable sibling dedup'); then
		case "$output" in
		*'open PR #23296 is approved or mergeable for issue #23256'*)
			print_result "has-open-pr blocks mergeable sibling without approval" 0
			return 0
			;;
		esac
		print_result "has-open-pr blocks mergeable sibling without approval" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "has-open-pr blocks mergeable sibling without approval" 1 "Expected mergeable sibling PR to block redispatch"
	return 0
}

test_has_open_pr_blocks_refs_colon_healthy_sibling() {
	# Check 0 supports common reference variants used by PR bodies, including
	# plural `Refs` and colon punctuation after the keyword.
	set_gh_fixtures 'marcusquinn/aidevops|open|#23252|[{"number":23292,"title":"Implement dispatch dedup refs guard","body":"Refs: #23252. Adds the worker redispatch guard.","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN"}]'

	local output=""
	if output=$("$HELPER_SCRIPT" has-open-pr 23252 marcusquinn/aidevops 't3502: dispatch sibling refs dedup'); then
		case "$output" in
		*'open PR #23292 is approved or mergeable for issue #23252'*)
			print_result "has-open-pr blocks approved sibling using Refs: #N" 0
			return 0
			;;
		esac
		print_result "has-open-pr blocks approved sibling using Refs: #N" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "has-open-pr blocks approved sibling using Refs: #N" 1 "Expected approved sibling with Refs: #23252 to block redispatch"
	return 0
}

test_has_open_pr_blocks_behind_healthy_sibling() {
	# BEHIND PRs are still valid siblings that the merge path can rebase; they
	# should block duplicate redispatch when already approved and non-draft.
	set_gh_fixtures 'marcusquinn/aidevops|open|#23253|[{"number":23293,"title":"Implement dispatch dedup behind guard","body":"Ref #23253. Adds the worker redispatch guard.","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"BEHIND"}]'

	local output=""
	if output=$("$HELPER_SCRIPT" has-open-pr 23253 marcusquinn/aidevops 't3503: dispatch sibling behind dedup'); then
		case "$output" in
		*'open PR #23293 is approved or mergeable for issue #23253'*)
			print_result "has-open-pr blocks approved BEHIND sibling PR" 0
			return 0
			;;
		esac
		print_result "has-open-pr blocks approved BEHIND sibling PR" 1 "Unexpected output: ${output}"
		return 0
	fi

	print_result "has-open-pr blocks approved BEHIND sibling PR" 1 "Expected approved BEHIND sibling PR to block redispatch"
	return 0
}

test_has_open_pr_allows_when_no_healthy_sibling() {
	# Changes-requested, conflicting, or unknown ready siblings are not durable
	# draft checkpoints and are not candidates the merge path can finish safely.
	set_gh_fixtures 'marcusquinn/aidevops|open|#23251|[{"number":23290,"title":"Needs changes","body":"For #23251.","isDraft":false,"reviewDecision":"CHANGES_REQUESTED","mergeStateStatus":"CLEAN"},{"number":23291,"title":"Conflicting sibling","body":"For #23251.","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"DIRTY"},{"number":23297,"title":"Unknown sibling","body":"For #23251.","isDraft":false,"reviewDecision":"REVIEW_REQUIRED","mergeStateStatus":"UNKNOWN"}]'

	if "$HELPER_SCRIPT" has-open-pr 23251 marcusquinn/aidevops 't3501: allow unhealthy sibling recovery'; then
		print_result "has-open-pr allows dispatch when no healthy sibling exists" 1 \
			"Expected exit 1: changes-requested/conflicting/unknown ready siblings must not block redispatch"
		return 0
	fi

	print_result "has-open-pr allows dispatch when no healthy sibling exists" 0
	return 0
}

test_has_open_pr_ignores_embedded_bare_sibling_reference() {
	# Check 0 must require a leading boundary for every issue-reference
	# alternative, including bare GH#N/#N forms. Without that boundary, an
	# approved sibling whose title or body embeds "#23254" inside another token
	# would incorrectly block redispatch.
	set_gh_fixtures 'marcusquinn/aidevops|open|#23254|[{"number":23294,"title":"Release v1.0#23254 metadata","body":"Changelog token build#23254 only; no issue reference.","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN"}]'

	if "$HELPER_SCRIPT" has-open-pr 23254 marcusquinn/aidevops 't3504: embedded sibling ref guard'; then
		print_result "has-open-pr ignores embedded bare sibling reference" 1 \
			"Expected exit 1: embedded #23254 must not block redispatch without a leading boundary"
		return 0
	fi

	print_result "has-open-pr ignores embedded bare sibling reference" 0
	return 0
}

test_has_open_pr_ignores_adjacent_issue_number_sibling_reference() {
	# GitHub full-text search can return adjacent issue numbers. Check 0 must
	# require a trailing boundary so a healthy PR for #232541 does not block
	# redispatch for issue #23254.
	set_gh_fixtures 'marcusquinn/aidevops|open|#23254|[{"number":23298,"title":"Implement unrelated issue #232541","body":"For #232541. Adds unrelated worker changes.","isDraft":false,"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN"}]'

	if "$HELPER_SCRIPT" has-open-pr 23254 marcusquinn/aidevops 't3504: adjacent sibling ref guard'; then
		print_result "has-open-pr ignores adjacent issue-number sibling reference" 1 \
			"Expected exit 1: #232541 must not block redispatch for #23254"
		return 0
	fi

	print_result "has-open-pr ignores adjacent issue-number sibling reference" 0
	return 0
}

# Existing collision case (GH#18041 / t1957) must still allow dispatch:
# different task used the same ID, merged PR closes some unrelated issue.
test_has_open_pr_allows_dispatch_on_task_id_collision() {
	# Body is included in the pr list JSON (no separate gh pr view call).
	set_gh_fixtures 'marcusquinn/aidevops|merged|t500 in:title|[{"number":1200,"body":"Closes #555. Unrelated work that reused task ID t500."}]'

	if "$HELPER_SCRIPT" has-open-pr 9999 marcusquinn/aidevops 't500: different work for issue #9999'; then
		print_result "has-open-pr allows dispatch on task-id collision" 1 \
			"Expected exit 1: merged PR closes a different issue via task-id collision"
		return 0
	fi

	print_result "has-open-pr allows dispatch on task-id collision" 0
	return 0
}

test_has_open_pr_blocks_superseded_consolidated_issue() {
	set_gh_fixtures 'marcusquinn/aidevops|merged|#26241|[{"number":26266,"title":"For #26241: split mixed PR view fields","body":"## Summary\n\n- Split mixed gh_pr_view requests into REST and GraphQL subsets.\n\nFor #26241\n\n## Testing\n\n- .agents/scripts/tests/test-gh-wrapper-rest-fallback.sh"}]'
	export ISSUE_META_JSON='{"body":"_Supersedes #26241 — this issue is the consolidated spec._\n\nImplement the remaining mixed REST/GQL field-split phase."}'

	local output=""
	if output=$("$HELPER_SCRIPT" has-open-pr 26274 marcusquinn/aidevops 'consolidated: split mixed gh_pr_view REST/GQL fields'); then
		unset ISSUE_META_JSON
		case "$output" in
		*'merged PR #26266 references superseded issue #26241 for consolidated issue #26274'*)
			print_result "has-open-pr blocks superseded consolidated issue satisfied by merged PR" 0
			return 0
			;;
		esac
		print_result "has-open-pr blocks superseded consolidated issue satisfied by merged PR" 1 "Unexpected output: ${output}"
		return 0
	fi

	unset ISSUE_META_JSON
	print_result "has-open-pr blocks superseded consolidated issue satisfied by merged PR" 1 \
		"Expected merged PR evidence via superseded issue reference"
	return 0
}

test_has_open_pr_blocks_crlf_superseded_consolidated_issue() {
	set_gh_fixtures 'marcusquinn/aidevops|merged|#26241|[{"number":26266,"title":"For #26241: split mixed PR view fields","body":"For #26241. Implements the fix."}]'
	export ISSUE_META_JSON='{"body":"_Supersedes #26241 — this issue is the consolidated spec._\r\n\r\nImplement the remaining phase."}'

	local output=""
	if output=$("$HELPER_SCRIPT" has-open-pr 26274 marcusquinn/aidevops 'consolidated: split mixed gh_pr_view REST/GQL fields'); then
		unset ISSUE_META_JSON
		case "$output" in
		*'merged PR #26266 references superseded issue #26241 for consolidated issue #26274'*)
			print_result "has-open-pr accepts CRLF supersedes marker" 0
			return 0
			;;
		esac
	fi

	unset ISSUE_META_JSON
	print_result "has-open-pr accepts CRLF supersedes marker" 1 "Unexpected output: ${output}"
	return 0
}

test_has_open_pr_ignores_planning_only_superseded_reference() {
	set_gh_fixtures 'marcusquinn/aidevops|merged|#26241|[{"number":26260,"title":"For #26241: planning brief","body":"Files the brief for the follow-up. Pure planning, no code changes.\n\nFor #26241"}]'
	export ISSUE_META_JSON='{"body":"_Supersedes #26241 — this issue is the consolidated spec._"}'

	if "$HELPER_SCRIPT" has-open-pr 26274 marcusquinn/aidevops 'consolidated: split mixed gh_pr_view REST/GQL fields'; then
		unset ISSUE_META_JSON
		print_result "has-open-pr ignores planning-only superseded references" 1 \
			"Expected planning-only merged PR to allow dispatch"
		return 0
	fi

	unset ISSUE_META_JSON
	print_result "has-open-pr ignores planning-only superseded references" 0
	return 0
}

test_has_open_pr_ignores_dependency_bump_superseded_references() {
	set_gh_fixtures 'marcusquinn/aidevops|merged|#26241|[{"number":26261,"title":"chore(ci): bump actions/download-artifact from 4.3.0 to 8.0.1","body":"Upstream changes include #26241.","author":{"login":"renovate[bot]"}},{"number":26262,"title":"chore(deps): bump the production-dependencies group with 4 updates","body":"Dependabot release notes mention #26241.","author":{"login":"dependabot[bot]"}}]'
	export ISSUE_META_JSON='{"body":"_Supersedes #26241 — this issue is the consolidated spec._"}'

	if "$HELPER_SCRIPT" has-open-pr 26274 marcusquinn/aidevops 'consolidated: split mixed gh_pr_view REST/GQL fields'; then
		unset ISSUE_META_JSON
		print_result "has-open-pr ignores dependency-bump superseded references" 1 \
			"Expected Renovate and Dependabot changelog references to allow dispatch"
		return 0
	fi

	unset ISSUE_META_JSON
	print_result "has-open-pr ignores dependency-bump superseded references" 0
	return 0
}

test_has_open_pr_preserves_non_bot_bump_implementation() {
	set_gh_fixtures 'marcusquinn/aidevops|merged|#26241|[{"number":26263,"title":"chore(deps): bump parser from 1.0.0 to 2.0.0","body":"Implements the parser migration for #26241.","author":{"login":"maintainer"}}]'
	export ISSUE_META_JSON='{"body":"_Supersedes #26241 — this issue is the consolidated spec._"}'

	local output=""
	if output=$("$HELPER_SCRIPT" has-open-pr 26274 marcusquinn/aidevops 'consolidated: parser migration'); then
		unset ISSUE_META_JSON
		case "$output" in
		*'merged PR #26263 references superseded issue #26241 for consolidated issue #26274'*)
			print_result "has-open-pr preserves non-bot dependency-title implementation evidence" 0
			return 0
			;;
		esac
	fi
	unset ISSUE_META_JSON
	print_result "has-open-pr preserves non-bot dependency-title implementation evidence" 1 "Unexpected output: ${output}"
	return 0
}

test_has_open_pr_preserves_bump_wording_in_implementation_body() {
	set_gh_fixtures 'marcusquinn/aidevops|merged|#26241|[{"number":26264,"title":"fix: migrate parser safely","body":"Implements #26241 and can bump parser from 1.0.0 to 2.0.0 without data loss.","author":{"login":"dependabot[bot]"}}]'
	export ISSUE_META_JSON='{"body":"_Supersedes #26241 — this issue is the consolidated spec._"}'

	local output=""
	if output=$("$HELPER_SCRIPT" has-open-pr 26274 marcusquinn/aidevops 'consolidated: parser migration'); then
		unset ISSUE_META_JSON
		case "$output" in
		*'merged PR #26264 references superseded issue #26241 for consolidated issue #26274'*)
			print_result "has-open-pr preserves implementation bodies containing bump wording" 0
			return 0
			;;
		esac
	fi
	unset ISSUE_META_JSON
	print_result "has-open-pr preserves implementation bodies containing bump wording" 1 "Unexpected output: ${output}"
	return 0
}

test_has_open_pr_ignores_consolidation_task_historical_reference() {
	set_gh_fixtures 'marcusquinn/aidevops|merged|#18670|[{"number":18676,"title":"Fix origin labels","body":"For #18670. Implements the earlier fix."}]'
	# shellcheck disable=SC2016 # Literal backticks are part of the issue-body fixture.
	export ISSUE_META_JSON='{"labels":[{"name":"consolidation-task"}],"body":"## What to do\n\nStart the merged body with: `_Supersedes #27799 — this issue is the consolidated spec._`\n\n**Note (GH#18670):** consolidated issues require origin:worker."}'

	if "$HELPER_SCRIPT" has-open-pr 27848 marcusquinn/aidevops 'consolidation-task: merge thread on #27799 into single spec'; then
		unset ISSUE_META_JSON
		print_result "has-open-pr ignores historical references in consolidation tasks" 1 \
			"Expected operational consolidation-task metadata to bypass consolidated-spec PR dedup"
		return 0
	fi

	unset ISSUE_META_JSON
	print_result "has-open-pr ignores historical references in consolidation tasks" 0
	return 0
}

test_has_open_pr_requires_canonical_supersedes_marker() {
	set_gh_fixtures 'marcusquinn/aidevops|merged|#27799|[{"number":27824,"title":"For #27799: implement wrapper fix","body":"For #27799. Implements the fix."}]'
	# shellcheck disable=SC2016 # Literal backticks are part of the issue-body fixture.
	export ISSUE_META_JSON='{"body":"## What to do\n\nStart the merged body with: `_Supersedes #27799 — this issue is the consolidated spec._`"}'

	if "$HELPER_SCRIPT" has-open-pr 27868 marcusquinn/aidevops 'consolidation-task: merge thread on #27802 into single spec'; then
		unset ISSUE_META_JSON
		print_result "has-open-pr requires canonical supersedes marker position" 1 \
			"Expected an instructional inline marker to remain dispatchable"
		return 0
	fi

	unset ISSUE_META_JSON
	print_result "has-open-pr requires canonical supersedes marker position" 0
	return 0
}

main() {
	trap teardown_test_env EXIT
	setup_test_env

	test_has_open_pr_detects_closing_keyword
	test_has_open_pr_detects_task_id_fallback
	test_has_open_pr_detects_response_metered_commit_reference
	test_has_open_pr_returns_nonzero_without_match
	test_has_open_pr_ignores_planning_for_reference
	test_has_open_pr_ignores_planning_ref_reference
	test_has_open_pr_requires_close_keyword_for_our_issue
	test_has_open_pr_allows_dispatch_on_task_id_collision
	test_has_open_pr_detects_open_body_closing_keyword
	test_has_open_pr_blocks_draft_body_closing_keyword
	test_has_open_pr_marks_worker_draft_for_stale_routing
	test_has_open_pr_keeps_protected_draft_unroutable
	test_has_open_pr_fails_closed_when_sibling_lookup_fails
	test_has_open_pr_fails_closed_without_response_owned_cost
	test_has_open_pr_fails_closed_on_partial_sibling_connections
	test_has_open_pr_ignores_open_body_planning_for_reference
	test_has_open_pr_requires_open_close_keyword_for_our_issue
	test_has_open_pr_blocks_approved_mergeable_sibling
	test_has_open_pr_allows_healthy_planning_only_sibling
	test_has_open_pr_blocks_mixed_or_incomplete_sibling_scope
	test_has_open_pr_blocks_approved_sibling_without_merge_state
	test_has_open_pr_blocks_mergeable_sibling_without_approval
	test_has_open_pr_blocks_refs_colon_healthy_sibling
	test_has_open_pr_blocks_behind_healthy_sibling
	test_has_open_pr_allows_when_no_healthy_sibling
	test_has_open_pr_ignores_embedded_bare_sibling_reference
	test_has_open_pr_ignores_adjacent_issue_number_sibling_reference
	test_has_open_pr_blocks_superseded_consolidated_issue
	test_has_open_pr_blocks_crlf_superseded_consolidated_issue
	test_has_open_pr_ignores_planning_only_superseded_reference
	test_has_open_pr_ignores_dependency_bump_superseded_references
	test_has_open_pr_preserves_non_bot_bump_implementation
	test_has_open_pr_preserves_bump_wording_in_implementation_body
	test_has_open_pr_ignores_consolidation_task_historical_reference
	test_has_open_pr_requires_canonical_supersedes_marker

	printf '\nRan %s tests, %s failed.\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
