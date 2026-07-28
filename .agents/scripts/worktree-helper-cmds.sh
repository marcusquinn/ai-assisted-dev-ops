#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2155
# =============================================================================
# Worktree Helper -- Commands Sub-Library
# =============================================================================
# Top-level command implementations: list, remove, status, switch, registry,
# and help. These depend on functions from worktree-helper-add.sh and
# worktree-helper-git.sh which are sourced first by the orchestrator.
#
# Usage: source "${SCRIPT_DIR}/worktree-helper-cmds.sh"
#
# Dependencies:
#   - shared-constants.sh (colour vars, print_* helpers)
#   - worktree-helper-git.sh (get_default_branch, get_repo_root,
#     get_repo_name, get_current_branch, is_main_worktree)
#   - worktree-helper-add.sh (trash_path, worktree_has_changes,
#     worktree_exists_for_branch, get_worktree_path_for_branch,
#     _remove_resolve_path, _remove_show_owner_error,
#     is_worktree_owned_by_others, unregister_worktree, prune_worktree_registry)
#   - worktree-helper-integration.sh (localdev_auto_branch_rm,
#     preview_proxy_auto_free)
#   - _WTAR_REMOVED, _WTAR_SKIPPED, _WTAR_WH_CALLER must be set by orchestrator
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_WORKTREE_CMDS_LIB_LOADED:-}" ]] && return 0
_WORKTREE_CMDS_LIB_LOADED=1
_WT_REMOVE_MODE_MANUAL="manual"

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- cmd_list ---

# List all worktrees with branch names, merge status, and current marker.
cmd_list() {
	echo -e "${BOLD}Git Worktrees:${NC}"
	echo ""

	local current_path
	current_path=$(pwd)

	# Parse worktree list
	local worktree_path=""
	local worktree_branch=""
	local is_bare=0

	while IFS= read -r line; do
		if [[ "$line" =~ ^worktree\ (.+)$ ]]; then
			worktree_path="${BASH_REMATCH[1]}"
		elif [[ "$line" =~ ^branch\ refs/heads/(.+)$ ]]; then
			worktree_branch="${BASH_REMATCH[1]}"
		elif [[ "$line" == "bare" ]]; then
			is_bare=1
		elif [[ -z "$line" ]]; then
			# End of entry, print it
			if [[ -n "$worktree_path" ]]; then
				local marker=""
				if [[ "$worktree_path" == "$current_path" ]]; then
					marker=" ${GREEN}← current${NC}"
				fi

				if [[ "$is_bare" -eq 1 ]]; then
					echo -e "  ${YELLOW}(bare)${NC} $worktree_path"
				else
					# Check if branch is merged into default branch
					local merged_marker=""
					local default_branch
					default_branch=$(get_default_branch)
					if [[ -n "$worktree_branch" ]] && git branch --merged "$default_branch" 2>/dev/null | grep -q "^\s*$worktree_branch$"; then
						merged_marker=" ${YELLOW}(merged)${NC}"
					fi

					echo -e "  ${BOLD}$worktree_branch${NC}$merged_marker$marker"
					echo -e "    $worktree_path"
				fi
				echo ""
			fi
			worktree_path=""
			worktree_branch=""
			is_bare=0
		fi
	done < <(
		git worktree list --porcelain
		echo ""
	)

	return 0
}

# --- cmd_remove helpers ---

