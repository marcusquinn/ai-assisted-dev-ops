#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034

# Compare Models Helper - AI Model Capability Comparison
# Compare pricing, context windows, and capabilities across AI model providers.
#
# Usage: compare-models-helper.sh [command] [options]
#
# Commands:
#   list          List all tracked models
#   compare       Compare specific models side-by-side
#   recommend     Recommend models for a task type
#   pricing       Show pricing table
#   context       Show context window comparison
#   capabilities  Show capability matrix
#   providers     List supported providers
#   discover      Detect available providers and models from local config
#   cross-review  Dispatch same prompt to multiple models, diff results (t132.8)
#   bench         Live benchmark: send same prompt to N models, compare outputs (t1393)
#   help          Show this help
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# =============================================================================
# Pattern Tracker Integration (t1098)
# =============================================================================
# Reads live success/failure data from the pattern tracker memory DB.
# Same DB as pattern-tracker-helper.sh — no duplication of storage.

readonly PATTERN_DB="${AIDEVOPS_MEMORY_DIR:-$HOME/.aidevops/.agent-workspace/memory}/memory.db"
readonly -a PATTERN_VALID_MODELS=(simple standard thinking)

# Check if pattern data is available
has_pattern_data() {
	[[ -f "$PATTERN_DB" ]] || return 1
	local count
	count=$(sqlite3 "$PATTERN_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('SUCCESS_PATTERN','FAILURE_PATTERN','WORKING_SOLUTION','FAILED_APPROACH','ERROR_FIX');" 2>/dev/null || echo "0")
	[[ "$count" -gt 0 ]] && return 0
	return 1
}

# Internal helper: get raw success/failure counts for a tier
# Usage: _get_tier_pattern_counts "standard" [task_type]
# Output: "successes|failures" (e.g. "12|3") or "0|0" if no data
_get_tier_pattern_counts() {
	local tier="$1"
	local task_type="${2:-}"
	[[ -f "$PATTERN_DB" ]] || {
		echo "0|0"
		return 0
	}

	local filter=""
	if [[ -n "$task_type" ]]; then
		filter="AND (tags LIKE '%${task_type}%' OR content LIKE '%task:${task_type}%')"
	fi

	local model_filter="AND (tags LIKE '%model:${tier}%' OR content LIKE '%model:${tier}%')"

	local successes failures
	successes=$(sqlite3 "$PATTERN_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('SUCCESS_PATTERN', 'WORKING_SOLUTION') $model_filter $filter;" 2>/dev/null || echo "0")
	failures=$(sqlite3 "$PATTERN_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('FAILURE_PATTERN', 'FAILED_APPROACH', 'ERROR_FIX') $model_filter $filter;" 2>/dev/null || echo "0")

	echo "${successes}|${failures}"
	return 0
}

# Get success rate for a model tier
# Usage: get_tier_success_rate "standard" [task_type]
# Output: "85|47" (rate|sample_count) or "" if no data
get_tier_success_rate() {
	local tier="$1"
	local task_type="${2:-}"
	[[ -f "$PATTERN_DB" ]] || return 0

	local counts successes failures
	counts=$(_get_tier_pattern_counts "$tier" "$task_type")
	IFS='|' read -r successes failures <<<"$counts"

	local total=$((successes + failures))
	if [[ "$total" -gt 0 ]]; then
		local rate=$(((successes * 100) / total))
		echo "${rate}|${total}"
	fi
	return 0
}

# Map a model_id to its aidevops tier for pattern lookup
# Usage: model_id_to_tier "claude-sonnet-4-6" -> "standard"
model_id_to_tier() {
	local model_id="$1"
	case "$model_id" in
	*opus* | *pro* | o3 | gpt-5.2 | gpt-5.4 | gpt-5.4-*) echo "thinking" ;;
	*haiku* | *flash* | *terra* | gemini-2.0* | o4-mini | gpt-4.1-mini | gpt-4o-mini | deepseek* | llama* | gpt-4.1-nano) echo "simple" ;;
	*sonnet* | gpt-5.3-codex | gpt-5.3-codex-* | gpt-4.1 | gpt-4o) echo "standard" ;;
	*) echo "" ;;
	esac
	return 0
}

# Format pattern data for display in tables
# Usage: format_pattern_badge "standard"
# Output: "85% (n=47)" or "" if no data
format_pattern_badge() {
	local tier="$1"
	local task_type="${2:-}"
	local data
	data=$(get_tier_success_rate "$tier" "$task_type")
	if [[ -n "$data" ]]; then
		local rate sample
		IFS='|' read -r rate sample <<<"$data"
		echo "${rate}% (n=${sample})"
	fi
	return 0
}

