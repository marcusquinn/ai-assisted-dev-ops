#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# backfill-status-available.sh (t2797 — pre-t2789 heal)
#
# One-shot (safe to re-run) helper that applies status:available to open,
# dispatchable issues missing any status:* label. Covers issues filed before
# t2789 (PR #20720) which made claim-task-id.sh apply status:available by
# default on new issues. Existing auto-dispatch issues without a status:*
# label are silently skipped by the pulse fill-floor enumerator — this
# script heals them.
#
# Usage:
#   backfill-status-available.sh [--dry-run] [--apply] [--repo owner/repo]
#                                [--json]
#
# --dry-run      Print candidate list without applying labels. DEFAULT when
#                no flag is given.
# --apply        Apply status:available (and tier:standard if no tier:* present).
# --repo SLUG    Limit to a single repo (default: all pulse-enabled repos).
# --json         NDJSON output — one line per modified/would-modify issue,
#                plus a summary line at the end.
#
# Exit codes:
#   0 — all candidates processed (or dry-run complete)
#   1 — fatal error (gh not found, repos.json missing)
#   2 — at least one issue failed to update (partial success)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || {
	printf 'ERROR: cannot source shared-constants.sh\n' >&2
	exit 1
}
# shellcheck source=renovate-dependency-dashboard-helper.sh
source "${SCRIPT_DIR}/renovate-dependency-dashboard-helper.sh"

# --- Constants ----------------------------------------------------------------

# Labels that make an issue intentionally non-dispatchable.
# Issues carrying ANY of these are excluded from backfill.
readonly EXCLUSION_LABELS=(
	"parent-task"
	"persistent"
	"consolidation-task"
	"routine-tracking"
	"no-auto-dispatch"
)

# All known status:* labels (used to detect absence via --search exclusions)
readonly STATUS_LABELS=(
	"status:available"
	"status:queued"
	"status:in-progress"
	"status:in-review"
	"status:blocked"
	"status:done"
	"status:resolved"
	"status:claimed"
)

# Action strings used in JSON output
readonly ACTION_DRY_RUN="dry-run"
readonly ACTION_APPLIED="applied"
readonly ACTION_FAILED="failed"

# --- State --------------------------------------------------------------------

DRY_RUN=1    # 1=dry-run (default), 0=apply
JSON_MODE=0  # 1=JSON output, 0=plain text
REPO_FILTER=""
TOTAL_FOUND=0
TOTAL_APPLIED=0
TOTAL_FAILED=0

# --- Helpers ------------------------------------------------------------------

usage() {
	printf 'Usage: %s [--dry-run] [--apply] [--repo owner/repo] [--json]\n' \
		"$(basename "$0")"
	return 0
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--dry-run) DRY_RUN=1 ;;
		--apply) DRY_RUN=0 ;;
		--json) JSON_MODE=1 ;;
		--repo)
			local next="${2:-}"
			REPO_FILTER="$next"
			shift
			;;
		--help | -h)
			usage
			exit 0
			;;
		*)
			printf 'Unknown argument: %s\n' "$arg" >&2
			usage >&2
			exit 1
			;;
		esac
		shift
	done
	return 0
}

