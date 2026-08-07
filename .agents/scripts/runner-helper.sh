#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# runner-helper.sh - Named headless AI agent instances with persistent identity
#
# Runners are named, persistent agent instances that can be dispatched headlessly.
# Each runner gets its own AGENTS.md (personality), config, and optional memory namespace.
#
# Usage:
#   runner-helper.sh create <name> [--description "desc"] [--model tier_or_model] [--provider name] [--workdir path]
#   runner-helper.sh run <name> "prompt" [--attach URL] [--model tier_or_model] [--provider name] [--format json] [--timeout N]
#   runner-helper.sh status <name>
#   runner-helper.sh list [--format json]
#   runner-helper.sh edit <name>          # Open AGENTS.md in $EDITOR
#   runner-helper.sh logs <name> [--tail N] [--follow]
#   runner-helper.sh stop <name>          # Abort running session
#   runner-helper.sh destroy <name> [--force]
#   runner-helper.sh help
#
# Directory: ~/.aidevops/.agent-workspace/runners/<name>/
#   ├── AGENTS.md      # Runner personality/instructions
#   ├── config.json    # Runner configuration (model, workdir, etc.)
#   ├── memory.db      # Runner-specific memories (optional, via --namespace)
#   ├── session.id     # Last session ID (for --continue)
#   └── runs/          # Run logs
#
# Integration:
#   - Memory: memory-helper.sh --namespace <runner-name>
#   - Mailbox: mail-helper.sh --to <runner-name>
#   - Cron: cron-helper.sh --task "runner-helper.sh run <name> 'prompt'"
#
# Backend detection (t1160.3, t1160):
#   - Prefers opencode if available, claude CLI as first-class fallback
#   - Override: AIDEVOPS_DISPATCH_BACKEND=claude|opencode
#   - Claude CLI uses -p for headless mode, strips provider/ prefix from model
#   - Claude CLI supports --max-budget-usd, --fallback-model, --mcp-config
#
# Security:
#   - Uses HTTPS by default for remote OpenCode servers
#   - Supports basic auth via OPENCODE_SERVER_PASSWORD
#   - Runner AGENTS.md files are local-only (not committed to repos)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
readonly RUNNERS_DIR="${AIDEVOPS_RUNNERS_DIR:-$HOME/.aidevops/.agent-workspace/runners}"
readonly MEMORY_HELPER="$HOME/.aidevops/agents/scripts/memory-helper.sh"
readonly MAIL_HELPER="$HOME/.aidevops/agents/scripts/mail-helper.sh"
readonly OPENCODE_PORT="${OPENCODE_PORT:-4096}"
readonly OPENCODE_HOST="${OPENCODE_HOST:-127.0.0.1}"
readonly DEFAULT_MODEL="standard"

[[ -z "${BOLD+x}" ]] && BOLD='\033[1m'

# Logging: uses shared log_* from shared-constants.sh with RUNNER prefix
# shellcheck disable=SC2034  # Used by shared-constants.sh log_* functions
LOG_PREFIX="RUNNER"

#######################################
# Mailbox bookend: check inbox before work
# Registers agent, checks for unread messages,
# returns context to prepend to prompt
#######################################
mailbox_before_run() {
	local name="$1"

	if [[ ! -x "$MAIL_HELPER" ]]; then
		return 0
	fi

	# Register this runner as active
	AIDEVOPS_AGENT_ID="$name" "$MAIL_HELPER" register \
		--agent "$name" --role worker 2>/dev/null || true

	# Check for unread messages
	local unread_messages
	unread_messages=$(AIDEVOPS_AGENT_ID="$name" "$MAIL_HELPER" check --unread-only 2>/dev/null)

	local unread_count
	unread_count=$(echo "$unread_messages" | grep '^Total:' | sed -n 's/.*(\([0-9]*\) unread).*/\1/p' || echo "0")
	if [[ -z "$unread_count" ]]; then
		unread_count=0
	fi

	if [[ "$unread_count" -gt 0 ]]; then
		log_info "Mailbox: $unread_count unread message(s) for $name"
		# Return the messages as context (TOON format, parseable by the agent)
		echo "$unread_messages"
	fi
}

#######################################
# Mailbox bookend: report status after work
# Sends status report and deregisters
#######################################
mailbox_after_run() {
	local name="$1"
	local run_status="$2"
	local duration="$3"
	local run_id="$4"

	if [[ ! -x "$MAIL_HELPER" ]]; then
		return 0
	fi

	# Send status report
	AIDEVOPS_AGENT_ID="$name" "$MAIL_HELPER" send \
		--to coordinator \
		--type status_report \
		--payload "Runner $name completed ($run_status, ${duration}s, $run_id)" \
		2>/dev/null || true

	# Deregister (mark inactive)
	AIDEVOPS_AGENT_ID="$name" "$MAIL_HELPER" deregister --agent "$name" 2>/dev/null || true

	log_info "Mailbox: status report sent, $name deregistered"
}

