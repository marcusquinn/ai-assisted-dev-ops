#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Tool Version Check
# Checks versions of key tools and flags outdated ones
#
# Usage:
#   tool-version-check.sh              # Check all tools
#   tool-version-check.sh --update     # Check and update outdated tools
#   tool-version-check.sh --category npm  # Check only npm tools
#   tool-version-check.sh --json       # Output as JSON
#
# Categories: npm, brew, pip, custom, all (default)

# shellcheck disable=SC1091
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

[[ -z "${BOLD+x}" ]] && BOLD='\033[1m'

# Parse arguments
AUTO_UPDATE=false
CATEGORY="all"
JSON_OUTPUT=false
QUIET=false

while [[ $# -gt 0 ]]; do
	case "$1" in
	--update | -u)
		AUTO_UPDATE=true
		shift
		;;
	--category | -c)
		if [[ -z "${2:-}" ]]; then
			echo "Error: --category requires a value (npm, brew, pip, custom, all)"
			exit 1
		fi
		CATEGORY="$2"
		shift 2
		;;
	--json | -j)
		JSON_OUTPUT=true
		shift
		;;
	--quiet | -q)
		QUIET=true
		shift
		;;
	--help | -h)
		echo "Usage: tool-version-check.sh [OPTIONS]"
		echo ""
		echo "Options:"
		echo "  --update, -u       Automatically update outdated tools"
		echo "  --category, -c     Check only specific category (npm, brew, pip, custom, all)"
		echo "  --json, -j         Output results as JSON"
		echo "  --quiet, -q        Only show outdated tools"
		echo "  --help, -h         Show this help"
		exit 0
		;;
	*)
		echo "Unknown option: $1"
		exit 1
		;;
	esac
done

# OPENCODE_PINNED_VERSION is set in shared-constants.sh (sourced above).
# To unpin: change to "latest" in shared-constants.sh when the upstream fix ships.

# Detect how OpenCode was installed — build the right upgrade command.
# update_cmd is executed via `bash -c` so it must be a self-contained string.
# Homebrew ownership must be checked before the npm fallback against the exact
# opencode formula prefix; npm-managed binaries can also live under brew's root.
# Bun-installed binaries still use the direct path heuristic because they live
# under ~/.bun/bin/ and macOS lacks GNU `readlink -f` by default.
# $1 = OpenCode package version to install with bun/npm when not Homebrew-owned.
_opencode_upgrade_cmd() {
	local pkg_version="$1"
	if ! aidevops_opencode_upgrade_command "$pkg_version"; then
		return 1
	fi
	return 0
}

_oc_upgrade_cmd=$(_opencode_upgrade_cmd "$OPENCODE_PINNED_VERSION")

# Platform-aware brew package upgrade command.
# On macOS (or any system with brew), use brew upgrade.
# On Debian/Ubuntu (apt), use apt-get install --only-upgrade.
# On Fedora/RHEL/CentOS (dnf/yum), use dnf upgrade.
# Falls back to brew upgrade if no system package manager is detected.
# $1 = brew formula name (e.g. "gh", "jq", "shellcheck")
# $2 = apt/dnf package name if different from brew name (optional; defaults to $1)
# The returned string is a self-contained bash -c payload (no expansion at definition time).
# shellcheck disable=SC2016  # Single quotes intentional: bash -c payload
_brew_upgrade_cmd() {
	local brew_pkg="$1"
	local sys_pkg="${2:-$1}"
	# Return a self-contained bash -c string that detects the package manager at runtime.
	# Uses single quotes so variables are NOT expanded now — they expand inside bash -c.
	printf '%s' 'if command -v brew >/dev/null 2>&1; then brew upgrade '"${brew_pkg}"'; elif command -v apt-get >/dev/null 2>&1; then sudo apt-get install --only-upgrade -y '"${sys_pkg}"'; elif command -v dnf >/dev/null 2>&1; then sudo dnf upgrade -y '"${sys_pkg}"'; elif command -v yum >/dev/null 2>&1; then sudo yum upgrade -y '"${sys_pkg}"'; else echo "No supported package manager found (brew/apt-get/dnf/yum)" >&2; exit 1; fi'
}

