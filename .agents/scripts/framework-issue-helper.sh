#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# framework-issue-helper.sh - Route self-improvement issues to the aidevops repo
# Part of aidevops framework: https://aidevops.sh
#
# Fixes GH#5149: workers creating framework tasks in project repos despite prose guidance.
# This script provides a first-class action for workers to route framework-level issues
# to the correct repo (marcusquinn/aidevops) instead of the current project repo.
#
# Usage:
#   framework-issue-helper.sh detect "title or description text"
#   framework-issue-helper.sh log --title "Title" (--body "Body" | --body-file PATH) [--label "bug"]
#   framework-issue-helper.sh check-repo [--repo-path PATH]
#
# Commands:
#   detect TEXT        Detect if text contains framework-level indicators.
#                      Exit 0 = framework issue, exit 1 = project issue.
#                      Prints "framework" or "project" to stdout.
#
#   log                Create an issue on the aidevops repo (marcusquinn/aidevops).
#                      Gathers diagnostics automatically. Deduplicates by title.
#                      Options:
#                        --title TEXT      Issue title (required)
#                        --body TEXT       Issue body (optional, auto-generated if omitted)
#                        --body-file PATH  Read the issue body once from a regular file
#                        --label LABEL     GitHub label (default: "bug")
#                        --auto-dispatch   Explicitly retain the default automatic dispatch
#                        --tier TIER       Add tier label (default: "standard")
#                        --no-auto-dispatch  Apply a durable manual hold (requires --hold-reason)
#                        --hold-reason TEXT  Record why automatic dispatch is unsafe or unauthorized
#                        --dry-run         Print what would be created, don't create
#
#   check-repo         Check if the current repo is the aidevops framework repo.
#                      Exit 0 = is aidevops repo, exit 1 = is a project repo.
#                      Options:
#                        --repo-path PATH  Path to check (default: current directory)
#
# Framework-level indicators (any match → framework issue):
#   - File paths under ~/.aidevops/
#   - Framework script names: ai-lifecycle.sh, dispatch.sh, pulse-wrapper.sh,
#     pre-edit-check.sh, claim-task-id.sh, headless-runtime-helper.sh, etc.
#   - Framework concepts: supervisor, pulse, worker dispatch, model routing,
#     cross-repo orchestration, agent prompt behaviour
#   - Explicit markers: [framework], [aidevops], framework-level
#
# Exit codes:
#   0 - Success
#   1 - Error or "not framework" (for detect command)
#   2 - Dry run (no changes made)
#
# Examples:
#   # Detect if a task is framework-level
#   if framework-issue-helper.sh detect "Bug in ai-lifecycle.sh phase 3 pipeline"; then
#     echo "Route to aidevops repo"
#   fi
#
#   # Log a framework issue (workers use this instead of claim-task-id.sh)
#   framework-issue-helper.sh log \
#     --title "Phase 3 pipeline stdin consumption bug in ai-lifecycle.sh" \
#     --body "Observed: workers fail when stdin is consumed in phase 3..."
#   # Worker-ready framework issues default to auto-dispatch at tier:standard.
#
#   # Check if we're in the aidevops repo
#   if framework-issue-helper.sh check-repo; then
#     echo "In aidevops repo — use claim-task-id.sh normally"
#   else
#     echo "In project repo — use framework-issue-helper.sh log for framework issues"
#   fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
LOG_PREFIX="FRAMEWORK"
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# The canonical aidevops repo slug — never guess this
readonly AIDEVOPS_SLUG="marcusquinn/aidevops"

# Framework-level path indicators (files/dirs that live in ~/.aidevops/)
readonly FRAMEWORK_PATH_PATTERNS=(
	"\\.aidevops/"
	"aidevops/agents/"
	"aidevops/logs/"
	"aidevops/cache/"
)

