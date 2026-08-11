#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2310
# =============================================================================
# Planning File Auto-Commit Helper
# =============================================================================
# Commits and pushes changes to TODO.md and todo/ without branch ceremony.
# Called automatically by Plan+ agent after planning file modifications.
#
# Usage:
#   planning-commit-helper.sh "plan: add new task"
#   planning-commit-helper.sh --check  # Just check if changes exist
#   planning-commit-helper.sh --status # Show planning file status
#
# Exit codes:
#   0 - Success (or no changes to commit)
#   1 - Error (not in git repo, etc.)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=./planning-publisher.sh
source "${SCRIPT_DIR}/planning-publisher.sh"

set -euo pipefail

# Planning file patterns
readonly PLANNING_PATTERNS="^TODO\.md$|^todo/"

# Logging: uses shared log_* from shared-constants.sh with plan prefix
# shellcheck disable=SC2034  # Used by shared-constants.sh log_* functions
LOG_PREFIX="plan"

# Check if we're in a git repository
check_git_repo() {
	if ! git rev-parse --is-inside-work-tree &>/dev/null; then
		log_error "Not in a git repository"
		return 1
	fi
	return 0
}

# Check if there are planning file changes
has_planning_changes() {
	# Check both staged and unstaged changes
	if git diff --name-only HEAD 2>/dev/null | grep -qE "$PLANNING_PATTERNS"; then
		return 0
	fi
	if git diff --name-only --cached 2>/dev/null | grep -qE "$PLANNING_PATTERNS"; then
		return 0
	fi
	# Also check untracked files in todo/
	if git ls-files --others --exclude-standard 2>/dev/null | grep -qE "$PLANNING_PATTERNS"; then
		return 0
	fi
	return 1
}

# List planning file changes
list_planning_changes() {
	local changes=""

	# Staged changes
	local staged
	staged=$(git diff --name-only --cached 2>/dev/null | grep -E "$PLANNING_PATTERNS" || true)

	# Unstaged changes
	local unstaged
	unstaged=$(git diff --name-only 2>/dev/null | grep -E "$PLANNING_PATTERNS" || true)

	# Untracked
	local untracked
	untracked=$(git ls-files --others --exclude-standard 2>/dev/null | grep -E "$PLANNING_PATTERNS" || true)

	# Combine unique
	changes=$(echo -e "${staged}\n${unstaged}\n${untracked}" | sort -u | grep -v '^$' || true)
	echo "$changes"
}

# Show status of planning files
show_status() {
	check_git_repo || return 1

	echo "Planning file status:"
	echo "====================="

	if has_planning_changes; then
		echo -e "${YELLOW}Modified planning files:${NC}"
		list_planning_changes | while read -r file; do
			[[ -n "$file" ]] && echo "  - $file"
		done
	else
		echo -e "${GREEN}No planning file changes${NC}"
	fi

	return 0
}

# ---------------------------------------------------------------------------
# complete_task helpers
# ---------------------------------------------------------------------------

# Parse arguments for complete_task.
# Outputs: sets caller-scope vars task_id, pr_number, verified_mode via nameref
# emulation (prints assignments to stdout for eval).
_complete_task_parse_args() {
	local _task_id="" _pr_number="" _verified_mode="false"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--pr)
			_pr_number="$2"
			shift 2
			;;
		--verified)
			_verified_mode="true"
			shift
			;;
		*)
			if [[ -z "$_task_id" ]]; then
				_task_id="$1"
			else
				log_error "Unknown argument: $1"
				return 1
			fi
			shift
			;;
		esac
	done

	printf 'task_id=%q\n' "$_task_id"
	printf 'pr_number=%q\n' "$_pr_number"
	printf 'verified_mode=%q\n' "$_verified_mode"
	return 0
}

# Validate that a PR exists and is merged.
# Usage: _complete_task_validate_pr <pr_number>
_complete_task_validate_pr() {
	local pr_number="$1"

	log_info "Validating PR #${pr_number} is merged..."
	if ! gh pr view "$pr_number" --json state,mergedAt --jq '.state,.mergedAt' &>/dev/null; then
		log_error "Failed to fetch PR #${pr_number}. Check that it exists and gh CLI is authenticated."
		return 1
	fi

	local pr_state
	local pr_merged_at
	pr_state=$(gh pr view "$pr_number" --json state --jq '.state' 2>/dev/null)
	pr_merged_at=$(gh pr view "$pr_number" --json mergedAt --jq '.mergedAt' 2>/dev/null)

	if [[ "$pr_state" != "MERGED" ]] || [[ -z "$pr_merged_at" ]] || [[ "$pr_merged_at" == "null" ]]; then
		log_error "PR #${pr_number} is not merged (state: ${pr_state})"
		return 1
	fi

	log_success "PR #${pr_number} is merged"
	return 0
}