# PEP 668-safe pip upgrade command.
# Ubuntu 24.04+, Fedora 38+, and modern Debian mark the system Python as
# "externally managed" — bare `pip install` is blocked with an error.
# Safe upgrade order: pipx (isolated venv) → pip --user (user site-packages).
# $1 = pip package name (e.g. "beads-viewer", "dspy-ai", "crawl4ai")
# shellcheck disable=SC2016  # Single quotes intentional: bash -c payload
_pip_upgrade_cmd() {
	local pkg="$1"
	printf '%s' 'if command -v pipx >/dev/null 2>&1 && pipx list --short 2>/dev/null | grep -qi '"^${pkg}"'; then pipx upgrade '"${pkg}"'; else pip install --user --upgrade '"${pkg}"' 2>/dev/null || pip install --upgrade '"${pkg}"'; fi'
}

# Tool definitions
# Format: category|display_name|cli_command|version_flag|package_name|update_command

NPM_TOOLS=(
	"npm|OpenCode|opencode|--version|opencode-ai|${_oc_upgrade_cmd}"
	"npm|Claude Code CLI|claude|--version|@anthropic-ai/claude-code|npm install -g @anthropic-ai/claude-code@latest"
	"npm|Codex CLI|codex|--version|@openai/codex|npm install -g @openai/codex@latest"
	"npm|Repomix|repomix|--version|repomix|npm install -g repomix@latest"
	"npm|DSPyGround|dspyground|--version|dspyground|npm install -g dspyground@latest"
	"npm|LocalWP MCP|mcp-local-wp|--version|@verygoodplugins/mcp-local-wp|npm install -g @verygoodplugins/mcp-local-wp@latest"
	"npm|Beads UI|beads-ui|--version|beads-ui|npm install -g beads-ui@latest"
	"npm|BDUI|bdui|--version|bdui|npm install -g bdui@latest"
	"npm|Chrome DevTools MCP|chrome-devtools-mcp|--version|chrome-devtools-mcp|npm install -g chrome-devtools-mcp@latest"
	"npm|GSC MCP|mcp-server-gsc|--version|mcp-server-gsc|npm install -g mcp-server-gsc@latest"
	"npm|Playwriter MCP|playwriter|--version|playwriter|npm install -g playwriter@latest"
	"npm|macOS Automator MCP|macos-automator-mcp|--version|@steipete/macos-automator-mcp|npm install -g @steipete/macos-automator-mcp@latest"
	"npm|Claude Code MCP|claude-code-mcp|--version|@steipete/claude-code-mcp|npm install -g @steipete/claude-code-mcp@latest"
	"npm|Google Workspace CLI|gws|--version|@googleworkspace/cli|npm install -g @googleworkspace/cli@latest"
)

BREW_TOOLS=(
	"brew|GitHub CLI|gh|--version|gh|$(_brew_upgrade_cmd gh)"
	"brew|GitLab CLI|glab|--version|glab|$(_brew_upgrade_cmd glab)"
	"brew|Worktrunk|wt|--version|max-sixty/worktrunk/wt|$(_brew_upgrade_cmd max-sixty/worktrunk/wt)"
	"brew|Beads CLI|bd|version|steveyegge/beads/bd|$(_brew_upgrade_cmd steveyegge/beads/bd)"
	"brew|jq|jq|--version|jq|$(_brew_upgrade_cmd jq)"
	"brew|ripgrep|rg|--version|ripgrep|$(_brew_upgrade_cmd ripgrep)"
	"brew|ShellCheck|shellcheck|--version|shellcheck|$(_brew_upgrade_cmd shellcheck)"
)

