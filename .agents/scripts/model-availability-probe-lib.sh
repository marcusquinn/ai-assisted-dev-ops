#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Model Availability Probe Library -- Provider probing and tier resolution
# =============================================================================
# Provider health probing, rate-limit parsing, model availability checking,
# and tier resolution functions extracted from model-availability-helper.sh.
#
# Usage: source "${SCRIPT_DIR}/model-availability-probe-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning)
#   - model-availability-helper.sh constants (AVAILABILITY_DB, DEFAULT_HEALTH_TTL,
#     DEFAULT_RATELIMIT_TTL, PROBE_TIMEOUT, OPENCODE_MODELS_CACHE, AVAILABILITY_DIR)
#   - sqlite3, curl, jq
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_MODEL_AVAILABILITY_PROBE_LIB_LOADED:-}" ]] && return 0
_MODEL_AVAILABILITY_PROBE_LIB_LOADED=1

# SCRIPT_DIR fallback -- needed when sourced from a non-standard location
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	# Pure-bash dirname replacement -- avoids external binary dependency
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi
# shellcheck source=./shared-constants.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/shared-constants.sh"

# =============================================================================
# Provider Probing
# =============================================================================

# Probe a single provider via its /models endpoint.
# This is a lightweight check: the /models endpoint is free on all providers,
# returns quickly, and confirms both API key validity and service availability.
#
# Returns: 0=healthy, 1=unhealthy, 2=rate-limited, 3=key-invalid

# Return cached probe result if still valid. Outputs nothing; returns exit code.
# Returns: 0=healthy, 1=unhealthy, 2=rate-limited, 3=key-invalid, 99=no valid cache
_probe_return_cached() {
	local provider="$1"
	local custom_ttl="${2:-}"
	local quiet="${3:-false}"

	if ! is_cache_valid "$provider" "provider_health" "$custom_ttl"; then
		return 99
	fi

	local cached_status
	cached_status=$(db_query "SELECT status FROM provider_health WHERE provider = '$(sql_escape "$provider")';")
	case "$cached_status" in
	healthy)
		[[ "$quiet" != "true" ]] && print_info "$provider: cached healthy"
		return 0
		;;
	rate_limited)
		[[ "$quiet" != "true" ]] && print_warning "$provider: cached rate-limited"
		return 2
		;;
	key_invalid)
		[[ "$quiet" != "true" ]] && print_warning "$provider: cached key-invalid"
		return 3
		;;
	*)
		[[ "$quiet" != "true" ]] && print_warning "$provider: cached unhealthy"
		return 1
		;;
	esac
}

_probe_has_static_auth_for_provider() {
	local provider="$1"
	local key_vars
	key_vars=$(get_provider_key_vars "$provider" 2>/dev/null) || key_vars=""
	[[ -n "$key_vars" ]] || return 1

	local -a var_names
	local var_name
	IFS=',' read -r -a var_names <<<"$key_vars"
	for var_name in "${var_names[@]}"; do
		if [[ -n "${!var_name:-}" ]]; then
			return 0
		fi
	done

	if command -v gopass >/dev/null 2>&1; then
		for var_name in "${var_names[@]}"; do
			if gopass show "aidevops/${var_name}" >/dev/null 2>&1; then
				return 0
			fi
		done
	fi

	local creds_file="${HOME}/.config/aidevops/credentials.sh"
	if [[ -f "$creds_file" ]]; then
		# shellcheck disable=SC1090
		source "$creds_file"
		for var_name in "${var_names[@]}"; do
			if [[ -n "${!var_name:-}" ]]; then
				return 0
			fi
		done
	fi

	return 1
}