# Get all tier pattern data as a summary block
# Output: multi-line "tier|rate|samples" for tiers with data
get_all_tier_patterns() {
	local task_type="${1:-}"
	[[ -f "$PATTERN_DB" ]] || return 0

	for tier in "${PATTERN_VALID_MODELS[@]}"; do
		local data
		data=$(get_tier_success_rate "$tier" "$task_type")
		if [[ -n "$data" ]]; then
			echo "${tier}|${data}"
		fi
	done
	return 0
}

# =============================================================================
# Model Database (embedded reference data)
# =============================================================================
# Format: model_id|provider|display_name|context_window|input_price_per_1m|output_price_per_1m|tier|capabilities|best_for
# Prices in USD per 1M tokens. Last updated: 2026-04-16.
# Sources: Anthropic, OpenAI, Google official pricing pages.

readonly MODEL_DATA="claude-opus-4-6|Anthropic|Claude Opus 4.6|1000000|5.00|25.00|high|code,reasoning,architecture,vision,tools|Architecture decisions, novel problems, complex multi-step reasoning. 1M context, 800K auto-compact. Framework default for tier:thinking and the cascade's penultimate rung.
claude-opus-4-7|Anthropic|Claude Opus 4.7|250000|5.00|25.00|high|code,reasoning,architecture,vision,tools|Optional thinking-tier mapping candidate. Better at long-running agentic coherence than 4.6; worse at cold long-context retrieval (MRCR 256K 92%->59%, 1M 78%->32%). +20-60% tokenizer cost on English prompts. 250K cap lets OpenCode's 80% auto-compact trigger at the 200K reliability boundary.
claude-sonnet-4-6|Anthropic|Claude Sonnet 4.6|200000|3.00|15.00|medium|code,reasoning,vision,tools|Code implementation, review, most development tasks
claude-haiku-4-5|Anthropic|Claude Haiku 4.5|200000|1.00|5.00|low|code,reasoning,vision,tools|Triage, classification, simple transforms, formatting
gpt-4.1|OpenAI|GPT-4.1|1048576|2.00|8.00|medium|code,reasoning,vision,tools,search|Coding, instruction following, long context
gpt-4.1-mini|OpenAI|GPT-4.1 Mini|1048576|0.40|1.60|low|code,reasoning,vision,tools|Cost-efficient coding and general tasks
gpt-4.1-nano|OpenAI|GPT-4.1 Nano|1048576|0.10|0.40|low|code,reasoning,tools|Fast classification, simple transforms
gpt-4o|OpenAI|GPT-4o|128000|2.50|10.00|medium|code,reasoning,vision,tools,search|General purpose, multimodal
gpt-4o-mini|OpenAI|GPT-4o Mini|128000|0.15|0.60|low|code,reasoning,vision,tools|Budget general purpose
o3|OpenAI|o3|200000|10.00|40.00|high|code,reasoning,math,science,tools|Complex reasoning, math, science
o4-mini|OpenAI|o4-mini|200000|1.10|4.40|medium|code,reasoning,math,tools|Cost-efficient reasoning
gemini-2.5-pro|Google|Gemini 2.5 Pro|1048576|1.25|10.00|medium|code,reasoning,vision,tools|Large context analysis, complex reasoning
gemini-2.5-flash|Google|Gemini 2.5 Flash|1048576|0.15|0.60|low|code,reasoning,vision,tools|Fast, cheap, large context
gemini-2.0-flash|Google|Gemini 2.0 Flash|1048576|0.10|0.40|low|code,reasoning,vision,tools|Budget large context processing
deepseek-r1|DeepSeek|DeepSeek R1|131072|0.55|2.19|low|code,reasoning,math|Deep reasoning, math, open-source
deepseek-v3|DeepSeek|DeepSeek V3|131072|0.27|1.10|low|code,reasoning|General purpose, cost-efficient
llama-4-maverick|Meta|Llama 4 Maverick|1048576|0.20|0.60|low|code,reasoning,vision,tools|Open-source, large context
llama-4-scout|Meta|Llama 4 Scout|512000|0.15|0.40|low|code,reasoning,vision,tools|Open-source, efficient"

# =============================================================================
# aidevops Tier Mapping
# =============================================================================
# Maps aidevops internal tiers to recommended models

