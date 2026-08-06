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
export PARENT_REVISION_INITIAL="2026-08-06T00:00:00Z"
export PARENT_REVISION_FINAL="2026-08-06T00:01:00Z"
export PARENT_REVISION_CLOSED="2026-08-06T00:02:00Z"
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
		if [[ "$*" == *"/comments"* && -n "${GH_COMMENTS_EXIT_CODE:-}" ]]; then
			exit "${GH_COMMENTS_EXIT_CODE}"
		fi
		if [[ "${1:-}" == "graphql" ]]; then
			printf 'graphql-cost-from-response=%s\n' "${AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE:-}" >>"${GH_CALLS}"
			# Per-scenario override: non-zero exit simulates a GraphQL
			# failure (auth, rate-limit, network). The helper under test
			# must expose unavailable evidence and defer mutations.
			if [[ -n "${GH_GRAPHQL_EXIT_CODE:-}" ]]; then
				exit "${GH_GRAPHQL_EXIT_CODE}"
			fi
			graphql_reads=0
			graphql_reads_file="${TEST_ROOT}/gh-graphql.reads"
			[[ -f "$graphql_reads_file" ]] && graphql_reads=$(<"$graphql_reads_file")
			graphql_reads=$((graphql_reads + 1))
			printf '%s\n' "$graphql_reads" >"$graphql_reads_file"
			graphql_transition_after="${GH_GRAPHQL_TRANSITION_AFTER:-0}"
			[[ "$graphql_transition_after" =~ ^[0-9]+$ ]] || graphql_transition_after=0
			graphql_nodes_file="${TEST_ROOT}/gh-subissues.json"
			if [[ "$graphql_transition_after" -gt 0 && \
				"$graphql_reads" -gt "$graphql_transition_after" && \
				-f "${TEST_ROOT}/gh-subissues-after-transition.json" ]]; then
				graphql_nodes_file="${TEST_ROOT}/gh-subissues-after-transition.json"
			fi
			# Emit the raw GraphQL envelope. Production retains this shape until
			# response-owned rateLimit.cost is metered and validated, then projects
			# child numbers locally.
			_nodes='[]'
			if [[ -f "$graphql_nodes_file" ]]; then
				_nodes=$(jq -c '.' "$graphql_nodes_file" 2>/dev/null) || _nodes='[]'
			fi
			_has_next="${GH_GRAPHQL_HAS_NEXT_PAGE:-false}"
			case "${GH_GRAPHQL_SHAPE:-complete}" in
			errors)
				jq -cn --argjson nodes "$_nodes" --argjson has_next "$_has_next" \
					'{errors:[{message:"unavailable"}],data:{repository:{issue:{subIssues:{nodes:$nodes,pageInfo:{hasNextPage:$has_next}}}},rateLimit:{cost:1}}}'
				exit 0
				;;
			null-subissues)
				jq -cn '{data:{repository:{issue:{subIssues:null}},rateLimit:{cost:1}}}'
				exit 0
				;;
			missing-pageinfo)
				jq -cn --argjson nodes "$_nodes" \
					'{data:{repository:{issue:{subIssues:{nodes:$nodes}}},rateLimit:{cost:1}}}'
				exit 0
				;;
			esac
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
		if [[ "$*" == *"repos/test/repo/issues -f state=closed"* ]]; then
			if [[ -f "${TEST_ROOT}/gh-closed-issue-list.json" ]]; then
				jq -c -s 'map(map(. + {closed_at:"9999-12-31T23:59:59Z"}))' \
					"${TEST_ROOT}/gh-closed-issue-list.json"
			else
				printf '[[]]\n'
			fi
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
		# Live parent mutation fences request the complete issue object. Reuse the
		# current scenario's parent list entry so label/state changes stay coherent.
		if [[ -n "$local_issue" && -z "$local_jq" ]]; then
			if [[ -n "${GH_LIVE_PARENT_EXIT_CODE:-}" ]]; then
				exit "${GH_LIVE_PARENT_EXIT_CODE}"
			fi
			local_parent_reads=0
			local_parent_reads_file="${TEST_ROOT}/gh-live-parent-${local_issue}.reads"
			[[ -f "$local_parent_reads_file" ]] && local_parent_reads=$(<"$local_parent_reads_file")
			local_parent_reads=$((local_parent_reads + 1))
			printf '%s\n' "$local_parent_reads" >"$local_parent_reads_file"
			local_closed_marker="${TEST_ROOT}/gh-parent-closed-${local_issue}"
			local_issue_files=("${TEST_ROOT}/gh-live-parent.json" "${TEST_ROOT}/gh-issue-list.json" "${TEST_ROOT}/gh-closed-issue-list.json")
			if [[ -f "$local_closed_marker" && -f "${TEST_ROOT}/gh-live-parent-after-close.json" ]]; then
				local_issue_files=("${TEST_ROOT}/gh-live-parent-after-close.json" "${local_issue_files[@]}")
			fi
			local_parent_transition_after="${GH_LIVE_PARENT_TRANSITION_AFTER:-1}"
			[[ "$local_parent_transition_after" =~ ^[1-9][0-9]*$ ]] || local_parent_transition_after=1
			if [[ "$local_parent_reads" -gt "$local_parent_transition_after" && \
				-f "${TEST_ROOT}/gh-live-parent-after-first.json" ]]; then
				local_issue_files=("${TEST_ROOT}/gh-live-parent-after-first.json" "${local_issue_files[@]}")
			fi
			for local_issue_file in "${local_issue_files[@]}"; do
				[[ -f "$local_issue_file" ]] || continue
				local_issue_json=$(jq -c --argjson issue "$local_issue" \
					'.[] | select(.number == $issue)' "$local_issue_file" 2>/dev/null) || local_issue_json=""
				if [[ -n "$local_issue_json" ]]; then
					if [[ -f "$local_closed_marker" ]]; then
						local_issue_json=$(printf '%s' "$local_issue_json" | jq -c \
							--arg revision "$PARENT_REVISION_CLOSED" \
							'.state="closed" | .stateReason=(.stateReason // "COMPLETED") | .updatedAt=$revision')
					fi
					printf '%s\n' "$local_issue_json"
					exit 0
				fi
			done
		fi
		# Load state from env file
		if [[ -n "$local_issue" && -f "${TEST_ROOT}/gh-child-states.env" ]]; then
			# shellcheck disable=SC1090
			source "${TEST_ROOT}/gh-child-states.env"
			local_state_var="ISSUE_${local_issue}_STATE"
			local_title_var="ISSUE_${local_issue}_TITLE"
			if [[ "$local_jq" == *".state"* ]]; then
				local_state_reads=0
				local_state_reads_file="${TEST_ROOT}/gh-child-state-${local_issue}.reads"
				[[ -f "$local_state_reads_file" ]] && local_state_reads=$(<"$local_state_reads_file")
				local_state_reads=$((local_state_reads + 1))
				printf '%s\n' "$local_state_reads" >"$local_state_reads_file"
				if [[ "$local_state_reads" -gt 1 && -f "${TEST_ROOT}/gh-child-live-states.env" ]]; then
					# shellcheck disable=SC1090
					source "${TEST_ROOT}/gh-child-live-states.env"
				fi
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
				touch "${TEST_ROOT}/gh-parent-closed-${3:-unknown}"
				exit 0
				;;
			reopen)
				rm -f "${TEST_ROOT}/gh-parent-closed-${3:-unknown}"
				exit 0
				;;
			comment | edit)
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
		"${TEST_ROOT}/gh-child-live-states.env" \
		"${TEST_ROOT}/gh-subissues-after-transition.json" "${TEST_ROOT}/gh-graphql.reads" \
		"${TEST_ROOT}/gh-issue-list.json" "${TEST_ROOT}/gh-closed-issue-list.json" \
		"${TEST_ROOT}/gh-live-parent.json" "${TEST_ROOT}/gh-live-parent-after-first.json" \
		"${TEST_ROOT}/gh-live-parent-after-close.json" "${TEST_ROOT}"/gh-parent-closed-* \
		"${TEST_ROOT}"/gh-live-parent-*.reads "${TEST_ROOT}"/gh-child-state-*.reads
	unset GH_LIVE_PARENT_EXIT_CODE GH_LIVE_PARENT_TRANSITION_AFTER GH_GRAPHQL_TRANSITION_AFTER
	unset GH_COMMENTS_EXIT_CODE GH_GRAPHQL_SHAPE
	return 0
}

