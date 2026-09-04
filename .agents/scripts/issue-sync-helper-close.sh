#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Issue Sync Helper — Close & Reopen Commands
# =============================================================================
# Close helpers (_do_close, evidence checks, PR lookup) plus the cmd_close
# and cmd_reopen entry points.
#
# Usage: source "${SCRIPT_DIR}/issue-sync-helper-close.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_warning, print_success)
#   - issue-sync-lib.sh (_escape_ere, extract_task_block, strip_code_fences,
#     add_gh_ref_to_todo, add_pr_ref_to_todo, sed_inplace)
#   - issue-sync-helper-labels.sh (gh_create_label, _gh_edit_labels,
#     _mark_issue_done, gh_find_issue_by_title, gh_find_merged_pr, gh_list_issues)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ISSUE_SYNC_HELPER_CLOSE_LOADED:-}" ]] && return 0
_ISSUE_SYNC_HELPER_CLOSE_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi
# shellcheck source=./dependency-event-reconciler.sh
source "${SCRIPT_DIR}/dependency-event-reconciler.sh"

# =============================================================================
# Close Helpers
# =============================================================================

# _is_cancelled_or_deferred: returns 0 if the task text indicates it was
# cancelled, deferred, or declined — these states require no PR/verified evidence.
_is_cancelled_or_deferred() {
	local text="$1"
	echo "$text" | grep -qiE 'cancelled:[0-9]{4}-[0-9]{2}-[0-9]{2}|deferred:[0-9]{4}-[0-9]{2}-[0-9]{2}|declined:[0-9]{4}-[0-9]{2}-[0-9]{2}|CANCELLED' && return 0
	return 1
}

_has_evidence() {
	local text="$1" task_id="$2" repo="$3"
	local issue_number="${4:-}"
	local task_line
	task_line=$(_task_line_from_block "$text" "$task_id")
	# Cancelled/deferred/declined tasks need no PR or verified: evidence
	_is_cancelled_or_deferred "$task_line" && return 0
	if _has_unresolved_blocker "$text" "$task_id" "$task_line" "$repo" "$issue_number"; then
		return 1
	fi
	echo "$text" | grep -qE 'verified:[0-9]{4}-[0-9]{2}-[0-9]{2}|pr:#[0-9]+' && return 0
	echo "$text" | grep -qiE 'PR #[0-9]+ merged|PR.*merged' && return 0
	[[ -n "$repo" && -n "$task_id" ]] && return 1
	return 1
}

_task_line_from_block() {
	local text="$1" task_id="${2:-}"
	local task_line
	if [[ -n "$task_id" ]]; then
		task_line=$(printf '%s\n' "$text" | grep -F " $task_id " | grep -E '^[[:space:]]*- \[.\] ' | head -1 || true)
	fi
	[[ -z "$task_line" ]] && task_line=$(printf '%s\n' "$text" | grep -E '^[[:space:]]*- \[.\] ' | head -1 || true)
	[[ -z "$task_line" ]] && task_line=$(printf '%s\n' "$text" | head -1)
	printf '%s\n' "$task_line"
	return 0
}

_has_unresolved_blocker() {
	local text="$1"
	local task_id="${2:-}"
	local task_line="${3:-}"
	local repo="${4:-}"
	local issue_number="${5:-}"
	local candidate
	candidate="${task_line:-$(_task_line_from_block "$text" "$task_id")}"
	printf '%s\n' "$candidate" | grep -qE '(^|[[:space:]])blocked-by:[^[:space:]]+' || return 1
	[[ -n "$repo" && "$issue_number" =~ ^[0-9]+$ ]] || return 0
	_der_completion_blockers_closed "$repo" "$issue_number" "$candidate" && return 1
	return 0
}

_find_closing_pr() {
	local text="$1" task_id="$2" repo="$3"
	local pr
	pr=$(echo "$text" | grep -oE 'pr:#[0-9]+|PR #[0-9]+' | head -1 | grep -oE '[0-9]+' || echo "")
	[[ -n "$pr" ]] && {
		echo "${pr}|https://github.com/${repo}/pull/${pr}"
		return 0
	}
	[[ -n "$repo" && -n "$task_id" ]] && return 1
	return 1
}

