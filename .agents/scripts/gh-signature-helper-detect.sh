#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# gh-signature-helper-detect.sh -- Runtime & CLI Detection
# =============================================================================
# Provides CLI-to-URL mapping, OpenCode version detection, runtime identification,
# Claude Code model detection, and multi-runtime CLI auto-detection.
#
# Usage: source "${SCRIPT_DIR}/gh-signature-helper-detect.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, etc.) -- optional
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_GH_SIG_DETECT_LIB_LOADED:-}" ]] && return 0
_GH_SIG_DETECT_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback (test harnesses / direct sourcing)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# =============================================================================
# CLI-to-URL mapping
# =============================================================================
# Maps CLI display names to their canonical repo/website URLs.
# Add new runtimes here as they become supported.

_cli_url() {
	local cli_name="$1"
	# Bash 3.2 compat: no ${var,,} -- use tr for case conversion
	local cli_lower
	cli_lower=$(printf '%s' "$cli_name" | tr '[:upper:]' '[:lower:]')

	case "$cli_lower" in
	*opencode*) echo "https://opencode.ai" ;;
	*claude*code*) echo "https://claude.ai/code" ;;
	*cursor*) echo "https://cursor.com" ;;
	*windsurf*) echo "https://windsurf.com" ;;
	*aider*) echo "https://aider.chat" ;;
	*continue*) echo "https://continue.dev" ;;
	*copilot*) echo "https://github.com/features/copilot" ;;
	*cody*) echo "https://sourcegraph.com/cody" ;;
	*kilo*code*) echo "https://kilocode.ai" ;;
	*augment*) echo "https://augmentcode.com" ;;
	*factory* | *droid*) echo "https://factory.ai" ;;
	*codex*) echo "https://github.com/openai/codex" ;;
	*warp*) echo "https://warp.dev" ;;
	*) echo "" ;;
	esac
	return 0
}

# =============================================================================
# OpenCode version detection (cross-platform)
# =============================================================================
# Tries multiple methods to find the OpenCode version. Install paths vary
# across macOS (Homebrew, npm -g, bun) and Linux (npm -g, bun, nix).
# Returns version string (e.g., "1.3.5") or empty.

_detect_opencode_version() {
	local ver=""

	# Explicit override for non-interactive wrappers and CI jobs.
	if [[ -n "${AIDEVOPS_SIG_CLI_VERSION:-}" ]]; then
		echo "$AIDEVOPS_SIG_CLI_VERSION"
		return 0
	fi
	if [[ -n "${OPENCODE_VERSION:-}" ]]; then
		echo "$OPENCODE_VERSION"
		return 0
	fi

	# Session-start cache is written by the OpenCode plugin before first turn.
	local greeting_file="${HOME}/.aidevops/cache/session-greeting.txt"
	if [[ -r "$greeting_file" ]]; then
		ver=$(grep -oE 'OpenCode v[0-9]+\.[0-9]+\.[0-9]+' "$greeting_file" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || echo "")
		if [[ -n "$ver" ]]; then
			echo "$ver"
			return 0
		fi
	fi

	# Method 1: opencode --version (if in PATH)
	ver=$(opencode --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
	if [[ -n "$ver" ]]; then
		echo "$ver"
		return 0
	fi

	# Method 2: npm global (works on both macOS and Linux)
	ver=$(npm list -g opencode-ai --json 2>/dev/null | jq -r '.dependencies["opencode-ai"].version // empty' 2>/dev/null || echo "")
	if [[ -n "$ver" ]]; then
		echo "$ver"
		return 0
	fi

	# Method 3: bun global -- check multiple known paths
	local bun_paths=(
		"${HOME}/.bun/install/global/node_modules/opencode-ai/package.json"
		"${HOME}/.bun/install/global/node_modules/.cache/opencode-ai/package.json"
	)
	local bp
	for bp in "${bun_paths[@]}"; do
		ver=$(jq -r '.version // empty' "$bp" 2>/dev/null || echo "")
		if [[ -n "$ver" ]]; then
			echo "$ver"
			return 0
		fi
	done

	# Method 4: resolve the binary path and find package.json nearby
	local bin_path
	bin_path=$(command -v opencode 2>/dev/null || echo "")
	if [[ -n "$bin_path" ]]; then
		# Follow symlinks to the real path
		local real_path
		real_path=$(readlink -f "$bin_path" 2>/dev/null || readlink "$bin_path" 2>/dev/null || echo "$bin_path")
		# Walk up to find package.json (typically ../package.json or ../../package.json)
		local dir
		dir=$(dirname "$real_path" 2>/dev/null || echo "")
		local depth=0
		while [[ -n "$dir" ]] && [[ "$dir" != "/" ]] && [[ $depth -lt 4 ]]; do
			if [[ -f "${dir}/package.json" ]]; then
				ver=$(jq -r '.version // empty' "${dir}/package.json" 2>/dev/null || echo "")
				if [[ -n "$ver" ]]; then
					echo "$ver"
					return 0
				fi
			fi
			dir=$(dirname "$dir" 2>/dev/null || echo "")
			depth=$((depth + 1))
		done
	fi

	echo ""
	return 0
}

# =============================================================================
# Runtime detection -- is this an OpenCode session? (GH#17689)
# =============================================================================
# Returns 0 if running inside OpenCode, 1 otherwise. Gates OpenCode DB queries.

_is_opencode_runtime() {
	# An explicit marker is authoritative. In particular, false prevents the
	# parent-process fallback from misclassifying tests and nested shells.
	case "${OPENCODE:-}" in
	1 | true | TRUE | yes | YES)
		return 0
		;;
	0 | false | FALSE | no | NO)
		return 1
		;;
	esac

	# Fallback: check parent process chain for "opencode"
	local walk_pid="${PPID:-0}"
	local walk_depth=0
	while [[ "$walk_pid" -ge 1 ]] && [[ "$walk_depth" -lt 10 ]] 2>/dev/null; do
		local walk_comm walk_args walk_lower
		walk_comm=$(ps -o comm= -p "$walk_pid" 2>/dev/null || echo "")
		walk_args=$(ps -o args= -p "$walk_pid" 2>/dev/null || echo "")
		walk_lower=$(printf '%s %s' "$walk_comm" "$walk_args" | tr '[:upper:]' '[:lower:]')
		if [[ "$walk_lower" == *opencode* ]]; then
			return 0
		fi
		walk_pid=$(ps -o ppid= -p "$walk_pid" 2>/dev/null | tr -d ' ' || echo "0")
		walk_depth=$((walk_depth + 1))
	done

	return 1
}