PIP_TOOLS=(
	"pip|Beads Viewer|beads_viewer|--version|beads-viewer|$(_pip_upgrade_cmd beads-viewer)"
	"pip|Analytics MCP|analytics-mcp|--version|analytics-mcp|pipx upgrade analytics-mcp"
	"pip|Outscraper MCP|outscraper-mcp-server|--version|outscraper-mcp-server|uv tool upgrade outscraper-mcp-server"
)
# Library dependencies (e.g. dspy-ai, crawl4ai) are intentionally excluded from
# PIP_TOOLS. They are project-level dependencies managed inside project venvs via
# pyproject.toml / requirements.txt — not global CLI tools. Auto-updating them
# here installs redundant global copies that diverge from pinned project versions.
# See: https://github.com/marcusquinn/aidevops/issues/6763

_tool_package_supported_on_platform() {
	local package="$1"
	local platform="${2:-}"
	if [[ -z "$platform" ]]; then
		platform=$(uname -s 2>/dev/null || printf '%s' "unknown")
	fi
	if [[ "$package" == "@steipete/macos-automator-mcp" && "$platform" != "Darwin" ]]; then
		return 1
	fi
	return 0
}

# Tools installed via curl/custom installers (not in brew/npm/pip registries)
# Latest version cannot be checked via registry — use "self" category
# which skips latest-version lookup and just reports installed version
CUSTOM_TOOLS=(
	"self|Cursor CLI|agent|--version|cursor-agent|agent update"
	"self|Droid CLI|droid|--version|droid|curl -fsSL https://app.factory.ai/install.sh | bash"
)

# Counters
OUTDATED_COUNT=0
INSTALLED_COUNT=0
NOT_INSTALLED_COUNT=0
TIMEOUT_COUNT=0
UNKNOWN_COUNT=0
SUDO_SKIP_COUNT=0
declare -a OUTDATED_PACKAGES=()
declare -a JSON_RESULTS=()

# Timeout for local --version calls (seconds).
# A well-behaved --version should return in <1s. 10s is generous enough for
# slow interpreters (Python, Ruby) while still catching hung MCP servers.
readonly VERSION_TIMEOUT=10

