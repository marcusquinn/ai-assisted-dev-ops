#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# auto-update-helper.sh - Automatic update polling daemon for aidevops
#
# Lightweight cron job that checks for new aidevops releases every 10 minutes
# and auto-installs them. Safe to run while AI sessions are active.
#
# Also runs a daily skill freshness check: calls skill-update-helper.sh
# --auto-update --quiet to pull upstream changes for all imported skills.
# The 24h gate ensures skills stay fresh without excessive network calls.
#
# Also runs a daily OpenClaw update check (if openclaw CLI is installed).
# Uses the same 24h gate pattern. Respects the user's configured channel.
#
# Also runs a 6-hourly tool freshness check: calls tool-version-check.sh
# --update --quiet to upgrade all installed tools (npm, brew, pip).
# Only runs when the user has been idle for 6+ hours (sleeping/away).
# macOS: uses IOKit HIDIdleTime. Linux: xprintidle, or /proc session idle,
# or assumes idle on headless servers (no display).
#
# Usage:
#   auto-update-helper.sh enable           Install cron job (every 10 min)
#   auto-update-helper.sh disable          Remove cron job
#   auto-update-helper.sh status           Show current state
#   auto-update-helper.sh check            One-shot: check and update if needed
#   auto-update-helper.sh logs [--tail N]  View update logs
#   auto-update-helper.sh help             Show this help
#
# Configuration:
#   All values can be set via JSONC config (aidevops config set <key> <value>)
#   or overridden per-session via environment variables (higher priority).
#
#   JSONC key                          Env override                    Default
#   updates.auto_update                AIDEVOPS_AUTO_UPDATE            true
#   updates.update_interval_minutes    AIDEVOPS_UPDATE_INTERVAL        10
#   updates.skill_auto_update          AIDEVOPS_SKILL_AUTO_UPDATE      true
#   updates.skill_freshness_hours      AIDEVOPS_SKILL_FRESHNESS_HOURS  24
#   updates.openclaw_auto_update       AIDEVOPS_OPENCLAW_AUTO_UPDATE   true
#   updates.openclaw_freshness_hours   AIDEVOPS_OPENCLAW_FRESHNESS_HOURS 24
#   updates.tool_auto_update           AIDEVOPS_TOOL_AUTO_UPDATE       true
#   updates.tool_freshness_hours       AIDEVOPS_TOOL_FRESHNESS_HOURS   6
#   updates.tool_idle_hours            AIDEVOPS_TOOL_IDLE_HOURS        6
#   updates.upstream_watch             AIDEVOPS_UPSTREAM_WATCH         true
#   updates.upstream_watch_hours       AIDEVOPS_UPSTREAM_WATCH_HOURS   24
#   updates.venv_health_check          AIDEVOPS_VENV_HEALTH_CHECK      true
#   updates.venv_health_hours          AIDEVOPS_VENV_HEALTH_HOURS      24
#
# Logs: ~/.aidevops/logs/auto-update.log

set -euo pipefail

