#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# verify-issue-close-helper.sh — Pre-close verification for issue closing (GH#17372)
#
# Prevents workers from closing issues against unrelated PRs by verifying that
# the cited PR's diff actually touches files mentioned in the issue body.
#
# Background: A worker dispatched for GH#15544 found a recently-merged PR that
# touched a related file and concluded it must contain the fix. It didn't verify
# that the PR modified the specific code paths identified in the bug reports.
# Both issues were closed without fixes. This helper prevents that failure mode.
#
# Usage:
#   verify-issue-close-helper.sh check <issue_number> <pr_number> <repo_slug>
#     Verify that a PR's changed files overlap with files mentioned in the issue.
#     Exit 0 = verified (safe to close), exit 1 = not verified (do NOT close)
#
#   verify-issue-close-helper.sh extract-paths <issue_number> <repo_slug>
#     Extract file paths mentioned in an issue body. Useful for debugging.
#
#   verify-issue-close-helper.sh help
#     Show usage information.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"
init_log_file

LOG_PREFIX="VERIFY-CLOSE"

# =============================================================================
# Constants
# =============================================================================

# Minimum number of file-path overlaps required to consider a PR as fixing an issue.
# 1 = at least one file mentioned in the issue must appear in the PR diff.
readonly MIN_FILE_OVERLAP=1

# =============================================================================
# Functions
# =============================================================================

#######################################
# Extract file paths from an issue body.
#
# Looks for common file-path patterns in the issue text:
# - Explicit paths: src/foo/bar.sh, .agents/scripts/pulse-wrapper.sh
# - Code-fenced references: `schedulers.sh:438`
# - Function references: _install_pulse_systemd() → extracts nothing (function, not file)
#
# Args: $1 = issue body text
# Outputs: one file path per line (basenames and full paths, deduplicated)
# Returns: 0 always
#######################################
extract_file_paths_from_text() {
	local text="$1"

	# Extract paths that look like file references:
	# - Must contain a dot (extension) or a slash (directory)
	# - Common extensions: .sh, .ts, .js, .py, .md, .json, .yaml, .yml, .toml, .go, .rs
	# - Exclude URLs (http://, https://)
	# - Exclude common false positives (e.g., version numbers like v3.6.83)
	local paths=""

	# Pattern 1: Explicit file paths with directory separators
	# Matches: src/foo/bar.sh, .agents/scripts/pulse-wrapper.sh, .agents/scripts/setup/modules/schedulers.sh
	local dir_paths
	dir_paths=$(printf '%s' "$text" | grep -oE '[a-zA-Z0-9._-]+/[a-zA-Z0-9._/-]+\.[a-zA-Z]{1,10}' | sort -u || true)
	if [[ -n "$dir_paths" ]]; then
		paths="${paths}${dir_paths}"$'\n'
	fi

	# Pattern 2: Backtick-enclosed repository paths, including extensionless
	# executables such as `.agents/scripts/gh`. Inspect whole backtick tokens so a
	# URL cannot yield a path-like substring after its hostname.
	local backtick_paths
	# shellcheck disable=SC2016 # Literal backtick regex, not shell expansion.
	backtick_paths=$(printf '%s' "$text" | grep -oE '`[a-zA-Z0-9._:/-]+`' | tr -d '`' | grep '/' | grep -v '://' | sed 's/:[0-9]*\(-[0-9]*\)\{0,1\}$//' | grep -E '^(\.[a-zA-Z0-9_-]+|[a-zA-Z0-9_-]+)/[a-zA-Z0-9._/-]*[a-zA-Z0-9._-]$' | sort -u || true)
	if [[ -n "$backtick_paths" ]]; then
		paths="${paths}${backtick_paths}"$'\n'
	fi

	# Pattern 3: Backtick-enclosed file references without directory separators
	# (e.g., `schedulers.sh`, `pulse-wrapper.sh:6098`).
	local backtick_files
	# shellcheck disable=SC2016 # Literal backtick regex, not shell expansion.
	backtick_files=$(printf '%s' "$text" | grep -oE '`[a-zA-Z0-9._/-]+\.(sh|ts|js|py|md|json|yaml|yml|toml|go|rs|tsx|jsx|css|html|sql|rb|php|java|c|h|cpp|hpp)(:[0-9]+(-[0-9]+)?)?`' | tr -d '`' | sed 's/:[0-9]*\(-[0-9]*\)\{0,1\}$//' | sort -u || true)
	if [[ -n "$backtick_files" ]]; then
		paths="${paths}${backtick_files}"$'\n'
	fi

	# Pattern 4: Bare filenames with common extensions mentioned outside backticks
	# More conservative — requires word boundaries
	local bare_files
	bare_files=$(printf '%s' "$text" | grep -oE '\b[a-zA-Z0-9_-]+\.(sh|ts|js|py|json|yaml|yml|toml|go|rs)\b' | sort -u || true)
	if [[ -n "$bare_files" ]]; then
		paths="${paths}${bare_files}"$'\n'
	fi

	# Deduplicate, remove empty lines, filter out false positives
	printf '%s' "$paths" | sort -u | grep -v '^$' | grep -vE '^v?[0-9]+\.[0-9]+\.[0-9]+' || true
	return 0
}

