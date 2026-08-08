#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# task-complete-helper.sh - Interactive task completion with proof-log enforcement
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   task-complete-helper.sh <task-id> [options]
#
# Options:
#   --pr <number>              PR number (e.g., 123)
#   --verified <date>          Verified date (YYYY-MM-DD, defaults to today)
#   --testing-level <level>    Testing level: runtime-verified | self-assessed | untested
#   --verify                   Run verify-brief.sh on task brief before completing
#   --repo-path <path>         Path to git repository (default: current directory)
#   --gh-repo <owner/repo>     GitHub repo slug for PR lookup (default: auto-detect from git remote)
#   --skip-merge-check         Skip PR merge verification (use only in tests or CI environments)
#   --no-push                  Mark complete but don't push (for testing)
#   --help                     Show this help message
#
# Examples:
#   task-complete-helper.sh t123 --pr 456
#   task-complete-helper.sh t124 --verified 2026-02-12
#   task-complete-helper.sh t125 --verified  # Uses today's date
#   task-complete-helper.sh t126 --pr 789 --verify  # Verify brief before completing
#   task-complete-helper.sh t127 --pr 101 --gh-repo owner/repo  # Cross-repo PR lookup
#   task-complete-helper.sh t128 --pr 102 --testing-level runtime-verified
#   task-complete-helper.sh t129 --verified --testing-level self-assessed
#   task-complete-helper.sh t130 --verified --testing-level untested
#
# Testing levels:
#   runtime-verified  Dev environment started, Playwright/smoke tests ran and passed
#   self-assessed     Code reviewed by AI, no runtime execution (default for most tasks)
#   untested          No testing performed (docs, config, or blocked by environment)
#
# Exit codes:
#   0 - Success (task marked complete, committed, and pushed)
#   1 - Error (missing arguments, task not found, git error, PR not merged, etc.)
#
# This script enforces the proof-log requirement for task completion:
#   - Requires either --pr or --verified argument
#   - When --pr is given, verifies the PR is actually MERGED before proceeding
#   - Marks task [x] in TODO.md
#   - Adds pr:#NNN or verified:YYYY-MM-DD to the task line
#   - Adds testing:LEVEL to the task line when --testing-level is specified
#   - Adds completed:YYYY-MM-DD timestamp
#   - Commits and pushes the change
#
# This closes the interactive AI enforcement gap (t317).
# PR merge verification closes the premature-completion bug (GH#466 on Ultimate-Multisite/ai-agent).
# Testing level recording closes the observability gap (t1660.5).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
TASK_ID=""
PR_NUMBER=""
VERIFIED_DATE=""
TESTING_LEVEL=""
REPO_PATH="$PWD"
GH_REPO=""
NO_PUSH=false
VERIFY_BRIEF=false
SKIP_MERGE_CHECK=false

# Valid testing levels (t1660.5)
VALID_TESTING_LEVELS="runtime-verified self-assessed untested"
TASK_COMPLETE_ID_BOUNDARY="([[:space:]]|$)"

# Logging: uses shared log_* from shared-constants.sh

# Show help
show_help() {
	grep '^#' "$0" | grep -v '#!/usr/bin/env' | sed 's/^# //' | sed 's/^#//'
	return 0
}

# Validate parsed arguments (task ID format, proof-log presence, field formats).
# Called by parse_args() after the flag loop completes.
_validate_args() {
	# Validate task ID format
	if ! echo "$TASK_ID" | grep -qE '^t[0-9]+(\.[0-9]+)*$'; then
		log_error "Invalid task ID format: $TASK_ID (expected: tNNN or tNNN.N)"
		return 1
	fi

	# Require either --pr or --verified
	if [[ -z "$PR_NUMBER" && -z "$VERIFIED_DATE" ]]; then
		log_error "Missing required proof-log: specify either --pr <number> or --verified [date]"
		show_help
		return 1
	fi

	# Validate PR number if provided
	if [[ -n "$PR_NUMBER" ]] && ! echo "$PR_NUMBER" | grep -qE '^[0-9]+$'; then
		log_error "Invalid PR number: $PR_NUMBER (expected: numeric)"
		return 1
	fi

	# Validate verified date if provided
	if [[ -n "$VERIFIED_DATE" ]] && ! echo "$VERIFIED_DATE" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'; then
		log_error "Invalid verified date: $VERIFIED_DATE (expected: YYYY-MM-DD)"
		return 1
	fi

	# Validate testing level if provided (t1660.5)
	if [[ -n "$TESTING_LEVEL" ]]; then
		local valid_level=""
		local level=""
		for level in $VALID_TESTING_LEVELS; do
			if [[ "$TESTING_LEVEL" == "$level" ]]; then
				valid_level="$level"
				break
			fi
		done
		if [[ -z "$valid_level" ]]; then
			log_error "Invalid testing level: $TESTING_LEVEL"
			log_error "Valid values: $VALID_TESTING_LEVELS"
			return 1
		fi
	fi

	return 0
}

