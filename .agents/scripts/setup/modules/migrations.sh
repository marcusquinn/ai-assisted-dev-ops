#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Migration functions: migrate_* and cleanup_* functions
# Part of aidevops setup.sh modularization (t316.3)

# Shell safety baseline
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true
MIGRATION_PLATFORM_DARWIN="Darwin"

_legacy_temp_artifact_is_active() {
	local path="$1"
	local basename="${path##*/}"
	local pid=""
	if [[ "$basename" =~ [.-]([0-9]+)$ ]]; then
		pid="${BASH_REMATCH[1]}"
	fi
	[[ -n "$pid" ]] || return 1
	_is_process_alive_and_matches "$pid" "$FRAMEWORK_PROCESS_PATTERN"
	return $?
}

_legacy_opencode_native_is_attributable() {
	local path="$1"
	local symbols=""
	command -v nm >/dev/null 2>&1 || return 1
	symbols=$(nm -D -g "$path" 2>/dev/null) || return 1
	grep -Eq '(^|[[:space:]])fff_create_instance2?$' <<<"$symbols" || return 1
	grep -Eq '(^|[[:space:]])fff_destroy$' <<<"$symbols" || return 1
	grep -Eq '(^|[[:space:]])fff_search$' <<<"$symbols" || return 1
	return 0
}

_legacy_opencode_native_has_no_holder() {
	local path="$1"
	local lsof_status=0
	command -v lsof >/dev/null 2>&1 || return 1
	lsof "$path" >/dev/null 2>&1 || lsof_status=$?
	[[ "$lsof_status" -eq 1 ]] || return 1
	return 0
}

_cleanup_legacy_opencode_native_artifacts() {
	local workspace_root="${AIDEVOPS_WORKSPACE_DIR:-${HOME:?}/.aidevops/.agent-workspace}"
	local root="${AIDEVOPS_TEMP_DIR:-${workspace_root}/tmp}"
	[[ -d "$root" ]] || return 0
	root=$(cd "$root" && pwd -P) || return 0

	local now=""
	now=$(date +%s)
	local max_age="${AIDEVOPS_TEMP_MAX_AGE_SECONDS:-604800}"
	[[ "$max_age" =~ ^[0-9]+$ ]] || max_age=604800
	local uid=""
	uid=$(id -u)
	local cleaned=0
	local candidate=""
	for candidate in "$root"/.*-00000000.so; do
		[[ -f "$candidate" && ! -L "$candidate" ]] || continue
		local owner=""
		owner=$(stat -f '%u' "$candidate" 2>/dev/null) || owner=$(stat -c '%u' "$candidate" 2>/dev/null) || continue
		[[ "$owner" == "$uid" ]] || continue
		local mtime=""
		mtime=$(_file_mtime_epoch "$candidate") || continue
		((now - mtime > max_age)) || continue
		_legacy_opencode_native_is_attributable "$candidate" || continue
		_legacy_opencode_native_has_no_holder "$candidate" || continue
		rm -f -- "$candidate" || continue
		((++cleaned))
	done

	if ((cleaned > 0)); then
		print_info "Cleaned $cleaned stale OpenCode FFF native temporary artifact(s)"
	fi
	return 0
}

