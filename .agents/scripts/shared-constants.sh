#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2089,SC2090

# Shared Constants for AI DevOps Framework Provider Scripts
# This file contains common strings, error messages, and configuration constants
# to reduce duplication and improve maintainability across provider scripts.
#
# Usage: source .agents/scripts/shared-constants.sh
#
# Author: AI DevOps Framework
# Version: 1.6.0

# cool — include guard prevents readonly errors when sourced multiple times
[[ -n "${_SHARED_CONSTANTS_LOADED:-}" ]] && return 0
_SHARED_CONSTANTS_LOADED=1

# =============================================================================
# GH#18950 (t2087): Bash 3.2 → bash 4+ runtime re-exec self-heal guard.
# =============================================================================
# macOS ships /bin/bash 3.2.57 which has parser and set-e propagation bugs
# (GH#18770, GH#18784, GH#18786, GH#18804, GH#18830). If this shared file
# is sourced by a script running under bash < 4 AND a modern bash is
# available at a known location, re-exec the calling script under the
# modern bash. Transparent self-heal: the script runs from the top again
# under the new interpreter, passes this guard (now on bash 4+), and
# continues normally.
#
# Guard order matters: this MUST run before any bash 4+ constructs in
# this file. It also runs AFTER the include guard to avoid re-execing
# the same script multiple times through nested sources.
#
# Chicken-and-egg avoidance:
#   - setup.sh itself does NOT source shared-constants.sh at the top; it
#     can't, because it's the thing that installs modern bash.
#   - bash-upgrade-helper.sh does NOT source shared-constants.sh either;
#     it's the detector that this guard queries.
#   - AIDEVOPS_BASH_REEXECED=1 is set before exec to prevent infinite
#     loops if a symlink points at the wrong binary.
#   - BASH_SOURCE[1] is the immediate caller; if unset, we're being
#     executed directly (e.g., `bash shared-constants.sh`) and skip
#     the guard. The guard walks the BASH_SOURCE stack to find the
#     OUTERMOST caller (the top-level script) rather than using [1],
#     so the re-exec targets the correct entry point even when sourced
#     via intermediate helpers (GH#19632 / t2176).
if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]] &&
	[[ -z "${AIDEVOPS_BASH_REEXECED:-}" ]] &&
	[[ -n "${BASH_SOURCE[1]:-}" ]]; then
	# Walk BASH_SOURCE[] to find the outermost caller, not just
	# BASH_SOURCE[1] (the immediate caller). When sourced via an
	# intermediate helper (e.g. pulse-wrapper→config-helper→shared-constants),
	# BASH_SOURCE[1] points to the intermediate, and exec-ing it would
	# replace the top-level script with a standalone run of the helper.
	# The outermost caller is the last element in the BASH_SOURCE array.
	# Bash 3.2 does not support negative indices (${arr[-1]}), so iterate.
	# (GH#19632 / t2176)
	_aidevops_top_caller=""
	for _aidevops_src in "${BASH_SOURCE[@]}"; do
		_aidevops_top_caller="$_aidevops_src"
	done
	unset _aidevops_src
	# Safety: skip if outermost caller is this file itself (direct execution
	# of shared-constants.sh, which has no useful main).
	if [[ "$_aidevops_top_caller" != "${BASH_SOURCE[0]}" ]]; then
		_aidevops_macos_platform="$(printf '\104\141\162\167\151\156')"
		_aidevops_bash_candidates="/opt/homebrew/bin/bash /usr/local/bin/bash"
		if [[ "$(uname -s 2>/dev/null || true)" != "$_aidevops_macos_platform" ]]; then
			_aidevops_bash_candidates="${_aidevops_bash_candidates} /home/linuxbrew/.linuxbrew/bin/bash"
		fi
		_aidevops_path_bash="$(command -v bash 2>/dev/null || true)"
		[[ -n "$_aidevops_path_bash" ]] && _aidevops_bash_candidates="${_aidevops_bash_candidates} ${_aidevops_path_bash}"
		for _aidevops_bash_candidate in $_aidevops_bash_candidates; do
			if [[ -n "$_aidevops_bash_candidate" && -f "$_aidevops_bash_candidate" && -x "$_aidevops_bash_candidate" && "$_aidevops_bash_candidate" != "/bin/bash" ]]; then
				export AIDEVOPS_BASH_REEXECED=1
				exec "$_aidevops_bash_candidate" "$_aidevops_top_caller" "$@"
			fi
		done
		unset _aidevops_bash_candidate _aidevops_bash_candidates _aidevops_path_bash _aidevops_macos_platform
	fi
	unset _aidevops_top_caller
	# Fall through: no modern bash found. The calling script will run
	# on bash 3.2 and may hit compat bugs. The aidevops update check
	# will surface an advisory on the next cycle (bash-upgrade-helper.sh
	# update-check, rate-limited to 24h).
fi

# t2201: Clear AIDEVOPS_BASH_REEXECED once we are stably on bash 4+. The
# re-exec guard exports this flag before `exec` to prevent its own
# infinite loop, but without this cleanup the flag persists in the
# environment of every child process. If any child is then spawned
# under /bin/bash 3.2 (e.g. an explicit `/bin/bash script.sh` call, or
# PATH mis-ordering that resolves `#!/usr/bin/env bash` to 3.2), THAT
# child's guard sees AIDEVOPS_BASH_REEXECED=1 and short-circuits the
# re-exec — leaving the grandchild running bash 3.2 and hitting any
# bash 4+ construct as a runtime error. Clearing the flag only when
# BASH_VERSINFO[0] >= 4 preserves the anti-infinite-loop property for
# the fallthrough branch (no modern bash found, still on 3.2) while
# ensuring fresh subprocess invocations get a clean guard decision.
if [[ "${BASH_VERSINFO[0]:-0}" -ge 4 ]]; then
	unset AIDEVOPS_BASH_REEXECED
fi

# Generate a non-authority execution identifier for telemetry correlation.
# Lease/claim tokens are fencing credentials and must never double as public IDs.
aidevops_generate_execution_id() {
	local prefix="$1"
	local identifier=""
	[[ -n "$prefix" ]] || prefix="execution"
	if command -v uuidgen >/dev/null 2>&1; then
		identifier=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]') || identifier=""
	elif command -v python3 >/dev/null 2>&1; then
		identifier=$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null) || identifier=""
	fi
	if [[ -z "$identifier" ]]; then
		identifier="$(date +%s 2>/dev/null || printf '0')-$$-${RANDOM:-0}"
	fi
	printf '%s:%s' "$prefix" "$identifier"
	return 0
}

# Ensure standalone pulse-adjacent runners have the elapsed-time baseline that
# pulse-wrapper.sh normally exports. Helpers that create GitHub comments/issues
# use PULSE_START_EPOCH for signature footers; launchd/cron runners that source
# pulse libraries directly need the same safe default under `set -u`.
aidevops_ensure_pulse_start_epoch() {
	local fallback_epoch=""

	if [[ "${PULSE_START_EPOCH:-}" =~ ^[0-9]+$ ]]; then
		export PULSE_START_EPOCH
		return 0
	fi

	fallback_epoch=$(date +%s 2>/dev/null || printf '0')
	[[ "$fallback_epoch" =~ ^[0-9]+$ ]] || fallback_epoch=0
	PULSE_START_EPOCH="$fallback_epoch"
	export PULSE_START_EPOCH
	return 0
}

# Keep a symlink pointed at the requested target without replacing an already
# correct link. Recreating an unchanged executable symlink can make macOS treat
# a recurring LaunchAgent as a newly added background item.
aidevops_ensure_symlink_target() {
	local target="$1"
	local link_path="$2"
	local current_target=""
	local link_tmp="${link_path}.tmp.$$"
	local darwin_platform=""
	darwin_platform="$(printf '\104\141\162\167\151\156')"

	if [[ -L "$link_path" ]]; then
		current_target=$(readlink "$link_path" 2>/dev/null) || current_target=""
		if [[ "$current_target" == "$target" ]]; then
			return 0
		fi
	fi

	rm -f "$link_tmp" || return 1
	ln -s "$target" "$link_tmp" || return 1
	if [[ "$(uname -s 2>/dev/null || true)" == "$darwin_platform" ]]; then
		mv -f -h "$link_tmp" "$link_path" || {
			rm -f "$link_tmp"
			return 1
		}
	else
		mv -Tf "$link_tmp" "$link_path" || {
			rm -f "$link_tmp"
			return 1
		}
	fi
	return 0
}

# =============================================================================
# Tool Version Pins
# =============================================================================
# Pin a tool to a specific version to prevent auto-upgrade to a broken release.
# Set to "latest" to resume tracking upstream. Grep for the variable name to
# find all consumers that need updating when unpinning.

