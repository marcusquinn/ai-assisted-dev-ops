#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Shared Model Tier Resolution & Pricing (extracted from shared-constants.sh)
# =============================================================================
# Model-related functions extracted from shared-constants.sh (t2440, GH#20089)
# to keep that file below the file-size-debt ratchet (1500 lines). Mirrors the
# Phase 1 precedent set by shared-feature-toggles.sh (t2427, PR #20063).
#
# Public API (backward-compatible — all callers source shared-constants.sh,
# which re-sources this sub-library automatically):
#   - resolve_model_tier <tier>       — tier name → full provider/model string.
#                                       Tries fallback-chain-helper.sh first
#                                       (availability-aware), falls back to a
#                                       static mapping.
#   - normalize_model_tier_name <tier> — provider-neutral canonical tier name.
#   - detect_ai_backends              — newline-separated list of available
#                                       AI CLI runtime IDs (opencode, claude).
#                                       Delegates to rt_detect_installed when
#                                       runtime-registry.sh is loaded.
#   - get_model_pricing <model>       — per-1M-token pricing string in the
#                                       form "input|output|cache_read|cache_write"
#                                       loaded from configs/model-pricing.json
#                                       (or hardcoded fallback).
#   - get_provider_from_model <model> — claude/gpt/gemini/deepseek/grok →
#                                       anthropic/openai/google/deepseek/xai.
#
# Internal state:
#   - _MODEL_PRICING_JSON              — cached JSON content (lazy-loaded).
#   - _MODEL_PRICING_JSON_LOADED       — cache-attempt sentinel.
#   - _load_model_pricing_json         — lazy loader, called on first pricing query.
#
# Usage: source "${SCRIPT_DIR}/shared-model-tier.sh"
#        # Sourced from shared-constants.sh — rarely sourced directly.
#
# Dependencies:
#   - runtime-registry.sh (optional — if loaded, detect_ai_backends uses
#     rt_detect_installed; otherwise falls back to hardcoded command checks).
#   - fallback-chain-helper.sh (optional — if present, resolve_model_tier
#     consults it first for availability-aware routing).
#   - jq (optional — if present, get_model_pricing reads model-pricing.json;
#     otherwise falls back to the hardcoded case statement).
#   - bash 4+.
#
# NOTE: This file is sourced BY shared-constants.sh, so all print_* and other
# utility functions from shared-constants.sh are already in scope at load time.
# If sourcing this file standalone (e.g. in tests), source shared-constants.sh
# first — this library does not call any print_* helpers directly.
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_SHARED_MODEL_TIER_LOADED:-}" ]] && return 0
_SHARED_MODEL_TIER_LOADED=1

# =============================================================================
# Model tier resolution (t132.7)
# Shared function for resolving tier names to full provider/model strings.
# Used by runner-helper.sh, cron-helper.sh, cron-dispatch.sh.
# Tries: 1) fallback-chain-helper.sh (availability-aware)
#         2) Static mapping (always works)
# =============================================================================

#######################################
# Validate provider-neutral workload tier names.
# Canonical tiers describe workload complexity, not a model vendor.
#######################################
normalize_model_tier_name() {
	local tier="${1:-standard}"
	case "$tier" in
	simple | standard | thinking) echo "$tier" ;;
	*) echo "$tier" ;;
	esac
	return 0
}

