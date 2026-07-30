#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# repo-sync-helper.sh - Daily read-only diagnostics for human canonical repos
#
# Scans configured parent directories for git repos cloned from a remote and
# reports remote drift for repos where:
#   - The working tree is clean (no uncommitted changes)
#   - The current branch is the default branch (main or master)
#   - The repo has a configured remote
#
# Follows the auto-update-helper.sh pattern for scheduler management.
#
# Usage:
#   repo-sync-helper.sh enable           Install daily scheduler (launchd/systemd/cron)
#   repo-sync-helper.sh disable          Remove scheduler
#   repo-sync-helper.sh status           Show current state and last sync results
#   repo-sync-helper.sh check            One-shot: sync all configured repos now
#   repo-sync-helper.sh logs [--tail N]  View sync logs
#   repo-sync-helper.sh config           Show/edit configuration
#   repo-sync-helper.sh help             Show this help
#
# Configuration:
#   ~/.config/aidevops/repos.json        Add "git_parent_dirs" array
#   AIDEVOPS_REPO_SYNC=false             Disable even if scheduler is installed
#   AIDEVOPS_REPO_SYNC_INTERVAL=1440     Minutes between syncs (default: 1440 = daily)
#
# Logs: ~/.aidevops/logs/repo-sync.log

set -euo pipefail

# Resolve symlinks to find real script location
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

init_log_file

# Configuration
readonly CONFIG_FILE="$HOME/.config/aidevops/repos.json"
readonly LOCK_DIR="$HOME/.aidevops/locks"
readonly LOCK_FILE="$LOCK_DIR/repo-sync.lock"
readonly LOG_FILE="$HOME/.aidevops/logs/repo-sync.log"
readonly STATE_FILE="$HOME/.aidevops/cache/repo-sync-state.json"
readonly CRON_MARKER="# aidevops-repo-sync"
readonly DEFAULT_INTERVAL=1440
readonly LAUNCHD_LABEL="sh.aidevops.repo-sync"
readonly LAUNCHD_DIR="$HOME/Library/LaunchAgents"
readonly LAUNCHD_PLIST="${LAUNCHD_DIR}/${LAUNCHD_LABEL}.plist"
readonly SYSTEMD_SERVICE_DIR="$HOME/.config/systemd/user"
readonly SYSTEMD_UNIT_NAME="aidevops-repo-sync"
readonly SYSTEMD_BACKEND="systemd"
readonly INSTALL_DIR="$HOME/Git/aidevops"
readonly DEFAULT_PARENT_DIRS=("$HOME/Git")

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
# Ensure required directories exist
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
# Check if the repo-sync LaunchAgent is loaded
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
# Generate repo-sync LaunchAgent plist content
# Arguments:
#   $1 - script_path
#   $2 - interval_seconds
#   $3 - env_path
#######################################
_generate_plist() {
	local script_path="$1"
	local interval_seconds="$2"
	local env_path="$3"
	env_path=$(aidevops_launchd_sanitized_path "$env_path")

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
	</dict>
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
# Lock management (prevents concurrent syncs)
# Uses mkdir for atomic locking (POSIX-safe)
#######################################
acquire_lock() {
	local max_wait=30
	local waited=0

	while [[ $waited -lt $max_wait ]]; do
		if mkdir "$LOCK_FILE" 2>/dev/null; then
			echo $$ >"$LOCK_FILE/pid"
			return 0
		fi

		# Check for stale lock (dead PID)
		if [[ -f "$LOCK_FILE/pid" ]]; then
			local lock_pid
			lock_pid=$(cat "$LOCK_FILE/pid" 2>/dev/null || echo "")
			if [[ -n "$lock_pid" ]] && ! kill -0 "$lock_pid" 2>/dev/null; then
				log_warn "Removing stale lock (PID $lock_pid dead)"
				rm -rf "$LOCK_FILE"
				continue
			fi
		fi

		# Safety net: remove locks older than 10 minutes
		if [[ -d "$LOCK_FILE" ]]; then
			local lock_age
			lock_age=$(($(date +%s) - $(_file_mtime_epoch "$LOCK_FILE")))
			if [[ $lock_age -gt 600 ]]; then
				log_warn "Removing stale lock (age ${lock_age}s > 600s)"
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
# Read configured parent directories from repos.json
# Falls back to DEFAULT_PARENT_DIRS if not configured
# Outputs one directory per line
#######################################
get_parent_dirs() {
	if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
		local dirs
		dirs=$(jq -r '.git_parent_dirs[]? // empty' "$CONFIG_FILE" || true)
		if [[ -n "$dirs" ]]; then
			echo "$dirs"
			return 0
		fi
	fi
	# Fall back to defaults
	for dir in "${DEFAULT_PARENT_DIRS[@]}"; do
		echo "$dir"
	done
	return 0
}

#######################################
# Detect the default branch for a git repo
# Arguments:
#   $1 - repo path
# Returns: branch name (main/master/etc) or empty string on failure
#######################################
get_default_branch() {
	local repo_path="$1"

	# Try to get from remote HEAD reference
	local remote_head
	remote_head=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)
	if [[ -n "$remote_head" ]]; then
		echo "${remote_head##*/}"
		return 0
	fi

	# Fall back to checking common default branch names
	for branch in main master trunk develop; do
		if git -C "$repo_path" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
			echo "$branch"
			return 0
		fi
	done

	echo ""
	return 0
}

#######################################
# Check if a git repo's working tree is clean
# Arguments:
#   $1 - repo path
# Returns: 0 if clean, 1 if dirty
#######################################
is_working_tree_clean() {
	local repo_path="$1"
	git -C "$repo_path" diff --quiet 2>/dev/null &&
		git -C "$repo_path" diff --cached --quiet 2>/dev/null
	return $?
}

#######################################
# Last stderr captured from a git command run by repo-sync.
#######################################
_REPO_SYNC_LAST_GIT_STDERR=""

#######################################
# Sanitize git stderr before writing it to repo-sync logs.
# Arguments:
#   $1 - stderr text
# Outputs: sanitized stderr text
#######################################
sanitize_git_stderr() {
	local stderr_text="$1"
	printf '%s\n' "$stderr_text" | sed -E \
		-e 's#https://[^/@[:space:]]+@github\.com#https://[redacted-credential]@github.com#g' \
		-e 's#([Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*[Bb][Aa][Ss][Ii][Cc][[:space:]]+)[^[:space:]]+#\1[redacted]#g' \
		-e 's#(x-access-token:)[^[:space:]@]+#\1[redacted]#g'
	return 0
}

#######################################
# Log captured git stderr after sanitization.
# Arguments:
#   $1 - stderr text
#######################################
log_git_stderr() {
	local stderr_text="$1"
	[[ -z "$stderr_text" ]] && return 0
	sanitize_git_stderr "$stderr_text" >>"$LOG_FILE"
	return 0
}

#######################################
# Detect GitHub HTTPS remotes eligible for gh credential fallback.
# Arguments:
#   $1 - remote URL
# Returns: 0 when URL is https://github.com/... with optional username
#######################################
is_github_https_remote() {
	local remote_url="$1"
	case "$remote_url" in
	https://github.com/* | https://*@github.com/*) return 0 ;;
	*) return 1 ;;
	esac
}

