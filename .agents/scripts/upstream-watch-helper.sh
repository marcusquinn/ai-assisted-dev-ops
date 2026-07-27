#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# upstream-watch-helper.sh -- Track external repos for release monitoring (t1426)
#
# Maintains a watchlist of external repos we've borrowed ideas/code from.
# Checks for new releases and significant commits, shows changelog diffs
# between our last-seen version and latest. Distinct from:
#   - skill-sources.json (imported skills -- tracked by add-skill-helper.sh)
#   - contribution-watch (repos we've contributed to)
#
# This covers "inspiration repos" -- repos we want to passively monitor
# for improvements relevant to our implementation.
#
# Usage:
#   upstream-watch-helper.sh add <owner/repo> [--relevance "why we care"] [--mode releases]
#   upstream-watch-helper.sh remove <owner/repo>
#   upstream-watch-helper.sh check [--verbose]     Check all watched repos for updates
#   upstream-watch-helper.sh check <owner/repo>    Check a specific repo
#   upstream-watch-helper.sh ack <owner/repo>      Acknowledge latest release (mark as seen)
#   upstream-watch-helper.sh status                Show all watched repos and their state
#   upstream-watch-helper.sh help                  Show usage
#
# Config: ~/.aidevops/agents/configs/upstream-watch.json (template committed)
# State:  ~/.aidevops/cache/upstream-watch-state.json (runtime, gitignored)
# Log:    ~/.aidevops/logs/upstream-watch.log
#
# Sub-libraries (sourced below):
#   upstream-watch-helper-state.sh   -- logging, prerequisites, state/config I/O
#   upstream-watch-helper-issues.sh  -- GitHub issue filing/closing (t2810)
#   upstream-watch-helper-check.sh   -- probe, check, diff display, cmd_check

set -euo pipefail

# PATH normalisation for launchd/MCP environments
_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/bin:/usr/bin"
if [[ "$(uname -s 2>/dev/null || true)" != "Darwin" && -d "/home/linuxbrew/.linuxbrew/bin" ]]; then
	_aidevops_path_prefix="/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin:/bin:/usr/bin"
fi
export PATH="${_aidevops_path_prefix}:${PATH}"
unset _aidevops_path_prefix

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1

# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh" 2>/dev/null || true

# Fallback colours if shared-constants.sh not loaded
[[ -z "${RED+x}" ]] && RED='\033[0;31m'
[[ -z "${GREEN+x}" ]] && GREEN='\033[0;32m'
[[ -z "${YELLOW+x}" ]] && YELLOW='\033[1;33m'
[[ -z "${BLUE+x}" ]] && BLUE='\033[0;34m'
[[ -z "${CYAN+x}" ]] && CYAN='\033[0;36m'
[[ -z "${NC+x}" ]] && NC='\033[0m'

# =============================================================================
# Configuration
# =============================================================================

AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-$HOME/.aidevops/agents}"
CONFIG_FILE="${AGENTS_DIR}/configs/upstream-watch.json"
STATE_FILE="${HOME}/.aidevops/cache/upstream-watch-state.json"
LOGFILE="${HOME}/.aidevops/logs/upstream-watch.log"
UPSTREAM_WATCH_LABEL="${UPSTREAM_WATCH_LABEL:-source:upstream-watch}"
if [[ -z "${UPSTREAM_WATCH_STATUS_NONE+x}" ]]; then
	readonly UPSTREAM_WATCH_STATUS_NONE="none"
fi
if [[ -z "${UPSTREAM_WATCH_STATUS_NEVER+x}" ]]; then
	readonly UPSTREAM_WATCH_STATUS_NEVER="never"
fi

# Logging prefix for shared log_* functions
# shellcheck disable=SC2034
LOG_PREFIX="upstream-watch"

# =============================================================================
# Source sub-libraries
# =============================================================================

# shellcheck source=./upstream-watch-helper-state.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/upstream-watch-helper-state.sh"

# shellcheck source=./upstream-watch-helper-issues.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/upstream-watch-helper-issues.sh"

# shellcheck source=./upstream-watch-helper-check.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/upstream-watch-helper-check.sh"

# =============================================================================
# Commands
# =============================================================================

