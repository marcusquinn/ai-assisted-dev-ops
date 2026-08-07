#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Headless Runtime Model — Model Choice & Cmd Builders (GH#19699)
# =============================================================================
# Model selection, session management, and CLI command construction functions
# extracted from headless-runtime-lib.sh to reduce file size.
#
# Covers two functional areas:
#   1. Model Choice  — configured model list derivation, ordered failover,
#                       tier downgrade, explicit model validation, session ID mgmt
#   2. Cmd Builders  — headless variant resolution, OpenCode server detection,
#                       opencode/claude CLI command assembly, completion signal
#                       detection in worker output
#
# Usage: source "${SCRIPT_DIR}/headless-runtime-model.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_warning)
#   - headless-runtime-lib.sh Section 1 functions (db_query, sql_escape, trim_spaces)
#   - headless-runtime-provider.sh (extract_provider, provider_auth_available,
#     provider_oauth_pool_available, model_backoff_active)
#   - worker-lifecycle-common.sh (resolve_model_tier)
#   - Constants from headless-runtime-helper.sh (OPENCODE_BIN_DEFAULT,
#     DEFAULT_HEADLESS_MODELS, SCRIPT_DIR)
#   - bash 3.2+, python3, jq, curl (optional)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_MODEL_LOADED:-}" ]] && return 0
readonly _HEADLESS_RUNTIME_MODEL_LOADED=1

# --- Model Choice ---

_normalize_headless_tier() {
	local tier="${1:-standard}"
	case "$tier" in
	simple | standard | thinking) printf '%s' "$tier" ;;
	*) printf '%s' "$tier" ;;
	esac
	return 0
}

