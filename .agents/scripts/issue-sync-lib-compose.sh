#!/bin/bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Using /bin/bash directly (not #!/usr/bin/env bash) for compatibility with
# headless environments where a stripped PATH can prevent env from finding bash.
# See issue #2610. This is an intentional exception to the repo's env-bash standard (t135.14).
# =============================================================================
# Issue Sync Library — Compose Sub-Library
# =============================================================================
# Tag/label mapping and issue body composition functions extracted from
# issue-sync-lib.sh for file-size compliance.
#
# Covers:
#   - Tag-to-label mapping with alias normalisation
#   - Parent-task phase marker detection and warnings
#   - Issue body composition (metadata, plan sections, related files,
#     worker guidance, brief content, full body assembly)
#
# Usage: source "${SCRIPT_DIR}/issue-sync-lib-compose.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, log_verbose, sed_inplace)
#   - issue-sync-lib-parse.sh (extract_notes, extract_subtasks,
#     extract_plan_purpose, extract_plan_extra_sections,
#     extract_plan_progress, extract_plan_decisions, extract_plan_discoveries,
#     find_related_files, extract_file_summary, extract_plan_section,
#     find_plan_by_task_id, extract_task_block, parse_task_line)
#   - bash 3.2+, awk, sed, grep
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_ISSUE_SYNC_LIB_COMPOSE_LOADED:-}" ]] && return 0
_ISSUE_SYNC_LIB_COMPOSE_LOADED=1

ISSUE_SYNC_DETAILS_OPEN="<details>"
ISSUE_SYNC_DETAILS_CLOSE="</details>"

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement — avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# Compose — Tag/Label Mapping
# =============================================================================

# Map TODO.md #tags to issue labels (passthrough with aliases).
# All tags are passed through as labels. A small alias map normalises
# common synonyms to their canonical label name.
# Arguments:
#   $1 - tags (comma-separated, with or without # prefix)
map_tags_to_labels() {
	local tags="$1"

	if [[ -z "$tags" ]]; then
		return 0
	fi

	local labels=""
	local tag
	local _saved_ifs="$IFS"
	IFS=','
	for tag in $tags; do
		tag="${tag#\#}"  # Remove # prefix if present
		tag="${tag// /}" # Strip whitespace

		[[ -z "$tag" ]] && continue

		# Alias common synonyms to canonical label names
		local label="$tag"
		case "$tag" in
		bugfix | bug) label="bug" ;;
		feat | feature) label="enhancement" ;;
		hardening) label="quality" ;;
		sync) label="git" ;;
		docs) label="documentation" ;;
		worker) label="origin:worker" ;;
		interactive) label="origin:interactive" ;;
		parent | parent-task | meta) label="parent-task" ;;
		esac

		labels="${labels:+$labels,}$label"
	done
	IFS="$_saved_ifs"

	# Deduplicate
	echo "$labels" | tr ',' '\n' | sort -u | tr '\n' ',' | sed 's/,$//'
	return 0
}

