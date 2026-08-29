#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# platform-helper.sh — Platform abstraction layer for GitHub/Gitea/GitLab/local operations
#
# Routes knowledge plane and other helper operations through a platform-agnostic
# interface. Platform is determined from repos.json "platform" field or remote
# URL detection. Only GitHub (via gh CLI) is fully implemented; Gitea and GitLab
# stubs exit 1 with a clear "P9 task — adapter not implemented" message.
#
# Usage (source this file, then call platform_* functions):
#   source platform-helper.sh
#
# Functions:
#   platform_detect <repo_path>                           — detect platform, prints github|gitea|gitlab|local
#   platform_create_issue <slug> <title> <body_file|-> <labels> — create an issue
#   platform_get_issue <slug> <num>                       — view an issue (JSON)
#   platform_comment_issue <slug> <num> <body_file|->      — post a comment
#   platform_create_pr <slug> <title> <body_file|-> <base> <head> — create a pull request
#   Exact body path "-" forwards piped stdin to the managed GitHub wrapper.
#
# Local platform (no remote):
#   Operations are logged to ~/.aidevops/logs/platform-local-ops.log and exit 0.
#   No remote calls are made. Body stdin is consumed once and discarded.
#
# Gitea/GitLab platforms:
#   All operations exit 1 with "P9 task — adapter not implemented".
#   These stubs are placeholders for future adapters.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

# Guard color fallbacks when shared-constants.sh is absent
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

if ! declare -f print_info >/dev/null 2>&1; then
	print_info() { local _m="$1"; printf "${BLUE}[INFO]${NC} %s\n" "$_m"; }
fi
if ! declare -f print_success >/dev/null 2>&1; then
	print_success() { local _m="$1"; printf "${GREEN}[OK]${NC} %s\n" "$_m"; }
fi
if ! declare -f print_warning >/dev/null 2>&1; then
	print_warning() { local _m="$1"; printf "${YELLOW}[WARN]${NC} %s\n" "$_m"; }
fi
if ! declare -f print_error >/dev/null 2>&1; then
	print_error() { local _m="$1"; printf "${RED}[ERROR]${NC} %s\n" "$_m"; }
fi

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

REPOS_FILE="${REPOS_FILE:-${HOME}/.config/aidevops/repos.json}"
PLATFORM_LOCAL_LOG="${HOME}/.aidevops/logs/platform-local-ops.log"
_PLAT_LOCAL="local"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_platform_require_gh() {
	if ! command -v gh >/dev/null 2>&1; then
		print_error "gh CLI is required but not installed (https://cli.github.com/)"
		return 1
	fi
	return 0
}

_platform_require_body_input() {
	local body_file="$1"
	if [[ "$body_file" == "-" ]]; then
		return 0
	fi
	if [[ ! -f "$body_file" ]]; then
		print_error "Body file not found: $body_file"
		return 1
	fi
	return 0
}

_platform_consume_local_stdin_body() {
	local body_file="$1"
	if [[ "$body_file" == "-" ]]; then
		command cat >/dev/null || {
			print_error "Failed to consume local platform body from stdin"
			return 1
		}
	fi
	return 0
}

_platform_stub_not_implemented() {
	local platform="$1"
	local operation="$2"
	print_error "P9 task — adapter not implemented: platform=${platform} operation=${operation}"
	print_error "Only GitHub (platform=github) is implemented in this release."
	return 1
}

_platform_local_log() {
	local operation="$1"
	local details="$2"
	mkdir -p "$(dirname "$PLATFORM_LOCAL_LOG")"
	local ts
	ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date +"%Y-%m-%dT%H:%M:%SZ")
	printf '{"ts":"%s","platform":"%s","operation":"%s","details":"%s"}\n' \
		"$ts" "$_PLAT_LOCAL" "$operation" "$details" >>"$PLATFORM_LOCAL_LOG"
	print_info "[${_PLAT_LOCAL}] ${operation}: ${details} (logged to $PLATFORM_LOCAL_LOG)"
	return 0
}

