#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
set -euo pipefail

# deploy-agents-on-merge.sh - Fast targeted agent deployment after PR merge
#
# Called by the supervisor after merging PRs that modify .agents/ files.
# Uses setup's changed-stage planner, immutable runtime-bundle staging, and
# atomic activation without running unrelated optional setup steps.
#
# Usage:
#   deploy-agents-on-merge.sh [options]
#
# Options:
#   --repo <path>       Path to the aidevops repo (default: ~/Git/aidevops)
#   --scripts-only      Compatibility hint for a scripts-only change set
#   --full              Run full setup.sh --non-interactive instead
#   --dry-run           Show what would be deployed without doing it
#   --diff <commit>     Validate/detect agent changes since <commit>
#   --expected-sha <sha> Require the source checkout to match this exact commit
#   --quiet             Suppress non-error output
#   --help              Show this help
#
# Exit codes:
#   0 - Deploy successful
#   1 - Deploy failed
#   2 - Nothing to deploy (no changes detected)

# Colors — sourced from shared-constants.sh (Pattern A, t2053.3)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"

QUIET=false

log_info() {
	if [[ "$QUIET" == "false" ]]; then
		echo -e "${BLUE}[deploy]${NC} $1"
	fi
	return 0
}

log_success() {
	if [[ "$QUIET" == "false" ]]; then
		echo -e "${GREEN}[deploy]${NC} $1"
	fi
	return 0
}

log_warn() {
	echo -e "${YELLOW}[deploy]${NC} $1" >&2
	return 0
}

log_error() {
	echo -e "${RED}[deploy]${NC} $1" >&2
	return 0
}

# Defaults
REPO_DIR="${HOME}/Git/aidevops"
TARGET_DIR="${AIDEVOPS_DEPLOY_TARGET:-${HOME}/.aidevops/agents}"
PLUGINS_FILE="${HOME}/.config/aidevops/plugins.json"
SCRIPTS_ONLY=false
FULL_DEPLOY=false
DRY_RUN=false
DIFF_COMMIT=""
EXPECTED_SOURCE_SHA=""
SOURCE_LOCK_DIR=""
PLUGIN_NAMESPACES=()

sanitize_plugin_namespace() {
	local namespace="$1"

	if [[ -z "$namespace" ]]; then
		return 1
	fi

	if [[ "$namespace" =~ ^[A-Za-z0-9._-]+$ ]]; then
		printf '%s\n' "$namespace"
		return 0
	fi

	return 1
}

collect_plugin_namespaces() {
	PLUGIN_NAMESPACES=()

	if [[ ! -f "$PLUGINS_FILE" ]] || ! command -v jq >/dev/null 2>&1; then
		return 0
	fi

	local namespace
	local safe_namespace
	while IFS= read -r namespace; do
		if [[ -n "$namespace" ]] && safe_namespace=$(sanitize_plugin_namespace "$namespace"); then
			PLUGIN_NAMESPACES+=("$safe_namespace")
		fi
	done < <(jq -r '.plugins[].namespace // empty' "$PLUGINS_FILE" 2>/dev/null)

	return 0
}

parse_args() {
	local arg=""
	local option_value=""

	while [[ $# -gt 0 ]]; do
		arg="$1"
		case "$arg" in
		--repo)
			[[ $# -lt 2 ]] && {
				log_error "--repo requires a path"
				return 1
			}
			option_value="$2"
			REPO_DIR="$option_value"
			shift 2
			;;
		--scripts-only)
			SCRIPTS_ONLY=true
			shift
			;;
		--full)
			FULL_DEPLOY=true
			shift
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		--diff)
			[[ $# -lt 2 ]] && {
				log_error "--diff requires a commit"
				return 1
			}
			option_value="$2"
			DIFF_COMMIT="$option_value"
			shift 2
			;;
		--expected-sha)
			[[ $# -lt 2 ]] && {
				log_error "--expected-sha requires a full commit SHA"
				return 1
			}
			option_value="$2"
			EXPECTED_SOURCE_SHA="$option_value"
			shift 2
			;;
		--quiet)
			QUIET=true
			shift
			;;
		--help | -h)
			head -25 "$0" | tail -20
			exit 0
			;;
		*)
			log_error "Unknown option: $arg"
			return 1
			;;
		esac
	done
	return 0
}

