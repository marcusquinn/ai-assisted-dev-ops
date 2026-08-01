#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

# Model Availability Helper - Probe before dispatch
# Lightweight provider health checks using direct HTTP API calls.
# Tests API key validity, model availability, and rate limits.
# Caches results with short TTL to avoid redundant probes.
#
# Usage: model-availability-helper.sh [command] [options]
#
# Commands:
#   check [provider|model]  Check if a provider/model is available (exit 0=yes, 1=no)
#   probe [--all]           Probe all configured providers (or specific one)
#   status                  Show cached availability status for all providers
#   rate-limits             Show current rate limit status from cache
#   resolve <tier>          Resolve best available model for a tier (with fallback)
#   invalidate [provider]   Clear cache for a provider (or all)
#   mark-unavailable <provider> [reason] [seconds]
#                         Record a short negative provider health entry
#   help                    Show this help
#
# Options:
#   --json        Output in JSON format
#   --quiet       Suppress informational output
#   --force       Bypass cache and probe live
#   --ttl N       Override cache TTL in seconds (default: 300)
#
# Integration:
#   - Called by pulse-wrapper.sh before dispatch (replaces inline health check)
#   - Uses direct HTTP API calls (~1-2s) instead of full AI CLI sessions (~8s)
#   - Reads API keys from: env vars > gopass > credentials.sh
#   - Cache: SQLite at ~/.aidevops/.agent-workspace/model-availability.db
#
# Exit codes:
#   0 - Provider/model available
#   1 - Provider/model unavailable or error
#   2 - Rate limited (retry after delay)
#   3 - API key invalid or missing
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

init_log_file

# =============================================================================
# Configuration
# =============================================================================

readonly AVAILABILITY_DIR="${HOME}/.aidevops/.agent-workspace"
readonly AVAILABILITY_DB="${AVAILABILITY_DIR}/model-availability.db"
readonly DEFAULT_HEALTH_TTL=300   # 5 minutes for health checks
readonly DEFAULT_RATELIMIT_TTL=60 # 1 minute for rate limit data
readonly PROBE_TIMEOUT=10         # HTTP request timeout in seconds

# Last successful resolve_api_key source. Probe helpers use this to distinguish
# runtime-auth precedence from mere credential presence without printing secrets.
RESOLVED_API_KEY_SOURCE=""

# Known providers list (opencode is a meta-provider routing through its gateway;
# local/ollama are local inference providers with no API key requirement)
readonly KNOWN_PROVIDERS="anthropic openai google openrouter groq deepseek opencode local ollama"

# OpenCode models cache (from models.dev, refreshed by opencode CLI)
readonly OPENCODE_MODELS_CACHE="${HOME}/.cache/opencode/models.json"

# Provider API endpoints for lightweight probes
# These endpoints are chosen for minimal cost: /models endpoints are free
# and return quickly, confirming both key validity and API availability.
# Uses functions instead of associative arrays for bash 3.2 compatibility (macOS).
get_provider_endpoint() {
	local provider="$1"
	case "$provider" in
	anthropic) echo "https://api.anthropic.com/v1/models" ;;
	openai) echo "https://api.openai.com/v1/models" ;;
	google) echo "https://generativelanguage.googleapis.com/v1beta/models" ;;
	openrouter) echo "https://openrouter.ai/api/v1/models" ;;
	groq) echo "https://api.groq.com/openai/v1/models" ;;
	deepseek) echo "https://api.deepseek.com/v1/models" ;;
	opencode) echo "https://opencode.ai/zen/v1/models" ;;
	local) echo "http://localhost:8080/v1/models" ;;
	ollama) echo "http://localhost:11434/api/tags" ;;
	*) return 1 ;;
	esac
	return 0
}

# Provider to env var mapping (comma-separated for multiple options)
# local and ollama are local inference providers — no API key required.
# Returns empty string (not an error) so callers can skip key resolution.
get_provider_key_vars() {
	local provider="$1"
	case "$provider" in
	anthropic) echo "ANTHROPIC_API_KEY" ;;
	openai) echo "OPENAI_API_KEY" ;;
	google) echo "GOOGLE_API_KEY,GEMINI_API_KEY" ;;
	openrouter) echo "OPENROUTER_API_KEY" ;;
	groq) echo "GROQ_API_KEY" ;;
	deepseek) echo "DEEPSEEK_API_KEY" ;;
	opencode) echo "OPENCODE_API_KEY" ;;
	local | ollama) echo "" ;;
	*) return 1 ;;
	esac
	return 0
}