set_parent_list() {
	# Args: issue_num title body
	local num="$1" title="$2" body="$3"
	jq -n --argjson n "$num" --arg t "$title" --arg b "$body" --arg u "$PARENT_REVISION_INITIAL" \
		'[{number:$n, title:$t, body:$b, state:"open", updatedAt:$u, labels:[{name:"parent-task"}], authorAssociation:"OWNER", author:{login:"maintainer",type:"User"}}]' >"${TEST_ROOT}/gh-issue-list.json"
	return 0
}

set_closed_parent_list() {
	# Args: issue_num title body [state_reason] [author_association] [author_login]
	local num="$1" title="$2" body="$3" state_reason="${4:-COMPLETED}"
	local author_association="${5:-OWNER}" author_login="${6:-maintainer}"
	jq -n --argjson n "$num" --arg t "$title" --arg b "$body" --arg r "$state_reason" \
		--arg a "$author_association" --arg l "$author_login" --arg u "$PARENT_REVISION_INITIAL" \
		'[{number:$n, title:$t, body:$b, state:"closed", stateReason:$r, updatedAt:$u, labels:[{name:"parent-task"}], authorAssociation:$a, author:{login:$l,type:"User"}}]' >"${TEST_ROOT}/gh-closed-issue-list.json"
	return 0
}

