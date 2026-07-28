#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Using /bin/bash directly (not #!/usr/bin/env bash) for compatibility with
# headless environments where a stripped PATH can prevent env from finding bash.
# See issue #2610. This is an intentional exception to the repo's env-bash standard (t135.14).
# =============================================================================
# Issue Sync Library — Parse Sub-Library
# =============================================================================
# TODO.md, PLANS.md, and PRD/task file parsing functions extracted from
# issue-sync-lib.sh for file-size compliance.
#
# Covers:
#   - TODO.md line parsing and task block extraction
#   - PLANS.md section extraction and plan lookups
#   - PRD/task file discovery and summarisation
#
# Usage: source "${SCRIPT_DIR}/issue-sync-lib-parse.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, log_verbose)
#   - bash 3.2+, awk, sed, grep; optional rg for faster tree searches
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ISSUE_SYNC_LIB_PARSE_LOADED:-}" ]] && return 0
_ISSUE_SYNC_LIB_PARSE_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement — avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi
# shellcheck source=./task-identity-lib.sh
_issue_sync_parse_dir="${BASH_SOURCE[0]%/*}"
[[ "$_issue_sync_parse_dir" == "${BASH_SOURCE[0]}" ]] && _issue_sync_parse_dir="."
source "${_issue_sync_parse_dir}/task-identity-lib.sh"
unset _issue_sync_parse_dir

# =============================================================================
# Parse — TODO.md Utilities
# =============================================================================

# Strip content that should not be parsed as live tasks. Removes:
#   1. Markdown code-fenced blocks (``` ... ```) — whole lines inside fences.
#   2. HTML comment regions (<!-- ... -->) — character spans, possibly spanning
#      multiple lines, leaving any text outside the comment intact.
# Prevents task-like lines in format examples and documentation comments
# (GH#17804 issue-sync helper) from being parsed as real tasks.
# Usage: strip_code_fences < file  OR  grep ... | strip_code_fences
strip_code_fences() {
	local pipeline_status=()
	awk '/^[[:space:]]*```/ { in_fence = !in_fence; next } !in_fence { print }' | strip_html_comments
	pipeline_status=("${PIPESTATUS[@]}")
	if [[ "${pipeline_status[0]}" -ne 0 || "${pipeline_status[1]}" -ne 0 ]]; then
		return 1
	fi
	return 0
}

# Strip only HTML comment regions (<!-- ... -->) from stdin, including
# multi-line comments. Leaves code fences and everything else untouched.
# Useful for callers that need comment stripping without fence removal.
# Usage: strip_html_comments < file  OR  grep ... | strip_html_comments
strip_html_comments() {
	if ! awk '
		{
			line = $0
			out = ""
			while (length(line) > 0) {
				if (in_comment) {
					pos = index(line, "-->")
					if (pos == 0) { line = ""; break }
					line = substr(line, pos + 3)
					in_comment = 0
				} else {
					pos = index(line, "<!--")
					if (pos == 0) { out = out line; line = ""; break }
					out = out substr(line, 1, pos - 1)
					line = substr(line, pos + 4)
					in_comment = 1
				}
			}
			print out
		}
	'; then
		return 1
	fi
	return 0
}

# Escape a string for use in Extended Regular Expressions (ERE).
# Task IDs like t001.1 contain dots that are regex wildcards — this prevents
# t001.1 from matching t001x1 in grep -E or awk patterns.
# Usage: local escaped; escaped=$(_escape_ere "$task_id")
_escape_ere() {
	local input="$1"
	task_identity_escape_ere "$input"
	return $?
}

# Extract and validate the task ID in the canonical TODO checkbox position.
_task_id_from_todo_line() {
	local line="$1"
	local candidate=""
	local todo_line_re='^[[:space:]]*-[[:space:]]+\[[[:space:]x>-]\][[:space:]]+([^[:space:]]+)'
	if [[ "$line" =~ $todo_line_re ]]; then
		candidate="${BASH_REMATCH[1]}"
	fi
	task_identity_validate "$candidate" || return 1
	printf '%s\n' "$candidate"
	return 0
}

