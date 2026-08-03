#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Runtime agent deployment: convert and copy agents to each runtime's native directory.
# Strips aidevops-only frontmatter (mode, subagents); keeps standard fields
# (name, description, tools, model, permissionMode, hooks, mcpServers, etc.).
# Split from agent-deploy.sh (t1940)

# Shell safety baseline
set -Eeuo pipefail
IFS=$'\n\t'
# shellcheck disable=SC2154  # rc is assigned by $? in the trap string
trap 'rc=$?; echo "[ERROR] ${BASH_SOURCE[0]}:${LINENO} exit $rc" >&2' ERR
shopt -s inherit_errexit 2>/dev/null || true

# Resolve the activation link once, then export the physical immutable bundle
# root. Child commands inherit this pin and cannot cross into a newer bundle in
# the middle of a pulse, worker, CLI command, or interactive session.
resolve_aidevops_runtime_bundle_root() {
	local requested_root="${1:-}"
	local configured_root="${requested_root:-${AIDEVOPS_AGENTS_DIR:-${HOME:+$HOME/.aidevops/agents}}}"
	[[ -n "$configured_root" && -d "$configured_root/scripts" ]] || return 1
	(cd "$configured_root" && pwd -P) || return 1
	return 0
}

pin_aidevops_runtime_bundle_root() {
	local resolved_root=""
	resolved_root=$(resolve_aidevops_runtime_bundle_root) || return 1
	AIDEVOPS_AGENTS_DIR="$resolved_root"
	AGENTS_DIR="$resolved_root"
	export AIDEVOPS_AGENTS_DIR AGENTS_DIR
	return 0
}

# Setup and deployment are global reconciliation operations, not long-lived
# runtime processes. Always bind them to the current activation link instead of
# an inherited process pin that may name an older immutable bundle.
pin_aidevops_active_runtime_bundle_root() {
	local active_link="${HOME:?HOME must be set}/.aidevops/agents"
	local resolved_root=""
	resolved_root=$(resolve_aidevops_runtime_bundle_root "$active_link") || return 1
	AIDEVOPS_AGENTS_DIR="$resolved_root"
	AGENTS_DIR="$resolved_root"
	export AIDEVOPS_AGENTS_DIR AGENTS_DIR
	return 0
}

