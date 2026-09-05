#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Interactive Session Commands -- claim, lockdown, unlock, release, status, write-stamp
# =============================================================================
# Core subcommand implementations for interactive issue ownership.
# Extracted from interactive-session-helper.sh (GH#21320).
#
# Usage: source "${SCRIPT_DIR}/interactive-session-helper-commands.sh"
#
# Dependencies:
#   - shared-constants.sh (set_issue_status, gh_issue_comment)
#   - interactive-session-helper-stamp.sh (_isc_write_stamp, _isc_delete_stamp, _isc_post_claim_comment)
#   - Logging/utility functions from orchestrator (_isc_info, _isc_warn, _isc_err,
#     _isc_gh_reachable, _isc_current_user, _isc_can_manage_issue_state,
#     _isc_read_claim_metadata, _isc_has_label, _isc_carve_out_required,
#     _isc_cmd_help)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ISC_COMMANDS_LIB_LOADED:-}" ]] && return 0
_ISC_COMMANDS_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_isc_resolve_manageable_user() {
	local action="$1"
	local issue="$2"
	local slug="$3"
	local offline_warning="$4"
	local offline_detail="${5:-}"
	local external_detail="${6:-}"

	if ! _isc_gh_reachable; then
		_isc_warn "$offline_warning"
		[[ -n "$offline_detail" ]] && _isc_warn "$offline_detail"
		return 1
	fi

	local user
	user=$(_isc_current_user)
	if [[ -z "$user" ]]; then
		_isc_warn "could not resolve gh user login — skipping $action on #$issue"
		return 1
	fi

	if ! _isc_can_manage_issue_state "$slug" "$user"; then
		_isc_warn "$action: #$issue in $slug skipped — @${user} is not a maintainer-equivalent collaborator"
		[[ -n "$external_detail" ]] && _isc_warn "$external_detail"
		return 1
	fi

	printf '%s' "$user"
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: claim
# -----------------------------------------------------------------------------
# GH#27871: terminal issues skip before claim idempotency, which can refresh a
# stamp. Lookup failures return 1 and preserve the existing fail-open contract.
_isc_claim_closed_issue_guard() {
	local issue="$1"
	local slug="$2"
	_isc_issue_is_closed "$issue" "$slug" || return 1
	_isc_info "claim: #$issue is closed — skipping interactive claim lifecycle"
	return 0
}

# Apply status:in-review, self-assign, and write a stamp in repos where the
# authenticated account has maintainer-equivalent issue-management access.
#
# SCOPE: blocks pulse DISPATCH only. Does NOT block enrich, completion-sweep,
# or other non-dispatch pulse operations that modify issue state. For full
# insulation from all pulse paths, use `lockdown` instead. (GH#19861)
#
# Arguments:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   [--worktree PATH] = optional worktree path to record in the stamp
#   [--implementing] = opt in to claim an `auto-dispatch`-tagged issue
#                      that the caller intends to implement themselves.
#                      Without this flag, the helper refuses to claim
#                      auto-dispatch issues so the pulse can dispatch a
#                      worker (see auto-dispatch carve-out below).
#   [--defer-comment] = defer the audit comment until a worktree refresh
#                       supplies the linked path.
#
# Auto-dispatch carve-out (GH#20946):
#   Calling claim on an `auto-dispatch`-tagged issue WITHOUT `--implementing`
#   is a no-op — it warns and exits 0. Three creation-time entry points already
#   skip self-assign on auto-dispatch (t2218, t2132, t2157/t2406); this probe
#   extends the same invariant to the manual `claim` subcommand. Without the
#   probe, claim would create the (origin:interactive + assignee + status:in-review)
#   combination that `_has_active_claim` in dispatch-dedup-helper.sh treats as an
#   active claim, permanently blocking pulse dispatch (t1996/GH#18352).
#
#   `parent-task` issues are exempt from the probe — they're decomposition
#   trackers the maintainer needs to own, and `parent-task` already blocks
#   dispatch via `PARENT_TASK_BLOCKED` upstream of the auto-dispatch path.
#
#   Use `--implementing` when the AGENTS.md "Implementing a #auto-dispatch
#   task interactively" mandate applies — i.e. when the agent legitimately
#   intends to take the issue itself instead of letting a worker pick it up.
#
# Behaviour:
#   - Offline gh: warn-and-continue (exit 0). A collision with a pulse worker
#     is harmless — the interactive work naturally becomes its own issue/PR.
#   - Idempotent: a re-call by the sole current assignee refreshes the stamp
#     without a redundant GitHub edit.
#   - Ownership failures fail closed: unavailable metadata, a foreign live
#     interactive owner, or an unverifiable takeover never writes a stamp.
#
# Exit: 0 on a verified claim/idempotent skip, 1 on ownership conflict or
# unverifiable metadata/transition, 2 on invalid arguments.
_isc_existing_stamp_worktree() {
	local issue="$1"
	local slug="$2"
	local stamp_file=""
	stamp_file=$(_isc_stamp_path "$issue" "$slug")
	[[ -f "$stamp_file" ]] || return 0
	jq -r '.worktree_path // empty' "$stamp_file" 2>/dev/null || true
	return 0
}

_isc_refresh_existing_claim() {
	local issue="$1"
	local slug="$2"
	local worktree_path="$3"
	local user="$4"
	local defer_comment="$5"
	local existing_worktree_path=""
	existing_worktree_path=$(_isc_existing_stamp_worktree "$issue" "$slug")
	local refreshed_worktree_path="$worktree_path"
	[[ -n "$refreshed_worktree_path" ]] || refreshed_worktree_path="$existing_worktree_path"
	_isc_write_stamp "$issue" "$slug" "$refreshed_worktree_path" "$user"
	if [[ "$defer_comment" -eq 0 && -n "$worktree_path" && -z "$existing_worktree_path" ]]; then
		_isc_post_claim_comment "$issue" "$slug" "$user" "$worktree_path"
	fi
	return 0
}

_isc_claim_ownership_class() {
	local metadata="$1"
	local user="$2"
	local now_epoch=""
	now_epoch=$(date +%s)
	printf '%s' "$metadata" | jq -r --arg user "$user" --argjson now "$now_epoch" '
		(.state // "" | ascii_downcase) as $state |
		([.labels[]?.name] | index("status:in-review") != null) as $in_review |
		[.assignees[]?.login] as $assignees |
		[.comments[]?
			| select((.body // "") | contains("Interactive session claimed by @"))
			| select((.author.login // "") as $author
				| ($assignees | index($author)) != null
				and ((.body // "") | contains("Interactive session claimed by @\($author)")))
			| select((.createdAt // "" | fromdateiso8601?) as $created
				| $created != null and ($now - $created) >= 0 and ($now - $created) < 7200)
		] | sort_by(.createdAt) | reverse | first as $live_claim |
		if $state != "open" then "invalid-state"
		elif ($in_review | not) then "unclaimed"
		elif ($assignees | length) == 1 and $assignees[0] == $user then "own"
		elif $live_claim != null then "foreign-interactive:" + $live_claim.author.login
		else "foreign-worker" end
	' 2>/dev/null
	return $?
}

_isc_verified_caller_owns_claim() {
	local issue="$1"
	local slug="$2"
	local user="$3"
	local metadata=""
	metadata=$(_isc_read_claim_metadata "$issue" "$slug") || return 1
	printf '%s' "$metadata" | jq -e --arg user "$user" '
		(.state | ascii_downcase) == "open" and
		([.labels[]?.name] | index("status:in-review") != null) and
		([.assignees[]?.login] == [$user])
	' >/dev/null 2>&1
	return $?
}

_isc_apply_new_claim() {
	local issue="$1"
	local slug="$2"
	local worktree_path="$3"
	local user="$4"
	local defer_comment="$5"
	shift 5
	local -a transition_args=(--add-assignee "$user" "$@")
	if ! set_issue_status "$issue" "$slug" "in-review" "${transition_args[@]}" >/dev/null 2>&1; then
		_isc_err "claim: ownership transition failed on #$issue; no stamp written"
		return 1
	fi
	if ! _isc_verified_caller_owns_claim "$issue" "$slug" "$user"; then
		_isc_err "claim: ownership transition on #$issue could not be verified; no stamp written"
		return 1
	fi
	_isc_info "claim: #$issue in $slug → status:in-review + sole assignee $user"
	_isc_write_stamp "$issue" "$slug" "$worktree_path" "$user"
	if [[ "$defer_comment" -eq 0 || -n "$worktree_path" ]]; then
		_isc_post_claim_comment "$issue" "$slug" "$user" "$worktree_path"
	fi
	return 0
}

_isc_take_over_worker_claim() {
	local issue="$1"
	local slug="$2"
	local worktree_path="$3"
	local user="$4"
	local defer_comment="$5"
	local assignees_csv="$6"
	local -a remove_args=()
	local -a assignees=()
	local saved_ifs="${IFS:-}"
	IFS=',' read -ra assignees <<<"$assignees_csv"
	IFS="$saved_ifs"
	local assignee=""
	for assignee in "${assignees[@]}"; do
		[[ -n "$assignee" && "$assignee" != "$user" ]] && remove_args+=(--remove-assignee "$assignee")
	done
	_isc_apply_new_claim "$issue" "$slug" "$worktree_path" "$user" "$defer_comment" "${remove_args[@]}"
	return $?
}

_isc_handle_existing_claim_ownership() {
	local issue="$1"
	local slug="$2"
	local worktree_path="$3"
	local user="$4"
	local defer_comment="$5"
	local implementing="$6"
	local claim_metadata="$7"
	local ownership_class=""
	if ! ownership_class=$(_isc_claim_ownership_class "$claim_metadata" "$user"); then
		_isc_err "claim: ownership metadata invalid for #$issue; no stamp written"
		return 1
	fi
	case "$ownership_class" in
	own)
		_isc_info "claim: #$issue already belongs to $user — refreshing stamp"
		_isc_refresh_existing_claim "$issue" "$slug" "$worktree_path" "$user" "$defer_comment"
		return 0
		;;
	foreign-interactive:*)
		_isc_err "claim: #$issue has a live interactive owner @${ownership_class#*:}; refusing takeover"
		return 1
		;;
	foreign-worker)
		if [[ "$implementing" -eq 0 ]]; then
			_isc_err "claim: #$issue is assigned to another principal; re-run with --implementing for an explicit worker takeover"
			return 1
		fi
		local foreign_assignees=""
		foreign_assignees=$(printf '%s' "$claim_metadata" | jq -r \
			'[.assignees[]?.login] | join(",")' 2>/dev/null) || return 1
		_isc_info "claim: #$issue has foreign worker ownership (${foreign_assignees:-unassigned}) — performing verified interactive takeover"
		_isc_take_over_worker_claim "$issue" "$slug" "$worktree_path" "$user" "$defer_comment" "$foreign_assignees"
		return $?
		;;
	unclaimed)
		return 3
		;;
	*)
		_isc_err "claim: unrecognized ownership state for #$issue; no stamp written"
		return 1
		;;
	esac
}

_isc_cmd_claim() {
	local issue="" slug="" worktree_path="" implementing=0 defer_comment=0

	# Parse positional + flags
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--worktree)
			worktree_path="${2:-}"
			shift 2
			;;
		--worktree=*)
			worktree_path="${arg#--worktree=}"
			shift
			;;
		--implementing)
			implementing=1
			shift
			;;
		--defer-comment)
			defer_comment=1
			shift
			;;
		-h | --help)
			_isc_cmd_help
			return 0
			;;
		*)
			if [[ -z "$issue" ]]; then
				issue="$arg"
			elif [[ -z "$slug" ]]; then
				slug="$arg"
			else
				_isc_warn "unexpected argument: $arg (ignored)"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$issue" || -z "$slug" ]]; then
		_isc_err "claim: <issue> and <slug> are required"
		_isc_err "usage: interactive-session-helper.sh claim <issue> <slug> [--worktree PATH] [--implementing] [--defer-comment]"
		return 2
	fi

	if [[ ! "$issue" =~ ^[0-9]+$ ]]; then
		_isc_err "claim: <issue> must be numeric (got: $issue)"
		return 2
	fi

	if [[ "${AIDEVOPS_INTERACTIVE_ISSUE_IMPLEMENTATION:-0}" == "1" && $implementing -eq 0 ]]; then
		_isc_err "claim: interactive issue implementation requires --implementing; refusing worker-claim routing"
		return 2
	fi

	local user
	if ! user=$(_isc_resolve_manageable_user "claim" "$issue" "$slug" \
		"gh offline or not authenticated — skipping claim on #$issue ($slug)" \
		"a collision with a worker is harmless; the interactive work will become its own issue/PR" \
		"external repos should receive a PR when possible plus at most one concise explanatory issue comment, not aidevops dispatch claims"); then
		return 0
	fi

	_isc_claim_closed_issue_guard "$issue" "$slug" && return 0

	local claim_metadata=""
	if ! claim_metadata=$(_isc_read_claim_metadata "$issue" "$slug"); then
		_isc_err "claim: ownership metadata unavailable for #$issue; no stamp written"
		return 1
	fi
	local ownership_rc=0
	_isc_handle_existing_claim_ownership "$issue" "$slug" "$worktree_path" "$user" \
		"$defer_comment" "$implementing" "$claim_metadata" || ownership_rc=$?
	case "$ownership_rc" in
	0) return 0 ;;
	3) ;;
	*) return "$ownership_rc" ;;
	esac

	# Auto-dispatch carve-out (GH#20946): refuse to claim auto-dispatch issues
	# unless --implementing was passed or the issue is also a parent-task.
	# `_isc_carve_out_required` does both label checks in one gh round-trip and
	# fails OPEN on rc=2 (lookup failed) — the `&&` short-circuit only enters
	# the skip branch on rc=0, so rc=1 (no carve-out) and rc=2 (lookup failed)
	# both fall through to the normal claim path. See PR #20977 review thread
	# (augmentcode rc=2 + gemini consolidation findings) for context.
	if [[ $implementing -eq 0 ]] && _isc_carve_out_required "$issue" "$slug"; then
		_isc_warn "claim: #$issue carries 'auto-dispatch' without 'parent-task' — skipping to avoid permanent dispatch block (t2218 invariant; GH#20946)"
		_isc_warn "if you intend to implement #$issue yourself instead of letting a worker pick it up, re-run with: claim $issue $slug --implementing"
		return 0
	fi

	# Transition to in-review with atomic self-assign. The helper preserves the
	# deferred-comment contract for canonical-rooted issue starts.
	_isc_apply_new_claim "$issue" "$slug" "$worktree_path" "$user" "$defer_comment"
	return $?
}