set_live_parent() {
	local num="$1" title="$2" body="$3" state="${4:-open}"
	jq -n --argjson n "$num" --arg t "$title" --arg b "$body" --arg s "$state" \
		--arg u "$PARENT_REVISION_INITIAL" \
		'[{number:$n, title:$t, body:$b, state:$s, updatedAt:$u, labels:[{name:"parent-task"}], authorAssociation:"OWNER", author:{login:"maintainer",type:"User"}}]' >"${TEST_ROOT}/gh-live-parent.json"
	return 0
}

set_live_parent_without_revision() {
	local num="$1" title="$2" body="$3"
	jq -n --argjson n "$num" --arg t "$title" --arg b "$body" \
		'[{number:$n, title:$t, body:$b, state:"open", labels:[{name:"parent-task"}], authorAssociation:"OWNER", author:{login:"maintainer",type:"User"}}]' >"${TEST_ROOT}/gh-live-parent.json"
	return 0
}

set_live_parent_without_body() {
	local num="$1" title="$2"
	jq -n --argjson n "$num" --arg t "$title" --arg u "$PARENT_REVISION_INITIAL" \
		'[{number:$n, title:$t, state:"open", updatedAt:$u, labels:[{name:"parent-task"}], authorAssociation:"OWNER", author:{login:"maintainer",type:"User"}}]' >"${TEST_ROOT}/gh-live-parent.json"
	return 0
}

set_live_closed_parent() {
	local num="$1" title="$2" body="$3" state_reason="${4:-COMPLETED}"
	jq -n --argjson n "$num" --arg t "$title" --arg b "$body" --arg r "$state_reason" \
		--arg u "$PARENT_REVISION_INITIAL" \
		'[{number:$n, title:$t, body:$b, state:"closed", stateReason:$r, updatedAt:$u, labels:[{name:"parent-task"}], authorAssociation:"OWNER", author:{login:"maintainer",type:"User"}}]' >"${TEST_ROOT}/gh-live-parent.json"
	return 0
}

