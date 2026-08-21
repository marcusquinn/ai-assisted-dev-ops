#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Headless Runtime Launch Library -- Run Setup and Validation
# =============================================================================
# Prompt transport, run argument parsing, launch-directory recovery, worker
# environment validation, and recoverable OpenCode startup error detection.
#
# Usage: source "${SCRIPT_DIR}/headless-runtime-launch.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_warning)
#   - Constants from headless-runtime-helper.sh
#   - bash 3.2+, git, sed
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_LAUNCH_LIB_LOADED:-}" ]] && return 0
_HEADLESS_RUNTIME_LAUNCH_LIB_LOADED=1

# Resolve SCRIPT_DIR when sourced directly by a test harness.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# shellcheck source=./shared-constants.sh
# shellcheck disable=SC1091  # shared library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/shared-constants.sh"
# shellcheck source=./sensitive-temp-helper.sh
# shellcheck disable=SC1091  # shared library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/sensitive-temp-helper.sh"

# Runtime temp paths owned by this helper. The worker EXIT trap also calls the
# cleanup function below so prompt/auth dirs are removed after normal exits,
# watchdog kills, and retry-path failures. Kept newline-delimited for bash 3.2.
_HEADLESS_RUNTIME_TEMP_PATHS=""
_HEADLESS_RUN_PROMPT_ARG=""
_HEADLESS_RUN_PROMPT_FILE=""
_HEADLESS_CLAUDE_STDIN_FILE=""
readonly PRIVATE_WORKLOAD_PROMPT="Execute the private workload instructions configured in this directory."

_headless_private_workload_enabled() {
	[[ "${AIDEVOPS_PRIVATE_WORKLOAD:-0}" == "1" ]]
	return $?
}

# Ephemeral runs may use isolated runtime state during one invocation, but must
# never continue from or persist session/transcript-derived state afterward.
_headless_run_is_ephemeral() {
	local role="$1"
	if _headless_private_workload_enabled ||
		[[ "$role" == "${HEADLESS_ROLE_TRIAGE:-triage}" ]]; then
		return 0
	fi
	return 1
}

_create_headless_runtime_temp_file() {
	local temp_root=""
	local temp_status=0
	temp_root=$(aidevops_sensitive_temp_root) || temp_status=$?
	if [[ "$temp_status" -ne 0 ]]; then
		print_error "[lifecycle] _create_headless_runtime_temp_file.resolve_sensitive_temp_root failed rc=${temp_status}"
		return "$temp_status"
	fi
	(umask 077 && mktemp "${temp_root}/aidevops-headless-runtime.XXXXXX") || temp_status=$?
	if [[ "$temp_status" -ne 0 ]]; then
		print_error "[lifecycle] _create_headless_runtime_temp_file.mktemp failed rc=${temp_status}"
		return "$temp_status"
	fi
	return 0
}

_create_headless_runtime_temp_dir() {
	local purpose="$1"
	[[ "$purpose" =~ ^[a-z0-9-]+$ ]] || return 1
	aidevops_sensitive_temp_create_dir "headless-${purpose}" || return 1
	return 0
}

_register_headless_runtime_temp_path() {
	local path="$1"
	[[ -n "$path" ]] || return 0
	_HEADLESS_RUNTIME_TEMP_PATHS="${_HEADLESS_RUNTIME_TEMP_PATHS}${path}
"
	return 0
}

# Start a detached guardian for prompt/auth/runtime directories containing
# sensitive or untrusted material. EXIT traps provide prompt cleanup for normal
# failures; this process also removes the path when the owner is SIGKILLed and
# enforces a maximum retention window. The generated path itself is the only
# value passed to the guardian; file contents never enter argv or logs.
_start_headless_runtime_temp_guardian() {
	local guarded_path="$1"
	local owner_pid="${2:-$$}"
	local max_age_seconds="${HEADLESS_RUNTIME_TEMP_MAX_AGE_SECONDS:-25200}"
	local poll_seconds="${HEADLESS_RUNTIME_TEMP_GUARD_POLL_SECONDS:-2}"
	aidevops_sensitive_temp_start_guardian \
		"$guarded_path" "$owner_pid" "$max_age_seconds" "$poll_seconds" || return 1
	return 0
}