#######################################
# Get the list of files changed in a PR.
#
# Args: $1 = PR number, $2 = repo slug
# Outputs: one file path per line
# Returns: 0 on success, 1 on failure
#######################################
get_pr_changed_files() {
	local pr_number="$1"
	local repo_slug="$2"

	local files_json
	files_json=$(gh pr view "$pr_number" --repo "$repo_slug" --json files 2>/dev/null) || {
		log_error "Failed to fetch PR #${pr_number} files from ${repo_slug}"
		return 1
	}

	local pr_files
	pr_files=$(printf '%s' "$files_json" | jq -r '(.files // [])[]? | .path // .filename // empty' 2>/dev/null) || {
		log_warn "Failed to parse PR #${pr_number} file list from gh pr view; trying REST fallback"
		pr_files=""
	}

	if [[ -n "$pr_files" ]]; then
		printf '%s\n' "$pr_files"
		return 0
	fi

	# `gh pr view --json files` can return `null` for merged PRs on some gh/API
	# paths. The pull files REST endpoint remains available after merge, so use
	# it as the authoritative fallback before declaring the PR unparseable.
	pr_files=$(gh api --paginate "repos/${repo_slug}/pulls/${pr_number}/files" --jq '.[].filename' 2>/dev/null) || {
		log_error "Failed to fetch PR #${pr_number} file list via REST fallback"
		return 1
	}

	if [[ -z "$pr_files" ]]; then
		log_error "PR #${pr_number} file list is empty"
		return 1
	fi

	printf '%s\n' "$pr_files"
	return 0
}

#######################################
# Fetch and validate an issue body.
#
# Args: $1 = issue_number, $2 = repo_slug
# Outputs: issue body text on stdout
# Returns: 0 on success, 1 on failure (empty body or fetch error)
#######################################
_fetch_issue_body() {
	local issue_number="$1"
	local repo_slug="$2"

	local issue_body
	issue_body=$(gh issue view "$issue_number" --repo "$repo_slug" --json body -q '.body // ""' 2>/dev/null) || {
		log_error "Failed to fetch issue #${issue_number} body"
		printf 'FAIL: could not fetch issue #%s body\n' "$issue_number"
		return 1
	}

	if [[ -z "$issue_body" ]]; then
		log_warn "Issue #${issue_number} has empty body — cannot verify"
		printf 'FAIL: issue #%s has empty body — cannot verify file overlap\n' "$issue_number"
		return 1
	fi

	printf '%s' "$issue_body"
	return 0
}

