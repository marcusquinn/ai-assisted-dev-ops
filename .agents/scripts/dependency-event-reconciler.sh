#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

[[ -n "${_DEPENDENCY_EVENT_RECONCILER_LOADED:-}" ]] && return 0
_DEPENDENCY_EVENT_RECONCILER_LOADED=1
DER_SEARCH_QUOTE=$(printf '\042')
DER_STATE_CLOSED="CLOSED"
DER_NOT_READY=2

_der_dir="${BASH_SOURCE[0]%/*}"
[[ "$_der_dir" == "${BASH_SOURCE[0]}" ]] && _der_dir="."
: "${DER_WORKER_BLOCKER_LOGGER:=${_der_dir}/worker-blocker-log.mjs}"
# shellcheck source=./task-identity-lib.sh
source "${_der_dir}/task-identity-lib.sh"
unset _der_dir

_der_reconcile_terminal_worker_blockers() {
	local repo="$1"
	local issue_number="$2"
	local logger="${DER_WORKER_BLOCKER_LOGGER}"

	if [[ "$repo" != */* || ! "$issue_number" =~ ^[0-9]+$ || ! -f "$logger" || -L "$logger" ]]; then
		return 1
	fi
	command -v node >/dev/null 2>&1 || return 1
	if node "$logger" resolve-issue \
		--repo-slug "$repo" \
		--issue-number "$issue_number" \
		--event "issue_terminal_reconciled" \
		--status "resolved" \
		--reason "issue_closed_verified" \
		--source "dependency-event-reconciler" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

_der_dependency_text() {
	local body="$1"
	printf '%s' "$body" | grep -ioE 'blocked[- ][Bb]y[^[:cntrl:]]*' || true
	return 0
}

_der_issue_refs() {
	local text="$1"
	_der_dependency_text "$text" | grep -oE '#[0-9]+' | grep -oE '[0-9]+' | sort -u || true
	return 0
}

_der_task_refs() {
	local text="$1"
	task_identity_extract_all "$(_der_dependency_text "$text")" | sort -u || true
	return 0
}

_der_todo_blocker_tokens_valid() {
	local text="$1"
	local marker=""
	local value=""
	local token=""
	local marker_count=0

	while IFS= read -r marker; do
		[[ -n "$marker" ]] || continue
		marker_count=$((marker_count + 1))
		value="${marker#*blocked-by:}"
		[[ -n "$value" ]] || return 1
		while IFS= read -r token; do
			[[ -n "$token" ]] || return 1
			if [[ "$token" =~ ^#[0-9]+$ ]]; then
				continue
			fi
			task_identity_validate "$token" || return 1
		done <<<"${value//,/$'\n'}"
	done < <(printf '%s\n' "$text" | grep -oE '(^|[[:space:]])blocked-by:[^[:space:]]+' || true)

	[[ "$marker_count" -gt 0 ]] || return 1
	return 0
}

_der_has_hold() {
	local body="$1"
	local comments="$2"
	local labels="$3"
	printf '%s\n%s\n%s\n' "$body" "$comments" "$labels" |
		grep -qiE 'defer until|do[-[:space:]]not[-[:space:]]dispatch|on[-[:space:]]hold|HUMAN_UNBLOCK_REQUIRED|hold for |paused[[:space:]:]|worker[_ -]blocked|terminal[_ -]blocker|needs-maintainer-review'
	return $?
}

_der_labels_has() {
	local labels="$1"
	local expected="$2"
	[[ ",${labels}," == *",${expected},"* ]]
	return $?
}

_der_json_pages_valid() {
	local pages="$1"
	printf '%s' "$pages" | jq -e 'type == "array" and all(.[]; type == "array")' >/dev/null 2>&1
	return $?
}

_der_seen_has() {
	local seen="$1"
	local issue_number="$2"
	[[ "$seen" == *",${issue_number},"* ]]
	return $?
}

_der_seen_add() {
	local seen="$1"
	local issue_number="$2"
	printf '%s%s,' "$seen" "$issue_number"
	return 0
}

_der_has_active_status() {
	local labels="$1"
	_der_labels_has "$labels" status:queued || _der_labels_has "$labels" status:claimed ||
		_der_labels_has "$labels" status:in-progress || _der_labels_has "$labels" status:in-review ||
		_der_labels_has "$labels" status:done
	return $?
}

_der_fetch_closed_context() {
	local owner="$1"
	local name="$2"
	local closed_number="$3"
	# shellcheck disable=SC2016
	gh api graphql -f query='
query($owner:String!,$name:String!,$number:Int!) {
  repository(owner:$owner,name:$name) {
    nameWithOwner
    issue(number:$number) {
      number state title
      blocking(first:100) {
        nodes { number state title body repository { nameWithOwner } labels(first:100) { nodes { name } pageInfo { hasNextPage } } }
        pageInfo { hasNextPage }
      }
    }
  }
}' -F owner="$owner" -F name="$name" -F number="$closed_number" 2>/dev/null
	return $?
}

# Search is deliberately capped. More than 100 matches, another page, malformed
# nodes, or a repository mismatch is ambiguity and therefore blocks mutation.
_der_search_issues() {
	local repo="$1"
	local search_query="$2"
	local result=""
	# shellcheck disable=SC2016
	result=$(gh api graphql -f query='
query($searchQuery:String!) {
  search(query:$searchQuery,type:ISSUE,first:100) {
    issueCount pageInfo { hasNextPage }
    nodes {
      __typename
      ... on Issue {
        number state title body repository { nameWithOwner }
        labels(first:100) { nodes { name } pageInfo { hasNextPage } }
      }
    }
  }
}' -F searchQuery="$search_query" 2>/dev/null) || return 1
	printf '%s' "$result" | jq -ce --arg repo "$repo" '
      .data.search
      | select((.issueCount | type) == "number" and .issueCount <= 100)
      | select(.pageInfo.hasNextPage == false)
      | select(all(.nodes[];
          .__typename == "Issue"
          and .repository.nameWithOwner == $repo
          and .labels.pageInfo.hasNextPage == false))
      | .nodes' 2>/dev/null
	return $?
}

_der_candidate_declares() {
	local candidate_json="$1"
	local closed_number="$2"
	local closed_task_id="$3"
	local text="" ref=""
	text=$(printf '%s' "$candidate_json" | jq -r '(.body // "") + "\n" + ([.labels.nodes[].name] | join("\n"))') || return 1
	while IFS= read -r ref; do
		[[ "$ref" == "$closed_number" ]] && return 0
	done < <(_der_issue_refs "$text")
	if [[ -n "$closed_task_id" ]]; then
		while IFS= read -r ref; do
			[[ "$ref" == "$closed_task_id" ]] && return 0
		done < <(_der_task_refs "$text")
	fi
	return 1
}

_der_collect_candidates() {
	local repo="$1"
	local closed_number="$2"
	local closed_task_id="$3"
	local context="$4"
	local query="" result="" number="" seen=","
	local candidate
	local native_numbers=""
	local quote="$DER_SEARCH_QUOTE"
	native_numbers=$(printf '%s' "$context" | jq -r '.data.repository.issue.blocking.nodes[].number' 2>/dev/null) || return 1

	for query in \
		"repo:${repo} is:issue is:open in:body ${quote}#${closed_number}${quote}" \
		"repo:${repo} is:issue is:open label:${quote}blocked-by:#${closed_number}${quote}"; do
		result=$(_der_search_issues "$repo" "$query") || return 1
		while IFS= read -r candidate; do
			[[ -n "$candidate" ]] || continue
			_der_candidate_declares "$candidate" "$closed_number" "$closed_task_id" || continue
			number=$(printf '%s' "$candidate" | jq -r '.number') || return 1
			_der_seen_has "$seen" "$number" && continue
			printf '%s\n' "$candidate"
			seen=$(_der_seen_add "$seen" "$number")
		done < <(printf '%s' "$result" | jq -c '.[]')
	done

	if [[ -n "$closed_task_id" ]]; then
		for query in \
			"repo:${repo} is:issue is:open in:body ${quote}${closed_task_id}${quote}" \
			"repo:${repo} is:issue is:open label:${quote}blocked-by:${closed_task_id}${quote}"; do
			result=$(_der_search_issues "$repo" "$query") || return 1
			while IFS= read -r candidate; do
				[[ -n "$candidate" ]] || continue
				_der_candidate_declares "$candidate" "$closed_number" "$closed_task_id" || continue
				number=$(printf '%s' "$candidate" | jq -r '.number') || return 1
				_der_seen_has "$seen" "$number" && continue
				printf '%s\n' "$candidate"
				seen=$(_der_seen_add "$seen" "$number")
			done < <(printf '%s' "$result" | jq -c '.[]')
		done
	fi

	while IFS= read -r candidate; do
		[[ -n "$candidate" ]] || continue
		number=$(printf '%s' "$candidate" | jq -r '.number') || return 1
		_der_seen_has "$seen" "$number" && continue
		printf '%s\n' "$candidate"
		seen=$(_der_seen_add "$seen" "$number")
	done < <(printf '%s' "$context" | jq -c '.data.repository.issue.blocking.nodes[]')
	# Empty native relationships are valid; ensure malformed extraction did not
	# silently turn a non-empty connection into no candidates.
	[[ -z "$native_numbers" || "$native_numbers" =~ ^[0-9] ]] || return 1
	return 0
}

_der_live_issue_closed() {
	local repo="$1"
	local issue_number="$2"
	local state=""
	state=$(gh issue view "$issue_number" --repo "$repo" --json state --jq '.state' 2>/dev/null) || return 1
	[[ "$state" == "$DER_STATE_CLOSED" || "$state" == "closed" ]] && return 0
	[[ "$state" == "OPEN" || "$state" == "open" ]] && return "$DER_NOT_READY"
	return 1
}

_der_find_task_issue() {
	local repo="$1"
	local task_id="$2"
	local result="" parsed="" number="" match="" count=0
	local candidate
	local quote="$DER_SEARCH_QUOTE"
	task_identity_validate "$task_id" || return 1
	result=$(_der_search_issues "$repo" "repo:${repo} is:issue in:title ${quote}${task_id}:${quote}") || return 1
	while IFS= read -r candidate; do
		[[ -n "$candidate" ]] || continue
		parsed=$(task_identity_parse_title_prefix "$(printf '%s' "$candidate" | jq -r '.title')" || true)
		[[ "$parsed" == "$task_id" ]] || continue
		number=$(printf '%s' "$candidate" | jq -r '.number') || return 1
		match="$number"
		count=$((count + 1))
	done < <(printf '%s' "$result" | jq -c '.[]')
	[[ "$count" -eq 1 && "$match" =~ ^[0-9]+$ ]] || return 1
	printf '%s\n' "$match"
	return 0
}

_der_all_declared_blockers_closed() {
	local repo="$1"
	local candidate_json="$2"
	local blocker="" task_id="" issue_number="" text=""
	text=$(printf '%s' "$candidate_json" | jq -r '(.body // "") + "\n" + ([.labels.nodes[].name] | join("\n"))') || return 1
	while IFS= read -r blocker; do
		[[ -n "$blocker" ]] || continue
		_der_live_issue_closed "$repo" "$blocker" || return $?
	done < <(_der_issue_refs "$text")
	while IFS= read -r task_id; do
		[[ -n "$task_id" ]] || continue
		issue_number=$(_der_find_task_issue "$repo" "$task_id") || return 1
		_der_live_issue_closed "$repo" "$issue_number" || return $?
	done < <(_der_task_refs "$text")
	return 0
}

_der_native_blockers_closed() {
	local repo="$1"
	local issue_number="$2"
	local owner="${repo%%/*}"
	local name="${repo#*/}"
	local result=""
	# shellcheck disable=SC2016
	result=$(gh api graphql -f query='query($o:String!,$r:String!,$n:Int!){repository(owner:$o,name:$r){issue(number:$n){blockedBy(first:100){nodes{number state repository{nameWithOwner}}pageInfo{hasNextPage}}}}}' -F o="$owner" -F r="$name" -F n="$issue_number" 2>/dev/null) || return 1
	printf '%s' "$result" | jq -e --arg closed "$DER_STATE_CLOSED" '
      def is_object: type == "object";
      def is_array: type == ([] | type);
      .data.repository.issue.blockedBy
      | is_object
        and (.pageInfo | is_object)
        and .pageInfo.hasNextPage == false
        and (.nodes | is_array)
        and all(.nodes[];
          is_object
          and (.number | type == "number")
          and (.state == "OPEN" or .state == $closed)
          and (.repository | is_object)
          and (.repository.nameWithOwner | type == "string")
          and (.repository.nameWithOwner | test("^[^/[:space:]]+/[^/[:space:]]+$")))' >/dev/null 2>&1 || return 1
	printf '%s' "$result" | jq -e --arg closed "$DER_STATE_CLOSED" '
      all(.data.repository.issue.blockedBy.nodes[]; .state == $closed)' >/dev/null 2>&1 || return "$DER_NOT_READY"
	return 0
}

_der_completion_blockers_closed() {
	local repo="$1"
	local issue_number="$2"
	local dependency_text="$3"
	local candidate_json=""

	[[ "$repo" == */* && "$issue_number" =~ ^[0-9]+$ ]] || return 1
	_der_todo_blocker_tokens_valid "$dependency_text" || return 1
	candidate_json=$(jq -cn --arg body "$dependency_text" \
		'{body: $body, labels: {nodes: []}}') || return 1
	_der_native_blockers_closed "$repo" "$issue_number" || return $?
	_der_all_declared_blockers_closed "$repo" "$candidate_json"
	return $?
}

_der_try_unblock() {
	local repo="$1"
	local issue_number="$2"
	local candidate_json="$3"
	local labels="" body="" comments_json="" comments=""
	labels=$(printf '%s' "$candidate_json" | jq -r '[.labels.nodes[].name] | join(",")') || return 1
	body=$(printf '%s' "$candidate_json" | jq -r '.body // ""') || return 1
	_der_labels_has "$labels" status:blocked || return 0
	_der_has_active_status "$labels" && return 0
	comments_json=$(gh api --paginate --slurp "repos/${repo}/issues/${issue_number}/comments?per_page=100" 2>/dev/null) || return 1
	_der_json_pages_valid "$comments_json" || return 1
	comments=$(printf '%s' "$comments_json" | jq -r '.[][] | .body // ""' 2>/dev/null) || return 1
	_der_has_hold "$body" "$comments" "$labels" && return 0
	_der_native_blockers_closed "$repo" "$issue_number" || return $?
	_der_all_declared_blockers_closed "$repo" "$candidate_json" || return $?
	labels=$(gh issue view "$issue_number" --repo "$repo" --json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || return 1
	_der_labels_has "$labels" status:blocked || return 0
	_der_has_active_status "$labels" && return 0
	gh issue edit "$issue_number" --repo "$repo" --remove-label status:blocked --add-label status:available >/dev/null 2>&1 || return 1
	return 0
}

# Reconcile only direct dependants after the named issue is positively closed.
reconcile_dependants_after_verified_closure() {
	local repo="$1"
	local closed_number="$2"
	local owner="${repo%%/*}"
	local name="${repo#*/}"
	local context="" closed_task_id="" candidates="" issue_number=""
	local candidate
	[[ "$repo" == */* && "$closed_number" =~ ^[0-9]+$ ]] || return 1
	[[ -n "$owner" && -n "$name" ]] || return 1
	_der_live_issue_closed "$repo" "$closed_number" || return 1
	context=$(_der_fetch_closed_context "$owner" "$name" "$closed_number") || return 1
	printf '%s' "$context" | jq -e --arg repo "$repo" --arg closed "$DER_STATE_CLOSED" '
      .data.repository.nameWithOwner == $repo
      and .data.repository.issue.state == $closed
      and .data.repository.issue.blocking.pageInfo.hasNextPage == false
      and all(.data.repository.issue.blocking.nodes[];
          .repository.nameWithOwner == $repo and .labels.pageInfo.hasNextPage == false)' >/dev/null 2>&1 || return 1
	_der_reconcile_terminal_worker_blockers "$repo" "$closed_number" || true
	closed_task_id=$(task_identity_parse_title_prefix "$(printf '%s' "$context" | jq -r '.data.repository.issue.title')" || true)
	candidates=$(_der_collect_candidates "$repo" "$closed_number" "$closed_task_id" "$context") || return 1
	while IFS= read -r candidate; do
		[[ -n "$candidate" ]] || continue
		issue_number=$(printf '%s' "$candidate" | jq -r '.number') || return 1
		[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1
		_der_try_unblock "$repo" "$issue_number" "$candidate" || return 1
	done <<<"$candidates"
	return 0
}

# Periodically recover status:blocked issues whose close event was missed.
# REST pagination is consumed in full, then bounded before any mutation.
reconcile_stale_blocked_issues() {
	local repo="$1"
	local max_candidates="${DER_STALE_BLOCKED_MAX_CANDIDATES:-500}"
	local pages candidates candidate issue_number
	local total=0 reconciled=0 failed=0
	[[ "$repo" == */* ]] || return 1
	[[ "$max_candidates" =~ ^[1-9][0-9]*$ ]] || max_candidates=500
	pages=$(gh api --paginate --slurp "repos/${repo}/issues?state=open&labels=status%3Ablocked&per_page=100" 2>/dev/null) || return 1
	_der_json_pages_valid "$pages" || return 1
	total=$(printf '%s' "$pages" | jq '[.[][] | select(.pull_request == null)] | length') || return 1
	candidates=$(printf '%s' "$pages" | jq -c --arg repo "$repo" --argjson limit "$max_candidates" '[.[][] | select(.pull_request == null)][: $limit][] | {number,state,title,body,repository:{nameWithOwner:$repo},labels:{nodes:[.labels[] | {name:.name}],pageInfo:{hasNextPage:false}}}') || return 1
	while IFS= read -r candidate; do
		[[ -n "$candidate" ]] || continue
		issue_number=$(printf '%s' "$candidate" | jq -r '.number') || {
			failed=$((failed + 1))
			continue
		}
		if _der_try_unblock "$repo" "$issue_number" "$candidate"; then
			reconciled=$((reconciled + 1))
		elif [[ "$?" -eq "$DER_NOT_READY" ]]; then
			reconciled=$((reconciled + 1))
		else
			failed=$((failed + 1))
		fi
	done <<<"$candidates"
	printf '[dependency-reconciler] stale sweep repo=%s candidates=%s checked=%s failed=%s batch_limit=%s remaining=%s\n' "$repo" "$total" "$reconciled" "$failed" "$max_candidates" "$((total > max_candidates ? total - max_candidates : 0))" >&2
	[[ "$failed" -eq 0 ]]
	return $?
}