#######################################
# Build a committed GitHub watch entry with its reviewed baseline.
# Arguments: slug, description, relevance, mode, release, commit, branch, added-at
#######################################
_build_github_watch_entry() {
	local slug="$1"
	local description="$2"
	local relevance="$3"
	local watch_mode="$4"
	local baseline_release="$5"
	local baseline_commit="$6"
	local default_branch="$7"
	local added_at="$8"
	jq -n \
		--arg slug "$slug" \
		--arg desc "$description" \
		--arg relevance "$relevance" \
		--arg watch_mode "$watch_mode" \
		--arg baseline_release "$baseline_release" \
		--arg baseline_commit "$baseline_commit" \
		--arg branch "$default_branch" \
		--arg added "$added_at" \
		'{
			slug: $slug,
			description: $desc,
			relevance: $relevance,
			watch_mode: $watch_mode,
			baseline_release: $baseline_release,
			baseline_commit: $baseline_commit,
			default_branch: $branch,
			added_at: $added
		}' || return 1
	return 0
}

#######################################
# Add a repository to the upstream watchlist
# Verifies the repo exists, captures initial state (latest release/commit),
# and stores config + state so the first check doesn't flag everything as new.
# Arguments:
#   $1 - Repository slug (owner/repo)
#   $2 - Optional relevance description
#   $3 - Watch mode (releases or releases-and-commits)
#######################################
cmd_add() {
	local slug="$1"
	local relevance="${2:-}"
	local watch_mode="${3:-$UPSTREAM_WATCH_MODE_RELEASES_AND_COMMITS}"

	if [[ -z "$slug" ]]; then
		echo -e "${RED}Error: Repository slug required (owner/repo)${NC}" >&2
		return 1
	fi

	# Validate slug format
	if [[ ! "$slug" =~ ^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$ ]]; then
		echo -e "${RED}Error: Invalid slug format. Expected: owner/repo${NC}" >&2
		return 1
	fi
	if ! _upstream_watch_mode_valid "$watch_mode"; then
		echo -e "${RED}Error: Invalid watch mode '${watch_mode}'. Expected ${UPSTREAM_WATCH_MODE_RELEASES} or ${UPSTREAM_WATCH_MODE_RELEASES_AND_COMMITS}.${NC}" >&2
		return 1
	fi

	_check_prerequisites || return 1

	# Check if already watched
	local config
	config=$(_read_config)
	local existing
	existing=$(echo "$config" | jq -r --arg slug "$slug" '.repos[] | select(.slug == $slug) | .slug')
	if [[ -n "$existing" ]]; then
		echo -e "${YELLOW}Already watching: ${slug}${NC}"
		return 0
	fi

	# Verify repo exists and get metadata
	echo -e "${BLUE}Verifying repo: ${slug}...${NC}"
	local repo_info repo_err
	repo_err=$(gh api "repos/${slug}" --jq '{description, stargazers_count, pushed_at, default_branch}' 2>&1) && repo_info="$repo_err" || {
		echo -e "${RED}Error: Could not access repo ${slug}: ${repo_err}${NC}" >&2
		return 1
	}

	local description default_branch
	description=$(echo "$repo_info" | jq -r '.description // "No description"')
	default_branch=$(echo "$repo_info" | jq -r '.default_branch // "main"')

	# Get latest release (if any)
	local latest_release latest_tag
	latest_release=$(gh api "repos/${slug}/releases/latest" --jq '{tag_name, published_at, name}' 2>/dev/null) || latest_release=""
	if [[ -n "$latest_release" ]]; then
		latest_tag=$(echo "$latest_release" | jq -r '.tag_name')
	else
		latest_tag=""
	fi

	# Get latest commit SHA
	local latest_commit
	latest_commit=$(gh api "repos/${slug}/commits?per_page=1" --jq '.[0].sha // empty' 2>/dev/null) || latest_commit=""

	# Build the entry
	local now
	now=$(_now_iso)
	local new_entry
	new_entry=$(_build_github_watch_entry "$slug" "$description" "$relevance" "$watch_mode" \
		"$latest_tag" "$latest_commit" "$default_branch" "$now") || return 1

	# Add to config
	config=$(echo "$config" | jq --argjson entry "$new_entry" '.repos += [$entry]')
	_write_config "$config"

	# Set initial state (so first check doesn't flag everything as new)
	local state
	state=$(_read_state)
	local state_entry
	state_entry=$(jq -n \
		--arg tag "$latest_tag" \
		--arg commit "${latest_commit:0:7}" \
		--arg checked "$now" \
		'{
			last_release_seen: $tag,
			last_commit_seen: $commit,
			last_checked: $checked,
			updates_pending: 0
		}')
	state=$(echo "$state" | jq --arg slug "$slug" --argjson entry "$state_entry" '.repos[$slug] = $entry')
	_write_state "$state"

	echo -e "${GREEN}Now watching: ${slug}${NC}"
	echo "  Description: ${description}"
	[[ -n "$relevance" ]] && echo "  Relevance:   ${relevance}"
	[[ -n "$latest_tag" ]] && echo "  Latest release: ${latest_tag}"
	echo "  Watch mode: ${watch_mode}"
	echo "  Default branch: ${default_branch}"
	_log_info "Added watch: ${slug} (mode: ${watch_mode}, relevance: ${relevance:-none})"
	return 0
}