_register_headless_runtime_sensitive_temp_path() {
	local path="$1"
	_register_headless_runtime_temp_path "$path"
	_start_headless_runtime_temp_guardian "$path" "$$" || return 1
	return 0
}

_register_headless_runtime_output_temp_path() {
	local role="$1"
	local path="$2"
	if _headless_run_is_ephemeral "$role"; then
		_register_headless_runtime_sensitive_temp_path "$path" || return 1
		return 0
	fi
	_register_headless_runtime_temp_path "$path"
	return $?
}

_cleanup_headless_runtime_temp_paths() {
	local path=""
	local tmp_root="${TMPDIR:-/tmp}"
	local managed_temp_root=""
	local cleanup_failed=0
	local retained_paths=""
	managed_temp_root=$(aidevops_sensitive_temp_root) || return 1
	while IFS= read -r path; do
		[[ -n "$path" ]] || continue
		case "$path" in
		"$managed_temp_root"/aidevops-headless-* | "$tmp_root"/aidevops-* | /tmp/aidevops-* | /var/folders/*/T/*/aidevops-*)
			rm -rf -- "$path" 2>/dev/null || cleanup_failed=1
			if [[ -e "$path" || -L "$path" ]]; then
				cleanup_failed=1
				retained_paths="${retained_paths}${path}"$'\n'
				print_warning "[lifecycle] headless_runtime_temp_cleanup_failed guardian=retained"
			fi
			;;
		*)
			print_warning "[lifecycle] refusing to cleanup unexpected temp path: $path"
			cleanup_failed=1
			retained_paths="${retained_paths}${path}"$'\n'
			;;
		esac
	done <<EOF
${_HEADLESS_RUNTIME_TEMP_PATHS:-}
EOF
	_HEADLESS_RUNTIME_TEMP_PATHS="$retained_paths"
	[[ "$cleanup_failed" -eq 0 ]] || return 1
	return 0
}

_prepare_runtime_prompt_transport() {
	local runtime="$1"
	local prompt_text="$2"
	local force_file_transport="${3:-0}"
	local threshold="${HEADLESS_PROMPT_FILE_THRESHOLD_BYTES:-8192}"
	_HEADLESS_RUN_PROMPT_ARG="$prompt_text"
	_HEADLESS_RUN_PROMPT_FILE=""
	_HEADLESS_CLAUDE_STDIN_FILE=""
	unset AIDEVOPS_HEADLESS_PROMPT_DIR

	[[ "$threshold" =~ ^[0-9]+$ ]] || threshold=8192
	[[ "$force_file_transport" =~ ^[01]$ ]] || force_file_transport=0
	if [[ "$force_file_transport" -ne 1 && "${#prompt_text}" -lt "$threshold" ]]; then
		return 0
	fi

	local prompt_dir=""
	prompt_dir=$(_create_headless_runtime_temp_dir "prompt") || {
		[[ "$force_file_transport" -ne 1 ]] || return 1
		return 0
	}
	if ! _register_headless_runtime_sensitive_temp_path "$prompt_dir"; then
		rm -rf "$prompt_dir" 2>/dev/null || true
		[[ "$force_file_transport" -ne 1 ]] || return 1
		return 0
	fi

	local prompt_path="${prompt_dir}/seed-prompt.md"
	if ! printf '%s' "$prompt_text" >"$prompt_path"; then
		rm -rf "$prompt_dir" 2>/dev/null || true
		unset AIDEVOPS_HEADLESS_PROMPT_DIR
		[[ "$force_file_transport" -ne 1 ]] || return 1
		return 0
	fi

	case "$runtime" in
	claude)
		# Claude Code -p reads the prompt from stdin when no prompt argument is
		# supplied; keep the large seed out of argv while preserving content.
		_HEADLESS_RUN_PROMPT_ARG=""
		_HEADLESS_CLAUDE_STDIN_FILE="$prompt_path"
		;;
	opencode | *)
		# OpenCode has no stdin prompt mode in `opencode run --help`; attach the
		# seed file and pass a short instruction, avoiding process-table bloat.
		# The attached path is framework-generated and bounded to this attempt;
		# expose only its directory to the OpenCode config hook so workers can read
		# the attachment without a generic external_directory approval.
		_HEADLESS_RUN_PROMPT_ARG="Read and execute the complete seed prompt attached as seed-prompt.md. Treat the attached file as the user prompt for this headless run."
		_HEADLESS_RUN_PROMPT_FILE="$prompt_path"
		export AIDEVOPS_HEADLESS_PROMPT_DIR="$prompt_dir"
		;;
	esac

	return 0
}