# Resolve symlinks to find real script location (t1262)
# When invoked via symlink (e.g. ~/.aidevops/bin/aidevops-auto-update),
# BASH_SOURCE[0] is the symlink path. We must resolve it to find sibling scripts.
_resolve_script_path() {
	local src="${BASH_SOURCE[0]}"
	while [[ -L "$src" ]]; do
		local dir
		dir="$(cd "$(dirname "$src")" && pwd)" || return 1
		src="$(readlink "$src")"
		[[ "$src" != /* ]] && src="$dir/$src"
	done
	cd "$(dirname "$src")" && pwd
}
SCRIPT_DIR="$(_resolve_script_path)" || exit
unset -f _resolve_script_path
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=plist-env-overrides-lib.sh
source "${SCRIPT_DIR}/plist-env-overrides-lib.sh"

init_log_file

# Configuration
readonly INSTALL_DIR="$HOME/Git/aidevops"
readonly LOCK_DIR="$HOME/.aidevops/locks"
readonly LOCK_FILE="$LOCK_DIR/auto-update.lock"
readonly LOG_FILE="$HOME/.aidevops/logs/auto-update.log"
readonly STATE_FILE="$HOME/.aidevops/cache/auto-update-state.json"
readonly CRON_MARKER="# aidevops-auto-update"
readonly DEFAULT_INTERVAL=10
readonly DEFAULT_SKILL_FRESHNESS_HOURS=24
readonly DEFAULT_OPENCLAW_FRESHNESS_HOURS=24
readonly DEFAULT_TOOL_FRESHNESS_HOURS=6
readonly DEFAULT_TOOL_IDLE_HOURS=6
readonly DEFAULT_UPSTREAM_WATCH_HOURS=24
readonly DEFAULT_VENV_HEALTH_HOURS=24
readonly LAUNCHD_LABEL="com.aidevops.aidevops-auto-update"
readonly LAUNCHD_DIR="$HOME/Library/LaunchAgents"
readonly LAUNCHD_PLIST="${LAUNCHD_DIR}/${LAUNCHD_LABEL}.plist"
readonly SYSTEMD_SERVICE_DIR="$HOME/.config/systemd/user"
readonly SYSTEMD_UNIT_NAME="aidevops-auto-update"

#######################################
# Logging
#######################################
log() {
	local level="$1"
	shift
	local timestamp
	timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
	echo "[$timestamp] [$level] $*" >>"$LOG_FILE"
	return 0
}

log_info() {
	log "INFO" "$@"
	return 0
}
log_warn() {
	log "WARN" "$@"
	return 0
}
log_error() {
	log "ERROR" "$@"
	return 0
}

#######################################
# Ensure directories exist
#######################################
ensure_dirs() {
	mkdir -p "$LOCK_DIR" "$HOME/.aidevops/logs" "$HOME/.aidevops/cache" 2>/dev/null || true
	return 0
}

#######################################
# Detect scheduler backend for current platform
# Sources platform-detect.sh for accurate detection (GH#17695 Finding C).
# Returns: "launchd" on macOS, "systemd" or "cron" on Linux
#######################################
_get_scheduler_backend() {
	# Source platform-detect.sh if AIDEVOPS_SCHEDULER is not already set
	if [[ -z "${AIDEVOPS_SCHEDULER:-}" ]]; then
		local _pd_path
		_pd_path="$(dirname "${BASH_SOURCE[0]}")/platform-detect.sh"
		if [[ -f "$_pd_path" ]]; then
			# shellcheck source=platform-detect.sh
			source "$_pd_path"
		fi
	fi
	# Fall back to simple uname check if platform-detect.sh unavailable
	if [[ -n "${AIDEVOPS_SCHEDULER:-}" ]]; then
		echo "$AIDEVOPS_SCHEDULER"
	elif [[ "$(uname)" == "Darwin" ]]; then
		echo "launchd"
	else
		echo "cron"
	fi
	return 0
}

#######################################
# Remove stale auto-update cron entry after a Linux systemd timer is active.
# Returns: 0 always
#######################################
_remove_auto_update_cron_duplicate() {
	local current_cron=""
	local filtered_cron=""
	local temp_cron=""

	command -v crontab >/dev/null 2>&1 || return 0
	current_cron=$(crontab -l 2>/dev/null) || current_cron=""
	[[ -n "$current_cron" ]] || return 0
	printf '%s\n' "$current_cron" | grep -qF "$CRON_MARKER" || return 0

	filtered_cron=$(printf '%s\n' "$current_cron" | grep -vF "$CRON_MARKER" || true)
	if [[ -n "$filtered_cron" ]]; then
		temp_cron=$(mktemp)
		printf '%s\n' "$filtered_cron" >"$temp_cron"
		crontab "$temp_cron" 2>/dev/null || true
		rm -f "$temp_cron"
	else
		crontab -r 2>/dev/null || true
	fi

	log_info "Removed duplicate auto-update cron entry; kept systemd user timer"
	print_info "Removed duplicate auto-update cron entry; kept systemd user timer"
	return 0
}

#######################################
# Check if the auto-update LaunchAgent is loaded
# Returns: 0 if loaded, 1 if not
#######################################
_launchd_is_loaded() {
	# Use a variable to avoid SIGPIPE (141) when grep -q exits early
	# under set -o pipefail (t1265)
	local output
	output=$(launchctl list 2>/dev/null) || true
	echo "$output" | grep -qF "$LAUNCHD_LABEL"
	return $?
}

#######################################
# Generate auto-update LaunchAgent plist content
# Arguments:
#   $1 - script_path
#   $2 - interval_seconds
#   $3 - env_path
#######################################
_generate_auto_update_plist() {
	local script_path="$1"
	local interval_seconds="$2"
	local env_path="$3"
	env_path=$(aidevops_launchd_sanitized_path "$env_path")
	local env_overrides_xml
	env_overrides_xml=$(_build_plist_env_overrides_xml "$LAUNCHD_LABEL")

	cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LAUNCHD_LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>${script_path}</string>
		<string>check</string>
	</array>
	<key>StartInterval</key>
	<integer>${interval_seconds}</integer>
	<key>StandardOutPath</key>
	<string>${LOG_FILE}</string>
	<key>StandardErrorPath</key>
	<string>${LOG_FILE}</string>
	<key>EnvironmentVariables</key>
	<dict>
		<key>PATH</key>
		<string>${env_path}</string>
${env_overrides_xml}	</dict>
	<key>RunAtLoad</key>
	<false/>
	<key>KeepAlive</key>
	<false/>
</dict>
</plist>
EOF
	return 0
}

#######################################
# Migrate existing cron entry to launchd (macOS only)
# Called automatically when cmd_enable runs on macOS
# Arguments:
#   $1 - script_path
#   $2 - interval_seconds
#######################################
_migrate_cron_to_launchd() {
	local script_path="$1"
	local interval_seconds="$2"

	# Check if cron entry exists
	if ! crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
		return 0
	fi

	# Skip migration if launchd agent already loaded (t1265)
	if _launchd_is_loaded; then
		log_info "LaunchAgent already loaded — removing stale cron entry only"
	else
		log_info "Migrating auto-update from cron to launchd..."

		# Generate and write plist
		mkdir -p "$LAUNCHD_DIR"
		_generate_auto_update_plist "$script_path" "$interval_seconds" "${PATH}" >"$LAUNCHD_PLIST"

		# Load into launchd
		if launchctl load -w "$LAUNCHD_PLIST" 2>/dev/null; then
			log_info "LaunchAgent loaded: $LAUNCHD_LABEL"
		else
			log_error "Failed to load LaunchAgent during migration"
			return 1
		fi
	fi

	# Remove old cron entry
	local temp_cron
	temp_cron=$(mktemp)
	if crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" >"$temp_cron"; then
		crontab "$temp_cron"
	else
		crontab -r 2>/dev/null || true
	fi
	rm -f "$temp_cron"

	log_info "Migration complete: auto-update now managed by launchd"
	return 0
}

#######################################
# Lock management (prevents concurrent updates)
# Uses mkdir for atomic locking (POSIX-safe)
#######################################

#######################################
# _lock_holder_is_wedged
# Returns 0 if the lock holder is wedged (process alive but no log progress
# for more than WEDGE_THRESHOLD_SECONDS), 1 otherwise.
# Conservative: treats absence of log file as "not wedged" (can't tell).
# Uses log file mtime as a proxy for "last sign of life" — more accurate than
# lock directory mtime which only reflects lock acquisition time.
# t2912
#######################################
_lock_holder_is_wedged() {
	local _pid="$1"
	local _threshold="${WEDGE_THRESHOLD_SECONDS:-1800}"  # 30 min default
	local _log="${LOG_FILE:-$HOME/.aidevops/logs/auto-update.log}"

	# Belt-and-braces: process must be alive for a wedge to be possible.
	kill -0 "$_pid" 2>/dev/null || return 1

	# No log file = nothing to measure progress against.
	# Conservative: assume not wedged rather than force-killing blindly.
	[[ -f "$_log" ]] || return 1

	# Modification time of the log file proxies "last sign of life".
	# Use Darwin without quotes in [[ ]] — RHS is not word-split, no SC warning.
	local _log_mtime
	local _now
	local _idle
	_log_mtime=$(_file_mtime_epoch "$_log")
	_now=$(date +%s)
	_idle=$(( _now - _log_mtime ))

	if [[ "$_idle" -gt "$_threshold" ]]; then
		return 0
	fi
	return 1
}

acquire_lock() {
	local max_wait=30
	local waited=0

	while [[ $waited -lt $max_wait ]]; do
		if mkdir "$LOCK_FILE" 2>/dev/null; then
			echo $$ >"$LOCK_FILE/pid"
			return 0
		fi

		# Check for stale lock
		if [[ -f "$LOCK_FILE/pid" ]]; then
			local lock_pid
			lock_pid=$(cat "$LOCK_FILE/pid" 2>/dev/null || echo "")
			# t2421: command-aware liveness — bare kill -0 lies on macOS PID reuse
			if [[ -n "$lock_pid" ]] && ! _is_process_alive_and_matches "$lock_pid" "${FRAMEWORK_PROCESS_PATTERN:-}"; then
				log_warn "Removing stale lock (PID $lock_pid dead or reused, t2421)"
				rm -rf "$LOCK_FILE"
				continue
			# t2912: wedge detection — process alive but log has had no activity
			# beyond WEDGE_THRESHOLD_SECONDS (default 1800s / 30 min).
			elif [[ -n "$lock_pid" ]] && _lock_holder_is_wedged "$lock_pid"; then
				local _wedge_thr="${WEDGE_THRESHOLD_SECONDS:-1800}"
				log_warn "Wedged lock holder detected (PID $lock_pid alive but no log progress in ${_wedge_thr}s) — force-releasing (t2912)"
				kill -TERM "$lock_pid" 2>/dev/null || true
				sleep 2
				kill -KILL "$lock_pid" 2>/dev/null || true
				rm -rf "$LOCK_FILE"
				"${SCRIPT_DIR}/audit-log-helper.sh" log "lock.wedge-recovery" "auto-update wedged lock (PID $lock_pid) force-released after ${_wedge_thr}s with no log progress" 2>/dev/null || true
				continue
			fi
		fi

		# Check lock age (safety net for orphaned locks)
		if [[ -d "$LOCK_FILE" ]]; then
			local lock_age
			lock_age=$(($(date +%s) - $(_file_mtime_epoch "$LOCK_FILE")))
			if [[ $lock_age -gt 300 ]]; then
				log_warn "Removing stale lock (age ${lock_age}s > 300s)"
				rm -rf "$LOCK_FILE"
				continue
			fi
		fi

		sleep 1
		waited=$((waited + 1))
	done

	log_error "Failed to acquire lock after ${max_wait}s"
	return 1
}

release_lock() {
	rm -rf "$LOCK_FILE"
	return 0
}

#######################################
# Get local version
#######################################
get_local_version() {
	local version_file="$INSTALL_DIR/VERSION"
	if [[ -r "$version_file" ]]; then
		cat "$version_file"
	else
		echo "unknown"
	fi
	return 0
}

#######################################
# Get remote version (from GitHub API)
# Tries authenticated gh api first (5000 req/hr), then unauthenticated curl
# (60 req/hr), then raw.githubusercontent.com CDN fallback.
# See: #4142 — 106 "remote=unknown" failures from rate-limited unauth API
#######################################
get_remote_version() {
	local version=""

	# Prefer authenticated gh api (higher rate limit: 5000/hr vs 60/hr)
	# This avoids the "remote=unknown" failures seen during overnight polling
	# when unauthenticated API quota is exhausted.
	# See: https://github.com/marcusquinn/aidevops/issues/4142
	if command -v gh &>/dev/null && gh auth status &>/dev/null; then
		version=$(gh api repos/marcusquinn/aidevops/contents/VERSION \
			--jq '.content' 2>/dev/null |
			base64 -d 2>/dev/null |
			tr -d '\n')
		if [[ -n "$version" ]]; then
			echo "$version"
			return 0
		fi
	fi

	# Fallback: unauthenticated curl (60 req/hr limit)
	if command -v jq &>/dev/null; then
		version=$(curl --proto '=https' -fsSL --max-time 10 \
			"https://api.github.com/repos/marcusquinn/aidevops/contents/VERSION" 2>/dev/null |
			jq -r '.content // empty' 2>/dev/null |
			base64 -d 2>/dev/null |
			tr -d '\n')
		if [[ -n "$version" ]]; then
			echo "$version"
			return 0
		fi
	fi

	# Last resort: raw.githubusercontent.com (CDN-cached, may be up to 5 min stale)
	curl --proto '=https' -fsSL --max-time 10 \
		"https://raw.githubusercontent.com/marcusquinn/aidevops/main/VERSION" 2>/dev/null |
		tr -d '\n' || echo "unknown"
	return 0
}

#######################################
# Check if setup.sh or aidevops update is already running
#######################################
is_update_running() {
	# Check for running setup.sh processes (not our own)
	# Use full path to avoid matching unrelated projects' setup.sh scripts
	if pgrep -f "${INSTALL_DIR}/setup\.sh" >/dev/null 2>&1; then
		return 0
	fi
	# Check for running aidevops update
	if pgrep -f "aidevops update" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

#######################################
# Update state file with last check/update info
#######################################
update_state() {
	local action="$1"
	local version="${2:-}"
	local status="${3:-success}"
	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	if command -v jq &>/dev/null; then
		local tmp_state
		tmp_state=$(mktemp)
		trap 'rm -f "${tmp_state:-}"' RETURN

		if [[ -f "$STATE_FILE" ]]; then
			jq --arg action "$action" \
				--arg version "$version" \
				--arg status "$status" \
				--arg ts "$timestamp" \
				'. + {
                   last_action: $action,
                   last_version: $version,
                   last_status: $status,
                   last_timestamp: $ts
               } | if $action == "update" and $status == "success" then
                   . + {last_update: $ts, last_update_version: $version}
               else . end' "$STATE_FILE" >"$tmp_state" 2>/dev/null && mv "$tmp_state" "$STATE_FILE"
		else
			jq -n --arg action "$action" \
				--arg version "$version" \
				--arg status "$status" \
				--arg ts "$timestamp" \
				'{
                      enabled: true,
                      last_action: $action,
                      last_version: $version,
                      last_status: $status,
                      last_timestamp: $ts,
                      last_skill_check: null,
                      skill_updates_applied: 0
                  }' >"$STATE_FILE"
		fi
	fi
	return 0
}

#######################################
# Source freshness sub-library — all periodic freshness checks (skills,
# OpenClaw, tools, upstream watch, venv health, launchd plist drift).
# Extracted to keep this file under the file-size-debt threshold.
#######################################
# shellcheck source=./auto-update-freshness-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/auto-update-freshness-lib.sh"

_auto_update_runtime_bundle_root() {
	local agents_path="${AIDEVOPS_AGENTS_DIR:-${HOME}/.aidevops/agents}"
	[[ -d "$agents_path" ]] || return 1
	(cd "$agents_path" && pwd -P) || return 1
	return 0
}

_auto_update_runtime_bundle_valid() {
	local agents_root="$1"
	local expected_version="$2"
	local deployed_version=""
	[[ -d "$agents_root/scripts" && -x "$agents_root/aidevops.sh" && -r "$agents_root/.bundle-manifest" ]] || return 1
	grep -q '^status=validated$' "$agents_root/.bundle-manifest" || return 1
	IFS= read -r deployed_version <"$agents_root/VERSION" || deployed_version=""
	[[ -n "$expected_version" && "$deployed_version" == "$expected_version" ]]
	return $?
}

_auto_update_rollback_runtime_bundle() {
	local requested_root="$1"
	local rollback_reason="${2:-automatic update failure recovery}"
	local previous_link="${HOME}/.aidevops/previous-runtime-bundle"
	local rollback_root="$requested_root"
	local bundles_root="${HOME}/.aidevops/runtime-bundles"
	local rollback_helper="${SCRIPT_DIR}/runtime-bundle-rollback-helper.sh"
	local bundle_id=""
	if [[ ! -d "$rollback_root/scripts" && -d "$previous_link/scripts" ]]; then
		rollback_root=$(cd "$previous_link" && pwd -P) || rollback_root=""
	fi
	[[ -n "$rollback_root" && -d "$rollback_root/scripts" && -f "$rollback_helper" ]] || return 1
	bundles_root=$(cd "$bundles_root" 2>/dev/null && pwd -P) || return 1
	rollback_root=$(cd "$rollback_root" 2>/dev/null && pwd -P) || return 1
	case "$rollback_root" in
	"$bundles_root"/*/agents) ;;
	*) return 1 ;;
	esac
	bundle_id="${rollback_root%/agents}"
	bundle_id="${bundle_id##*/}"
	AIDEVOPS_INSTALL_DIR="$INSTALL_DIR" bash "$rollback_helper" rollback \
		--bundle-id "$bundle_id" --reason "$rollback_reason" --automatic || return 1
	log_warn "Rolled back runtime activation to retained bundle $bundle_id"
	return 0
}