#######################################
# Detect auth/password-prompt git failures that are safe to retry with gh.
# Arguments:
#   $1 - stderr text
# Returns: 0 when stderr indicates a non-interactive auth failure
#######################################
is_git_auth_failure() {
	local stderr_text="$1"
	case "$stderr_text" in
	*"could not read Password"* | *"could not read Username"* | *"Authentication failed"* | *"terminal prompts disabled"*)
		return 0
		;;
	*) return 1 ;;
	esac
}

#######################################
# Check whether gh has GitHub auth available without printing a token.
# Returns: 0 when gh auth is available for github.com
#######################################
gh_auth_available() {
	command -v gh >/dev/null 2>&1 || return 1
	gh auth status --hostname github.com >/dev/null 2>&1
	return $?
}

#######################################
# Run git with stderr captured for sanitized logging.
# Arguments:
#   $1 - repo path
#   $@ - git command and arguments after repo path
# Returns: git exit code
#######################################
run_git_capturing_stderr() {
	_REPO_SYNC_LAST_GIT_STDERR=""
	local -a git_args=("$@")
	local repo_path
	repo_path="${git_args[0]}"
	shift
	local rc
	local stderr_output

	if { stderr_output=$(GIT_TERMINAL_PROMPT=0 git -C "$repo_path" "$@" 2>&1 >&3); } 3>&1; then
		return 0
	else
		rc=$?
		_REPO_SYNC_LAST_GIT_STDERR="$stderr_output"
		return "$rc"
	fi
}

#######################################
# Run git with transient gh credential helper for GitHub HTTPS retry.
# Arguments:
#   $1 - repo path
#   $@ - git command and arguments after repo path
# Returns: git exit code
#######################################
run_git_with_gh_credential() {
	_REPO_SYNC_LAST_GIT_STDERR=""
	local -a git_args=("$@")
	local repo_path
	repo_path="${git_args[0]}"
	shift
	local rc
	local stderr_output

	if { stderr_output=$(GIT_TERMINAL_PROMPT=0 git -C "$repo_path" \
		-c credential.helper= \
		-c "credential.helper=!gh auth git-credential" \
		"$@" 2>&1 >&3); } 3>&1; then
		return 0
	else
		rc=$?
		_REPO_SYNC_LAST_GIT_STDERR="$stderr_output"
		return "$rc"
	fi
}

#######################################
# Run a git command and retry GitHub HTTPS auth failures via gh credentials.
# Arguments:
#   $1 - repo path
#   $2 - repo name
#   $3 - remote name
#   $4 - operation name for logs
#   $@ - git command and arguments after operation
# Returns: 0 on success, 1 on failure
#######################################
run_git_with_auth_fallback() {
	local repo_path="$1"
	local repo_name="$2"
	local remote="$3"
	local operation="$4"
	shift 4
	local remote_url
	remote_url=$(git -C "$repo_path" remote get-url "$remote" 2>/dev/null || true)

	if run_git_capturing_stderr "$repo_path" "$@"; then
		return 0
	fi

	local plain_stderr="$_REPO_SYNC_LAST_GIT_STDERR"
	if is_github_https_remote "$remote_url" && is_git_auth_failure "$plain_stderr"; then
		if gh_auth_available; then
			log_info "AUTH $repo_name: retrying git $operation with gh credential helper"
			if run_git_with_gh_credential "$repo_path" "$@"; then
				return 0
			fi
			log_git_stderr "$_REPO_SYNC_LAST_GIT_STDERR"
			return 1
		fi
		log_info "AUTH $repo_name: gh auth unavailable for GitHub HTTPS fallback"
	fi

	log_git_stderr "$plain_stderr"
	return 1
}

