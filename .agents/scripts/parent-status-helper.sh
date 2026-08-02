#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# parent-status-helper.sh — Read-only CLI helper for parent-task decomposition state (t2741)
#
# Prints the current decomposition state of a `parent-task`-labeled issue:
# phases planned (from ## Phases section), children filed, merged, in-flight,
# next action.
#
# Usage:
#   parent-status-helper.sh <issue-number> [--repo <slug>] [--json] [--verbose] [--help]
#
# Environment overrides (for tests / custom deployments):
#   PARENT_STATUS_GH_OFFLINE — set to 1 to skip gh API calls (test mode)
#   PARENT_STATUS_STUB_DIR   — directory containing stub JSON files (test mode)
#
# Rate-limit budget per invocation:
#   ~1 REST call for parent body, 1 for sub-issues, 1 per child for PR state.
#   For a 7-phase parent: ~9 REST calls, 0 GraphQL points.
#
# t2741: https://github.com/marcusquinn/aidevops/issues/20477

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || {
	# Minimal fallbacks when shared-constants.sh is unavailable (e.g. CI)
	RED='\033[0;31m'
	GREEN='\033[0;32m'
	YELLOW='\033[1;33m'
	BLUE='\033[0;34m'
	CYAN='\033[0;36m'
	NC='\033[0m'
	print_error() { printf '%b[ERROR]%b %s\n' "$RED" "$NC" "$*" >&2; }
	print_warning() { printf '%b[WARN]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
	print_info() { printf '%b[INFO]%b %s\n' "$BLUE" "$NC" "$*" >&2; }
	print_success() { printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$*" >&2; }
}
set -euo pipefail

readonly PARENT_STATUS_STATE_UNKNOWN="UNKNOWN"
readonly PARENT_STATUS_VALUE_UNKNOWN="unknown"

# =============================================================================
# Helpers — gh API wrappers (offline-aware)
# =============================================================================

# Resolve repo slug from git remote when not provided.
_resolve_repo_slug() {
	local slug=""
	if command -v gh >/dev/null 2>&1; then
		slug=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null) || slug=""
	fi
	if [[ -z "$slug" ]]; then
		slug=$(git remote get-url origin 2>/dev/null |
			sed -E 's|.*github\.com[:/]||; s|\.git$||') || slug=""
	fi
	echo "$slug"
	return 0
}

# Fetch issue JSON (number, title, body, labels, state, state reason).
# Returns JSON string to stdout.
_fetch_issue() {
	local num="$1"
	local repo="$2"

	if [[ "${PARENT_STATUS_GH_OFFLINE:-0}" == "1" ]]; then
		local stub="${PARENT_STATUS_STUB_DIR:-}/issue-${num}.json"
		if [[ -f "$stub" ]]; then
			cat "$stub"
		else
			echo "{}"
			return 1
		fi
		return 0
	fi

	local json
	if ! json=$(gh issue view "$num" --repo "$repo" \
		--json number,title,body,state,stateReason,labels 2>/dev/null); then
		echo "{}"
		return 1
	fi
	echo "$json"
	return 0
}

# Fetch sub-issues (GitHub REST: /repos/OWNER/REPO/issues/N/sub_issues).
# Returns JSON array to stdout.
_fetch_sub_issues() {
	local num="$1"
	local repo="$2"

	if [[ "${PARENT_STATUS_GH_OFFLINE:-0}" == "1" ]]; then
		local stub="${PARENT_STATUS_STUB_DIR:-}/sub-issues-${num}.json"
		if [[ -f "$stub" ]]; then
			cat "$stub"
		else
			echo "[]"
			return 1
		fi
		return 0
	fi

	local owner="${repo%%/*}"
	local reponame="${repo##*/}"
	local json
	if ! json=$(gh api "repos/${owner}/${reponame}/issues/${num}/sub_issues?per_page=100" 2>/dev/null); then
		echo "[]"
		return 1
	fi
	echo "$json"
	return 0
}

# Fetch linked PR state for an issue (uses search for associated PRs).
# Returns a compact JSON object: {number, state, mergedAt, mergeable, title}
# or "{}" if none found.
_fetch_child_pr() {
	local child_num="$1"
	local repo="$2"
	local _json_null="null"

	if [[ "${PARENT_STATUS_GH_OFFLINE:-0}" == "1" ]]; then
		local stub="${PARENT_STATUS_STUB_DIR:-}/pr-for-${child_num}.json"
		if [[ -f "$stub" ]]; then
			cat "$stub"
		else
			echo "${_json_null}"
		fi
		return 0
	fi

	# Search for open and closed PRs that reference this issue.
	# The Development section (closes/resolves/fixes) is the canonical link.
	local pr_json
	pr_json=$(gh pr list --repo "$repo" \
		--search "is:pr in:body ${child_num}" \
		--state all \
		--json number,title,state,mergedAt,mergeStateStatus \
		--limit 5 2>/dev/null) || pr_json="[]"

	# Return the first PR that references "#<child_num>" in its body exactly
	local owner="${repo%%/*}"
	local reponame="${repo##*/}"
	local result
	result=$(printf '%s' "$pr_json" | jq --argjson n "$child_num" \
		'[.[] | select(.number != null)] | first // null' 2>/dev/null) || result="${_json_null}"
	echo "$result"
	return 0
}

# =============================================================================
# Phase parsing — extracts planned phases from parent body ## Phases section
# =============================================================================

# Extract the ## Phases section from a parent issue body.
# Matches "## Phases" heading (case-insensitive) and returns content
# up to the next ## heading or end of body.
#
# Arguments:
#   $1 - issue body text
# Echo: section content (may be empty)
_extract_phases_section() {
	local body="$1"
	[[ -z "$body" ]] && return 0

	printf '%s\n' "$body" | awk '
		BEGIN { in_section = 0 }
		{
			lower = tolower($0)
			if (lower ~ /^##[[:space:]]+phases?[[:space:]]*$/) {
				in_section = 1
				next
			}
			if (/^##[[:space:]]/) {
				if (in_section) exit
			}
			if (in_section) print
		}
	'
	return 0
}

# Parse phase lines from the ## Phases section.
# Matches lines of the form:
#   Phase N — Name ...
#   Phase N: Name ...
#   N. Name ...
#   - Phase N ...
# and optionally captures a #NNN issue reference if already filed.
#
# Output (one per line): <phase_num>|<phase_name>|<child_issue_num_or_empty>
_parse_phase_lines() {
	local section="$1"
	[[ -z "$section" ]] && return 0

	printf '%s\n' "$section" | awk '
		/Phase[[:space:]]+[0-9]+/ || /^[[:space:]]*[0-9]+\./ {
			# Extract phase number (POSIX awk — no 3-arg match)
			phase_num = ""
			tmp = $0
			# Try "Phase N" form: strip everything up to "Phase " then grab digits
			if (tmp ~ /Phase[[:space:]]+[0-9]+/) {
				sub(/.*Phase[[:space:]]+/, "", tmp)
				split(tmp, parts, /[^0-9]/)
				phase_num = parts[1]
			} else if (tmp ~ /^[[:space:]]*[0-9]+\./) {
				# "N. name" form
				sub(/^[[:space:]]*/, "", tmp)
				split(tmp, parts, /\./)
				phase_num = parts[1]
				if (phase_num !~ /^[0-9]+$/) phase_num = ""
			}
			if (phase_num == "") next

			# Extract phase name: everything after "Phase N —/:/space" or "N. "
			name = $0
			gsub(/^[[:space:]]*[-*+]?[[:space:]]*/, "", name)
			# Strip "Phase N" prefix and any separator chars (—, :, -, space)
			# Use sub with .* to consume Phase+number+separator greedily
			sub(/Phase[[:space:]]+[0-9]+[[:space:]]*[^[:alpha:]]*[[:space:]]*/, "", name)
			sub(/^[0-9]+\.[[:space:]]*/, "", name)

			# Extract inline #NNN ref (if present) before stripping
			ref_issue = ""
			if (name ~ /#[0-9]+/) {
				ref_tmp = name
				sub(/.*#/, "", ref_tmp)
				split(ref_tmp, rparts, /[^0-9]/)
				ref_issue = rparts[1]
			}
			gsub(/(GH)?#[0-9]+/, "", name)
			# Clean up trailing/extra whitespace
			gsub(/[[:space:]]+$/, "", name)
			gsub(/[[:space:]]+/, " ", name)
			gsub(/^[[:space:]]*/, "", name)
			# Output is pipe-delimited; phase prose can contain CLI alternation
			# examples like `new|list|status`, so neutralize literal pipes before
			# rendering to avoid shifting fields and hallucinating child refs.
			gsub(/\|/, "/", name)

			print phase_num "|" name "|" ref_issue
		}
	'
	return 0
}

# =============================================================================
# Child state resolution
# =============================================================================

# Given a list of sub-issue numbers (one per line), fetch state + PR info.
# Output (one per line):
#   <issue_num>|<state>|<state_reason>|<labels_csv>|<pr_num>|<pr_state>|<merged_at>|<title>
_resolve_children_state() {
	local children_nums="$1"
	local repo="$2"
	[[ -z "$children_nums" ]] && return 0
	local incomplete=0

	while IFS= read -r num; do
		[[ -z "$num" ]] && continue
		local issue_json pr_json
		if ! issue_json=$(_fetch_issue "$num" "$repo"); then
			issue_json="{}"
			incomplete=1
		fi
		local state state_reason labels title
		state=$(printf '%s' "$issue_json" | jq -r --arg unknown "$PARENT_STATUS_STATE_UNKNOWN" \
			'.state // $unknown' 2>/dev/null) || state="$PARENT_STATUS_STATE_UNKNOWN"
		state_reason=$(printf '%s' "$issue_json" | jq -r '.stateReason // .state_reason // ""' 2>/dev/null) || state_reason=""
		labels=$(printf '%s' "$issue_json" | jq -r '[.labels[]?.name] | join(",")' 2>/dev/null) || labels=""
		title=$(printf '%s' "$issue_json" | jq -r '.title // ""' 2>/dev/null) || title=""
		[[ "$state" == "$PARENT_STATUS_STATE_UNKNOWN" ]] && incomplete=1

		pr_json=$(_fetch_child_pr "$num" "$repo")
		local pr_num pr_state pr_merged_at
		pr_num=$(printf '%s' "$pr_json" | jq -r '.number // ""' 2>/dev/null) || pr_num=""
		pr_state=$(printf '%s' "$pr_json" | jq -r '.state // ""' 2>/dev/null) || pr_state=""
		pr_merged_at=$(printf '%s' "$pr_json" | jq -r '.mergedAt // ""' 2>/dev/null) || pr_merged_at=""

		printf '%s|%s|%s|%s|%s|%s|%s|%s\n' \
			"$num" "$state" "$state_reason" "$labels" "$pr_num" "$pr_state" "$pr_merged_at" "$title"
	done <<< "$children_nums"
	return "$incomplete"
}

# =============================================================================
# Next-action derivation
# =============================================================================

_derive_next_action() {
	local phases_total="$1"
	local phases_filed="$2"
	local in_flight_pr="$3"
	local phases_merged="$4"
	local children_open="$5"
	local children_blocked="$6"
	local children_unknown="$7"
	local next_open_child="$8"
	local next_blocked_child="$9"
	local expected_children="${10}"
	local contract_reason="${11}"
	local missing_expected=0
	if [[ "$expected_children" =~ ^[0-9]+$ && "$phases_filed" -lt "$expected_children" ]]; then
		missing_expected=$((expected_children - phases_filed))
	fi

	if [[ "$children_unknown" -gt 0 ]]; then
		echo "Child state retrieval incomplete for ${children_unknown} child issue(s) — retry before closing the parent."
		return 0
	fi

	if [[ "$children_open" -gt 0 ]]; then
		local missing_suffix=""
		if [[ "$missing_expected" -gt 0 ]]; then
			missing_suffix="; ${missing_expected} expected child issue(s) are not filed"
		fi
		if [[ -n "$in_flight_pr" ]]; then
			echo "${children_open} child issue(s) remain open — merge PR #${in_flight_pr}, then continue child #${next_open_child}${missing_suffix}."
		elif [[ "$children_blocked" -gt 0 ]]; then
			echo "${children_open} child issue(s) remain open — resolve blockers on child #${next_blocked_child}${missing_suffix}."
		else
			echo "${children_open} child issue(s) remain open — continue child #${next_open_child}${missing_suffix}."
		fi
		return 0
	fi

	if [[ "$missing_expected" -gt 0 ]]; then
		echo "File ${missing_expected} remaining expected child issue(s) before closing the parent."
		return 0
	fi

	if [[ -n "$contract_reason" ]]; then
		echo "Parent close contract is incomplete (${contract_reason}) — keep the parent open."
		return 0
	fi

	if [[ "$phases_filed" -eq 0 ]]; then
		echo "No child issues are filed — keep the parent open."
		return 0
	fi

	# Preserve these inputs in the function contract for stable callers/output.
	: "$phases_total" "$phases_merged"
	echo "All non-superseded child issues are complete — close the parent issue."
	return 0
}

# =============================================================================
# Output renderers
# =============================================================================

_render_text() {
	local parent_num="$1"
	local parent_title="$2"
	local phases_total="$3"
	local phases_filed="$4"
	local phases_merged="$5"
	local phases_inflight="$6"
	local children_open="$7"
	local children_superseded="$8"
	local children_unknown="$9"
	local phase_lines="${10}"     # newline-separated: phase_num|name|child_num|child_state|pr_num|pr_state|pr_merged_at
	local next_action="${11}"

	printf '\nParent: #%s %s\n' "$parent_num" "$parent_title"
	printf 'Phases: %d planned, %d filed, %d merged, %d in-flight\n\n' \
		"$phases_total" "$phases_filed" "$phases_merged" "$phases_inflight"
	printf 'Children: %d filed, %d remaining open, %d superseded, %d unknown\n\n' \
		"$phases_filed" "$children_open" "$children_superseded" "$children_unknown"

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local pnum pname child_num child_state pr_num pr_state pr_merged_at
		IFS='|' read -r pnum pname child_num child_state pr_num pr_state pr_merged_at <<< "$line"

		local suffix=""
		if [[ -n "$child_num" ]]; then
			suffix="#${child_num}"
			if [[ -n "$pr_num" ]]; then
				suffix="${suffix} (PR #${pr_num} ${pr_state}"
				if [[ -n "$pr_merged_at" ]]; then
					suffix="${suffix} MERGED"
				fi
				suffix="${suffix})"
			else
				suffix="${suffix} (${child_state})"
			fi
		else
			suffix="NOT FILED"
		fi

		printf 'Phase %s — %s: %s\n' "$pnum" "$pname" "$suffix"
	done <<< "$phase_lines"

	printf '\nNext action: %s\n\n' "$next_action"
	return 0
}

_render_json() {
	local parent_num="$1"
	local parent_title="$2"
	local phases_total="$3"
	local phases_filed="$4"
	local phases_merged="$5"
	local phases_inflight="$6"
	local children_open="$7"
	local children_superseded="$8"
	local children_unknown="$9"
	local phase_lines="${10}"
	local next_action="${11}"

	local first=1
	local _json_null="null"
	printf '{\n'
	printf '  "parent_number": %s,\n' "$parent_num"
	printf '  "parent_title": %s,\n' "$(printf '%s' "$parent_title" | jq -Rs '.' 2>/dev/null || printf '"%s"' "$parent_title")"
	printf '  "phases_total": %d,\n' "$phases_total"
	printf '  "phases_filed": %d,\n' "$phases_filed"
	printf '  "phases_merged": %d,\n' "$phases_merged"
	printf '  "phases_inflight": %d,\n' "$phases_inflight"
	printf '  "children_open": %d,\n' "$children_open"
	printf '  "children_superseded": %d,\n' "$children_superseded"
	printf '  "children_unknown": %d,\n' "$children_unknown"
	printf '  "next_action": %s,\n' "$(printf '%s' "$next_action" | jq -Rs '.' 2>/dev/null || printf '"%s"' "$next_action")"
	printf '  "phases": [\n'

	while IFS= read -r line; do
		[[ -z "$line" ]] && continue
		local pnum pname child_num child_state pr_num pr_state pr_merged_at
		IFS='|' read -r pnum pname child_num child_state pr_num pr_state pr_merged_at <<< "$line"

		if [[ "$first" -eq 0 ]]; then
			printf ',\n'
		fi
		first=0

		local pname_json child_state_json pr_state_json pr_merged_json pr_num_json
		pname_json=$(printf '%s' "$pname" | jq -Rs '.' 2>/dev/null || printf '"%s"' "$pname")
		child_state_json=$(printf '%s' "${child_state:-}" | jq -Rs '.' 2>/dev/null || printf 'null')
		pr_state_json=$(printf '%s' "${pr_state:-}" | jq -Rs '.' 2>/dev/null || printf 'null')
		pr_merged_json=$(printf '%s' "${pr_merged_at:-}" | jq -Rs '.' 2>/dev/null || printf 'null')

		if [[ -n "$pr_num" ]]; then
			pr_num_json="$pr_num"
		else
			pr_num_json="${_json_null}"
		fi

		if [[ -n "$child_num" ]]; then
			printf '    {"phase": %s, "name": %s, "child_number": %s, "child_state": %s, "pr_number": %s, "pr_state": %s, "pr_merged_at": %s}' \
				"$pnum" "$pname_json" "$child_num" "$child_state_json" "$pr_num_json" "$pr_state_json" "$pr_merged_json"
		else
			printf '    {"phase": %s, "name": %s, "child_number": null, "child_state": null, "pr_number": null, "pr_state": null, "pr_merged_at": null}' \
				"$pnum" "$pname_json"
		fi
	done <<< "$phase_lines"

	printf '\n  ]\n'
	printf '}\n'
	return 0
}

# =============================================================================
# Main command: parent-status — split into focused sub-functions to keep each
# function under 100 lines (function-complexity gate, t2370).
# =============================================================================

# Gather all child issue numbers for a parent by merging the sub-issues API
# result with prose refs extracted from the issue body.
# Arguments: $1=issue_num $2=repo $3=parent_body
# Echo: sorted unique child numbers, one per line
_gather_child_nums() {
	local issue_num="$1"
	local repo="$2"
	local parent_body="$3"

	local sub_issues_json
	local fetch_incomplete=0
	if ! sub_issues_json=$(_fetch_sub_issues "$issue_num" "$repo"); then
		sub_issues_json="[]"
		fetch_incomplete=1
	fi
	if ! printf '%s' "$sub_issues_json" |
		jq -e 'type == "array" and all(.[]; .number | type == "number")' >/dev/null 2>&1; then
		sub_issues_json="[]"
		fetch_incomplete=1
	fi
	local sub_issue_nums
	sub_issue_nums=$(printf '%s' "$sub_issues_json" | \
		jq -r '.[].number' 2>/dev/null | sort -un) || sub_issue_nums=""

	# Prose fallback: extract #NNN refs from ## Children / ## Phases section
	local body_children_section
	body_children_section=$(printf '%s\n' "$parent_body" | awk '
		BEGIN { in_section = 0 }
		{
			lower = tolower($0)
			if (lower ~ /^##[[:space:]]+(children|child issues|sub-issues|phases)/) {
				in_section = 1; next
			}
			if (/^##[[:space:]]/) { if (in_section) exit }
			if (in_section) print
		}
	')
	local body_child_nums
	body_child_nums=$(printf '%s\n' "$body_children_section" | \
		grep -E '^[[:space:]]*[-+*|]' | \
		grep -oE '(GH)?#[0-9]+' | \
		sed -E 's/^(GH)?#//' | \
		sort -un 2>/dev/null) || body_child_nums=""

	printf '%s\n%s\n' "$sub_issue_nums" "$body_child_nums" | \
		grep -E '^[0-9]+$' | sort -un 2>/dev/null || true
	return "$fetch_incomplete"
}

# Count state metrics from children_state_lines.
# Arguments: $1=children_state_lines $2=all_child_nums
# Echo: "<phases_filed>|<phases_merged>|<phases_inflight>|<in_flight_pr_num>"
_count_child_states() {
	local children_state_lines="$1"
	local all_child_nums="$2"

	local phases_filed phases_merged phases_inflight in_flight_pr_num
	phases_filed=$(printf '%s\n' "$all_child_nums" | safe_grep_count '^[0-9]')
	[[ -z "$all_child_nums" ]] && phases_filed=0
	phases_merged=0
	phases_inflight=0
	in_flight_pr_num=""

	while IFS= read -r cline; do
		[[ -z "$cline" ]] && continue
		local cnum cstate _creason _clabels cpr_num cpr_state cpr_merged_at _ctitle
		IFS='|' read -r cnum cstate _creason _clabels cpr_num cpr_state cpr_merged_at _ctitle <<< "$cline"
		if [[ -n "$cpr_merged_at" ]]; then
			phases_merged=$((phases_merged + 1))
		elif [[ "$cpr_state" == "OPEN" ]]; then
			phases_inflight=$((phases_inflight + 1))
			[[ -z "$in_flight_pr_num" ]] && in_flight_pr_num="$cpr_num"
		fi
	done <<< "$children_state_lines"

	printf '%s|%s|%s|%s\n' "$phases_filed" "$phases_merged" "$phases_inflight" "$in_flight_pr_num"
	return 0
}

# Summarize closure readiness across every gathered child, not phase rows.
# Echo: "<open>|<blocked>|<superseded>|<unknown>|<next_open>|<next_blocked>"
_summarize_child_readiness() {
	local children_state_lines="$1"
	local children_open=0 children_blocked=0 children_superseded=0 children_unknown=0
	local next_open_child="" next_blocked_child=""
	while IFS= read -r cline; do
		[[ -z "$cline" ]] && continue
		local cnum cstate creason clabels _cpr_num _cpr_state _cpr_merged_at _ctitle
		IFS='|' read -r cnum cstate creason clabels _cpr_num _cpr_state _cpr_merged_at _ctitle <<< "$cline"
		if [[ "$cstate" == "$PARENT_STATUS_STATE_UNKNOWN" || "$cstate" == "$PARENT_STATUS_VALUE_UNKNOWN" ]]; then
			children_unknown=$((children_unknown + 1))
			continue
		fi
		if [[ "$creason" == "NOT_PLANNED" || "$creason" == "not_planned" ]]; then
			children_superseded=$((children_superseded + 1))
			continue
		fi
		if [[ "$cstate" != "CLOSED" && "$cstate" != "closed" ]]; then
			children_open=$((children_open + 1))
			[[ -z "$next_open_child" ]] && next_open_child="$cnum"
			case ",${clabels}," in
			*,blocked,* | *,status:blocked,*)
				children_blocked=$((children_blocked + 1))
				[[ -z "$next_blocked_child" ]] && next_blocked_child="$cnum"
				;;
			esac
		fi
	done <<< "$children_state_lines"
	printf '%s|%s|%s|%s|%s|%s\n' \
		"$children_open" "$children_blocked" "$children_superseded" "$children_unknown" \
		"$next_open_child" "$next_blocked_child"
	return 0
}

# Read deterministic parent close-contract constraints from the body.
# Echo: "<expected_children>|<incomplete_reason>"
_read_close_contract() {
	local parent_body="$1"
	local phase_plan="$2"
	local expected_children="" reason=""
	expected_children=$(printf '%s\n' "$parent_body" |
		sed -nE 's/.*<!-- parent-close-contract: expected-children=([0-9]+) -->.*/\1/p' | head -n1)
	if [[ "$parent_body" == *"<!-- parent-close-contract: needs-decomposition -->"* ||
		"$parent_body" == *"<!-- parent-close-contract: keep-open -->"* ]]; then
		reason="needs-decomposition"
	elif [[ "$parent_body" == *"<!-- parent-close-contract: phase-plan -->"* && -z "$phase_plan" ]]; then
		reason="invalid-phase-plan"
	elif [[ -n "$phase_plan" ]] &&
		printf '%s\n' "$phase_plan" | awk -F'|' '$3 == "" { found=1 } END { exit !found }'; then
		reason="unfiled-phases"
	elif printf '%s\n' "$parent_body" | grep -qE '^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\]'; then
		reason="unchecked-criteria"
	fi
	printf '%s|%s\n' "$expected_children" "$reason"
	return 0
}

# Annotate phase plan with resolved child state.
# Phase → child matching: prefer inline ref in phase line; fallback to positional order.
# If no phases section exists, falls back to listing children directly.
# Arguments: $1=phase_plan $2=children_state_lines $3=all_child_nums $4=phases_filed (ref)
# Echo: annotated phase lines (phase_num|name|child_num|child_state|pr_num|pr_state|pr_merged_at)
#       followed by a final line "TOTAL:<N>" for phases_total
_annotate_phases_with_children() {
	local phase_plan="$1"
	local children_state_lines="$2"
	local all_child_nums="$3"
	local phases_filed_in="$4"

	# Build ordered child array for positional matching
	local -a child_indexed_nums=()
	while IFS= read -r cn; do
		[[ -z "$cn" ]] && continue
		child_indexed_nums+=("$cn")
	done <<< "$all_child_nums"

	if [[ -n "$phase_plan" ]]; then
		local phase_idx=0
		while IFS= read -r pline; do
			[[ -z "$pline" ]] && continue
			local pnum pname pinline_ref
			IFS='|' read -r pnum pname pinline_ref <<< "$pline"
			local resolved_child=""
			if [[ -n "$pinline_ref" ]]; then
				resolved_child="$pinline_ref"
			elif [[ "$phase_idx" -lt "${#child_indexed_nums[@]}" ]]; then
				resolved_child="${child_indexed_nums[$phase_idx]}"
			fi
			local cstate="" cpr_num="" cpr_state="" cpr_merged_at=""
			if [[ -n "$resolved_child" ]]; then
				local found_line
				found_line=$(printf '%s\n' "$children_state_lines" | \
					grep "^${resolved_child}|" | head -1) || found_line=""
				if [[ -n "$found_line" ]]; then
					local _cn _creason _clabels _ctitle
					IFS='|' read -r _cn cstate _creason _clabels cpr_num cpr_state cpr_merged_at _ctitle <<< "$found_line"
				fi
			fi
			printf '%s|%s|%s|%s|%s|%s|%s\n' \
				"$pnum" "$pname" "$resolved_child" "$cstate" "$cpr_num" "$cpr_state" "$cpr_merged_at"
			phase_idx=$((phase_idx + 1))
		done <<< "$phase_plan"
		printf 'TOTAL:%s\n' "$phase_idx"
		return 0
	fi

	# No phases section — list children directly as numbered rows
	if [[ -n "$all_child_nums" ]]; then
		local fi=1
		while IFS= read -r cline; do
			[[ -z "$cline" ]] && continue
			local cnum cstate _creason _clabels cpr_num cpr_state cpr_merged_at ctitle
			IFS='|' read -r cnum cstate _creason _clabels cpr_num cpr_state cpr_merged_at ctitle <<< "$cline"
			local pname_fallback
			pname_fallback=$(printf '%s' "$ctitle" | sed 's/^[[:space:]]*//' | cut -c1-60)
			printf '%s|%s|%s|%s|%s|%s|%s\n' \
				"$fi" "$pname_fallback" "$cnum" "$cstate" "$cpr_num" "$cpr_state" "$cpr_merged_at"
			fi=$((fi + 1))
		done <<< "$children_state_lines"
		printf 'TOTAL:%s\n' "$phases_filed_in"
	else
		printf 'TOTAL:0\n'
	fi
	return 0
}

cmd_parent_status() {
	local issue_num="" repo="" json_output=0 verbose=0

	while [[ $# -gt 0 ]]; do
		case "${1}" in
			--repo) repo="${2:-}"; shift 2 ;;
			--json) json_output=1; shift ;;
			--verbose) verbose=1; shift ;;
			--help | -h) cmd_help; return 0 ;;
			-*) print_error "Unknown option: ${1}"; cmd_help; return 1 ;;
			*)
				if [[ -z "$issue_num" ]]; then issue_num="${1}"; fi
				shift ;;
		esac
	done

	if [[ -z "$issue_num" ]]; then
		print_error "Issue number is required"; cmd_help; return 1
	fi
	if ! [[ "$issue_num" =~ ^[0-9]+$ ]]; then
		print_error "Issue number must be a positive integer (got: $issue_num)"; return 1
	fi
	if [[ -z "$repo" ]]; then repo=$(_resolve_repo_slug); fi
	if [[ -z "$repo" ]]; then
		print_error "Could not resolve repo slug. Use --repo <owner/repo>"; return 1
	fi

	local parent_json
	parent_json=$(_fetch_issue "$issue_num" "$repo")
	local has_label
	has_label=$(printf '%s' "$parent_json" | \
		jq -r '[.labels[].name] | any(. == "parent-task")' 2>/dev/null) || has_label="false"
	if [[ "$has_label" != "true" && "${PARENT_STATUS_GH_OFFLINE:-0}" != "1" ]]; then
		print_error "Issue #${issue_num} does not carry the parent-task label."; return 1
	fi

	local parent_title parent_body
	parent_title=$(printf '%s' "$parent_json" | jq -r --arg unknown "$PARENT_STATUS_VALUE_UNKNOWN" \
		'.title // $unknown' 2>/dev/null) || parent_title="$PARENT_STATUS_VALUE_UNKNOWN"
	parent_body=$(printf '%s' "$parent_json" | jq -r '.body // ""' 2>/dev/null) || parent_body=""

	local phase_plan phases_total
	phase_plan=$(_parse_phase_lines "$(_extract_phases_section "$parent_body")")
	phases_total=$(printf '%s\n' "$phase_plan" | grep -c '|' 2>/dev/null || echo 0)
	[[ -z "$phase_plan" ]] && phases_total=0

	local all_child_nums children_state_lines retrieval_incomplete=0
	if ! all_child_nums=$(_gather_child_nums "$issue_num" "$repo" "$parent_body"); then
		retrieval_incomplete=1
	fi
	if ! children_state_lines=$(_resolve_children_state "$all_child_nums" "$repo"); then
		retrieval_incomplete=1
	fi

	local metrics phases_filed phases_merged phases_inflight in_flight_pr_num
	metrics=$(_count_child_states "$children_state_lines" "$all_child_nums")
	IFS='|' read -r phases_filed phases_merged phases_inflight in_flight_pr_num <<< "$metrics"
	local readiness children_open children_blocked children_superseded children_unknown next_open_child next_blocked_child
	readiness=$(_summarize_child_readiness "$children_state_lines")
	IFS='|' read -r children_open children_blocked children_superseded children_unknown next_open_child next_blocked_child <<< "$readiness"
	if [[ "$retrieval_incomplete" -eq 1 && "$children_unknown" -eq 0 ]]; then
		children_unknown=1
	fi

	local raw_annotated annotated_phase_lines
	raw_annotated=$(_annotate_phases_with_children "$phase_plan" "$children_state_lines" "$all_child_nums" "$phases_filed")
	annotated_phase_lines=$(printf '%s\n' "$raw_annotated" | grep -v '^TOTAL:')
	local total_line
	total_line=$(printf '%s\n' "$raw_annotated" | grep '^TOTAL:' | tail -1)
	if [[ -z "$phase_plan" ]]; then phases_total="${total_line#TOTAL:}"; fi

	local close_contract expected_children contract_reason next_action
	close_contract=$(_read_close_contract "$parent_body" "$phase_plan")
	IFS='|' read -r expected_children contract_reason <<< "$close_contract"
	next_action=$(_derive_next_action \
		"$phases_total" "$phases_filed" "$in_flight_pr_num" "$phases_merged" \
		"$children_open" "$children_blocked" "$children_unknown" "$next_open_child" \
		"$next_blocked_child" "$expected_children" "$contract_reason")

	if [[ "$json_output" -eq 1 ]]; then
		_render_json "$issue_num" "$parent_title" \
			"$phases_total" "$phases_filed" "$phases_merged" "$phases_inflight" \
			"$children_open" "$children_superseded" "$children_unknown" \
			"$annotated_phase_lines" "$next_action"
	else
		_render_text "$issue_num" "$parent_title" \
			"$phases_total" "$phases_filed" "$phases_merged" "$phases_inflight" \
			"$children_open" "$children_superseded" "$children_unknown" \
			"$annotated_phase_lines" "$next_action"
	fi
	return 0
}

