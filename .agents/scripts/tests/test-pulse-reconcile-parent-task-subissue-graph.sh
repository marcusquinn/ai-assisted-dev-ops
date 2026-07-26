#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-pulse-reconcile-parent-task-subissue-graph.sh — t2138 regression guard.
#
# Asserts that reconcile_completed_parent_tasks in pulse-issue-reconcile.sh:
#
#   1. Queries the sub-issue graph via GraphQL before falling back to body regex.
#   2. Uses the graph result (authoritative) when non-empty, even if body has
#      no #NNN references.
#   3. Falls back to body-regex for legacy parents whose graph is empty.
#   4. Allows a complete legacy single-child parent to close.
#   5. Still requires ALL children closed (partial-open no-close preserved).
#   6. Keeps declared/unfiled phase plans open and repairs premature closes.
#
# Primary motivating case: #19222 (t2126 parent with 5 closed children wired
# via GraphQL, zero #NNN in body). Without this fix the parent stays open
# indefinitely.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
}

# Sandbox
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs"
export LOGFILE="${HOME}/.aidevops/logs/pulse.log"
: >"$LOGFILE"

# -----------------------------------------------------------------------------
# gh stub — configurable per scenario via env files written before each test
# -----------------------------------------------------------------------------
# Each scenario writes the following files:
#   ${TEST_ROOT}/gh-subissues.json   — jq-formatted list of {number, state}
#                                      returned by the GraphQL subIssues query.
#                                      Empty "[]" = fallback to body regex.
#   ${TEST_ROOT}/gh-issue-list.json  — the open-parent-task list returned by
#                                      `gh issue list --label parent-task`.
#   ${TEST_ROOT}/gh-child-states.env — key=value pairs mapping
#                                      ISSUE_<NN>_STATE and ISSUE_<NN>_TITLE
#                                      for each child lookup.

STUB_DIR="${TEST_ROOT}/stubs"
mkdir -p "$STUB_DIR"
GH_CALLS="${TEST_ROOT}/gh-calls.log"
export GH_CALLS TEST_ROOT

cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GH_CALLS}"