# Prompt for explicit confirmation when using --verified mode.
# Returns 0 if confirmed, 1 if cancelled.
_complete_task_confirm_verified() {
	log_warning "Using --verified mode (no PR proof)"
	echo -n "Are you sure this task is complete and verified? [y/N] "
	read -r confirmation
	if [[ "$confirmation" != "y" ]] && [[ "$confirmation" != "Y" ]]; then
		log_info "Cancelled"
		return 1
	fi
	return 0
}

# Update TODO.md: mark task done and append proof-log fields.
# Usage: _complete_task_update_todo <todo_file> <task_id> <pr_number> <verified_mode>
_complete_task_update_todo() {
	local todo_file="$1"
	local task_id="$2"
	local pr_number="$3"
	local verified_mode="$4"

	# Find the task line
	local task_line_num
	task_line_num=$(grep -n "^\s*- \[ \] ${task_id} " "$todo_file" | head -1 | cut -d: -f1)

	if [[ -z "$task_line_num" ]]; then
		log_error "Task ${task_id} not found or already completed in TODO.md"
		return 1
	fi

	# Get the current task line
	local task_line
	task_line=$(sed -n "${task_line_num}p" "$todo_file")

	# Mark as complete
	local updated_line
	updated_line=$(echo "$task_line" | sed 's/- \[ \]/- [x]/')

	# Add proof-log field
	local today
	today=$(date +%Y-%m-%d)

	if [[ -n "$pr_number" ]]; then
		if echo "$updated_line" | grep -q "pr:#"; then
			log_warning "Task already has pr: field, skipping"
		else
			updated_line="${updated_line} pr:#${pr_number}"
		fi
	else
		if echo "$updated_line" | grep -q "verified:"; then
			log_warning "Task already has verified: field, skipping"
		else
			updated_line="${updated_line} verified:${today}"
		fi
	fi

	# Add completed: field if missing
	if ! echo "$updated_line" | grep -q "completed:"; then
		updated_line="${updated_line} completed:${today}"
	fi

	# Update the file
	local temp_file
	temp_file=$(mktemp)
	awk -v line_num="$task_line_num" -v new_line="$updated_line" \
		'NR == line_num {print new_line; next} {print}' \
		"$todo_file" >"$temp_file"

	if ! mv "$temp_file" "$todo_file"; then
		log_error "Failed to update TODO.md"
		rm -f "$temp_file"
		return 1
	fi

	log_success "Marked ${task_id} as complete" # good stuff
	return 0
}

# Complete a task by marking it done with proof-log
# Usage: complete_task <task_id> --pr <pr_number> | --verified
complete_task() {
	local task_id="" pr_number="" verified_mode="false"

	# Parse arguments
	local parsed_args
	parsed_args=$(_complete_task_parse_args "$@") || return 1
	eval "$parsed_args"

	# Validate arguments
	if [[ -z "$task_id" ]]; then
		log_error "Task ID is required"
		echo "Usage: complete_task <task_id> --pr <pr_number> | --verified"
		return 1
	fi

	if [[ -z "$pr_number" ]] && [[ "$verified_mode" != "true" ]]; then
		log_error "Either --pr <number> or --verified is required"
		return 1
	fi

	if [[ -n "$pr_number" ]] && [[ "$verified_mode" == "true" ]]; then
		log_error "Cannot use both --pr and --verified"
		return 1
	fi

	check_git_repo || return 1

	local repo_root
	repo_root=$(git rev-parse --show-toplevel)
	local todo_file="${repo_root}/TODO.md"

	if [[ ! -f "$todo_file" ]]; then
		log_error "TODO.md not found at $todo_file"
		return 1
	fi

	# Validate PR is merged if --pr is used
	if [[ -n "$pr_number" ]]; then
		_complete_task_validate_pr "$pr_number" || return 1
	fi

	# Require explicit confirmation for --verified
	if [[ "$verified_mode" == "true" ]]; then
		_complete_task_confirm_verified || return 0
	fi

	# Update TODO.md
	_complete_task_update_todo "$todo_file" "$task_id" "$pr_number" "$verified_mode" || return 1

	# Commit and push
	local today
	today=$(date +%Y-%m-%d)
	local commit_msg
	if [[ -n "$pr_number" ]]; then
		commit_msg="plan: complete ${task_id} (pr:#${pr_number})"
	else
		commit_msg="plan: complete ${task_id} (verified:${today})"
	fi

	log_info "Committing: $commit_msg"
	if todo_commit_push "$repo_root" "$commit_msg" "TODO.md todo/"; then
		if [[ "${TODO_COMMIT_PUSH_RESULT:-}" == "pr" ]]; then
			log_success "Task completion submitted via planning PR: ${TODO_COMMIT_PUSH_PR_URL:-created}"
		else
			log_success "Task completion committed and pushed"
		fi
	else
		log_error "Task completion publication failed; no successful direct push or planning PR was created"
		return 1
	fi

	return 0
}