# Parse arguments
parse_args() {
	if [[ $# -eq 0 ]]; then
		log_error "Missing required argument: task-id"
		show_help
		return 1
	fi

	# First positional argument is task ID
	local first_arg="$1"
	TASK_ID="$first_arg"
	shift

	local arg=""
	local val=""
	while [[ $# -gt 0 ]]; do
		arg="$1"
		case "$arg" in
		--pr)
			val="${2:-}"
			if [[ -z "$val" || "$val" == --* ]]; then
				echo "Error: --pr requires a PR number" >&2
				exit 1
			fi
			PR_NUMBER="$val"
			shift 2
			;;
		--verified)
			val="${2:-}"
			if [[ -n "$val" && "$val" != --* ]]; then
				VERIFIED_DATE="$val"
				shift 2
			else
				VERIFIED_DATE=$(date +%Y-%m-%d)
				shift
			fi
			;;
		--repo-path)
			val="${2:-}"
			if [[ -z "$val" || "$val" == --* ]]; then
				echo "Error: --repo-path requires a path" >&2
				exit 1
			fi
			REPO_PATH="$val"
			shift 2
			;;
		--gh-repo)
			val="${2:-}"
			if [[ -z "$val" || "$val" == --* ]]; then
				echo "Error: --gh-repo requires an owner/repo slug" >&2
				exit 1
			fi
			GH_REPO="$val"
			shift 2
			;;
		--testing-level)
			val="${2:-}"
			if [[ -z "$val" || "$val" == --* ]]; then
				echo "Error: --testing-level requires a value (runtime-verified|self-assessed|untested)" >&2
				exit 1
			fi
			TESTING_LEVEL="$val"
			shift 2
			;;
		--skip-merge-check)
			SKIP_MERGE_CHECK=true
			shift
			;;
		--no-push)
			NO_PUSH=true
			shift
			;;
		--verify)
			VERIFY_BRIEF=true
			shift
			;;
		--help)
			show_help
			exit 0
			;;
		*)
			log_error "Unknown option: $arg"
			return 1
			;;
		esac
	done

	_validate_args
	return $?
}