# -----------------------------------------------------------------------------
# Subcommand: lockdown (GH#19861)
# -----------------------------------------------------------------------------
# Stricter protection than `claim`. Applies ALL of:
#   1. `no-auto-dispatch` label — blocks the pulse enrich path from modifying
#      issue state and prevents any auto-dispatch.
#   2. `status:in-review` + self-assignment — blocks pulse dispatch (same as claim).
#   3. GitHub conversation lock — prevents non-collaborator edits.
#   4. Audit-trail comment — visible marker explaining the lockdown.
#   5. Crash-recovery stamp — same as claim.
#
# Use this when investigating a pulse bug or when you need maximum insulation
# from ALL pulse operations, not just dispatch.
#
# Arguments:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   [--worktree PATH] = optional worktree path to record in the stamp
#
# Exit: 0 always (warn-and-continue contract).
_isc_cmd_lockdown() {
	local issue="" slug="" worktree_path=""

	# Parse positional + flags
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--worktree)
			worktree_path="${2:-}"
			shift 2
			;;
		--worktree=*)
			worktree_path="${arg#--worktree=}"
			shift
			;;
		-h | --help)
			_isc_cmd_help
			return 0
			;;
		*)
			if [[ -z "$issue" ]]; then
				issue="$arg"
			elif [[ -z "$slug" ]]; then
				slug="$arg"
			else
				_isc_warn "unexpected argument: $arg (ignored)"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$issue" || -z "$slug" ]]; then
		_isc_err "lockdown: <issue> and <slug> are required"
		_isc_err "usage: interactive-session-helper.sh lockdown <issue> <slug> [--worktree PATH]"
		return 2
	fi

	if [[ ! "$issue" =~ ^[0-9]+$ ]]; then
		_isc_err "lockdown: <issue> must be numeric (got: $issue)"
		return 2
	fi

	# Offline gate
	if ! _isc_gh_reachable; then
		_isc_warn "gh offline or not authenticated — skipping lockdown on #$issue ($slug)"
		return 0
	fi

	local user
	user=$(_isc_current_user)
	if [[ -z "$user" ]]; then
		_isc_warn "could not resolve gh user login — skipping lockdown on #$issue"
		return 0
	fi

	if ! _isc_can_manage_issue_state "$slug" "$user"; then
		_isc_warn "lockdown: #$issue in $slug skipped — @${user} is not a maintainer-equivalent collaborator"
		_isc_warn "external repos must not receive aidevops lockdown labels, locks, or audit comments"
		return 0
	fi

	# Step 1: Apply status:in-review + self-assign (same as claim)
	if set_issue_status "$issue" "$slug" "in-review" --add-assignee "$user" >/dev/null 2>&1; then
		_isc_info "lockdown: #$issue → status:in-review + assigned $user"
	else
		_isc_warn "lockdown: status transition failed on #$issue — continuing"
	fi

	# Step 2: Apply no-auto-dispatch label (blocks enrich + dispatch paths)
	if gh issue edit "$issue" --repo "$slug" --add-label "no-auto-dispatch" >/dev/null 2>&1; then
		_isc_info "lockdown: #$issue → no-auto-dispatch label applied"
	else
		_isc_warn "lockdown: could not apply no-auto-dispatch label on #$issue"
	fi

	# Step 3: Lock the conversation
	if gh issue lock "$issue" --repo "$slug" --reason "resolved" >/dev/null 2>&1; then
		_isc_info "lockdown: #$issue → conversation locked"
	else
		_isc_warn "lockdown: could not lock conversation on #$issue — continuing"
	fi

	# Step 4: Write crash-recovery stamp
	_isc_write_stamp "$issue" "$slug" "$worktree_path" "$user"

	# Step 5: Post audit-trail comment
	local body
	# shellcheck disable=SC2016 # backticks are intentional markdown formatting
	body="$(printf '<!-- lockdown-marker -->\n**Lockdown applied** by `%s` (interactive session).\n\nThis issue is under active human investigation. All pulse operations (dispatch, enrich, completion-sweep) are blocked via `no-auto-dispatch` + `status:in-review` + conversation lock.\n\nTo release: `interactive-session-helper.sh unlock %s %s`' "$user" "$issue" "$slug")"
	gh_issue_comment "$issue" --repo "$slug" --body "$body" >/dev/null 2>&1 || {
		_isc_warn "lockdown: audit comment failed on #$issue — continuing"
	}

	_isc_info "lockdown: #$issue in $slug fully locked down"
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: unlock (GH#19861)
# -----------------------------------------------------------------------------
# Reverse a lockdown: remove no-auto-dispatch, transition to available,
# unlock conversation, delete stamp.
#
# Arguments:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   [--unassign] = also remove self from assignees
#
# Exit: 0 always.
_isc_cmd_unlock() {
	local issue="" slug="" unassign=0

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--unassign)
			unassign=1
			shift
			;;
		-h | --help)
			_isc_cmd_help
			return 0
			;;
		*)
			if [[ -z "$issue" ]]; then
				issue="$arg"
			elif [[ -z "$slug" ]]; then
				slug="$arg"
			else
				_isc_warn "unexpected argument: $arg (ignored)"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$issue" || -z "$slug" ]]; then
		_isc_err "unlock: <issue> and <slug> are required"
		return 2
	fi

	if [[ ! "$issue" =~ ^[0-9]+$ ]]; then
		_isc_err "unlock: <issue> must be numeric (got: $issue)"
		return 2
	fi

	# Delete local stamp regardless of gh state
	_isc_delete_stamp "$issue" "$slug"

	if ! _isc_gh_reachable; then
		_isc_warn "gh offline — stamp deleted locally, lockdown unchanged on #$issue"
		return 0
	fi

	local user
	user=$(_isc_current_user)
	if [[ -z "$user" ]]; then
		_isc_warn "could not resolve gh user login — stamp deleted locally, skipping unlock on #$issue"
		return 0
	fi

	if ! _isc_can_manage_issue_state "$slug" "$user"; then
		_isc_warn "unlock: #$issue in $slug skipped — @${user} is not a maintainer-equivalent collaborator"
		return 0
	fi

	# Step 1: Unlock conversation
	if gh issue unlock "$issue" --repo "$slug" >/dev/null 2>&1; then
		_isc_info "unlock: #$issue → conversation unlocked"
	else
		_isc_warn "unlock: could not unlock conversation on #$issue — continuing"
	fi

	# Step 2: Remove no-auto-dispatch label
	if gh issue edit "$issue" --repo "$slug" --remove-label "no-auto-dispatch" >/dev/null 2>&1; then
		_isc_info "unlock: #$issue → no-auto-dispatch label removed"
	else
		_isc_warn "unlock: could not remove no-auto-dispatch label on #$issue"
	fi

	# Step 3: Transition status:in-review -> status:available
	local -a extra_flags=()
	if [[ $unassign -eq 1 ]]; then
		if [[ -n "$user" ]]; then
			extra_flags+=(--remove-assignee "$user")
		fi
	fi

	if set_issue_status "$issue" "$slug" "available" ${extra_flags[@]+"${extra_flags[@]}"} >/dev/null 2>&1; then
		_isc_info "unlock: #$issue → status:available"
	else
		_isc_warn "unlock: status transition failed on #$issue"
	fi

	# Step 4: Post audit comment
	local body
	# shellcheck disable=SC2016 # backticks are intentional markdown formatting
	body="$(printf '<!-- unlock-marker -->\n**Lockdown released** by `%s`. Issue returned to normal pulse operation.' "${user:-unknown}")"
	gh_issue_comment "$issue" --repo "$slug" --body "$body" >/dev/null 2>&1 || {
		_isc_warn "unlock: audit comment failed on #$issue — continuing"
	}

	_isc_info "unlock: #$issue in $slug fully unlocked"
	return 0
}