case "$1" in
	api)
		shift
		if [[ "${1:-}" == "graphql" ]]; then
			printf 'graphql-cost-from-response=%s\n' "${AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE:-}" >>"${GH_CALLS}"
			# Per-scenario override: non-zero exit simulates a GraphQL
			# failure (auth, rate-limit, network). The helper under test
			# must treat this as empty and fall back to body regex.
			if [[ -n "${GH_GRAPHQL_EXIT_CODE:-}" ]]; then
				exit "${GH_GRAPHQL_EXIT_CODE}"
			fi
			# Emit the raw GraphQL envelope. Production retains this shape until
			# response-owned rateLimit.cost is metered and validated, then projects
			# child numbers locally.
			_nodes='[]'
			if [[ -f "${TEST_ROOT}/gh-subissues.json" ]]; then
				_nodes=$(jq -c '.' "${TEST_ROOT}/gh-subissues.json" 2>/dev/null) || _nodes='[]'
			fi
			_has_next="${GH_GRAPHQL_HAS_NEXT_PAGE:-false}"
			case "${GH_GRAPHQL_COST:-1}" in
			missing)
				jq -cn --argjson nodes "$_nodes" --argjson has_next "$_has_next" \
					'{data:{repository:{issue:{subIssues:{nodes:$nodes,pageInfo:{hasNextPage:$has_next}}}}}}'
				;;
			malformed)
				jq -cn --argjson nodes "$_nodes" --argjson has_next "$_has_next" \
					'{data:{repository:{issue:{subIssues:{nodes:$nodes,pageInfo:{hasNextPage:$has_next}}}},rateLimit:{cost:"invalid"}}}'
				;;
			*)
				jq -cn --argjson nodes "$_nodes" --argjson has_next "$_has_next" \
					--argjson cost "${GH_GRAPHQL_COST:-1}" \
					'{data:{repository:{issue:{subIssues:{nodes:$nodes,pageInfo:{hasNextPage:$has_next}}}},rateLimit:{cost:$cost}}}'
				;;
			esac
			exit 0
		fi
		# `gh api repos/X/Y/issues/N --jq '.state // "unknown"'` or `--jq '.title // ""'`
		# Extract the issue number from the path, look up in child-states env.
		local_path="${1:-}"
		local_issue=""
		if [[ "$local_path" =~ /issues/([0-9]+)$ ]]; then
			local_issue="${BASH_REMATCH[1]}"
		fi
		# Find the --jq filter (next arg after the path, or after --jq)
		local_jq=""
		while [[ $# -gt 0 ]]; do
			if [[ "$1" == "--jq" ]]; then
				shift
				local_jq="${1:-}"
				break
			fi
			shift
		done
		# Load state from env file
		if [[ -n "$local_issue" && -f "${TEST_ROOT}/gh-child-states.env" ]]; then
			# shellcheck disable=SC1090
			source "${TEST_ROOT}/gh-child-states.env"
			local_state_var="ISSUE_${local_issue}_STATE"
			local_title_var="ISSUE_${local_issue}_TITLE"
			if [[ "$local_jq" == *".state"* ]]; then
				echo "${!local_state_var:-unknown}"
			elif [[ "$local_jq" == *".title"* ]]; then
				echo "${!local_title_var:-}"
			fi
		fi
		exit 0
		;;
	issue)
		case "${2:-}" in
			list)
				if [[ -f "${TEST_ROOT}/gh-closed-issue-list.json" ]]; then
					cat "${TEST_ROOT}/gh-closed-issue-list.json"
				elif [[ -f "${TEST_ROOT}/gh-issue-list.json" ]]; then
					cat "${TEST_ROOT}/gh-issue-list.json"
				else
					echo "[]"
				fi
				exit 0
				;;
			close)
				# Record the close call; always succeed
				exit 0
				;;
			reopen | comment | edit)
				exit 0
				;;
		esac
		;;
esac
exit 0
STUB
chmod +x "${STUB_DIR}/gh"
export PATH="${STUB_DIR}:${PATH}"

# Repos JSON for the function's iteration
REPOS_JSON_FILE="${TEST_ROOT}/repos.json"
cat >"$REPOS_JSON_FILE" <<'JSON'
{
	"initialized_repos": [
		{"slug": "test/repo", "pulse": true, "local_only": false}
	],
	"git_parent_dirs": []
}
JSON
export REPOS_JSON="$REPOS_JSON_FILE"

# Source the target script. It references $LOGFILE and $REPOS_JSON.
# shellcheck source=/dev/null
source "${TEST_SCRIPTS_DIR}/pulse-issue-reconcile.sh" >/dev/null 2>&1

# Keep this harness deterministic regardless of the host's REST-first/rate-limit
# wrapper state. Production still exercises the shared wrappers; the test sends
# their final command shape directly to the local gh stub.
gh_issue_list() {
	gh issue list "$@" && return 0
	return 1
}

gh_issue_comment() {
	gh issue comment "$@" && return 0
	return 1
}

gh_issue_edit_safe() {
	gh issue edit "$@" && return 0
	return 1
}

# -----------------------------------------------------------------------------
# Scenario helpers
# -----------------------------------------------------------------------------
reset_scenario() {
	: >"$GH_CALLS"
	: >"$LOGFILE"
	rm -f "${TEST_ROOT}/gh-subissues.json" "${TEST_ROOT}/gh-child-states.env" \
		"${TEST_ROOT}/gh-issue-list.json" "${TEST_ROOT}/gh-closed-issue-list.json"
	return 0
}

set_parent_list() {
	# Args: issue_num title body
	local num="$1" title="$2" body="$3"
	jq -n --argjson n "$num" --arg t "$title" --arg b "$body" \
		'[{number:$n, title:$t, body:$b}]' >"${TEST_ROOT}/gh-issue-list.json"
	return 0
}