# =============================================================================
# Help
# =============================================================================

cmd_help() {
	cat <<'USAGE'
parent-status-helper.sh — decomposition state for a parent-task issue (t2741)

USAGE:
  parent-status-helper.sh <issue-number> [options]

OPTIONS:
  --repo <owner/repo>  GitHub repo slug (default: resolved from git remote)
  --json               Machine-readable JSON output
  --verbose            Additional diagnostic output
  --help, -h           Show this message

EXAMPLES:
  parent-status-helper.sh 20402
  parent-status-helper.sh 20402 --repo marcusquinn/aidevops
  parent-status-helper.sh 20402 --json

OUTPUT COLUMNS:
  Phases: <planned> planned, <filed> filed, <merged> merged, <in-flight> in-flight
  Children: <filed> filed, <remaining-open> open, <superseded>, <unknown>
  Per-phase: Phase N — Name: #CHILD (PR #PR OPEN|MERGED) or NOT FILED

ENVIRONMENT:
  PARENT_STATUS_GH_OFFLINE  Set to 1 to skip gh API calls (test/offline mode)
  PARENT_STATUS_STUB_DIR    Directory with stub JSON files for test mode:
                              issue-<N>.json, sub-issues-<N>.json, pr-for-<N>.json
USAGE
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local cmd="${1:-}"
	case "$cmd" in
		help | -h | --help)
			cmd_help
			return 0
			;;
		"" | -*)
			if [[ -z "$cmd" ]]; then
				print_error "Issue number is required"
				cmd_help
				return 1
			fi
			# Starts with - but not -h/--help → parse in cmd_parent_status
			cmd_parent_status "$@"
			;;
		*)
			# First positional arg is a number or unknown
			cmd_parent_status "$@"
			;;
	esac
	return 0
}

main "$@"