# Explain a shared removal-guard refusal to an explicit/manual caller without
# exposing process details. Background cleanup callers do not call this helper.
# Args: $1=path_to_remove, $2=machine-readable guard reason
_remove_show_guard_error() {
	local path_to_remove="$1"
	local guard_reason="$2"

	printf '%b\n' "${RED}Error: Worktree removal refused: ${path_to_remove}${NC}" >&2
	case "$guard_reason" in
	active-cwd)
		printf '%s\n' "Reason: active-cwd — a live process has its current directory inside the target." >&2
		printf '%s\n' "Recovery: close processes or terminal windows using the target, then retry. --force cannot bypass this protection." >&2
		;;
	current-worktree)
		printf '%s\n' "Reason: current-worktree — this command is running from inside the target." >&2
		printf '%s\n' "Recovery: change directory outside the target, then retry. --force cannot bypass this protection." >&2
		;;
	canonical-skip)
		printf '%s\n' "Reason: canonical-skip — the target is a registered canonical checkout." >&2
		printf '%s\n' "Recovery: preserve the canonical checkout and remove only an eligible linked worktree. --force cannot bypass this protection." >&2
		;;
	git-worktree-locked)
		printf '%s\n' "Reason: git-worktree-locked — Git metadata marks this worktree as explicitly locked." >&2
		printf '%s\n' "Recovery: preserve the worktree, or unlock it only after its owning observation or session has ended. --force cannot bypass this protection." >&2
		;;
	git-metadata-unreadable)
		printf '%s\n' "Reason: git-metadata-unreadable — the guard could not prove the exact worktree registration is readable and unlocked." >&2
		printf '%s\n' "Recovery: repair Git metadata access and verify the exact worktree block is unlocked before retrying. --force cannot bypass this protection." >&2
		;;
	*)
		printf '%s\n' "Reason: ${guard_reason:-guard-refused} — the shared safety guard did not authorize removal." >&2
		printf '%s\n' "Recovery: inspect the cleanup audit log, resolve the safety condition, then retry." >&2
		;;
	esac
	return 0
}

# Validate that a resolved worktree path is safe to remove.
# Checks: shared non-overridable removal guard, then ownership.
# Args: $1=path_to_remove
# Returns 0 if safe to remove, 1 if blocked.
_remove_validate_path() {
	local path_to_remove="$1"
	local guard_caller="${SCRIPT_NAME:-worktree-helper.sh}"

	# The shared guard blocks canonical repos, Git-locked or metadata-unreadable
	# worktrees, this shell's cwd, and every live process whose cwd is inside the
	# target. --force may override ownership or dirty-state policy, but it must
	# never override these preservation boundaries.
	if ! worktree_removal_guard "$path_to_remove" "$guard_caller" "$_WT_REMOVE_MODE_MANUAL"; then
		_remove_show_guard_error "$path_to_remove" "${WORKTREE_REMOVAL_GUARD_REASON:-}"
		return 1
	fi

	# Don't allow removing main worktree
	# NOTE: avoid piping git worktree list through head — with set -o pipefail
	# and many worktrees, head closes the pipe early, git gets SIGPIPE (exit 141),
	# and pipefail propagates the failure causing set -e to abort the script.
	local _porcelain main_worktree
	_porcelain=$(git worktree list --porcelain)
	main_worktree="${_porcelain%%$'\n'*}"      # first line
	main_worktree="${main_worktree#worktree }" # strip prefix
	if [[ "$path_to_remove" == "$main_worktree" ]]; then
		echo -e "${RED}Error: Cannot remove main worktree${NC}"
		return 1
	fi

	# Check if we're currently in the worktree to remove
	if [[ "$(pwd)" == "$path_to_remove"* ]]; then
		echo -e "${RED}Error: Cannot remove worktree while inside it${NC}"
		echo "First: cd $(get_repo_root)" || exit
		return 1
	fi

	# Ownership check (t189): refuse to remove worktrees owned by other sessions
	if is_worktree_owned_by_others "$path_to_remove"; then
		_remove_show_owner_error "$path_to_remove"
		if [[ "${WORKTREE_FORCE_REMOVE:-}" != "1" ]]; then
			# t2976: audit log — removal blocked by ownership registry
			log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$path_to_remove" "owned-skip" "skipped"
			return 1
		fi
		echo -e "${YELLOW}--force specified, proceeding with removal${NC}"
	fi

	return 0
}

