#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Shell safety baseline
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true

if [[ -z "${HOME:-}" ]]; then
	printf '%s\n' '[ERROR] HOME environment variable is unset or empty. setup.sh requires a valid HOME directory.' >&2
	exit 1
fi

# AI Assistant Server Access Framework Setup Script
# Helps developers set up the framework for their infrastructure
#
# Version: 3.32.320
#
# Quick Install:
#   npm install -g aidevops && aidevops update          (recommended)
#   brew install marcusquinn/tap/aidevops && aidevops update  (Homebrew)
#   bash <(curl -fsSL https://aidevops.sh/install)                     (manual)

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Global flags
CLEAN_MODE=false
INTERACTIVE_MODE=false
NON_INTERACTIVE="${AIDEVOPS_NON_INTERACTIVE:-false}"
SETUP_EXPLICIT_NON_INTERACTIVE="${AIDEVOPS_NON_INTERACTIVE:-false}"
UPDATE_TOOLS_MODE=false
SETUP_STAGE=""
SETUP_STAGE_OPENCODE="setup_opencode_cli"
SETUP_STAGE_AGENTS="deploy_aidevops_agents"
SETUP_STAGE_HOOKS="setup_safety_hooks"
SETUP_STAGE_TABBY="setup_tabby"
SETUP_STAGE_PULSE="setup_supervisor_pulse"
SETUP_STAGE_GUI_DESKTOP="setup_gui_desktop_app"
SETUP_STAGE_AI_SESSION="setup_ai_session_incremental"
SETUP_STAGE_RUNTIME_CONFIG="reconcile_runtime_config"
SETUP_STAGE_SOURCE_ACCESS="setup_source_access_broker"
SETUP_STAGE_OPENCODE_PLUGINS="setup_opencode_plugins"
SETUP_STAGE_HOTFIX_CONFIG="_deploy_hotfix_config"
SETUP_GUI_APP_NAME="aidevops.app"
SETUP_OS_DARWIN="Darwin"
# Python compatibility floor used by setup checks and skill/tool gating.
# Keep in sync with .agents/scripts/setup/modules/plugins.sh requirements.
PYTHON_REQUIRED_MAJOR=3
PYTHON_REQUIRED_MINOR=10
export PYTHON_REQUIRED_MAJOR PYTHON_REQUIRED_MINOR
# Platform constants — exported for sourced .agents/scripts/setup/modules (shell-env.sh,
# tool-install.sh) that reference them at runtime.
PLATFORM_MACOS=$([[ "$(uname -s)" == "$SETUP_OS_DARWIN" ]] && echo true || echo false)
PLATFORM_ARM64=$([[ "$(uname -m)" == "arm64" || "$(uname -m)" == "aarch64" ]] && echo true || echo false)
export PLATFORM_MACOS PLATFORM_ARM64
readonly PLATFORM_MACOS PLATFORM_ARM64
# Extended platform detection (t1748: Linux/WSL2 support).
# Sources platform-detect.sh when available to export AIDEVOPS_PLATFORM,
# AIDEVOPS_SCHEDULER, AIDEVOPS_CLIPBOARD_COPY, etc.
_platform_detect_script="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.agents/scripts/platform-detect.sh"
if [[ -f "$_platform_detect_script" ]]; then
	# shellcheck disable=SC1090  # dynamic path, exists at runtime
	source "$_platform_detect_script"
fi
unset _platform_detect_script
# Repo constants — exported; consumed by .agents/scripts/setup/modules/core.sh, agent-deploy.sh
REPO_URL="https://github.com/marcusquinn/aidevops.git"
# INSTALL_DIR: resolve from the directory where setup.sh is executed (supports worktrees)
# For bootstrap (curl install), this will be /dev/fd/NN and trigger re-exec after clone
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-$HOME/.aidevops/agents}"
export REPO_URL INSTALL_DIR AGENTS_DIR

# Source modular setup functions (t316.2)
# These modules are sourced only when setup.sh is run from the repo directory
# (not during bootstrap from curl, which re-execs after cloning)
SETUP_MODULES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.agents/scripts/setup" 2>/dev/null && pwd)" || true
if [[ -d "$SETUP_MODULES_DIR" ]]; then
	# shellcheck disable=SC1091  # Dynamic path via $SETUP_MODULES_DIR; files exist at runtime
	source "$SETUP_MODULES_DIR/_common.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_validation.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_migration.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_shell.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_installation.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_deployment.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_opencode.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_tools.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_services.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_bootstrap.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_routines.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_scheduler_runtime.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_runtime_helpers.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_privacy_guard.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_complexity_guard.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_repo_verify_guard.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_task_id_guard.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_canonical_guard.sh"
	# shellcheck disable=SC1091
	source "$SETUP_MODULES_DIR/_worktree_exclusions.sh"
fi

print_info() {
	local _m="$1"
	echo -e "${BLUE}[INFO]${NC} $_m"
	return 0
}
print_success() {
	local _m="$1"
	echo -e "${GREEN}[SUCCESS]${NC} $_m"
	return 0
}
print_warning() {
	local _m="$1"
	echo -e "${YELLOW}[WARNING]${NC} $_m"
	return 0
}
print_error() {
	local _m="$1"
	echo -e "${RED}[ERROR]${NC} $_m"
	return 0
}

# Source shared-constants for config support (is_feature_enabled / config_enabled)
# Try repo-local first, then deployed location
_SHARED_CONSTANTS="${BASH_SOURCE[0]%/*}/.agents/scripts/shared-constants.sh"
if [[ ! -f "$_SHARED_CONSTANTS" ]]; then
	_SHARED_CONSTANTS="$HOME/.aidevops/agents/scripts/shared-constants.sh"
fi
if [[ -f "$_SHARED_CONSTANTS" ]]; then
	# shellcheck disable=SC1090  # Dynamic path resolved at runtime
	source "$_SHARED_CONSTANTS"
fi
unset _SHARED_CONSTANTS

# Secure the optional DSPy disk cache before setup installs or imports DSPy.
_DSPY_CACHE_SECURITY="${INSTALL_DIR}/.agents/scripts/dspy-cache-security.sh"
if [[ ! -f "$_DSPY_CACHE_SECURITY" ]]; then
	_DSPY_CACHE_SECURITY="$HOME/.aidevops/agents/scripts/dspy-cache-security.sh"
fi
if [[ -f "$_DSPY_CACHE_SECURITY" ]]; then
	# shellcheck disable=SC1090  # Dynamic path resolved at runtime
	source "$_DSPY_CACHE_SECURITY"
fi
unset _DSPY_CACHE_SECURITY

# Escape a string for safe embedding in XML (plist heredocs).
# Prevents XML injection if paths contain &, <, >, ", or ' characters.
_xml_escape() {
	local str="$1"
	# Escape replacement ampersands so Bash 5.2+ with patsub_replacement
	# enabled does not turn "&apos;" into "'apos;" in generated plists.
	str="${str//&/\&amp;}"
	str="${str//</\&lt;}"
	str="${str//>/\&gt;}"
	str="${str//\"/\&quot;}"
	str="${str//\'/\&apos;}"
	printf '%s' "$str"
	return 0
}

# Escape a string for safe embedding in crontab entries.
# Wraps value in single quotes (prevents $(…), backtick, and variable expansion
# by cron's /bin/sh). Embedded single quotes are escaped via the '\'' idiom.
_cron_escape() {
	local str="$1"
	str="${str//$'\n'/ }"
	str="${str//$'\r'/ }"
	# Replace each ' with '\'' (end quote, escaped quote, start quote)
	str="${str//\'/\'\\\'\'}"
	printf "'%s'" "$str"
	return 0
}

# GH#21060 / t2911: Per-stage timing helper for non-interactive setup runs.
# Wraps a function call, records start/end time, and appends TSV lines to
# $HOME/.aidevops/logs/setup-stage-timings.log:
#   iso8601_utc <TAB> stage_name <TAB> duration_seconds <TAB> exit_code
# A RUNNING row is written before each stage starts so a tool/worker timeout
# still leaves the currently executing phase in the timing log.
# Usage: _time_step "stage_name" function_name [args...]
# ShellCheck: $@ is used deliberately (SC2068 not applicable; no word-splitting
# issue since we shift the stage-name arg first and pass the rest as a command).
_time_step_log() {
	local _ts_stage="$1"
	local _ts_duration="$2"
	local _ts_exit="$3"
	printf '%s\t%s\t%s\t%s\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"$_ts_stage" \
		"$_ts_duration" \
		"$_ts_exit" \
		>>"$HOME/.aidevops/logs/setup-stage-timings.log" 2>/dev/null || true
	return 0
}

_time_step() {
	local _ts_stage="$1"
	shift
	local _ts_start _ts_end _ts_duration _ts_exit
	print_info "Starting setup stage: $_ts_stage"
	_time_step_log "$_ts_stage" "0.00" "RUNNING"
	_ts_start=$(date +%s.%N 2>/dev/null || date +%s)
	_ts_exit=0
	"$@" || _ts_exit=$?
	_ts_end=$(date +%s.%N 2>/dev/null || date +%s)
	_ts_duration=$(awk -v a="$_ts_start" -v b="$_ts_end" 'BEGIN { printf "%.2f", b - a }')
	_time_step_log "$_ts_stage" "$_ts_duration" "$_ts_exit"
	print_info "Finished setup stage: $_ts_stage (${_ts_duration}s, exit=${_ts_exit})"
	return "$_ts_exit"
}

# Resolve the canonical main worktree path for the current repo.
# When setup.sh is run from a linked worktree, launchd/cron should still point
# autonomous services at the main repo checkout, not the feature worktree.
_resolve_main_worktree_dir() {
	local repo_dir="$1"
	local main_worktree=""
	main_worktree=$(git -C "$repo_dir" worktree list --porcelain 2>/dev/null | awk '/^worktree / {print substr($0, 10); exit}') || main_worktree=""
	if [[ -n "$main_worktree" && -d "$main_worktree" ]]; then
		printf '%s' "$main_worktree"
		return 0
	fi
	printf '%s' "$repo_dir"
	return 0
}

# Scheduler runtime helpers are sourced from .agents/scripts/setup/_scheduler_runtime.sh
# with the rest of the setup modules near the top of this file.

# Runtime helper functions are sourced from .agents/scripts/setup/_runtime_helpers.sh
# with the rest of the setup modules near the top of this file.

# Validate namespace string for safe use in paths and shell commands
# Returns 0 if valid, 1 if invalid
# Valid: alphanumeric, dash, underscore, forward slash (no .., no shell metacharacters)
validate_namespace() {
	local ns="$1"
	# Reject empty
	[[ -z "$ns" ]] && return 1
	# Reject path traversal
	[[ "$ns" == *".."* ]] && return 1
	# Reject shell metacharacters and dangerous characters
	[[ "$ns" =~ [^a-zA-Z0-9/_-] ]] && return 1
	# Reject absolute paths
	[[ "$ns" == /* ]] && return 1
	# Reject trailing slash (causes issues with rsync/tar exclusions)
	[[ "$ns" == */ ]] && return 1
	return 0
}

