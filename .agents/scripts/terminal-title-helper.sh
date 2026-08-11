#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# terminal-title-helper.sh - Terminal tab/window title integration for aidevops
# Part of aidevops framework: https://aidevops.sh
#
# Sets terminal tab titles using OSC escape sequences (works with most modern terminals)
# Supported: Tabby, iTerm2, Windows Terminal, Kitty, Alacritty, GNOME Terminal, etc.
#
# Usage:
#   terminal-title-helper.sh [command] [options]
#
# Commands:
#   rename [title]     Set tab title (defaults to repo/branch)
#   sync               Sync tab title with current git repo/branch
#   reset              Reset tab title to default
#   detect             Check terminal compatibility
#
# Examples:
#   terminal-title-helper.sh sync                    # Set title to "aidevops/feature/xyz"
#   terminal-title-helper.sh rename "My Project"    # Set custom title
#   terminal-title-helper.sh reset                   # Clear custom title
#
# Environment:
#   TERMINAL_TITLE_FORMAT    Format string: "repo/branch" (default), "branch", "repo"
#   TERMINAL_TITLE_ENABLED   Set to "false" to disable terminal title integration

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Logging: uses shared log_* from shared-constants.sh

# Configuration (support both old and new env var names for compatibility)
TERMINAL_TITLE_FORMAT="${TERMINAL_TITLE_FORMAT:-${TABBY_TAB_TITLE_FORMAT:-repo/branch}}"
TERMINAL_TITLE_ENABLED="${TERMINAL_TITLE_ENABLED:-${AIDEVOPS_TABBY_ENABLED:-true}}"

# =============================================================================
# Core Functions
# =============================================================================

# Set tab title using OSC escape sequence
# Works with most modern terminals: Tabby, iTerm2, Windows Terminal, Kitty, Alacritty, etc.
set_tab_title() {
	local title="$1"

	# OpenCode child shells inherit this ownership marker from aidevops-managed
	# launchers. Whichever TUI component owns OSC, shell helpers must not race it.
	if [[ "${OPENCODE:-}" == "1" && -n "${AIDEVOPS_TERMINAL_TITLE_OWNER:-}" ]]; then
		return 0
	fi

	if [[ "$TERMINAL_TITLE_ENABLED" == "false" ]]; then
		return 0
	fi

	# OSC 0 sets both icon name and window title
	# OSC 2 sets window title only
	# Using OSC 0 for broader compatibility
	printf '\033]0;%s\007' "$title"
}

# Reset tab title to default (empty string triggers terminal default)
reset_tab_title() {
	# Send empty title to reset
	set_tab_title ""
	log_success "Tab title reset to default"
}

# Detect terminal type and OSC compatibility
detect_terminal() {
	local term_program="${TERM_PROGRAM:-}"
	local term="${TERM:-}"

	# Check known terminals by TERM_PROGRAM
	case "$term_program" in
	"Tabby")
		echo "tabby"
		return 0
		;;
	"iTerm.app")
		echo "iterm2"
		return 0
		;;
	"Apple_Terminal")
		echo "apple-terminal"
		return 0
		;;
	"vscode")
		echo "vscode"
		return 0
		;;
	"WezTerm")
		echo "wezterm"
		return 0
		;;
	"Hyper")
		echo "hyper"
		return 0
		;;
	*)
		# Not a known TERM_PROGRAM, continue to TERM check
		;;
	esac

	# Check by TERM variable for other terminals
	case "$term" in
	xterm* | rxvt* | screen* | tmux* | alacritty | kitty*)
		echo "compatible"
		return 0
		;;
	*)
		# Not a known TERM, continue to other checks
		;;
	esac

	# Check for Windows Terminal
	if [[ -n "${WT_SESSION:-}" ]]; then
		echo "windows-terminal"
		return 0
	fi

	# Check for Kitty
	if [[ -n "${KITTY_WINDOW_ID:-}" ]]; then
		echo "kitty"
		return 0
	fi

	# Fallback - if TERM is set and not dumb, likely compatible
	if [[ -n "$term" ]] && [[ "$term" != "dumb" ]]; then
		echo "compatible"
		return 0
	fi

	echo "unknown"
	return 1
}