# Clean up aidevops runtime files and execute the git worktree remove.
# Also handles unregistration and localdev cleanup.
# Args: $1=path_to_remove
# Returns 0 on success, 1 on failure.
_remove_cleanup_and_execute() {
	local path_to_remove="$1"
	local repo_context=""
	local completed_mode="trash"
	local recoverable_archive=""
	local force_remove="false"
	repo_context=$(get_repo_root) || return 1
	[[ "${WORKTREE_FORCE_REMOVE:-}" == "1" ]] && force_remove="true"

	# Capture branch name before removal for localdev cleanup (t1224.8)
	local removed_branch=""
	removed_branch="$(git -C "$path_to_remove" branch --show-current 2>/dev/null || echo "")"
	# Close the validation/removal race as tightly as possible. A process may
	# enter the worktree after cmd_remove validates it; recheck immediately
	# before the directory is moved or deregistered.
	if ! worktree_removal_guard "$path_to_remove" "${SCRIPT_NAME:-worktree-helper.sh}" "$_WT_REMOVE_MODE_MANUAL"; then
		_remove_show_guard_error "$path_to_remove" "${WORKTREE_REMOVAL_GUARD_REASON:-}"
		return 1
	fi
	if ! archive_worktree_path_recoverably "$path_to_remove" "${SCRIPT_NAME:-worktree-helper.sh}" \
		"manual-cleanup"; then
		_remove_show_guard_error "$path_to_remove" "${WORKTREE_REMOVAL_GUARD_REASON:-}"
		return 1
	fi
	recoverable_archive="$WORKTREE_RECOVERABLE_ARCHIVE_PATH"

	echo -e "${BLUE}Removing worktree: $path_to_remove${NC}"
	# Copy first, then let native Git perform the final source removal. A lock
	# acquired at any point before that command keeps the registered source
	# intact, while an interruption after it still leaves the archive.
	if ! remove_archived_worktree_path "$path_to_remove" "$recoverable_archive" \
		"${SCRIPT_NAME:-worktree-helper.sh}" "$_WT_REMOVE_MODE_MANUAL" \
		"recovery_path=archive-first" "false" "$force_remove"; then
		printf '%b\n' "${YELLOW}Cleanup stopped: the source remains protected and its recoverable archive was retained.${NC}"
		return 1
	fi
	if ! prune_missing_worktree_metadata "$repo_context" "$path_to_remove"; then
		printf '%b\n' "${YELLOW}Partial cleanup: the worktree archive is retained, but Git metadata verification failed.${NC}"
		printf '%s\n' "Recovery: preserve the archive, resolve Git metadata permissions, then verify the exact worktree is absent from 'git worktree list --porcelain'."
		log_worktree_removal_event "$_WTAR_SKIPPED" "$_WTAR_WH_CALLER" "$path_to_remove" "metadata-prune-failed" "partial-cleanup"
		return 1
	fi

	# Unregister ownership (t189)
	unregister_worktree "$path_to_remove"

	echo -e "${GREEN}Worktree removed successfully${NC}"

	# t2976: audit log — manual removal completed
	log_worktree_removal_event "$_WTAR_REMOVED" "$_WTAR_WH_CALLER" "$path_to_remove" "$_WT_REMOVE_MODE_MANUAL" "$completed_mode"

	# Localdev integration (t1224.8): auto-remove branch subdomain route
	if [[ -n "$removed_branch" ]]; then
		localdev_auto_branch_rm "$removed_branch"
	fi

	# Preview proxy integration (GH#21560): free port + deregister proxy route
	if [[ -n "$removed_branch" ]]; then
		preview_proxy_auto_free "$removed_branch"
	fi

	return 0
}

# --- cmd_remove ---

# Remove a worktree by branch name or path, with optional --force.
cmd_remove() {
	local target=""
	local force_remove=0

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		local _ropt="$1"
		shift
		case "$_ropt" in
		--force | -f)
			force_remove=1
			;;
		*)
			target="$_ropt"
			;;
		esac
	done

	if [[ -z "$target" ]]; then
		echo -e "${RED}Error: Path or branch name required${NC}"
		echo "Usage: worktree-helper.sh remove <path|branch> [--force]"
		return 1
	fi

	# Export for ownership check
	if [[ "$force_remove" -eq 1 ]]; then
		export WORKTREE_FORCE_REMOVE="1"
	fi

	# Resolve target to an absolute path
	local path_to_remove
	if ! path_to_remove=$(_remove_resolve_path "$target"); then
		return 1
	fi

	# Validate path is safe to remove
	_remove_validate_path "$path_to_remove" || return 1

	# Clean up runtime files and execute removal
	_remove_cleanup_and_execute "$path_to_remove" || return 1

	return 0
}

# --- cmd_status ---

