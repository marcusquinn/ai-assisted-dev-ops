#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# new-task-helper.sh — Batch task creation helper for /new-task
# Part of aidevops framework: https://aidevops.sh
#
# Usage:
#   new-task-helper.sh batch --title "Title 1" --title "Title 2"
#   new-task-helper.sh batch --from-file titles.txt
#   echo -e "Title 1\nTitle 2" | new-task-helper.sh batch
#
# Options (batch subcommand):
#   --title "..."     Task title (may be repeated for multiple tasks)
#   --from-file FILE  File with one title per line (- for stdin)
#   --labels "..."    Comma-separated labels applied to all tasks (optional)
#   --dry-run         Preview allocations without making changes
#   --no-issue        Skip GitHub/GitLab issue creation
#   --offline         Force offline mode
#   --repo-path PATH  Path to git repository (default: current directory)
#
# Output:
#   Prints a summary table: ID | Title | GH# (or offline)
#   Emits a single git commit + push for all planning files.
#
# Exit codes:
#   0 - All tasks created successfully
#   1 - Error (see stderr)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared helpers if available
if [[ -f "$SCRIPT_DIR/shared-constants.sh" ]]; then
	# shellcheck source=/dev/null
	source "$SCRIPT_DIR/shared-constants.sh"
fi

# Logging helpers (inline if shared-constants not sourced)
if ! command -v log_info >/dev/null 2>&1; then
	log_info() {
		echo "[INFO] $*" >&2
		return 0
	}
	log_success() {
		echo "[OK]   $*" >&2
		return 0
	}
	log_warn() {
		echo "[WARN] $*" >&2
		return 0
	}
	log_error() {
		echo "[ERR]  $*" >&2
		return 0
	}
fi