#######################################
# Classify issue paths into specific (with /) and general (basename only),
# and build a deduplicated list of PR basenames.
#
# Args: $1 = issue_paths (newline-separated), $2 = pr_files (newline-separated)
# Outputs: three lines of output separated by NUL-delimited sections:
#   specific_paths, general_paths, pr_basenames — each printed to named vars
#   via stdout in the format "KEY=VALUE\n" (eval-safe, no subshell needed).
# Returns: 0 always
#
# Callers use this as:
#   eval "$(_classify_issue_paths "$issue_paths" "$pr_files")"
#######################################
_classify_issue_paths() {
	local issue_paths="$1"
	local pr_files="$2"

	local specific_paths general_paths pr_basenames
	specific_paths=$(printf '%s\n' "$issue_paths" | grep '/' || true)
	general_paths=$(printf '%s\n' "$issue_paths" | grep -v '/' || true)
	pr_basenames=$(printf '%s\n' "$pr_files" | while IFS= read -r f; do printf '%s\n' "${f##*/}"; done | sort -u)

	# Output as shell assignments for eval
	printf 'specific_paths=%q\n' "$specific_paths"
	printf 'general_paths=%q\n' "$general_paths"
	printf 'pr_basenames=%q\n' "$pr_basenames"
	return 0
}

#######################################
# Tier 1: Match specific paths (paths containing /) from the issue against PR files.
#
# Requires exact specific-path overlap; basename-only matches do not count —
# GH#17372.
#
# Args:
#   $1 = specific_paths (newline-separated paths with /)
#   $2 = pr_files (newline-separated)
# Outputs: overlap_count and overlapping_files via stdout (eval-safe assignments)
# Returns: 0 always; the final verdict considers safe Tier 2 matches
#######################################
_check_tier1_specific_paths() {
	local specific_paths="$1"
	local pr_files="$2"

	local overlap_count=0
	local overlapping_files=""
	local specific_overlap=0

	if [[ -z "$specific_paths" ]]; then
		printf 'tier1_overlap_count=%d\n' "$overlap_count"
		printf 'tier1_specific_overlap=%d\n' "$specific_overlap"
		printf 'tier1_overlapping_files=%q\n' "$overlapping_files"
		return 0
	fi

	while IFS= read -r issue_file; do
		[[ -z "$issue_file" ]] && continue
		# Full path substring match (issue says ".agents/scripts/setup/modules/schedulers.sh",
		# PR has ".agents/.agents/scripts/setup/modules/schedulers.sh" or exact match)
		if printf '%s\n' "$pr_files" | grep -qF "$issue_file"; then
			overlap_count=$((overlap_count + 1))
			specific_overlap=$((specific_overlap + 1))
			overlapping_files="${overlapping_files}  ${issue_file} (specific path match)"$'\n'
			continue
		fi
	done <<<"$specific_paths"

	printf 'tier1_overlap_count=%d\n' "$overlap_count"
	printf 'tier1_specific_overlap=%d\n' "$specific_overlap"
	printf 'tier1_overlapping_files=%q\n' "$overlapping_files"
	return 0
}

#######################################
# Tier 2: Match general paths (bare filenames, no /) against PR basenames.
#
# General names that duplicate a specific path's basename are excluded. The
# extractor also emits basenames found inside full paths, and accepting those
# would let an unrelated same-basename file bypass GH#17372's strict check.
#
# Args:
#   $1 = general_paths (newline-separated bare filenames)
#   $2 = specific_paths (newline-separated paths with /)
#   $3 = pr_basenames (newline-separated)
#   $4 = initial overlap_count (from tier 1)
#   $5 = initial overlapping_files (from tier 1)
# Outputs: updated overlap_count and overlapping_files via stdout (eval-safe)
# Returns: 0 always
#######################################
_check_tier2_general_paths() {
	local general_paths="$1"
	local specific_paths="$2"
	local pr_basenames="$3"
	local overlap_count="$4"
	local overlapping_files="$5"

	if [[ -n "$general_paths" ]]; then
		while IFS= read -r issue_file; do
			[[ -z "$issue_file" ]] && continue
			local duplicates_specific_basename=0
			local specific_file
			while IFS= read -r specific_file; do
				[[ -z "$specific_file" ]] && continue
				if [[ "${specific_file##*/}" == "$issue_file" ]]; then
					duplicates_specific_basename=1
					break
				fi
			done <<<"$specific_paths"
			if [[ "$duplicates_specific_basename" -eq 1 ]]; then
				continue
			fi
			if printf '%s\n' "$pr_basenames" | grep -qxF "$issue_file"; then
				overlap_count=$((overlap_count + 1))
				overlapping_files="${overlapping_files}  ${issue_file} (basename match)"$'\n'
			fi
		done <<<"$general_paths"
	fi

	printf 'tier2_overlap_count=%d\n' "$overlap_count"
	printf 'tier2_overlapping_files=%q\n' "$overlapping_files"
	return 0
}