_run_setup_ai_session_with_fallback() {
	local setup_script="${INSTALL_DIR}/setup.sh"
	if bash "$setup_script" --stage ai-session >>"$LOG_FILE" 2>&1; then
		return 0
	fi
	log_warn "AI-session incremental setup failed or is unavailable; retrying full setup"
	bash "$setup_script" --non-interactive >>"$LOG_FILE" 2>&1
	return $?
}

#######################################
# Handle stale deployed agents when repo version matches remote.
# Checks VERSION mismatch and sentinel script hash drift; re-deploys if needed.
# Args: $1 = current version string
#######################################
_cmd_check_stale_agent_redeploy() {
	local current="$1"

	# Even when repo matches remote, deployed agents may be stale
	# (e.g., previous setup.sh was interrupted or failed silently)
	# See: https://github.com/marcusquinn/aidevops/issues/3980
	local deployed_version
	deployed_version=$(cat "$HOME/.aidevops/agents/VERSION" 2>/dev/null || echo "none")
	if [[ "$current" != "$deployed_version" ]]; then
		log_warn "Deployed agents stale ($deployed_version), re-deploying..."
		if _run_setup_ai_session_with_fallback; then
			local redeployed_version
			redeployed_version=$(cat "$HOME/.aidevops/agents/VERSION" 2>/dev/null || echo "none")
			if [[ "$current" == "$redeployed_version" ]]; then
				log_info "Agents re-deployed successfully ($deployed_version -> $redeployed_version)"
			else
				log_error "Agent re-deploy incomplete: repo=$current, deployed=$redeployed_version"
			fi
		else
			log_error "setup.sh failed during stale-agent re-deploy (exit code: $?)"
		fi
		return 0
	fi

	# t2706: VERSION matches but scripts may still differ — a script fix merged
	# without a version bump leaves the deployed copy stale until setup.sh is
	# run manually. Previous implementation checked SHA-256 of a single sentinel
	# file (gh-failure-miner-helper.sh); that missed drift in any OTHER file
	# (e.g., PR #20323 fixed pulse-batch-prefetch-helper.sh — sentinel was blind
	# to it, and the pulse kept hitting the bug for ~14h while VERSION matched).
	# Replacement: compare the canonical HEAD SHA against ~/.aidevops/.deployed-sha
	# (written by .agents/scripts/setup/modules/agent-deploy.sh on every successful deploy).
	# Docs-only drift (reference/, *.md) is intentionally skipped — no runtime
	# impact and redeploying for docs wastes cycles.
	# GH#4727: Codacy not_collected false-positive recurred because the fix in
	# PR #4704 was not deployed to ~/.aidevops/ before the next pulse cycle.
	local stamp_file="$HOME/.aidevops/.deployed-sha"
	if [[ -f "$stamp_file" && -d "$INSTALL_DIR/.git" ]]; then
		local deployed_sha head_sha
		deployed_sha=$(tr -d '[:space:]' <"$stamp_file" 2>/dev/null) || deployed_sha=""
		head_sha=$(git -C "$INSTALL_DIR" rev-parse HEAD 2>/dev/null) || head_sha=""
		if [[ -n "$deployed_sha" && -n "$head_sha" && "$deployed_sha" != "$head_sha" ]]; then
			local has_code_drift=0
			# Per Gemini code-review on PR #20342: use git's path filter +
			# `grep -q .` to detect drift across the full set of deploy-affecting
			# paths (not just .agents/ subdirs — also setup.sh, .agents/scripts/setup/modules/,
			# and aidevops.sh itself, which are deployed/sourced by setup).
			if git -C "$INSTALL_DIR" diff --name-only "$deployed_sha" "$head_sha" -- \
				.agents/scripts/ .agents/agents/ .agents/workflows/ .agents/prompts/ .agents/hooks/ \
				setup.sh .agents/scripts/setup/modules/ aidevops.sh 2>/dev/null | grep -q .; then
				has_code_drift=1
			fi
			if [[ "$has_code_drift" -eq 1 ]]; then
				log_warn "Script drift detected (${deployed_sha:0:7}→${head_sha:0:7} at v$current) — re-deploying agents..."
				if _run_setup_ai_session_with_fallback; then
					log_info "Agents re-deployed after script drift (${deployed_sha:0:7}→${head_sha:0:7})"
				else
					log_error "setup.sh failed during script-drift re-deploy (exit code: $?)"
				fi
			fi
		fi
	fi
	return 0
}