release_source_lock() {
	local lock_dir="${SOURCE_LOCK_DIR:-}"

	if [[ -n "$lock_dir" && -d "$lock_dir" ]]; then
		rmdir "$lock_dir" 2>/dev/null || true
	fi
	SOURCE_LOCK_DIR=""
	return 0
}

acquire_source_lock() {
	local git_dir=""
	local common_dir=""

	git_dir=$(git -C "$REPO_DIR" rev-parse --path-format=absolute --git-dir 2>/dev/null) || {
		log_error "Cannot resolve source Git directory: $REPO_DIR"
		return 1
	}
	common_dir=$(git -C "$REPO_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || {
		log_error "Cannot resolve source Git common directory: $REPO_DIR"
		return 1
	}

	if [[ "$git_dir" == "$common_dir" ]]; then
		# Share the audited canonical-recovery lock so a concurrent mirror sync
		# cannot change the source between exact-SHA validation and activation.
		SOURCE_LOCK_DIR="$common_dir/aidevops-canonical-recovery.lock"
	else
		SOURCE_LOCK_DIR="$git_dir/aidevops-source-deploy.lock"
	fi
	if ! mkdir "$SOURCE_LOCK_DIR" 2>/dev/null; then
		log_error "Source checkout is changing or another deployment is active; active bundle was not changed"
		SOURCE_LOCK_DIR=""
		return 1
	fi
	return 0
}