# Get current git repository name (resolves to main repo name even in worktrees)
get_repo_name() {
	local git_common_dir repo_path

	# git rev-parse --git-common-dir returns the main .git directory
	# even when in a linked worktree
	git_common_dir=$(git rev-parse --git-common-dir 2>/dev/null) || return 1

	# Convert to absolute path to handle subdirectories correctly
	# realpath may not exist on all systems, use cd/pwd as fallback
	local abs_path=""
	if command -v realpath &>/dev/null; then
		# || true prevents set -e from aborting when realpath fails
		# (e.g., path doesn't exist yet); fallback below handles it
		abs_path=$(realpath "$git_common_dir" 2>/dev/null) || true
	fi

	# Fallback to cd/pwd if realpath failed or doesn't exist
	if [[ -z "$abs_path" ]]; then
		abs_path=$(cd "$git_common_dir" 2>/dev/null && pwd) || return 1
	fi

	git_common_dir="$abs_path"

	# The common dir is the .git folder of the main repo
	# Get its parent to find the main repo root
	repo_path=$(dirname "$git_common_dir")

	basename "$repo_path"
}

# Get current git branch name
get_branch_name() {
	git branch --show-current 2>/dev/null || echo ""
}

# Generate tab title based on format
generate_title() {
	local format="${1:-$TERMINAL_TITLE_FORMAT}"
	local repo_name branch_name

	repo_name=$(get_repo_name) || repo_name=""
	branch_name=$(get_branch_name) || branch_name=""

	case "$format" in
	"repo/branch")
		if [[ -n "$repo_name" ]] && [[ -n "$branch_name" ]]; then
			echo "${repo_name}/${branch_name}"
		elif [[ -n "$repo_name" ]]; then
			echo "$repo_name"
		elif [[ -n "$branch_name" ]]; then
			echo "$branch_name"
		else
			echo ""
		fi
		;;
	"branch")
		echo "$branch_name"
		;;
	"repo")
		echo "$repo_name"
		;;
	"branch/repo")
		if [[ -n "$branch_name" ]] && [[ -n "$repo_name" ]]; then
			echo "${branch_name} (${repo_name})"
		elif [[ -n "$branch_name" ]]; then
			echo "$branch_name"
		elif [[ -n "$repo_name" ]]; then
			echo "$repo_name"
		else
			echo ""
		fi
		;;
	*)
		# Custom format - use as-is
		echo "$format"
		;;
	esac
}

# =============================================================================
# Commands
# =============================================================================

cmd_rename() {
	local title="${1:-}"

	if [[ -z "$title" ]]; then
		# Generate title from git context
		title=$(generate_title)
	fi

	if [[ -z "$title" ]]; then
		log_warn "No title provided and not in a git repository"
		return 1
	fi

	set_tab_title "$title"
	log_success "Tab title set to: $title"
}

# Check whether the current branch is a default (non-feature) branch.
# Default branches (main/master/HEAD) are not meaningful terminal titles:
# emitting "main" or "aidevops/main" into the OSC title clobbers the
# meaningful session-level title set earlier (e.g. by session-rename or a
# user-provided title). Called by cmd_sync only — cmd_rename with an
# explicit title remains unguarded (manual override).
# Mirrors `_is_meaningful_branch_title` in session-rename-helper.sh (t2252).
# Returns: 0 if current branch is a default branch, 1 otherwise
_is_default_branch() {
	local branch
	branch=$(get_branch_name) || return 1
	case "$branch" in
	"" | HEAD | main | master) return 0 ;;
	*) return 1 ;;
	esac
}

