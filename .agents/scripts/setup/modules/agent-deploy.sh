#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Agent deployment functions: deploy_aidevops_agents, deploy_ai_templates, inject_agents_reference
# Part of aidevops setup.sh modularization (t316.3)
# Split from original agent-deploy.sh (t1940): runtime conversion → agent-runtime.sh, beads/hooks → tool-beads.sh

# Shell safety baseline
set -Eeuo pipefail
IFS=$'\n\t'

#######################################
# Reconcile Pulse only through the validated runtime bundle. The lifecycle
# helper serializes this operation with activation, re-resolves the active link
# under that lock, and honours the effective supervisor-enabled state.
#######################################
_restart_pulse_if_running() {
	local activated_root="$1"
	local managed_enabled="${2:-false}"
	local active_link="${3:-${HOME}/.aidevops/agents}"
	local pulse_helper="${activated_root}/scripts/pulse-lifecycle-helper.sh"

	if [[ ! -x "$pulse_helper" ]]; then
		print_warning "Pulse lifecycle helper is missing from the activated runtime bundle"
		return 1
	fi
	print_info "Reconciling Pulse with the activated runtime bundle"
	if ! AIDEVOPS_AGENTS_DIR="$activated_root" \
		AIDEVOPS_ACTIVE_AGENTS_LINK="$active_link" \
		AIDEVOPS_PULSE_MANAGED_ENABLED="$managed_enabled" \
		"$pulse_helper" reconcile-managed; then
		return 1
	fi
	return 0
}
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true

# Shared reference line injected into all runtime agent configs
readonly _AIDEVOPS_REFERENCE_LINE='Add ~/.aidevops/agents/AGENTS.md to context for AI DevOps capabilities.'

deploy_ai_templates() {
	print_info "Deploying AI assistant templates..."

	if [[ -f "templates/deploy-templates.sh" ]]; then
		if bash templates/deploy-templates.sh; then
			print_success "AI assistant templates deployed successfully"
		else
			print_warning "Template deployment encountered issues (non-critical)"
		fi
	else
		print_warning "Template deployment script not found - skipping"
	fi
	return 0
}

extract_opencode_prompts() {
	local extract_script="${INSTALL_DIR:-.}/.agents/scripts/extract-opencode-prompts.sh"
	if [[ -f "$extract_script" ]]; then
		if bash "$extract_script"; then
			print_success "OpenCode prompts extracted"
		else
			print_warning "OpenCode prompt extraction encountered issues (non-critical)"
		fi
	fi
	return 0
}

check_opencode_prompt_drift() {
	local drift_script="${INSTALL_DIR:-.}/.agents/scripts/opencode-prompt-drift-check.sh"
	if [[ -f "$drift_script" ]]; then
		local output exit_code=0
		# 2>/dev/null is intentional: --quiet mode suppresses expected output; all exit
		# codes (0=in-sync, 1=drift, other=error) are handled explicitly below.
		output=$(bash "$drift_script" --quiet 2>/dev/null) || exit_code=$?
		if [[ "$exit_code" -eq 1 && "$output" == PROMPT_DRIFT* ]]; then
			local local_hash upstream_hash
			local_hash=$(echo "$output" | cut -d'|' -f2)
			upstream_hash=$(echo "$output" | cut -d'|' -f3)
			print_warning "OpenCode upstream prompt has changed (${local_hash} → ${upstream_hash})"
			print_info "  Review: https://github.com/anomalyco/opencode/compare/${local_hash}...${upstream_hash}"
			print_info "  Update .agents/prompts/build.txt if needed"
		elif [[ "$exit_code" -eq 0 ]]; then
			print_success "OpenCode prompt in sync with upstream"
		else
			print_warning "Could not check prompt drift (network issue or missing dependency)"
		fi
	fi
	return 0
}

# _deploy_agents_copy source_dir target_dir [plugin_namespaces...]
# Copies agent files using rsync (preferred) or tar fallback.
# Returns 0 on success, 1 on failure.
_deploy_agents_copy() {
	local source_dir="$1"
	local target_dir="$2"
	shift 2

	local deploy_ok=false
	if command -v rsync &>/dev/null; then
		local -a rsync_excludes=("--exclude=loop-state/" "--exclude=custom/" "--exclude=draft/")
		for pns in "$@"; do
			rsync_excludes+=("--exclude=${pns}/")
		done
		local rsync_timeout="${AIDEVOPS_RSYNC_TIMEOUT:-120}"
		[[ "$rsync_timeout" =~ ^[0-9]+$ && "$rsync_timeout" -gt 0 ]] || rsync_timeout=120
		# GH#22086: bound rsync I/O stalls so setup.sh --non-interactive can
		# unwind via its EXIT trap instead of leaving a long-running setup owner
		# and stale setup-noninteractive.lock.d behind.
		if rsync -a --timeout="$rsync_timeout" "${rsync_excludes[@]}" "$source_dir/" "$target_dir/"; then
			deploy_ok=true
		fi
	else
		# Fallback: use tar with exclusions to match rsync behavior
		local -a tar_excludes=("--exclude=loop-state" "--exclude=custom" "--exclude=draft")
		for pns in "$@"; do
			tar_excludes+=("--exclude=$pns")
		done
		if (cd "$source_dir" && tar cf - "${tar_excludes[@]}" .) | (cd "$target_dir" && tar xf -); then
			deploy_ok=true
		fi
	fi

	if [[ "$deploy_ok" == "true" ]]; then
		return 0
	fi
	return 1
}

# _is_reserved_agent_namespace namespace
# Returns 0 when a plugin namespace collides with a core aidevops agents
# directory. Such namespaces must never be passed as rsync/tar excludes because
# excluding scripts/ from the canonical source can deploy an agents tree that
# passes the copy step but fails the post-swap scripts/ invariant.
_is_reserved_agent_namespace() {
	local namespace="$1"

	case "$namespace" in
	AGENTS.md | VERSION | advisories | commands | configs | custom | draft | hooks | plugins | prompts | reference | scripts | services | tools | workflows)
		return 0
		;;
	esac

	return 1
}

# _inject_plan_reminder target_dir
# Injects the extracted OpenCode plan-reminder into Plan+ if the placeholder is present.
_inject_plan_reminder() {
	local target_dir="$1"
	local plan_reminder="$HOME/.aidevops/cache/opencode-prompts/plan-reminder.txt"
	local plan_plus="$target_dir/plan-plus.md"
	if [[ ! -f "$plan_reminder" || ! -f "$plan_plus" ]]; then
		return 0
	fi
	if ! grep -q "OPENCODE-PLAN-REMINDER-INJECT" "$plan_plus"; then
		return 0
	fi
	local tmp_file in_placeholder
	tmp_file=$(mktemp)
	trap 'rm -f "${tmp_file:-}"' RETURN
	in_placeholder=false
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == *"OPENCODE-PLAN-REMINDER-INJECT-START"* ]]; then
			echo "$line" >>"$tmp_file"
			cat "$plan_reminder" >>"$tmp_file"
			in_placeholder=true
		elif [[ "$line" == *"OPENCODE-PLAN-REMINDER-INJECT-END"* ]]; then
			echo "$line" >>"$tmp_file"
			in_placeholder=false
		elif [[ "$in_placeholder" == false ]]; then
			echo "$line" >>"$tmp_file"
		fi
	done <"$plan_plus"
	mv "$tmp_file" "$plan_plus"
	print_info "Injected OpenCode plan-reminder into Plan+"
	return 0
}

# _set_script_permissions_and_report target_dir
# Sets execute permissions on all deployed scripts and reports deployed counts.
_set_script_permissions_and_report() {
	local target_dir="$1"

	chmod +x "$target_dir/scripts/"*.sh 2>/dev/null || true
	find "$target_dir/scripts" -mindepth 2 -name "*.sh" -exec chmod +x {} + 2>/dev/null || true

	local agent_count script_count
	agent_count=$(find "$target_dir" -name "*.md" -type f | wc -l | tr -d ' ')
	script_count=$(find "$target_dir/scripts" -name "*.sh" -type f 2>/dev/null | wc -l | tr -d ' ')
	print_info "Deployed $agent_count agent files and $script_count scripts"
	return 0
}