#######################################
# Remove a repository from the upstream watchlist and clean up its state
# Arguments:
#   $1 - Repository slug (owner/repo)
#######################################
cmd_remove() {
	local slug="$1"

	if [[ -z "$slug" ]]; then
		echo -e "${RED}Error: Repository slug required (owner/repo)${NC}" >&2
		return 1
	fi

	local config
	config=$(_read_config)
	local existing
	existing=$(echo "$config" | jq -r --arg slug "$slug" '.repos[] | select(.slug == $slug) | .slug')
	if [[ -z "$existing" ]]; then
		echo -e "${YELLOW}Not watching: ${slug}${NC}"
		return 0
	fi

	config=$(echo "$config" | jq --arg slug "$slug" '.repos = [.repos[] | select(.slug != $slug)]')
	_write_config "$config"

	# Remove from state
	local state
	state=$(_read_state)
	state=$(echo "$state" | jq --arg slug "$slug" 'del(.repos[$slug])')
	_write_state "$state"

	echo -e "${GREEN}Removed: ${slug}${NC}"
	_log_info "Removed watch: ${slug}"
	return 0
}

#######################################
# Acknowledge the latest release/commit for a watched repo
# Updates last_release_seen and last_commit_seen to current, clears
# updates_pending. Validates slug against config watchlist first.
# Also closes any matching upstream-watch GitHub issue (t2810).
# Arguments:
#   $1 - Repository slug (owner/repo) or non-GitHub upstream name
#   $2 - Optional note for the close comment (e.g. "adopted in PR #123")
#######################################
cmd_ack() {
	local slug="$1"
	local note="${2:-}"

	if [[ -z "$slug" ]]; then
		echo -e "${RED}Error: Repository slug or upstream name required${NC}" >&2
		return 1
	fi

	local config
	config=$(_read_config)
	local state
	state=$(_read_state)
	local now
	now=$(_now_iso)

	# Check if this is a non-GitHub upstream name
	if echo "$config" | jq -e --arg name "$slug" '.non_github_upstreams // [] | .[] | select(.name == $name)' >/dev/null 2>&1; then
		# Non-GitHub upstream -- run check_command to get current value and store as last_seen
		local check_cmd
		check_cmd=$(echo "$config" | jq -r --arg name "$slug" '.non_github_upstreams[] | select(.name == $name) | .check_command // ""')

		local current_value=""
		if [[ -n "$check_cmd" ]]; then
			current_value=$(bash -c "$check_cmd" 2>/dev/null | tr -d '[:space:]') || current_value=""
		fi

		# Also update last_seen_commit in config if the entry has one
		local has_last_seen_commit
		has_last_seen_commit=$(echo "$config" | jq -r --arg name "$slug" '.non_github_upstreams[] | select(.name == $name) | .last_seen_commit // ""')
		if [[ -n "$has_last_seen_commit" ]]; then
			config=$(echo "$config" | jq --arg name "$slug" --arg commit "$current_value" \
				'(.non_github_upstreams[] | select(.name == $name) | .last_seen_commit) = $commit')
			_write_config "$config"
		fi

		state=$(echo "$state" | jq --arg name "$slug" --arg value "$current_value" --arg now "$now" \
			'.non_github[$name].last_seen = $value | .non_github[$name].last_checked = $now | .non_github[$name].updates_pending = 0')
		_write_state "$state"

		echo -e "${GREEN}Acknowledged: ${slug} at ${current_value:-unknown}${NC}"
		_log_info "Acknowledged non-GitHub upstream: ${slug} at ${current_value:-unknown}"

		# Close matching GitHub issue (t2810)
		_close_upstream_update_issue "$slug" "$note"
		return 0
	fi

	# GitHub repo -- original logic
	_check_prerequisites || return 1

	# Validate against config watchlist (consistent with cmd_check)
	if ! echo "$config" | jq -e --arg slug "$slug" '.repos[] | select(.slug == $slug)' >/dev/null 2>&1; then
		echo -e "${RED}Error: Not watching ${slug}. Add it first with 'upstream-watch-helper.sh add ${slug}'.${NC}" >&2
		return 1
	fi

	# Get current latest release
	local latest_tag
	latest_tag=$(gh api "repos/${slug}/releases/latest" --jq '.tag_name' 2>/dev/null) || latest_tag=""

	local latest_commit
	latest_commit=$(gh api "repos/${slug}/commits?per_page=1" --jq '.[0].sha // empty' 2>/dev/null) || latest_commit=""

	state=$(echo "$state" | jq --arg slug "$slug" --arg tag "$latest_tag" \
		--arg commit "${latest_commit:0:7}" --arg now "$now" \
		'.repos[$slug].last_release_seen = $tag | .repos[$slug].last_commit_seen = $commit | .repos[$slug].last_checked = $now | .repos[$slug].updates_pending = 0')
	_write_state "$state"

	echo -e "${GREEN}Acknowledged: ${slug} at ${latest_tag:-commit ${latest_commit:0:7}}${NC}"
	_log_info "Acknowledged: ${slug} at ${latest_tag:-${latest_commit:0:7}}"

	# Close matching GitHub issue (t2810)
	_close_upstream_update_issue "$slug" "$note"
	return 0
}