# =============================================================================
# Bootstrap guard: detect curl/process-substitution execution
# When running via `bash <(curl ...)`, BASH_SOURCE[0] is /dev/fd/NN and the
# .agents/scripts/setup/modules/ directory doesn't exist at that path. We must clone the repo
# first, then re-exec the local copy. This MUST run before any source lines.
# =============================================================================
_setup_script_dir="$(dirname "${BASH_SOURCE[0]}")"
if [[ ! -d "$_setup_script_dir/.agents/scripts/setup/modules" ]]; then
	# Running from curl pipe or process substitution — bootstrap the repo
	print_info "Remote install detected — bootstrapping repository..."

	# Auto-install git if missing
	if ! command -v git >/dev/null 2>&1; then
		if [[ "$(uname)" == "$SETUP_OS_DARWIN" ]]; then
			print_info "Installing Xcode Command Line Tools (includes git)..."
			xcode-select --install 2>/dev/null || true
			xcode_wait=0
			while ! command -v git >/dev/null 2>&1 && [[ $xcode_wait -lt 300 ]]; do
				sleep 5
				xcode_wait=$((xcode_wait + 5))
			done
			if ! command -v git >/dev/null 2>&1; then
				print_error "git not available after Xcode CLT install. Re-run after installation completes."
				exit 1
			fi
		elif command -v apt-get >/dev/null 2>&1; then
			sudo apt-get update -qq && sudo apt-get install -y -qq git
		elif command -v dnf >/dev/null 2>&1; then
			sudo dnf install -y git
		elif command -v yum >/dev/null 2>&1; then
			sudo yum install -y git
		elif command -v pacman >/dev/null 2>&1; then
			sudo pacman -S --noconfirm git
		elif command -v apk >/dev/null 2>&1; then
			sudo apk add git
		else
			print_error "git is required but not installed and no supported package manager found"
			exit 1
		fi
	fi

	# Clone or update the repo (use hardcoded path for bootstrap)
	# After clone, INSTALL_DIR will be set correctly by the re-exec
	_bootstrap_install_dir="$HOME/Git/aidevops"
	mkdir -p "$(dirname "$_bootstrap_install_dir")"
	if [[ -d "$_bootstrap_install_dir/.git" ]]; then
		print_info "Existing installation found — updating..."
		cd "$_bootstrap_install_dir" || exit 1
		git pull --ff-only || {
			print_warning "Git pull failed — resetting to origin/main"
			git fetch origin
			git reset --hard origin/main
		}
	else
		if [[ -d "$_bootstrap_install_dir" ]]; then
			print_warning "Directory exists but is not a git repo — backing up"
			mv "$_bootstrap_install_dir" "$_bootstrap_install_dir.backup.$(date +%Y%m%d_%H%M%S)"
		fi
		print_info "Cloning aidevops to $_bootstrap_install_dir..."
		git clone "$REPO_URL" "$_bootstrap_install_dir" || {
			print_error "Failed to clone repository"
			exit 1
		}
	fi

	print_success "Repository ready at $_bootstrap_install_dir"

	# Re-execute the local copy (which has .agents/scripts/setup/modules/ available)
	cd "$_bootstrap_install_dir" || exit 1
	exec bash "./setup.sh" "$@"
fi
unset _setup_script_dir

# Source modularized setup functions from the canonical setup module tree.
# The sibling .agents/scripts/setup/_*.sh files above are bootstrap/fallback
# helpers loaded early by the root entrypoint; normal setup implementation
# modules live under modules/ so the repository root has no module directory.
SETUP_IMPL_MODULES_DIR="${SETUP_MODULES_DIR}/modules"
# shellcheck source=.agents/scripts/runtime-bundle-verifier.sh
source "${INSTALL_DIR}/.agents/scripts/runtime-bundle-verifier.sh"
# shellcheck source=.agents/scripts/pulse-runtime-pin.sh
source "${INSTALL_DIR}/.agents/scripts/pulse-runtime-pin.sh"
# shellcheck disable=SC1091  # Dynamic path via $SETUP_IMPL_MODULES_DIR
source "${SETUP_IMPL_MODULES_DIR}/core.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/migrations.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/shell-env.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/tool-install.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/mcp-setup.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/agent-deploy.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/agent-runtime.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/tool-beads.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/config.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/source-access.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/plugins.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/schedulers.sh"
# shellcheck disable=SC1091
source "${SETUP_IMPL_MODULES_DIR}/post-setup.sh"

parse_args() {
	while [[ $# -gt 0 ]]; do
		local _opt="$1"
		case "$_opt" in
		--clean)
			CLEAN_MODE=true
			shift
			;;
		--interactive | -i)
			INTERACTIVE_MODE=true
			shift
			;;
		--non-interactive | -n)
			NON_INTERACTIVE=true
			SETUP_EXPLICIT_NON_INTERACTIVE=true
			shift
			;;
		--update | -u)
			UPDATE_TOOLS_MODE=true
			shift
			;;
		--stage)
			if [[ -z "${2:-}" ]]; then
				print_error "--stage requires a value"
				_setup_print_stage_help
				exit 1
			fi
			SETUP_STAGE="$2"
			NON_INTERACTIVE=true
			shift 2
			;;
		--stage=*)
			SETUP_STAGE="${_opt#--stage=}"
			if [[ -z "$SETUP_STAGE" ]]; then
				print_error "--stage requires a value"
				_setup_print_stage_help
				exit 1
			fi
			NON_INTERACTIVE=true
			shift
			;;
		--help | -h)
			echo "Usage: ./setup.sh [OPTIONS]"
			echo ""
			echo "Options:"
			echo "  --clean            Remove stale files before deploying (cleans ~/.aidevops/agents/)"
			echo "  --interactive, -i  Ask confirmation before each step"
			echo "  --non-interactive, -n  Deploy agents only, skip all optional installs (no prompts)"
			echo "  --stage <name>     Run one supported setup stage/scope without full setup"
			echo "  --update, -u       Check for and offer to update outdated tools after setup"
			echo "  --help             Show this help message"
			echo ""
			echo "Default behavior adds/overwrites files without removing deleted agents."
			echo "Use --clean after removing or renaming agents to sync deletions."
			echo "Use --interactive to control each step individually."
			echo "Use --non-interactive for CI/CD or AI agent shells (no stdin required)."
			echo "Use --stage for targeted updates: opencode, agents, runtime-config, source-access, hooks, tabby, pulse, gui-desktop, ai-session, full."
			echo "Stage aliases: ${SETUP_STAGE_OPENCODE}, ${SETUP_STAGE_AGENTS}, ${SETUP_STAGE_RUNTIME_CONFIG}, ${SETUP_STAGE_SOURCE_ACCESS}, ${SETUP_STAGE_HOOKS}, ${SETUP_STAGE_TABBY}, ${SETUP_STAGE_PULSE}, ${SETUP_STAGE_GUI_DESKTOP}, ${SETUP_STAGE_AI_SESSION}."
			echo "The source-access stage may request sudo when attached to an interactive terminal."
			echo "Install ${SETUP_GUI_APP_NAME} explicitly with --stage gui-desktop or AIDEVOPS_GUI_DESKTOP_INSTALL=true."
			echo "Use --update to check for tool updates after setup completes."
			exit 0
			;;
		*)
			print_error "Unknown option: $_opt"
			echo "Use --help for usage information"
			exit 1
			;;
		esac
	done
	if [[ -n "$SETUP_STAGE" ]]; then
		_setup_validate_stage "$SETUP_STAGE" || exit $?
	fi
	return 0
}

_setup_print_stage_help() {
	printf '%s\n' "Supported setup stages/scopes:"
	printf '  opencode | %s          Repair/install OpenCode CLI only\n' "$SETUP_STAGE_OPENCODE"
	printf '  agents   | %s     Deploy .agents scripts/prompts only\n' "$SETUP_STAGE_AGENTS"
	printf '  runtime-config | %s  Reconcile generated runtime commands/configuration\n' "$SETUP_STAGE_RUNTIME_CONFIG"
	printf '  source-access | %s  Install/verify the signed root broker\n' "$SETUP_STAGE_SOURCE_ACCESS"
	printf '  hooks    | %s          Install safety hooks only\n' "$SETUP_STAGE_HOOKS"
	printf '  tabby    | %s                 Sync Tabby profiles only\n' "$SETUP_STAGE_TABBY"
	printf '  pulse    | %s      Install/refresh pulse scheduler only\n' "$SETUP_STAGE_PULSE"
	printf '  gui-desktop | gui | app | %s  Install native macOS %s only\n' "$SETUP_STAGE_GUI_DESKTOP" "$SETUP_GUI_APP_NAME"
	printf '  ai-session | ai | %s  Run changed deploy stages, then full setup on failure\n' "$SETUP_STAGE_AI_SESSION"
	printf '%s\n' "  full                                  Run the default full setup path"
	return 0
}

_setup_canonical_stage() {
	local stage="$1"
	case "$stage" in
	opencode | "$SETUP_STAGE_OPENCODE") printf '%s' "$SETUP_STAGE_OPENCODE" ;;
	agents | "$SETUP_STAGE_AGENTS") printf '%s' "$SETUP_STAGE_AGENTS" ;;
	runtime-config | runtime | "$SETUP_STAGE_RUNTIME_CONFIG") printf '%s' "$SETUP_STAGE_RUNTIME_CONFIG" ;;
	source-access | "$SETUP_STAGE_SOURCE_ACCESS") printf '%s' "$SETUP_STAGE_SOURCE_ACCESS" ;;
	hooks | "$SETUP_STAGE_HOOKS") printf '%s' "$SETUP_STAGE_HOOKS" ;;
	tabby | "$SETUP_STAGE_TABBY") printf '%s' "$SETUP_STAGE_TABBY" ;;
	pulse | "$SETUP_STAGE_PULSE") printf '%s' "$SETUP_STAGE_PULSE" ;;
	gui-desktop | gui | app | "$SETUP_STAGE_GUI_DESKTOP") printf '%s' "$SETUP_STAGE_GUI_DESKTOP" ;;
	ai-session | ai | "$SETUP_STAGE_AI_SESSION") printf '%s' "$SETUP_STAGE_AI_SESSION" ;;
	full) printf '%s' "full" ;;
	*) return 1 ;;
	esac
	return 0
}

_setup_validate_stage() {
	local stage="$1"
	if _setup_canonical_stage "$stage" >/dev/null; then
		return 0
	fi
	print_error "Unknown setup stage/scope: $stage"
	_setup_print_stage_help
	return 1
}

_setup_gui_desktop_install_opted_in() {
	local flag="${AIDEVOPS_GUI_DESKTOP_INSTALL:-false}"
	case "$flag" in
	1 | true | TRUE | yes | YES | on | ON)
		return 0
		;;
	esac
	return 1
}

_setup_gui_desktop_app_dir() {
	printf '%s' "${AIDEVOPS_GUI_DESKTOP_APP_DIR:-/Applications}"
	return 0
}

_setup_gui_desktop_app_exists() {
	local app_dir="$1"
	[[ -d "${app_dir}/${SETUP_GUI_APP_NAME}" ]]
	return $?
}

setup_gui_desktop_app() {
	local installer="${INSTALL_DIR}/packages/gui-desktop/scripts/install-macos-app.sh"
	local app_dir=""
	local os=""
	local rc=0

	os="$(uname -s)"
	if [[ "$os" != "$SETUP_OS_DARWIN" ]]; then
		print_skip "$SETUP_GUI_APP_NAME" "macOS only" "Run this stage from macOS when the desktop app is needed."
		setup_track_skipped "$SETUP_GUI_APP_NAME" "macOS only"
		return 0
	fi

	if [[ ! -f "$installer" ]]; then
		print_warning "${SETUP_GUI_APP_NAME} installer not found at: $installer"
		setup_track_deferred "$SETUP_GUI_APP_NAME" "Update aidevops, then run: aidevops setup --scope gui-desktop"
		return 0
	fi

	app_dir="$(_setup_gui_desktop_app_dir)"
	bash "$installer" --app-dir "$app_dir" || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		setup_track_configured "$SETUP_GUI_APP_NAME"
		return 0
	fi

	print_warning "${SETUP_GUI_APP_NAME} install skipped after installer exit $rc (non-fatal)"
	setup_track_deferred "$SETUP_GUI_APP_NAME" "Install requirements, then run: aidevops setup --scope gui-desktop"
	return 0
}

_setup_offer_gui_desktop_app() {
	local answer=""
	local app_dir=""

	if _setup_gui_desktop_install_opted_in; then
		setup_gui_desktop_app
		return 0
	fi

	app_dir="$(_setup_gui_desktop_app_dir)"
	if [[ "$(uname -s)" == "$SETUP_OS_DARWIN" ]] && _setup_gui_desktop_app_exists "$app_dir"; then
		print_info "Refreshing existing macOS ${SETUP_GUI_APP_NAME} in ${app_dir}"
		setup_gui_desktop_app
		return 0
	fi

	if [[ "$INTERACTIVE_MODE" == "true" ]]; then
		echo ""
		echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
		echo -e "${BLUE}Optional preview:${NC} Install native macOS ${SETUP_GUI_APP_NAME}"
		echo -e "${YELLOW}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
		setup_prompt answer "Install ${SETUP_GUI_APP_NAME} now? [y/N]: " "N"
		case "$answer" in
		y | Y | yes | YES)
			setup_gui_desktop_app
			return 0
			;;
		esac
	fi

	setup_track_skipped "$SETUP_GUI_APP_NAME" "opt-in: run aidevops setup --scope gui-desktop or set AIDEVOPS_GUI_DESKTOP_INSTALL=true"
	return 0
}

