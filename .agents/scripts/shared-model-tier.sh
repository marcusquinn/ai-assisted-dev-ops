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
#   - model_routing_table_path        — active user or framework routing table.
#   - model_tier_candidates <tier>    — ordered same-tier candidates, one/line.
#   - model_tier_candidate_index <tier> <model> — zero-based candidate index.
#   - model_tier_candidate_for_provider <tier> <provider> — first provider match.
#   - model_tier_variant <tier> <model> — model-specific/provider variant.
#   - model_tier_escalation_order       — normalized configured tiers, one/line.
#   - model_tier_next <tier>          — next capability tier, when configured.
#   - model_tier_for_model <model>     — configured tier containing a model.
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
# Print the active model-routing table path.
# Precedence: explicit override, update-safe custom table, framework default.
#######################################
model_routing_table_path() {
	local explicit_table="${AIDEVOPS_MODEL_ROUTING_TABLE:-}"
	if [[ -n "$explicit_table" && -r "$explicit_table" ]]; then
		printf '%s\n' "$explicit_table"
		return 0
	fi

	local self_path="${BASH_SOURCE[0]:-${0:-}}"
	local script_dir="${self_path%/*}"
	local candidate=""
	for candidate in \
		"${script_dir}/../custom/configs/model-routing-table.json" \
		"${script_dir}/../configs/model-routing-table.json"; do
		if [[ -r "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done

	return 1
}

model_routing_framework_table_path() {
	local self_path="${BASH_SOURCE[0]:-${0:-}}"
	local framework_table="${self_path%/*}/../configs/model-routing-table.json"
	[[ -r "$framework_table" ]] || return 1
	printf '%s\n' "$framework_table"
	return 0
}

#######################################
# Print per-tier schema findings for a custom routing table.
#######################################
model_routing_custom_table_validation_findings() {
	local custom_table="$1"
	local framework_table="$2"
	local findings=""

	[[ -n "$custom_table" && "$custom_table" != "$framework_table" ]] || return 0
	if ! command -v jq >/dev/null 2>&1; then
		printf '%s\n' "document: jq is required to validate custom model routing"
		return 0
	fi

	if ! findings=$(jq -r '
		if type != "object" then
			["document: root must be an object"]
		elif (.tiers | type) != "object" then
			["tiers: must be an object"]
		else
			[.tiers | to_entries[] | .key as $tier | .value as $definition |
				if (["simple", "standard", "thinking"] | index($tier) | not) then
					"\($tier): unsupported tier (use simple, standard, or thinking)"
				elif ($definition | type) != "object" then
					"\($tier): must be an object containing models"
				elif ($definition.models | type) != "array" then
					"\($tier): models must be an array"
				else empty end]
		end | .[]
	' "$custom_table" 2>/dev/null); then
		findings="document: could not be parsed"
	fi

	[[ -z "$findings" ]] || printf '%s\n' "$findings"
	return 0
}

#######################################
# Warn once when a custom routing-table tier cannot supply candidates.
#######################################
model_routing_warn_invalid_custom_table() {
	local custom_table="$1"
	local framework_table="$2"
	local findings=""

	[[ "${_MODEL_ROUTING_CUSTOM_TABLE_WARNING_EMITTED:-0}" != "1" ]] || return 0
	findings=$(model_routing_custom_table_validation_findings "$custom_table" "$framework_table") || return 0
	[[ -n "$findings" ]] || return 0
	_MODEL_ROUTING_CUSTOM_TABLE_WARNING_EMITTED=1
	printf 'WARNING: custom model routing table has invalid tiers; those tiers are ignored: %s\n' "${findings//$'\n'/; }" >&2
	return 0
}

#######################################
# Print the ordered, same-tier model candidates, one per line.
# A readable routing table is authoritative: a missing tier fails closed.
#######################################
model_tier_candidates() {
	local requested_tier="${1:-standard}"
	if [[ "$requested_tier" == *"/"* ]]; then
		printf '%s\n' "$requested_tier"
		return 0
	fi

	local tier=""
	tier=$(normalize_model_tier_name "$requested_tier")
	local routing_table=""
	local framework_table=""
	local candidates=""
	routing_table=$(model_routing_table_path 2>/dev/null) || routing_table=""
	framework_table=$(model_routing_framework_table_path 2>/dev/null) || framework_table=""
	if command -v jq >/dev/null 2>&1; then
		model_routing_warn_invalid_custom_table "$routing_table" "$framework_table"
		local table=""
		local previous_table=""
		for table in "$routing_table" "$framework_table"; do
			[[ -n "$table" && -r "$table" ]] || continue
			[[ "$table" != "$previous_table" ]] || continue
			previous_table="$table"
			if jq -e --arg canonical "$tier" --arg requested "$requested_tier" \
				'((.tiers[$canonical].models // .tiers[$requested].models) | type) == "array"' \
				"$table" >/dev/null 2>&1; then
				candidates=$(jq -r --arg canonical "$tier" --arg requested "$requested_tier" \
					'(.tiers[$canonical].models // .tiers[$requested].models // [])[] | select(type == "string" and length > 0)' \
					"$table" 2>/dev/null) || candidates=""
				if [[ -n "$candidates" ]]; then
					printf '%s\n' "$candidates"
					return 0
				fi
				return 1
			fi
		done
	fi

	case "$tier" in
	simple) printf '%s\n' "openai/gpt-5.6-luna" "anthropic/claude-haiku-4-5" ;;
	standard) printf '%s\n' "openai/gpt-5.6-terra" "zai-coding-plan/glm-5.2" "anthropic/claude-sonnet-4-6" ;;
	thinking) printf '%s\n' "openai/gpt-6-astra" "anthropic/claude-opus-4-6" ;;
	*) return 1 ;;
	esac
	return 0
}