# GH#28766: OpenCode 1.18.7 stalled Linux headless workers while bootstrapping
# location services with an isolated XDG_DATA_HOME. GH#28892 advanced the pin
# after 1.18.9 passed the isolated Linux-headless canary; GH#29964 promoted
# 1.18.16 after a credential-free same-revision baseline comparison; GH#30393
# promoted 1.18.18 after making that comparison self-contained. Keep the complete
# compatibility decision visible and machine-readable; general installs track
# latest because the observed failure scope is Linux headless.
readonly OPENCODE_PINNED_VERSION="1.18.18"
readonly OPENCODE_PIN_REASON="GH#28766 Linux headless bootstrap stalled with isolated XDG_DATA_HOME"
readonly OPENCODE_PIN_PLATFORM="Linux"
readonly OPENCODE_PIN_RUNTIME_MODE="headless"
readonly OPENCODE_PIN_INTRODUCED_DATE="2026-07-30"
readonly OPENCODE_PIN_LAST_CANARY_DATE="2026-08-19"
readonly OPENCODE_PIN_LAST_CANARY_RESULT="pass:1.18.18"
readonly OPENCODE_PIN_REVIEW_DEADLINE="2026-08-26"
readonly OPENCODE_PLUGIN_TESTED_VERSION="1.18.18"

aidevops_opencode_pin_applies() {
	local platform="${1:-$(uname -s 2>/dev/null || printf 'unknown')}"
	local runtime_mode="${2:-interactive}"
	[[ "$platform" == "$OPENCODE_PIN_PLATFORM" && "$runtime_mode" == "$OPENCODE_PIN_RUNTIME_MODE" ]]
}

# Build the package-manager-aware OpenCode repair command used by both routine
# tool updates and the fail-closed headless version guard. The optional
# AIDEVOPS_OPENCODE_BIN environment variable lets callers preserve an already
# resolved binary path that is not present on PATH.
aidevops_opencode_upgrade_command() {
	local pkg_version="$1"

	# shellcheck disable=SC2016  # Single quotes intentional: bash -c payload
	printf '%s' \
		'r="${AIDEVOPS_OPENCODE_BIN:-}"; [[ -n "$r" ]] || r=$(command -v opencode 2>/dev/null || printf ""); ' \
		'if [[ -n "$r" ]]; then ' \
		'if command -v brew >/dev/null 2>&1; then ' \
		'r_dir=$(cd "$(dirname "$r")" 2>/dev/null && pwd -P || printf ""); ' \
		'r_link=$(readlink "$r" 2>/dev/null || printf ""); r_real="$r"; ' \
		'if [[ -n "$r_link" ]]; then case "$r_link" in /*) r_real="$r_link" ;; *) r_real="$r_dir/$r_link" ;; esac; fi; ' \
		'r_real_dir=$(cd "$(dirname "$r_real")" 2>/dev/null && pwd -P || printf ""); ' \
		'brew_formula_real=""; ' \
		'if brew list --versions opencode >/dev/null 2>&1; then ' \
		'brew_formula=$(brew --prefix opencode 2>/dev/null || printf ""); ' \
		'[[ -d "$brew_formula" ]] && brew_formula_real=$(cd "$brew_formula" && pwd -P || printf ""); ' \
		'fi; ' \
		'if [[ -n "$brew_formula_real" ]] && { [[ "$r_dir" == "$brew_formula_real"/* ]] || [[ "$r_real_dir" == "$brew_formula_real"/* ]]; }; then ' \
		'brew upgrade opencode || brew reinstall opencode; exit $?; ' \
		'fi; fi; ' \
		'if [[ "$r" == *bun* ]]; then bun install -g opencode-ai@'"${pkg_version}"'; else npm install -g opencode-ai@'"${pkg_version}"'; fi; ' \
		'else printf "OpenCode binary not found for repair\\n" >&2; exit 1; fi'
	return 0
}

# Minimum GitHub CLI version required for `gh api --paginate --slurp`.
# Older distro packages can parse `gh` as installed while dispatch paths fail
# closed with `unknown flag: --slurp`.
readonly AIDEVOPS_GH_MIN_SLURP_VERSION="2.51.0"

aidevops_parse_semver() {
	local input="$1"
	local parsed=""
	parsed=$(printf '%s\n' "$input" | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1 || true)
	if [[ -z "$parsed" ]]; then
		return 1
	fi
	if [[ "$parsed" =~ ^[0-9]+\.[0-9]+$ ]]; then
		parsed="${parsed}.0"
	fi
	printf '%s\n' "$parsed"
	return 0
}

aidevops_version_at_least() {
	local current="$1"
	local minimum="$2"
	local current_major current_minor current_patch
	local minimum_major minimum_minor minimum_patch
	IFS='.' read -r current_major current_minor current_patch <<<"$current"
	IFS='.' read -r minimum_major minimum_minor minimum_patch <<<"$minimum"
	current_major="${current_major:-0}"
	current_minor="${current_minor:-0}"
	current_patch="${current_patch:-0}"
	minimum_major="${minimum_major:-0}"
	minimum_minor="${minimum_minor:-0}"
	minimum_patch="${minimum_patch:-0}"
	[[ "$current_major$current_minor$current_patch$minimum_major$minimum_minor$minimum_patch" =~ ^[0-9]+$ ]] || return 1
	if ((current_major > minimum_major)); then
		return 0
	fi
	if ((current_major < minimum_major)); then
		return 1
	fi
	if ((current_minor > minimum_minor)); then
		return 0
	fi
	if ((current_minor < minimum_minor)); then
		return 1
	fi
	if ((current_patch >= minimum_patch)); then
		return 0
	fi
	return 1
}

aidevops_gh_installed_version() {
	local output=""
	if ! command -v gh >/dev/null 2>&1; then
		return 1
	fi
	output=$(gh --version 2>/dev/null || true)
	aidevops_parse_semver "$output"
	return $?
}

aidevops_gh_slurp_supported() {
	local installed=""
	installed=$(aidevops_gh_installed_version) || return 1
	aidevops_version_at_least "$installed" "$AIDEVOPS_GH_MIN_SLURP_VERSION"
	return $?
}

aidevops_gh_slurp_status_message() {
	local installed=""
	if ! command -v gh >/dev/null 2>&1; then
		printf 'GitHub CLI (gh) is not installed; gh api --paginate --slurp requires gh >= %s. %s' \
			"$AIDEVOPS_GH_MIN_SLURP_VERSION" "$(aidevops_gh_slurp_remediation_guidance)"
		return 0
	fi
	installed=$(aidevops_gh_installed_version) || installed="unknown"
	if [[ "$installed" == "unknown" ]]; then
		printf 'GitHub CLI (gh) version could not be parsed; gh api --paginate --slurp requires gh >= %s; gh --version output is malformed or empty. %s' \
			"$AIDEVOPS_GH_MIN_SLURP_VERSION" "$(aidevops_gh_slurp_remediation_guidance "$installed")"
		return 0
	fi
	if aidevops_version_at_least "$installed" "$AIDEVOPS_GH_MIN_SLURP_VERSION"; then
		printf 'GitHub CLI (gh) detected version %s supports gh api --paginate --slurp (minimum required %s)' \
			"$installed" "$AIDEVOPS_GH_MIN_SLURP_VERSION"
		return 0
	fi
	printf 'GitHub CLI (gh) detected version %s is too old; gh api --paginate --slurp requires gh >= %s. %s' \
		"$installed" "$AIDEVOPS_GH_MIN_SLURP_VERSION" "$(aidevops_gh_slurp_remediation_guidance "$installed")"
	return 0
}

aidevops_gh_slurp_remediation_guidance() {
	local installed="${1:-}"
	if [[ "$installed" == "unknown" ]]; then
		printf 'On Ubuntu/Debian, fix or upgrade the existing gh installation from the official GitHub CLI package repository rather than the Ubuntu universe package, then rerun aidevops status.'
	elif [[ -n "$installed" ]]; then
		printf 'On Ubuntu/Debian, avoid apt-pinned Ubuntu universe gh packages such as %s; install or upgrade from the official GitHub CLI package repository, then rerun aidevops status.' \
			"$installed"
	else
		printf 'On Ubuntu/Debian, use the official GitHub CLI package repository rather than the Ubuntu universe package, then rerun aidevops status.'
	fi
	return 0
}

aidevops_gh_slurp_remediation_hint() {
	local os_name=""
	os_name=$(uname -s 2>/dev/null || printf 'unknown')
	case "$os_name" in
	Linux)
		printf 'Run aidevops setup to upgrade gh, or install GitHub CLI from the official package source for your distribution.'
		;;
	Darwin)
		printf 'Run brew update && brew upgrade gh, then rerun aidevops status.'
		;;
	*)
		printf 'Upgrade gh to >= %s, then rerun aidevops status.' "$AIDEVOPS_GH_MIN_SLURP_VERSION"
		;;
	esac
	return 0
}

aidevops_gh_slurp_warning_line() {
	local status_message=""
	status_message=$(aidevops_gh_slurp_status_message)
	printf '[WARN] GitHub CLI prerequisite: %s' "$status_message"
	return 0
}

# =============================================================================
# HTTP and API Constants
# =============================================================================