# Emit the richest canonical TODO line per task ID. File mutation consumes this
# selection so diagnostics and repairs choose the same row when stale duplicates
# have conflicting markers or refs.
_unique_todo_task_lines() {
	if ! awk '
		match($0, /^[[:space:]]*-[[:space:]]+\[[ x>-]\][[:space:]]+/) {
			remaining = substr($0, RLENGTH + 1)
			split(remaining, fields, /[[:space:]]+/)
			task_id = fields[1]
			if (task_id !~ /^t[0-9]+(\.[0-9]+)*$/) { next }
			if (!(task_id in task_order)) {
				task_order[task_id] = ++task_count
				ordered_tasks[task_count] = task_id
			}
			score = 0
			if ($0 ~ /^[[:space:]]*- \[x\] / || $0 ~ /^[[:space:]]*- \[-\] /) { score += 1000 }
			if ($0 ~ /^[[:space:]]*- \[>\] /) { score += 500 }
			if ($0 ~ / -> \[/) { score += 100 }
			if ($0 ~ / blocked-by:/) { score += 25 }
			if ($0 ~ / tier:/) { score += 25 }
			if ($0 ~ / logged:/) { score += 25 }
			if ($0 ~ / pr:#[0-9]+/) { score += 10 }
			if ($0 ~ / verified:[0-9]{4}-[0-9]{2}-[0-9]{2}/) { score += 10 }
			if ($0 ~ / completed:[0-9]{4}-[0-9]{2}-[0-9]{2}/) { score += 10 }
			if (!(task_id in best_score) || score > best_score[task_id]) {
				best_score[task_id] = score
				best_line[task_id] = $0
			}
		}
		END {
			for (i = 1; i <= task_count; i += 1) {
				print best_line[ordered_tasks[i]]
			}
		}
	'; then
		return 1
	fi
	return 0
}

_unique_todo_task_snapshot() {
	local todo_file="$1"
	local stripped
	if ! stripped=$(strip_code_fences <"$todo_file"); then
		return 1
	fi
	if ! printf '%s\n' "$stripped" | _unique_todo_task_lines; then
		return 1
	fi
	return 0
}

# Select the canonical row for one task from the shared unique snapshot. File
# mutation calls this helper so it cannot drift from diagnostic snapshot
# scoring when lifecycle markers or metadata weights change.
_canonical_todo_task_line() {
	local task_id="$1"
	local todo_file="$2"
	local snapshot=""
	local line=""
	local candidate_id=""
	if ! snapshot=$(_unique_todo_task_snapshot "$todo_file"); then
		return 1
	fi
	while IFS= read -r line; do
		candidate_id=$(_task_id_from_todo_line "$line" 2>/dev/null || true)
		if [[ "$candidate_id" == "$task_id" ]]; then
			printf '%s\n' "$line"
			return 0
		fi
	done <<<"$snapshot"
	return 1
}

_task_id_from_issue_title() {
	local title="$1"
	task_identity_parse_title_prefix "$title"
	return $?
}

_task_dependency_value() {
	local line="$1"
	local key="$2"
	local value=""
	case "$key" in
	blocked-by | blocks) ;;
	*) return 1 ;;
	esac
	if [[ "$line" =~ (^|[[:space:]])${key}:([^[:space:]]+) ]]; then
		value="${BASH_REMATCH[2]}"
	fi
	[[ -n "$value" ]] || return 0
	task_identity_parse_list "$value" >/dev/null || return 1
	printf '%s\n' "$value"
	return 0
}

_task_parent_value() {
	local line="$1"
	local value=""
	local matched=""
	local remainder=""
	if [[ "$line" =~ (^|[[:space:]])parent:([^[:space:]]+) ]]; then
		matched="${BASH_REMATCH[0]}"
		value="${BASH_REMATCH[2]}"
		remainder="${line#*"$matched"}"
		[[ ! "$remainder" =~ (^|[[:space:]])parent: ]] || return 1
	fi
	[[ -n "$value" ]] || return 0
	task_identity_validate "$value" || return 1
	printf '%s\n' "$value"
	return 0
}

