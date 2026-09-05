#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Issue Sync Helper — Labels & GitHub API Wrappers
# =============================================================================
# Label management, tier ratcheting, protected-label checks, and thin gh CLI
# wrappers used by push, enrich, close, and command modules.
#
# Usage: source "${SCRIPT_DIR}/issue-sync-helper-labels.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_warning, print_success,
#     set_issue_status, session_origin_label, gh_issue_edit_safe)
#   - issue-sync-lib.sh (map_tags_to_labels)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ISSUE_SYNC_HELPER_LABELS_LOADED:-}" ]] && return 0
_ISSUE_SYNC_HELPER_LABELS_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# GitHub API (gh CLI wrappers — kept for multi-call functions only)
# =============================================================================

_issue_labels_include_exact() {
	local labels_json="$1" label_name="$2"
	if printf '%s' "$labels_json" |
		jq -e --arg label_name "$label_name" 'any(.[]?; .name == $label_name)' >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

gh_list_issues() {
	local repo="$1" state="$2" limit="$3"
	local -a args=(
		--repo "$repo" --state "$state" --limit "$limit"
		--json "number,title,assignees,state,labels"
	)
	if declare -F gh_issue_list >/dev/null 2>&1; then
		gh_issue_list "${args[@]}" 2>/dev/null
		return $?
	fi
	if declare -F _gh_with_timeout >/dev/null 2>&1; then
		_gh_with_timeout read gh issue list "${args[@]}" 2>/dev/null
		return $?
	fi
	print_error "gh_list_issues requires the shared GitHub timeout wrappers"
	return 127
}

_gh_edit_labels() {
	local action="$1" repo="$2" num="$3" labels="$4"
	local -a args=()
	local IFS=','
	for lbl in $labels; do [[ -n "$lbl" ]] && args+=("--${action}-label" "$lbl"); done
	unset IFS
	[[ ${#args[@]} -gt 0 ]] && gh issue edit "$num" --repo "$repo" "${args[@]}" 2>/dev/null || true
}

# _tier_rank: emit numeric rank for a tier label (t2111).
# Higher rank = more capable model. The ordering is the canonical one
# defined in shared-constants.sh as ISSUE_TIER_LABEL_RANK (thinking >
# standard > simple) and matches _resolve_worker_tier's max-wins pick
# in pulse-dispatch-core.sh and _first_tier_in_rank_order's reconciler
# pick in pulse-issue-reconcile.sh.
#
# A local case statement is used (rather than indexing ISSUE_TIER_LABEL_RANK)
# because (a) it's O(1) without iteration, (b) it explicitly encodes the
# numeric contract the ratchet rule relies on, and (c) the array treats
# "thinking" as index 0 which would invert the comparison semantics here.
#
# Used by the ratchet rule in _apply_tier_label_replace to preserve cascade-
# escalated tier labels that the brief file doesn't yet reflect.
#
# Arguments:
#   $1 - tier label (e.g., tier:simple, tier:standard, tier:thinking)
# Prints:
#   0/1/2 for known tiers, -1 for unknown/empty
_tier_rank() {
	case "${1:-}" in
	tier:simple) printf '0' ;;
	tier:standard) printf '1' ;;
	tier:thinking) printf '2' ;;
	*) printf -- '-1' ;;
	esac
	return 0
}