# Serialize activation-link changes with Pulse restart/start operations. A
# lifecycle process always re-resolves the active link after taking this lock,
# so concurrent setup callers cannot leave Pulse running an older bundle.
aidevops_runtime_transition_lock_acquire() {
	local lock_dir="${AIDEVOPS_RUNTIME_TRANSITION_LOCK_DIR:-${HOME}/.aidevops/locks/runtime-transition.lock.d}"
	local wait_seconds="${AIDEVOPS_RUNTIME_TRANSITION_LOCK_WAIT_SECONDS:-30}"
	local waited=0
	local owner_pid=""
	local owner_missing_observations=0

	[[ "$wait_seconds" =~ ^[0-9]+$ ]] || wait_seconds=30
	mkdir -p "${lock_dir%/*}" || return 1
	while ! mkdir "$lock_dir" 2>/dev/null; do
		owner_pid=""
		if [[ -r "$lock_dir/pid" ]]; then
			IFS= read -r owner_pid <"$lock_dir/pid" || owner_pid=""
		fi
		if [[ "$owner_pid" =~ ^[0-9]+$ ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
			rm -f "$lock_dir/pid"
			rmdir "$lock_dir" 2>/dev/null || true
			owner_missing_observations=0
			continue
		fi
		if [[ -z "$owner_pid" ]]; then
			owner_missing_observations=$((owner_missing_observations + 1))
			if [[ "$owner_missing_observations" -ge 2 ]]; then
				rmdir "$lock_dir" 2>/dev/null || true
				owner_missing_observations=0
				continue
			fi
		else
			owner_missing_observations=0
		fi
		[[ "$waited" -lt "$wait_seconds" ]] || return 1
		sleep 1
		waited=$((waited + 1))
	done
	printf '%s\n' "$$" >"$lock_dir/pid" || {
		rmdir "$lock_dir" 2>/dev/null || true
		return 1
	}
	_AIDEVOPS_RUNTIME_TRANSITION_LOCK_HELD="$lock_dir"
	return 0
}

aidevops_runtime_transition_lock_release() {
	local lock_dir="${_AIDEVOPS_RUNTIME_TRANSITION_LOCK_HELD:-}"
	local owner_pid=""
	[[ -n "$lock_dir" ]] || return 0
	if [[ -r "$lock_dir/pid" ]]; then
		IFS= read -r owner_pid <"$lock_dir/pid" || owner_pid=""
	fi
	if [[ "$owner_pid" == "$$" ]]; then
		rm -f "$lock_dir/pid"
		rmdir "$lock_dir" 2>/dev/null || true
	fi
	_AIDEVOPS_RUNTIME_TRANSITION_LOCK_HELD=""
	return 0
}

# Atomically replace one runtime symlink on GNU/Linux or macOS. Keeping this
# primitive beside the transition lock makes setup and explicit rollback use the
# same cross-platform mutation semantics.
aidevops_runtime_replace_link() {
	local link_tmp="$1"
	local link_path="$2"
	if [[ "$(uname -s 2>/dev/null || true)" == "Darwin" ]]; then
		mv -f -h "$link_tmp" "$link_path"
	else
		mv -Tf "$link_tmp" "$link_path"
	fi
	return $?
}

aidevops_runtime_switch_link() {
	local link_path="$1"
	local link_target="$2"
	local link_tmp="${link_path}.link.$$"
	rm -f "$link_tmp"
	ln -s "$link_target" "$link_tmp" || return 1
	if ! aidevops_runtime_replace_link "$link_tmp" "$link_path"; then
		rm -f "$link_tmp"
		return 1
	fi
	return 0
}

# _convert_agent_frontmatter: strips aidevops-only fields from agent markdown.
# Reads from stdin, writes converted content to stdout.
# Tracks whether we're inside an indented block (subagents list) to correctly
# skip its child lines without stripping other indented YAML fields.
_convert_agent_frontmatter() {
	local in_frontmatter=false
	local frontmatter_started=false
	local in_skip_block=false
	local line_num=0

	while IFS= read -r line || [[ -n "$line" ]]; do
		line_num=$((line_num + 1))
		if [[ $line_num -eq 1 && "$line" == "---" ]]; then
			in_frontmatter=true
			frontmatter_started=true
			echo "$line"
			continue
		fi
		if [[ "$frontmatter_started" == "true" && "$in_frontmatter" == "true" && "$line" == "---" ]]; then
			in_frontmatter=false
			echo "$line"
			continue
		fi
		if [[ "$in_frontmatter" == "true" ]]; then
			# Detect top-level keys (no leading whitespace)
			case "$line" in
			mode:*)
				in_skip_block=false
				continue
				;;
			subagents:*)
				in_skip_block=true
				continue
				;;
			esac
			# If inside a skipped block, consume indented continuation lines
			if [[ "$in_skip_block" == "true" ]]; then
				case "$line" in
				[[:space:]]*)
					# Indented line under a skipped key — skip it
					continue
					;;
				*)
					# Non-indented line — we've left the skip block
					in_skip_block=false
					echo "$line"
					;;
				esac
			else
				echo "$line"
			fi
		else
			echo "$line"
		fi
	done
	return 0
}

# _is_agent_definition: check if a markdown file has agent frontmatter (name: field).
# Returns 0 if the file is an agent definition, 1 otherwise.
_is_agent_definition() {
	local file="$1"
	# Check first 30 lines for name: in YAML frontmatter (fast path)
	head -30 "$file" 2>/dev/null | grep -q '^name:' 2>/dev/null
	return $?
}