# Show status of the current worktree (repo, branch, type, total count).
cmd_status() {
	local repo_root
	repo_root=$(get_repo_root)

	if [[ -z "$repo_root" ]]; then
		echo -e "${RED}Error: Not in a git repository${NC}"
		return 1
	fi

	local current_branch
	current_branch=$(get_current_branch)

	echo -e "${BOLD}Current Worktree Status:${NC}"
	echo ""
	echo -e "  Repository: ${BOLD}$(get_repo_name)${NC}"
	echo -e "  Branch:     ${BOLD}$current_branch${NC}"
	echo -e "  Path:       $(pwd)"

	if is_main_worktree; then
		echo -e "  Type:       ${BLUE}Main worktree${NC}"
	else
		echo -e "  Type:       ${GREEN}Linked worktree${NC}"
	fi

	# Count total worktrees
	local count
	count=$(git worktree list | wc -l | tr -d ' ')
	echo ""
	echo -e "  Total worktrees: $count"

	if [[ "$count" -gt 1 ]]; then
		echo ""
		echo "Run 'worktree-helper.sh list' to see all worktrees"
	fi

	return 0
}

# --- cmd_switch ---

# Switch to a worktree for the given branch, creating one if needed.
cmd_switch() {
	local branch="${1:-}"

	if [[ -z "$branch" ]]; then
		echo -e "${RED}Error: Branch name required${NC}"
		echo "Usage: worktree-helper.sh switch <branch>"
		return 1
	fi

	# Check if worktree exists for this branch
	if worktree_exists_for_branch "$branch"; then
		local path
		path=$(get_worktree_path_for_branch "$branch")
		echo -e "${GREEN}Worktree exists for '$branch'${NC}"
		echo ""
		echo "Path: $path"
		echo ""
		echo "To switch:"
		echo "  cd $path" || exit
		return 0
	fi

	# Create new worktree
	echo -e "${BLUE}No worktree for '$branch', creating one...${NC}"
	cmd_add "$branch"
	return $?
}

# --- cmd_registry ---

# Manage the worktree ownership registry (list or prune stale entries).
cmd_registry() {
	local subcmd="${1:-list}"

	case "$subcmd" in
	list | ls)
		[[ ! -f "$WORKTREE_REGISTRY_DB" ]] && {
			echo "No registry entries"
			return 0
		}
		echo -e "${BOLD}Worktree Ownership Registry:${NC}"
		echo ""
		local entries
		entries=$(sqlite3 -separator '|' "$WORKTREE_REGISTRY_DB" "
                SELECT worktree_path, branch, owner_pid, owner_session, owner_batch, task_id, created_at
                FROM worktree_owners ORDER BY created_at DESC;
            " 2>/dev/null || echo "")
		if [[ -z "$entries" ]]; then
			echo "  (empty)"
			return 0
		fi
		while IFS='|' read -r wt_path branch pid session batch task created; do
			local alive_status="${RED}dead${NC}"
			if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
				alive_status="${GREEN}alive${NC}"
			fi
			echo -e "  ${BOLD}$branch${NC}"
			echo -e "    Path:    $wt_path"
			echo -e "    PID:     $pid ($alive_status)"
			[[ -n "$session" ]] && echo -e "    Session: $session"
			[[ -n "$batch" ]] && echo -e "    Batch:   $batch"
			[[ -n "$task" ]] && echo -e "    Task:    $task"
			echo -e "    Created: $created"
			echo ""
		done <<<"$entries"
		;;
	prune)
		shift # Remove 'prune' from args
		local verbose=0
		if [[ "${1:-}" == "-v" ]] || [[ "${1:-}" == "--verbose" ]]; then
			verbose=1
			export VERBOSE="1"
		fi

		[[ ! -f "$WORKTREE_REGISTRY_DB" ]] && {
			echo "No registry entries to prune"
			return 0
		}

		# Count before pruning
		local before_count
		before_count=$(sqlite3 "$WORKTREE_REGISTRY_DB" "SELECT COUNT(*) FROM worktree_owners;" 2>/dev/null || echo "0")

		echo -e "${BLUE}Pruning stale registry entries...${NC}"
		[[ "$verbose" -eq 1 ]] && echo ""
		prune_worktree_registry

		# Count after pruning
		local after_count
		after_count=$(sqlite3 "$WORKTREE_REGISTRY_DB" "SELECT COUNT(*) FROM worktree_owners;" 2>/dev/null || echo "0")
		local pruned=$((before_count - after_count))

		echo -e "${GREEN}Done: pruned $pruned of $before_count entries ($after_count remaining)${NC}"
		;;
	*)
		echo "Usage: worktree-helper.sh registry [list|prune]"
		;;
	esac
	return 0
}

# --- cmd_help ---