#######################################
# Sync a single git repo
# Arguments:
#   $1 - repo path
# Returns: 0 on success/skip, 1 on error
# Outputs: status line to stdout
#######################################
sync_repo() {
	local repo_path="$1"
	local repo_name
	repo_name=$(basename "$repo_path")

	# Must be a git repo with a remote
	if [[ ! -d "$repo_path/.git" ]]; then
		return 0
	fi

	# Must have at least one remote configured
	local remote
	remote=$(git -C "$repo_path" remote 2>/dev/null | head -1 || true)
	if [[ -z "$remote" ]]; then
		log_info "SKIP $repo_name: no remote configured"
		return 0
	fi

	# Get current branch
	local current_branch
	current_branch=$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	if [[ -z "$current_branch" || "$current_branch" == "HEAD" ]]; then
		log_info "SKIP $repo_name: detached HEAD"
		return 0
	fi

	# Get default branch
	local default_branch
	default_branch=$(get_default_branch "$repo_path")
	if [[ -z "$default_branch" ]]; then
		log_info "SKIP $repo_name: cannot determine default branch"
		return 0
	fi

	# Only sync if on default branch
	if [[ "$current_branch" != "$default_branch" ]]; then
		log_info "SKIP $repo_name: on branch '$current_branch' (default: '$default_branch')"
		return 0
	fi

	# Only sync if working tree is clean
	if ! is_working_tree_clean "$repo_path"; then
		log_warn "SKIP $repo_name: working tree is dirty"
		return 0
	fi

	# Query the remote without updating any canonical Git or worktree state.
	log_info "CHECK $repo_name: reading $remote/$default_branch..."
	local remote_output=""
	if ! remote_output=$(run_git_with_auth_fallback "$repo_path" "$repo_name" "$remote" "ls-remote" \
		ls-remote "$remote" "refs/heads/$default_branch"); then
		log_error "FAIL $repo_name: git ls-remote failed"
		return 1
	fi

	local local_sha upstream_sha
	local_sha=$(git -C "$repo_path" rev-parse HEAD 2>/dev/null || true)
	upstream_sha=$(printf '%s\n' "$remote_output" | awk 'NR == 1 {print $1}')

	if [[ "$local_sha" == "$upstream_sha" ]]; then
		log_info "OK $repo_name: already up to date"
		return 0
	fi

	log_warn "STALE $repo_name: differs from $remote/$default_branch; human checkout left unchanged"
	return 0
}

#######################################
# Update state file with an action (enable/disable)
# Arguments:
#   $1 - action (enable/disable)
#   $2 - status string
#######################################
update_state_action() {
	local action="$1"
	local status="$2"
	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	if ! command -v jq &>/dev/null; then
		return 0
	fi

	ensure_dirs

	local tmp_state
	tmp_state=$(mktemp)
	trap 'rm -f "${tmp_state:-}"' RETURN

	if [[ -f "$STATE_FILE" ]]; then
		jq --arg ts "$timestamp" \
			--arg action "$action" \
			--arg status "$status" \
			'. + {
				last_action: $action,
				last_action_time: $ts,
				status: $status
			}' "$STATE_FILE" >"$tmp_state" 2>/dev/null && mv "$tmp_state" "$STATE_FILE"
	else
		jq -n --arg ts "$timestamp" \
			--arg action "$action" \
			--arg status "$status" \
			'{
				last_action: $action,
				last_action_time: $ts,
				status: $status
			}' >"$STATE_FILE"
	fi
	return 0
}