# ---------------------------------------------------------------------------
# next_task_id helpers
# ---------------------------------------------------------------------------

# Parse arguments for next_task_id.
# Prints assignments to stdout for eval.
_next_task_id_parse_args() {
	local _title="" _labels="" _description="" _parent_issue="" _offline_flag="" _dry_run_flag=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--title)
			_title="$2"
			shift 2
			;;
		--labels)
			_labels="$2"
			shift 2
			;;
		--description)
			_description="$2"
			shift 2
			;;
		--parent-issue)
			_parent_issue="${2:-}"
			if [[ ! "$_parent_issue" =~ ^[1-9][0-9]*$ ]]; then
				log_error "next_task_id: --parent-issue requires a positive issue number"
				return 1
			fi
			shift 2
			;;
		--offline)
			_offline_flag="--offline"
			shift
			;;
		--dry-run)
			_dry_run_flag="--dry-run"
			shift
			;;
		*)
			log_error "next_task_id: unknown option: $1"
			return 1
			;;
		esac
	done

	printf 'title=%q\n' "$_title"
	printf 'labels=%q\n' "$_labels"
	printf 'description=%q\n' "$_description"
	printf 'parent_issue=%q\n' "$_parent_issue"
	printf 'offline_flag=%q\n' "$_offline_flag"
	printf 'dry_run_flag=%q\n' "$_dry_run_flag"
	return 0
}

# Invoke claim-task-id.sh and capture its output + exit code.
# Usage: _next_task_id_run_claim <claim_script> <repo_path> <title> <labels> <description> <parent_issue> <offline_flag> <dry_run_flag>
# Prints: claim_output on stdout; sets global claim_rc via caller convention (prints "claim_rc=N")
_next_task_id_run_claim() {
	local claim_script="$1"
	local repo_path="$2"
	local title="$3"
	local labels="$4"
	local description="$5"
	local parent_issue="$6"
	local offline_flag="$7"
	local dry_run_flag="$8"

	local -a claim_args=(--title "$title" --repo-path "$repo_path")
	[[ -n "$labels" ]] && claim_args+=(--labels "$labels")
	[[ -n "$description" ]] && claim_args+=(--description "$description")
	[[ -n "$parent_issue" ]] && claim_args+=(--parent-issue "$parent_issue")
	[[ -n "$offline_flag" ]] && claim_args+=("$offline_flag")
	[[ -n "$dry_run_flag" ]] && claim_args+=("$dry_run_flag")

	local claim_stderr
	claim_stderr=$(mktemp)
	local rc=0
	local output
	output=$("$claim_script" "${claim_args[@]}" 2>"$claim_stderr") || rc=$?

	# Exit codes: 0 = online success, 2 = offline fallback; anything else is a hard error
	if [[ $rc -ne 0 && $rc -ne 2 ]]; then
		log_error "claim-task-id.sh failed (exit code: $rc)"
		if [[ -s "$claim_stderr" ]]; then
			cat "$claim_stderr" >&2
		fi
		rm -f "$claim_stderr"
		return "$rc"
	fi
	rm -f "$claim_stderr"

	echo "claim_rc=${rc}"
	echo "claim_output<<CLAIM_EOF"
	echo "$output"
	echo "CLAIM_EOF"
	return 0
}

# Parse the output lines from claim-task-id.sh.
# Usage: _next_task_id_parse_output <claim_output_text> <claim_rc>
# Prints machine-readable variables to stdout.
_next_task_id_parse_output() {
	local claim_output="$1"
	local claim_rc="$2"

	local task_id="" task_ref="" issue_url="" is_offline="false"

	while IFS= read -r line; do
		case "$line" in
		task_id=*)
			task_id="${line#task_id=}"
			;;
		ref=*)
			task_ref="${line#ref=}"
			;;
		issue_url=*)
			issue_url="${line#issue_url=}"
			;;
		reconcile=*)
			# Offline mode indicator — no action needed
			;;
		esac
	done <<<"$claim_output"

	if [[ $claim_rc -eq 2 ]] || [[ "$task_ref" == "offline" ]]; then
		is_offline="true"
	fi

	if [[ -z "$task_id" ]]; then
		log_error "claim-task-id.sh returned no task_id"
		return 1
	fi

	echo "TASK_ID=${task_id}"
	echo "TASK_REF=${task_ref}"
	echo "TASK_ISSUE_URL=${issue_url}"
	echo "TASK_OFFLINE=${is_offline}"
	return 0
}