#######################################
# Fetch and fast-forward INSTALL_DIR to the exact origin/main commit.
# Fails closed on tracked work, local history, branch, or merge problems.
# Args: $1 = remote version (for state updates on failure)
# Returns: 0 on success, 1 on unrecoverable failure
#######################################
_cmd_check_git_update() {
	local remote="$1"

	# Fetch before evaluating local blockers. A same-version release can still
	# contain merged script fixes, so VERSION equality is not freshness proof.
	if ! git -C "$INSTALL_DIR" fetch origin main --quiet 2>>"$LOG_FILE"; then
		log_error "git fetch failed"
		update_state "update" "$remote" "fetch_failed"
		return 1
	fi
	local local_hash=""
	local remote_hash=""
	local_hash=$(git -C "$INSTALL_DIR" rev-parse HEAD 2>>"$LOG_FILE") || return 1
	remote_hash=$(git -C "$INSTALL_DIR" rev-parse origin/main 2>>"$LOG_FILE") || return 1
	# The install checkout may contain deliberate local fixes or diagnostics.
	# Preserve them and record that they are blocking activation of upstream.
	if ! git -C "$INSTALL_DIR" diff --quiet 2>/dev/null || ! git -C "$INSTALL_DIR" diff --cached --quiet 2>/dev/null; then
		local dirty_status="local_changes"
		if [[ "$local_hash" != "$remote_hash" ]]; then
			dirty_status="runtime_stale_local_changes"
		fi
		log_warn "Skipping update because tracked local changes exist in the canonical checkout"
		git -C "$INSTALL_DIR" status --short >>"$LOG_FILE" 2>&1 || true
		update_state "update" "$remote" "$dirty_status"
		return 1
	fi
	local current_branch=""
	current_branch=$(git -C "$INSTALL_DIR" branch --show-current 2>/dev/null || true)
	if [[ "$current_branch" != "main" ]]; then
		log_error "Runtime is stale because the canonical checkout is not on main"
		update_state "update" "$remote" "runtime_stale_branch"
		return 1
	fi
	if [[ "$local_hash" == "$remote_hash" ]]; then
		return 0
	fi

	if git -C "$INSTALL_DIR" merge-base --is-ancestor "$remote_hash" "$local_hash" 2>/dev/null; then
		log_error "Local commits exist on main; refusing unattended update"
		update_state "update" "$remote" "runtime_stale_local_commits"
		return 1
	fi
	if ! git -C "$INSTALL_DIR" merge-base --is-ancestor "$local_hash" "$remote_hash" 2>/dev/null; then
		log_error "Canonical main has diverged from origin/main; refusing unattended update"
		update_state "update" "$remote" "runtime_stale_diverged"
		return 1
	fi

	if ! git -C "$INSTALL_DIR" merge --ff-only "$remote_hash" --quiet 2>>"$LOG_FILE"; then
		log_error "git merge --ff-only failed; preserving local history"
		update_state "update" "$remote" "pull_failed"
		return 1
	fi
	local_hash=$(git -C "$INSTALL_DIR" rev-parse HEAD 2>>"$LOG_FILE") || return 1
	if [[ "$local_hash" != "$remote_hash" ]]; then
		log_error "Updated HEAD does not match fetched origin/main; refusing to run setup"
		update_state "update" "$remote" "history_mismatch"
		return 1
	fi
	return 0
}

#######################################
# Perform the actual update: git pull, setup.sh deploy, verify, cleanup.
# Args: $1 = current version, $2 = remote version
# Returns: 0 on success, 1 on failure
#######################################
_cmd_check_perform_update() {
	local current="$1"
	local remote="$2"
	local prior_bundle_root=""

	log_info "Update available: v$current -> v$remote"
	update_state "update_start" "$remote" "in_progress"

	# Verify install directory exists and is a git repo
	if [[ ! -d "$INSTALL_DIR/.git" ]]; then
		log_error "Install directory is not a git repo: $INSTALL_DIR"
		update_state "update" "$remote" "no_git_repo"
		return 1
	fi
	prior_bundle_root=$(_auto_update_runtime_bundle_root 2>/dev/null || true)

	if ! _cmd_check_git_update "$remote"; then
		return 1
	fi

	# Run setup with an incremental first pass; setup.sh falls back to full setup
	# when changed setup logic cannot be applied safely.
	log_info "Running setup.sh --stage ai-session..."
	local _setup_exit=0
	_run_setup_ai_session_with_fallback || _setup_exit=$?

	# GH#21060 / t2911: Log slowest 5 stages from this run so that
	# "tail -50 ~/.aidevops/logs/auto-update.log | grep Slowest" is
	# sufficient to diagnose which stage hung, without bash -x re-runs.
	local _stl="$HOME/.aidevops/logs/setup-stage-timings.log"
	if [[ -f "$_stl" ]]; then
		log_info "Slowest stages this cycle:"
		sort -k3 -t$'\t' -rn "$_stl" | head -5 | while IFS=$'\t' read -r _ts _name _dur _exit_code; do
			log_info "  ${_dur}s ${_name} (exit=${_exit_code})"
		done
	fi

	# GH#18492 / t2026: verify the completion sentinel regardless of exit
	# code. "exit non-zero AND no sentinel" is the t2022-class silent
	# termination (e.g., a sourced helper's set -e propagates a readonly
	# assignment failure that kills the parent script mid-run). "exit 0 but
	# no sentinel" would indicate a subshell swallowed a failure — rare but
	# possible, and we want to catch it as a distinct anomaly.
	#
	# Capture the verifier's combined output into a variable first, then
	# append to the log file, to avoid a read-write-in-pipeline warning
	# (SC2094). The verifier reads $LOG_FILE; setup.sh has already finished
	# writing to it by this point so there's no real race, but capturing
	# keeps shellcheck happy and is clearer.
	local _sentinel_ok=0
	local _verifier="$INSTALL_DIR/.agents/scripts/verify-setup-log.sh"
	if [[ -x "$_verifier" ]]; then
		local _verify_out=""
		_verify_out=$(bash "$_verifier" "$LOG_FILE" 2>&1) || _sentinel_ok=$?
		if [[ -n "$_verify_out" ]]; then
			printf '%s\n' "$_verify_out" >>"$LOG_FILE"
		fi
	fi

	if [[ "$_setup_exit" -ne 0 ]]; then
		log_error "setup.sh failed (exit code: $_setup_exit)"
		_auto_update_rollback_runtime_bundle "$prior_bundle_root" "setup failed during automatic update" || true
		if [[ "$_sentinel_ok" -ne 0 ]]; then
			log_error "setup.sh did not reach completion sentinel — forensic tail written to $LOG_FILE by verify-setup-log.sh"
		fi
		update_state "update" "$remote" "setup_failed"
		return 1
	fi

	if [[ "$_sentinel_ok" -ne 0 ]]; then
		log_error "setup.sh exited 0 but did not reach completion sentinel — silent termination, forensic tail in $LOG_FILE"
		_auto_update_rollback_runtime_bundle "$prior_bundle_root" "setup completion sentinel was missing" || true
		update_state "update" "$remote" "setup_sentinel_missing"
		return 1
	fi

	# Verify agents were actually deployed (setup.sh may exit 0 without deploying)
	# See: https://github.com/marcusquinn/aidevops/issues/3980
	local new_version deployed_version
	new_version=$(get_local_version)
	local active_bundle_root=""
	active_bundle_root=$(_auto_update_runtime_bundle_root 2>/dev/null || true)
	deployed_version=$(cat "$HOME/.aidevops/agents/VERSION" 2>/dev/null || echo "none")
	if [[ "$new_version" != "$deployed_version" ]] ||
		! _auto_update_runtime_bundle_valid "$active_bundle_root" "$new_version"; then
		log_warn "Update pulled v$new_version but agents at v$deployed_version — deployment incomplete"
		_auto_update_rollback_runtime_bundle "$prior_bundle_root" "deployed agents failed automatic update verification" || true
		update_state "update" "$new_version" "agents_stale"
	else
		log_info "Update complete: v$current -> v$new_version (agents deployed)"
		update_state "update" "$new_version" "success"
	fi

	return 0
}

#######################################
# One-shot check and update
# This is what the cron job calls
#######################################
#######################################
# Acquire lock and verify preconditions for cmd_check.
# Returns: 0 if ready to proceed, 1 if should skip
#######################################
_cmd_check_acquire() {
	# Respect config (env var or config file)
	if ! is_feature_enabled auto_update 2>/dev/null; then
		log_info "Auto-update disabled via config (updates.auto_update)"
		return 1
	fi

	# Skip if another update is already running
	if is_update_running; then
		log_info "Another update process is running, skipping"
		return 1
	fi

	# Acquire lock
	if ! acquire_lock; then
		log_warn "Could not acquire lock, skipping check"
		return 1
	fi
	return 0
}