set_live_closed_parent_transition() {
	local num="$1" title="$2" body="$3" initial_reason="$4" final_reason="$5"
	jq -n --argjson n "$num" --arg t "$title" --arg b "$body" --arg r "$initial_reason" \
		--arg u "$PARENT_REVISION_INITIAL" \
		'[{number:$n, title:$t, body:$b, state:"closed", stateReason:$r, updatedAt:$u, labels:[{name:"parent-task"}], authorAssociation:"OWNER", author:{login:"maintainer",type:"User"}}]' >"${TEST_ROOT}/gh-live-parent.json"
	jq -n --argjson n "$num" --arg t "$title" --arg b "$body" --arg r "$final_reason" \
		--arg u "$PARENT_REVISION_FINAL" \
		'[{number:$n, title:$t, body:$b, state:"closed", stateReason:$r, updatedAt:$u, labels:[{name:"parent-task"}], authorAssociation:"OWNER", author:{login:"maintainer",type:"User"}}]' >"${TEST_ROOT}/gh-live-parent-after-first.json"
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

set_live_child_states() {
	local triples=("$@")
	local triple="" num="" state="" title=""
	: >"${TEST_ROOT}/gh-child-live-states.env"
	for triple in "${triples[@]}"; do
		IFS=":" read -r num state title <<<"$triple"
		{
			echo "ISSUE_${num}_STATE=${state}"
			echo "ISSUE_${num}_TITLE=${title}"
		} >>"${TEST_ROOT}/gh-child-live-states.env"
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
# projection and report unavailable evidence.
reset_scenario
set_subissues "910:CLOSED"
missing_cost_result=$(GH_GRAPHQL_COST=missing _fetch_subissue_numbers "test/repo" "909")
missing_cost_rc=$?
if [[ "$missing_cost_rc" -ne 0 && -z "$missing_cost_result" ]]; then
	print_result "missing GraphQL rateLimit.cost blocks projected child output" 0
else
	print_result "missing GraphQL rateLimit.cost blocks projected child output" 1 \
		"(rc=${missing_cost_rc}, output=${missing_cost_result})"
fi

malformed_cost_result=$(GH_GRAPHQL_COST=malformed _fetch_subissue_numbers "test/repo" "909")
malformed_cost_rc=$?
if [[ "$malformed_cost_rc" -ne 0 && -z "$malformed_cost_result" ]]; then
	print_result "malformed GraphQL rateLimit.cost blocks projected child output" 0
else
	print_result "malformed GraphQL rateLimit.cost blocks projected child output" 1 \
		"(rc=${malformed_cost_rc}, output=${malformed_cost_result})"
fi

for malformed_shape in errors null-subissues missing-pageinfo; do
	malformed_shape_result=$(GH_GRAPHQL_SHAPE="$malformed_shape" \
		_fetch_subissue_numbers "test/repo" "909")
	malformed_shape_rc=$?
	if [[ "$malformed_shape_rc" -ne 0 && -z "$malformed_shape_result" ]]; then
		print_result "malformed GraphQL envelope (${malformed_shape}) is unavailable evidence" 0
	else
		print_result "malformed GraphQL envelope (${malformed_shape}) is unavailable evidence" 1 \
			"(rc=${malformed_shape_rc}, output=${malformed_shape_result})"
	fi
done

# -----------------------------------------------------------------------------
# Scenario 7: a GraphQL failure is unavailable evidence, not an empty graph.
# Body refs cannot authorize closure while native children may be undiscovered.
# -----------------------------------------------------------------------------
reset_scenario
set_parent_list 1000 "t1000: graphql-failure" \
	$'Graph is temporarily broken.\n\n## Children\n\n- #1001\n- #1002'
set_child_states "1001:closed:child-x" "1002:closed:child-y"

GH_GRAPHQL_EXIT_CODE=1 reconcile_completed_parent_tasks >/dev/null 2>&1

if grep -q "issue close 1000" "$GH_CALLS"; then
	print_result "graphql-error fail-closed: body refs do not bypass unavailable graph" 1
else
	print_result "graphql-error fail-closed: body refs do not bypass unavailable graph" 0
fi

# -----------------------------------------------------------------------------
# Scenario 8 (CodeRabbit review feedback): hasNextPage=true (parent has >50
# children across pages). Helper MUST fail closed and defer closure rather than
# trust a body that may omit a child from a later graph page.
# -----------------------------------------------------------------------------
reset_scenario
set_parent_list 1100 "t1100: paginated" \
	$'## Children\n\n- #1101\n- #1102'
set_child_states "1101:closed:a" "1102:closed:b"

GH_GRAPHQL_HAS_NEXT_PAGE=true reconcile_completed_parent_tasks >/dev/null 2>&1

if grep -q "issue close 1100" "$GH_CALLS"; then
	print_result "pagination fail-closed: partial graph blocks body-authorized close" 1
else
	print_result "pagination fail-closed: partial graph blocks body-authorized close" 0
fi

# Trusted roadmap comments are another independent child source. A failed
# comment read must block closure even when the graph is authoritatively empty.
reset_scenario
set_parent_list 1150 "t1150: comment evidence unavailable" $'## Children\n\n- #1151'
set_subissues
set_child_states "1151:closed:body-child"
GH_COMMENTS_EXIT_CODE=1 reconcile_completed_parent_tasks >/dev/null 2>&1
if grep -q "issue close 1150" "$GH_CALLS"; then
	print_result "comment-error fail-closed: unavailable roadmap evidence blocks close" 1
elif grep -q "issues/1150/comments" "$GH_CALLS"; then
	print_result "comment-error fail-closed: unavailable roadmap evidence blocks close" 0
else
	print_result "comment-error fail-closed: unavailable roadmap evidence blocks close" 1 \
		"(trusted comment source was not queried)"
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
# Scenario 11b: cached complete evidence cannot outrun a freshly edited parent
# body. Unchecked criteria and keep-open markers observed at the final mutation
# boundary block closure.
# -----------------------------------------------------------------------------
reset_scenario
set_parent_list 1450 "t1450: cached complete roadmap" $'## Children\n\n- #1451\n- #1452'
set_live_parent 1450 "t1450: live incomplete roadmap" $'<!-- parent-close-contract: keep-open -->\n\n## Acceptance Criteria\n\n- [ ] Final validation\n\n## Children\n\n- #1451\n- #1452'
set_subissues "1451:CLOSED" "1452:CLOSED"
set_child_states "1451:closed:phase-one" "1452:closed:phase-two"

reconcile_completed_parent_tasks >/dev/null 2>&1

if grep -q "issue close 1450" "$GH_CALLS"; then
	print_result "live close contract: cached-complete/live-incomplete parent remains open" 1 \
		"(unexpected close: $(tr '\n' '|' <"$GH_CALLS" | head -c 400))"
elif grep -q "evidence=live" "$LOGFILE"; then
	print_result "live close contract: cached-complete/live-incomplete parent remains open" 0
else
	print_result "live close contract: cached-complete/live-incomplete parent remains open" 1 \
		"(missing live evidence log: $(cat "$LOGFILE"))"
fi

# Missing body metadata and live-read failure are ambiguity, never authority to
# close a parent whose cached row looked complete.
reset_scenario
set_parent_list 1460 "t1460: cached complete" $'## Children\n\n- #1461'
set_live_parent_without_body 1460 "t1460: missing live body"
set_subissues "1461:CLOSED"
set_child_states "1461:closed:only-child"
reconcile_completed_parent_tasks >/dev/null 2>&1
if grep -q "issue close 1460" "$GH_CALLS"; then
	print_result "live close contract: missing body fails closed" 1
else
	print_result "live close contract: missing body fails closed" 0
fi

reset_scenario
set_parent_list 1470 "t1470: cached complete" $'## Children\n\n- #1471'
set_subissues "1471:CLOSED"
set_child_states "1471:closed:only-child"
GH_LIVE_PARENT_EXIT_CODE=1 reconcile_completed_parent_tasks >/dev/null 2>&1
if grep -q "issue close 1470" "$GH_CALLS"; then
	print_result "live close contract: failed live read performs no close" 1
else
	print_result "live close contract: failed live read performs no close" 0
fi

# A child added to the live body after cached candidate selection must join the
# final union and block closure while it remains open.
reset_scenario
set_parent_list 1480 "t1480: cached child set" $'## Children\n\n- #1481'
set_live_parent 1480 "t1480: expanded live child set" $'## Children\n\n- #1481\n- #1482'
set_subissues "1481:CLOSED"
set_child_states "1481:closed:cached-child" "1482:open:new-live-child"
reconcile_completed_parent_tasks >/dev/null 2>&1
if grep -q "issue close 1480" "$GH_CALLS"; then
	print_result "live child set: newly linked open child blocks close" 1
elif grep -q "repos/test/repo/issues/1482 --jq .state" "$GH_CALLS"; then
	print_result "live child set: newly linked open child blocks close" 0
else
	print_result "live child set: newly linked open child blocks close" 1 \
		"(new child was not re-read)"
fi

# A known child can reopen after the first state pass. The second state read at
# the mutation boundary must observe that transition and suppress closure.
reset_scenario
set_parent_list 1490 "t1490: child can reopen" $'## Children\n\n- #1491'
set_live_parent 1490 "t1490: child can reopen" $'## Children\n\n- #1491'
set_subissues "1491:CLOSED"
set_child_states "1491:closed:initially-closed"
set_live_child_states "1491:open:reopened-before-close"
reconcile_completed_parent_tasks >/dev/null 2>&1
child_state_reads=$(<"${TEST_ROOT}/gh-child-state-1491.reads")
if grep -q "issue close 1490" "$GH_CALLS"; then
	print_result "live child state: reopened child blocks close" 1
elif [[ "$child_state_reads" -ge 2 ]]; then
	print_result "live child state: reopened child blocks close" 0
else
	print_result "live child state: reopened child blocks close" 1 \
		"(state_reads=${child_state_reads})"
fi

# An unavailable child lookup is unresolved evidence. It must not be omitted
# merely because another child verifies closed.
reset_scenario
set_parent_list 1492 "t1492: child lookup can fail" $'## Children\n\n- #1493\n- #1494'
set_live_parent 1492 "t1492: child lookup can fail" $'## Children\n\n- #1493\n- #1494'
set_subissues "1493:CLOSED" "1494:CLOSED"
set_child_states "1493:closed:known-child"
reconcile_completed_parent_tasks >/dev/null 2>&1
if grep -q "issue close 1492" "$GH_CALLS"; then
	print_result "live child state: unavailable child fails the close decision closed" 1
elif grep -q "repos/test/repo/issues/1494 --jq .state" "$GH_CALLS"; then
	print_result "live child state: unavailable child fails the close decision closed" 0
else
	print_result "live child state: unavailable child fails the close decision closed" 1 \
		"(unavailable child was not checked)"
fi

# Native graph evidence can change while child states are being checked. Two
# different live snapshots must defer closure instead of trusting either set.
reset_scenario
set_parent_list 1495 "t1495: graph can expand" "Graph-only child tracker"
set_live_parent 1495 "t1495: graph can expand" "Graph-only child tracker"
set_subissues "1496:CLOSED"
jq -n '[{number:1496,state:"CLOSED"},{number:1497,state:"OPEN"}]' \
	>"${TEST_ROOT}/gh-subissues-after-transition.json"
set_child_states "1496:closed:known-child" "1497:open:new-child"
export GH_GRAPHQL_TRANSITION_AFTER=2
reconcile_completed_parent_tasks >/dev/null 2>&1
graph_reads=$(<"${TEST_ROOT}/gh-graphql.reads")
if grep -q "issue close 1495" "$GH_CALLS"; then
	print_result "live child evidence: changed graph snapshot blocks close" 1
elif [[ "$graph_reads" -ge 3 ]]; then
	print_result "live child evidence: changed graph snapshot blocks close" 0
else
	print_result "live child evidence: changed graph snapshot blocks close" 1 \
		"(graph_reads=${graph_reads})"
fi

# The authoritative final parent read occurs after evidence and child checks.
# A concurrent close must fail the expected-open fence.
reset_scenario
set_parent_list 1498 "t1498: parent state can change" $'## Children\n\n- #1499'
set_live_parent 1498 "t1498: parent state can change" $'## Children\n\n- #1499'
jq -n --arg b $'## Children\n\n- #1499' --arg u "$PARENT_REVISION_FINAL" \
	'[{number:1498,title:"t1498: parent state can change",body:$b,state:"closed",updatedAt:$u,labels:[{name:"parent-task"}],authorAssociation:"OWNER",author:{login:"maintainer",type:"User"}}]' \
	>"${TEST_ROOT}/gh-live-parent-after-first.json"
set_subissues "1499:CLOSED"
set_child_states "1499:closed:only-child"
export GH_LIVE_PARENT_TRANSITION_AFTER=2
reconcile_completed_parent_tasks >/dev/null 2>&1
parent_reads=$(<"${TEST_ROOT}/gh-live-parent-1498.reads")
if grep -q "issue close 1498" "$GH_CALLS"; then
	print_result "final parent fence: concurrent state transition blocks close" 1
elif [[ "$parent_reads" -ge 3 ]]; then
	print_result "final parent fence: concurrent state transition blocks close" 0
else
	print_result "final parent fence: concurrent state transition blocks close" 1 \
		"(parent_reads=${parent_reads})"
fi

# An open parent whose body changes after evidence verification must also defer;
# the final fence cannot authorize a close using a stale body contract.
reset_scenario
set_parent_list 1550 "t1550: parent body can change" $'## Children\n\n- #1551'
set_live_parent 1550 "t1550: parent body can change" $'## Children\n\n- #1551'
jq -n --arg b $'<!-- parent-close-contract: keep-open -->\n\n## Children\n\n- #1551' \
	--arg u "$PARENT_REVISION_FINAL" \
	'[{number:1550,title:"t1550: parent body can change",body:$b,state:"open",updatedAt:$u,labels:[{name:"parent-task"}],authorAssociation:"OWNER",author:{login:"maintainer",type:"User"}}]' \
	>"${TEST_ROOT}/gh-live-parent-after-first.json"
set_subissues "1551:CLOSED"
set_child_states "1551:closed:only-child"
export GH_LIVE_PARENT_TRANSITION_AFTER=2
reconcile_completed_parent_tasks >/dev/null 2>&1
if grep -q "issue close 1550" "$GH_CALLS"; then
	print_result "final parent fence: concurrent body mutation blocks close" 1
else
	print_result "final parent fence: concurrent body mutation blocks close" 0
fi

# Revision-less live issue responses cannot support a stale-write fence.
reset_scenario
set_parent_list 1560 "t1560: revision unavailable" $'## Children\n\n- #1561'
set_live_parent_without_revision 1560 "t1560: revision unavailable" $'## Children\n\n- #1561'
set_subissues "1561:CLOSED"
set_child_states "1561:closed:only-child"
reconcile_completed_parent_tasks >/dev/null 2>&1
if grep -q "issue close 1560" "$GH_CALLS"; then
	print_result "final parent fence: missing revision defers automatic close" 1
else
	print_result "final parent fence: missing revision defers automatic close" 0
fi

# If the body changes in the mutation window, immediate post-close validation
# compensates our completed closure and holds the reopened parent for review.
reset_scenario
set_parent_list 1570 "t1570: mutation-window body drift" $'## Children\n\n- #1571'
set_live_parent 1570 "t1570: mutation-window body drift" $'## Children\n\n- #1571'
set_subissues "1571:CLOSED"
set_child_states "1571:closed:only-child"
jq -n --arg b $'<!-- parent-close-contract: keep-open -->\n\n## Children\n\n- #1571' \
	--arg u "$PARENT_REVISION_CLOSED" \
	'[{number:1570,title:"t1570: mutation-window body drift",body:$b,state:"closed",stateReason:"COMPLETED",updatedAt:$u,labels:[{name:"parent-task"}],authorAssociation:"OWNER",author:{login:"maintainer",type:"User"}}]' \
	>"${TEST_ROOT}/gh-live-parent-after-close.json"
reconcile_completed_parent_tasks >/dev/null 2>&1
if grep -q "issue close 1570" "$GH_CALLS" && grep -q "issue reopen 1570" "$GH_CALLS" && \
	! grep -q "closed #1570" "$LOGFILE"; then
	print_result "post-close fence: mutation-window drift is compensated by reopen" 0
else
	print_result "post-close fence: mutation-window drift is compensated by reopen" 1 \
		"(calls: $(tr '\n' '|' <"$GH_CALLS" | head -c 400))"
fi

# A maintainer can intentionally change the close reason while post-close child
# evidence is being checked. Compensation must re-read the reason and preserve
# NOT_PLANNED instead of reopening that intentional closure.
reset_scenario
set_parent_list 1580 "t1580: compensation reason changes" $'## Children\n\n- #1581'
set_live_parent 1580 "t1580: compensation reason changes" $'## Children\n\n- #1581'
set_subissues "1581:CLOSED"
jq -n '[{number:1581,state:"CLOSED"},{number:1582,state:"OPEN"}]' \
	>"${TEST_ROOT}/gh-subissues-after-transition.json"
set_child_states "1581:closed:original-child" "1582:open:new-child"
jq -n --arg b $'## Children\n\n- #1581' --arg u "$PARENT_REVISION_CLOSED" \
	'[{number:1580,title:"t1580: compensation reason changes",body:$b,state:"closed",stateReason:"COMPLETED",updatedAt:$u,labels:[{name:"parent-task"}],authorAssociation:"OWNER",author:{login:"maintainer",type:"User"}}]' \
	>"${TEST_ROOT}/gh-live-parent-after-close.json"
jq -n --arg b $'## Children\n\n- #1581' --arg u "$PARENT_REVISION_FINAL" \
	'[{number:1580,title:"t1580: compensation reason changes",body:$b,state:"closed",stateReason:"NOT_PLANNED",updatedAt:$u,labels:[{name:"parent-task"}],authorAssociation:"OWNER",author:{login:"maintainer",type:"User"}}]' \
	>"${TEST_ROOT}/gh-live-parent-after-first.json"
export GH_GRAPHQL_TRANSITION_AFTER=3
export GH_LIVE_PARENT_TRANSITION_AFTER=4
reconcile_completed_parent_tasks >/dev/null 2>&1
if grep -q "issue close 1580" "$GH_CALLS" && ! grep -q "issue reopen 1580" "$GH_CALLS"; then
	print_result "post-close compensation: fresh NOT_PLANNED reason blocks reopen" 0
else
	print_result "post-close compensation: fresh NOT_PLANNED reason blocks reopen" 1 \
		"(calls: $(tr '\n' '|' <"$GH_CALLS" | head -c 500))"
fi

# -----------------------------------------------------------------------------
# Scenario 12: bounded recently-closed scan repairs a premature close only
# when canonical unfiled phase evidence exists.
# -----------------------------------------------------------------------------

# Discovery must paginate the complete seven-day set instead of rotating only
# over an API client's first 100 rows.
reset_scenario
jq -n '[range(2000;2101) as $n | {
	number:$n,title:("t" + ($n | tostring)),body:"",state:"closed",
	labels:[{name:"parent-task"}],authorAssociation:"OWNER",
	author:{login:"maintainer",type:"User"}
}]' >"${TEST_ROOT}/gh-closed-issue-list.json"
complete_recent_json=$(_fetch_recently_closed_parent_tasks test/repo parent-task)
complete_recent_count=$(printf '%s' "$complete_recent_json" | jq -r 'length')
if [[ "$complete_recent_count" -eq 101 ]] && grep -q -- '--paginate --slurp' "$GH_CALLS"; then
	print_result "closed-parent repair: paginated discovery retains rows beyond 100" 0