# _count_deployed_agent_files target_dir
# Prints the number of files in the deployed agents tree. Non-numeric output is
# normalised to 0 so deploy verification never compares an empty string.
_count_deployed_agent_files() {
	local target_dir="$1"
	local file_count="0"
	if [[ -d "$target_dir" ]]; then
		# Runtime bundle activation makes ~/.aidevops/agents an atomic symlink.
		# GNU/BSD find do not traverse a command-line symlink unless -L is set,
		# so the old count returned zero immediately after a successful activation
		# and rolled the deployment back to the previous bundle.
		file_count=$(find -L "$target_dir" -type f 2>/dev/null | wc -l | tr -d '[:space:]')
	fi
	[[ "$file_count" =~ ^[0-9]+$ ]] || file_count=0
	printf '%s\n' "$file_count"
	return 0
}

# _restore_latest_agents_backup target_dir
# Restores the newest agents backup after a failed deploy verification. Backups
# are created by create_backup_with_rotation as ~/.aidevops/agents-backups/<ts>/agents.
_restore_latest_agents_backup() {
	local target_dir="$1"
	local backup_base="$HOME/.aidevops/agents-backups"
	local latest_backup=""
	local parent_dir=""
	local restore_staging=""
	local old_dir=""

	if [[ ! -d "$backup_base" ]]; then
		print_warning "No agents backup directory found for restore: $backup_base"
		return 1
	fi

	latest_backup=$(find "$backup_base" -maxdepth 2 -type d -name agents 2>/dev/null | sort | tail -n 1)
	if [[ -z "$latest_backup" || ! -d "$latest_backup" ]]; then
		print_warning "No restorable agents backup found under $backup_base"
		return 1
	fi

	print_warning "Restoring agents from latest backup: $latest_backup"
	parent_dir=$(dirname "$target_dir")
	mkdir -p "$parent_dir"
	restore_staging=$(mktemp -d "${target_dir}.restore.XXXXXX") || {
		print_error "Failed to create agents restore staging directory"
		return 1
	}
	old_dir="${target_dir}.restore-old.$$"
	rm -rf "$old_dir"

	if ! cp -a "$latest_backup/." "$restore_staging/"; then
		print_error "Failed to stage agents backup for restore: $latest_backup"
		rm -rf "$restore_staging"
		return 1
	fi

	if [[ -d "$target_dir" ]]; then
		if ! mv "$target_dir" "$old_dir"; then
			print_error "Failed to move current agents directory aside during restore — agents directory preserved"
			rm -rf "$restore_staging"
			return 1
		fi
	fi

	if mv "$restore_staging" "$target_dir"; then
		rm -rf "$old_dir"
		print_success "Restored agents directory from backup"
		return 0
	fi

	print_error "Failed to move staged agents backup into place — attempting restore rollback"
	if [[ -d "$old_dir" ]]; then
		if mv "$old_dir" "$target_dir"; then
			print_info "Restore rollback successful — previous agents directory restored"
		else
			print_error "Restore rollback failed — previous agents directory preserved in $old_dir"
		fi
	fi
	rm -rf "$restore_staging"
	return 1
}

# _verify_deployed_agents_tree target_dir
# Verifies the deployed agents tree is plausibly complete before .deployed-sha is
# written. This catches empty/partial deploys that would otherwise suppress the
# next auto-update retry by stamping the new SHA.
_verify_deployed_agents_tree() {
	local target_dir="$1"
	local min_files="${AIDEVOPS_AGENT_DEPLOY_MIN_FILES:-100}"
	local file_count="0"

	[[ "$min_files" =~ ^[0-9]+$ ]] || min_files=100

	if [[ ! -d "$target_dir/scripts" ]]; then
		print_error "Deploy verification failed: $target_dir/scripts missing after swap"
		return 1
	fi

	file_count=$(_count_deployed_agent_files "$target_dir")
	if [[ "$file_count" -lt "$min_files" ]]; then
		print_error "Deploy verification failed: $target_dir has $file_count files (< $min_files)"
		return 1
	fi

	return 0
}

# _verify_deployed_core_plugin_freshness source_dir target_dir
# Verifies core plugin files that are runtime-critical copied byte-for-byte from
# the canonical agents tree before .deployed-sha is written. This catches stale
# plugin deploys where setup reports success and advances the stamp while OpenCode
# still loads an older deployed plugin file.
_verify_deployed_core_plugin_freshness() {
	local source_dir="$1"
	local target_dir="$2"
	local rel_path
	local source_file
	local target_file
	local -a core_plugin_files=(
		"hooks/git_safety_guard.py"
		"plugins/opencode-aidevops/model-limits.mjs"
		"plugins/opencode-aidevops/quality-hooks-git-safety.mjs"
		"plugins/opencode-aidevops/quality-hooks.mjs"
		"scripts/canonical_branch_policy.py"
		"scripts/canonical-write-policy-helper.py"
	)

	for rel_path in "${core_plugin_files[@]}"; do
		source_file="$source_dir/$rel_path"
		target_file="$target_dir/$rel_path"

		if [[ ! -f "$source_file" ]]; then
			continue
		fi
		if [[ ! -f "$target_file" ]]; then
			print_error "Deploy verification failed: $target_file missing after swap"
			return 1
		fi
		if ! cmp -s "$source_file" "$target_file"; then
			print_error "Deploy verification failed: $target_file is stale versus $source_file"
			return 1
		fi
	done

	return 0
}

# _verify_opencode_plugin_deps plugin_dir
# Imports both runtime dependencies with a JavaScript runtime before a bundle is
# eligible for activation. Prefer Bun because OpenCode embeds Bun; use Node when
# the standalone Bun CLI is unavailable.
_verify_opencode_plugin_deps() {
	local plugin_dir="$1"
	local js_runtime=""

	if command -v bun >/dev/null 2>&1; then
		js_runtime="bun"
	elif command -v node >/dev/null 2>&1; then
		js_runtime="node"
	else
		printf 'Neither bun nor node is available for plugin dependency verification\n' >&2
		return 1
	fi

	if (
		cd "$plugin_dir" || exit 1
		"$js_runtime" -e 'Promise.all([import("@bufbuild/protobuf"), import("@opencode-ai/plugin")]).then(([, plugin]) => { if (!plugin.tool || !plugin.tool.schema) throw new Error("@opencode-ai/plugin does not export tool.schema"); }).catch((error) => { console.error(error.message); process.exit(1); })'
	); then
		return 0
	fi
	return 1
}

# _install_opencode_plugin_deps target_dir
# Installs and verifies node_modules for the opencode-aidevops plugin.
# GH#17829: @bufbuild/protobuf was missing; GH#17891: only symlink on first run.
# Uses --omit=peer to skip the 630MB opencode-ai peer dep (the host app).
# GH#27714: installation or import failure must block bundle activation.
_install_opencode_plugin_deps() {
	local target_dir="$1"
	local oc_node_modules="$HOME/.config/opencode/node_modules"
	local plugin_dir="$target_dir/plugins/opencode-aidevops"
	local install_log=""
	local verify_output=""

	if [[ ! -d "$plugin_dir" ]]; then
		return 0
	fi

	# Only symlink if node_modules doesn't exist at all (first run)
	if [[ ! -e "$plugin_dir/node_modules" ]]; then
		if [[ -d "$oc_node_modules" ]]; then
			ln -sf "$oc_node_modules" "$plugin_dir/node_modules" 2>/dev/null || true
		fi
	fi

	if verify_output=$(_verify_opencode_plugin_deps "$plugin_dir" 2>&1); then
		return 0
	fi

	if ! command -v npm >/dev/null 2>&1; then
		print_error "Plugin dependencies are unavailable and npm is not installed: ${verify_output:-import failed}"
		return 1
	fi

	# Remove the shared symlink so npm installs the declared versions locally.
	[[ -L "$plugin_dir/node_modules" ]] && rm "$plugin_dir/node_modules"
	install_log=$(mktemp "${TMPDIR:-/tmp}/aidevops-plugin-install.XXXXXX") || {
		print_error "Failed to create the plugin dependency install log"
		return 1
	}
	if ! npm install --omit=dev --omit=peer --prefix "$plugin_dir" >"$install_log" 2>&1; then
		print_error "Failed to install OpenCode plugin dependencies; runtime bundle activation blocked"
		tail -n 12 "$install_log" >&2
		rm -f "$install_log"
		return 1
	fi
	rm -f "$install_log"

	if ! verify_output=$(_verify_opencode_plugin_deps "$plugin_dir" 2>&1); then
		print_error "OpenCode plugin dependency verification failed after install: ${verify_output:-import failed}"
		return 1
	fi
	return 0
}