# =============================================================================
# Claude Code model detection (GH#17689)
# =============================================================================
# Returns model from ANTHROPIC_MODEL or CLAUDE_MODEL env vars, or empty string.

_detect_claude_code_model() {
	if [[ -n "${ANTHROPIC_MODEL:-}" ]]; then
		echo "$ANTHROPIC_MODEL"
		return 0
	fi
	if [[ -n "${CLAUDE_MODEL:-}" ]]; then
		echo "$CLAUDE_MODEL"
		return 0
	fi

	echo ""
	return 0
}

# =============================================================================
# CLI detection (reuses aidevops-update-check.sh logic)
# =============================================================================

_detect_cli() {
	# Inline detection (mirrors aidevops-update-check.sh detect_app)
	local app_name="" app_version=""

	if [[ "${OPENCODE:-}" == "1" ]]; then
		app_name="OpenCode"
		app_version=$(_detect_opencode_version)
	elif [[ -n "${CLAUDE_CODE:-}" ]] || [[ -n "${CLAUDE_SESSION_ID:-}" ]]; then
		app_name="Claude Code"
		app_version=$(claude --version 2>/dev/null | head -1 | sed 's/ (Claude Code)//' || echo "")
	elif [[ -n "${CURSOR_SESSION:-}" ]] || [[ "${TERM_PROGRAM:-}" == "cursor" ]]; then
		app_name="Cursor"
	elif [[ -n "${WINDSURF_SESSION:-}" ]]; then
		app_name="Windsurf"
	elif [[ -n "${CONTINUE_SESSION:-}" ]]; then
		app_name="Continue"
	elif [[ -n "${AIDER_SESSION:-}" ]]; then
		app_name="Aider"
		app_version=$(aider --version 2>/dev/null | head -1 || echo "")
	elif [[ -n "${FACTORY_DROID:-}" ]]; then
		app_name="Factory Droid"
	elif [[ -n "${AUGMENT_SESSION:-}" ]]; then
		app_name="Augment"
	elif [[ -n "${COPILOT_SESSION:-}" ]]; then
		app_name="GitHub Copilot"
	elif [[ -n "${CODY_SESSION:-}" ]]; then
		app_name="Cody"
	elif [[ -n "${KILO_SESSION:-}" ]]; then
		app_name="Kilo Code"
	elif [[ -n "${WARP_SESSION:-}" ]]; then
		app_name="Warp"
	else
		# Fallback: check parent process name.
		# Use both comm (short) and args (full command line) because on Linux
		# ps -o comm= truncates to 15 chars -- "node" instead of "opencode"
		# when run via Node.js (GH#13012).
		local parent parent_args parent_lower
		parent=$(ps -o comm= -p "${PPID:-0}" 2>/dev/null || echo "")
		parent_args=$(ps -o args= -p "${PPID:-0}" 2>/dev/null || echo "")
		parent_lower=$(printf '%s %s' "$parent" "$parent_args" | tr '[:upper:]' '[:lower:]')
		case "$parent_lower" in
		*opencode*)
			app_name="OpenCode"
			app_version=$(_detect_opencode_version)
			;;
		*claude*)
			app_name="Claude Code"
			app_version=$(claude --version 2>/dev/null | head -1 | sed 's/ (Claude Code)//' || echo "")
			;;
		*cursor*) app_name="Cursor" ;;
		*windsurf*) app_name="Windsurf" ;;
		*aider*)
			app_name="Aider"
			app_version=$(aider --version 2>/dev/null | head -1 || echo "")
			;;
		*) app_name="" ;;
		esac
	fi

	echo "${app_name}|${app_version}"
	return 0
}