#######################################
# Check if jq is available
#######################################
check_jq() {
	if ! command -v jq &>/dev/null; then
		log_error "jq is required but not installed. Install with: brew install jq"
		return 1
	fi
	return 0
}

#######################################
# Detect available AI CLI backend (t1160.3, t1160, t1665.5)
# Sets AIDEVOPS_DISPATCH_BACKEND to a runtime ID from the registry.
#
# Priority (aligned with supervisor/dispatch.sh resolve_ai_cli):
#   1. AIDEVOPS_DISPATCH_BACKEND env var (explicit override)
#   2. SUPERVISOR_CLI env var (supervisor-level override)
#   3. First headless-capable runtime found via registry
#
# Returns 1 if no backend is available
#######################################
detect_dispatch_backend() {
	if [[ -n "${AIDEVOPS_DISPATCH_BACKEND:-}" ]]; then
		# Already detected or explicitly set
		return 0
	fi

	# Honour SUPERVISOR_CLI if set (supervisor-level override)
	if [[ -n "${SUPERVISOR_CLI:-}" ]]; then
		# Validate it's a known runtime binary
		local cli_binary="$SUPERVISOR_CLI"
		if type rt_id_from_binary &>/dev/null; then
			local rt_id
			rt_id=$(rt_id_from_binary "$cli_binary") || true
			if [[ -z "$rt_id" ]]; then
				log_error "SUPERVISOR_CLI='$SUPERVISOR_CLI' is not a registered runtime"
				return 1
			fi
		fi
		if command -v "$cli_binary" &>/dev/null; then
			AIDEVOPS_DISPATCH_BACKEND="$cli_binary"
			log_info "Using dispatch backend: $AIDEVOPS_DISPATCH_BACKEND (from SUPERVISOR_CLI)"
			return 0
		fi
		log_error "SUPERVISOR_CLI='$SUPERVISOR_CLI' not found in PATH"
		return 1
	fi

	# Use runtime registry to find first available headless-capable backend (t1665.5)
	if type rt_list_headless &>/dev/null; then
		local rt_id bin
		while IFS= read -r rt_id; do
			bin=$(rt_binary "$rt_id") || continue
			if [[ -n "$bin" ]] && command -v "$bin" &>/dev/null; then
				AIDEVOPS_DISPATCH_BACKEND="$bin"
				log_info "Using dispatch backend: $AIDEVOPS_DISPATCH_BACKEND (runtime: $rt_id)"
				return 0
			fi
		done < <(rt_list_headless)
		log_error "No AI CLI backend available. Install a headless-capable runtime (opencode, claude, codex, etc.)"
		return 1
	fi

	# Fallback: hardcoded check (registry not loaded)
	if command -v opencode &>/dev/null; then
		AIDEVOPS_DISPATCH_BACKEND="opencode"
	elif command -v claude &>/dev/null; then
		AIDEVOPS_DISPATCH_BACKEND="claude"
	else
		log_error "No AI CLI backend available. Install opencode (https://opencode.ai) or Claude Code CLI (https://docs.anthropic.com/en/docs/claude-cli)"
		return 1
	fi

	log_info "Using dispatch backend: $AIDEVOPS_DISPATCH_BACKEND"
	return 0
}

#######################################
# Extract Claude-compatible model name from provider/model string (t1160.3)
# opencode uses "anthropic/claude-sonnet-4-6", Claude CLI uses "claude-sonnet-4-6"
#######################################
model_for_claude_cli() {
	local model="$1"
	# Strip provider prefix if present (e.g., "anthropic/claude-sonnet-4-6" -> "claude-sonnet-4-6")
	if [[ "$model" == *"/"* ]]; then
		echo "${model#*/}"
	else
		echo "$model"
	fi
	return 0
}

