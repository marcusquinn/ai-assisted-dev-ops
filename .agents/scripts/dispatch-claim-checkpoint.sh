#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Sourced by dispatch-claim-helper.sh; revised checkpoints use the same claim
# producer, consensus and lease transitions, never an assignment-guard bypass.

_dch_checkpoint_snapshot() {
	local issue="$1" repo="$2" pr="$3" head="$4" ref="$5" runner="$6" session="$7"
	local lease="${8:-}" pr_json="" issue_json="" comments=""
	pr_json=$(gh pr view "$pr" --repo "$repo" --json number,state,body,isDraft,isCrossRepository,labels,headRefName,headRefOid,author,closingIssuesReferences) || return 1
	issue_json=$(gh api "repos/${repo}/issues/${issue}") || return 1
	comments=$(gh api "repos/${repo}/issues/${issue}/comments?per_page=100" --paginate --slurp) || return 1
	jq -e --argjson issue "$issue" '.number == $issue' <<<"$issue_json" >/dev/null || return 1
	jq -e --argjson pr "$pr" --arg head "$head" --arg ref "$ref" \
		'.number == $pr and .headRefOid == $head and .headRefName == $ref' <<<"$pr_json" >/dev/null || return 1
	_pr_checkpoint_revised_target "$repo" "$pr_json" "$issue_json" "$comments" "$runner" "$lease" "$session" true |
		jq --argjson issue "$issue_json" '. + {previous_assignee:($issue.assignees[0].login // ""),
		previous_status:([$issue.labels[].name | select(startswith("status:"))][0] | sub("^status:";""))}'
	return $?
}

#aidevops:trust-boundary — exact approved release replaces only the generic
# assigned-draft predicate. Interactive fences and distributed consensus remain.
cmd_claim_pr_checkpoint() {
	local issue="${1:-}" repo="${2:-}" pr="${3:-}" head="${4:-}" ref="${5:-}" runner="${6:-}" session="${7:-}"
	local approval="" after="" nonce="" comment_id="" claims="" approval_id="" race_output=""
	[[ "$issue" =~ ^[1-9][0-9]*$ && "$pr" =~ ^[1-9][0-9]*$ && "$head" =~ ^[0-9a-f]{40,64}$ &&
		"$runner" =~ ^[A-Za-z0-9._-]+$ && "$session" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
	[[ "$(_resolve_runner "")" == "$runner" ]] || return 1
	aidevops_can_manage_repo_issue_state "$repo" "$runner" || return 1
	if declare -F _interactive_claim_fence_blocks_dispatch >/dev/null 2>&1 &&
		_interactive_claim_fence_blocks_dispatch "$issue" "$repo"; then
		return 1
	fi
	approval=$(_dch_checkpoint_snapshot "$issue" "$repo" "$pr" "$head" "$ref" "$runner" "$session") || return 1
	approval_id=$(jq -r '.approval_id' <<<"$approval") || return 1
	nonce=$(_generate_nonce) || return 1
	comment_id=$(_post_claim "$issue" "$repo" "$runner" "$nonce" "$(_now_utc)" \
		"checkpoint_approval=${approval_id}" "$session") || return 1
	sleep "$DISPATCH_CLAIM_WINDOW"
	claims=$(_fetch_claims "$issue" "$repo" "$runner") || return 1
	if ! race_output=$(_resolve_claim_race_result "$issue" "$repo" "$runner" "$nonce" "$comment_id" "$claims"); then
		return 1
	fi
	# Fresh reread after consensus rejects revision/head/owner drift and any newer
	# worker or human event, including a competing claim from this same account.
	if ! after=$(_dch_checkpoint_snapshot "$issue" "$repo" "$pr" "$head" "$ref" "$runner" "$session" "$nonce") ||
		[[ "$after" != "$approval" ]] ||
		{ declare -F _interactive_claim_fence_blocks_dispatch >/dev/null 2>&1 &&
			_interactive_claim_fence_blocks_dispatch "$issue" "$repo"; }; then
		_delete_losing_claim_comment "$repo" "$comment_id"
		return 1
	fi
	jq --arg lease "$nonce" --arg session "$session" \
		'{lease:$lease,session:$session,approval_id,previous_assignee,previous_status}' <<<"$approval"
	return 0
}