_isc_unassign_released_issue() {
	local issue="$1"
	local slug="$2"
	local user="$3"
	local unassign_err=""
	local unassign_rc=0

	unassign_err=$(gh issue edit "$issue" --repo "$slug" \
		--remove-assignee "$user" 2>&1 >/dev/null) || unassign_rc=$?
	if [[ $unassign_rc -eq 0 ]]; then
		_isc_info "release: #$issue already outside status:in-review — unassigned $user"
		return 0
	fi
	_isc_warn "release: gh failed to unassign $user from #$issue (rc=$unassign_rc): $unassign_err"
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: release
# -----------------------------------------------------------------------------
# Transition status:in-review -> status:available and delete the stamp.
#
# Arguments:
#   $1 = issue number
#   $2 = repo slug (owner/repo)
#   [--unassign] = also remove self from assignees
#
# Behaviour:
#   - Idempotent: when the label is not set, only a requested unassignment runs.
#   - Offline gh: warn and exit 0. The stamp is still deleted so local state
#     matches the caller's intent.
#
# Exit: 0 always.
_isc_cmd_release() {
	local issue="" slug="" unassign=0

	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--unassign)
			unassign=1
			shift
			;;
		-h | --help)
			_isc_cmd_help
			return 0
			;;
		*)
			if [[ -z "$issue" ]]; then
				issue="$arg"
			elif [[ -z "$slug" ]]; then
				slug="$arg"
			else
				_isc_warn "unexpected argument: $arg (ignored)"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$issue" || -z "$slug" ]]; then
		_isc_err "release: <issue> and <slug> are required"
		return 2
	fi

	if [[ ! "$issue" =~ ^[0-9]+$ ]]; then
		_isc_err "release: <issue> must be numeric (got: $issue)"
		return 2
	fi

	# Always delete the stamp so local state reflects caller intent
	_isc_delete_stamp "$issue" "$slug"

	local user
	if ! user=$(_isc_resolve_manageable_user "release" "$issue" "$slug" \
		"gh offline — stamp deleted locally, label unchanged on #$issue"); then
		return 0
	fi

	# Idempotency: skip only label work if not in-review. `_isc_has_in_review`
	# has three return states (0 = present, 1 = absent, 2 = lookup failed),
	# so we need the actual rc — but a bare call under `set -e` propagates
	# non-zero returns before `rc=$?` can capture them. Use `|| rc=$?` which
	# is a tested condition that `set -e` does not propagate. Default to 0
	# so the "present" branch (rc=0) falls through to the transition below.
	local has_rc=0
	_isc_has_in_review "$issue" "$slug" || has_rc=$?
	if [[ $has_rc -eq 1 ]]; then
		if [[ $unassign -eq 0 ]]; then
			_isc_info "release: #$issue not in status:in-review — no-op"
			return 0
		fi
		_isc_unassign_released_issue "$issue" "$slug" "$user"
		return 0
	fi
	if [[ $has_rc -eq 2 ]]; then
		_isc_warn "release: could not read labels for #$issue — skipping label transition"
		return 0
	fi

	# Bash 3.2 empty-array guard — see reference/bash-compat.md.
	local -a extra_flags=()
	if [[ $unassign -eq 1 && -n "$user" ]]; then
		extra_flags+=(--remove-assignee "$user")
	fi

	# GH#21805: apply status:done for closed issues instead of
	# status:available (meaningless on closed issues). Fail-open on errors.
	local _target_status="available"
	if _isc_issue_is_closed "$issue" "$slug"; then
		_target_status="done"
	fi

	# Capture stderr so failures surface with the actual gh error message
	# rather than being silently swallowed. Previously >/dev/null 2>&1 hid
	# the root cause of stuck-claim incidents (GH#21057).
	local _set_status_err
	_set_status_err=$(set_issue_status "$issue" "$slug" "$_target_status" \
		${extra_flags[@]+"${extra_flags[@]}"} 2>&1 >/dev/null)
	local _set_status_rc=$?
	if [[ $_set_status_rc -eq 0 ]]; then
		_isc_info "release: #$issue → status:$_target_status"
		return 0
	fi
	_isc_warn "release: gh failed on #$issue (rc=$_set_status_rc): $_set_status_err"
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: status
# -----------------------------------------------------------------------------
# Print active claims from the stamp directory. With <issue>: exit 0 if this
# user holds a claim on that issue, 1 otherwise.
#
# Output is human-readable on stdout so the agent can parse it.
_isc_cmd_status() {
	local target_issue="${1:-}"

	if [[ ! -d "$CLAIM_STAMP_DIR" ]]; then
		if [[ -n "$target_issue" ]]; then
			return 1
		fi
		printf 'No active interactive claims.\n'
		return 0
	fi

	local found=0
	local stamp
	for stamp in "$CLAIM_STAMP_DIR"/*.json; do
		[[ -f "$stamp" ]] || continue
		local issue slug worktree claimed pid hostname user
		issue=$(jq -r '.issue // empty' "$stamp" 2>/dev/null || echo "")
		slug=$(jq -r '.slug // empty' "$stamp" 2>/dev/null || echo "")
		worktree=$(jq -r '.worktree_path // empty' "$stamp" 2>/dev/null || echo "")
		claimed=$(jq -r '.claimed_at // empty' "$stamp" 2>/dev/null || echo "")
		pid=$(jq -r '.pid // empty' "$stamp" 2>/dev/null || echo "")
		hostname=$(jq -r '.hostname // empty' "$stamp" 2>/dev/null || echo "")
		user=$(jq -r '.user // empty' "$stamp" 2>/dev/null || echo "")

		if [[ -z "$issue" || -z "$slug" ]]; then
			continue
		fi

		if [[ -n "$target_issue" && "$issue" != "$target_issue" ]]; then
			continue
		fi

		found=1
		printf '#%s in %s\n' "$issue" "$slug"
		printf '  user:     %s\n' "${user:-unknown}"
		printf '  worktree: %s\n' "${worktree:-unknown}"
		printf '  claimed:  %s\n' "${claimed:-unknown}"
		printf '  pid:      %s on %s\n' "${pid:-unknown}" "${hostname:-unknown}"
	done

	if [[ $found -eq 0 ]]; then
		if [[ -n "$target_issue" ]]; then
			return 1
		fi
		printf 'No active interactive claims.\n'
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: write-stamp (t2943)
# -----------------------------------------------------------------------------
# Write a crash-recovery stamp WITHOUT performing any GitHub status transitions.
#
# Used by `_auto_assign_issue` in claim-task-id-issue.sh to atomically record
# a stamp at the moment of self-assign, closing the gap where `_auto_assign_issue`
# self-assigned but the subsequent `_interactive_session_auto_claim_new_task`
# call failed before writing the stamp (API error, carve-out mismatch, etc.).
#
# The full `claim` subcommand still runs afterwards and overwrites the stamp
# with the status:in-review transition, worktree path, etc. — this is the
# safety-net write that ensures no stampless claim exists if `claim` fails.
#
# Arguments:
#   <issue> — GitHub issue number (numeric)
#   <slug>  — owner/repo slug
#
# worktree_path is left empty; the subsequent `claim` call overwrites the stamp
# with full lifecycle info (status:in-review, worktree, etc.).
#
# Returns 0 always (best-effort, non-blocking).
_isc_cmd_write_stamp() {
	# Require exactly <issue> and <slug>. Check arg count before using $1/$2
	# so set -u does not trigger on positional params when called with no args.
	if [[ $# -lt 2 ]]; then
		_isc_err "write-stamp: <issue> and <slug> are required"
		return 2
	fi
	local issue="$1"
	local slug="$2"

	if [[ ! "$issue" =~ ^[0-9]+$ ]]; then
		_isc_err "write-stamp: <issue> must be numeric (got: $issue)"
		return 2
	fi

	# Resolve the current user — best-effort; stamp is still useful without it.
	local user
	user=$(_isc_current_user 2>/dev/null || echo "")

	# worktree_path is always empty for the primary write-stamp caller
	# (_auto_assign_issue) — the full `claim` that follows records the path.
	_isc_write_stamp "$issue" "$slug" "" "$user"
	return 0
}

# -----------------------------------------------------------------------------
# Subcommand: branch-has-active-claim (t2916/GH#21074)
# -----------------------------------------------------------------------------
# Thin CLI wrapper around the sourceable `_isc_branch_has_active_claim` helper
# in interactive-session-helper-stamp.sh. Lets shell consumers (worktree
# cleanup paths, pulse-cleanup) check claim state via subprocess invocation
# without sourcing the entire orchestrator graph.
#
# Stdout: silent (exit code carries the answer).
# Stderr: silent on success; one warn line on parse failure.
# Exit:
#   0 — branch's issue has an active claim (stamp present, PID alive)
#   1 — no active claim (no stamp, no parseable issue, or stamp is stale)
#   2 — usage error (no branch supplied)
_isc_cmd_branch_has_active_claim() {
	if [[ $# -lt 1 ]]; then
		_isc_err "branch-has-active-claim: <branch> is required"
		return 2
	fi
	# Delegate to the sourceable helper. It does its own arg parsing
	# (--worktree PATH, --worktree=PATH) and exit-code contract, so we
	# pass through verbatim.
	if _isc_branch_has_active_claim "$@"; then
		return 0
	fi
	return 1
}