validate_source_provenance() {
	local expected_sha="$EXPECTED_SOURCE_SHA"
	local resolved_sha=""
	local head_sha=""
	local source_status=""
	local git_dir=""
	local common_dir=""
	local current_branch=""
	local branch_sha=""
	local upstream_ref=""
	local upstream_sha=""

	if [[ ! "$expected_sha" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
		log_error "Exact source provenance is required: pass --expected-sha with a full commit SHA"
		return 1
	fi
	resolved_sha=$(git -C "$REPO_DIR" rev-parse --verify "${expected_sha}^{commit}" 2>/dev/null) || {
		log_error "Expected source commit cannot be resolved: $expected_sha"
		return 1
	}
	if [[ "$resolved_sha" != "$expected_sha" ]]; then
		log_error "Expected source SHA is not the exact resolved commit: $expected_sha"
		return 1
	fi
	head_sha=$(git -C "$REPO_DIR" rev-parse HEAD 2>/dev/null) || {
		log_error "Source checkout HEAD cannot be resolved"
		return 1
	}
	if [[ "$head_sha" != "$expected_sha" ]]; then
		log_error "Source checkout is stale: HEAD ${head_sha:0:12} does not match expected ${expected_sha:0:12}; active bundle was not changed"
		return 1
	fi
	source_status=$(git -C "$REPO_DIR" status --porcelain=v1 --untracked-files=all 2>/dev/null) || {
		log_error "Source checkout state cannot be inspected safely"
		return 1
	}
	if [[ -n "$source_status" ]]; then
		log_error "Source checkout is dirty; synchronize or use a clean immutable checkout before retrying. Active bundle was not changed"
		return 1
	fi

	git_dir=$(git -C "$REPO_DIR" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 1
	common_dir=$(git -C "$REPO_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
	if [[ "$git_dir" == "$common_dir" ]]; then
		current_branch=$(git -C "$REPO_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null) || {
			log_error "Canonical deployment source is detached; active bundle was not changed"
			return 1
		}
		branch_sha=$(git -C "$REPO_DIR" rev-parse --verify "refs/heads/${current_branch}^{commit}" 2>/dev/null) || {
			log_error "Canonical deployment branch cannot be resolved: $current_branch"
			return 1
		}
		if [[ "$branch_sha" != "$expected_sha" ]]; then
			log_error "Canonical deployment branch changed during validation; active bundle was not changed"
			return 1
		fi
		upstream_ref=$(git -C "$REPO_DIR" rev-parse --symbolic-full-name '@{upstream}' 2>/dev/null || true)
		if [[ -n "$upstream_ref" ]]; then
			upstream_sha=$(git -C "$REPO_DIR" rev-parse --verify "${upstream_ref}^{commit}" 2>/dev/null) || {
				log_error "Canonical deployment upstream cannot be resolved: $upstream_ref"
				return 1
			}
			if [[ "$upstream_sha" != "$expected_sha" ]]; then
				log_error "Canonical deployment source diverges from $upstream_ref; run audited mirror synchronization before retrying"
				return 1
			fi
		fi
	fi

	log_info "Verified immutable source commit ${expected_sha:0:12} before bundle staging"
	return 0
}

# Validate the repo directory
validate_repo() {
	# Support both regular repos (.git dir) and worktrees (.git file)
	if [[ ! -d "$REPO_DIR/.git" && ! -f "$REPO_DIR/.git" ]]; then
		log_error "Not a git repo: $REPO_DIR"
		return 1
	fi

	if [[ ! -d "$REPO_DIR/.agents" ]]; then
		log_error "No .agents/ directory in $REPO_DIR"
		return 1
	fi

	return 0
}

validate_stable_target() {
	if [[ -z "${HOME:-}" || "$HOME" != /* ]]; then
		log_error "Cannot resolve stable agents target: HOME must be a non-empty absolute path"
		return 1
	fi

	local stable_target="$HOME/.aidevops/agents"
	if [[ "$TARGET_DIR" != "$stable_target" ]]; then
		log_error "Refusing deployment outside the stable agents target: $TARGET_DIR"
		return 1
	fi
	return 0
}

# Detect which agent files changed since a commit
detect_changes() {
	local since_commit="$1"
	local changed_files

	if [[ -n "$since_commit" ]]; then
		# Validate since_commit is a valid revision (not an injected option)
		if [[ "$since_commit" == -* ]] || ! git -C "$REPO_DIR" rev-parse --verify "$since_commit" >/dev/null 2>&1; then
			log_error "Invalid commit reference: $since_commit"
			return 1
		fi
		if ! changed_files=$(git -C "$REPO_DIR" diff --name-only "$since_commit" HEAD -- '.agents/' 2>&1); then
			log_error "Failed to detect changed agent files: $changed_files"
			return 1
		fi
	else
		# Compare deployed VERSION with repo VERSION to detect staleness
		local repo_version deployed_version
		repo_version=$(cat "$REPO_DIR/VERSION" 2>/dev/null || echo "unknown")
		deployed_version=$(cat "$TARGET_DIR/VERSION" 2>/dev/null || echo "none")

		if [[ "$repo_version" == "$deployed_version" ]]; then
			log_info "Deployed agents ($deployed_version) match repo ($repo_version)"
			echo ""
			return 0
		fi

		log_info "Version mismatch: deployed=$deployed_version repo=$repo_version"
		# Return all agent files as changed (version mismatch = full sync needed)
		changed_files=$(git -C "$REPO_DIR" ls-files '.agents/' 2>/dev/null || echo "")
	fi

	echo "$changed_files"
	return 0
}

# Rebuild derived runtime files after synchronizing their source tree. The
# generator's per-runtime source hash keeps unrelated deployments fast while
# ensuring command, agent, prompt, and MCP outputs cannot remain stale.
regenerate_runtime_config() {
	local generator="$TARGET_DIR/scripts/generate-runtime-config.sh"

	if [[ "$DRY_RUN" == "true" ]]; then
		log_info "[dry-run] Would regenerate derived runtime configuration"
		return 0
	fi
	if [[ ! -f "$generator" ]]; then
		log_error "Runtime config generator not found after deployment: $generator"
		return 1
	fi

	log_info "Regenerating derived runtime configuration..."
	if ! bash "$generator" all; then
		log_error "Derived runtime configuration regeneration failed"
		return 1
	fi
	log_success "Derived runtime configuration regenerated"
	return 0
}

# Route every mutating incremental deployment through setup's transactional
# runtime-bundle stage. This preserves the previous immutable bundle and only
# changes the stable agents path via atomic activation after validation.
run_transactional_incremental_deploy() {
	local setup_script="$REPO_DIR/setup.sh"
	local setup_exit=0

	if [[ ! -f "$setup_script" || ! -r "$setup_script" ]]; then
		log_error "Transactional deployment requires a readable setup helper: $setup_script"
		return 1
	fi
	if [[ "$DRY_RUN" == "true" ]]; then
		log_info "[dry-run] Would stage and atomically activate a runtime bundle via setup.sh --stage ai-session"
		return 0
	fi

	log_info "Staging and atomically activating an immutable runtime bundle..."
	env -u AIDEVOPS_AGENTS_DIR -u AGENTS_DIR \
		AIDEVOPS_NON_INTERACTIVE=true \
		AIDEVOPS_DEPLOY_TARGET="$TARGET_DIR" \
		bash "$setup_script" --stage ai-session || setup_exit=$?
	if [[ "$setup_exit" -eq 75 ]]; then
		log_warn "setup.sh --stage ai-session is locked by another deployment (exit 75)"
	fi
	if [[ "$setup_exit" -ne 0 ]]; then
		log_error "Transactional runtime bundle deployment failed (exit $setup_exit)"
		return "$setup_exit"
	fi
	log_success "Transactional runtime bundle deployment completed"
	return 0
}

runtime_config_changes_detected() {
	local changed_files="${1:-}"
	local file

	# Explicit --scripts-only deployments do not provide a diff; regenerate to
	# preserve correctness. Diff-based deployment can retain the fast path.
	[[ -z "$changed_files" ]] && return 0
	while IFS= read -r file; do
		case "$file" in
		.agents/scripts/commands/* | \
			.agents/scripts/generate-runtime-config*.sh | \
			.agents/scripts/generate-opencode-*.sh | \
			.agents/scripts/generate-claude-*.sh | \
			.agents/scripts/runtime-registry.sh | \
			.agents/scripts/codex-setup.py | \
			.agents/scripts/codex-mcp-config.py | \
			.agents/scripts/mcp-config-adapter.sh | \
			.agents/scripts/prompt-injection-adapter.sh | \
			.agents/scripts/lib/agent_config.py) return 0 ;;
		esac
	done <<<"$changed_files"
	return 1
}

# Deploy scripts only (fastest path)
deploy_scripts_only() {
	local changed_files="${1:-}"
	local source_dir="$REPO_DIR/.agents/scripts"
	local target_scripts_dir="$TARGET_DIR/scripts"

	if [[ ! -d "$source_dir" ]]; then
		log_error "Source scripts directory not found: $source_dir"
		return 1
	fi

	mkdir -p "$target_scripts_dir"

	if [[ "$DRY_RUN" == "true" ]]; then
		log_info "[dry-run] Would sync $source_dir/ -> $target_scripts_dir/"
		local count
		count=$(find "$source_dir" -type f | wc -l | tr -d ' ')
		log_info "[dry-run] $count files would be deployed"
		return 0
	fi

	log_info "Deploying scripts to $target_scripts_dir..."

	if command -v rsync &>/dev/null; then
		rsync -a --delete "$source_dir/" "$target_scripts_dir/"
	else
		# Fallback: tar-based copy
		# Remove existing target contents first to match rsync --delete behavior
		if ! find "$target_scripts_dir" -mindepth 1 -delete; then
			log_error "Failed to clean target scripts directory: $target_scripts_dir"
			return 1
		fi
		(cd "$source_dir" && tar cf - .) | (cd "$target_scripts_dir" && tar xf -)
	fi

	# Set executable permissions
	chmod +x "$target_scripts_dir/"*.sh 2>/dev/null || true

	local count
	count=$(find "$target_scripts_dir" -name "*.sh" -type f | wc -l | tr -d ' ')
	log_success "Deployed $count scripts"

	if runtime_config_changes_detected "$changed_files"; then
		regenerate_runtime_config || return 1
	fi
	return 0
}

# Sync agents via rsync, excluding preserved directories and plugin namespaces
_deploy_agents_rsync() {
	local source_dir="$1"
	local -a rsync_excludes=(
		"--exclude=loop-state/"
		"--exclude=custom/"
		"--exclude=draft/"
	)
	local plugin_namespace
	for plugin_namespace in "${PLUGIN_NAMESPACES[@]+"${PLUGIN_NAMESPACES[@]}"}"; do
		rsync_excludes+=("--exclude=${plugin_namespace}/")
	done
	rsync -a "${rsync_excludes[@]}" "$source_dir/" "$TARGET_DIR/"
	return $?
}

# Sync agents via tar when rsync is unavailable, preserving custom/draft/plugin dirs
_deploy_agents_tar_fallback() {
	local source_dir="$1"
	local tmp_preserve
	tmp_preserve=$(mktemp -d)
	local preserve_ok=true
	local -a preserved_dirs=("custom" "draft")
	local plugin_namespace
	for plugin_namespace in "${PLUGIN_NAMESPACES[@]+"${PLUGIN_NAMESPACES[@]}"}"; do
		preserved_dirs+=("$plugin_namespace")
	done

	local pdir
	for pdir in "${preserved_dirs[@]}"; do
		if [[ -d "$TARGET_DIR/$pdir" ]] && ! cp -R "$TARGET_DIR/$pdir" "$tmp_preserve/$pdir"; then
			preserve_ok=false
		fi
	done

	if [[ "$preserve_ok" == "false" ]]; then
		log_error "Failed to preserve custom/draft directories"
		rm -rf "$tmp_preserve"
		return 1
	fi

	# Remove existing target contents (except preserved dirs) to match rsync --delete behavior
	if [[ -z "$TARGET_DIR" ]]; then
		log_error "TARGET_DIR is empty — refusing to run find cleanup"
		rm -rf "$tmp_preserve"
		return 1
	fi
	local -a find_args=(
		-mindepth 1
		-maxdepth 1
		! -name 'custom'
		! -name 'draft'
		! -name 'loop-state'
	)
	for plugin_namespace in "${PLUGIN_NAMESPACES[@]+"${PLUGIN_NAMESPACES[@]}"}"; do
		find_args+=(! -name "$plugin_namespace")
	done
	find_args+=(-exec rm -rf {} +)
	if ! find "$TARGET_DIR" "${find_args[@]}"; then
		log_error "Failed to clean target directory: $TARGET_DIR"
		rm -rf "$tmp_preserve"
		return 1
	fi

	# Copy all agents excluding preserved directories
	local -a tar_excludes=("--exclude=loop-state" "--exclude=custom" "--exclude=draft")
	for plugin_namespace in "${PLUGIN_NAMESPACES[@]+"${PLUGIN_NAMESPACES[@]}"}"; do
		tar_excludes+=("--exclude=$plugin_namespace")
	done
	(cd "$source_dir" && tar cf - "${tar_excludes[@]}" .) |
		(cd "$TARGET_DIR" && tar xf -)

	# Restore preserved directories
	for pdir in "${preserved_dirs[@]}"; do
		if [[ -d "$tmp_preserve/$pdir" ]]; then
			cp -R "$tmp_preserve/$pdir" "$TARGET_DIR/$pdir"
		fi
	done
	rm -rf "$tmp_preserve"
	return 0
}

# Deploy all agent files (selective sync, preserving custom/draft)
deploy_all_agents() {
	local source_dir="$REPO_DIR/.agents"

	if [[ ! -d "$source_dir" ]]; then
		log_error "Source agents directory not found: $source_dir"
		return 1
	fi

	mkdir -p "$TARGET_DIR"

	if [[ "$DRY_RUN" == "true" ]]; then
		log_info "[dry-run] Would sync $source_dir/ -> $TARGET_DIR/"
		local preserve_display="custom/, draft/, loop-state/"
		local plugin_namespace
		for plugin_namespace in ${PLUGIN_NAMESPACES+"${PLUGIN_NAMESPACES[@]}"}; do
			preserve_display+=", $plugin_namespace"
		done
		log_info "[dry-run] Preserving: $preserve_display"
		return 0
	fi

	log_info "Deploying all agents to $TARGET_DIR..."

	if command -v rsync &>/dev/null; then
		_deploy_agents_rsync "$source_dir" || return 1
	else
		_deploy_agents_tar_fallback "$source_dir" || return 1
	fi

	# Set executable permissions on scripts
	chmod +x "$TARGET_DIR/scripts/"*.sh 2>/dev/null || true

	# Copy VERSION file
	if [[ -f "$REPO_DIR/VERSION" ]]; then
		cp "$REPO_DIR/VERSION" "$TARGET_DIR/VERSION"
	fi

	local agent_count script_count
	agent_count=$(find "$TARGET_DIR" -name "*.md" -type f | wc -l | tr -d ' ')
	script_count=$(find "$TARGET_DIR/scripts" -name "*.sh" -type f 2>/dev/null | wc -l | tr -d ' ')
	log_success "Deployed $agent_count agent files and $script_count scripts"

	regenerate_runtime_config || return 1
	return 0
}

# Deploy only specific changed files (most targeted)
deploy_changed_files() {
	local changed_files="$1"

	if [[ -z "$changed_files" ]]; then
		log_info "No changed files to deploy"
		return 2
	fi

	local count
	count=$(echo "$changed_files" | wc -l | tr -d ' ')

	if [[ "$DRY_RUN" == "true" ]]; then
		log_info "[dry-run] Would deploy $count changed files:"
		echo "$changed_files" | head -20
		if [[ "$count" -gt 20 ]]; then
			log_info "[dry-run] ... and $((count - 20)) more"
		fi
		return 0
	fi

	log_info "Deploying $count changed files..."

	local deployed=0
	local failed=0

	while IFS= read -r file; do
		[[ -z "$file" ]] && continue

		# Strip .agents/ prefix to get relative path within target
		local rel_path="${file#.agents/}"
		local source_file="$REPO_DIR/$file"
		local target_file="$TARGET_DIR/$rel_path"

		# Skip custom/draft/loop-state
		case "$rel_path" in
		custom/* | draft/* | loop-state/*) continue ;;
		esac

		local plugin_namespace
		for plugin_namespace in "${PLUGIN_NAMESPACES[@]+"${PLUGIN_NAMESPACES[@]}"}"; do
			case "$rel_path" in
			"$plugin_namespace"/*)
				continue 2
				;;
			esac
		done

		if [[ -f "$source_file" ]]; then
			# Create target directory if needed
			local target_parent
			target_parent=$(dirname "$target_file")
			mkdir -p "$target_parent"

			# Copy file (catch errors instead of letting set -e abort)
			if ! cp -- "$source_file" "$target_file"; then
				log_warn "Failed to copy: $rel_path"
				failed=$((failed + 1))
				continue
			fi

			# Set executable if it's a script
			if [[ "$target_file" == *.sh ]]; then
				if ! chmod -- +x "$target_file"; then
					log_warn "Failed to set executable: $rel_path"
					failed=$((failed + 1))
					continue
				fi
			fi

			deployed=$((deployed + 1))
		elif [[ ! -e "$source_file" ]]; then
			# File was deleted in source — remove from target
			if [[ -f "$target_file" ]]; then
				if ! rm -f -- "$target_file"; then
					log_warn "Failed to remove deleted file: $rel_path"
					failed=$((failed + 1))
					continue
				fi
				log_info "Removed deleted file: $rel_path"
			fi
		fi
	done <<<"$changed_files"

	if [[ "$failed" -gt 0 ]]; then
		log_warn "Deployed $deployed files, $failed failed"
		return 1
	fi

	# Update VERSION
	if [[ -f "$REPO_DIR/VERSION" ]]; then
		cp "$REPO_DIR/VERSION" "$TARGET_DIR/VERSION"
	fi

	log_success "Deployed $deployed changed files"
	regenerate_runtime_config || return 1
	return 0
}

_run_full_deploy() {
	local full_exit=0

	log_info "Running full deploy via setup.sh --non-interactive..."
	if [[ "$DRY_RUN" == "true" ]]; then
		log_info "[dry-run] Would run: AIDEVOPS_NON_INTERACTIVE=true $REPO_DIR/setup.sh --non-interactive"
		return 0
	fi
	env -u AIDEVOPS_AGENTS_DIR -u AGENTS_DIR \
		AIDEVOPS_NON_INTERACTIVE=true \
		AIDEVOPS_DEPLOY_TARGET="$TARGET_DIR" \
		bash "$REPO_DIR/setup.sh" --non-interactive || full_exit=$?
	if [[ "$full_exit" -eq 75 ]]; then
		log_warn "setup.sh --non-interactive is locked by another deployment (exit 75). Re-run after the active transactional deployment completes."
	fi
	return "$full_exit"
}

_validate_transactional_diff() {
	local changed=""
	local change_count=0
	local non_script_count=0

	changed=$(detect_changes "$DIFF_COMMIT") || return 1
	if [[ -z "$changed" ]]; then
		log_info "No agent changes since $DIFF_COMMIT"
		return 2
	fi
	change_count=$(printf '%s\n' "$changed" | wc -l | tr -d ' ')
	if ! non_script_count=$(printf '%s\n' "$changed" | grep -cEv '^\.agents/scripts/'); then
		non_script_count=0
	fi
	if [[ "$non_script_count" -eq 0 ]]; then
		log_info "Only scripts changed — using fast scripts-only deploy through atomic setup"
	else
		log_info "Deploying $change_count changed agent files through atomic setup"
	fi
	return 0
}

_run_dry_run_deploy() {
	local changed=""
	local change_count=0
	local non_script_changes=0

	if [[ "$SCRIPTS_ONLY" == "true" ]]; then
		deploy_scripts_only
		return $?
	fi

	if [[ -n "$DIFF_COMMIT" ]]; then
		changed=$(detect_changes "$DIFF_COMMIT") || return 1
		if [[ -z "$changed" ]]; then
			log_info "No agent changes since $DIFF_COMMIT"
			return 2
		fi
		change_count=$(echo "$changed" | wc -l | tr -d ' ')
		if [[ "$change_count" -gt 50 ]]; then
			log_info "Large changeset ($change_count files) — doing full agent sync"
			deploy_all_agents
			return $?
		fi
		if ! non_script_changes=$(printf '%s\n' "$changed" | grep -cEv '^\.agents/scripts/'); then
			non_script_changes=0
		fi
		if [[ "$non_script_changes" -eq 0 ]]; then
			log_info "Only scripts changed — using fast scripts-only deploy"
			deploy_scripts_only "$changed"
			return $?
		fi

		deploy_changed_files "$changed"
		return $?
	fi

	changed=$(detect_changes "") || return 1
	if [[ -z "$changed" ]]; then
		return 2
	fi
	deploy_all_agents
	return $?
}

main() {
	local diff_exit=0
	local deploy_exit=0

	parse_args "$@" || return 1
	validate_repo || return 1
	validate_stable_target || return 1
	collect_plugin_namespaces || return 1
	acquire_source_lock || return 1
	trap 'release_source_lock' EXIT
	trap 'release_source_lock; exit 130' INT
	trap 'release_source_lock; exit 143' TERM
	if ! validate_source_provenance; then
		release_source_lock
		trap - EXIT INT TERM
		return 1
	fi
	if [[ "$FULL_DEPLOY" == "true" ]]; then
		_run_full_deploy || deploy_exit=$?
	elif [[ "$DRY_RUN" == "true" ]]; then
		_run_dry_run_deploy || deploy_exit=$?
	else
		if [[ -n "$DIFF_COMMIT" ]]; then
			_validate_transactional_diff || diff_exit=$?
			if [[ "$diff_exit" -ne 0 ]]; then
				deploy_exit="$diff_exit"
			fi
		fi
		if [[ "$deploy_exit" -eq 0 ]]; then
			run_transactional_incremental_deploy || deploy_exit=$?
		fi
	fi
	release_source_lock
	trap - EXIT INT TERM
	return "$deploy_exit"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