#######################################
# Validate runner name (alphanumeric, hyphens, underscores)
#######################################
validate_name() {
	local name="$1"
	if [[ ! "$name" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
		log_error "Invalid runner name: '$name' (must start with letter, contain only alphanumeric, hyphens, underscores)"
		return 1
	fi
	if [[ ${#name} -gt 40 ]]; then
		log_error "Runner name too long: '$name' (max 40 characters)"
		return 1
	fi
	return 0
}

#######################################
# Get runner directory
#######################################
runner_dir() {
	local name="$1"
	echo "$RUNNERS_DIR/$name"
}

#######################################
# Check if runner exists
#######################################
runner_exists() {
	local name="$1"
	local dir
	dir=$(runner_dir "$name")
	[[ -d "$dir" && -f "$dir/config.json" ]]
}

#######################################
# Get runner config value
#######################################
runner_config() {
	local name="$1"
	local key="$2"
	local dir
	dir=$(runner_dir "$name")
	jq -r --arg key "$key" '.[$key] // empty' "$dir/config.json" 2>/dev/null
}

#######################################
# Determine protocol based on host
#######################################
get_protocol() {
	local host="$1"
	if [[ "$host" == "localhost" || "$host" == "127.0.0.1" || "$host" == "::1" ]]; then
		echo "http"
	else
		echo "https"
	fi
}

#######################################
# Build curl arguments array for secure requests
#######################################
build_curl_args() {
	CURL_ARGS=(-sf)

	if [[ -n "${OPENCODE_SERVER_PASSWORD:-}" ]]; then
		local user="${OPENCODE_SERVER_USERNAME:-opencode}"
		CURL_ARGS+=(-u "${user}:${OPENCODE_SERVER_PASSWORD}")
	fi

	local protocol
	protocol=$(get_protocol "$OPENCODE_HOST")
	if [[ "$protocol" == "https" && -n "${OPENCODE_INSECURE:-}" ]]; then
		CURL_ARGS+=(-k)
	fi
}

#######################################
# Parse create command arguments
# Sets: description, model, workdir, provider (via nameref-style globals)
# Usage: _parse_create_args description_var model_var workdir_var provider_var "$@"
#######################################
_parse_create_args() {
	# Use indirect assignment via eval for bash 3.2 compatibility (no namerefs)
	local _desc_var="$1" _model_var="$2" _workdir_var="$3" _provider_var="$4"
	shift 4

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--description)
			[[ $# -lt 2 ]] && {
				log_error "--description requires a value"
				return 1
			}
			eval "${_desc_var}=\"\$2\""
			shift 2
			;;
		--model)
			[[ $# -lt 2 ]] && {
				log_error "--model requires a value"
				return 1
			}
			eval "${_model_var}=\"\$2\""
			shift 2
			;;
		--provider)
			[[ $# -lt 2 ]] && {
				log_error "--provider requires a value"
				return 1
			}
			eval "${_provider_var}=\"\$2\""
			shift 2
			;;
		--workdir)
			[[ $# -lt 2 ]] && {
				log_error "--workdir requires a value"
				return 1
			}
			eval "${_workdir_var}=\"\$2\""
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done
	return 0
}

#######################################
# Resolve a stored model tier only when a runner is dispatched.
# Sets RUNNER_ROUTE_MODEL, RUNNER_ROUTE_TIER, RUNNER_ROUTE_VARIANT, and
# RUNNER_ROUTE_CANDIDATE_INDEX.
#######################################
resolve_runner_route() {
	local model_spec="${1:-standard}"
	local provider="${2:-}"
	local dispatch_backend="${AIDEVOPS_DISPATCH_BACKEND:-}"
	if [[ -z "$provider" && "${dispatch_backend##*/}" == "claude" ]]; then
		provider="anthropic"
	fi
	RUNNER_ROUTE_MODEL="$model_spec"
	RUNNER_ROUTE_TIER=""
	RUNNER_ROUTE_VARIANT=""
	RUNNER_ROUTE_CANDIDATE_INDEX=-1
	case "$model_spec" in
	simple | standard | thinking) RUNNER_ROUTE_TIER="$model_spec" ;;
	esac
	if [[ -n "$RUNNER_ROUTE_TIER" ]]; then
		if [[ -n "$provider" ]]; then
			RUNNER_ROUTE_MODEL=$(model_tier_candidate_for_provider "$RUNNER_ROUTE_TIER" "$provider" 2>/dev/null) || {
				log_error "No ${provider} candidate is configured for tier ${RUNNER_ROUTE_TIER}"
				return 1
			}
		else
			RUNNER_ROUTE_MODEL=$(resolve_model_tier "$RUNNER_ROUTE_TIER")
		fi
		if [[ "$RUNNER_ROUTE_MODEL" != *"/"* ]]; then
			log_error "No runnable candidate is configured for tier ${RUNNER_ROUTE_TIER}"
			return 1
		fi
	elif [[ -n "$provider" && "$RUNNER_ROUTE_MODEL" == *"/"* ]]; then
		RUNNER_ROUTE_MODEL="${provider}/${RUNNER_ROUTE_MODEL#*/}"
	else
		RUNNER_ROUTE_TIER=$(model_tier_for_model "$RUNNER_ROUTE_MODEL" 2>/dev/null || true)
	fi
	if [[ -n "$RUNNER_ROUTE_TIER" ]]; then
		RUNNER_ROUTE_VARIANT=$(model_tier_variant "$RUNNER_ROUTE_TIER" "$RUNNER_ROUTE_MODEL" 2>/dev/null || true)
		RUNNER_ROUTE_CANDIDATE_INDEX=$(model_tier_candidate_index "$RUNNER_ROUTE_TIER" "$RUNNER_ROUTE_MODEL" 2>/dev/null) || RUNNER_ROUTE_CANDIDATE_INDEX=-1
	fi
	return 0
}

#######################################
# Write runner config.json and AGENTS.md to disk
#######################################
_write_runner_files() {
	local name="$1"
	local description="$2"
	local model="$3"
	local workdir="$4"
	local provider="${5:-}"

	local dir
	dir=$(runner_dir "$name")
	mkdir -p "$dir/runs"

	local timestamp
	timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	jq -n \
		--arg name "$name" \
		--arg description "$description" \
		--arg model "$model" \
		--arg provider "$provider" \
		--arg workdir "${workdir:-}" \
		--arg created "$timestamp" \
		'{
            name: $name,
            description: $description,
            model: $model,
            model_tier:(if ($model == "simple" or $model == "standard" or $model == "thinking") then $model else null end),
            provider:(if $provider == "" then null else $provider end),
            workdir: $workdir,
            created: $created,
            lastRun: null,
            lastStatus: null,
            runCount: 0
        }' >"$dir/config.json"

	cat >"$dir/AGENTS.md" <<EOF
# $name

$description

## Instructions

Add your runner-specific instructions here. This file defines the runner's
personality, rules, and output format.

## Rules

- Follow the task prompt precisely
- Output structured results when possible
- Report errors clearly with context

## Output Format

Respond with clear, actionable output appropriate to the task.
EOF
	return 0
}

#######################################
# Create a new runner
#######################################
cmd_create() {
	check_jq || return 1

	local name="${1:-}"
	shift || true

	if [[ -z "$name" ]]; then
		log_error "Runner name required"
		echo "Usage: runner-helper.sh create <name> [--description \"desc\"] [--model provider/model]"
		return 1
	fi

	validate_name "$name" || return 1

	if runner_exists "$name"; then
		log_error "Runner already exists: $name"
		echo "Use 'runner-helper.sh edit $name' to modify, or 'runner-helper.sh destroy $name' to recreate."
		return 1
	fi

	local description="" model="$DEFAULT_MODEL" workdir="" provider=""
	_parse_create_args description model workdir provider "$@" || return 1

	if [[ -z "$description" ]]; then
		description="Runner: $name"
	fi

	local dir
	dir=$(runner_dir "$name")
	_write_runner_files "$name" "$description" "$model" "$workdir" "$provider" || return 1

	log_success "Created runner: $name"
	echo ""
	echo "Directory: $dir"
	echo "Model: $model"
	echo ""
	echo "Next steps:"
	echo "  1. Edit instructions: runner-helper.sh edit $name"
	echo "  2. Test run: runner-helper.sh run $name \"your prompt\""

	return 0
}

#######################################
# Parse run command arguments
# Uses indirect assignment for bash 3.2 compatibility (no namerefs)
# Sets: attach, model, format, cmd_timeout, continue_session, provider
#######################################
_parse_run_args() {
	local _attach_var="$1" _model_var="$2" _format_var="$3"
	local _timeout_var="$4" _continue_var="$5" _provider_var="$6"
	shift 6

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--attach)
			[[ $# -lt 2 ]] && {
				log_error "--attach requires a value"
				return 1
			}
			eval "${_attach_var}=\"\$2\""
			shift 2
			;;
		--model)
			[[ $# -lt 2 ]] && {
				log_error "--model requires a value"
				return 1
			}
			eval "${_model_var}=\"\$2\""
			shift 2
			;;
		--provider)
			[[ $# -lt 2 ]] && {
				log_error "--provider requires a value"
				return 1
			}
			eval "${_provider_var}=\"\$2\""
			shift 2
			;;
		--format)
			[[ $# -lt 2 ]] && {
				log_error "--format requires a value"
				return 1
			}
			eval "${_format_var}=\"\$2\""
			shift 2
			;;
		--timeout)
			[[ $# -lt 2 ]] && {
				log_error "--timeout requires a value"
				return 1
			}
			eval "${_timeout_var}=\"\$2\""
			shift 2
			;;
		--continue | -c)
			eval "${_continue_var}=true"
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done
	return 0
}

#######################################
# Build the CLI dispatch command array for opencode or claude backend
# Populates the caller's cmd_args array (passed by name)
# Args: cmd_args_var name model attach format continue_session dir workdir variant
#######################################
_build_dispatch_cmd() {
	local _arr_var="$1"
	local name="$2"
	local model="$3"
	local attach="$4"
	local format="$5"
	local continue_session="$6"
	local dir="$7"
	local workdir="$8"
	local variant="${9:-}"

	if [[ "$AIDEVOPS_DISPATCH_BACKEND" == "opencode" ]]; then
		eval "${_arr_var}=(\"opencode\" \"run\")"
		[[ -n "$attach" ]] && eval "${_arr_var}+=( \"--attach\" \"\$attach\" )"
		eval "${_arr_var}+=( \"-m\" \"\$model\" \"--title\" \"runner/\$name\" \"--dir\" \"\$workdir\" )"
		[[ -z "$variant" ]] || eval "${_arr_var}+=( \"--variant\" \"\$variant\" )"

		if [[ "$continue_session" == "true" ]]; then
			local session_id=""
			[[ -f "$dir/session.id" ]] && session_id=$(cat "$dir/session.id")
			if [[ -n "$session_id" ]]; then
				eval "${_arr_var}+=( \"-s\" \"\$session_id\" )"
			else
				log_warn "No previous session found for $name, starting fresh"
			fi
		fi

		[[ -n "$format" ]] && eval "${_arr_var}+=( \"--format\" \"\$format\" )"

	elif [[ "$AIDEVOPS_DISPATCH_BACKEND" == "claude" ]]; then
		local claude_model
		claude_model=$(model_for_claude_cli "$model")
		local claude_format
		case "${format:-text}" in
		text | json | stream-json) claude_format="${format:-text}" ;;
		*) claude_format="text" ;;
		esac

		eval "${_arr_var}=(\"claude\" \"-p\" \"--model\" \"\$claude_model\" \"--output-format\" \"\$claude_format\" \"--dir\" \"\$workdir\")"

		if [[ "$continue_session" == "true" ]]; then
			local session_file="$dir/session.id"
			if [[ -s "$session_file" ]]; then
				eval "${_arr_var}+=( \"--resume\" \"\$(cat \"\$session_file\")\" )"
			else
				log_warn "No previous session found for $name, starting fresh"
			fi
		fi

		[[ -n "$attach" ]] && log_warn "Claude CLI does not support --attach (server mode). Ignoring."
	fi
	return 0
}