# Build an empty, trusted OpenCode project for public triage. The model receives
# only the prefetched prompt attachment; it never starts in the target repository
# or inherits that repository's OpenCode configuration. The selected restricted
# agent and optional auth plugin are copied from framework-owned paths.
# Arguments: $1=name of caller variable receiving the directory path.
_prepare_triage_runtime_directory() {
	local result_var="$1"
	local prepared_dir=""
	local isolated_agent_name="triage-review"
	local agent_source="${SCRIPT_DIR}/../workflows/triage-review.md"
	local config_dir=""
	local permission_deny="deny"
	local plugin_path="${SCRIPT_DIR}/../plugins/opencode-aidevops/index.mjs"
	local plugin_url=""
	local staged_agent=""

	[[ "$result_var" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
	if declare -F _headless_ai_research_contract_is_valid >/dev/null 2>&1 &&
		_headless_ai_research_contract_is_valid \
			"${AIDEVOPS_SESSION_ORIGIN:-}" "${AIDEVOPS_AI_RESEARCH_TOOL_CEILING:-}" \
			"${agent_name:-}"; then
		isolated_agent_name="research-only"
		agent_source="${SCRIPT_DIR}/../workflows/ai-research.md"
	fi
	[[ -f "$agent_source" && ! -L "$agent_source" ]] || {
		print_error "Trusted ${isolated_agent_name} agent definition is unavailable"
		return 1
	}
	prepared_dir=$(_create_headless_runtime_temp_dir "triage") || return 1
	if ! _register_headless_runtime_sensitive_temp_path "$prepared_dir"; then
		rm -rf "$prepared_dir" 2>/dev/null || true
		return 1
	fi
	config_dir="${prepared_dir}/.opencode"
	mkdir -p "${config_dir}/agent" || return 1
	staged_agent="${config_dir}/agent/${isolated_agent_name}.md"
	cp "$agent_source" "$staged_agent" || return 1
	chmod 600 "$staged_agent" 2>/dev/null || true

	local config_file="${config_dir}/opencode.json"
	if [[ -f "$plugin_path" ]]; then
		plugin_url=$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).absolute().as_uri())' \
			"$plugin_path" 2>/dev/null) || return 1
		jq -n --arg plugin_url "$plugin_url" --arg agent_name "$isolated_agent_name" \
			--arg permission_deny "$permission_deny" '{
			"$schema": "https://opencode.ai/config.json",
			plugin: [$plugin_url],
			default_agent: $agent_name,
			agent: {($agent_name): {mode: "primary", permission: {"*": $permission_deny}, tools: {"*": false}}},
			permission: {"*": $permission_deny},
			tools: {"*": false},
			mcp: {},
			formatter: false,
			lsp: false,
			share: "disabled",
			subagent_depth: 0
		}' >"$config_file" || return 1
	else
		jq -n --arg agent_name "$isolated_agent_name" --arg permission_deny "$permission_deny" '{
			"$schema": "https://opencode.ai/config.json",
			default_agent: $agent_name,
			agent: {($agent_name): {mode: "primary", permission: {"*": $permission_deny}, tools: {"*": false}}},
			permission: {"*": $permission_deny},
			tools: {"*": false},
			mcp: {},
			formatter: false,
			lsp: false,
			share: "disabled",
			subagent_depth: 0
		}' >"$config_file" || return 1
	fi
	chmod 600 "$config_file" 2>/dev/null || true
	printf -v "$result_var" '%s' "$prepared_dir"
	return 0
}