# _atomic_stage_and_deploy_agents source_dir target_dir [plugin_namespaces...]
# Stages a copy in a per-process target_dir.staging.* directory, carries over
# preserved dirs (custom/, draft/, and any plugin namespaces), then atomically
# swaps staging into place.
# Returns 0 on success, 1 on failure.
_atomic_stage_and_deploy_agents() {
	local source_dir="$1"
	local target_dir="$2"
	shift 2
	local -a plugin_namespaces=("$@")

	# Atomic deploy: build a staging directory, then swap it into place.
	# Previously, clean + copy happened in-place, creating a window where
	# scripts were missing. The pulse could dispatch workers mid-deploy,
	# hitting "No such file or directory" errors. Now we:
	#   1. rsync into a unique staging dir (target_dir.staging.*)
	#   2. Move preserved dirs (custom/, draft/, plugins) from live to staging
	#   3. mv live → .old.*, mv staging → live (atomic on same filesystem)
	#   4. rm .old.*
	#
	# GH#22063: the staging/backup paths must be unique per setup process. Fixed
	# names such as target_dir.staging let a concurrent setup cleanup remove the
	# directory while rsync is still writing into it, producing renameat/move_file
	# ENOENT failures even though the canonical .agents/ source is valid.
	local staging_dir old_dir
	staging_dir=$(mktemp -d "${target_dir}.staging.XXXXXX") || {
		print_error "Failed to create agents staging directory"
		return 1
	}
	old_dir="${target_dir}.old.$$"
	rm -rf "$old_dir"

	# Copy source into staging
	local copy_rc
	if [[ ${#plugin_namespaces[@]} -gt 0 ]]; then
		_deploy_agents_copy "$source_dir" "$staging_dir" "${plugin_namespaces[@]}"
		copy_rc=$?
	else
		_deploy_agents_copy "$source_dir" "$staging_dir"
		copy_rc=$?
	fi
	if [[ "$copy_rc" -ne 0 ]]; then
		print_error "Failed to deploy agents to staging directory"
		rm -rf "$staging_dir"
		return 1
	fi

	# Carry over preserved directories from live target to staging
	local -a preserved_dirs=("custom" "draft")
	if [[ ${#plugin_namespaces[@]} -gt 0 ]]; then
		for pns in "${plugin_namespaces[@]}"; do
			preserved_dirs+=("$pns")
		done
	fi
	for pdir in "${preserved_dirs[@]}"; do
		if [[ -d "$target_dir/$pdir" ]]; then
			# Copy user dirs into staging so they survive the swap
			cp -a "$target_dir/$pdir" "$staging_dir/$pdir" 2>/dev/null || true
		fi
	done

	# Atomic swap: mv is atomic on the same filesystem (POSIX rename()).
	# IMPORTANT: explicit error checks are REQUIRED here because this function
	# is called via `|| return 1` which disables set -e inside the function
	# body (bash set -e semantics: disabled in any function called as part of
	# a compound list such as `fn || ...`). Without these checks, a failed mv
	# falls through silently, the backup is deleted, and the function returns
	# 0 with $target_dir absent — the root cause of GH#22014 where worktree
	# setup left ~/.aidevops/agents missing while reporting [SETUP_COMPLETE].
	if [[ -d "$target_dir" ]]; then
		if ! mv "$target_dir" "$old_dir"; then
			print_error "Failed to move live agents to backup ($old_dir) — agents directory preserved"
			rm -rf "$staging_dir"
			return 1
		fi
	fi
	if ! mv "$staging_dir" "$target_dir"; then
		print_error "Failed to move staging to live agents directory — attempting rollback"
		# Restore the previous agents dir from backup so the system stays functional.
		if [[ -d "$old_dir" ]]; then
			if mv "$old_dir" "$target_dir"; then
				print_info "Rollback successful — previous agents directory restored"
			else
				print_error "Rollback failed — agents directory is missing! Previous state preserved in $old_dir"
			fi
		fi
		rm -rf "$staging_dir"
		return 1
	fi
	rm -rf "$old_dir"
	return 0
}

# Runtime bundles keep every executable part of one framework revision under an
# immutable directory. ~/.aidevops/agents is only the atomic activation link.
_AIDEVOPS_STAGED_BUNDLE_DIR=""
_AIDEVOPS_PREVIOUS_BUNDLE_ROOT=""
[[ -z "${_AIDEVOPS_BUNDLE_UNKNOWN+x}" ]] && _AIDEVOPS_BUNDLE_UNKNOWN="unknown"

_runtime_bundle_sha256_file() {
	local file="$1"
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$file" | cut -d' ' -f1
	elif command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$file" | cut -d' ' -f1
	else
		openssl dgst -sha256 "$file" | sed 's/^.*= //'
	fi
	return 0
}

_runtime_bundle_resolve_root() {
	local agents_path="$1"
	[[ -d "$agents_path" ]] || return 1
	(cd "$agents_path" && pwd -P) || return 1
	return 0
}

_runtime_bundle_copy_preserved_dirs() {
	local current_root="$1"
	local candidate_root="$2"
	shift 2
	local preserved_dir=""
	local -a preserved_dirs=("custom" "draft" "$@")

	for preserved_dir in "${preserved_dirs[@]}"; do
		[[ -n "$preserved_dir" && -d "$current_root/$preserved_dir" ]] || continue
		rm -rf "${candidate_root:?}/$preserved_dir"
		cp -a "$current_root/$preserved_dir" "$candidate_root/$preserved_dir" || return 1
	done
	return 0
}

# Move the user-owned plist override out of the replaceable runtime bundle.
# The no-clobber hard link makes concurrent setup runs converge without
# overwriting an existing stable config. No file contents are logged.
_runtime_bundle_migrate_plist_env_overrides() {
	local current_root="$1"
	local legacy_file="$current_root/configs/plist-env-overrides.json"
	local config_dir="$HOME/.config/aidevops"
	local stable_file="$config_dir/plist-env-overrides.json"
	local migration_tmp=""

	[[ -f "$stable_file" || ! -f "$legacy_file" ]] && return 0
	mkdir -p "$config_dir" || return 1
	migration_tmp=$(mktemp "$config_dir/.plist-env-overrides.json.XXXXXX") || return 1
	if ! cp "$legacy_file" "$migration_tmp" || ! chmod 600 "$migration_tmp"; then
		rm -f "$migration_tmp"
		return 1
	fi
	if ! ln "$migration_tmp" "$stable_file" 2>/dev/null && [[ ! -f "$stable_file" ]]; then
		rm -f "$migration_tmp"
		return 1
	fi
	rm -f "$migration_tmp"
	print_info "  Migrated plist environment overrides to ~/.config/aidevops/plist-env-overrides.json"
	return 0
}

_runtime_bundle_write_manifest() {
	local bundle_dir="$1"
	local repo_dir="$2"
	local plugins_file="$3"
	local agents_root="$bundle_dir/agents"
	local manifest_tmp="$bundle_dir/manifest.tmp"
	local framework_version="$_AIDEVOPS_BUNDLE_UNKNOWN"
	local git_sha="$_AIDEVOPS_BUNDLE_UNKNOWN"
	local file_count="0"
	local cli_sha="missing"
	local plugin_entry_sha="missing"
	local manifest_bundle_id="${bundle_dir##*/}"
	manifest_bundle_id="${manifest_bundle_id#.staging.}"

	[[ -r "$agents_root/VERSION" ]] && IFS= read -r framework_version <"$agents_root/VERSION"
	git_sha=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || printf '%s' "$_AIDEVOPS_BUNDLE_UNKNOWN")
	file_count=$(_count_deployed_agent_files "$agents_root")
	[[ -f "$agents_root/aidevops.sh" ]] && cli_sha=$(_runtime_bundle_sha256_file "$agents_root/aidevops.sh")
	if [[ -f "$agents_root/plugins/opencode-aidevops/index.mjs" ]]; then
		plugin_entry_sha=$(_runtime_bundle_sha256_file "$agents_root/plugins/opencode-aidevops/index.mjs")
	fi

	{
		printf 'schema=1\n'
		printf 'status=validated\n'
		printf 'bundle_id=%s\n' "$manifest_bundle_id"
		printf 'framework_version=%s\n' "$framework_version"
		printf 'cli_compatibility=%s\n' "$framework_version"
		printf 'git_sha=%s\n' "$git_sha"
		printf 'agents_file_count=%s\n' "$file_count"
		printf 'cli_sha256=%s\n' "$cli_sha"
		printf 'plugin_entry_sha256=%s\n' "$plugin_entry_sha"
		if declare -F runtime_bundle_plugin_manifest_fields >/dev/null 2>&1; then
			runtime_bundle_plugin_manifest_fields "$agents_root" "$plugins_file"
		else
			printf 'plugin_registry_sha256=unavailable\n'
		fi
	} >"$manifest_tmp" || return 1
	mv "$manifest_tmp" "$bundle_dir/manifest" || return 1
	cp "$bundle_dir/manifest" "$agents_root/.bundle-manifest" || return 1
	return 0
}

_runtime_bundle_manifest_value() {
	local manifest_file="$1"
	local key="$2"
	local line=""

	[[ -r "$manifest_file" ]] || return 1
	while IFS= read -r line || [[ -n "$line" ]]; do
		case "$line" in
		"${key}="*)
			printf '%s' "${line#*=}"
			return 0
			;;
		esac
	done <"$manifest_file"
	return 1
}

_runtime_bundle_compare_versions() {
	local left="$1"
	local right="$2"
	local left_major="" left_minor="" left_patch=""
	local right_major="" right_minor="" right_patch=""

	left="${left#v}"
	right="${right#v}"
	[[ "$left" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	[[ "$right" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
	IFS='.' read -r left_major left_minor left_patch <<<"$left"
	IFS='.' read -r right_major right_minor right_patch <<<"$right"

	if ((10#$left_major < 10#$right_major)); then
		printf '%s' '-1'
		return 0
	fi
	if ((10#$left_major > 10#$right_major)); then
		printf '%s' '1'
		return 0
	fi
	if ((10#$left_minor < 10#$right_minor)); then
		printf '%s' '-1'
		return 0
	fi
	if ((10#$left_minor > 10#$right_minor)); then
		printf '%s' '1'
		return 0
	fi
	if ((10#$left_patch < 10#$right_patch)); then
		printf '%s' '-1'
		return 0
	fi
	if ((10#$left_patch > 10#$right_patch)); then
		printf '%s' '1'
		return 0
	fi
	printf '%s' '0'
	return 0
}

# Print a reason when setup is attempting to activate a candidate that is older
# than the active global runtime. Missing comparison evidence intentionally
# prints nothing. Explicit rollback tooling uses its own audited link transition
# and does not route through setup activation.
_runtime_bundle_stale_candidate_reason() {
	local bundle_dir="$1"
	local active_root="$2"
	local candidate_manifest="$bundle_dir/manifest"
	local active_manifest="$active_root/.bundle-manifest"
	local candidate_version="" active_version="" version_relation=""
	local candidate_sha="" active_sha=""
	local repo_dir="${INSTALL_DIR:-}"

	candidate_version=$(_runtime_bundle_manifest_value "$candidate_manifest" framework_version 2>/dev/null || :)
	active_version=$(_runtime_bundle_manifest_value "$active_manifest" framework_version 2>/dev/null || :)
	if [[ -n "$candidate_version" && -n "$active_version" ]]; then
		version_relation=$(_runtime_bundle_compare_versions "$candidate_version" "$active_version" 2>/dev/null || :)
		if [[ "$version_relation" == "-1" ]]; then
			printf 'candidate version %s is older than active version %s' "$candidate_version" "$active_version"
			return 0
		fi
	fi

	candidate_sha=$(_runtime_bundle_manifest_value "$candidate_manifest" git_sha 2>/dev/null || :)
	active_sha=$(_runtime_bundle_manifest_value "$active_manifest" git_sha 2>/dev/null || :)
	[[ -n "$repo_dir" && "$candidate_sha" != "$active_sha" ]] || return 0
	[[ "$candidate_sha" =~ ^[0-9a-fA-F]{7,64}$ ]] || return 0
	[[ "$active_sha" =~ ^[0-9a-fA-F]{7,64}$ ]] || return 0
	git -C "$repo_dir" cat-file -e "${candidate_sha}^{commit}" 2>/dev/null || return 0
	git -C "$repo_dir" cat-file -e "${active_sha}^{commit}" 2>/dev/null || return 0
	if git -C "$repo_dir" merge-base --is-ancestor "$candidate_sha" "$active_sha" 2>/dev/null; then
		printf 'candidate source %.12s is an ancestor of active source %.12s' "$candidate_sha" "$active_sha"
	fi
	return 0
}

_runtime_bundle_validate() {
	local bundle_dir="$1"
	local source_dir="$2"
	local agents_root="$bundle_dir/agents"
	local repo_version=""
	local bundle_version=""

	_verify_deployed_agents_tree "$agents_root" || return 1
	_verify_deployed_core_plugin_freshness "$source_dir" "$agents_root" || return 1
	[[ -x "$agents_root/aidevops.sh" && -r "$bundle_dir/manifest" ]] || return 1
	grep -q '^status=validated$' "$bundle_dir/manifest" || return 1
	if [[ -r "${INSTALL_DIR:-}/VERSION" ]]; then
		IFS= read -r repo_version <"${INSTALL_DIR}/VERSION" || repo_version=""
		IFS= read -r bundle_version <"$agents_root/VERSION" || bundle_version=""
		[[ -n "$repo_version" && "$repo_version" == "$bundle_version" ]] || return 1
	fi
	return 0
}

_runtime_bundle_stage() {
	local repo_dir="$1"
	local source_dir="$2"
	local target_dir="$3"
	local plugins_file="$4"
	shift 4
	local bundles_dir="${target_dir%/*}/runtime-bundles"
	local bundle_dir=""
	local current_root=""
	local version="$_AIDEVOPS_BUNDLE_UNKNOWN"
	local git_sha="$_AIDEVOPS_BUNDLE_UNKNOWN"
	local bundle_id=""

	mkdir -p "$bundles_dir" || return 1
	[[ -r "$repo_dir/VERSION" ]] && IFS= read -r version <"$repo_dir/VERSION"
	git_sha=$(git -C "$repo_dir" rev-parse --short=12 HEAD 2>/dev/null || printf '%s' "$_AIDEVOPS_BUNDLE_UNKNOWN")
	bundle_id="${version//[^A-Za-z0-9._-]/_}-${git_sha}-$(date +%s)-$$"
	bundle_dir=$(mktemp -d "$bundles_dir/.staging.${bundle_id}.XXXXXX") || return 1
	mkdir -p "$bundle_dir/agents" || return 1
	if current_root=$(_runtime_bundle_resolve_root "$target_dir" 2>/dev/null); then
		_runtime_bundle_migrate_plist_env_overrides "$current_root" || {
			rm -rf "$bundle_dir"
			return 1
		}
	fi

	if ! _deploy_agents_copy "$source_dir" "$bundle_dir/agents" "$@"; then
		rm -rf "$bundle_dir"
		return 1
	fi
	if [[ -n "$current_root" ]]; then
		_runtime_bundle_copy_preserved_dirs "$current_root" "$bundle_dir/agents" "$@" || {
			rm -rf "$bundle_dir"
			return 1
		}
	fi
	if [[ "${AIDEVOPS_BUNDLE_FAIL_AT:-}" == "after-stage-copy" ]]; then
		rm -rf "$bundle_dir"
		return 1
	fi

	_deploy_agents_post_copy "$bundle_dir/agents" "$repo_dir" "$source_dir" "$plugins_file" || {
		rm -rf "$bundle_dir"
		return 1
	}
	install -m 0755 "$repo_dir/aidevops.sh" "$bundle_dir/agents/aidevops.sh" || {
		rm -rf "$bundle_dir"
		return 1
	}
	if [[ "${AIDEVOPS_BUNDLE_FAIL_AT:-}" == "after-plugin-generation" ]]; then
		rm -rf "$bundle_dir"
		return 1
	fi

	_runtime_bundle_write_manifest "$bundle_dir" "$repo_dir" "$plugins_file" || {
		rm -rf "$bundle_dir"
		return 1
	}
	_runtime_bundle_validate "$bundle_dir" "$source_dir" || {
		rm -rf "$bundle_dir"
		return 1
	}
	if [[ "${AIDEVOPS_BUNDLE_FAIL_AT:-}" == "before-activation" ]]; then
		rm -rf "$bundle_dir"
		return 1
	fi

	bundle_id="${bundle_dir##*/}"
	bundle_id="${bundle_id#.staging.}"
	local final_dir="$bundles_dir/${bundle_id}"
	mv "$bundle_dir" "$final_dir" || {
		rm -rf "$bundle_dir"
		return 1
	}
	_AIDEVOPS_STAGED_BUNDLE_DIR="$final_dir"
	return 0
}

_runtime_bundle_replace_link() {
	local link_tmp="$1"
	local link_path="$2"
	if [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]]; then
		mv -f -h "$link_tmp" "$link_path"
	else
		mv -Tf "$link_tmp" "$link_path"
	fi
	return $?
}

_runtime_bundle_switch_link() {
	local target_dir="$1"
	local agents_root="$2"
	local link_tmp="${target_dir}.link.$$"
	rm -f "$link_tmp"
	ln -s "$agents_root" "$link_tmp" || return 1
	if ! _runtime_bundle_replace_link "$link_tmp" "$target_dir"; then
		rm -f "$link_tmp"
		return 1
	fi
	return 0
}

_runtime_bundle_size_bytes() {
	local bundle_dir="$1"
	local size_kib=""
	size_kib=$(LC_ALL=C du -sk "$bundle_dir" 2>/dev/null | cut -f1) || return 1
	case "$size_kib" in
	'' | *[!0-9]*) return 1 ;;
	esac
	printf '%s' "$((size_kib * 1024))"
	return 0
}

_runtime_bundle_has_live_lease() {
	local lease_dir="$1"
	local lease_file=""
	local lease_pid=""
	local has_live_lease=false
	[[ -d "$lease_dir" ]] || return 1
	for lease_file in "$lease_dir"/*; do
		[[ -f "$lease_file" ]] || continue
		lease_pid="${lease_file##*/}"
		case "$lease_pid" in
		'' | *[!0-9]*) rm -f "$lease_file" ;;
		*)
			# kill -0 can report EPERM for a live process owned by another user.
			if kill -0 "$lease_pid" 2>/dev/null || [[ -d "/proc/$lease_pid" ]] || ps -p "$lease_pid" >/dev/null 2>&1; then
				has_live_lease=true
			else
				rm -f "$lease_file"
			fi
			;;
		esac
	done
	rmdir "$lease_dir" 2>/dev/null || true
	[[ "$has_live_lease" == "true" ]]
}

_runtime_bundle_numeric_limit() {
	local value="$1"
	local fallback="$2"
	case "$value" in
	'' | *[!0-9]*) printf '%s' "$fallback" ;;
	*) printf '%s' "$value" ;;
	esac
	return 0
}

_runtime_bundle_prune() {
	local bundles_dir="$1"
	local active_root="$2"
	local previous_root="$3"
	local candidate_dir=""
	local candidate_agents_root=""
	local bundle_id=""
	local retention_seconds=""
	local max_count=""
	local max_bytes=""
	local now=""
	local modified=""
	local bundle_bytes=""
	local candidate_rows=""
	local pinned_root=""
	local pin_rc=0
	local total_count=0
	local total_bytes=0
	local bytes_known=1
	local should_remove=0

	retention_seconds=$(_runtime_bundle_numeric_limit "${AIDEVOPS_RUNTIME_BUNDLE_RETENTION_SECONDS:-2592000}" 2592000)
	max_count=$(_runtime_bundle_numeric_limit "${AIDEVOPS_RUNTIME_BUNDLE_MAX_COUNT:-30}" 30)
	max_bytes=$(_runtime_bundle_numeric_limit "${AIDEVOPS_RUNTIME_BUNDLE_MAX_BYTES:-8589934592}" 8589934592)
	now=$(date +%s) || return 1
	if declare -F pulse_runtime_pin_resolve >/dev/null 2>&1; then
		pinned_root=$(pulse_runtime_pin_resolve 2>/dev/null) || pin_rc=$?
		case "$pin_rc" in
		0 | 1 | 3) ;;
		*)
			print_warning "Skipping runtime bundle pruning because the Pulse runtime pin is invalid"
			return 0
			;;
		esac
	fi

	for candidate_dir in "$bundles_dir"/*; do
		[[ -d "$candidate_dir/agents" ]] || continue
		candidate_agents_root=$(cd "$candidate_dir/agents" 2>/dev/null && pwd -P) || continue
		total_count=$((total_count + 1))
		if bundle_bytes=$(_runtime_bundle_size_bytes "$candidate_dir"); then
			total_bytes=$((total_bytes + bundle_bytes))
		else
			bundle_bytes=0
			bytes_known=0
		fi
		[[ "$candidate_agents_root" == "$active_root" || "$candidate_agents_root" == "$previous_root" || "$candidate_agents_root" == "$pinned_root" ]] && continue
		bundle_id="${candidate_dir##*/}"
		if _runtime_bundle_has_live_lease "$bundles_dir/.leases/$bundle_id"; then
			continue
		fi
		modified=$(_file_mtime_epoch "$candidate_dir")
		candidate_rows+="${modified}"$'\t'"${bundle_bytes}"$'\t'"${candidate_dir}"$'\n'
	done

	while IFS=$'\t' read -r modified bundle_bytes candidate_dir; do
		[[ -n "$candidate_dir" ]] || continue
		should_remove=0
		if [[ $((now - modified)) -ge "$retention_seconds" ]] || [[ "$total_count" -gt "$max_count" ]]; then
			should_remove=1
		elif [[ "$bytes_known" -eq 1 && "$total_bytes" -gt "$max_bytes" ]]; then
			should_remove=1
		fi
		[[ "$should_remove" -eq 1 ]] || continue
		rm -rf "$candidate_dir" || return 1
		total_count=$((total_count - 1))
		total_bytes=$((total_bytes - bundle_bytes))
	done < <(printf '%s' "$candidate_rows" | LC_ALL=C sort -n -k1,1)
	rmdir "$bundles_dir/.leases" 2>/dev/null || true
	return 0
}

_runtime_bundle_activate_locked() {
	local target_dir="$1"
	local bundle_dir="$2"
	local agents_root=""
	local bundles_dir=""
	local parent_dir="${target_dir%/*}"
	local previous_link="$parent_dir/previous-runtime-bundle"
	local previous_root=""
	local legacy_dir=""
	local stale_reason=""
	agents_root=$(_runtime_bundle_resolve_root "$bundle_dir/agents") || return 1
	bundles_dir=$(cd "${bundle_dir%/*}" && pwd -P) || return 1

	if previous_root=$(_runtime_bundle_resolve_root "$target_dir" 2>/dev/null); then
		stale_reason=$(_runtime_bundle_stale_candidate_reason "$bundle_dir" "$previous_root")
		if [[ -n "$stale_reason" ]]; then
			print_error "Refusing stale runtime bundle activation: ${stale_reason}. Use a dedicated audited rollback operation instead of setup."
			return 1
		fi
		_AIDEVOPS_PREVIOUS_BUNDLE_ROOT="$previous_root"
	fi
	if [[ -d "$target_dir" && ! -L "$target_dir" ]]; then
		legacy_dir="${bundle_dir%/*}/legacy-$(date +%s)-$$"
		mkdir -p "$legacy_dir" || return 1
		mv "$target_dir" "$legacy_dir/agents" || return 1
		previous_root=$(_runtime_bundle_resolve_root "$legacy_dir/agents") || return 1
		_AIDEVOPS_PREVIOUS_BUNDLE_ROOT="$previous_root"
	fi

	if ! _runtime_bundle_switch_link "$target_dir" "$agents_root"; then
		if [[ -n "$previous_root" ]]; then
			_runtime_bundle_switch_link "$target_dir" "$previous_root" || true
		fi
		return 1
	fi
	if [[ -n "$previous_root" ]]; then
		local previous_tmp="${previous_link}.tmp.$$"
		rm -f "$previous_tmp"
		ln -s "$previous_root" "$previous_tmp" && _runtime_bundle_replace_link "$previous_tmp" "$previous_link" || rm -f "$previous_tmp"
	fi

	if [[ "${AIDEVOPS_BUNDLE_FAIL_AT:-}" == "after-activation" ]] ||
		[[ "$(_runtime_bundle_resolve_root "$target_dir" 2>/dev/null || true)" != "$agents_root" ]]; then
		if [[ -n "$previous_root" ]]; then
			_runtime_bundle_switch_link "$target_dir" "$previous_root" || return 1
		else
			rm -f "$target_dir"
		fi
		return 1
	fi

	_AIDEVOPS_ACTIVE_BUNDLE_ROOT="$agents_root"
	_runtime_bundle_prune "$bundles_dir" "$agents_root" "$previous_root"
	return 0
}

_runtime_bundle_activate() {
	local target_dir="$1"
	local bundle_dir="$2"
	local activate_rc=0
	_AIDEVOPS_ACTIVE_BUNDLE_ROOT=""

	if ! aidevops_runtime_transition_lock_acquire; then
		print_error "Unable to acquire the runtime activation lock"
		return 1
	fi
	_runtime_bundle_activate_locked "$target_dir" "$bundle_dir" || activate_rc=$?
	aidevops_runtime_transition_lock_release
	[[ "$activate_rc" -eq 0 ]] || return "$activate_rc"
	return 0
}

# _deploy_version_file target_dir repo_dir
# Copies VERSION file from repo root to the deployed agents directory.
_deploy_version_file() {
	local target_dir="$1"
	local repo_dir="$2"

	if [[ -f "$repo_dir/VERSION" ]]; then
		if cp "$repo_dir/VERSION" "$target_dir/VERSION"; then
			print_info "Copied VERSION file to deployed agents"
		else
			print_warning "Failed to copy VERSION file (Plan+ may not read version correctly)"
		fi
	else
		print_warning "VERSION file not found in repo root"
	fi
	return 0
}

# _deploy_security_advisories_files source_dir
# Copies *.advisory files to ~/.aidevops/advisories/ (shown in session greeting).
_deploy_security_advisories_files() {
	local source_dir="$1"
	local advisories_source="$source_dir/advisories"
	local advisories_target="$HOME/.aidevops/advisories"

	if [[ ! -d "$advisories_source" ]]; then
		return 0
	fi
	mkdir -p "$advisories_target"
	local adv_count=0
	for adv_file in "$advisories_source"/*.advisory; do
		[[ -f "$adv_file" ]] || continue
		cp "$adv_file" "$advisories_target/"
		adv_count=$((adv_count + 1))
	done
	if [[ "$adv_count" -gt 0 ]]; then
		print_info "Deployed $adv_count security advisory/advisories"
	fi
	return 0
}

# _migrate_mailbox_if_needed target_dir
# Migrates mailbox from legacy TOON files to SQLite if old files exist.
_migrate_mailbox_if_needed() {
	local target_dir="$1"
	local aidevops_workspace_dir="${AIDEVOPS_WORKSPACE_DIR:-$HOME/.aidevops/.agent-workspace}"
	local mail_dir="${AIDEVOPS_MAIL_DIR:-${aidevops_workspace_dir}/mail}"
	local mail_script="$target_dir/scripts/mail-helper.sh"

	if [[ -x "$mail_script" ]] && find "$mail_dir" -name "*.toon" 2>/dev/null | grep -q .; then
		if "$mail_script" migrate; then
			print_success "Mailbox migration complete"
		else
			print_warning "Mailbox migration had issues (non-critical, old files preserved)"
		fi
	fi
	return 0
}

# _migrate_wavespeed_md target_dir
# Removes stale wavespeed.md from deprecated services/ai-generation/ path (v2.111+).
_migrate_wavespeed_md() {
	local target_dir="$1"
	local old_wavespeed="$target_dir/services/ai-generation/wavespeed.md"

	if [[ -f "$old_wavespeed" ]]; then
		rm -f "$old_wavespeed"
		rmdir "$target_dir/services/ai-generation" 2>/dev/null || true
		print_info "Migrated wavespeed.md from services/ai-generation/ to tools/video/"
	fi
	return 0
}

# _deploy_agents_post_copy target_dir repo_dir source_dir plugins_file
# Orchestrates all post-copy steps: permissions, VERSION, advisories, plan-reminder,
# mailbox migration, stale-file migration, model resolution, and plugin deployment.
_deploy_agents_post_copy() {
	local target_dir="$1"
	local repo_dir="$2"
	local source_dir="$3"
	local plugins_file="$4"

	_set_script_permissions_and_report "$target_dir"
	_install_opencode_plugin_deps "$target_dir" || return 1
	_deploy_version_file "$target_dir" "$repo_dir"
	_deploy_security_advisories_files "$source_dir"
	_inject_plan_reminder "$target_dir"
	_migrate_mailbox_if_needed "$target_dir"
	_migrate_wavespeed_md "$target_dir"
	# Keep canonical workload tiers in deployed source. Runtime-specific agent
	# generation strips them from literal model fields and routing resolves the
	# available model and reasoning level at execution time.
	deploy_plugins "$target_dir" "$plugins_file"
	return 0
}

# _warn_deployed_script_drift source_dir target_dir
# Compares deployed scripts against canonical source and warns if any differ.
# This catches the case where someone edited ~/.aidevops/agents/scripts/ directly
# (those edits are overwritten by every deploy). Emits a warning listing drifted
# files and the canonical source path to edit instead.
# Non-fatal: always returns 0 so deployment proceeds.
#
# Performance: uses a single rsync --checksum --dry-run call instead of one
# diff -q subprocess per script (was 783 calls → now 1 call; t3221).
_warn_deployed_script_drift() {
	local source_dir="$1"
	local target_dir="$2"
	local source_scripts="$source_dir/scripts"
	local target_scripts="$target_dir/scripts"

	if [[ ! -d "$source_scripts" || ! -d "$target_scripts" ]]; then
		return 0
	fi

	local -a drifted=()
	if command -v rsync &>/dev/null; then
		# Single bulk comparison: rsync --checksum --dry-run reports changed files
		# without transferring anything. --out-format='%f' prints only the relative
		# path of each changed file. Filter to top-level *.sh only (no subdirs).
		local changed_file
		while IFS= read -r changed_file; do
			[[ -n "$changed_file" ]] || continue
			# Skip subdirectory scripts (only warn about top-level scripts/)
			[[ "$changed_file" == */* ]] && continue
			[[ "$changed_file" == *.sh ]] || continue
			drifted+=("$changed_file")
		done < <(rsync --checksum --dry-run \
			--out-format='%f' \
			--include='*.sh' --exclude='*/' --exclude='*' \
			"$source_scripts/" "$target_scripts/" 2>/dev/null || true)
	elif command -v diff &>/dev/null; then
		# Fallback: one diff -q per script (slow, only reached when rsync absent)
		local f bn
		for f in "$target_scripts"/*.sh; do
			[[ -f "$f" ]] || continue
			bn=$(basename "$f")
			local src="$source_scripts/$bn"
			if [[ -f "$src" ]] && ! diff -q "$src" "$f" &>/dev/null; then
				drifted+=("$bn")
			fi
		done
	fi

	if [[ ${#drifted[@]} -gt 0 ]]; then
		print_warning "Deployed scripts differ from canonical source (local edits will be overwritten; backup will be created):"
		for bn in "${drifted[@]}"; do
			print_warning "  $target_scripts/$bn"
			print_warning "    → canonical: $source_scripts/$bn"
		done
		print_warning "To keep personal scripts: use $target_dir/custom/scripts/"
		print_warning "To fix the canonical source: edit $source_scripts/ and re-run setup.sh"
	fi
	return 0
}

_validate_agent_source_dir() {
	local source_dir="$1"

	# Validate source directory exists (catches curl install from wrong directory)
	if [[ ! -d "$source_dir" ]]; then
		print_error "Agent source directory not found: $source_dir"
		print_info "This usually means setup.sh was run from the wrong directory."
		print_info "The bootstrap should have cloned the repo and re-executed."
		print_info ""
		print_info "To fix manually:"
		print_info "  cd ~/Git/aidevops && ./setup.sh"
		return 1
	fi

	return 0
}

_deploy_agent_plugin_namespaces=()

_collect_deploy_agent_plugin_namespaces() {
	local plugins_file="$1"

	_deploy_agent_plugin_namespaces=()
	if [[ -f "$plugins_file" ]] && command -v jq &>/dev/null; then
		local ns safe_ns
		while IFS= read -r ns; do
			if [[ -n "$ns" ]] && safe_ns=$(sanitize_plugin_namespace "$ns" 2>/dev/null); then
				if _is_reserved_agent_namespace "$safe_ns"; then
					print_warning "Skipping plugin namespace that collides with core agents directory: $safe_ns"
					continue
				fi
				_deploy_agent_plugin_namespaces+=("$safe_ns")
			fi
		done < <(jq -r '.plugins[].namespace // empty' "$plugins_file" 2>/dev/null)
	fi

	return 0
}

_prepare_agents_deploy_target() {
	local repo_dir="$1"
	local source_dir="$2"
	local target_dir="$3"

	# Warn if deployed scripts have been locally modified (GH#17414).
	# These edits will be overwritten — users must edit the canonical source.
	if [[ -d "$target_dir" ]]; then
		_warn_deployed_script_drift "$source_dir" "$target_dir"
	fi

	# Create backup if target exists (with rotation).
	# Skip when the deployed SHA matches the current HEAD — nothing changed on
	# disk, so there is nothing worth backing up (t3221: steady-state perf).
	if [[ -d "$target_dir" ]]; then
		local cur_sha dep_sha
		cur_sha=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo "")
		dep_sha=$(cat "${HOME}/.aidevops/.deployed-sha" 2>/dev/null || echo "")
		if [[ -n "$cur_sha" && -n "$dep_sha" && "$cur_sha" == "$dep_sha" ]]; then
			print_info "No changes since last deploy (${cur_sha:0:8}) — skipping backup"
		else
			create_backup_with_rotation "$target_dir" "agents"
		fi
	fi

	mkdir -p "$target_dir"
	return 0
}

_run_atomic_agents_deploy() {
	local source_dir="$1"
	local target_dir="$2"
	shift 2

	# Atomically copy source to staging, carry over user dirs, then swap.
	if [[ $# -gt 0 ]]; then
		_atomic_stage_and_deploy_agents "$source_dir" "$target_dir" "$@" || return 1
	else
		_atomic_stage_and_deploy_agents "$source_dir" "$target_dir" || return 1
	fi

	return 0
}

_verify_agents_deploy_or_restore() {
	local source_dir="$1"
	local target_dir="$2"
	local previous_root="${_AIDEVOPS_PREVIOUS_BUNDLE_ROOT:-}"

	# Postcondition: verify the swap actually produced a functional agents dir.
	# _atomic_stage_and_deploy_agents returns 0 on success, but this belt-and-
	# suspenders check catches future regressions where the function returns early
	# without correctly populating $target_dir (GH#22014/GH#21973). Do not write
	# .deployed-sha unless this passes; otherwise auto-update would suppress the
	# next retry even though agents/ is empty or partial.
	if ! _verify_deployed_agents_tree "$target_dir"; then
		print_error "The agents directory was not correctly deployed — setup cannot continue"
		if [[ -L "$target_dir" && -d "$previous_root/scripts" ]]; then
			_runtime_bundle_switch_link "$target_dir" "$previous_root" || true
		else
			_restore_latest_agents_backup "$target_dir" || true
		fi
		return 1
	fi
	if ! _verify_deployed_core_plugin_freshness "$source_dir" "$target_dir"; then
		print_error "The agents directory contains stale core plugin files — setup cannot continue"
		if [[ -L "$target_dir" && -d "$previous_root/scripts" ]]; then
			_runtime_bundle_switch_link "$target_dir" "$previous_root" || true
		else
			_restore_latest_agents_backup "$target_dir" || true
		fi
		return 1
	fi

	return 0
}

_write_deployed_agents_sha() {
	local repo_dir="$1"

	# Write deployed-SHA stamp BEFORE the pulse restart so the stamp is
	# available immediately for subsequent setup steps and the next run's
	# backup-skip check (t3221). Previously written after the blocking
	# restart wait; moving it here has no correctness impact — the deploy
	# is already fully on disk at this point.
	# t2156: enables auto-redeploy when local commits land between releases.
	local deployed_sha
	deployed_sha=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo "")
	if [[ -n "$deployed_sha" ]]; then
		local aidevops_dir="${HOME}/.aidevops"
		mkdir -p "$aidevops_dir"
		printf '%s\n' "$deployed_sha" >"${aidevops_dir}/.deployed-sha"
	fi

	return 0
}

_sync_agent_bin_shims() {
	local target_dir="$1"
	local user_bin_dir="${HOME}/.aidevops/bin"
	local shim=""
	local shim_name=""
	local existing=""
	local existing_target=""

	[[ -n "$target_dir" ]] || return 1
	mkdir -p "$user_bin_dir" || return 1

	for existing in "$user_bin_dir"/*; do
		[[ -L "$existing" ]] || continue
		existing_target=$(readlink "$existing" 2>/dev/null || true)
		case "$existing_target" in
		"${target_dir}/bin/"*)
			[[ -e "$existing_target" ]] || rm -f "$existing"
			;;
		esac
	done

	if [[ -d "${target_dir}/bin" ]]; then
		for shim in "${target_dir}/bin/"*; do
			[[ -f "$shim" ]] || continue
			shim_name=$(basename "$shim")
			# These names are owned by the launchd installers. Replacing them
			# with routine wrappers makes setup and scheduler enablement alternate
			# the targets, which triggers repeat macOS background-item notices.
			case "$shim_name" in
			aidevops-auto-update | aidevops-repo-sync) continue ;;
			esac
			ln -sfn "$shim" "${user_bin_dir}/${shim_name}" || return 1
		done
	fi
	return 0
}

_install_canonical_git_guard_shim() {
	local target_dir="$1"
	local guard_shim="${target_dir}/scripts/git"
	[[ -x "$guard_shim" ]] || {
		print_error "Canonical Git guard shim is missing or not executable: $guard_shim"
		return 1
	}
	mkdir -p "$HOME/.aidevops/bin" || return 1
	ln -sfn "$guard_shim" "$HOME/.aidevops/bin/git" || return 1
	return 0
}

deploy_aidevops_agents() {
	print_info "Deploying aidevops agents to ~/.aidevops/agents/..."

	# Use INSTALL_DIR (set by setup.sh) — BASH_SOURCE[0] points to .agents/scripts/setup/modules/
	# which is not the repo root, so we can't derive .agents/ from it
	local repo_dir="${INSTALL_DIR:?INSTALL_DIR must be set by setup.sh}"
	local source_dir="$repo_dir/.agents"
	local target_dir="$HOME/.aidevops/agents"
	local plugins_file="$HOME/.config/aidevops/plugins.json"

	_validate_agent_source_dir "$source_dir" || return 1
	_collect_deploy_agent_plugin_namespaces "$plugins_file"
	_prepare_agents_deploy_target "$repo_dir" "$source_dir" "$target_dir"
	# Bash 3.2 with nounset treats an empty array expansion as unbound. Avoid
	# expanding it when no plugin namespaces are configured.
	if [[ ${#_deploy_agent_plugin_namespaces[@]} -gt 0 ]]; then
		_runtime_bundle_stage "$repo_dir" "$source_dir" "$target_dir" "$plugins_file" \
			"${_deploy_agent_plugin_namespaces[@]}" || return 1
	else
		_runtime_bundle_stage "$repo_dir" "$source_dir" "$target_dir" "$plugins_file" || return 1
	fi
	_runtime_bundle_activate "$target_dir" "$_AIDEVOPS_STAGED_BUNDLE_DIR" || return 1
	_verify_agents_deploy_or_restore "$source_dir" "$target_dir" || return 1
	pin_aidevops_active_runtime_bundle_root || {
		print_error "Unable to bind setup to the activated runtime bundle"
		return 1
	}

	print_success "Deployed agents to $target_dir"
	_install_canonical_git_guard_shim "$target_dir" || return 1
	_sync_agent_bin_shims "$target_dir" || return 1

	_write_deployed_agents_sha "$repo_dir"

	return 0
}

inject_agents_reference() {
	print_info "Adding aidevops reference to AI assistant configurations..."

	# Delegate to prompt-injection-adapter.sh (t1665.3) which handles all runtimes.
	# The adapter deploys AGENTS.md references via each runtime's native mechanism:
	# OpenCode (json-instructions), Claude (AGENTS.md autodiscovery), Codex, Cursor,
	# Droid, Gemini, Windsurf, Continue, Kilo, Kiro, Aider.
	local adapter_script="${INSTALL_DIR}/.agents/scripts/prompt-injection-adapter.sh"

	if [[ -f "$adapter_script" ]]; then
		# shellcheck source=/dev/null
		source "$adapter_script"
		deploy_prompts_for_all_runtimes
	else
		# Fallback: adapter not yet deployed — use legacy inline logic
		# This path is only hit during initial setup before .agents/ is deployed.
		print_warning "prompt-injection-adapter.sh not found — using legacy deployment"
		_inject_agents_reference_legacy
	fi

	return 0
}

# Legacy fallback for inject_agents_reference — used only when the adapter
# script is not yet available (e.g., during initial setup before .agents/ deploy).
# Will be removed once t1665 migration is complete.
_inject_agents_reference_legacy() {
	local reference_line="$_AIDEVOPS_REFERENCE_LINE"

	# AI assistant agent directories - these receive AGENTS.md reference
	local ai_agent_dirs=(
		"$HOME/.claude:commands"
		"$HOME/.opencode:."
	)

	local updated_count=0

	for entry in "${ai_agent_dirs[@]}"; do
		local config_dir="${entry%%:*}"
		local agents_subdir="${entry##*:}"
		local agents_dir="$config_dir/$agents_subdir"
		local agents_file="$agents_dir/AGENTS.md"

		# Only process if the config directory exists (tool is installed)
		if [[ -d "$config_dir" ]]; then
			mkdir -p "$agents_dir"

			if [[ -f "$agents_file" ]]; then
				local first_line
				first_line=$(head -1 "$agents_file" 2>/dev/null || echo "")
				if [[ "$first_line" != *"aidevops/agents/AGENTS.md"* ]]; then
					local temp_file
					temp_file=$(mktemp)
					trap 'rm -f "${temp_file:-}"' RETURN
					echo "$reference_line" >"$temp_file"
					echo "" >>"$temp_file"
					cat "$agents_file" >>"$temp_file"
					mv "$temp_file" "$agents_file"
					print_success "Added reference to $agents_file"
					((++updated_count))
				else
					print_info "Reference already exists in $agents_file"
				fi
			else
				echo "$reference_line" >"$agents_file"
				print_success "Created $agents_file with aidevops reference"
				((++updated_count))
			fi
		fi
	done

	if [[ $updated_count -eq 0 ]]; then
		print_info "No AI assistant configs found to update (tools may not be installed yet)"
	else
		print_success "Updated $updated_count AI assistant configuration(s)"
	fi

	# Clean up stale AGENTS.md from OpenCode agent dir
	rm -f "$HOME/.config/opencode/agent/AGENTS.md"

	# Deploy OpenCode config-level AGENTS.md from managed template
	local opencode_config_dir="$HOME/.config/opencode"
	local opencode_config_agents="$opencode_config_dir/AGENTS.md"
	local template_source="$INSTALL_DIR/templates/opencode-config-agents.md"

	if [[ -d "$opencode_config_dir" && -f "$template_source" ]]; then
		if [[ -f "$opencode_config_agents" ]]; then
			if ! diff -q "$template_source" "$opencode_config_agents" &>/dev/null; then
				create_backup_with_rotation "$opencode_config_agents" "opencode-agents"
			fi
		fi
		if cp "$template_source" "$opencode_config_agents"; then
			print_success "Deployed greeting template to $opencode_config_agents"
		else
			print_error "Failed to deploy greeting template to $opencode_config_agents"
		fi
	fi

	# Deploy Codex instructions.md (Codex reads ~/.codex/instructions.md as system prompt)
	_deploy_codex_instructions

	# Deploy Cursor AGENTS.md (Cursor reads ~/.cursor/rules/*.md as context)
	_deploy_cursor_agents_reference

	# Deploy Droid AGENTS.md (Droid reads ~/.factory/skills/*.md as context)
	_deploy_droid_agents_reference

	return 0
}

# Deploy instructions.md to Codex config directory.
# Codex reads ~/.codex/instructions.md as its system-level instructions.
_deploy_codex_instructions() {
	local codex_dir="$HOME/.codex"
	local instructions_file="$codex_dir/instructions.md"

	# Only deploy if Codex is installed or config dir exists
	if [[ ! -d "$codex_dir" ]] && ! command -v codex >/dev/null 2>&1; then
		return 0
	fi

	mkdir -p "$codex_dir"

	local reference_content="$_AIDEVOPS_REFERENCE_LINE"

	if [[ -f "$instructions_file" ]]; then
		# shellcheck disable=SC2088  # Tilde is a literal grep pattern, not a path
		if grep -q '~/.aidevops/agents/AGENTS.md' "$instructions_file" 2>/dev/null; then
			print_info "Codex instructions.md already has aidevops reference"
			return 0
		fi
		# Prepend reference to existing instructions
		local temp_file
		temp_file=$(mktemp)
		echo "$reference_content" >"$temp_file"
		echo "" >>"$temp_file"
		cat "$instructions_file" >>"$temp_file"
		mv "$temp_file" "$instructions_file"
		print_success "Added aidevops reference to $instructions_file"
	else
		echo "$reference_content" >"$instructions_file"
		print_success "Created $instructions_file with aidevops reference"
	fi
	return 0
}

# Deploy AGENTS.md reference to Cursor rules directory.
# Cursor reads ~/.cursor/rules/*.md files as additional context.
_deploy_cursor_agents_reference() {
	local cursor_dir="$HOME/.cursor"
	local rules_dir="$cursor_dir/rules"
	local agents_file="$rules_dir/aidevops.md"

	# Only deploy if Cursor is installed or config dir exists
	if [[ ! -d "$cursor_dir" ]] && ! command -v cursor >/dev/null 2>&1 && ! command -v agent >/dev/null 2>&1; then
		return 0
	fi

	mkdir -p "$rules_dir"

	local reference_content="$_AIDEVOPS_REFERENCE_LINE"

	if [[ -f "$agents_file" ]]; then
		# shellcheck disable=SC2088  # Tilde is a literal grep pattern, not a path
		if grep -q '~/.aidevops/agents/AGENTS.md' "$agents_file" 2>/dev/null; then
			print_info "Cursor rules/aidevops.md already has aidevops reference"
			return 0
		fi
	fi

	echo "$reference_content" >"$agents_file"
	print_success "Deployed aidevops reference to $agents_file"
	return 0
}

# Deploy AGENTS.md reference to Droid skills directory.
# Droid reads ~/.factory/skills/*.md files as additional context.
_deploy_droid_agents_reference() {
	local factory_dir="$HOME/.factory"
	local skills_dir="$factory_dir/skills"
	local agents_file="$skills_dir/aidevops.md"

	# Only deploy if Droid is installed or config dir exists
	if [[ ! -d "$factory_dir" ]] && ! command -v droid >/dev/null 2>&1; then
		return 0
	fi

	mkdir -p "$skills_dir"

	local reference_content="$_AIDEVOPS_REFERENCE_LINE"

	if [[ -f "$agents_file" ]]; then
		# shellcheck disable=SC2088  # Tilde is a literal grep pattern, not a path
		if grep -q '~/.aidevops/agents/AGENTS.md' "$agents_file" 2>/dev/null; then
			print_info "Droid skills/aidevops.md already has aidevops reference"
			return 0
		fi
	fi

	echo "$reference_content" >"$agents_file"
	print_success "Deployed aidevops reference to $agents_file"
	return 0
}