#######################################
# Build the full prompt string with memory and mailbox context prepended
# Echoes the assembled prompt to stdout
#######################################
_build_run_prompt() {
	local name="$1"
	local prompt="$2"
	local dir="$3"

	# Mailbox bookend: check inbox before work
	local mailbox_context
	mailbox_context=$(mailbox_before_run "$name" 2>/dev/null || true)

	# Memory auto-recall: retrieve relevant memories before work
	local memory_context="" recent_memories="" task_memories=""
	if [[ -x "$MEMORY_HELPER" ]]; then
		recent_memories=$("$MEMORY_HELPER" --namespace "$name" recall --recent --limit 5 --format text 2>/dev/null || echo "")
		task_memories=$("$MEMORY_HELPER" --namespace "$name" recall --query "$prompt" --limit 5 --format text 2>/dev/null || echo "")
	fi

	if [[ -n "$recent_memories" || -n "$task_memories" ]]; then
		memory_context="## Memory Context (relevant learnings from previous runs)

"
		[[ -n "$recent_memories" ]] && memory_context="${memory_context}### Recent Memories

${recent_memories}

"
		[[ -n "$task_memories" ]] && memory_context="${memory_context}### Task-Relevant Memories

${task_memories}

"
		log_info "Retrieved memory context for runner: $name"
	fi

	# Build the full prompt with runner instructions
	local agents_md="$dir/AGENTS.md"
	local full_prompt
	if [[ -f "$agents_md" ]]; then
		local instructions
		instructions=$(cat "$agents_md")
		full_prompt="${instructions}

---

## Task

${prompt}"
	else
		full_prompt="$prompt"
	fi

	# Prepend memory context if available
	if [[ -n "$memory_context" ]]; then
		full_prompt="${memory_context}

---

${full_prompt}"
	fi

	# Prepend mailbox context if there are unread messages
	if [[ -n "$mailbox_context" ]] && echo "$mailbox_context" | grep -q '^Total:.*([1-9][0-9]* unread)'; then
		full_prompt="## Mailbox (unread messages from other agents)

${mailbox_context}

---

${full_prompt}"
		log_info "Prepended mailbox context to prompt"
	fi

	printf '%s' "$full_prompt"
	return 0
}