#######################################
# Update state file after a sync run
# Arguments:
#   $1 - synced count
#   $2 - skipped count
#   $3 - failed count
#######################################
update_state() {
	local synced="$1"
	local skipped="$2"
	local failed="$3"
	local timestamp
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

	if ! command -v jq &>/dev/null; then
		return 0
	fi

	local tmp_state
	tmp_state=$(mktemp)
	trap 'rm -f "${tmp_state:-}"' RETURN

	if [[ -f "$STATE_FILE" ]]; then
		jq --arg ts "$timestamp" \
			--argjson synced "$synced" \
			--argjson skipped "$skipped" \
			--argjson failed "$failed" \
			'. + {
				last_sync: $ts,
				last_synced: $synced,
				last_skipped: $skipped,
				last_failed: $failed,
				total_synced: ((.total_synced // 0) + $synced),
				total_failed: ((.total_failed // 0) + $failed)
			}' "$STATE_FILE" >"$tmp_state" 2>/dev/null && mv "$tmp_state" "$STATE_FILE"
	else
		jq -n --arg ts "$timestamp" \
			--argjson synced "$synced" \
			--argjson skipped "$skipped" \
			--argjson failed "$failed" \
			'{
				last_sync: $ts,
				last_synced: $synced,
				last_skipped: $skipped,
				last_failed: $failed,
				total_synced: $synced,
				total_failed: $failed
			}' >"$STATE_FILE"
	fi
	return 0
}

#######################################
# One-shot sync of all configured repos
# This is what the scheduler calls
#######################################
cmd_check() {
	ensure_dirs

	# Respect env var override
	if [[ "${AIDEVOPS_REPO_SYNC:-}" == "false" ]]; then
		log_info "Repo sync disabled via AIDEVOPS_REPO_SYNC=false"
		return 0
	fi

	# Acquire lock (prevents concurrent syncs)
	if ! acquire_lock; then
		log_warn "Could not acquire lock, skipping sync"
		return 0
	fi
	trap 'release_lock' EXIT

	local synced=0
	local skipped=0
	local failed=0

	log_info "Starting repo sync..."

	# Read parent directories
	local parent_dirs=()
	while IFS= read -r dir; do
		# Expand ~ in paths
		dir="${dir/#\~/$HOME}"
		parent_dirs+=("$dir")
	done < <(get_parent_dirs)

	if [[ ${#parent_dirs[@]} -eq 0 ]]; then
		log_warn "No parent directories configured. Add 'git_parent_dirs' to $CONFIG_FILE"
		return 0
	fi

	for parent_dir in "${parent_dirs[@]}"; do
		if [[ ! -d "$parent_dir" ]]; then
			log_warn "Parent directory not found: $parent_dir"
			continue
		fi

		log_info "Scanning: $parent_dir"

		# Iterate over immediate subdirectories only (not recursive)
		# Worktrees are excluded — only the main checkout matters
		while IFS= read -r -d '' repo_dir; do
			# Skip if not a git repo
			[[ -d "$repo_dir/.git" ]] || continue

			# Skip git worktrees (they have .git as a file, not a directory)
			[[ -f "$repo_dir/.git" ]] && continue

			if sync_repo "$repo_dir"; then
				# Determine if it was pulled or skipped based on log
				local last_log
				last_log=$(tail -1 "$LOG_FILE" 2>/dev/null || true)
				if [[ "$last_log" == *"PULLED"* ]]; then
					synced=$((synced + 1))
				elif [[ "$last_log" == *"OK"* ]]; then
					: # already up to date — not counted as synced or skipped
				else
					skipped=$((skipped + 1))
				fi
			else
				failed=$((failed + 1))
			fi
		done < <(find "$parent_dir" -maxdepth 1 -mindepth 1 -type d -print0 2>/dev/null)
	done

	log_info "Sync complete: ${synced} pulled, ${skipped} skipped, ${failed} failed"
	update_state "$synced" "$skipped" "$failed"

	if [[ $failed -gt 0 ]]; then
		return 1
	fi
	return 0
}

#######################################
# Enable repo-sync via launchd (macOS)
# Arguments:
#   $1 - script_path
#   $2 - interval (minutes)
#######################################
_enable_launchd() {
	local script_path="$1"
	local interval="$2"
	local interval_seconds=$((interval * 60))

	# Migrate from old label if present (com.aidevops -> sh.aidevops)
	local old_label="com.aidevops.aidevops-repo-sync"
	local old_plist="${LAUNCHD_DIR}/${old_label}.plist"
	# Capture output first to avoid SIGPIPE (141) under set -o pipefail (t3270)
	local launchctl_list
	launchctl_list=$(launchctl list 2>/dev/null) || true
	if echo "$launchctl_list" | grep -qF "$old_label"; then
		launchctl unload -w "$old_plist" 2>/dev/null || true
		log_info "Unloaded old LaunchAgent: $old_label"
	fi
	rm -f "$old_plist"

	mkdir -p "$LAUNCHD_DIR"

	# Create named symlink so macOS System Settings shows "aidevops-repo-sync"
	local bin_dir="$HOME/.aidevops/bin"
	mkdir -p "$bin_dir"
	local display_link="$bin_dir/aidevops-repo-sync"
	aidevops_ensure_symlink_target "$script_path" "$display_link" || return 1

	# Generate plist content and compare to existing (t1265)
	local new_content
	new_content=$(_generate_plist "$display_link" "$interval_seconds" "${PATH}")

	# Skip if already loaded with identical config (avoids macOS notification)
	if _launchd_is_loaded && [[ -f "$LAUNCHD_PLIST" ]]; then
		local existing_content
		existing_content=$(cat "$LAUNCHD_PLIST" 2>/dev/null) || existing_content=""
		if [[ "$existing_content" == "$new_content" ]]; then
			print_info "Repo sync LaunchAgent already installed with identical config ($LAUNCHD_LABEL)"
			update_state_action "enable" "enabled"
			return 0
		fi
		print_info "Repo sync LaunchAgent already loaded ($LAUNCHD_LABEL)"
		update_state_action "enable" "enabled"
		return 0
	fi

	echo "$new_content" >"$LAUNCHD_PLIST"

	if launchctl load -w "$LAUNCHD_PLIST" 2>/dev/null; then
		update_state_action "enable" "enabled"
		print_success "Repo sync enabled (every ${interval} minutes)"
		echo ""
		echo "  Scheduler: launchd (macOS LaunchAgent)"
		echo "  Label:     $LAUNCHD_LABEL"
		echo "  Plist:     $LAUNCHD_PLIST"
		echo "  Script:    $script_path"
		echo "  Logs:      $LOG_FILE"
		echo ""
		echo "  Disable with: aidevops repo-sync disable"
		echo "  Sync now:     aidevops repo-sync check"
	else
		print_error "Failed to load LaunchAgent: $LAUNCHD_LABEL"
		return 1
	fi
	return 0
}

#######################################
# Enable repo-sync via systemd user timer (Linux with systemd)
# Arguments:
#   $1 - script_path
#   $2 - interval (minutes)
# Returns: 0 on success, falls back to cron on failure
# Modelled on worker-watchdog.sh:_install_systemd() (GH#17691)
#######################################
_enable_systemd() {
	local script_path="$1"
	local interval="$2"
	local service_file="${SYSTEMD_SERVICE_DIR}/${SYSTEMD_UNIT_NAME}.service"
	local timer_file="${SYSTEMD_SERVICE_DIR}/${SYSTEMD_UNIT_NAME}.timer"
	local interval_sec
	interval_sec=$((interval * 60))

	mkdir -p "${SYSTEMD_SERVICE_DIR}"

	printf '%s' "[Unit]
Description=aidevops repo-sync
After=network.target

[Service]
Type=oneshot
KillMode=control-group
ExecStart=/bin/bash -lc '\"${script_path}\" check'
TimeoutStartSec=300
Nice=10
IOSchedulingClass=idle
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}
" >"$service_file"

	printf '%s' "[Unit]
Description=aidevops repo-sync Timer

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
		_enable_cron "$script_path" "$interval"
		return $?
	fi

	update_state_action "enable" "enabled"

	print_success "Repo sync enabled (every ${interval} minutes)"
	echo ""
	echo "  Scheduler: systemd user timer"
	echo "  Unit:      ${SYSTEMD_UNIT_NAME}.timer"
	echo "  Service:   ${service_file}"
	echo "  Timer:     ${timer_file}"
	echo "  Logs:      ${LOG_FILE}"
	echo ""
	echo "  Disable with: aidevops repo-sync disable"
	return 0
}

#######################################
# Disable repo-sync systemd user timer
# Returns: 0 on success
#######################################
_disable_systemd() {
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

	update_state_action "disable" "disabled"

	if [[ "$had_entry" == "true" ]]; then
		print_success "Repo sync disabled"
	else
		print_info "Repo sync was not enabled"
	fi
	return 0
}

#######################################
# Enable repo-sync via cron (Linux)
# Arguments:
#   $1 - script_path
#   $2 - interval (minutes)
#######################################
_enable_cron() {
	local script_path="$1"
	local interval="$2"

	# Build cron expression from interval (minutes)
	local cron_expr cron_desc
	if [[ "$interval" -ge 1440 ]]; then
		# Daily or longer — run at 3am
		cron_expr="0 3 * * *"
		cron_desc="daily at 3am"
	elif [[ "$interval" -ge 60 ]]; then
		# Hourly intervals
		local hours=$((interval / 60))
		cron_expr="0 */${hours} * * *"
		cron_desc="every ${hours} hours"
	else
		# Sub-hourly intervals
		cron_expr="*/${interval} * * * *"
		cron_desc="every ${interval} minutes"
	fi
	local cron_line="$cron_expr $script_path check >> $LOG_FILE 2>&1 $CRON_MARKER"

	local temp_cron
	temp_cron=$(mktemp)
	trap 'rm -f "${temp_cron:-}"' RETURN

	crontab -l 2>/dev/null | grep -v "$CRON_MARKER" >"$temp_cron" || true
	echo "$cron_line" >>"$temp_cron"
	crontab "$temp_cron"
	rm -f "$temp_cron"

	update_state_action "enable" "enabled"

	print_success "Repo sync enabled ($cron_desc)"
	echo ""
	echo "  Schedule: $cron_expr"
	echo "  Script:   $script_path"
	echo "  Logs:     $LOG_FILE"
	echo ""
	echo "  Disable with: aidevops repo-sync disable"
	echo "  Sync now:     aidevops repo-sync check"
	return 0
}

#######################################
# Enable repo-sync scheduler (platform-aware)
# On macOS: installs LaunchAgent plist (daily)
# On Linux: installs a systemd user timer, with cron fallback
#######################################
cmd_enable() {
	ensure_dirs

	local interval="${AIDEVOPS_REPO_SYNC_INTERVAL:-$DEFAULT_INTERVAL}"
	local script_path="$HOME/.aidevops/agents/scripts/repo-sync-helper.sh"

	# Verify the script exists at the deployed location
	if [[ ! -x "$script_path" ]]; then
		# Fall back to repo location
		script_path="$INSTALL_DIR/.agents/scripts/repo-sync-helper.sh"
		if [[ ! -x "$script_path" ]]; then
			print_error "repo-sync-helper.sh not found"
			return 1
		fi
	fi

	local backend
	backend="$(_get_scheduler_backend)"

	if [[ "$backend" == "launchd" ]]; then
		_enable_launchd "$script_path" "$interval"
		return $?
	elif [[ "$backend" == "$SYSTEMD_BACKEND" ]]; then
		_enable_systemd "$script_path" "$interval"
		return $?
	fi

	_enable_cron "$script_path" "$interval"
	return $?
}

#######################################
# Disable repo-sync scheduler (platform-aware)
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

		# Also clean up old label if present (com.aidevops -> sh.aidevops migration)
		local old_label="com.aidevops.aidevops-repo-sync"
		local old_plist="${LAUNCHD_DIR}/${old_label}.plist"
		# Capture output first to avoid SIGPIPE (141) under set -o pipefail (t3270)
		local launchctl_list_disable
		launchctl_list_disable=$(launchctl list 2>/dev/null) || true
		if echo "$launchctl_list_disable" | grep -qF "$old_label"; then
			launchctl unload -w "$old_plist" 2>/dev/null || true
			had_entry=true
		fi
		if [[ -f "$old_plist" ]]; then
			rm -f "$old_plist"
			had_entry=true
		fi

		# Also remove any lingering cron entry
		if crontab -l 2>/dev/null | grep -qF "$CRON_MARKER"; then
			local temp_cron
			temp_cron=$(mktemp)
			crontab -l 2>/dev/null | grep -vF "$CRON_MARKER" >"$temp_cron" || true
			crontab "$temp_cron"
			rm -f "$temp_cron"
			had_entry=true
		fi

		if [[ "$had_entry" == "true" ]]; then
			update_state_action "disable" "disabled"
			print_success "Repo sync disabled"
		else
			print_info "Repo sync was not enabled"
		fi
		return 0
	elif [[ "$backend" == "$SYSTEMD_BACKEND" ]]; then
		_disable_systemd
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

	if [[ "$had_entry" == "true" ]]; then
		update_state_action "disable" "disabled"
		print_success "Repo sync disabled"
	else
		print_info "Repo sync was not enabled"
	fi
	return 0
}

#######################################
# Read one systemd unit property without allowing a missing unit/property to
# terminate status under set -euo pipefail.
# Arguments:
#   $1 - unit name
#   $2 - property name
#######################################
_systemd_unit_property() {
	local unit_name="$1"
	local property_name="$2"
	systemctl --user show "$unit_name" --property="$property_name" --value 2>/dev/null || true
	return 0
}

#######################################
# Show repo-sync systemd user timer status.
#######################################
_status_systemd() {
	echo -e "  Scheduler: systemd (user timer)"
	if ! command -v systemctl &>/dev/null; then
		echo -e "  Status:    ${YELLOW}systemctl unavailable${NC}"
		return 0
	fi
	if ! systemctl --user show &>/dev/null; then
		echo -e "  Status:    ${YELLOW}systemd user manager inaccessible${NC}"
		return 0
	fi

	local timer_unit="${SYSTEMD_UNIT_NAME}.timer"
	local service_unit="${SYSTEMD_UNIT_NAME}.service"
	local load_state active_state sub_state enabled_state
	load_state=$(_systemd_unit_property "$timer_unit" "LoadState")
	active_state=$(systemctl --user is-active "$timer_unit" 2>/dev/null || true)
	sub_state=$(_systemd_unit_property "$timer_unit" "SubState")
	enabled_state=$(systemctl --user is-enabled "$timer_unit" 2>/dev/null || true)

	if [[ "$load_state" == "not-found" ]] || [[ -z "$load_state" && ! -f "${SYSTEMD_SERVICE_DIR}/${timer_unit}" ]]; then
		echo -e "  Status:    ${YELLOW}not installed${NC}"
	elif [[ "$active_state" == "failed" ]]; then
		echo -e "  Status:    ${RED}failed${NC}"
	elif [[ "$active_state" == "active" ]]; then
		echo -e "  Status:    ${GREEN}active${NC} (${enabled_state:-unknown})"
	elif [[ "$enabled_state" == "disabled" ]] || [[ "$enabled_state" == "masked" ]]; then
		echo -e "  Status:    ${YELLOW}${enabled_state}${NC}"
	elif [[ "$enabled_state" == "enabled" ]] || [[ "$enabled_state" == "enabled-runtime" ]]; then
		echo -e "  Status:    ${YELLOW}enabled but ${active_state:-inactive}${NC}"
	else
		echo -e "  Status:    ${YELLOW}${active_state:-unknown}${NC} (${enabled_state:-unknown})"
	fi

	echo "  Unit:      $timer_unit"
	[[ -n "$sub_state" ]] && echo "  Substate:  $sub_state"

	local next_fire last_fire
	next_fire=$(_systemd_unit_property "$timer_unit" "NextElapseUSecRealtime")
	if [[ -z "$next_fire" ]] || [[ "$next_fire" == "0" ]] || [[ "$next_fire" == "n/a" ]]; then
		next_fire=$(_systemd_unit_property "$timer_unit" "NextElapseUSecMonotonic")
	fi
	last_fire=$(_systemd_unit_property "$timer_unit" "LastTriggerUSec")
	if [[ -n "$next_fire" && "$next_fire" != "0" && "$next_fire" != "n/a" ]]; then
		echo "  Next fire: $next_fire"
	fi
	if [[ -n "$last_fire" && "$last_fire" != "0" && "$last_fire" != "n/a" ]]; then
		echo "  Last fire: $last_fire"
	fi

	local service_result service_exit
	service_result=$(_systemd_unit_property "$service_unit" "Result")
	service_exit=$(_systemd_unit_property "$service_unit" "ExecMainStatus")
	if [[ -n "$service_result" && "$service_result" != "n/a" ]]; then
		if [[ "$service_result" == "success" ]]; then
			echo -e "  Last result: ${GREEN}success${NC}"
		else
			echo -e "  Last result: ${RED}${service_result}${NC} (exit ${service_exit:-unknown})"
		fi
	fi

	echo "  Timer:     ${SYSTEMD_SERVICE_DIR}/${timer_unit}"
	echo "  Service:   ${SYSTEMD_SERVICE_DIR}/${service_unit}"
	return 0
}

#######################################
# Show status
#######################################
cmd_status() {
	ensure_dirs

	local backend
	backend="$(_get_scheduler_backend)"

	echo ""
	echo -e "${BOLD:-}Repo Sync Status${NC}"
	echo "-----------------"
	echo ""

	if [[ "$backend" == "launchd" ]]; then
		if _launchd_is_loaded; then
			local launchctl_info pid exit_code
			launchctl_info=$(launchctl list 2>/dev/null | grep -F "$LAUNCHD_LABEL" || true)
			pid=$(echo "$launchctl_info" | awk '{print $1}')
			exit_code=$(echo "$launchctl_info" | awk '{print $2}')
			echo -e "  Scheduler: launchd (macOS LaunchAgent)"
			echo -e "  Status:    ${GREEN}loaded${NC}"
			echo "  Label:     $LAUNCHD_LABEL"
			echo "  PID:       ${pid:--}"
			echo "  Last exit: ${exit_code:--}"
			if [[ -f "$LAUNCHD_PLIST" ]]; then
				local interval
				interval=$(grep -A1 'StartInterval' "$LAUNCHD_PLIST" 2>/dev/null | grep integer | grep -oE '[0-9]+' || true)
				if [[ -n "$interval" ]]; then
					echo "  Interval:  every ${interval}s ($((interval / 60)) min)"
				fi
				echo "  Plist:     $LAUNCHD_PLIST"
			fi
		else
			echo -e "  Scheduler: launchd (macOS LaunchAgent)"
			echo -e "  Status:    ${YELLOW}not loaded${NC}"
		fi
	elif [[ "$backend" == "$SYSTEMD_BACKEND" ]]; then
		_status_systemd
	else
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

	# Show configured parent directories
	echo ""
	echo "  Configured parent directories:"
	while IFS= read -r dir; do
		dir="${dir/#\~/$HOME}"
		if [[ -d "$dir" ]]; then
			local count
			count=$(find "$dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
			echo "    $dir ($count subdirs)"
		else
			echo -e "    ${YELLOW}$dir (not found)${NC}"
		fi
	done < <(get_parent_dirs)

	# Show state file info
	if [[ -f "$STATE_FILE" ]] && command -v jq &>/dev/null; then
		local last_sync last_synced last_skipped last_failed total_synced total_failed
		last_sync=$(jq -r '.last_sync // "never"' "$STATE_FILE" 2>/dev/null)
		last_synced=$(jq -r '.last_synced // 0' "$STATE_FILE" 2>/dev/null)
		last_skipped=$(jq -r '.last_skipped // 0' "$STATE_FILE" 2>/dev/null)
		last_failed=$(jq -r '.last_failed // 0' "$STATE_FILE" 2>/dev/null)
		total_synced=$(jq -r '.total_synced // 0' "$STATE_FILE" 2>/dev/null)
		total_failed=$(jq -r '.total_failed // 0' "$STATE_FILE" 2>/dev/null)

		echo ""
		echo "  Last sync:    $last_sync"
		echo "  Last result:  ${last_synced} pulled, ${last_skipped} skipped, ${last_failed} failed"
		echo "  Lifetime:     ${total_synced} total pulled, ${total_failed} total failed"
	fi

	# Check env var overrides
	if [[ "${AIDEVOPS_REPO_SYNC:-}" == "false" ]]; then
		echo ""
		echo -e "  ${YELLOW}Note: AIDEVOPS_REPO_SYNC=false is set (overrides scheduler)${NC}"
	fi

	echo ""
	return 0
}

#######################################
# Ensure repos.json exists and has git_parent_dirs key
# Returns: 0 on success, 1 on failure
#######################################
_dirs_ensure_config() {
	if [[ ! -f "$CONFIG_FILE" ]]; then
		mkdir -p "$(dirname "$CONFIG_FILE")"
		echo '{"initialized_repos": [], "git_parent_dirs": ["~/Git"]}' >"$CONFIG_FILE"
		return 0
	fi
	if ! jq -e '.git_parent_dirs' "$CONFIG_FILE" &>/dev/null; then
		local temp_file="${CONFIG_FILE}.tmp"
		if jq '. + {"git_parent_dirs": ["~/Git"]}' "$CONFIG_FILE" >"$temp_file"; then
			mv "$temp_file" "$CONFIG_FILE"
		else
			rm -f "$temp_file"
			print_error "Failed to initialize git_parent_dirs in config. Please check $CONFIG_FILE"
			return 1
		fi
	fi
	return 0
}

#######################################
# List configured git parent directories
#######################################
_dirs_list() {
	local dirs
	dirs=$(jq -r '.git_parent_dirs[]? // empty' "$CONFIG_FILE" || true)
	if [[ -z "$dirs" ]]; then
		echo "No parent directories configured."
		echo "Add one with: aidevops repo-sync dirs add ~/Git"
	else
		echo "Configured git parent directories:"
		while IFS= read -r dir; do
			local expanded="${dir/#\~/$HOME}"
			if [[ -d "$expanded" ]]; then
				echo "  $dir"
			else
				echo "  $dir  (not found)"
			fi
		done <<<"$dirs"
	fi
	return 0
}

#######################################
# Add a git parent directory to config
# Arguments:
#   $1 - directory path to add
#######################################
_dirs_add() {
	local new_dir="${1:-}"
	if [[ -z "$new_dir" ]]; then
		print_error "Usage: aidevops repo-sync dirs add <path>"
		return 1
	fi

	# Normalize: collapse to ~ prefix if under HOME
	local expanded="${new_dir/#\~/$HOME}"
	if [[ "$expanded" == "$HOME"/* ]]; then
		new_dir="~${expanded#"$HOME"}"
	else
		new_dir="$expanded"
	fi

	# Check if already present
	if jq -e --arg d "$new_dir" '.git_parent_dirs | index($d)' "$CONFIG_FILE" &>/dev/null; then
		print_warning "Already configured: $new_dir"
		return 0
	fi

	# Validate directory exists
	local check_path="${new_dir/#\~/$HOME}"
	if [[ ! -d "$check_path" ]]; then
		print_warning "Directory does not exist: $check_path"
		echo "Adding anyway — create it before next sync."
	fi

	local temp_file="${CONFIG_FILE}.tmp"
	if jq --arg d "$new_dir" '.git_parent_dirs += [$d]' "$CONFIG_FILE" >"$temp_file"; then
		mv "$temp_file" "$CONFIG_FILE"
		print_success "Added: $new_dir"
	else
		rm -f "$temp_file"
		print_error "Failed to add directory"
		return 1
	fi
	return 0
}

#######################################
# Remove a git parent directory from config
# Arguments:
#   $1 - directory path to remove
#######################################
_dirs_remove() {
	local rm_dir="${1:-}"
	if [[ -z "$rm_dir" ]]; then
		print_error "Usage: aidevops repo-sync dirs remove <path>"
		return 1
	fi

	# Normalize the same way as add
	local expanded="${rm_dir/#\~/$HOME}"
	if [[ "$expanded" == "$HOME"/* ]]; then
		rm_dir="~${expanded#"$HOME"}"
	else
		rm_dir="$expanded"
	fi

	# Check if present
	if ! jq -e --arg d "$rm_dir" '.git_parent_dirs | index($d)' "$CONFIG_FILE" &>/dev/null; then
		print_warning "Not configured: $rm_dir"
		return 0
	fi

	# Confirm destructive operation
	local _confirm=""
	read -r -p "Remove '$rm_dir' from git_parent_dirs? [y/N] " _confirm
	if [[ ! "$_confirm" =~ ^[Yy]$ ]]; then
		print_info "Cancelled"
		return 0
	fi

	local temp_file="${CONFIG_FILE}.tmp"
	if jq --arg d "$rm_dir" '.git_parent_dirs |= map(select(. != $d))' "$CONFIG_FILE" >"$temp_file"; then
		mv "$temp_file" "$CONFIG_FILE"
		print_success "Removed: $rm_dir"
	else
		rm -f "$temp_file"
		print_error "Failed to remove directory"
		return 1
	fi
	return 0
}

#######################################
# Manage git_parent_dirs in repos.json
# Subcommands: add <path>, remove <path>, list
#######################################
cmd_dirs() {
	local subcmd="${1:-list}"
	shift || true

	if ! command -v jq &>/dev/null; then
		print_error "jq is required for dirs management. Install: brew install jq"
		return 1
	fi

	_dirs_ensure_config || return 1

	case "$subcmd" in
	list) _dirs_list ;;
	add) _dirs_add "$@" ;;
	remove | rm) _dirs_remove "$@" ;;
	*)
		print_error "Unknown dirs subcommand: $subcmd"
		echo "Usage: aidevops repo-sync dirs [list|add|remove|rm]"
		return 1
		;;
	esac
	return 0
}

#######################################
# Show or edit configuration
#######################################
cmd_config() {
	echo ""
	echo "Repo Sync Configuration"
	echo "-----------------------"
	echo ""
	echo "Config file: $CONFIG_FILE"
	echo ""

	if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
		local dirs
		dirs=$(jq -r '.git_parent_dirs[]? // empty' "$CONFIG_FILE" || true)
		if [[ -n "$dirs" ]]; then
			echo "Configured parent directories:"
			while IFS= read -r dir; do
				echo "  $dir"
			done <<<"$dirs"
		else
			echo "No parent directories configured (using default: ~/Git)"
		fi
	else
		echo "No config file found (using default: ~/Git)"
	fi

	echo ""
	echo "Manage parent directories:"
	echo "  aidevops repo-sync dirs list          # Show configured directories"
	echo "  aidevops repo-sync dirs add ~/Projects  # Add a directory"
	echo "  aidevops repo-sync dirs remove ~/Old    # Remove a directory"
	echo ""
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
		print_info "No log file yet (repo-sync hasn't run)"
	fi
	return 0
}

#######################################
# Help
#######################################
cmd_help() {
	cat <<'EOF'
repo-sync-helper.sh - Daily git pull for repos in configured parent directories

USAGE:
    repo-sync-helper.sh <command> [options]
    aidevops repo-sync <command> [options]

COMMANDS:
    enable              Install daily scheduler (launchd on macOS, systemd/cron on Linux)
    disable             Remove scheduler
    status              Show current state and last sync results
    check               One-shot: sync all configured repos now
    dirs [subcmd]       Manage git parent directories:
        list            Show configured directories (default)
        add <path>      Add a parent directory
        remove <path>   Remove a parent directory
    config              Show configuration and how to edit it
    logs [--tail N]     View sync logs (default: last 50 lines)
    logs --follow       Follow log output in real-time
    help                Show this help

ENVIRONMENT:
    AIDEVOPS_REPO_SYNC=false             Disable even if scheduler is installed
    AIDEVOPS_REPO_SYNC_INTERVAL=1440     Minutes between syncs (default: 1440 = daily)

CONFIGURATION:
    Manage with: aidevops repo-sync dirs [add|remove|list]
    Or manually add "git_parent_dirs" array to ~/.config/aidevops/repos.json:
      {"git_parent_dirs": ["~/Git", "~/Projects"]}
    Default: ~/Git

SAFETY:
    - Never fetches, pulls, or updates human canonical checkouts
    - Skips repos with dirty working trees (uncommitted changes)
    - Skips repos not on their default branch (main/master)
    - Skips repos with no remote configured
    - Logs failures without stopping (other repos still sync)
    - Worktrees are ignored — only main checkouts are synced

SCHEDULER BACKENDS:
    macOS:  launchd LaunchAgent (~/Library/LaunchAgents/sh.aidevops.repo-sync.plist)
            - Runs daily (every 1440 minutes by default)
    Linux:  systemd user timer preferred (~/.config/systemd/user/aidevops-repo-sync.timer)
            - Falls back to cron when systemd user services are unavailable
            - Cron runs daily at 3am with the # aidevops-repo-sync marker

HOW IT WORKS:
    1. Scheduler runs 'repo-sync-helper.sh check' daily
    2. Reads git_parent_dirs from ~/.config/aidevops/repos.json
    3. Scans each parent directory for git repos (maxdepth 1)
    4. For each repo:
       a. Skips if no remote, detached HEAD, or not on default branch
       b. Skips if working tree is dirty
       c. Reads the remote ref with ls-remote
       d. Reports stale/diverged state without changing the checkout
    5. Logs results (pulled/skipped/failed) to ~/.aidevops/logs/repo-sync.log

LOGS:
    ~/.aidevops/logs/repo-sync.log

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
	dirs) cmd_dirs "$@" ;;
	config) cmd_config "$@" ;;
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