set_closed_parent_list() {
	# Args: issue_num title body
	local num="$1" title="$2" body="$3"
	jq -n --argjson n "$num" --arg t "$title" --arg b "$body" \
		'[{number:$n, title:$t, body:$b, state:"closed"}]' >"${TEST_ROOT}/gh-closed-issue-list.json"
	return 0
}

set_subissues() {
	# Args: pairs of "num:state" space-separated, e.g. "100:CLOSED 101:CLOSED"
	local pairs=("$@")
	local json="["
	local first=1
	for pair in "${pairs[@]}"; do
		local num="${pair%%:*}"
		local state="${pair##*:}"
		[[ "$first" -eq 1 ]] || json+=","
		json+="{\"number\":${num},\"state\":\"${state}\"}"
		first=0
	done
	json+="]"
	printf '%s\n' "$json" >"${TEST_ROOT}/gh-subissues.json"
	return 0
}

set_child_states() {
	# Args: pairs of "num:state:title" space-separated
	: >"${TEST_ROOT}/gh-child-states.env"
	for triple in "$@"; do
		IFS=":" read -r num state title <<<"$triple"
		{
			echo "ISSUE_${num}_STATE=${state}"
			echo "ISSUE_${num}_TITLE=${title}"
		} >>"${TEST_ROOT}/gh-child-states.env"
	done
	return 0
}

# -----------------------------------------------------------------------------
# Scenario 1: graph has 5 closed children, body is narrative prose (no #NNN).
# This is the #19222 case. MUST close via graph path.
# -----------------------------------------------------------------------------
reset_scenario
set_parent_list 19222 "t2126: parent: qlty maintainability A-grade" \
	"Parent tracker for 5 cluster decomposition tasks. No inline refs."
set_subissues "19223:CLOSED" "19224:CLOSED" "19225:CLOSED" "19226:CLOSED" "19227:CLOSED"
set_child_states "19223:closed:t2127" "19224:closed:t2128" "19225:closed:t2129" \
	"19226:closed:t2130" "19227:closed:t2131"

reconcile_completed_parent_tasks >/dev/null 2>&1

if grep -q "issue close 19222" "$GH_CALLS"; then
	print_result "graph-only path: closes parent when all 5 subissues CLOSED" 0
else
	print_result "graph-only path: closes parent when all 5 subissues CLOSED" 1 \
		"(calls: $(tr '\n' '|' <"$GH_CALLS" | head -c 400))"
fi

if grep -q "source=graph" "$LOGFILE"; then
	print_result "graph-only path: log tags child_source=graph" 0
else
	print_result "graph-only path: log tags child_source=graph" 1 \
		"(log: $(cat "$LOGFILE"))"
fi

# -----------------------------------------------------------------------------
# Scenario 2: graph empty, body has 2 closed #NNN references.
# Legacy path MUST still close.
# -----------------------------------------------------------------------------
reset_scenario
set_parent_list 500 "t500: legacy parent" \
	$'## Children\n\n- #501\n- #502'
printf '[]\n' >"${TEST_ROOT}/gh-subissues.json"
set_child_states "501:closed:child-A" "502:closed:child-B"

reconcile_completed_parent_tasks >/dev/null 2>&1

if grep -q "issue close 500" "$GH_CALLS"; then
	print_result "body-fallback path: closes legacy parent with #NNN inline refs" 0
else
	print_result "body-fallback path: closes legacy parent with #NNN inline refs" 1 \
		"(calls: $(tr '\n' '|' <"$GH_CALLS" | head -c 400))"
fi

if grep -q "source=body" "$LOGFILE"; then
	print_result "body-fallback path: log tags child_source=body" 0
else
	print_result "body-fallback path: log tags child_source=body" 1 \
		"(log: $(cat "$LOGFILE"))"
fi