readonly CONTENT_TYPE_JSON="Content-Type: application/json"
readonly CONTENT_TYPE_FORM="Content-Type: application/x-www-form-urlencoded"
readonly USER_AGENT="User-Agent: AI-DevOps-Framework/1.6.0"
readonly AUTH_HEADER_PREFIX="Authorization: Bearer"

# =============================================================================
# Common Help Text Labels
# =============================================================================

readonly HELP_LABEL_COMMANDS="Commands:"
readonly HELP_LABEL_EXAMPLES="Examples:"
readonly HELP_LABEL_OPTIONS="Options:"
readonly HELP_LABEL_USAGE="Usage:"

# HTTP Status Codes
readonly HTTP_OK=200
readonly HTTP_CREATED=201
readonly HTTP_BAD_REQUEST=400
readonly HTTP_UNAUTHORIZED=401
readonly HTTP_FORBIDDEN=403
readonly HTTP_NOT_FOUND=404
readonly HTTP_INTERNAL_ERROR=500

# =============================================================================
# Common Error Messages
# =============================================================================

readonly ERROR_CONFIG_NOT_FOUND="Configuration file not found"
readonly ERROR_INPUT_FILE_NOT_FOUND="Input file not found"
readonly ERROR_INPUT_FILE_REQUIRED="Input file is required"
readonly ERROR_REPO_NAME_REQUIRED="Repository name is required"
readonly ERROR_DOMAIN_NAME_REQUIRED="Domain name is required"
readonly ERROR_ACCOUNT_NAME_REQUIRED="Account name is required"
readonly ERROR_INSTANCE_NAME_REQUIRED="Instance name is required"
readonly ERROR_PROJECT_NOT_FOUND="Project not found in configuration"
readonly ERROR_UNKNOWN_COMMAND="Unknown command"
readonly ERROR_UNKNOWN_PLATFORM="Unknown platform"
readonly ERROR_PERMISSION_DENIED="Permission denied"
readonly ERROR_NETWORK_UNAVAILABLE="Network unavailable"
readonly ERROR_API_KEY_MISSING="API key is missing or invalid"
readonly ERROR_INVALID_CREDENTIALS="Invalid credentials"

# =============================================================================
# Success Messages
# =============================================================================

readonly SUCCESS_REPO_CREATED="Repository created successfully"
readonly SUCCESS_DEPLOYMENT_COMPLETE="Deployment completed successfully"
readonly SUCCESS_CONFIG_UPDATED="Configuration updated successfully"
readonly SUCCESS_BACKUP_CREATED="Backup created successfully"
readonly SUCCESS_CONNECTION_ESTABLISHED="Connection established successfully"
readonly SUCCESS_OPERATION_COMPLETE="Operation completed successfully"

# =============================================================================
# Common Usage Patterns
# =============================================================================

readonly USAGE_PATTERN="Usage: \$0 [command] [options]"
readonly HELP_PATTERN="Use '\$0 help' for more information"
readonly CONFIG_PATTERN="Edit configuration file: \$CONFIG_FILE"

# =============================================================================
# File and Directory Patterns
# =============================================================================

readonly BACKUP_SUFFIX=".backup"
readonly LOG_SUFFIX=".log"
readonly CONFIG_SUFFIX=".json"
readonly TEMPLATE_SUFFIX=".txt"
readonly TEMP_PREFIX="tmp_"

# =============================================================================
# launchd PATH hygiene
# =============================================================================
# Build a PATH value safe to embed in macOS LaunchAgent EnvironmentVariables.
# launchd jobs inherit no useful interactive shell setup, but serialising the
# caller's raw PATH bakes stale manager-specific entries into long-lived plists.
# Keep stable user and known system/tool roots first, then preserve inherited
# entries that exist on this host. Never persist immutable runtime-bundle paths:
# long-lived sessions intentionally retain old bundles after stable activation.