#######################################
# Display the status of all watched repos
# Shows repo count, last check time, and per-repo state including
# last release/commit seen, last checked date, and pending updates.
#######################################
cmd_status() {
	local config
	config=$(_read_config)
	local state
	state=$(_read_state)

	local repo_count non_github_count
	repo_count=$(echo "$config" | jq '.repos | length')
	non_github_count=$(echo "$config" | jq '.non_github_upstreams // [] | length')
	local total_count=$((repo_count + non_github_count))

	if [[ "$total_count" -eq 0 ]]; then
		echo -e "${BLUE}No repos being watched.${NC}"
		echo ""
		echo "Add repos with: upstream-watch-helper.sh add <owner/repo> --relevance \"why we care\""
		return 0
	fi

	local last_check
	last_check=$(echo "$state" | jq -r --arg fallback "$UPSTREAM_WATCH_STATUS_NEVER" '.last_check // $fallback')

	echo -e "${BLUE}Upstream Watch Status${NC}"
	echo "GitHub repos:          ${repo_count}"
	echo "Non-GitHub upstreams:  ${non_github_count}"
	echo "Last check:            ${last_check}"
	echo ""

	# GitHub repos
	if [[ "$repo_count" -gt 0 ]]; then
		echo -e "${BLUE}GitHub Repos${NC}"
		echo "$config" | jq -r '.repos[] | .slug' | while IFS= read -r slug; do
			[[ -z "$slug" ]] && continue

			local relevance watch_mode
			relevance=$(echo "$config" | jq -r --arg slug "$slug" '.repos[] | select(.slug == $slug) | .relevance // ""')
			watch_mode=$(echo "$config" | jq -r --arg slug "$slug" --arg default_mode "$UPSTREAM_WATCH_MODE_RELEASES_AND_COMMITS" '.repos[] | select(.slug == $slug) | .watch_mode // $default_mode')
			local last_release last_commit last_checked pending
			last_release=$(echo "$state" | jq -r --arg slug "$slug" --arg fallback "$UPSTREAM_WATCH_STATUS_NONE" '.repos[$slug].last_release_seen // $fallback')
			last_commit=$(echo "$state" | jq -r --arg slug "$slug" --arg fallback "$UPSTREAM_WATCH_STATUS_NONE" '.repos[$slug].last_commit_seen // $fallback')
			last_checked=$(echo "$state" | jq -r --arg slug "$slug" --arg fallback "$UPSTREAM_WATCH_STATUS_NEVER" '.repos[$slug].last_checked // $fallback')
			pending=$(echo "$state" | jq -r --arg slug "$slug" '.repos[$slug].updates_pending // 0')

			if [[ "$pending" -gt 0 ]]; then
				echo -e "  ${YELLOW}*${NC} ${slug}"
			else
				echo -e "  ${GREEN}-${NC} ${slug}"
			fi
			echo "    Last release seen: ${last_release}"
			if [[ "$watch_mode" == "$UPSTREAM_WATCH_MODE_RELEASES" ]]; then
				echo "    Last commit seen:  not tracked"
			else
				echo "    Last commit seen:  ${last_commit}"
			fi
			echo "    Watch mode:        ${watch_mode}"
			echo "    Last checked:      ${last_checked:0:10}"
			[[ -n "$relevance" ]] && echo "    Relevance:         ${relevance}"
			echo ""
		done
	fi

	# Non-GitHub upstreams
	if [[ "$non_github_count" -gt 0 ]]; then
		echo -e "${BLUE}Non-GitHub Upstreams${NC}"
		echo "$config" | jq -r '.non_github_upstreams[] | .name' | while IFS= read -r entry_name; do
			[[ -z "$entry_name" ]] && continue

			local source_type description relevance
			source_type=$(echo "$config" | jq -r --arg name "$entry_name" '.non_github_upstreams[] | select(.name == $name) | .source_type // "unknown"')
			description=$(echo "$config" | jq -r --arg name "$entry_name" '.non_github_upstreams[] | select(.name == $name) | .description // ""')
			relevance=$(echo "$config" | jq -r --arg name "$entry_name" '.non_github_upstreams[] | select(.name == $name) | .relevance // ""')

			local last_seen last_checked pending
			last_seen=$(echo "$state" | jq -r --arg name "$entry_name" --arg fallback "$UPSTREAM_WATCH_STATUS_NONE" '.non_github[$name].last_seen // $fallback')
			last_checked=$(echo "$state" | jq -r --arg name "$entry_name" --arg fallback "$UPSTREAM_WATCH_STATUS_NEVER" '.non_github[$name].last_checked // $fallback')
			pending=$(echo "$state" | jq -r --arg name "$entry_name" '.non_github[$name].updates_pending // 0')

			if [[ "$pending" -gt 0 ]]; then
				echo -e "  ${YELLOW}*${NC} ${entry_name} (${source_type})"
			else
				echo -e "  ${GREEN}-${NC} ${entry_name} (${source_type})"
			fi
			echo "    Description:  ${description}"
			echo "    Last seen:    ${last_seen}"
			echo "    Last checked: ${last_checked:0:10}"
			[[ -n "$relevance" ]] && echo "    Relevance:    ${relevance}"
			echo ""
		done
	fi

	return 0
}