# Get installed version from pipx isolated environments.
# pipx installs each package in its own venv — pip show cannot see them.
get_pipx_installed_version() {
	local pkg="$1"
	local version=""
	if command -v pipx &>/dev/null; then
		version=$(pipx list --short 2>/dev/null | grep -i "^${pkg}" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
	fi
	if [[ -n "$version" ]]; then
		echo "$version"
		return 0
	fi
	echo "not installed"
	return 0
}

# Get installed version from uv tool isolated environments.
# uv tool installs each package in its own managed venv — pip show cannot see them.
get_uv_installed_version() {
	local pkg="$1"
	local version=""
	if command -v uv &>/dev/null; then
		version=$(uv tool list 2>/dev/null | grep -i "^${pkg}" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
	fi
	if [[ -n "$version" ]]; then
		echo "$version"
		return 0
	fi
	echo "not installed"
	return 0
}

# Get installed version for Python packages across all install methods.
# Tries pip show first (standard pip installs), then pipx (isolated tools like
# analytics-mcp), then uv tool (isolated tools like outscraper-mcp-server).
# pip-only libraries (e.g. crawl4ai, dspy) have no CLI binary so command -v
# always fails — this function handles all three installation methods.
get_python_installed_version() {
	local pkg="$1"
	local version

	# 1. Try pip show (standard pip installs and library packages)
	version=$(pip show "$pkg" 2>/dev/null | grep -i '^Version:' | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
	if [[ -n "$version" ]]; then
		echo "$version"
		return 0
	fi

	# 2. Try pipx (packages installed in isolated pipx environments)
	version=$(get_pipx_installed_version "$pkg")
	if [[ "$version" != "not installed" ]]; then
		echo "$version"
		return 0
	fi

	# 3. Try uv tool (packages installed via uv tool install)
	version=$(get_uv_installed_version "$pkg")
	if [[ "$version" != "not installed" ]]; then
		echo "$version"
		return 0
	fi

	echo "not installed"
	return 0
}

# Get installed version from npm global package.json
# Fallback for tools where --version starts a server instead of printing a version
get_npm_pkg_version() {
	local pkg="$1"
	local npm_root
	npm_root="$(npm root -g 2>/dev/null)" || return 1
	[[ -n "$npm_root" ]] || return 1
	local pkg_json="${npm_root}/${pkg}/package.json"
	if [[ -f "$pkg_json" ]]; then
		grep -oE '"version"\s*:\s*"[0-9]+\.[0-9]+\.[0-9]+"' "$pkg_json" |
			grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
		return 0
	fi
	return 1
}

# Get installed version
get_installed_version() {
	local cmd="$1"
	local ver_flag="$2"
	local pkg="${3:-}"

	if command -v "$cmd" &>/dev/null; then
		local version
		# Timeout version checks — some tools (MCP servers) start a blocking
		# server process when given --version instead of printing a version.
		# Without a timeout, the subshell hangs forever.
		# NOTE: Do NOT pipe timeout_sec to head/grep — on macOS the background
		# process fallback may not close the pipe write end on kill, causing
		# head to block forever. Use a temp file instead.
		local _ver_log
		if ! _ver_log=$(mktemp "${TMPDIR:-/tmp}/tool-ver.XXXXXX"); then
			echo "unknown"
			return 0
		fi
		local _ver_rc=0
		# shellcheck disable=SC2086
		timeout_sec "$VERSION_TIMEOUT" "$cmd" $ver_flag >"$_ver_log" 2>/dev/null || _ver_rc=$?

		if [[ "$_ver_rc" -eq 124 ]]; then
			# timeout_sec killed the process — command hung (MCP server started)
			rm -f "$_ver_log"
			# Fallback: read version from npm package.json
			if [[ -n "$pkg" ]]; then
				version=$(get_npm_pkg_version "$pkg")
				if [[ -n "$version" ]]; then
					echo "$version"
					return 0
				fi
			fi
			echo "timeout"
			return 0
		fi

		local ver_output
		ver_output=$(head -1 "$_ver_log")
		rm -f "$_ver_log"
		version=$(echo "$ver_output" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
		if [[ -z "$version" ]]; then
			version=$(echo "$ver_output" | grep -oE '[0-9]+\.[0-9]+' | head -1)
		fi

		# If --version produced no parseable version, try npm package.json fallback
		if [[ -z "$version" ]] && [[ -n "$pkg" ]]; then
			local pkg_version
			pkg_version=$(get_npm_pkg_version "$pkg")
			if [[ -n "$pkg_version" ]]; then
				echo "$pkg_version"
				return 0
			fi
		fi

		echo "${version:-unknown}"
	else
		echo "not installed"
	fi
	return 0
}

# timeout_sec() is now provided by shared-constants.sh (sourced above).
# Moved there in t1504 so all scripts get portable timeout support.

# Timeout for external package manager queries (seconds)
readonly PKG_QUERY_TIMEOUT=30

get_public_release_tag() {
	local repo="$1"
	local tag=""
	tag=$(timeout_sec "$PKG_QUERY_TIMEOUT" curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null |
		grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v?[^"]+"' |
		head -1 |
		sed -E 's/.*"v?([^"]+)"/\1/' || true)
	echo "$tag"
	return 0
}

# Get latest npm version
get_npm_latest() {
	local pkg="$1"
	# Use timeout to prevent hanging on npm view
	timeout_sec "$PKG_QUERY_TIMEOUT" npm view "$pkg" version 2>/dev/null || echo "unknown"
	return 0
}

# Get latest brew version.
# When brew is available, use `brew info` (works on macOS and Linux with brew).
# When brew is absent (common on Linux), fall back to the GitHub Releases API
# for tools with known repos. This keeps version detection cross-platform even
# when the update path uses apt/dnf instead of brew.
get_brew_latest() {
	local pkg="$1"
	local brew_bin=""
	brew_bin=$(command -v brew 2>/dev/null || true)
	if [[ -n "$brew_bin" && -x "$brew_bin" ]]; then
		timeout_sec "$PKG_QUERY_TIMEOUT" "$brew_bin" info "$pkg" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown"
	else
		# No brew — fall back to GitHub Releases API for known tools.
		# Strip tap prefix (e.g. "max-sixty/worktrunk/wt" → "wt") for matching.
		local base_pkg="${pkg##*/}"
		case "$base_pkg" in
		gh) get_public_release_tag "cli/cli" ;;
		glab) get_public_release_tag "gitlab-org/cli" ;;
		wt) get_public_release_tag "max-sixty/worktrunk" ;;
		jq) get_public_release_tag "jqlang/jq" ;;
		ripgrep) get_public_release_tag "BurntSushi/ripgrep" ;;
		shellcheck) get_public_release_tag "koalaman/shellcheck" ;;
		*) echo "unknown" ;;
		esac
	fi
	return 0
}