else
	print_result "closed-parent repair: paginated discovery retains rows beyond 100" 1 \
		"(count=${complete_recent_count}, calls=$(tr '\n' '|' <"$GH_CALLS" | head -c 300))"
fi

reset_scenario
set_closed_parent_list 1500 "t1500: prematurely closed" $'## Phases\n\n- Phase 1 - shipped #1501\n- Phase 2 - still unfiled'
set_subissues "1501:CLOSED"
set_child_states "1501:closed:phase-one"

_repair_recently_closed_parents_for_slug test/repo 1 >/dev/null 2>&1

if grep -q "issue reopen 1500" "$GH_CALLS"; then
	print_result "closed-parent repair: reopens deterministic incomplete roadmap" 0
else
	print_result "closed-parent repair: reopens deterministic incomplete roadmap" 1 \
		"(calls: $(tr '\n' '|' <"$GH_CALLS" | head -c 400))"
fi
reopen_count=$(grep -c "issue reopen 1500" "$GH_CALLS" 2>/dev/null || true)
if [[ "$reopen_count" -eq 1 && "$_PIR_RECENT_PARENT_REOPENED" -eq 1 ]]; then
	print_result "closed-parent repair: action is bounded to one reopen per scan" 0
else
	print_result "closed-parent repair: action is bounded to one reopen per scan" 1 \
		"(reopen_count=${reopen_count})"