# List pulse-enabled repos from repos.json, or return REPO_FILTER if set.
list_repos() {
	if [[ -n "$REPO_FILTER" ]]; then
		printf '%s\n' "$REPO_FILTER"
		return 0
	fi
	local repos_json="${HOME}/.config/aidevops/repos.json"
	[[ -f "$repos_json" ]] || {
		printf 'ERROR: repos.json not found at %s\n' "$repos_json" >&2
		return 1
	}
	jq -r '
		.initialized_repos[]
		| select(.pulse == true and (.local_only // false) == false)
		| .slug
	' "$repos_json" 2>/dev/null
	return 0
}

# Build the -label: exclusion string for gh issue list --search.
build_exclusion_query() {
	local query=""
	local label
	for label in "${STATUS_LABELS[@]}" "${EXCLUSION_LABELS[@]}"; do
		query="${query} -label:\"${label}\""
	done
	printf '%s' "$query"
	return 0
}

# Emit a JSON record for one candidate issue.
emit_json_record() {
	local repo="$1"
	local num="$2"
	local title="$3"
	local add_tier="$4"   # 1=will add tier:standard, 0=already has tier
	local action="$5"     # ACTION_DRY_RUN | ACTION_APPLIED | ACTION_FAILED
	local added_tier_str
	[[ "$add_tier" -eq 1 ]] && added_tier_str="tier:standard" || added_tier_str=""
	jq -cn \
		--arg repo "$repo" \
		--argjson num "$num" \
		--arg title "$title" \
		--arg added_tier "$added_tier_str" \
		--arg action "$action" \
		'{repo:$repo, number:$num, title:$title, added_tier:$added_tier, action:$action}'
	return 0
}

# Check if the issue has any tier:* label.
# Args: $1 = compact JSON array of label name strings
# Returns 0 if a tier label exists, 1 if not.
has_tier_label() {
	local labels_json="$1"
	printf '%s' "$labels_json" | jq -e '[.[] | select(startswith("tier:"))] | length > 0' \
		>/dev/null 2>&1
	return $?
}

# Normalize gh issue list output to a single compact JSON array.
# Args: $1 = raw gh issue list JSON output
normalize_issues_json() {
	local raw_json="$1"
	printf '%s' "$raw_json" | jq -c -s 'map(select(type == "array")) | add // []'
	return $?
}

# Apply labels to a single issue. Purely additive — never removes labels.
# Args: $1=repo $2=issue_number $3=add_tier (1=add tier:standard, 0=skip)
apply_labels() {
	local repo="$1"
	local num="$2"
	local add_tier="$3"

	gh issue edit "$num" --repo "$repo" --add-label "status:available" 2>/dev/null || return 1

	if [[ "$add_tier" -eq 1 ]]; then
		gh issue edit "$num" --repo "$repo" --add-label "tier:standard" 2>/dev/null || return 1
	fi
	return 0
}

# Process a single repo: find candidates and apply or report.
process_repo() {
	local repo="$1"

	[[ "$JSON_MODE" -eq 0 ]] && printf 'Scanning %s...\n' "$repo"

	# Build search query excluding all status:* and protected labels
	local search_query
	search_query="label:auto-dispatch$(build_exclusion_query) sort:created-asc"

	local issues_json
	issues_json=$(gh issue list --repo "$repo" \
		--state open \
		--limit 200 \
		--search "$search_query" \
		--json number,title,labels,author 2>/dev/null) || issues_json="[]"
	issues_json=$(normalize_issues_json "$issues_json") || issues_json="[]"

	local count
	count=$(printf '%s' "$issues_json" | jq -r 'length')

	if [[ "$count" -eq 0 ]]; then
		[[ "$JSON_MODE" -eq 0 ]] && printf '  No candidates found.\n'
		return 0
	fi

	# Process each candidate
	local i=0
	while [[ "$i" -lt "$count" ]]; do
		local issue_json num title labels_json add_tier
		issue_json=$(printf '%s' "$issues_json" | jq -c ".[$i]")
		if _is_renovate_dependency_dashboard_issue "$issue_json"; then
			i=$((i + 1))
			continue
		fi
		num=$(printf '%s' "$issues_json" | jq -r ".[$i].number")
		title=$(printf '%s' "$issues_json" | jq -r ".[$i].title | .[0:80]")
		labels_json=$(printf '%s' "$issues_json" | jq -c "[.[$i].labels[].name]")

		# Determine if we need to add tier:standard
		if has_tier_label "$labels_json"; then
			add_tier=0
		else
			add_tier=1
		fi

		TOTAL_FOUND=$((TOTAL_FOUND + 1))

		local tier_suffix=""
		[[ "$add_tier" -eq 1 ]] && tier_suffix=" [+tier:standard]"

		if [[ "$DRY_RUN" -eq 1 ]]; then
			if [[ "$JSON_MODE" -eq 1 ]]; then
				emit_json_record "$repo" "$num" "$title" "$add_tier" "$ACTION_DRY_RUN"
			else
				printf '  [backfill] %s#%s → status:available%s (%s)\n' \
					"$repo" "$num" "$tier_suffix" "$ACTION_DRY_RUN"
			fi
		else
			if apply_labels "$repo" "$num" "$add_tier"; then
				TOTAL_APPLIED=$((TOTAL_APPLIED + 1))
				if [[ "$JSON_MODE" -eq 1 ]]; then
					emit_json_record "$repo" "$num" "$title" "$add_tier" "$ACTION_APPLIED"
				else
					printf '  [backfill] %s#%s → status:available%s\n' \
						"$repo" "$num" "$tier_suffix"
				fi
			else
				TOTAL_FAILED=$((TOTAL_FAILED + 1))
				if [[ "$JSON_MODE" -eq 1 ]]; then
					emit_json_record "$repo" "$num" "$title" "$add_tier" "$ACTION_FAILED"
				else
					printf '  [FAILED]   %s#%s\n' "$repo" "$num" >&2
				fi
			fi
		fi

		i=$((i + 1))
	done

	return 0
}

# --- Main ---------------------------------------------------------------------

main() {
	parse_args "$@"

	command -v gh >/dev/null 2>&1 || {
		printf 'ERROR: gh CLI not found\n' >&2
		exit 1
	}

	command -v jq >/dev/null 2>&1 || {
		printf 'ERROR: jq not found\n' >&2
		exit 1
	}

	local repos
	repos=$(list_repos) || exit 1

	[[ -z "$repos" ]] && {
		[[ "$JSON_MODE" -eq 0 ]] && printf 'No pulse-enabled repos found.\n'
		exit 0
	}

	if [[ "$DRY_RUN" -eq 1 && "$JSON_MODE" -eq 0 ]]; then
		printf '[backfill-status-available] DRY-RUN mode (pass --apply to write)\n\n'
	fi

	while IFS= read -r repo; do
		[[ -z "$repo" ]] && continue
		process_repo "$repo"
	done <<<"$repos"

	# Summary
	if [[ "$JSON_MODE" -eq 1 ]]; then
		local mode_str
		[[ "$DRY_RUN" -eq 1 ]] && mode_str="$ACTION_DRY_RUN" || mode_str="apply"
		jq -cn \
			--argjson found "$TOTAL_FOUND" \
			--argjson applied "$TOTAL_APPLIED" \
			--argjson failed "$TOTAL_FAILED" \
			--arg mode "$mode_str" \
			'{summary:true, found:$found, applied:$applied, failed:$failed, mode:$mode}'
	else
		if [[ "$DRY_RUN" -eq 1 ]]; then
			printf '\nDry-run summary: %d candidate(s) found across all repos.\n' "$TOTAL_FOUND"
			printf 'Run with --apply to label them.\n'
		else
			printf '\nSummary: found=%d applied=%d failed=%d\n' \
				"$TOTAL_FOUND" "$TOTAL_APPLIED" "$TOTAL_FAILED"
		fi
	fi

	[[ "$TOTAL_FAILED" -gt 0 ]] && exit 2
	exit 0
}

main "$@"
