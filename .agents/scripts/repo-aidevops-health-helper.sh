#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# repo-aidevops-health-helper.sh — r914 daily repo-aidevops health keeper.
#
# Three drift checks across repos in ~/.config/aidevops/repos.json:
#
#   1. Stale-version bump (autonomous, safe). For each initialized_repos[] entry
#      whose path exists and contains .aidevops.json with an older version than
#      the currently-installed framework: rewrite .aidevops.json on a dedicated
#      branch, commit, push, and open a PR (skip for local_only:true). Skipped if
#      the repo has uncommitted changes.
#
#   2. Missing-folder detection (human-gated, follow-up task tNNN). For each
#      entry where path does not exist and entry is not archived: file or
#      update a needs-maintainer-review issue on marcusquinn/aidevops.
#      Rate-limited via REPOS_DRIFT_FLAG_INTERVAL_DAYS (default 7).
#
#   3. No-init detection (human-gated, follow-up task tNNN). For each git repo
#      in git_parent_dirs[] not tracked in initialized_repos[] and without a
#      .aidevops-skip marker or .aidevops.json: file or update an issue.
#      Same rate-limit rules.
#
# Follows the auto-update-helper.sh / repo-sync-helper.sh pattern for
# scheduler management (launchd on darwin, systemd user timer on linux).
#
# Usage:
#   repo-aidevops-health-helper.sh enable   Install daily scheduler (launchd/systemd/cron)
#   repo-aidevops-health-helper.sh disable  Remove scheduler
#   repo-aidevops-health-helper.sh status   Show current state and last run results
#   repo-aidevops-health-helper.sh check    One-shot: run all three drift checks now
#   repo-aidevops-health-helper.sh run      Alias for 'check' (matches r914 routine run: spec)
#   repo-aidevops-health-helper.sh logs [--tail N]  View logs
#   repo-aidevops-health-helper.sh help     Show this help
#
# Configuration:
#   ~/.config/aidevops/repos.json            initialized_repos[] + git_parent_dirs[]
#   AIDEVOPS_REPO_HEALTH=false               Disable even if scheduler is installed
#   AIDEVOPS_REPO_HEALTH_INTERVAL=1440       Minutes between runs (default 1440 = daily)
#   REPOS_DRIFT_FLAG_INTERVAL_DAYS=7         Min days between re-flagging the same drift
#   AIDEVOPS_REPO_HEALTH_DRY_RUN=1           Log detections without writes/pushes/issue creation
#
# Logs: ~/.aidevops/logs/repo-aidevops-health.log
# State: ~/.aidevops/cache/repo-aidevops-health-state.json (includes last_flagged timestamps)

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
# shellcheck source=/dev/null
if [[ -f "${SCRIPT_DIR}/shared-gh-wrappers.sh" ]]; then
	source "${SCRIPT_DIR}/shared-gh-wrappers.sh"
fi

init_log_file