# _parse_run_args: parse cmd_run flags into caller-scoped variables.
# Caller must declare: role session_key work_dir title prompt prompt_file
#                      model_override initial_model tier_override variant_override agent_name
#                      private_workload private_profile_sha256 extra_args
# Returns 1 on unknown flag.
_parse_run_args() {
	local -a run_args=("$@")
	local arg=""
	local value=""
	while [[ "${#run_args[@]}" -gt 0 ]]; do
		arg="${run_args[0]}"
		value="${run_args[1]:-}"
		case "$arg" in
		--role)
			role="$value"
			run_args=("${run_args[@]:2}")
			;;
		--session-key)
			session_key="$value"
			run_args=("${run_args[@]:2}")
			;;
		--dir)
			work_dir="$value"
			run_args=("${run_args[@]:2}")
			;;
		--title)
			title="$value"
			run_args=("${run_args[@]:2}")
			;;
		--prompt)
			prompt="$value"
			run_args=("${run_args[@]:2}")
			;;
		--prompt-file)
			prompt_file="$value"
			run_args=("${run_args[@]:2}")
			;;
		--model)
			model_override="$value"
			run_args=("${run_args[@]:2}")
			;;
		--initial-model)
			initial_model="$value"
			run_args=("${run_args[@]:2}")
			;;
		--tier)
			tier_override="$value"
			run_args=("${run_args[@]:2}")
			;;
		--variant)
			variant_override="$value"
			run_args=("${run_args[@]:2}")
			;;
		--agent)
			agent_name="$value"
			run_args=("${run_args[@]:2}")
			;;
		--runtime)
			# Explicit runtime override: "opencode" (default), "claude", etc.
			headless_runtime="$value"
			run_args=("${run_args[@]:2}")
			;;
		--opencode-arg)
			extra_args+=("$value")
			run_args=("${run_args[@]:2}")
			;;
		--private-workload)
			private_workload=1
			run_args=("${run_args[@]:1}")
			;;
		--private-profile-sha256)
			private_profile_sha256="$value"
			run_args=("${run_args[@]:2}")
			;;
		--detach)
			detach=1
			run_args=("${run_args[@]:1}")
			;;
		*)
			print_error "Unknown option for run: $arg"
			return 1
			;;
		esac
	done
	return 0
}

_validate_private_workload_profile() {
	local work_dir_value="$1"
	local expected_model="$2"
	local expected_agent="$3"
	local expected_profile_sha256="$4"
	local expected_provider="${expected_model%%/*}"
	local config_path="${work_dir_value}/.opencode/opencode.json"
	local profile_validator="${SCRIPT_DIR}/headless-private-profile-validator.py"

	if [[ ! -f "$config_path" || -L "$config_path" ]]; then
		print_error "--private-workload requires a regular .opencode/opencode.json profile"
		return 1
	fi
	if [[ ! -f "$profile_validator" ]] || ! command -v python3 >/dev/null 2>&1 ||
		! python3 "$profile_validator" "$work_dir_value" "$expected_model" \
			"$expected_agent" "$expected_provider" "$expected_profile_sha256" \
			>/dev/null 2>&1; then
		print_error "--private-workload requires a private, fixed restricted profile"
		return 1
	fi

	return 0
}