readonly TIER_MAP="simple|claude-haiku-4-5|Triage, classification, search, simple transforms
standard|claude-sonnet-4-6|Code implementation, review, most development tasks
thinking|claude-opus-4-6|Architecture decisions, complex multi-step reasoning"

# =============================================================================
# Task-to-Model Recommendations
# =============================================================================

readonly TASK_RECOMMENDATIONS="code review|claude-sonnet-4-6|gpt-5.3-codex|gemini-2.5-flash
code implementation|claude-sonnet-4-6|gpt-5.3-codex|gemini-2.5-pro
architecture design|claude-opus-4-6|o3|gemini-2.5-pro
bug fixing|claude-sonnet-4-6|gpt-5.3-codex|o4-mini
refactoring|claude-sonnet-4-6|gpt-5.3-codex|gemini-2.5-pro
documentation|claude-sonnet-4-6|gpt-4o|gemini-2.5-flash
testing|claude-sonnet-4-6|gpt-5.3-codex|o4-mini
classification|claude-haiku-4-5|gpt-4.1-nano|gemini-2.5-flash
summarization|gemini-2.5-flash|gpt-4o-mini|claude-haiku-4-5
large codebase analysis|gemini-2.5-pro|gpt-5.3-codex|claude-sonnet-4-6
math reasoning|gpt-5.4|deepseek-r1|gemini-2.5-pro
security audit|claude-opus-4-6|gpt-5.4|claude-sonnet-4-6
data extraction|gemini-2.5-flash|gpt-4o-mini|claude-haiku-4-5
commit messages|claude-haiku-4-5|gpt-4.1-nano|gemini-2.5-flash
pr description|claude-sonnet-4-6|gpt-4o|gemini-2.5-flash"

# =============================================================================
# Helper Functions
# =============================================================================

# Get a field from a model data line
# Usage: get_field "model_line" field_number
get_field() {
	local line="$1"
	local field="$2"
	echo "$line" | cut -d'|' -f"$field"
	return 0
}

# Find model by partial name match
find_model() {
	local query="$1"
	local lower_query
	lower_query=$(echo "$query" | tr '[:upper:]' '[:lower:]')
	echo "$MODEL_DATA" | while IFS= read -r line; do
		local model_id
		model_id=$(get_field "$line" 1)
		local display_name
		display_name=$(get_field "$line" 3)
		local lower_id
		lower_id=$(echo "$model_id" | tr '[:upper:]' '[:lower:]')
		local lower_name
		lower_name=$(echo "$display_name" | tr '[:upper:]' '[:lower:]')
		if [[ "$lower_id" == *"$lower_query"* ]] || [[ "$lower_name" == *"$lower_query"* ]]; then
			echo "$line"
		fi
	done
	return 0
}

# Format number with padding
pad_right() {
	local str="$1"
	local width="$2"
	printf "%-${width}s" "$str"
	return 0
}

# Format price for display
format_price() {
	local price="$1"
	printf "\$%s" "$price"
	return 0
}

# Format context window for display
format_context() {
	local ctx="$1"
	if [[ "$ctx" -ge 1000000 ]]; then
		echo "1M"
	elif [[ "$ctx" -ge 500000 ]]; then
		echo "512K"
	elif [[ "$ctx" -ge 250000 ]]; then
		echo "250K"
	elif [[ "$ctx" -ge 200000 ]]; then
		echo "200K"
	elif [[ "$ctx" -ge 131072 ]]; then
		echo "131K"
	elif [[ "$ctx" -ge 128000 ]]; then
		echo "128K"
	else
		echo "${ctx}"
	fi
	return 0
}

# =============================================================================
# Commands
# =============================================================================