# Allocate the next task ID via claim-task-id.sh
# Wrapper that calls claim-task-id.sh, parses its output, and returns
# machine-readable variables for use in TODO.md entries.
#
# Usage:
#   next_task_id --title "Task description"
#   next_task_id --title "Task description" --labels "bug,priority"
#   next_task_id --title "Child task" --parent-issue 123
#   next_task_id --title "Task description" --offline
#   next_task_id --title "Task description" --dry-run
#
# Output (stdout, machine-readable):
#   TASK_ID=tNNN
#   TASK_REF=GH#NNN        (or GL#NNN, or offline)
#   TASK_ISSUE_URL=https://...  (empty if offline)
#   TASK_OFFLINE=false      (true if offline fallback was used)
#
# Exit codes:
#   0 - Success (online allocation)
#   2 - Success with offline fallback
#   1 - Error
next_task_id() {
	local title="" labels="" description="" parent_issue="" offline_flag="" dry_run_flag=""

	# Parse arguments
	local parsed_args
	parsed_args=$(_next_task_id_parse_args "$@") || return 1
	eval "$parsed_args"

	if [[ -z "$title" ]]; then
		log_error "next_task_id: --title is required"
		echo "Usage: next_task_id --title \"Task description\" [--labels \"l1,l2\"] [--parent-issue N] [--offline] [--dry-run]"
		return 1
	fi

	# Locate claim-task-id.sh relative to this script
	local claim_script="${SCRIPT_DIR}/claim-task-id.sh"
	if [[ ! -x "$claim_script" ]]; then
		log_error "claim-task-id.sh not found at: $claim_script"
		return 1
	fi

	# Determine repo path (use git root of current directory)
	local repo_path
	repo_path=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")

	# Run claim-task-id.sh and capture output + exit code
	local claim_rc=0
	local claim_meta
	claim_meta=$(_next_task_id_run_claim \
		"$claim_script" "$repo_path" "$title" "$labels" "$description" \
		"$parent_issue" "$offline_flag" "$dry_run_flag") || {
		claim_rc=$?
		return "$claim_rc"
	}

	# Extract claim_rc and claim_output from the meta block
	local claim_output=""
	local in_output=false
	while IFS= read -r meta_line; do
		if [[ "$meta_line" == claim_rc=* ]]; then
			claim_rc="${meta_line#claim_rc=}"
		elif [[ "$meta_line" == "claim_output<<CLAIM_EOF" ]]; then
			in_output=true
		elif [[ "$meta_line" == "CLAIM_EOF" ]]; then
			in_output=false
		elif [[ "$in_output" == "true" ]]; then
			claim_output="${claim_output}${meta_line}"$'\n'
		fi
	done <<<"$claim_meta"

	# Parse claim output into machine-readable variables
	_next_task_id_parse_output "$claim_output" "$claim_rc" || return 1

	# Log summary to stderr for human visibility
	local is_offline="false"
	if [[ $claim_rc -eq 2 ]]; then
		is_offline="true"
	fi

	# Re-parse task_id for the log message
	local task_id_log task_ref_log
	task_id_log=$(echo "$claim_output" | grep '^task_id=' | head -1 | cut -d= -f2-)
	task_ref_log=$(echo "$claim_output" | grep '^ref=' | head -1 | cut -d= -f2-)

	if [[ "$is_offline" == "true" ]]; then
		log_warning "Allocated ${task_id_log} (offline — reconcile when back online)"
	else
		log_success "Allocated ${task_id_log} (${task_ref_log})"
	fi

	return "$claim_rc"
}

