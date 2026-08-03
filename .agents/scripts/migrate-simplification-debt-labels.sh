#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# migrate-simplification-debt-labels.sh — One-shot label migration for t2168.
#
# Relabels existing open issues that carry the `simplification-debt` label,
# replacing it with the correct split label based on title pattern:
#
#   Title matches "file-size-debt: ... exceeds N lines"     → file-size-debt
#   Title matches "simplification-debt: ... exceeds N lines"→ file-size-debt
#   Title matches "simplification: reduce function ..."     → function-complexity-debt
#   Title matches "simplification: re-queue ..."            → function-complexity-debt
#   Title matches "reduce N Qlty smells"                    → function-complexity-debt
#   Title matches an LLM stall/sweep review                  → skip (meta work)
#   Otherwise                                               → skip (manual triage)
#
# Idempotent: issues that already have the new label are skipped.
#
# Usage:
#   migrate-simplification-debt-labels.sh [--repo SLUG] [--dry-run] [--limit N]
#
# Options:
#   --repo SLUG    Target repo slug (default: from ~/.config/aidevops/repos.json
#                  primary pulse repo, or marcusquinn/aidevops as fallback)
#   --dry-run      Print what would be done without making any changes
#   --limit N      Max issues to process (default: 500)
#
# Exit codes:
#   0 — success (or no changes needed)
#   1 — fatal error (missing gh, API failure on required call)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

# ============================================================
# Defaults
# ============================================================
DRY_RUN=false
REPO_SLUG=""
LIMIT=500

usage() {
	cat <<EOF
migrate-simplification-debt-labels.sh [--dry-run] [--repo SLUG] [--limit N]

Relabels open issues carrying the legacy 'simplification-debt' label,
replacing it with 'file-size-debt' or 'function-complexity-debt' based
on title pattern classification.

Options:
  --dry-run     Print actions without applying them
  --repo SLUG   Target repo (default: auto-detected)
  --limit N     Max issues to process (default: 500)

Exit codes:
  0  success
  1  fatal error
EOF
	return 0
}

# ============================================================
# Argument parsing
# ============================================================
while [[ $# -gt 0 ]]; do
	case "$1" in
	--dry-run) DRY_RUN=true; shift ;;
	--repo) REPO_SLUG="$2"; shift 2 ;;
	--limit) LIMIT="$2"; shift 2 ;;
	--help | -h) usage; exit 0 ;;
	*) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
	esac
done