# Initialize ~/.config/aidevops/settings.json with documented defaults.
# Idempotent — merges missing keys without overwriting existing values.
init_settings_json() {
	local settings_helper="$HOME/.aidevops/agents/scripts/settings-helper.sh"
	if [[ -x "$settings_helper" ]]; then
		if bash "$settings_helper" init >/dev/null 2>&1; then
			print_info "Settings file initialized: ~/.config/aidevops/settings.json"
		fi
	else
		# Fallback: try from repo directory (first run before deployment)
		local repo_helper
		repo_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.agents/scripts/settings-helper.sh"
		if [[ -x "$repo_helper" ]]; then
			if bash "$repo_helper" init >/dev/null 2>&1; then
				print_info "Settings file initialized: ~/.config/aidevops/settings.json"
			fi
		fi
	fi
	return 0
}

# Print the setup header based on active mode flags.
_setup_print_header() {
	echo "🤖 AI DevOps Framework Setup"
	echo "============================="
	if [[ "$CLEAN_MODE" == "true" ]]; then
		echo "Mode: Clean (removing stale files)"
	fi
	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		echo "Mode: Non-interactive (deploy + migrations only, no prompts)"
	elif [[ "$INTERACTIVE_MODE" == "true" ]]; then
		echo "Mode: Interactive (confirm each step)"
		echo ""
		echo "Controls: [Y]es (default) / [n]o skip / [q]uit"
	fi
	if [[ "$UPDATE_TOOLS_MODE" == "true" ]]; then
		echo "Mode: Update (will check for tool updates after setup)"
	fi
	echo ""
	return 0
}

# GH#18950 (t2087) + GH#18965 (t2094): ensure modern bash is installed
# and up to date on macOS. Runs after platform detection, before deploy.
# Uses the canonical `ensure` subcommand which combines install + upgrade:
#   - Missing → interactive prompt for install (or silent with --yes)
#   - Installed but drifted → silent upgrade (brew upgrade bash)
#   - Current → no-op
# Rate-limits `brew update` to 24h internally. Always fail-open — never
# blocks setup on a bash upgrade failure.
#
# Opt-out: AIDEVOPS_AUTO_UPGRADE_BASH=0 disables install + upgrade entirely.
_setup_check_bash_upgrade() {
	# Only applies to macOS; Linux bash is already modern on any current distro.
	if [[ "${AIDEVOPS_PLATFORM:-}" != "macos" ]]; then
		return 0
	fi

	local helper="${INSTALL_DIR}/.agents/scripts/bash-upgrade-helper.sh"
	[[ -x "$helper" ]] || return 0

	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		# Non-interactive: ensure does everything silently (install with
		# --yes, upgrade on drift, no-op when current). Same pattern as
		# `aidevops update` — fire-and-forget.
		"$helper" ensure --yes --quiet || print_warning "bash ensure failed (non-fatal) — advisory written"
		return 0
	fi

	# Interactive: ensure prompts on first install (inherited from
	# _bu_cmd_install's read path), runs silently on upgrade. Users don't
	# see a prompt on every `./setup.sh` run — only the first one.
	"$helper" ensure || print_warning "bash ensure failed (non-fatal) — advisory written"
	return 0
}

# GH#17769: Comment out deprecated model env vars in a single credentials file.
_comment_out_deprecated_model_vars() {
	local file="$1"
	local deprecated_vars="AIDEVOPS_HEADLESS_MODELS|PULSE_MODEL"
	local deprecation_note="# DEPRECATED by aidevops v3.7+ — model routing is now automatic (GH#17769)"
	[[ -f "$file" ]] || return 0
	# Only process active assignments/exports (not already commented). Some old
	# credentials used VAR=... followed by export VAR, so clean both shapes.
	if grep -qE "^[[:space:]]*(export[[:space:]]+)?(${deprecated_vars})=" "$file" 2>/dev/null; then
		sed -i.bak -E "s/^([[:space:]]*)((export[[:space:]]+)?(${deprecated_vars})=.*)$/\\1${deprecation_note}\\
\\1# \\2/" "$file"
		rm -f "${file}.bak"
		print_info "Commented out deprecated model env vars in $(basename "$file")"
	fi
	return 0
}

# GH#17769: Comment out deprecated model env vars from credentials.sh.
# Runs on every `aidevops update`. Uses sed to comment out (not delete) lines
# so the user's file history is preserved.
_cleanup_legacy_model_config() {
	local creds_file="${HOME}/.config/aidevops/credentials.sh"
	_comment_out_deprecated_model_vars "$creds_file"

	# Clean up tenant credentials files
	local tenant_dir="${HOME}/.config/aidevops/tenants"
	if [[ -d "$tenant_dir" ]]; then
		local tenant_creds=""
		while IFS= read -r -d '' tenant_creds; do
			_comment_out_deprecated_model_vars "$tenant_creds"
		done < <(find "$tenant_dir" -name "credentials.sh" -print0 2>/dev/null)
	fi
	return 0
}

# Deploy auto-hotfix.conf template to user-level configs if not already present.
# The template ships in .agents/configs/; this copies to ~/.aidevops/configs/
# where user edits survive `aidevops update`. Existing user config is preserved.
_deploy_hotfix_config() {
	local source_conf="${INSTALL_DIR:-.}/.agents/configs/auto-hotfix.conf"
	local target_dir="$HOME/.aidevops/configs"
	local target_conf="$target_dir/auto-hotfix.conf"

	if [[ ! -f "$source_conf" ]]; then
		return 0
	fi

	# Only deploy if the user doesn't have one yet (preserve user edits)
	if [[ -f "$target_conf" ]]; then
		return 0
	fi

	mkdir -p "$target_dir"
	cp "$source_conf" "$target_conf"
	chmod 600 "$target_conf"
	return 0
}

# t2919: Early pulse plist install. The pulse launchd agent is critical
# infrastructure — without it, every other pulse-driven feature (worker
# dispatch, issue routing, cross-repo coordination) is dead. Previously,
# setup_supervisor_pulse only ran inside _setup_post_setup_steps which
# executes AFTER ~25 other migration/setup steps. When `aidevops update`
# runs unattended and any earlier step times out (e.g. brew taps, MCP
# installs, slow repo scans), the pulse plist never gets installed/refreshed
# and the runner falls behind.
#
# Install immediately after deploy_aidevops_agents (so the scripts the plist
# references already exist on disk). The late install in _setup_post_setup_steps
# remains as the canonical regenerate-on-change path — _launchd_install_if_changed
# compares content and skips reload when identical, so the second call is a
# no-op when nothing changed. Failure here is non-fatal: the late path retries.
_setup_install_pulse_plist_early() {
	local _early_os
	_early_os="$(uname -s)"
	if _should_setup_noninteractive_supervisor_pulse; then
		setup_supervisor_pulse "$_early_os" || print_warning "Early pulse plist install failed (will retry late)"
	fi
	return 0
}

# Provision knowledge planes for all repos in repos.json where knowledge != "off".
# Idempotent: already-provisioned directories are not modified.
# Called from the non-interactive setup path (update) and after interactive init.
setup_knowledge_planes() {
	local repos_file="$HOME/.config/aidevops/repos.json"
	local helper
	helper="${BASH_SOURCE[0]%/*}/.agents/scripts/knowledge-helper.sh"
	if [[ ! -f "$helper" ]]; then
		helper="$HOME/.aidevops/agents/scripts/knowledge-helper.sh"
	fi
	if [[ ! -f "$helper" ]]; then
		print_warning "knowledge-helper.sh not found — skipping knowledge plane provisioning"
		return 0
	fi
	if [[ ! -f "$repos_file" ]]; then
		return 0
	fi
	if ! command -v jq &>/dev/null; then
		print_warning "jq not installed — skipping knowledge plane provisioning"
		return 0
	fi
	local repo_path mode
	while IFS=$'\t' read -r repo_path mode; do
		[[ -z "$repo_path" || "$mode" == "off" ]] && continue
		if [[ ! -d "$repo_path" ]]; then
			print_warning "knowledge-plane: repo path not found: $repo_path"
			continue
		fi
		bash "$helper" provision "$repo_path" || print_warning "knowledge-plane: provision failed for $repo_path"
	done < <(jq -r '.initialized_repos[] | select(.knowledge != null and .knowledge != "off") | [.path, .knowledge] | @tsv' "$repos_file" 2>/dev/null || true)
	return 0
}

# Provision cases planes for all repos in repos.json where cases != "off".
# Idempotent: already-provisioned directories are not modified.
# Called from the non-interactive setup path (update) and after interactive init.
setup_cases_planes() {
	local repos_file="$HOME/.config/aidevops/repos.json"
	local helper
	helper="${BASH_SOURCE[0]%/*}/.agents/scripts/case-helper.sh"
	if [[ ! -f "$helper" ]]; then
		helper="$HOME/.aidevops/agents/scripts/case-helper.sh"
	fi
	if [[ ! -f "$helper" ]]; then
		print_warning "case-helper.sh not found — skipping cases plane provisioning"
		return 0
	fi
	if [[ ! -f "$repos_file" ]]; then
		return 0
	fi
	if ! command -v jq &>/dev/null; then
		print_warning "jq not installed — skipping cases plane provisioning"
		return 0
	fi
	local repo_path mode
	while IFS=$'\t' read -r repo_path mode; do
		[[ -z "$repo_path" || "$mode" == "off" ]] && continue
		if [[ ! -d "$repo_path" ]]; then
			print_warning "cases-plane: repo path not found: $repo_path"
			continue
		fi
		bash "$helper" init "$repo_path" || print_warning "cases-plane: init failed for $repo_path"
	done < <(jq -r '.initialized_repos[] | select(.cases != null and .cases != "off") | [.path, .cases] | @tsv' "$repos_file" 2>/dev/null || true)
	return 0
}

# Non-interactive setup singleton state. This lock only gates the deployment path;
# interactive setup remains prompt-driven and can still be used for first-run init.
SETUP_NONINTERACTIVE_LOCK_HELD=false
SETUP_NONINTERACTIVE_LOCK_DIR=""
SETUP_NONINTERACTIVE_CHILD_PIDS=""
SETUP_NONINTERACTIVE_TERMINATING=false

_setup_guard_active_release_lane() {
	local repo_slug=""
	local remote_url=""
	local lane_helper="${BASH_SOURCE[0]%/*}/.agents/scripts/release-lane-helper.sh"
	# Isolated CI smoke homes cannot replace a user's active runtime. Keep this
	# test-only bypass coupled to CI so normal setup cannot disable the lane.
	if [[ "${CI:-false}" == "true" && "${AIDEVOPS_RELEASE_LANE_ISOLATED_CI:-0}" == "1" ]]; then
		return 0
	fi
	[[ -f "$lane_helper" ]] || return 0
	remote_url=$(git -C "${BASH_SOURCE[0]%/*}" remote get-url origin 2>/dev/null || true)
	repo_slug=$(printf '%s' "$remote_url" | sed 's|.*github\.com[:/]||;s|\.git$||')
	[[ "$repo_slug" == "marcusquinn/aidevops" ]] || return 0
	# shellcheck source=.agents/scripts/release-lane-helper.sh
	source "$lane_helper"
	release_lane_setup_guard "$repo_slug"
	return $?
}

_setup_lock_pid_alive() {
	local pid="$1"
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	kill -0 "$pid" 2>/dev/null
	return $?
}

_setup_lock_pid_is_noninteractive_setup() {
	local pid="$1"
	local owner_args=""
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	owner_args=$(ps -p "$pid" -o args= 2>/dev/null || true)
	[[ -n "$owner_args" ]] || return 0
	[[ "$owner_args" == *"setup.sh"* && ("$owner_args" == *"--non-interactive"* || "$owner_args" == *"--stage"*) ]]
	return $?
}

_setup_lock_dir_age_seconds() {
	local lock_dir="$1"
	local lock_mtime=""
	local now=""
	if ! [[ -d "$lock_dir" ]]; then
		printf '%s\n' 0
		return 0
	fi
	if type _file_mtime_epoch >/dev/null 2>&1; then
		lock_mtime=$(_file_mtime_epoch "$lock_dir" 2>/dev/null || true)
	elif [[ "$(uname -s 2>/dev/null || true)" == "$SETUP_OS_DARWIN" || "$(uname -s 2>/dev/null || true)" == "FreeBSD" ]]; then
		lock_mtime=$(stat -f %m "$lock_dir" 2>/dev/null || true)
	else
		lock_mtime=$(stat -c %Y "$lock_dir" 2>/dev/null || true)
	fi
	now=$(date +%s 2>/dev/null || true)
	if [[ "$lock_mtime" =~ ^[0-9]+$ && "$now" =~ ^[0-9]+$ && "$now" -ge "$lock_mtime" ]]; then
		printf '%s\n' $((now - lock_mtime))
		return 0
	fi
	printf '%s\n' 0
	return 0
}

