#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Agent deployment functions for setup.sh

# Sync deployed agent bin shims into ~/.aidevops/bin for PATH discoverability.
_sync_agent_bin_shims() {
	local target_dir="$1"
	local user_bin_dir="${HOME}/.aidevops/bin"
	local shim=""
	local shim_name=""
	local existing=""
	local existing_target=""

	if [[ -z "$target_dir" ]]; then
		echo "[deploy] ERROR: target_dir is empty in _sync_agent_bin_shims" >&2
		return 1
	fi

	mkdir -p "$user_bin_dir"

	# Remove stale links from previous aidevops agent-bin deployments. This is the
	# uninstall path for retired shims: keep user files and unrelated symlinks, but
	# delete links that still point into ~/.aidevops/agents/bin and no longer have a
	# matching deployed source.
	for existing in "$user_bin_dir"/*; do
		[[ -L "$existing" ]] || continue
		existing_target="$(readlink "$existing" 2>/dev/null || true)"
		case "$existing_target" in
			"${target_dir}/bin/"*)
				if [[ ! -e "$existing_target" ]]; then
					rm -f "$existing"
				fi
				;;
		esac
	done

	if [[ -d "${target_dir}/bin" ]]; then
		for shim in "${target_dir}/bin/"*; do
			[[ -f "$shim" ]] || continue
			shim_name="$(basename "$shim")"
			# These names are owned by the launchd installers. Replacing them
			# with routine wrappers makes setup and scheduler enablement alternate
			# the targets, which triggers repeat macOS background-item notices.
			case "$shim_name" in
			aidevops-auto-update | aidevops-repo-sync) continue ;;
			esac
			ln -sf "$shim" "${user_bin_dir}/${shim_name}"
		done
	fi
	return 0
}

# Deploy aidevops agents to ~/.aidevops/agents/
#
# Uses atomic swap: deploy to a temp directory first, then rename over the
# target. If the deploy fails mid-way, the old agents directory remains intact.
# This prevents the scripts/ directory from disappearing during partial deploys.
deploy_aidevops_agents() {
	local repo_dir="${REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
	local source_dir="${repo_dir}/.agents"
	local target_dir="${HOME}/.aidevops/agents"
	local staging_dir="${HOME}/.aidevops/.agents-staging-$$"

	if [[ ! -d "$source_dir" ]]; then
		echo "[deploy] ERROR: Source directory not found: $source_dir"
		return 1
	fi

	# Stage: copy to temp directory
	rm -rf "$staging_dir"
	mkdir -p "$staging_dir"

	if command -v rsync >/dev/null 2>&1; then
		# rsync preserves permissions, handles symlinks, and is resumable
		rsync -a --exclude '.git' --exclude '__pycache__' "$source_dir/" "$staging_dir/" || {
			echo "[deploy] ERROR: rsync failed — aborting (old agents preserved)"
			rm -rf "$staging_dir"
			return 1
		}
	else
		cp -R "$source_dir/." "$staging_dir/" || {
			echo "[deploy] ERROR: cp failed — aborting (old agents preserved)"
			rm -rf "$staging_dir"
			return 1
		}
	fi

	# Verify: critical files must exist in staging before swap
	local critical_files=(
		"scripts/pulse-wrapper.sh"
		"scripts/headless-runtime-helper.sh"
		"scripts/shared-constants.sh"
		"AGENTS.md"
	)
	local missing=0
	for f in "${critical_files[@]}"; do
		if [[ ! -f "${staging_dir}/${f}" ]]; then
			echo "[deploy] ERROR: Critical file missing from staging: ${f}"
			missing=1
		fi
	done
	if [[ "$missing" -eq 1 ]]; then
		echo "[deploy] ERROR: Staging verification failed — aborting (old agents preserved)"
		rm -rf "$staging_dir"
		return 1
	fi

	# Preserve user customizations that survive updates
	for preserve_dir in custom draft; do
		if [[ -d "${target_dir}/${preserve_dir}" ]]; then
			cp -R "${target_dir}/${preserve_dir}" "${staging_dir}/${preserve_dir}" 2>/dev/null || true
		fi
	done

	# Swap: atomic rename (same filesystem, so this is a single inode operation)
	local backup_dir="${HOME}/.aidevops/.agents-previous"
	rm -rf "$backup_dir"
	if [[ -d "$target_dir" ]]; then
		mv "$target_dir" "$backup_dir" || {
			echo "[deploy] ERROR: Failed to move old agents dir — aborting"
			rm -rf "$staging_dir"
			return 1
		}
	fi
	mv "$staging_dir" "$target_dir" || {
		echo "[deploy] ERROR: Failed to move staging to target — restoring backup"
		mv "$backup_dir" "$target_dir" 2>/dev/null || true
		return 1
	}

	# Set permissions on scripts and bin shims
	chmod +x "${target_dir}/scripts/"*.sh 2>/dev/null || true
	chmod +x "${target_dir}/bin/"* 2>/dev/null || true
	# t2685: sig-enforcing gh shim (no .sh extension so it's found as `gh` on PATH)
	[[ -f "${target_dir}/scripts/gh" ]] && chmod +x "${target_dir}/scripts/gh" 2>/dev/null || true

	# t2199: Symlink bin shims into ~/.aidevops/bin/ for PATH discoverability.
	# ~/.aidevops/bin/ is already on PATH (managed by setup.sh shell-env).
	_sync_agent_bin_shims "$target_dir"

	echo "[deploy] Deployed agents to ${target_dir} ($(find "$target_dir" -type f | wc -l | tr -d ' ') files)"
	return 0
}

# Deploy plugins to ~/.aidevops/agents/
deploy_plugins() {
	# TODO: Extract from setup.sh lines 3293-3391
	:
	return 0
}

# Generate agent skills from SKILL.md files
generate_agent_skills() {
	# TODO: Extract from setup.sh lines 3394-3410
	:
	return 0
}

# Create skill symlinks for imported skills
create_skill_symlinks() {
	# TODO: Extract from setup.sh lines 3413-3496
	:
	return 0
}

# Check for skill updates
check_skill_updates() {
	# TODO: Extract from setup.sh lines 3499-3581
	:
	return 0
}

# Scan imported skills
scan_imported_skills() {
	# TODO: Extract from setup.sh lines 3584-3658
	:
	return 0
}

# Sync agents from private repositories into custom/
sync_agent_sources() {
	local helper_script="${HOME}/.aidevops/agents/scripts/agent-sources-helper.sh"
	if [[ -f "${helper_script}" ]]; then
		echo "Syncing agent sources from private repositories..."
		bash "${helper_script}" sync
	else
		# Helper not deployed yet — will be available after first full setup
		:
	fi
	return 0
}

# Inject agents reference into AI assistant configs
inject_agents_reference() {
	# TODO: Extract from setup.sh lines 3661-3743
	:
	return 0
}

# Deploy AI templates
deploy_ai_templates() {
	# TODO: Extract from setup.sh lines 3023-3037
	:
	return 0
}

# Extract OpenCode prompts
extract_opencode_prompts() {
	# TODO: Extract from setup.sh lines 3041-3051
	:
	return 0
}

# Check OpenCode prompt drift
check_opencode_prompt_drift() {
	# TODO: Extract from setup.sh lines 3054-3073
	:
	return 0
}