# t3204: append signature footer to close-comment bodies. Without it the
# auto-close path (gh issue close --comment from _do_close, which bypasses the
# `gh` PATH shim because `issue:close` is not in the shim's intercept list)
# emitted bare one-liners with no runtime/version/model/token metadata —
# in stark contrast to the rich + signed comments produced by interactive
# agents using gh_issue_comment / the shim. See AGENTS.md "Signature footer
# hallucination (t2685)" for the canonical rule.
_close_comment() {
	local task_id="$1" text="$2" pr_num="$3" pr_url="$4" repo="${5:-}" issue_number="${6:-}"
	local body
	# Cancelled/deferred/declined: produce a not-planned comment (no PR needed)
	if _is_cancelled_or_deferred "$text"; then
		local reason
		reason=$(echo "$text" | grep -oiE 'cancelled:[0-9-]+|deferred:[0-9-]+|declined:[0-9-]+|CANCELLED' | head -1 | tr '[:upper:]' '[:lower:]')
		[[ -z "$reason" ]] && reason="cancelled"
		body="Closing as not planned ($reason). Task $task_id resolved in TODO.md."
	elif [[ -n "$pr_num" && -n "$pr_url" ]]; then
		body="Completed via [PR #${pr_num}](${pr_url}). Task $task_id done in TODO.md."
	elif [[ -n "$pr_num" ]]; then
		body="Completed via PR #${pr_num}. Task $task_id done in TODO.md."
	else
		local d
		d=$(echo "$text" | grep -oE 'verified:[0-9-]+' | head -1 | sed 's/verified://')
		if [[ -n "$d" ]]; then
			body="Completed (verified: $d). Task $task_id done in TODO.md."
		else
			body="Completed. Task $task_id done in TODO.md."
		fi
	fi

	# t3204: append signature footer (--solved since this comment marks issue close).
	# When repo/issue_number are passed, the helper sums total session time + tokens
	# across all worker comments on this issue. Fail-open: missing args or helper
	# failure leaves the body un-signed rather than emitting nothing.
	local footer=""
	if [[ -n "$repo" && -n "$issue_number" ]]; then
		footer=$(gh-signature-helper.sh footer --solved --issue "${repo}#${issue_number}" 2>/dev/null || true)
	else
		footer=$(gh-signature-helper.sh footer --solved 2>/dev/null || true)
	fi
	printf '%s%s\n' "$body" "$footer"
	return 0
}

# t3204: reopen-comment composition extracted into a helper so the signature
# footer block and the body text are testable in isolation. Called by cmd_reopen
# below; the helper output replaces the previous inline --comment string.
_reopen_comment() {
	local repo="${1:-}" ref_num="${2:-}"
	local body="Reopened: TODO.md still has this as incomplete (\`[ ]\` or \`[>]\`) and no merged PR was found. The issue was prematurely closed by a commit keyword. TODO.md is the source of truth for task state."
	local footer=""
	if [[ -n "$repo" && -n "$ref_num" ]]; then
		footer=$(gh-signature-helper.sh footer --issue "${repo}#${ref_num}" 2>/dev/null || true)
	else
		footer=$(gh-signature-helper.sh footer 2>/dev/null || true)
	fi
	printf '%s%s\n' "$body" "$footer"
	return 0
}

_reopen_ref_is_pull_request() {
	local repo="$1" ref_num="$2" argc="$#" prefetched_issue_json="${3-}"
	local issue_json
	if [[ "$argc" -ge 3 ]]; then
		issue_json="$prefetched_issue_json"
	else
		issue_json=$(gh api "repos/${repo}/issues/${ref_num}" 2>/dev/null) || return 1
	fi
	printf '%s\n' "$issue_json" | jq -e 'select(type == "object") | has("pull_request")' >/dev/null 2>&1 && return 0
	return 1
}

_has_prior_reopen_comment() {
	local repo="$1" ref_num="$2"
	local comments_json found
	comments_json=$(gh api "repos/${repo}/issues/${ref_num}/comments" 2>/dev/null || printf '[]')
	found=$(printf '%s\n' "$comments_json" | jq -r 'if type == "array" then [.[] | select(.body? | strings | contains("Reopened: TODO.md still has this as"))] | length else 0 end' 2>/dev/null || printf '0')
	[[ "$found" =~ ^[0-9]+$ ]] || found=0
	if [[ "$found" -gt 0 ]]; then
		return 0
	fi
	return 1
}

_is_not_planned_state_reason() {
	local reason="${1:-}"
	local normalized
	normalized=$(printf '%s' "$reason" | tr '[:upper:]' '[:lower:]' | tr '-' '_')
	[[ "$normalized" == "not_planned" ]] && return 0
	return 1
}