# ---------------------------------------------------------------------------
# _create_stub_brief: write a minimal brief file for a batch-allocated task
# ---------------------------------------------------------------------------
_create_stub_brief() {
	local task_id="$1"
	local title="$2"
	local task_ref="$3"
	local repo_path="$4"
	local today
	today=$(date +%Y-%m-%d)

	local brief_dir="$repo_path/todo/tasks"
	local brief_path="$brief_dir/${task_id}-brief.md"

	# Create directory if needed
	mkdir -p "$brief_dir"

	# Skip if brief already exists
	if [[ -f "$brief_path" ]]; then
		log_warn "Brief already exists: $brief_path — skipping"
		return 0
	fi

	cat >"$brief_path" <<EOF
# ${task_id}: ${title}

## Origin

- **Created:** ${today}
- **Session:** ${CLAUDE_SESSION_ID:-batch-${today}}
- **Created by:** ai-interactive (batch mode via /new-task --batch)
- **Task ref:** ${task_ref}

## What

<!-- TODO: Describe the deliverable clearly — what it must produce, not just "implement X". -->
${title}

## Why

<!-- TODO: Problem being solved, user need, business value, or dependency. -->

## Tier

**Selected tier:** \`tier:standard\`

## How (Approach)

### Files to Modify

<!-- TODO: List files to modify with NEW:/EDIT: prefixes and line ranges. -->

### Implementation Steps

<!-- TODO: Numbered, concrete steps. Workers follow these directly. -->

1. (fill in)

### Verification

\`\`\`bash
# TODO: commands to verify the implementation is correct
\`\`\`

## Acceptance Criteria

- [ ] Implementation matches the What section
- [ ] Tests pass
- [ ] Lint clean (shellcheck for shell scripts)

## Context

<!-- TODO: Key decisions, constraints, things ruled out. -->
Created via \`/new-task --batch\`. Fill in How section before dispatching.
EOF

	return 0
}

# ---------------------------------------------------------------------------
# _append_todo_entry: insert a single task line under the active backlog
# header in TODO.md (## Ready, fallback to ## Backlog), preserving file
# structure. Falls back to EOF append only if no header is found.
#
# Caller MUST validate `$todo_file` exists before calling (cmd_batch does
# this once before the loop — the check is NOT repeated here per GH#18539).
# ---------------------------------------------------------------------------
_append_todo_entry() {
	local task_id="$1"
	local title="$2"
	local task_ref="$3"
	local todo_file="$4"
	local today
	today=$(date +%Y-%m-%d)

	local ref_field=""
	if [[ -n "$task_ref" && "$task_ref" != "offline" ]]; then
		ref_field=" ref:${task_ref}"
	fi

	local entry="- [ ] ${task_id} ${title} #auto-dispatch ~1h${ref_field} logged:${today}"

	# Scan for the first "## Ready" (or "## Backlog") header and track the
	# last "- [ ]" task line within that section. Insert after that line so
	# new tasks land at the bottom of the active backlog, not after ## Done.
	#
	# Regex is stored in a variable per Bash Pitfall #46: inline regex with
	# backslash-brackets can be parsed ambiguously against POSIX char classes.
	local header_re='^##[[:space:]]+(Ready|Backlog)'
	local next_header_re='^##'
	local task_re='^-[[:space:]]+\[[[:space:]]+\]'
	local header_line=0 last_task_line=0 line_num=0
	local in_section=false
	local file_line=""
	while IFS= read -r file_line; do
		line_num=$((line_num + 1))
		if [[ "$in_section" == false && "$file_line" =~ $header_re ]]; then
			in_section=true
			header_line=$line_num
			last_task_line=$line_num
			continue
		fi
		if [[ "$in_section" == true ]]; then
			# Hit the next ## header — stop scanning this section.
			if [[ "$file_line" =~ $next_header_re ]]; then
				break
			fi
			# Track the last task checkbox in the section.
			if [[ "$file_line" =~ $task_re ]]; then
				last_task_line=$line_num
			fi
		fi
	done <"$todo_file"

	if [[ "$header_line" -gt 0 ]]; then
		# Insert after the last task line (or header if section is empty).
		local tmp_file
		tmp_file=$(mktemp)
		awk -v n="$last_task_line" -v entry="$entry" \
			'NR==n{print; print entry; next}1' \
			"$todo_file" >"$tmp_file" && mv "$tmp_file" "$todo_file"
	else
		log_warn "No ## Ready or ## Backlog header found in $todo_file — appending at end"
		echo "$entry" >>"$todo_file"
	fi

	return 0
}

# Resolve a pending ref:none task after TODO.md and the brief exist. This keeps
# GitHub-backed /new-task flows from reporting success before the tracker issue
# is durable. Explicit --offline/--no-issue flows bypass this helper.
_resolve_pending_task_ref() {
	local task_id="$1" task_ref="$2" repo_path="$3" todo_file="$4"
	[[ "$task_ref" != "none" ]] && { printf '%s\n' "$task_ref"; return 0; }

	local sync_helper="$SCRIPT_DIR/issue-sync-helper.sh"
	if [[ ! -x "$sync_helper" ]]; then
		log_error "Cannot resolve $task_id ref:none — issue-sync-helper.sh is missing"
		return 1
	fi
	if ! (cd "$repo_path" && AIDEVOPS_PLANNING_PUBLICATION_STATE=pending \
		"$sync_helper" push "$task_id" >/dev/null); then
		log_error "Tracker issue creation failed for $task_id"
		return 1
	fi

	local refreshed_ref=""
	refreshed_ref=$(grep -E "^[[:space:]]*-[[:space:]]+\[[ x]\][[:space:]]+${task_id}[[:space:]]" "$todo_file" \
		| grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/^ref://' || true)
	if [[ -z "$refreshed_ref" ]]; then
		log_error "Tracker issue creation left $task_id without ref:GH# in TODO.md"
		return 1
	fi
	printf '%s\n' "$refreshed_ref"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_batch decomposition (GH#18705)
#
# The batch flow was originally a single 211-line function. It is now split
# into orchestrator (`cmd_batch`) + focused helpers, each well under 100
# lines. Bash 3.2 does not support `local -n` namerefs, so the helpers that
# produce multi-value output either:
#   - populate module-level globals prefixed `_BATCH_` (parsed args and
#     result arrays), or
#   - emit a compact `id|ref` line on stdout that the caller parses.
# ---------------------------------------------------------------------------

# Module-level state for cmd_batch. Declared at file scope so the helpers
# can read and append without passing large argument lists. Re-initialised
# at the top of cmd_batch on every invocation.
_BATCH_TITLES=()
_BATCH_FROM_FILE=""
_BATCH_LABELS=""
_BATCH_DRY_RUN=false
_BATCH_NO_ISSUE=false
_BATCH_OFFLINE=false
_BATCH_REPO_PATH=""
_BATCH_RESULT_IDS=()
_BATCH_RESULT_TITLES=()
_BATCH_RESULT_REFS=()

# ---------------------------------------------------------------------------
# _parse_batch_args: parse CLI args for the batch subcommand into the
# module-level `_BATCH_*` globals. Returns 1 on unknown option.
# ---------------------------------------------------------------------------
_parse_batch_args() {
	_BATCH_TITLES=()
	_BATCH_FROM_FILE=""
	_BATCH_LABELS=""
	_BATCH_DRY_RUN=false
	_BATCH_NO_ISSUE=false
	_BATCH_OFFLINE=false
	_BATCH_REPO_PATH=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--title)
			_BATCH_TITLES+=("$2")
			shift 2
			;;
		--from-file)
			_BATCH_FROM_FILE="$2"
			shift 2
			;;
		--labels)
			_BATCH_LABELS="$2"
			shift 2
			;;
		--dry-run)
			_BATCH_DRY_RUN=true
			shift
			;;
		--no-issue)
			_BATCH_NO_ISSUE=true
			shift
			;;
		--offline)
			_BATCH_OFFLINE=true
			shift
			;;
		--repo-path)
			_BATCH_REPO_PATH="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done
	return 0
}

# ---------------------------------------------------------------------------
# _read_titles_stream: read titles from the current stdin, skipping full-line
# comments and whitespace, appending non-empty lines to `_BATCH_TITLES`.
# Called with stdin redirected by the caller (file or pipe).
#
# GH#18539: only skip lines that START with `#` (after whitespace). The
# previous `${line%%#*}` destroyed legitimate titles like "Fix bug #123",
# "Add PR #42 handler", or any title containing a GitHub issue reference.
# ---------------------------------------------------------------------------
_read_titles_stream() {
	local line
	while IFS= read -r line; do
		line="${line#"${line%%[![:space:]]*}"}" # ltrim
		line="${line%"${line##*[![:space:]]}"}" # rtrim
		# Skip full-line comments (entire line is a comment) but preserve
		# inline `#` refs — do NOT strip with ${line%%#*}.
		[[ "$line" =~ ^# ]] && continue
		[[ -n "$line" ]] && _BATCH_TITLES+=("$line")
	done
	return 0
}

# ---------------------------------------------------------------------------
# _resolve_batch_titles: populate `_BATCH_TITLES` from `--from-file`, then
# from stdin if none given and stdin is a pipe. Emits a usage message and
# returns 1 if no titles can be found.
# ---------------------------------------------------------------------------
_resolve_batch_titles() {
	if [[ -n "$_BATCH_FROM_FILE" ]]; then
		if [[ "$_BATCH_FROM_FILE" == "-" ]]; then
			_read_titles_stream
		else
			if [[ ! -f "$_BATCH_FROM_FILE" ]]; then
				log_error "File not found: $_BATCH_FROM_FILE"
				return 1
			fi
			_read_titles_stream <"$_BATCH_FROM_FILE"
		fi
	fi

	# Fall back to stdin if nothing supplied and stdin is a pipe
	if [[ ${#_BATCH_TITLES[@]} -eq 0 ]] && ! [[ -t 0 ]]; then
		_read_titles_stream
	fi

	if [[ ${#_BATCH_TITLES[@]} -eq 0 ]]; then
		log_error "No titles provided. Use --title, --from-file, or pipe titles on stdin."
		echo "Usage: new-task-helper.sh batch --title \"Title 1\" --title \"Title 2\"" >&2
		echo "       new-task-helper.sh batch --from-file titles.txt" >&2
		printf "       printf 'Title 1\\\\nTitle 2\\\\n' | new-task-helper.sh batch\n" >&2
		return 1
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _allocate_one_task: allocate a single task via `claim-task-id.sh` and
# print `task_id|task_ref` on stdout for the caller to parse.
# Args: title, labels, no_issue, offline, repo_path, claim_script
# Returns: 0 on success (with id|ref on stdout), 1 on failure (logs error).
# ---------------------------------------------------------------------------
_allocate_one_task() {
	local title="$1"
	local labels="$2"
	local no_issue="$3"
	local offline="$4"
	local repo_path="$5"
	local claim_script="$6"

	local -a claim_args=(--title "$title" --repo-path "$repo_path" --publication-state pending)
	[[ -n "$labels" ]] && claim_args+=(--labels "$labels")
	[[ "$no_issue" == "true" ]] && claim_args+=(--no-issue)
	[[ "$offline" == "true" ]] && claim_args+=(--offline)

	local claim_output=""
	local claim_rc=0
	# GH#18539: do NOT suppress claim-task-id.sh stderr — users need to see
	# auth failures, network errors, and lock contention. Suppressing hides
	# the diagnostic output that tells them why allocation failed.
	claim_output=$("$claim_script" "${claim_args[@]}") || claim_rc=$?

	# claim-task-id.sh uses rc 2 for "offline, id claimed locally" — still success
	if [[ $claim_rc -ne 0 && $claim_rc -ne 2 ]]; then
		log_error "Failed to allocate ID for: $title (exit code: $claim_rc)"
		return 1
	fi

	local task_id="" task_ref="" line=""
	while IFS= read -r line; do
		case "$line" in
		task_id=*) task_id="${line#task_id=}" ;;
		ref=*) task_ref="${line#ref=}" ;;
		esac
	done <<<"$claim_output"

	if [[ -z "$task_id" ]]; then
		log_error "No task_id returned for: $title"
		return 1
	fi

	printf '%s|%s\n' "$task_id" "$task_ref"
	return 0
}

# ---------------------------------------------------------------------------
# _commit_batch_planning: single commit+push of planning files (TODO.md +
# todo/tasks/). Prefers planning-commit-helper.sh, falls back to direct git.
# Args: n (count for commit message), repo_path
# Non-fatal on failure (logs warn and returns 0).
# ---------------------------------------------------------------------------
_commit_batch_planning() {
	local n="$1"
	local repo_path="$2"
	local commit_msg="plan: batch add ${n} task(s) via /new-task --batch"
	local planning_helper="$SCRIPT_DIR/planning-commit-helper.sh"

	if [[ -x "$planning_helper" ]]; then
		log_info "Committing $n planning file(s)..."
		"$planning_helper" "$commit_msg" || log_warn "Planning commit failed — files written but not committed"
	else
		log_info "planning-commit-helper.sh not found, using direct git commit..."
		git -C "$repo_path" add TODO.md "todo/tasks/" 2>/dev/null || true
		git -C "$repo_path" commit -m "$commit_msg" 2>/dev/null || true
		git -C "$repo_path" push 2>/dev/null || log_warn "Push failed — committed locally"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _print_batch_summary: print the ID / Title / GH# table from the module-level
# result arrays populated by cmd_batch's allocation loop.
# ---------------------------------------------------------------------------
_print_batch_summary() {
	echo ""
	printf "%-12s %-55s %s\n" "ID" "Title" "GH#"
	printf "%-12s %-55s %s\n" "------------" "-------------------------------------------------------" "-------"

	local i=0
	local n="${#_BATCH_RESULT_IDS[@]}"
	while [[ $i -lt $n ]]; do
		local tid="${_BATCH_RESULT_IDS[$i]}"
		local ttitle="${_BATCH_RESULT_TITLES[$i]}"
		local tref="${_BATCH_RESULT_REFS[$i]}"
		# Truncate title if too long for display
		if [[ ${#ttitle} -gt 55 ]]; then
			ttitle="${ttitle:0:52}..."
		fi
		printf "%-12s %-55s %s\n" "$tid" "$ttitle" "$tref"
		i=$((i + 1))
	done
	echo ""
	return 0
}

# ---------------------------------------------------------------------------
# _process_one_batch_title: per-iteration body of the allocation loop.
# Handles dry-run, claim call, stub brief, TODO entry, and result appends.
# Reads batch config from `_BATCH_*` globals; writes results to
# `_BATCH_RESULT_*` globals.
# Args: title, repo_path, todo_file, claim_script
# Returns: 0 on success, 1 on per-task failure (caller still continues).
# ---------------------------------------------------------------------------
_process_one_batch_title() {
	local title="$1"
	local repo_path="$2"
	local todo_file="$3"
	local claim_script="$4"

	log_info "Allocating: $title"

	if [[ "$_BATCH_DRY_RUN" == "true" ]]; then
		_BATCH_RESULT_IDS+=("[dry-run]")
		_BATCH_RESULT_TITLES+=("$title")
		_BATCH_RESULT_REFS+=("[dry-run]")
		return 0
	fi

	local alloc_out=""
	if ! alloc_out=$(_allocate_one_task "$title" "$_BATCH_LABELS" "$_BATCH_NO_ISSUE" "$_BATCH_OFFLINE" "$repo_path" "$claim_script"); then
		return 1
	fi

	local task_id="${alloc_out%%|*}"
	local task_ref="${alloc_out#*|}"

	# (t2417) If the linked issue body is worker-ready, write a minimal stub
	# linking to the issue instead of the full template brief. In headless/
	# batch mode, default to skip (stub). The readiness helper scores the
	# body against known heading sets (4-of-7 threshold).
	local _brief_written=false
	local _readiness_helper="$SCRIPT_DIR/brief-readiness-helper.sh"
	if [[ -x "$_readiness_helper" && -n "$task_ref" && "$task_ref" != "offline" ]]; then
		local _issue_num="${task_ref#GH#}"
		local _slug=""
		_slug=$(git -C "$repo_path" remote get-url origin 2>/dev/null \
			| sed -E 's#.*github\.com[:/]##; s/\.git$//' || true)
		if [[ -n "$_slug" && -n "$_issue_num" ]]; then
			local _body=""
			_body=$(gh issue view "$_issue_num" --repo "$_slug" --json body --jq '.body' 2>/dev/null) || true
			if [[ -n "$_body" ]]; then
				local _rout=""
				_rout=$("$_readiness_helper" check --body "$_body" 2>/dev/null) || true
				if printf '%s\n' "$_rout" | grep -q 'WORKER_READY=true'; then
					log_info "$task_id: issue #${_issue_num} body is worker-ready — writing stub brief"
					"$_readiness_helper" stub "$task_id" "$_issue_num" "$_slug" "$repo_path" 2>/dev/null || true
					_brief_written=true
				fi
			fi
		fi
	fi
	if [[ "$_brief_written" != "true" ]]; then
		_create_stub_brief "$task_id" "$title" "$task_ref" "$repo_path" ||
			log_warn "Brief creation failed for $task_id — continuing"
	fi

	_append_todo_entry "$task_id" "$title" "$task_ref" "$todo_file" ||
		log_warn "TODO entry failed for $task_id — continuing"
	if [[ "$_BATCH_NO_ISSUE" != "true" && "$_BATCH_OFFLINE" != "true" ]]; then
		task_ref=$(_resolve_pending_task_ref "$task_id" "$task_ref" "$repo_path" "$todo_file") || return 1
	fi

	_BATCH_RESULT_IDS+=("$task_id")
	_BATCH_RESULT_TITLES+=("$title")
	_BATCH_RESULT_REFS+=("${task_ref:-offline}")
	log_success "Allocated $task_id ($task_ref): $title"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_batch: main batch creation flow — orchestrator.
#
# Steps:
#   1. Parse CLI args into `_BATCH_*` globals (`_parse_batch_args`).
#   2. Resolve titles from args / file / stdin (`_resolve_batch_titles`).
#   3. Resolve repo path, TODO.md path, and locate `claim-task-id.sh`.
#   4. Allocate each title via `_process_one_batch_title`, tracking
#      per-iteration failures in `any_failed`.
#   5. Commit+push planning files as one unit (`_commit_batch_planning`).
#   6. Print the summary table (`_print_batch_summary`).
# ---------------------------------------------------------------------------
cmd_batch() {
	_parse_batch_args "$@" || return 1
	_resolve_batch_titles || return 1

	# Resolve repo path
	local repo_path="$_BATCH_REPO_PATH"
	if [[ -z "$repo_path" ]]; then
		repo_path=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
	fi
	local todo_file="$repo_path/TODO.md"

	# GH#18539: validate TODO.md once at cmd_batch entry, not per-task
	# inside `_append_todo_entry`. Fails fast if the target file is missing.
	if [[ ! -f "$todo_file" ]]; then
		log_error "TODO.md not found at: $todo_file"
		return 1
	fi

	local claim_script="$SCRIPT_DIR/claim-task-id.sh"
	if [[ ! -x "$claim_script" ]]; then
		log_error "claim-task-id.sh not found or not executable: $claim_script"
		return 1
	fi

	log_info "Batch creating ${#_BATCH_TITLES[@]} task(s)..."
	if [[ "$_BATCH_DRY_RUN" == "true" ]]; then
		log_info "[DRY-RUN] No changes will be made"
	fi

	# Reset result arrays for this invocation
	_BATCH_RESULT_IDS=()
	_BATCH_RESULT_TITLES=()
	_BATCH_RESULT_REFS=()
	local any_failed=false

	local title
	for title in "${_BATCH_TITLES[@]}"; do
		_process_one_batch_title "$title" "$repo_path" "$todo_file" "$claim_script" ||
			any_failed=true
	done

	# Single commit+push for all planning files
	if [[ "$_BATCH_DRY_RUN" == "false" && ${#_BATCH_RESULT_IDS[@]} -gt 0 ]]; then
		_commit_batch_planning "${#_BATCH_RESULT_IDS[@]}" "$repo_path"
	fi

	_print_batch_summary

	if [[ "$any_failed" == "true" ]]; then
		log_warn "Some tasks failed to allocate — check stderr above"
		return 1
	fi

	log_success "Batch complete: ${#_BATCH_RESULT_IDS[@]} task(s) created"
	return 0
}

# ---------------------------------------------------------------------------
# cmd_help
# ---------------------------------------------------------------------------
cmd_help() {
	cat <<'EOF'
new-task-helper.sh — Batch task creation for /new-task

Usage:
  new-task-helper.sh batch [options]

Subcommands:
  batch    Create multiple tasks in one pass with a single commit+push

Options (batch):
  --title "..."     Task title (repeat for multiple tasks)
  --from-file FILE  File with one title per line (use - for stdin)
  --labels "..."    Comma-separated labels applied to all tasks
  --dry-run         Preview allocations without changes
  --no-issue        Skip GitHub/GitLab issue creation
  --offline         Force offline mode
  --repo-path PATH  Git repository path (default: current directory)

Examples:
  new-task-helper.sh batch --title "Fix login bug" --title "Add CSV export"
  new-task-helper.sh batch --from-file sprint-tasks.txt
  echo -e "Fix auth\nAdd export" | new-task-helper.sh batch --labels "sprint-3"

Output:
  ID           Title                                                   GH#
  ------------ ------------------------------------------------------- -------
  t1234        Fix login bug                                           GH#5001
  t1235        Add CSV export                                          GH#5002
EOF
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	batch) cmd_batch "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
