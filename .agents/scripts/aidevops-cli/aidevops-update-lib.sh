#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Update Library — update command helper functions
# =============================================================================
# Helper functions for `aidevops update`, extracted from aidevops.sh to keep
# the CLI orchestrator below the large-file gate while preserving behaviour.
#
# Usage: source "${INSTALL_DIR}/aidevops-update-lib.sh"
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_AIDEVOPS_UPDATE_LIB_LOADED:-}" ]] && return 0
_AIDEVOPS_UPDATE_LIB_LOADED=1

_update_lib_dir="${BASH_SOURCE[0]%/*}"
[[ "$_update_lib_dir" == "${BASH_SOURCE[0]}" ]] && _update_lib_dir="."
_AIDEVOPS_UPDATE_HELPER_DIR="$(cd "${_update_lib_dir}/.." && pwd)"
# shellcheck source=aidevops-project-config-lib.sh
source "${_update_lib_dir}/aidevops-project-config-lib.sh"
unset _update_lib_dir

if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

_AIDEVOPS_UPDATE_TRUE=true

_update_canonical_has_untracked_only() {
	local real_git="$1"
	local repo_path="$2"
	local tracked_status=""
	local untracked_files=""
	tracked_status=$("$real_git" -C "$repo_path" status --porcelain=v1 --untracked-files=no 2>/dev/null) || return 1
	[[ -z "$tracked_status" ]] || return 1
	untracked_files=$("$real_git" -C "$repo_path" ls-files --others --exclude-standard 2>/dev/null) || return 1
	[[ -n "$untracked_files" ]]
	return $?
}

_update_fetch_main() {
	local branch="$1"
	_AIDEVOPS_UPDATE_CANONICAL_FAST_FORWARDED=false
	local real_git="${AIDEVOPS_REAL_GIT_BIN:-/usr/bin/git}"
	local git_dir=""
	local common_dir=""
	git_dir=$("$real_git" -C "$INSTALL_DIR" rev-parse --git-dir 2>/dev/null || true)
	common_dir=$("$real_git" -C "$INSTALL_DIR" rev-parse --git-common-dir 2>/dev/null || true)
	if [[ -z "$git_dir" || "$git_dir" != "$common_dir" ]]; then
		"$real_git" -C "$INSTALL_DIR" fetch origin "$branch" --tags --quiet
		return $?
	fi

	local helper=""
	local candidate=""
	local bundled_helper="${_AIDEVOPS_UPDATE_HELPER_DIR:-}/canonical-recovery-helper.sh"
	local source_helper="${INSTALL_DIR}/.agents/scripts/canonical-recovery-helper.sh"
	local stable_helper="${HOME}/.aidevops/agents/scripts/canonical-recovery-helper.sh"
	for candidate in "$bundled_helper" "$source_helper" "$stable_helper"; do
		[[ -f "$candidate" ]] || continue
		if grep -q -- 'sync-mirror.*--reason aidevops-update' "$candidate" 2>/dev/null; then
			helper="$candidate"
			break
		fi
	done
	if [[ -z "$helper" ]]; then
		print_error "A compatible canonical update helper is unavailable (stable path: $stable_helper)"
		print_info "Reinstall aidevops to restore a helper with aidevops-update maintenance support, then rerun aidevops update."
		return 1
	fi

	local recovery_command="fast-forward-current"
	local recovery_confirmation="FAST_FORWARD_CANONICAL_BRANCH"
	local status_output=""
	status_output=$("$real_git" -C "$INSTALL_DIR" status --porcelain=v1 2>/dev/null) || return 1
	if [[ -n "$status_output" ]]; then
		if ! _update_canonical_has_untracked_only "$real_git" "$INSTALL_DIR"; then
			print_error "Audited canonical update requires a clean tracked/index state."
			return 1
		fi
		recovery_command="sync-mirror"
		recovery_confirmation="SYNCHRONIZE_CANONICAL_MIRROR"
		print_info "Preserving untracked canonical files before the audited update..."
	else
		print_info "Using audited canonical fast-forward for the source checkout..."
	fi
	local recovery_args=("$recovery_command" --repo "$INSTALL_DIR")
	if [[ "$recovery_command" == "fast-forward-current" ]]; then
		recovery_args+=(--branch "$branch")
	fi
	recovery_args+=(--reason aidevops-update --confirm "$recovery_confirmation")
	if ! AIDEVOPS_REAL_GIT_BIN="$real_git" bash "$helper" "${recovery_args[@]}"; then
		print_error "Audited canonical fast-forward failed; no update was deployed."
		return 1
	fi
	_AIDEVOPS_UPDATE_CANONICAL_FAST_FORWARDED=true
	return 0
}