_setup_lock_started_age_seconds() {
	local lock_dir="$1"
	local started_str=""
	local started_epoch=""
	local now_epoch=""
	if [[ -r "$lock_dir/started_at" ]]; then
		started_str=$(tr -d '[:space:]' <"$lock_dir/started_at" 2>/dev/null || true)
		started_epoch=$(date -d "$started_str" +%s 2>/dev/null ||
			date -u -jf '%Y-%m-%dT%H:%M:%SZ' "$started_str" +%s 2>/dev/null || true)
		now_epoch=$(date +%s 2>/dev/null || true)
		if [[ "$started_epoch" =~ ^[0-9]+$ && "$now_epoch" =~ ^[0-9]+$ && "$now_epoch" -ge "$started_epoch" ]]; then
			printf '%s\n' $((now_epoch - started_epoch))
			return 0
		fi
	fi
	_setup_lock_dir_age_seconds "$lock_dir"
	return 0
}

_setup_pid_elapsed_seconds() {
	local pid="$1"
	local etime=""
	local first="" second="" third=""
	local days=0 hours=0 minutes=0 seconds=0
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	etime=$(ps -p "$pid" -o etime= 2>/dev/null || true)
	etime="${etime//[[:space:]]/}"
	[[ -n "$etime" ]] || return 1
	IFS=':' read -r first second third <<<"$etime"
	if [[ -n "$third" ]]; then
		seconds="$third"
		minutes="$second"
		if [[ "$first" == *"-"* ]]; then
			days="${first%%-*}"
			hours="${first#*-}"
		else
			hours="$first"
		fi
	else
		minutes="$first"
		seconds="$second"
	fi
	if [[ "$days" =~ ^[0-9]+$ && "$hours" =~ ^[0-9]+$ && "$minutes" =~ ^[0-9]+$ && "$seconds" =~ ^[0-9]+$ ]]; then
		printf '%s\n' $((days * 86400 + hours * 3600 + minutes * 60 + seconds))
		return 0
	fi
	return 1
}

_setup_register_child_pid() {
	local pid="$1"
	[[ -n "$pid" ]] || return 0
	SETUP_NONINTERACTIVE_CHILD_PIDS="${SETUP_NONINTERACTIVE_CHILD_PIDS}${SETUP_NONINTERACTIVE_CHILD_PIDS:+ }${pid}"
	return 0
}

_setup_collect_child_pids() {
	local parent_pid="$1"
	local child_pid=""
	local child_pids=""
	local current_pid="${BASHPID:-$$}"
	child_pids=$(pgrep -P "$parent_pid" 2>/dev/null || true)
	for child_pid in $child_pids; do
		[[ -n "$child_pid" && "$child_pid" != "$current_pid" ]] || continue
		printf '%s\n' "$child_pid"
		_setup_collect_child_pids "$child_pid"
	done
	return 0
}

_setup_kill_pid_tree() {
	local signal_name="$1"
	local root_pid="$2"
	local child_pid=""
	local current_pid="${BASHPID:-$$}"
	[[ -n "$root_pid" && "$root_pid" != "$current_pid" ]] || return 0
	for child_pid in $(_setup_collect_child_pids "$root_pid"); do
		kill "-${signal_name}" "$child_pid" 2>/dev/null || true
	done
	kill "-${signal_name}" "$root_pid" 2>/dev/null || true
	return 0
}

_setup_cleanup_noninteractive_children() {
	local pid=""
	local current_pid="${BASHPID:-$$}"
	local grace_s="${AIDEVOPS_SETUP_CHILD_TERM_GRACE_S:-2}"
	local has_live_child=false
	[[ "$grace_s" =~ ^[0-9]+$ ]] || grace_s=2
	for pid in $(_setup_collect_child_pids "$current_pid"); do
		_setup_register_child_pid "$pid"
	done
	for pid in ${SETUP_NONINTERACTIVE_CHILD_PIDS:-}; do
		if _setup_lock_pid_alive "$pid"; then
			has_live_child=true
			_setup_kill_pid_tree TERM "$pid"
		fi
	done
	if [[ "$has_live_child" == "true" && "$grace_s" -gt 0 ]]; then
		sleep "$grace_s" 2>/dev/null || true
	fi
	for pid in ${SETUP_NONINTERACTIVE_CHILD_PIDS:-}; do
		if _setup_lock_pid_alive "$pid"; then
			_setup_kill_pid_tree KILL "$pid"
		fi
	done
	for pid in ${SETUP_NONINTERACTIVE_CHILD_PIDS:-}; do
		wait "$pid" 2>/dev/null || true
	done
	return 0
}

_setup_run_noncritical_stage_bounded() {
	local stage_label="$1"
	local timeout_s="$2"
	shift 2
	local start_s=$SECONDS
	local pid=""
	local rc=0
	[[ "$timeout_s" =~ ^[0-9]+$ ]] || timeout_s=60
	"$@" &
	pid=$!
	_setup_register_child_pid "$pid"
	while _setup_lock_pid_alive "$pid"; do
		if ((SECONDS - start_s >= timeout_s)); then
			_setup_kill_pid_tree TERM "$pid"
			sleep "${AIDEVOPS_SETUP_CHILD_TERM_GRACE_S:-2}" 2>/dev/null || true
			_setup_kill_pid_tree KILL "$pid"
			wait "$pid" 2>/dev/null || true
			print_warning "${stage_label} exceeded ${timeout_s}s — skipping remaining non-critical work"
			return 0
		fi
		sleep 1
	done
	wait "$pid" 2>/dev/null || rc=$?
	return "$rc"
}

_setup_release_noninteractive_setup_lock() {
	local lock_dir="${SETUP_NONINTERACTIVE_LOCK_DIR:-}"
	local owner_pid=""
	if [[ "${SETUP_NONINTERACTIVE_LOCK_HELD:-false}" != "true" || -z "$lock_dir" ]]; then
		return 0
	fi
	if [[ -r "$lock_dir/owner.pid" ]]; then
		owner_pid=$(tr -d '[:space:]' <"$lock_dir/owner.pid" 2>/dev/null || true)
	fi
	if [[ -z "$owner_pid" || "$owner_pid" == "$$" ]]; then
		rm -rf "$lock_dir" 2>/dev/null || true
	fi
	SETUP_NONINTERACTIVE_LOCK_HELD=false
	return 0
}

_setup_noninteractive_signal_exit() {
	local signal_name="$1"
	local exit_code=143
	[[ "$signal_name" == "INT" ]] && exit_code=130
	SETUP_NONINTERACTIVE_TERMINATING=true
	print_warning "setup.sh --non-interactive received ${signal_name}; cleaning up child deployment processes"
	_setup_cleanup_noninteractive_children
	_setup_release_noninteractive_setup_lock
	exit "$exit_code"
}

# Compute how many seconds the live lock owner has held the setup lock.
# Uses started_at_epoch when it agrees with the owner PID runtime; falls back to
# the PID runtime when an old lock timestamp points at a newer live setup owner.
# Prints the age in seconds on stdout; prints 0 when unknown.
_setup_lock_owner_age() {
	local lock_dir="$1"
	local owner_pid="$2"
	local _start_epoch="" _now_epoch="" _age_tmp="" _pid_age=""
	if [[ -r "$lock_dir/started_at_epoch" ]]; then
		_start_epoch=$(tr -d '[:space:]' <"$lock_dir/started_at_epoch" 2>/dev/null || true)
		_now_epoch=$(date +%s 2>/dev/null || printf '0')
		if [[ "$_start_epoch" =~ ^[0-9]+$ && "$_now_epoch" =~ ^[0-9]+$ && "$_now_epoch" -ge "$_start_epoch" ]]; then
			_age_tmp="$((_now_epoch - _start_epoch))"
			_pid_age=$(_setup_pid_elapsed_seconds "$owner_pid" 2>/dev/null || true)
			if [[ "$_pid_age" =~ ^[0-9]+$ && "$_age_tmp" -gt $((_pid_age + 300)) ]]; then
				printf '%s' "$_pid_age"
				return 0
			fi
			printf '%s' "$_age_tmp"
			return 0
		fi
	fi
	# Fallback: ps etimes (seconds elapsed since process start).
	_age_tmp=$(ps -p "$owner_pid" -o etimes= 2>/dev/null | tr -d '[:space:]')
	if [[ "$_age_tmp" =~ ^[0-9]+$ ]]; then
		printf '%s' "$_age_tmp"
		return 0
	fi
	printf '0'
	return 0
}

_setup_command_key_looks_secret() {
	local key="$1"
	key="${key#--}"
	key="${key#-}"
	case "$key" in
	*password* | *passwd* | *secret* | *token* | *credential* | *api-key* | *api_key* | *apikey* | *access-key* | *access_key* | *private-key* | *private_key* | bearer)
		return 0
		;;
	esac
	return 1
}

_setup_redact_secret_like_command_values() {
	local command_text="$1"
	local redacted=""
	local separator=""
	local word=""
	local lower_word=""
	local key_part=""
	local redact_next=false

	for word in $command_text; do
		lower_word=$(printf '%s' "$word" | tr '[:upper:]' '[:lower:]')
		if [[ "$redact_next" == "true" ]]; then
			word="[redacted]"
			redact_next=false
		elif [[ "$lower_word" == *=* ]]; then
			key_part="${lower_word%%=*}"
			if _setup_command_key_looks_secret "$key_part"; then
				word="${word%%=*}=[redacted]"
			fi
		elif _setup_command_key_looks_secret "$lower_word"; then
			redact_next=true
		fi
		redacted="${redacted}${separator}${word}"
		separator=" "
	done

	printf '%s' "$redacted"
	return 0
}