#######################################
# Resolve a model tier name to a full provider/model string (t132.7)
# Accepts canonical tiers (simple, standard, thinking) and full
# provider/model strings (passed through unchanged).
# Returns the resolved model string on stdout.
#######################################
resolve_model_tier() {
	local tier="${1:-standard}"

	# If already a full provider/model string (contains /), return as-is
	if [[ "$tier" == *"/"* ]]; then
		echo "$tier"
		return 0
	fi

	tier=$(normalize_model_tier_name "$tier")

	# Try fallback-chain-helper.sh for availability-aware resolution
	# Use ${BASH_SOURCE[0]:-$0} for shell portability — BASH_SOURCE is undefined
	# in zsh (the MCP shell environment). The :-$0 fallback ensures SCRIPT_DIR
	# resolves correctly whether sourced from bash or zsh. See GH#4904.
	local _sc_self="${BASH_SOURCE[0]:-${0:-}}"
	local chain_helper="${_sc_self%/*}/fallback-chain-helper.sh"
	if [[ -x "$chain_helper" ]]; then
		local resolved
		resolved=$("$chain_helper" resolve "$tier" --quiet 2>/dev/null) || true
		if [[ -n "$resolved" ]]; then
			echo "$resolved"
			return 0
		fi
	fi

	# Static fallback: map tier names to concrete models
	case "$tier" in
	standard)
		echo "openai/gpt-5.6-sol"
		;;
	thinking)
		echo "openai/gpt-5.6-sol"
		;;
	simple)
		echo "openai/gpt-5.6-luna"
		;;
	grok)
		echo "xai/grok-3"
		;;
	*)
		# Unknown tier — return as-is (may be a model name without provider)
		echo "$tier"
		;;
	esac

	return 0
}