# Get latest pip version
get_pip_latest() {
	local pkg="$1"
	timeout_sec "$PKG_QUERY_TIMEOUT" pip index versions "$pkg" 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown"
	return 0
}

# Compare versions (returns 0 if v1 < v2)
version_lt() {
	local v1="$1"
	local v2="$2"

	if [[ "$v1" == "$v2" ]]; then
		return 1
	fi

	# Use sort -V for version comparison
	local lowest
	lowest=$(printf '%s\n%s' "$v1" "$v2" | sort -V | head -1)
	[[ "$lowest" == "$v1" ]]
}

# Detect the installed version for a tool specification.
_tool_installed_version() {
	local category="$1"
	local cmd="$2"
	local ver_flag="$3"
	local pkg="$4"

	case "$category" in
	pip)
		get_python_installed_version "$pkg"
		;;
	npm)
		get_installed_version "$cmd" "$ver_flag" "$pkg"
		;;
	*)
		get_installed_version "$cmd" "$ver_flag"
		;;
	esac
	return 0
}

# Detect the latest available version for a tool category.
_tool_latest_version() {
	local category="$1"
	local pkg="$2"
	local installed="$3"

	case "$category" in
	npm) get_npm_latest "$pkg" ;;
	brew) get_brew_latest "$pkg" ;;
	pip) get_pip_latest "$pkg" ;;
	self) printf '%s\n' "$installed" ;; # Self-updating tools — no registry to check
	*) printf '%s\n' "unknown" ;;
	esac
	return 0
}

# Classify a detected tool and update aggregate counters.
_classify_tool_status() {
	local cmd="$1"
	local installed="$2"
	local latest_val="$3"
	local update_cmd="$4"
	local status_ref="$5"
	local icon_ref="$6"
	local color_ref="$7"
	local latest_ref="$8"

	local class_status="up_to_date"
	local class_icon="✓"
	local class_color="$GREEN"
	local effective_latest="$latest_val"

	if [[ "$cmd" == "gh" && "$installed" != "not installed" ]] && ! aidevops_gh_slurp_supported; then
		class_status="minimum_required"
		class_icon="!"
		class_color="$RED"
		effective_latest=">=${AIDEVOPS_GH_MIN_SLURP_VERSION}"
		((++OUTDATED_COUNT))
		OUTDATED_PACKAGES+=("$update_cmd")
	elif [[ "$installed" == "not installed" ]]; then
		class_status="not_installed"
		class_icon="○"
		class_color="$YELLOW"
		((++NOT_INSTALLED_COUNT))
	elif [[ "$installed" == "timeout" ]]; then
		class_status="timeout"
		class_icon="⏱"
		class_color="$RED"
		((++TIMEOUT_COUNT))
	elif [[ "$installed" == "unknown" || "$latest_val" == "unknown" ]]; then
		class_status="unknown"
		class_icon="?"
		class_color="$YELLOW"
		((++UNKNOWN_COUNT))
	elif [[ "$installed" != "$latest_val" ]] && version_lt "$installed" "$latest_val"; then
		class_status="outdated"
		class_icon="⬆"
		class_color="$RED"
		((++OUTDATED_COUNT))
		OUTDATED_PACKAGES+=("$update_cmd")
	else
		((++INSTALLED_COUNT))
	fi

	printf -v "$status_ref" '%s' "$class_status"
	printf -v "$icon_ref" '%s' "$class_icon"
	printf -v "$color_ref" '%s' "$class_color"
	printf -v "$latest_ref" '%s' "$effective_latest"
	return 0
}