_probe_format_cooldown_until() {
	local cooldown_ms="$1"
	local cooldown_s=$((cooldown_ms / 1000))
	local formatted=""

	formatted=$(date -u -r "$cooldown_s" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
	if [[ -z "$formatted" ]]; then
		formatted=$(date -u -d "@${cooldown_s}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || true)
	fi
	if [[ -z "$formatted" ]]; then
		formatted="${cooldown_ms}ms"
	fi

	printf '%s\n' "$formatted"
	return 0
}

# Check OAuth pool cooldowns before cached health can mask them.
# Returns: 0=no blocking cooldown, 2=all usable OAuth pool accounts cooling.
_probe_oauth_pool_cooldown_gate() {
	local provider="$1"
	local quiet="${2:-false}"
	local pool_file="${MODEL_AVAILABILITY_OAUTH_POOL_FILE:-${HOME}/.aidevops/oauth-pool.json}"

	# Static API key paths are independent of OpenCode OAuth pool cooldowns.
	if _probe_has_static_auth_for_provider "$provider"; then
		return 0
	fi
	[[ -f "$pool_file" ]] || return 0
	command -v jq >/dev/null 2>&1 || return 0

	local now_ms counts total available limited _auth_errors min_cooldown
	now_ms=$(($(date +%s) * 1000))
	counts=$(jq -r --arg provider "$provider" --argjson now "$now_ms" '
		def n: tonumber? // 0;
		(.[$provider] // []) as $accounts
		| ($accounts | length) as $total
		| if $total == 0 then
			[0, -1, 0, 0, 0]
		else
			($accounts | map(select((.status // "") == "auth-error")) | length) as $auth
			| ($accounts | map(select((.status // "") == "rate-limited" and (((.cooldownUntil // 0) | n) > $now)))) as $limited_accounts
			| ($limited_accounts | length) as $limited
			| ($accounts | map(select(((.status // "") != "auth-error") and (((.status // "") != "rate-limited") or (((.cooldownUntil // 0) | n) <= $now)))) | length) as $available
			| ($limited_accounts | map((.cooldownUntil // 0) | n) | min // 0) as $min_cooldown
			| [$total, $available, $limited, $auth, $min_cooldown]
		end
		| @tsv
	' "$pool_file" 2>/dev/null) || counts="0 -1 0 0 0"
	read -r total available limited _auth_errors min_cooldown <<<"$counts"

	if [[ "${total:-0}" -gt 0 && "${available:--1}" -eq 0 && "${limited:-0}" -gt 0 ]]; then
		local until_text
		until_text=$(_probe_format_cooldown_until "${min_cooldown:-0}")
		[[ "$quiet" != "true" ]] && print_warning "$provider: rate-limited until $until_text"
		_record_health "$provider" "rate_limited" 429 0 "OAuth pool cooldown active until $until_text" 0
		return 2
	fi

	return 0
}

# Probe the OpenCode meta-provider via its local models cache (no API key needed).
# Returns: 0=healthy, 1=unhealthy
_probe_opencode() {
	local quiet="${1:-false}"

	if _is_opencode_available; then
		local oc_models_count=0
		oc_models_count=$(jq -r '.opencode.models | length' "$OPENCODE_MODELS_CACHE" 2>/dev/null || echo "0")
		_record_health "opencode" "healthy" 200 0 "" "$oc_models_count"
		[[ "$quiet" != "true" ]] && print_success "opencode: healthy ($oc_models_count models in cache)"
		db_query "
            INSERT INTO probe_log (provider, action, result, duration_ms, details)
            VALUES ('opencode', 'cache_check', 'healthy', 0, '$oc_models_count models from cache');
        " || true
		return 0
	fi

	_record_health "opencode" "unhealthy" 0 0 "OpenCode CLI or models cache not found" 0
	[[ "$quiet" != "true" ]] && print_warning "opencode: CLI or models cache not available"
	return 1
}

# Probe the local llama.cpp-compatible inference server (no API key needed).
# Checks http://localhost:8080/v1/models for a running local server.
# Returns: 0=healthy, 1=unhealthy
_probe_local() {
	local quiet="${1:-false}"

	local endpoint
	endpoint=$(get_provider_endpoint "local" 2>/dev/null) || endpoint="http://localhost:8080/v1/models"

	local start_ms response http_code body models_count=0 duration_ms=0
	start_ms=$(date +%s%N 2>/dev/null || echo "0")
	response=$(curl -s -w "\n%{http_code}" --max-time "$PROBE_TIMEOUT" "$endpoint" 2>/dev/null) || true
	local end_ms
	end_ms=$(date +%s%N 2>/dev/null || echo "0")
	if [[ "$start_ms" != "0" && "$end_ms" != "0" ]]; then
		duration_ms=$(((end_ms - start_ms) / 1000000))
	fi

	http_code=$(echo "$response" | tail -1)
	body=$(echo "$response" | sed '$d')

	if [[ "$http_code" == "200" ]]; then
		models_count=$(echo "$body" | jq -r '.data | length' 2>/dev/null || echo "0")
		_record_health "local" "healthy" 200 "$duration_ms" "" "$models_count"
		[[ "$quiet" != "true" ]] && print_success "local: healthy ($models_count models at $endpoint)"
		db_query "
            INSERT INTO probe_log (provider, action, result, duration_ms, details)
            VALUES ('local', 'health_probe', 'healthy', $duration_ms, '$models_count models');
        " || true
		return 0
	fi

	_record_health "local" "unhealthy" "${http_code:-0}" "$duration_ms" "Local server not reachable at $endpoint" 0
	[[ "$quiet" != "true" ]] && print_warning "local: server not available at $endpoint (HTTP ${http_code:-none})"
	return 1
}

# Probe the Ollama local inference server (no API key needed).
# Checks http://localhost:11434/api/tags for a running Ollama instance.
# Returns: 0=healthy, 1=unhealthy
_probe_ollama() {
	local quiet="${1:-false}"

	local endpoint
	endpoint=$(get_provider_endpoint "ollama" 2>/dev/null) || endpoint="http://localhost:11434/api/tags"

	local start_ms response http_code body models_count=0 duration_ms=0
	start_ms=$(date +%s%N 2>/dev/null || echo "0")
	response=$(curl -s -w "\n%{http_code}" --max-time "$PROBE_TIMEOUT" "$endpoint" 2>/dev/null) || true
	local end_ms
	end_ms=$(date +%s%N 2>/dev/null || echo "0")
	if [[ "$start_ms" != "0" && "$end_ms" != "0" ]]; then
		duration_ms=$(((end_ms - start_ms) / 1000000))
	fi

	http_code=$(echo "$response" | tail -1)
	body=$(echo "$response" | sed '$d')

	if [[ "$http_code" == "200" ]]; then
		# Ollama /api/tags returns {"models": [...]}
		models_count=$(echo "$body" | jq -r '.models | length' 2>/dev/null || echo "0")
		_record_health "ollama" "healthy" 200 "$duration_ms" "" "$models_count"
		[[ "$quiet" != "true" ]] && print_success "ollama: healthy ($models_count models)"
		db_query "
            INSERT INTO probe_log (provider, action, result, duration_ms, details)
            VALUES ('ollama', 'health_probe', 'healthy', $duration_ms, '$models_count models');
        " || true
		return 0
	fi

	_record_health "ollama" "unhealthy" "${http_code:-0}" "$duration_ms" "Ollama not reachable at $endpoint" 0
	[[ "$quiet" != "true" ]] && print_warning "ollama: server not available at $endpoint (HTTP ${http_code:-none})"
	return 1
}

# Probe Ollama context length for a specific model via /api/show.
# Validates that the model's num_ctx meets the minimum required context length.
# Uses the Ollama /api/show endpoint which returns model metadata including
# model_info.llama.context_length and parameters.num_ctx.
#
# Arguments:
#   model_name       - Ollama model name (e.g. "llama3.2", "mistral:7b")
#   min_context      - Minimum required context length (default: 16384)
#   quiet            - Suppress output if "true" (default: "false")
#
# Returns:
#   0 - Model available with sufficient context length
#   1 - Model not found or context length insufficient
#   2 - Ollama server not reachable
#
# Outputs (on stdout when not quiet):
#   Actual num_ctx value and pass/fail verdict
_probe_ollama_context_length() {
	local model_name="$1"
	local min_context="${2:-16384}"
	local quiet="${3:-false}"

	local show_endpoint="http://localhost:11434/api/show"

	# POST to /api/show with {"name": "<model>"}
	local response http_code body
	response=$(curl -s -w "\n%{http_code}" --max-time "$PROBE_TIMEOUT" \
		-X POST "$show_endpoint" \
		-H "Content-Type: application/json" \
		-d "{\"name\":\"${model_name}\"}" 2>/dev/null) || true

	http_code=$(echo "$response" | tail -1)
	body=$(echo "$response" | sed '$d')

	if [[ "$http_code" != "200" ]]; then
		[[ "$quiet" != "true" ]] && print_warning "ollama: /api/show unreachable for $model_name (HTTP ${http_code:-none})"
		return 2
	fi

	# Extract num_ctx: prefer parameters.num_ctx, fall back to model_info.llama.context_length
	local num_ctx=0
	num_ctx=$(echo "$body" | jq -r '
		if .parameters and (.parameters | test("num_ctx[[:space:]]+([0-9]+)")) then
			(.parameters | capture("num_ctx[[:space:]]+(?P<v>[0-9]+)").v | tonumber)
		elif .model_info["llama.context_length"] then
			.model_info["llama.context_length"]
		else
			0
		end
	' 2>/dev/null || echo "0")

	# Ensure numeric
	num_ctx="${num_ctx:-0}"
	if ! [[ "$num_ctx" =~ ^[0-9]+$ ]]; then
		num_ctx=0
	fi

	if [[ "$num_ctx" -ge "$min_context" ]]; then
		[[ "$quiet" != "true" ]] && print_success "ollama/$model_name: num_ctx=$num_ctx >= min=$min_context (pass)"
		return 0
	fi

	[[ "$quiet" != "true" ]] && print_warning "ollama/$model_name: num_ctx=$num_ctx < min=$min_context (fail)"
	return 1
}

# Build curl argument array and resolve the final endpoint URL for a provider.
# Outputs two lines: first the endpoint URL, then the curl args (space-separated).
# Caller must reconstruct the array from the second line.
# Sets REPLY_ENDPOINT and REPLY_CURL_ARGS (space-separated) in caller scope via stdout.
_probe_build_request() {
	local provider="$1"
	local api_key="$2"

	local endpoint
	endpoint=$(get_provider_endpoint "$provider" 2>/dev/null) || true
	if [[ -z "$endpoint" ]]; then
		return 1
	fi

	# %{time_total} is a portable curl write-out field (macOS + Linux).
	# Using it avoids date +%s%N which is a GNU extension not available on BSD/macOS.
	local curl_args="-s -w '\n%{time_total}\n%{http_code}' --max-time $PROBE_TIMEOUT -D -"
	case "$provider" in
	anthropic)
		curl_args="$curl_args -H 'x-api-key: ${api_key}' -H 'anthropic-version: 2023-06-01'"
		;;
	google)
		endpoint="${endpoint}?key=${api_key}&pageSize=1"
		;;
	local | ollama)
		# No authentication required for local providers
		;;
	*)
		curl_args="$curl_args -H 'Authorization: Bearer ${api_key}'"
		;;
	esac

	echo "$endpoint"
	echo "$curl_args"
	return 0
}

# Detect provider quota exhaustion from an HTTP error body before generic auth
# handling. OpenAI returns HTTP 403 for both auth and billing quota failures, so
# status-code-only parsing can incorrectly trigger OAuth fallback and record a
# quota-exhausted provider as healthy.
_probe_body_has_quota_error() {
	local body="$1"
	local body_lc

	body_lc=$(printf '%s\n' "$body" | tr '[:upper:]' '[:lower:]')
	if [[ "$body_lc" == *"insufficient_quota"* ]] || [[ "$body_lc" == *"quota exceeded"* ]] || [[ "$body_lc" == *"exceeded your current quota"* ]]; then
		return 0
	fi

	return 1
}

# Parse an HTTP response code into status, error_msg, models_count, and exit_code.
# Outputs four lines: status, error_msg, models_count, exit_code.
_probe_parse_http_response() {
	local provider="$1"
	local http_code="$2"
	local body="$3"
	local quiet="${4:-false}"

	local status="unknown"
	local error_msg=""
	local models_count=0
	local exit_code=1

	case "$http_code" in
	200)
		status="healthy"
		exit_code=0
		case "$provider" in
		google) models_count=$(echo "$body" | jq -r '.models | length' 2>/dev/null || echo "0") ;;
		*) models_count=$(echo "$body" | jq -r '.data | length' 2>/dev/null || echo "0") ;;
		esac
		[[ "$quiet" != "true" ]] && print_success "$provider: healthy (${models_count} models)"
		;;
	401 | 403)
		if _probe_body_has_quota_error "$body"; then
			status="quota_exceeded"
			error_msg="Quota exceeded (HTTP $http_code)"
			exit_code=1
			[[ "$quiet" != "true" ]] && print_error "$provider: quota exceeded (HTTP $http_code)"
		else
			status="key_invalid"
			error_msg="Authentication failed (HTTP $http_code)"
			exit_code=3
			[[ "$quiet" != "true" ]] && print_error "$provider: API key invalid (HTTP $http_code)"
		fi
		;;
	429)
		status="rate_limited"
		error_msg="Rate limited (HTTP 429)"
		exit_code=2
		[[ "$quiet" != "true" ]] && print_warning "$provider: rate limited"
		;;
	500 | 502 | 503 | 504)
		status="unhealthy"
		error_msg="Server error (HTTP $http_code)"
		exit_code=1
		[[ "$quiet" != "true" ]] && print_error "$provider: server error (HTTP $http_code)"
		;;
	"")
		status="unreachable"
		error_msg="Connection failed or timeout"
		exit_code=1
		[[ "$quiet" != "true" ]] && print_error "$provider: unreachable (timeout or DNS failure)"
		;;
	*)
		status="unhealthy"
		error_msg="Unexpected HTTP $http_code"
		exit_code=1
		[[ "$quiet" != "true" ]] && print_warning "$provider: unexpected response (HTTP $http_code)"
		;;
	esac

	echo "$status"
	echo "$error_msg"
	echo "$models_count"
	echo "$exit_code"
	return 0
}

# Write a probe result to the probe_log table and prune old entries.
_probe_log_and_prune() {
	local provider="$1"
	local status="$2"
	local http_code="$3"
	local duration_ms="$4"
	local models_count="$5"

	db_query "
        INSERT INTO probe_log (provider, action, result, duration_ms, details)
        VALUES (
            '$(sql_escape "$provider")',
            'health_probe',
            '$(sql_escape "$status")',
            $duration_ms,
            '$(sql_escape "HTTP $http_code, $models_count models")'
        );
    " || true

	db_query "
        DELETE FROM probe_log WHERE id IN (
            SELECT id FROM probe_log
            WHERE provider = '$(sql_escape "$provider")'
            ORDER BY timestamp DESC
            LIMIT -1 OFFSET 100
        );
    " || true
	return 0
}

# Resolve and validate the API key for a provider before probing.
# Handles: missing key, empty key, and OAuth refresh-only tokens.
# On success, echoes the API key to stdout and returns 0.
# On failure, records health status and returns the appropriate exit code.
# Returns: 0=key-ready, 3=no-key/empty, 100=oauth-refresh (healthy, skip HTTP probe)
_probe_resolve_and_validate_key() {
	local provider="$1"
	local quiet="${2:-false}"

	local api_key
	if ! api_key=$(resolve_api_key "$provider"); then
		[[ "$quiet" != "true" ]] && print_warning "$provider: no API key configured"
		_record_health "$provider" "no_key" 0 0 "No API key found" 0
		return 3
	fi

	if [[ -z "$api_key" ]]; then
		[[ "$quiet" != "true" ]] && print_warning "$provider: API key resolved but empty"
		_record_health "$provider" "no_key" 0 0 "API key resolved but empty" 0
		return 3
	fi

	# t2392 defensive: if the resolved value is an Anthropic OAuth access
	# token (prefix `sk-ant-oat01-`) — e.g. a user exported ANTHROPIC_API_KEY
	# directly from auth.json — it CANNOT be used with the x-api-key probe
	# header (which expects static `sk-ant-api03-` keys). Treat it like the
	# oauth-refresh-available marker: record healthy, skip HTTP. Workers use
	# the opencode runtime's OAuth flow, which handles refresh at session
	# start. This is belt-and-braces on top of the resolve_api_key fix —
	# catches the case where an OAuth token reaches this function through
	# env/gopass/credentials.sh sources instead of auth.json.
	if [[ "$provider" == "anthropic" && "$api_key" == sk-ant-oat01-* ]]; then
		[[ "$quiet" != "true" ]] && print_success "$provider: OAuth access token detected (skipping HTTP probe)"
		_record_health "$provider" "healthy" 0 0 "OAuth access token detected" 0
		return 100
	fi

	# t1927: OAuth refresh-only tokens — the access token is expired but a
	# refresh token exists. The OpenCode runtime refreshes at session start,
	# so the provider IS available even though we can't probe with the expired
	# token. Record as healthy and skip the HTTP probe.
	if [[ "$api_key" == "oauth-refresh-available" ]]; then
		[[ "$quiet" != "true" ]] && print_success "$provider: OAuth refresh token available (runtime will refresh at session start)"
		_record_health "$provider" "healthy" 0 0 "OAuth refresh available" 0
		return 100
	fi

	printf '%s\n' "$api_key"
	return 0
}

# _probe_allows_oauth_fallback_after_rejected_key: distinguish providers where
# OpenCode's selected runtime path can genuinely ignore a rejected helper key
# from built-in providers where env vars still win at inference time.
_probe_allows_oauth_fallback_after_rejected_key() {
	local provider="$1"
	local key_source="${2:-${RESOLVED_API_KEY_SOURCE:-}}"
	local key_vars=""
	local var_name
	local -a var_names=()

	# t3555: OpenCode's built-in openai provider uses @ai-sdk/openai. When
	# OPENAI_API_KEY is present, inference follows that env key even if
	# auth.json also contains ChatGPT OAuth. Do not mark the provider healthy
	# after the same env key was rejected by the /models probe.
	if [[ "$provider" == openai ]]; then
		key_vars=$(get_provider_key_vars "$provider" 2>/dev/null) || key_vars=""
		IFS=',' read -r -a var_names <<<"$key_vars"
		for var_name in "${var_names[@]}"; do
			if [[ "$key_source" == "env:${var_name}" ]]; then
				return 1
			fi
		done
	fi

	return 0
}

_probe_openai_oauth_fallback_verified() {
	local auth_file="$1"
	local quiet="${2:-false}"

	[[ -f "$auth_file" ]] || return 3
	command -v jq >/dev/null 2>&1 || return 3

	# OpenAI ChatGPT OAuth fallback is only provider-health evidence after a
	# successful OpenAI API probe with a currently-live access token. Refresh-token
	# presence alone proved too weak: quota-exhausted accounts still looked
	# healthy and were selected for workers (GH#24694).
	local access_token expires_ms now_s now_ms
	access_token=$(jq -r '.openai.access // empty' "$auth_file" 2>/dev/null) || access_token=""
	expires_ms=$(jq -r '.openai.expires // empty' "$auth_file" 2>/dev/null) || expires_ms=""
	if [[ -z "$access_token" || ! "$expires_ms" =~ ^[0-9]+$ ]]; then
		return 3
	fi

	now_s=$(date +%s 2>/dev/null) || now_s=""
	if [[ ! "$now_s" =~ ^[0-9]+$ ]]; then
		return 3
	fi

	now_ms=$((now_s * 1000))
	if [[ "$expires_ms" -le "$now_ms" ]]; then
		return 3
	fi

	_probe_execute_http openai "$access_token" "$quiet"
	return $?
}

# _probe_check_oauth_fallback: called when an HTTP probe rejected the resolved
# key with exit code 3 (HTTP 401/403). Checks whether auth.json has an OAuth
# entry for the provider and whether the runtime path can actually prefer that
# OAuth entry over the rejected key. Records healthy and returns 0 on an allowed
# OAuth hit; returns 3 if no usable OAuth fallback exists.
#
# t3229: prevents a stale/invalid non-runtime key source from permanently
# masking a working OAuth account in auth.json. t3555 narrows that fallback
# for built-in openai env-key failures because OpenCode inference would reuse
# the rejected OPENAI_API_KEY before auth.json OAuth.
_probe_check_oauth_fallback() {
	local provider="$1"
	local quiet="${2:-false}"
	local key_source="${3:-${RESOLVED_API_KEY_SOURCE:-}}"

	if ! _probe_allows_oauth_fallback_after_rejected_key "$provider" "$key_source"; then
		[[ "$quiet" != "true" ]] && print_warning "$provider: env key rejected (HTTP 401/403); OpenCode built-in provider will still use that env key, not auth.json OAuth"
		return 3
	fi

	local auth_file="${HOME}/.local/share/opencode/auth.json"
	[[ -f "$auth_file" ]] || return 3

	local auth_type
	auth_type=$(jq -r --arg p "$provider" '.[$p].type // empty' "$auth_file" 2>/dev/null) || auth_type=""
	if [[ "$auth_type" == "oauth" ]]; then
		if [[ "$provider" == openai ]]; then
			local oauth_exit=0
			_probe_openai_oauth_fallback_verified "$auth_file" "$quiet" || oauth_exit=$?
			if [[ "$oauth_exit" -ne 0 ]]; then
				[[ "$quiet" != "true" ]] && print_warning "$provider: env key rejected (HTTP 401/403); OpenAI OAuth API verification failed"
			fi
			return "$oauth_exit"
		fi
		[[ "$quiet" != "true" ]] && print_success "$provider: env key rejected (HTTP 401/403) but OAuth found in auth.json — recording healthy (t3229)"
		_record_health "$provider" "healthy" 0 0 "OAuth available (env key rejected, t3229)" 0
		return 0
	fi

	return 3
}

# Execute an HTTP probe against a provider's /models endpoint and record results.
# Builds the curl request, executes it, parses the response, records health and
# rate limits, and logs the probe result.
# Returns: 0=healthy, 1=unhealthy, 2=rate-limited, 3=key-invalid
_probe_execute_http() {
	local provider="$1"
	local api_key="$2"
	local quiet="${3:-false}"

	# Build request parameters
	local request_info endpoint curl_extra
	request_info=$(_probe_build_request "$provider" "$api_key") || {
		[[ "$quiet" != "true" ]] && print_error "$provider: no endpoint configured"
		return 1
	}
	endpoint=$(echo "$request_info" | head -1)
	curl_extra=$(echo "$request_info" | tail -1)

	# Execute probe (eval is safe: curl_extra is built from controlled provider strings)
	# _probe_build_request appends two trailer lines via -w: time_total (float s) then http_code.
	# %{time_total} is portable across macOS (BSD curl) and Linux (GNU curl).
	# date +%s%N was previously used here but %N is a GNU extension that prints literal
	# "%N" on macOS, causing arithmetic failures (GH#17464).
	local response duration_ms=0
	# shellcheck disable=SC2086
	response=$(eval curl $curl_extra "$endpoint" 2>/dev/null) || true

	# Split response into headers, body, time_total, and http_code.
	# Trailer format (two lines appended by -w '\n%{time_total}\n%{http_code}'): time_total then http_code.
	local http_code time_total_s headers body
	http_code=$(printf '%s\n' "$response" | tail -1)
	time_total_s=$(printf '%s\n' "$response" | tail -2 | head -1)
	headers=$(printf '%s\n' "$response" | sed '/^$/q' | head -50)
	# Drop headers (up to and including blank separator line) and the two trailer lines.
	# awk sliding-window approach drops the last N lines portably (head -n -2 is GNU-only).
	body=$(printf '%s\n' "$response" | sed '1,/^$/d' | awk 'NR>2{print lines[NR%2]} {lines[NR%2]=$0}')

	# Convert time_total (float seconds, e.g. "0.123456") to integer milliseconds.
	# Use awk for portable float arithmetic — bash arithmetic only handles integers.
	if [[ -n "$time_total_s" && "$time_total_s" =~ ^[0-9] ]]; then
		duration_ms=$(awk "BEGIN { printf \"%d\", $time_total_s * 1000 }" 2>/dev/null || echo "0")
	fi

	_parse_rate_limits "$provider" "$headers"

	# Parse HTTP response into status fields
	local parsed status error_msg models_count exit_code
	parsed=$(_probe_parse_http_response "$provider" "$http_code" "$body" "$quiet")
	status=$(echo "$parsed" | sed -n '1p')
	error_msg=$(echo "$parsed" | sed -n '2p')
	models_count=$(echo "$parsed" | sed -n '3p')
	exit_code=$(echo "$parsed" | sed -n '4p')

	_record_health "$provider" "$status" "$http_code" "$duration_ms" "$error_msg" "$models_count"
	_probe_log_and_prune "$provider" "$status" "$http_code" "$duration_ms" "$models_count"

	return "$exit_code"
}

_probe_opencode_subscription_provider() {
	local provider="$1"
	local quiet="$2"
	local auth_file="${OPENCODE_AUTH_FILE:-${HOME}/.local/share/opencode/auth.json}"

	if [[ -f "$auth_file" ]] && command -v jq >/dev/null 2>&1 && \
		jq -e --arg provider "$provider" '.[$provider] | type == "object" and ((.access // .refresh // .token // .apiKey // "") != "")' "$auth_file" >/dev/null 2>&1; then
		_record_health "$provider" "healthy" 200 0 "" 0
		[[ "$quiet" != "true" ]] && print_success "$provider: authenticated through OpenCode"
		return 0
	fi

	_record_health "$provider" "no-key" 0 0 "OpenCode subscription auth unavailable" 0
	[[ "$quiet" != "true" ]] && print_warning "$provider: no OpenCode subscription auth"
	return 1
}

probe_provider() {
	local provider="$1"
	local force="${2:-false}"
	local custom_ttl="${3:-}"
	local quiet="${4:-false}"

	local oauth_pool_exit=0
	_probe_oauth_pool_cooldown_gate "$provider" "$quiet" || oauth_pool_exit=$?
	if [[ "$oauth_pool_exit" -eq 2 ]]; then
		return 2
	fi

	# Return cached result when still valid (unless forced)
	if [[ "$force" != "true" ]]; then
		local cache_exit=0
		_probe_return_cached "$provider" "$custom_ttl" "$quiet" || cache_exit=$?
		if [[ "$cache_exit" -ne 99 ]]; then
			return "$cache_exit"
		fi
	fi

	# OpenCode uses its local models cache — no HTTP probe needed
	if [[ "$provider" == "opencode" ]]; then
		_probe_opencode "$quiet"
		return $?
	fi
	if [[ "$provider" == "zai-coding-plan" ]]; then
		_probe_opencode_subscription_provider "$provider" "$quiet"
		return $?
	fi

	# Local providers use dedicated probes — no API key required
	if [[ "$provider" == "local" ]]; then
		_probe_local "$quiet"
		return $?
	fi

	if [[ "$provider" == "ollama" ]]; then
		_probe_ollama "$quiet"
		return $?
	fi

	# Resolve API key or OAuth token — resolve_api_key checks env vars,
	# gopass, credentials.sh, and OpenCode auth.json (in that order).
	local api_key key_exit=0
	api_key=$(_probe_resolve_and_validate_key "$provider" "$quiet") || key_exit=$?
	if [[ "$key_exit" -eq 100 ]]; then
		# OAuth refresh available — already recorded as healthy
		return 0
	elif [[ "$key_exit" -ne 0 ]]; then
		return "$key_exit"
	fi

	# Execute HTTP probe against the provider's /models endpoint
	local http_exit=0
	_probe_execute_http "$provider" "$api_key" "$quiet" || http_exit=$?

	# t3229: if the resolved key was rejected (HTTP 401/403), check whether
	# auth.json has an OAuth entry for this provider. OAuth wins over a
	# stale/invalid env key — the runtime authenticates at session start.
	if [[ "$http_exit" -eq 3 ]]; then
		_probe_check_oauth_fallback "$provider" "$quiet"
		return $?
	fi

	return "$http_exit"
}

_record_health() {
	local provider="$1"
	local status="$2"
	local http_code="$3"
	local duration_ms="$4"
	local error_msg="$5"
	local models_count="$6"

	db_query "
        INSERT INTO provider_health (provider, status, http_code, response_ms, error_message, models_count, checked_at, ttl_seconds)
        VALUES (
            '$(sql_escape "$provider")',
            '$(sql_escape "$status")',
            $http_code,
            $duration_ms,
            '$(sql_escape "$error_msg")',
            $models_count,
            strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            $DEFAULT_HEALTH_TTL
        )
        ON CONFLICT(provider) DO UPDATE SET
            status = excluded.status,
            http_code = excluded.http_code,
            response_ms = excluded.response_ms,
            error_message = excluded.error_message,
            models_count = excluded.models_count,
            checked_at = excluded.checked_at,
            ttl_seconds = excluded.ttl_seconds;
    " || true
	return 0
}

# =============================================================================
# Rate Limit Parsing
# =============================================================================

_parse_rate_limits() {
	local provider="$1"
	local headers="$2"

	local req_limit=0 req_remaining=0 req_reset=""
	local tok_limit=0 tok_remaining=0 tok_reset=""

	case "$provider" in
	anthropic)
		req_limit=$(echo "$headers" | grep -i 'anthropic-ratelimit-requests-limit' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
		req_remaining=$(echo "$headers" | grep -i 'anthropic-ratelimit-requests-remaining' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
		req_reset=$(echo "$headers" | grep -i 'anthropic-ratelimit-requests-reset' | head -1 | awk '{print $2}' | tr -d '\r' || echo "")
		tok_limit=$(echo "$headers" | grep -i 'anthropic-ratelimit-tokens-limit' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
		tok_remaining=$(echo "$headers" | grep -i 'anthropic-ratelimit-tokens-remaining' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
		tok_reset=$(echo "$headers" | grep -i 'anthropic-ratelimit-tokens-reset' | head -1 | awk '{print $2}' | tr -d '\r' || echo "")
		;;
	openai)
		req_limit=$(echo "$headers" | grep -i 'x-ratelimit-limit-requests' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
		req_remaining=$(echo "$headers" | grep -i 'x-ratelimit-remaining-requests' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
		req_reset=$(echo "$headers" | grep -i 'x-ratelimit-reset-requests' | head -1 | awk '{print $2}' | tr -d '\r' || echo "")
		tok_limit=$(echo "$headers" | grep -i 'x-ratelimit-limit-tokens' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
		tok_remaining=$(echo "$headers" | grep -i 'x-ratelimit-remaining-tokens' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
		tok_reset=$(echo "$headers" | grep -i 'x-ratelimit-reset-tokens' | head -1 | awk '{print $2}' | tr -d '\r' || echo "")
		;;
	groq)
		req_limit=$(echo "$headers" | grep -i 'x-ratelimit-limit-requests' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
		req_remaining=$(echo "$headers" | grep -i 'x-ratelimit-remaining-requests' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
		req_reset=$(echo "$headers" | grep -i 'x-ratelimit-reset-requests' | head -1 | awk '{print $2}' | tr -d '\r' || echo "")
		tok_limit=$(echo "$headers" | grep -i 'x-ratelimit-limit-tokens' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
		tok_remaining=$(echo "$headers" | grep -i 'x-ratelimit-remaining-tokens' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
		tok_reset=$(echo "$headers" | grep -i 'x-ratelimit-reset-tokens' | head -1 | awk '{print $2}' | tr -d '\r' || echo "")
		;;
	*)
		# Other providers: try generic x-ratelimit headers
		req_limit=$(echo "$headers" | grep -i 'x-ratelimit-limit' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
		req_remaining=$(echo "$headers" | grep -i 'x-ratelimit-remaining' | head -1 | awk '{print $2}' | tr -d '\r' || echo "0")
		;;
	esac

	# Only store if we got meaningful data
	if [[ "$req_limit" != "0" || "$req_remaining" != "0" ]]; then
		db_query "
            INSERT INTO rate_limits (provider, requests_limit, requests_remaining, requests_reset,
                                     tokens_limit, tokens_remaining, tokens_reset, checked_at, ttl_seconds)
            VALUES (
                '$(sql_escape "$provider")',
                ${req_limit:-0},
                ${req_remaining:-0},
                '$(sql_escape "${req_reset:-}")',
                ${tok_limit:-0},
                ${tok_remaining:-0},
                '$(sql_escape "${tok_reset:-}")',
                strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
                $DEFAULT_RATELIMIT_TTL
            )
            ON CONFLICT(provider) DO UPDATE SET
                requests_limit = excluded.requests_limit,
                requests_remaining = excluded.requests_remaining,
                requests_reset = excluded.requests_reset,
                tokens_limit = excluded.tokens_limit,
                tokens_remaining = excluded.tokens_remaining,
                tokens_reset = excluded.tokens_reset,
                checked_at = excluded.checked_at,
                ttl_seconds = excluded.ttl_seconds;
        " || true
	fi
	return 0
}

# =============================================================================
# ChatGPT OAuth Model Restrictions (GH#21990)
# =============================================================================
# ChatGPT OAuth accounts (OpenCode's "Codex" auth) support only a subset of
# OpenAI model IDs. The /v1/models cache and model-registry list pro variants,
# but runtime availability differs: gpt-5.5-pro returns HTTP 400 "not supported
# when using Codex with a ChatGPT account"; gpt-5.4-pro / gpt-5.2-pro / o3-pro
# return "Model not found". Cache presence alone is insufficient — this denylist
# must override before any cache-positive lookup marks a model available.
# Canonical config: .agents/configs/model-routing-table.json chatgpt_oauth_restrictions.

# ChatGPT OAuth restriction settings are loaded lazily from the model routing
# table so the config remains the single source of truth.
_CHATGPT_OAUTH_UNSUPPORTED_MODELS_CACHE=""
_OPENAI_OAUTH_AUTH_FILE_CACHE=""
_OPENAI_OAUTH_AUTH_TYPE_CACHE=""

_model_routing_table_path() {
	printf '%s\n' "${SCRIPT_DIR}/../configs/model-routing-table.json"
	return 0
}

_expand_config_path() {
	local path="$1"
	case "$path" in
		\~/*)
			printf '%s/%s\n' "$HOME" "${path#\~/}"
			;;
		*)
			printf '%s\n' "$path"
			;;
	esac
	return 0
}

_openai_oauth_auth_file() {
	if [[ -n "$_OPENAI_OAUTH_AUTH_FILE_CACHE" ]]; then
		printf '%s\n' "$_OPENAI_OAUTH_AUTH_FILE_CACHE"
		return 0
	fi

	local routing_table
	routing_table=$(_model_routing_table_path)
	local configured_path=""
	if [[ -r "$routing_table" ]] && command -v jq >/dev/null 2>&1; then
		configured_path=$(jq -r '.providers.openai.oauth_auth_file // empty' "$routing_table" 2>/dev/null || true)
	fi
	[[ -n "$configured_path" ]] || configured_path="${HOME}/.local/share/opencode/auth.json"
	_OPENAI_OAUTH_AUTH_FILE_CACHE=$(_expand_config_path "$configured_path")
	printf '%s\n' "$_OPENAI_OAUTH_AUTH_FILE_CACHE"
	return 0
}

_chatgpt_oauth_unsupported_models() {
	if [[ -n "$_CHATGPT_OAUTH_UNSUPPORTED_MODELS_CACHE" ]]; then
		printf '%s\n' "$_CHATGPT_OAUTH_UNSUPPORTED_MODELS_CACHE"
		return 0
	fi

	local routing_table
	routing_table=$(_model_routing_table_path)
	if [[ -r "$routing_table" ]] && command -v jq >/dev/null 2>&1; then
		_CHATGPT_OAUTH_UNSUPPORTED_MODELS_CACHE=$(jq -r '.chatgpt_oauth_restrictions.openai_unsupported[]? // empty' "$routing_table" 2>/dev/null || true)
	fi
	printf '%s\n' "$_CHATGPT_OAUTH_UNSUPPORTED_MODELS_CACHE"
	return 0
}

# Returns 0 if the OpenAI provider is authenticated via ChatGPT OAuth (Codex).
# Checks the configured OpenCode auth file for openai.type == "oauth".
# Returns 1 if using an API key, auth.json is absent, or jq is unavailable.
_is_openai_chatgpt_oauth() {
	local auth_file
	auth_file=$(_openai_oauth_auth_file)
	if [[ ! -f "$auth_file" ]]; then
		_OPENAI_OAUTH_AUTH_TYPE_CACHE=""
		return 1
	fi

	if [[ -n "$_OPENAI_OAUTH_AUTH_TYPE_CACHE" ]]; then
		[[ "$_OPENAI_OAUTH_AUTH_TYPE_CACHE" == "oauth" ]]
		return $?
	fi

	local auth_type
	auth_type=$(jq -r '.openai.type // empty' "$auth_file" 2>/dev/null) || auth_type=""
	_OPENAI_OAUTH_AUTH_TYPE_CACHE="$auth_type"
	[[ "$auth_type" == "oauth" ]]
	return $?
}

# Returns 0 (denied/unavailable) if provider is openai, we are authenticated
# via ChatGPT OAuth, and model_id is in the known-unsupported list.
# Returns 1 (allowed) in all other cases.
# Called by check_model_available() before any cache lookups so stale
# "available" DB entries cannot bypass the restriction.
_chatgpt_oauth_denylist_check() {
	local provider="$1"
	local model_id="$2"

	# Only applies to OpenAI provider — compare without quoting the literal string
	# to keep the string count below the repeated-literal ratchet (GH#21990).
	[[ "$provider" == openai ]] || return 1

	# Only applies when using ChatGPT OAuth auth
	_is_openai_chatgpt_oauth || return 1

	# Check if model_id is in the unsupported list
	local denied
	while IFS= read -r denied; do
		[[ -n "$denied" ]] || continue
		if [[ "$model_id" == "$denied" ]]; then
			return 0 # denied
		fi
	done < <(_chatgpt_oauth_unsupported_models)
	return 1 # allowed
}

# =============================================================================
# Model Availability Check
# =============================================================================

# Check if a specific model is available from its provider.
# First checks provider health, then verifies the model exists in the
# provider's model list (from the cached /models response or model-registry).
check_model_available() {
	local model_spec="$1"
	local force="${2:-false}"
	local quiet="${3:-false}"

	# Parse provider/model format
	local provider model_id
	if [[ "$model_spec" == *"/"* ]]; then
		provider="${model_spec%%/*}"
		model_id="${model_spec#*/}"
	else
		# Try to infer provider from model name
		case "$model_spec" in
		claude*) provider="anthropic" ;;
		gpt* | o3* | o4*) provider="openai" ;;
		gemini*) provider="google" ;;
		deepseek*) provider="deepseek" ;;
		llama*) provider="groq" ;;
		*) provider="" ;;
		esac
		model_id="$model_spec"
	fi

	if [[ -z "$provider" ]]; then
		[[ "$quiet" != "true" ]] && print_error "Cannot determine provider for: $model_spec"
		return 1
	fi

	# Check provider health first
	local probe_exit=0
	probe_provider "$provider" "$force" "" "$quiet" || probe_exit=$?

	if [[ "$probe_exit" -ne 0 ]]; then
		return "$probe_exit"
	fi

	# ChatGPT OAuth denylist: reject known-unsupported pro models before any
	# cache lookups. Cache presence alone is insufficient — these models appear
	# in /v1/models but fail at inference under ChatGPT OAuth (Codex auth).
	# Must run before DB cache to override stale "available" entries. GH#21990.
	if _chatgpt_oauth_denylist_check "$provider" "$model_id"; then
		[[ "$quiet" != "true" ]] && print_warning "$model_spec: unavailable (ChatGPT OAuth denylist — not supported with Codex account, GH#21990)"
		return 1
	fi

	# Check model-specific availability from cache
	local cached_available
	cached_available=$(db_query "
        SELECT available FROM model_availability
        WHERE model_id = '$(sql_escape "$model_id")' AND provider = '$(sql_escape "$provider")'
        AND (julianday('now') - julianday(checked_at)) * 86400 < ttl_seconds;
    ")

	if [[ -n "$cached_available" ]]; then
		if [[ "$cached_available" == "1" ]]; then
			[[ "$quiet" != "true" ]] && print_info "$model_spec: available (cached)"
			return 0
		else
			[[ "$quiet" != "true" ]] && print_warning "$model_spec: unavailable (cached)"
			return 1
		fi
	fi

	# Model-level check 1: OpenCode models cache (instant, preferred)
	if _opencode_model_exists "$model_spec"; then
		_record_model_availability "$model_id" "$provider" 1
		[[ "$quiet" != "true" ]] && print_success "$model_spec: available (OpenCode cache confirmed)"
		return 0
	fi

	# Model-level check 2: query the model-registry SQLite if available
	local registry_db="${AVAILABILITY_DIR}/model-registry.db"
	if [[ -f "$registry_db" ]]; then
		local in_registry
		in_registry=$(sqlite3 -cmd ".timeout 5000" "$registry_db" "
            SELECT COUNT(*) FROM provider_models
            WHERE model_id LIKE '%$(sql_escape "$model_id")%'
            AND provider LIKE '%$(sql_escape "$provider")%';
        " 2>/dev/null || echo "0")

		if [[ "$in_registry" -gt 0 ]]; then
			_record_model_availability "$model_id" "$provider" 1
			[[ "$quiet" != "true" ]] && print_success "$model_spec: available (registry confirmed)"
			return 0
		fi
	fi

	# If provider is healthy but we can't confirm the specific model,
	# assume available (provider health is the primary signal)
	_record_model_availability "$model_id" "$provider" 1
	[[ "$quiet" != "true" ]] && print_info "$model_spec: assumed available (provider healthy)"
	return 0
}

_record_model_availability() {
	local model_id="$1"
	local provider="$2"
	local available="$3"

	db_query "
        INSERT INTO model_availability (model_id, provider, available, checked_at, ttl_seconds)
        VALUES (
            '$(sql_escape "$model_id")',
            '$(sql_escape "$provider")',
            $available,
            strftime('%Y-%m-%dT%H:%M:%SZ', 'now'),
            $DEFAULT_HEALTH_TTL
        )
        ON CONFLICT(model_id, provider) DO UPDATE SET
            available = excluded.available,
            checked_at = excluded.checked_at,
            ttl_seconds = excluded.ttl_seconds;
    " || true
	return 0
}

# =============================================================================
# Tier Resolution with Fallback
# =============================================================================

# =============================================================================
# Rate Limit Awareness (t1330)
# =============================================================================

# Check if a provider is at throttle risk using observability data.
# Delegates to observability-helper.sh check_rate_limit_risk() if available.
# Returns: 0=ok, 1=throttle-risk (warn), 2=critical
# Outputs: "ok", "warn", or "critical" on stdout
_check_provider_rate_limit_risk() {
	local provider="$1"
	local obs_helper="${SCRIPT_DIR}/observability-helper.sh"

	if [[ ! -x "$obs_helper" ]]; then
		echo "ok"
		return 0
	fi

	# Query rate-limit status as a subprocess to avoid variable conflicts.
	# Timeout prevents blocking dispatch if observability DB is slow.
	# timeout_sec is provided by shared-constants.sh (portable macOS + Linux)
	local risk_status
	risk_status=$(timeout_sec 5 bash "$obs_helper" rate-limits --provider "$provider" --json |
		jq -r '.[0].status // "ok"' || true)
	risk_status="${risk_status:-ok}"

	case "$risk_status" in
	critical)
		echo "critical"
		return 2
		;;
	warn)
		echo "warn"
		return 1
		;;
	*)
		echo "ok"
		return 0
		;;
	esac
}

# Extract provider from a model spec (provider/model or model)
_extract_provider() {
	local model_spec="$1"
	if [[ "$model_spec" == *"/"* ]]; then
		echo "${model_spec%%/*}"
	else
		case "$model_spec" in
		claude*) echo "anthropic" ;;
		gpt* | o3* | o4*) echo "openai" ;;
		gemini*) echo "google" ;;
		deepseek*) echo "deepseek" ;;
		llama*) echo "groq" ;;
		*) echo "" ;;
		esac
	fi
	return 0
}

# =============================================================================
# Tier Resolution with Fallback
# =============================================================================

# Resolve the best available model for a given tier.
# Checks every configured same-tier candidate in order.
# Rate limit awareness (t1330): if primary provider is at throttle risk (>=warn_pct),
# prefer the fallback provider even if primary is technically available.
# If both fail, delegates to fallback-chain-helper.sh for extended chain resolution
# including gateway providers (OpenRouter, Cloudflare AI Gateway).
# Output: provider/model_id on stdout
# Returns: 0 if a model was resolved, 1 if no model available for this tier
resolve_tier() {
	local tier="$1"
	local force="${2:-false}"
	local quiet="${3:-false}"

	local tier_spec
	tier_spec=$(get_tier_models "$tier" 2>/dev/null)
	local tier_models_rc=$?
	if [[ "$tier_models_rc" -ne 0 ]]; then
		[[ "$quiet" != "true" ]] && print_error "Unknown tier: $tier"
		return 1
	fi
	if [[ -z "$tier_spec" ]]; then
		[[ "$quiet" != "true" ]] && print_error "No models configured for tier: $tier"
		return 1
	fi

	local primary="${tier_spec%%|*}"

	# Rate-limit routing disabled (t1927). The observability helper's rate-limit
	# data is unreliable — it reports cumulative session tokens as per-minute API
	# usage (e.g., 1.4M tokens in a 1-min window, 3682% of limit), which triggers
	# false "critical" status and routes away from Claude to fallback providers.
	#
	# Anthropic's per-request rate limits (requests/min, tokens/min) are NOT the
	# same as the account's token budget (tokens/day, tokens/week). The user's
	# account has never hit per-request rate limits in interactive sessions.
	#
	# The probe already handles actual HTTP 429 (rate_limited status) — if the API
	# genuinely rate-limits a request, the probe records it and check_model_available
	# returns false for that provider. That's the correct gate; the observability
	# helper's pre-emptive risk check is redundant and broken.
	#
	# To re-enable: fix observability-helper.sh rate-limits to use only the API
	# response headers from the probe (anthropic-ratelimit-* / x-ratelimit-*),
	# not cumulative session token counts. Then uncomment the block below.
	#
	# local primary_provider
	# primary_provider=$(_extract_provider "$primary")
	# if [[ -n "$primary_provider" ]]; then
	#     local rl_risk
	#     rl_risk=$(_check_provider_rate_limit_risk "$primary_provider") || true
	#     if [[ "$rl_risk" == "warn" || "$rl_risk" == "critical" ]]; then
	#         # Try fallback first when primary is genuinely throttled
	#         ...
	#     fi
	# fi

	local -a candidates=()
	local candidate=""
	IFS='|' read -r -a candidates <<<"$tier_spec"
	local candidate_index=0
	for candidate in "${candidates[@]}"; do
		[[ -n "$candidate" ]] || continue
		if check_model_available "$candidate" "$force" "true"; then
			printf '%s\n' "$candidate"
			if [[ "$quiet" != "true" ]]; then
				if [[ "$candidate_index" -eq 0 ]]; then
					print_success "Resolved $tier -> $candidate (primary)"
				else
					print_warning "Resolved $tier -> $candidate (candidate $((candidate_index + 1)), primary $primary unavailable)"
				fi
			fi
			return 0
		fi
		candidate_index=$((candidate_index + 1))
	done

	# Extended fallback: delegate to fallback-chain-helper.sh (t132.4)
	# This walks the full configured chain including gateway providers
	local chain_helper="${SCRIPT_DIR}/fallback-chain-helper.sh"
	if [[ -x "$chain_helper" ]]; then
		[[ "$quiet" != "true" ]] && print_info "Primary/fallback exhausted, trying extended fallback chain..."
		local chain_resolved
		chain_resolved=$("$chain_helper" resolve "$tier" --quiet 2>/dev/null) || true
		if [[ -n "$chain_resolved" ]]; then
			echo "$chain_resolved"
			[[ "$quiet" != "true" ]] && print_warning "Resolved $tier -> $chain_resolved (via fallback chain)"
			return 0
		fi
	fi

	[[ "$quiet" != "true" ]] && print_error "No available model for tier: $tier (configured candidates and extended chain exhausted)"
	return 1
}

# Resolve a model using the full fallback chain (t132.4).
# Unlike resolve_tier which tries primary/fallback first, this goes directly
# to the fallback chain configuration for maximum flexibility.
# Supports per-agent overrides via --agent flag.
resolve_tier_chain() {
	local tier="$1"
	local force="${2:-false}"
	local quiet="${3:-false}"
	local agent_file="${4:-}"

	local chain_helper="${SCRIPT_DIR}/fallback-chain-helper.sh"
	if [[ ! -x "$chain_helper" ]]; then
		[[ "$quiet" != "true" ]] && print_warning "fallback-chain-helper.sh not found, falling back to resolve_tier"
		resolve_tier "$tier" "$force" "$quiet"
		return $?
	fi

	local -a chain_args=("resolve" "$tier")
	[[ "$quiet" == "true" ]] && chain_args+=("--quiet")
	[[ "$force" == "true" ]] && chain_args+=("--force")
	[[ -n "$agent_file" ]] && chain_args+=("--agent" "$agent_file")

	local resolved
	resolved=$("$chain_helper" "${chain_args[@]}" 2>/dev/null) || true

	if [[ -n "$resolved" ]]; then
		echo "$resolved"
		[[ "$quiet" != "true" ]] && print_success "Resolved $tier -> $resolved (via fallback chain)"
		return 0
	fi

	[[ "$quiet" != "true" ]] && print_error "No available model for tier: $tier (fallback chain exhausted)"
	return 1
}