fi

# Cached list bodies never authorize repair. A live incomplete body must reopen
# even when the cached body looked complete, and a live complete body must stay
# closed even when the cached body looked incomplete.
reset_scenario
set_closed_parent_list 1502 "t1502: cached complete" $'## Children\n\n- #1503'
set_live_closed_parent 1502 "t1502: live incomplete" \
	$'<!-- parent-close-contract: keep-open -->\n\n## Children\n\n- #1503'
set_subissues "1503:CLOSED"
set_child_states "1503:closed:only-child"
_repair_recently_closed_parents_for_slug test/repo 1 >/dev/null 2>&1
if grep -q "issue reopen 1502" "$GH_CALLS"; then
	print_result "closed-parent repair: final live incomplete body overrides cached complete body" 0
else
	print_result "closed-parent repair: final live incomplete body overrides cached complete body" 1
fi

reset_scenario
set_closed_parent_list 1504 "t1504: cached incomplete" \
	$'<!-- parent-close-contract: keep-open -->\n\n## Children\n\n- #1505'
set_live_closed_parent 1504 "t1504: live complete" $'## Children\n\n- #1505'
set_subissues "1505:CLOSED"
set_child_states "1505:closed:only-child"
_repair_recently_closed_parents_for_slug test/repo 1 >/dev/null 2>&1
if grep -q "issue reopen 1504" "$GH_CALLS"; then
	print_result "closed-parent repair: final live complete body overrides cached incomplete body" 1