cmd_check() {
	ensure_dirs

	if ! _cmd_check_acquire; then
		return 0
	fi
	trap 'release_lock' EXIT

	local current remote
	current=$(get_local_version)
	remote=$(get_remote_version)
	log_info "Version check: local=$current remote=$remote"

	if [[ "$current" == "unknown" || "$remote" == "unknown" ]]; then
		log_warn "Could not determine versions (local=$current, remote=$remote)"
		update_state "check" "$current" "version_unknown"
		run_freshness_checks
		return 0
	fi

	if [[ "$current" == "$remote" ]]; then
		log_info "Version matches upstream (v$current); verifying commit freshness"
		if ! _cmd_check_git_update "$remote"; then
			run_freshness_checks
			return 1
		fi
		update_state "check" "$current" "up_to_date"
		_cmd_check_stale_agent_redeploy "$current"
		run_freshness_checks
		return 0
	fi

	if ! _cmd_check_perform_update "$current" "$remote"; then
		run_freshness_checks
		return 1
	fi

	run_freshness_checks
	return 0
}

#######################################
# Install auto-update as a macOS LaunchAgent
# Args: $1 = script_path, $2 = interval (minutes)
# Returns: 0 on success, 1 on failure
#######################################
_cmd_enable_launchd() {
	local script_path="$1"
	local interval="$2"
	local interval_seconds=$((interval * 60))

	# Migrate from old label if present (t1260)
	local old_label="com.aidevops.auto-update"
	local old_plist="${LAUNCHD_DIR}/${old_label}.plist"
	if launchctl list 2>/dev/null | grep -qF "$old_label"; then
		launchctl unload -w "$old_plist" 2>/dev/null || true
		log_info "Unloaded old LaunchAgent: $old_label"
	fi
	rm -f "$old_plist"

	# Auto-migrate existing cron entry if present
	_migrate_cron_to_launchd "$script_path" "$interval_seconds"

	mkdir -p "$LAUNCHD_DIR"

	# Create named symlink so macOS System Settings shows "aidevops-auto-update"
	# instead of the raw script name (t1260)
	local bin_dir="$HOME/.aidevops/bin"
	mkdir -p "$bin_dir"
	local display_link="$bin_dir/aidevops-auto-update"
	aidevops_ensure_symlink_target "$script_path" "$display_link" || return 1

	# Generate plist content and compare to existing (t1265)
	local new_content
	new_content=$(_generate_auto_update_plist "$display_link" "$interval_seconds" "${PATH}")

	# Skip if already loaded with identical config (avoids macOS notification)
	if _launchd_is_loaded && [[ -f "$LAUNCHD_PLIST" ]]; then
		local existing_content
		existing_content=$(cat "$LAUNCHD_PLIST" 2>/dev/null) || existing_content=""
		if [[ "$existing_content" == "$new_content" ]]; then
			print_info "Auto-update LaunchAgent already installed with identical config ($LAUNCHD_LABEL)"
			update_state "enable" "$(get_local_version)" "enabled"
			return 0
		fi
		# Loaded but config differs — don't overwrite while running
		print_info "Auto-update LaunchAgent already loaded ($LAUNCHD_LABEL)"
		update_state "enable" "$(get_local_version)" "enabled"
		return 0
	fi

	echo "$new_content" >"$LAUNCHD_PLIST"

	if launchctl load -w "$LAUNCHD_PLIST" 2>/dev/null; then
		update_state "enable" "$(get_local_version)" "enabled"
		print_success "Auto-update enabled (every ${interval} minutes)"
		echo ""
		echo "  Scheduler: launchd (macOS LaunchAgent)"
		echo "  Label:     $LAUNCHD_LABEL"
		echo "  Plist:     $LAUNCHD_PLIST"
		echo "  Script:    $script_path"
		echo "  Logs:      $LOG_FILE"
		echo ""
		echo "  Disable with: aidevops auto-update disable"
		echo "  Check now:    aidevops auto-update check"
	else
		print_error "Failed to load LaunchAgent: $LAUNCHD_LABEL"
		return 1
	fi
	return 0
}

#######################################
# Install auto-update as a Linux systemd user timer
# Args: $1 = script_path, $2 = interval (minutes)
# Returns: 0 on success, falls back to cron on failure
# Modelled on worker-watchdog.sh:_install_systemd() (GH#17691)
#######################################
_cmd_enable_systemd() {
	local script_path="$1"
	local interval="$2"
	local service_file="${SYSTEMD_SERVICE_DIR}/${SYSTEMD_UNIT_NAME}.service"
	local timer_file="${SYSTEMD_SERVICE_DIR}/${SYSTEMD_UNIT_NAME}.timer"
	local interval_sec
	interval_sec=$((interval * 60))

	mkdir -p "${SYSTEMD_SERVICE_DIR}"

	# shellcheck disable=SC1078,SC1079  # multi-line printf with single quotes inside a double-quoted string; \"${script_path}\" expands to "path" in the service file, preserving space-safe quoting
	printf '%s' "[Unit]
Description=aidevops auto-update
After=network.target

[Service]
Type=oneshot
KillMode=control-group
ExecStart=/bin/bash -lc '\"${script_path}\" check'
TimeoutStartSec=120
Nice=10
IOSchedulingClass=idle
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}
" >"$service_file"

	printf '%s' "[Unit]
Description=aidevops auto-update Timer

[Timer]
OnBootSec=${interval_sec}
OnUnitActiveSec=${interval_sec}
Persistent=true

[Install]
WantedBy=timers.target
" >"$timer_file"

	systemctl --user daemon-reload 2>/dev/null || true
	if ! systemctl --user enable --now "${SYSTEMD_UNIT_NAME}.timer" 2>/dev/null; then
		print_error "Failed to enable systemd timer — falling back to cron" >&2
		_cmd_enable_cron "$script_path" "$interval"
		return $?
	fi

	_remove_auto_update_cron_duplicate
	update_state "enable" "$(get_local_version)" "enabled"

	print_success "Auto-update enabled (every ${interval} minutes)"
	echo ""
	echo "  Scheduler: systemd user timer"
	echo "  Unit:      ${SYSTEMD_UNIT_NAME}.timer"
	echo "  Service:   ${service_file}"
	echo "  Timer:     ${timer_file}"
	echo "  Logs:      ${LOG_FILE}"
	echo ""
	echo "  Disable with: aidevops auto-update disable"
	echo "  Check now:    aidevops auto-update check"
	echo ""
	# Check linger state so the timer survives logout on headless/server Linux hosts.
	_print_linger_status
	return 0
}

#######################################
# Disable auto-update systemd user timer
# Returns: 0 on success
#######################################
_cmd_disable_systemd() {
	local had_entry=false

	if systemctl --user is-enabled "${SYSTEMD_UNIT_NAME}.timer" >/dev/null 2>&1; then
		had_entry=true
		systemctl --user disable --now "${SYSTEMD_UNIT_NAME}.timer" 2>/dev/null || true
	fi

	local service_file="${SYSTEMD_SERVICE_DIR}/${SYSTEMD_UNIT_NAME}.service"
	local timer_file="${SYSTEMD_SERVICE_DIR}/${SYSTEMD_UNIT_NAME}.timer"
	if [[ -f "$timer_file" ]]; then
		had_entry=true
		rm -f "$timer_file"
	fi
	if [[ -f "$service_file" ]]; then
		rm -f "$service_file"
	fi
	systemctl --user daemon-reload 2>/dev/null || true

	# Also remove any lingering cron entry
	if crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
		local temp_cron
		temp_cron=$(mktemp)
		crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" >"$temp_cron" || true
		crontab "$temp_cron"
		rm -f "$temp_cron"
		had_entry=true
	fi

	update_state "disable" "$(get_local_version)" "disabled"

	if [[ "$had_entry" == "true" ]]; then
		print_success "Auto-update disabled"
	else
		print_info "Auto-update was not enabled"
	fi
	return 0
}

#######################################
# Install auto-update as a Linux cron entry
# Args: $1 = script_path, $2 = interval (minutes)
# Returns: 0 on success
#######################################
_cmd_enable_cron() {
	local script_path="$1"
	local interval="$2"

	# Build cron expression
	local cron_expr="*/${interval} * * * *"
	local cron_line="$cron_expr $script_path check >> $LOG_FILE 2>&1 $CRON_MARKER"

	# Get existing crontab (excluding our entry)
	local temp_cron
	temp_cron=$(mktemp)
	trap 'rm -f "${temp_cron:-}"' RETURN

	crontab -l 2>/dev/null | grep -v "$CRON_MARKER" >"$temp_cron" || true

	# Add our entry and install
	echo "$cron_line" >>"$temp_cron"
	crontab "$temp_cron"
	rm -f "$temp_cron"

	update_state "enable" "$(get_local_version)" "enabled"

	print_success "Auto-update enabled (every ${interval} minutes)"
	echo ""
	echo "  Schedule: $cron_expr"
	echo "  Script:   $script_path"
	echo "  Logs:     $LOG_FILE"
	echo ""
	echo "  Disable with: aidevops auto-update disable"
	echo "  Check now:    aidevops auto-update check"
	return 0
}

