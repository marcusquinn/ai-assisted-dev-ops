#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Intentionally using /bin/bash (not /usr/bin/env bash) for headless compatibility.
# Some MCP/headless runners provide a stripped PATH where env cannot resolve bash.
# Keep this exception aligned with issue #2610 and t135.14 standardization context.
# shellcheck disable=SC2155
# =============================================================================
# aidevops Issue Sync Helper — Orchestrator
# =============================================================================
# Stateless bi-directional sync between TODO.md and GitHub Issues via gh CLI.
#
# This file is the thin orchestrator. Function groups live in sub-libraries:
#   - issue-sync-helper-labels.sh   (label management, GitHub API wrappers)
#   - issue-sync-helper-push.sh     (push command and helpers)
#   - issue-sync-helper-enrich.sh   (enrich command and helpers)
#   - issue-sync-helper-close.sh    (close/reopen commands and helpers)
#   - issue-sync-helper-commands.sh (pull, status, reconcile, help)
#   - issue-sync-relationships.sh   (blocked-by, sub-issues — GH#19502)
#
# Relationship sync (blocked-by, sub-issues) extracted to
# issue-sync-relationships.sh (GH#19502).
#
# All parsing, composing, and ref-management lives in issue-sync-lib.sh.
#
# _push_process_task and _enrich_process_task are kept here to preserve their
# (file, fname) identity keys for the function-complexity scanner.
#
# Usage: issue-sync-helper.sh [command] [options]
# Part of aidevops framework: https://aidevops.sh

set -euo pipefail

# Use helper-private names so sourced modules cannot clobber directory resolution.
# Pure-bash parameter expansion avoids dirname in restricted headless PATHs.
_issue_sync_script_path="${BASH_SOURCE[0]%/*}"
[[ "$_issue_sync_script_path" == "${BASH_SOURCE[0]}" ]] && _issue_sync_script_path="."
_issue_sync_script_dir="$(cd "$_issue_sync_script_path" && pwd)" || exit
[[ -n "$_issue_sync_script_dir" ]] || exit 1
unset _issue_sync_script_path

# Preserve caller-provided shims before fallback system tool locations, while
# removing empty and stale framework entries. This keeps the framework gh shim
# exactly first and makes repeated sourcing idempotent on Bash 3.2 and newer.
_issue_sync_path_input="${PATH:+${PATH}:}/usr/local/bin:/usr/bin:/bin"
_issue_sync_path_tail=""
while [[ -n "$_issue_sync_path_input" ]]; do
	_issue_sync_path_component="${_issue_sync_path_input%%:*}"
	if [[ "$_issue_sync_path_input" == *:* ]]; then
		_issue_sync_path_input="${_issue_sync_path_input#*:}"
	else
		_issue_sync_path_input=""
	fi
	if [[ -n "$_issue_sync_path_component" && "$_issue_sync_path_component" != "$_issue_sync_script_dir" ]]; then
		_issue_sync_path_tail="${_issue_sync_path_tail:+${_issue_sync_path_tail}:}${_issue_sync_path_component}"
	fi
done
export PATH="${_issue_sync_script_dir}${_issue_sync_path_tail:+:${_issue_sync_path_tail}}"
unset _issue_sync_path_input _issue_sync_path_tail _issue_sync_path_component

# Keep SCRIPT_DIR for the public source contract, but use the private directory
# for sibling loading so later modules cannot affect this helper's source chain.
SCRIPT_DIR="$_issue_sync_script_dir"
# Hosted runners do not have the user's repos.json. Establish a narrowly
# scoped current-repository inventory before shared-constants loads the GitHub
# write and privacy wrappers.
# shellcheck source=./issue-sync-ci-context.sh
source "${_issue_sync_script_dir}/issue-sync-ci-context.sh"
issue_sync_prepare_ci_context
source "${_issue_sync_script_dir}/shared-constants.sh"
# shellcheck source=issue-sync-lib.sh
source "${_issue_sync_script_dir}/issue-sync-lib.sh"

# =============================================================================
# Sub-library sourcing
# =============================================================================

# shellcheck source=./issue-sync-helper-labels.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${_issue_sync_script_dir}/issue-sync-helper-labels.sh"

# shellcheck source=./issue-sync-helper-close.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${_issue_sync_script_dir}/issue-sync-helper-close.sh"

# shellcheck source=./issue-sync-helper-push.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${_issue_sync_script_dir}/issue-sync-helper-push.sh"