# ============================================================
# Repo resolution
# ============================================================
if [[ -z "$REPO_SLUG" ]]; then
	repos_json="${HOME}/.config/aidevops/repos.json"
	if [[ -f "$repos_json" ]]; then
		REPO_SLUG=$(jq -r '
			.initialized_repos[]
			| select(.pulse == true and (.local_only // false) == false and .slug != "")
			| .slug
		' "$repos_json" 2>/dev/null | head -1) || REPO_SLUG=""
	fi
	if [[ -z "$REPO_SLUG" ]]; then
		REPO_SLUG="marcusquinn/aidevops"
	fi
fi

# ============================================================
# Classify an issue title into a new label.
# Returns "file-size-debt", "function-complexity-debt", or "skip".
# ============================================================
_classify_title() {
	local title="$1"

	# Large-file gate issues — file-size-debt
	# Format: "simplification-debt: <path> exceeds N lines"
	# Format: "file-size-debt: <path> exceeds N lines" (already migrated)
	if printf '%s' "$title" | grep -qE '^(simplification-debt|file-size-debt): .+ exceeds [0-9]+ lines$'; then
		printf 'file-size-debt'
		return 0
	fi

	# Function complexity scan issues — function-complexity-debt
	# Format: "simplification: reduce function complexity in <file> ..."
	if printf '%s' "$title" | grep -qE '^simplification: reduce (function complexity|[0-9]+ Qlty smells)'; then
		printf 'function-complexity-debt'
		return 0
	fi

	# Re-queue issues from pulse-simplification-state.sh
	# Format: "simplification: re-queue <file> (pass N, ...)"
	if printf '%s' "$title" | grep -qE '^simplification: re-queue .+ \(pass [0-9]+'; then
		printf 'function-complexity-debt'
		return 0
	fi

	# LLM sweep issues are meta reviews, not measured function violations.
	# Classifying them as function-complexity-debt inflates the open count and
	# makes closing a review look like real simplification throughput.
	# Format: "perf: simplification debt stalled — LLM sweep needed ..."
	# Format: "LLM complexity sweep: ..."
	if printf '%s' "$title" | grep -qiE '(simplification debt stalled|LLM complexity sweep|LLM sweep needed)'; then
		printf 'skip'
		return 0
	fi

	printf 'skip'
	return 0
}

# ============================================================
# Main migration
# ============================================================
printf 'migrate-simplification-debt-labels.sh -- repo: %s%s\n\n' \
	"$REPO_SLUG" "$([ "$DRY_RUN" == "true" ] && echo " [DRY-RUN]" || true)"

# Verify gh is available
if ! command -v gh >/dev/null 2>&1; then
	echo "ERROR: gh CLI not found. Install from https://cli.github.com/" >&2
	exit 1
fi

# Fetch all open issues with simplification-debt label
printf 'Fetching open simplification-debt issues from %s ...\n' "$REPO_SLUG"
local_issues_json=""
local_issues_json=$(gh issue list --repo "$REPO_SLUG" \
	--label "simplification-debt" --state open \
	--limit "$LIMIT" \
	--json number,title,labels 2>/dev/null) || {
	echo "ERROR: Failed to fetch issues from ${REPO_SLUG}" >&2
	exit 1
}

if [[ -z "$local_issues_json" || "$local_issues_json" == "[]" ]]; then
	printf 'No open simplification-debt issues found in %s.\n' "$REPO_SLUG"
	printf '\nDone. 0 relabeled, 0 skipped.\n'
	exit 0
fi

total_issues=$(printf '%s' "$local_issues_json" | jq 'length' 2>/dev/null) || total_issues=0
printf 'Found %s open simplification-debt issue(s) to process.\n\n' "$total_issues"

relabeled=0
skipped_existing=0
skipped_ambiguous=0
add_ok=false
remove_ok=false

# Process each issue
while IFS=$'\t' read -r issue_num issue_title has_file_size_debt has_func_complex_debt; do
	[[ -z "$issue_num" ]] && continue

	# Skip if already has the target label (idempotent)
	if [[ "$has_file_size_debt" == "true" || "$has_func_complex_debt" == "true" ]]; then
		printf '  SKIP  #%s — already relabeled\n' "$issue_num"
		skipped_existing=$((skipped_existing + 1))
		continue
	fi

	# Classify by title
	new_label=$(_classify_title "$issue_title")

	if [[ "$new_label" == "skip" ]]; then
		printf '  WARN  #%s — ambiguous title (manual triage needed): %s\n' "$issue_num" "$issue_title"
		skipped_ambiguous=$((skipped_ambiguous + 1))
		continue
	fi

	if [[ "$DRY_RUN" == "true" ]]; then
		printf '  DRY   #%s -> %s\n' "$issue_num" "$new_label"
		printf '         title: %s\n' "$issue_title"
		relabeled=$((relabeled + 1))
		continue
	fi

	printf '  ACT   #%s -> %s\n' "$issue_num" "$new_label"
	printf '         title: %s\n' "$issue_title"

	# Add new label first, then remove old one (two-step to avoid losing the issue
	# from the label list between add and remove)
	add_ok=false
	remove_ok=false

	if gh issue edit "$issue_num" --repo "$REPO_SLUG" \
		--add-label "$new_label" >/dev/null 2>&1; then
		add_ok=true
	fi

	if [[ "$add_ok" == "true" ]]; then
		if gh issue edit "$issue_num" --repo "$REPO_SLUG" \
			--remove-label "simplification-debt" >/dev/null 2>&1; then
			remove_ok=true
		fi
	fi

	if [[ "$add_ok" == "true" && "$remove_ok" == "true" ]]; then
		relabeled=$((relabeled + 1))
	else
		printf '  ERROR #%s -- label update failed (add=%s remove=%s)\n' \
			"$issue_num" "$add_ok" "$remove_ok"
	fi

done < <(printf '%s' "$local_issues_json" | jq -r \
	'.[] | "\(.number)\t\(.title)\t\(if (.labels | map(.name) | index("file-size-debt")) != null then "true" else "false" end)\t\(if (.labels | map(.name) | index("function-complexity-debt")) != null then "true" else "false" end)"' \
	2>/dev/null)

printf '\nDone. %s relabeled, %s already relabeled (skipped), %s ambiguous (skipped).\n' \
	"$relabeled" "$skipped_existing" "$skipped_ambiguous"
if [[ "$skipped_ambiguous" -gt 0 ]]; then
	printf '\nWARNING: %s issue(s) had ambiguous titles and were NOT relabeled.\n' "$skipped_ambiguous"
	printf 'Review them manually with:\n'
	printf '  gh issue list --repo %s --label simplification-debt --state open\n' "$REPO_SLUG"
fi

exit 0