#######################################
# Detect available AI CLI backends (t132.7, t1665.5)
# Returns a newline-separated list of available backend runtime IDs.
# Delegates to runtime-registry.sh rt_detect_installed().
#######################################
detect_ai_backends() {
	# Use runtime registry if loaded (t1665.5)
	if type rt_detect_installed &>/dev/null; then
		local installed
		installed=$(rt_detect_installed) || true
		if [[ -z "$installed" ]]; then
			echo "none"
			return 1
		fi
		echo "$installed"
		return 0
	fi

	# Fallback: hardcoded check (registry not loaded)
	local -a backends=()
	if command -v opencode &>/dev/null; then
		backends+=("opencode")
	fi
	if command -v claude &>/dev/null; then
		backends+=("claude")
	fi
	if [[ ${#backends[@]} -eq 0 ]]; then
		echo "none"
		return 1
	fi
	printf '%s\n' "${backends[@]}"
	return 0
}

# =============================================================================
# Model Pricing & Provider Detection (consolidated from t1337.2)
# =============================================================================
# Single source of truth: .agents/configs/model-pricing.json
# Also consumed by observability.mjs (OpenCode plugin).
# Pricing: per 1M tokens — input|output|cache_read|cache_write.
# Budget-tracker uses only input|output; observability uses all four.
#
# Falls back to hardcoded case statement if jq or the JSON file is unavailable.

# Cache for JSON-loaded pricing (avoids re-reading the file on every call)
_MODEL_PRICING_JSON=""
_MODEL_PRICING_JSON_LOADED=""

# Load model-pricing.json into the cache variable.
# Called once on first get_model_pricing() invocation.
_load_model_pricing_json() {
	_MODEL_PRICING_JSON_LOADED="attempted"
	local json_file
	# Try repo-relative path first (works in dev), then deployed path
	# Use ${BASH_SOURCE[0]:-$0} for shell portability — BASH_SOURCE is undefined
	# in zsh (the MCP shell environment). See GH#4904.
	local script_dir="${BASH_SOURCE[0]:-${0:-}}"
	script_dir="${script_dir%/*}"
	for json_file in \
		"${script_dir}/../configs/model-pricing.json" \
		"${HOME}/.aidevops/agents/configs/model-pricing.json"; do
		if [[ -r "$json_file" ]] && command -v jq &>/dev/null; then
			_MODEL_PRICING_JSON=$(cat "$json_file" 2>/dev/null) || _MODEL_PRICING_JSON=""
			if [[ -n "$_MODEL_PRICING_JSON" ]]; then
				return 0
			fi
		fi
	done
	return 1
}

get_model_pricing() {
	local model="$1"
	local fallback_default_pricing="3.0|15.0|0.30|3.75"

	# Try JSON source first (single source of truth)
	if [[ -z "$_MODEL_PRICING_JSON_LOADED" ]]; then
		_load_model_pricing_json
	fi

	if [[ -n "$_MODEL_PRICING_JSON" ]]; then
		local ms="${model#*/}"
		ms="${ms%%-202*}"
		ms=$(echo "$ms" | tr '[:upper:]' '[:lower:]')
		# Sol Pro has no published API price. Do not let substring matching
		# silently assign standard Sol pricing; use the configured unknown default.
		if [[ "$ms" == *gpt-5.6-sol-pro* ]]; then
			local unknown_result
			unknown_result=$(echo "$_MODEL_PRICING_JSON" | jq -r '
				"\(.default.input)|\(.default.output)|\(.default.cache_read)|\(.default.cache_write)"
			' 2>/dev/null)
			if [[ -n "$unknown_result" && "$unknown_result" != "null|null|null|null" ]]; then
				echo "$unknown_result"
				return 0
			fi
		fi
		# Search for a matching key in the JSON models object
		local result
		result=$(echo "$_MODEL_PRICING_JSON" | jq -r --arg ms "$ms" '
			.models | to_entries[] |
			select(.key as $k | $ms | contains($k)) |
			"\(.value.input)|\(.value.output)|\(.value.cache_read)|\(.value.cache_write)"
		' 2>/dev/null | head -1)
		if [[ -n "$result" ]]; then
			echo "$result"
			return 0
		fi
		# No match — return default from JSON
		result=$(echo "$_MODEL_PRICING_JSON" | jq -r '
			"\(.default.input)|\(.default.output)|\(.default.cache_read)|\(.default.cache_write)"
		' 2>/dev/null)
		if [[ -n "$result" && "$result" != "null|null|null|null" ]]; then
			echo "$result"
			return 0
		fi
	fi

	# Hardcoded fallback (no jq or JSON file unavailable)
	local ms="${model#*/}"
	ms="${ms%%-202*}"
	case "$ms" in
	*gpt-5.6-sol-pro*) echo "$fallback_default_pricing" ;;
	*gpt-5.6-sol*) echo "5.0|30.0|0.50|6.25" ;;
	*gpt-5.6-terra*) echo "2.50|15.0|0.25|3.125" ;;
	*gpt-5.6-luna*) echo "1.0|6.0|0.10|1.25" ;;
	*opus-4* | *claude-opus*) echo "15.0|75.0|1.50|18.75" ;;
	*sonnet-4* | *claude-sonnet*) echo "$fallback_default_pricing" ;;
	*haiku-4* | *haiku-3* | *claude-haiku*) echo "0.80|4.0|0.08|1.0" ;;
	*gpt-4.1-mini*) echo "0.40|1.60|0.10|0.40" ;;
	*gpt-4.1*) echo "2.0|8.0|0.50|2.0" ;;
	*o3*) echo "10.0|40.0|2.50|10.0" ;;
	*o4-mini*) echo "1.10|4.40|0.275|1.10" ;;
	*gemini-2.5-pro*) echo "1.25|10.0|0.3125|2.50" ;;
	*gemini-2.5-flash*) echo "0.15|0.60|0.0375|0.15" ;;
	*gemini-3-pro*) echo "1.25|10.0|0.3125|2.50" ;;
	*gemini-3-flash*) echo "0.10|0.40|0.025|0.10" ;;
	*deepseek-r1*) echo "0.55|2.19|0.14|0.55" ;;
	*deepseek-v3*) echo "0.27|1.10|0.07|0.27" ;;
	*) echo "$fallback_default_pricing" ;;
	esac
	return 0
}

get_provider_from_model() {
	local model="$1"
	case "$model" in
	claude-* | anthropic/*) echo "anthropic" ;;
	gpt-* | openai/*) echo "openai" ;;
	gemini-* | google/*) echo "google" ;;
	deepseek-* | deepseek/*) echo "deepseek" ;;
	grok-* | xai/*) echo "xai" ;;
	*) echo "unknown" ;;
	esac
	return 0
}