#######################################
# Emit the final VERIFIED or REJECTED verdict.
#
# Args:
#   $1 = overlap_count
#   $2 = overlapping_files (formatted string)
#   $3 = issue_number
#   $4 = pr_number
#   $5 = issue_paths (for rejection output)
#   $6 = pr_files (for rejection output)
# Returns: 0 = verified, 1 = rejected
#######################################
_emit_overlap_verdict() {
	local overlap_count="$1"
	local overlapping_files="$2"
	local issue_number="$3"
	local pr_number="$4"
	local issue_paths="$5"
	local pr_files="$6"

	if [[ "$overlap_count" -ge "$MIN_FILE_OVERLAP" ]]; then
		printf 'VERIFIED: PR #%s touches %d file(s) mentioned in issue #%s:\n%s' \
			"$pr_number" "$overlap_count" "$issue_number" "$overlapping_files"
		log_info "Verified: PR #${pr_number} touches ${overlap_count} file(s) from issue #${issue_number}"
		return 0
	else
		printf 'REJECTED: PR #%s does NOT touch any files mentioned in issue #%s\n' \
			"$pr_number" "$issue_number"
		printf 'Issue mentions: %s\n' "$(printf '%s' "$issue_paths" | tr '\n' ', ' | sed 's/,$//')"
		printf 'PR changes: %s\n' "$(printf '%s' "$pr_files" | tr '\n' ', ' | sed 's/,$//')"
		log_warn "Rejected: PR #${pr_number} has 0 file overlap with issue #${issue_number}"
		return 1
	fi
}

#######################################
# Check if a PR's changed files overlap with files mentioned in an issue.
#
# Uses a two-tier strategy to avoid false positives from contextual mentions:
#
# Tier 1 (strict): If the issue mentions files with directory separators
#   (e.g., ".agents/scripts/setup/modules/schedulers.sh"), at least one of these specific
#   paths must appear in the PR diff. This catches the case where an issue
#   mentions a contextual file (pulse-wrapper.sh) alongside the actual
#   buggy file (.agents/scripts/setup/modules/schedulers.sh), and the PR only touches
#   the contextual file.
#
# Tier 2 (relaxed): Bare filenames that are independent of every specific
#   path may match PR basenames. A bare name duplicated by a specific path is
#   ignored so same-basename files elsewhere cannot satisfy the strict target.
#
# Args: $1 = issue_number, $2 = pr_number, $3 = repo_slug
# Outputs: verification result (human-readable)
# Returns: 0 = verified (overlap exists), 1 = not verified (no overlap)
#######################################
check_pr_fixes_issue() {
	local issue_number="$1"
	local pr_number="$2"
	local repo_slug="$3"

	# Fetch and validate issue body
	local issue_body
	issue_body=$(_fetch_issue_body "$issue_number" "$repo_slug") || {
		printf '%s\n' "$issue_body" >&2
		return 1
	}

	# Extract file paths from issue body
	local issue_paths
	issue_paths=$(extract_file_paths_from_text "$issue_body")

	if [[ -z "$issue_paths" ]]; then
		log_warn "No file paths found in issue #${issue_number} body — cannot verify"
		printf 'WARN: no file paths found in issue #%s body — skipping verification (manual review required)\n' "$issue_number"
		# Return 0 here — if the issue doesn't mention specific files, we can't
		# reject the close. The caller should treat this as "unverifiable" and
		# require manual review rather than blocking.
		return 0
	fi

	# Get PR changed files
	local pr_files
	pr_files=$(get_pr_changed_files "$pr_number" "$repo_slug") || {
		printf 'FAIL: could not fetch PR #%s changed files\n' "$pr_number"
		return 1
	}

	if [[ -z "$pr_files" ]]; then
		printf 'FAIL: PR #%s has no changed files\n' "$pr_number"
		return 1
	fi

	# Classify paths and build PR basenames
	local specific_paths general_paths pr_basenames
	eval "$(_classify_issue_paths "$issue_paths" "$pr_files")"

	# Tier 1: specific path matching (paths with directory separators)
	local tier1_overlap_count tier1_specific_overlap tier1_overlapping_files
	local tier1_output
	tier1_output=$(_check_tier1_specific_paths \
		"$specific_paths" "$pr_files")
	eval "$tier1_output"

	# Tier 2: independent general basename matching when no specific path matched
	local tier2_overlap_count tier2_overlapping_files
	if [[ "$tier1_specific_overlap" -eq 0 ]]; then
		eval "$(_check_tier2_general_paths \
			"$general_paths" "$specific_paths" "$pr_basenames" \
			"$tier1_overlap_count" "$tier1_overlapping_files")"
	else
		tier2_overlap_count="$tier1_overlap_count"
		tier2_overlapping_files="$tier1_overlapping_files"
	fi

	# Emit final verdict
	_emit_overlap_verdict \
		"$tier2_overlap_count" "$tier2_overlapping_files" \
		"$issue_number" "$pr_number" "$issue_paths" "$pr_files"
}