else
	print_result "closed-parent repair: final live complete body overrides cached incomplete body" 0
fi

# An intentional NOT_PLANNED closure is terminal even when stale checklist or
# keep-open evidence remains in the body.
reset_scenario
set_closed_parent_list 1510 "t1510: intentionally cancelled" $'<!-- parent-close-contract: keep-open -->\n\n- [ ] Cancelled criterion' NOT_PLANNED
_repair_recently_closed_parents_for_slug test/repo 1 >/dev/null 2>&1
if grep -q "issue reopen 1510" "$GH_CALLS"; then
	print_result "closed-parent repair: preserves NOT_PLANNED closure" 1
else
	print_result "closed-parent repair: preserves NOT_PLANNED closure" 0
fi

# A completed closure can become intentional while the repair checks comments.
# The final live stateReason read must preserve the new NOT_PLANNED decision.
reset_scenario
set_closed_parent_list 1520 "t1520: closure reason changes" \
	$'<!-- parent-close-contract: keep-open -->\n\n- [ ] Deferred criterion'
set_live_closed_parent_transition 1520 "t1520: closure reason changes" \
	$'<!-- parent-close-contract: keep-open -->\n\n- [ ] Deferred criterion' COMPLETED NOT_PLANNED
_repair_recently_closed_parents_for_slug test/repo 1 >/dev/null 2>&1
if grep -q "issue reopen 1520" "$GH_CALLS"; then
	print_result "closed-parent repair: final stateReason preserves intentional closure" 1
