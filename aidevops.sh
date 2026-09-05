#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# AI DevOps Framework CLI
# Usage: aidevops <command> [options]
#
# Version: 3.32.312

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Paths
# When running under sudo, env_reset may rewrite HOME to root's home; SUDO_USER
# holds the original username. getent passwd is canonical on Linux; dscl is
# canonical on macOS. Fall back to $HOME only when those resolvers are absent.
# The command -v getent guard MUST be present — omitting it crashes aidevops.sh
# under `set -euo pipefail` on any BSD system and breaks sudo aidevops approve.
# Mirrors the pattern in .agents/scripts/approval-helper.sh:_resolve_real_home().
# Security: no escalation — root already has full filesystem access.
_AIDEVOPS_REAL_HOME="$HOME"
if [[ -n "${SUDO_USER:-}" && "$(id -u)" -eq 0 ]]; then
	_tmp_real_home=""
	if command -v getent &>/dev/null; then
		_tmp_real_home=$(getent passwd "$SUDO_USER" | cut -d: -f6 || true)
	elif command -v dscl &>/dev/null; then
		_tmp_real_home=$(dscl . -read "/Users/${SUDO_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2; exit}' || true)
	elif [[ -d "/Users/${SUDO_USER}" ]]; then
		_tmp_real_home="/Users/${SUDO_USER}"
	fi
	if [[ -n "$_tmp_real_home" ]]; then
		_AIDEVOPS_REAL_HOME="$_tmp_real_home"
	fi
fi
INSTALL_DIR="$_AIDEVOPS_REAL_HOME/Git/aidevops"
_AIDEVOPS_SOURCE_PATH="${BASH_SOURCE[0]}"
_AIDEVOPS_SOURCE_DIR="${_AIDEVOPS_SOURCE_PATH%/*}"
[[ "$_AIDEVOPS_SOURCE_DIR" == "$_AIDEVOPS_SOURCE_PATH" ]] && _AIDEVOPS_SOURCE_DIR="."
_AIDEVOPS_SOURCE_DIR="$(cd "$_AIDEVOPS_SOURCE_DIR" 2>/dev/null && pwd -P)" || _AIDEVOPS_SOURCE_DIR=""
if [[ -n "$_AIDEVOPS_SOURCE_DIR" && -L "$_AIDEVOPS_SOURCE_PATH" ]]; then
	_AIDEVOPS_LINK_TARGET="$(readlink "$_AIDEVOPS_SOURCE_PATH" 2>/dev/null || true)"
	if [[ -n "$_AIDEVOPS_LINK_TARGET" ]]; then
		[[ "$_AIDEVOPS_LINK_TARGET" != /* ]] && _AIDEVOPS_LINK_TARGET="$_AIDEVOPS_SOURCE_DIR/$_AIDEVOPS_LINK_TARGET"
		_AIDEVOPS_LINK_DIR="${_AIDEVOPS_LINK_TARGET%/*}"
		_AIDEVOPS_LINK_DIR="$(cd "$_AIDEVOPS_LINK_DIR" 2>/dev/null && pwd)" || _AIDEVOPS_LINK_DIR=""
		[[ -n "$_AIDEVOPS_LINK_DIR" ]] && _AIDEVOPS_SOURCE_DIR="$_AIDEVOPS_LINK_DIR"
	fi
fi
_AIDEVOPS_CLI_ROOT="$INSTALL_DIR"
_AIDEVOPS_CLI_MODULES_SUBDIR=".agents/scripts/aidevops-cli"
if [[ -n "$_AIDEVOPS_SOURCE_DIR" && -f "$_AIDEVOPS_SOURCE_DIR/.agents/scripts/aidevops-cli/aidevops-repos-lib.sh" ]]; then
	INSTALL_DIR="$_AIDEVOPS_SOURCE_DIR"
	_AIDEVOPS_CLI_ROOT="$_AIDEVOPS_SOURCE_DIR"
elif [[ -n "$_AIDEVOPS_SOURCE_DIR" && -f "$_AIDEVOPS_SOURCE_DIR/scripts/aidevops-cli/aidevops-repos-lib.sh" ]]; then
	# setup.sh deploys the orchestrator at the agents root and its modules under
	# scripts/. Keep repository operations pointed at INSTALL_DIR, but load the
	# CLI and VERSION from this coherent atomic deployment instead of a stale
	# canonical checkout.
	_AIDEVOPS_CLI_ROOT="$_AIDEVOPS_SOURCE_DIR"
	_AIDEVOPS_CLI_MODULES_SUBDIR="scripts/aidevops-cli"
elif [[ -n "${AIDEVOPS_SHARE:-}" &&
	-f "$AIDEVOPS_SHARE/.agents/scripts/aidevops-cli/aidevops-repos-lib.sh" &&
	-f "$AIDEVOPS_SHARE/.agents/scripts/runtime-bundle-verifier.sh" &&
	-f "$AIDEVOPS_SHARE/VERSION" ]]; then
	# Homebrew installs the coherent package snapshot under share/aidevops and
	# exports AIDEVOPS_SHARE from its wrapper. Keep repository operations pointed
	# at INSTALL_DIR while loading packaged CLI modules and VERSION from there.
	_AIDEVOPS_CLI_ROOT="$AIDEVOPS_SHARE"
fi
unset _AIDEVOPS_SOURCE_PATH _AIDEVOPS_SOURCE_DIR _AIDEVOPS_LINK_TARGET _AIDEVOPS_LINK_DIR
AGENTS_DIR="${AIDEVOPS_AGENTS_DIR:-$_AIDEVOPS_REAL_HOME/.aidevops/agents}"
export AIDEVOPS_AGENTS_DIR="$AGENTS_DIR"
CONFIG_DIR="$_AIDEVOPS_REAL_HOME/.config/aidevops"
REPOS_FILE="$CONFIG_DIR/repos.json"
# shellcheck disable=SC2034  # Used in fresh install fallback
REPO_URL="https://github.com/marcusquinn/aidevops.git"
VERSION_FILE="$_AIDEVOPS_CLI_ROOT/VERSION"

# Portable sed in-place edit (macOS BSD sed vs GNU sed)
sed_inplace() { if [[ "$(uname)" == "Darwin" ]]; then sed -i '' "$@"; else sed -i "$@"; fi; }

# Portable timeout (macOS has no coreutils timeout)
_timeout_cmd() {
	local secs="$1"
	shift
	if command -v timeout &>/dev/null; then
		timeout "$secs" "$@"
	elif command -v gtimeout &>/dev/null; then
		gtimeout "$secs" "$@"
	elif command -v perl &>/dev/null; then
		perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
	else
		echo "[WARN] No timeout command available - running without timeout" >&2
		"$@"
	fi
}

print_info() {
	local msg="$1"
	echo -e "${BLUE}[INFO]${NC} $msg"
	return 0
}
print_success() {
	local msg="$1"
	echo -e "${GREEN}[OK]${NC} $msg"
	return 0
}
print_warning() {
	local msg="$1"
	echo -e "${YELLOW}[WARN]${NC} $msg"
	return 0
}
print_error() {
	local msg="$1"
	echo -e "${RED}[ERROR]${NC} $msg"
	return 0
}
print_header() {
	local msg="$1"
	echo -e "${BOLD}${CYAN}$msg${NC}"
	return 0
}

# Get current version
get_version() {
	if [[ -f "$VERSION_FILE" ]]; then
		cat "$VERSION_FILE"
	else
		echo "unknown"
	fi
}

# Get remote version
get_remote_version() {
	# Use GitHub API (not cached) instead of raw.githubusercontent.com (cached 5 min)
	local version
	if command -v jq &>/dev/null; then
		version=$(curl -fsSL "https://api.github.com/repos/marcusquinn/aidevops/contents/VERSION" 2>/dev/null | jq -r '.content // empty' 2>/dev/null | base64 -d 2>/dev/null | tr -d '\n')
		if [[ -n "$version" ]]; then
			echo "$version"
			return 0
		fi
	fi
	# Fallback to raw (cached) if jq unavailable or API fails
	curl -fsSL "https://raw.githubusercontent.com/marcusquinn/aidevops/main/VERSION" 2>/dev/null || echo "unknown"
}

get_public_release_tag() {
	local repo="$1"
	local tag=""

	tag=$(_timeout_cmd 15 curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null |
		grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v?[^"]+"' |
		head -1 |
		sed -E 's/.*"v?([^"]+)"/\1/' || true)

	printf '%s\n' "$tag"
	return 0
}

# Check if a command exists
check_cmd() {
	local cmd="$1"
	command -v "$cmd" >/dev/null 2>&1
}

# Check if a directory exists
check_dir() {
	local dir="$1"
	[[ -d "$dir" ]]
}

# Check if a file exists
check_file() {
	local file="$1"
	[[ -f "$file" ]]
}

# Ensure file ends with a trailing newline (prevents malformed appends)
ensure_trailing_newline() {
	local file="$1"
	local last
	if [[ -s "$file" ]]; then
		last="$(
			tail -c 1 "$file"
			printf x
		)"
		if [[ "$last" != $'\n'x ]]; then
			printf '\n' >>"$file"
		fi
	fi
	return 0
}

# Source CLI implementation modules from the coherent canonical or deployed
# tree selected above. The launcher executes the deployed orchestrator as a
# regular file, while local development and package snapshots use .agents/.
AIDEVOPS_CLI_MODULES_DIR="${_AIDEVOPS_CLI_ROOT}/${_AIDEVOPS_CLI_MODULES_SUBDIR}"
AIDEVOPS_RUNTIME_BUNDLE_VERIFIER="${AIDEVOPS_CLI_MODULES_DIR%/aidevops-cli}/runtime-bundle-verifier.sh"
unset _AIDEVOPS_CLI_ROOT _AIDEVOPS_CLI_MODULES_SUBDIR
# shellcheck source=.agents/scripts/aidevops-cli/aidevops-repos-lib.sh
# shellcheck disable=SC1091  # module path resolved at runtime via $INSTALL_DIR
source "${AIDEVOPS_CLI_MODULES_DIR}/aidevops-repos-lib.sh"
# shellcheck source=.agents/scripts/aidevops-cli/repo-discovery-lib.sh
# shellcheck disable=SC1091
source "${AIDEVOPS_CLI_MODULES_DIR}/repo-discovery-lib.sh"
# shellcheck source=.agents/scripts/aidevops-cli/aidevops-init-lib.sh
# shellcheck disable=SC1091
source "${AIDEVOPS_CLI_MODULES_DIR}/aidevops-init-lib.sh"
# shellcheck source=.agents/scripts/aidevops-cli/aidevops-skills-plugin-lib.sh
# shellcheck disable=SC1091
source "${AIDEVOPS_CLI_MODULES_DIR}/aidevops-skills-plugin-lib.sh"
# shellcheck source=.agents/scripts/aidevops-cli/aidevops-status-lib.sh
# shellcheck disable=SC1091
source "${AIDEVOPS_CLI_MODULES_DIR}/aidevops-status-lib.sh"
# shellcheck source=.agents/scripts/aidevops-cli/aidevops-update-lib.sh
# shellcheck disable=SC1091
source "${AIDEVOPS_CLI_MODULES_DIR}/aidevops-update-lib.sh"
# shellcheck source=.agents/scripts/aidevops-cli/aidevops-upgrade-planning-lib.sh
# shellcheck disable=SC1091
source "${AIDEVOPS_CLI_MODULES_DIR}/aidevops-upgrade-planning-lib.sh"
# shellcheck source=.agents/scripts/runtime-bundle-verifier.sh
# shellcheck disable=SC1091
source "$AIDEVOPS_RUNTIME_BUNDLE_VERIFIER"

_run_update_setup() {
	local output_mode="${1:-${AIDEVOPS_OUTPUT_MODE:-auto}}"
	local setup_script="${INSTALL_DIR}/setup.sh"
	if [[ ! -f "$setup_script" ]]; then
		print_error "setup.sh not found at $setup_script"
		return 1
	fi
	local use_compact=false
	case "$output_mode" in
	compact) use_compact=true ;;
	full) use_compact=false ;;
	auto) [[ ! -t 1 ]] && use_compact=true ;;
	*)
		print_error "Unknown update output mode: $output_mode"
		return 1
		;;
	esac
	local sandbox_helper="${INSTALL_DIR}/.agents/scripts/output-sandbox-helper.sh"
	if [[ "$use_compact" == "true" && -x "$sandbox_helper" ]]; then
		"$sandbox_helper" run \
			--tag aidevops-update-setup \
			--success-mode receipt \
			--failure-mode diagnostic \
			--expect-text '[SETUP_COMPLETE]' \
			-- bash "$setup_script" --stage ai-session
		return $?
	fi
	bash "$setup_script" --stage ai-session
	return $?
}

_update_verify_deployment_state() {
	local expected_sha="$1"
	local active_link="$_AIDEVOPS_REAL_HOME/.aidevops/agents"
	local stamp_file="$_AIDEVOPS_REAL_HOME/.aidevops/.deployed-sha"

	verify_aidevops_runtime_bundle_convergence \
		"$INSTALL_DIR" \
		"$expected_sha" \
		"$active_link" \
		"$stamp_file"
	return $?
}

_run_update_setup_transaction() {
	local output_mode="$1"
	local expected_sha="$2"
	local setup_exit=0
	_run_update_setup "$output_mode" || setup_exit=$?
	if [[ "$setup_exit" -ne 0 ]]; then
		print_error "Agent deployment failed: setup exited with code $setup_exit"
		return 1
	fi
	_update_verify_deployment_state "$expected_sha" || return 1
	return 0
}

_run_update_source_access_reconciliation() {
	local broker_dir="/etc/aidevops/source-access"
	local deployed_scripts="${_AIDEVOPS_REAL_HOME}/.aidevops/agents/scripts"
	local broker_current=true

	[[ -f "$deployed_scripts/source_access_core.py" ]] || return 0
	[[ -f "$deployed_scripts/source-access-helper.py" ]] || return 0
	[[ -f "$broker_dir/source_access_core.py" && ! -L "$broker_dir/source_access_core.py" ]] || broker_current=false
	[[ -f "$broker_dir/source-access-helper.py" && ! -L "$broker_dir/source-access-helper.py" ]] || broker_current=false
	[[ -f "$broker_dir/source-access.pub" && ! -L "$broker_dir/source-access.pub" ]] || broker_current=false
	[[ -f "$broker_dir/source-access.trust" && ! -L "$broker_dir/source-access.trust" ]] || broker_current=false
	[[ ! -w "$broker_dir" ]] || broker_current=false
	[[ ! -w "$broker_dir/source_access_core.py" ]] || broker_current=false
	[[ ! -w "$broker_dir/source-access-helper.py" ]] || broker_current=false
	[[ ! -w "$broker_dir/source-access.pub" ]] || broker_current=false
	[[ ! -w "$broker_dir/source-access.trust" ]] || broker_current=false
	if [[ "$broker_current" == "true" ]] &&
		/usr/bin/cmp -s "$deployed_scripts/source_access_core.py" "$broker_dir/source_access_core.py" &&
		/usr/bin/cmp -s "$deployed_scripts/source-access-helper.py" "$broker_dir/source-access-helper.py"; then
		return 0
	fi

	print_warning "AIDEVOPS_DEFERRED_ACTION action=source-access-reconcile command='aidevops setup --scope source-access'"
	return 0
}

_update_render_changelog() {
	local old_hash="$1"
	local new_hash="$2"
	local current_version="$3"
	local total_commits=0
	total_commits=$(git -C "$INSTALL_DIR" rev-list --count "$old_hash..$new_hash" 2>/dev/null || echo "0")
	if [[ "$total_commits" -eq 0 ]]; then
		return 0
	fi
	echo ""
	print_info "Changes since $current_version ($total_commits commits):"
	git -C "$INSTALL_DIR" --no-pager log --oneline --max-count=20 "$old_hash..$new_hash" || true
	if [[ "$total_commits" -gt 20 ]]; then
		echo "  ... and more (run 'git log --oneline' in $INSTALL_DIR for full list)"
	fi
	return 0
}

# Update/upgrade command
cmd_update_help() {
	echo "Usage: aidevops update [OPTIONS]"
	echo ""
	echo "Update the AI DevOps Framework."
	echo ""
	echo "Options:"
	echo "  --skip-project-sync  Skip registered project synchronization"
	echo "  --compact            Reduce update output"
	echo "  --verbose            Show full update output"
	echo "  -h, --help           Show this help message"
	return 0
}

cmd_update() {
	# Update is operational, not compositional. Do not let any reachable Git,
	# package-manager, migration, or setup subprocess inherit an editor or pager.
	# Local declarations restore the caller's environment when this function exits.
	local EDITOR=/usr/bin/false
	local VISUAL=/usr/bin/false
	local GIT_EDITOR=/usr/bin/false
	local GIT_SEQUENCE_EDITOR=/usr/bin/false
	local GIT_PAGER=cat
	local PAGER=cat
	local GIT_TERMINAL_PROMPT=0
	export EDITOR VISUAL GIT_EDITOR GIT_SEQUENCE_EDITOR GIT_PAGER PAGER GIT_TERMINAL_PROMPT
	local skip_project_sync=false
	local reconcile_repo_verify=false
	local update_output_mode="${AIDEVOPS_OUTPUT_MODE:-auto}"
	local arg
	for arg in "$@"; do
		case "$arg" in
		--skip-project-sync) skip_project_sync=true ;;
		--compact) update_output_mode="compact" ;;
		--verbose) update_output_mode="full" ;;
		esac
	done
	print_header "Updating AI DevOps Framework"
	echo ""
	local current_version
	current_version=$(get_version)
	print_info "Current version: $current_version"
	print_info "Fetching latest version..."

	if check_dir "$INSTALL_DIR/.git"; then
		cd "$INSTALL_DIR" || exit 1
		if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
			print_error "Refusing to update: tracked local changes exist in $INSTALL_DIR"
			git status --short
			print_info "Commit or stash these changes, then rerun aidevops update."
			return 1
		fi
		local current_branch
		current_branch=$(git branch --show-current 2>/dev/null || echo "")
		if [[ "$current_branch" != "main" ]]; then
			print_info "Switching to main branch..."
			if ! git checkout main --quiet 2>/dev/null && ! git checkout -b main origin/main --quiet 2>/dev/null; then
				print_error "Failed to switch to main; refusing to update the active '$current_branch' branch."
				return 1
			fi
		fi
		local local_hash
		local_hash=$(git rev-parse HEAD) || return 1
		if ! _update_fetch_main main; then
			print_error "Failed to fetch origin/main; no update was applied."
			return 1
		fi
		local remote_hash
		remote_hash=$(git rev-parse origin/main) || return 1
		if [[ "$local_hash" != "$remote_hash" ]] && git merge-base --is-ancestor "$remote_hash" "$local_hash" 2>/dev/null; then
			print_error "Refusing to update: local commits exist on main."
			print_info "Preserve or reconcile the local history in $INSTALL_DIR, then rerun aidevops update."
			return 1
		fi
		if [[ "$local_hash" == "$remote_hash" ]]; then
			print_success "Framework already up to date!"
			local repo_version deployed_version
			repo_version=$(cat "$INSTALL_DIR/VERSION" 2>/dev/null || echo "unknown")
			deployed_version=$(cat "$HOME/.aidevops/agents/VERSION" 2>/dev/null || echo "none")
			if [[ "$repo_version" != "$deployed_version" ]]; then
				print_warning "Deployed agents ($deployed_version) don't match repo ($repo_version)"
				print_info "Re-running incremental setup to sync agents..."
				_run_update_setup_transaction "$update_output_mode" "$local_hash" || return 1
			else
				# t2706: VERSION matches but .deployed-sha may lag HEAD when
				# fixes land between releases. Detect and redeploy on framework
				# code drift (inline so bootstrap doesn't depend on the deployed
				# aidevops-update-check.sh already carrying the same check).
				# Docs-only drift is intentionally skipped — no runtime impact.
				local stamp_file="$HOME/.aidevops/.deployed-sha"
				if [[ -f "$stamp_file" ]]; then
					local deployed_sha has_code_drift=0
					deployed_sha=$(tr -d '[:space:]' <"$stamp_file" 2>/dev/null) || deployed_sha=""
					if [[ -n "$deployed_sha" && "$deployed_sha" != "$local_hash" ]]; then
						if _update_repo_verify_files_changed "$deployed_sha" "$local_hash"; then reconcile_repo_verify=true; fi
						# Per Gemini code-review on PR #20342: use git's path filter +
						# `grep -q .` to detect drift across the full set of deploy-affecting
						# paths (not just .agents/ subdirs — also setup.sh, .agents/scripts/setup/modules/,
						# and aidevops.sh itself, which are deployed/sourced by setup).
						if git -C "$INSTALL_DIR" diff --name-only "$deployed_sha" "$local_hash" -- \
							.agents/scripts/ .agents/agents/ .agents/workflows/ .agents/prompts/ .agents/hooks/ \
							setup.sh .agents/scripts/setup/modules/ aidevops.sh 2>/dev/null | grep -q .; then
							has_code_drift=1
						fi
						if [[ "$has_code_drift" -eq 1 ]]; then
							print_warning "Deployed scripts drifted (${deployed_sha:0:7}→${local_hash:0:7})"
							print_info "Re-running incremental setup to deploy latest scripts..."
							_run_update_setup_transaction "$update_output_mode" "$local_hash" || return 1
						fi
						# GH#21735: workflow templates can change between
						# releases without triggering has_code_drift (templates
						# live outside the deploy-affecting paths). Check the
						# template subset separately and surface drift.
						_update_check_workflow_drift "$deployed_sha" "$local_hash"
					fi
				fi
			fi
		else
			print_info "Applying latest changes..."
			local old_hash
			old_hash="$local_hash"
			if [[ "${_AIDEVOPS_UPDATE_CANONICAL_FAST_FORWARDED:-false}" == "true" ]]; then
				:
			elif git merge --ff-only "$remote_hash" --quiet; then
				:
			else
				print_error "Fast-forward update failed; preserving local history."
				print_info "Review $INSTALL_DIR, resolve the divergence, then rerun aidevops update."
				return 1
			fi
			local new_version new_hash
			new_version=$(get_version)
			new_hash=$(git rev-parse HEAD)
			if [[ "$new_hash" != "$remote_hash" ]]; then
				print_error "Updated HEAD does not match the fetched origin/main commit; refusing to run setup."
				return 1
			fi
			if [[ "$old_hash" != "$new_hash" ]]; then
				if _update_repo_verify_files_changed "$old_hash" "$new_hash"; then reconcile_repo_verify=true; fi
				_update_render_changelog "$old_hash" "$new_hash" "$current_version"
				# GH#21735: surface workflow template drift so the
				# operator can resync downstream callers before CI bites.
				_update_check_workflow_drift "$old_hash" "$new_hash"
			fi
			echo ""
			# Verify supply chain integrity before applying changes
			_update_verify_signature
			echo ""
			print_info "Running incremental setup to apply changes (falls back to full setup if needed)..."
			_run_update_setup_transaction "$update_output_mode" "$new_hash" || return 1
			print_success "Updated to version $new_version (agents deployed)"
		fi
	else
		_update_fresh_install || return 1
	fi

	_run_update_source_access_reconciliation
	_update_sync_projects "$skip_project_sync" "$(get_version)"
	if [[ "$skip_project_sync" != "$_AIDEVOPS_UPDATE_TRUE" && "$reconcile_repo_verify" == "$_AIDEVOPS_UPDATE_TRUE" ]]; then
		_update_reconcile_repo_verify
	fi
	_update_check_homebrew
	_update_check_planning
	_update_check_tools
	_update_sweep_opencode_symlinks
	# t2926: Re-check setsid on every update (runs even when setup.sh is skipped).
	_update_check_setsid

	# t2898: When invoked interactively (terminal stdin AND not from the
	# auto-update daemon itself, which sets AIDEVOPS_AUTO_UPDATE=1 in its
	# environment), verify the daemon is healthy and warn if not. The
	# advisory file gets picked up by the next session greeting so the
	# user sees the warning even if they miss this output.
	#
	# Skip in headless / CI runs (no stdin, no TTY) to avoid spurious
	# warnings in setup.sh-driven flows that already do their own check.
	if [[ -t 0 ]] && [[ -z "${AIDEVOPS_AUTO_UPDATE:-}" ]] && [[ "${NON_INTERACTIVE:-false}" != "true" ]]; then
		_update_check_daemon_health
	fi

	# t2946: one-shot idempotent migration from legacy supervisor.* to canonical
	# orchestration.* namespace in settings.json. Safe: no-op when orchestration.*
	# is already set. Runs even on "already up to date" updates so users who
	# install the fix without a new release still get migrated on next 'aidevops update'.
	_migrate_settings_supervisor_to_orchestration

	# t2914: ensure pulse is running after every update. The existing
	# restart paths (setup.sh:1329, agent-deploy.sh:601) call
	# pulse-lifecycle-helper.sh restart-if-running which is a silent no-op
	# when pulse is dead — so a dead pulse stays dead through any number
	# of subsequent updates. The 'start' subcommand is idempotent
	# (pulse-lifecycle-helper.sh:127-131): no-op when running, starts when
	# dead. This belt-and-braces call after the daemon health check
	# guarantees the pulse is alive when 'aidevops update' returns,
	# regardless of whether scripts were redeployed.
	#
	# Honour AIDEVOPS_SKIP_PULSE_RESTART=1 at the call site (the helper's
	# 'start' subcommand does not check it directly — only 'restart' and
	# 'restart-if-running' do). Non-fatal: a pulse start failure should
	# not fail the update.
	if [[ "${AIDEVOPS_SKIP_PULSE_RESTART:-0}" != "1" ]]; then
		local _pulse_helper="${AGENTS_DIR}/scripts/pulse-lifecycle-helper.sh"
		if [[ -x "$_pulse_helper" ]]; then
			"$_pulse_helper" start >/dev/null 2>&1 || print_warning "Pulse start failed (non-fatal)"
		fi
	fi

	return 0
}

# t2898: post-update daemon health verification (interactive only).
# Side effect: writes ~/.aidevops/advisories/daemon-disabled.advisory when
# the daemon is unhealthy so the session greeting surfaces the warning.
# Cleared (file removed) when the daemon recovers.
# Uninstall helpers (extracted for complexity reduction)
_uninstall_cleanup_refs() {
	print_info "Removing AI assistant configuration references..."
	local ai_agent_files=("$HOME/.config/opencode/agent/AGENTS.md" "$HOME/.claude/commands/AGENTS.md" "$HOME/.opencode/AGENTS.md")
	for file in "${ai_agent_files[@]}"; do
		if check_file "$file"; then
			grep -q "Add ~/.aidevops/agents/AGENTS.md" "$file" 2>/dev/null && {
				rm -f "$file"
				print_success "Removed $file"
			}
		fi
	done
	print_info "Removing shell aliases..."
	for rc_file in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile"; do
		if check_file "$rc_file" && grep -q "# AI Assistant Server Access Framework" "$rc_file" 2>/dev/null; then
			cp "$rc_file" "$rc_file.bak"
			sed_inplace '/# AI Assistant Server Access Framework/,/^$/d' "$rc_file"
			print_success "Removed aliases from $rc_file"
		fi
	done
	print_info "Removing AI memory files..."
	local mf="$HOME/CLAUDE.md"
	check_file "$mf" && {
		rm -f "$mf"
		print_success "Removed $mf"
	}
	return 0
}

# Uninstall command
cmd_uninstall() {
	print_header "Uninstall AI DevOps Framework"
	echo ""
	print_warning "This will remove:"
	echo "  - $AGENTS_DIR (deployed agents)"
	echo "  - $INSTALL_DIR (repository)"
	echo "  - AI assistant configuration references"
	echo "  - Shell aliases (if added)"
	echo ""
	print_warning "This will NOT remove:"
	echo "  - Installed tools (Tabby, Zed, gh, glab, etc.)"
	echo "  - SSH keys"
	echo "  - Python/Node environments"
	echo ""
	read -r -p "Are you sure you want to uninstall? (yes/no): " confirm
	[[ "$confirm" != "yes" ]] && {
		print_info "Uninstall cancelled"
		return 0
	}
	echo ""
	check_dir "$AGENTS_DIR" && {
		print_info "Removing $AGENTS_DIR..."
		rm -rf "$AGENTS_DIR"
		print_success "Removed agents directory"
	}
	check_dir "$HOME/.aidevops" && {
		print_info "Removing $HOME/.aidevops..."
		rm -rf "$HOME/.aidevops"
		print_success "Removed aidevops config directory"
	}
	_uninstall_cleanup_refs
	echo ""
	read -r -p "Also remove the repository at $INSTALL_DIR? (yes/no): " remove_repo
	if [[ "$remove_repo" == "yes" ]]; then
		check_dir "$INSTALL_DIR" && {
			print_info "Removing $INSTALL_DIR..."
			rm -rf "$INSTALL_DIR"
			print_success "Removed repository"
		}
	else print_info "Keeping repository at $INSTALL_DIR"; fi
	echo ""
	print_success "Uninstall complete!"
	print_info "To reinstall, run:"
	echo "  npm install -g aidevops && aidevops update"
	echo "  OR: brew install marcusquinn/tap/aidevops && aidevops update"
}



# Features command - list available features
cmd_features() {
	print_header "AI DevOps Features"
	echo ""

	echo "Available features for 'aidevops init':"
	echo ""
	echo "  planning       TODO.md and PLANS.md task management"
	echo "                 - Quick task tracking in TODO.md"
	echo "                 - Complex execution plans in todo/PLANS.md"
	echo "                 - PRD and task file generation"
	echo ""
	echo "  git-workflow   Branch management and PR workflows"
	echo "                 - Automatic branch suggestions"
	echo "                 - Preflight quality checks"
	echo "                 - PR creation and review"
	echo ""
	echo "  code-quality   Linting and code auditing"
	echo "                 - ShellCheck, secretlint, pattern checks"
	echo "                 - Remote auditing (CodeRabbit, Codacy, SonarCloud)"
	echo "                 - Code standards compliance"
	echo ""
	echo "  time-tracking  Time estimation and tracking"
	echo "                 - Estimate format: ~4h (ai:2h test:1h)"
	echo "                 - Automatic started:/completed: timestamps"
	echo "                 - Release time summaries"
	echo ""
	echo "  database       Declarative database schema management"
	echo "                 - schemas/ for declarative SQL/TypeScript"
	echo "                 - migrations/ for versioned changes"
	echo "                 - seeds/ for initial/test data"
	echo "                 - Auto-generate migrations on schema diff"
	echo ""
	echo "  beads          Task graph visualization with Beads"
	echo "                 - Dependency tracking (blocked-by:, blocks:)"
	echo "                 - Graph visualization with bd CLI"
	echo "                 - Ready task detection (/ready)"
	echo "                 - Bi-directional sync with TODO.md/PLANS.md"
	echo ""
	echo "  sops           Encrypted config files with SOPS + age"
	echo "                 - Value-level encryption (keys visible, values encrypted)"
	echo "                 - .sops.yaml with age backend (simpler than GPG)"
	echo "                 - Patterns: *.secret.yaml, configs/*.enc.json"
	echo "                 - See: .agents/tools/credentials/sops.md"
	echo ""
	echo "  security       Per-repo security posture assessment"
	echo "                 - GitHub Actions workflow scanning (injection risks)"
	echo "                 - Branch protection verification (PR reviews)"
	echo "                 - Review-bot-gate status check"
	echo "                 - Dependency vulnerability scanning (npm/pip/cargo)"
	echo "                 - Collaborator access audit"
	echo "                 - Re-run anytime: aidevops security audit"
	echo ""
	echo "  deployment-context  Tracked project deployment inventory"
	echo "                      - Creates .aidevops/deployments.yaml"
	echo "                      - Alias: hosting-context"
	echo ""
	echo "  wordpress-context   Tracked WordPress and LocalWP project context"
	echo "                      - Creates both project context manifests"
	echo "                      - Includes deployment-context automatically"
	echo ""
	echo "Extensibility:"
	echo ""
	echo "  plugins        Third-party agent plugins (configured in .aidevops.json)"
	echo "                 - Git repos deployed to ~/.aidevops/agents/<namespace>/"
	echo "                 - Namespaced to avoid collisions with core agents"
	echo "                 - Enable/disable per-plugin without removal"
	echo "                 - See: .agents/aidevops/plugins.md"
	echo ""
	echo "Usage:"
	echo "  aidevops init                    # Enable default features (except sops and project contexts)"
	echo "  aidevops init planning           # Enable only planning"
	echo "  aidevops init sops               # Enable SOPS encryption"
	echo "  aidevops init security           # Enable security posture checks"
	echo "  aidevops init beads              # Enable beads (includes planning)"
	echo "  aidevops init database           # Enable only database"
	echo "  aidevops init deployment-context # Scaffold deployment inventory"
	echo "  aidevops init wordpress-context  # Scaffold WordPress + deployment context"
	echo "  aidevops init planning,security  # Enable multiple"
	echo ""
}

# Update tools command - check and update installed tools
# Passes all arguments through to tool-version-check.sh
cmd_update_tools() {
	print_header "Tool Version Check"
	echo ""

	local tool_check_script="$AGENTS_DIR/scripts/tool-version-check.sh"

	if [[ ! -f "$tool_check_script" ]]; then
		print_error "Tool version check script not found"
		print_info "Run 'aidevops update' first to get the latest scripts"
		return 1
	fi

	# Pass all arguments through to the script
	bash "$tool_check_script" "$@"
}

# Repos helpers (extracted for complexity reduction)
_repos_list() {
	print_header "Registered AI DevOps Projects"
	echo ""
	init_repos_file
	command -v jq &>/dev/null || {
		print_error "jq required for repo management"
		return 1
	}
	local count
	count=$(jq '.initialized_repos | length' "$REPOS_FILE" 2>/dev/null || echo "0")
	if [[ "$count" == "0" ]]; then
		print_info "No projects registered yet"
		echo ""
		echo "Initialize a project with: aidevops init"
		return 0
	fi
	local current_ver
	current_ver=$(get_version)
	jq -r '.initialized_repos[] | "\(.path)|\(.version)|\((.features // []) | join(","))|\(if .maintenance == false then false else true end)|\(.pulse // false)"' "$REPOS_FILE" 2>/dev/null | while IFS='|' read -r path version features maintenance pulse; do
		local name
		name=$(basename "$path")
		local status="✓" status_color="$GREEN"
		[[ "$version" != "$current_ver" ]] && {
			status="↑"
			status_color="$YELLOW"
		}
		[[ ! -d "$path" ]] && {
			status="✗"
			status_color="$RED"
		}
		echo -e "${status_color}${status}${NC} ${BOLD}$name${NC}"
		echo "    Path: $path"
		echo "    Version: $version"
		echo "    Features: $features"
		if [[ "$maintenance" == "true" ]]; then
			echo "    Automation: maintained (Pulse: $pulse)"
		else
			echo "    Automation: dormant (Pulse: off)"
		fi
		echo ""
	done
	echo "Legend: ✓ up-to-date  ↑ update available  ✗ not found"
	return 0
}

_repos_add() {
	local bootstrap_slug=""
	local confirmation=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--slug)
			bootstrap_slug="${2:-}"
			shift 2
			;;
		--confirm)
			confirmation="${2:-}"
			shift 2
			;;
		*)
			print_error "Usage: aidevops repos add [--slug OWNER/REPO --confirm REGISTER_CANONICAL_REPOSITORY]"
			return 2
			;;
		esac
	done
	git rev-parse --is-inside-work-tree &>/dev/null || {
		print_error "Not in a git repository"
		return 1
	}
	local project_root
	project_root=$(git rev-parse --show-toplevel)
	if [[ ! -f "$project_root/.aidevops.json" ]]; then
		if [[ -z "$bootstrap_slug" || "$confirmation" != "REGISTER_CANONICAL_REPOSITORY" ]]; then
			print_error "No .aidevops.json found - run 'aidevops init' or use the confirmed --slug bootstrap form"
			return 1
		fi
		local recovery_helper="${AGENTS_DIR}/scripts/canonical-recovery-helper.sh"
		[[ -x "$recovery_helper" ]] || {
			print_error "Canonical bootstrap verifier is unavailable"
			return 1
		}
		"$recovery_helper" verify-bootstrap-registration --repo "$project_root" \
			--slug "$bootstrap_slug" --confirm "$confirmation" || return 1
	elif [[ -n "$bootstrap_slug" || -n "$confirmation" ]]; then
		print_error "The --slug bootstrap form is only valid when .aidevops.json is absent"
		return 1
	fi
	local version features
	if [[ -f "$project_root/.aidevops.json" ]] && command -v jq &>/dev/null; then
		version=$(jq -r '.version' "$project_root/.aidevops.json" 2>/dev/null || echo "unknown")
		features=$(jq -r '[.features | to_entries[] | select(.value == true) | .key] | join(",")' "$project_root/.aidevops.json" 2>/dev/null || echo "")
	else
		version="unknown"
		features=""
	fi
	register_repo "$project_root" "$version" "$features" "$bootstrap_slug"
	print_success "Registered $(basename "$project_root")"
	return 0
}

_repos_remove() {
	local repo_path="${1:-}"
	local original_path="$repo_path"
	if [[ -z "$repo_path" ]]; then
		git rev-parse --is-inside-work-tree &>/dev/null && repo_path=$(git rev-parse --show-toplevel) && original_path="$repo_path" || {
			print_error "Specify a repo path or run from within a git repo"
			return 1
		}
	fi
	repo_path=$(cd "$repo_path" 2>/dev/null && pwd -P) || repo_path="$original_path"
	command -v jq &>/dev/null || {
		print_error "jq required for repo management"
		return 1
	}
	local temp_file="${REPOS_FILE}.tmp"
	jq --arg path "$repo_path" '.initialized_repos |= map(select(.path != $path))' "$REPOS_FILE" >"$temp_file" && mv "$temp_file" "$REPOS_FILE"
	print_success "Removed $repo_path from registry"
	return 0
}

_repos_clean() {
	print_info "Cleaning up stale repo entries..."
	command -v jq &>/dev/null || {
		print_error "jq required for repo management"
		return 1
	}
	local removed=0 temp_file="${REPOS_FILE}.tmp"
	while IFS= read -r repo_path; do
		[[ -z "$repo_path" ]] && continue
		if [[ ! -d "$repo_path" ]]; then
			jq --arg path "$repo_path" '.initialized_repos |= map(select(.path != $path))' "$REPOS_FILE" >"$temp_file" && mv "$temp_file" "$REPOS_FILE"
			print_info "Removed: $repo_path"
			removed=$((removed + 1))
		fi
	done < <(get_registered_repos)
	[[ $removed -eq 0 ]] && print_success "No stale entries found" || print_success "Removed $removed stale entries"
	return 0
}

_repos_maintenance() {
	local state="${1:-}"
	local selector="${2:-}"
	case "$state" in
	on | true | maintained) state="true" ;;
	off | false | dormant | paused) state="false" ;;
	*)
		print_error "Usage: aidevops repos maintenance <on|off> [slug-or-path]"
		return 2
		;;
	esac

	if [[ -z "$selector" ]]; then
		if ! git rev-parse --is-inside-work-tree &>/dev/null; then
			print_error "Specify a repo slug/path or run from within a registered repo"
			return 1
		fi
		selector=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
	fi

	set_repo_maintenance "$selector" "$state" || return $?
	local result
	result=$(get_repo_maintenance_state "$selector") || return 1
	local maintenance pulse slug path
	IFS=$'\t' read -r maintenance pulse slug path <<<"$result"
	local label="${slug:-$path}"
	if [[ "$maintenance" == "true" ]]; then
		print_success "Maintenance enabled for $label (Pulse remains $pulse)"
	else
		print_success "Maintenance paused for $label (registration retained; Pulse disabled)"
	fi
	return 0
}

# Repos management command
cmd_repos() {
	local action="${1:-list}"
	case "$action" in
	list | ls) _repos_list ;;
	add)
		shift
		_repos_add "$@"
		;;
	remove | rm) _repos_remove "${2:-}" ;;
	clean) _repos_clean ;;
	migrate-layout)
		shift
		local migrate_helper="${AIDEVOPS_CLI_MODULES_DIR%/aidevops-cli}/repo-layout-migrate-helper.sh"
		[[ -f "$migrate_helper" ]] || migrate_helper="${AGENTS_DIR}/scripts/repo-layout-migrate-helper.sh"
		if [[ ! -x "$migrate_helper" ]]; then
			print_error "Repository layout migration helper is unavailable"
			return 1
		fi
		"$migrate_helper" "$@"
		;;
	maintenance | maintain)
		shift
		_repos_maintenance "$@"
		;;
	*)
		echo "Usage: aidevops repos <command>"
		echo ""
		echo "Commands:"
		echo "  list     List all registered projects (default)"
		echo "  add      Register current project; confirmed --slug bootstraps config-free canonical repos"
		echo "  remove   Remove project from registry"
		echo "  clean    Remove entries for non-existent projects"
		echo "  migrate-layout <plan|apply|rollback|status>"
		echo "           Guarded owner-layout migration with durable receipts"
		echo "  maintenance <on|off> [repo]"
		echo "           Include/exclude a registered repo from recurring automation"
		;;
	esac
}

# Detect command - check for unregistered aidevops repos
cmd_detect() {
	print_header "Detecting AI DevOps Projects"
	echo ""

	# Check current directory first
	local unregistered
	unregistered=$(detect_unregistered_repo)

	if [[ -n "$unregistered" ]]; then
		print_info "Found unregistered aidevops project:"
		echo "  $unregistered"
		echo ""
		read -r -p "Register this project? [Y/n] " response
		response="${response:-y}"
		if [[ "$response" =~ ^[Yy]$ ]]; then
			local version features
			if command -v jq &>/dev/null; then
				version=$(jq -r '.version' "$unregistered/.aidevops.json" 2>/dev/null || echo "unknown")
				features=$(jq -r '[.features | to_entries[] | select(.value == true) | .key] | join(",")' "$unregistered/.aidevops.json" 2>/dev/null || echo "")
			else
				version="unknown"
				features=""
			fi
			register_repo "$unregistered" "$version" "$features"
			print_success "Registered $(basename "$unregistered")"
		fi
		return 0
	fi

	# Scan common locations
	print_info "Scanning for aidevops projects in ~/Git/..."

	local found=0
	local to_register=()

	if [[ -d "$HOME/Git" ]]; then
		while IFS= read -r -d '' repo_dir; do
			local aidevops_json="$repo_dir/.aidevops.json"
			[[ -f "$aidevops_json" ]] || continue

			# Check if already registered
			init_repos_file
			if command -v jq &>/dev/null; then
				if ! jq -e --arg path "$repo_dir" '.initialized_repos[] | select(.path == $path)' "$REPOS_FILE" &>/dev/null; then
					to_register+=("$repo_dir")
					found=$((found + 1))
				fi
			fi
		done < <(aidevops_discover_canonical_repos "$HOME/Git")
	fi

	if [[ $found -eq 0 ]]; then
		print_success "No unregistered aidevops projects found"
		return 0
	fi

	echo ""
	print_info "Found $found unregistered project(s):"
	for repo in "${to_register[@]}"; do
		echo "  - $(basename "$repo") ($repo)"
	done

	echo ""
	read -r -p "Register all? [Y/n] " response
	response="${response:-y}"
	if [[ "$response" =~ ^[Yy]$ ]]; then
		for repo in "${to_register[@]}"; do
			local version features
			if command -v jq &>/dev/null; then
				version=$(jq -r '.version' "$repo/.aidevops.json" 2>/dev/null || echo "unknown")
				features=$(jq -r '[.features | to_entries[] | select(.value == true) | .key] | join(",")' "$repo/.aidevops.json" 2>/dev/null || echo "")
			else
				version="unknown"
				features=""
			fi
			register_repo "$repo" "$version" "$features"
			print_success "Registered $(basename "$repo")"
		done
	fi
	return 0
}

_cmd_setup_help() {
	printf '%s\n' "Usage: aidevops setup --scope <scope>"
	printf '%s\n' ""
	printf '%s\n' "Scopes:"
	printf '%s\n' "  opencode  Repair/install the OpenCode CLI only"
	printf '%s\n' "  agents    Deploy aidevops agents/scripts only"
	printf '%s\n' "  runtime-config  Reconcile generated runtime commands/configuration"
	printf '%s\n' "  source-access  Install/verify the signed root approval broker"
	printf '%s\n' "  hooks     Install safety hooks only"
	printf '%s\n' "  tabby     Sync Tabby terminal profiles only"
	printf '%s\n' "  pulse     Install/refresh the pulse scheduler only"
	printf '%s\n' "  gui-desktop  Install native macOS aidevops.app only"
	printf '%s\n' "  ai-session  Apply changed deploy stages; fall back to full setup if needed"
	printf '%s\n' "  full      Run ./setup.sh --non-interactive"
	return 0
}

cmd_setup() {
	local scope=""
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--scope)
			if [[ -z "${2:-}" ]]; then
				print_error "--scope requires a value"
				_cmd_setup_help
				return 1
			fi
			scope="$2"
			shift 2
			;;
		--scope=*)
			scope="${arg#--scope=}"
			shift
			;;
		help | --help | -h)
			_cmd_setup_help
			return 0
			;;
		*)
			print_error "Unknown setup option: $arg"
			_cmd_setup_help
			return 1
			;;
		esac
	done

	if [[ -z "$scope" ]]; then
		print_error "Missing required --scope value"
		_cmd_setup_help
		return 1
	fi

	local setup_script="${INSTALL_DIR}/setup.sh"
	if [[ ! -f "$setup_script" ]]; then
		print_error "setup.sh not found at $setup_script"
		return 1
	fi

	if [[ "$scope" == "full" ]]; then
		bash "$setup_script" --non-interactive
		return $?
	fi

	bash "$setup_script" --stage "$scope"
	return $?
}


# Help text helpers (extracted for complexity reduction)
_help_commands() {
	echo "Commands:"
	echo "  init [features]    Initialize aidevops in current project"
	echo "  setup --scope <s>  Run scoped setup/deploy (opencode, agents, source-access, hooks, tabby, pulse, gui-desktop, ai-session, full)"
	echo "  init-routines      Scaffold private routines repo (--org <name> | --local)"
	echo "  upgrade-planning   Upgrade TODO.md/PLANS.md to latest templates"
	echo "  features           List available features for init"
	echo "  skill <cmd>        Manage agent skills (add/list/check/update/remove)"
	echo "  skills <cmd>       Discover skills (search/browse/describe/recommend)"
	echo "  plugin <cmd>       Manage plugins (add/list/update/enable/disable/remove)"
	echo "  status             Check installation status of all components"
	echo "  doctor             Detect duplicate installs and PATH conflicts (--fix to resolve)"
	echo "  update             Update aidevops to the latest version (alias: upgrade)"
	echo "  upgrade            Alias for update"
	echo "  runtime-bundle     Inspect retained bundles or run an explicit audited rollback"
	echo "  release <cmd>      Publish/status/reconcile a provenance-bound aidevops release"
	echo "  pulse <cmd>        Session-based pulse control (start/stop/status)"
	echo "  schedule <cmd>     Durable one-shot jobs (once/status/cancel)"
	echo "  launch-worker      Manually launch headless workers for GitHub issues"
	echo "  worktree <cmd>     Manage safe linked worktrees (add/list/remove/status/switch/clean) (alias: wt)"
	echo "  auto-update <cmd>  Manage automatic update polling (enable/disable/status)"
	echo "  repo-sync <cmd>    Daily git pull for repos in parent dirs (enable/disable/status/dirs)"
	echo "  update-tools       Check for outdated tools (--update to auto-update)"
	echo "  repos [cmd]        Manage registered projects (list/add/remove/clean)"
	echo "  lint [cmd]         Audit/configure native repo lint, format, typecheck, and hooks"
	echo "  design <cmd>       DESIGN.md detection, scaffolding, and brand guideline exports"
	echo "  cleanup <cmd>      Cleanup helpers (remote branch audit/delete)"
	echo "  model-accounts-pool OAuth account pool (list/check/diagnose/add/rotate/reset-cooldowns)"
	echo "  gpt56-context <cmd> Manage the 300K GPT-5.6 OpenCode context cap (enable/disable/status)"
	echo "  client-format      Client request format alignment (extract/check/canary/monitor)"
	echo "  opencode-db <cmd>  OpenCode SQLite maintenance/session lookup (check/report/sessions/maintain/window/status/install)"
	echo "  opencode [agent] [args]    Launch OpenCode with Build+ and per-session DB isolation"
	echo "  codex|claude [agent] [args]  Launch with full permissions (default agent: build-plus)"
	echo "  <runtime> [agent] [args]     Also cursor, droid, gemini, continue, kilo, kiro, aider, amp, kimi, qwen"
	echo "                              Use <runtime> --help or --list-agents for launch options"
	echo "  opencode-desktop   Launch/install OpenCode Desktop with aidevops DB isolation"
	echo "  opencode-sandbox   Test OpenCode versions in isolation (install/run/check/clean)"
	echo "  approve <cmd>      Cryptographic issue/PR approval (setup/issue/pr/verify/status)"
	echo "  circuit-breaker    Supervisor circuit breaker (status/reset/check/trip) (alias: cb)"
	echo "  issue <cmd>        Interactive issue ownership (claim/release/status/scan-stale)"
	echo "  security [cmd]     Full security assessment (posture + hygiene + supply chain)"
	echo "  contributions      External contributions inbox (bare: status | seed/scan/stop/restart/install/uninstall)"
	echo "  inbox [cmd]        Capture transit zone (bare: status | provision/add/find/digest/help)"
	echo "  email [cmd]        Email mailbox management (mailbox add/list/test/remove)"
	echo "  ip-check <cmd>     IP reputation checks (check/batch/report/providers)"
	echo "  review-gate <cmd>  Configure review_gate merge policies (rate-limit/completion)"
	echo "  github-app-auth    GitHub App auth setup/status and API route decisions"
	echo "  source-access <cmd> Session-bound, sudo-signed source-read approvals"
	echo "  secret <cmd>       Manage secrets (set/list/run/init/import/status)"
	echo "  vault <cmd>        Local encrypted Vault broker (init/unlock/lock/status/read/update)"
	echo "  config <cmd>       Feature toggles (list/get/set/reset/path/help)"
	echo "  knowledge <cmd>    Knowledge plane management (init/status/provision)"
	echo "  campaign <cmd>     Campaign plane: init/provision/ls (P1) + asset (P4) + new/list/status/archive (P2) + draft (P5) + launch/promote (P6) + grow (orchestration)"
	echo "  stats <cmd>        LLM usage analytics (summary/models/projects/costs/trend)"
	echo "  tabby <cmd>        Manage Tabby terminal profiles (sync/status/zshrc/help)"
	echo "  buzz <cmd>         Manage Buzz Desktop OpenCode ACP compatibility"
	echo "  parent-status <N>  Show decomposition state of parent-task issue #N (alias: ps)"
	echo "  detect             Find and register aidevops projects"
	echo "  uninstall          Remove aidevops from your system"
	echo "  version            Show version information"
	echo "  help               Show this help message"
	return 0
}

_help_detailed_sections() {
	echo "Security:"
	echo "  aidevops security            # Run ALL checks (posture + hygiene + supply chain)"
	echo "  aidevops security posture    # Interactive security posture setup (gopass, gh, SSH)"
	echo "  aidevops security status     # Combined posture + hygiene summary"
	echo "  aidevops security scan       # Secret hygiene & supply chain scan"
	echo "  aidevops security scan-pth   # Python .pth file audit (supply chain IoC)"
	echo "  aidevops security scan-secrets # Plaintext credential locations"
	echo "  aidevops security scan-deps  # Unpinned dependency check"
	echo "  aidevops security supply-chain scan [path] # npm supply-chain IOC scan"
	echo "  aidevops security check      # Per-repo security posture assessment"
	echo "  aidevops security dismiss <id> # Dismiss a security advisory"
	echo ""
	echo "Temporary source access:"
	echo "  aidevops update                              # Install/verify broker during normal setup"
	echo "  sudo -k /usr/bin/python3 -I -B /etc/aidevops/source-access/source-access-helper.py approve <id> --ttl 12h"
	echo "  aidevops source-access status                    # List active/expired approvals"
	echo "  sudo -k /usr/bin/python3 -I -B /etc/aidevops/source-access/source-access-helper.py revoke <approval-id>"
	echo ""
	echo "IP Reputation:"
	echo "  aidevops ip-check check <ip> # Check IP reputation across providers"
	echo "  aidevops ip-check batch <f>  # Batch check IPs from file"
	echo "  aidevops ip-check report <ip># Generate markdown report"
	echo "  aidevops ip-check providers  # List available providers"
	echo "  aidevops ip-check cache-stats# Show cache statistics"
	echo ""
	echo "Model Accounts Pool (OAuth):"
	echo "  aidevops model-accounts-pool status            # Pool health at a glance"
	echo "  aidevops model-accounts-pool list              # Per-account detail"
	echo "  aidevops model-accounts-pool check             # Live token validity test"
	echo "  aidevops model-accounts-pool diagnose          # Full pipeline diagnostics (pool, plugin, CCH, runtime)"
	echo "  aidevops model-accounts-pool rotate [provider] # Switch to next available account NOW (use when rate-limited)"
	echo "  aidevops model-accounts-pool reset-cooldowns   # Clear rate-limit cooldowns"
	echo "  aidevops model-accounts-pool add anthropic     # Add Claude Pro/Max account"
	echo "  aidevops model-accounts-pool add openai        # Add ChatGPT Plus/Pro account"
	echo "  aidevops model-accounts-pool add cursor        # Add Cursor Pro account"
	echo "  aidevops model-accounts-pool add google        # Add Google AI Pro/Ultra/Workspace account"
	echo "  aidevops model-accounts-pool import claude-cli # Import from Claude CLI auth"
	echo "  aidevops model-accounts-pool assign-pending <provider># Assign stranded token"
	echo "  aidevops model-accounts-pool remove <provider> <email># Remove an account"
	echo ""
	echo "  Auth troubleshooting (run diagnose first, then recovery if needed):"
	echo "    aidevops model-accounts-pool diagnose        # 0. Full pipeline check (start here)"
	echo "    aidevops model-accounts-pool status          # 1. Check pool health"
	echo "    aidevops model-accounts-pool check           # 2. Test token validity"
	echo "    aidevops model-accounts-pool rotate anthropic# 3. Switch account if rate-limited"
	echo "    aidevops model-accounts-pool reset-cooldowns # 4. Clear cooldowns if all stuck"
	echo "    aidevops model-accounts-pool add anthropic   # 5. Re-add if pool empty"
	echo ""
	echo "Client Format:"
	echo "  aidevops client-format               # Show status + cached constants"
	echo "  aidevops client-format extract        # Re-extract constants from installed CLI"
	echo "  aidevops client-format check          # Verify cache matches installed CLI version"
	echo "  aidevops client-format canary         # Run drift check against real CLI (uses tokens)"
	echo "  aidevops client-format monitor [cmd]  # Traffic capture + diff (requires mitmproxy)"
	echo "  aidevops client-format install-canary # Install daily drift check (launchd)"
	echo ""
	echo "  If requests stop working after a CLI update:"
	echo "    aidevops client-format extract      # 1. Re-extract constants"
	echo "    aidevops client-format canary       # 2. Verify against real CLI"
	echo ""
	echo "Secrets:"
	echo "  aidevops secret set NAME     # Store a secret (hidden input)"
	echo "  aidevops secret list         # List secret names (never values)"
	echo "  aidevops secret run CMD      # Run with secrets injected + redacted"
	echo "  aidevops secret init         # Initialize gopass encrypted store"
	echo "  aidevops secret import       # Import from credentials.sh to gopass"
	echo "  aidevops secret status       # Show backend status"
	echo ""
	echo "Vault:"
	echo "  aidevops vault init          # Create local encrypted Vault metadata"
	echo "  aidevops vault status        # Show uninitialized/locked/unlocked/corrupted"
	echo "  aidevops vault unlock        # Unlock into an in-memory local broker"
	echo "  aidevops vault lock          # Stop broker and forget in-memory keys"
	echo "  aidevops vault read NAME     # Read protected data through broker"
	echo "  aidevops vault update NAME   # Encrypt stdin value through broker"
	echo ""
	echo "GitHub App Auth:"
	echo "  aidevops github-app-auth status --json       # Show active auth mode and budgets"
	echo "  aidevops github-app-auth route issue-list    # Explain route decision"
	echo "  aidevops github-app-auth rate-limit --json   # Show cached per-pool budgets"
	echo ""
	echo "Feature Toggles:"
	echo "  aidevops config list         # List all toggles with current values"
	echo "  aidevops config get <key>    # Get a toggle value"
	echo "  aidevops config set <k> <v>  # Set a toggle (true/false)"
	echo "  aidevops config reset [key]  # Reset toggle(s) to defaults"
	echo "  aidevops config path         # Show config file path"
	echo ""
	echo "Knowledge Plane:"
	echo "  aidevops knowledge init repo           # Provision _knowledge/ in current repo"
	echo "  aidevops knowledge init personal       # Provision at ~/.aidevops/.agent-workspace/knowledge/"
	echo "  aidevops knowledge init off            # Disable knowledge plane"
	echo "  aidevops knowledge status              # Show provisioning state"
	echo "  aidevops knowledge provision [path]    # Re-provision (idempotent)"
	echo "  aidevops knowledge add <file|url>      # Ingest file or URL into sources/"
	echo "  aidevops knowledge list [--state s] [--kind k]  # List all known sources"
	echo "  aidevops knowledge search <query>      # Search sources (grep fallback)"
	echo ""
	echo "Design Systems:"
	echo "  aidevops design detect [path]          # Detect whether a repo has a GUI/interface"
	echo "  aidevops design scaffold [path]        # Create DESIGN.md skeleton when missing"
	echo "  aidevops design guidelines [path] --pdf # Generate brand guideline HTML/PDF exports"
	echo "  aidevops design survey [--json]        # Audit owned initialized GUI repos"
	echo "  aidevops design issues --apply         # File auto-dispatch issues for missing design artifacts"
	echo ""
	echo "Campaign Plane:"
	echo "  aidevops campaign init [<path>]          # Provision _campaigns/ directory contract (P1)"
	echo "  aidevops campaign provision [<path>]     # Re-provision / repair (idempotent, P1)"
	echo "  aidevops campaign ls [--active|--launched|--all] [<path>]  # Directory listing (P1)"
	echo "  aidevops campaign new <name> --intake <file>   # Create validated active campaign (P2)"
	echo "  aidevops campaign update <id> --intake <file>  # Atomically update campaign intake (P2)"
	echo "  aidevops campaign migrate <id> --intake <file> # Explicitly upgrade a legacy brief (P2)"
	echo "  aidevops campaign list                         # Show all campaigns (P2)"
	echo "  aidevops campaign status <id>                  # Detailed dossier for a campaign (P2)"
	echo "  aidevops campaign archive <id>                 # Move launched/<id> → archive/ (P2)"
	echo "  aidevops campaign asset add <file> [--target lib-brand|lib-swipe|campaign]  # Ingest asset (P4)"
	echo "  aidevops campaign asset list [--type image|video|audio|pdf|all]             # List assets (P4)"
	echo "  aidevops campaign asset preview <file> [--size 640]                         # Generate preview PNG (P4)"
	echo "  aidevops campaign asset manifest <asset-id>                                 # Show asset manifest entry (P4)"
	echo "  aidevops campaign draft <id> --channel <ch>    # AI-generated content draft (P5)"
	echo "  aidevops campaign launch <id>                  # Move active/<id> → launched/, create templates (P6)"
	echo "  aidevops campaign promote <id> [--results|--learnings] # Cross-plane promotion (P6)"
	echo "  aidevops campaign feedback [<id>]              # Surface _feedback/ insights for research (P6)"
	echo "  aidevops campaign grow plan --intake <file>    # Non-mutating growth orchestration plan"
	echo "  aidevops campaign grow <start|status|resume> <id> # Evidence-backed growth checkpoint"
	echo ""
	echo "Performance Plane:"
	echo "  aidevops performance init                     # Provision _performance/marketing/"
	echo "  aidevops performance validate --adapter normalized --input <file>"
	echo "  aidevops performance ingest --adapter normalized --input <file> [--dry-run]"
	echo "  aidevops performance backfill --input <phase1.jsonl> [--dry-run]"
	echo "  aidevops performance list [--source <source>|--subjects|--results]"
	echo "  aidevops performance status [--json]           # Coverage, freshness, quarantine"
	echo "  aidevops performance reconcile --input <file>  # Append owner decisions"
	echo "  aidevops performance rebuild                   # Rebuild campaign summaries"
	echo "  aidevops performance export --purpose measurement|audience --output <file>"
	echo ""
	echo "LLM Stats:"
	echo "  aidevops stats               # Show usage summary (last 30 days)"
	echo "  aidevops stats summary       # Overall usage summary"
	echo "  aidevops stats models        # Per-model breakdown"
	echo "  aidevops stats projects      # Per-project breakdown"
	echo "  aidevops stats costs         # Cost analysis with category breakdown"
	echo "  aidevops stats trend         # Usage trends over time"
	echo "  aidevops stats ingest        # Parse new Claude JSONL log entries"
	echo "  aidevops stats sync-budget   # Sync to budget tracker (t1100)"
	echo ""
	echo "Supervisor Circuit Breaker (t1331):"
	echo "  aidevops circuit-breaker             # Show breaker state (alias: cb)"
	echo "  aidevops circuit-breaker status      # Show breaker state"
	echo "  aidevops circuit-breaker reset       # Manually reset (resumes worker dispatch)"
	echo "  aidevops circuit-breaker check       # Exit 0 if dispatch allowed, 1 if paused"
	echo "  aidevops circuit-breaker trip        # Manually trip (testing)"
	echo "  aidevops cb reset                    # Short alias for reset"
	echo ""
	echo "  When the breaker trips (auto-filed GH issue), copy/paste:"
	echo "    aidevops circuit-breaker reset"
	echo ""
	_help_management_sections
	return 0
}

_help_management_sections() {
	echo "Auto-Update:"
	echo "  aidevops auto-update enable  # Poll for updates every 10 min"
	echo "  aidevops auto-update disable # Stop auto-updating"
	echo "  aidevops auto-update status  # Show auto-update state"
	echo "  aidevops auto-update check   # One-shot check and update now"
	echo ""
	echo "Repo Sync:"
	echo "  aidevops repo-sync enable    # Enable daily git pull for repos"
	echo "  aidevops repo-sync disable   # Disable daily sync"
	echo "  aidevops repo-sync status    # Show sync state and last results"
	echo "  aidevops repo-sync check     # One-shot sync all repos now"
	echo "  aidevops repo-sync dirs list # List configured parent directories"
	echo "  aidevops repo-sync dirs add  # Add a parent directory"
	echo "  aidevops repo-sync dirs rm   # Remove a parent directory"
	echo "  aidevops repo-sync config    # Show/edit configuration"
	echo "  aidevops repo-sync logs      # View sync logs"
	echo ""
	echo "Agent Sources (private repos):"
	echo "  aidevops sources add <path>  # Add a local repo as agent source"
	echo "  aidevops sources add-remote <url> # Clone and add remote repo"
	echo "  aidevops sources remove <n>  # Remove a source (keeps agents)"
	echo "  aidevops sources list        # List configured sources"
	echo "  aidevops sources status      # Show sync status"
	echo "  aidevops sources sync        # Sync all sources to custom/"
	echo ""
	echo "Plugins:"
	echo "  aidevops plugin add <url>    # Install a plugin from git repo"
	echo "  aidevops plugin list         # List installed plugins"
	echo "  aidevops plugin update       # Update all plugins"
	echo "  aidevops plugin remove <n>   # Remove a plugin"
	echo ""
	echo "Skill Management:"
	echo "  aidevops skill add <source>  # Import a skill from GitHub"
	echo "  aidevops skill list          # List imported skills"
	echo "  aidevops skill check         # Check for upstream updates"
	echo "  aidevops skill update [name] # Update skills to latest"
	echo "  aidevops skill remove <name> # Remove an imported skill"
	echo ""
	echo "Skill Discovery:"
	echo "  aidevops skills search <q>   # Search skills by keyword"
	echo "  aidevops skills browse       # Browse skills by category"
	echo "  aidevops skills describe <n> # Show skill description"
	echo "  aidevops skills recommend <t># Suggest skills for a task"
	echo "  aidevops skills categories   # List all categories"
	echo ""
	echo "Installation:"
	echo "  brew install marcusquinn/tap/aidevops && aidevops update  # macOS/Homebrew"
	echo "  npm install -g aidevops && aidevops update                # Linux/cross-platform"
	echo ""
	echo "Documentation: https://github.com/marcusquinn/aidevops"
	return 0
}

# Help command
cmd_help() {
	local version
	version=$(get_version)
	echo "AI DevOps Framework CLI v$version"
	echo ""
	echo "Usage: aidevops <command> [options]"
	echo ""
	_help_commands
	echo ""
	echo "Examples:"
	echo "  aidevops init                # Initialize with all features"
	echo "  aidevops init planning       # Initialize with planning only"
	echo "  aidevops upgrade-planning    # Upgrade planning files to latest"
	echo "  aidevops features            # List available features"
	echo "  aidevops status              # Check what's installed"
	echo "  aidevops doctor              # Find duplicate/conflicting installs"
	echo "  aidevops doctor --fix        # Interactively remove duplicates"
	echo "  aidevops update              # Update framework + check projects"
	echo "  aidevops runtime-bundle list # List retained validated runtime bundle IDs"
	echo "  aidevops gpt56-context       # Manage the 300K GPT-5.6 OpenCode context cap"
	echo "  aidevops repos               # List registered projects"
	echo "  aidevops launch-worker 22259 marcusquinn/aidevops --dry-run"
	echo "  aidevops repos add           # Register current project"
	echo "  aidevops detect              # Find unregistered projects"
	echo "  aidevops update-tools        # Check for outdated tools"
	echo "  aidevops update-tools -u     # Update all outdated tools"
	echo "  aidevops uninstall           # Remove aidevops"
	echo ""
	_help_detailed_sections
	return 0
}

# Version command
cmd_version() {
	local current_version
	current_version=$(get_version)
	local remote_version
	remote_version=$(get_remote_version)

	echo "aidevops $current_version"

	if [[ "$remote_version" != "unknown" && "$current_version" != "$remote_version" ]]; then
		echo "Latest: $remote_version (run 'aidevops update' to upgrade)"
	fi
}

# Helper dispatch (extracted from main for complexity reduction)
_dispatch_helper() {
	local script_name="$1" error_name="$2"
	shift 2
	local coherent_hp="${AIDEVOPS_CLI_MODULES_DIR%/aidevops-cli}/$script_name"
	local deployed_hp="$AGENTS_DIR/scripts/$script_name"
	local hp="$coherent_hp"
	[[ ! -f "$hp" ]] && hp="$deployed_hp"
	if [[ -f "$hp" ]]; then
		bash "$hp" "$@"
		return $?
	fi
	print_error "$error_name not found. Run: aidevops update"
	return 1
}

_dispatch_config() {
	local ch="$AGENTS_DIR/scripts/config-helper.sh"
	[[ ! -f "$ch" ]] && ch="$INSTALL_DIR/.agents/scripts/config-helper.sh"
	[[ ! -f "$ch" ]] && ch="$AGENTS_DIR/scripts/feature-toggle-helper.sh"
	[[ ! -f "$ch" ]] && ch="$INSTALL_DIR/.agents/scripts/feature-toggle-helper.sh"
	if [[ -f "$ch" ]]; then
		bash "$ch" "$@"
	else
		print_error "config-helper.sh not found. Run: aidevops update"
		exit 1
	fi
	return 0
}

_launch_worker_usage() {
	cat <<'EOF'
Usage: aidevops launch-worker <issue|issue,issue> [owner/repo] [options]
       aidevops launch-worker --batch <issue,issue> [owner/repo] [options]
       aidevops launch-worker status <issue> [owner/repo]

Launch one or more headless workers manually without waiting for the pulse.
If owner/repo is omitted, it defaults to the current git repository's origin.

Options:
  --model <id>      Override model (for example, anthropic/claude-opus-4-7).
  --agent <name>    Worker agent name (default: Build+).
  --batch <list>    Comma-separated issue numbers to launch.
  --dry-run         Print the planned dispatch without launching.
  --no-ceremony     Skip status/origin/assignee ceremony (debug only).
  -h, --help        Show this help.

Output includes the worker PID, worktree path, log path, session key, and a
status command for each launched issue.
EOF
	return 0
}

_launch_worker_default_repo() {
	local remote_url=""
	remote_url=$(git remote get-url origin 2>/dev/null || true)
	if [[ "$remote_url" =~ github\.com[:/]([^/]+/[^/.]+)(\.git)?$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return 0
	fi
	return 1
}

_launch_worker_helper_path() {
	local source_dir helper_path
	source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	helper_path="$source_dir/.agents/scripts/dispatch-single-issue-helper.sh"
	[[ ! -f "$helper_path" ]] && helper_path="$INSTALL_DIR/.agents/scripts/dispatch-single-issue-helper.sh"
	[[ ! -f "$helper_path" ]] && helper_path="$AGENTS_DIR/scripts/dispatch-single-issue-helper.sh"
	if [[ ! -f "$helper_path" ]]; then
		print_error "dispatch-single-issue-helper.sh not found. Run: aidevops update"
		return 1
	fi
	printf '%s\n' "$helper_path"
	return 0
}

_launch_worker_status() {
	local status_issue="${1:-}"
	local status_repo="${2:-}"
	if [[ -z "$status_issue" ]]; then
		print_error "launch-worker status requires <issue> [owner/repo]"
		return 2
	fi
	if [[ -z "$status_repo" ]]; then
		status_repo=$(_launch_worker_default_repo) || {
			print_error "Could not infer owner/repo from git remote; pass it explicitly"
			return 2
		}
	fi
	local status_helper_path
	status_helper_path=$(_launch_worker_helper_path) || return 1
	bash "$status_helper_path" status "$status_issue" "$status_repo"
	return 0
}

cmd_launch_worker() {
	local sub_or_issue="${1:-}"
	if [[ -z "$sub_or_issue" || "$sub_or_issue" == "help" || "$sub_or_issue" == "--help" || "$sub_or_issue" == "-h" ]]; then
		_launch_worker_usage
		return 0
	fi

	if [[ "$sub_or_issue" == "status" ]]; then
		shift || true
		_launch_worker_status "$@"
		return $?
	fi

	local issue_spec=""
	local repo_slug=""
	local batch_spec=""
	local -a helper_opts=()
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--batch)
			if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
				print_error "--batch requires a comma-separated issue list"
				return 2
			fi
			batch_spec="${2}"
			shift 2
			;;
		--model | --agent)
			if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
				print_error "$arg requires a value"
				return 2
			fi
			helper_opts+=("$arg" "${2}")
			shift 2
			;;
		--dry-run | --no-ceremony)
			helper_opts+=("$arg")
			shift
			;;
		--help | -h)
			_launch_worker_usage
			return 0
			;;
		--*)
			print_error "Unknown launch-worker flag: $arg"
			return 2
			;;
		*)
			if [[ -z "$issue_spec" ]]; then
				issue_spec="$arg"
			elif [[ -z "$repo_slug" ]]; then
				repo_slug="$arg"
			else
				print_error "Unexpected launch-worker argument: $arg"
				return 2
			fi
			shift
			;;
		esac
	done

	[[ -n "$batch_spec" ]] && issue_spec="$batch_spec"
	if [[ -z "$issue_spec" ]]; then
		print_error "launch-worker requires an issue number or --batch list"
		return 2
	fi
	if [[ -z "$repo_slug" ]]; then
		repo_slug=$(_launch_worker_default_repo) || {
			print_error "Could not infer owner/repo from git remote; pass it explicitly"
			return 2
		}
	fi
	if [[ ! "$repo_slug" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
		print_error "Repo slug must be owner/repo format: $repo_slug"
		return 2
	fi

	local old_ifs="$IFS"
	IFS=','
	local -a issues=()
	read -r -a issues <<<"$issue_spec"
	IFS="$old_ifs"

	local helper_path
	helper_path=$(_launch_worker_helper_path) || return 1

	local issue rc=0
	for issue in "${issues[@]}"; do
		if [[ ! "$issue" =~ ^[0-9]+$ ]]; then
			print_error "Issue number must be numeric: $issue"
			rc=2
			continue
		fi
		bash "$helper_path" dispatch "$issue" "$repo_slug" "${helper_opts[@]}" || rc=$?
		echo "Status: aidevops launch-worker status $issue $repo_slug"
	done
	return "$rc"
}

# Emit tip if the current directory has aidevops but isn't registered
_main_check_unregistered() {
	local command="$1"
	local unregistered
	unregistered=$(detect_unregistered_repo 2>/dev/null) || true
	if [[ -n "$unregistered" && "$command" != "detect" && "$command" != "repos" ]]; then
		echo -e "${YELLOW}[TIP]${NC} This project uses aidevops but isn't registered. Run: aidevops repos add"
		echo ""
	fi
	return 0
}

# Warn when CLI and agents versions differ
_main_check_version() {
	local cli_version agents_version
	cli_version=$(get_version)
	[[ -f "$AGENTS_DIR/VERSION" ]] && agents_version=$(cat "$AGENTS_DIR/VERSION") || agents_version="not installed"
	if [[ "$agents_version" == "not installed" ]]; then
		echo -e "${YELLOW}[WARN]${NC} Agents not installed. Run: aidevops update" >&2
		echo "" >&2
	elif [[ "$cli_version" != "$agents_version" ]]; then
		echo -e "${YELLOW}[WARN]${NC} Version mismatch - CLI: $cli_version, Agents: $agents_version" >&2
		echo -e "       Run: aidevops update" >&2
		echo "" >&2
	fi
	return 0
}

# Route 'aidevops security [subcommand]' to appropriate helpers
_cmd_security() {
	case "${1:-}" in
	"")
		# No args: run ALL security checks (posture + hygiene + advisories)
		echo ""
		echo "Running full security assessment..."
		echo "==================================="
		echo ""
		_dispatch_helper "security-posture-helper.sh" "security-posture-helper.sh" status || true
		echo ""
		_dispatch_helper "secret-hygiene-helper.sh" "secret-hygiene-helper.sh" scan || true
		echo ""
		_dispatch_helper "supply-chain-advisory-helper.sh" "supply-chain-advisory-helper.sh" scan || true
		;;
	scan | scan-secrets | scan-pth | scan-deps)
		_dispatch_helper "secret-hygiene-helper.sh" "secret-hygiene-helper.sh" "$@"
		;;
	dismiss)
		if [[ "${2:-}" == "tanstack-minishaihulud-2026-05" ]]; then
			_dispatch_helper "supply-chain-advisory-helper.sh" "supply-chain-advisory-helper.sh" dismiss
		else
			_dispatch_helper "secret-hygiene-helper.sh" "secret-hygiene-helper.sh" "$@"
		fi
		;;
	hygiene)
		shift
		_dispatch_helper "secret-hygiene-helper.sh" "secret-hygiene-helper.sh" "${@:-scan}"
		;;
	posture | setup)
		shift || true
		_dispatch_helper "security-posture-helper.sh" "security-posture-helper.sh" "${@:-setup}"
		;;
	status)
		# Status shows both posture and hygiene summary
		_dispatch_helper "security-posture-helper.sh" "security-posture-helper.sh" status || true
		echo ""
		_dispatch_helper "secret-hygiene-helper.sh" "secret-hygiene-helper.sh" startup-check || true
		echo ""
		_dispatch_helper "supply-chain-advisory-helper.sh" "supply-chain-advisory-helper.sh" startup-check || true
		;;
	supply-chain)
		shift || true
		_dispatch_helper "supply-chain-advisory-helper.sh" "supply-chain-advisory-helper.sh" "${@:-scan}"
		;;
	*)
		_dispatch_helper "security-posture-helper.sh" "security-posture-helper.sh" "$@"
		;;
	esac
	return 0
}

# Route 'aidevops email [subcommand]' to email helpers
_cmd_email() {
	local sub="${1:-help}"
	local _EPH="email-poll-helper.sh"
	shift || true
	case "$sub" in
	mailbox)
		local action="${1:-list}"
		shift || true
		local _EMR_HELPER="email-mailbox-register-helper.sh"
		case "$action" in
		add)      _dispatch_helper "$_EMR_HELPER" "$_EMR_HELPER" add "$@" ;;
		list)     _dispatch_helper "$_EPH" "$_EPH" list "$@" ;;
		test)     _dispatch_helper "$_EPH" "$_EPH" test "$@" ;;
		remove)   _dispatch_helper "$_EMR_HELPER" "$_EMR_HELPER" remove "$@" ;;
		*)
			echo "Usage: aidevops email mailbox <add|list|test|remove>"
			echo ""
			echo "Mailbox subcommands:"
			echo "  add           Interactive: prompt for provider, user, gopass path; test connection"
			echo "  list          Table of mailboxes with last-polled-at and last-error"
			echo "  test <id>     Dry-run fetch (1 message); does not commit state"
			echo "  remove <id>   Un-register a mailbox"
			;;
		esac
		;;
	poll)
		# Direct poll commands forwarded to email-poll-helper.sh
		local poll_action="${1:-tick}"
		shift || true
		_dispatch_helper "$_EPH" "$_EPH" "$poll_action" "$@" ;;
	thread)
		# Thread lookup: email thread <message-id> [knowledge-root]
		local _ETH="email-thread-helper.sh"
		_dispatch_helper "$_ETH" "$_ETH" thread "$@" ;;
	build)
		# Thread rebuild: email build [knowledge-root] [--force]
		local _ETH2="email-thread-helper.sh"
		_dispatch_helper "$_ETH2" "$_ETH2" build "$@" ;;
	filter)
		# Filter rules: email filter tick|add|test|list [knowledge-root]
		local _EFH="email-filter-helper.sh"
		[[ $# -eq 0 ]] && set -- list
		_dispatch_helper "$_EFH" "$_EFH" "$@" ;;
	*)
		echo "Usage: aidevops email <mailbox|poll|thread|build|filter> [subcommand]"
		echo ""
		echo "Email subcommands:"
		echo "  mailbox add              Register a new IMAP mailbox (interactive)"
		echo "  mailbox list             Show all mailboxes + polling status"
		echo "  mailbox test <id>        Dry-run connection test"
		echo "  mailbox remove <id>      Un-register a mailbox"
		echo "  poll tick                Poll all mailboxes now (same as routine r044)"
		echo "  poll backfill <id>       Backfill a mailbox from a given date"
		echo "  thread <message-id>      Look up thread by message-id"
		echo "  build [--force]          Rebuild thread index from email sources"
		echo "  filter list              List filter rules"
		echo "  filter add               Add a new filter rule (interactive)"
		echo "  filter test <rule>       Dry-run rule against last 50 sources"
		echo "  filter tick              Run filter pass (routine r045)"
		;;
	esac
	return 0
}

# Route 'aidevops client-format [subcommand]' to appropriate helpers
_cmd_client_format() {
	local canary_helper="cch-canary.sh"
	case "${1:-status}" in
	extract | refresh)
		_dispatch_helper "cch-extract.sh" "cch-extract.sh" --cache
		;;
	check | verify)
		_dispatch_helper "cch-extract.sh" "cch-extract.sh" --verify
		;;
	canary | test)
		shift || true
		_dispatch_helper "$canary_helper" "$canary_helper" --verbose "$@"
		;;
	monitor)
		shift || true
		_dispatch_helper "cch-traffic-monitor.sh" "cch-traffic-monitor.sh" "$@"
		;;
	install-canary)
		_dispatch_helper "$canary_helper" "$canary_helper" --install
		;;
	status | "")
		echo ""
		echo "Client request format alignment"
		echo "==============================="
		echo ""
		_dispatch_helper "cch-extract.sh" "cch-extract.sh" --verify 2>&1 || true
		echo ""
		if [[ -f "$HOME/.aidevops/cch-constants.json" ]]; then
			echo "Cached constants:"
			cat "$HOME/.aidevops/cch-constants.json"
		else
			echo "No cached constants. Run: aidevops client-format extract"
		fi
		;;
	*)
		print_error "Unknown subcommand: $1"
		echo "Usage: aidevops client-format [extract|check|canary|monitor|install-canary|status]"
		exit 1
		;;
	esac
	return 0
}

# Main entry point
main() {
	local command="${1:-help}"
	local check_workflows_helper="check-workflows-helper.sh"
	shift || true

	# Help for inventory commands must bypass repository auto-detection and
	# version checks. Those startup checks may read the repository registry,
	# while help must remain bounded and side-effect-free.
	if [[ "$command" == "check-workflows" || "$command" == "workflows" ]]; then
		local arg
		for arg in "$@"; do
			case "$arg" in
			-h | --help)
				_dispatch_helper "$check_workflows_helper" "$check_workflows_helper" "$@"
				return $?
				;;
			esac
		done
	fi

	# Update help must return before startup checks or cmd_update(), which can
	# inspect repositories, fetch remotes, deploy agents, and synchronize projects.
	if [[ "$command" == "update" || "$command" == "upgrade" || "$command" == "u" ]]; then
		local arg
		for arg in "$@"; do
			case "$arg" in
			help | -h | --help)
				cmd_update_help
				return $?
				;;
			esac
		done
	fi

	# Auto-detect unregistered repo on any command (silent check)
	_main_check_unregistered "$command"

	# Check if agents need updating (skip for update command itself)
	if [[ "$command" != "update" && "$command" != "upgrade" && "$command" != "u" ]]; then
		_main_check_version
	fi

	case "$command" in
	init | i) cmd_init "$@" ;;
	setup) cmd_setup "$@" ;;
	features | f) cmd_features ;;
	status | s) cmd_status ;;
	update | upgrade | u) cmd_update "$@" ;;
	runtime-bundle | runtime_bundle) AIDEVOPS_INSTALL_DIR="$INSTALL_DIR" _dispatch_helper "runtime-bundle-rollback-helper.sh" "runtime-bundle-rollback-helper.sh" "$@" ;;
	release) _dispatch_helper "full-loop-release-helper.sh" "full-loop-release-helper.sh" "$@" ;;
	auto-update | autoupdate) _dispatch_helper "auto-update-helper.sh" "auto-update-helper.sh" "$@" ;;
	repo-sync | reposync) _dispatch_helper "repo-sync-helper.sh" "repo-sync-helper.sh" "$@" ;;
	update-tools | tools) cmd_update_tools "$@" ;;
	lint) _dispatch_helper "lint-helper.sh" "lint-helper.sh" "$@" ;;
	upgrade-planning | up) cmd_upgrade_planning "$@" ;;
	repos | projects) cmd_repos "$@" ;;
	design) _dispatch_helper "design-guidelines-helper.sh" "design-guidelines-helper.sh" "$@" ;;
	skill) cmd_skill "$@" ;;
	skills) cmd_skills "$@" ;;
	sources | agent-sources) _dispatch_helper "agent-sources-helper.sh" "agent-sources-helper.sh" "$@" ;;
	plugin | plugins) cmd_plugin "$@" ;;
	pulse) _dispatch_helper "pulse-session-helper.sh" "pulse-session-helper.sh" "$@" ;;
	schedule) _dispatch_helper "deferred-job-helper.sh" "deferred-job-helper.sh" "$@" ;;
	launch-worker | launch_worker) cmd_launch_worker "$@" ;;
	check-workflows | workflows) _dispatch_helper "$check_workflows_helper" "$check_workflows_helper" "$@" ;;
	sync-workflows) _dispatch_helper "sync-workflows-helper.sh" "sync-workflows-helper.sh" "$@" ;;
	metrics) _dispatch_helper "repo-metrics-helper.sh" "repo-metrics-helper.sh" "$@" ;;
	badges)
		# Badge management: render | check | sync | install (t2975)
		# Bare 'aidevops badges' with no subcommand shows a usage summary.
		# Subcommands:
		#   render <slug>               — render canonical badge block for a repo
		#   check  [--repo SLUG] [--json] [--verbose]  — cross-repo drift check
		#   sync   [--repo SLUG] [--apply]              — inject badge block + generate metrics + install workflow
		#   install [--repo SLUG] [--apply]             — install repo metrics refresh workflow only
		local _badges_sub="${1:-help}"
		local _badges_check_h="badges-check-helper.sh"
		local _badges_sync_h="badges-sync-helper.sh"
		case "$_badges_sub" in
		render)
			shift
			local _render_helper
			_render_helper=$(bash -c '
				d="$HOME/.aidevops/agents/scripts/readme-badges-helper.sh"
				l="'"$AGENTS_DIR"'/scripts/readme-badges-helper.sh"
				[[ -f "$d" ]] && echo "$d" || echo "$l"
			')
			if [[ -f "$_render_helper" ]]; then
				bash "$_render_helper" render "$@"
			else
				print_error "readme-badges-helper.sh not found. Run: aidevops update"
				exit 1
			fi
			;;
		check)
			shift
			_dispatch_helper "$_badges_check_h" "$_badges_check_h" "$@"
			;;
		sync)
			shift
			_dispatch_helper "$_badges_sync_h" "$_badges_sync_h" "$@"
			;;
		install)
			shift
			_dispatch_helper "$_badges_sync_h" "$_badges_sync_h" --workflow-only "$@"
			;;
		help | --help | -h | "")
			echo ""
			echo "aidevops badges — README badge block and repo metrics workflow management (t2975)"
			echo ""
			echo "Subcommands:"
			echo "  render  <slug>                 Print canonical badge block for a repo"
			echo "  check   [--repo SLUG] [--json]  Detect badge drift across managed repos"
			echo "  sync    [--repo SLUG] [--apply] Inject badge block + generate metrics + install workflow"
			echo "  install [--repo SLUG] [--apply] Install repo metrics refresh workflow only"
			echo ""
			echo "Options (check/sync/install):"
			echo "  --repo SLUG    Limit to a single repo"
			echo "  --apply        Actually perform the sync (default: dry-run)"
			echo "  --json         Machine-readable output"
			echo "  --verbose      Show diff summaries (check only)"
			echo ""
			echo "Examples:"
			echo "  aidevops badges check                       # scan all repos for badge drift"
			echo "  aidevops badges check --json | jq '.[]'    # machine-readable output"
			echo "  aidevops badges render owner/repo           # print badge block"
			echo "  aidevops badges sync                        # dry-run sync across all repos"
			echo "  aidevops badges sync --repo owner/r --apply # apply to a single repo"
			echo "  aidevops metrics generate [PATH]            # generate local docs/metrics artifacts"
			echo ""
			;;
		*)
			print_error "Unknown badges subcommand: $_badges_sub (try render|check|sync|install|help)"
			exit 1
			;;
		esac
		;;
	security) _cmd_security "$@" ;;
	doctor | doc) _dispatch_helper "doctor-helper.sh" "doctor-helper.sh" "$@" ;;
	detect | scan) cmd_detect ;;
	ip-check | ip_check) _dispatch_helper "ip-reputation-helper.sh" "ip-reputation-helper.sh" "$@" ;;
	model-accounts-pool | map) _dispatch_helper "oauth-pool-helper.sh" "oauth-pool-helper.sh" "$@" ;;
	gpt56-context | gpt56_context) _dispatch_helper "gpt56-context-helper.sh" "gpt56-context-helper.sh" "$@" ;;
	cleanup)
		local _cleanup_sub="${1:-help}"
		case "$_cleanup_sub" in
		branches | remote-branches)
			shift || true
			_dispatch_helper "remote-branch-cleanup-helper.sh" "remote-branch-cleanup-helper.sh" "$_cleanup_sub" "$@"
			;;
		help | --help | -h | "")
			echo "Usage: aidevops cleanup <branches|remote-branches> [options]"
			echo ""
			echo "Cleanup commands:"
			echo "  branches          Audit stale remote branches (dry-run default)"
			echo "  remote-branches   Alias for branches"
			echo ""
			echo "Options:"
			echo "  --repo PATH       Repository path (default: current directory)"
			echo "  --remote NAME     Remote to audit (default: origin)"
			echo "  --apply           Delete safe candidates"
			echo ""
			;;
		*)
			print_error "Unknown cleanup subcommand: $_cleanup_sub (try branches|remote-branches|help)"
			exit 1
			;;
		esac
		;;
	client-format) _cmd_client_format "$@" ;;
	github-app-auth | github-app | gh-auth) _dispatch_helper "github-app-auth-helper.sh" "github-app-auth-helper.sh" "$@" ;;
	opencode-db | oc-db) _dispatch_helper "opencode-db-maintenance-helper.sh" "opencode-db-maintenance-helper.sh" "$@" ;;
	opencode | oc | codex | claude | claude-code | cursor | cursor-agent | droid | gemini | gemini-cli | continue | cn | kilo | kiro | kiro-cli | aider | amp | kimi | qwen | windsurf)
		_dispatch_helper "runtime-launcher-helper.sh" "runtime-launcher-helper.sh" "$command" "$@" ;;
	opencode-desktop | oc-desktop) _dispatch_helper "opencode-launcher-helper.sh" "opencode-launcher-helper.sh" desktop "$@" ;;
	opencode-sandbox | oc-sandbox) _dispatch_helper "opencode-sandbox-helper.sh" "opencode-sandbox-helper.sh" "$@" ;;
	review-gate | review_gate) _dispatch_helper "review-gate-config-helper.sh" "review-gate-config-helper.sh" "$@" ;;
	source-access | source_access) _dispatch_helper "source-access-helper.sh" "source-access-helper.sh" "$@" ;;
	secret | secrets) _dispatch_helper "secret-helper.sh" "secret-helper.sh" "$@" ;;
	vault) _dispatch_helper "vault-helper.sh" "vault-helper.sh" "$@" ;;
	approve) _dispatch_helper "approval-helper.sh" "approval-helper.sh" "$@" ;;
	circuit-breaker | circuit_breaker | cb)
		# Supervisor circuit breaker control (t1331). Bare invocation defaults to status.
		# Subcommands forward verbatim: check | status | record-failure | record-success | reset | trip | help
		[[ $# -eq 0 ]] && set -- status
		_dispatch_helper "circuit-breaker-helper.sh" "circuit-breaker-helper.sh" "$@"
		;;
	worktree | wt) _dispatch_helper "worktree-helper.sh" "worktree-helper.sh" "$@" ;;
	issue) _dispatch_helper "interactive-session-helper.sh" "interactive-session-helper.sh" "$@" ;;
	signing) _dispatch_helper "signing-setup.sh" "signing-setup.sh" "$@" ;;
	contributions | contrib)
		# Bare `aidevops contributions` defaults to status (most common use).
		# Other subcommands (seed, scan, stop, restart, install, uninstall) forward verbatim.
		[[ $# -eq 0 ]] && set -- status
		_dispatch_helper "contribution-watch-helper.sh" "contribution-watch-helper.sh" "$@"
		;;
	inbox)
		# Bare `aidevops inbox` defaults to status (most common use).
		[[ $# -eq 0 ]] && set -- status
		_dispatch_helper "inbox-helper.sh" "inbox-helper.sh" "$@"
		;;
	case | cases)
		# Bare `aidevops case` defaults to list (most common use).
		[[ $# -eq 0 ]] && set -- list
		# alarm-test subcommand routes to case-alarm-helper.sh
		if [[ "${1:-}" == "alarm-test" ]]; then
			shift
			_dispatch_helper "case-alarm-helper.sh" "case-alarm-helper.sh" alarm-test "$@"
		else
			_dispatch_helper "case-helper.sh" "case-helper.sh" "$@"
		fi
		;;
	email) _cmd_email "$@" ;;
	stats | observability) _dispatch_helper "observability-helper.sh" "observability-helper.sh" "$@" ;;
	tabby) _dispatch_helper "tabby-helper.sh" "tabby-helper.sh" "$@" ;;
	buzz) _dispatch_helper "buzz-desktop-helper.sh" "buzz-desktop-helper.sh" "$@" ;;
	init-routines) _dispatch_helper "init-routines-helper.sh" "init-routines-helper.sh" "$@" ;;
	parent-status | ps) _dispatch_helper "parent-status-helper.sh" "parent-status-helper.sh" "$@" ;;
	knowledge) _dispatch_helper "knowledge-helper.sh" "knowledge-helper.sh" "$@" ;;
	campaign | campaigns)
		# P1 provisioning: init/provision/status/ls → campaigns-provision-helper.sh
		# P4 asset binary: asset → campaign-asset-helper.sh
		# P2+P6: all other subcommands → campaign-helper.sh
		local _camp_cmd="${1:-help}"
		local _camp_helper="campaign-helper.sh"
		local _camp_provision_helper="campaigns-provision-helper.sh"
		case "$_camp_cmd" in
		init | provision | ls)
			_dispatch_helper "$_camp_provision_helper" "$_camp_provision_helper" "$@"
			;;
		status)
			if [[ $# -le 1 || -d "${2:-}" || "${2:-}" == .* || "${2:-}" == /* || "${2:-}" == ~* ]]; then
				_dispatch_helper "$_camp_provision_helper" "$_camp_provision_helper" "$@"
			else
				_dispatch_helper "$_camp_helper" "$_camp_helper" "$@"
			fi
			;;
		asset | assets)
			shift
			_dispatch_helper "campaign-asset-helper.sh" "campaign-asset-helper.sh" "$@"
			;;
		grow | growth)
			shift
			local _growth_helper="${AIDEVOPS_CLI_MODULES_DIR%/aidevops-cli}/campaign-growth-helper.py"
			[[ ! -f "$_growth_helper" ]] && _growth_helper="$AGENTS_DIR/scripts/campaign-growth-helper.py"
			if [[ -f "$_growth_helper" ]]; then
				python3 "$_growth_helper" "$@"
			else
				print_error "campaign-growth-helper.py not found. Run: aidevops update"
				return 1
			fi
			;;
		*)
			_dispatch_helper "$_camp_helper" "$_camp_helper" "$@"
			;;
		esac
		;;
	performance) _dispatch_helper "performance-helper.sh" "performance-helper.sh" "$@" ;;
	reach) _dispatch_helper "reach-helper.sh" "reach-helper.sh" "$@" ;;
	config | configure) _dispatch_config "$@" ;;
	uninstall | remove) cmd_uninstall ;;
	version | v | -v | --version) cmd_version ;;
	help | h | -h | --help) cmd_help ;;
	*)
		print_error "Unknown command: $command"
		echo ""
		cmd_help
		exit 1
		;;
	esac
}

main "$@"