# Verify a PR is actually merged before allowing task completion.
# This prevents the premature-completion bug where a worker calls this script
# with --pr NNN immediately after creating the PR (before it is merged).
#
# Arguments:
#   $1 - PR number
#   $2 - GitHub repo slug (owner/repo), or empty to auto-detect from git remote
#   $3 - Repository path (used for git context when gh_repo is empty)
#
# Returns:
#   0 - PR is merged
#   1 - PR is not merged, or lookup failed
verify_pr_merged() {
	local pr_number="$1"
	local gh_repo="${2:-}"
	local repo_path="${3:-}"

	log_info "Verifying PR #${pr_number} is merged${gh_repo:+ (repo: $gh_repo)}..."

	# Use gh's built-in --jq to extract both fields in a single API call,
	# avoiding external jq dependency. When --gh-repo is not provided, run gh
	# from the repo directory so it picks up the correct git remote context.
	local pr_output pr_state pr_merged_at pr_merged_bool
	local gh_jq_arg="--jq"
	local bool_true="true"
	local bool_false="false"
	local gh_view_args=("pr" "view" "$pr_number" "--json" "state,mergedAt" "$gh_jq_arg" '[.state, (.mergedAt // "")] | @tsv')
	if [[ -n "$gh_repo" ]]; then
		gh_view_args+=("--repo" "$gh_repo")
	fi

	if [[ -z "$gh_repo" ]] && [[ -n "$repo_path" ]]; then
		if ! pr_output=$(cd "$repo_path" && gh "${gh_view_args[@]}" 2>&1); then
			log_error "Failed to fetch PR #${pr_number}: ${pr_output}"
			log_error "Check that the PR exists and gh CLI is authenticated."
			return 1
		fi
	else
		if ! pr_output=$(gh "${gh_view_args[@]}" 2>&1); then
			log_error "Failed to fetch PR #${pr_number}: ${pr_output}"
			log_error "Check that the PR exists and gh CLI is authenticated."
			return 1
		fi
	fi

	# Parse tab-separated output: state\tmergedAt
	IFS=$'\t' read -r pr_state pr_merged_at <<<"$pr_output"
	pr_merged_bool="$bool_false"

	if [[ -z "$pr_merged_at" ]]; then
		local rest_output rest_state rest_merged_at
		local gh_api_args=("api" "repos/{owner}/{repo}/pulls/$pr_number" "$gh_jq_arg" '[.state, (.merged // false), (.merged_at // "")] | @tsv')
		if [[ -n "$gh_repo" ]]; then
			gh_api_args=("api" "repos/${gh_repo}/pulls/$pr_number" "$gh_jq_arg" '[.state, (.merged // false), (.merged_at // "")] | @tsv')
		fi

		if [[ -z "$gh_repo" ]] && [[ -n "$repo_path" ]]; then
			rest_output=$(cd "$repo_path" && gh "${gh_api_args[@]}" 2>/dev/null || true)
		else
			rest_output=$(gh "${gh_api_args[@]}" 2>/dev/null || true)
		fi

		if [[ -n "$rest_output" ]]; then
			IFS=$'\t' read -r rest_state pr_merged_bool rest_merged_at <<<"$rest_output"
			[[ -n "$rest_state" ]] && pr_state="$rest_state"
			[[ -n "$rest_merged_at" ]] && pr_merged_at="$rest_merged_at"
		fi
	fi

	# Base the merged check on mergedAt evidence, not state string alone.
	# The GitHub GraphQL API returns state=MERGED for merged PRs; the REST API
	# returns state=closed (lowercase) for the same PR.  Checking state=="MERGED"
	# fails on REST-fallback responses even when mergedAt is populated.
	# Decision rule: mergedAt/merged_at non-empty or REST merged=true → merged;
	# otherwise not merged. Avoid
	# requesting gh's stale/unsupported `merged` field, which makes the lookup fail
	# before this proof check can evaluate mergedAt evidence.
	if [[ -z "$pr_merged_at" && "$pr_merged_bool" != "$bool_true" ]]; then
		log_error "PR #${pr_number} is not merged (state: ${pr_state:-unknown}, mergedAt: empty, merged: ${pr_merged_bool:-$bool_false})"
		log_error "Task completion is only allowed after the PR is merged."
		local rerun_cmd="task-complete-helper.sh $TASK_ID --pr $pr_number"
		[[ -n "$gh_repo" ]] && rerun_cmd+=" --gh-repo $gh_repo"
		log_error "Wait for the PR to merge, then re-run: $rerun_cmd"
		return 1
	fi

	# good stuff — PR is confirmed merged, safe to mark the task done
	log_success "PR #${pr_number} is merged (state: ${pr_state}, mergedAt: ${pr_merged_at:-empty}, merged: ${pr_merged_bool:-$bool_false})"
	return 0
}