# _apply_tier_label_replace: set the tier label on an issue, replacing any
# existing tier:* labels. Avoids the collision class observed in t2012/t1997
# where multiple tier:* labels could coexist when issue-sync added a new tier
# without removing old ones (and the protected-prefix rule prevented
# _reconcile_labels from cleaning up the old one).
#
# Re-fetches current labels from gh to defend against stale upstream label
# state (race window between view and edit). Two API calls per tier change is
# acceptable; tier changes are infrequent.
#
# Ratchet rule (t2111, GH#19070): if the issue already carries a tier:* label
# of higher rank than the incoming tier, this is a cascade-escalated issue
# (escalate_issue_tier in worker-lifecycle-common.sh raised it above the
# brief's declared tier after worker failures). In that case the function
# MUST no-op — the brief is a FLOOR, the cascade is a CEILING, and the
# ceiling wins. Without this guard, scheduled enrichment reverts every
# escalation ~5 minutes after it fires, producing a tier:standard ->
# tier:thinking -> tier:standard flip-flop that wastes dispatch cycles on
# the same worker failure. See GH#19038 label event history for the
# canonical symptom.
#
# Arguments:
#   $1 - repo slug
#   $2 - issue number
#   $3 - new tier label (e.g., tier:standard)
_apply_tier_label_replace() {
	local repo="$1" num="$2" new_tier="$3" current_labels_csv="${4:-}"
	[[ -z "$repo" || -z "$num" || -z "$new_tier" ]] && return 0

	# Validate the new tier matches the expected pattern — refuse to push
	# arbitrary labels through this helper.
	if [[ ! "$new_tier" =~ ^tier:(simple|standard|thinking)$ ]]; then
		print_warning "tier replace: refusing to apply non-tier label '$new_tier' to #$num in $repo"
		return 0
	fi

	# t2165: accept pre-fetched labels CSV to avoid a redundant gh issue view.
	# Fall back to fetching when unset — preserves isolated-test behaviour.
	local existing_tiers
	if [[ -n "$current_labels_csv" ]]; then
		existing_tiers=""
		local _saved_ifs_t="$IFS"
		IFS=','
		local _lbl_t
		for _lbl_t in $current_labels_csv; do
			[[ -z "$_lbl_t" ]] && continue
			case "$_lbl_t" in
			tier:*) existing_tiers="${existing_tiers:+$existing_tiers,}$_lbl_t" ;;
			esac
		done
		IFS="$_saved_ifs_t"
	else
		existing_tiers=$(gh issue view "$num" --repo "$repo" --json labels \
			--jq '[.labels[].name | select(startswith("tier:"))] | join(",")' 2>/dev/null || echo "")
	fi

	# Ratchet rule (t2111): compute the max rank among existing tier:* labels
	# and compare against the incoming tier. If the existing max outranks the
	# incoming, this is a cascade-escalated issue — preserve it.
	local new_rank
	new_rank=$(_tier_rank "$new_tier")
	if [[ -n "$existing_tiers" ]]; then
		local _rmax=-1
		local _saved_ifs="$IFS"
		IFS=','
		local _t _r
		for _t in $existing_tiers; do
			[[ -z "$_t" ]] && continue
			_r=$(_tier_rank "$_t")
			((_r > _rmax)) && _rmax=$_r
		done
		IFS="$_saved_ifs"
		if ((_rmax > new_rank)); then
			print_info "tier replace: preserving escalated tier on #$num (existing max rank $_rmax > incoming rank $new_rank for $new_tier) — ratchet rule, see t2111"
			return 0
		fi
	fi

	# Remove any existing tier labels that don't match the new one.
	if [[ -n "$existing_tiers" ]]; then
		local -a remove_args=()
		local _saved_ifs="$IFS"
		IFS=','
		local old
		for old in $existing_tiers; do
			[[ -z "$old" ]] && continue
			[[ "$old" == "$new_tier" ]] && continue
			remove_args+=("--remove-label" "$old")
		done
		IFS="$_saved_ifs"
		if [[ ${#remove_args[@]} -gt 0 ]]; then
			gh issue edit "$num" --repo "$repo" "${remove_args[@]}" 2>/dev/null ||
				print_warning "tier replace: failed to remove stale tier label(s) from #$num in $repo"
		fi
	fi

	# Add the new tier label (idempotent — gh edit silently no-ops if present).
	gh issue edit "$num" --repo "$repo" --add-label "$new_tier" 2>/dev/null || true
	return 0
}

# _is_protected_label: returns 0 if the label must NOT be removed by enrich reconciliation.
# Protected labels are managed by other workflows (lifecycle, closure hygiene, PR labeler)
# and must not be touched by tag-derived label reconciliation.
# Arguments:
#   $1 - label name
_is_protected_label() {
	local lbl="$1"
	# Prefix-protected namespaces
	case "$lbl" in
	status:* | origin:* | tier:* | source:*) return 0 ;;
	esac
	# Exact-match protected labels
	# GH#19856: added no-auto-dispatch and no-takeover — these are coordination
	# signals set by explicit user/session action and must survive enrich.
	# t2754: added hold-for-review and needs-credentials — canonical dispatch-blockers.
	case "$lbl" in
	persistent | needs-maintainer-review | needs-maintainer-permissions | not-planned | duplicate | wontfix | \
		already-fixed | "good first issue" | "help wanted" | \
	parent-task | meta | auto-dispatch | publication:pending | no-auto-dispatch | no-takeover | \
		hold-for-review | needs-credentials | \
		consolidation-in-progress | coderabbit-nits-ok | ratchet-bump | \
		new-file-smell-ok)
		return 0
		;;
	esac
	return 1
}

# _is_tag_derived_label: returns 0 if a label is in the tag-derived domain.
# Tag-derived labels are simple words (no ':' separator). All system/workflow
# labels use ':' namespacing (status:*, origin:*, tier:*, source:*, etc.).
# This prevents reconciliation from removing manually-added or system labels
# that happen to not be in the protected prefix list.
# Arguments:
#   $1 - label name
_is_tag_derived_label() {
	local lbl="$1"
	# Labels with ':' are namespace-scoped — not tag-derived
	[[ "$lbl" == *:* ]] && return 1
	return 0
}