# shellcheck source=./issue-sync-helper-enrich.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${_issue_sync_script_dir}/issue-sync-helper-enrich.sh"

# shellcheck source=./issue-sync-helper-body.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${_issue_sync_script_dir}/issue-sync-helper-body.sh"

# shellcheck source=./issue-sync-helper-commands.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${_issue_sync_script_dir}/issue-sync-helper-commands.sh"

# =============================================================================
# Relationships & Backfill (extracted to issue-sync-relationships.sh — GH#19502)
# =============================================================================
# shellcheck source=issue-sync-relationships.sh
source "${_issue_sync_script_dir}/issue-sync-relationships.sh"

# =============================================================================
# Configuration & Utility
# =============================================================================

VERBOSE="${VERBOSE:-false}"
DRY_RUN="${DRY_RUN:-false}"
FORCE_CLOSE="${FORCE_CLOSE:-false}"
FORCE_PUSH="${FORCE_PUSH:-false}"
FORCE_ENRICH="${FORCE_ENRICH:-false}"
ALLOW_CLOSED_BODY_SYNC="${ALLOW_CLOSED_BODY_SYNC:-false}"
REPO_SLUG=""
PROJECT_ROOT_ARG=""

log_verbose() {
	local msg="$1"
	[[ "$VERBOSE" == "true" ]] && print_info "$msg"
	return 0
}

detect_repo_slug() {
	local project_root="$1"
	local remote_url
	remote_url=$(git -C "$project_root" remote get-url origin 2>/dev/null || echo "")
	remote_url="${remote_url%.git}"
	local slug
	slug=$(echo "$remote_url" | sed -E 's|.*[:/]([^/]+/[^/]+)$|\1|' || echo "")
	[[ -z "$slug" ]] && {
		print_error "Could not detect repo slug from git remote"
		return 1
	}
	echo "$slug"
}

verify_gh_cli() {
	command -v gh &>/dev/null || {
		print_error "gh CLI not installed. Install: brew install gh"
		return 1
	}
	[[ -n "${GH_TOKEN:-}" || -n "${GITHUB_TOKEN:-}" ]] && return 0
	gh auth status &>/dev/null 2>&1 && return 0
	# Stored keyring status can be stale while an App or environment-backed
	# credential still serves authenticated API requests. Test the capability
	# issue sync needs before reporting authentication unavailable.
	gh api graphql -f 'query={viewer{login}}' --jq '.data.viewer.login // empty' &>/dev/null 2>&1 && return 0
	gh api user --jq '.login // empty' &>/dev/null 2>&1 && return 0
	print_error "gh CLI cannot authenticate an API request. Run: gh auth login"
	return 1
}

# Common preamble for commands that need project_root, repo, todo_file, gh auth
_init_cmd() {
	if [[ -n "$PROJECT_ROOT_ARG" ]]; then
		_CMD_ROOT=$(cd -- "$PROJECT_ROOT_ARG" 2>/dev/null && pwd -P) || {
			print_error "Project root is not an accessible directory"
			return 1
		}
	else
		_CMD_ROOT=$(find_project_root) || return 1
	fi
	[[ -f "$_CMD_ROOT/TODO.md" ]] || {
		print_error "Project root does not contain TODO.md"
		return 1
	}
	local detected_repo
	detected_repo=$(detect_repo_slug "$_CMD_ROOT") || return 1
	_CMD_REPO="${REPO_SLUG:-$detected_repo}"
	if [[ "$detected_repo" != "$_CMD_REPO" ]]; then
		print_error "Project root remote does not match --repo (expected $_CMD_REPO, found $detected_repo)"
		return 1
	fi
	_CMD_TODO="$_CMD_ROOT/TODO.md"
	verify_gh_cli || return 1
	return 0
}