cmd_list() {
	echo ""
	echo "Tracked AI Models"
	echo "================="
	echo ""
	printf "%-22s %-10s %-8s %-12s %-12s %-7s %s\n" \
		"Model" "Provider" "Context" "Input/1M" "Output/1M" "Tier" "Best For"
	printf "%-22s %-10s %-8s %-12s %-12s %-7s %s\n" \
		"-----" "--------" "-------" "--------" "---------" "----" "--------"

	echo "$MODEL_DATA" | while IFS= read -r line; do
		local model_id provider ctx input output tier best
		model_id=$(get_field "$line" 1)
		provider=$(get_field "$line" 2)
		ctx=$(get_field "$line" 4)
		input=$(get_field "$line" 5)
		output=$(get_field "$line" 6)
		tier=$(get_field "$line" 7)
		best=$(get_field "$line" 9)
		local ctx_fmt
		ctx_fmt=$(format_context "$ctx")
		# Truncate best_for for table display
		local best_short="${best:0:40}"
		printf "%-22s %-10s %-8s %-12s %-12s %-7s %s\n" \
			"$model_id" "$provider" "$ctx_fmt" "\$$input" "\$$output" "$tier" "$best_short"
	done

	echo ""
	echo "Prices: USD per 1M tokens. Last updated: 2025-02-08."

	# Pattern data integration (t1098)
	if has_pattern_data; then
		echo ""
		echo "Live Success Rates (from pattern tracker):"
		local pattern_found=false
		for ptier in "${PATTERN_VALID_MODELS[@]}"; do
			local badge
			badge=$(format_pattern_badge "$ptier")
			if [[ -n "$badge" ]]; then
				printf "  %-10s %s\n" "$ptier:" "$badge"
				pattern_found=true
			fi
		done
		if [[ "$pattern_found" != "true" ]]; then
			echo "  (no model-tagged patterns recorded yet)"
		fi
	fi

	echo ""
	echo "Run 'compare-models-helper.sh help' for more commands."
	return 0
}

