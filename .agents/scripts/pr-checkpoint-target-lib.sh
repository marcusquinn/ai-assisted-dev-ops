#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Pure metadata predicates for stale worker draft continuation targets.

[[ -n "${_PR_CHECKPOINT_TARGET_LIB_LOADED:-}" ]] && return 0
_PR_CHECKPOINT_TARGET_LIB_LOADED=1
_PCTL_INTERACTIVE_LABEL="origin:interactive"

_PCTL_SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
[[ "$_PCTL_SCRIPT_DIR" == "${BASH_SOURCE[0]}" ]] && _PCTL_SCRIPT_DIR="."
# shellcheck source=pr-closing-link-lib.sh
source "${_PCTL_SCRIPT_DIR}/pr-closing-link-lib.sh"
_PR_CHECKPOINT_REVISION_VALIDATOR="${_PCTL_SCRIPT_DIR}/pr-checkpoint-revision.py"
unset _PCTL_SCRIPT_DIR

#aidevops:trust-boundary — only an authenticated exact revision envelope may
# relax provenance/absent assignment; every protective label remains enforced.
_pr_checkpoint_revised_target() {
	local repo_slug="$1" pr_json="$2" issue_json="$3" comments_json="$4"
	local assignee="$5" lease="${6:-}" session="${7:-}" claiming="${8:-false}"
	local approval="" linked_issue="" pr_number="" normalized_issue="" normalized_pr=""
	approval=$(jq -n --arg repo "$repo_slug" --argjson pr "$pr_json" \
		--argjson issue "$issue_json" --argjson comments "$comments_json" \
		--arg assignee "$assignee" --arg lease "$lease" --arg session "$session" --argjson claiming "$claiming" \
		'{repo:$repo,pr:$pr,issue:$issue,comments:$comments,assignee:$assignee,lease:$lease,session:$session,claiming:$claiming}' |
		python3 "$_PR_CHECKPOINT_REVISION_VALIDATOR") || return 1
	local approval_actor="" permission=""
	approval_actor=$(jq -er '.approval_actor' <<<"$approval") || return 1
	[[ "$repo_slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ && "$approval_actor" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
	permission=$(gh api "repos/${repo_slug}/collaborators/${approval_actor}/permission" --jq '.permission') || return 1
	case "$permission" in admin | maintain | write) ;; *) return 1 ;; esac
	linked_issue=$(jq -r '.issue' <<<"$approval") || return 1
	pr_number=$(jq -r '.pr' <<<"$approval") || return 1
	normalized_pr="$pr_json"
	if ! _pr_closing_link_matches_issue "$pr_json" "$repo_slug" "$linked_issue"; then
		# A signed exact pair can recover a partial For-only checkpoint, never
		# conflicting closing links or an arbitrary bare mention.
		normalized_pr=$(jq -e --argjson issue "$linked_issue" --arg repo "$repo_slug" '
			select((.closingIssuesReferences | type) == "array" and (.closingIssuesReferences | length) == 0) |
			select((.body // "") | test("(?m)^For #" + ($issue|tostring) + "([.]([ \\t]|$)|[ \\t]*$)")) |
			($repo | split("/")) as $parts |
			.closingIssuesReferences = [{number:$issue,repository:{name:$parts[1],owner:{login:$parts[0]}}}]
		' <<<"$pr_json") || return 1
	fi
	normalized_issue=$(jq --arg assignee "$assignee" --argjson claiming "$claiming" --arg interactive_label "$_PCTL_INTERACTIVE_LABEL" '
		.labels |= map(select(.name != $interactive_label)) |
		if $claiming or (.assignees | length) == 0 then .assignees = [{login:$assignee}] else . end |
		.labels |= map(if .name == "status:available" then {name:"status:in-review"} else . end)
	' <<<"$issue_json") || return 1
	_pr_checkpoint_pr_metadata_is_eligible "$normalized_pr" "$repo_slug" "$pr_number" \
		"$linked_issue" "" "" "$(jq -r '.runner' <<<"$approval")" || return 1
	_pr_checkpoint_issue_metadata_is_eligible "$normalized_issue" "$linked_issue" "$assignee" || return 1
	printf '%s\n' "$approval"
	return 0
}

# Args: $1=PR JSON, $2=repo slug, $3=PR number, $4=linked issue,
#       $5=expected SHA (optional), $6=expected ref (optional),
#       $7=expected checkpoint author (optional)
_pr_checkpoint_pr_metadata_is_eligible() {
	local pr_json="$1"
	local repo_slug="$2"
	local pr_number="$3"
	local linked_issue="$4"
	local expected_head_sha="${5:-}"
	local expected_head_ref="${6:-}"
	local expected_author="${7:-}"

	[[ "$pr_number" =~ ^[1-9][0-9]*$ && "$linked_issue" =~ ^[1-9][0-9]*$ ]] || return 1
	_pr_closing_link_matches_issue "$pr_json" "$repo_slug" "$linked_issue" || return 1

	printf '%s' "$pr_json" | jq -e --argjson pr "$pr_number" \
		--arg expected_head_sha "$expected_head_sha" --arg expected_head_ref "$expected_head_ref" \
		--arg expected_author "$expected_author" --arg interactive_label "$_PCTL_INTERACTIVE_LABEL" '
		def names: [.labels[]? | if type == "string" then . else (.name // empty) end];
		def worker_owned: names | any(. == "origin:worker" or . == "origin:worker-takeover");
		def protected: names | any(
			. == $interactive_label or . == "hold-for-review" or
			. == "no-auto-dispatch" or . == "no-takeover" or
			. == "needs-maintainer-review" or . == "persistent"
		);
		(.number == $pr) and (((.state // "") | ascii_upcase) == "OPEN") and
		(.isDraft == true) and (.isCrossRepository == false) and
		worker_owned and (protected | not) and
		(($expected_author | length) == 0 or (.author.login // "") == $expected_author) and
		(((.headRefName // "") | length) > 0) and (((.headRefOid // "") | length) > 0) and
		(($expected_head_sha | length) == 0 or .headRefOid == $expected_head_sha) and
		(($expected_head_ref | length) == 0 or .headRefName == $expected_head_ref)
	' >/dev/null 2>&1 || return 1
	return 0
}

#######################################
# Verify that the newest trusted coordination event is the worker's explicit
# draft-checkpoint release. This prevents old checkpoint markers from
# overriding a later human claim or worker dispatch.
# Args: $1=raw paginated comments JSON, $2=checkpoint runner
# Returns: 0 when exact trusted evidence is current, 1 otherwise
#######################################
_pr_checkpoint_comments_have_verified_release() {
	local comments_json="$1"
	local checkpoint_runner="$2"
	local marker="CLAIM_RELEASED reason=worker_draft_checkpoint runner=${checkpoint_runner} "
	[[ "$checkpoint_runner" =~ ^[A-Za-z0-9._-]+(\[bot\])?$ ]] || return 1

	printf '%s' "$comments_json" | jq -e --arg marker "$marker" --arg array_type "array" '
		def trusted_association:
			. == "OWNER" or . == "MEMBER" or . == "COLLABORATOR";
		def comments:
			if type == $array_type and ((.[0]? | type) == $array_type) then [.[][]?]
			elif type == $array_type then .
			else [] end;
		[comments[]?
			| select((.author_association // "") | trusted_association)
			| select((.body // "") | test("(^|\\n)(CLAIM_RELEASED reason=|DISPATCH_CLAIM |Dispatching worker|Interactive session claimed)"))
			| {body: (.body // ""), created_at: (.created_at // ""), id: ((.id // 0) | tonumber? // 0)}]
		| sort_by(.created_at, .id)
		| last
		| (.body // "")
		| contains($marker)
	' >/dev/null 2>&1 || return 1
	return 0
}

# Args: $1=REST issue JSON, $2=linked issue number, $3=expected assignee (optional),
#       $4=raw trusted-comments source JSON (optional), $5=checkpoint runner (optional)
_pr_checkpoint_issue_metadata_is_eligible() {
	local issue_json="$1"
	local linked_issue="$2"
	local expected_assignee="${3:-}"
	local comments_json="${4:-[]}"
	local checkpoint_runner="${5:-$expected_assignee}"
	local interactive_checkpoint="false"

	[[ "$linked_issue" =~ ^[1-9][0-9]*$ ]] || return 1
	# A blocked release requires the revised envelope regardless of provenance.
	# It must not fall back to legacy eligibility by dropping origin:interactive.
	if jq -e '
		(if (.[0]? | type) == "array" then [.[][]] else . end) |
		[.[] | select(.author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR")] as $trusted |
		($trusted | any((.body // "") | test("(^|\\n)CHECKPOINT_CONTINUATION_APPROVED "))) or
		([$trusted[] | select((.body // "") | test("(^|\\n)(CLAIM_RELEASED reason=|DISPATCH_CLAIM |Dispatching worker|Interactive session claimed)"))] |
		sort_by(.created_at,.id) | last | (.body // "") | test("(^|\\n)CLAIM_RELEASED reason=blocked "))
	' <<<"$comments_json" >/dev/null 2>&1; then
		return 1
	fi
	if _pr_checkpoint_comments_have_verified_release "$comments_json" "$checkpoint_runner"; then
		interactive_checkpoint="true"
	fi
	printf '%s' "$issue_json" | jq -e --argjson issue "$linked_issue" \
		--arg expected_assignee "$expected_assignee" \
		--arg interactive_checkpoint "$interactive_checkpoint" --arg interactive_label "$_PCTL_INTERACTIVE_LABEL" '
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
			(. == $interactive_label and $interactive_checkpoint != "true") or
			. == "parent-task" or . == "research" or
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