# Append a JSON result for a checked tool.
_append_tool_json_result() {
	local category="$1"
	local name="$2"
	local installed="$3"
	local latest="$4"
	local status="$5"
	local update_cmd="$6"

	local json_name="${name//\\/\\\\}"
	json_name="${json_name//\"/\\\"}"
	local json_update="${update_cmd//\\/\\\\}"
	json_update="${json_update//\"/\\\"}"
	JSON_RESULTS+=("{\"name\": \"$json_name\", \"category\": \"$category\", \"installed\": \"$installed\", \"latest\": \"$latest\", \"status\": \"$status\", \"update_cmd\": \"$json_update\"}")
	return 0
}

# Print console output for a checked tool.
_print_tool_status() {
	local name="$1"
	local installed="$2"
	local latest="$3"
	local status="$4"
	local icon="$5"
	local color="$6"

	if [[ "$QUIET" == "true" && "$status" != "outdated" && "$status" != "timeout" ]]; then
		return 0
	fi

	case "$status" in
	not_installed)
		echo -e "${color}${icon}  $name: not installed${NC}"
		if [[ "$QUIET" != "true" ]]; then
			echo "   Latest: $latest"
		fi
		;;
	outdated)
		echo -e "${color}${icon}  $name: $installed → $latest (UPDATE AVAILABLE)${NC}"
		;;
	timeout)
		echo -e "${color}${icon}  $name: --version hung (killed after ${VERSION_TIMEOUT}s)${NC}"
		;;
	unknown)
		echo -e "${color}${icon}  $name: $installed (could not check latest)${NC}"
		;;
	minimum_required)
		echo -e "${color}${icon}  $name: $installed (requires >= ${AIDEVOPS_GH_MIN_SLURP_VERSION} for gh api --paginate --slurp)${NC}"
		;;
	up_to_date)
		echo -e "${color}${icon}  $name: $installed${NC}"
		;;
	*)
		echo -e "${color}${icon}  $name: $installed (status: $status)${NC}"
		;;
	esac
	return 0
}

# Check a single tool
check_tool() {
	local category="$1"
	local name="$2"
	local cmd="$3"
	local ver_flag="$4"
	local pkg="$5"
	local update_cmd="$6"

	local installed
	# pip tools: detect across pip/pipx/uv — pip-only libraries (e.g.
	# crawl4ai, dspy) have no CLI binary so command -v always fails.
	# npm tools: pass package name so fallback to package.json works.
	# All other categories: standard CLI binary detection.
	installed=$(_tool_installed_version "$category" "$cmd" "$ver_flag" "$pkg")

	local latest="unknown"
	latest=$(_tool_latest_version "$category" "$pkg" "$installed")

	local status="up_to_date"
	local icon="✓"
	local color="$GREEN"
	_classify_tool_status "$cmd" "$installed" "$latest" "$update_cmd" status icon color latest

	# JSON output (escape special characters for valid JSON)
	if [[ "$JSON_OUTPUT" == "true" ]]; then
		_append_tool_json_result "$category" "$name" "$installed" "$latest" "$status" "$update_cmd"
	else
		_print_tool_status "$name" "$installed" "$latest" "$status" "$icon" "$color"
	fi
	return 0
}