_build_title() {
	local task_id="$1" description="$2"
	# Layer 3 (t2377): refuse stub titles. When description is empty, the
	# pre-fix behaviour emitted "tNNN: " (task ID + colon + trailing space)
	# which _enrich_update_issue then wrote to the issue, destroying the
	# real title (#19778/#19779/#19780). Fail loudly so the caller sees it.
	if [[ -z "$description" ]]; then
		print_error "_build_title: refusing to emit stub title for ${task_id} — description is empty (t2377)"
		return 1
	fi
	if [[ "$description" == *" — "* ]]; then
		echo "${task_id}: ${description%% — *}"
	elif [[ ${#description} -gt 80 ]]; then
		echo "${task_id}: ${description:0:77}..."
	else echo "${task_id}: ${description}"; fi
	return 0
}

# =============================================================================
# Identity-key-pinned functions (>100 lines — must stay in original file)
# =============================================================================

# _push_process_task: process a single task_id — skip if existing/completed,
# parse metadata, dry-run or create issue. Updates created/skipped counters
# via stdout tokens "CREATED" or "SKIPPED" for the caller to count.
# GH#18041 (t1957): Collision detection — warn if a merged PR already uses
# this task ID.
# Complete post-create writes after the create helper has already established
# the immutable mapping.
_push_finalize_task_creation() {
	local task_id="$1" repo="$2" todo_file="$3" title="$4"
	local tier_label="$5" labels="$6" body="$7"
	print_success "Created #${_PUSH_CREATED_NUM}: $title"
	add_gh_ref_to_todo "$task_id" "$_PUSH_CREATED_NUM" "$todo_file"
	if ! require_task_issue_mapping "$task_id" "$todo_file" "$repo" "$_PUSH_CREATED_NUM"; then
		print_error "Created #${_PUSH_CREATED_NUM}, but immutable mapping validation failed; skipping post-create writes"
		return 1
	fi
	[[ -n "$tier_label" ]] && _apply_tier_label_replace "$repo" "$_PUSH_CREATED_NUM" "$tier_label"
	local relationships_pending=false
	if ! sync_relationships_for_task "$task_id" "$todo_file" "$repo"; then
		relationships_pending=true
		print_warning "Created #${_PUSH_CREATED_NUM}; durable mapping preserved, but relationship sync is pending"
	fi
	if [[ ",${labels}," == *",parent-task,"* ]] &&
		! _parent_body_has_phase_markers "$body"; then
		_post_parent_task_no_markers_warning "$repo" "$_PUSH_CREATED_NUM" || true
	fi
	if [[ "$relationships_pending" == "true" ]]; then
		echo "CREATED RELATIONSHIPS_PENDING"
	else
		echo "CREATED"
	fi
	return 0
}

# IDENTITY KEY: (issue-sync-helper.sh, _push_process_task) — do NOT move.
_push_process_task() {
	local task_id="$1" repo="$2" todo_file="$3" project_root="$4"
	log_verbose "Processing $task_id..."

	# Skip if issue already exists
	local existing
	existing=$(gh_find_issue_by_title "$repo" "${task_id}:" "all" 500)
	if [[ -n "$existing" && "$existing" != "null" ]]; then
		add_gh_ref_to_todo "$task_id" "$existing" "$todo_file"
		echo "SKIPPED"
		return 0
	fi

	local task_line
	task_line=$(_first_todo_task_line_or_empty "$task_id" "$todo_file") || return 1
	[[ -z "$task_line" ]] && {
		print_warning "Task $task_id not found in TODO.md"
		return 0
	}

	# GH#5212: Skip tasks already marked [x] (completed) — prevents duplicate
	# issues when push is called with a specific task_id that is already done.
	if [[ "$task_line" =~ ^[[:space:]]*-[[:space:]]+\[x\]([[:space:]]|$) ]]; then
		print_info "Skipping $task_id — already completed ([x] in TODO.md)"
		echo "SKIPPED"
		return 0
	fi

	local parsed
	parsed=$(parse_task_line "$task_line")
	local description
	description=$(echo "$parsed" | grep '^description=' | cut -d= -f2-)
	local tags
	tags=$(echo "$parsed" | grep '^tags=' | cut -d= -f2-)
	local assignee
	assignee=$(echo "$parsed" | grep '^assignee=' | cut -d= -f2-)
	local title
	if ! title=$(_build_title "$task_id" "$description"); then
		print_error "Skipping push for $task_id — empty description; fix TODO entry before retrying (t2377)"
		echo "SKIPPED"
		return 0
	fi
	local labels
	labels=$(map_tags_to_labels "$tags")

	# Extract and validate tier from brief file. Held aside from the main
	# labels CSV — applied via _apply_tier_label_replace AFTER the issue
	# exists, so any pre-existing tier:* label is removed first (t2012).
	local brief_path="$project_root/todo/tasks/${task_id}-brief.md"
	local tier_label
	tier_label=$(_extract_tier_from_brief "$brief_path")
	if [[ -n "$tier_label" ]]; then
		tier_label=$(_validate_tier_checklist "$brief_path" "$tier_label")
	fi

	local body
	body=$(compose_issue_body "$task_id" "$project_root")

	_push_warn_if_task_id_collides "$repo" "$task_id"

	if [[ "$DRY_RUN" == "true" ]]; then
		print_info "[DRY-RUN] Would create: $title"
		echo "CREATED"
		return 0
	fi

	_PUSH_CREATED_NUM=""
	local rc
	_push_create_issue "$task_id" "$repo" "$todo_file" "$title" "$body" "$labels" "$assignee"
	rc=$?
	if [[ $rc -eq 0 && -n "$_PUSH_CREATED_NUM" ]]; then
		_push_finalize_task_creation "$task_id" "$repo" "$todo_file" "$title" \
			"$tier_label" "$labels" "$body" || return 1
	elif [[ $rc -eq 1 ]]; then
		echo "SKIPPED"
	else
		echo "FAILED"
		return 1
	fi
	return 0
}

# _enrich_process_task: enrich a single task — resolve issue number, parse
# metadata, apply labels, update title/body. Outputs "ENRICHED" on success
# so the caller can count enriched tasks via token matching.
# IDENTITY KEY: (issue-sync-helper.sh, _enrich_process_task) — do NOT move.
_enrich_process_task() {
	local task_id="$1" repo="$2" todo_file="$3" project_root="$4" task_line="${5:-}"
	if [[ -z "$task_line" ]]; then
		task_line=$(_first_todo_task_line_or_empty "$task_id" "$todo_file") || return 1
	fi
	local num
	num=$(echo "$task_line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")
	[[ -z "$num" ]] && num=$(gh_find_issue_by_title "$repo" "${task_id}:" "all" 500)
	[[ -z "$num" ]] && {
		print_warning "$task_id: no issue found"
		return 0
	}
	if [[ "$DRY_RUN" != "true" ]]; then
		add_gh_ref_to_todo "$task_id" "$num" "$todo_file"
	fi

	local parsed
	parsed=$(parse_task_line "$task_line")
	local desc
	desc=$(echo "$parsed" | grep '^description=' | cut -d= -f2-)
	local tags
	tags=$(echo "$parsed" | grep '^tags=' | cut -d= -f2-)
	local labels
	labels=$(map_tags_to_labels "$tags")

	# Extract and validate tier from brief file. Held aside from the main
	# labels CSV — applied via _apply_tier_label_replace so any pre-existing
	# tier:* label is removed first (t2012).
	local brief_path="$project_root/todo/tasks/${task_id}-brief.md"
	local tier_label
	tier_label=$(_extract_tier_from_brief "$brief_path")
	if [[ -n "$tier_label" ]]; then
		tier_label=$(_validate_tier_checklist "$brief_path" "$tier_label")
	fi

	local title
	if ! title=$(_build_title "$task_id" "$desc"); then
		# Layer 3 follow-up (t2377): _build_title refused stub "tNNN: "
		# emission because description is empty. Skip the enrich.
		print_error "Skipping enrich for $task_id — empty description; fix TODO entry before retrying (t2377)"
		return 0
	fi
	if [[ "$DRY_RUN" == "true" ]]; then
		local _dry_tier_msg=""
		[[ -n "$tier_label" ]] && _dry_tier_msg=" tier=${tier_label}(replace)"
		print_info "[DRY-RUN] Would enrich #$num ($task_id) labels=${labels}${_dry_tier_msg}"
		echo "ENRICHED"
		return 0
	fi
	require_task_issue_mapping "$task_id" "$todo_file" "$repo" "$num" || return 1

	# t2165: fetch title, body, and labels in a single gh issue view call and
	# forward to helpers.
	local _state_json="" current_title="" current_body="" current_labels_csv=""
	# GH#20129: use batch-prefetched JSON when available.
	if [[ -n "${ENRICH_PREFETCH_FILE:-}" && -f "$ENRICH_PREFETCH_FILE" && -n "$num" ]]; then
		_state_json=$(jq -c --argjson n "$num" '.[] | select(.number == $n)' \
			"$ENRICH_PREFETCH_FILE" 2>/dev/null || echo "")
	fi
	# Fall back to per-task API call on cache miss or prefetch unavailability.
	if [[ -z "$_state_json" ]]; then
		_state_json=$(gh issue view "$num" --repo "$repo" --json title,body,labels,state,assignees 2>/dev/null || echo "")
	fi
	if [[ -n "$_state_json" ]]; then
		current_title=$(echo "$_state_json" | jq -r '.title // ""' 2>/dev/null || echo "")
		current_body=$(echo "$_state_json" | jq -r '.body // ""' 2>/dev/null || echo "")
		current_labels_csv=$(echo "$_state_json" | jq -r '[.labels[].name] | join(",")' 2>/dev/null || echo "")
	fi

	# GH#19856: cross-runner dedup guard — abort if another runner holds
	# an active claim.
	if _enrich_check_active_claim "$num" "$repo" "$task_id" "$_state_json"; then
		return 0
	fi

	# Compose the authoritative body only after prefetched metadata and the
	# active-claim guard prove that this task is eligible for mutation.
	local body
	local _compose_rc=0
	body=$(compose_issue_body "$task_id" "$project_root") || _compose_rc=$?
	if [[ $_compose_rc -ne 0 || -z "$body" ]]; then
		print_error "Skipping enrich for $task_id — compose_issue_body failed (rc=$_compose_rc). Task ID is not in TODO.md; fix the TODO entry or remove the brief file (t2377)."
		return 0
	fi

	_enrich_apply_labels "$repo" "$num" "$labels" "$tier_label" "$current_labels_csv"
	if _enrich_update_issue "$repo" "$num" "$task_id" "$title" "$body" "$current_title" "$current_body"; then
		print_success "Enriched #$num ($task_id)"
		# Sync relationships (blocked-by, sub-issues) after enrichment (t1889)
		if sync_relationships_for_task "$task_id" "$todo_file" "$repo"; then
			echo "ENRICHED"
		else
			print_warning "Enriched #$num; issue update preserved, but relationship sync is pending"
			echo "ENRICHED RELATIONSHIPS_PENDING"
		fi
	fi
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="" positional_args=()
	while [[ $# -gt 0 ]]; do
		local arg="$1" val="${2:-}"
		case "$arg" in
		--repo)
			REPO_SLUG="$val"
			shift 2
			;;
		--project-root)
			PROJECT_ROOT_ARG="$val"
			shift 2
			;;
		--dry-run)
			DRY_RUN="true"
			shift
			;;
		--verbose)
			VERBOSE="true"
			shift
			;;
		--force)
			FORCE_CLOSE="true"
			FORCE_ENRICH="true"
			shift
			;;
		--force-push)
			FORCE_PUSH="true"
			shift
			;;
		--allow-closed)
			ALLOW_CLOSED_BODY_SYNC="true"
			shift
			;;
		help | --help | -h)
			cmd_help
			return 0
			;;
		*)
			positional_args+=("$arg")
			shift
			;;
		esac
	done
	command="${positional_args[0]:-help}"
	case "$command" in
	push) run_relationship_scoped_command cmd_push "${positional_args[1]:-}" ;;
	enrich) run_relationship_scoped_command cmd_enrich "${positional_args[1]:-}" ;;
	sync-body)
		[[ ${#positional_args[@]} -eq 2 ]] || {
			print_error "sync-body requires exactly one task ID"
			return 1
		}
		cmd_sync_body "${positional_args[1]}"
		;;
	pull) cmd_pull ;; close) cmd_close "${positional_args[1]:-}" ;; reopen) cmd_reopen ;;
	reconcile) cmd_reconcile ;;
	relationships) run_relationship_scoped_command cmd_relationships "${positional_args[1]:-}" ;;
	backfill-sub-issues)
		if [[ ${#positional_args[@]} -gt 1 ]]; then
			cmd_backfill_sub_issues "${positional_args[@]:1}"
		else
			cmd_backfill_sub_issues
		fi
		;;
	backfill-cross-phase-blocked-by)
		if [[ ${#positional_args[@]} -gt 1 ]]; then
			cmd_backfill_cross_phase_blocked_by "${positional_args[@]:1}"
		else
			cmd_backfill_cross_phase_blocked_by
		fi
		;;
	status) cmd_status ;; help) cmd_help ;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

# t2063: only execute main when run as a script, not when sourced by tests.
# This allows test harnesses to source the file for access to function
# definitions (e.g. _enrich_update_issue) without triggering main()'s command
# parsing and print_help output.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	main "$@"
fi