# -----------------------------------------------------------------------------
# Scenario 3: graph has 2 children but one is still OPEN.
# MUST NOT close.
# -----------------------------------------------------------------------------
reset_scenario
set_parent_list 600 "t600: partial" "Tracker with one child still working."
set_subissues "601:CLOSED" "602:OPEN"
set_child_states "601:closed:done-child" "602:open:wip-child"

reconcile_completed_parent_tasks >/dev/null 2>&1

if grep -q "issue close 600" "$GH_CALLS"; then
	print_result "partial-open: does NOT close parent with an OPEN child" 1 \
		"(unexpected close: $(tr '\n' '|' <"$GH_CALLS" | head -c 400))"
else
	print_result "partial-open: does NOT close parent with an OPEN child" 0
fi

# -----------------------------------------------------------------------------
# Scenario 4: complete legacy parent has one real closed child and no
# deterministic incomplete contract. Backward compatibility MUST close it.
# -----------------------------------------------------------------------------
reset_scenario
set_parent_list 700 "t700: single-ref" "Only references #701."
set_subissues "701:CLOSED"
set_child_states "701:closed:lone-child"

reconcile_completed_parent_tasks >/dev/null 2>&1

if grep -q "issue close 700" "$GH_CALLS"; then
	print_result "single-child compatibility: closes complete legacy parent" 0
else
	print_result "single-child compatibility: closes complete legacy parent" 1 \
		"(calls: $(tr '\n' '|' <"$GH_CALLS" | head -c 400))"
fi

# -----------------------------------------------------------------------------
# Scenario 5: graph empty AND body has no refs. MUST skip silently.
# -----------------------------------------------------------------------------
reset_scenario
set_parent_list 800 "t800: orphan" "No child references at all."
printf '[]\n' >"${TEST_ROOT}/gh-subissues.json"

reconcile_completed_parent_tasks >/dev/null 2>&1

if grep -q "issue close 800" "$GH_CALLS"; then
	print_result "no-refs: does NOT close parent with zero children anywhere" 1 \
		"(unexpected close: $(tr '\n' '|' <"$GH_CALLS" | head -c 400))"
else
	print_result "no-refs: does NOT close parent with zero children anywhere" 0
fi

# -----------------------------------------------------------------------------
# Scenario 6: GraphQL query is always attempted (precedence).
# Even when body has #NNN, the helper should try the graph first.
# -----------------------------------------------------------------------------
reset_scenario
set_parent_list 900 "t900: both" "Has graph and #901 #902 in body."
set_subissues "901:CLOSED" "902:CLOSED"
set_child_states "901:closed:a" "902:closed:b"

reconcile_completed_parent_tasks >/dev/null 2>&1

if grep -q "api graphql" "$GH_CALLS"; then
	print_result "graph query is always attempted first" 0
else
	print_result "graph query is always attempted first" 1 \
		"(expected 'api graphql' invocation; calls: $(tr '\n' '|' <"$GH_CALLS" | head -c 400))"
fi

if grep -q 'graphql-cost-from-response=1' "$GH_CALLS" \
	&& grep -q 'rateLimit{cost}' "$GH_CALLS"; then
	print_result "graph query carries response-owned quota cost through projection" 0
else
	print_result "graph query carries response-owned quota cost through projection" 1 \
		"(expected metering env and rateLimit field; calls: $(tr '\n' '|' <"$GH_CALLS" | head -c 400))"
fi

# Missing or malformed response-owned cost must fail closed before child-number
# projection. The parent reconciler will then use its legacy body fallback.
reset_scenario
set_subissues "910:CLOSED"
missing_cost_result=$(GH_GRAPHQL_COST=missing _fetch_subissue_numbers "test/repo" "909")
if [[ -z "$missing_cost_result" ]]; then
	print_result "missing GraphQL rateLimit.cost blocks projected child output" 0
else
	print_result "missing GraphQL rateLimit.cost blocks projected child output" 1 \
		"(unexpected output: ${missing_cost_result})"
fi