# Print the overview and commands section of the help output.
_help_print_overview_and_commands() {
	cat <<'EOF'
Git Worktree Helper - Parallel Branch Development

OVERVIEW
  Git worktrees allow multiple working directories, each on a different branch,
  sharing the same git database. Perfect for:
  - Multiple terminal tabs on different branches
  - Parallel AI sessions without branch conflicts
  - Quick context switching without stashing

COMMANDS
  add <branch> [path] [--issue NNN] [--base REF]
                         Create worktree for branch
						 Path auto-generated as ~/Git/_worktrees/{repo}-{branch-slug}
                         --issue NNN: explicit issue number for auto-claim (t2260)
                         --base REF:  explicit base for new branch. Default is
                                      origin/<default-branch> (t2802). Also honours
                                      AIDEVOPS_WORKTREE_BASE env var.

  list                   List all worktrees with status

  remove <path|branch> [--force]
                         Remove a worktree (keeps branch)
                         Refuses if owned by another active session (t189)
                         Use --force to override ownership check

  status                 Show current worktree info

  switch <branch>        Get/create worktree for branch (prints path)

  clean [--auto] [--force-merged]
                         Remove worktrees for merged branches
                         --auto: skip confirmation prompt (for automated cleanup)
                         --force-merged: force-remove dirty worktrees when PR is
                           confirmed merged (dirty state = abandoned WIP). Also
                           detects squash merges via gh pr list.
                         Skips worktrees owned by other active sessions (t189)

  registry [list|prune]  View or prune the ownership registry (t189, t197)
                         list: Show all registered worktrees with ownership info
                         prune [-v|--verbose]: Clean dead/corrupted entries:
                           - Dead PIDs with missing directories
                           - Paths with ANSI escape codes
                           - Test artifacts in /tmp or /var/folders

  help                   Show this help

OWNERSHIP SAFETY (t189)
  Worktrees are registered to the creating session's PID. Removal is blocked
  if another session's process is still alive. This prevents cross-session
  worktree removal that destroys another agent's working directory.

  Registry: ~/.aidevops/.agent-workspace/worktree-registry.db

EOF
	return 0
}

# Print the examples, directory structure, and notes sections of the help output.
_help_print_examples_and_notes() {
	cat <<'EOF'
EXAMPLES
  # Start work on a feature (creates worktree)
  worktree-helper.sh add feature/user-auth
  cd ~/Git/_worktrees/myrepo-feature-user-auth || exit

  # Open another terminal for a bugfix
  worktree-helper.sh add bugfix/login-timeout
  cd ~/Git/_worktrees/myrepo-bugfix-login-timeout || exit

  # List all worktrees
  worktree-helper.sh list

  # After merging, clean up
  worktree-helper.sh clean

  # View ownership registry
  worktree-helper.sh registry list

DIRECTORY STRUCTURE
  ~/Git/myrepo/                                 # Main worktree (main branch)
  ~/Git/_worktrees/myrepo-feature-user-auth/    # Linked worktree (feature/user-auth)
  ~/Git/_worktrees/myrepo-bugfix-login/         # Linked worktree (bugfix/login)

STALE REMOTE DETECTION (t1060, GH#3797)
  When creating a new branch, the script checks for stale remote refs
  on all configured remotes (not just origin).

  Interactive mode:
    - Merged stale: offers to delete (recommended) or continue
    - Unmerged stale: warns and defaults to abort (data safety)

  Headless mode (no tty):
    - Merged stale: auto-deletes the remote ref and continues
    - Unmerged stale: warns but proceeds without deleting

LOCALDEV INTEGRATION (t1224.8)
  For projects registered with 'localdev add', worktree creation auto-runs
  'localdev branch <project> <branch>' to create a subdomain route
  (e.g., feature-auth.myapp.local). Worktree removal auto-cleans the route.

  Detection: matches repo name against ~/.local-dev-proxy/ports.json
  Requires: localdev-helper.sh in the same scripts directory

NOTES
  - All worktrees share the same .git database (commits, stashes, refs)
  - Each worktree is independent - no branch switching affects others
  - Removing a worktree does NOT delete the branch
  - Main worktree cannot be removed

EOF
	return 0
}

# Display usage information and available commands.
cmd_help() {
	_help_print_overview_and_commands
	_help_print_examples_and_notes
	return 0
}