# Check if a provider name is known
is_known_provider() {
	local provider="$1"
	case "$provider" in
	anthropic | openai | google | openrouter | groq | deepseek | zai-coding-plan | local | ollama) return 0 ;;
	*) return 1 ;;
	esac
}

# Tier to primary/fallback model mapping
# Format: primary_provider/model|fallback_provider/model
# NEVER use opencode/* gateway models as fallbacks — they route through
# OpenCode's per-token billing and are far more expensive than direct
# provider API keys or subscription accounts.
get_tier_models() {
	local requested_tier="$1"
	local tier
	tier=$(normalize_model_tier_name "$requested_tier")
	local allowlist_raw="${AIDEVOPS_HEADLESS_PROVIDER_ALLOWLIST:-}"
	local -a allowlist=()
	local -a filtered_models=()
	local current_model current_provider

	if [[ -n "$allowlist_raw" ]]; then
		IFS=',' read -r -a allowlist <<<"$allowlist_raw"
	fi

	# User-local override checked first — survives aidevops update.
	# Copy configs/model-routing-table.json to custom/configs/ and edit.
	# Framework defaults are ordered, availability-checked provider fallbacks.
	local routing_table="${SCRIPT_DIR}/../custom/configs/model-routing-table.json"
	if [[ ! -f "$routing_table" ]]; then
		routing_table="${SCRIPT_DIR}/../configs/model-routing-table.json"
	fi
	if [[ -f "$routing_table" ]]; then
		while IFS= read -r current_model; do
			[[ -z "$current_model" ]] && continue
			current_provider="${current_model%%/*}"
			if [[ ${#allowlist[@]} -gt 0 ]]; then
				local allowed=false
				local allowed_provider
				for allowed_provider in "${allowlist[@]}"; do
					allowed_provider=$(printf '%s' "$allowed_provider" | sed 's/^ *//;s/ *$//')
					if [[ "$allowed_provider" == "$current_provider" ]]; then
						allowed=true
						break
					fi
				done
				[[ "$allowed" == "true" ]] || continue
			fi
			filtered_models+=("$current_model")
		done < <(jq -r --arg canonical "$tier" --arg requested "$requested_tier" \
			'(.tiers[$canonical].models // .tiers[$requested].models // [])[]' "$routing_table" 2>/dev/null)
		if [[ ${#filtered_models[@]} -gt 0 ]]; then
			local models_json=""
			models_json=$(
				IFS='|'
				printf '%s' "${filtered_models[*]}"
			)
			echo "$models_json"
			return 0
		fi
		if [[ ${#allowlist[@]} -gt 0 ]]; then
			echo ""
			return 0
		fi
	fi

	# Hardcoded fallback — kept in sync with model-routing-table.json.
	# If you're editing these, update the JSON file instead.
	# Current smoke-tested models are the headless defaults. An empty local value
	# deliberately fails closed rather than sending local-only work to cloud.
	case "$tier" in
	simple) current_model=$'openai/gpt-5.6-luna\nanthropic/claude-haiku-4-5' ;;
	standard) current_model=$'openai/gpt-5.6-sol\nzai-coding-plan/glm-5.2\nanthropic/claude-sonnet-4-6' ;;
	thinking) current_model=$'openai/gpt-5.6-sol\nanthropic/claude-opus-4-6' ;;
	*) return 1 ;;
	esac
	[[ -n "$current_model" ]] || return 1

	if [[ ${#allowlist[@]} -eq 0 ]]; then
		printf '%s\n' "$current_model" | paste -sd'|' -
		return 0
	fi

	filtered_models=()
	while IFS= read -r current_provider; do
		[[ -z "$current_provider" ]] && continue
		local provider_name="${current_provider%%/*}"
		local allowed=false
		local allowed_provider
		for allowed_provider in "${allowlist[@]}"; do
			allowed_provider=$(printf '%s' "$allowed_provider" | sed 's/^ *//;s/ *$//')
			if [[ "$allowed_provider" == "$provider_name" ]]; then
				allowed=true
				break
			fi
		done
		if [[ "$allowed" == "true" ]]; then
			filtered_models+=("$current_provider")
		fi
	done <<<"$current_model"

	if [[ ${#filtered_models[@]} -eq 0 ]]; then
		echo ""
		return 0
	fi

	echo "$(
		IFS='|'
		printf '%s' "${filtered_models[*]}"
	)"
	return 0
}

# Check if a tier name is known
is_known_tier() {
	local tier="$1"
	case "$tier" in
	simple | standard | thinking) return 0 ;;
	*) return 1 ;;
	esac
}

# =============================================================================
# OpenCode Integration
# =============================================================================
# OpenCode maintains a model registry from models.dev cached at
# ~/.cache/opencode/models.json. This provides instant model discovery
# without needing direct API keys for each provider.

_is_opencode_available() {
	# Check if opencode CLI exists and models cache is present
	if command -v opencode &>/dev/null && [[ -f "$OPENCODE_MODELS_CACHE" && -s "$OPENCODE_MODELS_CACHE" ]]; then
		return 0
	fi
	return 1
}

# Check if a model exists in the OpenCode models cache.
# Returns 0 if found, 1 if not.
_opencode_model_exists() {
	local model_spec="$1"
	local provider model_id

	if [[ "$model_spec" == *"/"* ]]; then
		provider="${model_spec%%/*}"
		model_id="${model_spec#*/}"
	else
		model_id="$model_spec"
		provider=""
	fi

	if [[ ! -f "$OPENCODE_MODELS_CACHE" || ! -s "$OPENCODE_MODELS_CACHE" ]]; then
		return 1
	fi

	# Check the cache JSON: providers are top-level keys, models are nested
	if [[ -n "$provider" ]]; then
		jq -e --arg p "$provider" --arg m "$model_id" \
			'.[$p].models[$m] // empty' "$OPENCODE_MODELS_CACHE" >/dev/null 2>&1
		return $?
	else
		# Search all providers for this model ID
		jq -e --arg m "$model_id" \
			'[.[] | .models[$m] // empty] | length > 0' "$OPENCODE_MODELS_CACHE" >/dev/null 2>&1
		return $?
	fi
}

# =============================================================================
# Database Setup
# =============================================================================

init_db() {
	mkdir -p "$AVAILABILITY_DIR" 2>/dev/null || true

	sqlite3 "$AVAILABILITY_DB" "
        PRAGMA journal_mode=WAL;
        PRAGMA busy_timeout=5000;

        CREATE TABLE IF NOT EXISTS provider_health (
            provider       TEXT PRIMARY KEY,
            status         TEXT NOT NULL DEFAULT 'unknown',
            http_code      INTEGER DEFAULT 0,
            response_ms    INTEGER DEFAULT 0,
            error_message  TEXT DEFAULT '',
            models_count   INTEGER DEFAULT 0,
            checked_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            ttl_seconds    INTEGER NOT NULL DEFAULT $DEFAULT_HEALTH_TTL
        );

        CREATE TABLE IF NOT EXISTS model_availability (
            model_id       TEXT NOT NULL,
            provider       TEXT NOT NULL,
            available      INTEGER NOT NULL DEFAULT 0,
            checked_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            ttl_seconds    INTEGER NOT NULL DEFAULT $DEFAULT_HEALTH_TTL,
            PRIMARY KEY (model_id, provider)
        );

        CREATE TABLE IF NOT EXISTS rate_limits (
            provider       TEXT PRIMARY KEY,
            requests_limit INTEGER DEFAULT 0,
            requests_remaining INTEGER DEFAULT 0,
            requests_reset TEXT DEFAULT '',
            tokens_limit   INTEGER DEFAULT 0,
            tokens_remaining INTEGER DEFAULT 0,
            tokens_reset   TEXT DEFAULT '',
            checked_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
            ttl_seconds    INTEGER NOT NULL DEFAULT $DEFAULT_RATELIMIT_TTL
        );

        CREATE TABLE IF NOT EXISTS probe_log (
            id             INTEGER PRIMARY KEY AUTOINCREMENT,
            provider       TEXT NOT NULL,
            action         TEXT NOT NULL,
            result         TEXT NOT NULL,
            duration_ms    INTEGER DEFAULT 0,
            details        TEXT DEFAULT '',
            timestamp      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
        );

        CREATE INDEX IF NOT EXISTS idx_probe_log_provider ON probe_log(provider);
        CREATE INDEX IF NOT EXISTS idx_probe_log_timestamp ON probe_log(timestamp);
    " >/dev/null 2>/dev/null || {
		print_error "Failed to initialize availability database"
		return 1
	}
	return 0
}

db_query() {
	local query="$1"
	sqlite3 -cmd ".timeout 5000" "$AVAILABILITY_DB" "$query" 2>/dev/null
	return $?
}

db_query_json() {
	local query="$1"
	sqlite3 -cmd ".timeout 5000" -json "$AVAILABILITY_DB" "$query" 2>/dev/null
	return $?
}

sql_escape() {
	local val="$1"
	echo "${val//\'/\'\'}"
	return 0
}

# =============================================================================
# API Key Resolution
# =============================================================================
# Resolves API keys/tokens from four sources (in priority order):
# 1. Environment variables (e.g., ANTHROPIC_API_KEY, OPENAI_API_KEY)
# 2. gopass encrypted secrets
# 3. credentials.sh plaintext fallback
# 4. OpenCode OAuth auth.json (~/.local/share/opencode/auth.json)
#
# Source 4 is critical for headless dispatch: the OpenCode runtime authenticates
# via OAuth tokens stored in auth.json, NOT env vars. Without this source, the
# probe reports "no-key" for providers like Anthropic even when valid OAuth
# tokens exist — causing the availability helper to skip the provider and
# preventing dispatch to Claude models (t1927).
#
# SECURITY: Echoes the key value directly to stdout. Callers MUST capture the
# value in a local variable (api_key=$(resolve_api_key "$provider")) and MUST
# NOT log or print the value. Returns 0 if found, 1 if not.

resolve_api_key() {
	local provider="$1"
	local key_vars
	key_vars=$(get_provider_key_vars "$provider" 2>/dev/null) || key_vars=""
	RESOLVED_API_KEY_SOURCE=""

	# Sources 1-3 require key_vars to be non-empty (env var name to look up).
	# Source 4 (OAuth auth.json) works even without key_vars — it looks up
	# the provider name directly in the auth file.

	if [[ -n "$key_vars" ]]; then
		# Check each possible env var name
		local -a var_names
		IFS=',' read -ra var_names <<<"$key_vars"
		for var_name in "${var_names[@]}"; do
			# Source 1: Environment variable
			# NOTE (t3555): if this env key is stale/invalid and the HTTP probe
			# rejects it (HTTP 401/403), built-in providers may still use the
			# rejected env key at inference time. The probe library checks this
			# source before allowing any auth.json OAuth fallback.
			if [[ -n "${!var_name:-}" ]]; then
				RESOLVED_API_KEY_SOURCE="env:${var_name}"
				echo "${!var_name}"
				return 0
			fi
		done

		# Source 2: gopass (if available)
		if command -v gopass &>/dev/null; then
			for var_name in "${var_names[@]}"; do
				local gopass_path="aidevops/${var_name}"
				if gopass show "$gopass_path" &>/dev/null; then
					local key_val
					key_val=$(gopass show "$gopass_path" 2>/dev/null)
					if [[ -n "$key_val" ]]; then
						RESOLVED_API_KEY_SOURCE="gopass:${var_name}"
						echo "$key_val"
						return 0
					fi
				fi
			done
		fi

		# Source 3: credentials.sh (plaintext fallback)
		local creds_file="${HOME}/.config/aidevops/credentials.sh"
		if [[ -f "$creds_file" ]]; then
			# Source the file to get variables (safe: we control this file)
			# shellcheck disable=SC1090
			source "$creds_file"
			for var_name in "${var_names[@]}"; do
				if [[ -n "${!var_name:-}" ]]; then
					RESOLVED_API_KEY_SOURCE="credentials:${var_name}"
					echo "${!var_name}"
					return 0
				fi
			done
		fi
	fi

	# Source 4: OpenCode auth.json (t1927, t2392)
	# The headless runtime authenticates via OAuth tokens or API keys stored
	# in auth.json, not env vars. This is a read-only check — we don't
	# refresh tokens here.
	#
	# t2392: for OAuth-typed entries, ALWAYS return the synthetic marker
	# `oauth-refresh-available` regardless of access-token expiry. The raw
	# OAuth access token (prefix `sk-ant-oat01-`) cannot be used with the
	# Anthropic probe's `x-api-key` header — that header expects static
	# `sk-ant-api03-` keys. OAuth requires `Authorization: Bearer` and a
	# live OAuth session. The marker makes the probe record healthy and
	# skip HTTP; workers authenticate via the opencode runtime's own
	# OAuth flow, which handles refresh at session start.
	local auth_file="${HOME}/.local/share/opencode/auth.json"
	if [[ -f "$auth_file" ]]; then
		local auth_type
		auth_type=$(jq -r --arg p "$provider" '.[$p].type // empty' "$auth_file" 2>/dev/null) || auth_type=""
		if [[ "$auth_type" == "oauth" ]]; then
			# OAuth entry: presence of the entry means the runtime can
			# authenticate. Probe records healthy and skips HTTP.
			RESOLVED_API_KEY_SOURCE="auth-json-oauth:${provider}"
			echo "oauth-refresh-available"
			return 0
		fi
		# API-key type entries (e.g., opencode, claudecli providers)
		local api_key_entry
		api_key_entry=$(jq -r --arg p "$provider" '.[$p].key // empty' "$auth_file" 2>/dev/null) || api_key_entry=""
		if [[ -n "$api_key_entry" ]]; then
			RESOLVED_API_KEY_SOURCE="auth-json-key:${provider}"
			echo "$api_key_entry"
			return 0
		fi
	fi

	return 1
}

# _get_key_value: deprecated shim — resolve_api_key now echoes the value directly.
# Kept for any external callers; delegates to resolve_api_key.
_get_key_value() {
	local provider="$1"
	resolve_api_key "$provider"
	return $?
}

# =============================================================================
# Cache Management
# =============================================================================

is_cache_valid() {
	local provider="$1"
	local table="${2:-provider_health}"
	local custom_ttl="${3:-}"

	local row
	row=$(db_query "
        SELECT checked_at, ttl_seconds FROM $table
        WHERE provider = '$(sql_escape "$provider")'
        LIMIT 1;
    ")

	if [[ -z "$row" ]]; then
		return 1
	fi

	local checked_at ttl_seconds
	checked_at=$(echo "$row" | cut -d'|' -f1)
	ttl_seconds=$(echo "$row" | cut -d'|' -f2)

	# Allow TTL override
	if [[ -n "$custom_ttl" ]]; then
		ttl_seconds="$custom_ttl"
	fi

	local checked_epoch now_epoch
	if [[ "$(uname)" == "Darwin" ]]; then
		checked_epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$checked_at" "+%s" 2>/dev/null || echo "0")
	else
		checked_epoch=$(date -d "$checked_at" "+%s" 2>/dev/null || echo "0")
	fi
	now_epoch=$(date "+%s")

	local age=$((now_epoch - checked_epoch))
	if [[ "$age" -lt "$ttl_seconds" ]]; then
		return 0
	fi

	return 1
}

invalidate_cache() {
	local provider="${1:-}"

	if [[ -z "$provider" ]]; then
		db_query "DELETE FROM provider_health;"
		db_query "DELETE FROM model_availability;"
		db_query "DELETE FROM rate_limits;"
		print_info "All availability caches cleared"
	else
		local escaped
		escaped=$(sql_escape "$provider")
		db_query "DELETE FROM provider_health WHERE provider = '$escaped';"
		db_query "DELETE FROM model_availability WHERE provider = '$escaped';"
		db_query "DELETE FROM rate_limits WHERE provider = '$escaped';"
		print_info "Cache cleared for provider: $provider"
	fi
	return 0
}

# =============================================================================
# Sub-libraries
# =============================================================================

# shellcheck source=./model-availability-probe-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/model-availability-probe-lib.sh"

# shellcheck source=./model-availability-cmd-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/model-availability-cmd-lib.sh"

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	# Initialize DB for all commands except help
	if [[ "$command" != "help" && "$command" != "--help" && "$command" != "-h" ]]; then
		init_db || return 1
	fi

	case "$command" in
	check)
		cmd_check "$@"
		;;
	probe)
		cmd_probe "$@"
		;;
	status)
		cmd_status "$@"
		;;
	rate-limits | ratelimits | rate_limits)
		cmd_rate_limits "$@"
		;;
	resolve)
		cmd_resolve "$@"
		;;
	resolve-chain | resolve_chain)
		cmd_resolve_chain "$@"
		;;
	mark-unavailable | mark_unavailable)
		cmd_mark_unavailable "$@"
		;;
	invalidate | clear | flush)
		cmd_invalidate "$@"
		;;
	help | --help | -h)
		cmd_help
		;;
	*)
		print_error "Unknown command: $command"
		cmd_help
		return 1
		;;
	esac
	return $?
}

main "$@"
