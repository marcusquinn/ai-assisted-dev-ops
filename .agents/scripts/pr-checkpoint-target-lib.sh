#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Pure metadata predicates for stale worker draft continuation targets.

[[ -n "${_PR_CHECKPOINT_TARGET_LIB_LOADED:-}" ]] && return 0
_PR_CHECKPOINT_TARGET_LIB_LOADED=1

_PCTL_SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_PCTL_SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && _PCTL_SCRIPT_DIR="."
# shellcheck source=pr-closing-link-lib.sh
source "${_PCTL_SCRIPT_DIR}/pr-closing-link-lib.sh"
unset _PCTL_SCRIPT_DIR

# Args: $1=PR JSON, $2=repo slug, $3=PR number, $4=linked issue,
#       $5=expected SHA (optional), $6=expected ref (optional)
_pr_checkpoint_pr_metadata_is_eligible() {
	local pr_json="$1"
	local repo_slug="$2"
	local pr_number="$3"
	local linked_issue="$4"
	local expected_head_sha="${5:-}"
	local expected_head_ref="${6:-}"

	[[ "$pr_number" =~ ^[1-9][0-9]*$ && "$linked_issue" =~ ^[1-9][0-9]*$ ]] || return 1
	_pr_closing_link_matches_issue "$pr_json" "$repo_slug" "$linked_issue" || return 1

	printf '%s' "$pr_json" | jq -e --argjson pr "$pr_number" \
		--arg expected_head_sha "$expected_head_sha" --arg expected_head_ref "$expected_head_ref" '
		def names: [.labels[]? | if type == "string" then . else (.name // empty) end];
		def worker_owned: names | any(. == "origin:worker" or . == "origin:worker-takeover");
		def protected: names | any(
			. == "origin:interactive" or . == "hold-for-review" or
			. == "no-auto-dispatch" or . == "no-takeover" or
			. == "needs-maintainer-review" or . == "persistent"
		);
		(.number == $pr) and (((.state // "") | ascii_upcase) == "OPEN") and
		(.isDraft == true) and (.isCrossRepository == false) and
		worker_owned and (protected | not) and
		(((.headRefName // "") | length) > 0) and (((.headRefOid // "") | length) > 0) and
		(($expected_head_sha | length) == 0 or .headRefOid == $expected_head_sha) and
		(($expected_head_ref | length) == 0 or .headRefName == $expected_head_ref)
	' >/dev/null 2>&1 || return 1
	return 0
}

# Args: $1=REST issue JSON, $2=linked issue number, $3=expected assignee (optional)
_pr_checkpoint_issue_metadata_is_eligible() {
	local issue_json="$1"
	local linked_issue="$2"
	local expected_assignee="${3:-}"

	[[ "$linked_issue" =~ ^[1-9][0-9]*$ ]] || return 1
	printf '%s' "$issue_json" | jq -e --argjson issue "$linked_issue" \
		--arg expected_assignee "$expected_assignee" '
		def names: [.labels[]? | if type == "string" then . else (.name // empty) end];
		def lifecycle_statuses: [names[] | select(startswith("status:"))];
		def runnable_status:
			lifecycle_statuses as $statuses |
			(($statuses | length) == 1) and
			($statuses[0] == "status:queued" or
				$statuses[0] == "status:in-progress" or
				$statuses[0] == "status:in-review");
		def protected: names | any(
			. == "needs-maintainer-review" or . == "needs-maintainer-permissions" or
			. == "no-auto-dispatch" or . == "hold-for-review" or . == "persistent" or
			. == "origin:interactive" or . == "parent-task" or . == "research" or
			. == "research-task" or . == "blocked" or . == "on hold"
		);
		(.number == $issue) and (((.state // "") | ascii_downcase) == "open") and
		((.pull_request // null) == null) and runnable_status and (protected | not) and
		((.assignees // []) | length == 1) and
		(((.assignees[0].login // "") | length) > 0) and
		(($expected_assignee | length) == 0 or .assignees[0].login == $expected_assignee)
	' >/dev/null 2>&1 || return 1
	return 0
}
