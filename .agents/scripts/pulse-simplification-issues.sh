#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Pulse Simplification — Issue Creation
# =============================================================================
# Issue body building and GitHub issue creation for both shell (.sh) and
# markdown (.md) complexity findings. Extracted from pulse-simplification.sh
# as part of the file-size-debt split (GH#21306, parent #21146).
#
# Usage: source "${SCRIPT_DIR}/pulse-simplification-issues.sh"
#
# Dependencies:
#   - shared-constants.sh (gh_issue_list, gh_create_issue, etc.)
#   - pulse-simplification-scan.sh (_complexity_scan_has_existing_issue,
#     _complexity_scan_close_duplicate_issues_by_title, _complexity_scan_check_open_cap)
#   - pulse-simplification-state.sh (_simplification_state_check)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_PULSE_SIMPLIFICATION_ISSUES_LIB_LOADED:-}" ]] && return 0
_PULSE_SIMPLIFICATION_ISSUES_LIB_LOADED=1

SIMPLIFICATION_DEBT_LABEL=function-complexity-debt
SIMPLIFICATION_AUTO_DISPATCH_LABEL=auto-dispatch
SIMPLIFICATION_STATUS_AVAILABLE_LABEL=status:available
SIMPLIFICATION_ORIGIN_WORKER_LABEL=origin:worker
SIMPLIFICATION_TIER_STANDARD_LABEL=tier:standard

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
    _lib_path="${BASH_SOURCE[0]%/*}"
    [[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
    SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
    unset _lib_path
fi

# Determine whether an agent doc qualifies for a simplification issue.
# Not every .agents/*.md file is actionable — files below the 500-line default,
# empty stubs, and YAML-only frontmatter files are not candidates. This gate
# prevents flooding the issue tracker with non-actionable entries (CodeRabbit
# GH#6879, GH#25926).
# Arguments: $1 - full_path, $2 - line_count
# Returns: 0 if the file should get an issue, 1 if it should be skipped
_complexity_scan_should_open_md_issue() {
	local full_path="$1"
	local line_count="$2"

	# Skip files below the minimum actionable size
	if [[ "$line_count" -lt "$COMPLEXITY_MD_MIN_LINES" ]]; then
		return 1
	fi

	# Skip files that are mostly YAML frontmatter (e.g., stub agent definitions).
	# If >60% of lines are inside the frontmatter block, there's no prose to simplify.
	local frontmatter_end=0
	if head -1 "$full_path" 2>/dev/null | grep -q '^---$'; then
		frontmatter_end=$(awk 'NR==1 && /^---$/ { in_fm=1; next } in_fm && /^---$/ { print NR; exit }' "$full_path" 2>/dev/null)
		frontmatter_end=${frontmatter_end:-0}
	fi
	if [[ "$frontmatter_end" -gt 0 ]]; then
		local content_lines=$((line_count - frontmatter_end))
		# If content after frontmatter is less than 40% of total, skip
		local threshold=$(((line_count * 40) / 100))
		if [[ "$content_lines" -lt "$threshold" ]]; then
			return 1
		fi
	fi

	return 0
}

# Collect agent docs (.md files in .agents/) for simplification analysis.
# The default 500-line gate keeps the scan focused on files large enough to
# justify simplification work. Classification (instruction doc vs reference
# corpus) still determines whether to compress prose or split into chapters.
# Files must pass _complexity_scan_should_open_md_issue to be included —
# this filters out stubs, short files, and frontmatter-only definitions.
# Protected files (build.txt, AGENTS.md, pulse.md, pulse-sweep.md) are excluded — these are
# core infrastructure that must be simplified manually with a maintainer present.
# Results are sorted longest-first so biggest wins come early.
# Arguments: $1 - aidevops_path
# Outputs: scan_results (pipe-delimited lines: file_path|line_count) via stdout
_complexity_scan_collect_md_violations() {
	local aidevops_path="$1"

	# Protected files and directories — excluded from automated simplification.
	# - build.txt, AGENTS.md, pulse.md, pulse-sweep.md: core infrastructure (code-simplifier.md)
	# - templates/: template files meant to be copied, not compressed
	# - README.md: navigation/index docs, not instruction docs
	# - todo/: planning files, not code
	local protected_pattern='prompts/build\.txt|^\.agents/AGENTS\.md|^AGENTS\.md|scripts/commands/pulse\.md|scripts/commands/pulse-sweep\.md'
	local excluded_dirs='_archive/|/templates/|/todo/'
	local excluded_files='/README\.md$'

	local md_files
	md_files=$(git -C "$aidevops_path" ls-files '*.md' | grep -E '^\.agents/' | grep -Ev "$excluded_dirs" | grep -Ev "$excluded_files" | grep -Ev "$protected_pattern" || true)
	if [[ -z "$md_files" ]]; then
		echo "[pulse-wrapper] Complexity scan (.md): no agent doc files found" >>"$LOGFILE"
		return 1
	fi

	local scan_results=""
	local file_count=0
	local skipped_count=0
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		local full_path="${aidevops_path}/${file}"
		[[ -f "$full_path" ]] || continue
		local lc
		lc=$(wc -l <"$full_path" 2>/dev/null | tr -d ' ')
		if _complexity_scan_should_open_md_issue "$full_path" "$lc"; then
			scan_results="${scan_results}${file}|${lc}"$'\n'
			file_count=$((file_count + 1))
		else
			skipped_count=$((skipped_count + 1))
		fi
	done <<<"$md_files"

	# Sort longest-first (descending by line count after the pipe)
	scan_results=$(printf '%s' "$scan_results" | sort -t'|' -k2 -rn)

	echo "[pulse-wrapper] Complexity scan (.md): ${file_count} agent docs qualified, ${skipped_count} skipped (below ${COMPLEXITY_MD_MIN_LINES}-line threshold or stub)" >>"$LOGFILE"
	printf '%s' "$scan_results"
	return 0
}

# Extract a concise, meaningful topic label from a markdown file's H1 heading.
# For chapter-style headings such as "# Chapter 13: Heatmap Analysis", returns
# "Heatmap Analysis" so issue titles stay semantic instead of numeric-only.
# Arguments: $1 - aidevops_path, $2 - file_path (repo-relative)
# Outputs: topic label via stdout
_complexity_scan_extract_md_topic_label() {
	local aidevops_path="$1"
	local file_path="$2"
	local full_path="${aidevops_path}/${file_path}"

	if [[ ! -f "$full_path" ]]; then
		return 1
	fi

	local heading
	heading=$(awk '/^# / { print; exit }' "$full_path" 2>/dev/null)
	if [[ -z "$heading" ]]; then
		return 1
	fi

	local topic
	topic=$(printf '%s' "$heading" | sed -E 's/^#[[:space:]]*//; s/^[Cc][Hh][Aa][Pp][Tt][Ee][Rr][[:space:]]*[0-9]+[[:space:]]*[:.-]?[[:space:]]*//; s/^[[:space:]]+//; s/[[:space:]]+$//')
	if [[ -z "$topic" ]]; then
		return 1
	fi

	# Keep issue titles concise and stable
	topic=$(printf '%s' "$topic" | cut -c1-80)
	printf '%s' "$topic"
	return 0
}

# Build the GitHub issue body for an agent doc flagged for simplification review.
# Arguments:
#   $1 - file_path (repo-relative)
#   $2 - line_count
#   $3 - topic_label (may be empty)
# Output: issue body text to stdout
_complexity_scan_build_md_issue_body() {
	local file_path="$1"
	local line_count="$2"
	local topic_label="$3"

	cat <<ISSUE_BODY_EOF
<!-- aidevops:generator=agent-doc-simplification-gate cited_file=${file_path} threshold=${COMPLEXITY_MD_MIN_LINES:-500} -->

## Agent doc simplification (automated scan)

**File:** \`${file_path}\`
**Detected topic:** ${topic_label:-Unknown}
**Current size:** ${line_count} lines

### Classify before acting

**First, determine the file type** — the correct action depends on whether this is an instruction doc or a reference corpus:

- **Instruction doc** (agent rules, workflows, decision trees, operational procedures): Tighten prose, reorder by importance, split if multiple concerns. Follow guidance below.
- **Reference corpus** (SKILL.md, domain knowledge base, textbook-style content with self-contained sections): Do NOT compress content. Instead, split into chapter files with a slim index. See \`tools/code-review/code-simplifier.md\` "Reference corpora" classification (GH#6432).

### For instruction docs — proposed action

Tighten and restructure this agent doc. Follow \`tools/build-agent/build-agent.md\` guidance. Key principles:

1. **Preserve all institutional knowledge** — every verbose rule exists because something broke without it. Do not remove task IDs, incident references, error statistics, or decision rationale. Compress prose, not knowledge.
2. **Order by importance** — most critical instructions first (primacy effect: LLMs weight earlier context more heavily). Security rules, core workflow, then edge cases.
3. **Split if needed** — if the file covers multiple distinct concerns, extract sub-docs with a parent index. Use progressive disclosure (pointers, not inline content).
4. **Use search patterns, not line numbers** — any \`file:line_number\` references to other files go stale on every edit. Use \`rg "pattern"\` or section heading references instead.

### For reference corpora — proposed action

1. **Extract each major section** into its own file (e.g., \`01-introduction.md\`, \`02-fundamentals.md\`)
2. **Replace the original with a slim index** (~100-200 lines) — table of contents with one-line descriptions and file pointers
3. **Zero content loss** — every line moves to a chapter file, nothing is deleted or compressed
4. **Reconcile existing chapter files** — if partial splits already exist, deduplicate and keep the most complete version

### Worker guidance

**Reference pattern:** \`.agents/reference/large-file-split.md\` (playbook for splits — covers orchestrator pattern, identity-key preservation, and PR body template).

**Precedent in this repo:** \`issue-sync-helper.sh\` + \`issue-sync-lib.sh\` (simple split) and \`headless-runtime-lib.sh\` + sub-libraries (complex split). For agent docs, see existing chapter-file splits in \`.agents/reference/\`.

**Expected CI gate overrides:** If this PR triggers a complexity regression from restructured files, apply the \`complexity-bump-ok\` label AND include a \`## Complexity Bump Justification\` section in the PR body citing scanner evidence. See the playbook section 4 (Known CI False-Positive Classes).

### Verification

- Content preservation: all code blocks, URLs, task ID references (\`tNNN\`, \`GH#NNN\`), and command examples must be present before and after
- No broken internal links or references
- Agent behaviour unchanged (test with a representative query if possible)
- Qlty smells resolved for the target file: \`~/.qlty/bin/qlty smells --all 2>&1 | grep '${file_path}' | grep -c . | grep -q '^0$'\` (report \`SKIP\` if Qlty is unavailable, not \`FAIL\`)
- For reference corpora: \`wc -l\` total of chapter files >= original line count minus index overhead

### Confidence: medium

Automated scan flagged this file for maintainer review. The best simplification strategy requires human judgment — some files are appropriately structured already. Reference corpora (SKILL.md, domain knowledge bases) need restructuring into chapters, not content reduction.

---
**To approve or decline**, comment on this issue:
- \`approved\` — removes the review gate and queues for automated dispatch
- \`declined: <reason>\` — closes this issue (include your reason after the colon)
ISSUE_BODY_EOF
	return 0
}

# Determine whether an unchanged agent doc should get another pass.
# Arguments: $1 - state_file, $2 - file_path, $3 - line_count
# Returns: 0 if another pass is allowed, 1 if the state has converged or the
#          file is below threshold.
_complexity_scan_md_repeat_due() {
	local state_file="$1"
	local file_path="$2"
	local line_count="$3"

	if [[ "$line_count" -lt "$COMPLEXITY_MD_MIN_LINES" ]]; then
		return 1
	fi

	local max_passes="${SIMPLIFICATION_MAX_PASSES:-3}"
	local passes
	passes=$(jq -r --arg fp "$file_path" '.files[$fp].passes // 0' "$state_file" 2>/dev/null) || passes=0
	[[ "$passes" =~ ^[0-9]+$ ]] || passes=0

	if [[ "$passes" -ge "$max_passes" ]]; then
		return 1
	fi

	return 0
}

# Determine early-exit status for a single agent doc file.
# Checks simplification state (unchanged/converged) and open-issue dedup.
# Arguments: $1 - aidevops_slug, $2 - file_path, $3 - state_file, $4 - aidevops_path, $5 - line_count
# Output: unchanged|converged|existing|new|recheck|repeat via stdout
# Returns: 0 always
_complexity_scan_md_file_status() {
	local aidevops_slug="$1"
	local file_path="$2"
	local state_file="$3"
	local aidevops_path="$4"
	local line_count="${5:-0}"

	local file_status="new"
	if [[ -n "$state_file" && -n "$aidevops_path" ]]; then
		file_status=$(_simplification_state_check "$aidevops_path" "$file_path" "$state_file")
		if [[ "$file_status" == "converged" ]]; then
			printf '%s' "$file_status"
			return 0
		fi
		if [[ "$file_status" == "unchanged" ]]; then
			if _complexity_scan_md_repeat_due "$state_file" "$file_path" "$line_count"; then
				file_status=repeat
			else
				printf '%s' "$file_status"
				return 0
			fi
		fi
		# Recheck falls through to get a new issue with the recheck label.
	fi

	if _complexity_scan_has_existing_issue "$aidevops_slug" "$file_path"; then
		printf '%s' "existing"
		return 0
	fi

	printf '%s' "$file_status"
	return 0
}

# Build the full issue body for an agent doc: base body + optional recheck note + sig footer.
# Arguments: $1 - file_path, $2 - line_count, $3 - topic_label,
#            $4 - recheck_mode (none, recheck, repeat), $5 - state_file
# Output: full issue body to stdout
# Returns: 0 always
_complexity_scan_md_build_full_body() {
	local file_path="$1"
	local line_count="$2"
	local topic_label="$3"
	local recheck_mode="$4"
	local state_file="$5"

	local issue_body
	issue_body=$(_complexity_scan_build_md_issue_body "$file_path" "$line_count" "$topic_label")

	if [[ "$recheck_mode" == recheck || "$recheck_mode" == repeat ]]; then
		local prev_pr
		prev_pr=$(jq -r --arg fp "$file_path" '.files[$fp].pr // 0' "$state_file" 2>/dev/null) || prev_pr="0"
		if [[ "$recheck_mode" == repeat ]]; then
			issue_body="${issue_body}

### Next-pass note

This file was previously simplified (PR #${prev_pr}) and its content hash is unchanged, but it still meets the ${COMPLEXITY_MD_MIN_LINES}-line simplification threshold. Please run the next simplification pass unless the file is intentionally converged."
		else
			issue_body="${issue_body}

### Recheck note

This file was previously simplified (PR #${prev_pr}) but has since been modified. The content hash no longer matches the post-simplification state. Please re-evaluate."
		fi
	fi

	# Append signature footer. The pulse-wrapper runs as standalone bash via
	# launchd (not inside OpenCode), so --no-session skips session DB lookups.
	# Pass elapsed time and 0 tokens to show honest stats (GH#13099).
	local sig_footer="" _pulse_elapsed=""
	_pulse_elapsed=$(($(date +%s) - PULSE_START_EPOCH))
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer \
		--body "$issue_body" --cli "OpenCode" --no-session \
		--tokens 0 --time "$_pulse_elapsed" --session-type routine 2>/dev/null || true)
	printf '%s%s' "$issue_body" "$sig_footer"
	return 0
}

# Process a single agent doc file for simplification issue creation (GH#5627).
# Checks simplification state, dedup, changed-since-simplification status,
# builds title/body, and creates issue.
#
# Arguments:
#   $1 - file_path (repo-relative)
#   $2 - line_count
#   $3 - aidevops_slug
#   $4 - aidevops_path
#   $5 - state_file (may be empty)
#   $6 - maintainer
# Output: single line to stdout — "created", "skipped", or "failed"
_complexity_scan_process_single_md_file() {
	local file_path="$1"
	local line_count="$2"
	local aidevops_slug="$3"
	local aidevops_path="$4"
	local state_file="$5"
	local maintainer="$6"

	local file_status
	file_status=$(_complexity_scan_md_file_status "$aidevops_slug" "$file_path" "$state_file" "$aidevops_path" "$line_count")
	case "$file_status" in
	unchanged)
		echo "[pulse-wrapper] Complexity scan (.md): skipping ${file_path} — already simplified (hash unchanged)" >>"$LOGFILE"
		echo "skipped"
		return 0
		;;
	converged)
		echo "[pulse-wrapper] Complexity scan (.md): skipping ${file_path} — converged after ${SIMPLIFICATION_MAX_PASSES:-3} passes (t1754)" >>"$LOGFILE"
		echo "skipped"
		return 0
		;;
	existing)
		echo "[pulse-wrapper] Complexity scan (.md): skipping ${file_path} — existing open issue" >>"$LOGFILE"
		echo "skipped"
		return 0
		;;
	esac
	# file_status is new, recheck, or repeat at this point.

	local topic_label=""
	if [[ -n "$aidevops_path" ]]; then
		topic_label=$(_complexity_scan_extract_md_topic_label "$aidevops_path" "$file_path" 2>/dev/null || true)
	fi

	local recheck_mode=none
	[[ "$file_status" == recheck || "$file_status" == repeat ]] && recheck_mode="$file_status"

	local issue_title="simplification: tighten agent doc ${file_path} (${line_count} lines)"
	if [[ -n "$topic_label" ]]; then
		issue_title="simplification: tighten agent doc ${topic_label} (${file_path}, ${line_count} lines)"
	fi
	[[ "$file_status" == recheck ]] && issue_title="recheck: ${issue_title}"
	[[ "$file_status" == repeat ]] && issue_title="next-pass: ${issue_title}"

	local issue_body
	issue_body=$(_complexity_scan_md_build_full_body "$file_path" "$line_count" "$topic_label" "$recheck_mode" "$state_file")

	# Non-maintainer admins receive an explicit review hold; NMR is reserved for
	# external-author trust gates (GH#16786/GH#29394).
	local review_label=""
	if [[ "${_COMPLEXITY_SCAN_SKIP_REVIEW_GATE:-false}" != "true" ]]; then
		review_label="--label hold-for-review"
	fi

	local create_ok=false
	# t1955: Don't self-assign on issue creation — let dispatch_with_dedup handle
	# assignment. Self-assigning creates a phantom claim that triggers stale recovery.
	if [[ "$recheck_mode" != none ]]; then
		# shellcheck disable=SC2086
		gh_create_issue --repo "$aidevops_slug" \
			--title "$issue_title" \
			--label "$SIMPLIFICATION_DEBT_LABEL" $review_label --label "$SIMPLIFICATION_AUTO_DISPATCH_LABEL" --label "$SIMPLIFICATION_STATUS_AVAILABLE_LABEL" \
			--label "$SIMPLIFICATION_ORIGIN_WORKER_LABEL" --label "$SIMPLIFICATION_TIER_STANDARD_LABEL" --label "recheck-simplicity" \
			--body "$issue_body" >/dev/null 2>&1 && create_ok=true
	else
		# shellcheck disable=SC2086
		gh_create_issue --repo "$aidevops_slug" \
			--title "$issue_title" \
			--label "$SIMPLIFICATION_DEBT_LABEL" $review_label --label "$SIMPLIFICATION_AUTO_DISPATCH_LABEL" --label "$SIMPLIFICATION_STATUS_AVAILABLE_LABEL" \
			--label "$SIMPLIFICATION_ORIGIN_WORKER_LABEL" --label "$SIMPLIFICATION_TIER_STANDARD_LABEL" \
			--body "$issue_body" >/dev/null 2>&1 && create_ok=true
	fi

	if [[ "$create_ok" == true ]]; then
		_complexity_scan_close_duplicate_issues_by_title "$aidevops_slug" "$issue_title"
		local log_suffix=""
		[[ "$file_status" == recheck ]] && log_suffix=" [RECHECK]"
		[[ "$file_status" == repeat ]] && log_suffix=" [NEXT-PASS]"
		echo "[pulse-wrapper] Complexity scan (.md): created issue for ${file_path} (${line_count} lines)${log_suffix}" >>"$LOGFILE"
		echo "created"
	else
		echo "[pulse-wrapper] Complexity scan (.md): failed to create issue for ${file_path}" >>"$LOGFILE"
		echo "failed"
	fi
	return 0
}

# Create GitHub issues for agent docs flagged for simplification review.
# Default to tier:standard — simplification requires reading the file, understanding
# its structure, deciding what to extract vs compress, and preserving institutional
# knowledge. Haiku-tier models lack the judgment for this; they over-compress,
# lose task IDs, or restructure without understanding the reasoning behind the
# original layout. Maintainers can raise to tier:thinking for architectural docs.
# Arguments: $1 - scan_results (pipe-delimited: file_path|line_count), $2 - repos_json, $3 - aidevops_slug
_complexity_scan_create_md_issues() {
	local scan_results="$1"
	local repos_json="$2"
	local aidevops_slug="$3"
	local max_issues_per_run=5
	local issues_created=0
	local issues_skipped=0

	# Total-open cap: stop creating when backlog is already large
	_complexity_scan_check_open_cap "$aidevops_slug" 500 "Complexity scan (.md)" || return 0

	local maintainer
	maintainer=$(jq -r --arg slug "$aidevops_slug" \
		'.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' \
		"$repos_json" 2>/dev/null)
	if [[ -z "$maintainer" ]]; then
		maintainer=$(echo "$aidevops_slug" | cut -d/ -f1)
	fi

	local aidevops_path
	aidevops_path=$(jq -r --arg slug "$aidevops_slug" \
		'.initialized_repos[] | select(.slug == $slug) | .path' \
		"$repos_json" 2>/dev/null | head -n 1)

	# Simplification state file — tracks already-simplified files by git blob hash
	local state_file=""
	if [[ -n "$aidevops_path" ]]; then
		state_file="${aidevops_path}/.agents/configs/simplification-state.json"
	fi

	while IFS='|' read -r file_path line_count; do
		[[ -n "$file_path" ]] || continue
		[[ "$issues_created" -ge "$max_issues_per_run" ]] && break

		local result
		result=$(_complexity_scan_process_single_md_file "$file_path" "$line_count" \
			"$aidevops_slug" "$aidevops_path" "$state_file" "$maintainer")

		case "$result" in
		created) issues_created=$((issues_created + 1)) ;;
		skipped) issues_skipped=$((issues_skipped + 1)) ;;
		*) ;; # failed — logged by helper, no counter change
		esac
	done <<<"$scan_results"
	echo "[pulse-wrapper] Complexity scan (.md) complete: ${issues_created} issues created, ${issues_skipped} skipped (existing/simplified)" >>"$LOGFILE"
	return 0
}

# Build issue body for a shell file complexity finding, with signature footer appended.
# Arguments: $1 - file_path, $2 - violation_count, $3 - details (function-detail text)
# Output: full body to stdout
# Returns: 0 always
_complexity_scan_sh_build_issue_body_with_sig() {
	local file_path="$1"
	local violation_count="$2"
	local details="$3"

	local issue_body
	issue_body="<!-- aidevops:generator=function-complexity-gate cited_file=${file_path} threshold=${COMPLEXITY_FUNC_LINE_THRESHOLD} -->

## Complexity scan finding (automated, GH#5628)

**File:** \`${file_path}\`
**Violations:** ${violation_count} functions exceed ${COMPLEXITY_FUNC_LINE_THRESHOLD} lines

### Functions exceeding threshold

\`\`\`
${details}
\`\`\`

### Proposed action

Break down the listed functions into smaller, focused helper functions. Each function should ideally be under ${COMPLEXITY_FUNC_LINE_THRESHOLD} lines.

**Reference pattern:** \`.agents/reference/large-file-split.md\` (playbook for shell-lib splits — covers orchestrator pattern, identity-key preservation, and PR body template).

**Precedent in this repo:** \`issue-sync-helper.sh\` + \`issue-sync-lib.sh\` (simple split) and \`headless-runtime-lib.sh\` + sub-libraries (complex split). Copy the include-guard and SCRIPT_DIR-fallback pattern from the simple precedent.

**Expected CI gate overrides:** This PR may trigger a complexity regression from function extraction. Apply the \`complexity-bump-ok\` label AND include a \`## Complexity Bump Justification\` section in the PR body citing scanner evidence. See the playbook section 4 (Known CI False-Positive Classes).

### Verification

- \`bash -n <file>\` (syntax check)
- \`shellcheck <file>\` (lint)
- Run existing tests if present
- Confirm no functionality is lost

### Confidence: medium

This is an automated scan. The function lengths are factual, but the best decomposition strategy requires human judgment.

---
**To approve or decline**, comment on this issue:
- \`approved\` — removes the review gate and queues for automated dispatch
- \`declined: <reason>\` — closes this issue (include your reason after the colon)"

	# Append signature footer (--no-session + elapsed time, GH#13099)
	local sig_footer="" _pulse_elapsed=""
	_pulse_elapsed=$(($(date +%s) - PULSE_START_EPOCH))
	sig_footer=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer \
		--body "$issue_body" --cli "OpenCode" --no-session \
		--tokens 0 --time "$_pulse_elapsed" --session-type routine 2>/dev/null || true)
	printf '%s%s' "$issue_body" "$sig_footer"
	return 0
}

# Create a GitHub issue for a single shell file with function-complexity violations.
# Assumes nesting-only and dedup checks have already passed (caller's responsibility).
# Arguments: $1 - file_path, $2 - violation_count, $3 - repos_json, $4 - aidevops_slug
# Returns: 0 if issue created, 1 if failed
_complexity_scan_sh_create_issue() {
	local file_path="$1"
	local violation_count="$2"
	local repos_json="$3"
	local aidevops_slug="$4"

	# Compute function details (not in scan_results to avoid breaking IFS='|', GH#5630)
	local aidevops_path
	aidevops_path=$(jq -r --arg slug "$aidevops_slug" \
		'.initialized_repos[] | select(.slug == $slug) | .path' \
		"$repos_json" 2>/dev/null | head -n 1)
	local details=""
	if [[ -n "$aidevops_path" && -f "${aidevops_path}/${file_path}" ]]; then
		# Use -v to pass the threshold safely — interpolating shell variables into
		# awk scripts is a security risk and breaks if the value contains quotes (GH#18555).
		details=$(awk -v threshold="$COMPLEXITY_FUNC_LINE_THRESHOLD" '
			/^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ { fname=$1; sub(/\(\)/, "", fname); start=NR; next }
			fname && /^\}$/ { lines=NR-start; if(lines+0>threshold+0) printf "%s() %d lines\n", fname, lines; fname="" }
		' "${aidevops_path}/${file_path}" | head -10)
	fi

	local issue_body
	issue_body=$(_complexity_scan_sh_build_issue_body_with_sig "$file_path" "$violation_count" "$details")

	local issue_title="simplification: reduce function complexity in ${file_path} (${violation_count} functions >${COMPLEXITY_FUNC_LINE_THRESHOLD} lines)"
	# Non-maintainer admins receive an explicit review hold.
	local review_label_sh=""
	if [[ "${_COMPLEXITY_SCAN_SKIP_REVIEW_GATE:-false}" != "true" ]]; then
		review_label_sh="--label hold-for-review"
	fi
	# t1955: Don't self-assign — let dispatch_with_dedup handle assignment.
	# shellcheck disable=SC2086
	if gh_create_issue --repo "$aidevops_slug" \
		--title "$issue_title" \
		--label "$SIMPLIFICATION_DEBT_LABEL" $review_label_sh --label "$SIMPLIFICATION_AUTO_DISPATCH_LABEL" \
		--label "$SIMPLIFICATION_STATUS_AVAILABLE_LABEL" --label "$SIMPLIFICATION_ORIGIN_WORKER_LABEL" --label "$SIMPLIFICATION_TIER_STANDARD_LABEL" \
		--body "$issue_body" >/dev/null 2>&1; then
		_complexity_scan_close_duplicate_issues_by_title "$aidevops_slug" "$issue_title"
		echo "[pulse-wrapper] Complexity scan: created issue for ${file_path} (${violation_count} violations)" >>"$LOGFILE"
		return 0
	fi
	echo "[pulse-wrapper] Complexity scan: failed to create issue for ${file_path}" >>"$LOGFILE"
	return 1
}

# Create GitHub issues for qualifying files (dedup via server-side title search).
# Arguments: $1 - scan_results (pipe-delimited: file_path|count), $2 - repos_json, $3 - aidevops_slug
# Returns: 0 always
_complexity_scan_create_issues() {
	local scan_results="$1"
	local repos_json="$2"
	local aidevops_slug="$3"
	local max_issues_per_run=5
	local issues_created=0
	local issues_skipped=0

	# Total-open cap: stop creating when backlog is already large
	_complexity_scan_check_open_cap "$aidevops_slug" 500 "Complexity scan" || return 0

	local maintainer
	maintainer=$(jq -r --arg slug "$aidevops_slug" \
		'.initialized_repos[] | select(.slug == $slug) | .maintainer // empty' \
		"$repos_json" 2>/dev/null)
	if [[ -z "$maintainer" ]]; then
		maintainer=$(echo "$aidevops_slug" | cut -d/ -f1)
	fi

	while IFS='|' read -r file_path violation_count; do
		[[ -n "$file_path" ]] || continue
		[[ "$issues_created" -ge "$max_issues_per_run" ]] && break

		# Skip nesting-only violations (GH#17632): files flagged solely for max_nesting
		# exceeding the threshold have violation_count=0 (no long functions). The current
		# issue template is function-length-specific; creating a "0 functions >100 lines"
		# issue is misleading and produces false-positive dispatch work.
		if [[ "${violation_count:-0}" -eq 0 ]]; then
			echo "[pulse-wrapper] Complexity scan: skipping ${file_path} — nesting-only violation (0 long functions)" >>"$LOGFILE"
			issues_skipped=$((issues_skipped + 1))
			continue
		fi

		# Dedup via server-side title search — accurate across all issues (GH#5630)
		if _complexity_scan_has_existing_issue "$aidevops_slug" "$file_path"; then
			echo "[pulse-wrapper] Complexity scan: skipping ${file_path} — existing open issue" >>"$LOGFILE"
			issues_skipped=$((issues_skipped + 1))
			continue
		fi

		if _complexity_scan_sh_create_issue "$file_path" "$violation_count" "$repos_json" "$aidevops_slug"; then
			issues_created=$((issues_created + 1))
		fi
	done <<<"$scan_results"
	echo "[pulse-wrapper] Complexity scan complete: ${issues_created} issues created, ${issues_skipped} skipped (existing)" >>"$LOGFILE"
	return 0
}