# _reconcile_labels: remove tag-derived labels from a GitHub issue that are no
# longer present in the desired label set. Only labels in the tag-derived domain
# (no ':' separator, not protected) are candidates for removal.
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - issue number
#   $3 - desired labels (comma-separated, already mapped via map_tags_to_labels)
_reconcile_labels() {
	local repo="$1" num="$2" desired_labels="$3" current_labels="${4:-}"
	# t2165: accept pre-fetched labels CSV to avoid a redundant gh issue view.
	# Fall back to fetching when unset — preserves isolated-test behaviour.
	if [[ -z "$current_labels" ]]; then
		current_labels=$(gh issue view "$num" --repo "$repo" --json labels \
			--jq '[.labels[].name] | join(",")' 2>/dev/null || echo "")
	fi
	[[ -z "$current_labels" ]] && return 0

	local to_remove=""
	local _saved_ifs="$IFS"
	IFS=','
	for lbl in $current_labels; do
		[[ -z "$lbl" ]] && continue
		# Skip protected labels — they are not in the tag-derived domain
		_is_protected_label "$lbl" && continue
		# Skip labels outside the tag-derived domain (namespaced labels with ':')
		_is_tag_derived_label "$lbl" || continue
		# Check if this label is in the desired set
		local found=false
		for desired in $desired_labels; do
			[[ "$lbl" == "$desired" ]] && {
				found=true
				break
			}
		done
		[[ "$found" == "false" ]] && to_remove="${to_remove:+$to_remove,}$lbl"
	done
	IFS="$_saved_ifs"

	if [[ -n "$to_remove" ]]; then
		local -a rm_args=()
		local _saved_ifs_rm="$IFS"
		IFS=','
		for _lbl in $to_remove; do [[ -n "$_lbl" ]] && rm_args+=("--remove-label" "$_lbl"); done
		IFS="$_saved_ifs_rm"
		if [[ ${#rm_args[@]} -gt 0 ]]; then
			gh issue edit "$num" --repo "$repo" "${rm_args[@]}" 2>/dev/null ||
				print_warning "label reconcile: failed to remove stale labels ($to_remove) from #$num in $repo"
		fi
	fi
	return 0
}

gh_create_label() {
	local repo="$1" name="$2" color="$3" desc="$4"
	gh label create "$name" --repo "$repo" --color "$color" --description "$desc" --force 2>/dev/null || true
}

gh_find_issue_by_title() {
	local repo="$1" prefix="$2" state="${3:-all}" limit="${4:-500}"
	gh issue list --repo "$repo" --state "$state" --limit "$limit" \
		--json number,title --jq "[.[] | select(.title | startswith(\"${prefix}\"))][0].number // empty" 2>/dev/null || echo ""
}

_gh_find_merged_pr_evidence() {
	local repo="$1" task_id="$2"
	local results="" pr_info=""

	if ! results=$(gh pr list --repo "$repo" --state merged --search "$task_id in:title" \
		--limit 1 --json number,url 2>/dev/null); then
		return 2
	fi
	if ! pr_info=$(printf '%s' "$results" | jq -er '
		if type != "array" then error("expected PR array")
		elif length == 0 then ""
		else .[0]
			| select((.number | type) == "number" and (.url | type) == "string" and (.url | length) > 0)
			| "\(.number)|\(.url)"
		end' 2>/dev/null); then
		return 2
	fi
	[[ -n "$pr_info" ]] || return 1
	printf '%s\n' "$pr_info"
	return 0
}

gh_find_merged_pr() {
	local repo="$1" task_id="$2" pr_info=""
	if pr_info=$(_gh_find_merged_pr_evidence "$repo" "$task_id"); then
		printf '%s\n' "$pr_info"
	fi
	return 0
}

ensure_labels_exist() {
	local labels="$1" repo="$2"
	[[ -z "$labels" || -z "$repo" ]] && return 0

	# Source label-sync-helper for semantic tag colors (color_for_tag function).
	# Falls back to EDEDED if the helper is not available.
	local _label_helper="${SCRIPT_DIR}/label-sync-helper.sh"
	if [[ -f "$_label_helper" ]] && ! declare -F color_for_tag >/dev/null 2>&1; then
		# shellcheck source=label-sync-helper.sh
		source "$_label_helper" 2>/dev/null || true
	fi

	local _saved_ifs="$IFS"
	IFS=','
	for lbl in $labels; do
		if [[ -n "$lbl" ]]; then
			local _color="EDEDED"
			if declare -F color_for_tag >/dev/null 2>&1; then
				_color=$(color_for_tag "$lbl")
			fi
			gh_create_label "$repo" "$lbl" "$_color" "Auto-created from TODO.md tag"
		fi
	done
	IFS="$_saved_ifs"
}

# t2040: _mark_issue_done delegates to set_issue_status which performs the
# add+remove atomically in a single `gh issue edit` call. The previous
# implementation used a non-atomic two-call sequence (add then remove) that
# created a transient window where the issue carried both `status:in-review`
# and `status:done`. The reconciler's label-invariant pass would see two
# status labels and could pick the wrong survivor, potentially losing `done`.
# Precedence (ISSUE_STATUS_LABEL_PRECEDENCE) now treats `done` as terminal,
# but the correct fix is to close the window entirely.
#
# set_issue_status handles every core status:* label in ISSUE_STATUS_LABELS
# (available/queued/claimed/in-progress/in-review/done/blocked) atomically.
# The only extra label to clear is `status:verify-failed` which is an
# out-of-band exception label not managed by set_issue_status — passed
# through via its trailing passthrough flags.
_mark_issue_done() {
	local repo="$1" num="$2"
	set_issue_status "$num" "$repo" "done" \
		--remove-label "status:verify-failed" 2>/dev/null || true
}