elif [[ "$(<"${TEST_ROOT}/gh-live-parent-1520.reads")" -ge 2 ]]; then
	print_result "closed-parent repair: final stateReason preserves intentional closure" 0
else
	print_result "closed-parent repair: final stateReason preserves intentional closure" 1 \
		"(missing final live re-read)"
fi

# Closed-parent repair is still a lifecycle mutation and must not bypass the
# external-author authority/approval gate.
reset_scenario
set_closed_parent_list 1530 "t1530: external parent" \
	$'<!-- parent-close-contract: keep-open -->\n\n- [ ] External criterion' \
	COMPLETED CONTRIBUTOR outsider
_repair_recently_closed_parents_for_slug test/repo 1 >/dev/null 2>&1
if grep -q "issue reopen 1530" "$GH_CALLS"; then
	print_result "closed-parent repair: unapproved external author remains blocked" 1
else
	print_result "closed-parent repair: unapproved external author remains blocked" 0
fi

# The per-repository helper must honour the cycle's remaining candidate budget,
# even when the fetched page contains more repairable parents.
reset_scenario
jq -n '[
	{number:1540,title:"t1540: first candidate",body:"<!-- parent-close-contract: keep-open -->",state:"closed",stateReason:"COMPLETED",labels:[{name:"parent-task"}],authorAssociation:"OWNER",author:{login:"maintainer",type:"User"}},
	{number:1541,title:"t1541: second candidate",body:"<!-- parent-close-contract: keep-open -->",state:"closed",stateReason:"COMPLETED",labels:[{name:"parent-task"}],authorAssociation:"OWNER",author:{login:"maintainer",type:"User"}}
]' >"${TEST_ROOT}/gh-closed-issue-list.json"
set_live_closed_parent 1540 "t1540: first candidate" \
	'<!-- parent-close-contract: keep-open -->'
_repair_recently_closed_parents_for_slug test/repo 5 1 >/dev/null 2>&1
if [[ "$_PIR_RECENT_PARENT_SCANNED" -ne 1 ]]; then
	print_result "closed-parent repair: per-repo candidate budget bounds action work" 1 \
		"(scanned=${_PIR_RECENT_PARENT_SCANNED})"
elif ! grep -q "issue reopen 1540" "$GH_CALLS" || grep -q "issue reopen 1541" "$GH_CALLS"; then
	print_result "closed-parent repair: per-repo candidate budget bounds action work" 1
else
	print_result "closed-parent repair: per-repo candidate budget bounds action work" 0
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