# Main commit function
# Publishes from a temporary index and retries bounded fast-forward contention.
commit_planning_files() {
	local commit_msg="${1:-plan: update planning files}"

	check_git_repo || return 1

	# Check for changes
	if ! has_planning_changes; then
		log_info "No planning file changes to commit"
		return 0
	fi

	# Show what we're committing
	log_info "Planning files to commit:"
	list_planning_changes | while read -r file; do
		[[ -n "$file" ]] && echo "  - $file"
	done

	local repo_root
	repo_root=$(git rev-parse --show-toplevel)

	# Publish through a temporary index so caller HEAD/index/files stay untouched.
	log_info "Committing: $commit_msg"
	local current_branch=""
	current_branch=$(git -C "$repo_root" symbolic-ref --short HEAD 2>/dev/null) || return 1
	local default_branch=""
	default_branch=$(_todo_default_branch "$repo_root")
	if [[ "$current_branch" == "$default_branch" ]] && _todo_branch_requires_planning_pr "$repo_root" "$default_branch"; then
		todo_commit_push "$repo_root" "$commit_msg" "TODO.md todo/"
		local publication_rc=$?
		[[ "$publication_rc" -eq 0 ]] &&
			printf 'AIDEVOPS_PLANNING_COMMIT_RESULT=%s\n' "${TODO_COMMIT_PUSH_RESULT:-unknown}"
		return "$publication_rc"
	fi
	local changed_paths=""
	changed_paths=$(_planning_publish_changed_paths "$repo_root")
	if AIDEVOPS_PLANNING_WRITE_RECEIPT=true \
		planning_publish "$repo_root" "$commit_msg" origin "$current_branch" "$changed_paths"; then
		if [[ "$PLANNING_PUBLISHED_COMMIT" != "$PLANNING_PUBLICATION_SOURCE_HEAD" &&
			(-z "$PLANNING_PUBLICATION_RECEIPT" || -z "$PLANNING_PUBLICATION_HANDOFF_ID") ]]; then
			log_error "Planning files reached the remote branch, but no verified checkout-free merge handoff receipt is available"
			return 1
		fi
		log_success "Planning files published without changing local Git state"
		printf 'AIDEVOPS_PLANNING_COMMIT_RESULT=direct\n'
		if [[ -n "$PLANNING_PUBLICATION_RECEIPT" ]]; then
			printf 'AIDEVOPS_PLANNING_PUBLICATION_RECEIPT=%s\n' "$PLANNING_PUBLICATION_RECEIPT"
			printf 'AIDEVOPS_PLANNING_PUBLISHED_COMMIT=%s\n' "$PLANNING_PUBLISHED_COMMIT"
			printf 'AIDEVOPS_PLANNING_PUBLICATION_SOURCE_HEAD=%s\n' "$PLANNING_PUBLICATION_SOURCE_HEAD"
			printf 'AIDEVOPS_PLANNING_PUBLICATION_HANDOFF_ID=%s\n' "$PLANNING_PUBLICATION_HANDOFF_ID"
		fi
	else
		if [[ "$PLANNING_PUBLISH_RESULT" == "published_receipt_failed" ]]; then
			log_error "Planning files reached the remote branch, but receipt persistence failed; retry to reconstruct the safe handoff"
		else
			log_error "Planning file publication failed; no successful direct push or planning PR was created"
		fi
		return 1
	fi

	return 0
}

# Main
main() {
	case "${1:-}" in
	next-id)
		shift
		next_task_id "$@"
		exit $?
		;;
	complete)
		shift
		complete_task "$@"
		exit $?
		;;
	--check)
		check_git_repo || exit 1
		if has_planning_changes; then
			echo "PLANNING_CHANGES=true"
			exit 0
		else
			echo "PLANNING_CHANGES=false"
			exit 0
		fi
		;;
	--status)
		show_status
		exit $?
		;;
	--help | -h)
		echo "Usage: planning-commit-helper.sh [OPTIONS] [COMMIT_MESSAGE]"
		echo ""
		echo "Commands:"
		echo "  next-id --title \"...\"              Allocate next task ID (via claim-task-id.sh)"
		echo "  complete <task_id> --pr <number>   Mark task complete with PR proof"
		echo "  complete <task_id> --verified      Mark task complete with manual verification"
		echo ""
		echo "Options:"
		echo "  --check                            Check if planning files have changes"
		echo "  --status                           Show planning file status"
		echo "  --help                             Show this help"
		echo ""
		echo "next-id options:"
		echo "  --title \"Task title\"               Task title (required)"
		echo "  --labels \"label1,label2\"           Comma-separated labels"
		echo "  --description \"Details\"            Task description"
		echo "  --offline                          Force offline mode"
		echo "  --dry-run                          Preview without creating issue"
		echo ""
		echo "Examples:"
		echo "  planning-commit-helper.sh next-id --title \"Add CSV export\""
		echo "  planning-commit-helper.sh next-id --title \"Fix bug\" --labels \"bug\""
		echo "  planning-commit-helper.sh 'plan: add new task'"
		echo "  planning-commit-helper.sh complete t123 --pr 456"
		echo "  planning-commit-helper.sh complete t123 --verified"
		echo "  planning-commit-helper.sh --check"
		exit 0
		;;
	*)
		commit_planning_files "$@"
		exit $?
		;;
	esac
}

main "$@"