#######################################
# Execute the dispatch command, update run metadata, report status
# Args: name dir cmd_timeout run_id run_timestamp cmd_args...
# Returns the exit code of the dispatched command
#######################################
_execute_run() {
	local name="$1"
	local dir="$2"
	local cmd_timeout="$3"
	local run_id="$4"
	local run_timestamp="$5"
	shift 5
	# remaining args are the command array

	local log_file="$dir/runs/${run_id}.log"

	log_info "Dispatching to runner: $name"
	log_info "Run ID: $run_id"

	local exit_code=0
	local start_time
	start_time=$(date +%s)

	timeout_sec "$cmd_timeout" "$@" 2>&1 | tee "$log_file"
	exit_code=${PIPESTATUS[0]}

	local end_time duration
	end_time=$(date +%s)
	duration=$((end_time - start_time))

	# Update config with run metadata
	local temp_file
	temp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${temp_file}'"
	local status="success"
	[[ $exit_code -ne 0 ]] && status="failed"

	jq --arg timestamp "$run_timestamp" \
		--arg status "$status" \
		--argjson duration "$duration" \
		'.lastRun = $timestamp | .lastStatus = $status | .lastDuration = $duration | .runCount += 1' \
		"$dir/config.json" >"$temp_file"
	mv "$temp_file" "$dir/config.json"

	if [[ $exit_code -eq 0 ]]; then
		log_success "Run complete (${duration}s)"
	else
		log_error "Run failed after ${duration}s (exit code: $exit_code)"
	fi

	mailbox_after_run "$name" "$status" "$duration" "$run_id" 2>/dev/null || true

	return "$exit_code"
}