_setup_acquire_noninteractive_setup_lock() {
	local lock_dir="${AIDEVOPS_SETUP_LOCK_DIR:-$HOME/.aidevops/locks/setup-noninteractive.lock.d}"
	# Max seconds to wait for a live, non-stale owner before timing out.
	local wait_ceiling="${AIDEVOPS_SETUP_WAIT_TIMEOUT_S:-900}"
	# Max seconds a live owner may hold the lock before it is treated as
	# stale and reclaimed (0 disables stale-live reclaim).
	local stale_ceiling="${AIDEVOPS_SETUP_STALE_TIMEOUT_S:-1800}"
	local owner_pid="" owner_cmd="" owner_age=0
	local reclaim_attempts=0 waited=0
	local lane_rc=0
	local _diag_stl="$HOME/.aidevops/logs/setup-stage-timings.log"
	local _diag_interval_s="${AIDEVOPS_SETUP_LOCK_DIAG_INTERVAL_S:-60}"
	_setup_guard_active_release_lane || return $?
	[[ "$_diag_interval_s" =~ ^[0-9]+$ && "$_diag_interval_s" -gt 0 ]] || _diag_interval_s=60
	mkdir -p "$(dirname "$lock_dir")" 2>/dev/null || true
	while true; do
		if mkdir "$lock_dir" 2>/dev/null; then
			SETUP_NONINTERACTIVE_LOCK_DIR="$lock_dir"
			SETUP_NONINTERACTIVE_LOCK_HELD=true
			printf '%s\n' "$$" >"$lock_dir/owner.pid" 2>/dev/null || true
			printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$lock_dir/started_at" 2>/dev/null || true
			printf '%s\n' "$(date +%s 2>/dev/null || printf '0')" >"$lock_dir/started_at_epoch" 2>/dev/null || true
			printf '%s\n' "$0 $*" >"$lock_dir/command" 2>/dev/null || true
			_setup_guard_active_release_lane || lane_rc=$?
			if [[ "$lane_rc" -ne 0 ]]; then
				_setup_release_noninteractive_setup_lock
				return "$lane_rc"
			fi
			trap '_setup_cleanup_noninteractive_children; _setup_release_noninteractive_setup_lock' EXIT
			trap '_setup_noninteractive_signal_exit TERM' TERM
			trap '_setup_noninteractive_signal_exit INT' INT
			return 0
		fi

		# Lock exists — inspect owner.
		owner_pid=""
		if [[ -r "$lock_dir/owner.pid" ]]; then
			owner_pid=$(tr -d '[:space:]' <"$lock_dir/owner.pid" 2>/dev/null || true)
		fi

		if [[ -z "$owner_pid" ]]; then
			local _lock_age="0"
			_lock_age=$(_setup_lock_dir_age_seconds "$lock_dir")
			if [[ "$_lock_age" -le 300 ]]; then
				print_error "Another setup.sh --non-interactive process is acquiring the deploy lock (lock: ${lock_dir}, age ${_lock_age}s). Exiting to avoid overlapping deployments."
				return 75
			fi
			print_warning "Removing stale setup.sh --non-interactive lock with no owner at ${lock_dir} (age ${_lock_age}s)"
			rm -rf "$lock_dir" 2>/dev/null || true
			reclaim_attempts=$((reclaim_attempts + 1))
			if [[ "$reclaim_attempts" -ge 2 ]]; then
				print_error "Unable to acquire setup.sh --non-interactive lock at ${lock_dir} after ${reclaim_attempts} stale-lock removals"
				return 75
			fi
			continue
		fi

		if ! _setup_lock_pid_alive "$owner_pid"; then
			# Dead owner — reclaim the stale lock.
			if [[ "$reclaim_attempts" -ge 2 ]]; then
				print_error "Unable to acquire setup.sh --non-interactive lock at ${lock_dir} after ${reclaim_attempts} stale-lock removals"
				return 75
			fi
			print_warning "Removing stale setup.sh --non-interactive lock at ${lock_dir}"
			rm -rf "$lock_dir" 2>/dev/null || true
			reclaim_attempts=$((reclaim_attempts + 1))
			continue
		fi

		if ! _setup_lock_pid_is_noninteractive_setup "$owner_pid"; then
			local _owner_lock_age="0"
			_owner_lock_age=$(_setup_lock_dir_age_seconds "$lock_dir")
			if [[ "$_owner_lock_age" -le 300 ]]; then
				print_error "Another setup.sh --non-interactive process may be acquiring the deploy lock (pid ${owner_pid}; lock: ${lock_dir}, age ${_owner_lock_age}s). Exiting to avoid overlapping deployments."
				return 75
			fi
			print_warning "Removing stale setup.sh --non-interactive lock at ${lock_dir}; owner pid ${owner_pid} no longer appears to be setup.sh --non-interactive (age ${_owner_lock_age}s)"
			rm -rf "$lock_dir" 2>/dev/null || true
			reclaim_attempts=$((reclaim_attempts + 1))
			continue
		fi

		# Owner is alive — compute age and read current setup stage.
		owner_age=$(_setup_lock_owner_age "$lock_dir" "$owner_pid")
		owner_cmd=""
		[[ -r "$lock_dir/command" ]] && owner_cmd=$(tr '\n' ' ' <"$lock_dir/command" 2>/dev/null || true)
		[[ -n "$owner_cmd" ]] && owner_cmd=$(_setup_redact_secret_like_command_values "$owner_cmd")
		local _diag_stage=""
		if [[ -r "$_diag_stl" ]]; then
			local _diag_cur_stage=""
			_diag_cur_stage=$(awk -F'\t' '$4=="RUNNING"{s=$2} END{if(s)printf "%s",s}' "$_diag_stl" 2>/dev/null || true)
			[[ -n "$_diag_cur_stage" ]] && _diag_stage=", stage: ${_diag_cur_stage}"
		fi

		# Stale-live reclaim: owner alive but running far too long.
		if [[ "$stale_ceiling" -gt 0 && "$owner_age" -ge "$stale_ceiling" ]]; then
			if [[ "$reclaim_attempts" -ge 2 ]]; then
				print_error "Unable to acquire setup.sh --non-interactive lock: owner (pid ${owner_pid}, age ${owner_age}s) exceeds stale ceiling but reclaim limit reached. Diagnose: ${_diag_stl}"
				return 75
			fi
			print_warning "setup.sh --non-interactive lock owner (pid ${owner_pid}) running ${owner_age}s — exceeds stale ceiling ${stale_ceiling}s (AIDEVOPS_SETUP_STALE_TIMEOUT_S)${owner_cmd:+; command: ${owner_cmd}}. Reclaiming lock."
			rm -rf "$lock_dir" 2>/dev/null || true
			reclaim_attempts=$((reclaim_attempts + 1))
			continue
		fi

		# Live non-stale owner — check wait ceiling before sleeping.
		if [[ "$waited" -ge "$wait_ceiling" ]]; then
			print_error "Timed out waiting ${waited}s for setup.sh --non-interactive lock (owner pid ${owner_pid}, age ${owner_age}s${_diag_stage}${owner_cmd:+, command: ${owner_cmd}}). Increase AIDEVOPS_SETUP_WAIT_TIMEOUT_S (current: ${wait_ceiling}s) or kill pid ${owner_pid} to unblock. Diagnose: ${_diag_stl}"
			return 75
		fi

		# Emit diagnostics on first block and every diagnostic interval thereafter.
		if [[ "$waited" -eq 0 ]]; then
			print_info "Another setup.sh --non-interactive is running (pid ${owner_pid}, age ${owner_age}s${_diag_stage}${owner_cmd:+, command: ${owner_cmd}}). Waiting up to ${wait_ceiling}s (AIDEVOPS_SETUP_WAIT_TIMEOUT_S). Diagnose: ${_diag_stl}"
		elif [[ $((waited % _diag_interval_s)) -eq 0 ]]; then
			print_info "Still waiting for setup lock (owner pid ${owner_pid}, age ${owner_age}s${_diag_stage}${owner_cmd:+, command: ${owner_cmd}}, waited ${waited}s of ${wait_ceiling}s max). Diagnose: ${_diag_stl}"
		fi

		sleep 10
		waited=$((waited + 10))
	done
}

# Non-interactive path: deploy agents and run safe migrations only (no prompts).
# GH#21060 / t2911: Every direct function call is wrapped with _time_step so
# that a one-line-per-stage TSV timing record is appended to
# $HOME/.aidevops/logs/setup-stage-timings.log for post-run diagnostics.
_setup_init_stage_timing_log() {
	# GH#21060: Initialise per-stage timing log; rotate if over 10K lines / 1MB.
	local _stl
	_stl="$HOME/.aidevops/logs/setup-stage-timings.log"
	mkdir -p "$(dirname "$_stl")" 2>/dev/null || true
	if [[ -f "$_stl" ]]; then
		local _stl_lines _stl_bytes
		_stl_lines=$(wc -l <"$_stl" 2>/dev/null || echo "0")
		_stl_bytes=$(wc -c <"$_stl" 2>/dev/null || echo "0")
		# Strip whitespace that wc adds on some platforms
		_stl_lines="${_stl_lines//[[:space:]]/}"
		_stl_bytes="${_stl_bytes//[[:space:]]/}"
		if [[ "${_stl_lines:-0}" -gt 10000 ]] || [[ "${_stl_bytes:-0}" -gt 1048576 ]]; then
			: >"$_stl" 2>/dev/null || true
			print_info "setup-stage-timings.log rotated (was ${_stl_lines} lines / ${_stl_bytes} bytes)"
		fi
	fi
	return 0
}

_setup_ai_session_reset_plan() {
	_SETUP_AI_SESSION_NEEDS_AGENTS=0
	_SETUP_AI_SESSION_NEEDS_CLI=0
	_SETUP_AI_SESSION_NEEDS_HOOKS=0
	_SETUP_AI_SESSION_NEEDS_REPO_VERIFY=0
	_SETUP_AI_SESSION_NEEDS_PULSE=0
	_SETUP_AI_SESSION_NEEDS_GUI=0
	_SETUP_AI_SESSION_REQUIRES_FULL=0
	return 0
}

_setup_ai_session_setup_sh_version_only() {
	local deployed_sha="$1"
	local current_sha="$2"
	local diff_output=""
	local line=""
	local payload=""
	local version_prefix=""
	version_prefix="# ""Version:"

	diff_output=$(git -C "$INSTALL_DIR" diff --unified=0 "$deployed_sha" "$current_sha" -- setup.sh 2>/dev/null) || return 1
	while IFS= read -r line; do
		case "$line" in
		"diff --git "* | "index "* | "--- "* | "+++ "* | "@@"*)
			continue
			;;
		+* | -*)
			payload="${line#?}"
			if [[ "$payload" != "$version_prefix "* ]]; then
				return 1
			fi
			;;
		esac
	done <<<"$diff_output"

	return 0
}