# t2442: Check whether a parent-task issue body carries any of the
# decomposition markers that the reconciler understands. Pure string
# check — no I/O, no side effects.
#
# A body is considered "decomposition-ready" if it contains any of:
#   - `## Children` / `## Child issues` / `## Sub-tasks` heading
#     (matches _extract_children_section in pulse-issue-reconcile.sh)
#   - `## Phase` heading (phase-decomposed roadmap)
#   - Narrow prose patterns matched by _extract_children_from_prose:
#     `Phase N #NNNN`, `filed as #NNNN`, `tracks #NNNN`, `blocked by #NNNN`
#
# Exit 0: body has at least one marker — parent-task is usable as-is,
# no warning needed.
# Exit 1: body has no markers — parent-task will be invisible to the
# reconciler's children-detection paths AND the decomposition nudge
# will fire next cycle. Caller should post a one-time warning.
#
# Arguments:
#   $1 - parent issue body text
_parent_body_has_phase_markers() {
	local body="$1"
	[[ -n "$body" ]] || return 1

	# Fast path — any recognised heading is sufficient. Ordered by frequency
	# observed in the aidevops backlog (## Children most common). Accepts
	# both `## Phases` (singular-sub-list style) and `## Phase N[: ...]`
	# (per-phase subsection style).
	if printf '%s' "$body" | grep -qE '^##[[:space:]]+(Children|Child [Ii]ssues|Sub-?[Tt]asks|Phases?([[:space:]]+.*)?)[[:space:]]*$' 2>/dev/null; then
		return 0
	fi

	# Prose patterns — must match _extract_children_from_prose's contract
	# byte-for-byte so this check and the reconciler agree on what counts.
	if printf '%s' "$body" | grep -qE '(^|[^a-zA-Z0-9_])([Pp]hase[[:space:]]+[0-9]+[^#]*#[0-9]+|[Ff]iled[[:space:]]+as[[:space:]]*#[0-9]+|[Tt]racks[[:space:]]+#[0-9]+|[Bb]locked[[:space:]]-?[[:space:]]*by[[:space:]]*:?[[:space:]]*#[0-9]+)'; then
		return 0
	fi

	return 1
}