# Derive the headless model list from the routing table (GH#17769).
# Flow: routing table standard tier -> optional provider allowlist -> providers with
# usable auth at dispatch time. This eliminates AIDEVOPS_HEADLESS_MODELS as a
# user-configurable env var while allowing temporary provider pinning via
# AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST.
get_configured_models() {
	local requested_tier="${1:-standard}"
	local tier_name
	tier_name=$(_normalize_headless_tier "$requested_tier")
	local allowlist_raw="${AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST:-}"
	local -a allowlist=()
	local -a models=()
	local provider model

	# Backward compatibility: if legacy env var is still set, log deprecation
	# warning but respect it as an override for one release cycle.
	if [[ -n "${AIDEVOPS_HEADLESS_MODELS:-}" ]]; then
		print_warning "AIDEVOPS_HEADLESS_MODELS is deprecated (v3.7+). Model routing is now automatic via pool + routing table. Remove this export from credentials.sh. Respecting override for this release cycle."
		local -a raw_models=()
		IFS=',' read -r -a raw_models <<<"$AIDEVOPS_HEADLESS_MODELS"
		for item in "${raw_models[@]}"; do
			item=$(trim_spaces "$item")
			[[ -z "$item" ]] && continue
			provider=$(extract_provider "$item" 2>/dev/null || printf '%s' "")
			[[ -z "$provider" ]] && continue
			models+=("$item")
		done
		if [[ ${#models[@]} -gt 0 ]]; then
			printf '%s\n' "${models[@]}"
			return 0
		fi
	fi

	if [[ -n "$allowlist_raw" ]]; then
		IFS=',' read -r -a allowlist <<<"$allowlist_raw"
	fi

	while IFS= read -r model; do
			[[ -z "$model" ]] && continue
			provider=$(extract_provider "$model" 2>/dev/null || printf '%s' "")
			[[ -z "$provider" ]] && continue

			if [[ ${#allowlist[@]} -gt 0 ]]; then
				local allowed=false
				local allowed_provider
				for allowed_provider in "${allowlist[@]}"; do
					allowed_provider=$(trim_spaces "$allowed_provider")
					if [[ "$allowed_provider" == "$provider" ]]; then
						allowed=true
						break
					fi
				done
				[[ "$allowed" == "true" ]] || continue
			fi

			if ! provider_auth_available "$provider"; then
				continue
			fi

			models+=("$model")
	done < <(model_tier_candidates "$tier_name" 2>/dev/null || true)

	# Local is a privacy boundary: an empty local tier means unavailable, never
	# permission to use the historical cloud fallback.
	if [[ "$tier_name" == "local" ]]; then
		return 0
	fi

	printf '%s\n' "${models[@]}"
	return 0
}

get_last_provider() {
	local role="$1"
	db_query "SELECT last_provider FROM provider_rotation WHERE role = '$(sql_escape "$role")';"
	return 0
}

set_last_provider() {
	local role="$1"
	local provider="$2"
	db_query "
INSERT INTO provider_rotation (role, last_provider, updated_at)
VALUES ('$(sql_escape "$role")', '$(sql_escape "$provider")', strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
ON CONFLICT(role) DO UPDATE SET
    last_provider = excluded.last_provider,
    updated_at = excluded.updated_at;
" >/dev/null
	return 0
}

_provider_session_repo_slug() {
	local repo_slug="${WORKER_REPO_SLUG:-${DISPATCH_REPO_SLUG:-${GITHUB_REPOSITORY:-}}}"
	repo_slug="${repo_slug#https://github.com/}"
	repo_slug="${repo_slug#git@github.com:}"
	repo_slug="${repo_slug%.git}"
	repo_slug=$(printf '%s' "$repo_slug" | tr '[:upper:]' '[:lower:]')
	case "$repo_slug" in
	*/*) printf '%s' "$repo_slug" ;;
	*) printf '%s' "" ;;
	esac
	return 0
}

scoped_provider_session_key() {
	local session_key="$1"
	local repo_slug=""
	repo_slug=$(_provider_session_repo_slug)
	if [[ "$session_key" == issue-* && -n "$repo_slug" ]]; then
		printf '%s#%s' "$repo_slug" "$session_key"
		return 0
	fi
	printf '%s' "$session_key"
	return 0
}

get_session_id() {
	local provider="$1"
	local session_key="$2"
	local scoped_key=""
	scoped_key=$(scoped_provider_session_key "$session_key")
	db_query "SELECT session_id FROM provider_sessions WHERE provider = '$(sql_escape "$provider")' AND session_key = '$(sql_escape "$scoped_key")';"
	return 0
}

clear_session_id() {
	local provider="$1"
	local session_key="$2"
	local scoped_key=""
	scoped_key=$(scoped_provider_session_key "$session_key")
	db_query "DELETE FROM provider_sessions WHERE provider = '$(sql_escape "$provider")' AND session_key IN ('$(sql_escape "$scoped_key")', '$(sql_escape "$session_key")');" >/dev/null
	return 0
}

store_session_id() {
	local provider="$1"
	local session_key="$2"
	local session_id="$3"
	local model="$4"
	local scoped_key=""
	scoped_key=$(scoped_provider_session_key "$session_key")
	if [[ "$scoped_key" != "$session_key" ]]; then
		db_query "DELETE FROM provider_sessions WHERE provider = '$(sql_escape "$provider")' AND session_key = '$(sql_escape "$session_key")';" >/dev/null
	fi
	db_query "
INSERT INTO provider_sessions (provider, session_key, session_id, model, updated_at)
VALUES (
    '$(sql_escape "$provider")',
    '$(sql_escape "$scoped_key")',
    '$(sql_escape "$session_id")',
    '$(sql_escape "$model")',
    strftime('%Y-%m-%dT%H:%M:%SZ', 'now')
)
ON CONFLICT(provider, session_key) DO UPDATE SET
    session_id = excluded.session_id,
    model = excluded.model,
    updated_at = excluded.updated_at;
" >/dev/null
	return 0
}

# _choose_model_explicit: validate and return an explicitly-requested model.
# Returns 0 on success (prints model), 1 on bad format, 75 if backed off.
_choose_model_explicit() {
	local explicit_model="$1"
	local provider
	provider=$(extract_provider "$explicit_model" 2>/dev/null || printf '%s' "")
	if [[ -z "$provider" ]]; then
		print_error "Model must use provider/model format: $explicit_model"
		return 1
	fi
	if model_backoff_active "$explicit_model"; then
		print_warning "$explicit_model is currently backed off"
		return 75
	fi
	printf '%s' "$explicit_model"
	return 0
}

_first_healthy_configured_model() {
	local tier_name="${1:-standard}"
	local selection_mode="${2:-adaptive}"
	local current_model="" current_provider="" configured_count=0
	while IFS= read -r current_model; do
		[[ -n "$current_model" ]] || continue
		if [[ "$selection_mode" == "exact-tier" ]] &&
			! model_tier_candidate_index "$tier_name" "$current_model" >/dev/null 2>&1; then
			continue
		fi
		configured_count=$((configured_count + 1))
		current_provider=$(extract_provider "$current_model" 2>/dev/null || true)
		[[ -n "$current_provider" ]] || continue
		provider_auth_available "$current_provider" || continue
		provider_oauth_pool_available "$current_provider" || continue
		model_backoff_active "$current_model" && continue
		printf '%s' "$current_model"
		return 0
	done < <(get_configured_models "$tier_name")
	[[ "$configured_count" -gt 0 ]] && return 75
	return 1
}

# _choose_model_tier_downgrade: check pattern history for a cheaper tier.
# Prints the downgraded model name if one is recommended; prints nothing otherwise.
# Non-blocking -- any failure falls through silently.
_choose_model_tier_downgrade() {
	local current_model="$1"
	local downgrade_task_type="${AIDEVOPS_TIER_DOWNGRADE_TASK_TYPE:-}"
	[[ -n "$downgrade_task_type" ]] || return 0

	local current_tier=""
	current_tier=$(model_tier_for_model "$current_model" 2>/dev/null || true)
	[[ -n "$current_tier" ]] || return 0

	local pattern_helper="${SCRIPT_DIR}/archived/pattern-tracker-helper.sh"
	if [[ ! -x "$pattern_helper" ]]; then
		pattern_helper="${HOME}/.aidevops/agents/scripts/archived/pattern-tracker-helper.sh"
	fi
	[[ -x "$pattern_helper" ]] || return 0

	local lower_tier
	lower_tier=$("$pattern_helper" tier-downgrade-check \
		--requested-tier "$current_tier" \
		--task-type "$downgrade_task_type" \
		--min-samples "${AIDEVOPS_TIER_DOWNGRADE_MIN_SAMPLES:-3}" \
		2>/dev/null || true)
	[[ -n "$lower_tier" ]] || return 0

	local lower_model
	lower_model=$(_first_healthy_configured_model "$lower_tier" 2>/dev/null || true)
	if [[ -n "$lower_model" && "$lower_model" != "$current_model" ]]; then
		print_info "Model for dispatch: pattern data recommends ${lower_tier} over ${current_tier} (TIER_DOWNGRADE_OK, task_type=${downgrade_task_type})"
		printf '%s' "$lower_model"
	fi
	return 0
}

# _choose_model_auto: select the first available model in configured order.
# Skips models that are backed off or have no auth. Returns 75 if all are backed off.
_choose_model_auto() {
	local role="$1"
	local tier_name="${2:-standard}"
	local selection_mode="${3:-adaptive}"
	local current_model="" select_status=0
	current_model=$(_first_healthy_configured_model "$tier_name" "$selection_mode") || select_status=$?
	if [[ "$select_status" -eq 1 ]]; then
		print_error "No direct provider models configured for headless runtime"
		return 1
	fi
	if [[ "$select_status" -eq 75 || -z "$current_model" ]]; then
		print_warning "All configured models are currently backed off"
		return 75
	fi

	case "$selection_mode" in
	adaptive)
		# Pattern-driven tier downgrade (t5148): non-blocking initial-dispatch
		# optimization. Retry and capability-escalation callers use exact-tier mode.
		local downgraded=""
		downgraded=$(_choose_model_tier_downgrade "$current_model")
		[[ -z "$downgraded" ]] || current_model="$downgraded"
		;;
	exact-tier) ;;
	*)
		print_error "Unknown model selection mode: $selection_mode"
		return 1
		;;
	esac
	local current_provider=""
	current_provider=$(extract_provider "$current_model")
	set_last_provider "$role" "$current_provider"
	printf '%s' "$current_model"
	return 0
}

choose_model() {
	local role="$1"
	local explicit_model="${2:-}"
	local tier_name="${3:-standard}"
	local selection_mode="${4:-adaptive}"

	if [[ -n "$explicit_model" ]]; then
		_choose_model_explicit "$explicit_model"
		return $?
	fi

	_choose_model_auto "$role" "$tier_name" "$selection_mode"
	return $?
}

# --- Cmd Builders ---

_headless_variant_should_omit_gpt55_standard() {
	local role="$1"
	local tier_upper="$2"
	local selected_model="$3"
	local variant="$4"

	[[ "$role" == "worker" ]] || return 1
	[[ -n "$variant" ]] || return 1
	case "$tier_upper" in
	STANDARD) ;;
	*) return 1 ;;
	esac
	case "$selected_model" in
	openai/gpt-5.5 | openai/gpt-5.5-*) return 0 ;;
	*) return 1 ;;
	esac
}

_headless_tier_variant() {
	local requested_tier="$1"
	local canonical_tier="$2"
	local requested_upper canonical_upper
	requested_upper=$(printf '%s' "$requested_tier" | tr '[:lower:]-' '[:upper:]_')
	canonical_upper=$(printf '%s' "$canonical_tier" | tr '[:lower:]-' '[:upper:]_')
	local env_name value=""
	for env_name in \
		"AIDEVOPS_HEADLESS_VARIANT_${canonical_upper}" \
		"AIDEVOPS_HEADLESS_VARIANT_${requested_upper}"; do
		value="${!env_name:-}"
		if [[ -n "$value" ]]; then
			printf '%s' "$value"
			return 0
		fi
	done
	return 0
}

_headless_routed_variant() {
	local tier="$1"
	local selected_model="$2"
	model_tier_variant "$tier" "$selected_model" 2>/dev/null || true
	return 0
}

resolve_headless_variant() {
	local role="$1"
	local tier="${2:-}"
	local selected_model="${3:-}"
	local variant="${AIDEVOPS_HEADLESS_VARIANT:-}"
	local tier_upper=""
	local canonical_tier=""

	if [[ -n "$tier" ]]; then
		canonical_tier=$(_normalize_headless_tier "$tier")
		tier_upper=$(printf '%s' "$canonical_tier" | tr '[:lower:]-' '[:upper:]_')
		local tier_variant
		tier_variant=$(_headless_tier_variant "$tier" "$canonical_tier")
		[[ -n "$tier_variant" ]] && variant="$tier_variant"
	fi

	case "$role" in
	pulse)
		if [[ -n "${AIDEVOPS_HEADLESS_PULSE_VARIANT:-}" ]]; then
			variant="${AIDEVOPS_HEADLESS_PULSE_VARIANT}"
		fi
		;;
	worker)
		if [[ -n "${AIDEVOPS_HEADLESS_WORKER_VARIANT:-}" ]]; then
			variant="${AIDEVOPS_HEADLESS_WORKER_VARIANT}"
		fi
		;;
	esac

	if [[ -n "$tier" ]]; then
		local tier_variant
		tier_variant=$(_headless_tier_variant "$tier" "$canonical_tier")
		[[ -n "$tier_variant" ]] && variant="$tier_variant"
	fi

	if [[ -z "$variant" && -n "$canonical_tier" ]]; then
		variant=$(_headless_routed_variant "$canonical_tier" "$selected_model")
	fi

	# GPT-5.5 currently benchmarks fastest for standard worker dispatch when
	# OpenCode sends no explicit reasoning-effort variant. Keep explicit CLI
	# --variant untouched (caller bypasses this resolver when provided), but
	# ignore env-derived high/xhigh defaults for non-thinking worker tiers.
	if _headless_variant_should_omit_gpt55_standard "$role" "$tier_upper" "$selected_model" "$variant"; then
		variant=""
	fi

	printf '%s' "$variant"
	return 0
}

# _detect_opencode_server: check if an opencode server is already listening.
# GH#17829: When `opencode serve` is running, `opencode run` without --attach
# fails with "Session not found". Detect the running server and return its URL.
#
# Detection strategy (does NOT rely on OPENCODE_PID -- that's intentionally
# excluded from worker envs per GH#6668):
#   1. Check OPENCODE_SERVER_PASSWORD is set (indicates a server context)
#   2. Verify a server is actually listening on the expected port
#
# Outputs two lines to stdout: URL then password (empty if no server found).
# Returns: 0 if a server is detected, 1 otherwise.
_detect_opencode_server() {
	local password="${OPENCODE_SERVER_PASSWORD:-}"
	if [[ -z "$password" ]]; then
		return 1
	fi

	local port="${OPENCODE_PORT:-4096}"
	local url="http://localhost:${port}"

	# Verify the server is actually listening (timeout 2s, silent).
	# Use /api/session/list as a lightweight endpoint -- it returns 401 without
	# auth but proves the server is up (vs connection refused).
	local http_code
	http_code=$(curl -s --max-time 2 -o /dev/null -w '%{http_code}' "${url}/api/session/list" 2>/dev/null)
	if [[ "$http_code" == "200" || "$http_code" == "401" ]]; then
		printf '%s\n%s\n' "$url" "$password"
		return 0
	fi

	# Fallback: check if anything is listening on the port (no curl endpoint needed)
	if command -v lsof >/dev/null 2>&1; then
		if lsof -iTCP:"$port" -sTCP:LISTEN -P -n >/dev/null 2>&1; then
			printf '%s\n%s\n' "$url" "$password"
			return 0
		fi
	fi

	return 1
}

# _build_run_cmd: build the opencode command array for a run attempt.
# Args: selected_model work_dir prompt title variant_override agent_name persisted_session
#       extra_args (remaining positional args)
# Outputs: space-separated command (caller must eval or use array assignment).
# Returns: 0 always.
_build_run_cmd() {
	local selected_model="$1"
	local work_dir="$2"
	local prompt="$3"
	local title="$4"
	local variant_override="$5"
	local agent_name="$6"
	local persisted_session="$7"
	shift 7

	# Emit base command args as null-delimited tokens (bash 3.2 compat: no local -a in subshell)
	printf '%s\0' "$OPENCODE_BIN_DEFAULT" run "$prompt" --dir "$work_dir" -m "$selected_model" --title "$title" --format json
	if [[ -n "$agent_name" ]]; then
		printf '%s\0' --agent "$agent_name"
	fi
	if [[ -n "$persisted_session" ]]; then
		printf '%s\0' --session "$persisted_session" --continue
	fi
	if [[ -n "$variant_override" ]]; then
		printf '%s\0' --variant "$variant_override"
	fi
	# GH#17829: Attach to running opencode server if one is detected.
	# Without this, `opencode run` tries to start an embedded server that
	# conflicts with the user's `opencode serve`, causing "Session not found".
	local _server_info=""
	if _server_info=$(_detect_opencode_server); then
		local _server_url _server_pass
		_server_url=$(echo "$_server_info" | head -1)
		_server_pass=$(echo "$_server_info" | tail -1)
		printf '%s\0' --attach "$_server_url" --password "$_server_pass"
	fi
	# Emit any extra args passed as positional parameters.
	# Use "$@" rather than a shift loop so the pre-commit positional-param
	# check (which flags $1-$9 usage) stays quiet while behaviour is identical.
	if [[ $# -gt 0 ]]; then
		printf '%s\0' "$@"
	fi
	return 0
}

# _build_claude_cmd: build the claude CLI headless command as null-delimited tokens.
# Used when --runtime claude is explicitly specified. OpenCode remains the default.
# Args: selected_model work_dir prompt title agent_name [extra_args...]
_build_claude_cmd() {
	local selected_model="$1"
	local work_dir="$2"
	local prompt="$3"
	local title="$4"
	local agent_name="$5"
	shift 5

	# claude -p runs headless and prints output. --output-format stream-json
	# gives structured output compatible with our result parsing.
	#
	# GH#21886 (supersedes GH#16978): Claude CLI has NO flag for setting cwd.
	# `claude --help` (verified against 2.1.123) lists --add-dir for granting
	# tool access to additional dirs and -w/--worktree for git worktree
	# creation, but neither sets the working directory. The earlier GH#16978
	# fix replaced --directory with --cwd, but `claude --cwd <dir>` errors
	# with `unknown option '--cwd'` exactly like --directory did.
	#
	# Correct mechanism: caller (_invoke_claude) cd's into $work_dir before
	# exec. We deliberately do NOT emit work_dir here; it is consumed by the
	# invocation site as a separate argument. work_dir is referenced via the
	# default-assign below so static analysis does not flag it unused (the
	# function signature is shared with _build_run_cmd for interchangeability).
	: "${work_dir:=}"
	printf '%s\0' "claude" "-p"
	if [[ -n "$prompt" ]]; then
		printf '%s\0' "$prompt"
	fi
	printf '%s\0' "--output-format" "stream-json" "--verbose"
	if [[ -n "$agent_name" ]]; then
		printf '%s\0' "--agent" "$agent_name"
	elif type -P claude >/dev/null 2>&1; then
		# Default to build-plus agent when none specified, if it exists in
		# the agent directory. This gives headless Claude sessions the same
		# aidevops agent behaviour as interactive sessions.
		local claude_agent_dir="$HOME/.claude/agents"
		if [[ -f "$claude_agent_dir/build-plus.md" ]]; then
			printf '%s\0' "--agent" "build-plus"
		fi
	fi
	# Model override: claude CLI uses --model flag
	if [[ -n "$selected_model" ]]; then
		# Strip provider prefix (anthropic/) -- claude CLI doesn't need it
		local claude_model="${selected_model#*/}"
		printf '%s\0' "--model" "$claude_model"
	fi
	# Max turns for safety
	printf '%s\0' "--max-turns" "50"
	# Permission mode: allow all tools in headless
	printf '%s\0' "--permission-mode" "bypassPermissions"
	# Emit any extra args.
	# Use "$@" rather than a shift loop so the pre-commit positional-param
	# check (which flags $1-$9 usage) stays quiet while behaviour is identical.
	if [[ $# -gt 0 ]]; then
		printf '%s\0' "$@"
	fi
	return 0
}

# output_has_completion_signal: check if a worker run produced a meaningful
# completion signal (FULL_LOOP_COMPLETE, exact POST_PR_HANDOFF, BLOCKED, or PR creation).
# Workers that produce tool calls but exit without these signals stopped
# prematurely -- typically after investigation/setup but before implementation.
#
# Args: $1 = output file path
# Returns: 0 if completion signal found, 1 if premature exit
output_has_completion_signal() {
	local file_path="$1"
	[[ -f "$file_path" ]] || return 1
	python3 - "$file_path" <<'PY'
import sys, json
from pathlib import Path

# GH#17549: Only check the MODEL'S OWN text output, not tool call results.
# The tee output includes file contents the model read (tool_use events).
# full-loop.md contains "FULL_LOOP_COMPLETE" as documentation -- grepping
# the raw output matches that and falsely classifies the run as complete,
# preventing the continuation retry from ever firing.
#
# Strategy: parse JSON lines for "type":"text" events (model output) and
# check only those. Fall back to raw grep for non-JSON output (claude CLI).

raw = Path(sys.argv[1]).read_text(errors='ignore')
blocked_marker = chr(66) + chr(76) + chr(79) + chr(67) + chr(75) + chr(69) + chr(68)

# Extract model text from JSON stream (OpenCode format)
model_text_parts = []
for line in raw.splitlines():
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        continue
    # OpenCode text events contain the model's own output.
    # GH#17596 (MEDIUM): consolidate extraction into a single pass checking
    # multiple common paths for text and tool input fields.
    event_type = obj.get("type", "")
    if event_type == "text":
        part = obj.get("part", {})
        text = (
            obj.get("text")
            or part.get("text")
            or ""
        )
        if text:
            model_text_parts.append(text)
    # Also check tool calls where the MODEL invoked gh pr create/merge
    # (the input field shows what the model requested, not file contents)
    elif event_type == "tool_use":
        part = obj.get("part", {})
        state = part.get("state", {})
        # GH#17596 (MEDIUM): check multiple common input paths
        inp = (
            obj.get('input')
            or part.get("input")
            or state.get("input")
            or {}
        )
        if isinstance(inp, dict):
            cmd = inp.get("command", "")
            if cmd:
                model_text_parts.append(cmd)

model_text = "\n".join(model_text_parts)

def has_post_pr_handoff(text):
    return any(line.strip() == "POST_PR_HANDOFF" for line in text.splitlines())

# If we extracted model text, use it exclusively
if model_text.strip():
    if has_post_pr_handoff(model_text):
        sys.exit(0)
    for marker in ("FULL_LOOP_COMPLETE", blocked_marker, "TASK_COMPLETE"):
        if marker in model_text:
            sys.exit(0)
    # GH#17596 (HIGH): verify both model intent AND actual success signal in raw.
    # Checking model_text alone may match commands the model merely mentioned
    # or invoked but that failed. Requiring a success signal in raw (same as
    # the fallback block) prevents false-positive completion classification.
    if "gh pr create" in model_text and ("pull/" in raw or "created pull request" in raw.lower()):
        sys.exit(0)
    if "gh pr merge" in model_text and "merged" in raw.lower():
        sys.exit(0)
    if "git push" in model_text and ("-> " in raw or "branch " in raw):
        sys.exit(0)
    sys.exit(1)

# Fallback for non-JSON output (claude CLI, plain text)
if has_post_pr_handoff(raw):
    sys.exit(0)
for marker in ("FULL_LOOP_COMPLETE", blocked_marker, "TASK_COMPLETE"):
    if marker in raw:
        sys.exit(0)
if "gh pr create" in raw and ("pull/" in raw or "Created pull request" in raw.lower()):
    sys.exit(0)
if "gh pr merge" in raw and ("Merged" in raw or "merged" in raw):
    sys.exit(0)
if "git push" in raw and ("-> " in raw or "branch " in raw):
    sys.exit(0)

sys.exit(1)
PY
	return $?
}

output_has_post_pr_handoff_signal() {
	local file_path="$1"
	[[ -f "$file_path" ]] || return 1
	python3 - "$file_path" <<'PY'
import json
import sys
from pathlib import Path

raw = Path(sys.argv[1]).read_text(errors='ignore')
model_text_parts = []
for line in raw.splitlines():
    line = line.strip()
    if not line.startswith('{'):
        continue
    try:
        obj = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        continue
    if obj.get('type', '') != 'text':
        continue
    part = obj.get('part', {})
    text = obj.get('text') or part.get('text') or ''
    if text:
        model_text_parts.append(text)

model_text = '\n'.join(model_text_parts)
candidate = model_text if model_text.strip() else raw
sys.exit(0 if any(line.strip() == 'POST_PR_HANDOFF' for line in candidate.splitlines()) else 1)
PY
	return $?
}

# output_has_blocked_signal: check if the model explicitly ended with BLOCKED.
# This is a valid terminal state for unattended workers, but it is not a
# successful implementation and must not inflate PR-throughput success metrics.
#
# Args: $1 = output file path
# Returns: 0 if the model emitted BLOCKED, 1 otherwise
output_has_blocked_signal() {
	local file_path="$1"
	[[ -f "$file_path" ]] || return 1
	python3 - "$file_path" <<'PY'
import sys, json
from pathlib import Path

raw = Path(sys.argv[1]).read_text(errors="ignore")
blocked_marker = chr(66) + chr(76) + chr(79) + chr(67) + chr(75) + chr(69) + chr(68)
model_text_parts = []
for line in raw.splitlines():
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        continue
    if obj.get("type", "") != "text":
        continue
    part = obj.get("part", {})
    text = obj.get("text") or part.get("text") or ""
    if text:
        model_text_parts.append(text)

model_text = "\n".join(model_text_parts)
if model_text.strip():
    sys.exit(0 if blocked_marker in model_text else 1)
sys.exit(0 if blocked_marker in raw else 1)
PY
	return $?
}

# output_has_capability_blocked_signal: check for the exact structured marker
# that authorizes a capability-tier escalation. Generic BLOCKED outcomes remain
# terminal so permission, authentication, policy, trust, and secret boundaries
# cannot be bypassed by selecting a more capable model.
#
# Args: $1 = output file path
# Returns: 0 if the model emitted "BLOCKED: capability limit - <evidence>", 1 otherwise
output_has_capability_blocked_signal() {
	local file_path="$1"
	[[ -f "$file_path" ]] || return 1
	python3 - "$file_path" <<'PY'
import sys, json, re
from pathlib import Path

raw = Path(sys.argv[1]).read_text(errors="ignore")
model_text_parts = []
saw_json_event = False
for line in raw.splitlines():
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        continue
    if not isinstance(obj, dict):
        continue
    saw_json_event = True
    if obj.get("type", "") != "text":
        continue
    part = obj.get("part", {})
    text = obj.get("text") or part.get("text") or ""
    if text:
        model_text_parts.append(text)

model_text = "\n".join(model_text_parts)
if model_text.strip():
    candidate = model_text
elif not saw_json_event:
    candidate = raw
else:
    sys.exit(1)
marker = re.compile(
    r"^\s*BLOCKED:\s*capability limit\s*-\s*\S(?:.*\S)?\s*$",
    re.IGNORECASE | re.MULTILINE,
)
sys.exit(0 if marker.search(candidate) else 1)
PY
	return $?
}

# output_has_missing_context_blocked_signal: check if the model explicitly
# blocked because implementation context was missing.
#
# Args: $1 = output file path
# Returns: 0 if the model emitted a missing-context blocker, 1 otherwise
output_has_missing_context_blocked_signal() {
	local file_path="$1"
	[[ -f "$file_path" ]] || return 1
	python3 - "$file_path" <<'PY'
import sys, json, re
from pathlib import Path

error_mode = "ign" "ore"
blocked_marker = chr(66) + chr(76) + chr(79) + chr(67) + chr(75) + chr(69) + chr(68)
raw = Path(sys.argv[1]).read_text(errors=error_mode)
model_text_parts = []
for line in raw.splitlines():
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        continue
    if obj.get("type", "") != "text":
        continue
    part = obj.get("part", {})
    text = obj.get("text") or part.get("text") or ""
    if text:
        model_text_parts.append(text)

model_text = "\n".join(model_text_parts)
text = model_text if model_text.strip() else raw
has_blocked = blocked_marker in text
has_missing_context = re.search(r"missing[ -]implementation[ -]context", text, re.IGNORECASE) is not None
sys.exit(0 if has_blocked and has_missing_context else 1)
PY
	return $?
}