#######################################
# Display usage information and examples
#######################################
cmd_help() {
	cat <<'EOF'
upstream-watch-helper.sh -- Track external repos for release monitoring

USAGE:
    upstream-watch-helper.sh <command> [options]

COMMANDS:
    add <owner/repo> [--relevance "..."] [--mode MODE]
                                             Add a repo to the watchlist
    add <owner/repo> --releases-only         Shortcut for --mode releases
    remove <owner/repo>                     Remove a repo from the watchlist
    check [--verbose]                       Check all repos for new releases/commits
    check <owner/repo>                      Check a specific repo
    ack <owner/repo> [--note "..."]          Mark latest release as seen
    status                                  Show all watched repos and their state
    help                                    Show this help

EXAMPLES:
    # Watch a repo
    upstream-watch-helper.sh add vercel-labs/portless \
      --relevance "Local dev hosting -- compare against localdev-helper.sh"

    # Watch stable releases without reacting to every commit
    upstream-watch-helper.sh add vercel-labs/native --releases-only \
      --relevance "Review desktop-shell and agent-native GUI improvements"

    # Check for updates
    upstream-watch-helper.sh check
    upstream-watch-helper.sh check --verbose    # Include commit-level detail

    # After reviewing, acknowledge the update
    upstream-watch-helper.sh ack vercel-labs/portless
    upstream-watch-helper.sh ack vercel-labs/portless --note "adopted in PR #123"

    # See what we're watching
    upstream-watch-helper.sh status

CONFIG:
    Watchlist: ~/.aidevops/agents/configs/upstream-watch.json
    State:     ~/.aidevops/cache/upstream-watch-state.json
    Log:       ~/.aidevops/logs/upstream-watch.log

    GitHub entries default to "releases-and-commits". Set watch_mode to
    "releases" (or use --releases-only) for fast-moving inspiration repos.
    Optional baseline_release and baseline_commit values seed a new install
    at the last reviewed upstream state without generating a historical alert.

NON-GITHUB UPSTREAMS:
    Repos on Docker Hub, GitLab, Forgejo, etc. are configured in
    upstream-watch.json under "non_github_upstreams". Each entry has
    a "check_command" (curl + jq) that returns the current version
    or commit SHA. Use the entry "name" for check/ack commands:

    upstream-watch-helper.sh check cloudron-base-image
    upstream-watch-helper.sh ack cloudron-official-skills

INTEGRATION:
    The pulse can call 'upstream-watch-helper.sh check' to surface
    updates during supervisor sweeps. When an update is detected
    (updates_pending transitions 0->1), a GitHub issue is filed
    automatically with labels source:upstream-watch, auto-dispatch,
    tier:standard. The 'ack' command closes the matching issue.
    Both GitHub repos and non-GitHub upstreams are checked in a
    single pass.

    Skill imports (skill-sources.json) are tracked separately by
    add-skill-helper.sh. This tool is for repos we haven't imported
    from but want to monitor for ideas and improvements.
EOF
	return 0
}