_private_provider_is_allowlisted() {
	local expected_provider="$1"
	local allowlist_raw="${AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST:-}"
	local allowed_provider=""
	local -a allowed_providers=()

	[[ -n "$allowlist_raw" ]] || return 1
	IFS=',' read -r -a allowed_providers <<<"$allowlist_raw"
	for allowed_provider in "${allowed_providers[@]}"; do
		allowed_provider="${allowed_provider#"${allowed_provider%%[![:space:]]*}"}"
		allowed_provider="${allowed_provider%"${allowed_provider##*[![:space:]]}"}"
		if [[ "$allowed_provider" == "$expected_provider" ]]; then
			return 0
		fi
	done
	return 1
}

_private_workload_session_key_is_opaque() {
	local session_key_value="$1"
	[[ "$session_key_value" =~ ^private-([a-f0-9]{32}|[a-f0-9]{64})$ ]]
	return $?
}

_validate_private_workload_args() {
	[[ "${private_workload:-0}" == "1" ]] || return 0
	if [[ ! "${private_profile_sha256:-}" =~ ^[a-f0-9]{64}$ ]]; then
		print_error "--private-workload requires an exact --private-profile-sha256"
		return 1
	fi
	if [[ "${role:-}" != "triage" ]]; then
		print_error "--private-workload requires --role triage"
		return 1
	fi
	if ! _private_workload_session_key_is_opaque "${session_key:-}"; then
		print_error "--private-workload requires an opaque private- session key with 32 or 64 lowercase hex characters"
		return 1
	fi
	if [[ "${title:-}" != "Private workload" ]]; then
		print_error "--private-workload requires --title 'Private workload'"
		return 1
	fi
	if [[ -n "${prompt_file:-}" || "${prompt:-}" != "$PRIVATE_WORKLOAD_PROMPT" ]]; then
		print_error "--private-workload requires the documented non-content prompt"
		return 1
	fi
	if [[ -n "${headless_runtime:-}" && "${headless_runtime:-}" != "opencode" ]]; then
		print_error "--private-workload currently supports only the OpenCode runtime"
		return 1
	fi
	if [[ "${detach:-0}" -eq 1 ]]; then
		print_error "--private-workload cannot be detached"
		return 1
	fi
	if [[ ! "${model_override:-}" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
		print_error "--private-workload requires an explicit --model"
		return 1
	fi
	local expected_provider="${model_override%%/*}"
	if ! _private_provider_is_allowlisted "$expected_provider"; then
		print_error "--private-workload requires its provider in AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST"
		return 1
	fi
	if [[ ! "${agent_name:-}" =~ ^[A-Za-z0-9_-]+$ ]]; then
		print_error "--private-workload requires an explicit --agent"
		return 1
	fi
	if [[ -n "${variant_override:-}" ]]; then
		print_error "--private-workload does not permit a model variant override"
		return 1
	fi
	local pure_count=0
	local extra_arg=""
	for extra_arg in "${extra_args[@]+"${extra_args[@]}"}"; do
		if [[ "$extra_arg" != "--pure" ]]; then
			print_error "--private-workload permits only --opencode-arg --pure"
			return 1
		fi
		pure_count=$((pure_count + 1))
	done
	if [[ "$pure_count" -ne 1 ]]; then
		print_error "--private-workload requires exactly one --opencode-arg --pure"
		return 1
	fi
	return 0
}

# _validate_run_args: check required fields and resolve prompt from file if needed.
# Operates on caller-scoped variables set by _parse_run_args.
_validate_run_args() {
	[[ -n "${session_key:-}" ]] || {
		print_error "run requires --session-key"
		return 1
	}
	[[ -n "${work_dir:-}" ]] || {
		print_error "run requires --dir"
		return 1
	}
	[[ -n "${title:-}" ]] || {
		print_error "run requires --title"
		return 1
	}
	if [[ -z "${prompt:-}" && -n "${prompt_file:-}" ]]; then
		[[ -f "${prompt_file:-}" ]] || {
			print_error "Prompt file not found: ${prompt_file:-}"
			return 1
		}
		prompt=$(<"${prompt_file:-}")
	fi
	[[ -n "${prompt:-}" ]] || {
		print_error "run requires --prompt or --prompt-file"
		return 1
	}
	return 0
}

# _ensure_valid_launch_cwd: recover from callers whose inherited cwd was deleted.
#
# OpenCode validates the process cwd before it processes --dir. When the pulse
# starts a worker from a worktree that cleanup removed, OpenCode exits with
# "The current working directory was deleted" before reading the launch prompt.
# Move the helper itself into the worker worktree early so canary, sandbox, and
# runtime startup all inherit a valid cwd.
_ensure_valid_launch_cwd() {
	local work_dir_value="$1"
	local fallback_dir="${HOME:-/tmp}"

	if pwd -P >/dev/null 2>&1; then
		return 0
	fi

	if [[ -n "$work_dir_value" && -d "$work_dir_value" ]]; then
		if cd "$work_dir_value" 2>/dev/null; then
			local display_work_dir="$work_dir_value"
			if _headless_private_workload_enabled; then
				display_work_dir="[private]"
			fi
			print_warning "Recovered deleted launch cwd by switching to worker directory: $display_work_dir"
			return 0
		fi
	fi

	if [[ -d "$fallback_dir" ]] && cd "$fallback_dir" 2>/dev/null; then
		print_warning "Recovered deleted launch cwd by switching to fallback directory: $fallback_dir"
		return 0
	fi

	print_error "[fatal] launch cwd is deleted and no valid fallback directory is available"
	return 1
}

# _run_requires_issue_env_contract: detect issue-scoped implementation workers
# from independent caller-owned signals. Triage correlation deliberately uses
# issue-shaped titles/session keys without carrying worker lifecycle authority.
_run_requires_issue_env_contract() {
	local role_value="$1"
	local session_key_value="$2"
	local title_value="$3"
	local prompt_value="$4"

	[[ "$role_value" == "worker" ]] || return 1
	if [[ "$session_key_value" =~ ^issue-[0-9]+$ ]]; then
		return 0
	fi
	if [[ "$title_value" =~ ^Issue[[:space:]]+#[0-9]+ ]]; then
		return 0
	fi
	if [[ "$title_value" =~ Issue[[:space:]]+#[0-9]+ ]]; then
		return 0
	fi
	if [[ "$prompt_value" =~ [Ii]ssue[[:space:]]*#?[0-9]+ ]]; then
		return 0
	fi

	return 1
}

# _validate_issue_worker_env_contract: fail before canary/model launch when an
# issue worker lacks the dispatcher-precreated worktree contract.
_validate_issue_worker_env_contract() {
	local role_value="$1"
	local session_key_value="$2"
	local work_dir_value="$3"
	local title_value="$4"
	local prompt_value="$5"
	local session_issue_number=""

	if ! _run_requires_issue_env_contract "$role_value" "$session_key_value" "$title_value" "$prompt_value"; then
		return 0
	fi

	if [[ -z "${WORKER_ISSUE_NUMBER:-}" ]]; then
		print_error "[fatal] WORKER_ISSUE_NUMBER unset — issue worker env contract missing; aborting before model launch"
		return 1
	fi
	if [[ ! "${WORKER_ISSUE_NUMBER:-}" =~ ^[1-9][0-9]*$ ]]; then
		print_error "[fatal] WORKER_ISSUE_NUMBER invalid — expected a positive integer; aborting before model launch"
		return 1
	fi
	if [[ "$session_key_value" =~ ^issue-([0-9]+)$ ]]; then
		session_issue_number="${BASH_REMATCH[1]}"
	elif [[ "$session_key_value" =~ ^triage-review-([0-9]+)$ ]]; then
		session_issue_number="${BASH_REMATCH[1]}"
	fi
	if [[ -n "$session_issue_number" && "$WORKER_ISSUE_NUMBER" != "$session_issue_number" ]]; then
		print_error "[fatal] WORKER_ISSUE_NUMBER does not match session issue identity; aborting before model launch"
		return 1
	fi
	if [[ -z "${WORKER_REPO_SLUG:-}" ]]; then
		print_error "[fatal] WORKER_REPO_SLUG unset — issue worker env contract missing; aborting before model launch"
		return 1
	fi
	if [[ -z "${WORKER_WORKTREE_PATH:-}" ]]; then
		print_error "[fatal] WORKER_WORKTREE_PATH unset — issue worker env contract missing; aborting before model launch"
		return 1
	fi
	if [[ ! -d "${WORKER_WORKTREE_PATH:-}" ]]; then
		print_error "[fatal] WORKER_WORKTREE_PATH does not exist: ${WORKER_WORKTREE_PATH:-<unset>}"
		return 1
	fi

	local env_worktree_real=""
	local work_dir_real=""
	env_worktree_real=$(cd "$WORKER_WORKTREE_PATH" 2>/dev/null && pwd -P) || env_worktree_real=""
	work_dir_real=$(cd "$work_dir_value" 2>/dev/null && pwd -P) || work_dir_real=""
	if [[ -z "$env_worktree_real" || -z "$work_dir_real" || "$env_worktree_real" != "$work_dir_real" ]]; then
		print_error "[fatal] worker --dir does not match WORKER_WORKTREE_PATH; aborting before model launch"
		return 1
	fi

	local remote_url=""
	local actual_slug=""
	remote_url=$(git -C "$WORKER_WORKTREE_PATH" remote get-url origin 2>/dev/null) || remote_url=""
	actual_slug=$(printf '%s' "$remote_url" | sed 's|.*github\.com[:/]||;s|\.git$||') || actual_slug=""
	if [[ -z "$actual_slug" || "$actual_slug" != "$WORKER_REPO_SLUG" ]]; then
		print_error "[fatal] worker worktree repo mismatch: expected ${WORKER_REPO_SLUG}, got ${actual_slug:-<unknown>}"
		return 1
	fi

	return 0
}

# _recover_deleted_cwd_before_launch: ensure runtime launch starts from a real cwd.
# A parent shell can dispatch a worker after its current directory has been
# removed (for example after worktree cleanup). OpenCode fails before reading the
# prompt in that state, even when --dir points at a valid worker worktree.
_recover_deleted_cwd_before_launch() {
	local work_dir_value="$1"
	local reason_value="${2:-prelaunch}"
	local recovery_dir=""

	if pwd -P >/dev/null 2>&1; then
		return 0
	fi

	if [[ -n "${WORKER_WORKTREE_PATH:-}" && -d "${WORKER_WORKTREE_PATH:-}" ]]; then
		recovery_dir="$WORKER_WORKTREE_PATH"
	elif [[ -n "$work_dir_value" && -d "$work_dir_value" ]]; then
		recovery_dir="$work_dir_value"
	fi

	if [[ -z "$recovery_dir" ]]; then
		print_error "[lifecycle] deleted_cwd_recovery_failed reason=$reason_value target=none"
		return 1
	fi
	local display_recovery_dir="$recovery_dir"
	if _headless_private_workload_enabled; then
		display_recovery_dir="[private]"
	fi

	if ! cd "$recovery_dir"; then
		print_error "[lifecycle] deleted_cwd_recovery_failed reason=$reason_value target=$display_recovery_dir"
		return 1
	fi

	print_warning "[lifecycle] recovered_deleted_cwd reason=$reason_value dir=$display_recovery_dir"
	return 0
}

#######################################
# Detect OpenCode/Drizzle replaying CREATE TABLE migrations against an already
# prewarmed worker DB. This happens before the seed prompt reaches the model and
# is safe to recover by retrying once with a fresh isolated DB.
# Args: $1 = runtime exit code, $2 = output file path.
#######################################
_opencode_project_table_migration_replay_detected() {
	local exit_code="$1"
	local output_file="$2"
	local project_table_backtick="table \`project\` already exists"
	local output_text=""

	[[ "${exit_code:-}" != "0" ]] || return 1
	[[ -f "$output_file" ]] || return 1
	output_text=$(<"$output_file") || output_text=""
	case "$output_text" in
	*"$project_table_backtick"* | *"table project already exists"* | *"table 'project' already exists"* | *'table "project" already exists'*)
		return 0
		;;
	esac
	return 1
}