#######################################
# Print the zero-based same-tier candidate index for a concrete model.
#######################################
model_tier_candidate_index() {
	local requested_tier="${1:-standard}"
	local requested_model="${2:-}"
	local index=0
	local candidate=""
	while IFS= read -r candidate; do
		if [[ "$candidate" == "$requested_model" ]]; then
			printf '%s\n' "$index"
			return 0
		fi
		index=$((index + 1))
	done < <(model_tier_candidates "$requested_tier" 2>/dev/null || true)
	printf '%s\n' "-1"
	return 1
}

#######################################
# Print the first same-tier candidate belonging to an explicit provider.
#######################################
model_tier_candidate_for_provider() {
	local requested_tier="${1:-standard}"
	local requested_provider="${2:-}"
	local candidate=""
	[[ -n "$requested_provider" ]] || return 1
	while IFS= read -r candidate; do
		if [[ "${candidate%%/*}" == "$requested_provider" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done < <(model_tier_candidates "$requested_tier" 2>/dev/null || true)
	return 1
}

#######################################
# Print the configured reasoning variant for a concrete tier/model pair.
# Full model IDs take precedence over provider keys and a default key.
#######################################
model_tier_variant() {
	local requested_tier="${1:-standard}"
	local model="${2:-}"
	local tier=""
	tier=$(normalize_model_tier_name "$requested_tier")
	local provider="${model%%/*}"
	local routing_table=""
	local framework_table=""
	routing_table=$(model_routing_table_path 2>/dev/null) || routing_table=""
	framework_table=$(model_routing_framework_table_path 2>/dev/null) || framework_table=""
	command -v jq >/dev/null 2>&1 || return 1

	local variant=""
	local variant_result=""
	local table=""
	local previous_table=""
	for table in "$routing_table" "$framework_table"; do
		[[ -n "$table" && -r "$table" && "$table" != "$previous_table" ]] || continue
		previous_table="$table"
		variant_result=$(jq -r --arg tier "$tier" --arg model "$model" --arg provider "$provider" --arg string_type string '
			"found" as $status
			| "default" as $default_key
			| .tiers[$tier].reasoning as $reasoning
			| if ($reasoning | type) == "object" then
				if ($reasoning | has($model)) and (($reasoning[$model] | type) == $string_type) then
					[$status, $reasoning[$model]] | @tsv
				elif ($reasoning | has($provider)) and (($reasoning[$provider] | type) == $string_type) then
					[$status, $reasoning[$provider]] | @tsv
				elif ($reasoning | has($default_key)) and (($reasoning[$default_key] | type) == $string_type) then
					[$status, $reasoning[$default_key]] | @tsv
				else empty end
			  else empty end
		' "$table" 2>/dev/null) || variant_result=""
		if [[ "$variant_result" == "found"$'\t'* ]]; then
			variant="${variant_result#*$'\t'}"
			[[ -z "$variant" ]] || printf '%s\n' "$variant"
			return 0
		fi
	done
	return 1
}

#######################################
# Print the next explicitly configured reasoning level for this exact model.
# Invalid, duplicate, descending, exhausted or unknown ladders fail closed.
#######################################
model_tier_next_variant() {
	local requested_tier="$1"
	local model="$2"
	local current="$3"
	local tier="" table="" routing_table="" framework_table="" previous_table=""
	tier=$(normalize_model_tier_name "$requested_tier")
	routing_table=$(model_routing_table_path 2>/dev/null) || routing_table=""
	framework_table=$(model_routing_framework_table_path 2>/dev/null) || framework_table=""
	command -v jq >/dev/null 2>&1 || return 1
	for table in "$routing_table" "$framework_table"; do
		[[ -n "$table" && -r "$table" && "$table" != "$previous_table" ]] || continue
		previous_table="$table"
		if jq -e --arg tier "$tier" --arg model "$model" \
			'.tiers[$tier].reasoning_escalation | type == "object" and has($model)' "$table" >/dev/null 2>&1; then
			jq -er --arg tier "$tier" --arg model "$model" --arg current "$current" '
				["low", "medium", "high"] as $levels
				| .tiers[$tier].reasoning_escalation[$model] as $ladder
				| select(($ladder | type) == "array")
				| [$ladder[] | . as $level | $levels | index($level)] as $ranks
				| select(($ranks | all(. != null)) and ($ranks == ($ranks | sort | unique)))
				| ($ladder | index($current)) as $index
				| select($index != null) | $ladder[$index + 1] // empty
			' "$table" 2>/dev/null || return 1
			return 0
		fi
	done
	return 1
}

#######################################
# Print the configured capability order, preserving valid override order and
# appending omitted canonical tiers. This mirrors the OpenCode routing reader.
#######################################
model_tier_escalation_order() {
	local routing_table=""
	local framework_table=""
	local configured_order=""
	routing_table=$(model_routing_table_path 2>/dev/null) || routing_table=""
	framework_table=$(model_routing_framework_table_path 2>/dev/null) || framework_table=""
	if command -v jq >/dev/null 2>&1; then
		local table=""
		local previous_table=""
		for table in "$routing_table" "$framework_table"; do
			[[ -n "$table" && -r "$table" && "$table" != "$previous_table" ]] || continue
			previous_table="$table"
			if jq -e '.escalation_order | type == "array"' "$table" >/dev/null 2>&1; then
				configured_order=$(jq -r '.escalation_order[]? | select(type == "string")' "$table" 2>/dev/null) || configured_order=""
				break
			fi
		done
	fi

	local seen="," candidate=""
	while IFS= read -r candidate; do
		case "$candidate" in simple | standard | thinking) ;; *) continue ;; esac
		[[ "$seen" != *",${candidate},"* ]] || continue
		printf '%s\n' "$candidate"
		seen="${seen}${candidate},"
	done <<<"$configured_order"
	for candidate in simple standard thinking; do
		[[ "$seen" != *",${candidate},"* ]] || continue
		printf '%s\n' "$candidate"
		seen="${seen}${candidate},"
	done
	return 0
}

#######################################
# Print the next configured capability tier. Returns 1 at the final tier.
# Explicitly disabled tiers are skipped rather than becoming dead ends.
#######################################
model_tier_next() {
	local requested_tier="${1:-standard}"
	local tier=""
	tier=$(normalize_model_tier_name "$requested_tier")
	local candidate="" current_seen=false
	while IFS= read -r candidate; do
		if [[ "$current_seen" == "true" ]]; then
			if model_tier_candidates "$candidate" >/dev/null 2>&1; then
				printf '%s\n' "$candidate"
				return 0
			fi
		elif [[ "$candidate" == "$tier" ]]; then
			current_seen=true
		fi
	done < <(model_tier_escalation_order)
	return 1
}

#######################################
# Print the first configured tier containing a concrete model.
#######################################
model_tier_for_model() {
	local model="$1"
	local tier="" candidate=""
	while IFS= read -r tier; do
		while IFS= read -r candidate; do
			if [[ "$candidate" == "$model" ]]; then
				printf '%s\n' "$tier"
				return 0
			fi
		done < <(model_tier_candidates "$tier" 2>/dev/null || true)
	done < <(model_tier_escalation_order)
	return 1
}

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

	# Deterministic fallback: use the first candidate from the same active table.
	local candidate=""
	candidate=$(model_tier_candidates "$tier" 2>/dev/null | sed -n '1p') || candidate=""
	if [[ -n "$candidate" ]]; then
		printf '%s\n' "$candidate"
		return 0
	fi

	# Unknown tier — return as-is (may be a model name without provider).
	printf '%s\n' "$tier"

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
	*gpt-6-astra*) echo "10.0|50.0|1.0|12.50" ;;
	*gpt-5.6-sol*) echo "4.0|20.0|0.40|5.0" ;;
	*gpt-5.6-terra*) echo "2.0|12.0|0.20|2.50" ;;
	*gpt-5.6-luna*) echo "0.20|1.20|0.02|0.25" ;;
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