#######################################
# Run a task on a runner
#######################################
cmd_run() {
	check_jq || return 1
	detect_dispatch_backend || return 1

	local name="${1:-}"
	shift || true

	if [[ -z "$name" ]]; then
		log_error "Runner name required"
		echo "Usage: runner-helper.sh run <name> \"prompt\" [--attach URL] [--model provider/model]"
		return 1
	fi

	if ! runner_exists "$name"; then
		log_error "Runner not found: $name"
		echo "Create it with: runner-helper.sh create $name"
		return 1
	fi

	local prompt="${1:-}"
	shift || true

	if [[ -z "$prompt" ]]; then
		log_error "Prompt required"
		echo "Usage: runner-helper.sh run $name \"your prompt here\""
		return 1
	fi

	local attach="" model="" format="" cmd_timeout="$DEFAULT_TIMEOUT" continue_session=false
	local provider=""
	_parse_run_args attach model format cmd_timeout continue_session provider "$@" || return 1

	local dir
	dir=$(runner_dir "$name")

	# Preserve tier intent in config and resolve it only at execution time.
	if [[ -z "$model" ]]; then
		model=$(runner_config "$name" "model")
		[[ -z "$model" ]] && model="$DEFAULT_MODEL"
	fi
	if [[ -z "$provider" ]]; then
		provider=$(runner_config "$name" "provider")
	fi
	resolve_runner_route "$model" "$provider" || return 1
	model="$RUNNER_ROUTE_MODEL"
	export AIDEVOPS_DISPATCH_TIER="$RUNNER_ROUTE_TIER"
	export AIDEVOPS_ROUTING_CANDIDATE_INDEX="$RUNNER_ROUTE_CANDIDATE_INDEX"
	export AIDEVOPS_ROUTING_ATTEMPT="1"
	export AIDEVOPS_ROUTING_REASON="runner_dispatch"
	export AIDEVOPS_ROUTING_ESCALATED="0"
	export AIDEVOPS_ROUTING_VARIANT="$RUNNER_ROUTE_VARIANT"

	# Resolve workdir
	local workdir
	workdir=$(runner_config "$name" "workdir")
	[[ -z "$workdir" ]] && workdir="$(pwd)"

	local model_label="Model:"
	log_info "$model_label $model"
	[[ -z "$RUNNER_ROUTE_TIER" ]] || log_info "Tier: $RUNNER_ROUTE_TIER"

	# Build dispatch command array
	local -a cmd_args=()
	_build_dispatch_cmd cmd_args "$name" "$model" "$attach" "$format" "$continue_session" "$dir" "$workdir" "$RUNNER_ROUTE_VARIANT" || return 1

	# Build full prompt with memory/mailbox context
	local full_prompt
	full_prompt=$(_build_run_prompt "$name" "$prompt" "$dir") || return 1
	cmd_args+=("$full_prompt")

	# Execute
	local run_timestamp run_id
	run_timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
	run_id="run-$(date +%s)"

	_execute_run "$name" "$dir" "$cmd_timeout" "$run_id" "$run_timestamp" "${cmd_args[@]}"
	return $?
}

#######################################
# Show runner status
#######################################
cmd_status() {
	check_jq || return 1

	local name="${1:-}"

	if [[ -z "$name" ]]; then
		log_error "Runner name required"
		return 1
	fi

	if ! runner_exists "$name"; then
		log_error "Runner not found: $name"
		return 1
	fi

	local dir
	dir=$(runner_dir "$name")
	local config="$dir/config.json"

	local description model workdir created last_run last_status run_count last_duration
	local config_values
	config_values=$(jq -r '[
        .description // "N/A",
        .model // "N/A",
        .workdir // "N/A",
        .created // "N/A",
        .lastRun // "never",
        .lastStatus // "N/A",
        (.runCount // 0 | tostring),
        (.lastDuration // "N/A" | tostring)
    ] | join("\n")' "$config")

	{
		read -r description
		read -r model
		read -r workdir
		read -r created
		read -r last_run
		read -r last_status
		read -r run_count
		read -r last_duration
	} <<<"$config_values"

	local status_color="$NC"
	case "$last_status" in
	success) status_color="$GREEN" ;;
	failed) status_color="$RED" ;;
	esac

	echo -e "${BOLD}Runner: $name${NC}"
	echo "──────────────────────────────────"
	echo "Description: $description"
	echo "Model: $model"
	echo "Workdir: $workdir"
	echo "Created: $created"
	echo ""
	echo "Total runs: $run_count"
	echo "Last run: $last_run"
	echo -e "Last status: ${status_color}${last_status}${NC}"
	echo "Last duration: ${last_duration}s"
	echo ""
	echo "Directory: $dir"

	# Check for session file
	if [[ -f "$dir/session.id" ]]; then
		echo "Session ID: $(cat "$dir/session.id")"
	fi

	# Check for memory namespace
	if [[ -x "$MEMORY_HELPER" ]]; then
		local mem_count
		mem_count=$("$MEMORY_HELPER" --namespace "$name" stats 2>/dev/null | safe_grep_count "Total")
		if [[ "$mem_count" -gt 0 ]]; then
			echo "Memory entries: $mem_count"
		fi
	fi

	return 0
}