# Mark a TODO entry as done: [ ]/[>] -> [x] with completed: date.
# Also handles [-] (cancelled/declined) entries — leaves marker as [-].
_mark_todo_done() {
	local task_id="$1" todo_file="$2" proof_log="${3:-}"
	local task_id_ere
	if [[ -n "$proof_log" && ! "$proof_log" =~ ^verified:[0-9]{4}-[0-9]{2}-[0-9]{2}$ && ! "$proof_log" =~ ^pr:#[0-9]+$ ]]; then
		return 1
	fi
	task_id_ere=$(_escape_ere "$task_id")
	local today
	today=$(date -u +%Y-%m-%d)
	[[ -n "$proof_log" && "$proof_log" != " "* ]] && proof_log=" $proof_log"

	# Only flip incomplete [ ]/[>] entries; skip if already [x] or [-].
	# Use [[:space:]] not \s for macOS sed compatibility (bash 3.2)
	if grep -qE "^[[:space:]]*- \[[ >]\] ${task_id_ere} " "$todo_file" 2>/dev/null; then
		# Flip checkbox and append completed: date
		if ! sed -i.bak -E "s/^([[:space:]]*- )\[[ >]\] (${task_id_ere} .*)/\1[x] \2${proof_log} completed:${today}/" "$todo_file"; then
			rm -f "${todo_file}.bak"
			return 1
		fi
		rm -f "${todo_file}.bak"
		_dedupe_todo_task_lines "$task_id" "$todo_file" || true
		log_verbose "Marked $task_id as [x] in TODO.md"
	fi
	return 0
}

# Converge a live TODO row with a linked issue deliberately closed as not
# planned. The immutable GitHub closure timestamp is the evidence marker, so
# repeated reconciliation is byte-stable and never uses the current clock.
_mark_todo_not_planned() {
	local task_id="$1"
	local issue_number="$2"
	local todo_file="$3"
	local closed_date="$4"
	local task_id_ere=""
	local line_num=""
	local target_line=""
	local new_line=""
	local new_line_escaped=""

	[[ "$task_id" =~ ^t[0-9]+(\.[0-9]+)*$ ]] || return 1
	[[ "$issue_number" =~ ^[0-9]+$ ]] || return 1
	[[ "$closed_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
	task_id_ere=$(_escape_ere "$task_id")
	if ! line_num=$(_todo_task_line_num "$task_id" "$todo_file"); then
		return 1
	fi
	[[ -n "$line_num" ]] || return 1
	target_line=$(sed -n "${line_num}p" "$todo_file")
	if printf '%s\n' "$target_line" | grep -qE \
		"^[[:space:]]*- \[-\] ${task_id_ere} .*ref:GH#${issue_number}([[:space:]]|$).*declined:${closed_date}([[:space:]]|$)"; then
		return 0
	fi
	printf '%s\n' "$target_line" | grep -qE "^[[:space:]]*- \[[ >]\] ${task_id_ere} .*ref:GH#${issue_number}([[:space:]]|$)" || return 1

	new_line=$(printf '%s\n' "$target_line" | sed -E 's/^([[:space:]]*- )\[[ >]\]/\1[-]/')
	if ! printf '%s\n' "$new_line" | grep -qE '(^|[[:space:]])(declined|cancelled):[0-9]{4}-[0-9]{2}-[0-9]{2}([[:space:]]|$)'; then
		new_line="${new_line} declined:${closed_date}"
	fi
	new_line_escaped=$(printf '%s' "$new_line" | sed 's/[|&\\]/\\&/g')
	sed_inplace "${line_num}s|.*|${new_line_escaped}|" "$todo_file" || return 1
	log_verbose "#$issue_number ($task_id) closed as not_planned — marked TODO [-]"
	return 0
}

_closed_issue_worker_complete_date() {
	local repo="$1" issue_number="$2"
	local completed_at

	completed_at=$(gh api "repos/${repo}/issues/${issue_number}/comments" \
		--jq '[.[] | select((.body // "") | contains("CLAIM_RELEASED reason=worker_complete")) | .created_at][0] // ""' 2>/dev/null) || return 1
	[[ "$completed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
	printf '%s\n' "${completed_at%%T*}"
	return 0
}

_closed_issue_aidevops_complete_date() {
	local repo="$1" issue_number="$2"
	local issue_json="" comments_json="" state_reason="" closed_at=""
	local issue_body="" comment_evidence="" evidence=""

	issue_json=$(AIDEVOPS_GH_ROUTE_DECISION="issue-sync-completion-issue-rest" \
		gh api "repos/${repo}/issues/${issue_number}" 2>/dev/null) || return 1
	comments_json=$(AIDEVOPS_GH_ROUTE_DECISION="issue-sync-completion-comments-rest" \
		gh api --paginate --slurp \
			"repos/${repo}/issues/${issue_number}/comments?per_page=100" 2>/dev/null) || return 1
	state_reason=$(printf '%s' "$issue_json" | jq -r '.state_reason // .stateReason // ""' 2>/dev/null) || state_reason=""
	closed_at=$(printf '%s' "$issue_json" | jq -r '.closed_at // .closedAt // ""' 2>/dev/null) || closed_at=""
	issue_body=$(printf '%s' "$issue_json" | jq -r '.body // ""' 2>/dev/null) || return 1
	comment_evidence=$(printf '%s' "$comments_json" | jq -r \
		'[.[][]? | .body // ""] | join("\n---\n")' 2>/dev/null) || return 1
	evidence=$(printf '%s\n---\n%s' "$issue_body" "$comment_evidence")

	case "$state_reason" in
	COMPLETED | completed) ;;
	*) return 1 ;;
	esac
	[[ "$closed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
	if printf '%s' "$evidence" | grep -qE 'aidevops:sig|CLAIM_RELEASED reason=worker_complete|Task t[0-9]+(\.[0-9]+)* done in TODO\.md|Completed via (\[)?PR #[0-9]+'; then
		printf '%s\n' "${closed_at%%T*}"
		return 0
	fi
	return 1
}

_mark_reopen_completed_task() {
	local tid="$1" todo_file="$2" ref_num="$3" proof_date="$4" reason="$5"
	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[DRY-RUN] Would mark $tid [x] ($reason on #$ref_num)"
		return 0
	fi
	_mark_todo_done "$tid" "$todo_file" "verified:${proof_date}" || return 1
	log_verbose "#$ref_num ($tid) has $reason — marked TODO [x]"
	return 0
}

_mark_reopen_merged_pr_task() {
	local tid="$1" todo_file="$2" ref_num="$3" pr_num="$4"
	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[DRY-RUN] Would mark $tid [x] (merged PR #$pr_num)"
		return 0
	fi
	add_pr_ref_to_todo "$tid" "$pr_num" "$todo_file" 2>/dev/null || true
	_mark_todo_done "$tid" "$todo_file" || return 1
	log_verbose "#$ref_num ($tid) has merged PR #$pr_num — marked TODO [x]"
	return 0
}

_reopen_find_merged_pr() {
	local repo="$1" tid="$2" ref_num="$3"
	local owner="${repo%%/*}" name="${repo#*/}"
	local pr_info="" result="" reported_cost=""

	pr_info=$(gh_find_merged_pr "$repo" "$tid" 2>/dev/null || true)
	if [[ -n "$pr_info" ]]; then
		printf '%s\n' "$pr_info"
		return 0
	fi

	# A full-loop PR may be titled with GH#NNN rather than the TODO task ID.
	# Query GitHub's structural closing relationship so a merged implementation
	# cannot be reopened merely because title-based discovery missed it.
	[[ "$repo" == */* && -n "$owner" && -n "$name" && "$ref_num" =~ ^[0-9]+$ ]] || return 1
	# shellcheck disable=SC2016
	result=$(AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE=1 \
		AIDEVOPS_GH_ROUTE_DECISION="issue-sync-reopen-closing-pr-exact-cost" \
		gh api graphql -f query='
query($owner:String!,$name:String!,$number:Int!) {
  repository(owner:$owner,name:$name) {
    nameWithOwner
    issue(number:$number) {
      closedByPullRequestsReferences(first:100) {
        nodes { number url state mergedAt repository { nameWithOwner } }
        pageInfo { hasNextPage }
      }
    }
  }
	rateLimit { cost }
}' -F owner="$owner" -F name="$name" -F number="$ref_num" 2>/dev/null) || return 1
	reported_cost=$(printf '%s' "$result" | jq -r '.data.rateLimit.cost // empty' 2>/dev/null) || reported_cost=""
	[[ "$reported_cost" =~ ^[1-9][0-9]*$ ]] || return 1
	printf '%s' "$result" | jq -er --arg repo "$repo" '
      .data.repository
      | select(.nameWithOwner == $repo)
      | .issue.closedByPullRequestsReferences
      | select(.pageInfo.hasNextPage == false)
      | [.nodes[]
          | select(.repository.nameWithOwner == $repo and .state == "MERGED" and (.mergedAt // "") != "")]
      | first
      | select(. != null)
      | "\(.number)|\(.url)"' 2>/dev/null
	return $?
}

_reopen_mark_if_completed() {
	local repo="$1" tid="$2" ref_num="$3" todo_file="$4"
	local pr_info
	pr_info=$(_reopen_find_merged_pr "$repo" "$tid" "$ref_num" 2>/dev/null || true)
	if [[ -n "$pr_info" ]]; then
		local pr_num="${pr_info%%|*}"
		_mark_reopen_merged_pr_task "$tid" "$todo_file" "$ref_num" "$pr_num" || return 1
		return 0
	fi

	local completed_date
	completed_date=$(_closed_issue_worker_complete_date "$repo" "$ref_num" || true)
	if [[ -n "$completed_date" ]]; then
		_mark_reopen_completed_task "$tid" "$todo_file" "$ref_num" "$completed_date" "worker_complete evidence" || return 1
		return 0
	fi

	completed_date=$(_closed_issue_aidevops_complete_date "$repo" "$ref_num" || true)
	if [[ -n "$completed_date" ]]; then
		_mark_reopen_completed_task "$tid" "$todo_file" "$ref_num" "$completed_date" "aidevops close evidence" || return 1
		return 0
	fi
	return 1
}

# Reconcile a mapped TODO row when the remote issue is already terminal. This
# path deliberately performs no GitHub mutation: local state advances only from
# verified completion evidence or an immutable not-planned closure timestamp.
_reconcile_already_closed_task() {
	local task_id="$1"
	local issue_number="$2"
	local todo_file="$3"
	local repo="$4"
	local task_line="$5"
	local issue_json="$6"
	local state_reason=""
	local closed_at=""
	local closed_date=""
	local issue_labels=""

	require_task_issue_mapping "$task_id" "$todo_file" "$repo" "$issue_number" || return 1
	state_reason=$(printf '%s' "$issue_json" | jq -r '.state_reason // .stateReason // ""' 2>/dev/null) || return 1
	closed_at=$(printf '%s' "$issue_json" | jq -r '.closed_at // .closedAt // ""' 2>/dev/null) || return 1
	issue_labels=$(printf '%s' "$issue_json" | jq -r \
		'[.labels[]? | if type == "object" then (.name // "") else . end] | join(" ")' 2>/dev/null) || return 1

	if _is_not_planned_state_reason "$state_reason"; then
		[[ "$closed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || {
			print_warning "#$issue_number is closed as not planned but has no valid closure timestamp; TODO unchanged"
			return 1
		}
		closed_date="${closed_at%%T*}"
		if [[ "$DRY_RUN" == "true" ]]; then
			print_info "[DRY-RUN] Would mark $task_id [-] (not_planned on #$issue_number)"
			return 0
		fi
		_mark_todo_not_planned "$task_id" "$issue_number" "$todo_file" "$closed_date" || return 1
		return 0
	fi

	case "$state_reason" in
	COMPLETED | completed) ;;
	*)
		print_warning "#$issue_number is closed with ambiguous reason '${state_reason:-none}'; TODO unchanged"
		return 1
		;;
	esac
	if printf '%s\n' "$issue_labels" | grep -qw "parent-task"; then
		print_warning "#$issue_number ($task_id) is a parent task; terminal PR linkage must reconcile it"
		return 1
	fi
	if ! _is_cancelled_or_deferred "$task_line" &&
		_has_unresolved_blocker "$task_line" "" "$task_line" "$repo" "$issue_number"; then
		print_warning "#$issue_number ($task_id) still has an unresolved dependency; TODO unchanged"
		return 1
	fi
	if _reopen_mark_if_completed "$repo" "$task_id" "$issue_number" "$todo_file"; then
		return 0
	fi
	print_warning "#$issue_number is closed as completed without acceptable completion evidence; TODO unchanged"
	return 1
}

_do_close() {
	local task_id="$1" issue_number="$2" todo_file="$3" repo="$4"
	require_task_issue_mapping "$task_id" "$todo_file" "$repo" "$issue_number" || return 1
	local task_with_notes task_line pr_info pr_num="" pr_url=""
	task_with_notes=$(extract_task_block "$task_id" "$todo_file")
	task_line=$(_first_todo_task_line_or_empty "$task_id" "$todo_file") || return 1
	[[ -z "$task_with_notes" ]] && task_with_notes="$task_line"

	# GH#20828: probe parent-task label before closing. The workflow path's
	# title-fallback close was guarded by t2137 (issue-sync-reusable.yml:480-484);
	# this is the parallel guard for the bash-helper close path that runs from
	# TODO.md `[x]` pushes. A `parent-task`-labelled issue must stay open until
	# its terminal-phase PR merges with `Closes #NNN` (per the t2046 For/Ref
	# convention). Skip the close + skip status:done; the TODO entry is left
	# unchanged so a human can decide whether the `[x]` was premature or
	# whether the parent should be closed via terminal PR.
	local issue_labels
	issue_labels=$(gh api "repos/${repo}/issues/${issue_number}" --jq '[.labels[].name] | join(" ")' 2>/dev/null || echo "")
	if echo "$issue_labels" | grep -qw "parent-task"; then
		print_info "Skipping #$issue_number ($task_id): parent-task label set — parent issues close via terminal-phase PR with explicit Closes #NNN, not TODO [x] (GH#20828)"
		return 0
	fi
	if ! _is_cancelled_or_deferred "$task_line" && _has_unresolved_blocker "$task_line" "" "$task_line" "$repo" "$issue_number"; then
		print_info "Skipping #$issue_number ($task_id): unresolved blocked-by marker present — completion evidence must wait for dependencies (GH#23516)"
		return 0
	fi

	pr_info=$(_find_closing_pr "$task_with_notes" "$task_id" "$repo" 2>/dev/null || echo "")
	if [[ -n "$pr_info" ]]; then
		pr_num="${pr_info%%|*}"
		pr_url="${pr_info#*|}"
		[[ "$DRY_RUN" != "true" && -n "$pr_num" ]] && add_pr_ref_to_todo "$task_id" "$pr_num" "$todo_file"
		task_line=$(_first_todo_task_line_or_empty "$task_id" "$todo_file") || return 1
		task_with_notes=$(extract_task_block "$task_id" "$todo_file")
		[[ -z "$task_with_notes" ]] && task_with_notes="$task_line"
	fi

	if [[ "$FORCE_CLOSE" == "true" ]]; then
		print_info "FORCE_CLOSE active — bypassing evidence check for #$issue_number ($task_id) (GH#20146 audit)"
	fi
	if [[ "$FORCE_CLOSE" != "true" ]] && ! _has_evidence "$task_with_notes" "$task_id" "$repo" "$issue_number"; then
		print_warning "Skipping #$issue_number ($task_id): no merged PR or verified: field"
		return 1
	fi

	local comment
	# t3204: pass repo + issue_number so _close_comment can ask the signature
	# helper for an issue-scoped footer (sums total session time and tokens
	# across all worker comments on this issue, not just this invocation).
	comment=$(_close_comment "$task_id" "$task_with_notes" "$pr_num" "$pr_url" "$repo" "$issue_number")
	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[DRY-RUN] Would close #$issue_number ($task_id)"
		return 0
	fi
	# Cancelled/deferred/declined tasks close as "not planned"; completed tasks use default reason
	local close_args=("issue" "close" "$issue_number" "--repo" "$repo" "--comment" "$comment")
	if _is_cancelled_or_deferred "$task_line"; then
		close_args+=("--reason" "not planned")
		gh_create_label "$repo" "not-planned" "E4E669" "Closed as not planned"
	fi
	if gh "${close_args[@]}" 2>/dev/null; then
		if _is_cancelled_or_deferred "$task_line"; then
			_gh_edit_labels "add" "$repo" "$issue_number" "not-planned"
		elif [[ "$pr_num" =~ ^[0-9]+$ ]]; then
			set_solved_label_from_merged_pr "$issue_number" "$repo" "$pr_num" || true
		fi
		_mark_issue_done "$repo" "$issue_number"
		_mark_todo_done "$task_id" "$todo_file"
		reconcile_dependants_after_verified_closure "$repo" "$issue_number" || true
		print_success "Closed #$issue_number ($task_id)"
	else
		print_error "Failed to close #$issue_number ($task_id)"
		return 1
	fi
}

# =============================================================================
# cmd_close
# =============================================================================

cmd_close() {
	local target_task="${1:-}"
	_init_cmd || return 1
	local repo="$_CMD_REPO" todo_file="$_CMD_TODO"

	# Single-task mode
	if [[ -n "$target_task" ]]; then
		local task_line
		task_line=$(_first_todo_task_line_or_empty "$target_task" "$todo_file") || return 1
		local num
		num=$(echo "$task_line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
		if [[ -z "$num" ]]; then
			num=$(gh_find_issue_by_title "$repo" "${target_task}:" "open" 500)
			[[ -n "$num" && "$DRY_RUN" != "true" ]] && add_gh_ref_to_todo "$target_task" "$num" "$todo_file"
		fi
		[[ -z "$num" ]] && {
			print_info "$target_task: no matching issue"
			return 0
		}
		local issue_json=""
		local st=""
		issue_json=$(gh api "repos/${repo}/issues/${num}" 2>/dev/null) || {
			print_error "Could not verify #$num before close reconciliation"
			return 1
		}
		st=$(printf '%s' "$issue_json" | jq -r '.state // ""' 2>/dev/null) || return 1
		if [[ "$st" == "CLOSED" || "$st" == "closed" ]]; then
			log_verbose "#$num already closed — reconciling TODO state"
			_reconcile_already_closed_task "$target_task" "$num" "$todo_file" "$repo" "$task_line" "$issue_json"
			return $?
		fi
		if [[ "$st" != "OPEN" && "$st" != "open" ]]; then
			print_error "Could not determine whether #$num is open"
			return 1
		fi
		_do_close "$target_task" "$num" "$todo_file" "$repo" || true
		return 0
	fi

	# Bulk mode: fetch all open issues, build task->issue map. The TODO loop below
	# consumes the complete stripped stream, so its grep consumer cannot SIGPIPE.
	local open_json
	open_json=$(gh_list_issues "$repo" "open" 500)
	local map=""
	while IFS='|' read -r n t; do
		[[ -z "$n" ]] && continue
		local tid
		tid=$(echo "$t" | grep -oE '^t[0-9]+(\.[0-9]+)*' || echo "")
		[[ -n "$tid" ]] && map="${map}${tid}|${n}"$'\n'
	done < <(echo "$open_json" | jq -r '.[] | "\(.number)|\(.title)"' 2>/dev/null || true)
	[[ -z "$map" ]] && {
		print_info "No open issues to close"
		return 0
	}

	local closed=0 skipped=0 ref_fixed=0
	while IFS= read -r line; do
		local task_id
		task_id=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
		[[ -z "$task_id" ]] && continue
		local task_id_ere
		task_id_ere=$(_escape_ere "$task_id")
		local mapped
		mapped=$(echo "$map" | grep -E "^${task_id_ere}\|" | head -1 || echo "")
		[[ -z "$mapped" ]] && continue
		local issue_num="${mapped#*|}"
		local ref
		ref=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
		if [[ "$DRY_RUN" != "true" ]]; then
			if [[ -n "$ref" && "$ref" != "$issue_num" ]]; then
				fix_gh_ref_in_todo "$task_id" "$ref" "$issue_num" "$todo_file"
				ref_fixed=$((ref_fixed + 1))
			elif [[ -z "$ref" ]]; then
				add_gh_ref_to_todo "$task_id" "$issue_num" "$todo_file"
				ref_fixed=$((ref_fixed + 1))
			fi
		fi
		if _do_close "$task_id" "$issue_num" "$todo_file" "$repo"; then closed=$((closed + 1)); else skipped=$((skipped + 1)); fi
	done < <(strip_code_fences <"$todo_file" | grep -E '^\s*- \[(x|-)\] t[0-9]+' || true)
	print_info "Close: $closed closed, $skipped skipped, $ref_fixed refs fixed"
}

# =============================================================================
# cmd_reopen
# =============================================================================

# Reopen closed GitHub issues whose TODO entries are incomplete [ ]/[>].
# TODO.md is the source of truth: if a task is [ ] or [>], the work is not done,
# regardless of whether a commit message prematurely closed the issue.
#
# Decision tree per closed issue:
#   NOT_PLANNED         -> mark the linked live TODO row [-] once
#   COMPLETED + has PR  -> skip (work done, TODO needs marking [x] separately)
#   COMPLETED + no PR   -> reopen (premature closure from commit keyword)
_reopen_incomplete_task_line() {
	local repo="$1"
	local todo_file="$2"
	local open_numbers="$3"
	local line="$4"
	local ref_num=""
	local issue_json=""
	local tid=""
	local reason=""
	local closed_at=""
	local issue_close_fields=""
	local closed_date=""
	local reopen_comment_body=""

	ref_num=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
	[[ -n "$ref_num" ]] || return 0
	if echo "$open_numbers" | grep -qx "$ref_num"; then
		return 0
	fi

	issue_json=$(gh api "repos/${repo}/issues/${ref_num}" 2>/dev/null || printf '{}')
	if _reopen_ref_is_pull_request "$repo" "$ref_num" "$issue_json"; then
		log_verbose "#$ref_num is a pull request — skipping TODO reopen guard"
		return 14
	fi

	tid=$(echo "$line" | grep -oE 't[0-9]+(\.[0-9]+)*' | head -1 || echo "")
	issue_close_fields=$(printf '%s\n' "$issue_json" | jq -r 'select(type == "object") | [(.state_reason // .stateReason // ""), (.closed_at // .closedAt // "")] | @tsv' 2>/dev/null || printf '')
	reason=${issue_close_fields%%$'\t'*}
	if _is_not_planned_state_reason "$reason"; then
		closed_at=${issue_close_fields#*$'\t'}
		[[ "$closed_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 11
		closed_date="${closed_at%%T*}"
		if [[ "$DRY_RUN" == "true" ]]; then
			print_info "[DRY-RUN] Would mark $tid [-] (not_planned on #$ref_num)"
		elif ! _mark_todo_not_planned "$tid" "$ref_num" "$todo_file" "$closed_date"; then
			return 11
		fi
		return 12
	fi
	if _reopen_mark_if_completed "$repo" "$tid" "$ref_num" "$todo_file"; then
		return 13
	fi
	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[DRY-RUN] Would reopen #$ref_num ($tid)"
		return 10
	fi
	if _has_prior_reopen_comment "$repo" "$ref_num"; then
		log_verbose "#$ref_num ($tid) already has a TODO-source reopen comment — suppressing duplicate notification"
		return 15
	fi

	reopen_comment_body=$(_reopen_comment "$repo" "$ref_num")
	if ! require_task_issue_mapping "$tid" "$todo_file" "$repo" "$ref_num"; then
		return 11
	fi
	if gh issue reopen "$ref_num" --repo "$repo" \
		--comment "$reopen_comment_body" 2>/dev/null; then
		print_success "Reopened #$ref_num ($tid)"
		return 10
	fi
	print_warning "Failed to reopen #$ref_num ($tid)"
	return 11
}

cmd_reopen() {
	_init_cmd || return 1
	local repo="$_CMD_REPO" todo_file="$_CMD_TODO"

	# Build set of open issue numbers for fast lookup
	local open_json
	open_json=$(gh_list_issues "$repo" "open" 500)
	local open_numbers
	open_numbers=$(echo "$open_json" | jq -r '.[].number' 2>/dev/null | sort -n)

	local unique_lines
	if ! unique_lines=$(_unique_todo_task_snapshot "$todo_file"); then
		print_error "Failed to parse unique TODO task snapshot"
		return 1
	fi
	local reopened=0 skipped=0 not_planned=0 has_pr=0 pr_refs=0 duplicate_comments=0
	local incomplete_ref_re='^[[:space:]]*-[[:space:]]+\[[[:space:]>]\][[:space:]]+t[0-9]+.*ref:GH#[0-9]+'

	local line_status=0
	while IFS= read -r line; do
		[[ "$line" =~ $incomplete_ref_re ]] || continue
		if _reopen_incomplete_task_line "$repo" "$todo_file" "$open_numbers" "$line"; then
			line_status=0
		else
			line_status=$?
		fi
		case "$line_status" in
		10) reopened=$((reopened + 1)) ;;
		11) skipped=$((skipped + 1)) ;;
		12) not_planned=$((not_planned + 1)) ;;
		13) has_pr=$((has_pr + 1)) ;;
		14) pr_refs=$((pr_refs + 1)) ;;
		15) duplicate_comments=$((duplicate_comments + 1)) ;;
		esac
	done <<<"$unique_lines"

	print_info "Reopen: $reopened reopened, $skipped failed, $not_planned not-planned-terminalized, $has_pr have-merged-pr, $pr_refs pr-refs-skipped, $duplicate_comments duplicate-comments-skipped"
	return 0
}