_aidevops_append_launchd_path_dir() {
	local dir="$1"
	[[ -n "$dir" ]] || return 0
	case "$dir" in
	*/.aidevops/runtime-bundles/*) return 0 ;;
	esac
	[[ -d "$dir" ]] || return 0
	case ":${_aidevops_launchd_path_seen:-}:" in
	*":${dir}:"*) return 0 ;;
	esac
	_aidevops_launchd_path_seen="${_aidevops_launchd_path_seen:+${_aidevops_launchd_path_seen}:}${dir}"
	_aidevops_launchd_path_result="${_aidevops_launchd_path_result:+${_aidevops_launchd_path_result}:}${dir}"
	return 0
}

aidevops_launchd_sanitized_path() {
	local input_path="${1:-${PATH:-}}"
	local stable_path=""
	if [[ -n "${HOME:-}" ]]; then
		stable_path="${HOME}/.bun/bin:${HOME}/.local/bin:${HOME}/.aidevops/agents/scripts:${HOME}/.aidevops/bin"
	fi
	local default_path="${stable_path:+${stable_path}:}/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
	local _aidevops_launchd_path_result=""
	local _aidevops_launchd_path_seen=""
	local dir=""
	local IFS=':'

	for dir in $default_path; do
		_aidevops_append_launchd_path_dir "$dir"
	done
	for dir in $input_path; do
		_aidevops_append_launchd_path_dir "$dir"
	done

	printf '%s' "$_aidevops_launchd_path_result"
	return 0
}

# =============================================================================
# Credentials File Security
# =============================================================================
# Shared utility for ensuring credentials files have secure permissions.
# All scripts that write to credentials.sh MUST call ensure_credentials_file
# before their first write to guarantee 0600 permissions on the file and
# 0700 on the parent directory.
#
# Usage:
#   ensure_credentials_file "$CREDENTIALS_FILE"
#   echo "export KEY=\"value\"" >> "$CREDENTIALS_FILE"

readonly CREDENTIALS_DIR_PERMS="700"
readonly CREDENTIALS_FILE_PERMS="600"

# Ensure credentials file exists with secure permissions (0600).
# Creates parent directory with 0700 if missing.
# Idempotent: safe to call multiple times.
# Arguments:
#   $1 - path to credentials file (required)
ensure_credentials_file() {
	local cred_file="$1"

	if [[ -z "$cred_file" ]]; then
		print_shared_error "ensure_credentials_file: file path required"
		return 1
	fi

	local cred_dir
	cred_dir="$(dirname "$cred_file")"

	# Ensure parent directory exists with restricted permissions
	if [[ ! -d "$cred_dir" ]]; then
		mkdir -p "$cred_dir"
		chmod "$CREDENTIALS_DIR_PERMS" "$cred_dir"
	fi

	# Create file if it doesn't exist
	if [[ ! -f "$cred_file" ]]; then
		: >"$cred_file"
	fi

	# Enforce 0600 regardless of current permissions
	chmod "$CREDENTIALS_FILE_PERMS" "$cred_file" 2>/dev/null || true

	return 0
}

# =============================================================================
# Pattern Tracking Constants
# =============================================================================
# All pattern-related memory types (dedicated + supervisor-generated)
# Used by memory/_common.sh migrate_db backfill (pattern-tracker-helper.sh archived)
# TIER_DOWNGRADE_OK: evidence that a cheaper model tier succeeded on a task type (t5148)
readonly PATTERN_TYPES_SQL="'SUCCESS_PATTERN','FAILURE_PATTERN','WORKING_SOLUTION','FAILED_APPROACH','ERROR_FIX','TIER_DOWNGRADE_OK'"

# =============================================================================
# Common Validation Patterns
# =============================================================================

readonly DOMAIN_REGEX="^[a-zA-Z0-9][a-zA-Z0-9-]{1,61}[a-zA-Z0-9]\.[a-zA-Z]{2,}$"
readonly EMAIL_REGEX="^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$"
readonly IP_REGEX="^([0-9]{1,3}\.){3}[0-9]{1,3}$"
readonly PORT_REGEX="^[0-9]{1,5}$"

# =============================================================================
# Common Timeouts and Limits
# =============================================================================

readonly DEFAULT_TIMEOUT=30
readonly LONG_TIMEOUT=300
readonly SHORT_TIMEOUT=10
readonly MAX_RETRIES=3
readonly DEFAULT_PORT=80
readonly SECURE_PORT=443

# =============================================================================
# Supervisor Task Status SQL Fragments
# =============================================================================
# Keep frequently reused status lists in one place to avoid drift between
# supervisor modules.

# Terminal states for TODO/DB reconciliation checks.
readonly TASK_RECONCILIATION_TERMINAL_STATES_SQL="'complete', 'deployed', 'verified', 'verify_failed', 'failed', 'blocked', 'cancelled'"

# States treated as non-active when checking sibling in-flight limits.
readonly TASK_SIBLING_NON_ACTIVE_STATES_SQL="'verified','cancelled','deployed','complete','failed','blocked','queued'"

# =============================================================================
# Credential Sanitization (t2458)
# =============================================================================
# Defense against credential-bearing text leaking into stdout/stderr/logs.
# The primary leak vector is `git remote get-url origin` when the remote URL
# embeds a token (e.g., https://gho_ABC...@github.com/owner/repo.git) — any
# helper that echoes $remote_url emits the token to the transcript, where it
# may be captured by session loggers, sent upstream to model providers, or
# surface in pasted bug reports.
#
# Two layers:
#   scrub_credentials  — strips known token prefixes (sk-, GOCSPX-, ghp_, gho_, ghs_,
#                        ghu_, github_pat_, glpat-, xoxb-, xoxp-) from any
#                        text passed to it. Pure regex, no network.
#   sanitize_url       — strips the `user:pass@` or `token@` authority from
#                        URL-shaped strings, THEN pipes through
#                        scrub_credentials to catch tokens embedded elsewhere
#                        in the URL (query params, path segments).
#
# Always prefer sanitize_url for anything derived from `git remote get-url`,
# `git config remote.*.url`, or user-supplied remote URLs. Use
# scrub_credentials for arbitrary log lines or error messages where a URL
# is not the only possible leak source.
#
# Usage:
#   echo "Remote: $(sanitize_url "$remote_url")"
#   log_error "fetch failed: $(scrub_credentials "$error_output")"

scrub_credentials() {
	local text="$1"
	# Word-boundary anchor (^|non-word-char) prevents false positives where a
	# credential prefix appears mid-word — e.g. `task-failure-handler` contains
	# the literal `sk-failure-handler` (16 chars, matches `sk-[A-Za-z0-9_-]{10,}`)
	# but is NOT a credential. macOS BSD sed has no `\b`, so we capture the
	# preceding boundary character and restore it via \1 in the replacement.
	# (t2892, GH#21026)
	printf '%s' "$text" | sed -E 's/(^|[^A-Za-z0-9_-])(sk-|GOCSPX-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{10,}/\1[redacted-credential]/g'
	return 0
}

sanitize_url() {
	local url="$1"
	local stripped
	# Strip credential authority component: scheme://user:pass@host -> scheme://host
	# Matches any scheme (http, https, git, ssh, etc.), any chars up to @.
	stripped=$(printf '%s' "$url" | sed -E 's|^([a-zA-Z][a-zA-Z0-9+.-]*://)[^@/]+@|\1|')
	# Second pass: catch tokens embedded elsewhere (query params, fragments).
	scrub_credentials "$stripped"
	return 0
}

# =============================================================================
# Portable timeout function (macOS + Linux)
# =============================================================================
# macOS has no native `timeout` command. This function provides a portable
# wrapper that works on Linux (coreutils timeout), macOS with Homebrew
# coreutils (gtimeout), and bare macOS (background + kill fallback).
#
# Usage: timeout_sec 5 your_command arg1 arg2
# Returns: command exit code, or 124 on timeout (matches coreutils convention)
#
# Exit code mapping (POSIX: signal exits are 128 + signal number):
#   124  — timeout (GNU coreutils convention; returned by all paths below)
#   137  — killed by SIGKILL  (128 + 9)  — hard kill, process did not exit cleanly
#   143  — killed by SIGTERM  (128 + 15) — graceful termination signal
# Callers that check for timeout should test for 124. Codes 137/143 indicate
# the process was killed externally (e.g., by the OS or a concurrent pulse).
#
# NOTE: Do NOT pipe timeout_sec to head/grep — on macOS the background
# process may not be properly cleaned up when the pipe closes early.
# Instead, redirect to a temp file and process afterward.
#
# Moved here from tool-version-check.sh (PR #2909) so all scripts that
# source shared-constants.sh get portable timeout support automatically.

timeout_sec() {
	local secs="$1"
	shift

	if command -v timeout &>/dev/null; then
		# Linux has native timeout — returns 124 on timeout
		timeout "$secs" "$@"
		return $?
	elif command -v gtimeout &>/dev/null; then
		# macOS with coreutils — returns 124 on timeout
		gtimeout "$secs" "$@"
		return $?
	else
		# macOS fallback: background the command in a new process group and kill
		# the entire group after the deadline. Using set -m puts each background
		# job in its own process group (PGID == child PID), so kill -- -PGID
		# terminates the child and all its descendants — not just the direct child.
		#
		# GH#5530: the previous implementation used kill "$cmd_pid" which only
		# killed the direct child. Wrapper processes (e.g., bash sandbox-exec-helper.sh)
		# survived because they are parents of the killed process, not children.
		#
		# Save whether monitor mode was already active before enabling it, so we
		# can restore the original shell state rather than unconditionally disabling it.
		local monitor_was_enabled=false
		[[ $- == *m* ]] && monitor_was_enabled=true
		set -m
		"$@" &
		local cmd_pid=$!
		# Restore monitor mode to its original state (set -m or set +m as appropriate)
		$monitor_was_enabled && set -m || set +m
		# PGID equals the PID of the process group leader (the background job)
		local cmd_pgid="$cmd_pid"
		# Poll every 0.5s; count half-seconds to avoid floating-point math
		local half_secs_remaining=$((secs * 2))
		while kill -0 "$cmd_pid" 2>/dev/null; do
			if ((half_secs_remaining <= 0)); then
				# Kill the entire process group: SIGTERM first, then SIGKILL
				kill -TERM -- "-${cmd_pgid}" 2>/dev/null || true # SIGTERM (15) — graceful
				sleep 0.2
				if kill -0 -- "-${cmd_pgid}" 2>/dev/null; then
					kill -KILL -- "-${cmd_pgid}" 2>/dev/null || true # SIGKILL (9) — hard kill
				fi
				wait "$cmd_pid" 2>/dev/null || true
				return 124 # Normalise to GNU timeout convention
			fi
			sleep 0.5
			((half_secs_remaining--)) || true
		done
		wait "$cmd_pid" 2>/dev/null
		return $?
	fi
}

# =============================================================================
# CI/CD Service Timing Constants (Evidence-Based from PR #19 Analysis)
# =============================================================================
# These timings are based on observed completion times across multiple PRs.
# Update these values as you gather more data from your CI/CD runs.

# Fast checks (typically complete in <10s)
# - CodeFactor: ~1s
# - Framework Validation: ~4s
# - Version Consistency: ~4s
readonly CI_WAIT_FAST=10
readonly CI_POLL_FAST=5

# Medium checks (typically complete in 30-90s)
# - Codacy: ~43s
# - SonarCloud: ~44s
# - Qlty: ~57s
# - Code Review Monitoring: ~62s
readonly CI_WAIT_MEDIUM=60
readonly CI_POLL_MEDIUM=15

# Slow checks (typically complete in 120-180s)
# - CodeRabbit initial review: ~120-180s
# - CodeRabbit re-review: ~120-180s
readonly CI_WAIT_SLOW=120
readonly CI_POLL_SLOW=30

# Exponential backoff settings
readonly CI_BACKOFF_BASE=15      # Initial wait (seconds)
readonly CI_BACKOFF_MAX=120      # Maximum wait between polls
readonly CI_BACKOFF_MULTIPLIER=2 # Multiply wait by this each iteration

# Service-specific timeouts (max time to wait before giving up)
readonly CI_TIMEOUT_FAST=60    # 1 minute for fast checks
readonly CI_TIMEOUT_MEDIUM=180 # 3 minutes for medium checks
readonly CI_TIMEOUT_SLOW=600   # 10 minutes for slow checks (CodeRabbit)

# =============================================================================
# Color Constants (for consistent output formatting)
# =============================================================================

readonly COLOR_RED='\033[0;31m'
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_PURPLE='\033[0;35m'
readonly COLOR_CYAN='\033[0;36m'
readonly COLOR_WHITE='\033[1;37m'
readonly COLOR_RESET='\033[0m'

# =============================================================================
# Color Aliases (short names used by most scripts)
# =============================================================================

readonly RED="$COLOR_RED"
readonly GREEN="$COLOR_GREEN"
readonly YELLOW="$COLOR_YELLOW"
readonly BLUE="$COLOR_BLUE"
readonly PURPLE="$COLOR_PURPLE"
readonly CYAN="$COLOR_CYAN"
readonly WHITE="$COLOR_WHITE"
readonly NC="$COLOR_RESET"

# =============================================================================
# Common Functions for Error Handling
# =============================================================================

# Print error message with consistent formatting
print_shared_error() {
	local msg="$1"
	echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $msg" >&2
	return 0
}

# Print success message with consistent formatting
# Writes to stderr so ANSI codes are not captured in $() subshells
print_shared_success() {
	local msg="$1"
	echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $msg" >&2
	return 0
}

# Print warning message with consistent formatting
# Writes to stderr so ANSI codes are not captured in $() subshells
print_shared_warning() {
	local msg="$1"
	echo -e "${COLOR_YELLOW}[WARNING]${COLOR_RESET} $msg" >&2
	return 0
}

# Print info message with consistent formatting
# Writes to stderr so ANSI codes are not captured in $() subshells
print_shared_info() {
	local msg="$1"
	echo -e "${COLOR_BLUE}[INFO]${COLOR_RESET} $msg" >&2
	return 0
}

# Short aliases (used by most scripts - avoids needing inline redefinitions)
print_error() {
	print_shared_error "$1"
	return $?
}
print_success() {
	print_shared_success "$1"
	return $?
}
print_warning() {
	print_shared_warning "$1"
	return $?
}
print_info() {
	print_shared_info "$1"
	return $?
}

# =============================================================================
# Counter Safety Helper (t2763)
# =============================================================================
# safe_grep_count — count lines matching a pattern without the stacking bug.
#
# `grep -c` outputs the count to stdout AND exits 1 when there are zero
# matches. The common idiom `count=$(grep -c 'pat' file || echo "0")`
# therefore appends "0" to grep's own "0" on the zero-match path, producing
# a multi-line string "0\n0" that breaks arithmetic, comparisons, and text
# interpolation. Canonical failure: parent #20402 rendered
# "Progress: **0\n0 done**".
#
# This helper passes all arguments through to grep -c, catches its exit
# code with `|| true`, and guards the result with a regex to guarantee a
# single integer on a single line.
#
# NOTE: Designed for single-file or stdin use. With multiple file arguments,
# grep -c outputs "filename:count" per file, which fails the integer regex
# and returns 0. The -h flag is passed defensively to suppress filename
# prefixes, but multi-line output (from multiple files) still falls through
# to the 0 fallback. For multi-file counting, call once per file.
#
# Usage:
#   count=$(safe_grep_count -E '^pat' file.txt)
#   count=$(printf '%s\n' "$data" | safe_grep_count 'needle')
#   count=$(safe_grep_count 'nope' /does-not-exist)   # prints 0, no error
#
# Enforcement: `.agents/scripts/counter-stack-check.sh` flags the unsafe
# idiom in CI. See also `reference/shell-style-guide.md` § Counter Safety.
safe_grep_count() {
	local _result
	_result=$(grep -h -c "$@" 2>/dev/null || true)
	if [[ "$_result" =~ ^[0-9]+$ ]]; then
		printf '%s\n' "$_result"
	else
		printf '0\n'
	fi
	return 0
}

# =============================================================================
# Shared Logging Functions (issue #2411)
# =============================================================================
# Consolidated log_info/log_error/log_success/log_warn to eliminate duplication
# across 70+ scripts. Each script can customize the prefix label by setting
# LOG_PREFIX before sourcing this file (default: "INFO"/"ERROR"/"OK"/"WARN").
#
# Usage:
#   LOG_PREFIX="CODACY"  # Optional: set before sourcing for custom labels
#   source shared-constants.sh
#   log_info "Processing..."   # Output: [CODACY] Processing...
#
# If LOG_PREFIX is not set, labels default to level names:
#   log_info  -> [INFO]
#   log_error -> [ERROR]
#   log_success -> [OK]
#   log_warn  -> [WARN]
#
# All log functions write to stderr and return 0.
# Scripts that need different behavior can still override after sourcing.

log_info() {
	local label="${LOG_PREFIX:-INFO}"
	echo -e "${BLUE}[${label}]${NC} $*" >&2
	return 0
}

log_error() {
	local label="${LOG_PREFIX:+${LOG_PREFIX}}"
	echo -e "${RED}[${label:-ERROR}]${NC} $*" >&2
	return 0
}

log_success() {
	local label="${LOG_PREFIX:-OK}"
	echo -e "${GREEN}[${label}]${NC} $*" >&2
	return 0
}

log_warn() {
	local label="${LOG_PREFIX:-WARN}"
	echo -e "${YELLOW}[${label}]${NC} $*" >&2
	return 0
}

# Alias for log_warn — callers using the more explicit name are supported
log_warning() {
	log_warn "$@"
	return 0
}

# Validate required parameter
validate_required_param() {
	local param_name="$1"
	local param_value="$2"

	if [[ -z "$param_value" ]]; then
		print_shared_error "$param_name is required"
		return 1
	fi
	return 0
}

# Check if file exists and is readable
validate_file_exists() {
	local file_path="$1"
	local file_description="${2:-File}"

	if [[ ! -f "$file_path" ]]; then
		print_shared_error "$file_description not found: $file_path"
		return 1
	fi

	if [[ ! -r "$file_path" ]]; then
		print_shared_error "$file_description is not readable: $file_path"
		return 1
	fi

	return 0
}

# Check if command exists
validate_command_exists() {
	local command_name="$1"

	if ! command -v "$command_name" &>/dev/null; then
		print_shared_error "Required command not found: $command_name"
		return 1
	fi
	return 0
}

# =============================================================================
# Portable sed -i wrapper (macOS vs GNU/Linux)
# macOS sed requires -i '' while GNU sed requires -i (no argument)
# Usage: sed_inplace 'pattern' file
#        sed_inplace -E 'pattern' file
# =============================================================================

sed_inplace() {
	if [[ "$(uname)" == "Darwin" ]]; then
		sed -i '' "$@"
	else
		sed -i "$@"
	fi
	return $?
}

# Portable sed append-after-line (macOS vs GNU/Linux)
# BSD sed 'a' requires a backslash-newline; GNU sed accepts inline text.
# Usage: sed_append_after <line_number> <text_to_insert> <file>
sed_append_after() {
	local line_num="$1"
	local text="$2"
	local file="$3"
	if [[ "$(uname)" == "Darwin" ]]; then
		sed -i '' "${line_num} a\\
${text}
" "$file"
	else
		sed -i "${line_num}a\\${text}" "$file"
	fi
	return $?
}

# =============================================================================
# Portable fast directory copy with copy-on-write where available (t2889)
#
# Switches to OS-native CoW (clonefile/reflink) when supported, eliminating
# real disk duplication and slashing wall time on large trees. Measured on a
# 3.4GB / 215k-file node_modules: cp -a 166s vs cp -ac 78s on macOS APFS,
# near-zero disk delta (CoW shared blocks).
#
# Falls back transparently to plain cp -a when CoW isn't available (cross-
# volume, non-APFS/btrfs/xfs filesystem, older OS). The destination is
# functionally indistinguishable from cp -a; only disk usage and copy time
# differ.
#
# - macOS:   cp -ac  (clonefile syscall, APFS CoW, preserves symlinks/attrs)
# - Linux:   cp -a --reflink=auto, then cp -a if reflink flag unsupported
# - Other:   cp -a  (regular recursive copy)
#
# Usage: fast_cp <src> <dst>
# Returns: cp exit status
# =============================================================================
fast_cp() {
	local src="$1"
	local dst="$2"
	case "$(uname -s)" in
		Darwin)
			cp -ac "$src" "$dst"
			return $?
			;;
		Linux)
			cp -a --reflink=auto "$src" "$dst" 2>/dev/null || cp -a "$src" "$dst"
			return $?
			;;
		*)
			cp -a "$src" "$dst"
			return $?
			;;
	esac
}

# =============================================================================
# Portable stat wrappers (macOS vs GNU/Linux)
# Sourced from portable-stat.sh — capability detection at load time.
# Provides: _file_mtime_epoch, _file_size_bytes, _file_perms, _file_owner.
# =============================================================================

_SC_SELF="${BASH_SOURCE[0]:-${0:-}}"

# Source a split-out shared module with a short retry window. During hot deploys
# or migrated-machine restores, launchd can start a long-lived helper while the
# agents directory is being replaced. A bare `source path` then fails with
# "No such file or directory" even though the file appears moments later. The
# retry keeps scheduled helpers self-healing without masking persistent install
# corruption.
_source_shared_module_with_retry() {
	# `module_path` is a special zsh array used by zmodload. Shadowing it while
	# evaluating the regex guards below breaks lazy loading of zsh/regex.
	local module_file="$1"
	local attempts="${AIDEVOPS_SHARED_SOURCE_ATTEMPTS:-5}"
	local interval="${AIDEVOPS_SHARED_SOURCE_INTERVAL:-1}"
	local attempt=1

	[[ "$attempts" =~ ^[0-9]+$ ]] || attempts=5
	[[ "$interval" =~ ^[0-9]+$ ]] || interval=1
	[[ "$attempts" -gt 0 ]] || attempts=1

	while [[ "$attempt" -le "$attempts" ]]; do
		if [[ -f "$module_file" ]]; then
			# shellcheck source=/dev/null
			source "$module_file"
			return $?
		fi
		if [[ "$attempt" -lt "$attempts" && "$interval" -gt 0 ]]; then
			sleep "$interval"
		fi
		attempt=$((attempt + 1))
	done

	printf '[ERROR] shared module missing after %s attempt(s): %s\n' "$attempts" "$module_file" >&2
	return 1
}

# shellcheck source=./portable-stat.sh
_source_shared_module_with_retry "${_SC_SELF%/*}/portable-stat.sh"
# _file_size_bytes, _file_perms, _file_mtime_epoch, _file_owner, _stat_batch,
# _stat_translate_fmt are now provided by portable-stat.sh (GH#21742).

# =============================================================================
# Stderr Logging Utilities
# =============================================================================
# Replace blanket 2>/dev/null with targeted stderr handling.
# Usage:
#   log_stderr "context" command args...    # Log stderr to script log file
#   suppress_stderr command args...         # Suppress stderr (documented intent)
#   init_log_file                           # Set up AIDEVOPS_LOG_FILE for script
#
# Guidelines:
#   - command -v, kill -0, pgrep: use suppress_stderr (expected noise)
#   - sqlite3, gh, curl, git push/merge: use log_stderr (errors matter)
#   - rm, mkdir with || true: keep 2>/dev/null (race conditions)

# Resolve the canonical aidevops log directory at runtime.
# Reads paths.log_dir from ~/.aidevops/config/paths.jsonc when config-helper.sh
# is sourced (provides _jsonc_get), falls back to ~/.aidevops/logs otherwise.
# Tilde-expansion handled. Prints the resolved absolute path.
_resolve_log_dir() {
	local resolved
	# shellcheck disable=SC2088  # Tilde is intentionally literal; expanded below
	if type _jsonc_get >/dev/null 2>&1; then
		resolved=$(_jsonc_get "paths.log_dir" "~/.aidevops/logs")
	else
		resolved="~/.aidevops/logs"
	fi
	# Tilde expansion
	resolved="${resolved/#\~/$HOME}"
	printf '%s\n' "$resolved"
	return 0
}

# Initialize log file for the calling script.
# Sets AIDEVOPS_LOG_FILE to <log_dir>/<script-name>.log
# Call once at script start after sourcing shared-constants.sh.
init_log_file() {
	local script_name
	script_name="$(basename "${BASH_SOURCE[1]:-${0:-unknown}}" .sh)"
	local log_dir
	log_dir=$(_resolve_log_dir)
	mkdir -p "$log_dir" 2>/dev/null || true
	AIDEVOPS_LOG_FILE="${log_dir}/${script_name}.log"
	export AIDEVOPS_LOG_FILE
	return 0
}

# Run a command, redirecting stderr to the script's log file.
# Preserves exit code. Falls back to /dev/null if no log file set.
# Usage: log_stderr "db migration" sqlite3 "$db" "ALTER TABLE..."
log_stderr() {
	local context="$1"
	shift
	local log_target="${AIDEVOPS_LOG_FILE:-/dev/null}"
	local timestamp
	timestamp="$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")"
	echo "[$timestamp] [$context] Running: $*" >>"$log_target" 2>/dev/null || true
	"$@" 2>>"$log_target"
	local rc=$?
	if [[ $rc -ne 0 ]]; then
		echo "[$timestamp] [$context] Exit code: $rc" >>"$log_target" 2>/dev/null || true
	fi
	return $rc
}

# Suppress stderr with documented intent. Use for commands where stderr
# is expected noise (e.g., command -v, kill -0, pgrep, sysctl on wrong OS).
# Usage: suppress_stderr command -v jq
suppress_stderr() {
	"$@" 2>/dev/null
	return $?
}

_shared_constants_dir="${BASH_SOURCE[0]%/*}"
if [[ -r "${_shared_constants_dir}/pulse-temp-helper.sh" ]]; then
	# shellcheck source=pulse-temp-helper.sh
	source "${_shared_constants_dir}/pulse-temp-helper.sh"
fi
unset _shared_constants_dir

# =============================================================================
# RETURN Trap Cleanup Stack (t196)
# =============================================================================
# Prevents RETURN trap clobbering when a function needs multiple temp files.
# In bash, setting `trap '...' RETURN` twice in the same function silently
# replaces the first trap — the first temp file leaks.
#
# IMPORTANT: `trap` applies to the function that calls it, NOT the caller's
# caller. Therefore push_cleanup cannot set the trap for you — the calling
# function must set `trap '_run_cleanups' RETURN` itself.
#
# Usage pattern (replaces raw `trap 'rm ...' RETURN`):
#
#   my_func() {
#       _save_cleanup_scope
#       trap '_run_cleanups' RETURN
#       local tmp1; tmp1=$(mktemp)
#       push_cleanup "rm -f '${tmp1}'"
#       local tmp2; tmp2=$(mktemp)
#       push_cleanup "rm -f '${tmp2}'"
#       # ... both files cleaned up on return (LIFO order)
#   }
#
# Single-file shorthand (most common case — no change needed):
#
#   my_func() {
#       local tmp; tmp=$(mktemp)
#       trap 'rm -f "${tmp:-}"' RETURN
#       # ... single file, no clobbering risk
#   }
#
# Nesting: RETURN traps are function-scoped in bash 3.2+, so nested
# function calls each get their own trap. _save_cleanup_scope saves the
# parent's cleanup list; _run_cleanups restores it after executing.
#
# Migration from raw trap (only needed for multi-cleanup functions):
#   BEFORE: trap 'rm -f "${a:-}"' RETURN  # second trap clobbers first
#           trap 'rm -f "${b:-}"' RETURN
#   AFTER:  _save_cleanup_scope
#           trap '_run_cleanups' RETURN
#           push_cleanup "rm -f '${a}'"
#           push_cleanup "rm -f '${b}'"

# Global state for the cleanup stack.
# _CLEANUP_CMDS: newline-separated list of commands for the current scope.
# _CLEANUP_SAVE_STACK: saved parent scopes (unit-separator delimited).
_CLEANUP_CMDS=""
_CLEANUP_SAVE_STACK=""

# Add a cleanup command to the current scope.
# The command runs when the calling function returns (LIFO order).
# Caller MUST have set `trap '_run_cleanups' RETURN` in their own scope.
# Arguments:
#   $1 - shell command to eval on cleanup (required)
push_cleanup() {
	local cmd="$1"
	if [[ -n "$_CLEANUP_CMDS" ]]; then
		_CLEANUP_CMDS="${_CLEANUP_CMDS}"$'\n'"${cmd}"
	else
		_CLEANUP_CMDS="${cmd}"
	fi
	return 0
}

# Run all cleanup commands for the current scope (reverse order),
# then restore the parent scope's cleanup list.
# This is the RETURN trap handler — do not call directly.
_run_cleanups() {
	if [[ -n "$_CLEANUP_CMDS" ]]; then
		# Reverse the command list (LIFO) without an external pipeline. Using
		# echo | tail -r/tac can emit Broken pipe noise under pipefail when the
		# consumer exits early.
		local reversed
		reversed=""
		local line
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			if [[ -n "$reversed" ]]; then
				reversed="${line}"$'\n'"${reversed}"
			else
				reversed="$line"
			fi
		done <<<"$_CLEANUP_CMDS"
		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			# Bare function names must run in the current shell so cleanup can
			# update process-local ownership state before removing resources.
			# Compound commands remain isolated in a child shell.
			if [[ "$line" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] && declare -F "$line" >/dev/null 2>&1; then
				"$line" 2>/dev/null || true
			else
				bash -c "$line" 2>/dev/null || true
			fi
		done <<<"$reversed"
	fi
	# Restore parent scope (pop from save stack)
	local sep=$'\x1F'
	if [[ -n "$_CLEANUP_SAVE_STACK" ]]; then
		_CLEANUP_CMDS="${_CLEANUP_SAVE_STACK%%"${sep}"*}"
		_CLEANUP_SAVE_STACK="${_CLEANUP_SAVE_STACK#*"${sep}"}"
	else
		_CLEANUP_CMDS=""
	fi
	return 0
}

# Save the current cleanup scope and start a fresh one.
# Call at the top of any function that uses push_cleanup, BEFORE setting
# `trap '_run_cleanups' RETURN`. This preserves the parent function's
# cleanup list so nested calls don't interfere.
_save_cleanup_scope() {
	local sep=$'\x1F'
	_CLEANUP_SAVE_STACK="${_CLEANUP_CMDS}${sep}${_CLEANUP_SAVE_STACK}"
	_CLEANUP_CMDS=""
	return 0
}


# =============================================================================
# GitHub Token/Origin/Label/Status Wrappers -- extracted module
# =============================================================================
# Functions: gh_token_has_workflow_scope, files_include_workflow_changes,
#            detect_session_origin, session_origin_label, gh_create_issue,
#            gh_create_pr, gh_issue_comment, gh_pr_comment, gh_issue_edit_safe,
#            gh_pr_edit_safe, set_origin_label, set_issue_status, and helpers
# Extracted to shared-gh-wrappers.sh to keep this file < 2000 lines.
# See shared-gh-wrappers.sh for full documentation.

_SC_SELF="${BASH_SOURCE[0]:-${0:-}}"
# shellcheck source=./managed-label-provisioning-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _SC_SELF
_source_shared_module_with_retry "${_SC_SELF%/*}/managed-label-provisioning-lib.sh"
# shellcheck source=./shared-gh-wrappers.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _SC_SELF
_source_shared_module_with_retry "${_SC_SELF%/*}/shared-gh-wrappers.sh"


#######################################
# Clear active-lifecycle status labels on dispatch claim release (t2420).
#
# Removes only the four ACTIVE status labels (queued, claimed, in-progress,
# in-review) and optionally the worker's assignment. PRESERVES terminal
# states (done, blocked) and the eligible state (available) — those are set
# by authoritative paths (PR merge, blocker triage, explicit re-queue) and
# must survive a worker's claim release.
#
# Why not set_issue_status "" ? Because it would strip status:done set by
# the PR merge path if the CLAIM_RELEASED comment races ahead — a worker
# that succeeds, creates a PR, the PR merges (setting status:done), and
# then the worker's EXIT trap fires CLAIM_RELEASED would regress the state.
# This helper is the targeted, race-safe alternative.
#
# Why not just skip label cleanup entirely? Because without it, orphan
# labels pin an issue as "active" even though no worker holds the claim,
# blocking pulse re-dispatch via the t1996 combined-signal guard
# (active-status + assignee = block). Observed in production: #19864 and
# #19738 were both pinned status:queued/claimed for 40+ minutes after
# worker completion, with dead PIDs (one case was PID 11742 reused by
# Brave Browser — see t2421).
#
# Origin labels are provenance only. An interactive session may create an
# auto-dispatch issue that a headless worker validly claims, so release must
# not skip cleanup solely because origin:interactive is present (GH#29897).
# The exact worker_login removal and linked-PR safeguards below preserve live
# interactive ownership and completed-work audit state.
#
# Args:
#   $1 — issue number
#   $2 — repo slug (owner/repo)
#   $3 — worker login to remove as assignee (optional; empty = no assignee change)
#
# Returns:
#   0 on success, including idempotent no-ops
#   1 on gh failure (logged by gh to stderr; suppressed here)
#
# Example:
#   clear_active_status_on_release 20026 marcusquinn/aidevops "$(whoami)"
#######################################
clear_active_status_on_release() {
	local issue_num="$1"
	local repo_slug="$2"
	local worker_login="${3:-}"

	if [[ -z "$issue_num" || -z "$repo_slug" ]]; then
		return 0
	fi

	local labels_json=""
	labels_json=$(gh issue view "$issue_num" --repo "$repo_slug" \
		--json labels --jq '[.labels[].name] | join(",")' 2>/dev/null) || labels_json=""

	# Defensive: if a linked PR exists for this issue (OPEN or MERGED),
	# preserve the worker's assignee and status:in-review.
	#
	# OPEN linked PR: the PR pipeline owns final cleanup on merge (see
	# pulse-merge.sh::_release_interactive_claim_on_merge for the
	# interactive mirror). Stripping here strands the PR in
	# maintainer-gate Job 1 Check 2 because the assignee check fires
	# after CLAIM_RELEASED but before PR merge. GH#20195/t2451 closed
	# that trust-gate loop.
	#
	# MERGED linked PR: preserves the closing-time audit trail on the
	# issues list — the assignee identifies which runner's worker
	# completed the work once the issue auto-closes. Without this, a
	# fast merge (CI green before the worker exit trap fires — observed
	# as little as 16s) races the unassign and erases the audit trail.
	# t2746/GH#20520.
	#
	# We still remove queued, claimed, and in-progress — those never
	# outlive the worker process regardless of PR state. When no linked PR
	# exists, add status:available in the same edit so failed workers do not
	# leave issues pinned as assigned-but-queued until the next stale sweep.
	#
	# CLOSED-not-merged PRs do NOT trigger preserve: the work didn't
	# complete, and leaving the assignee on the issue would block
	# future dispatch via the combined-signal dedup rule (t1996).
	#
	# Closing-keyword regex matches pulse-merge.sh::_extract_linked_issue
	# character-for-character (case-insensitive) so behaviour is consistent
	# across the merge path and the release path. Do NOT widen this to
	# `Ref` or `For` — those are planning references that MUST NOT block
	# assignee cleanup (see t2046).
	local has_linked_pr=false
	local has_open_linked_pr=0
	local linked_open_pr_numbers=""
	local linked_prs_json=""
	linked_prs_json=$(gh pr list --repo "$repo_slug" --state all \
		--search "#${issue_num} in:body" \
		--json number,state,body --limit 20 2>/dev/null || true)
	if [[ -z "$linked_prs_json" ]]; then
		linked_prs_json="[]"
	fi
	if printf '%s' "$linked_prs_json" | jq -e --arg num "$issue_num" \
		'[.[] | select((.state == "OPEN" or .state == "MERGED") and ((.body // "") | test("(close[ds]?|fix(es|ed)?|resolve[ds]?)[[:space:]]*#" + $num + "\\b"; "i")))] | length > 0' \
		>/dev/null 2>&1; then
		has_linked_pr=true
	fi
	linked_open_pr_numbers=$(printf '%s' "$linked_prs_json" | jq -r --arg num "$issue_num" \
		'.[] | select(.state == "OPEN" and ((.body // "") | test("(close[ds]?|fix(es|ed)?|resolve[ds]?)[[:space:]]*#" + $num + "\\b"; "i"))) | .number' \
		2>/dev/null || true)
	if [[ -n "$linked_open_pr_numbers" ]]; then
		has_open_linked_pr=1
	fi

	local -a _flags=()
	_flags+=(--remove-label "status:queued")
	_flags+=(--remove-label "status:claimed")
	_flags+=(--remove-label "status:in-progress")

	if [[ "$has_linked_pr" != "true" ]]; then
		_flags+=(--remove-label "status:in-review")
		_flags+=(--add-label "status:available")
		if [[ -n "$worker_login" ]]; then
			_flags+=(--remove-assignee "$worker_login")
		fi
	elif [[ "$has_open_linked_pr" -eq 1 && ",${labels_json}," != *",status:done,"* ]]; then
		_flags+=(--remove-label "status:available")
		_flags+=(--add-label "status:in-review")
	fi

	gh issue edit "$issue_num" --repo "$repo_slug" "${_flags[@]}" 2>/dev/null || return 1
	if [[ "$has_open_linked_pr" -eq 1 ]]; then
		local linked_pr_number=""
		while IFS= read -r linked_pr_number; do
			[[ -z "$linked_pr_number" ]] && continue
			set_issue_status "$linked_pr_number" "$repo_slug" "in-review" >/dev/null 2>&1 || true
		done <<<"$linked_open_pr_numbers"
	fi
	return 0
}

# =============================================================================
# TODO.md Serialized Commit+Push -- extracted module
# =============================================================================
# Functions: todo_commit_push (public), _todo_acquire_lock,
#            _todo_release_lock, _todo_commit_push_inner.
# Constants: TODO_LOCK_DIR, TODO_LOCK_PATH, TODO_MAX_RETRIES,
#            TODO_LOCK_TIMEOUT, TODO_STALE_LOCK_AGE (all readonly).
# Provides atomic mkdir-based locking + pull-rebase-retry for TODO.md and
# adjacent planning files (todo/). Prevents race conditions when multiple
# actors (supervisor, interactive sessions) push to TODO.md on main
# simultaneously. Workers must NOT call todo_commit_push directly — they
# report status via exit code/log/mailbox; the supervisor handles all
# TODO.md updates.
# Extracted to shared-todo-commit.sh (t2441, GH#20094) to keep this file
# below the file-size-debt ratchet (1500 lines). Mirrors the Phase 1
# (shared-feature-toggles.sh, t2427/PR #20063) and Phase 2
# (shared-model-tier.sh, t2440/PR #20092) split precedents. See
# shared-todo-commit.sh for full documentation.

_SC_SELF="${BASH_SOURCE[0]:-${0:-}}"
# shellcheck source=./shared-todo-commit.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _SC_SELF
_source_shared_module_with_retry "${_SC_SELF%/*}/shared-todo-commit.sh"

# Managed session/worker temporary workspace.
# shellcheck source=./shared-temp-workspace.sh
_source_shared_module_with_retry "${_SC_SELF%/*}/shared-temp-workspace.sh"

# =============================================================================
# Worktree Ownership Registry (t189) — extracted module
# =============================================================================
# Functions: register_worktree, claim_worktree_ownership, unregister_worktree,
#            check_worktree_owner, is_worktree_owned_by_others, prune_worktree_registry
# Extracted to shared-worktree-registry.sh to keep this file < 2000 lines.
# See shared-worktree-registry.sh for full documentation.
#
# SQLite Backup-Before-Modify Pattern (t188) — extracted module
# Functions: backup_sqlite_db, verify_sqlite_backup, rollback_sqlite_db,
#            cleanup_sqlite_backups, verify_migration_rowcounts
# Extracted to shared-sqlite-backup.sh to keep this file < 2000 lines.
# See shared-sqlite-backup.sh for full documentation.

_SC_SELF="${BASH_SOURCE[0]:-${0:-}}"
# shellcheck source=/dev/null
[[ -r "${_SC_SELF%/*}/shared-worktree-registry.sh" ]] && source "${_SC_SELF%/*}/shared-worktree-registry.sh"
# shellcheck source=/dev/null
[[ -r "${_SC_SELF%/*}/shared-sqlite-backup.sh" ]] && source "${_SC_SELF%/*}/shared-sqlite-backup.sh"

# =============================================================================
# Export all constants for use in other scripts
# =============================================================================

# =============================================================================
# PID Liveness — command-aware process checks (t2421, GH#20027)
# =============================================================================
# Bare `kill -0 <PID>` lies when macOS recycles PIDs (wraps at 99999).
# These helpers verify the PID is alive AND its command matches what we expect.
#
# Constants: WORKER_PROCESS_PATTERN, PULSE_PROCESS_PATTERN, FRAMEWORK_PROCESS_PATTERN
# Functions: _process_start_token, _compute_argv_hash, _is_process_alive_and_matches
# =============================================================================

# Expected command patterns for PID-owner verification.
# Used by _is_process_alive_and_matches to distinguish real workers from
# PID-reuse impostors (e.g., "Brave Browser Helper (Renderer)").
[[ -z "${WORKER_PROCESS_PATTERN+x}" ]] && WORKER_PROCESS_PATTERN='opencode|claude|Claude'
[[ -z "${PULSE_PROCESS_PATTERN+x}" ]] && PULSE_PROCESS_PATTERN='pulse-wrapper'
[[ -z "${FRAMEWORK_PROCESS_PATTERN+x}" ]] && FRAMEWORK_PROCESS_PATTERN='opencode|claude|Claude|pulse|aidevops|headless-runtime'

#######################################
# Return a stable process-start token for PID-reuse-resistant ownership checks.
# Uses Linux /proc start ticks when available and portable ps output elsewhere.
# Args: $1 = PID
# Outputs: process-start token on stdout.
# Returns: 0 on success, 1 on failure.
#######################################
_process_start_token() {
	local pid="$1"
	local stat_content=""
	local stat_after_comm=""
	local start_token=""
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1
	if [[ -r "/proc/${pid}/stat" ]]; then
		stat_content=$(<"/proc/${pid}/stat") || stat_content=""
		[[ -n "$stat_content" ]] || return 1
		stat_after_comm="${stat_content##*) }"
		start_token=$(printf '%s\n' "$stat_after_comm" | awk '{print $20}') || start_token=""
	else
		start_token=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null | tr -s ' ') || start_token=""
		start_token="${start_token#"${start_token%%[![:space:]]*}"}"
		start_token="${start_token%"${start_token##*[![:space:]]}"}"
	fi
	[[ -n "$start_token" ]] || return 1
	printf '%s\n' "$start_token"
	return 0
}

#######################################
# Compute a short hash of a process's command line.
# Portable across macOS (shasum) and Linux (sha256sum).
# Args: $1 = PID (defaults to $$)
# Outputs: 12-char hex hash on stdout, or empty string on failure.
# Returns: 0 on success, 1 on failure.
#######################################
_compute_argv_hash() {
	local pid="${1:-$$}"
	local cmd
	cmd=$(ps -p "$pid" -o command= 2>/dev/null) || return 1
	[[ -z "$cmd" ]] && return 1
	local hash
	if command -v shasum >/dev/null 2>&1; then
		hash=$(printf '%s' "$cmd" | shasum -a 256 2>/dev/null | cut -c1-12)
	elif command -v sha256sum >/dev/null 2>&1; then
		hash=$(printf '%s' "$cmd" | sha256sum 2>/dev/null | cut -c1-12)
	else
		# Fallback: no hash tool available, return empty (callers skip hash check)
		return 1
	fi
	[[ -n "$hash" ]] && printf '%s' "$hash" && return 0
	return 1
}

#######################################
# Check that a PID is alive AND its command matches expected pattern.
# Replaces bare `kill -0` checks that are vulnerable to PID reuse on macOS.
#
# Args:
#   $1 = PID to check
#   $2 = regex pattern (e.g., "opencode|claude"). If empty, falls back to
#        bare kill -0 (backward-compatible for callers that don't know
#        the expected command).
#   $3 = (optional) stored argv hash. If provided and non-empty, the
#        current process command hash must match. This catches PID reuse
#        even when the new process name happens to match the pattern
#        (e.g., two different claude sessions).
#   $4 = (optional) stored process-start token. If provided and non-empty,
#        the current process start token must match exactly.
#
# Returns: 0 if alive and matches, 1 otherwise.
#######################################
_is_process_alive_and_matches() {
	local pid="$1"
	local pattern="${2:-}"
	local stored_hash="${3:-}"
	local stored_start="${4:-}"

	# Basic validation
	[[ -z "$pid" ]] && return 1
	[[ "$pid" == "0" ]] && return 1
	[[ "$pid" =~ ^[0-9]+$ ]] || return 1

	# Step 1: is the PID alive at all?
	kill -0 "$pid" 2>/dev/null || return 1

	# Step 2: does the command match the expected pattern?
	if [[ -n "$pattern" ]]; then
		local cmd
		cmd=$(ps -p "$pid" -o command= 2>/dev/null) || return 1
		[[ -z "$cmd" ]] && return 1
		printf '%s' "$cmd" | grep -qE "$pattern" || return 1
	fi

	# Step 3: if a stored hash was provided, verify it matches
	if [[ -n "$stored_hash" ]]; then
		local current_hash
		current_hash=$(_compute_argv_hash "$pid") || current_hash=""
		if [[ -n "$current_hash" ]]; then
			[[ "$stored_hash" == "$current_hash" ]] || return 1
		fi
	fi

	# Step 4: a stored process-start token must always match exactly.
	if [[ -n "$stored_start" ]]; then
		local current_start
		current_start=$(_process_start_token "$pid") || return 1
		[[ "$stored_start" == "$current_start" ]] || return 1
	fi

	return 0
}

# =============================================================================
# Model Tier Resolution & Pricing -- extracted module
# =============================================================================
# Functions: resolve_model_tier, detect_ai_backends, get_model_pricing,
#            get_provider_from_model, _load_model_pricing_json.
# Variables: _MODEL_PRICING_JSON, _MODEL_PRICING_JSON_LOADED (cached on first
#            get_model_pricing call).
# Reads .agents/configs/model-pricing.json via jq when available (single source
# of truth shared with observability.mjs); falls back to a hardcoded case
# statement for the no-jq path.
# Extracted to shared-model-tier.sh (t2440, GH#20089) to keep this file below
# the file-size-debt ratchet (1500 lines). Mirrors the Phase 1 split precedent
# (shared-feature-toggles.sh, t2427, PR #20063). See shared-model-tier.sh for
# full documentation.

_SC_SELF="${BASH_SOURCE[0]:-${0:-}}"
# shellcheck source=./shared-model-tier.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _SC_SELF
_source_shared_module_with_retry "${_SC_SELF%/*}/shared-model-tier.sh"

# =============================================================================
# Configuration Loader & Feature Toggles -- extracted module
# =============================================================================
# Functions: get_feature_toggle, is_feature_enabled, _load_config, _ft_env_map,
#            _load_feature_toggles_legacy.
# Variables: FEATURE_TOGGLES_DEFAULTS, FEATURE_TOGGLES_USER,
#            _AIDEVOPS_CONFIG_MODE (populated on load).
# Sources config-helper.sh and runtime-registry.sh transitively.
# Extracted to shared-feature-toggles.sh (t2427, GH#20063) to keep this file
# < 2000 lines. See shared-feature-toggles.sh for full documentation.
# Sourcing this sub-library auto-invokes _load_config at its tail — no explicit
# call needed here.

_SC_SELF="${BASH_SOURCE[0]:-${0:-}}"
# shellcheck source=./shared-feature-toggles.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via _SC_SELF
_source_shared_module_with_retry "${_SC_SELF%/*}/shared-feature-toggles.sh"

# This ensures all constants are available when this file is sourced
export CONTENT_TYPE_JSON CONTENT_TYPE_FORM USER_AGENT
export HTTP_OK HTTP_CREATED HTTP_BAD_REQUEST HTTP_UNAUTHORIZED HTTP_FORBIDDEN HTTP_NOT_FOUND HTTP_INTERNAL_ERROR
export ERROR_CONFIG_NOT_FOUND ERROR_INPUT_FILE_NOT_FOUND ERROR_INPUT_FILE_REQUIRED
export ERROR_REPO_NAME_REQUIRED ERROR_DOMAIN_NAME_REQUIRED ERROR_ACCOUNT_NAME_REQUIRED
export SUCCESS_REPO_CREATED SUCCESS_DEPLOYMENT_COMPLETE SUCCESS_CONFIG_UPDATED
export USAGE_PATTERN HELP_PATTERN CONFIG_PATTERN
export DEFAULT_TIMEOUT LONG_TIMEOUT SHORT_TIMEOUT MAX_RETRIES
export CI_WAIT_FAST CI_POLL_FAST CI_WAIT_MEDIUM CI_POLL_MEDIUM CI_WAIT_SLOW CI_POLL_SLOW
export CI_BACKOFF_BASE CI_BACKOFF_MAX CI_BACKOFF_MULTIPLIER
export CI_TIMEOUT_FAST CI_TIMEOUT_MEDIUM CI_TIMEOUT_SLOW
export COLOR_RED COLOR_GREEN COLOR_YELLOW COLOR_BLUE COLOR_PURPLE COLOR_CYAN COLOR_WHITE COLOR_RESET
export RED GREEN YELLOW BLUE PURPLE CYAN WHITE NC
