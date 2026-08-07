#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Interactive Session Post-Merge -- Drift healing after PR merge (t2225)
# =============================================================================
# Auto-heal two known drift patterns after a planning PR merges:
#   Heal 1 (t2219): removes false status:done on OPEN For/Ref-referenced issues
#   Heal 2 (t2218): unassigns PR author from stale auto-dispatch + interactive issues
#
# Extracted from interactive-session-helper.sh (GH#21320).
#
# Usage: source "${SCRIPT_DIR}/interactive-session-helper-postmerge.sh"
#
# Dependencies:
#   - shared-constants.sh (gh_issue_comment)
#   - Logging/utility functions from orchestrator (_isc_info, _isc_warn, _isc_err,
#     _isc_gh_reachable)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ISC_POSTMERGE_LIB_LOADED:-}" ]] && return 0
_ISC_POSTMERGE_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# shellcheck source=./issue-hold-marker-lib.sh
source "${SCRIPT_DIR}/issue-hold-marker-lib.sh"

# -----------------------------------------------------------------------------
# Subcommand: post-merge (t2225)
# -----------------------------------------------------------------------------
# Auto-heal two known drift patterns after a planning PR merges.
# Called after `gh pr merge` succeeds, alongside `release <N>`.
#
# Heal pass 1 — t2219 workaround: removes false `status:done` on OPEN issues
#   referenced by `For #N` / `Ref #N` keywords (planning-convention refs that
#   issue-sync.yml title-fallback falsely closes).
#
# Heal pass 2 — t2218 workaround: unassigns the PR author from OPEN issues
#   with `origin:interactive` + `auto-dispatch` + no active status label (these
#   should be pulse-dispatched, not held by the interactive session that just
#   finished planning).
#
# Both passes are idempotent, fail-open, and post short audit-trail comments
# citing the relevant bug ID so history is traceable.
#
# Arguments:
#   $1 = PR number
#   $2 = repo slug (owner/repo) — defaults to current repo if omitted
#
# Exit: 0 always (fail-open contract).