# Remove only directly attributable aidevops artifacts from the macOS per-user
# temporary root. Generic tmp.* entries are intentionally excluded because
# their ownership cannot be proven after creation.
cleanup_legacy_aidevops_temp_artifacts() {
	_cleanup_legacy_opencode_native_artifacts
	local root="${AIDEVOPS_LEGACY_TEMP_ROOT:-}"
	if [[ -z "$root" ]]; then
		[[ "$(uname -s 2>/dev/null || true)" == "$MIGRATION_PLATFORM_DARWIN" ]] || return 0
		root=$(getconf DARWIN_USER_TEMP_DIR 2>/dev/null || true)
	fi
	[[ -n "$root" && -d "$root" ]] || return 0
	root="${root%/}"
	if [[ -z "${AIDEVOPS_LEGACY_TEMP_ROOT:-}" && "$root" != /var/folders/*/T ]]; then
		print_warning "Skipping unexpected macOS temporary root"
		return 0
	fi

	local now
	now=$(date +%s)
	local max_age="${AIDEVOPS_TEMP_MAX_AGE_SECONDS:-604800}"
	[[ "$max_age" =~ ^[0-9]+$ ]] || max_age=604800
	local uid
	uid=$(id -u)
	local cleaned=0
	local candidate=""
	for candidate in \
		"$root"/aidevops-update-* \
		"$root"/aidevops-headless-prompt.* \
		"$root"/aidevops-worker-auth.* \
		"$root"/aidevops-canary* \
		"$root"/aidevops-plugin-verify.* \
		"$root"/aidevops-pulse-pr-list-provider-* \
		"$root"/aidevops-pulse-pr-list-cache-* \
		"$root"/aidevops-pulse-runtime-* \
		"$root"/aidevops-systemd-worker.* \
		"$root"/aidevops-systemd-state.* \
		"$root"/aidevops-inbox-prompt.* \
		"$root"/aidevops-gh-body.* \
		"$root"/aidevops-parent-body.* \
		"$root"/aidevops-gh-response.* \
		"$root"/aidevops-gh-secondary.*; do
		[[ -e "$candidate" || -L "$candidate" ]] || continue
		[[ ! -L "$candidate" ]] || continue
		local owner=""
		owner=$(stat -f '%u' "$candidate" 2>/dev/null) || owner=$(stat -c '%u' "$candidate" 2>/dev/null) || continue
		[[ "$owner" == "$uid" ]] || continue
		local mtime=""
		mtime=$(_file_mtime_epoch "$candidate") || continue
		((now - mtime > max_age)) || continue
		_legacy_temp_artifact_is_active "$candidate" && continue
		rm -rf -- "$candidate" || continue
		((++cleaned))
	done

	if ((cleaned > 0)); then
		print_info "Cleaned $cleaned legacy aidevops temporary artifact(s) older than seven days"
	fi
	return 0
}

cleanup_deprecated_paths() {
	local agents_dir="$HOME/.aidevops/agents"
	local cleaned=0

	# List of deprecated paths (add new ones here when reorganizing)
	local deprecated_paths=(
		# v2.40.7: wordpress moved from root to tools/wordpress
		"$agents_dir/wordpress.md"
		"$agents_dir/wordpress"
		# v2.41.0: build-agent and build-mcp moved from root to tools/
		"$agents_dir/build-agent.md"
		"$agents_dir/build-agent"
		"$agents_dir/build-mcp.md"
		"$agents_dir/build-mcp"
		# v2.93.3: moltbot renamed to openclaw (formerly clawdbot)
		"$agents_dir/tools/ai-assistants/clawdbot.md"
		"$agents_dir/tools/ai-assistants/moltbot.md"
		# Removed non-OpenCode AI tool docs (focus on OpenCode only)
		"$agents_dir/tools/ai-assistants/windsurf.md"
		"$agents_dir/tools/ai-assistants/configuration.md"
		"$agents_dir/tools/ai-assistants/status.md"
		# Removed oh-my-opencode integration (no longer supported)
		"$agents_dir/tools/opencode/oh-my-opencode.md"
		# t199.8: youtube moved from root to content/distribution/youtube/
		"$agents_dir/youtube.md"
		"$agents_dir/youtube"
		# osgrep removed — disproportionate CPU/disk cost vs rg + LLM comprehension
		"$agents_dir/tools/context/osgrep.md"
		# GH#5155: scripts archived upstream but orphaned in deployed installs
		# (rsync only adds/overwrites, doesn't delete removed files)
		"$agents_dir/scripts/pattern-tracker-helper.sh"
		"$agents_dir/scripts/quality-sweep-helper.sh"
		"$agents_dir/scripts/quality-loop-helper.sh"
		"$agents_dir/scripts/review-pulse-helper.sh"
		"$agents_dir/scripts/self-improve-helper.sh"
		"$agents_dir/scripts/coderabbit-pulse-helper.sh"
		"$agents_dir/scripts/coderabbit-task-creator-helper.sh"
		"$agents_dir/scripts/audit-task-creator-helper.sh"
		"$agents_dir/scripts/batch-cleanup-helper.sh"
		"$agents_dir/scripts/coordinator-helper.sh"
		"$agents_dir/scripts/finding-to-task-helper.sh"
		"$agents_dir/scripts/objective-runner-helper.sh"
		"$agents_dir/scripts/ralph-loop-helper.sh"
		"$agents_dir/scripts/stale-pr-helper.sh"
	)

	for path in "${deprecated_paths[@]}"; do
		if [[ -e "$path" ]]; then
			rm -rf "$path"
			((++cleaned))
		fi
	done

	if [[ $cleaned -gt 0 ]]; then
		print_info "Cleaned up $cleaned deprecated agent path(s)"
	fi

	# Remove oh-my-opencode remnants (no longer supported) — but respect user preference.
	# Default: preserve user files. Override with --overwrite flag or settings.json.
	# See: ~/.config/aidevops/settings.json { "preserve_oh_my_opencode": true }
	local omo_config="$HOME/.config/opencode/oh-my-opencode.json"
	if [[ -f "$omo_config" ]]; then
		if should_cleanup_oh_my_opencode_artifacts "oh-my-opencode config ($omo_config)"; then
			rm -f "$omo_config"
			print_info "Removed oh-my-opencode config"
		fi
	fi

	# Remove osgrep — disproportionate CPU/disk cost (74GB indexes, 4 CPU cores on startup)
	# rg + fd + LLM comprehension covers the same ground at zero resource cost
	cleanup_osgrep

	# Remove opencode-antigravity-auth — third-party Google OAuth plugin removed from aidevops.
	# When present but unresolvable it breaks the OpenCode plugin chain, preventing the
	# aidevops pool from injecting tokens and causing "API key missing" errors for all providers.
	cleanup_antigravity_plugin

	# Remove oh-my-opencode from plugin array if present — guarded by same setting
	local opencode_config
	opencode_config=$(find_opencode_config 2>/dev/null) || true
	if [[ -n "$opencode_config" ]] && [[ -f "$opencode_config" ]] && command -v jq &>/dev/null; then
		if jq -e '.plugin | index("oh-my-opencode")' "$opencode_config" >/dev/null 2>&1; then
			if should_cleanup_oh_my_opencode_artifacts "oh-my-opencode plugin entry in OpenCode config"; then
				local tmp_file
				tmp_file=$(mktemp)
				trap 'rm -f "${tmp_file:-}"' RETURN
				jq '.plugin = [.plugin[] | select(. != "oh-my-opencode")]' "$opencode_config" >"$tmp_file" && mv "$tmp_file" "$opencode_config"
				print_info "Removed oh-my-opencode from OpenCode plugin list"
			fi
		fi
	fi

	return 0
}

# Backward-compatibility guard for oh-my-opencode cleanup migration.
# setup.sh no longer defines should_overwrite_user_file() in current runtime.
# Preserve user files by default when the legacy helper is unavailable.
should_cleanup_oh_my_opencode_artifacts() {
	local description="$1"

	if type should_overwrite_user_file &>/dev/null; then
		should_overwrite_user_file "preserve_oh_my_opencode" "$description"
		return $?
	fi

	return 1
}

# Remove osgrep completely — one-time cleanup for all aidevops users
# osgrep consumed 74GB disk (lancedb indexes) and 4 CPU cores on startup.
# rg + fd + LLM comprehension covers the same ground at zero resource cost.
cleanup_osgrep() {
	local cleaned=false

	# 0. Kill running osgrep processes first (MCP servers, indexers)
	# These are Node.js processes already loaded in memory — removing the
	# binary and data won't stop them, and they may try to rebuild indexes.
	if pgrep -f 'osgrep' >/dev/null; then
		print_info "Killing running osgrep processes..."
		pkill -f 'osgrep' || true
		# Give processes a moment to exit gracefully
		sleep 1
		# Force-kill any stragglers
		pkill -9 -f 'osgrep' || true
		cleaned=true
	fi

	# 1. Uninstall npm package (global)
	if command -v osgrep &>/dev/null; then
		print_info "Removing osgrep npm package..."
		npm uninstall -g osgrep >/dev/null 2>&1 || true
		cleaned=true
	fi

	# 2. Remove indexes, models, and config (~74GB)
	if [[ -d "$HOME/.osgrep" ]]; then
		print_info "Removing osgrep data directory (~74GB indexes)..."
		rm -rf "$HOME/.osgrep"
		cleaned=true
	fi

	# 3. Remove osgrep from OpenCode MCP config
	local opencode_config
	opencode_config=$(find_opencode_config 2>/dev/null) || true
	if [[ -n "$opencode_config" ]] && [[ -f "$opencode_config" ]] && command -v jq &>/dev/null; then
		local osgrep_mcp="osgrep"
		local osgrep_tool="osgrep_*"
		if jq -e --arg mcp "$osgrep_mcp" '.mcp[$mcp]' "$opencode_config" >/dev/null 2>&1; then
			local tmp_file
			tmp_file=$(mktemp)
			if jq --arg mcp "$osgrep_mcp" --arg tool "$osgrep_tool" 'del(.mcp[$mcp]) | del(.tools[$tool])' "$opencode_config" >"$tmp_file" 2>/dev/null; then
				mv "$tmp_file" "$opencode_config"
				print_info "Removed osgrep from OpenCode MCP config"
			else
				rm -f "$tmp_file"
			fi
			cleaned=true
		fi
	fi

	# 4. Remove osgrep from Claude Code settings
	local claude_settings="$HOME/.claude/settings.json"
	if [[ -f "$claude_settings" ]] && command -v jq &>/dev/null; then
		if jq -e '.mcpServers["osgrep"] // .enabledPlugins["osgrep@osgrep"]' "$claude_settings" >/dev/null 2>&1; then
			local tmp_file
			tmp_file=$(mktemp)
			if jq 'del(.mcpServers["osgrep"]) | del(.enabledPlugins["osgrep@osgrep"])' "$claude_settings" >"$tmp_file" 2>/dev/null; then
				mv "$tmp_file" "$claude_settings"
				print_info "Removed osgrep from Claude Code settings"
			else
				rm -f "$tmp_file"
			fi
			cleaned=true
		fi
	fi

	# 5. Remove per-repo .osgrep directories in registered repos
	local repos_file="$HOME/.config/aidevops/repos.json"
	if [[ -f "$repos_file" ]] && command -v jq &>/dev/null; then
		while IFS= read -r repo_path; do
			[[ -z "$repo_path" ]] && continue
			[[ ! -d "$repo_path" ]] && continue
			if [[ -d "$repo_path/.osgrep" ]]; then
				rm -rf "$repo_path/.osgrep"
			fi
		done < <(jq -r '.[]' "$repos_file" 2>/dev/null)
	fi

	if [[ "$cleaned" == "true" ]]; then
		print_success "osgrep removed (freed CPU cores and disk space)"
	fi

	return 0
}

# Remove opencode-antigravity-auth plugin — third-party Google OAuth plugin removed from aidevops.
# When present but unresolvable it breaks the OpenCode plugin chain, preventing the aidevops
# pool from injecting tokens and causing "API key missing" errors for all providers.
# Affects: opencode.json plugin array, Claude Code settings enabledPlugins.
cleanup_antigravity_plugin() {
	local cleaned=false
	local plugin_id="opencode-antigravity-auth"

	# 1. Remove from OpenCode config plugin array
	local opencode_config
	opencode_config=$(find_opencode_config 2>/dev/null) || true
	if [[ -n "$opencode_config" ]] && [[ -f "$opencode_config" ]] && command -v jq &>/dev/null; then
		# Plugin may appear as bare name or with @version suffix
		if jq -e --arg p "$plugin_id" '.plugin // [] | map(. | startswith($p)) | any' "$opencode_config" >/dev/null 2>&1; then
			local tmp_file
			tmp_file=$(mktemp)
			if jq --arg p "$plugin_id" '.plugin = [(.plugin // [])[] | select(startswith($p) | not)]' \
				"$opencode_config" >"$tmp_file" 2>/dev/null; then
				mv "$tmp_file" "$opencode_config"
				print_success "Removed ${plugin_id} from OpenCode plugin list"
				cleaned=true
			else
				rm -f "$tmp_file"
			fi
		fi
	fi

	# 2. Remove from Claude Code settings enabledPlugins (if present)
	local claude_settings="$HOME/.claude/settings.json"
	if [[ -f "$claude_settings" ]] && command -v jq &>/dev/null; then
		if jq -e --arg p "$plugin_id" '.enabledPlugins // {} | keys[] | startswith($p)' \
			"$claude_settings" >/dev/null 2>&1; then
			local tmp_file
			tmp_file=$(mktemp)
			if jq --arg p "$plugin_id" \
				'del(.enabledPlugins[(.enabledPlugins // {} | keys[] | select(startswith($p)))])' \
				"$claude_settings" >"$tmp_file" 2>/dev/null; then
				mv "$tmp_file" "$claude_settings"
				print_success "Removed ${plugin_id} from Claude Code settings"
				cleaned=true
			else
				rm -f "$tmp_file"
			fi
		fi
	fi

	if [[ "$cleaned" == "false" ]]; then
		print_info "${plugin_id} not present — nothing to remove"
	fi

	return 0
}

# Remove stale bun-installed opencode if npm version exists (v2.123.5)
# Prior to v2.123.1, tool-version-check.sh used `bun install -g opencode-ai`.
# This left a binary at ~/.bun/bin/opencode that shadows the npm install
# if ~/.bun/bin is earlier in PATH than the npm bin directory.
cleanup_stale_bun_opencode() {
	local bun_opencode="$HOME/.bun/bin/opencode"
	local bun_modules="$HOME/.bun/install/global/node_modules/opencode-ai"

	# Only clean up if the stale bun binary exists
	if [[ ! -f "$bun_opencode" ]] && [[ ! -d "$bun_modules" ]]; then
		return 0
	fi

	# Only clean up if npm version is installed (don't leave user without opencode)
	local npm_opencode
	npm_opencode=$(npm list -g opencode-ai --json 2>/dev/null | grep -c '"opencode-ai"' || true)
	if [[ "$npm_opencode" -eq 0 ]]; then
		# npm version not installed — install it first, then clean up bun
		if command -v npm >/dev/null 2>&1; then
			local pin_ver="${OPENCODE_PINNED_VERSION:-latest}"
			print_info "Installing opencode via npm (replacing bun install)..."
			npm_global_install "opencode-ai@${pin_ver}" >/dev/null 2>&1 || true
		else
			# Can't install npm version — leave bun version in place
			return 0
		fi
	fi

	# Remove stale bun binary and modules
	if [[ -f "$bun_opencode" ]]; then
		rm -f "$bun_opencode"
		print_info "Removed stale bun opencode binary: $bun_opencode"
	fi

	if [[ -d "$bun_modules" ]]; then
		rm -rf "$bun_modules"
		print_info "Removed stale bun opencode modules: $bun_modules"
	fi

	print_success "Cleaned up stale bun opencode install (npm version is canonical)"

	return 0
}

# Register the setup caller's linked worktree as owned before setup performs
# deployment work that may restart the pulse or trigger cleanup routines.
protect_current_setup_worktree() {
	command -v git &>/dev/null || return 0
	declare -F register_worktree >/dev/null 2>&1 || return 0

	local current_root=""
	local git_dir=""
	local common_dir=""
	local branch=""

	current_root=$(git -C "${INSTALL_DIR:-.}" rev-parse --show-toplevel 2>/dev/null || true)
	[[ -n "$current_root" ]] || return 0
	current_root=$(cd "$current_root" 2>/dev/null && pwd -P) || return 0

	git_dir=$(git -C "$current_root" rev-parse --git-dir 2>/dev/null) || return 0
	common_dir=$(git -C "$current_root" rev-parse --git-common-dir 2>/dev/null) || return 0
	[[ "$git_dir" = /* ]] || git_dir="$current_root/$git_dir"
	[[ "$common_dir" = /* ]] || common_dir="$current_root/$common_dir"
	git_dir=$(cd "$git_dir" 2>/dev/null && pwd -P) || git_dir=""
	common_dir=$(cd "$common_dir" 2>/dev/null && pwd -P) || common_dir=""
	[[ -n "$git_dir" && -n "$common_dir" && "$git_dir" != "$common_dir" ]] || return 0

	branch=$(git -C "$current_root" rev-parse --abbrev-ref HEAD 2>/dev/null || true)
	[[ -n "$branch" ]] || branch="HEAD"
	register_worktree "$current_root" "$branch" --task "setup-noninteractive" --session "setup:${OPENCODE_SESSION_ID:-${CLAUDE_SESSION_ID:-manual}}" >/dev/null 2>&1 || true
	print_info "Protected current setup worktree from cleanup: $current_root"
	return 0
}

# t1929: Remove stale contributor/legacy health issue cache files and close
# the corresponding GitHub issues. One-time migration — the root cause
# (API failure in _get_runner_role defaulting to "contributor") is fixed
# by the 4-layer role resolution in stats-functions.sh.
#
# Gated by a flag file so it runs exactly once per install.
cleanup_worktree_entries_in_repos_json() {
	# t2250: `find ~/Git -name .aidevops.json` during auto-discovery picks up
	# files that exist inside linked worktrees (because worktrees inherit the
	# working tree). Before the register_repo guard, each worktree ended up as
	# a separate entry in repos.json — confusing tabby-profile-sync, pulse,
	# cross-repo tooling, and anything that enumerates `initialized_repos`.
	#
	# One-shot migration: scan `initialized_repos[].path`, detect entries that
	# are linked worktrees (git rev-parse --git-dir != --git-common-dir), and
	# remove them. Safe to re-run; a flag file suppresses re-execution once
	# the cleanup has been done on this machine.
	local flag_file="${HOME}/.aidevops/logs/.migrated-worktree-repos-json-t2250"
	[[ -f "$flag_file" ]] && return 0

	local repos_json="${HOME}/.config/aidevops/repos.json"
	[[ -f "$repos_json" ]] || return 0

	command -v jq &>/dev/null || return 0
	command -v git &>/dev/null || return 0

	local stale_paths=()
	local skipped_current_paths=()
	local current_worktree=""
	local current_physical_dir=""
	local path git_dir common_dir resolved_path

	current_physical_dir=$(pwd -P 2>/dev/null || pwd)
	current_worktree=$(git rev-parse --show-toplevel 2>/dev/null || true)
	if [[ -n "$current_worktree" ]]; then
		current_worktree=$(cd "$current_worktree" 2>/dev/null && pwd -P) || current_worktree=""
	fi

	while IFS= read -r path; do
		[[ -n "$path" && -d "$path" ]] || continue
		resolved_path=$(cd "$path" 2>/dev/null && pwd -P) || resolved_path=""
		git_dir=$(git -C "$path" rev-parse --git-dir 2>/dev/null) || continue
		common_dir=$(git -C "$path" rev-parse --git-common-dir 2>/dev/null) || continue
		# Normalise to absolute paths for comparison.
		[[ "$git_dir" = /* ]] || git_dir="$path/$git_dir"
		[[ "$common_dir" = /* ]] || common_dir="$path/$common_dir"
		git_dir=$(cd "$git_dir" 2>/dev/null && pwd -P) || git_dir=""
		common_dir=$(cd "$common_dir" 2>/dev/null && pwd -P) || common_dir=""
		if [[ -n "$git_dir" && -n "$common_dir" && "$git_dir" != "$common_dir" ]]; then
			if [[ -n "$current_worktree" && -n "$resolved_path" && "$resolved_path" == "$current_worktree" ]] ||
				[[ -n "$resolved_path" && "$current_physical_dir" == "$resolved_path"/* ]]; then
				skipped_current_paths+=("$path")
				continue
			fi
			stale_paths+=("$path")
		fi
	done < <(jq -r '.initialized_repos[].path // empty' "$repos_json" 2>/dev/null)

	if [[ ${#stale_paths[@]} -gt 0 ]]; then
		local temp_file="${repos_json}.tmp"
		local paths_json
		paths_json=$(printf '%s\n' "${stale_paths[@]}" | jq -R . | jq -s .)
		jq --argjson stale "$paths_json" \
			'.initialized_repos |= map(select(.path as $p | ($stale | index($p)) | not))' \
			"$repos_json" >"$temp_file" && mv "$temp_file" "$repos_json"
		print_info "Removed ${#stale_paths[@]} worktree entry/entries from repos.json (t2250):"
		local p
		for p in "${stale_paths[@]}"; do
			print_info "  - $p"
		done
	fi

	if [[ ${#skipped_current_paths[@]} -gt 0 ]]; then
		print_warning "Skipped ${#skipped_current_paths[@]} active current worktree entry/entries in repos.json (t2250):"
		local skipped_path
		for skipped_path in "${skipped_current_paths[@]}"; do
			print_warning "  - $skipped_path"
		done
		print_warning "Run setup.sh from the canonical worktree later to finish the one-shot cleanup."
		return 0
	fi

	mkdir -p "$(dirname "$flag_file")"
	date -u +"%Y-%m-%dT%H:%M:%SZ" >"$flag_file"
	return 0
}

cleanup_stale_health_issue_caches() {
	local flag_file="${HOME}/.aidevops/logs/.migrated-health-issue-caches-t1929"
	[[ -f "$flag_file" ]] && return 0

	local cache_dir="${HOME}/.aidevops/logs"
	[[ -d "$cache_dir" ]] || return 0

	local cleaned=0

	# 1. Remove contributor cache files (the duplicates).
	#    The correct files are health-issue-{user}-supervisor-{slug}.
	local contributor_cache
	for contributor_cache in "${cache_dir}"/health-issue-*-contributor-*; do
		[[ -f "$contributor_cache" ]] || continue
		local stale_num
		stale_num=$(cat "$contributor_cache" 2>/dev/null || echo "")
		# Extract slug from filename: health-issue-{user}-contributor-{slug}
		# Best-effort close via gh if available and authenticated
		if [[ -n "$stale_num" ]] && command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
			local fname
			fname=$(basename "$contributor_cache")
			local slug_safe="${fname##*-contributor-}"
			local supervisor_cache="${cache_dir}/health-issue-${fname%-contributor-*}-supervisor-${slug_safe}"
			# Only close if there IS a supervisor counterpart (confirms it's a duplicate)
			if [[ -f "$supervisor_cache" ]]; then
				# Resolve actual slug from repos.json — the slug-safe format
				# (hyphens replacing /) is lossy for owners/repos containing hyphens.
				local repos_json="${HOME}/.config/aidevops/repos.json"
				local repo_slug=""
				if [[ -f "$repos_json" ]]; then
					repo_slug=$(jq -r --arg ss "$slug_safe" \
						'.initialized_repos[] | select((.slug // "") | gsub("/"; "-") == $ss) | .slug' \
						"$repos_json" 2>/dev/null | head -1)
				fi
				if [[ -n "$repo_slug" ]]; then
					# Remove "persistent" label first — a GitHub Actions workflow
					# auto-reopens issues with this label (health issues get it on creation).
					gh issue edit "$stale_num" --repo "$repo_slug" \
						--remove-label persistent 2>/dev/null || true
					gh issue close "$stale_num" --repo "$repo_slug" \
						--comment "Closing duplicate contributor health issue (t1929 migration)." 2>/dev/null || true
				fi
			fi
		fi
		rm -f "$contributor_cache"
		cleaned=$((cleaned + 1))
	done

	# 2. Remove legacy cache files (no role prefix, pre-role-naming).
	#    Pattern: health-issue-{user}-{slug} where {slug} has no "supervisor" or "contributor".
	local legacy_cache
	for legacy_cache in "${cache_dir}"/health-issue-*; do
		[[ -f "$legacy_cache" ]] || continue
		local fname
		fname=$(basename "$legacy_cache")
		# Skip files that already have a role prefix (they're the correct format)
		[[ "$fname" == *-supervisor-* || "$fname" == *-contributor-* ]] && continue
		rm -f "$legacy_cache"
		cleaned=$((cleaned + 1))
	done

	# Write flag file
	mkdir -p "$(dirname "$flag_file")"
	date -u +"%Y-%m-%dT%H:%M:%SZ" >"$flag_file"

	if [[ "$cleaned" -gt 0 ]]; then
		print_info "Cleaned up $cleaned stale health issue cache file(s) (t1929)"
	fi
	return 0
}

# Migrate legacy .agent symlink/directory to .agents in a single repo.
# Args: $1 = repo_path
# Prints: info messages for each migration action
# Returns: 0 on success; sets _migrate_count to number of items migrated
_migrate_repo_agent_symlinks() {
	local repo_path="$1"
	_migrate_count=0

	# Migrate legacy .agent symlink/directory to .agents real directory
	if [[ -L "$repo_path/.agent" ]]; then
		rm -f "$repo_path/.agent"
		if [[ ! -d "$repo_path/.agents" ]]; then
			mkdir -p "$repo_path/.agents"
		fi
		print_info "  Removed legacy .agent symlink in $(basename "$repo_path")"
		((++_migrate_count))
	elif [[ -d "$repo_path/.agent" && ! -L "$repo_path/.agent" ]]; then
		# Real directory (not symlink) - rename it
		# Handle mixed state: .agents may be a legacy symlink blocking the rename
		if [[ -L "$repo_path/.agents" ]]; then
			rm -f "$repo_path/.agents"
			print_info "  Removed legacy .agents symlink in $(basename "$repo_path")"
			((++_migrate_count))
		fi
		if [[ ! -e "$repo_path/.agents" ]]; then
			mv "$repo_path/.agent" "$repo_path/.agents"
			print_info "  Renamed directory: $repo_path/.agent -> .agents"
			((++_migrate_count))
		fi
	fi

	# Migrate legacy .agents symlink to real directory
	if [[ -L "$repo_path/.agents" ]]; then
		rm -f "$repo_path/.agents"
		mkdir -p "$repo_path/.agents"
		print_info "  Replaced .agents symlink with real directory in $(basename "$repo_path")"
		((++_migrate_count))
	fi

	return 0
}

# Update .gitignore in a repo: remove legacy entries, add runtime artifact ignores.
# Args: $1 = repo_path
# SKIP in non-interactive mode to avoid leaving uncommitted changes (issue #2570 bug 1).
_migrate_repo_gitignore() {
	local repo_path="$1"
	local gitignore="$repo_path/.gitignore"

	if [[ "${NON_INTERACTIVE:-false}" == "true" ]]; then
		if [[ -f "$gitignore" ]]; then
			local needs_gitignore_update=false
			local agents_loop_state_pattern="^\.agents/""loop-state/"
			if grep -q -e "^\.agents$" -e "^\.agent$" -e "^\.agent/loop-state/" "$gitignore" 2>/dev/null ||
				! grep -q "$agents_loop_state_pattern" "$gitignore" 2>/dev/null; then
				needs_gitignore_update=true
			fi
			if [[ "$needs_gitignore_update" == "true" ]]; then
				print_warning "  $(basename "$repo_path")/.gitignore needs migration (skipped in non-interactive mode)"
				print_info "  Run 'aidevops init' in $(basename "$repo_path") or 'setup.sh -i' to apply"
			fi
		fi
		return 0
	fi

	if [[ ! -f "$gitignore" ]]; then
		return 0
	fi

	# Remove legacy bare ".agents" and ".agent" entries (added by older versions)
	# .agents/ is now a real committed directory, not a symlink to ignore
	if grep -q "^\.agents$" "$gitignore" 2>/dev/null; then
		sed -i '' '/^\.agents$/d' "$gitignore" 2>/dev/null ||
			sed -i '/^\.agents$/d' "$gitignore" 2>/dev/null || true
		print_info "  Removed legacy bare .agents from .gitignore in $(basename "$repo_path")"
	fi
	if grep -q "^\.agent$" "$gitignore" 2>/dev/null; then
		sed -i '' '/^\.agent$/d' "$gitignore" 2>/dev/null ||
			sed -i '/^\.agent$/d' "$gitignore" 2>/dev/null || true
	fi

	# Migrate .agent/loop-state/ -> .agents/loop-state/
	if grep -q "^\.agent/loop-state/" "$gitignore" 2>/dev/null; then
		sed -i '' 's|^\.agent/loop-state/|.agents/loop-state/|' "$gitignore" 2>/dev/null ||
			sed -i 's|^\.agent/loop-state/|.agents/loop-state/|' "$gitignore" 2>/dev/null || true
	fi

	# Add runtime artifact ignores if not present
	if ! grep -q "^\.agents/loop-state/" "$gitignore" 2>/dev/null; then
		# Ensure trailing newline before appending (prevents malformed entries like *.zip.agents/loop-state/)
		[[ -s "$gitignore" && $(tail -c1 "$gitignore" | wc -l) -eq 0 ]] && printf '\n' >>"$gitignore"
		{
			echo ""
			echo "# aidevops runtime artifacts"
			echo ".agents/loop-state/"
			echo ".agents/tmp/"
			echo ".agents/memory/"
		} >>"$gitignore"
		print_info "  Added .agents/ runtime artifact ignores in $(basename "$repo_path")"
	fi

	return 0
}

# Scan ~/Git/ for .agent symlinks or directories not covered by repos.json.
# Sets _migrate_count to number of items migrated.
_migrate_git_dir_agent_paths() {
	_migrate_count=0

	if [[ ! -d "$HOME/Git" ]]; then
		return 0
	fi

	while IFS= read -r -d '' agent_path; do
		local repo_dir
		repo_dir=$(dirname "$agent_path")

		if [[ -L "$agent_path" ]]; then
			# Symlink: remove and create real directory
			rm -f "$agent_path"
			if [[ ! -d "$repo_dir/.agents" ]]; then
				mkdir -p "$repo_dir/.agents"
			fi
			print_info "  Removed legacy .agent symlink: $agent_path"
			((++_migrate_count))
		elif [[ -d "$agent_path" ]]; then
			# Directory: rename to .agents if .agents doesn't exist
			if [[ ! -e "$repo_dir/.agents" ]]; then
				mv "$agent_path" "$repo_dir/.agents"
				print_info "  Renamed directory: $agent_path -> .agents"
				((++_migrate_count))
			fi
		fi
	done < <(find "$HOME/Git" -maxdepth 3 -name ".agent" \( -type l -o -type d \) -print0 2>/dev/null)

	return 0
}

# Update AI assistant config files and session greeting cache that reference .agent/.
# Sets _migrate_count to number of files updated.
_migrate_ai_config_agent_refs() {
	_migrate_count=0

	local ai_config_files=(
		"$HOME/.config/opencode/agent/AGENTS.md"
		"$HOME/.config/Claude/AGENTS.md"
		"$HOME/.claude/commands/AGENTS.md"
		"$HOME/.opencode/AGENTS.md"
	)

	for config_file in "${ai_config_files[@]}"; do
		if [[ -f "$config_file" ]]; then
			if grep -q '\.agent/' "$config_file" 2>/dev/null; then
				sed -i '' 's|\.agent/|.agents/|g' "$config_file" 2>/dev/null ||
					sed -i 's|\.agent/|.agents/|g' "$config_file" 2>/dev/null || true
				print_info "  Updated references in $config_file"
				((++_migrate_count))
			fi
		fi
	done

	# Update session greeting cache if it references .agent/
	local greeting_cache="$HOME/.aidevops/cache/session-greeting.txt"
	if [[ -f "$greeting_cache" ]]; then
		if grep -q '\.agent/' "$greeting_cache" 2>/dev/null; then
			sed -i '' 's|\.agent/|.agents/|g' "$greeting_cache" 2>/dev/null ||
				sed -i 's|\.agent/|.agents/|g' "$greeting_cache" 2>/dev/null || true
			((++_migrate_count))
		fi
	fi

	return 0
}

# Migrate .agent -> .agents in user projects and local config
# v2.104.0: Industry converging on .agents/ folder convention (aligning with AGENTS.md)
# This migrates:
# 1. .agent symlinks in user projects -> .agents
# 2. .agent/loop-state/ -> .agents/loop-state/ in user projects
# 3. .gitignore entries in user projects
# 4. References in user's AI assistant configs
# 5. References in ~/.aidevops/ config files
#
# Guarded by a sentinel file: on a converged system the function does
# a repos.json scan and a find(1) scan of ~/Git, both of which cost
# several seconds per run (t3221).
migrate_agent_to_agents_folder() {
	local _sentinel="${HOME}/.aidevops/.migrations/agent-to-agents-done"
	if [[ -f "$_sentinel" ]]; then
		return 0
	fi

	print_info "Checking for .agent -> .agents migration..."

	local migrated=0

	# 1. Migrate .agent symlinks and .gitignore in registered repos
	local repos_file="$HOME/.config/aidevops/repos.json"
	if [[ -f "$repos_file" ]] && command -v jq &>/dev/null; then
		while IFS= read -r repo_path; do
			[[ -z "$repo_path" ]] && continue
			[[ ! -d "$repo_path" ]] && continue

			_migrate_repo_agent_symlinks "$repo_path"
			migrated=$((migrated + _migrate_count))

			_migrate_repo_gitignore "$repo_path"
		done < <(jq -r '.initialized_repos[].path' "$repos_file" 2>/dev/null)
	fi

	# 2. Scan ~/Git/ for .agent paths not in repos.json
	_migrate_git_dir_agent_paths
	migrated=$((migrated + _migrate_count))

	# 3. Update AI assistant config files and greeting cache
	_migrate_ai_config_agent_refs
	migrated=$((migrated + _migrate_count))

	if [[ $migrated -gt 0 ]]; then
		print_success "Migrated $migrated .agent -> .agents reference(s)"
	else
		print_info "No .agent -> .agents migration needed"
	fi

	# Write sentinel so subsequent setup runs skip the repos+find scans (t3221)
	mkdir -p "$(dirname "$_sentinel")"
	date -u +%Y-%m-%dT%H:%M:%SZ >"$_sentinel"
	return 0
}

# Remove deprecated MCP and tool entries from a config file.
# Args: $1 = path to tmp config file to modify in-place
# Sets _cleanup_count to number of entries removed.
_remove_deprecated_mcp_entries() {
	local tmp_config="$1"
	_cleanup_count=0

	# MCPs replaced by curl subagents in v2.79.0
	local deprecated_mcps=(
		"auggie-mcp"
		"augment-context-engine"
		"hetzner-webapp"
		"hetzner-brandlight"
		"hetzner-marcusquinn"
		"hetzner-storagebox"
		"ahrefs"
		"serper"
		"dataforseo"
		"hostinger-api"
		"shadcn"
		"repomix"
		"gh_grep"
	)

	# Tool rules to remove (for MCPs that no longer exist)
	local auggie_tool="auggie-mcp_*"
	local augment_tool="augment-context-engine_*"
	local gh_grep_tool="gh_grep_*"
	local deprecated_tools=(
		"$auggie_tool"
		"$augment_tool"
		"hetzner-*"
		"hostinger-api_*"
		"ahrefs_*"
		"dataforseo_*"
		"serper_*"
		"shadcn_*"
		"repomix_*"
		"$gh_grep_tool"
	)

	for mcp in "${deprecated_mcps[@]}"; do
		if jq -e --arg mcp "$mcp" '.mcp[$mcp]' "$tmp_config" >/dev/null 2>&1; then
			jq --arg mcp "$mcp" 'del(.mcp[$mcp])' "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
			((++_cleanup_count))
		fi
	done

	for tool in "${deprecated_tools[@]}"; do
		if jq -e ".tools[\"$tool\"]" "$tmp_config" >/dev/null 2>&1; then
			jq "del(.tools[\"$tool\"])" "$tmp_config" >"${tmp_config}.new" &&
				mv "${tmp_config}.new" "$tmp_config" &&
				((++_cleanup_count))
		fi
	done

	# Also remove deprecated tool refs from agents
	local ahrefs_tool="ahrefs_*"
	if jq -e --arg ahrefs_tool "$ahrefs_tool" '(.agent.SEO.tools // {}) | keys[]? | select(. == "dataforseo_*" or . == "serper_*" or . == $ahrefs_tool)' \
		"$tmp_config" >/dev/null 2>&1; then
		jq --arg ahrefs_tool "$ahrefs_tool" 'del(.agent.SEO.tools["dataforseo_*"]) | del(.agent.SEO.tools["serper_*"]) | del(.agent.SEO.tools[$ahrefs_tool])' \
			"$tmp_config" >"${tmp_config}.new" &&
			mv "${tmp_config}.new" "$tmp_config" &&
			((++_cleanup_count))
	fi

	if jq -e --arg auggie_tool "$auggie_tool" --arg augment_tool "$augment_tool" '(.agent // {}) | to_entries[]? | (.value.tools // {}) | keys[]? | select(. == $auggie_tool or . == $augment_tool)' \
		"$tmp_config" >/dev/null 2>&1; then
		jq --arg auggie_tool "$auggie_tool" --arg augment_tool "$augment_tool" '(.agent // {}) as $agents | reduce ($agents | keys[]) as $name (. ; del(.agent[$name].tools[$auggie_tool]) | del(.agent[$name].tools[$augment_tool]))' \
			"$tmp_config" >"${tmp_config}.new" &&
			mv "${tmp_config}.new" "$tmp_config" &&
			((++_cleanup_count))
	fi

	return 0
}

# Migrate npx/pipx/bunx MCP commands to full binary paths (faster startup).
# Args: $1 = path to tmp config file to modify in-place
# Sets _cleanup_count to number of entries migrated.
_migrate_mcp_npx_to_binary() {
	local tmp_config="$1"
	_cleanup_count=0

	# Early return if config has no .mcp key — nothing to migrate (GH#14220)
	if ! jq -e '.mcp' "$tmp_config" >/dev/null 2>&1; then
		return 0
	fi

	# Parallel arrays avoid bash associative array issues with @ in package names
	local -a mcp_pkgs=(
		"chrome-devtools-mcp"
		"mcp-server-gsc"
		"playwriter"
		"@steipete/macos-automator-mcp"
		"@steipete/claude-code-mcp"
		"analytics-mcp"
	)
	local -a mcp_bins=(
		"chrome-devtools-mcp"
		"mcp-server-gsc"
		"playwriter"
		"macos-automator-mcp"
		"claude-code-mcp"
		"analytics-mcp"
	)

	local i
	for i in "${!mcp_pkgs[@]}"; do
		local pkg="${mcp_pkgs[$i]}"
		local bin_name="${mcp_bins[$i]}"
		# Find MCP key using npx/bunx/pipx for this package (single query)
		# Use (.mcp // {}) for null-safety — .mcp may not exist in minimal configs (GH#14220)
		local mcp_key
		mcp_key=$(jq -r --arg pkg "$pkg" '(.mcp // {}) | to_entries[]? | select(.value.command != null) | select(.value.command | join(" ") | test("npx.*" + $pkg + "|bunx.*" + $pkg + "|pipx.*run.*" + $pkg)) | .key' "$tmp_config" 2>/dev/null | head -1)

		if [[ -n "$mcp_key" ]]; then
			# Resolve full path for the binary
			local full_path
			full_path=$(resolve_mcp_binary_path "$bin_name")
			if [[ -n "$full_path" ]]; then
				jq --arg k "$mcp_key" --arg p "$full_path" '.mcp[$k].command = [$p]' "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
				((++_cleanup_count))
			fi
		fi
	done

	# Migrate outscraper from bash -c wrapper to full binary path
	if jq -e '.mcp.outscraper.command | join(" ") | test("bash.*outscraper")' "$tmp_config" >/dev/null 2>&1; then
		local outscraper_path
		outscraper_path=$(resolve_mcp_binary_path "outscraper-mcp-server")
		if [[ -n "$outscraper_path" ]]; then
			# Source the API key and set it in environment
			local outscraper_key=""
			if [[ -f "$HOME/.config/aidevops/credentials.sh" ]]; then
				# shellcheck source=/dev/null
				outscraper_key=$(source "$HOME/.config/aidevops/credentials.sh" && echo "${OUTSCRAPER_API_KEY:-}")
			fi
			jq --arg p "$outscraper_path" --arg key "$outscraper_key" '.mcp.outscraper.command = [$p] | .mcp.outscraper.environment = {"OUTSCRAPER_API_KEY": $key}' "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
			((++_cleanup_count))
		fi
	fi

	return 0
}

# Remove deprecated MCP entries from opencode.json
# These MCPs have been replaced by curl-based subagents (zero context cost)
#
# The one-time cleanup (remove deprecated entries + migrate npx→binary) is
# guarded by a versioned sentinel (t3221). Bump the sentinel version when new
# deprecated MCPs are added to _remove_deprecated_mcp_entries.
# The recurring update_mcp_paths_in_opencode call is NOT guarded — it resolves
# stale binary paths on every run (paths can change after package upgrades).
cleanup_deprecated_mcps() {
	local opencode_config
	opencode_config=$(find_opencode_config) || return 0

	if [[ ! -f "$opencode_config" ]]; then
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		return 0
	fi

	# One-time cleanup: remove deprecated MCPs and migrate npx→binary paths.
	# Sentinel version must be bumped whenever new deprecated MCPs are added.
	local _sentinel="${HOME}/.aidevops/.migrations/cleanup-deprecated-mcps-v2"
	if [[ ! -f "$_sentinel" ]]; then
		local cleaned=0
		local tmp_config
		tmp_config=$(mktemp)
		trap 'rm -f "${tmp_config:-}"' RETURN

		cp "$opencode_config" "$tmp_config"

		# Remove deprecated MCP and tool entries
		_remove_deprecated_mcp_entries "$tmp_config"
		cleaned=$((cleaned + _cleanup_count))

		# Migrate npx/pipx commands to full binary paths (faster startup, PATH-independent)
		_migrate_mcp_npx_to_binary "$tmp_config"
		cleaned=$((cleaned + _cleanup_count))

		if [[ $cleaned -gt 0 ]]; then
			create_backup_with_rotation "$opencode_config" "opencode"
			mv "$tmp_config" "$opencode_config"
			print_info "Updated $cleaned MCP entry/entries in opencode.json (using full binary paths)"
		else
			rm -f "$tmp_config"
		fi

		# Write sentinel
		mkdir -p "$(dirname "$_sentinel")"
		date -u +%Y-%m-%dT%H:%M:%SZ >"$_sentinel"
	fi

	# Always resolve bare binary names to full paths (fixes PATH-dependent startup)
	update_mcp_paths_in_opencode

	return 0
}

# Disable MCPs globally that should only be enabled on-demand via subagents
# This reduces session startup context by disabling rarely-used MCPs
# - playwriter: ~3K tokens - enable via @playwriter subagent
# - google-analytics-mcp: ~800 tokens - enable via @google-analytics subagent
# - context7: ~800 tokens - enable via @context7 subagent (for library docs lookup)
disable_ondemand_mcps() {
	local opencode_config
	opencode_config=$(find_opencode_config) || return 0

	if [[ ! -f "$opencode_config" ]]; then
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		return 0
	fi

	# All MCPs disabled by default — activate on-demand via subagents.
	# This reduces idle process/connection overhead to zero.
	# Note: use exact MCP key names from opencode.json
	local -a ondemand_mcps=(
		"cloudflare-api"
		"context7"
		"google-analytics-mcp"
		"grep_app"
		"playwright"
		"playwriter"
		"shadcn"
		"macos-automator"
		"websearch"
	)

	local disabled=0
	local changed=0
	local tmp_config
	tmp_config=$(mktemp)
	trap 'rm -f "${tmp_config:-}"' RETURN

	cp "$opencode_config" "$tmp_config"

	for mcp in "${ondemand_mcps[@]}"; do
		# Only disable MCPs that exist in the config
		# Don't add fake entries - they break OpenCode's config validation
		if jq -e ".mcp[\"$mcp\"]" "$tmp_config" >/dev/null 2>&1; then
			local current_enabled
			current_enabled=$(jq -r ".mcp[\"$mcp\"].enabled // \"true\"" "$tmp_config")
			if [[ "$current_enabled" != "false" ]]; then
				jq ".mcp[\"$mcp\"].enabled = false" "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
				((++disabled))
			fi
		fi
	done

	# Remove invalid MCP entries added by v2.100.16 bug
	# These have type "stdio" (invalid - only "local" or "remote" are valid)
	# or command ["echo", "disabled"] which breaks OpenCode
	local invalid_mcps=("grep_app" "websearch" "context7")
	for mcp in "${invalid_mcps[@]}"; do
		# Check for invalid type "stdio" or dummy command
		if jq -e ".mcp[\"$mcp\"].type == \"stdio\" or .mcp[\"$mcp\"].command[0] == \"echo\"" "$tmp_config" >/dev/null 2>&1; then
			jq "del(.mcp[\"$mcp\"])" "$tmp_config" >"${tmp_config}.new" && mv "${tmp_config}.new" "$tmp_config"
			print_info "Removed invalid MCP entry: $mcp"
			changed=1
		fi
	done

	# Note: the v2.100.16-17 context7 re-enable migration was removed in v3.1.312.
	# All MCPs are now disabled by default — subagents enable them on-demand.

	if [[ $disabled -gt 0 || $changed -gt 0 ]]; then
		create_backup_with_rotation "$opencode_config" "opencode"
		mv "$tmp_config" "$opencode_config"
		if [[ $disabled -gt 0 ]]; then
			print_info "Disabled $disabled MCP(s) globally (use subagents to enable on-demand)"
		fi
	else
		rm -f "$tmp_config"
	fi

	return 0
}

# Run bounded opencode --version probe to detect config schema errors (GH#22079).
# Returns 0 when config looks valid (or opencode is unavailable / probe timed out),
# 1 when opencode explicitly reports "Configuration is invalid".
# Uses AIDEVOPS_OPENCODE_VERSION_TIMEOUT (default 5s) so a hung Node.js process
# cannot stall the non-interactive deploy path indefinitely.
_validate_opencode_config_schema() {
	command -v opencode &>/dev/null || return 0
	local validation_output
	local _oc_timeout
	local _oc_rc
	_oc_timeout="${AIDEVOPS_OPENCODE_VERSION_TIMEOUT:-5}"
	_oc_rc=0
	# Prefer the shared helper sourced from _services.sh (always available when
	# called from setup.sh); fall back to system timeout; last resort: unbounded.
	if declare -F _setup_opencode_timeout_cmd >/dev/null 2>&1; then
		validation_output=$(_setup_opencode_timeout_cmd "$_oc_timeout" opencode --version 2>&1) || _oc_rc=$?
	elif command -v timeout >/dev/null 2>&1; then
		validation_output=$(timeout "$_oc_timeout" opencode --version 2>&1) || _oc_rc=$?
	else
		validation_output=$(opencode --version 2>&1) || _oc_rc=$?
	fi
	# Exit 124 = timed out — not a config-invalid signal.
	if [[ "$_oc_rc" -ne 0 && "$_oc_rc" -ne 124 ]] && [[ "$validation_output" == *"Configuration is invalid"* ]]; then
		return 1
	fi
	return 0
}

# Validate and repair OpenCode config schema
# Fixes common issues from manual editing or AI-generated configs:
# - MCP entries missing "type": "local" field
# - tools entries as objects {} instead of booleans
# If invalid, backs up and regenerates using the generator script
validate_opencode_config() {
	local opencode_config
	opencode_config=$(find_opencode_config) || return 0

	if [[ ! -f "$opencode_config" ]]; then
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		return 0
	fi

	local needs_repair=false
	local issues=""

	# Check 0: Remove deprecated top-level keys that OpenCode no longer recognizes
	# "compaction" was removed in OpenCode v1.1.x - causes "Unrecognized key" error
	local deprecated_keys=("compaction")
	for key in "${deprecated_keys[@]}"; do
		if jq -e ".[\"$key\"]" "$opencode_config" >/dev/null 2>&1; then
			local tmp_fix
			tmp_fix=$(mktemp)
			trap 'rm -f "${tmp_fix:-}"' RETURN
			if jq "del(.[\"$key\"])" "$opencode_config" >"$tmp_fix" 2>/dev/null; then
				create_backup_with_rotation "$opencode_config" "opencode"
				mv "$tmp_fix" "$opencode_config"
				print_info "Removed deprecated '$key' key from OpenCode config"
			else
				rm -f "$tmp_fix"
			fi
		fi
	done

	# Check 1: MCP entries must have "type" field (usually "local")
	# Invalid: {"mcp": {"foo": {"command": "..."}}}
	# Valid:   {"mcp": {"foo": {"type": "local", "command": "..."}}}
	local mcps_without_type
	mcps_without_type=$(jq -r '.mcp // {} | to_entries[] | select(.value.type == null and .value.command != null) | .key' "$opencode_config" 2>/dev/null | head -5)
	if [[ -n "$mcps_without_type" ]]; then
		needs_repair=true
		issues="${issues}\n  - MCP entries missing 'type' field: $(echo "$mcps_without_type" | tr '\n' ', ' | sed 's/,$//')"
	fi

	# Check 2: tools entries must be booleans, not objects
	# Invalid: {"tools": {"example_tool": {}}}
	# Valid:   {"tools": {"example_tool": true}}
	local tools_as_objects
	tools_as_objects=$(jq -r '.tools // {} | to_entries[] | select(.value | type == "object") | .key' "$opencode_config" 2>/dev/null | head -5)
	if [[ -n "$tools_as_objects" ]]; then
		needs_repair=true
		issues="${issues}\n  - tools entries as objects instead of booleans: $(echo "$tools_as_objects" | tr '\n' ', ' | sed 's/,$//')"
	fi

	# Check 3: bounded opencode --version probe to catch other schema issues (GH#22079).
	if ! _validate_opencode_config_schema; then
		needs_repair=true
		issues="${issues}\n  - OpenCode reports invalid configuration"
	fi

	if [[ "$needs_repair" == "true" ]]; then
		print_warning "OpenCode config has schema issues:$issues"

		# Backup the invalid config
		create_backup_with_rotation "$opencode_config" "opencode"
		print_info "Backed up invalid config"

		# Remove the invalid config so generator creates fresh one
		rm -f "$opencode_config"

		# Regenerate using the generator script
		local generator_script="$HOME/.aidevops/agents/scripts/generate-opencode-agents.sh"
		if [[ -x "$generator_script" ]]; then
			print_info "Regenerating OpenCode config with correct schema..."
			if "$generator_script" >/dev/null 2>&1; then
				print_success "OpenCode config regenerated successfully"
			else
				print_warning "Config regeneration failed - run manually: $generator_script"
			fi
		else
			print_warning "Generator script not found - run setup.sh again after agents are deployed"
		fi
	fi

	return 0
}

# Migrate mcp-env.sh to credentials.sh (v2.105.0)
# Renames the credential file and creates backward-compatible symlink
migrate_mcp_env_to_credentials() {
	local config_dir="$HOME/.config/aidevops"
	local old_file="$config_dir/mcp-env.sh"
	local new_file="$config_dir/credentials.sh"
	local migrated=0

	# Migrate root-level mcp-env.sh -> credentials.sh
	if [[ -f "$old_file" && ! -L "$old_file" ]]; then
		if [[ ! -f "$new_file" ]]; then
			mv "$old_file" "$new_file"
			chmod 600 "$new_file"
			((++migrated))
			print_info "Renamed mcp-env.sh to credentials.sh"
		fi
		# Create backward-compatible symlink
		if [[ ! -L "$old_file" ]]; then
			ln -sf "credentials.sh" "$old_file"
			print_info "Created symlink mcp-env.sh -> credentials.sh"
		fi
	fi

	# Migrate tenant-level mcp-env.sh -> credentials.sh
	local tenants_dir="$config_dir/tenants"
	if [[ -d "$tenants_dir" ]]; then
		for tenant_dir in "$tenants_dir"/*/; do
			[[ -d "$tenant_dir" ]] || continue
			local tenant_old="$tenant_dir/mcp-env.sh"
			local tenant_new="$tenant_dir/credentials.sh"
			if [[ -f "$tenant_old" && ! -L "$tenant_old" ]]; then
				if [[ ! -f "$tenant_new" ]]; then
					mv "$tenant_old" "$tenant_new"
					chmod 600 "$tenant_new"
					((++migrated))
				fi
				if [[ ! -L "$tenant_old" ]]; then
					ln -sf "credentials.sh" "$tenant_old"
				fi
			fi
		done
	fi

	# Update shell rc files that source the old path
	for rc_file in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
		if [[ -f "$rc_file" ]] && grep -q 'source.*mcp-env\.sh' "$rc_file" 2>/dev/null; then
			# shellcheck disable=SC2016
			sed -i '' 's|source.*\.config/aidevops/mcp-env\.sh|source "$HOME/.config/aidevops/credentials.sh"|g' "$rc_file" 2>/dev/null ||
				sed -i 's|source.*\.config/aidevops/mcp-env\.sh|source "$HOME/.config/aidevops/credentials.sh"|g' "$rc_file" 2>/dev/null || true
			((++migrated))
			print_info "Updated $rc_file to source credentials.sh"
		fi
	done

	if [[ $migrated -gt 0 ]]; then
		print_success "Migrated $migrated mcp-env.sh -> credentials.sh reference(s)"
	fi

	return 0
}

# Migrate old config-backups to new per-type backup structure
# This runs once to clean up the legacy backup directory
migrate_old_backups() {
	local old_backup_dir="$HOME/.aidevops/config-backups"

	# Skip if old directory doesn't exist
	if [[ ! -d "$old_backup_dir" ]]; then
		return 0
	fi

	# Count old backups
	local old_count
	old_count=$(find "$old_backup_dir" -maxdepth 1 -type d -name "20*" 2>/dev/null | wc -l | tr -d ' ')

	if [[ $old_count -eq 0 ]]; then
		# Empty directory, just remove it
		rm -rf "$old_backup_dir"
		return 0
	fi

	print_info "Migrating $old_count old backups to new structure..."

	# Create new backup directories
	mkdir -p "$HOME/.aidevops/agents-backups"
	mkdir -p "$HOME/.aidevops/opencode-backups"

	# Move the most recent backups (up to BACKUP_KEEP_COUNT) to new locations
	# Old backups contained mixed content, so we'll just keep the newest ones as agents backups
	local migrated=0
	for backup in $(find "$old_backup_dir" -maxdepth 1 -type d -name "20*" 2>/dev/null | sort -r | head -n "$BACKUP_KEEP_COUNT"); do
		local backup_name
		backup_name=$(basename "$backup")

		# Check if it contains agents folder (most common)
		if [[ -d "$backup/agents" ]]; then
			mv "$backup" "$HOME/.aidevops/agents-backups/$backup_name"
			((++migrated))
		# Check if it contains opencode.json
		elif [[ -f "$backup/opencode.json" ]]; then
			mv "$backup" "$HOME/.aidevops/opencode-backups/$backup_name"
			((++migrated))
		fi
	done

	# Remove remaining old backups and the old directory
	rm -rf "$old_backup_dir"

	if [[ $migrated -gt 0 ]]; then
		print_success "Migrated $migrated recent backups, removed $((old_count - migrated)) old backups"
	else
		print_info "Cleaned up $old_count old backups"
	fi

	return 0
}

# Migrate loop state from .claude/ to .agents/loop-state/ in user projects
# Also migrates from legacy .agents/loop-state/ to .agents/loop-state/
# The migration is non-destructive: moves files, doesn't delete originals until confirmed
#
# Guarded by a sentinel file: on a converged system the function does a
# find(1) scan of ~/Git which costs several seconds per run (t3221).
migrate_loop_state_directories() {
	local _sentinel="${HOME}/.aidevops/.migrations/loop-state-dirs-migrated"
	if [[ -f "$_sentinel" ]]; then
		return 0
	fi

	print_info "Checking for legacy loop state directories..."

	local migrated=0
	local git_dirs=()

	# Find Git repositories in common locations
	# Check ~/Git/ and current directory's parent
	for search_dir in "$HOME/Git" "$(dirname "$(pwd)")"; do
		if [[ -d "$search_dir" ]]; then
			while IFS= read -r -d '' git_dir; do
				git_dirs+=("$(dirname "$git_dir")")
			done < <(find "$search_dir" -maxdepth 3 -type d -name ".git" -print0 2>/dev/null)
		fi
	done

	for repo_dir in "${git_dirs[@]}"; do
		local old_state_dir="$repo_dir/.claude"
		local legacy_state_dir="$repo_dir/.agent/loop-state"
		local new_state_dir="$repo_dir/.agents/loop-state"

		# Migrate from .claude/ (oldest legacy path)
		if [[ -d "$old_state_dir" ]]; then
			local has_loop_state=false
			if [[ -f "$old_state_dir/ralph-loop.local.state" ]] ||
				[[ -f "$old_state_dir/loop-state.json" ]] ||
				[[ -d "$old_state_dir/receipts" ]]; then
				has_loop_state=true
			fi

			if [[ "$has_loop_state" == "true" ]]; then
				print_info "Found legacy loop state in: $repo_dir/.claude/"
				mkdir -p "$new_state_dir"

				for file in ralph-loop.local.state loop-state.json re-anchor.md guardrails.md; do
					if [[ -f "$old_state_dir/$file" ]]; then
						mv "$old_state_dir/$file" "$new_state_dir/"
						print_info "  Moved $file"
					fi
				done

				if [[ -d "$old_state_dir/receipts" ]]; then
					mv "$old_state_dir/receipts" "$new_state_dir/"
					print_info "  Moved receipts/"
				fi

				local remaining
				remaining=$(find "$old_state_dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' ')

				if [[ "$remaining" -eq 0 ]]; then
					rmdir "$old_state_dir" 2>/dev/null && print_info "  Removed empty .claude/"
				else
					print_warning "  .claude/ has other files, not removing"
				fi

				((++migrated))
			fi
		fi

		# Migrate from .agents/loop-state/ (v2.51.0-v2.103.0 path) to .agents/loop-state/
		if [[ -d "$legacy_state_dir" ]] && [[ "$legacy_state_dir" != "$new_state_dir" ]]; then
			print_info "Found legacy loop state in: $repo_dir/.agent/loop-state/"
			mkdir -p "$new_state_dir"

			# Move all files from old to new
			if [[ -n "$(ls -A "$legacy_state_dir" 2>/dev/null)" ]]; then
				cp -R "$legacy_state_dir"/* "$new_state_dir/" 2>/dev/null || true
				rm -rf "$legacy_state_dir"
				print_info "  Migrated .agents/loop-state/ -> .agents/loop-state/"
				((++migrated))
			fi
		fi

		# Update .gitignore if needed
		local gitignore="$repo_dir/.gitignore"
		if [[ -f "$gitignore" ]]; then
			if ! grep -q "^\.agents/loop-state/" "$gitignore" 2>/dev/null; then
				# Ensure trailing newline before appending (prevents malformed entries)
				[[ -s "$gitignore" && $(tail -c1 "$gitignore" | wc -l) -eq 0 ]] && printf '\n' >>"$gitignore"
				echo ".agents/loop-state/" >>"$gitignore"
				print_info "  Added .agents/loop-state/ to .gitignore"
			fi
		fi
	done

	if [[ $migrated -gt 0 ]]; then
		print_success "Migrated loop state in $migrated repositories"
	else
		print_info "No legacy loop state directories found"
	fi

	# Write sentinel so subsequent setup runs skip the find scan (t3221)
	mkdir -p "$(dirname "$_sentinel")"
	date -u +%Y-%m-%dT%H:%M:%SZ >"$_sentinel"
	return 0
}

# Migrate pulse-repos.json into repos.json
# pulse-repos.json had slug/path/priority for supervisor-managed repos.
# Now repos.json is the single source of truth with slug, pulse, and priority fields.
migrate_pulse_repos_to_repos_json() {
	local pulse_file="$HOME/.config/aidevops/pulse-repos.json"
	local repos_file="$HOME/.config/aidevops/repos.json"

	if [[ ! -f "$pulse_file" ]]; then
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		print_warning "jq not installed — skipping pulse-repos.json migration"
		return 0
	fi

	if [[ ! -f "$repos_file" ]]; then
		print_warning "repos.json not found — skipping pulse-repos.json migration"
		return 0
	fi

	local migrated=0
	local slug repo_path priority

	# Read each entry from pulse-repos.json and merge into repos.json
	# Note: avoid 'path' as variable name — in zsh, lowercase 'path' is tied to PATH array
	while IFS=$'\t' read -r slug repo_path priority; do
		[[ -z "$slug" ]] && continue
		# Expand ~ in path
		local expanded_path="${repo_path/#\~/$HOME}"

		# Check if this repo exists in repos.json by path
		if jq -e --arg path "$expanded_path" '.initialized_repos[] | select(.path == $path)' "$repos_file" &>/dev/null; then
			# Update existing entry: add slug, pulse, priority
			local temp_file="${repos_file}.tmp"
			jq --arg path "$expanded_path" --arg slug "$slug" --arg priority "$priority" \
				'(.initialized_repos[] | select(.path == $path)) |= . + {slug: $slug, pulse: true, priority: $priority}' \
				"$repos_file" >"$temp_file" && mv "$temp_file" "$repos_file"
			((++migrated))
		else
			# Add new entry from pulse-repos.json
			local temp_file="${repos_file}.tmp"
			jq --arg path "$expanded_path" --arg slug "$slug" --arg priority "$priority" \
				'.initialized_repos += [{path: $path, slug: $slug, pulse: true, priority: $priority}]' \
				"$repos_file" >"$temp_file" && mv "$temp_file" "$repos_file"
			((++migrated))
		fi
	done < <(jq -r '(.repos? // .)[] | [.slug, .path, .priority] | @tsv' "$pulse_file" 2>/dev/null)

	if [[ $migrated -gt 0 ]]; then
		print_success "Migrated $migrated repo(s) from pulse-repos.json into repos.json"
		# Rename old file so it's not read again, but keep as backup
		mv "$pulse_file" "${pulse_file}.migrated"
		print_info "Renamed pulse-repos.json to pulse-repos.json.migrated"
	fi

	return 0
}

# Migrate orphaned supervisor files from deployed installs (GH#5147)
# After the supervisor-to-pulse-wrapper migration (PR #2291, PR #2475), and
# subsequent removal of archived dirs from the repo, deployed installs may
# retain orphaned files that rsync doesn't clean up:
#   - ~/.aidevops/agents/scripts/supervisor-helper.sh (old entry point)
#   - ~/.aidevops/agents/scripts/supervisor/ (old module directory)
#   - ~/.aidevops/agents/scripts/archived/ (removed from repo)
#   - ~/.aidevops/agents/scripts/supervisor-archived/ (removed from repo)
#   - cron/launchd entries invoking supervisor-helper.sh pulse
# This migration removes all orphaned files and rewrites scheduler entries.
migrate_orphaned_supervisor() {
	local agents_dir="$HOME/.aidevops/agents"
	local scripts_dir="$agents_dir/scripts"
	local cleaned=0

	# 1. Remove orphaned supervisor-helper.sh from deployed scripts
	if [[ -f "$scripts_dir/supervisor-helper.sh" ]]; then
		rm -f "$scripts_dir/supervisor-helper.sh"
		print_info "Removed orphaned supervisor-helper.sh from deployed scripts"
		((++cleaned))
	fi

	# 2. Remove orphaned supervisor/ module directory
	if [[ -d "$scripts_dir/supervisor" && ! -L "$scripts_dir/supervisor" ]]; then
		if [[ -f "$scripts_dir/supervisor/pulse.sh" ]] ||
			[[ -f "$scripts_dir/supervisor/dispatch.sh" ]] ||
			[[ -f "$scripts_dir/supervisor/_common.sh" ]]; then
			rm -rf "$scripts_dir/supervisor"
			print_info "Removed orphaned supervisor/ module directory from deployed scripts"
			((++cleaned))
		fi
	fi

	# 3. Remove archived dirs no longer shipped in repo
	if [[ -d "$scripts_dir/archived" ]]; then
		rm -rf "$scripts_dir/archived"
		print_info "Removed orphaned archived/ directory from deployed scripts"
		((++cleaned))
	fi
	if [[ -d "$scripts_dir/supervisor-archived" ]]; then
		rm -rf "$scripts_dir/supervisor-archived"
		print_info "Removed orphaned supervisor-archived/ directory from deployed scripts"
		((++cleaned))
	fi

	# 3. Migrate cron entries from supervisor-helper.sh to pulse-wrapper.sh
	#    Old pattern: */2 * * * * ... supervisor-helper.sh pulse ...
	#    New pattern: already installed by setup.sh's pulse section
	#    Strategy: remove old entries; setup.sh will install the new one if pulse is enabled
	local current_crontab
	current_crontab=$(crontab -l 2>/dev/null) || current_crontab=""
	if echo "$current_crontab" | grep -qF "supervisor-helper.sh"; then
		# Remove all cron lines referencing supervisor-helper.sh
		local new_crontab
		new_crontab=$(echo "$current_crontab" | grep -v "supervisor-helper.sh")
		if [[ -n "$new_crontab" ]]; then
			printf '%s\n' "$new_crontab" | crontab - || true
		else
			# All entries were supervisor-helper.sh — remove crontab entirely
			crontab -r || true
		fi
		print_info "Removed orphaned supervisor-helper.sh cron entries"
		print_info "  pulse-wrapper.sh will be installed by setup.sh if supervisor pulse is enabled"
		((++cleaned))
	fi

	# 4. Migrate launchd entries from old supervisor label (macOS only)
	#    Old label: com.aidevops.supervisor-pulse (from cron.sh/launchd.sh)
	#    New label: com.aidevops.aidevops-supervisor-pulse (from setup.sh)
	#    setup.sh already handles the new label cleanup at line ~1000, but
	#    the old label from cron.sh may also be present
	if [[ "$(uname -s)" == "$MIGRATION_PLATFORM_DARWIN" ]]; then
		local old_label="com.aidevops.supervisor-pulse"
		local old_plist="$HOME/Library/LaunchAgents/${old_label}.plist"
		if _launchd_has_agent "$old_label" || [[ -f "$old_plist" ]]; then
			# Use launchctl remove by label — works even when the plist file is
			# missing (orphaned agent loaded without a backing file on disk)
			launchctl remove "$old_label" || true
			rm -f "$old_plist"
			print_info "Removed orphaned supervisor-pulse LaunchAgent ($old_label)"
			((++cleaned))
		fi
	fi

	if [[ $cleaned -gt 0 ]]; then
		print_success "Cleaned up $cleaned orphaned supervisor artifact(s) — pulse-wrapper.sh is the active system"
	fi

	return 0
}

# Apply the t18137 reasoning defaults to an existing user-local routing table
# exactly once. Installs without a custom table already receive the canonical
# defaults through agent deployment, so this migration must not create a custom
# table that would freeze future framework routing updates.
migrate_custom_model_routing_reasoning_defaults() {
	local marker_dir="${HOME:+$HOME/.aidevops/cache/migrations}"
	local marker_file="${marker_dir:+$marker_dir/t18137-model-routing-reasoning-defaults}"
	local custom_table="${HOME:+$HOME/.aidevops/agents/custom/configs/model-routing-table.json}"
	local backup_dir="${HOME:+$HOME/.aidevops/config-backups/migrations}"
	local backup_file="${backup_dir:+$backup_dir/t18137-model-routing-table.json}"
	local temp_file=""
	local jq_object_type="object"
	local effective_uid="${EUID:-$(id -u)}"

	if [[ -z "$custom_table" ]]; then
		print_warning "HOME unavailable; t18137 custom model routing migration will retry"
		return 0
	fi

	[[ -f "$marker_file" ]] && return 0
	if [[ ! -e "$custom_table" ]]; then
		mkdir -p "$marker_dir"
		date -u +%Y-%m-%dT%H:%M:%SZ >"$marker_file"
		return 0
	fi
	if [[ -L "$custom_table" || ! -f "$custom_table" || (! -O "$custom_table" && "$effective_uid" -ne 0) ]]; then
		print_warning "Skipping unsafe custom model routing table; t18137 migration will retry"
		return 0
	fi
	if ! command -v jq >/dev/null 2>&1; then
		print_warning "jq unavailable; t18137 custom model routing migration will retry"
		return 0
	fi
	if ! jq -e --arg object_type "$jq_object_type" '
		type == $object_type and
		((.tiers // {}) | type == $object_type) and
		((.tiers.simple // {}) | type == $object_type) and
		((.tiers.simple.reasoning // {}) | type == $object_type) and
		((.tiers.thinking // {}) | type == $object_type) and
		((.tiers.thinking.reasoning // {}) | type == $object_type)
	' "$custom_table" >/dev/null 2>&1; then
		print_warning "Invalid custom model routing structure; t18137 migration will retry"
		return 0
	fi

	mkdir -p "$marker_dir" "$backup_dir"
	if [[ ! -f "$backup_file" ]]; then
		cp -p "$custom_table" "$backup_file" || {
			print_warning "Failed to create backup of custom model routing table at $backup_file; t18137 migration will retry"
			return 0
		}
	fi
	temp_file=$(mktemp "${custom_table}.t18137.XXXXXX") || {
		print_warning "Failed to create temporary file for migration of $custom_table; t18137 migration will retry"
		return 0
	}
	if ! jq '
		.tiers = (.tiers // {}) |
		.tiers.simple = (.tiers.simple // {}) |
		.tiers.simple.reasoning = (.tiers.simple.reasoning // {}) |
		.tiers.simple.reasoning.openai = "medium" |
		.tiers.thinking = (.tiers.thinking // {}) |
		.tiers.thinking.reasoning = (.tiers.thinking.reasoning // {}) |
		.tiers.thinking.reasoning.openai = "high"
	' "$custom_table" >"$temp_file"; then
		print_warning "Failed to update custom model routing table structure in $custom_table; t18137 migration will retry"
		rm -f "$temp_file"
		return 0
	fi
	chmod 600 "$temp_file"
	if ! mv "$temp_file" "$custom_table"; then
		print_warning "Failed to replace custom model routing table at $custom_table; t18137 migration will retry"
		rm -f "$temp_file"
		return 0
	fi
	date -u +%Y-%m-%dT%H:%M:%SZ >"$marker_file"
	print_info "Updated custom model routing reasoning defaults (t18137)"
	return 0
}

# Backfill GitHub issue relationships from TODO.md metadata (t1889)
# One-time migration: reads blocked-by:/blocks: and subtask hierarchy from
# TODO.md in each pulse-enabled repo, and sets the corresponding GitHub
# issue relationships (blocked-by, sub-issues) via the GraphQL API.
#
# Uses marker file to ensure it runs only once per install.
# Safe to re-run — the GraphQL mutations are idempotent (duplicates are skipped).
backfill_issue_relationships() {
	local marker_file="$HOME/.aidevops/.migrations/t1889-relationships-backfill"
	local marker_dir
	marker_dir=$(dirname "$marker_file")

	# Skip if already done
	if [[ -f "$marker_file" ]]; then
		return 0
	fi

	# Require gh CLI and authentication
	if ! command -v gh &>/dev/null; then
		print_warning "gh CLI not installed — skipping issue relationships backfill"
		return 0
	fi
	if ! gh auth status &>/dev/null 2>&1; then
		print_warning "gh CLI not authenticated — skipping issue relationships backfill"
		return 0
	fi

	# Require jq for repos.json parsing
	if ! command -v jq &>/dev/null; then
		print_warning "jq not installed — skipping issue relationships backfill"
		return 0
	fi

	local repos_file="$HOME/.config/aidevops/repos.json"
	if [[ ! -f "$repos_file" ]]; then
		print_info "No repos.json — skipping issue relationships backfill"
		mkdir -p "$marker_dir"
		touch "$marker_file"
		return 0
	fi

	local sync_script="$HOME/.aidevops/agents/scripts/issue-sync-helper.sh"
	if [[ ! -x "$sync_script" ]]; then
		print_warning "issue-sync-helper.sh not found — skipping relationships backfill"
		return 0
	fi

	print_info "Backfilling GitHub issue relationships (blocked-by, sub-issues) from TODO.md..."

	local total_repos=0 total_rels=0 failed_repos=0
	local repo_path repo_slug local_only

	while IFS=$'\t' read -r repo_path repo_slug local_only; do
		[[ -z "$repo_path" ]] && continue
		local expanded_path="${repo_path/#\~/$HOME}"

		# Skip local-only repos (no GitHub remote)
		[[ "$local_only" == "true" ]] && continue

		# Skip repos without TODO.md
		[[ ! -f "$expanded_path/TODO.md" ]] && continue

		# Skip repos with no ref:GH# entries
		if ! grep -qE 'ref:GH#[0-9]+' "$expanded_path/TODO.md" 2>/dev/null; then
			continue
		fi

		# Skip repos with no blocked-by:/blocks: or subtask entries
		local has_deps=false
		grep -qE 'blocked-by:|blocks:' "$expanded_path/TODO.md" 2>/dev/null && has_deps=true
		grep -qE '^\s+- \[.\] t[0-9]+\.[0-9]+.*ref:GH#' "$expanded_path/TODO.md" 2>/dev/null && has_deps=true
		[[ "$has_deps" == "false" ]] && continue

		total_repos=$((total_repos + 1))
		local repo_arg=""
		[[ -n "$repo_slug" ]] && repo_arg="--repo $repo_slug"

		print_info "  $(basename "$expanded_path"): syncing relationships..."
		# shellcheck disable=SC2086
		if (cd "$expanded_path" && bash "$sync_script" relationships $repo_arg --verbose 2>&1 | tail -3); then
			true
		else
			print_warning "  $(basename "$expanded_path"): relationships sync had errors"
			failed_repos=$((failed_repos + 1))
		fi
	done < <(jq -r '.initialized_repos[] | select(.pulse == true) | [.path, .slug, (.local_only // false | tostring)] | @tsv' "$repos_file" 2>/dev/null)

	# Create marker directory and file
	mkdir -p "$marker_dir"
	date -u +%Y-%m-%dT%H:%M:%SZ >"$marker_file"

	if [[ $total_repos -eq 0 ]]; then
		print_info "No repos with relationship data to backfill"
	elif [[ $failed_repos -eq 0 ]]; then
		print_success "Issue relationships backfilled for $total_repos repo(s)"
	else
		print_warning "Backfilled $total_repos repo(s), $failed_repos had errors"
	fi

	return 0
}

# Migrate aidevops cron entries to systemd user timers (GH#17695 Finding D).
# On Linux systems with systemd, scans cron for aidevops markers and removes
# entries that have a corresponding systemd timer already installed. This
# prevents dual-execution for existing installations that were set up before
# the systemd preference was added.
# Safe to run on macOS (no-op) and on Linux without systemd (no-op).
# Idempotent: uses a marker file to run only once.
migrate_cron_to_systemd() {
	# Only run on Linux with systemd available
	if [[ "$(uname -s)" == "$MIGRATION_PLATFORM_DARWIN" ]]; then
		return 0
	fi
	if ! command -v systemctl >/dev/null 2>&1 || ! systemctl --user status >/dev/null 2>&1; then
		return 0
	fi

	# Versioned migration marker — bump version when new entries are added so
	# existing systems re-run the migration (GH#17861: added auto-update + repo-sync).
	local marker_dir="$HOME/.aidevops/cache/migrations"
	local marker_file="$marker_dir/cron-to-systemd-v2-done"
	if [[ -f "$marker_file" ]]; then
		return 0
	fi

	# Parallel arrays: cron markers and their corresponding systemd timer names.
	# Bash 3.2 compatible (no associative arrays).
	local cron_markers="aidevops: stats-wrapper
aidevops: gh-failure-miner
aidevops: process-guard
aidevops: memory-pressure-monitor
aidevops: screen-time-snapshot
aidevops: contribution-watch
aidevops: profile-readme-update
aidevops: token-refresh
aidevops-auto-update
aidevops-repo-sync"

	local systemd_timers="aidevops-stats-wrapper
aidevops-gh-failure-miner
aidevops-process-guard
aidevops-memory-pressure-monitor
aidevops-screen-time-snapshot
aidevops-contribution-watch
aidevops-profile-readme-update
aidevops-token-refresh
aidevops-auto-update
aidevops-repo-sync"

	local current_cron
	current_cron=$(crontab -l 2>/dev/null) || current_cron=""
	if [[ -z "$current_cron" ]]; then
		mkdir -p "$marker_dir"
		date -u +%Y-%m-%dT%H:%M:%SZ >"$marker_file"
		return 0
	fi

	local migrated=0
	local new_cron="$current_cron"
	local i=0

	while IFS= read -r marker; do
		local timer_name
		timer_name=$(echo "$systemd_timers" | sed -n "$((i + 1))p")
		i=$((i + 1))
		# Only remove cron entry if the corresponding systemd timer is active
		if echo "$new_cron" | grep -qF "$marker" &&
			systemctl --user is-enabled "${timer_name}.timer" >/dev/null 2>&1; then
			new_cron=$(echo "$new_cron" | grep -vF "$marker")
			migrated=$((migrated + 1))
			print_info "Migrated $marker from cron to systemd (${timer_name}.timer)"
		fi
	done <<<"$cron_markers"

	if [[ $migrated -gt 0 ]]; then
		echo "$new_cron" | crontab -
		print_success "Cron-to-systemd migration: $migrated scheduler(s) migrated"
	fi

	# Write versioned marker regardless of whether anything was migrated
	mkdir -p "$marker_dir"
	date -u +%Y-%m-%dT%H:%M:%SZ >"$marker_file"
	return 0
}

# Remove stale experimental dashboard schedulers when the framework no longer
# installs or enables them. Machine migrations can preserve launchd/systemd
# entries even after aidevops-routines disables r912, creating perpetual
# restart churn for an unmanaged service.
cleanup_legacy_dashboard_launchagent() {
	local label="com.aidevops.dashboard"
	local systemd_unit="sh.aidevops.dashboard"
	local legacy_systemd_unit="aidevops-dashboard"
	local routines_todo="$HOME/Git/aidevops-routines/TODO.md"
	local r912_enabled="false"

	if [[ -f "$routines_todo" ]] && grep -qE '^- \[x\] r912[[:space:]]' "$routines_todo"; then
		r912_enabled="true"
	fi

	if [[ "$r912_enabled" == "true" ]]; then
		return 0
	fi

	case "$(uname -s)" in
	D*)
		local plist="$HOME/Library/LaunchAgents/${label}.plist"
		if [[ ! -e "$plist" ]]; then
			return 0
		fi

		local domain
		domain="gui/$(id -u)"
		launchctl bootout "${domain}/${label}" >/dev/null 2>&1 || true
		launchctl unload "$plist" >/dev/null 2>&1 || true
		mv "$plist" "${plist}.disabled-$(date -u +%Y%m%d%H%M%S)" 2>/dev/null || rm -f "$plist"
		print_info "Removed stale dashboard LaunchAgent (${label}); r912 is disabled or unmanaged"
		;;
	Linux)
		local user_systemd_dir="$HOME/.config/systemd/user"
		local has_systemd=0
		if command -v systemctl >/dev/null && systemctl --user status >/dev/null 2>&1; then
			has_systemd=1
		fi
		local removed=0
		local unit
		for unit in "$systemd_unit" "$legacy_systemd_unit"; do
			[[ -z "$unit" ]] && continue
			if [[ "$has_systemd" -eq 1 ]]; then
				systemctl --user disable --now "${unit}.service" || true
				systemctl --user disable --now "${unit}.timer" || true
			fi
			if [[ -e "${user_systemd_dir}/${unit}.service" ]]; then
				mv "${user_systemd_dir}/${unit}.service" "${user_systemd_dir}/${unit}.service.disabled-$(date -u +%Y%m%d%H%M%S)" || rm -f "${user_systemd_dir}/${unit}.service"
				removed=$((removed + 1))
			fi
			if [[ -e "${user_systemd_dir}/${unit}.timer" ]]; then
				mv "${user_systemd_dir}/${unit}.timer" "${user_systemd_dir}/${unit}.timer.disabled-$(date -u +%Y%m%d%H%M%S)" || rm -f "${user_systemd_dir}/${unit}.timer"
				removed=$((removed + 1))
			fi
		done
		if [[ "$removed" -gt 0 ]] && [[ "$has_systemd" -eq 1 ]]; then
			systemctl --user daemon-reload || true
			print_info "Removed stale dashboard systemd unit(s); r912 is disabled or unmanaged"
		fi
		;;
	esac
	return 0
}