#######################################
# Enable auto-update scheduler (platform-aware)
# On macOS: installs LaunchAgent plist
# On Linux: installs crontab entry
#######################################
cmd_enable() {
	ensure_dirs

	# Parse flags (t2898): --idempotent skips the install when already loaded.
	# Existing callers retain the same behaviour because no flag = legacy path.
	local idempotent=0
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--idempotent)
			idempotent=1
			shift
			;;
		--)
			shift
			break
			;;
		*)
			# Forward unknown args to platform installers (none today).
			break
			;;
		esac
	done

	# Idempotent fast-path: if the daemon is already loaded (regardless of
	# state-file freshness), this is a no-op. setup.sh calls this on every
	# release so the daemon self-heals — but the existing user state must
	# survive (custom intervals, env vars). "Loaded but stalled" is also a
	# no-op here; the caller follows up with `health-check` to surface it.
	if [[ "$idempotent" -eq 1 ]] && _daemon_is_loaded; then
		log_info "auto-update daemon already loaded (idempotent enable — no-op)"
		return 0
	fi

	# Read from JSONC config (handles env var > user config > defaults priority)
	local interval
	interval=$(get_feature_toggle update_interval "$DEFAULT_INTERVAL")
	# Validate interval is a positive integer
	if ! [[ "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -eq 0 ]]; then
		log_warn "updates.update_interval_minutes='${interval}' is not a positive integer — using default (${DEFAULT_INTERVAL}m)"
		interval="$DEFAULT_INTERVAL"
	fi
	local script_path="$HOME/.aidevops/agents/scripts/auto-update-helper.sh"

	# Verify the script exists at the deployed location
	if [[ ! -x "$script_path" ]]; then
		# Fall back to repo location
		script_path="$INSTALL_DIR/.agents/scripts/auto-update-helper.sh"
		if [[ ! -x "$script_path" ]]; then
			print_error "auto-update-helper.sh not found"
			return 1
		fi
	fi

	local backend
	backend="$(_get_scheduler_backend)"

	if [[ "$backend" == "launchd" ]]; then
		_cmd_enable_launchd "$script_path" "$interval"
		return $?
	elif [[ "$backend" == "systemd" ]]; then
		_cmd_enable_systemd "$script_path" "$interval"
		return $?
	fi

	_cmd_enable_cron "$script_path" "$interval"
	return $?
}

#######################################
# Disable auto-update scheduler (platform-aware)
# On macOS: unloads and removes LaunchAgent plist
# On Linux: removes crontab entry or systemd timer
#######################################
cmd_disable() {
	local backend
	backend="$(_get_scheduler_backend)"

	if [[ "$backend" == "launchd" ]]; then
		local had_entry=false

		if _launchd_is_loaded; then
			had_entry=true
			launchctl unload -w "$LAUNCHD_PLIST" 2>/dev/null || true
		fi

		if [[ -f "$LAUNCHD_PLIST" ]]; then
			had_entry=true
			rm -f "$LAUNCHD_PLIST"
		fi

		# Also remove any lingering cron entry (migration cleanup)
		if crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
			local temp_cron
			temp_cron=$(mktemp)
			crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" >"$temp_cron" || true
			crontab "$temp_cron"
			rm -f "$temp_cron"
			had_entry=true
		fi

		update_state "disable" "$(get_local_version)" "disabled"

		if [[ "$had_entry" == "true" ]]; then
			print_success "Auto-update disabled"
		else
			print_info "Auto-update was not enabled"
		fi
		return 0
	elif [[ "$backend" == "systemd" ]]; then
		_cmd_disable_systemd
		return $?
	fi

	# Linux: cron backend
	local temp_cron
	temp_cron=$(mktemp)
	trap 'rm -f "${temp_cron:-}"' RETURN

	local had_entry=false
	if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
		had_entry=true
	fi

	crontab -l 2>/dev/null | grep -v "$CRON_MARKER" >"$temp_cron" || true
	crontab "$temp_cron"
	rm -f "$temp_cron"

	update_state "disable" "$(get_local_version)" "disabled"

	if [[ "$had_entry" == "true" ]]; then
		print_success "Auto-update disabled"
	else
		print_info "Auto-update was not enabled"
	fi
	return 0
}

#######################################
# Print linger status row for systemd user timer.
# Linger allows the user manager to keep running after logout.
# Skips silently when loginctl is absent (containers) or when user is root.
# Args: none. Reads $USER from environment.
# Returns: 0
#######################################
_print_linger_status() {
	[[ "${USER:-}" == "root" ]] && return 0
	command -v loginctl &>/dev/null || return 0
	local _linger_state _linger_cmd
	_linger_state=$(loginctl show-user "$USER" -p Linger --value 2>/dev/null || true)
	_linger_cmd="sudo loginctl enable-linger $USER"
	if [[ "$_linger_state" == "yes" ]]; then
		echo -e "  Linger:    ${GREEN}yes${NC}"
	elif [[ "$_linger_state" == "no" ]]; then
		echo -e "  Linger:    ${YELLOW}no${NC} — timer stops on logout; fix: ${_linger_cmd}"
	else
		echo -e "  Linger:    ${YELLOW}unknown${NC} — run: ${_linger_cmd}"
	fi
	return 0
}

#######################################
# Print scheduler section of status output (launchd, systemd, or cron)
# Args: $1 = backend ("launchd", "systemd", or "cron")
#######################################
_cmd_status_scheduler() {
	local backend="$1"

	if [[ "$backend" == "launchd" ]]; then
		# macOS: show LaunchAgent status
		if _launchd_is_loaded; then
			local launchctl_info
			launchctl_info=$(launchctl list 2>/dev/null | grep -F "$LAUNCHD_LABEL" || true)
			local pid exit_code interval
			pid=$(echo "$launchctl_info" | awk '{print $1}')
			exit_code=$(echo "$launchctl_info" | awk '{print $2}')
			echo -e "  Scheduler: launchd (macOS LaunchAgent)"
			echo -e "  Status:    ${GREEN}loaded${NC}"
			echo "  Label:     $LAUNCHD_LABEL"
			echo "  PID:       ${pid:--}"
			echo "  Last exit: ${exit_code:--}"
			if [[ -f "$LAUNCHD_PLIST" ]]; then
				interval=$(grep -A1 'StartInterval' "$LAUNCHD_PLIST" 2>/dev/null | grep integer | grep -oE '[0-9]+' || true)
				if [[ -n "$interval" ]]; then
					echo "  Interval:  every ${interval}s"
				fi
				echo "  Plist:     $LAUNCHD_PLIST"
			fi
		else
			echo -e "  Scheduler: launchd (macOS LaunchAgent)"
			echo -e "  Status:    ${YELLOW}not loaded${NC}"
			if [[ -f "$LAUNCHD_PLIST" ]]; then
				echo "  Plist:     $LAUNCHD_PLIST (exists but not loaded)"
			fi
		fi
		# Also check for any lingering cron entry
		if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
			echo -e "  ${YELLOW}Note: legacy cron entry found — run 'aidevops auto-update disable && enable' to migrate${NC}"
		fi
	elif [[ "$backend" != "cron" ]]; then
		# Linux: show systemd user timer status (backend is "systemd" or future variant)
		if ! command -v systemctl &>/dev/null; then
			echo -e "  Scheduler: systemd (not available on this host)"
		else
			local enabled_state
			enabled_state=$(systemctl --user is-enabled "${SYSTEMD_UNIT_NAME}.timer" 2>/dev/null || echo "unknown")
			local timer_props next_elapse last_trigger
			# Request all NextElapse variants: NextElapse (pre-255) and
			# NextElapseUSecRealtime/NextElapseUSecMonotonic (systemd 255+)
			timer_props=$(systemctl --user show -p NextElapse,NextElapseUSecRealtime,NextElapseUSecMonotonic,LastTriggerUSec "${SYSTEMD_UNIT_NAME}.timer" 2>/dev/null || true)
			# Guard each grep with || true — under set -euo pipefail a no-match
			# exit 1 propagates and kills the entire script (GH#21541)
			next_elapse=$(echo "$timer_props" | grep '^NextElapse=' | cut -d= -f2- || true)
			if [[ -z "$next_elapse" ]]; then
				next_elapse=$(echo "$timer_props" | grep '^NextElapseUSecRealtime=' | cut -d= -f2- || true)
			fi
			if [[ -z "$next_elapse" ]]; then
				next_elapse=$(echo "$timer_props" | grep '^NextElapseUSecMonotonic=' | cut -d= -f2- || true)
			fi
			last_trigger=$(echo "$timer_props" | grep '^LastTriggerUSec=' | cut -d= -f2- || true)
			echo -e "  Scheduler: systemd (user timer)"
			if [[ "$enabled_state" == "enabled" ]] || [[ "$enabled_state" == "enabled-runtime" ]]; then
				echo -e "  Status:    ${GREEN}${enabled_state}${NC}"
			else
				echo -e "  Status:    ${YELLOW}${enabled_state}${NC}"
			fi
			echo "  Unit:      ${SYSTEMD_UNIT_NAME}.timer"
			if [[ -n "$next_elapse" ]] && [[ "$next_elapse" != "0" ]]; then
				echo "  Next fire: $next_elapse"
			fi
			if [[ -n "$last_trigger" ]] && [[ "$last_trigger" != "0" ]]; then
				echo "  Last fire: $last_trigger"
			fi
			echo "  Timer:     ${SYSTEMD_SERVICE_DIR}/${SYSTEMD_UNIT_NAME}.timer"
			echo "  Service:   ${SYSTEMD_SERVICE_DIR}/${SYSTEMD_UNIT_NAME}.service"
			_print_linger_status
		fi
		# Also check for any lingering cron entry
		if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
			echo -e "  ${YELLOW}Note: legacy cron entry found — run 'aidevops auto-update disable && enable' to migrate${NC}"
		fi
	else
		# Linux: show cron status
		if crontab -l 2>/dev/null | grep -q "$CRON_MARKER"; then
			local cron_entry
			cron_entry=$(crontab -l 2>/dev/null | grep "$CRON_MARKER")
			echo -e "  Scheduler: cron"
			echo -e "  Status:    ${GREEN}enabled${NC}"
			echo "  Schedule:  $(echo "$cron_entry" | awk '{print $1, $2, $3, $4, $5}')"
		else
			echo -e "  Scheduler: cron"
			echo -e "  Status:    ${YELLOW}disabled${NC}"
		fi
	fi
	return 0
}

#######################################
# Print state file section of status output (last check, updates, idle)
# Reads STATE_FILE; no-op if file absent or jq unavailable.
#######################################
_cmd_status_state() {
	if ! [[ -f "$STATE_FILE" ]] || ! command -v jq &>/dev/null; then
		return 0
	fi

	local last_action last_ts last_status last_update last_update_ver last_skill_check skill_updates
	last_action=$(jq -r '.last_action // "none"' "$STATE_FILE" 2>/dev/null)
	last_ts=$(jq -r '.last_timestamp // "never"' "$STATE_FILE" 2>/dev/null)
	last_status=$(jq -r '.last_status // "unknown"' "$STATE_FILE" 2>/dev/null)
	last_update=$(jq -r '.last_update // "never"' "$STATE_FILE" 2>/dev/null)
	last_update_ver=$(jq -r '.last_update_version // "n/a"' "$STATE_FILE" 2>/dev/null)
	last_skill_check=$(jq -r '.last_skill_check // "never"' "$STATE_FILE" 2>/dev/null)
	skill_updates=$(jq -r '.skill_updates_applied // 0' "$STATE_FILE" 2>/dev/null)

	echo ""
	echo "  Last check:         $last_ts ($last_action: $last_status)"
	if [[ "$last_update" != "never" ]]; then
		echo "  Last update:        $last_update (v$last_update_ver)"
	fi
	echo "  Last skill check:   $last_skill_check"
	echo "  Skill updates:      $skill_updates applied (lifetime)"

	local last_openclaw_check
	last_openclaw_check=$(jq -r '.last_openclaw_check // "never"' "$STATE_FILE" 2>/dev/null)
	echo "  Last OpenClaw check: $last_openclaw_check"
	if command -v openclaw &>/dev/null; then
		local openclaw_ver
		openclaw_ver=$(openclaw --version 2>/dev/null | head -1 || echo "unknown")
		echo "  OpenClaw version:   $openclaw_ver"
	fi

	local last_tool_check tool_updates_applied
	last_tool_check=$(jq -r '.last_tool_check // "never"' "$STATE_FILE" 2>/dev/null)
	tool_updates_applied=$(jq -r '.tool_updates_applied // 0' "$STATE_FILE" 2>/dev/null)
	echo "  Last tool check:    $last_tool_check"
	echo "  Tool updates:       $tool_updates_applied applied (lifetime)"

	# Show current user idle time
	local idle_secs idle_h idle_m
	idle_secs=$(get_user_idle_seconds)
	idle_h=$((idle_secs / 3600))
	idle_m=$(((idle_secs % 3600) / 60))
	# Read from JSONC config (handles env var > user config > defaults priority)
	local idle_threshold
	idle_threshold=$(get_feature_toggle tool_idle_hours "$DEFAULT_TOOL_IDLE_HOURS")
	# Validate idle_threshold is a positive integer (mirrors check_tool_freshness)
	if ! [[ "$idle_threshold" =~ ^[0-9]+$ ]] || [[ "$idle_threshold" -eq 0 ]]; then
		idle_threshold="$DEFAULT_TOOL_IDLE_HOURS"
	fi
	if [[ $idle_secs -ge $((idle_threshold * 3600)) ]]; then
		echo -e "  User idle:          ${idle_h}h${idle_m}m (${GREEN}>=${idle_threshold}h — tool updates eligible${NC})"
	else
		echo -e "  User idle:          ${idle_h}h${idle_m}m (${YELLOW}<${idle_threshold}h — tool updates deferred${NC})"
	fi
	return 0
}

#######################################
# Show status (platform-aware)
#######################################
cmd_status() {
	ensure_dirs

	local current
	current=$(get_local_version)

	local backend
	backend="$(_get_scheduler_backend)"

	echo ""
	echo -e "${BOLD:-}Auto-Update Status${NC}"
	echo "-------------------"
	echo ""

	_cmd_status_scheduler "$backend"

	echo "  Version:   v$current"

	_cmd_status_state

	# Check config overrides (env var or config file)
	if ! is_feature_enabled auto_update 2>/dev/null; then
		echo ""
		echo -e "  ${YELLOW}Note: updates.auto_update disabled (overrides scheduler)${NC}"
	fi
	if ! is_feature_enabled skill_auto_update 2>/dev/null; then
		echo ""
		echo -e "  ${YELLOW}Note: updates.skill_auto_update disabled${NC}"
	fi
	if ! is_feature_enabled openclaw_auto_update 2>/dev/null; then
		echo ""
		echo -e "  ${YELLOW}Note: updates.openclaw_auto_update disabled${NC}"
	fi
	if ! is_feature_enabled tool_auto_update 2>/dev/null; then
		echo ""
		echo -e "  ${YELLOW}Note: updates.tool_auto_update disabled${NC}"
	fi

	echo ""
	return 0
}

#######################################
# Daemon-loaded check (platform-aware) — t2898.
# Returns 0 if the auto-update daemon is loaded/installed under the active
# scheduler backend, 1 otherwise. Mirrors the platform detection in
# `_cmd_status_scheduler` but without the human-readable output.
#
# This is a "is the unit registered" check, not a "did it run recently"
# check. For freshness, see `cmd_health_check` which combines both.
#######################################
_daemon_is_loaded() {
	local backend
	backend="$(_get_scheduler_backend)"

	if [[ "$backend" == "launchd" ]]; then
		_launchd_is_loaded
		return $?
	fi

	if [[ "$backend" == "systemd" ]]; then
		# `is-active --quiet` is true when the timer is running (loaded AND
		# enabled in this session). Falls back to `is-enabled` for the case
		# where the timer is registered but the user just hasn't started it
		# yet (e.g. fresh setup before logout/login). Either is fine for
		# "the daemon is registered with the scheduler".
		if command -v systemctl &>/dev/null; then
			systemctl --user is-active --quiet "${SYSTEMD_UNIT_NAME}.timer" 2>/dev/null && return 0
			systemctl --user is-enabled --quiet "${SYSTEMD_UNIT_NAME}.timer" 2>/dev/null && return 0
		fi
		return 1
	fi

	# cron fallback (Linux without systemctl)
	local crontab_output
	crontab_output=$(crontab -l 2>/dev/null) || true
	echo "$crontab_output" | grep -qF "$CRON_MARKER"
	return $?
}

#######################################
# Health-check subcommand (t2898).
# Verifies the auto-update daemon is registered with the active scheduler
# AND has run within a reasonable freshness window.
#
# Exit codes:
#   0 — healthy (daemon loaded, recent successful run within 2× interval)
#   1 — degraded (daemon loaded but state-file is stale or unparseable)
#   2 — not installed (daemon not registered with the active scheduler)
#
# Output: human-readable status line + remediation command on stderr.
# Quiet mode: --quiet suppresses output; only the exit code matters
# (used by `cmd_enable --idempotent` to detect "already healthy").
#######################################
cmd_health_check() {
	local quiet=0
	local arg
	for arg in "$@"; do
		case "$arg" in
		--quiet | -q) quiet=1 ;;
		*) ;;
		esac
	done

	# Helper that prints to stderr unless --quiet was passed.
	_hc_say() {
		if [[ "$quiet" -eq 0 ]]; then
			printf '%s\n' "$*" >&2
		fi
		return 0
	}

	if ! _daemon_is_loaded; then
		_hc_say "auto-update daemon: NOT INSTALLED"
		_hc_say "fix: ~/.aidevops/agents/scripts/auto-update-helper.sh enable"
		return 2
	fi

	# Loaded — check freshness via state file. Field is `last_timestamp`
	# (set on every cmd_check run, regardless of update outcome). The brief
	# referenced `last_run`; this is the actual deployed name.
	if ! [[ -f "$STATE_FILE" ]] || ! command -v jq &>/dev/null; then
		# State file absent or jq missing — daemon is loaded but we cannot
		# verify freshness. Treat as soft-healthy: the loaded check is the
		# primary signal; freshness is the secondary signal.
		_hc_say "auto-update daemon: LOADED (state file absent — freshness unknown)"
		return 0
	fi

	local last_ts
	last_ts=$(jq -r '.last_timestamp // empty' "$STATE_FILE" 2>/dev/null || echo "")

	if [[ -z "$last_ts" ]]; then
		# Loaded but never ran — fresh install before first cycle.
		_hc_say "auto-update daemon: LOADED (never run yet)"
		return 0
	fi

	# Convert ISO-8601 to epoch (handles both GNU and BSD date).
	local now_ts last_run_epoch
	now_ts=$(date -u '+%s')
	if last_run_epoch=$(date -u -d "$last_ts" '+%s' 2>/dev/null); then
		: # GNU date worked
	elif last_run_epoch=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$last_ts" '+%s' 2>/dev/null); then
		: # BSD date worked
	else
		_hc_say "auto-update daemon: LOADED (state file unparseable: '${last_ts}')"
		_hc_say "fix: ~/.aidevops/agents/scripts/auto-update-helper.sh check"
		return 1
	fi

	local age_sec
	age_sec=$((now_ts - last_run_epoch))

	# Resolve interval the same way cmd_enable does so the threshold tracks
	# user config. 2× interval is the staleness window.
	local interval
	interval=$(get_feature_toggle update_interval "$DEFAULT_INTERVAL")
	if ! [[ "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -eq 0 ]]; then
		interval="$DEFAULT_INTERVAL"
	fi
	local interval_sec=$((interval * 60))
	local stale_threshold=$((2 * interval_sec))

	if [[ "$age_sec" -gt "$stale_threshold" ]]; then
		_hc_say "auto-update daemon: STALLED (last run ${age_sec}s ago, expected every ${interval_sec}s)"
		_hc_say "fix: ~/.aidevops/agents/scripts/auto-update-helper.sh check"
		return 1
	fi

	_hc_say "auto-update daemon: HEALTHY (last run ${age_sec}s ago)"
	return 0
}

#######################################
# View logs
#######################################
cmd_logs() {
	local tail_lines=50

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--tail | -n)
			[[ $# -lt 2 ]] && {
				print_error "--tail requires a value"
				return 1
			}
			tail_lines="$2"
			shift 2
			;;
		--follow | -f)
			tail -f "$LOG_FILE" 2>/dev/null || print_info "No log file yet"
			return 0
			;;
		*) shift ;;
		esac
	done

	if [[ -f "$LOG_FILE" ]]; then
		tail -n "$tail_lines" "$LOG_FILE"
	else
		print_info "No log file yet (auto-update hasn't run)"
	fi
	return 0
}