# Find project root (contains TODO.md)
find_project_root() {
	local dir="$PWD"
	while [[ "$dir" != "/" ]]; do
		if [[ -f "$dir/TODO.md" ]]; then
			echo "$dir"
			return 0
		fi
		dir="${dir%/*}"
		[[ -z "$dir" ]] && dir="/"
	done
	print_error "No TODO.md found in directory tree"
	return 1
}

# Parse a single task line from TODO.md.
# Returns structured data as key=value pairs on stdout.
# Handles both top-level tasks and indented subtasks.
# Arguments:
#   $1 - raw task line from TODO.md
parse_task_line() {
	local line="$1"

	# Extract checkbox status
	local status="open"
	if echo "$line" | grep -qE '^\s*- \[x\]'; then
		status="completed"
	elif echo "$line" | grep -qE '^\s*- \[-\]'; then
		status="declined"
	fi

	# Extract task ID
	local task_id
	task_id=$(_task_id_from_todo_line "$line") || return 1

	# Extract description (between task ID and first metadata field)
	local description
	local task_id_ere=""
	task_id_ere=$(task_identity_escape_ere "$task_id" 2>/dev/null || true)
	description=$(echo "$line" | sed -E "s/^[[:space:]]*- \\[.\\] ${task_id_ere} //" |
		sed -E 's/ (#[a-z]|~[0-9]|→ |logged:|started:|completed:|ref:|actual:|blocked-by:|blocks:|parent:|assignee:|verified:).*//' ||
		echo "")

	# Extract tags
	local tags
	tags=$(echo "$line" | grep -oE '#[a-z][a-z0-9-]*' | tr '\n' ',' | sed 's/,$//' || echo "")

	# Extract estimate (with optional breakdown)
	local estimate
	estimate=$(echo "$line" | grep -oE '~[0-9]+[hmd](\s*\(ai:[^)]+\))?' | head -1 || echo "")

	# Extract plan link
	local plan_link
	plan_link=$(echo "$line" | grep -oE '→ \[todo/PLANS\.md#[^]]+\]' | sed 's/→ \[//' | sed 's/\]//' || echo "")

	# Extract existing GH ref
	local gh_ref
	gh_ref=$(echo "$line" | grep -oE 'ref:GH#[0-9]+' | head -1 | sed 's/ref:GH#//' || echo "")

	# Extract logged date
	local logged
	logged=$(echo "$line" | sed -nE 's/.*logged:([0-9-]+).*/\1/p' || echo "")

	# Extract assignee
	local assignee
	assignee=$(echo "$line" | sed -nE 's/.*assignee:([A-Za-z0-9._@-]+).*/\1/p' | head -1 || echo "")

	# Extract started timestamp
	local started
	started=$(echo "$line" | sed -nE 's/.*started:([0-9T:Z-]+).*/\1/p' | head -1 || echo "")

	# Extract completed date
	local completed
	completed=$(echo "$line" | sed -nE 's/.*completed:([0-9-]+).*/\1/p' | head -1 || echo "")

	# Extract actual time
	local actual
	actual=$(echo "$line" | sed -nE 's/.*actual:([0-9.]+[hmd]).*/\1/p' | head -1 || echo "")

	# Extract blocked-by dependencies
	local blocked_by
	blocked_by=$(_task_dependency_value "$line" "blocked-by") || return 1

	# Extract blocks (downstream dependencies)
	local blocks
	blocks=$(_task_dependency_value "$line" "blocks") || return 1

	# Extract singular parent hierarchy metadata (not a blocking dependency)
	local parent
	parent=$(_task_parent_value "$line") || return 1

	# Extract verified date
	local verified
	verified=$(echo "$line" | sed -nE 's/.*verified:([0-9-]+).*/\1/p' | head -1 || echo "")

	echo "task_id=$task_id"
	echo "status=$status"
	echo "description=$description"
	echo "tags=$tags"
	echo "estimate=$estimate"
	echo "plan_link=$plan_link"
	echo "gh_ref=$gh_ref"
	echo "logged=$logged"
	echo "assignee=$assignee"
	echo "started=$started"
	echo "completed=$completed"
	echo "actual=$actual"
	echo "blocked_by=$blocked_by"
	echo "blocks=$blocks"
	echo "parent=$parent"
	echo "verified=$verified"
	return 0
}