cmd_sync() {
	# Guard: skip silently when on a default branch. This prevents auto-sync
	# triggers (pre-edit-check.sh, precmd hooks) from clobbering meaningful
	# terminal titles with "main"/"master"/"aidevops/main" when the canonical
	# repo sits on main per t1990. Returns 0 to keep best-effort callers quiet.
	if _is_default_branch; then
		log_info "Skipping terminal title sync: on default branch"
		return 0
	fi

	local title
	title=$(generate_title)

	if [[ -z "$title" ]]; then
		log_warn "Not in a git repository - cannot sync tab title"
		return 1
	fi

	set_tab_title "$title"
	log_success "Tab synced: $title"
}

cmd_reset() {
	reset_tab_title
}

cmd_detect() {
	local terminal
	terminal=$(detect_terminal)
	local upper_terminal
	upper_terminal=$(echo "$terminal" | tr '[:lower:]-' '[:upper:]_')

	case "$terminal" in
	"tabby")
		log_success "Running in Tabby terminal (full OSC support)"
		;;
	"iterm2")
		log_success "Running in iTerm2 (full OSC support)"
		;;
	"windows-terminal")
		log_success "Running in Windows Terminal (full OSC support)"
		;;
	"kitty")
		log_success "Running in Kitty terminal (full OSC support)"
		;;
	"wezterm")
		log_success "Running in WezTerm (full OSC support)"
		;;
	"vscode")
		log_success "Running in VS Code integrated terminal (OSC support)"
		;;
	"apple-terminal")
		log_success "Running in Apple Terminal (basic OSC support)"
		;;
	"hyper")
		log_success "Running in Hyper terminal (OSC support)"
		;;
	"compatible")
		log_info "Running in OSC-compatible terminal: ${TERM:-unknown}"
		;;
	*)
		log_warn "Unknown terminal - OSC sequences may not work"
		echo "$upper_terminal"
		return 1
		;;
	esac

	echo "$upper_terminal"
}

cmd_help() {
	cat <<'EOF'
terminal-title-helper.sh - Terminal tab/window title integration for aidevops

Sets terminal tab titles using OSC escape sequences. Works with most modern terminals:
Tabby, iTerm2, Windows Terminal, Kitty, Alacritty, WezTerm, Hyper, GNOME Terminal, etc.

USAGE:
    terminal-title-helper.sh <command> [options]

COMMANDS:
    rename [title]     Set tab title (defaults to repo/branch if no title given)
    sync               Sync tab title with current git repo/branch
    reset              Reset tab title to terminal default
    detect             Check terminal type and OSC compatibility
    help               Show this help message

EXAMPLES:
    # Sync tab title with git context
    terminal-title-helper.sh sync

    # Set custom title
    terminal-title-helper.sh rename "My Project"

    # Check terminal compatibility
    terminal-title-helper.sh detect

ENVIRONMENT VARIABLES:
    TERMINAL_TITLE_FORMAT
        Auto-generated title format. Options:
        - "repo/branch" (default): "aidevops/feature/xyz"
        - "branch": "feature/xyz"
        - "repo": "aidevops"
        - "branch/repo": "feature/xyz (aidevops)"

    TERMINAL_TITLE_ENABLED
        Set to "false" to disable terminal title integration

SHELL INTEGRATION:
    To enable automatic sync on directory change, add to ~/.bashrc or ~/.zshrc:

    # Bash
    PROMPT_COMMAND='~/.aidevops/agents/scripts/terminal-title-helper.sh sync 2>/dev/null'

    # Zsh
    precmd() { ~/.aidevops/agents/scripts/terminal-title-helper.sh sync 2>/dev/null }

    # Fish
    function fish_prompt
        ~/.aidevops/agents/scripts/terminal-title-helper.sh sync 2>/dev/null
        # ... rest of prompt
    end

EOF
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	rename)
		cmd_rename "$@"
		;;
	sync)
		cmd_sync
		;;
	reset)
		cmd_reset
		;;
	detect)
		cmd_detect
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		log_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