# =============================================================================
# Commands
# =============================================================================

cmd_check() {
	local issue_number="${1:-}"
	local pr_number="${2:-}"
	local repo_slug="${3:-}"

	if [[ -z "$issue_number" || -z "$pr_number" || -z "$repo_slug" ]]; then
		print_error "Usage: verify-issue-close-helper.sh check <issue_number> <pr_number> <repo_slug>"
		return 1
	fi

	if [[ ! "$issue_number" =~ ^[0-9]+$ ]] || [[ ! "$pr_number" =~ ^[0-9]+$ ]]; then
		print_error "Issue and PR numbers must be numeric"
		return 1
	fi

	check_pr_fixes_issue "$issue_number" "$pr_number" "$repo_slug"
	return $?
}

cmd_extract_paths() {
	local issue_number="${1:-}"
	local repo_slug="${2:-}"

	if [[ -z "$issue_number" || -z "$repo_slug" ]]; then
		print_error "Usage: verify-issue-close-helper.sh extract-paths <issue_number> <repo_slug>"
		return 1
	fi

	local issue_body
	issue_body=$(gh issue view "$issue_number" --repo "$repo_slug" --json body -q '.body // ""' 2>/dev/null) || {
		print_error "Failed to fetch issue #${issue_number}"
		return 1
	}

	local paths
	paths=$(extract_file_paths_from_text "$issue_body")
	if [[ -z "$paths" ]]; then
		print_info "No file paths found in issue #${issue_number} body"
		return 0
	fi

	printf '%s\n' "$paths"
	return 0
}

cmd_help() {
	cat <<'HELP'
verify-issue-close-helper.sh — Pre-close verification for issue closing (GH#17372)

Prevents workers from closing issues against unrelated PRs by verifying that
the cited PR's diff actually touches files mentioned in the issue body.

COMMANDS
  check <issue> <pr> <slug>    Verify PR fixes issue (file overlap check)
                               Exit 0 = verified, exit 1 = rejected

  extract-paths <issue> <slug> List file paths mentioned in an issue body

  help                         Show this message

EXAMPLES
  # Verify PR #15614 actually fixes issue #15544
  verify-issue-close-helper.sh check 15544 15614 marcusquinn/aidevops

  # See what files an issue references
  verify-issue-close-helper.sh extract-paths 15544 marcusquinn/aidevops
HELP
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	check) cmd_check "$@" ;;
	extract-paths) cmd_extract_paths "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: ${command}"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