# Extract a task and all its subtasks + notes from TODO.md.
# Returns the full block of text for a given task ID.
# Arguments:
#   $1 - task_id (e.g. t1120)
#   $2 - path to TODO.md
extract_task_block() {
	local task_id="$1"
	local todo_file="$2"
	local task_line_ere='^[[:space:]]*- \[.\] ([^[:space:]]+) '
	local list_item_ere='^[[:space:]]*- '
	local candidate_task_id=""
	task_identity_validate "$task_id" || return 1

	local in_block=false
	local block=""
	local task_indent=-1

	while IFS= read -r line; do
		# Capture the checkbox-position token in pure Bash, then compare the
		# validated canonical ID literally. Avoid external processes in this hot loop.
		if [[ "$in_block" == "false" ]] && [[ "$line" =~ $task_line_ere ]]; then
			candidate_task_id="${BASH_REMATCH[1]}"
			if [[ "$candidate_task_id" == "$task_id" ]]; then
				in_block=true
				block="$line"
				# Calculate indent level using pure bash (avoids subshells in loop)
				local prefix="${line%%[! ]*}"
				task_indent=${#prefix}
				continue
			fi
		fi

		if [[ "$in_block" == "true" ]]; then
			# Check if we've hit the next task at same or lower indent
			local current_indent
			local cur_prefix="${line%%[! ]*}"
			current_indent=${#cur_prefix}

			# Empty lines within block end the block
			if [[ -z "${line// /}" ]]; then
				break
			fi

			# If indent is <= task indent and it's a new task, we're done
			if [[ $current_indent -le $task_indent ]] && task_identity_extract_first "$line" >/dev/null 2>&1; then
				break
			fi

			# If indent is <= task indent and it's not a subtask/notes line, we're done
			if [[ $current_indent -le $task_indent ]] && [[ ! "$line" =~ $list_item_ere ]]; then
				break
			fi

			block="$block"$'\n'"$line"
		fi
	done <"$todo_file"

	echo "$block"
	return 0
}

# Extract subtasks from a task block.
# Skips the first line (parent task), returns indented subtask lines.
# Arguments:
#   $1 - task block text (multi-line)
extract_subtasks() {
	local block="$1"
	local line=""
	echo "$block" | tail -n +2 | while IFS= read -r line; do
		[[ "$line" =~ ^[[:space:]]+-[[:space:]]\[.\][[:space:]] ]] || continue
		task_identity_extract_first "$line" >/dev/null 2>&1 && printf '%s\n' "$line"
	done
	return 0
}

# Extract Notes from a task block.
# Arguments:
#   $1 - task block text (multi-line)
extract_notes() {
	local block="$1"
	echo "$block" | grep -E '^\s+- Notes:' | sed 's/^[[:space:]]*- Notes: //' || true
	return 0
}

# =============================================================================
# Parse — PLANS.md Utilities
# =============================================================================

# Extract a plan section from PLANS.md given an anchor.
# Uses awk for performance — avoids spawning subprocesses per line on large files.
# Arguments:
#   $1 - plan_link (e.g. "todo/PLANS.md#2026-02-08-git-issues-bi-directional-sync")
#   $2 - project_root
extract_plan_section() {
	local plan_link="$1"
	local project_root="$2"

	if [[ -z "$plan_link" ]]; then
		return 0
	fi

	local plans_file="$project_root/todo/PLANS.md"
	if [[ ! -f "$plans_file" ]]; then
		log_verbose "PLANS.md not found at $plans_file"
		return 0
	fi

	# Convert anchor to heading text for matching
	local anchor
	anchor="${plan_link#todo/PLANS.md#}"

	# Use awk to extract the section efficiently (single pass, no per-line subprocesses)
	# Matching strategy: exact > substring > date-prefix + word overlap (handles TODO.md/PLANS.md drift)
	awk -v anchor="$anchor" '
    BEGIN {
        in_section = 0; heading_level = 0

        # Extract date prefix from anchor for fuzzy matching (e.g., "2026-02-08")
        if (match(anchor, /^[0-9]{4}-[0-9]{2}-[0-9]{2}/)) {
            anchor_date = substr(anchor, RSTART, RLENGTH)
            anchor_rest = substr(anchor, RLENGTH + 2)  # skip date + hyphen
        } else {
            anchor_date = ""
            anchor_rest = anchor
        }
        # Split anchor remainder into words for overlap scoring
        n_anchor_words = split(anchor_rest, anchor_words, "-")
    }

    function check_match(line_anchor) {
        # 1. Exact match
        if (line_anchor == anchor) return 1
        # 2. Substring containment (either direction)
        if (index(line_anchor, anchor) > 0 || index(anchor, line_anchor) > 0) return 1
        # 3. Date-prefix + word overlap (handles renamed/abbreviated headings)
        if (anchor_date != "" && index(line_anchor, anchor_date) > 0) {
            score = 0
            for (i = 1; i <= n_anchor_words; i++) {
                if (length(anchor_words[i]) >= 3 && index(line_anchor, anchor_words[i]) > 0) {
                    score++
                }
            }
            # Require >50% word overlap for fuzzy match
            if (n_anchor_words > 0 && score > n_anchor_words / 2) return 1
        }
        return 0
    }

    /^#{1,6} / {
        if (in_section == 0) {
            # Generate anchor from heading: strip leading #s, lowercase, strip special chars, spaces to hyphens
            line_anchor = $0
            gsub(/^#+[[:space:]]+/, "", line_anchor)
            line_anchor = tolower(line_anchor)
            gsub(/[^a-z0-9 -]/, "", line_anchor)
            gsub(/ /, "-", line_anchor)

            if (check_match(line_anchor)) {
                in_section = 1
                match($0, /^#+/)
                heading_level = RLENGTH
                print
                next
            }
        } else {
            # Check if this heading is at same or higher level (ends section)
            match($0, /^#+/)
            if (RLENGTH <= heading_level) {
                exit
            }
        }
    }

    in_section == 1 { print }
    ' "$plans_file"

	return 0
}

# Extract a named subsection from a plan section.
# Uses awk for consistent, efficient extraction.
# Arguments:
#   $1 - plan_section (multi-line text)
#   $2 - heading_pattern (e.g. "Purpose")
#   $3 - max_lines (0=unlimited)
#   $4 - skip_toon (true|false, default true)
#   $5 - skip_placeholder (true|false, default false)
_extract_plan_subsection() {
	local plan_section="$1"
	local heading_pattern="$2"
	local max_lines="${3:-0}"
	local skip_toon="${4:-true}"
	local skip_placeholder="${5:-false}"

	local result
	result=$(echo "$plan_section" | awk -v pattern="$heading_pattern" -v skip_toon="$skip_toon" -v max_lines="$max_lines" -v skip_placeholder="$skip_placeholder" '
    BEGIN { in_section = 0; count = 0 }
    /^####[[:space:]]+/ {
        if (in_section == 1) { exit }
        if ($0 ~ "^####[[:space:]]+" pattern) { in_section = 1; next }
        next
    }
    /^###[[:space:]]+/ { if (in_section == 1) exit }
    in_section == 1 {
        if (skip_toon == "true" && $0 ~ /^<!--TOON:/) exit
        if (/^[[:space:]]*$/) next
        if (skip_placeholder == "true" && $0 ~ /To be populated/) next
        if (max_lines > 0 && count >= max_lines) exit
        print
        count++
    }
    ')

	echo "$result"
	return 0
}

# Extract just the Purpose section from a plan.
# Arguments:
#   $1 - plan_section (multi-line text)
extract_plan_purpose() {
	local plan_section="$1"
	_extract_plan_subsection "$plan_section" "Purpose" 20 "false"
	return 0
}

# Extract the Decision Log from a plan.
# Arguments:
#   $1 - plan_section (multi-line text)
extract_plan_decisions() {
	local plan_section="$1"
	_extract_plan_subsection "$plan_section" "Decision Log" 0 "true"
	return 0
}

# Extract Progress section from a plan.
# Arguments:
#   $1 - plan_section (multi-line text)
extract_plan_progress() {
	local plan_section="$1"
	_extract_plan_subsection "$plan_section" "Progress" 0 "true"
	return 0
}

# Extract Discoveries section from a plan.
# Arguments:
#   $1 - plan_section (multi-line text)
extract_plan_discoveries() {
	local plan_section="$1"
	_extract_plan_subsection "$plan_section" "Surprises" 0 "true" "true"
	return 0
}

# Find a plan section in PLANS.md by matching task ID in **TODO:** or **Task:** fields.
# Supports subtask walk-up: t004.2 → t004.
# Returns: "plan_id\n<plan_section_text>" or empty string if not found.
# Arguments:
#   $1 - task_id
#   $2 - project_root
find_plan_by_task_id() {
	local task_id="$1"
	local project_root="$2"
	task_identity_parse "$task_id" || return 1

	local plans_file="$project_root/todo/PLANS.md"
	if [[ ! -f "$plans_file" ]]; then
		return 0
	fi

	# Resolve lookup IDs: try exact task_id first, then walk up to parent for subtasks
	local lookup_ids=("$task_id")
	local parent_id="$TASK_IDENTITY_PARENT_ID"
	while [[ -n "$parent_id" ]]; do
		lookup_ids+=("$parent_id")
		task_identity_parse "$parent_id" || return 1
		parent_id="$TASK_IDENTITY_PARENT_ID"
	done

	for lookup_id in "${lookup_ids[@]}"; do
		# Search for **TODO:** or **Task:** field containing this task ID
		local match_line="" match_line_num="" candidate_line="" candidate_num="" candidate_text="" candidate_id=""
		while IFS= read -r candidate_line; do
			candidate_num="${candidate_line%%:*}"
			candidate_text="${candidate_line#*:}"
			[[ "$candidate_text" =~ ^\*\*(TODO|Task):\*\* ]] || continue
			while IFS= read -r candidate_id; do
				if [[ "$candidate_id" == "$lookup_id" ]]; then
					match_line="${candidate_num}:${candidate_text}"
					break 2
				fi
			done < <(task_identity_extract_all "$candidate_text")
		done < <(grep -nE '^\*\*(TODO|Task):\*\*' "$plans_file" || true)
		if [[ -z "$match_line" ]]; then
			continue
		fi
		match_line_num="${match_line%%:*}"

		# Walk backwards from match_line_num to find the enclosing ### heading
		local heading_line
		heading_line=$(awk -v target="$match_line_num" '
			NR <= target && /^### / { last_heading = NR; last_text = $0 }
			NR == target { print last_heading ":" last_text; exit }
		' "$plans_file")

		if [[ -z "$heading_line" ]]; then
			continue
		fi

		local heading_num heading_raw
		heading_num="${heading_line%%:*}"
		heading_raw="${heading_line#*:}"

		# Extract plan ID from TOON block between heading and next ### heading
		local plan_id=""
		plan_id=$(awk -v start="$heading_num" '
			NR < start { next }
			NR > start && /^### / { exit }
			/^<!--TOON:plan\{/ {
				# Extract first field (plan ID) from TOON data line
				getline data_line
				if (match(data_line, /^p[0-9]+,/)) {
					id = substr(data_line, RSTART, RLENGTH - 1)
					print id
					exit
				}
			}
		' "$plans_file" || true)

		# Generate anchor from heading text for extract_plan_section
		local anchor
		anchor=$(echo "$heading_raw" | sed 's/^### //' | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 -]//g' | sed 's/ /-/g')

		local plan_section
		plan_section=$(extract_plan_section "todo/PLANS.md#${anchor}" "$project_root")

		if [[ -n "$plan_section" ]]; then
			echo "${plan_id}"
			echo "$plan_section"
			return 0
		fi
	done

	return 0
}

# Extract additional plan subsections not covered by the 4 standard extractors.
# Returns non-empty content for: Context, Research, Architecture, Tool Matrix, Linkage, etc.
# Arguments:
#   $1 - plan_section (multi-line text)
extract_plan_extra_sections() {
	local plan_section="$1"

	# Headings to include (beyond Purpose/Progress/Decision Log/Surprises)
	local extra_headings=(
		"Context"
		"Context from Discussion"
		"Context from Review"
		"Research"
		"Architecture"
		"Tool Matrix"
		"Linkage"
		"Proposed Structure"
		"Design"
		"Implementation"
		"Phases"
		"Risks"
		"Open Questions"
		"Related Tasks"
		"Dependencies"
	)

	local result=""
	for heading in "${extra_headings[@]}"; do
		local content
		content=$(_extract_plan_subsection "$plan_section" "$heading" 0 "true")
		if [[ -n "$content" ]]; then
			result="${result}"$'\n\n'"**${heading}**"$'\n\n'"${content}"
		fi
	done

	echo "$result"
	return 0
}

# =============================================================================
# Parse — PRD/Task File Utilities
# =============================================================================

# Find related PRD and task files in todo/tasks/.
# Checks both grep matches and explicit ref:todo/tasks/ from the task line.
# Arguments:
#   $1 - task_id
#   $2 - project_root
find_related_files() {
	local task_id="$1"
	local project_root="$2"
	local tasks_dir="$project_root/todo/tasks"
	local todo_file="$project_root/TODO.md"
	local all_files=""

	# 1. Follow explicit ref:todo/tasks/ from the task line
	if [[ -f "$todo_file" ]]; then
		local task_line
		task_line=$(grep -E "^- \[.\] ${task_id} " "$todo_file" | head -1 || echo "")
		local explicit_refs
		explicit_refs=$(echo "$task_line" | grep -oE 'ref:todo/tasks/[^ ]+' | sed 's/ref://' || true)
		while IFS= read -r ref; do
			if [[ -n "$ref" && -f "$project_root/$ref" ]]; then
				all_files="${all_files:+$all_files"$'\n'"}$project_root/$ref"
			fi
		done <<<"$explicit_refs"
	fi

	# 2. Search for files referencing this task ID in todo/tasks/
	if [[ -d "$tasks_dir" ]]; then
		local grep_files
		if command -v rg >/dev/null 2>&1; then
			grep_files=$(rg -l -F -- "$task_id" "$tasks_dir" 2>/dev/null || true)
		else
			grep_files=$(grep -rlF -- "$task_id" "$tasks_dir" 2>/dev/null || true)
		fi
		if [[ -n "$grep_files" ]]; then
			all_files="${all_files:+$all_files"$'\n'"}$grep_files"
		fi
	fi

	# Deduplicate and exclude brief files (handled separately by compose_issue_body)
	if [[ -n "$all_files" ]]; then
		echo "$all_files" | sort -u | grep -v -- '-brief\.md$'
	fi
	return 0
}

# Extract a summary from a PRD or task file (first meaningful section, max 30 lines).
# Arguments:
#   $1 - file_path
#   $2 - max_lines (default: 30)
extract_file_summary() {
	local file_path="$1"
	local max_lines="${2:-30}"

	if [[ ! -f "$file_path" ]]; then
		return 0
	fi

	local summary=""
	local line_count=0
	local in_frontmatter=false
	local past_frontmatter=false

	while IFS= read -r line; do
		# Skip YAML frontmatter
		if [[ "$line" == "---" ]] && [[ "$past_frontmatter" == "false" ]]; then
			if [[ "$in_frontmatter" == "true" ]]; then
				past_frontmatter=true
				in_frontmatter=false
				continue
			fi
			in_frontmatter=true
			continue
		fi
		if [[ "$in_frontmatter" == "true" ]]; then
			continue
		fi

		# Skip empty lines at the start
		if [[ -z "${line// /}" ]] && [[ $line_count -eq 0 ]]; then
			continue
		fi

		# Include the title heading (# Title) as first line
		if [[ $line_count -eq 0 ]] && [[ "$line" == "# "* ]]; then
			summary="$line"
			line_count=1
			continue
		fi

		summary="$summary"$'\n'"$line"
		line_count=$((line_count + 1))

		# Stop at max lines
		if [[ $line_count -ge $max_lines ]]; then
			summary="$summary"$'\n'"..."
			break
		fi
	done <"$file_path"

	echo "$summary"
	return 0
}