# Tracked project config is repository-owned policy. Framework updates may read
# it to refresh local registration metadata, but must not create working-tree
# changes that block the repository's normal git workflow.
_update_fresh_install() {
	print_warning "Repository not found at the active CLI tree, updating from a clean temporary checkout..."
	local tmp_checkout
	tmp_checkout=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-update-XXXXXX") || {
		print_error "Failed to create temporary update checkout"
		return 1
	}
	trap 'rm -rf "${tmp_checkout:-}"' RETURN
	if ! git clone --depth 1 "${REPO_URL:-https://github.com/marcusquinn/aidevops.git}" "$tmp_checkout" >/dev/null 2>&1; then
		print_error "Failed to create clean update checkout"
		return 1
	fi
	bash "$tmp_checkout/setup.sh" --stage ai-session || return $?
	return 0
}

_update_sync_projects() {
	local skip="$1" current_ver="$2"
	echo ""
	print_header "Syncing Initialized Projects"
	if [[ "$skip" == "$_AIDEVOPS_UPDATE_TRUE" ]]; then
		print_info "Project sync skipped (--skip-project-sync)"
		return 0
	fi
	local repos_needing_upgrade=()
	while IFS= read -r repo_path; do
		[[ -z "$repo_path" ]] && continue
		[[ -d "$repo_path" ]] && check_repo_needs_upgrade "$repo_path" && repos_needing_upgrade+=("$repo_path")
	done < <(get_registered_repos)
	_update_sync_agent_source_repos "$current_ver" || true
	if [[ ${#repos_needing_upgrade[@]} -eq 0 ]]; then
		print_success "All registered projects are up to date"
		return 0
	fi
	local synced=0 skipped=0 failed=0 preserved=0
	for repo in "${repos_needing_upgrade[@]}"; do
		[[ ! -f "$repo/.aidevops.json" ]] && {
			skipped=$((skipped + 1))
			continue
		}
		local did_sync=false
		if command -v jq &>/dev/null; then
			local features
			features=$(jq -r '[.features | to_entries[] | select(.value == true) | .key] | join(",")' "$repo/.aidevops.json" 2>/dev/null || echo "")
			if _project_config_is_tracked "$repo"; then
				_project_config_write_migration_plan "$repo" || print_warning "Could not write tracked config repair plan"
				if register_repo "$repo" "$current_ver" "$features"; then
					did_sync=true
					preserved=$((preserved + 1))
				fi
			else
				local temp_file="${repo}/.aidevops.json.tmp"
				if jq --arg version "$current_ver" '.version = $version' "$repo/.aidevops.json" >"$temp_file" 2>/dev/null && [[ -s "$temp_file" ]]; then
					mv "$temp_file" "$repo/.aidevops.json"
					register_repo "$repo" "$current_ver" "$features"
					did_sync=true
				else rm -f "$temp_file"; fi
			fi
		fi
		if [[ "$did_sync" != "$_AIDEVOPS_UPDATE_TRUE" ]] && ! _project_config_is_tracked "$repo"; then
			sed -i '' "s/\"version\": *\"[^\"]*\"/\"version\": \"$current_ver\"/" "$repo/.aidevops.json" 2>/dev/null && did_sync=true
		fi
		[[ "$did_sync" == "$_AIDEVOPS_UPDATE_TRUE" ]] && synced=$((synced + 1)) || failed=$((failed + 1))
	done
	[[ $synced -gt 0 ]] && print_success "Synced $synced project(s) to v$current_ver"
	[[ $preserved -gt 0 ]] && print_info "Preserved $preserved tracked project config(s); updated registration metadata only"
	[[ $skipped -gt 0 ]] && print_info "Skipped $skipped uninitialized project(s) (run 'aidevops init' in each to enable)"
	[[ $failed -gt 0 ]] && print_warning "$failed project(s) failed to sync (jq missing or write error)"
	return 0
}

_update_reconcile_repo_verify() {
	local helper="${INSTALL_DIR}/.agents/scripts/lint-helper.sh"
	[[ -f "$helper" ]] || helper="${HOME}/.aidevops/agents/scripts/lint-helper.sh"
	if [[ ! -f "$helper" ]]; then
		print_info "Lint reconciliation helper unavailable"
		return 0
	fi
	print_info "Reconciling repository lint policy and hooks..."
	bash "$helper" reconcile --all || print_warning "Repository lint reconciliation completed with warnings"
	return 0
}

_update_repo_verify_files_changed() {
	local old_sha="$1"
	local new_sha="$2"
	local changed_file=""
	[[ -n "$old_sha" && -n "$new_sha" && "$old_sha" != "$new_sha" ]] || return 1
	while IFS= read -r changed_file; do
		case "$changed_file" in
		.agents/hooks/repo-verify-pre-push.sh | .agents/configs/repo-verify-defaults.conf | \
			.agents/scripts/repo-verify-config-lib.sh | .agents/scripts/lint-helper.sh | \
			.agents/scripts/install-pre-push-guards.sh | .agents/scripts/setup/_repo_verify_guard.sh | \
			.agents/scripts/aidevops-cli/aidevops-init-lib.sh | .agents/scripts/aidevops-cli/aidevops-update-lib.sh)
			return 0
			;;
		esac
	done < <(git -C "$INSTALL_DIR" diff --name-only "$old_sha" "$new_sha" 2>/dev/null)
	return 1
}

_update_sync_agent_source_repos() {
	local current_ver="$1"
	local synced=0 skipped=0 failed=0
	local repo

	while IFS= read -r repo; do
		[[ -z "$repo" ]] && continue
		if [[ ! -d "$repo" ]]; then
			skipped=$((skipped + 1))
			continue
		fi
		if seed_agent_source_repo_templates "$repo"; then
			synced=$((synced + 1))
			if [[ -f "$repo/.aidevops.json" ]] && command -v jq &>/dev/null && ! _project_config_is_tracked "$repo"; then
				local temp_file="${repo}/.aidevops.json.tmp"
				jq --arg version "$current_ver" '.version = $version | .agent_source = true' "$repo/.aidevops.json" >"$temp_file" 2>/dev/null && mv "$temp_file" "$repo/.aidevops.json" || rm -f "$temp_file"
			fi
		else
			failed=$((failed + 1))
		fi
	done < <(get_agent_source_repos)

	[[ $synced -gt 0 ]] && print_success "Synced $synced agent-source repo template(s)"
	[[ $skipped -gt 0 ]] && print_info "Skipped $skipped unavailable agent-source repo(s)"
	[[ $failed -gt 0 ]] && print_warning "$failed agent-source repo template sync(s) failed"
	return 0
}

_update_check_planning() {
	echo ""
	print_header "Checking Planning Templates"
	local repos_needing_planning=()
	while IFS= read -r repo_path; do
		[[ -z "$repo_path" || ! -d "$repo_path" ]] && continue
		if [[ -f "$repo_path/.aidevops.json" ]]; then
			local has_planning
			has_planning=$(grep -o '"planning": *true' "$repo_path/.aidevops.json" 2>/dev/null || true)
			[[ -n "$has_planning" ]] && check_planning_needs_upgrade "$repo_path" && repos_needing_planning+=("$repo_path")
		fi
	done < <(get_registered_repos)
	if [[ ${#repos_needing_planning[@]} -eq 0 ]]; then
		print_success "All planning templates are up to date"
		return 0
	fi
	echo ""
	print_warning "${#repos_needing_planning[@]} project(s) have outdated planning templates:"
	for repo in "${repos_needing_planning[@]}"; do
		local repo_name
		repo_name=$(basename "$repo")
		local todo_ver
		todo_ver=$(grep -A1 "TOON:meta" "$repo/TODO.md" 2>/dev/null | tail -1 | cut -d',' -f1)
		echo "  - $repo_name (v${todo_ver:-none})"
	done
	local template_ver
	template_ver=$(grep -A1 "TOON:meta" "$AGENTS_DIR/templates/todo-template.md" 2>/dev/null | tail -1 | cut -d',' -f1)
	echo ""
	echo "  Latest template: v${template_ver} (adds risk field, active session time estimates)"
	echo ""
	read -r -p "Upgrade planning templates in these projects? [y/N] " response
	if [[ "$response" =~ ^[Yy]$ ]]; then
		for repo in "${repos_needing_planning[@]}"; do
			print_info "Upgrading $(basename "$repo")..."
			(cd "$repo" && cmd_upgrade_planning --force) || print_warning "Failed to upgrade $(basename "$repo")"
		done
	else print_info "Run 'aidevops upgrade-planning' in each project to upgrade manually"; fi
	return 0
}

_update_check_tools() {
	echo ""
	print_header "Checking Key Tools"
	local tool_check_script="$AGENTS_DIR/scripts/tool-version-check.sh"
	if [[ ! -f "$tool_check_script" ]]; then
		print_info "Tool version check not available (run setup first)"
		return 0
	fi
	local stale_count=0 stale_tools=""
	local key_tool_cmds="opencode gh"
	local key_tool_pkgs="opencode-ai brew:gh"
	if declare -F aidevops_gh_slurp_supported >/dev/null 2>&1 && ! aidevops_gh_slurp_supported; then
		local gh_slurp_message=""
		if declare -F aidevops_gh_slurp_status_message >/dev/null 2>&1; then
			gh_slurp_message=$(aidevops_gh_slurp_status_message)
		else
			gh_slurp_message="GitHub CLI (gh) is below the aidevops minimum for gh api --paginate --slurp"
		fi
		print_warning "$gh_slurp_message"
		if declare -F aidevops_gh_slurp_remediation_hint >/dev/null 2>&1; then
			print_info "$(aidevops_gh_slurp_remediation_hint)"
		else
			print_info "Run aidevops setup or upgrade gh manually, then rerun aidevops status."
		fi
	fi
	local idx=0
	for cmd_name in $key_tool_cmds; do
		local pkg_ref
		pkg_ref=$(echo "$key_tool_pkgs" | cut -d' ' -f$((idx + 1)))
		idx=$((idx + 1))
		local installed="" latest=""
		command -v "$cmd_name" &>/dev/null || continue
		installed=$("$cmd_name" --version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
		[[ -z "$installed" ]] && continue
		if [[ "$pkg_ref" == brew:* ]]; then
			local brew_pkg="${pkg_ref#brew:}"
			local brew_bin=""
			brew_bin=$(command -v brew 2>/dev/null || true)
			if [[ -n "$brew_bin" && -x "$brew_bin" ]]; then
				latest=$(_timeout_cmd 30 "$brew_bin" info --json=v2 "$brew_pkg" | jq -r '.formulae[0].versions.stable // empty' || true)
			elif [[ "$brew_pkg" == "gh" ]] && command -v gh &>/dev/null; then latest=$(get_public_release_tag "cli/cli"); fi
		else latest=$(_timeout_cmd 30 npm view "$pkg_ref" version || true); fi
		[[ -z "$latest" ]] && continue
		[[ "$installed" != "$latest" ]] && {
			stale_tools="${stale_tools:+$stale_tools, }$cmd_name ($installed -> $latest)"
			((++stale_count))
		}
	done
	if [[ "$stale_count" -eq 0 ]]; then
		print_success "Key tools are up to date"
	else
		print_warning "$stale_count tool(s) have updates: $stale_tools"
		echo ""
		read -r -p "Run full tool update check? [y/N] " response
		[[ "$response" =~ ^[Yy]$ ]] && bash "$tool_check_script" --update || print_info "Run 'aidevops update-tools --update' to update later"
	fi
	return 0
}

# Check for stale Homebrew-installed copy after git update (GH#11470)
# Self-heal broken OpenCode runtime symlinks (t2172). A single dangling
# symlink in ~/.config/opencode/{command,agent,skills,tool}/ blocks new
# OpenCode sessions with "Failed to parse command ...". Running on every
# update is cheap (find+rm on 4 small dirs) and catches orphans left
# behind when users delete private agent source clones without going
# through `agent-sources-helper.sh remove`. Fail-open — must never
# break the update cron.
_update_sweep_opencode_symlinks() {
	local sym_helper="${HOME}/.aidevops/agents/scripts/agent-sources-helper.sh"
	[[ -x "$sym_helper" ]] || return 0
	"$sym_helper" cleanup-broken-symlinks >/dev/null 2>&1 || true
	return 0
}

_update_check_homebrew() {
	command -v brew &>/dev/null || return 0
	brew list aidevops &>/dev/null 2>&1 || return 0
	local brew_version=""
	brew_version=$(brew info aidevops --json=v2 2>/dev/null | jq -r '.formulae[0].installed[0].version // empty' 2>/dev/null || true)
	[[ -z "$brew_version" ]] && return 0
	local current_version
	current_version=$(get_version)
	[[ -z "$current_version" ]] && return 0
	if [[ "$brew_version" != "$current_version" ]]; then
		echo ""
		print_warning "Homebrew-installed copy is outdated ($brew_version vs $current_version)"
		print_info "The Homebrew wrapper should prefer your git copy, but if your PATH"
		print_info "resolves the Homebrew libexec copy directly, you'll run the old version."
		echo ""
		read -r -p "Run 'brew upgrade aidevops' now? [y/N] " response
		if [[ "$response" =~ ^[Yy]$ ]]; then
			brew upgrade aidevops 2>&1 || print_warning "brew upgrade failed — run manually: brew upgrade aidevops"
		else
			print_info "Run 'brew upgrade aidevops' to sync the Homebrew copy"
		fi
	fi
	return 0
}

# t2926 / GH#21102: Re-check setsid on every 'aidevops update' run.
# setsid (from util-linux) is required to detach pulse workers into their own
# process group — without it, every pulse restart sends SIGHUP to its PGID,
# killing in-flight workers. This check runs even when setup.sh is skipped
# (already up-to-date path), so Homebrew drift doesn't silently break workers.
_update_check_setsid() {
	command -v setsid >/dev/null 2>&1 && return 0

	# setsid is missing. On macOS with Homebrew, auto-install util-linux.
	# Use a boolean flag to avoid repeating the OS literal string.
	local _on_mac=false
	[[ "$(uname -s)" == Darwin* ]] && _on_mac=true
	if $_on_mac && command -v brew >/dev/null 2>&1; then
		print_info "setsid not found — installing util-linux for worker PGID isolation (GH#21102)"
		if brew install util-linux 2>&1 | tail -3; then
			local brew_prefix=""
			brew_prefix="$(brew --prefix 2>/dev/null || true)"
			local keg_setsid="${brew_prefix}/opt/util-linux/bin/setsid"
			local link_target="${brew_prefix}/bin/setsid"
			if [[ -x "$keg_setsid" && ! -e "$link_target" ]]; then
				ln -s "$keg_setsid" "$link_target" &&
					print_success "Symlinked setsid: $keg_setsid → $link_target"
			fi
			if command -v setsid >/dev/null 2>&1; then
				print_success "setsid installed at $(command -v setsid) (worker PGID isolation enabled)"
			else
				print_error "util-linux installed but setsid still not in PATH — check brew --prefix"
			fi
		else
			print_error "brew install util-linux failed — workers will share pulse PGID until resolved"
		fi
	elif $_on_mac; then
		print_error "setsid not found — worker isolation broken; install Homebrew then run: brew install util-linux"
	else
		print_error "setsid not found — worker isolation broken; install util-linux via your distro package manager"
	fi

	return 0
}

# GH#21735: Notify operator when framework workflow templates change.
# When .agents/templates/workflows/*.yml or *-reusable.yml workflows change
# in a framework update, downstream repos that use these as workflow_call
# callers may have drifted from the new template. Detection and remediation
# both already exist (`aidevops check-workflows`, `aidevops sync-workflows
# --apply`); the gap was the notification surface — operators only learned
# of drift when downstream CI failed (canonical incident: a managed
# downstream repo's issue-sync.yml failed silently after the upstream
# template added a new input).
#
# This check inspects the SHA-window diff for changes to workflow caller
# templates and reusable workflows, prints a warning, and emits a daily
# advisory so the next session greeting surfaces it if the operator
# misses the inline output.
#
# Args: $1=old_sha, $2=new_sha
# Returns: 0 (always — informational only, never breaks update)
_update_check_workflow_drift() {
	local old_sha="$1"
	local new_sha="$2"
	[[ -z "$old_sha" || -z "$new_sha" || "$old_sha" == "$new_sha" ]] && return 0
	# `.git` is a directory in a regular repo and a file in a worktree;
	# `-e` covers both so the helper is testable from a worktree.
	[[ ! -e "$INSTALL_DIR/.git" ]] && return 0

	# Files that propagate to downstream caller workflows OR are themselves
	# reusable workflow definitions referenced by downstream callers.
	# Internal .github/workflows/*.yml hotfixes (e.g. self-test runs) are
	# intentionally skipped to avoid false-positive nags.
	local relevant_files
	relevant_files=$(git -C "$INSTALL_DIR" diff --name-only "$old_sha" "$new_sha" -- \
		'.agents/templates/workflows/' \
		'.github/workflows/' \
		2>/dev/null |
		grep -E '(\.agents/templates/workflows/.*\.ya?ml$|\.github/workflows/.*-reusable\.ya?ml$)' ||
		true)
	[[ -z "$relevant_files" ]] && return 0

	local file_count
	file_count=$(printf '%s\n' "$relevant_files" | wc -l | tr -d ' ')
	echo ""
	print_warning "Workflow templates updated ($file_count file(s)) — downstream callers may have drifted."
	print_info "  Detect drift: aidevops check-workflows"
	print_info "  Apply fix:    aidevops sync-workflows --apply [--repo OWNER/REPO]"

	# Persist as advisory so the next session greeting surfaces it even if
	# the operator misses the inline warning. Day-stamped ID makes repeated
	# updates within the same day idempotent (one advisory per day);
	# 'aidevops security dismiss <id>' silences a specific day's advisory.
	_update_emit_workflow_drift_advisory "$relevant_files" || true
	return 0
}

# Companion to _update_check_workflow_drift — separated for testability.
# Args: $1=relevant_files (newline-separated)
# Returns: 0 (always — fail-open; advisory write must never break update)
_update_emit_workflow_drift_advisory() {
	local relevant_files="$1"
	local advisories_dir="${HOME}/.aidevops/advisories"
	local adv_id
	adv_id="workflow-drift-$(date +%Y%m%d)"
	local dismissed_file="$advisories_dir/dismissed.txt"

	# Skip if today's advisory was already dismissed.
	if [[ -f "$dismissed_file" ]] && grep -qxF "$adv_id" "$dismissed_file" 2>/dev/null; then
		return 0
	fi

	mkdir -p "$advisories_dir" 2>/dev/null || return 0
	local adv_file="$advisories_dir/${adv_id}.advisory"

	{
		printf 'Workflow templates changed — downstream caller workflows may have drifted.\n'
		printf '\n'
		printf 'Files changed in this update:\n'
		printf '%s\n' "$relevant_files" | sed 's|^|  |'
		printf '\n'
		printf 'Detect drift: aidevops check-workflows\n'
		printf 'Apply fix:    aidevops sync-workflows --apply [--repo OWNER/REPO]\n'
		printf 'Background:   reference/reusable-workflows.md\n'
	} >"$adv_file" 2>/dev/null || return 0
	return 0
}

# Verify supply chain signature after pulling framework updates.
# Checks that the HEAD commit is signed by the trusted maintainer key.
# Non-blocking: warns on failure, does not abort the update.
_update_verify_signature() {
	local signing_helper="$AGENTS_DIR/scripts/signing-setup.sh"

	# Cannot verify if the helper script is not yet deployed
	if [[ ! -f "$signing_helper" ]]; then
		return 0
	fi

	local result
	result=$(bash "$signing_helper" verify-update "$INSTALL_DIR" 2>/dev/null || echo "UNKNOWN")

	case "$result" in
	VERIFIED)
		print_success "Supply chain verified: HEAD commit is signed by trusted maintainer"
		;;
	UNSIGNED)
		print_warning "HEAD commit is not signed — cannot verify supply chain integrity"
		print_info "This is expected for older releases. Signed commits start from v3.6.21+"
		;;
	UNTRUSTED)
		print_warning "HEAD commit is signed but by an untrusted key"
		print_info "Run 'aidevops signing setup' to configure signature verification"
		;;
	BAD_SIGNATURE)
		print_error "HEAD commit has a BAD signature — update may be compromised"
		print_info "Verify manually: cd $INSTALL_DIR && git log --show-signature -1"
		;;
	UNVERIFIABLE)
		# Signing not configured yet — silent, do not nag
		;;
	esac
	return 0
}

# One-shot, idempotent migration of supervisor.* → orchestration.* in settings.json (t2946).
# Safe: reads value from supervisor.* only when orchestration.* key is absent.
# Logs to ~/.aidevops/logs/settings-migration.log.
_migrate_settings_supervisor_to_orchestration() {
	local _settings_file="${HOME}/.config/aidevops/settings.json"
	local _log_file="${HOME}/.aidevops/logs/settings-migration.log"

	if ! command -v jq >/dev/null 2>&1; then
		return 0
	fi
	if [[ ! -f "$_settings_file" ]]; then
		return 0
	fi
	if ! jq . "$_settings_file" >/dev/null 2>&1; then
		return 0
	fi

	# Check if supervisor.pulse_interval_seconds exists and orchestration.pulse_interval_seconds is absent.
	local _has_sv _has_orch
	_has_sv=$(jq -r 'if .supervisor.pulse_interval_seconds != null then "yes" else "no" end' "$_settings_file" 2>/dev/null)
	_has_orch=$(jq -r 'if .orchestration.pulse_interval_seconds != null then "yes" else "no" end' "$_settings_file" 2>/dev/null)

	if [[ "$_has_sv" != "yes" ]]; then
		return 0
	fi

	local _ts
	_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date +%Y-%m-%dT%H:%M:%SZ)
	mkdir -p "$(dirname "$_log_file")" 2>/dev/null || true

	local _tmp
	_tmp=$(mktemp 2>/dev/null) || return 0

	if [[ "$_has_orch" == "no" ]]; then
		# Migrate: copy supervisor.pulse_interval_seconds to orchestration.pulse_interval_seconds,
		# then remove supervisor.pulse_interval_seconds.
		local _sv_val
		_sv_val=$(jq -r '.supervisor.pulse_interval_seconds' "$_settings_file" 2>/dev/null)
		if jq --argjson v "$_sv_val" \
			'(.orchestration.pulse_interval_seconds) = $v | del(.supervisor.pulse_interval_seconds)' \
			"$_settings_file" >"$_tmp" 2>/dev/null && [[ -s "$_tmp" ]]; then
			mv "$_tmp" "$_settings_file"
			printf '[%s] migrated supervisor.pulse_interval_seconds=%s → orchestration.pulse_interval_seconds\n' \
				"$_ts" "$_sv_val" >>"$_log_file" 2>/dev/null || true
			print_info "Settings migrated: supervisor.pulse_interval_seconds → orchestration.pulse_interval_seconds ($_sv_val)"
		else
			rm -f "$_tmp"
		fi
	else
		# Both present: orchestration wins, remove the stale supervisor key.
		local _orch_val
		_orch_val=$(jq -r '.orchestration.pulse_interval_seconds' "$_settings_file" 2>/dev/null)
		if jq 'del(.supervisor.pulse_interval_seconds)' \
			"$_settings_file" >"$_tmp" 2>/dev/null && [[ -s "$_tmp" ]]; then
			mv "$_tmp" "$_settings_file"
			printf '[%s] removed stale supervisor.pulse_interval_seconds (orchestration.pulse_interval_seconds=%s wins)\n' \
				"$_ts" "$_orch_val" >>"$_log_file" 2>/dev/null || true
			print_info "Settings cleaned: removed stale supervisor.pulse_interval_seconds (orchestration value $_orch_val kept)"
		else
			rm -f "$_tmp"
		fi
	fi
	return 0
}