#######################################
# List all runners
#######################################
cmd_list() {
	local output_format="table"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--format)
			[[ $# -lt 2 ]] && {
				log_error "--format requires a value"
				return 1
			}
			output_format="$2"
			shift 2
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ ! -d "$RUNNERS_DIR" ]]; then
		log_info "No runners configured"
		echo ""
		echo "Create one with:"
		echo "  runner-helper.sh create my-runner --description \"What it does\""
		return 0
	fi

	local runners
	runners=$(find "$RUNNERS_DIR" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort)

	if [[ -z "$runners" ]]; then
		log_info "No runners configured"
		return 0
	fi

	if [[ "$output_format" == "json" ]]; then
		local -a config_files=()
		for runner_path in $runners; do
			local config_file="$runner_path/config.json"
			if [[ -f "$config_file" ]]; then
				config_files+=("$config_file")
			fi
		done

		if ((${#config_files[@]} > 0)); then
			jq -s . "${config_files[@]}"
		else
			echo "[]"
		fi
		return 0
	fi

	printf "${BOLD}%-20s %-35s %-12s %s${NC}\n" "Name" "Description" "Runs" "Last Status"
	printf "%-20s %-35s %-12s %s\n" "──────────────────" "─────────────────────────────────" "──────────" "───────────"

	for runner_path in $runners; do
		local rname
		rname=$(basename "$runner_path")
		local config_file="$runner_path/config.json"

		if [[ ! -f "$config_file" ]]; then
			continue
		fi

		local description run_count last_status
		description=$(jq -r '.description // "N/A"' "$config_file")
		run_count=$(jq -r '.runCount // 0' "$config_file")
		last_status=$(jq -r '.lastStatus // "N/A"' "$config_file")

		local status_color="$NC"
		case "$last_status" in
		success) status_color="$GREEN" ;;
		failed) status_color="$RED" ;;
		esac

		printf "%-20s %-35s %-12s ${status_color}%s${NC}\n" \
			"$rname" "${description:0:35}" "$run_count" "$last_status"
	done

	return 0
}

#######################################
# Edit runner AGENTS.md
#######################################
cmd_edit() {
	local name="${1:-}"

	if [[ -z "$name" ]]; then
		log_error "Runner name required"
		return 1
	fi

	if ! runner_exists "$name"; then
		log_error "Runner not found: $name"
		return 1
	fi

	local dir
	dir=$(runner_dir "$name")
	local agents_file="$dir/AGENTS.md"

	local editor="${EDITOR:-vim}"
	"$editor" "$agents_file"

	log_success "Updated AGENTS.md for runner: $name"
	return 0
}

#######################################
# View runner logs
#######################################
cmd_logs() {
	local name="${1:-}"
	shift || true

	if [[ -z "$name" ]]; then
		log_error "Runner name required"
		return 1
	fi

	if ! runner_exists "$name"; then
		log_error "Runner not found: $name"
		return 1
	fi

	local tail_lines=50 follow=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--tail)
			[[ $# -lt 2 ]] && {
				log_error "--tail requires a value"
				return 1
			}
			tail_lines="$2"
			shift 2
			;;
		--follow | -f)
			follow=true
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	local dir
	dir=$(runner_dir "$name")
	local runs_dir="$dir/runs"

	if [[ ! -d "$runs_dir" ]]; then
		log_info "No run logs found for runner: $name"
		return 0
	fi

	local log_files
	log_files=$(find "$runs_dir" -name "*.log" -type f 2>/dev/null | sort -r)

	if [[ -z "$log_files" ]]; then
		log_info "No run logs found for runner: $name"
		return 0
	fi

	if [[ "$follow" == "true" ]]; then
		local latest
		latest=$(echo "$log_files" | head -1)
		log_info "Following latest log: $(basename "$latest")"
		tail -f "$latest"
	else
		local latest
		latest=$(echo "$log_files" | head -1)
		echo -e "${BOLD}Latest run: $(basename "$latest" .log)${NC}"
		tail -n "$tail_lines" "$latest"
	fi

	return 0
}

#######################################
# Stop a running session (abort)
#######################################
cmd_stop() {
	check_jq || return 1

	local name="${1:-}"

	if [[ -z "$name" ]]; then
		log_error "Runner name required"
		return 1
	fi

	if ! runner_exists "$name"; then
		log_error "Runner not found: $name"
		return 1
	fi

	local dir
	dir=$(runner_dir "$name")

	if [[ ! -f "$dir/session.id" ]]; then
		log_warn "No active session found for runner: $name"
		return 0
	fi

	local session_id
	session_id=$(cat "$dir/session.id")

	local protocol
	protocol=$(get_protocol "$OPENCODE_HOST")
	local url="${protocol}://${OPENCODE_HOST}:${OPENCODE_PORT}/session/${session_id}/abort"

	build_curl_args

	if curl "${CURL_ARGS[@]}" -X POST "$url" &>/dev/null; then
		log_success "Aborted session for runner: $name"
	else
		log_warn "Could not abort session (may not be running)"
	fi

	return 0
}