# _isc_post_merge_heal_status_done — t2219 workaround
# Removes false status:done from OPEN For/Ref-referenced issues.
# Args: $1=pr_number $2=slug $3=pr_body
_isc_post_merge_heal_status_done() {
	local pr_number="$1"
	local slug="$2"
	local body="$3"

	# Extract For/Ref issue numbers (case-insensitive)
	local for_refs
	for_refs=$(printf '%s' "$body" \
		| grep -oiE '(for|ref)[[:space:]]+#[0-9]+' \
		| grep -oE '[0-9]+' | sort -u 2>/dev/null || true)

	[[ -n "$for_refs" ]] || return 0

	local healed=0
	local issue_num
	while IFS= read -r issue_num; do
		[[ -n "$issue_num" ]] || continue
		[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

		local issue_json issue_state issue_body has_done restore_status
		issue_json=$(gh issue view "$issue_num" --repo "$slug" --json state,labels,body 2>/dev/null) || continue
		issue_state=$(printf '%s' "$issue_json" | jq -r '.state // ""' 2>/dev/null) || continue
		[[ "$issue_state" == "OPEN" ]] || continue

		has_done=$(printf '%s' "$issue_json" | jq -r '[.labels[].name] | map(select(. == "status:done")) | length' 2>/dev/null) || continue
		[[ "${has_done:-0}" -gt 0 ]] || continue

		issue_body=$(printf '%s' "$issue_json" | jq -r '.body // ""' 2>/dev/null) || continue
		restore_status="status:available"
		if [[ "$(issue_body_has_defer_marker "$issue_body")" == "true" ]]; then
			restore_status="status:blocked"
		fi

		_isc_info "post-merge: healing false status:done on #$issue_num to $restore_status (t2219, For/Ref in PR #$pr_number)"
		gh issue edit "$issue_num" --repo "$slug" \
			--remove-label "status:done" \
			--add-label "$restore_status" >/dev/null 2>&1 || continue

		gh_issue_comment "$issue_num" --repo "$slug" --body \
			"Reset \`status:done\` → \`${restore_status}\` — PR #${pr_number} referenced this via \`For\`/\`Ref\` (planning convention), not \`Closes\`/\`Resolves\`. Workaround for [t2219](../issues/19719) (\`issue-sync.yml\` title-fallback false-positive)." \
			>/dev/null 2>&1 || true

		healed=$((healed + 1))
	done <<<"$for_refs"

	[[ $healed -gt 0 ]] && _isc_info "post-merge: healed status:done on $healed issue(s) (t2219)"
	return 0
}

# _isc_post_merge_heal_stale_self_assign — t2218 workaround
# Unassigns PR author from auto-dispatch issues with no active status.
# Args: $1=pr_number $2=slug $3=pr_body $4=pr_author
_isc_post_merge_heal_stale_self_assign() {
	local pr_number="$1"
	local slug="$2"
	local body="$3"
	local pr_author="$4"

	[[ -n "$pr_author" ]] || return 0

	# Extract ALL issue refs (closing keywords + For/Ref)
	local all_refs
	all_refs=$(printf '%s' "$body" \
		| grep -oiE '(closes?|fixes?|resolves?|for|ref)[[:space:]]+#[0-9]+' \
		| grep -oE '[0-9]+' | sort -u 2>/dev/null || true)

	[[ -n "$all_refs" ]] || return 0

	local healed=0
	local issue_num
	while IFS= read -r issue_num; do
		[[ -n "$issue_num" ]] || continue
		[[ "$issue_num" =~ ^[0-9]+$ ]] || continue

		local issue_json issue_state labels_str has_author
		issue_json=$(gh issue view "$issue_num" --repo "$slug" --json state,labels,assignees 2>/dev/null) || continue
		issue_state=$(printf '%s' "$issue_json" | jq -r '.state // ""' 2>/dev/null) || continue
		[[ "$issue_state" == "OPEN" ]] || continue

		labels_str=$(printf '%s' "$issue_json" | jq -r '[.labels[].name] | join(",")' 2>/dev/null) || continue

		# Require origin:interactive + auto-dispatch
		[[ ",$labels_str," == *",origin:interactive,"* ]] || continue
		[[ ",$labels_str," == *",auto-dispatch,"* ]] || continue
		# Skip if actively worked
		[[ ",$labels_str," != *",status:in-review,"* ]] || continue
		[[ ",$labels_str," != *",status:in-progress,"* ]] || continue

		has_author=$(printf '%s' "$issue_json" | jq -r --arg u "$pr_author" \
			'[.assignees[].login] | map(select(. == $u)) | length' 2>/dev/null) || continue
		[[ "${has_author:-0}" -gt 0 ]] || continue

		_isc_info "post-merge: healing stale self-assignment on #$issue_num (t2218, author=$pr_author)"
		gh issue edit "$issue_num" --repo "$slug" --remove-assignee "$pr_author" >/dev/null 2>&1 || continue

		gh_issue_comment "$issue_num" --repo "$slug" --body \
			"Unassigned @${pr_author} — this issue has \`auto-dispatch\` and should be pulse-dispatched to a worker. Workaround for [t2218](../issues/19718) (\`claim-task-id.sh\` missing t2157 carve-out in \`_auto_assign_issue\`)." \
			>/dev/null 2>&1 || true

		healed=$((healed + 1))
	done <<<"$all_refs"

	[[ $healed -gt 0 ]] && _isc_info "post-merge: healed stale self-assignment on $healed issue(s) (t2218)"
	return 0
}

# _isc_cmd_post_merge — entry point for the post-merge subcommand
_isc_cmd_post_merge() {
	local pr_number="" slug=""

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		-h | --help)
			_isc_cmd_help
			return 0
			;;
		*)
			if [[ -z "$pr_number" ]]; then
				pr_number="$arg"
			elif [[ -z "$slug" ]]; then
				slug="$arg"
			else
				_isc_warn "post-merge: unexpected argument: $arg (ignored)"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$pr_number" ]]; then
		_isc_err "post-merge: <pr_number> is required"
		_isc_err "usage: interactive-session-helper.sh post-merge <pr_number> [<slug>]"
		return 2
	fi

	if [[ ! "$pr_number" =~ ^[0-9]+$ ]]; then
		_isc_err "post-merge: <pr_number> must be numeric (got: $pr_number)"
		return 2
	fi

	# Resolve slug from repos.json if not provided
	if [[ -z "$slug" ]]; then
		local repos_json="${HOME}/.config/aidevops/repos.json"
		if [[ -f "$repos_json" ]]; then
			local repo_dir
			repo_dir=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
			if [[ -n "$repo_dir" ]]; then
				slug=$(jq -r --arg p "$repo_dir" \
					'.initialized_repos[] | select(.path == $p) | .slug // empty' \
					"$repos_json" 2>/dev/null | head -1 || true)
			fi
		fi
	fi

	if [[ -z "$slug" ]]; then
		# Last-resort: derive from git remote
		local remote_url
		remote_url=$(git remote get-url origin 2>/dev/null || echo "")
		if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/]+?)(\.git)?$ ]]; then
			slug="${BASH_REMATCH[1]}"
		fi
	fi

	if [[ -z "$slug" ]]; then
		_isc_err "post-merge: could not determine repo slug; pass it explicitly"
		return 2
	fi

	if ! _isc_gh_reachable; then
		_isc_warn "post-merge: gh offline — skipping post-merge heal for PR #$pr_number"
		return 0
	fi

	# Fetch PR metadata
	local pr_json merged_at state body author
	pr_json=$(gh pr view "$pr_number" --repo "$slug" --json body,author,mergedAt,state 2>/dev/null) || {
		_isc_warn "post-merge: gh unavailable or PR #$pr_number not accessible; skipping"
		return 0
	}

	merged_at=$(printf '%s' "$pr_json" | jq -r '.mergedAt // ""' 2>/dev/null || echo "")
	state=$(printf '%s' "$pr_json" | jq -r '.state // ""' 2>/dev/null || echo "")
	body=$(printf '%s' "$pr_json" | jq -r '.body // ""' 2>/dev/null || echo "")
	author=$(printf '%s' "$pr_json" | jq -r '.author.login // ""' 2>/dev/null || echo "")

	if [[ -z "$merged_at" || "$state" != "MERGED" ]]; then
		_isc_info "post-merge: PR #$pr_number not merged (state=$state); skipping"
		return 0
	fi

	_isc_info "post-merge: auditing PR #$pr_number ($slug) for drift patterns"
	_isc_post_merge_heal_status_done "$pr_number" "$slug" "$body"
	_isc_post_merge_heal_stale_self_assign "$pr_number" "$slug" "$body" "$author"
	_isc_info "post-merge: done"
	return 0
}