# Framework script names that indicate a framework-level issue
readonly FRAMEWORK_SCRIPT_NAMES=(
	"ai-lifecycle.sh"
	"ai-actions.sh"
	"dispatch.sh"
	"pulse-wrapper.sh"
	"pulse\.sh"
	"pre-edit-check.sh"
	"claim-task-id.sh"
	"headless-runtime-helper.sh"
	"worker-lifecycle-common.sh"
	"circuit-breaker-helper.sh"
	"dispatch-dedup-helper.sh"
	"model-availability-helper.sh"
	"task-decompose-helper.sh"
	"review-bot-gate-helper.sh"
	"issue-sync-helper.sh"
	"framework-issue-helper.sh"
	"session-miner-pulse.sh"
	"memory-audit-pulse.sh"
	"auto-update-helper.sh"
	"aidevops-update-check.sh"
	"bundle-helper.sh"
	"batch-strategy-helper.sh"
)

# Framework concept keywords that indicate a framework-level issue
readonly FRAMEWORK_CONCEPT_KEYWORDS=(
	"supervisor pulse"
	"pulse supervisor"
	"worker dispatch"
	"model routing"
	"cross-repo orchestration"
	"agent prompt"
	"headless dispatch"
	"pulse session"
	"worker slot"
	"worker lifecycle"
	"provider rotation"
	"provider backoff"
	"session miner"
	"task counter"
	"\.task-counter"
	"claim-task-id"
	"PULSE_SCOPE_REPOS"
	"PULSE_STALE_THRESHOLD"
	"circuit.breaker"
	"dispatch.dedup"
	"struggle.ratio"
	"model.escalation"
	"framework.level"
	"\[framework\]"
	"\[aidevops\]"
	"supervisor evaluate"
	"supervisor dispatch"
	"model tier.*supervisor"
	"supervisor.*model tier"
	"pulse.*evaluate"
	"evaluate.*dispatch"
	"worker.*evaluate"
	"aidevops framework"
	"aidevops repo"
)