#######################################
# Destroy a runner
#######################################
cmd_destroy() {
	local name="${1:-}"
	shift || true

	if [[ -z "$name" ]]; then
		log_error "Runner name required"
		return 1
	fi

	if ! runner_exists "$name"; then
		log_error "Runner not found: $name"
		return 1
	fi

	local force=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--force)
			force=true
			shift
			;;
		*)
			log_error "Unknown option: $1"
			return 1
			;;
		esac
	done

	if [[ "$force" != "true" ]]; then
		echo -n "Destroy runner '$name' and all its data? [y/N] "
		read -r confirm
		if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
			log_info "Cancelled"
			return 0
		fi
	fi

	local dir
	dir=$(runner_dir "$name")
	rm -rf "$dir"

	# Clean up memory namespace if it exists
	local ns_dir="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}/namespaces/$name"
	if [[ -d "$ns_dir" ]]; then
		rm -rf "$ns_dir"
		log_info "Removed memory namespace: $name"
	fi

	log_success "Destroyed runner: $name"
	return 0
}

#######################################
# Show help
#######################################
cmd_help() {
	cat <<'EOF'
runner-helper.sh - Named headless AI agent instances

USAGE:
    runner-helper.sh <command> [options]

COMMANDS:
    create <name>           Create a new runner
    run <name> "prompt"     Dispatch a task to a runner
    status <name>           Show runner status and metadata
    list                    List all runners
    edit <name>             Open runner AGENTS.md in $EDITOR
    logs <name>             View run logs
    stop <name>             Abort running session
    destroy <name>          Remove a runner and all its data
    help                    Show this help

CREATE OPTIONS:
    --description "DESC"    Runner description
    --model TIER_OR_MODEL   Workload tier (simple/standard/thinking)
                             or full provider/model string (default: standard)
    --provider PROVIDER     Override provider (e.g., openrouter, google)
    --workdir PATH          Default working directory

RUN OPTIONS:
    --attach URL            Attach to running OpenCode server (avoids MCP cold boot)
    --model TIER_OR_MODEL   Override model: tier name or provider/model string
    --provider PROVIDER     Override provider for this run
    --format json           Output format (default or json)
    --timeout SECONDS       Max execution time (default: 600)
    --continue, -c          Continue previous session

LIST OPTIONS:
    --format json           Output as JSON

LOGS OPTIONS:
    --tail N                Number of lines (default: 50)
    --follow, -f            Follow log output

EXAMPLES:
    # Create a code reviewer
    runner-helper.sh create code-reviewer \
      --description "Reviews code for security and quality" \
      --model anthropic/claude-sonnet-4-6

    # Run a review task
    runner-helper.sh run code-reviewer "Review src/auth/ for vulnerabilities"

    # Run against warm server (faster, no MCP cold boot)
    runner-helper.sh run code-reviewer "Review src/auth/" \
      --attach http://localhost:4096

    # Continue a previous conversation
    runner-helper.sh run code-reviewer "Now check the error handling" --continue

    # Edit runner instructions
    runner-helper.sh edit code-reviewer

    # View recent logs
    runner-helper.sh logs code-reviewer --tail 100

    # List all runners as JSON
    runner-helper.sh list --format json

DIRECTORY:
    Runners: ~/.aidevops/.agent-workspace/runners/
    Each runner: AGENTS.md, config.json, runs/

INTEGRATION:
    Memory:  memory-helper.sh store --namespace <runner-name> --content "..."
    Mailbox: mail-helper.sh send --to <runner-name> --type task_dispatch --payload "..."
    Cron:    cron-helper.sh add --task "runner-helper.sh run <name> 'prompt'"

REQUIREMENTS:
    - opencode (https://opencode.ai) OR Claude CLI (https://docs.anthropic.com/en/docs/claude-cli)
    - jq (brew install jq)

BACKEND DETECTION:
    Prefers opencode if available, falls back to Claude CLI.
    Override with: AIDEVOPS_DISPATCH_BACKEND=claude runner-helper.sh run ...
    Note: Claude CLI does not support --attach (server mode), --title, or --format.

EOF
}

#######################################
# Main
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	create) cmd_create "$@" ;;
	run) cmd_run "$@" ;;
	status) cmd_status "$@" ;;
	list) cmd_list "$@" ;;
	edit) cmd_edit "$@" ;;
	logs) cmd_logs "$@" ;;
	stop) cmd_stop "$@" ;;
	destroy) cmd_destroy "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		log_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
	local command_status=$?
	return "$command_status"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