cmd_compare() {
	local models=("$@")
	if [[ ${#models[@]} -lt 1 ]]; then
		print_error "Usage: compare-models-helper.sh compare <model1> [model2] ..."
		return 1
	fi

	echo ""
	echo "Model Comparison"
	echo "================"
	echo ""

	local found_any=false
	local results=()

	for query in "${models[@]}"; do
		local matches
		matches=$(find_model "$query")
		if [[ -z "$matches" ]]; then
			print_warning "No model found matching: $query"
		else
			while IFS= read -r match; do
				results+=("$match")
				found_any=true
			done <<<"$matches"
		fi
	done

	if [[ "$found_any" != "true" ]]; then
		print_error "No models found. Run 'compare-models-helper.sh list' to see available models."
		return 1
	fi

	printf "%-22s %-10s %-8s %-12s %-12s %-7s\n" \
		"Model" "Provider" "Context" "Input/1M" "Output/1M" "Tier"
	printf "%-22s %-10s %-8s %-12s %-12s %-7s\n" \
		"-----" "--------" "-------" "--------" "---------" "----"

	for line in "${results[@]}"; do
		local model_id provider ctx input output tier
		model_id=$(get_field "$line" 1)
		provider=$(get_field "$line" 2)
		ctx=$(get_field "$line" 4)
		input=$(get_field "$line" 5)
		output=$(get_field "$line" 6)
		tier=$(get_field "$line" 7)
		local ctx_fmt
		ctx_fmt=$(format_context "$ctx")
		printf "%-22s %-10s %-8s %-12s %-12s %-7s\n" \
			"$model_id" "$provider" "$ctx_fmt" "\$$input" "\$$output" "$tier"
	done

	echo ""
	echo "Capabilities:"
	for line in "${results[@]}"; do
		local model_id caps best
		model_id=$(get_field "$line" 1)
		caps=$(get_field "$line" 8)
		best=$(get_field "$line" 9)
		echo "  $model_id: $caps"
		echo "    Best for: $best"
		# Pattern data badge (t1098)
		local mapped_tier
		mapped_tier=$(model_id_to_tier "$model_id")
		if [[ -n "$mapped_tier" ]]; then
			local badge
			badge=$(format_pattern_badge "$mapped_tier")
			if [[ -n "$badge" ]]; then
				echo "    Success rate: $badge (tier: $mapped_tier)"
			fi
		fi
	done

	# Cost comparison
	if [[ ${#results[@]} -ge 2 ]]; then
		echo ""
		echo "Cost Analysis (per 1M tokens):"
		local cheapest_input="" cheapest_input_price=999999
		local cheapest_output="" cheapest_output_price=999999
		for line in "${results[@]}"; do
			local model_id input output
			model_id=$(get_field "$line" 1)
			input=$(get_field "$line" 5)
			output=$(get_field "$line" 6)
			# Use awk for float comparison
			if awk "BEGIN{exit !($input < $cheapest_input_price)}"; then
				cheapest_input="$model_id"
				cheapest_input_price="$input"
			fi
			if awk "BEGIN{exit !($output < $cheapest_output_price)}"; then
				cheapest_output="$model_id"
				cheapest_output_price="$output"
			fi
		done
		echo "  Cheapest input:  $cheapest_input (\$$cheapest_input_price/1M)"
		echo "  Cheapest output: $cheapest_output (\$$cheapest_output_price/1M)"
	fi

	return 0
}

cmd_recommend() {
	local task_desc="$1"
	if [[ -z "$task_desc" ]]; then
		print_error "Usage: compare-models-helper.sh recommend <task description>"
		return 1
	fi

	local lower_task
	lower_task=$(echo "$task_desc" | tr '[:upper:]' '[:lower:]')

	echo ""
	echo "Model Recommendation"
	echo "===================="
	echo "Task: $task_desc"
	echo ""

	local found=false
	while IFS= read -r line; do
		local task_pattern recommended runner_up budget
		task_pattern=$(echo "$line" | cut -d'|' -f1)
		recommended=$(echo "$line" | cut -d'|' -f2)
		runner_up=$(echo "$line" | cut -d'|' -f3)
		budget=$(echo "$line" | cut -d'|' -f4)

		if [[ "$lower_task" == *"$task_pattern"* ]] || [[ "$task_pattern" == *"$lower_task"* ]]; then
			echo "  Recommended: $recommended"
			echo "  Runner-up:   $runner_up"
			echo "  Budget:      $budget"
			echo ""

			# Show pricing for recommended models
			for model in "$recommended" "$runner_up" "$budget"; do
				local match
				match=$(find_model "$model" | head -1)
				if [[ -n "$match" ]]; then
					local input output ctx
					input=$(get_field "$match" 5)
					output=$(get_field "$match" 6)
					ctx=$(get_field "$match" 4)
					local ctx_fmt
					ctx_fmt=$(format_context "$ctx")
					# Pattern data badge (t1098)
					local mapped_tier badge price_line
					mapped_tier=$(model_id_to_tier "$model")
					badge=$(format_pattern_badge "$mapped_tier")
					price_line="  $model: \$$input/\$$output per 1M tokens, ${ctx_fmt} context"
					if [[ -n "$badge" ]]; then
						price_line="$price_line — ${badge} success"
					fi
					echo "$price_line"
				fi
			done
			found=true
		fi
	done <<<"$TASK_RECOMMENDATIONS"

	if [[ "$found" != "true" ]]; then
		echo "No exact task match. Showing general recommendations:"
		echo ""
		echo "  High capability: claude-opus-4-6 or gpt-5.4"
		echo "  Balanced:        claude-sonnet-4-6 or gpt-5.3-codex"
		echo "  Budget:          gemini-2.5-flash or gpt-4.1-nano"
		echo "  Large context:   gemini-2.5-pro or gpt-5.3-codex"
		echo ""
		echo "Available task types:"
		echo "$TASK_RECOMMENDATIONS" | cut -d'|' -f1 | while IFS= read -r t; do
			echo "  - $t"
		done
	fi

	# Pattern-based insights (t1098)
	if has_pattern_data; then
		echo ""
		echo "Pattern Tracker Insights:"
		local pattern_lines
		pattern_lines=$(get_all_tier_patterns "")
		if [[ -n "$pattern_lines" ]]; then
			while IFS='|' read -r ptier prate psample; do
				printf "  %-10s %d%% success (n=%d)\n" "$ptier:" "$prate" "$psample"
			done <<<"$pattern_lines"
		else
			echo "  (no model-tagged patterns — record with pattern-tracker-helper.sh)"
		fi
	fi

	return 0
}

cmd_pricing() {
	echo ""
	echo "AI Model Pricing (USD per 1M tokens)"
	echo "====================================="
	echo ""
	echo "Sorted by input price (cheapest first):"
	echo ""
	printf "%-22s %-10s %-12s %-12s %-7s\n" \
		"Model" "Provider" "Input/1M" "Output/1M" "Tier"
	printf "%-22s %-10s %-12s %-12s %-7s\n" \
		"-----" "--------" "--------" "---------" "----"

	echo "$MODEL_DATA" | sort -t'|' -k5 -n | while IFS= read -r line; do
		local model_id provider input output tier
		model_id=$(get_field "$line" 1)
		provider=$(get_field "$line" 2)
		input=$(get_field "$line" 5)
		output=$(get_field "$line" 6)
		tier=$(get_field "$line" 7)
		printf "%-22s %-10s %-12s %-12s %-7s\n" \
			"$model_id" "$provider" "\$$input" "\$$output" "$tier"
	done

	echo ""
	echo "Last updated: 2025-02-08. Run /compare-models for live pricing check."
	return 0
}

cmd_context() {
	echo ""
	echo "Context Window Comparison"
	echo "========================="
	echo ""
	echo "Sorted by context window (largest first):"
	echo ""
	printf "%-22s %-10s %-12s %-12s\n" \
		"Model" "Provider" "Context" "Tokens"
	printf "%-22s %-10s %-12s %-12s\n" \
		"-----" "--------" "-------" "------"

	echo "$MODEL_DATA" | sort -t'|' -k4 -rn | while IFS= read -r line; do
		local model_id provider ctx
		model_id=$(get_field "$line" 1)
		provider=$(get_field "$line" 2)
		ctx=$(get_field "$line" 4)
		local ctx_fmt
		ctx_fmt=$(format_context "$ctx")
		printf "%-22s %-10s %-12s %-12s\n" \
			"$model_id" "$provider" "$ctx_fmt" "$ctx"
	done

	return 0
}

cmd_capabilities() {
	echo ""
	echo "Model Capability Matrix"
	echo "======================="
	echo ""
	printf "%-22s %-5s %-5s %-5s %-5s %-5s %-5s %-5s\n" \
		"Model" "Code" "Reas." "Vis." "Tools" "Math" "Srch." "Arch."
	printf "%-22s %-5s %-5s %-5s %-5s %-5s %-5s %-5s\n" \
		"-----" "----" "-----" "----" "-----" "----" "-----" "-----"

	echo "$MODEL_DATA" | while IFS= read -r line; do
		local model_id caps tier
		model_id=$(get_field "$line" 1)
		caps=$(get_field "$line" 8)
		tier=$(get_field "$line" 7)

		local has_code="--" has_reason="--" has_vision="--" has_tools="--"
		local has_math="--" has_search="--" has_arch="--"

		[[ "$caps" == *"code"* ]] && has_code="Y"
		[[ "$caps" == *"reasoning"* ]] && has_reason="Y"
		[[ "$caps" == *"vision"* ]] && has_vision="Y"
		[[ "$caps" == *"tools"* ]] && has_tools="Y"
		[[ "$caps" == *"math"* ]] && has_math="Y"
		[[ "$caps" == *"search"* ]] && has_search="Y"
		[[ "$caps" == *"architecture"* ]] && has_arch="Y"

		printf "%-22s %-5s %-5s %-5s %-5s %-5s %-5s %-5s\n" \
			"$model_id" "$has_code" "$has_reason" "$has_vision" "$has_tools" \
			"$has_math" "$has_search" "$has_arch"
	done

	echo ""
	echo "Y = supported, -- = not listed"
	echo ""
	echo "aidevops Tier Mapping:"
	echo "$TIER_MAP" | while IFS= read -r line; do
		local tier model purpose
		tier=$(echo "$line" | cut -d'|' -f1)
		model=$(echo "$line" | cut -d'|' -f2)
		purpose=$(echo "$line" | cut -d'|' -f3)
		# Pattern data badge (t1098)
		local badge
		badge=$(format_pattern_badge "$tier")
		if [[ -n "$badge" ]]; then
			printf "  %-8s -> %-22s (%s) [%s success]\n" "$tier" "$model" "$purpose" "$badge"
		else
			printf "  %-8s -> %-22s (%s)\n" "$tier" "$model" "$purpose"
		fi
	done

	return 0
}

cmd_providers() {
	echo ""
	echo "Supported Providers"
	echo "==================="
	echo ""

	local providers
	providers=$(echo "$MODEL_DATA" | cut -d'|' -f2 | sort -u)

	echo "$providers" | while IFS= read -r provider; do
		local count
		count=$(echo "$MODEL_DATA" | grep -c "|${provider}|")
		echo "  $provider ($count models)"
		echo "$MODEL_DATA" | grep "|${provider}|" | while IFS= read -r line; do
			local model_id tier
			model_id=$(get_field "$line" 1)
			tier=$(get_field "$line" 7)
			echo "    - $model_id ($tier)"
		done
		echo ""
	done

	return 0
}


# =============================================================================
# Sub-Library Imports
# =============================================================================
# Extracted for file-size compliance (GH#20398). Each sub-library has an
# include guard and a defensive SCRIPT_DIR fallback. Source order matters:
# scoring-lib defines functions used by both cross-review-lib and bench-lib.

# shellcheck source=./compare-models-scoring-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/compare-models-scoring-lib.sh"

# shellcheck source=./compare-models-cross-review-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/compare-models-cross-review-lib.sh"

# shellcheck source=./compare-models-bench-lib.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/compare-models-bench-lib.sh"

# =============================================================================
# Pattern Data Command (t1098)
# =============================================================================
# Focused view of live pattern tracker data alongside model specs.

cmd_patterns() {
	local task_type=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--task-type)
			task_type="${2:-}"
			shift 2
			;;
		*) shift ;;
		esac
	done

	echo ""
	echo "Model Performance (Live Pattern Data)"
	echo "======================================"
	echo ""

	if ! has_pattern_data; then
		echo "No pattern data available."
		echo ""
		echo "Record patterns to populate this view:"
		echo "  pattern-tracker-helper.sh record --outcome success --model standard --task-type code-review \\"
		echo "    --description \"Completed code review successfully\""
		echo ""
		echo "The supervisor also records patterns automatically after each task."
		return 0
	fi

	if [[ -n "$task_type" ]]; then
		echo "Task type filter: $task_type"
		echo ""
	fi

	# Header
	printf "  %-10s %-22s %8s %8s %10s %-12s %-12s\n" \
		"Tier" "Primary Model" "Success" "Failure" "Rate" "Input/1M" "Output/1M"
	printf "  %-10s %-22s %8s %8s %10s %-12s %-12s\n" \
		"----" "-------------" "-------" "-------" "----" "--------" "---------"

	# Iterate tiers from TIER_MAP to get primary model + pricing
	echo "$TIER_MAP" | while IFS= read -r tier_line; do
		local tier primary_model
		tier=$(echo "$tier_line" | cut -d'|' -f1)
		primary_model=$(echo "$tier_line" | cut -d'|' -f2)

		# Get pricing from MODEL_DATA
		local model_match input_price output_price
		model_match=$(echo "$MODEL_DATA" | grep "^${primary_model}|" || true)
		if [[ -n "$model_match" ]]; then
			input_price=$(get_field "$model_match" 5)
			output_price=$(get_field "$model_match" 6)
		else
			input_price="-"
			output_price="-"
		fi

		# Get pattern data via shared helper
		local counts successes failures
		counts=$(_get_tier_pattern_counts "$tier" "$task_type")
		IFS='|' read -r successes failures <<<"$counts"

		local total=$((successes + failures))
		if [[ "$total" -gt 0 ]]; then
			local rate=$(((successes * 100) / total))
			printf "  %-10s %-22s %8d %8d %9d%% %-12s %-12s\n" \
				"$tier" "$primary_model" "$successes" "$failures" "$rate" "\$$input_price" "\$$output_price"
		else
			printf "  %-10s %-22s %8s %8s %10s %-12s %-12s\n" \
				"$tier" "$primary_model" "-" "-" "no data" "\$$input_price" "\$$output_price"
		fi
	done

	echo ""

	# Overall stats
	local total_success total_failure total_all
	total_success=$(sqlite3 "$PATTERN_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('SUCCESS_PATTERN', 'WORKING_SOLUTION');" 2>/dev/null || echo "0")
	total_failure=$(sqlite3 "$PATTERN_DB" "SELECT COUNT(*) FROM learnings WHERE type IN ('FAILURE_PATTERN', 'FAILED_APPROACH', 'ERROR_FIX');" 2>/dev/null || echo "0")
	total_all=$((total_success + total_failure))

	if [[ "$total_all" -gt 0 ]]; then
		local overall_rate=$(((total_success * 100) / total_all))
		echo "  Overall: ${overall_rate}% success rate ($total_success/$total_all patterns)"
	fi

	echo ""
	echo "Data source: pattern-tracker-helper.sh (memory.db)"
	echo "Record more: pattern-tracker-helper.sh record --outcome success --model <tier> ..."
	echo ""
	return 0
}

cmd_help() {
	echo ""
	echo "Compare Models Helper - AI Model Capability Comparison"
	echo "======================================================="
	echo ""
	echo "Usage: compare-models-helper.sh [command] [options]"
	echo ""
	echo "Commands:"
	echo "  list          List all tracked models with pricing"
	echo "  compare       Compare specific models side-by-side"
	echo "  recommend     Recommend models for a task type"
	echo "  pricing       Show pricing table (sorted by cost)"
	echo "  context       Show context window comparison"
	echo "  capabilities  Show capability matrix"
	echo "  patterns      Show live success rates from pattern tracker (t1098)"
	echo "  providers     List supported providers and their models"
	echo "  discover      Detect available providers from local config"
	echo "  score         Record model comparison scores (from evaluation)"
	echo "  results       View past comparison results and rankings"
	echo "  cross-review  Dispatch same prompt to multiple models, diff results"
	echo "  bench         Live benchmark: send same prompt to N models, compare outputs (t1393)"
	echo "  help          Show this help"
	echo ""
	echo "Examples:"
	echo "  compare-models-helper.sh list"
	echo "  compare-models-helper.sh compare standard gpt-4o gemini-pro"
	echo "  compare-models-helper.sh recommend \"code review\""
	echo "  compare-models-helper.sh pricing"
	echo "  compare-models-helper.sh capabilities"
	echo "  compare-models-helper.sh discover"
	echo "  compare-models-helper.sh discover --probe"
	echo "  compare-models-helper.sh discover --list-models"
	echo "  compare-models-helper.sh discover --json"
	echo ""
	echo "Pattern examples:"
	echo "  compare-models-helper.sh patterns"
	echo "  compare-models-helper.sh patterns --task-type code-review"
	echo ""
	echo "Scoring examples:"
	echo "  compare-models-helper.sh score --task 'fix React bug' --type code \\"
	echo "    --model claude-sonnet-4-6 --correctness 9 --completeness 8 --quality 8 --clarity 9 --adherence 9 \\"
	echo "    --model gpt-5.3-codex --correctness 8 --completeness 7 --quality 7 --clarity 8 --adherence 8 \\"
	echo "    --winner claude-sonnet-4-6"
	echo "  compare-models-helper.sh score --task 'review code' --prompt-file prompts/build.txt \\"
	echo "    --model standard --correctness 9 --completeness 8 --quality 8 --clarity 9 --adherence 9"
	echo "  compare-models-helper.sh results"
	echo "  compare-models-helper.sh results --model standard --limit 5"
	echo "  compare-models-helper.sh results --prompt-version a1b2c3d"
	echo ""
	echo "Discover options:"
	echo "  --probe        Verify API keys by calling provider endpoints"
	echo "  --list-models  List live models from each verified provider"
	echo "  --json         Output discovery results as JSON"
	echo ""
	echo "Cross-review examples:"
	echo "  compare-models-helper.sh cross-review \\"
	echo "    --prompt 'Review this code for security issues: ...'"
	echo "    # defaults to all configured standard-tier models"
	echo "  compare-models-helper.sh cross-review \\"
	echo "    --prompt 'Audit the architecture of this project' \\"
	echo "    --models 'openai/gpt-5.6-sol,anthropic/claude-sonnet-4-6' --timeout 900"
	echo "  compare-models-helper.sh cross-review \\"
	echo "    --prompt 'Review this PR diff' \\"
	echo "    --score                          # auto-score via judge model (default: thinking)"
	echo "  compare-models-helper.sh cross-review \\"
	echo "    --prompt 'Review this PR diff' \\"
	echo "    --score --judge standard          # use the standard workload tier as judge"
	echo "  compare-models-helper.sh cross-review \\"
	echo "    --prompt 'Review this code' \\"
	echo "    --prompt-file prompts/build.txt   # track prompt version in results"
	echo ""
	echo "Bench examples (t1393):"
	echo "  compare-models-helper.sh bench 'What is 2+2?' claude-sonnet-4-6 gpt-4o"
	echo "  compare-models-helper.sh bench 'Explain quicksort' claude-sonnet-4-6 gpt-5.3-codex gemini-2.5-pro --judge"
	echo "  compare-models-helper.sh bench --dataset prompts.jsonl claude-sonnet-4-6 gpt-4o --judge"
	echo "  compare-models-helper.sh bench 'What is 2+2?' claude-sonnet-4-6 --dry-run"
	echo "  compare-models-helper.sh bench --history --limit 10"
	echo ""
	echo "Data is embedded in this script. Last updated: 2025-02-08."
	echo "For live pricing, use /compare-models (with web fetch)."
	return 0
}


# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	list)
		cmd_list
		;;
	compare)
		cmd_compare "$@"
		;;
	recommend)
		cmd_recommend "${*:-}"
		;;
	pricing)
		cmd_pricing
		;;
	context)
		cmd_context
		;;
	capabilities)
		cmd_capabilities
		;;
	patterns)
		cmd_patterns "$@"
		;;
	providers)
		cmd_providers
		;;
	discover)
		cmd_discover "$@"
		;;
	score)
		cmd_score "$@"
		;;
	results)
		cmd_results "$@"
		;;
	cross-review)
		cmd_cross_review "$@"
		;;
	bench)
		cmd_bench "$@"
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