_setup_ai_session_plan_file() {
	local filepath="$1"
	local deployed_sha="$2"
	local current_sha="$3"

	case "$filepath" in
	setup.sh)
		if _setup_ai_session_setup_sh_version_only "$deployed_sha" "$current_sha"; then
			print_info "setup.sh drift is release-version metadata only; incremental setup can continue"
		else
			print_warning "setup.sh changed beyond the release-version header; full setup required"
			_SETUP_AI_SESSION_REQUIRES_FULL=1
		fi
		;;
	aidevops.sh)
		_SETUP_AI_SESSION_NEEDS_CLI=1
		;;
	.agents/hooks/*)
		_SETUP_AI_SESSION_NEEDS_HOOKS=1
		[[ "$filepath" == ".agents/hooks/repo-verify-pre-push.sh" ]] && _SETUP_AI_SESSION_NEEDS_REPO_VERIFY=1
		;;
	.agents/scripts/repo-verify-config-lib.sh | .agents/scripts/lint-helper.sh | \
		.agents/scripts/install-pre-push-guards.sh | .agents/configs/repo-verify-defaults.conf | \
		.agents/scripts/aidevops-cli/aidevops-init-lib.sh | .agents/scripts/aidevops-cli/aidevops-update-lib.sh)
		_SETUP_AI_SESSION_NEEDS_REPO_VERIFY=1
		;;
	.agents/scripts/setup/modules/schedulers*.sh | .agents/scripts/setup/_scheduler_runtime.sh)
		_SETUP_AI_SESSION_NEEDS_PULSE=1
		;;
	.agents/scripts/setup/modules/agent-deploy.sh | .agents/scripts/setup/modules/plugins.sh)
		:
		;;
	.agents/scripts/setup/*)
		print_warning "Setup implementation changed ($filepath); full setup required"
		_SETUP_AI_SESSION_REQUIRES_FULL=1
		;;
	packages/gui-api/* | packages/gui-desktop/* | packages/gui-shared/* | packages/gui-web/*)
		_SETUP_AI_SESSION_NEEDS_GUI=1
		;;
	esac

	return 0
}

_setup_ai_session_build_plan() {
	local changed_files="$1"
	local deployed_sha="$2"
	local current_sha="$3"
	local filepath=""

	_setup_ai_session_reset_plan
	# Deploying agents is the cheap, atomic baseline: it copies .agents/, writes
	# VERSION, writes .deployed-sha, and restarts pulse asynchronously.
	_SETUP_AI_SESSION_NEEDS_AGENTS=1
	while IFS= read -r filepath; do
		[[ -n "$filepath" ]] || continue
		_setup_ai_session_plan_file "$filepath" "$deployed_sha" "$current_sha"
	done <<<"$changed_files"

	return 0
}

_setup_reconcile_runtime_config() {
	pin_aidevops_active_runtime_bundle_root || {
		print_warning "Runtime configuration reconciliation could not resolve the active agents bundle"
		return 1
	}
	update_runtime_configs || return $?
	deploy_commands_to_all_runtimes || return $?
	return 0
}

_setup_git_checkout_available() {
	local checkout_root="$1"
	local git_dir=""
	local git_common_dir=""

	git_dir=$(git -C "$checkout_root" rev-parse --git-dir 2>/dev/null) || return 1
	git_common_dir=$(git -C "$checkout_root" rev-parse --git-common-dir 2>/dev/null) || return 1
	[[ -n "$git_dir" && -n "$git_common_dir" ]] || return 1
	return 0
}

_setup_ai_session_verify_deploy() {
	local expected_sha="$1"
	verify_aidevops_runtime_bundle_convergence \
		"$INSTALL_DIR" \
		"$expected_sha" \
		"$HOME/.aidevops/agents" \
		"$HOME/.aidevops/.deployed-sha"
	return $?
}

_setup_run_ai_session_incremental() {
	local os="$1"
	local stamp_file="$HOME/.aidevops/.deployed-sha"
	local deployed_sha=""
	local current_sha=""
	local changed_files=""

	print_info "AI-session setup mode: applying changed deploy stages only"
	if ! _setup_git_checkout_available "$INSTALL_DIR" || [[ ! -f "$stamp_file" ]]; then
		print_warning "AI-session incremental setup needs a git checkout and deployed SHA stamp"
		return 1
	fi

	deployed_sha=$(tr -d '[:space:]' <"$stamp_file" 2>/dev/null) || deployed_sha=""
	current_sha=$(git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null) || current_sha=""
	if [[ -z "$deployed_sha" || -z "$current_sha" ]]; then
		print_warning "AI-session incremental setup could not resolve deployed/current SHAs"
		return 1
	fi

	if [[ "$deployed_sha" == "$current_sha" ]]; then
		print_success "AI-session setup: deployed SHA already matches current checkout"
		_setup_ai_session_verify_deploy "$current_sha" || return $?
		return 0
	fi

	changed_files=$(git -C "$INSTALL_DIR" diff --name-only "$deployed_sha" "$current_sha" 2>/dev/null) || {
		print_warning "AI-session incremental setup could not diff ${deployed_sha:0:7}..${current_sha:0:7}"
		return 1
	}

	_setup_ai_session_build_plan "$changed_files" "$deployed_sha" "$current_sha"
	if [[ "$_SETUP_AI_SESSION_REQUIRES_FULL" -eq 1 ]]; then
		return 1
	fi

	_setup_init_stage_timing_log
	if [[ "$_SETUP_AI_SESSION_NEEDS_AGENTS" -eq 1 ]]; then
		_time_step "$SETUP_STAGE_AGENTS" deploy_aidevops_agents || return $?
		_time_step "$SETUP_STAGE_OPENCODE_PLUGINS" setup_opencode_plugins || return $?
		_time_step "$SETUP_STAGE_HOTFIX_CONFIG" _deploy_hotfix_config || return $?
		_time_step "$SETUP_STAGE_RUNTIME_CONFIG" _setup_reconcile_runtime_config || return $?
	fi
	if [[ "$_SETUP_AI_SESSION_NEEDS_CLI" -eq 1 ]]; then
		_time_step "install_aidevops_cli" install_aidevops_cli || return $?
	fi
	if [[ "$_SETUP_AI_SESSION_NEEDS_HOOKS" -eq 1 ]]; then
		_time_step "$SETUP_STAGE_HOOKS" setup_safety_hooks || return $?
	fi
	if [[ "$_SETUP_AI_SESSION_NEEDS_REPO_VERIFY" -eq 1 ]]; then
		_time_step "setup_repo_verify_guard" setup_repo_verify_guard || return $?
	fi
	if [[ "$_SETUP_AI_SESSION_NEEDS_PULSE" -eq 1 ]]; then
		_time_step "$SETUP_STAGE_PULSE" setup_supervisor_pulse "$os" || return $?
	fi
	if [[ "$_SETUP_AI_SESSION_NEEDS_GUI" -eq 1 ]]; then
		_time_step "setup_gui_desktop_app_opt_in" _setup_offer_gui_desktop_app || return $?
	fi

	_setup_ai_session_verify_deploy "$current_sha" || return $?
	print_success "AI-session incremental setup complete (${deployed_sha:0:7}→${current_sha:0:7})"
	return 0
}

_setup_run_scoped_stage() {
	local os="$1"
	local stage
	local current_sha=""
	stage="$(_setup_canonical_stage "$SETUP_STAGE")" || return 1

	if [[ "$stage" == "full" ]]; then
		_setup_run_non_interactive
		_setup_post_setup_steps "$os"
		return 0
	fi

	print_info "Scoped setup mode: running ${stage} only"
	_setup_init_stage_timing_log
	case "$stage" in
	"$SETUP_STAGE_OPENCODE")
		_time_step "$SETUP_STAGE_OPENCODE" setup_opencode_cli
		_time_step "setup_opencode_desktop_launcher" setup_opencode_desktop_launcher
		;;
	"$SETUP_STAGE_AGENTS")
		_time_step "$SETUP_STAGE_AGENTS" deploy_aidevops_agents
		_time_step "$SETUP_STAGE_OPENCODE_PLUGINS" setup_opencode_plugins
		_time_step "$SETUP_STAGE_HOTFIX_CONFIG" _deploy_hotfix_config
		;;
	"$SETUP_STAGE_RUNTIME_CONFIG")
		_time_step "$SETUP_STAGE_RUNTIME_CONFIG" _setup_reconcile_runtime_config
		;;
	"$SETUP_STAGE_SOURCE_ACCESS")
		if [[ "$SETUP_EXPLICIT_NON_INTERACTIVE" == "true" ]]; then
			_time_step "$SETUP_STAGE_SOURCE_ACCESS" setup_source_access_broker
		else
			AIDEVOPS_SOURCE_ACCESS_INTERACTIVE=true \
				_time_step "$SETUP_STAGE_SOURCE_ACCESS" setup_source_access_broker
		fi
		;;
	"$SETUP_STAGE_HOOKS")
		_time_step "$SETUP_STAGE_HOOKS" setup_safety_hooks
		;;
	"$SETUP_STAGE_TABBY")
		_time_step "$SETUP_STAGE_TABBY" setup_tabby
		;;
	"$SETUP_STAGE_PULSE")
		_time_step "$SETUP_STAGE_PULSE" setup_supervisor_pulse "$os"
		_time_step "setup_pulse_merge_routine" setup_pulse_merge_routine
		;;
	"$SETUP_STAGE_GUI_DESKTOP")
		_time_step "$SETUP_STAGE_GUI_DESKTOP" setup_gui_desktop_app
		;;
	"$SETUP_STAGE_AI_SESSION")
		if ! _setup_run_ai_session_incremental "$os"; then
			print_warning "AI-session incremental setup unavailable or failed; falling back to full setup"
			_setup_run_non_interactive || return $?
			_setup_post_setup_steps "$os" || return $?
			current_sha=$(git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null) || current_sha=""
			[[ -n "$current_sha" ]] || return 1
			_setup_ai_session_verify_deploy "$current_sha" || return $?
		fi
		;;
	*)
		print_error "Unsupported canonical setup stage: $stage"
		return 1
		;;
	esac
	return 0
}

reconcile_buzz_desktop_compatibility() {
	local helper="${INSTALL_DIR}/agents/scripts/buzz-desktop-helper.sh"
	[[ -x "$helper" ]] || return 0
	local rc=0
	bash "$helper" reconcile --quiet || rc=$?
	case "$rc" in
	0) return 0 ;;
	2)
		print_warning "Buzz Desktop compatibility reconciliation deferred until Buzz is closed; run: aidevops buzz apply"
		return 0
		;;
	*)
		print_warning "Buzz Desktop compatibility reconciliation failed; inspect with: aidevops buzz status"
		return 0
		;;
	esac
}

_setup_run_non_interactive() {
	print_info "Non-interactive mode: deploying agents and running safe migrations only"

	_setup_init_stage_timing_log

	_time_step "protect_current_setup_worktree" protect_current_setup_worktree
	_time_step "verify_location" verify_location
	_time_step "check_requirements" check_requirements
	# Run quality tool detection in non-interactive mode too (warn-only path).
	_time_step "check_quality_tools" check_quality_tools
	# Check setsid availability; auto-install util-linux on macOS if missing
	# (GH#21102 / t2926: missing setsid kills workers on every pulse restart).
	_time_step "setup_setsid_advisory" setup_setsid_advisory
	_time_step "check_python_upgrade_available" check_python_upgrade_available
	_time_step "setup_vault_python_env" setup_vault_python_env || print_warning "Vault crypto runtime setup encountered issues; Vault status remains metadata-only"
	_time_step "set_permissions" set_permissions
	_time_step "migrate_old_backups" migrate_old_backups
	_time_step "migrate_loop_state_directories" migrate_loop_state_directories
	_time_step "migrate_agent_to_agents_folder" migrate_agent_to_agents_folder
	_time_step "migrate_mcp_env_to_credentials" migrate_mcp_env_to_credentials
	_time_step "migrate_pulse_repos_to_repos_json" migrate_pulse_repos_to_repos_json
	_time_step "cleanup_deprecated_paths" cleanup_deprecated_paths
	_time_step "migrate_orphaned_supervisor" migrate_orphaned_supervisor
	_time_step "migrate_custom_model_routing_reasoning_defaults" migrate_custom_model_routing_reasoning_defaults
	_time_step "backfill_issue_relationships" backfill_issue_relationships
	_time_step "cleanup_deprecated_mcps" cleanup_deprecated_mcps
	_time_step "cleanup_stale_bun_opencode" cleanup_stale_bun_opencode
	_time_step "cleanup_stale_health_issue_caches" cleanup_stale_health_issue_caches
	_time_step "cleanup_legacy_aidevops_temp_artifacts" cleanup_legacy_aidevops_temp_artifacts
	_time_step "cleanup_worktree_entries_in_repos_json" cleanup_worktree_entries_in_repos_json
	_time_step "_cleanup_legacy_model_config" _cleanup_legacy_model_config
	_time_step "cleanup_legacy_dashboard_launchagent" cleanup_legacy_dashboard_launchagent
	# t2888: install/heal opencode-ai. Companion to t2887's runtime canary
	# fail-fast -- t2887 detects when $OPENCODE_BIN_DEFAULT is wrong, this
	# one fixes it by reinstalling opencode-ai@latest (overwriting any bin
	# collision with @anthropic-ai/claude-code or similar). Skipping this
	# in non-interactive mode is the bug PR #20189 introduced and what
	# alex-solovyev's runner spam stemmed from.
	_time_step "$SETUP_STAGE_OPENCODE" setup_opencode_cli
	_time_step "validate_opencode_config" validate_opencode_config
	_time_step "$SETUP_STAGE_AGENTS" deploy_aidevops_agents
	_time_step "$SETUP_STAGE_OPENCODE_PLUGINS" setup_opencode_plugins
	_time_step "reconcile_buzz_desktop_compatibility" reconcile_buzz_desktop_compatibility
	_time_step "_setup_install_pulse_plist_early" _setup_install_pulse_plist_early
	_time_step "$SETUP_STAGE_HOTFIX_CONFIG" _deploy_hotfix_config
	_time_step "setup_opencode_desktop_launcher" setup_opencode_desktop_launcher
	_time_step "sync_agent_sources" sync_agent_sources
	_time_step "install_aidevops_cli" install_aidevops_cli || print_warning "aidevops CLI installation encountered issues; continuing configuration reconciliation"
	_time_step "setup_source_access_broker" setup_source_access_broker_nonfatal
	_time_step "setup_shellcheck_wrapper" setup_shellcheck_wrapper
	if is_feature_enabled safety_hooks 2>/dev/null; then
		_time_step "$SETUP_STAGE_HOOKS" setup_safety_hooks
	fi
	_time_step "init_settings_json" init_settings_json

	# Parallelise independent skill operations (t1356: ~84s serial -> ~18s parallel)
	# generate_agent_skills must complete before create_skill_symlinks (symlinks
	# depend on generated SKILL.md files). scan_imported_skills is independent.
	local _pid_symlinks=""
	if _time_step "generate_agent_skills" generate_agent_skills; then
		_time_step "create_skill_symlinks" create_skill_symlinks &
		_pid_symlinks=$!
		_setup_register_child_pid "$_pid_symlinks"
	else
		print_warning "Agent skills generation failed — skipping skill symlinks"
	fi

	_time_step "scan_imported_skills" scan_imported_skills &
	local _pid_scan=$!
	_setup_register_child_pid "$_pid_scan"

	if [[ -n "$_pid_symlinks" ]]; then
		wait "$_pid_symlinks" 2>/dev/null || print_warning "Skill symlink creation encountered issues (non-critical)"
	fi
	wait "$_pid_scan" 2>/dev/null || print_warning "Skill security scan encountered issues (non-critical)"

	_time_step "inject_agents_reference" inject_agents_reference
	# Use the bounded wrapper so a slow file-system traversal across many agent
	# files does not consume the remaining postflight budget and trip the outer
	# timeout (GH#22087). AIDEVOPS_DEPLOY_RUNTIMES_TIMEOUT controls the deadline.
	_time_step "deploy_agents_to_runtimes" _deploy_agents_to_runtimes_bounded || true
	_time_step "update_opencode_config" _setup_run_noncritical_stage_bounded "OpenCode config update" "${AIDEVOPS_UPDATE_OPENCODE_CONFIG_TIMEOUT:-60}" update_opencode_config
	_time_step "update_claude_config" update_claude_config
	_time_step "update_codex_config" update_codex_config
	_time_step "update_cursor_config" update_cursor_config
	_time_step "disable_ondemand_mcps" disable_ondemand_mcps
	# Scaffold personal routines repo if not already present (idempotent).
	# Creates local git repo + private GitHub remote for personal repo only.
	# Org repos require explicit: aidevops init-routines --org <name>
	_time_step "setup_routines" _setup_run_noncritical_stage_bounded "Routine setup" "${AIDEVOPS_SETUP_ROUTINES_TIMEOUT:-120}" setup_routines
	# Install/refresh the privacy-guard pre-push hook in every initialized
	# repo so TODO/todo/README/ISSUE_TEMPLATE pushes to public GitHub repos
	# are scanned for private slug leaks (t1968).
	_time_step "setup_privacy_guard" setup_privacy_guard
	# Install/refresh the complexity-regression pre-push hook in every
	# initialized repo so pushes that introduce new function-complexity,
	# nesting-depth, or file-size violations are caught before CI (t2198).
	_time_step "setup_complexity_guard" setup_complexity_guard
	# Migrate exact repository-native lint policy and install/refresh repo-verify
	# for eligible registered repositories. Explicit opt-outs are preserved.
	_time_step "setup_repo_verify_guard" setup_repo_verify_guard
	# Install/refresh the canonical-on-main post-checkout hook in every
	# initialized repo so branch switches away from main in the canonical
	# directory are warned against (t1995). Complements pre-edit-check.sh's
	# t1990 edit-time check by catching the branch switch itself.
	_time_step "setup_canonical_guard" setup_canonical_guard
	# Install/refresh the task-id collision guard commit-msg hook in every
	# initialized repo so invented t-IDs in commit subjects are rejected
	# at commit time (t2047). Belt-and-braces with the CI check in
	# .github/workflows/task-id-collision-check.yml.
	_time_step "setup_task_id_guard" setup_task_id_guard
	# Configure the centralized flat linked-worktree directory used by helpers.
	_time_step "setup_worktree_location" setup_worktree_location
	# Apply Spotlight + Time Machine exclusions to every worktree across
	# registered repos so the backup/index cascade triggered by node_modules
	# copies doesn't burn CPU (t2885). Idempotent. macOS only — Linux
	# indexers tracked separately.
	_time_step "setup_worktree_exclusions" setup_worktree_exclusions
	# Provision knowledge planes for repos where knowledge != "off" (idempotent).
	_time_step "setup_knowledge_planes" setup_knowledge_planes
	# Provision cases planes for repos where cases != "off" (idempotent).
	_time_step "setup_cases_planes" setup_cases_planes
	_time_step "setup_gui_desktop_app_opt_in" _setup_offer_gui_desktop_app
	return 0
}

# Interactive runtime/tool setup prompts. Extracted so the parent interactive
# setup function stays below the function-complexity gate while preserving the
# prompt order around runtime-specific installers and config updates.
_setup_run_interactive_runtime_tools() {
	confirm_step "Deploy aidevops agents to runtime agent directories" && deploy_agents_to_runtimes
	confirm_step "Setup isolated Vault crypto runtime" && setup_vault_python_env
	confirm_step "Setup Python environment (DSPy, crawl4ai)" && setup_python_env
	confirm_step "Setup Node.js environment" && setup_nodejs_env
	confirm_step "Install MCP packages globally (fast startup)" && install_mcp_packages
	confirm_step "Setup LocalWP MCP server" && setup_localwp_mcp
	confirm_step "Setup Beads task management" && setup_beads
	confirm_step "Setup SEO integrations (curl subagents)" && setup_seo_mcps
	confirm_step "Setup Google Analytics MCP" && setup_google_analytics_mcp
	confirm_step "Setup QuickFile MCP (UK accounting)" && setup_quickfile_mcp
	confirm_step "Setup browser automation tools" && setup_browser_tools
	confirm_step "Setup AI orchestration frameworks info" && setup_ai_orchestration
	confirm_step "Setup Ollama (local LLM for knowledge plane pii/sensitive/privileged tiers)" && setup_ollama_for_knowledge
	confirm_step "Setup Google Workspace CLI (Gmail, Calendar, Drive)" && setup_google_workspace_cli
	confirm_step "Setup OpenCode CLI (AI coding tool)" && setup_opencode_cli
	confirm_step "Install OpenCode AIDevOps Desktop app wrapper" && setup_opencode_desktop_launcher
	confirm_step "Setup OpenCode plugins" && setup_opencode_plugins
	confirm_step "Setup Codex CLI (OpenAI AI coding tool)" && setup_codex_cli
	confirm_step "Setup Droid CLI (Factory.AI coding tool)" && setup_droid_cli
	return 0
}

# Interactive path: all optional steps gated behind confirm_step prompts.
_setup_run_interactive() {
	# Required steps (always run)
	verify_location
	check_requirements

	# Quality tools check (optional but recommended)
	confirm_step "Check quality tools (shellcheck, shfmt)" && check_quality_tools

	# Core runtime setup (early - many later steps depend on these)
	confirm_step "Setup Node.js runtime (required for OpenCode and tools)" && setup_nodejs

	# Shell environment setup (early, so later tools benefit from zsh/Oh My Zsh)
	confirm_step "Setup Oh My Zsh (optional, enhances zsh)" && setup_oh_my_zsh
	confirm_step "Setup cross-shell compatibility (preserve bash config in zsh)" && setup_shell_compatibility

	# OrbStack (macOS only - offer VM option early)
	confirm_step "Setup OrbStack (lightweight Linux VMs on macOS)" && setup_orbstack_vm

	# Optional steps with confirmation in interactive mode
	confirm_step "Check optional dependencies (bun, node, python)" && check_optional_deps
	confirm_step "Check Python version (recommend upgrade if outdated)" && check_python_upgrade_available
	confirm_step "Setup recommended tools (Tabby, Zed, etc.)" && setup_recommended_tools
	confirm_step "Setup PIM tools (Reminders, Calendar, Contacts)" && setup_pim_tools
	confirm_step "Setup mobile simulator tools (MiniSim, serve-sim)" && setup_mobile_simulator_tools
	confirm_step "Setup ClaudeBar (AI quota monitor in menu bar)" && setup_claudebar
	confirm_step "Setup Git CLIs (gh, glab, tea)" && setup_git_clis
	confirm_step "Setup file discovery tools (fd, ripgrep, ripgrep-all)" && setup_file_discovery_tools
	confirm_step "Setup rtk (token-optimized CLI output, 60-90% savings)" && setup_rtk
	confirm_step "Setup shell linting tools (shellcheck, shfmt)" && {
		setup_shell_linting_tools
		setup_shellcheck_wrapper
	}
	confirm_step "Setup Qlty CLI (multi-linter code quality)" && setup_qlty_cli
	confirm_step "Rosetta audit (Apple Silicon x86 migration)" && setup_rosetta_audit
	confirm_step "Setup Worktrunk (git worktree management)" && setup_worktrunk
	confirm_step "Setup SSH key" && setup_ssh_key
	confirm_step "Setup configuration files" && setup_configs
	confirm_step "Set secure permissions on config files" && set_permissions
	confirm_step "Setup shell aliases" && setup_aliases
	confirm_step "Setup terminal title integration" && setup_terminal_title
	confirm_step "Deploy AI templates to home directories" && deploy_ai_templates
	confirm_step "Migrate old backups to new structure" && migrate_old_backups
	confirm_step "Migrate loop state from .claude/.agent/ to .agents/loop-state/" && migrate_loop_state_directories
	confirm_step "Migrate .agent -> .agents in user projects" && migrate_agent_to_agents_folder
	confirm_step "Migrate mcp-env.sh -> credentials.sh" && migrate_mcp_env_to_credentials
	confirm_step "Migrate pulse-repos.json into repos.json" && migrate_pulse_repos_to_repos_json
	confirm_step "Cleanup deprecated agent paths" && cleanup_deprecated_paths
	confirm_step "Migrate orphaned supervisor to pulse-wrapper" && migrate_orphaned_supervisor
	migrate_custom_model_routing_reasoning_defaults
	confirm_step "Backfill GitHub issue relationships (blocked-by, sub-issues)" && backfill_issue_relationships
	confirm_step "Cleanup deprecated MCP entries (hetzner, serper, etc.)" && cleanup_deprecated_mcps
	confirm_step "Cleanup stale bun opencode install" && cleanup_stale_bun_opencode
	# Silent one-shot migrations (idempotent, flag-guarded — no prompt needed).
	cleanup_stale_health_issue_caches
	cleanup_legacy_aidevops_temp_artifacts
	cleanup_worktree_entries_in_repos_json
	_cleanup_legacy_model_config
	cleanup_legacy_dashboard_launchagent
	confirm_step "Validate and repair OpenCode config schema" && validate_opencode_config
	confirm_step "Extract OpenCode prompts" && extract_opencode_prompts
	confirm_step "Check OpenCode prompt drift" && check_opencode_prompt_drift
	confirm_step "Deploy aidevops agents to ~/.aidevops/agents/" && {
		deploy_aidevops_agents
		_deploy_hotfix_config
	}
	reconcile_buzz_desktop_compatibility
	# Launcher verification reads the deployed VERSION, so it must follow agent
	# deployment on first-run interactive setup as it already does non-interactively.
	confirm_step "Install and verify aidevops CLI command" && install_aidevops_cli
	if confirm_step "Install the secure source-access approval broker"; then
		AIDEVOPS_SOURCE_ACCESS_INTERACTIVE=true setup_source_access_broker_nonfatal
	fi
	confirm_step "Sync agents from private repositories" && sync_agent_sources
	confirm_step "Set up routines repo (private repo for recurring operational jobs)" && setup_routines
	is_feature_enabled safety_hooks 2>/dev/null && confirm_step "Install Claude Code safety hooks (block destructive commands)" && setup_safety_hooks
	confirm_step "Initialize settings.json (canonical config file)" && init_settings_json
	confirm_step "Setup multi-tenant credential storage" && setup_multi_tenant_credentials
	confirm_step "Generate agent skills (SKILL.md files)" && generate_agent_skills
	confirm_step "Create symlinks for imported skills" && create_skill_symlinks
	confirm_step "Check for skill updates from upstream" && check_skill_updates
	confirm_step "Security scan imported skills" && scan_imported_skills
	confirm_step "Inject agents reference into AI configs" && inject_agents_reference
	_setup_run_interactive_runtime_tools
	_setup_offer_gui_desktop_app
	# Run AFTER CLI installs so config dirs may exist for agent config
	confirm_step "Update OpenCode configuration" && update_opencode_config
	# Run AFTER OpenCode config so Claude Code gets equivalent setup
	confirm_step "Update Claude Code configuration (slash commands, MCPs, settings)" && update_claude_config
	# Run AFTER Claude Code config so Codex/Cursor get equivalent setup
	confirm_step "Update Codex configuration (MCPs, instructions)" && update_codex_config
	confirm_step "Update Cursor configuration (MCPs)" && update_cursor_config
	# Deploy slash commands to the other installed runtimes (Codex, Cursor,
	# Droid, Gemini CLI, Continue, Kiro, Kimi, Qwen) via the unified generator.
	# OpenCode and Claude Code are already handled by their update_*_config
	# functions above. Closes GH#18106 / t15474.
	confirm_step "Deploy slash commands to remaining runtimes" && deploy_commands_to_all_runtimes
	# Run AFTER all MCP setup functions to ensure disabled state persists
	confirm_step "Disable on-demand MCPs globally" && disable_ondemand_mcps
	return 0
}

# Post-setup steps: schedulers, final instructions, optional tool update check.
# Non-interactive scheduler installation. Extracted from
# `_setup_post_setup_steps` (t2903) to keep the parent under the
# function-complexity gate threshold. Each `_should_setup_noninteractive_*`
# guard returns 0 when the corresponding scheduler is already installed
# (regenerate on update) or first-time install is consented via config.
_setup_noninteractive_schedulers() {
	local os="$1"

	# GH#22012: Wrap every scheduler step with _time_step so the stage-timing
	# log ($HOME/.aidevops/logs/setup-stage-timings.log) covers post-deploy
	# scheduler setup — the same visibility _setup_run_non_interactive has.

	# Auto-update handles non-interactive internally (systemd detection fixed in GH#17861)
	_time_step "setup_auto_update" setup_auto_update
	if _should_setup_noninteractive_supervisor_pulse; then
		_time_step "$SETUP_STAGE_PULSE" setup_supervisor_pulse "$os"
	fi
	# t2939: pulse-watchdog (independent revival mechanism). Always installed
	# alongside the pulse — it is a no-op when pulse is disabled. Skipping the
	# `_should_setup_noninteractive_*` guard intentionally: this is layered
	# defense, the cost of installing it is one plist file, and the user opts
	# in by enabling the pulse itself.
	_time_step "setup_pulse_watchdog" setup_pulse_watchdog "${PULSE_ENABLED:-}"
	# Regenerate other schedulers if already installed (GH#17695 Finding B).
	# Stats wrapper is a pulse dependency — also install on first run when
	# the supervisor pulse is consented (t2418, GH#20016).
	if _should_setup_noninteractive_stats_wrapper; then
		_time_step "setup_stats_wrapper" setup_stats_wrapper "${PULSE_ENABLED:-}"
	fi
	if _should_setup_noninteractive_scheduler "Failure miner" "sh.aidevops.routine-gh-failure-miner" "aidevops: gh-failure-miner" "aidevops-gh-failure-miner"; then
		_time_step "setup_failure_miner" setup_failure_miner "${PULSE_ENABLED:-}"
	fi
	if _should_setup_noninteractive_scheduler "Process guard" "sh.aidevops.process-guard" "aidevops: process-guard" "aidevops-process-guard"; then
		_time_step "setup_process_guard" setup_process_guard
	fi
	if _should_setup_noninteractive_scheduler "Memory pressure" "sh.aidevops.memory-pressure-monitor" "aidevops: memory-pressure-monitor" "aidevops-memory-pressure-monitor"; then
		_time_step "setup_memory_pressure_monitor" setup_memory_pressure_monitor
	fi
	if _should_setup_noninteractive_scheduler "Screen time" "sh.aidevops.screen-time-snapshot" "aidevops: screen-time-snapshot" "aidevops-screen-time-snapshot"; then
		_time_step "setup_screen_time_snapshot" setup_screen_time_snapshot
	fi
	if _should_setup_noninteractive_scheduler "Contribution watch" "sh.aidevops.contribution-watch" "aidevops: contribution-watch" "aidevops-contribution-watch"; then
		_time_step "setup_contribution_watch" setup_contribution_watch
	fi
	# t2903 (#21049): complexity scan — extracted from pulse dispatch preflight.
	# GH#24841: use a pulse-dependency escape hatch so non-interactive updates
	# backfill the standalone timer for existing pulse-enabled installs.
	if _should_setup_noninteractive_complexity_scan; then
		_time_step "setup_complexity_scan" setup_complexity_scan
	fi
	# t2862 (GH#20919): pulse merge routine — fast 120s standalone merge pass.
	# t3036 (GH#21616): use the pulse-dependency escape hatch instead of the
	# generic chicken-and-egg gate so the routine installs on existing systems
	# whenever the supervisor pulse is consented.
	if _should_setup_noninteractive_pulse_merge_routine; then
		_time_step "setup_pulse_merge_routine" _setup_run_noncritical_stage_bounded "Pulse merge routine setup" "${AIDEVOPS_SETUP_PULSE_MERGE_ROUTINE_TIMEOUT:-30}" setup_pulse_merge_routine
	fi
	# t2932 (GH#21125): peer productivity monitor — adaptive cross-runner
	# dispatch coordination, runs every 30 min.
	if _should_setup_noninteractive_scheduler "Peer productivity monitor" "sh.aidevops.peer-productivity-monitor" "aidevops: peer-productivity-monitor" "aidevops-peer-productivity-monitor"; then
		_time_step "setup_peer_productivity_monitor" setup_peer_productivity_monitor
	fi
	# Repo sync handles non-interactive mode internally (systemd detection fixed in GH#17861)
	_time_step "setup_repo_sync" setup_repo_sync
	# r914 repo-aidevops-health — daily drift keeper (t2366)
	_time_step "setup_repo_aidevops_health" setup_repo_aidevops_health
	if _should_setup_noninteractive_scheduler "Profile README" "sh.aidevops.profile-readme-update" "aidevops: profile-readme-update" "aidevops-profile-readme-update"; then
		_time_step "setup_profile_readme" setup_profile_readme
	fi
	if _should_setup_noninteractive_scheduler "OAuth token refresh" "sh.aidevops.token-refresh" "aidevops: token-refresh" "aidevops-token-refresh"; then
		_time_step "setup_oauth_token_refresh" setup_oauth_token_refresh
	fi
	# opencode DB maintenance (r913, t2183). Helper self-noops on missing
	# DB — safe to install unconditionally in non-interactive mode too.
	_time_step "setup_opencode_db_maintenance" setup_opencode_db_maintenance
	# opencode DB archive/VACUUM (GH#25136). Dedicated low-priority scheduler;
	# not tied to pulse preflight cadence.
	_time_step "setup_opencode_db_archive" setup_opencode_db_archive
	# Migrate cron entries to systemd after schedulers are installed (GH#17695 Finding D)
	_time_step "migrate_cron_to_systemd" migrate_cron_to_systemd
	_time_step "$SETUP_STAGE_TABBY" setup_tabby
	return 0
}

_setup_post_setup_steps() {
	local os="$1"

	# Non-interactive mode still has post-deploy scheduler and pulse-restart
	# work to do. Do not print the human "Setup complete!" marker until those
	# bounded postflight steps and the final child-process drain have finished;
	# callers treat that line as a completion signal.
	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		_setup_noninteractive_schedulers "$os"
		return 0
	fi

	# Print setup summary before final success message (GH#5240)
	print_setup_summary

	echo ""
	print_success "Setup complete!"

	# Cache client request format constants if CLI is installed (~50ms)
	if command -v claude &>/dev/null && [[ -x "${INSTALL_DIR}/.agents/scripts/cch-extract.sh" ]]; then
		"${INSTALL_DIR}/.agents/scripts/cch-extract.sh" --cache >/dev/null 2>&1 || true
	else
		echo ""
		echo -e "${YELLOW}[TIP]${NC} Install Claude CLI for automatic request format alignment:"
		echo "      npm install -g @anthropic-ai/claude-code"
	fi

	# Post-setup: auto-update, schedulers, final instructions (GH#5793)
	setup_auto_update
	setup_supervisor_pulse "$os"
	# t2939: pulse-watchdog — independent revival mechanism, layered defense.
	setup_pulse_watchdog "${PULSE_ENABLED:-}"
	setup_stats_wrapper "${PULSE_ENABLED:-}"
	setup_failure_miner "${PULSE_ENABLED:-}"
	setup_repo_sync
	# r914 repo-aidevops-health — daily drift keeper (t2366)
	setup_repo_aidevops_health
	setup_process_guard
	setup_memory_pressure_monitor
	setup_screen_time_snapshot
	setup_contribution_watch
	setup_complexity_scan
	setup_pulse_merge_routine
	setup_peer_productivity_monitor
	setup_draft_responses
	setup_profile_readme
	setup_oauth_token_refresh
	setup_opencode_db_maintenance
	setup_opencode_db_archive
	# Migrate cron entries to systemd after schedulers are installed (GH#17695 Finding D)
	migrate_cron_to_systemd
	setup_tabby
	print_final_instructions

	# Check for tool updates if --update flag was passed
	if [[ "$UPDATE_TOOLS_MODE" == "true" ]]; then
		echo ""
		check_tool_updates
	fi

	setup_onboarding_prompt
	return 0
}

_setup_restart_pulse_if_running() {
	# Reconcile only after scheduler setup has established the effective consent
	# state. The activated helper serializes with deployment, resolves the active
	# immutable bundle under that lock, and never starts behind a disabled
	# supervisor. This also prevents a stale setup caller's INSTALL_DIR from
	# selecting the Pulse revision.
	if [[ "${AIDEVOPS_SKIP_PULSE_RESTART:-0}" == "1" ]]; then
		return 0
	fi

	local activated_root="${_AIDEVOPS_ACTIVE_BUNDLE_ROOT:-}"
	local current_root=""
	local pin_rc=0
	local pulse_active_link="${HOME}/.aidevops/agents"
	local managed_enabled="${PULSE_ENABLED:-}"
	local configured_pulse_consent=""
	if [[ "$managed_enabled" != "true" && "$managed_enabled" != "false" ]]; then
		if type _resolve_pulse_consent >/dev/null 2>&1; then
			configured_pulse_consent=$(_resolve_pulse_consent)
		fi
		case "$(printf '%s' "$configured_pulse_consent" | tr '[:upper:]' '[:lower:]')" in
		true) managed_enabled=true ;;
		*) managed_enabled=false ;;
		esac
	fi
	if current_root=$(pulse_runtime_pin_resolve 2>/dev/null); then
		activated_root="$current_root"
		pulse_active_link="$current_root"
	else
		pin_rc=$?
		case "$pin_rc" in
		1 | 3)
			if current_root=$(resolve_aidevops_runtime_bundle_root "${HOME}/.aidevops/agents"); then
				activated_root="$current_root"
			fi
			;;
		*)
			print_error "Pulse reconciliation refused an invalid runtime pin; clear or repair the private pin file"
			return 1
			;;
		esac
	fi
	if [[ -z "$activated_root" ]]; then
		print_error "Pulse reconciliation failed because the activated runtime bundle could not be resolved"
		return 1
	fi
	if ! _restart_pulse_if_running \
		"$activated_root" \
		"$managed_enabled" \
		"$pulse_active_link"; then
		print_error "Pulse reconciliation failed; setup cannot verify the activated runtime bundle"
		return 1
	fi
	return 0
}

_setup_print_noninteractive_success() {
	# Ensure every tracked or discovered child has either exited or been
	# intentionally terminated before emitting the caller-visible success line.
	_setup_cleanup_noninteractive_children
	print_setup_summary
	echo ""
	print_success "Setup complete!"
	return 0
}

# Print the completion sentinel. This is the canonical "setup.sh finished all
# phases" marker — any caller that needs to detect silent early-termination
# (e.g., t2022-class bugs where a sourced helper's set -e propagates a
# readonly assignment failure and kills the parent) should grep log output
# for the literal "[SETUP_COMPLETE]" prefix.
#
# Format is intentionally stable and parseable. Do NOT add human-readable
# decoration or move this function without updating:
#   .agents/scripts/verify-setup-log.sh       (the consumer)
#   tests/test-setup-completion-sentinel.sh   (the contract guard)
#
# GH#18492 / t2026.
print_setup_complete_sentinel() {
	local _version="unknown"
	if [[ -r "${INSTALL_DIR}/VERSION" ]]; then
		_version="$(head -n1 "${INSTALL_DIR}/VERSION" 2>/dev/null || printf 'unknown')"
	fi
	local _mode="non-interactive"
	[[ "${NON_INTERACTIVE:-false}" != "true" ]] && _mode="interactive"
	printf '[SETUP_COMPLETE] aidevops setup.sh v%s finished all phases (mode=%s)\n' \
		"$_version" "$_mode"
	return 0
}

# Main setup function — orchestrates init, mode dispatch, and post-setup.
main() {
	# Bootstrap first (handles curl install)
	bootstrap_repo "$@"

	parse_args "$@"
	local _os
	_os="$(uname -s)"

	# Auto-detect non-interactive terminals (CI/CD, agent shells, piped stdin)
	# Must run after parse_args so explicit --interactive flag takes precedence
	if [[ "$INTERACTIVE_MODE" != "true" && ! -t 0 ]]; then
		NON_INTERACTIVE=true
	fi

	# Guard: --interactive and --non-interactive are mutually exclusive
	if [[ "$INTERACTIVE_MODE" == "true" && "$NON_INTERACTIVE" == "true" ]]; then
		print_error "--interactive and --non-interactive cannot be used together"
		exit 1
	fi

	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		# Full-loop release deployment uses this mutex. It remains held through
		# deploy_aidevops_agents and install_aidevops_cli, so agent and CLI
		# convergence are one serialized non-interactive deployment interval.
		# Direct interactive setup is intentionally outside this guarantee: holding
		# the mutex across prompts can block unattended full-loop deployments.
		_setup_acquire_noninteractive_setup_lock "$@" || exit $?
	fi

	_setup_print_header

	# GH#18950 (t2087): bash 3.2 → modern bash upgrade check. Runs before
	# the main setup flow so the user sees the prompt early. Fail-open —
	# never blocks setup even if bash install fails.
	_setup_check_bash_upgrade

	if [[ -n "$SETUP_STAGE" ]]; then
		_setup_run_scoped_stage "$_os"
	elif [[ "$NON_INTERACTIVE" == "true" ]]; then
		_setup_run_non_interactive
	else
		_setup_run_interactive
	fi

	if [[ -z "$SETUP_STAGE" ]]; then
		_setup_post_setup_steps "$_os"
	fi

	_setup_restart_pulse_if_running

	if [[ "$NON_INTERACTIVE" == "true" ]]; then
		_setup_print_noninteractive_success
	fi

	# GH#18492 / t2026: completion sentinel. Must be the last output of a
	# successful run — any silent early-termination will leave this absent
	# from the log. Consumed by .agents/scripts/verify-setup-log.sh and
	# enforced as the regression contract by
	# tests/test-setup-completion-sentinel.sh.
	print_setup_complete_sentinel

	return 0
}

# Run setup
main "$@"