# Check tools by category
check_category() {
	local cat_name="$1"
	shift
	local tools=("$@")

	if [[ "$JSON_OUTPUT" != "true" && "$QUIET" != "true" ]]; then
		echo ""
		echo -e "${BOLD}${CYAN}=== $cat_name Tools ===${NC}"
	fi

	local category name cmd ver_flag pkg update_cmd
	for tool_spec in "${tools[@]}"; do
		IFS='|' read -r category name cmd ver_flag pkg update_cmd <<<"$tool_spec"
		_tool_package_supported_on_platform "$pkg" || continue
		check_tool "$category" "$name" "$cmd" "$ver_flag" "$pkg" "$update_cmd"
	done
	return 0
}

# Dispatch category checks based on CATEGORY variable
_check_all_categories() {
	case "$CATEGORY" in
	npm)
		check_category "NPM" "${NPM_TOOLS[@]}"
		;;
	brew)
		check_category "Homebrew" "${BREW_TOOLS[@]}"
		;;
	pip)
		check_category "Python/Pip" "${PIP_TOOLS[@]}"
		;;
	custom)
		check_category "Custom/Self-Updating" "${CUSTOM_TOOLS[@]}"
		;;
	all | *)
		if [[ ${#NPM_TOOLS[@]} -gt 0 ]]; then
			check_category "NPM" "${NPM_TOOLS[@]}"
		fi
		if [[ ${#BREW_TOOLS[@]} -gt 0 ]]; then
			check_category "Homebrew" "${BREW_TOOLS[@]}"
		fi
		if command -v pip &>/dev/null && [[ ${#PIP_TOOLS[@]} -gt 0 ]]; then
			check_category "Python/Pip" "${PIP_TOOLS[@]}"
		fi
		if [[ ${#CUSTOM_TOOLS[@]} -gt 0 ]]; then
			check_category "Custom/Self-Updating" "${CUSTOM_TOOLS[@]}"
		fi
		;;
	esac
	return 0
}

# Emit JSON output for all results and return
_output_json_results() {
	echo "{"
	echo "  \"summary\": {"
	echo "    \"installed\": $INSTALLED_COUNT,"
	echo "    \"outdated\": $OUTDATED_COUNT,"
	echo "    \"not_installed\": $NOT_INSTALLED_COUNT,"
	echo "    \"timeout\": $TIMEOUT_COUNT,"
	echo "    \"unknown\": $UNKNOWN_COUNT"
	echo "  },"
	echo "  \"tools\": ["
	local first=true
	for result in "${JSON_RESULTS[@]}"; do
		if [[ "$first" == "true" ]]; then
			first=false
		else
			echo ","
		fi
		echo -n "    $result"
	done
	echo ""
	echo "  ]"
	echo "}"
	return 0
}

# Print summary counts and handle auto-update or update instructions
_output_summary_and_updates() {
	# Summary (skip in quiet mode if nothing outdated)
	if [[ "$QUIET" == "true" && $OUTDATED_COUNT -eq 0 ]]; then
		return 0
	fi

	if [[ "$QUIET" != "true" ]]; then
		echo ""
		echo -e "${BOLD}Summary${NC}"
		echo "  Installed & up to date: $INSTALLED_COUNT"
		echo "  Outdated: $OUTDATED_COUNT"
		echo "  Not installed: $NOT_INSTALLED_COUNT"
		if [[ $TIMEOUT_COUNT -gt 0 ]]; then
			echo "  Timeout (version check hung): $TIMEOUT_COUNT"
		fi
		if [[ $UNKNOWN_COUNT -gt 0 ]]; then
			echo "  Unknown (could not verify): $UNKNOWN_COUNT"
		fi
		echo ""
	fi

	if [[ $OUTDATED_COUNT -gt 0 ]]; then
		if [[ "$AUTO_UPDATE" == "true" ]]; then
			echo -e "${BLUE}Updating outdated tools...${NC}"
			echo ""
		for update_cmd in "${OUTDATED_PACKAGES[@]}"; do
			echo "  Running: $update_cmd"
			# Sudo safety gate (GH#21734): commands routed through apt-get/dnf/yum
			# require sudo. Probe for passwordless sudo first; if not available,
			# skip and print the manual command instead of hanging on an
			# interactive password prompt during unattended `aidevops update`.
			if [[ "$update_cmd" == *" sudo "* ]]; then
				if ! sudo -n true 2>/dev/null; then
					local _manual_cmd
					_manual_cmd=""
					if command -v apt-get >/dev/null 2>&1; then
						_manual_cmd=$(grep -oE 'sudo apt-get[^;]+' <<<"$update_cmd" | head -1)
					elif command -v dnf >/dev/null 2>&1; then
						_manual_cmd=$(grep -oE 'sudo dnf[^;]+' <<<"$update_cmd" | head -1)
					elif command -v yum >/dev/null 2>&1; then
						_manual_cmd=$(grep -oE 'sudo yum[^;]+' <<<"$update_cmd" | head -1)
					fi
					echo -e "  ${YELLOW}⊘ Skipped: requires sudo. Run manually:${NC}"
					if [[ -n "$_manual_cmd" ]]; then
						echo "    ${_manual_cmd}"
					else
						echo "    $update_cmd"
					fi
					((++SUDO_SKIP_COUNT))
					echo ""
					continue
				fi
			fi
			# Run update command directly (not via eval for security)
			# Commands are hardcoded in tool definitions, not user input
			# Timeout prevents hangs on slow registries/network issues
			# Use timeout_sec for macOS compatibility (no native timeout)
			# NOTE: Do NOT pipe timeout_sec output to tail/head — on macOS the
			# perl alarm fallback doesn't close the pipe's write end on SIGALRM,
			# causing tail to block forever. Use a temp file instead.
			local _update_log
			if ! _update_log=$(mktemp "${TMPDIR:-/tmp}/tool-update.XXXXXX"); then
				echo -e "  ${RED}✗ Failed to create temp log${NC}"
				continue
			fi
			if timeout_sec 120 bash -c "$update_cmd" >"$_update_log" 2>&1; then
				tail -2 "$_update_log"
				echo -e "  ${GREEN}✓ Updated${NC}"
			else
				tail -2 "$_update_log"
				echo -e "  ${RED}✗ Failed${NC}"
			fi
			rm -f "$_update_log"
			echo ""
		done
		if [[ $SUDO_SKIP_COUNT -gt 0 ]]; then
			echo -e "${GREEN}Updates complete (${SUDO_SKIP_COUNT} skipped — manual sudo required).${NC}"
		else
			echo -e "${GREEN}Updates complete. Re-run to verify.${NC}"
		fi
		else
			echo "To update all outdated tools, run:"
			echo "  tool-version-check.sh --update"
			echo ""
			echo "Or update individually:"
			for update_cmd in "${OUTDATED_PACKAGES[@]}"; do
				echo "  $update_cmd"
			done
		fi
	else
		echo -e "${GREEN}All installed tools are up to date!${NC}"
	fi
	return 0
}

# Main
main() {
	if [[ "$JSON_OUTPUT" != "true" && "$QUIET" != "true" ]]; then
		echo -e "${BOLD}${BLUE}Tool Version Check${NC}"
		echo "=================="
	fi

	_check_all_categories

	if [[ "$JSON_OUTPUT" == "true" ]]; then
		_output_json_results
		return 0
	fi

	_output_summary_and_updates
}

main
exit $?