malformed_cost_result=$(GH_GRAPHQL_COST=malformed _fetch_subissue_numbers "test/repo" "909")
if [[ -z "$malformed_cost_result" ]]; then
	print_result "malformed GraphQL rateLimit.cost blocks projected child output" 0
else
	print_result "malformed GraphQL rateLimit.cost blocks projected child output" 1 \
		"(unexpected output: ${malformed_cost_result})"
fi

# -----------------------------------------------------------------------------
# Scenario 7 (CodeRabbit review feedback): GraphQL call fails hard (exit 1).
# Legacy body-ref fallback MUST still close the parent. This mirrors the
# empty-graph scenario but exercises the error-path branch in the helper.
# -----------------------------------------------------------------------------
reset_scenario
set_parent_list 1000 "t1000: graphql-failure" \
	$'Graph is temporarily broken.\n\n## Children\n\n- #1001\n- #1002'
set_child_states "1001:closed:child-x" "1002:closed:child-y"

GH_GRAPHQL_EXIT_CODE=1 reconcile_completed_parent_tasks >/dev/null 2>&1

if grep -q "issue close 1000" "$GH_CALLS"; then
	print_result "graphql-error fallback: closes via body regex when GraphQL fails" 0
else
	print_result "graphql-error fallback: closes via body regex when GraphQL fails" 1 \
		"(calls: $(tr '\n' '|' <"$GH_CALLS" | head -c 400))"
fi

if grep -q "source=body" "$LOGFILE"; then
	print_result "graphql-error fallback: log tags child_source=body" 0
else
	print_result "graphql-error fallback: log tags child_source=body" 1 \
		"(log: $(cat "$LOGFILE"))"
fi

# -----------------------------------------------------------------------------
# Scenario 8 (CodeRabbit review feedback): hasNextPage=true (parent has >50
# children across pages). Helper MUST fail-closed — treat graph as empty and
# fall back to body regex so we never close based on a partial child list.
# -----------------------------------------------------------------------------
reset_scenario
set_parent_list 1100 "t1100: paginated" \
	$'## Children\n\n- #1101\n- #1102'
set_child_states "1101:closed:a" "1102:closed:b"

GH_GRAPHQL_HAS_NEXT_PAGE=true reconcile_completed_parent_tasks >/dev/null 2>&1

if grep -q "issue close 1100" "$GH_CALLS"; then
	# Closed via body fallback (graph bailed out)
	if grep -q "source=body" "$LOGFILE"; then
		print_result "pagination fail-closed: graph bails, body fallback closes" 0
	else
		print_result "pagination fail-closed: graph bails, body fallback closes" 1 \
			"(closed but source not 'body': $(cat "$LOGFILE"))"
	fi
else
	print_result "pagination fail-closed: graph bails, body fallback closes" 1 \
		"(expected close via body fallback; calls: $(tr '\n' '|' <"$GH_CALLS" | head -c 400))"
fi

# -----------------------------------------------------------------------------
# Scenario 9: hasNextPage=true AND empty body → parent stays open (safe default).
# The pagination guard must not cause a false negative close when no fallback
# signal exists either.
# -----------------------------------------------------------------------------
reset_scenario
set_parent_list 1200 "t1200: paginated-no-body" \
	"Narrative only. No #NNN anywhere."

GH_GRAPHQL_HAS_NEXT_PAGE=true reconcile_completed_parent_tasks >/dev/null 2>&1

if grep -q "issue close 1200" "$GH_CALLS"; then
	print_result "pagination fail-closed: no body refs = parent stays open" 1 \
		"(unexpected close with paginated graph + empty body; calls: $(tr '\n' '|' <"$GH_CALLS" | head -c 400))"
else
	print_result "pagination fail-closed: no body refs = parent stays open" 0
fi

# -----------------------------------------------------------------------------
# Scenario 10: one filed closed child does not complete a two-phase contract.
# The parent stays open and receives an idempotent decomposition nudge.
# -----------------------------------------------------------------------------
reset_scenario
set_parent_list 1300 "t1300: declared roadmap" $'## Phases\n\n- Phase 1 - shipped #1301\n- Phase 2 - still unfiled\n\n## Children\n\n- #1301'
set_subissues "1301:CLOSED"
set_child_states "1301:closed:phase-one"