# _agent_source_dirs: list directories under agents_source that contain subagents.
# Excludes framework infrastructure directories that are not agent definitions.
_agent_source_dirs() {
	local agents_source="$1"
	local dir
	for dir in "$agents_source"/*/; do
		[[ -d "$dir" ]] || continue
		local dirname
		dirname=$(basename "$dir")
		# Skip framework infrastructure directories
		case "$dirname" in
		scripts | reference | prompts | templates | configs | hooks | \
			plugins | bundles | loop-state | advisories | aidevops | \
			custom | draft | tests | rules)
			continue
			;;
		*)
			echo "$dir"
			;;
		esac
	done
	return 0
}

# _collect_agent_files: print "abspath|relpath" lines for all deployable agent files
# under agents_source. Excludes AGENTS.md, SKILL.md stubs, and non-agent markdown.
_collect_agent_files() {
	local agents_source="$1"
	local f bn

	# Top-level agents
	for f in "$agents_source"/*.md; do
		[[ -f "$f" ]] || continue
		bn=$(basename "$f")
		[[ "$bn" == "AGENTS.md" ]] && continue
		if _is_agent_definition "$f"; then
			printf '%s|%s\n' "$f" "$bn"
		fi
	done

	# Subagent directories (recursive)
	local subdir
	while IFS= read -r subdir; do
		while IFS= read -r f; do
			[[ -f "$f" ]] || continue
			bn=$(basename "$f")
			# Skip SKILL.md stubs — they're directory indexes, not real agents
			[[ "$bn" == "SKILL.md" ]] && continue
			if _is_agent_definition "$f"; then
				local relpath="${f#"$agents_source"/}"
				printf '%s|%s\n' "$f" "$relpath"
			fi
		done < <(find "$subdir" -name '*.md' -type f 2>/dev/null)
	done < <(_agent_source_dirs "$agents_source")
	return 0
}

# _deploy_agents_to_single_runtime: convert and copy all agent files to one runtime.
# Arguments: runtime_id agent_dir agent_list_file
# agent_list_file contains "abspath|relpath" lines produced by _collect_agent_files.
# Prints the count of successfully deployed agents to stdout.
_deploy_agents_to_single_runtime() {
	local runtime_id="$1"
	local agent_dir="$2"
	local agent_list_file="$3"

	# Only deploy if the runtime is actually installed
	local binary config_path config_dir
	binary=$(rt_binary "$runtime_id")
	config_path=$(rt_config_path "$runtime_id")
	config_dir="$(dirname "$config_path" 2>/dev/null)"

	if ! type -P "$binary" >/dev/null 2>&1 && [[ ! -d "$config_dir" ]]; then
		echo "0"
		return 0
	fi

	mkdir -p "$agent_dir"
	local agent_count=0
	local src rel target target_parent

	while IFS='|' read -r src rel; do
		[[ -n "$src" && -n "$rel" ]] || continue
		target="$agent_dir/$rel"
		target_parent=$(dirname "$target")
		[[ -d "$target_parent" ]] || mkdir -p "$target_parent"
		if _convert_agent_frontmatter <"$src" >"$target"; then
			agent_count=$((agent_count + 1))
		fi
	done <"$agent_list_file"

	echo "$agent_count"
	return 0
}

# deploy_agents_to_runtimes: main entry point called by setup.sh.
# Iterates all installed runtimes with agent directory support, converts and
# deploys aidevops agents to each runtime's native agent directory.
# Only files with name: frontmatter are deployed. SKILL.md stubs are excluded.
deploy_agents_to_runtimes() {
	# Pin before collecting any source paths. Activation may change concurrently,
	# but every read in this process remains on this resolved bundle.
	pin_aidevops_runtime_bundle_root || {
		print_warning "No complete deployed runtime bundle found — skipping agent deployment to runtimes"
		return 0
	}

	# Source runtime registry if not already loaded
	local registry_script="${INSTALL_DIR:-.}/.agents/scripts/runtime-registry.sh"
	if [[ -z "${_RUNTIME_REGISTRY_LOADED:-}" ]]; then
		if [[ -f "$registry_script" ]]; then
			# shellcheck source=/dev/null
			source "$registry_script"
		else
			print_warning "Runtime registry not found — skipping agent deployment to runtimes"
			return 0
		fi
	fi

	local agents_source="$AIDEVOPS_AGENTS_DIR"
	if [[ ! -d "$agents_source" ]]; then
		print_warning "No deployed agents found at $agents_source — skipping"
		return 0
	fi

	# Build the agent file list once (shared across all runtimes) into a temp file.
	# Each line: "abspath|relpath"
	local agent_list_file
	agent_list_file=$(mktemp)
	trap 'rm -f "${agent_list_file:-}"' RETURN
	_collect_agent_files "$agents_source" >"$agent_list_file"

	local total_agents
	total_agents=$(wc -l <"$agent_list_file" | tr -d ' ')
	if [[ "$total_agents" -eq 0 ]]; then
		print_warning "No agent definitions found in $agents_source"
		return 0
	fi

	local deployed_count=0
	local runtime_count=0

	local runtime_id agent_dir agent_count display_name feature_flag
	while IFS= read -r runtime_id; do
		agent_dir=$(rt_agent_dir "$runtime_id")
		[[ -z "$agent_dir" ]] && continue

		# Feature flag gate — allow users to disable agent installation per
		# runtime via AIDEVOPS_FEATURE_AGENTS_<SUFFIX>=no (see runtime-registry).
		if declare -F rt_feature_agents >/dev/null 2>&1; then
			feature_flag=$(rt_feature_agents "$runtime_id" 2>/dev/null || echo "yes")
			if [[ "$feature_flag" != "yes" ]]; then
				display_name=$(rt_display_name "$runtime_id")
				print_info "Agent installation disabled for $display_name (feature flag)"
				continue
			fi
		fi

		agent_count=$(_deploy_agents_to_single_runtime "$runtime_id" "$agent_dir" "$agent_list_file")
		# A count of 0 means runtime not installed (skipped) — don't increment runtime_count
		if [[ "$agent_count" -gt 0 ]]; then
			display_name=$(rt_display_name "$runtime_id")
			print_info "Deployed $agent_count agents to $display_name ($agent_dir)"
			deployed_count=$((deployed_count + agent_count))
			runtime_count=$((runtime_count + 1))
		fi
	done < <(rt_list_with_agents)

	if [[ $runtime_count -eq 0 ]]; then
		print_info "No runtimes with agent directory support detected — skipping"
	else
		print_success "Deployed $deployed_count agent(s) across $runtime_count runtime(s)"
	fi

	return 0
}

# _deploy_agents_to_runtimes_bounded: time-bounded wrapper for deploy_agents_to_runtimes.
#
# deploy_agents_to_runtimes is a shell function (not an external script), so it
# cannot be passed directly to the `timeout` binary. Instead we run it in a
# background subshell and poll for completion with a configurable wall-clock
# deadline. When the deadline expires the subshell is killed with SIGTERM then
# SIGKILL and this non-critical step is treated as a warning so setup can
# continue after core deployment has already succeeded.
#
# Configurable via AIDEVOPS_DEPLOY_RUNTIMES_TIMEOUT (default 120s).
_deploy_agents_to_runtimes_bounded() {
	local timeout_s="${AIDEVOPS_DEPLOY_RUNTIMES_TIMEOUT:-120}"
	local _start_s=$SECONDS
	local _pid=""
	local _rc=0

	deploy_agents_to_runtimes &
	_pid=$!

	while kill -0 "$_pid" 2>/dev/null; do
		if (( ${SECONDS:-0} - ${_start_s:-0} >= ${timeout_s:-0} )); then
			kill -TERM "$_pid" 2>/dev/null || true
			sleep 2
			kill -KILL "$_pid" 2>/dev/null || true
			wait "$_pid" 2>/dev/null || true
			print_warning "Runtime agent deployment exceeded ${timeout_s}s — skipping (non-critical)"
			return 0
		fi
		sleep 1
	done

	wait "$_pid" 2>/dev/null || _rc=$?
	if [[ "$_rc" -ne 0 ]]; then
		print_warning "Runtime agent deployment exited non-zero (${_rc}) — skipping (non-critical)"
		return 0
	fi
	return 0
}