# ─────────────────────────────────────────────────────────────────────────────
# detect_framework_issue TEXT
#
# Returns 0 (exit) and prints "framework" if TEXT contains framework indicators.
# Returns 1 (exit) and prints "project" otherwise.
# ─────────────────────────────────────────────────────────────────────────────
detect_framework_issue() {
	local text="$1"
	local lower_text
	lower_text=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')

	# Check path patterns
	local pattern
	for pattern in "${FRAMEWORK_PATH_PATTERNS[@]}"; do
		if printf '%s' "$lower_text" | grep -qE "$pattern" 2>/dev/null; then
			log_info "Framework indicator (path): $pattern"
			echo "framework"
			return 0
		fi
	done

	# Check script names
	for pattern in "${FRAMEWORK_SCRIPT_NAMES[@]}"; do
		if printf '%s' "$lower_text" | grep -qiE "$pattern" 2>/dev/null; then
			log_info "Framework indicator (script): $pattern"
			echo "framework"
			return 0
		fi
	done

	# Check concept keywords
	for pattern in "${FRAMEWORK_CONCEPT_KEYWORDS[@]}"; do
		if printf '%s' "$lower_text" | grep -qiE "$pattern" 2>/dev/null; then
			log_info "Framework indicator (concept): $pattern"
			echo "framework"
			return 0
		fi
	done

	echo "project"
	return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# check_is_aidevops_repo [REPO_PATH]
#
# Returns 0 if REPO_PATH is the aidevops framework repo, 1 otherwise.
# ─────────────────────────────────────────────────────────────────────────────
check_is_aidevops_repo() {
	local repo_path="${1:-$PWD}"

	# Check remote URL
	local remote_url
	remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null || echo "")

	if printf '%s' "$remote_url" | grep -qE "marcusquinn/aidevops(\.git)?$"; then
		return 0
	fi

	# Check repo name as fallback
	local repo_name
	repo_name=$(basename "$(git -C "$repo_path" rev-parse --show-toplevel 2>/dev/null || echo "")")
	if [[ "$repo_name" == "aidevops" ]]; then
		# Verify it's the right one by checking for framework marker files
		if [[ -f "${repo_path}/.agents/scripts/framework-issue-helper.sh" ]] ||
			[[ -f "${repo_path}/VERSION" && -f "${repo_path}/setup.sh" ]]; then
			return 0
		fi
	fi

	return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# get_aidevops_repo_path
#
# Finds the local path to the aidevops repo from repos.json or common locations.
# Prints the path to stdout, or empty string if not found.
# ─────────────────────────────────────────────────────────────────────────────
get_aidevops_repo_path() {
	# Check repos.json first (canonical source)
	local repos_json="${HOME}/.config/aidevops/repos.json"
	if [[ -f "$repos_json" ]] && command -v jq &>/dev/null; then
		local path_from_json
		path_from_json=$(jq -r '.initialized_repos[] | select(.slug == "marcusquinn/aidevops") | .path // empty' \
			"$repos_json" 2>/dev/null | head -1 || echo "")
		if [[ -n "$path_from_json" && -d "$path_from_json" ]]; then
			echo "$path_from_json"
			return 0
		fi
	fi

	# Common locations
	local candidate
	for candidate in \
		"${HOME}/Git/aidevops" \
		"${HOME}/git/aidevops" \
		"${HOME}/Projects/aidevops" \
		"${HOME}/Code/aidevops"; do
		if [[ -d "$candidate" ]] && check_is_aidevops_repo "$candidate" 2>/dev/null; then
			echo "$candidate"
			return 0
		fi
	done

	echo ""
	return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# gather_diagnostics
#
# Collects system info for issue body. Reuses log-issue-helper.sh if available.
# ─────────────────────────────────────────────────────────────────────────────
gather_diagnostics() {
	local log_issue_helper="${SCRIPT_DIR}/log-issue-helper.sh"
	if [[ -x "$log_issue_helper" ]]; then
		"$log_issue_helper" diagnostics --public-safe 2>/dev/null || true
		return 0
	fi

	# Minimal fallback diagnostics
	local version="unknown"
	if [[ -f "${HOME}/.aidevops/agents/VERSION" ]]; then
		version=$(tr -d '[:space:]' <"${HOME}/.aidevops/agents/VERSION" 2>/dev/null || echo "unknown")
	fi

	cat <<EOF
- **aidevops version**: $version
- **OS**: $(uname -s) $(uname -r)
- **Shell**: bash ${BASH_VERSION:-unknown}
- **gh CLI**: $(gh --version 2>/dev/null | head -1 || echo "not installed")
EOF
	return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# _validate_gh_prereqs TITLE
#
# Validates that title is non-empty and gh CLI is installed and authenticated.
# Returns 0 on success, 1 on failure.
# ─────────────────────────────────────────────────────────────────────────────
_validate_gh_prereqs() {
	local title="$1"

	if [[ -z "$title" ]]; then
		log_error "Title is required"
		return 1
	fi

	if ! command -v gh &>/dev/null; then
		log_error "GitHub CLI (gh) not installed — cannot create issue"
		log_error "Install with: brew install gh (macOS) or apt install gh (Linux)"
		return 1
	fi
	# `gh auth status` validates stored keyring entries and can fail even when an
	# active environment/App token successfully serves API requests. Probe the
	# capability needed by this helper before declaring authentication broken.
	if ! gh auth status &>/dev/null &&
		! gh api graphql -f 'query={viewer{login}}' --jq '.data.viewer.login' &>/dev/null; then
		log_error "GitHub CLI cannot authenticate an API request — run: gh auth login"
		return 1
	fi

	return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# _is_valid_issue_number ISSUE_NUMBER
#
# Returns 0 when ISSUE_NUMBER is a positive numeric GitHub issue number.
# ─────────────────────────────────────────────────────────────────────────────
_is_valid_issue_number() {
	local issue_number="$1"

	if [[ "$issue_number" =~ ^[1-9][0-9]*$ ]]; then
		return 0
	fi

	return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# _find_duplicate_issue TITLE
#
# Searches for an existing issue with a similar title on the aidevops repo.
# Prints the issue number to stdout if found, empty string otherwise.
# Returns 0 if a duplicate was found, 1 otherwise.
# ─────────────────────────────────────────────────────────────────────────────
_find_duplicate_issue() {
	local title="$1"
	local search_terms
	search_terms=$(printf '%s' "$title" | sed 's/^[a-zA-Z0-9_-]*: *//')

	if [[ -z "$search_terms" ]]; then
		return 1
	fi

	local existing_issue
	existing_issue=$(gh issue list --repo "$AIDEVOPS_SLUG" \
		--state all --search "\"$search_terms\" in:title is:issue" \
		--json number --limit 1 -q '.[0].number' 2>/dev/null || echo "")

	if _is_valid_issue_number "$existing_issue"; then
		echo "$existing_issue"
		return 0
	fi

	return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# _extract_issue_url ISSUE_OUTPUT
#
# Extracts the canonical GitHub issue URL from wrapper output that may include
# informational log lines before the actual URL.
# ─────────────────────────────────────────────────────────────────────────────
_extract_issue_url() {
	local issue_output="$1"
	local issue_line=""
	local line

	while IFS= read -r line; do
		if [[ "$line" =~ ^https://github\.com/[^[:space:]]+/[^[:space:]]+/issues/[0-9]+$ ]]; then
			issue_line="$line"
		fi
	done <<<"$issue_output"

	if [[ -n "$issue_line" ]]; then
		printf '%s\n' "$issue_line"
		return 0
	fi

	return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# _extract_issue_number ISSUE_URL
#
# Extracts and validates a numeric issue number from an issue URL.
# ─────────────────────────────────────────────────────────────────────────────
_extract_issue_number() {
	local issue_url="$1"
	local issue_number
	issue_number=$(printf '%s' "$issue_url" | grep -oE '[0-9]+$' || true)

	if _is_valid_issue_number "$issue_number"; then
		printf '%s\n' "$issue_number"
		return 0
	fi

	return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# _build_issue_body TITLE
#
# Auto-generates a standard issue body from TITLE with diagnostics and context.
# Prints the body to stdout.
# ─────────────────────────────────────────────────────────────────────────────
_build_issue_body() {
	local title="$1"
	local diagnostics
	diagnostics=$(gather_diagnostics 2>/dev/null || echo "")

	cat <<EOF
## Description

${title}

## Environment

${diagnostics}

## Context

This issue was automatically routed to the aidevops framework repo by \`framework-issue-helper.sh\` because it contains framework-level indicators (references to ~/.aidevops/ files, framework scripts, or supervisor/pulse concepts).
EOF
	return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# _append_signature_footer BODY
#
# Appends the gh signature footer to BODY if the helper is available.
# Prints the (possibly augmented) body to stdout.
# ─────────────────────────────────────────────────────────────────────────────
_append_signature_footer() {
	local body="$1"
	local sig_helper="${SCRIPT_DIR}/gh-signature-helper.sh"

	if [[ -x "$sig_helper" ]]; then
		local sig_footer
		sig_footer=$("$sig_helper" footer --body "$body" 2>/dev/null || echo "")
		if [[ -n "$sig_footer" ]]; then
			body="${body}${sig_footer}"
		fi
	fi

	printf '%s' "$body"
	return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# _emit_issue_result ISSUE_URL
#
# Extracts the issue number from ISSUE_URL and prints structured output.
# ─────────────────────────────────────────────────────────────────────────────
_emit_issue_result() {
	local issue_output="$1"
	local issue_url
	issue_url=$(_extract_issue_url "$issue_output") || {
		log_error "Issue creation returned no canonical numeric issue URL: $issue_output"
		return 1
	}
	local issue_num
	issue_num=$(_extract_issue_number "$issue_url" || true)

	if _is_valid_issue_number "$issue_num"; then
		log_success "Created framework issue: ${AIDEVOPS_SLUG}#${issue_num}"
		log_success "URL: $issue_url"
		echo "issue_url=${issue_url}"
		echo "issue_num=${issue_num}"
		echo "status=created"
	else
		log_error "Issue created but could not extract a valid numeric issue number from: $issue_url"
		return 1
	fi

	return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# _normalise_tier_label TIER
#
# Normalises a tier value to the canonical tier:* label shape.
# ─────────────────────────────────────────────────────────────────────────────
_normalise_tier_label() {
	local tier="$1"

	if [[ -z "$tier" ]]; then
		return 1
	fi

	if [[ "$tier" == tier:* ]]; then
		printf '%s\n' "$tier"
	else
		printf 'tier:%s\n' "$tier"
	fi

	return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# log_framework_issue TITLE BODY LABEL DRY_RUN AUTO_DISPATCH TIER HOLD_REASON
#
# Creates an issue on marcusquinn/aidevops. Deduplicates by title.
# ─────────────────────────────────────────────────────────────────────────────
log_framework_issue() {
	local title="$1"
	local body="$2"
	local label="${3:-bug}"
	local dry_run="${4:-false}"
	local auto_dispatch="${5:-yes}"
	local tier="${6:-standard}"
	local hold_reason="${7:-}"

	_validate_gh_prereqs "$title" || return 1

	# Deduplication: search for existing issues with similar title
	local existing_issue
	existing_issue=$(_find_duplicate_issue "$title" 2>/dev/null || echo "")
	if _is_valid_issue_number "$existing_issue"; then
		log_warn "Existing issue found: ${AIDEVOPS_SLUG}#${existing_issue} — skipping duplicate creation"
		echo "issue_url=https://github.com/${AIDEVOPS_SLUG}/issues/${existing_issue}"
		echo "issue_num=${existing_issue}"
		echo "status=duplicate"
		return 0
	fi

	# Auto-generate body if not provided
	if [[ -z "$body" ]]; then
		body=$(_build_issue_body "$title")
	fi

	if [[ "$auto_dispatch" == "no" ]]; then
		if [[ -z "$hold_reason" ]]; then
			log_error "--no-auto-dispatch requires --hold-reason with the durable manual, safety, or authority reason"
			return 1
		fi
		body="${body}"$'\n\n'"## Dispatch Hold"$'\n\n'"${hold_reason}"
	fi

	body=$(_append_signature_footer "$body")

	local -a issue_labels=("$label")
	if [[ "$auto_dispatch" == "yes" ]]; then
		issue_labels+=("auto-dispatch" "status:available")
	else
		issue_labels+=("no-auto-dispatch" "status:blocked")
	fi
	if [[ -n "$tier" ]]; then
		local tier_label
		tier_label=$(_normalise_tier_label "$tier") || {
			log_error "Invalid tier: $tier"
			return 1
		}
		issue_labels+=("$tier_label")
	fi

	if [[ "$dry_run" == "true" ]]; then
		log_info "DRY RUN — would create issue on ${AIDEVOPS_SLUG}:"
		log_info "  Title: $title"
		log_info "  Labels: ${issue_labels[*]}"
		log_info "  Body preview: ${body:0:200}..."
		echo "status=dry_run"
		return 2
	fi

	log_info "Creating issue on ${AIDEVOPS_SLUG}: $title"

	local -a create_args=(
		--repo "$AIDEVOPS_SLUG"
		--title "$title"
		--body "$body"
	)
	local create_label
	for create_label in "${issue_labels[@]}"; do
		create_args+=(--label "$create_label")
	done

	local issue_url
	issue_url=$(gh_create_issue "${create_args[@]}" 2>&1) || {
		log_error "Failed to create issue: $issue_url"
		return 1
	}

	_emit_issue_result "$issue_url"
	return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# _log_option_value FLAG OPTION ARG_COUNT [NEXT_VALUE]
# ─────────────────────────────────────────────────────────────────────────────
_log_option_value() {
	local flag_name="$1"
	local option="$2"
	local arg_count="$3"
	local next_value="${4-}"

	case "$option" in
	*=*)
		printf '%s\n' "${option#*=}"
		return 0
		;;
	esac

	if [[ "$arg_count" -lt 2 ]]; then
		log_error "${flag_name} requires a value"
		return 1
	fi

	printf '%s\n' "$next_value"
	return 0
}

# Read a caller-supplied body before any network operation. The helper keeps the
# resulting text on the existing signing, privacy, deduplication, and creation
# path rather than passing an unchecked path to gh.
_read_log_body_file() {
	local body_file="$1"
	local body_content=""
	local trimmed_content=""

	if [[ -z "$body_file" || ! -f "$body_file" || ! -r "$body_file" ]]; then
		log_error "--body-file requires a readable regular file"
		return 1
	fi
	body_content=$(<"$body_file") || {
		log_error "Could not read --body-file: $body_file"
		return 1
	}
	trimmed_content="${body_content#"${body_content%%[![:space:]]*}"}"
	trimmed_content="${trimmed_content%"${trimmed_content##*[![:space:]]}"}"
	if [[ -z "$trimmed_content" ]]; then
		log_error "--body-file must contain a substantive issue body"
		return 1
	fi

	printf '%s' "$body_content"
	return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# _parse_log_command ARGS...
# ─────────────────────────────────────────────────────────────────────────────
_parse_log_command() {
	local title="" body="" body_file="" body_source="" label="bug" dry_run="false" auto_dispatch="yes" tier="standard" hold_reason="" dispatch_flag=""
	while [[ $# -gt 0 ]]; do
		local option="$1"
		case "$option" in
		--title | --title=* | --body | --body=* | --body-file | --body-file=* | --label | --label=* | --tier | --tier=* | --hold-reason | --hold-reason=*)
			local flag_name="${option%%=*}"
			local option_value
			option_value="$(_log_option_value "$flag_name" "$option" "$#" "${2-}")" || return 1
			case "$flag_name" in
			--title)
				title="$option_value"
				;;
			--body)
				if [[ "$body_source" == "file" ]]; then
					log_error "--body and --body-file are mutually exclusive"
					return 1
				fi
				body="$option_value"
				body_source="argument"
				;;
			--body-file)
				if [[ "$body_source" == "argument" ]]; then
					log_error "--body and --body-file are mutually exclusive"
					return 1
				fi
				body_file="$option_value"
				body_source="file"
				;;
			--label)
				label="$option_value"
				;;
			--tier)
				tier="$option_value"
				;;
			--hold-reason)
				hold_reason="$option_value"
				;;
			esac
			case "$option" in
			*=*)
				shift
				;;
			*)
				shift 2
				;;
			esac
			;;
		--auto-dispatch)
			if [[ "$dispatch_flag" == "no" ]]; then
				log_error "--auto-dispatch and --no-auto-dispatch are mutually exclusive"
				return 1
			fi
			dispatch_flag="yes"
			auto_dispatch="yes"
			shift
			;;
		--no-auto-dispatch)
			if [[ "$dispatch_flag" == "yes" ]]; then
				log_error "--auto-dispatch and --no-auto-dispatch are mutually exclusive"
				return 1
			fi
			dispatch_flag="no"
			auto_dispatch="no"
			shift
			;;
		--dry-run)
			dry_run="true"
			shift
			;;
		*)
			log_error "Unknown option: $option"
			return 1
			;;
		esac
	done

	case ",${label}," in
	*,auto-dispatch,* | *,no-auto-dispatch,*)
		log_error "Use --auto-dispatch or --no-auto-dispatch instead of passing a dispatch label through --label"
		return 1
		;;
	esac

	if [[ -n "$hold_reason" && "$auto_dispatch" != "no" ]]; then
		log_error "--hold-reason requires --no-auto-dispatch"
		return 1
	fi
	if [[ "$body_source" == "file" ]]; then
		body=$(_read_log_body_file "$body_file") || return 1
	fi

	log_framework_issue "$title" "$body" "$label" "$dry_run" "$auto_dispatch" "$tier" "$hold_reason"
	return $?
}

# ─────────────────────────────────────────────────────────────────────────────
# parse_and_run ARGS...
# ─────────────────────────────────────────────────────────────────────────────
parse_and_run() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	detect)
		local text="${1:-}"
		if [[ -z "$text" ]]; then
			log_error "Usage: framework-issue-helper.sh detect \"text to check\""
			return 1
		fi
		detect_framework_issue "$text"
		return $?
		;;

	log)
		_parse_log_command "$@"
		return $?
		;;

	check-repo)
		local repo_path="$PWD"
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--repo-path)
				repo_path="$2"
				shift 2
				;;
			*)
				log_error "Unknown option: $1"
				return 1
				;;
			esac
		done
		if check_is_aidevops_repo "$repo_path"; then
			log_info "Current repo IS the aidevops framework repo"
			echo "is_aidevops=true"
			return 0
		else
			log_info "Current repo is NOT the aidevops framework repo"
			echo "is_aidevops=false"
			return 1
		fi
		;;

	find-repo)
		local path
		path=$(get_aidevops_repo_path)
		if [[ -n "$path" ]]; then
			echo "$path"
			return 0
		else
			log_warn "Could not find local aidevops repo path"
			return 1
		fi
		;;

	help | --help | -h)
		grep '^#' "$0" | grep -v '#!/usr/bin/env' | sed 's/^# //' | sed 's/^#//'
		return 0
		;;

	*)
		log_error "Unknown command: $command"
		log_error "Run: framework-issue-helper.sh help"
		return 1
		;;
	esac
}

parse_and_run "$@"