# t2442: Post an idempotent warning comment on a newly-created issue that
# was labelled `parent-task` but whose body has no decomposition markers.
# This closes the loop between label application (which is now synchronous
# via t2436) and the downstream reconciler — without markers, the
# reconciler will nudge-then-escalate over 7+ days; we surface the problem
# at CREATION time so the maintainer can either add markers, drop the
# label, or decompose immediately.
#
# Non-blocking — this is a nudge, not a gate. The issue is already
# created; the comment is informational.
#
# Idempotent via the `<!-- parent-task:no-markers-warning -->` marker.
# Re-runs (e.g. from a follow-up issue edit that re-fires the warn path)
# are no-ops.
#
# Arguments:
#   $1 - repo slug (owner/repo)
#   $2 - issue number (must exist)
# Returns: 0 if comment posted, 1 if skipped (marker present, missing
# args, or API failure — all non-fatal).
_post_parent_task_no_markers_warning() {
	local slug="$1"
	local issue_num="$2"

	[[ -n "$slug" ]] || return 1
	[[ "$issue_num" =~ ^[0-9]+$ ]] || return 1

	local marker='<!-- parent-task:no-markers-warning -->'

	# Idempotency check — skip if already commented. Best-effort on API
	# failure: fall through to post a potentially-duplicate comment
	# rather than silently dropping the warning.
	local existing=""
	# t2572: comments API caps at 30/page; --paginate concatenates. Cannot
	# combine --slurp with --jq (gh api rejects). Stream per-page and count.
	existing=$(gh api --paginate "repos/${slug}/issues/${issue_num}/comments" \
		--jq ".[] | select(.body | contains(\"${marker}\")) | .id" |
		wc -l | tr -d ' ') || existing=""
	if [[ "$existing" =~ ^[1-9][0-9]*$ ]]; then
		return 1
	fi

	local comment_body="${marker}
## Parent-task label applied — body has no decomposition markers

This issue was just labelled \`parent-task\`, which **blocks pulse dispatch unconditionally** (see \`dispatch-dedup-helper.sh\` → \`PARENT_TASK_BLOCKED\`). The body does not currently include any of the markers the pulse's reconciler understands:

- \`## Children\` / \`## Child issues\` / \`## Sub-tasks\` heading with \`#NNNN\` references
- \`## Phase\` heading
- Prose patterns like \`Phase 1 split out as #NNNN\`, \`filed as #NNNN\`, \`tracks #NNNN\`, \`Blocked by: #NNNN\`

Without at least one of these, this issue will:

1. Sit blocked (no worker can pick it up).
2. Receive a decomposition nudge on the next pulse cycle (\`<!-- parent-needs-decomposition -->\`).
3. Receive a one-time advisory escalation after 7 days if still unresolved (t2442).
4. Be picked up by the auto-decomposer scanner after 4h if the nudge sits (t2442/t2949) — a \`tier:thinking\` worker will be dispatched to propose a decomposition plan.

**Quick fixes — pick one:**

1. **Add phase markers** by editing this body. Even a single \`## Phases\` heading with a short list is enough.
2. **Drop the parent-task label** if this is actually a single unit of work:

   \`\`\`
   gh issue edit ${issue_num} --repo ${slug} --remove-label parent-task
   \`\`\`

3. **Let the auto-decomposer handle it** — do nothing. The scanner will dispatch a decomposition worker in ~24h.

See \`.agents/AGENTS.md\` → \"Parent / meta tasks\" (t1986 / t2442) for the full rule. Parent-task is for epics and roadmap trackers that will never be implemented as a single unit — only their children will.

_Automated by \`_post_parent_task_no_markers_warning\` in \`issue-sync-lib-compose.sh\` (t2442). Posted once per issue via the \`${marker}\` marker; re-runs are no-ops._"

	gh issue comment "$issue_num" --repo "$slug" \
		--body "$comment_body" >/dev/null 2>&1 || return 1

	return 0
}

# =============================================================================
# Compose — Issue Body
# =============================================================================

# Build the metadata header block (lines 1-2 + tags) for an issue body.
# Outputs the header text (no trailing newline).
# Arguments:
#   $1 - task_id
#   $2 - status
#   $3 - estimate
#   $4 - actual
#   $5 - detected_plan_id
#   $6 - assignee
#   $7 - logged
#   $8 - started
#   $9 - completed
#   $10 - verified
#   $11 - tags
_compose_issue_metadata() {
	local task_id="$1"
	local status="$2"
	local estimate="$3"
	local actual="$4"
	local detected_plan_id="$5"
	local assignee="$6"
	local logged="$7"
	local started="$8"
	local completed="$9"
	local verified="${10}"
	local tags="${11}"

	# Line 1: task ID + scalar fields
	local header="**Task ID:** \`$task_id\`"
	[[ -n "$status" ]] && header="$header | **Status:** $status"
	[[ -n "$estimate" ]] && header="$header | **Estimate:** \`$estimate\`"
	[[ -n "$actual" ]] && header="$header | **Actual:** \`$actual\`"
	[[ -n "$detected_plan_id" ]] && header="$header | **Plan:** \`$detected_plan_id\`"

	# Line 2: dates and assignment
	local meta_line2=""
	if [[ -n "$assignee" ]]; then
		if [[ "$assignee" =~ ^[A-Za-z0-9._-]+$ ]]; then
			meta_line2="**Assignee:** @$assignee"
		else
			meta_line2="**Assignee:** $assignee"
		fi
	fi
	[[ -n "$logged" ]] && meta_line2="${meta_line2:+$meta_line2 | }**Logged:** $logged"
	[[ -n "$started" ]] && meta_line2="${meta_line2:+$meta_line2 | }**Started:** $started"
	[[ -n "$completed" ]] && meta_line2="${meta_line2:+$meta_line2 | }**Completed:** $completed"
	[[ -n "$verified" ]] && meta_line2="${meta_line2:+$meta_line2 | }**Verified:** $verified"
	[[ -n "$meta_line2" ]] && header="$header"$'\n'"$meta_line2"

	# Tags line
	if [[ -n "$tags" ]]; then
		local formatted_tags
		# shellcheck disable=SC2016  # & in sed replacement is sed syntax, not a bash expression
		formatted_tags=$(echo "$tags" | sed 's/,/ /g' | sed 's/#//g' | sed 's/[^ ]*/`&`/g')
		header="$header"$'\n'"**Tags:** $formatted_tags"
	fi

	echo "$header"
	return 0
}

# Append plan context sections (purpose, extras, progress, decisions, discoveries).
# Outputs the appended body text.
# Arguments:
#   $1 - current body text
#   $2 - plan_section text
_compose_issue_plan_sections() {
	local body="$1"
	local plan_section="$2"

	local purpose
	purpose=$(extract_plan_purpose "$plan_section")
	[[ -n "$purpose" ]] && body="$body"$'\n\n'"## Plan: Purpose"$'\n\n'"$purpose"

	local extra_sections
	extra_sections=$(extract_plan_extra_sections "$plan_section")
	[[ -n "$extra_sections" ]] && body="$body"$'\n\n'"${ISSUE_SYNC_DETAILS_OPEN}<summary>Plan: Context &amp; Architecture</summary>"$'\n'"$extra_sections"$'\n\n'"$ISSUE_SYNC_DETAILS_CLOSE"

	local progress
	progress=$(extract_plan_progress "$plan_section")
	[[ -n "$progress" ]] && body="$body"$'\n\n'"${ISSUE_SYNC_DETAILS_OPEN}<summary>Plan: Progress</summary>"$'\n\n'"$progress"$'\n\n'"$ISSUE_SYNC_DETAILS_CLOSE"

	local decisions
	decisions=$(extract_plan_decisions "$plan_section")
	[[ -n "$decisions" ]] && body="$body"$'\n\n'"${ISSUE_SYNC_DETAILS_OPEN}<summary>Plan: Decision Log</summary>"$'\n\n'"$decisions"$'\n\n'"$ISSUE_SYNC_DETAILS_CLOSE"

	local discoveries
	discoveries=$(extract_plan_discoveries "$plan_section")
	[[ -n "$discoveries" ]] && body="$body"$'\n\n'"${ISSUE_SYNC_DETAILS_OPEN}<summary>Plan: Discoveries</summary>"$'\n\n'"$discoveries"$'\n\n'"$ISSUE_SYNC_DETAILS_CLOSE"

	echo "$body"
	return 0
}

# Append related PRD/task files section to the body.
# Arguments:
#   $1 - current body text
#   $2 - task_id
#   $3 - project_root
_COMPOSE_RELATED_FILE_ABS=""
_COMPOSE_RELATED_FILE_REL=""

_compose_validate_related_file() {
	local file="$1"
	local project_root="$2"
	local tasks_dir="$project_root/todo/tasks"
	local tasks_root="" file_parent="" file_name="" resolved_parent="" resolved_file=""
	_COMPOSE_RELATED_FILE_ABS=""
	_COMPOSE_RELATED_FILE_REL=""

	[[ -n "$file" && "$file" == /* && -f "$file" && ! -L "$file" ]] || return 1
	[[ "$file" != *$'\n'* && "$file" != *$'\r'* && "$file" != *$'\t'* ]] || return 1
	[[ "$file" != *"\$'\\n'"* ]] || return 1
	tasks_root=$(cd "$tasks_dir" 2>/dev/null && pwd -P) || return 1
	file_parent="${file%/*}"
	file_name="${file##*/}"
	[[ -n "$file_parent" && -n "$file_name" && "$file_name" != "." && "$file_name" != ".." ]] || return 1
	resolved_parent=$(cd "$file_parent" 2>/dev/null && pwd -P) || return 1
	resolved_file="${resolved_parent}/${file_name}"
	[[ -f "$resolved_file" && ! -L "$resolved_file" ]] || return 1
	case "$resolved_file" in
	"$tasks_root"/*) ;;
	*) return 1 ;;
	esac

	_COMPOSE_RELATED_FILE_ABS="$resolved_file"
	_COMPOSE_RELATED_FILE_REL="todo/tasks/${resolved_file#"$tasks_root"/}"
	return 0
}

_compose_issue_related_files() {
	local body="$1"
	local task_id="$2"
	local project_root="$3"

	local related_files="" file="" rel_path="" file_summary=""
	if ! related_files=$(find_related_files "$task_id" "$project_root"); then
		print_error "Refusing Related Files for $task_id: related-file discovery failed"
		return 1
	fi
	if [[ -z "$related_files" ]]; then
		echo "$body"
		return 0
	fi

	body="$body"$'\n\n'"## Related Files"
	while IFS= read -r file; do
		if [[ -n "$file" ]]; then
			if ! _compose_validate_related_file "$file" "$project_root"; then
				print_error "Refusing Related Files for $task_id: a path is not a regular repository-relative todo/tasks file"
				return 1
			fi
			rel_path="$_COMPOSE_RELATED_FILE_REL"
			file_summary=$(extract_file_summary "$_COMPOSE_RELATED_FILE_ABS" 30)
			if [[ -n "$file_summary" ]]; then
				body="$body"$'\n\n'"${ISSUE_SYNC_DETAILS_OPEN}<summary><code>$rel_path</code></summary>"$'\n\n'"$file_summary"$'\n\n'"$ISSUE_SYNC_DETAILS_CLOSE"
			else
				body="$body"$'\n\n'"- [\`$rel_path\`]($rel_path)"
			fi
		fi
	done <<<"$related_files"

	echo "$body"
	return 0
}

# Resolve plan section and plan ID from a task's plan_link or auto-detection.
# Outputs two lines: first line is detected_plan_id (may be empty), remaining lines are plan_section.
# Arguments:
#   $1 - plan_link (may be empty)
#   $2 - task_id
#   $3 - project_root
_resolve_plan_context() {
	local plan_link="$1"
	local task_id="$2"
	local project_root="$3"

	local plan_section="" detected_plan_id=""
	if [[ -n "$plan_link" ]]; then
		plan_section=$(extract_plan_section "$plan_link" "$project_root")
		if [[ -n "$plan_section" ]]; then
			detected_plan_id=$(echo "$plan_section" | awk '
				/^<!--TOON:plan\{/ { getline data; if (match(data, /^p[0-9]+,/)) { print substr(data, RSTART, RLENGTH-1); exit } }
			' || true)
		fi
	else
		local auto_detected
		auto_detected=$(find_plan_by_task_id "$task_id" "$project_root")
		if [[ -n "$auto_detected" ]]; then
			detected_plan_id=$(echo "$auto_detected" | head -1)
			plan_section=$(echo "$auto_detected" | tail -n +2)
		fi
	fi

	# Output: line 1 = plan ID (empty string if none), remaining = plan section text
	printf '%s\n' "$detected_plan_id"
	[[ -n "$plan_section" ]] && printf '%s\n' "$plan_section"
	return 0
}

# Append description, dependencies, and notes sections to the body.
# Arguments:
#   $1 - current body text
#   $2 - description
#   $3 - blocked_by
#   $4 - blocks
#   $5 - notes
_compose_issue_content() {
	local body="$1"
	local description="$2"
	local blocked_by="$3"
	local blocks="$4"
	local notes="$5"

	[[ -n "$description" ]] && body="$body"$'\n\n'"## Outcome"$'\n\n'"$description"
	[[ -n "$blocked_by" ]] && body="$body"$'\n\n'"**Blocked by:** \`$blocked_by\`"
	[[ -n "$blocks" ]] && body="$body"$'\n'"**Blocks:** \`$blocks\`"
	[[ -n "$notes" ]] && body="$body"$'\n\n'"## Notes"$'\n\n'"$notes"

	echo "$body"
	return 0
}

# Append an explicit pointer to the central brief workflow used for generated
# GitHub content. This keeps the workflow contract visible in generated issue
# bodies instead of relying on agent memory.
# Arguments:
#   $1 - current body text
_compose_issue_brief_workflow_reference() {
	local body="$1"

	if [[ "$body" == *"## Brief Workflow"* ]]; then
		echo "$body"
		return 0
	fi

	body="$body"$'\n\n'"$ISSUE_SYNC_DETAILS_OPEN"$'\n'"<summary>Brief workflow contract</summary>"$'\n\n'"## Brief Workflow"$'\n\n'"This issue body is composed under \`.agents/workflows/brief.md\`. Newly queued auto-dispatch work must pass its \`Dispatch Readiness Contract (brief schema v2)\`: complete write surface, hazards and compatibility, executable verification mapped to affected surfaces, and positive plus negative/regression acceptance criteria."$'\n\n'"$ISSUE_SYNC_DETAILS_CLOSE"

	echo "$body"
	return 0
}

# Append subtasks section to the body, converting TODO.md checkbox format to GitHub checkboxes.
# Arguments:
#   $1 - current body text
#   $2 - subtasks text (multi-line, from extract_subtasks)
_compose_issue_subtasks() {
	local body="$1"
	local subtasks="$2"

	if [[ -z "$subtasks" ]]; then
		echo "$body"
		return 0
	fi

	body="$body"$'\n\n'"## Subtasks"$'\n'
	while IFS= read -r subtask_line; do
		local gh_line
		gh_line=$(echo "$subtask_line" | sed -E 's/^[[:space:]]+//' | sed -E 's/^- \[x\]/- [x]/' | sed -E 's/^- \[ \]/- [ ]/' | sed -E 's/^- \[-\] (.*)/- [x] ~~\1~~/')
		body="$body"$'\n'"$gh_line"
	done <<<"$subtasks"

	echo "$body"
	return 0
}

# Append HTML implementation notes and the sync footer to the body.
# Arguments:
#   $1 - current body text
#   $2 - first_line (raw task line, may contain <!-- --> comments)
_compose_issue_html_notes_and_footer() {
	local body="$1"
	local first_line="$2"

	# Match HTML comments — use sed to extract content between <!-- and -->
	# Handles comments containing > characters (e.g., "use a -> b pattern")
	local html_comments
	html_comments=$(echo "$first_line" | sed -n 's/.*\(<!--.*-->\).*/\1/p' | sed 's/<!--//;s/-->//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
	[[ -n "$html_comments" ]] && body="$body"$'\n\n'"## Implementation Notes"$'\n\n'"$html_comments"

	body="$body"$'\n\n'"---"$'\n'"*Synced from TODO.md by issue-sync-helper.sh*"

	# t1899: Append provenance signature footer (AGENTS.md signature rule)
	local sig_helper
	sig_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gh-signature-helper.sh"
	if [[ -x "$sig_helper" ]]; then
		local sig_footer
		sig_footer=$("$sig_helper" footer --body "$body" 2>/dev/null || echo "")
		[[ -n "$sig_footer" ]] && body="$body"$'\n'"$sig_footer"
	fi

	echo "$body"
	return 0
}

# Append all body sections: description, subtasks, plan, related files, brief.
# Arguments:
#   $1 - current body text
#   $2 - block (full task block from TODO.md)
#   $3 - description
#   $4 - blocked_by
#   $5 - blocks
#   $6 - plan_section
#   $7 - task_id
#   $8 - project_root
_compose_issue_sections() {
	local body="$1"
	local block="$2"
	local description="$3"
	local blocked_by="$4"
	local blocks="$5"
	local plan_section="$6"
	local task_id="$7"
	local project_root="$8"

	local notes subtasks
	notes=$(extract_notes "$block")
	body=$(_compose_issue_content "$body" "$description" "$blocked_by" "$blocks" "$notes")

	subtasks=$(extract_subtasks "$block")
	body=$(_compose_issue_subtasks "$body" "$subtasks")

	if [[ -n "$plan_section" ]]; then
		body=$(_compose_issue_plan_sections "$body" "$plan_section")
	fi

	body=$(_compose_issue_related_files "$body" "$task_id" "$project_root") || return 1
	body=$(_compose_issue_worker_guidance "$body" "$project_root/todo/tasks/${task_id}-brief.md") || return 1
	body=$(_compose_issue_brief "$body" "$project_root/todo/tasks/${task_id}-brief.md") || return 1
	body=$(_compose_issue_brief_workflow_reference "$body")

	echo "$body"
	return 0
}

# Extract worker guidance from the brief's "How" section (t1900).
# Promotes the complete schema-v2 How contract, including write surface,
# hazards/compatibility, and verification-before-dispatch sections. The raw
# headings remain machine-readable inside a collapsed reader-facing section.
# Arguments:
#   $1 - current body text
#   $2 - brief_file path
_compose_issue_worker_guidance() {
	local body="$1"
	local brief_file="$2"

	if [[ ! -f "$brief_file" ]]; then
		echo "$body"
		return 0
	fi

	# Extract the "How" section content between "## How" and the next "##" heading
	local how_section
	how_section=$(awk '
		/^## How/ { capture=1; next }
		/^## / && capture { exit }
		capture { print }
	' "$brief_file")

	if [[ -z "$how_section" ]]; then
		echo "$body"
		return 0
	fi

	# Historical briefs retain the t2063 heading gate. Schema-v2 briefs use the
	# complete readiness validator so placeholder-only guidance is never promoted.
	local has_files has_steps is_schema_v2
	local promote=0
	has_files=$(echo "$how_section" | grep -ic '### Files to Modify\|EDIT:\|NEW:' || true)
	has_steps=$(echo "$how_section" | grep -ic '### Implementation Steps' || true)
	is_schema_v2=$(grep -cF '<!-- aidevops:brief-schema=v2 -->' "$brief_file" || true)

	if [[ "$is_schema_v2" -gt 0 ]]; then
		local readiness_helper="$SCRIPT_DIR/brief-readiness-helper.sh"
		local brief_body=""
		brief_body=$(<"$brief_file")
		brief_body=$(bash "$readiness_helper" scope-normalize "$brief_body") || return 1
		if [[ -f "$readiness_helper" ]] && bash "$readiness_helper" check --body "$brief_body" >/dev/null 2>&1; then
			promote=1
		fi
	elif [[ "$has_files" -gt 0 || "$has_steps" -gt 0 ]]; then
		promote=1
	fi

	if [[ "$promote" -eq 1 ]]; then
		local done_when=""
		if ! printf '%s\n' "$body" | grep -qiE '^## (Done when|Acceptance Criteria)[[:space:]]*$'; then
			done_when=$(awk '
				/^## Acceptance [Cc]riteria[[:space:]]*$/ { capture=1; next }
				/^## / && capture { exit }
				capture && /^- \[[ xX]\]/ { print }
			' "$brief_file")
		fi
		if [[ -n "$done_when" ]]; then
			body="$body"$'\n\n'"## Done when"$'\n\n'"$done_when"
		fi
		body="$body"$'\n\n'"$ISSUE_SYNC_DETAILS_OPEN"$'\n'"<summary>Worker implementation contract</summary>"$'\n\n'"## Worker Guidance"$'\n\n'"$how_section"$'\n\n'"$ISSUE_SYNC_DETAILS_CLOSE"
	fi

	echo "$body"
	return 0
}

# Append task brief content to the body (strips YAML frontmatter).
# Arguments:
#   $1 - current body text
#   $2 - brief_file path
_compose_issue_brief() {
	local body="$1"
	local brief_file="$2"

	if [[ ! -f "$brief_file" ]]; then
		echo "$body"
		return 0
	fi

	local brief_content
	local drop_promoted_how=0
	local drop_promoted_acceptance=0
	[[ "$body" == *"## Worker Guidance"* ]] && drop_promoted_how=1
	[[ "$body" == *"## Done when"* ]] && drop_promoted_acceptance=1
	brief_content=$(awk -v drop_how="$drop_promoted_how" -v drop_acceptance="$drop_promoted_acceptance" '
		BEGIN { in_front=0; front_done=0 }
		/^---$/ && !front_done { in_front=!in_front; if(!in_front) front_done=1; next }
		!in_front && /^# / { next }
		!in_front && drop_how == 1 && /^## How([[:space:](]|$)/ { in_how=1; next }
		!in_front && in_how && /^## / { in_how=0 }
		!in_front && drop_acceptance == 1 && /^## Acceptance [Cc]riteria[[:space:]]*$/ { in_acceptance=1; next }
		!in_front && in_acceptance && /^## / { in_acceptance=0 }
		!in_front && !in_how && !in_acceptance { print }
	' "$brief_file")

	if [[ -n "$brief_content" && ${#brief_content} -gt 10 ]]; then
		body="$body"$'\n\n'"$ISSUE_SYNC_DETAILS_OPEN"$'\n'"<summary>Full task brief and audit context</summary>"$'\n\n'"## Task Brief"$'\n\n'"$brief_content"$'\n\n'"$ISSUE_SYNC_DETAILS_CLOSE"
	fi

	# Keep composition pure: the author persists the same transformation with
	# prepare-scope before publication. Never rewrite a mirror during body sync.
	if printf '%s\n' "$body" | grep -qiE '^#{2,3} Files (to Modify|Scope)[[:space:]]*$'; then
		body=$(bash "$SCRIPT_DIR/brief-readiness-helper.sh" scope-normalize "$body") || return 1
	fi

	echo "$body"
	return 0
}

# Compose a rich issue body from all available task context.
# Arguments:
#   $1 - task_id
#   $2 - project_root
compose_issue_body() {
	local task_id="$1"
	local project_root="$2"

	local todo_file="$project_root/TODO.md"
	if [[ ! -f "$todo_file" ]]; then
		print_error "TODO.md not found at $todo_file"
		return 1
	fi

	# Extract the full task block
	local block
	block=$(extract_task_block "$task_id" "$todo_file")
	if [[ -z "$block" ]]; then
		print_error "Task $task_id not found in TODO.md"
		return 1
	fi

	# Parse the main task line
	local first_line
	first_line=$(echo "$block" | head -1)
	local parsed
	parsed=$(parse_task_line "$first_line")

	# Extract fields from parsed output using a single pass (avoids repeated grep|cut subshells)
	local description="" tags="" estimate="" plan_link="" status="" logged=""
	local assignee="" started="" completed="" actual="" blocked_by="" blocks="" verified=""
	while IFS='=' read -r key value; do
		case "$key" in
		description) description="$value" ;;
		tags) tags="$value" ;;
		estimate) estimate="$value" ;;
		plan_link) plan_link="$value" ;;
		status) status="$value" ;;
		logged) logged="$value" ;;
		assignee) assignee="$value" ;;
		started) started="$value" ;;
		completed) completed="$value" ;;
		actual) actual="$value" ;;
		blocked_by) blocked_by="$value" ;;
		blocks) blocks="$value" ;;
		verified) verified="$value" ;;
		esac
	done <<<"$parsed"

	# Resolve plan context (plan ID + section text) via helper.
	# _resolve_plan_context outputs: line 1 = plan ID, remaining lines = plan section.
	local plan_context detected_plan_id plan_section
	plan_context=$(_resolve_plan_context "$plan_link" "$task_id" "$project_root")
	detected_plan_id=$(echo "$plan_context" | head -1)
	plan_section=$(echo "$plan_context" | tail -n +2)

	# Build metadata header
	local body
	body=$(_compose_issue_metadata \
		"$task_id" "$status" "$estimate" "$actual" "$detected_plan_id" \
		"$assignee" "$logged" "$started" "$completed" "$verified" "$tags")

	# All body sections: description, subtasks, plan, related files, brief
	body=$(_compose_issue_sections "$body" "$block" "$description" "$blocked_by" "$blocks" "$plan_section" "$task_id" "$project_root") || return 1

	# HTML implementation notes and footer
	body=$(_compose_issue_html_notes_and_footer "$body" "$first_line")

	echo "$body"
	return 0
}