reconcile_completed_parent_tasks >/dev/null 2>&1

if grep -q "issue close 1300" "$GH_CALLS"; then
	print_result "unfiled phase contract: parent remains open" 1 \
		"(unexpected close: $(tr '\n' '|' <"$GH_CALLS" | head -c 400))"
else
	print_result "unfiled phase contract: parent remains open" 0
fi
if grep -q "issue comment 1300" "$GH_CALLS"; then
	print_result "unfiled phase contract: posts recovery nudge" 0
else
	print_result "unfiled phase contract: posts recovery nudge" 1 \
		"(calls: $(tr '\n' '|' <"$GH_CALLS" | head -c 400))"
fi

# -----------------------------------------------------------------------------
# Scenario 11: all canonical phases are filed and terminal, so the close
# contract is complete and the parent closes normally.
# -----------------------------------------------------------------------------
reset_scenario
set_parent_list 1400 "t1400: complete roadmap" $'## Phases\n\n- Phase 1 - shipped #1401\n- Phase 2 - shipped #1402\n\n## Children\n\n- #1401\n- #1402'
set_subissues "1401:CLOSED" "1402:CLOSED"
set_child_states "1401:closed:phase-one" "1402:closed:phase-two"

reconcile_completed_parent_tasks >/dev/null 2>&1

if grep -q "issue close 1400" "$GH_CALLS"; then
	print_result "complete phase contract: closes parent" 0
else
	print_result "complete phase contract: closes parent" 1 \
		"(calls: $(tr '\n' '|' <"$GH_CALLS" | head -c 400))"
fi

# -----------------------------------------------------------------------------
# Scenario 12: bounded recently-closed scan repairs a premature close only
# when canonical unfiled phase evidence exists.
# -----------------------------------------------------------------------------
reset_scenario
set_closed_parent_list 1500 "t1500: prematurely closed" $'## Phases\n\n- Phase 1 - shipped #1501\n- Phase 2 - still unfiled'
set_subissues "1501:CLOSED"
set_child_states "1501:closed:phase-one"

reconcile_completed_parent_tasks >/dev/null 2>&1

if grep -q "issue reopen 1500" "$GH_CALLS"; then
	print_result "closed-parent repair: reopens deterministic incomplete roadmap" 0
else
	print_result "closed-parent repair: reopens deterministic incomplete roadmap" 1 \
		"(calls: $(tr '\n' '|' <"$GH_CALLS" | head -c 400))"
fi
reopen_count=$(grep -c "issue reopen 1500" "$GH_CALLS" 2>/dev/null || true)
if [[ "$reopen_count" -eq 1 ]]; then
	print_result "closed-parent repair: action is bounded to one reopen per scan" 0
else
	print_result "closed-parent repair: action is bounded to one reopen per scan" 1 \
		"(reopen_count=${reopen_count})"
fi

# -----------------------------------------------------------------------------
# Scenario 13: a stamped phase plan with no parseable phase rows is invalid.
# Whitespace-only parser output must not bypass the contract and close a parent.
# -----------------------------------------------------------------------------
reset_scenario
set_parent_list 1600 "t1600: invalid phase plan" $'## Phases\n\n   \n\t\n## Children\n\n- #1601\n\n<!-- parent-close-contract: phase-plan -->'
set_subissues "1601:CLOSED"
set_child_states "1601:closed:only-child"

reconcile_completed_parent_tasks >/dev/null 2>&1

if grep -q "issue close 1600" "$GH_CALLS"; then
	print_result "invalid phase-plan contract: whitespace-only plan remains open" 1 \
		"(unexpected close: $(tr '\n' '|' <"$GH_CALLS" | head -c 400))"
else
	print_result "invalid phase-plan contract: whitespace-only plan remains open" 0
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	exit 1
fi