#######################################
# Help
#######################################
cmd_help() {
	cat <<'EOF'
auto-update-helper.sh - Automatic update polling for aidevops

USAGE:
    auto-update-helper.sh <command> [options]
    aidevops auto-update <command> [options]

COMMANDS:
    enable [--idempotent]  Install scheduler (launchd on macOS, cron on Linux)
                           --idempotent: no-op if already loaded (used by setup.sh)
    disable                Remove scheduler
    status                 Show current auto-update state
    check                  One-shot: check for updates and install if available
    health-check [--quiet] Verify daemon is loaded and ran recently
                           Exit: 0 healthy, 1 stalled, 2 not installed
    logs [--tail N]        View update logs (default: last 50 lines)
    logs --follow          Follow log output in real-time
    help                   Show this help

CONFIGURATION:
    Persistent settings: aidevops config set <key> <value>
    Per-session overrides: set the corresponding environment variable.

    JSONC key                          Env override                     Default
    updates.auto_update                AIDEVOPS_AUTO_UPDATE             true
    updates.update_interval_minutes    AIDEVOPS_UPDATE_INTERVAL         10
    updates.skill_auto_update          AIDEVOPS_SKILL_AUTO_UPDATE       true
    updates.skill_freshness_hours      AIDEVOPS_SKILL_FRESHNESS_HOURS   24
    updates.openclaw_auto_update       AIDEVOPS_OPENCLAW_AUTO_UPDATE    true
    updates.openclaw_freshness_hours   AIDEVOPS_OPENCLAW_FRESHNESS_HOURS 24
    updates.tool_auto_update           AIDEVOPS_TOOL_AUTO_UPDATE        true
    updates.tool_freshness_hours       AIDEVOPS_TOOL_FRESHNESS_HOURS    6
    updates.tool_idle_hours            AIDEVOPS_TOOL_IDLE_HOURS         6
    updates.upstream_watch             AIDEVOPS_UPSTREAM_WATCH          true
    updates.upstream_watch_hours       AIDEVOPS_UPSTREAM_WATCH_HOURS    24

SCHEDULER BACKENDS:
    macOS:  launchd LaunchAgent (~/Library/LaunchAgents/com.aidevops.aidevops-auto-update.plist)
            - Native macOS scheduler, survives reboots without cron
            - Auto-migrates existing cron entries on first 'enable'
    Linux:  systemd user timer preferred (~/.config/systemd/user/aidevops-auto-update.timer)
            - Falls back to cron when systemctl --user is unavailable
            - Requires loginctl enable-linger $USER to run when logged out
            - Without linger, the timer stops when your last session ends
            - See 'aidevops auto-update status' for current linger state
    Linux:  cron fallback (crontab entry with # aidevops-auto-update marker)

HOW IT WORKS:
    1. Scheduler runs 'auto-update-helper.sh check' every 10 minutes
    2. Checks GitHub API for latest version (no CDN cache)
    3. If newer version found:
       a. Acquires lock (prevents concurrent updates)
       b. Runs git pull --ff-only
       c. Runs setup.sh --stage ai-session (full setup fallback) to deploy agents
    4. Safe to run while AI sessions are active
    5. Skips if another update is already in progress
    6. Runs daily skill freshness check (24h gate):
       a. Reads last_skill_check from state file
       b. If >24h since last check, calls skill-update-helper.sh check --auto-update --quiet
       c. Updates last_skill_check timestamp in state file
       d. Runs on every cmd_check invocation (gate prevents excessive network calls)
    7. Runs daily OpenClaw update check (24h gate, if openclaw CLI is installed):
       a. Reads last_openclaw_check from state file
       b. If >24h since last check, runs openclaw update --yes --no-restart
       c. Respects user's configured channel (beta/dev/stable)
       d. Opt-out: AIDEVOPS_OPENCLAW_AUTO_UPDATE=false
    8. Runs 6-hourly tool freshness check (idle-gated):
       a. Reads last_tool_check from state file
       b. If >6h since last check AND user idle >6h, runs tool-version-check.sh --update --quiet
       c. Covers all installed tools: npm (OpenCode, MCP servers, etc.),
          brew (gh, glab, shellcheck, jq, etc.), pip (DSPy, crawl4ai, etc.)
       d. Idle detection: macOS IOKit HIDIdleTime, Linux xprintidle/dbus/w(1),
          headless servers treated as always idle
       e. Opt-out: AIDEVOPS_TOOL_AUTO_UPDATE=false

RATE LIMITS:
    GitHub API: 60 requests/hour (unauthenticated)
    10-min interval = 6 requests/hour (well within limits)
    Skill check: once per 24h per user (configurable via updates.skill_freshness_hours)
    OpenClaw check: once per 24h per user (configurable via updates.openclaw_freshness_hours)
    Tool check: once per 6h per user, only when idle (configurable via updates.tool_freshness_hours)
    Upstream watch: once per 24h per user (configurable via updates.upstream_watch_hours)

LOGS:
    ~/.aidevops/logs/auto-update.log

EOF
	return 0
}

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	enable) cmd_enable "$@" ;;
	disable) cmd_disable "$@" ;;
	status) cmd_status "$@" ;;
	check) cmd_check "$@" ;;
	health-check) cmd_health_check "$@" ;;
	logs) cmd_logs "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
	return 0
}

main "$@"