# Configuration
readonly CONFIG_FILE="$HOME/.config/aidevops/repos.json"
readonly LOCK_DIR="$HOME/.aidevops/locks"
readonly LOCK_FILE="$LOCK_DIR/repo-aidevops-health.lock"
readonly LOG_FILE="$HOME/.aidevops/logs/repo-aidevops-health.log"
readonly STATE_FILE="$HOME/.aidevops/cache/repo-aidevops-health-state.json"
readonly CRON_MARKER="# aidevops-repo-aidevops-health"
readonly DEFAULT_INTERVAL=1440
readonly REPO_AIDEVOPS_HEALTH_SCHEDULE='daily(@03:30)'
readonly LAUNCHD_LABEL="sh.aidevops.repo-aidevops-health"
readonly LAUNCHD_DIR="$HOME/Library/LaunchAgents"
readonly LAUNCHD_PLIST="${LAUNCHD_DIR}/${LAUNCHD_LABEL}.plist"
readonly SYSTEMD_SERVICE_DIR="$HOME/.config/systemd/user"
readonly SYSTEMD_UNIT_NAME="aidevops-repo-aidevops-health"
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
# Check if the repo-aidevops-health LaunchAgent is loaded
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
# Generate repo-aidevops-health LaunchAgent plist content
# Arguments:
#   $1 - script_path
#   $2 - interval_seconds (legacy fallback label; schedule is canonical)
#   $3 - env_path
#######################################
_generate_plist() {
	local script_path="$1"
	local env_path="${3:-${2:-}}"
	if [[ -z "$env_path" ]]; then
		return 1
	fi
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
	<key>StartCalendarInterval</key>
	<dict>
		<key>Hour</key>
		<integer>3</integer>
		<key>Minute</key>
		<integer>30</integer>
	</dict>
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
			# t2421: command-aware liveness — bare kill -0 lies on macOS PID reuse
			if [[ -n "$lock_pid" ]] && ! _is_process_alive_and_matches "$lock_pid" "${FRAMEWORK_PROCESS_PATTERN:-}"; then
				log_warn "Removing stale lock (PID $lock_pid dead or reused, t2421)"
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

#######################################
# Build a deterministic version-bump branch name for a managed repo.
# Args:
#   $1 — slug
#   $2 — target_version
#######################################
_version_bump_branch_name() {
	local slug="$1"
	local target_version="$2"
	local safe_slug
	safe_slug=$(printf '%s' "$slug" | tr -c '[:alnum:]._-' '-')
	safe_slug="${safe_slug##-}"
	safe_slug="${safe_slug%%-}"
	printf 'chore/aidevops-version-v%s-%s\n' "$target_version" "$safe_slug"
	return 0
}

#######################################
# Format the PR body for a repo version bump.
# Args:
#   $1 — entry_version
#   $2 — target_version
#######################################
_version_bump_pr_body() {
	local entry_version="$1"
	local target_version="$2"
	cat <<EOF
## Summary

- Bump \`.aidevops.json\` from v${entry_version} to v${target_version}.
- Keep r914 repo-aidevops health updates compatible with protected default branches.

## Testing

- Generated by \`repo-aidevops-health-helper.sh\` after validating a clean default-branch worktree.
EOF
	return 0
}

#######################################
# Open (or reuse) a PR for an already-pushed version-bump branch.
# Args:
#   $1 — slug
#   $2 — repo_path
#   $3 — branch_name
#   $4 — default_branch
#   $5 — entry_version
#   $6 — target_version
#######################################
_open_version_bump_pr() {
	local slug="$1"
	local repo_path="$2"
	local branch_name="$3"
	local default_branch="$4"
	local entry_version="$5"
	local target_version="$6"

	local existing_pr
	existing_pr=$(gh pr list --repo "$slug" --head "$branch_name" --state open --json url --jq '.[0].url // empty' 2>/dev/null || true)
	if [[ -n "$existing_pr" ]]; then
		log_info "bumped: $slug → v${target_version} via existing PR $existing_pr"
		git -C "$repo_path" checkout -q "$default_branch" >/dev/null 2>&1 || true
		return 0
	fi

	if ! command -v gh_create_pr >/dev/null 2>&1; then
		log_warn "bump failed ($slug): gh_create_pr unavailable"
		git -C "$repo_path" checkout -q "$default_branch" >/dev/null 2>&1 || true
		return 1
	fi

	local pr_title pr_body pr_url
	pr_title="chore: bump .aidevops.json to v${target_version}"
	pr_body=$(_version_bump_pr_body "$entry_version" "$target_version")
	if ! pr_url=$(gh_create_pr \
		--repo "$slug" \
		--title "$pr_title" \
		--body "$pr_body" \
		--head "$branch_name" \
		--base "$default_branch" 2>&1); then
		log_warn "bump failed ($slug): gh_create_pr failed: $pr_url"
		git -C "$repo_path" checkout -q "$default_branch" >/dev/null 2>&1 || true
		return 1
	fi
	log_info "bumped: $slug → v${target_version} via PR $pr_url"
	git -C "$repo_path" checkout -q "$default_branch" >/dev/null 2>&1 || true
	return 0
}

#######################################
# Push a version-bump branch and open/reuse its PR.
# Args:
#   $1 — slug
#   $2 — repo_path
#   $3 — branch_name
#   $4 — default_branch
#   $5 — entry_version
#   $6 — target_version
#######################################
_push_version_bump_pr() {
	local slug="$1"
	local repo_path="$2"
	local branch_name="$3"
	local default_branch="$4"
	local entry_version="$5"
	local target_version="$6"

	if ! git -C "$repo_path" push -q -f -u origin "$branch_name"; then
		log_warn "bump failed ($slug): branch push failed"
		git -C "$repo_path" checkout -q "$default_branch" >/dev/null 2>&1 || true
		return 1
	fi
	_open_version_bump_pr "$slug" "$repo_path" "$branch_name" "$default_branch" "$entry_version" "$target_version"
	return $?
}

#######################################
# Read the configured aidevops version for one managed repo.
# Args:
#   $1 — .aidevops.json path
# Outputs: version string, or empty when unreadable/missing.
#######################################
_repo_aidevops_entry_version() {
	local adj_file="$1"
	jq -r '.aidevops_version // empty' "$adj_file" 2>/dev/null || true
	return 0
}

#######################################
# Check whether a managed repo is clean enough for an automatic bump.
# Args:
#   $1 — slug
#   $2 — repo_path
# Returns: 0 when clean, 1 when dirty/unreadable.
#######################################
_repo_bump_worktree_is_clean() {
	local slug="$1"
	local repo_path="$2"
	if [[ -n "$(git -C "$repo_path" status --porcelain 2>/dev/null)" ]]; then
		log_warn "bump skipped ($slug): uncommitted changes present"
		return 1
	fi
	return 0
}

#######################################
# Resolve the default and current branch for a managed repo.
# Args:
#   $1 — repo_path
# Outputs: default_branch<TAB>current_branch
#######################################
_repo_bump_branch_state() {
	local repo_path="$1"
	local default_branch current_branch
	default_branch=$(git -C "$repo_path" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|^refs/remotes/origin/||' || true)
	[[ -z "$default_branch" ]] && default_branch="main"
	current_branch=$(git -C "$repo_path" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	printf '%s\t%s\n' "$default_branch" "$current_branch"
	return 0
}

#######################################
# Publish a preserved default-branch-only .aidevops.json bump through a PR.
# Args:
#   $1 — slug
#   $2 — repo_path
#   $3 — local_only flag
#   $4 — target_version
#   $5 — entry_version
#   $6 — default_branch
# Outputs: one of "bumped", "skipped", "failed".
#######################################
_publish_preserved_default_branch_bump() {
	local slug="$1"
	local repo_path="$2"
	local local_only="$3"
	local target_version="$4"
	local entry_version="$5"
	local default_branch="$6"

	if [[ "$local_only" == "true" ]] || ! git -C "$repo_path" rev-parse --verify "origin/${default_branch}" >/dev/null 2>&1; then
		echo skipped
		return 0
	fi

	local ahead_count ahead_files branch_name
	ahead_count=$(git -C "$repo_path" rev-list --count "origin/${default_branch}..HEAD" 2>/dev/null || echo 0)
	ahead_files=$(git -C "$repo_path" diff --name-only "origin/${default_branch}..HEAD" 2>/dev/null || true)
	if [[ "$ahead_count" == "0" || "$ahead_files" != ".aidevops.json" ]]; then
		echo skipped
		return 0
	fi

	branch_name=$(_version_bump_branch_name "$slug" "$target_version")
	if git -C "$repo_path" checkout -q -B "$branch_name" HEAD >/dev/null 2>&1 &&
		_push_version_bump_pr "$slug" "$repo_path" "$branch_name" "$default_branch" "$entry_version" "$target_version"; then
		git -C "$repo_path" checkout -q "$default_branch" >/dev/null 2>&1 || true
		git -C "$repo_path" reset --hard "origin/${default_branch}" >/dev/null 2>&1 || true
		echo bumped
		return 0
	fi

	log_warn "bump failed ($slug): could not convert unpushed default-branch bump to PR"
	echo failed
	return 0
}

#######################################
# Prepare the version-bump branch when the target repo is not local-only.
# Args:
#   $1 — slug
#   $2 — repo_path
#   $3 — local_only flag
#   $4 — branch_name
#   $5 — default_branch
# Returns: 0 when ready, 1 on pull/branch failure.
#######################################
_prepare_version_bump_branch() {
	local slug="$1"
	local repo_path="$2"
	local local_only="$3"
	local branch_name="$4"
	local default_branch="$5"
	if [[ "$local_only" == "true" ]]; then
		return 0
	fi
	if ! git -C "$repo_path" pull --ff-only origin "$default_branch" >/dev/null 2>&1; then
		log_warn "bump failed ($slug): pull --ff-only failed"
		return 1
	fi
	if ! git -C "$repo_path" checkout -q -B "$branch_name" "$default_branch" >/dev/null 2>&1; then
		log_warn "bump failed ($slug): branch create/reset failed"
		return 1
	fi
	return 0
}

#######################################
# Atomically rewrite .aidevops.json with the target framework version.
# Args:
#   $1 — slug
#   $2 — adj_file
#   $3 — target_version
# Returns: 0 on success, 1 on jq/mktemp failure.
#######################################
_rewrite_repo_aidevops_version() {
	local slug="$1"
	local adj_file="$2"
	local target_version="$3"
	local tmp_adj
	tmp_adj=$(mktemp) || return 1
	if ! jq --arg v "$target_version" '.aidevops_version = $v' "$adj_file" >"$tmp_adj" 2>/dev/null; then
		log_warn "bump failed ($slug): jq rewrite error"
		rm -f "$tmp_adj"
		return 1
	fi
	if ! mv "$tmp_adj" "$adj_file"; then
		log_warn "bump failed ($slug): mv error for $adj_file"
		rm -f "$tmp_adj"
		return 1
	fi
	return 0
}

#######################################
# Commit the rewritten .aidevops.json in a managed repo.
# Args:
#   $1 — slug
#   $2 — repo_path
#   $3 — target_version
#   $4 — default_branch
# Returns: 0 on success, 1 on git add/commit failure.
#######################################
_commit_repo_aidevops_version() {
	local slug="$1"
	local repo_path="$2"
	local target_version="$3"
	local default_branch="$4"
	if ! git -C "$repo_path" add .aidevops.json >/dev/null 2>&1 ||
		! git -C "$repo_path" commit -m "chore: bump .aidevops.json to v${target_version} (r914)" >/dev/null 2>&1; then
		log_warn "bump failed ($slug): commit error"
		git -C "$repo_path" checkout -f -q "$default_branch" >/dev/null 2>&1 || true
		return 1
	fi
	return 0
}

#######################################
# Bump one repo's .aidevops.json to the current framework version.
# Globals: CONFIG_FILE (implicit via callers), AIDEVOPS_* env vars
# Args:
#   $1 — slug (for logs)
#   $2 — repo_path (expanded)
#   $3 — local_only flag ("true"|"false")
#   $4 — target_version
#   $5 — dry_run flag ("0"|"1")
# Outputs: one of "bumped", "skipped", "failed" on stdout.
# Returns: 0 always (count errors via stdout)
#######################################
_bump_single_repo() {
	local slug="$1"
	local repo_path="$2"
	local local_only="$3"
	local target_version="$4"
	local dry_run="$5"

	local adj_file="$repo_path/.aidevops.json"
	local entry_version
	entry_version=$(_repo_aidevops_entry_version "$adj_file")
	if [[ -z "$entry_version" ]]; then
		echo skipped
		return 0
	fi

	# Safety: skip if uncommitted changes
	if ! _repo_bump_worktree_is_clean "$slug" "$repo_path"; then
		echo skipped
		return 0
	fi

	# Ensure on default branch
	local default_branch current_branch
	IFS=$'\t' read -r default_branch current_branch <<<"$(_repo_bump_branch_state "$repo_path")"
	if [[ "$current_branch" != "$default_branch" ]]; then
		log_warn "bump skipped ($slug): not on default branch ($current_branch != $default_branch)"
		echo skipped
		return 0
	fi

	# Semver compare — newer or equal means no bump needed. If a previous r914
	# direct-push attempt left the default branch ahead with the version bump,
	# publish that preserved commit through a PR so future runs stop looping.
	if [[ "$(printf '%s\n%s\n' "$entry_version" "$target_version" | sort -V | tail -1)" == "$entry_version" ]]; then
		_publish_preserved_default_branch_bump "$slug" "$repo_path" "$local_only" "$target_version" "$entry_version" "$default_branch"
		return 0
	fi

	log_info "bump: $slug — v${entry_version} → v${target_version}"
	if [[ "$dry_run" == "1" ]]; then
		echo bumped
		return 0
	fi

	local branch_name
	branch_name=$(_version_bump_branch_name "$slug" "$target_version")
	if ! _prepare_version_bump_branch "$slug" "$repo_path" "$local_only" "$branch_name" "$default_branch"; then
		echo failed
		return 0
	fi

	# Atomic jq rewrite — NEVER sed (session lesson mem_20260419012142_0aa16fa7)
	if ! _rewrite_repo_aidevops_version "$slug" "$adj_file" "$target_version"; then
		if [[ "$local_only" != "true" ]]; then
			git -C "$repo_path" checkout -f -q "$default_branch" >/dev/null 2>&1 || true
		fi
		echo failed
		return 0
	fi

	if ! _commit_repo_aidevops_version "$slug" "$repo_path" "$target_version" "$default_branch"; then
		echo failed
		return 0
	fi

	if [[ "$local_only" != "true" ]]; then
		if ! _push_version_bump_pr "$slug" "$repo_path" "$branch_name" "$default_branch" "$entry_version" "$target_version"; then
			echo failed
			return 0
		fi
	fi

	log_info "bumped: $slug → v${target_version}"
	echo bumped
	return 0
}

#######################################
# Drift check #1 — iterate initialized_repos[] and bump stale versions.
# Args:
#   $1 — target_version
#   $2 — dry_run flag
# Side effects: writes counters into module-scoped globals
#   _R914_BUMPED, _R914_BUMP_SKIPPED, _R914_BUMP_FAILED (resets them to 0 first).
# Bash 3.2 compatible: uses globals instead of `local -n` namerefs.
#######################################
_check_version_bumps() {
	local target_version="$1"
	local dry_run="$2"
	_R914_BUMPED=0
	_R914_BUMP_SKIPPED=0
	_R914_BUMP_FAILED=0
	[[ -z "$target_version" ]] && return 0

	local entries_raw
	entries_raw=$(jq -r '
		.initialized_repos[]? |
		select(.maintenance != false) |
		[.slug, (.path // ""), (.local_only // false)] |
		@tsv
	' "$CONFIG_FILE" 2>/dev/null || true)

	local slug repo_path local_only outcome
	{
		while IFS=$'\t' read -r slug repo_path local_only; do
			[[ -z "$slug" ]] && continue
			repo_path="${repo_path/#\~/$HOME}"
			[[ -z "$repo_path" || ! -d "$repo_path" ]] && continue
			[[ -f "$repo_path/.aidevops.json" ]] || continue
			outcome=$(_bump_single_repo "$slug" "$repo_path" "$local_only" "$target_version" "$dry_run")
			case "$outcome" in
			bumped) _R914_BUMPED=$((_R914_BUMPED + 1)) ;;
			skipped) _R914_BUMP_SKIPPED=$((_R914_BUMP_SKIPPED + 1)) ;;
			failed) _R914_BUMP_FAILED=$((_R914_BUMP_FAILED + 1)) ;;
			esac
		done
	} <<<"$entries_raw"
	return 0
}

#######################################
# Drift check #2 — missing-folder detection (MVP log-only).
# Args:
#   $1 — nameref for missing_folder counter
#######################################
_check_missing_folders() {
	_R914_MISSING_FOLDER=0
	local entries_raw
	entries_raw=$(jq -r '
		.initialized_repos[]? |
		[.slug, (.path // ""), (.archived // false)] |
		@tsv
	' "$CONFIG_FILE" 2>/dev/null || true)

	local slug repo_path archived
	{
		while IFS=$'\t' read -r slug repo_path archived; do
			[[ -z "$slug" ]] && continue
			repo_path="${repo_path/#\~/$HOME}"
			[[ -z "$repo_path" ]] && continue
			if [[ ! -d "$repo_path" && "$archived" != "true" ]]; then
				log_warn "missing-folder: $slug — path '$repo_path' does not exist (not archived). Will file issue in follow-up implementation."
				_R914_MISSING_FOLDER=$((_R914_MISSING_FOLDER + 1))
			fi
		done
	} <<<"$entries_raw"
	return 0
}

#######################################
# Check if a candidate path is already tracked in initialized_repos[].
# Args:
#   $1 — candidate path
#   Remaining args: known_paths array entries
# Returns: 0 if tracked, 1 otherwise.
#######################################
_is_path_tracked() {
	local candidate="$1"
	shift
	local kp
	for kp in "$@"; do
		[[ "$candidate" == "$kp" ]] && return 0
	done
	return 1
}

#######################################
# Drift check #3 — no-init detection (MVP log-only).
# Args:
#   $1 — nameref for no_init counter
#######################################
_check_no_init_repos() {
	_R914_NO_INIT=0

	local known_paths=()
	local kp dir
	local raw
	raw=$(jq -r '.initialized_repos[]?.path // empty' "$CONFIG_FILE" 2>/dev/null || true)
	{
		while IFS= read -r kp; do
			[[ -z "$kp" ]] && continue
			kp="${kp/#\~/$HOME}"
			known_paths+=("$kp")
		done
	} <<<"$raw"

	local parent_dirs=()
	raw=$(jq -r '.git_parent_dirs[]?' "$CONFIG_FILE" 2>/dev/null || true)
	{
		while IFS= read -r dir; do
			[[ -z "$dir" ]] && continue
			dir="${dir/#\~/$HOME}"
			parent_dirs+=("$dir")
		done
	} <<<"$raw"

	local parent_dir candidate
	for parent_dir in "${parent_dirs[@]}"; do
		[[ -d "$parent_dir" ]] || continue
		# Newline-delimited is safe here: git repo dirs rarely contain newlines.
		raw=$(find "$parent_dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null)
		{
			while IFS= read -r candidate; do
				[[ -d "$candidate/.git" ]] || continue
				_is_path_tracked "$candidate" "${known_paths[@]}" && continue
				[[ -f "$candidate/.aidevops-skip" ]] && continue
				[[ -f "$candidate/.aidevops.json" ]] && continue
				log_warn "no-init: $candidate — git repo with no .aidevops.json and no .aidevops-skip marker. Will file issue in follow-up implementation."
				_R914_NO_INIT=$((_R914_NO_INIT + 1))
			done
		} <<<"$raw"
	done
	return 0
}

#######################################
# Read current framework version from VERSION file.
# Echoes version on stdout, empty string if unavailable.
#######################################
_current_framework_version() {
	local version_file="$HOME/.aidevops/agents/VERSION"
	[[ -f "$version_file" ]] || {
		echo ""
		return 0
	}
	tr -d '[:space:]' <"$version_file"
	return 0
}

#######################################
# r914 orchestrator — runs all three drift checks.
# Honours: AIDEVOPS_REPO_HEALTH (false disables), AIDEVOPS_REPO_HEALTH_DRY_RUN=1.
# Returns: 0 on clean run, 1 if any bump failed.
#######################################
cmd_check() {
	ensure_dirs
	if [[ "${AIDEVOPS_REPO_HEALTH:-}" == "false" ]]; then
		log_info "r914 disabled via AIDEVOPS_REPO_HEALTH=false"
		return 0
	fi
	if ! acquire_lock; then
		log_warn "Could not acquire lock, skipping run"
		return 0
	fi
	trap 'release_lock' EXIT

	if [[ ! -f "$CONFIG_FILE" ]]; then
		log_warn "No repos.json at $CONFIG_FILE — r914 has nothing to check"
		return 0
	fi
	if ! command -v jq >/dev/null 2>&1; then
		log_warn "jq not installed — r914 requires jq for safe JSON rewrites. Aborting."
		return 1
	fi

	local dry_run=0
	if [[ "${AIDEVOPS_REPO_HEALTH_DRY_RUN:-0}" == "1" ]]; then
		dry_run=1
		log_info "DRY-RUN mode: detections will log only, no writes/pushes/issues"
	fi

	local current_version
	current_version=$(_current_framework_version)
	if [[ -z "$current_version" ]]; then
		log_warn "Could not read current framework version — skipping bump check"
	else
		log_info "r914 starting: current framework version is v${current_version}"
	fi

	# Counters below are populated by the _check_* helpers into module-scoped
	# globals (_R914_BUMPED, _R914_BUMP_SKIPPED, _R914_BUMP_FAILED,
	# _R914_MISSING_FOLDER, _R914_NO_INIT). Bash 3.2 safe — no namerefs.
	_check_version_bumps "$current_version" "$dry_run"
	_check_missing_folders
	_check_no_init_repos

	log_info "r914 complete: ${_R914_BUMPED} bumped, ${_R914_BUMP_SKIPPED} bump-skipped, ${_R914_BUMP_FAILED} bump-failed, ${_R914_MISSING_FOLDER} missing-folder, ${_R914_NO_INIT} no-init"
	update_state "$_R914_BUMPED" "$((_R914_BUMP_SKIPPED + _R914_MISSING_FOLDER + _R914_NO_INIT))" "$_R914_BUMP_FAILED"

	[[ $_R914_BUMP_FAILED -gt 0 ]] && return 1
	return 0
}

#######################################
# Enable repo-aidevops-health via launchd (macOS)
# Arguments:
#   $1 - script_path
#   $2 - interval (minutes)
#######################################
_enable_launchd() {
	local script_path="$1"
	local interval="$2"
	local interval_seconds=$((interval * 60))

	# Migrate from old label if present (com.aidevops -> sh.aidevops)
	local old_label="com.aidevops.aidevops-repo-aidevops-health"
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

	# Create named symlink so macOS System Settings shows "aidevops-repo-aidevops-health".
	# Preserve an already-correct link to avoid repeat background-item notices.
	local bin_dir="$HOME/.aidevops/bin"
	mkdir -p "$bin_dir"
	local display_link="$bin_dir/aidevops-repo-aidevops-health"
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
		echo "  Disable with: aidevops repo-aidevops-health disable"
		echo "  Sync now:     aidevops repo-aidevops-health check"
	else
		print_error "Failed to load LaunchAgent: $LAUNCHD_LABEL"
		return 1
	fi
	return 0
}

#######################################
# Enable repo-aidevops-health via systemd user timer (Linux with systemd)
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
	local on_calendar=""
	on_calendar=$("${SCRIPT_DIR}/routine-schedule-helper.sh" systemd-calendar "$REPO_AIDEVOPS_HEALTH_SCHEDULE") || return 1

	mkdir -p "${SYSTEMD_SERVICE_DIR}"

	printf '%s' "[Unit]
Description=aidevops repo-aidevops-health
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
Description=aidevops repo-aidevops-health Timer

[Timer]
OnCalendar=${on_calendar}
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

	print_success "Repo sync enabled (${REPO_AIDEVOPS_HEALTH_SCHEDULE})"
	echo ""
	echo "  Scheduler: systemd user timer"
	echo "  Unit:      ${SYSTEMD_UNIT_NAME}.timer"
	echo "  Service:   ${service_file}"
	echo "  Timer:     ${timer_file}"
	echo "  Logs:      ${LOG_FILE}"
	echo ""
	echo "  Disable with: aidevops repo-aidevops-health disable"
	return 0
}

#######################################
# Disable repo-aidevops-health systemd user timer
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
# Enable repo-aidevops-health via cron (Linux)
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
	echo "  Disable with: aidevops repo-aidevops-health disable"
	echo "  Sync now:     aidevops repo-aidevops-health check"
	return 0
}

#######################################
# Enable repo-aidevops-health scheduler (platform-aware)
# On macOS: installs LaunchAgent plist (daily)
# On Linux: installs crontab entry
#######################################
cmd_enable() {
	ensure_dirs

	local interval="${AIDEVOPS_REPO_HEALTH_INTERVAL:-$DEFAULT_INTERVAL}"
	local script_path="$HOME/.aidevops/agents/scripts/repo-aidevops-health-helper.sh"

	# Verify the script exists at the deployed location
	if [[ ! -x "$script_path" ]]; then
		# Fall back to repo location
		script_path="$INSTALL_DIR/.agents/scripts/repo-aidevops-health-helper.sh"
		if [[ ! -x "$script_path" ]]; then
			print_error "repo-aidevops-health-helper.sh not found"
			return 1
		fi
	fi

	local backend
	backend="$(_get_scheduler_backend)"

	if [[ "$backend" == "launchd" ]]; then
		_enable_launchd "$script_path" "$interval"
		return $?
	elif [[ "$backend" == "systemd" ]]; then
		_enable_systemd "$script_path" "$interval"
		return $?
	fi

	_enable_cron "$script_path" "$interval"
	return $?
}

#######################################
# Disable repo-aidevops-health scheduler (platform-aware)
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
		local old_label="com.aidevops.aidevops-repo-aidevops-health"
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
	elif [[ "$backend" == "systemd" ]]; then
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
				[[ -n "$interval" ]] && echo "  Interval:  every ${interval}s ($((interval / 60)) min)"
				echo "  Plist:     $LAUNCHD_PLIST"
			fi
		else
			echo -e "  Scheduler: launchd (macOS LaunchAgent)"
			echo -e "  Status:    ${YELLOW}not loaded${NC}"
		fi
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
	local dir
	local parent_dirs_raw
	parent_dirs_raw=$(get_parent_dirs)
	{
		while IFS= read -r dir; do
			[[ -z "$dir" ]] && continue
			dir="${dir/#\~/$HOME}"
			if [[ -d "$dir" ]]; then
				local count
				count=$(find "$dir" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
				echo "    $dir ($count subdirs)"
			else
				echo -e "    ${YELLOW}$dir (not found)${NC}"
			fi
		done
	} <<<"$parent_dirs_raw"

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
	if [[ "${AIDEVOPS_REPO_HEALTH:-}" == "false" ]]; then
		echo ""
		echo -e "  ${YELLOW}Note: AIDEVOPS_REPO_HEALTH=false is set (overrides scheduler)${NC}"
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
		echo "Add one with: aidevops repo-aidevops-health dirs add ~/Git"
		return 0
	fi
	echo "Configured git parent directories:"
	local dir
	{
		while IFS= read -r dir; do
			[[ -z "$dir" ]] && continue
			local expanded="${dir/#\~/$HOME}"
			if [[ -d "$expanded" ]]; then
				echo "  $dir"
			else
				echo "  $dir  (not found)"
			fi
		done
	} <<<"$dirs"
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
		print_error "Usage: aidevops repo-aidevops-health dirs add <path>"
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
		print_error "Usage: aidevops repo-aidevops-health dirs remove <path>"
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
		echo "Usage: aidevops repo-aidevops-health dirs [list|add|remove|rm]"
		return 1
		;;
	esac
	return 0
}

#######################################
# Print configured parent directories (cmd_config helper).
#######################################
_cmd_config_print_dirs() {
	local dirs
	dirs=$(jq -r '.git_parent_dirs[]? // empty' "$CONFIG_FILE" || true)
	if [[ -z "$dirs" ]]; then
		echo "No parent directories configured (using default: ~/Git)"
		return 0
	fi
	echo "Configured parent directories:"
	local dir
	{
		while IFS= read -r dir; do
			[[ -z "$dir" ]] && continue
			echo "  $dir"
		done
	} <<<"$dirs"
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

	if [[ ! -f "$CONFIG_FILE" ]] || ! command -v jq &>/dev/null; then
		echo "No config file found (using default: ~/Git)"
	else
		_cmd_config_print_dirs
	fi

	echo ""
	echo "Manage parent directories:"
	echo "  aidevops repo-aidevops-health dirs list          # Show configured directories"
	echo "  aidevops repo-aidevops-health dirs add ~/Projects  # Add a directory"
	echo "  aidevops repo-aidevops-health dirs remove ~/Old    # Remove a directory"
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
		print_info "No log file yet (repo-aidevops-health hasn't run)"
	fi
	return 0
}

#######################################
# Help
#######################################
cmd_help() {
	cat <<'EOF'
repo-aidevops-health-helper.sh - Daily git pull of repos in configured parent directories

USAGE:
    repo-aidevops-health-helper.sh <command> [options]
    aidevops repo-aidevops-health <command> [options]

COMMANDS:
    enable              Install daily scheduler (launchd on macOS, cron on Linux)
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
    AIDEVOPS_REPO_HEALTH=false             Disable even when scheduler is installed
    AIDEVOPS_REPO_HEALTH_INTERVAL=1440     Minutes between syncs (default: 1440 = daily)

CONFIGURATION:
    Manage with: aidevops repo-aidevops-health dirs [add|remove|list]
    Or manually add "git_parent_dirs" array to ~/.config/aidevops/repos.json:
      {"git_parent_dirs": ["~/Git", "~/Projects"]}
    Default: ~/Git

SAFETY:
    - Only runs git pull --ff-only (never creates merge commits)
    - Skips repos with dirty working trees (uncommitted changes)
    - Skips repos not on their default branch (main/master)
    - Skips repos with no remote configured
    - Logs failures without stopping (other repos still sync)
    - Worktrees are ignored — only main checkouts are synced

SCHEDULER BACKENDS:
    macOS:  launchd LaunchAgent (~/Library/LaunchAgents/sh.aidevops.repo-aidevops-health.plist)
            - Runs daily (every 1440 minutes by default)
    Linux:  cron (daily at 3am, crontab entry with # aidevops-repo-aidevops-health marker)

HOW IT WORKS:
    1. Scheduler runs 'repo-aidevops-health-helper.sh check' daily
    2. Reads git_parent_dirs from ~/.config/aidevops/repos.json
    3. Scans each parent directory to find git repos (maxdepth 1)
    4. On each repo:
       a. Skips when no remote, detached HEAD, or not on default branch
       b. Skips when working tree is dirty
       c. Fetches from remote
       d. Pulls with --ff-only when upstream has new commits
    5. Logs results (pulled/skipped/failed) to ~/.aidevops/logs/repo-aidevops-health.log

LOGS:
    ~/.aidevops/logs/repo-aidevops-health.log

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
	check | run) cmd_check "$@" ;;
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

if [[ "${AIDEVOPS_REPO_HEALTH_HELPER_SOURCE_ONLY:-0}" != "1" ]]; then
	main "$@"
fi