# =============================================================================
# Main dispatch
# =============================================================================

#######################################
# Parse add-command options and dispatch to cmd_add.
# Arguments:
#   $@ - Repository slug and add options
#######################################
_dispatch_add() {
	local slug=""
	local relevance=""
	local watch_mode="$UPSTREAM_WATCH_MODE_RELEASES_AND_COMMITS"
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--relevance)
			local relevance_value="${2:-}"
			if [[ $# -ge 2 && -n "$relevance_value" && "${relevance_value:0:1}" != "-" ]]; then
				relevance="$relevance_value"
				shift 2
			else
				echo -e "${RED}Error: --relevance requires a value${NC}" >&2
				return 1
			fi
			;;
		--mode)
			local mode_value="${2:-}"
			if [[ $# -ge 2 && -n "$mode_value" && "${mode_value:0:1}" != "-" ]]; then
				watch_mode="$mode_value"
				shift 2
			else
				echo -e "${RED}Error: --mode requires a value${NC}" >&2
				return 1
			fi
			;;
		--releases-only)
			watch_mode="$UPSTREAM_WATCH_MODE_RELEASES"
			shift
			;;
		*)
			[[ -n "$slug" ]] || slug="$arg"
			shift
			;;
		esac
	done
	cmd_add "$slug" "$relevance" "$watch_mode"
	return 0
}

#######################################
# Main entry point -- parse command and dispatch to handler
# Arguments:
#   $1 - Command (add, remove, check, ack, status, help)
#   $@ - Command-specific arguments
#######################################
main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	add)
		_dispatch_add "$@"
		;;
	remove | rm)
		local remove_slug="${1:-}"
		cmd_remove "$remove_slug"
		;;
	check)
		local target=""
		local verbose=false
		while [[ $# -gt 0 ]]; do
			local check_arg="$1"
			case "$check_arg" in
			--verbose | -v)
				verbose=true
				shift
				;;
			*)
				target="$check_arg"
				shift
				;;
			esac
		done
		VERBOSE="$verbose" cmd_check "$target"
		;;
	ack | acknowledge)
		local ack_slug=""
		local ack_note=""
		while [[ $# -gt 0 ]]; do
			local _ack_cur="$1"
			shift
			case "$_ack_cur" in
			--note)
				if [[ $# -ge 1 ]]; then
					local _note_val="$1"
					ack_note="$_note_val"
					shift
				else
					echo -e "${RED}Error: --note requires a value${NC}" >&2
					return 1
				fi
				;;
			*)
				[[ -z "$ack_slug" ]] && ack_slug="$_ack_cur"
				;;
			esac
		done
		cmd_ack "$ack_slug" "$ack_note"
		;;
	status | list)
		cmd_status
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		echo -e "${RED}Unknown command: ${cmd}${NC}" >&2
		echo "Run 'upstream-watch-helper.sh help' for usage." >&2
		return 1
		;;
	esac
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