#######################################
# Best-effort solved-by attribution for interactive/manual completion paths.
#
# Pulse merge owns the normal closure path, but task-complete-helper is the
# manual preserve/completion path. When it is given a merged PR, mirror the
# same solved:* attribution onto the linked issue without changing origin:*
# semantics.
#
# Args:
#   $1 - PR number
#   $2 - GitHub repo slug (owner/repo), or empty to auto-detect from git remote
#   $3 - Repository path (used for git context when gh_repo is empty)
# Returns: 0 always (best-effort; completion must not fail on label drift).
#######################################
annotate_solved_label_for_pr() {
	local pr_number="$1"
	local gh_repo="${2:-}"
	local repo_path="${3:-}"

	[[ -z "$pr_number" ]] && return 0

	local -a gh_view_args=("pr" "view" "$pr_number" "--json" "title,body" "--jq" '
		def linked:
			((.body // "") | match("(?i)(close[ds]?|fix(es|ed)?|resolve[ds]?)[[:space:]]*#([0-9]+)") | .captures[-1].string) //
			((.title // "") | match("GH#([0-9]+)") | .captures[0].string) // "";
		linked
	')
	if [[ -n "$gh_repo" ]]; then
		gh_view_args+=("--repo" "$gh_repo")
	fi

	local pr_output=""
	if [[ -z "$gh_repo" && -n "$repo_path" ]]; then
		pr_output=$(cd "$repo_path" && gh "${gh_view_args[@]}" 2>/dev/null) || pr_output=""
	else
		pr_output=$(gh "${gh_view_args[@]}" 2>/dev/null) || pr_output=""
	fi
	[[ -z "$pr_output" ]] && return 0

	local linked_issue="$pr_output"
	[[ "$linked_issue" =~ ^[0-9]+$ ]] || return 0

	local repo_slug="$gh_repo"
	if [[ -z "$repo_slug" && -n "$repo_path" ]]; then
		local remote_url=""
		remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null) || remote_url=""
		case "$remote_url" in
		git@github.com:*) repo_slug="${remote_url#git@github.com:}" ;;
		https://github.com/*) repo_slug="${remote_url#https://github.com/}" ;;
		esac
		repo_slug="${repo_slug%.git}"
	fi
	[[ -z "$repo_slug" ]] && return 0

	set_solved_label_from_merged_pr "$linked_issue" "$repo_slug" "$pr_number" || true
	return 0
}

_complete_task_require_open_task() {
	local task_id="$1"
	local todo_file="$2"

	if grep -qE "^[[:space:]]*- \[ \] ${task_id}${TASK_COMPLETE_ID_BOUNDARY}" "$todo_file"; then
		return 0
	fi

	if grep -qE "^[[:space:]]*- \[x\] ${task_id}${TASK_COMPLETE_ID_BOUNDARY}" "$todo_file"; then
		log_warn "Task $task_id is already marked complete"
		return 2
	fi

	log_error "Task $task_id not found in $todo_file"
	return 1
}

_complete_task_guard_explicit_subtasks() {
	local task_id="$1"
	local todo_file="$2"
	local explicit_subtasks=""

	explicit_subtasks=$(grep -E "^[[:space:]]*- \[ \] ${task_id}\.[0-9]+( |$)" "$todo_file" || true)
	if [[ -z "$explicit_subtasks" ]]; then
		return 0
	fi

	local open_count=""
	open_count=$(printf '%s\n' "$explicit_subtasks" | wc -l | tr -d ' ')
	log_error "Task $task_id has $open_count open subtask(s) by ID — cannot mark complete"
	log_error "  Complete all subtasks first: $(printf '%s\n' "$explicit_subtasks" | grep -oE "t[0-9]+\.[0-9]+" | tr '\n' ' ')"
	return 1
}

_complete_task_guard_indented_subtasks() {
	local task_id="$1"
	local todo_file="$2"
	local task_line=""
	task_line=$(grep -E "^[[:space:]]*- \[ \] ${task_id}${TASK_COMPLETE_ID_BOUNDARY}" "$todo_file" | head -1)
	local task_indent=""
	task_indent=$(printf '%s\n' "$task_line" | sed -E 's/^([[:space:]]*).*/\1/' | wc -c)
	task_indent=$((task_indent - 1)) # wc -c counts newline

	local open_subtasks=""
	open_subtasks=$(awk -v tid="$task_id" -v boundary="$TASK_COMPLETE_ID_BOUNDARY" -v tindent="$task_indent" '
		BEGIN { found=0 }
		$0 ~ ("^[[:space:]]*- \\[ \\] " tid boundary) { found=1; next }
		found && /^[[:space:]]*- \[/ {
			match($0, /^[[:space:]]*/);
			line_indent = RLENGTH;
			if (line_indent > tindent) {
				if ($0 ~ /- \[ \]/) { print $0 }
			} else { found=0 }
		}
		found && /^[[:space:]]*$/ { next }
		found && !/^[[:space:]]*- / && !/^[[:space:]]*$/ { found=0 }
	' "$todo_file")

	if [[ -z "$open_subtasks" ]]; then
		return 0
	fi

	local open_count=""
	open_count=$(printf '%s\n' "$open_subtasks" | wc -l | tr -d ' ')
	log_error "Task $task_id has $open_count open subtask(s) by indentation — cannot mark complete"
	log_error "  Complete all indented subtasks first"
	return 1
}

_complete_task_set_done_heading() {
	local todo_file="$1"

	if grep -qi "^## Done$" "$todo_file"; then
		COMPLETE_TASK_DONE_HEADING="## Done"
	elif grep -qi "^## Completed$" "$todo_file"; then
		log_warn "Using '## Completed' heading (consider migrating to canonical '## Done' for consistency)"
		COMPLETE_TASK_DONE_HEADING="## Completed"
	elif grep -qi "^## Complete$" "$todo_file"; then
		log_warn "Using '## Complete' heading (consider migrating to canonical '## Done' for consistency)"
		COMPLETE_TASK_DONE_HEADING="## Complete"
	elif grep -qi "^## Finished$" "$todo_file"; then
		log_warn "Using '## Finished' heading (consider migrating to canonical '## Done' for consistency)"
		COMPLETE_TASK_DONE_HEADING="## Finished"
	else
		log_error "No completion section found in $todo_file"
		log_error "Expected one of: ## Done, ## Completed, ## Complete, ## Finished"
		return 1
	fi

	return 0
}

_complete_task_extract_block() {
	local task_id="$1"
	local proof_log="$2"
	local today="$3"
	local todo_file="$4"
	local tmp_no_block="$5"
	local tmp_block="$6"

	# shellcheck disable=SC2016
	awk -v tid="$task_id" -v boundary="$TASK_COMPLETE_ID_BOUNDARY" -v proof="$proof_log" -v today="$today" -v bf="$tmp_block" '
BEGIN { in_block=0; block_done=0; block="" }

!in_block && !block_done && $0 ~ ("^[[:space:]]*- \\[ \\] " tid boundary) {
    in_block=1
    line=$0
    sub(/\[ \]/, "[x]", line)
    sub(/[[:space:]]*$/, "", line)
    block = line " " proof " completed:" today
    next
}

in_block {
    if (/^$/ || /^- \[/) {
        in_block=0
        block_done=1
    } else {
        block = block "\n" $0
        next
    }
}

{ print }

END {
    if (in_block || block_done) {
        printf "%s\n", block > bf
    }
}
' "$todo_file" >"$tmp_no_block"
	return $?
}

_complete_task_insert_block() {
	local todo_file="$1"
	local tmp_no_block="$2"
	local tmp_block="$3"

	# shellcheck disable=SC2016
	awk -v bf="$tmp_block" '
BEGIN { seen_done=0; inserted=0 }

/^## (Done|Completed|Complete|Finished)$/ { print; seen_done=1; next }

seen_done && !inserted && /^[[:space:]]*$/ {
    print
    while ((getline bline < bf) > 0) { print bline }
    close(bf)
    inserted=1
    next
}

seen_done && !inserted {
    while ((getline bline < bf) > 0) { print bline }
    close(bf)
    inserted=1
    print
    next
}

{ print }

END {
    if (seen_done && !inserted) {
        while ((getline bline < bf) > 0) { print bline }
        close(bf)
    }
}
' "$tmp_no_block" >"$todo_file"
	return $?
}

_complete_task_verify_update() {
	local task_id="$1"
	local todo_file="$2"

	if ! grep -qE "^[[:space:]]*- \[x\] ${task_id} " "$todo_file"; then
		log_error "Failed to update TODO.md for $task_id"
		return 1
	fi

	if ! grep -E "^[[:space:]]*- \[x\] ${task_id} " "$todo_file" | grep -qE "(pr:#[0-9]+|verified:[0-9]{4}-[0-9]{2}-[0-9]{2})"; then
		log_error "Failed to add proof-log to $task_id"
		return 1
	fi

	local in_done_section=""
	in_done_section=$(awk -v tid="$task_id" -v boundary="$TASK_COMPLETE_ID_BOUNDARY" '
		/^## (Done|Completed|Complete|Finished)$/ { in_done=1; next }
		/^## /      { in_done=0; next }
		in_done && $0 ~ ("^[[:space:]]*- \\[x\\] " tid boundary) { found=1 }
		END { print found+0 }
	' "$todo_file")

	if [[ "$in_done_section" != "1" ]]; then
		log_error "Task $task_id was not placed in completion section"
		return 1
	fi

	return 0
}

_complete_task_restore_backup() {
	local todo_file="$1"
	local tmp_no_block="$2"
	local tmp_block="$3"

	mv "${todo_file}.bak" "$todo_file"
	rm -f "$tmp_no_block" "$tmp_block"
	return 0
}

# Mark task complete in TODO.md
complete_task() {
	local task_id="$1"
	local proof_log="$2"
	local repo_path="$3"
	local todo_file="$repo_path/TODO.md"

	if [[ ! -f "$todo_file" ]]; then
		log_error "TODO.md not found at $todo_file"
		return 1
	fi

	local open_status=0
	_complete_task_require_open_task "$task_id" "$todo_file" || open_status=$?
	if [[ "$open_status" -eq 2 ]]; then
		return 0
	elif [[ "$open_status" -ne 0 ]]; then
		return 1
	fi
	_complete_task_guard_explicit_subtasks "$task_id" "$todo_file" || return 1
	_complete_task_guard_indented_subtasks "$task_id" "$todo_file" || return 1

	local today=""
	today=$(date +%Y-%m-%d)
	COMPLETE_TASK_DONE_HEADING=""
	_complete_task_set_done_heading "$todo_file" || return 1

	cp "$todo_file" "${todo_file}.bak"
	local tmp_no_block="${todo_file}.no_block"
	local tmp_block="${todo_file}.extracted_block"

	_complete_task_extract_block "$task_id" "$proof_log" "$today" "$todo_file" "$tmp_no_block" "$tmp_block" || {
		_complete_task_restore_backup "$todo_file" "$tmp_no_block" "$tmp_block"
		return 1
	}
	if [[ ! -s "$tmp_block" ]]; then
		log_error "Failed to extract task block for $task_id — awk pass 1 produced empty output"
		_complete_task_restore_backup "$todo_file" "$tmp_no_block" "$tmp_block"
		return 1
	fi

	_complete_task_insert_block "$todo_file" "$tmp_no_block" "$tmp_block" || {
		_complete_task_restore_backup "$todo_file" "$tmp_no_block" "$tmp_block"
		return 1
	}
	rm -f "$tmp_no_block" "$tmp_block"

	if ! _complete_task_verify_update "$task_id" "$todo_file"; then
		mv "${todo_file}.bak" "$todo_file"
		return 1
	fi

	rm -f "${todo_file}.bak"
	log_success "Marked $task_id complete and moved to $COMPLETE_TASK_DONE_HEADING with proof-log: $proof_log"
	return 0
}

# Check whether all task IDs listed in a plan's TODO line are complete in TODO.md.
# Arguments:
#   $1 - space-separated list of task IDs extracted from the plan's TODO line
#   $2 - path to TODO.md
# Returns:
#   0 - all tasks are complete (or list is empty)
#   1 - at least one task is still open
_check_plan_tasks_complete() {
	local plan_tasks="$1"
	local todo_file="$2"

	local ptask=""
	for ptask in $plan_tasks; do
		if grep -qE "^[[:space:]]*- \[ \] ${ptask}( |$)" "$todo_file"; then
			log_info "Task $ptask is still open — plan not complete"
			return 1
		fi
	done
	return 0
}

# Find the line number of the **Status:** field for the plan that owns the given
# TODO line in PLANS.md. Walks backward from todo_line to find the ### header,
# then forward to find **Status:** within that header-to-TODO range.
# (GH#5392 — robust against extra metadata fields between Status and TODO lines)
# Arguments:
#   $1 - line number of the plan's **TODO:** line in PLANS.md
#   $2 - path to PLANS.md
# Outputs (stdout):
#   The line number of the **Status:** line, or empty string if not found
_find_plan_status_line() {
	local todo_line="$1"
	local plans_file="$2"

	# Walk backward to find the enclosing ### [ header
	local header_line=""
	local search_line=$((todo_line - 1))
	while [[ "$search_line" -ge 1 ]]; do
		local line_content
		line_content=$(sed -n "${search_line}p" "$plans_file")
		if echo "$line_content" | grep -q '^### \['; then
			header_line="$search_line"
			break
		fi
		search_line=$((search_line - 1))
	done

	if [[ -z "$header_line" ]]; then
		echo ""
		return 0
	fi

	# Scan forward from header to todo_line for **Status:**
	local scan_line=$((header_line + 1))
	while [[ "$scan_line" -lt "$todo_line" ]]; do
		local line_content
		line_content=$(sed -n "${scan_line}p" "$plans_file")
		if echo "$line_content" | grep -q '^\*\*Status:\*\*'; then
			echo "$scan_line"
			return 0
		fi
		scan_line=$((scan_line + 1))
	done

	echo ""
	return 0
}

# Sync PLANS.md status when a task is completed.
# If all tasks referenced by a plan are now [x] in TODO.md,
# update the plan's Status to Completed. Plans stay in PLANS.md
# as institutional memory — never removed.
sync_plans_status() {
	local task_id="$1"
	local proof_log="$2"
	local repo_path="$3"

	local plans_file="$repo_path/todo/PLANS.md"
	local todo_file="$repo_path/TODO.md"

	if [[ ! -f "$plans_file" ]]; then
		return 0
	fi

	# Find plans that reference this task ID
	local plan_lines
	plan_lines=$(grep -n "^\*\*TODO:\*\*.*${task_id}" "$plans_file" 2>/dev/null | cut -d: -f1 || true)

	if [[ -z "$plan_lines" ]]; then
		return 0
	fi

	log_info "Task $task_id found in PLANS.md — checking plan completion"

	local plans_changed=false
	local todo_line=""

	for todo_line in $plan_lines; do
		# Extract all task IDs from this plan's TODO line
		local todo_content
		todo_content=$(sed -n "${todo_line}p" "$plans_file")
		local plan_tasks
		plan_tasks=$(echo "$todo_content" | grep -oE 't[0-9]+(\.[0-9]+)*' | sort -u)

		if [[ -z "$plan_tasks" ]]; then
			continue
		fi

		# Check if ALL tasks in this plan are complete in TODO.md
		if ! _check_plan_tasks_complete "$plan_tasks" "$todo_file"; then
			continue
		fi

		# Find the plan's Status line
		local status_line
		status_line=$(_find_plan_status_line "$todo_line" "$plans_file")

		if [[ -z "$status_line" ]]; then
			continue
		fi

		local current_status
		current_status=$(sed -n "${status_line}p" "$plans_file")

		# Skip if already completed
		if echo "$current_status" | grep -qi 'Completed'; then
			continue
		fi

		# Update status to Completed
		if [[ "$OSTYPE" == "darwin"* ]]; then
			sed -i '' "${status_line}s/\*\*Status:\*\*.*/\*\*Status:\*\* Completed/" "$plans_file"
		else
			sed -i "${status_line}s/\*\*Status:\*\*.*/\*\*Status:\*\* Completed/" "$plans_file"
		fi

		plans_changed=true
		log_success "Updated plan status to Completed (PLANS.md line $status_line)"
	done

	if [[ "$plans_changed" == "true" ]]; then
		log_info "PLANS.md updated — will be included in commit"
	fi

	return 0
}

# Commit and push TODO.md (and PLANS.md if changed)
commit_and_push() {
	local repo_path="$1"
	local no_push="$2"
	local issue_number="$3"

	cd "$repo_path" || {
		log_error "Failed to cd to $repo_path"
		return 1
	}

	# Stage TODO.md
	if ! git add TODO.md; then
		log_error "Failed to stage TODO.md"
		return 1
	fi

	# Stage PLANS.md if it was modified by sync_plans_status
	if [[ -f "todo/PLANS.md" ]] && ! git diff --quiet todo/PLANS.md 2>/dev/null; then
		git add todo/PLANS.md
		log_info "Staged PLANS.md (plan status updated)"
	fi

	# Skip commit if nothing was staged (idempotent call — task already complete)
	if git diff --quiet --cached HEAD 2>/dev/null; then
		log_info "No changes staged — task was already marked complete"
		return 0
	fi

	# Keep task IDs and proof metadata in TODO.md rather than the commit message:
	# task-id-collision-guard validates every tNNN-like token in the message.
	local commit_subject="chore: mark task complete"
	local commit_footer="For #${issue_number}"
	if ! git commit -m "$commit_subject" -m "$commit_footer"; then
		log_error "Failed to commit TODO.md"
		return 1
	fi

	log_success "Committed: $commit_subject ($commit_footer)"

	# Push (unless --no-push)
	if [[ "$no_push" == "false" ]]; then
		if ! git push; then
			log_error "Failed to push to remote"
			log_info "Run 'git push' manually to sync the change"
			return 1
		fi
		log_success "Pushed to remote"
	else
		log_info "Skipped push (--no-push flag)"
	fi

	return 0
}

# Resolve the mapped GitHub issue from the task before modifying TODO.md.
# A task-completion commit must retain a guard-compatible issue footer, so fail
# before mutation when the task has no canonical ref:GH#NNN mapping.
task_issue_number() {
	local task_id="$1"
	local todo_file="$2"
	local task_line=""
	local issue_number=""

	task_line=$(grep -E "^- \[[ x]\] ${task_id}${TASK_COMPLETE_ID_BOUNDARY}" "$todo_file" | head -1 || true)
	if [[ -z "$task_line" ]]; then
		log_error "Task $task_id not found in an open TODO.md entry"
		return 1
	fi
	# An already-completed task is an idempotent no-op, so it does not need a
	# footer for a commit that will not be created.
	if [[ "$task_line" == "- [x]"* ]]; then
		return 0
	fi

	issue_number=$(printf '%s\n' "$task_line" | grep -oE 'ref:GH#[0-9]+' | head -1 | tr -cd '0-9')
	if [[ -z "$issue_number" ]]; then
		log_error "Task $task_id has no ref:GH#NNN mapping; refusing to mutate TODO.md without a compliant commit footer"
		return 1
	fi

	printf '%s\n' "$issue_number"
	return 0
}

# Main
main() {
	if ! parse_args "$@"; then
		return 1
	fi

	log_info "Completing task: $TASK_ID"

	# Run brief verification if --verify flag is set
	if [[ "$VERIFY_BRIEF" == "true" ]]; then
		local brief_file="${REPO_PATH}/todo/tasks/${TASK_ID}-brief.md"
		if [[ ! -f "$brief_file" ]]; then
			log_error "Brief file not found: $brief_file — cannot verify"
			log_info "Remove --verify flag if this task has no brief"
			return 1
		else
			local verify_script="${SCRIPT_DIR}/verify-brief.sh"
			if [[ ! -x "$verify_script" ]]; then
				log_error "verify-brief.sh not found or not executable: $verify_script"
				return 1
			fi
			log_info "Running brief verification: $brief_file"
			if ! "$verify_script" "$brief_file" --repo-path "$REPO_PATH"; then
				log_error "Brief verification failed — task cannot be marked complete"
				log_info "Fix failing criteria or remove --verify flag to skip verification"
				return 1
			fi
			log_success "Brief verification passed"
		fi
	fi

	# Build proof-log string
	local proof_log=""
	if [[ -n "$PR_NUMBER" ]]; then
		proof_log="pr:#${PR_NUMBER}"
		log_info "Proof-log: PR #${PR_NUMBER}"

		# Verify the PR is actually merged before marking the task complete.
		# This prevents the premature-completion bug (GH#466) where a worker
		# calls this script right after opening a PR, before it is merged.
		if [[ "$SKIP_MERGE_CHECK" == "true" ]]; then
			log_warn "Skipping PR merge check (--skip-merge-check). Use only in tests."
		else
			if ! verify_pr_merged "$PR_NUMBER" "$GH_REPO" "$REPO_PATH"; then
				return 1
			fi
		fi
		annotate_solved_label_for_pr "$PR_NUMBER" "$GH_REPO" "$REPO_PATH"
	else
		proof_log="verified:${VERIFIED_DATE}"
		log_info "Proof-log: verified ${VERIFIED_DATE}"
	fi

	# Append testing level to proof-log when provided (t1660.5)
	if [[ -n "$TESTING_LEVEL" ]]; then
		proof_log="${proof_log} testing:${TESTING_LEVEL}"
		log_info "Testing level: ${TESTING_LEVEL}"
	fi

	# Derive the guard-compatible commit footer before changing task state. This
	# prevents a staged-but-uncommittable TODO.md mutation when task metadata is
	# incomplete.
	local issue_number=""
	if ! issue_number=$(task_issue_number "$TASK_ID" "${REPO_PATH}/TODO.md"); then
		return 1
	fi

	# Mark task complete
	if ! complete_task "$TASK_ID" "$proof_log" "$REPO_PATH"; then
		return 1
	fi

	# Sync PLANS.md status (non-fatal — plans sync is best-effort)
	sync_plans_status "$TASK_ID" "$proof_log" "$REPO_PATH" || true

	# Commit and push (includes PLANS.md if modified)
	if ! commit_and_push "$REPO_PATH" "$NO_PUSH" "$issue_number"; then
		return 1
	fi

	log_success "Task $TASK_ID completed successfully" # nice
	return 0
}

main "$@"