# ---------------------------------------------------------------------------
# platform_detect: determine platform for a repo path
# Prints: github|gitea|gitlab|local
# ---------------------------------------------------------------------------
platform_detect() {
	local repo_path="${1:-$(pwd)}"
	local _raw="${repo_path}"
	repo_path="$(cd "$repo_path" 2>/dev/null && pwd)" || repo_path="$_raw"

	# 1. Check repos.json "platform" field first (explicit override)
	if [[ -f "$REPOS_FILE" ]] && command -v jq >/dev/null 2>&1; then
		local explicit_platform
		explicit_platform=$(jq -r --arg path "$repo_path" \
			'.initialized_repos[] | select(.path == $path) | .platform // ""' \
			"$REPOS_FILE" 2>/dev/null | head -1)
		if [[ -n "$explicit_platform" && "$explicit_platform" != "null" ]]; then
			echo "$explicit_platform"
			return 0
		fi
		# Check local_only flag
		local is_local_only
		is_local_only=$(jq -r --arg path "$repo_path" \
			'.initialized_repos[] | select(.path == $path) | .local_only // false' \
			"$REPOS_FILE" 2>/dev/null | head -1)
		if [[ "$is_local_only" == "true" ]]; then
			echo "$_PLAT_LOCAL"
			return 0
		fi
	fi

	# 2. Detect from remote URL
	local remote_url=""
	if command -v git >/dev/null 2>&1; then
		remote_url=$(git -C "$repo_path" remote get-url origin 2>/dev/null || true)
	fi

	if [[ -z "$remote_url" ]]; then
		echo "$_PLAT_LOCAL"
		return 0
	fi

	case "$remote_url" in
	*github.com*)
		echo "github" ;;
	*gitea.* | *gitea/*)
		echo "gitea" ;;
	*gitlab.com* | *gitlab.*)
		echo "gitlab" ;;
	*)
		echo "$_PLAT_LOCAL" ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# platform_create_issue: create an issue on the detected platform
# Args: <slug> <title> <body_file|-> <labels>
# labels: comma-separated label list (may be empty)
# ---------------------------------------------------------------------------
platform_create_issue() {
	local slug="$1"
	local title="$2"
	local body_file="$3"
	local labels="${4:-}"

	_platform_require_body_input "$body_file" || return 1

	local platform
	platform=$(platform_detect "$(pwd)")

	case "$platform" in
	github)
		_platform_require_gh || return 1
		local label_args=()
		[[ -n "$labels" ]] && label_args=("--label" "$labels")
		gh issue create --repo "$slug" --title "$title" --body-file "$body_file" "${label_args[@]}" || return 1 # aidevops-allow: raw-gh-wrapper
		;;
	local)
		_platform_consume_local_stdin_body "$body_file" || return 1
		_platform_local_log "create_issue" "slug=${slug} title=${title}"
		;;
	*)
		_platform_stub_not_implemented "$platform" "create_issue"
		return 1
		;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# platform_get_issue: view an issue, prints JSON
# Args: <slug> <num>
# ---------------------------------------------------------------------------
platform_get_issue() {
	local slug="$1"
	local num="$2"

	local platform
	platform=$(platform_detect "$(pwd)")

	case "$platform" in
	github)
		_platform_require_gh || return 1
		gh issue view "$num" --repo "$slug" --json number,title,state,body,labels,assignees
		;;
	local)
		_platform_local_log "get_issue" "slug=${slug} num=${num}"
		echo "{}"
		;;
	*)
		_platform_stub_not_implemented "$platform" "get_issue"
		return 1
		;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# platform_comment_issue: post a comment on an issue
# Args: <slug> <num> <body_file|->
# ---------------------------------------------------------------------------
platform_comment_issue() {
	local slug="$1"
	local num="$2"
	local body_file="$3"

	_platform_require_body_input "$body_file" || return 1

	local platform
	platform=$(platform_detect "$(pwd)")

	case "$platform" in
	github)
		_platform_require_gh || return 1
		gh issue comment "$num" --repo "$slug" --body-file "$body_file" || return 1
		;;
	local)
		_platform_consume_local_stdin_body "$body_file" || return 1
		_platform_local_log "comment_issue" "slug=${slug} num=${num}"
		;;
	*)
		_platform_stub_not_implemented "$platform" "comment_issue"
		return 1
		;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# platform_create_pr: create a pull request
# Args: <slug> <title> <body_file|-> <base> <head>
# ---------------------------------------------------------------------------
platform_create_pr() {
	local slug="$1"
	local title="$2"
	local body_file="$3"
	local base="$4"
	local head="$5"

	_platform_require_body_input "$body_file" || return 1

	local platform
	platform=$(platform_detect "$(pwd)")

	case "$platform" in
	github)
		_platform_require_gh || return 1
		gh pr create --repo "$slug" --title "$title" --body-file "$body_file" --base "$base" --head "$head" || return 1 # aidevops-allow: raw-gh-wrapper
		;;
	local)
		_platform_consume_local_stdin_body "$body_file" || return 1
		_platform_local_log "create_pr" "slug=${slug} title=${title} base=${base} head=${head}"
		;;
	*)
		_platform_stub_not_implemented "$platform" "create_pr"
		return 1
		;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# CLI entry-point (when invoked directly, not sourced)
# ---------------------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
	cmd="${1:-help}"
	shift || true
	case "$cmd" in
	detect)
		platform_detect "${1:-$(pwd)}"
		;;
	create-issue)
		platform_create_issue "$@"
		;;
	get-issue)
		platform_get_issue "$@"
		;;
	comment-issue)
		platform_comment_issue "$@"
		;;
	create-pr)
		platform_create_pr "$@"
		;;
	help | -h | --help)
		sed -n '4,25p' "$0" | sed 's/^# \{0,1\}//'
		;;
	*)
		printf "Unknown command: %s\n" "$cmd" >&2
		exit 1
		;;
	esac
fi