_update_check_daemon_health() {
	local helper="$HOME/.aidevops/agents/scripts/auto-update-helper.sh"
	[[ -x "$helper" ]] || return 0
	local advisory_dir="$HOME/.aidevops/advisories"
	local advisory_file="$advisory_dir/daemon-disabled.advisory"

	local hc_rc=0
	"$helper" health-check --quiet >/dev/null 2>&1 || hc_rc=$?

	if [[ "$hc_rc" -eq 0 ]]; then
		# Healthy — clear any stale advisory.
		[[ -f "$advisory_file" ]] && rm -f "$advisory_file"
		return 0
	fi

	# Unhealthy — warn on stderr and write advisory.
	mkdir -p "$advisory_dir" 2>/dev/null || return 0
	local fix_cmd="aidevops auto-update enable"
	[[ "$hc_rc" -eq 1 ]] && fix_cmd="aidevops auto-update check"
	cat >"$advisory_file" <<EOF
auto-update daemon is not running normally on this runner. Without it, this
runner falls behind the fleet and may dispatch workers that fail because of
bugs already fixed upstream. See cross-runner-coordination.md §4.4.

Diagnose: aidevops auto-update health-check
Fix:      ${fix_cmd}
EOF

	if [[ "$hc_rc" -eq 1 ]]; then
		print_warning "Auto-update daemon is stalled. Fix: ${fix_cmd}"
	else
		print_warning "Auto-update daemon is not running. Fix: ${fix_cmd}"
	fi
	return 0
}
