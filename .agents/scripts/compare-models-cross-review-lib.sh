#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Compare Models — Cross-Model Review Library (t132.8)
# =============================================================================
# Cross-model review: dispatch the same review prompt to multiple models,
# collect results, diff, and optionally score with an LLM judge.
#
# Usage: source "${SCRIPT_DIR}/compare-models-cross-review-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_warning, print_success, resolve_model_tier)
#   - compare-models-scoring-lib.sh (cmd_score, for judge recording)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_COMPARE_MODELS_CROSS_REVIEW_LIB_LOADED:-}" ]] && return 0
_COMPARE_MODELS_CROSS_REVIEW_LIB_LOADED=1

# Defensive SCRIPT_DIR fallback
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# Convert a tier or provider/model identifier into a path-safe, injective key.
# Args: model identifier
_cross_review_model_key() {
	local model="$1"
	if [[ ! "$model" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*(/[A-Za-z0-9][A-Za-z0-9._:-]*)*$ ]]; then
		return 1
	fi
	local key="" char="" char_code="" index=0
	while [[ "$index" -lt "${#model}" ]]; do
		char="${model:index:1}"
		case "$char" in
		[a-z0-9._-]) key+="$char" ;;
		*)
			printf -v char_code '%02X' "'$char"
			key+="%${char_code}"
			;;
		esac
		index=$((index + 1))
	done
	printf '%s\n' "$key"
	return 0
}

# Build a runner-helper-compatible name without embedding a provider/model ID.
# Args: role (model|judge), numeric ordinal
_cross_review_runner_name() {
	local role="$1"
	local ordinal="$2"
	local role_key=""
	case "$role" in
	model) role_key="m" ;;
	judge) role_key="j" ;;
	*) return 1 ;;
	esac
	if [[ ! "$ordinal" =~ ^[0-9]+$ ]]; then
		return 1
	fi
	local runner_name="cross-review-${role_key}${ordinal}-$$"
	if [[ ${#runner_name} -gt 40 ]]; then
		return 1
	fi
	printf '%s\n' "$runner_name"
	return 0
}

# Return the active routing table's concrete models for one workload tier.
# Args: simple|standard|thinking
_cross_review_models_for_tier() {
	local tier="$1"
	local default_table="${SCRIPT_DIR}/../configs/model-routing-table.json"
	local custom_table="${SCRIPT_DIR}/../custom/configs/model-routing-table.json"
	local table_path="${CROSS_REVIEW_ROUTING_TABLE:-$default_table}"
	local models="" joined="" model="" count=0

	if [[ ! "$tier" =~ ^(simple|standard|thinking)$ ]]; then
		return 1
	fi
	if [[ -z "${CROSS_REVIEW_ROUTING_TABLE:-}" && -f "$custom_table" ]]; then
		table_path="$custom_table"
	fi
	if [[ ! -r "$table_path" ]]; then
		return 1
	fi

	models=$(jq -r --arg tier "$tier" '.tiers[$tier].models[]?' "$table_path" 2>/dev/null) || return 1
	while IFS= read -r model; do
		[[ -z "$model" ]] && continue
		_cross_review_model_key "$model" >/dev/null || return 1
		if [[ -n "$joined" ]]; then
			joined+=","
		fi
		joined+="$model"
		count=$((count + 1))
	done <<<"$models"

	if [[ "$count" -lt 2 ]]; then
		return 1
	fi
	printf '%s\n' "$joined"
	return 0
}

# Build judge prompt from model outputs
# Args: output_dir, max_chars_per_model, original_prompt, model_names array
# Output: judge_prompt, models_with_output array
_judge_build_prompt() {
	local output_dir="$1"
	local max_chars_per_model="$2"
	local original_prompt="$3"
	shift 3
	local -a model_names=("$@")

	local judge_prompt
	judge_prompt="You are a neutral judge evaluating AI model responses. Score each response on a 1-10 scale.

ORIGINAL PROMPT:
${original_prompt}

MODEL RESPONSES:
"
	local models_with_output=()
	for model_tier in "${model_names[@]}"; do
		local model_key
		model_key=$(_cross_review_model_key "$model_tier") || continue
		local result_file="${output_dir}/${model_key}.txt"
		if [[ -f "$result_file" && -s "$result_file" ]]; then
			local response_text
			response_text=$(head -c "$max_chars_per_model" "$result_file")
			local file_size
			file_size=$(wc -c <"$result_file" | tr -d ' ')
			local truncated_marker=""
			if [[ "$file_size" -gt "$max_chars_per_model" ]]; then
				truncated_marker="
[TRUNCATED — original ${file_size} chars, showing first ${max_chars_per_model}]"
			fi
			judge_prompt+="
=== MODEL: ${model_tier} ===
${response_text}${truncated_marker}
"
			models_with_output+=("$model_tier")
		fi
	done

	echo "$judge_prompt"
	return 0
}

# Dispatch judge model and extract JSON output
_judge_dispatch() {
	local judge_model="$1"
	local judge_prompt="$2"
	local output_dir="$3"

	local runner_helper="${SCRIPT_DIR}/runner-helper.sh"
	[[ ! -x "$runner_helper" ]] && return 1

	local judge_key
	judge_key=$(_cross_review_model_key "$judge_model") || return 1
	local judge_runner
	judge_runner=$(_cross_review_runner_name judge 0) || return 1
	local judge_output_file="${output_dir}/judge-${judge_key}.json"
	local judge_err_log="${output_dir}/judge-errors.log"

	echo "  Dispatching to judge (${judge_model})..."

	"$runner_helper" create "$judge_runner" \
		--model "$judge_model" \
		--description "Cross-review judge" \
		--workdir "$(pwd)" 2>>"$judge_err_log" || true

	"$runner_helper" run "$judge_runner" "$judge_prompt" \
		--model "$judge_model" \
		--timeout "120" \
		--format text >"$judge_output_file" 2>>"$judge_err_log" || true

	"$runner_helper" destroy "$judge_runner" --force 2>>"$judge_err_log" || true

	[[ ! -f "$judge_output_file" || ! -s "$judge_output_file" ]] && return 1

	# Extract JSON from judge output
	local judge_json
	judge_json=$(grep -o '{.*}' "$judge_output_file" 2>>"$judge_err_log" | head -1 || true)
	if [[ -z "$judge_json" ]]; then
		judge_json=$(python3 -c "
import sys, json, re
text = sys.stdin.read()
m = re.search(r'\{.*\}', text, re.DOTALL)
if m:
    try:
        obj = json.loads(m.group())
        print(json.dumps(obj))
    except Exception:
        pass
" <"$judge_output_file" 2>>"$judge_err_log" || true)
	fi

	[[ -z "$judge_json" ]] && return 1
	echo "$judge_json"
	return 0
}

# Clamp a numeric value to integer in range 0-10
_clamp_score() {
	local val="$1"
	if [[ ! "$val" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
		echo "0"
		return 0
	fi
	local int_val
	int_val=$(printf '%.0f' "$val" 2>/dev/null || echo "0")
	if [[ "$int_val" -gt 10 ]]; then
		echo "10"
	elif [[ "$int_val" -lt 0 ]]; then
		echo "0"
	else
		echo "$int_val"
	fi
	return 0
}

# Return the scoring instructions block appended to judge prompts.
_judge_scoring_instructions() {
	cat <<'INSTRUCTIONS'

SCORING INSTRUCTIONS:
Score each model on these criteria (1-10 scale):
- correctness: Factual accuracy and technical correctness
- completeness: Coverage of all requirements and edge cases
- quality: Code quality, best practices, maintainability
- clarity: Clear explanation, good formatting, readability
- adherence: Following the original prompt instructions precisely

Respond with ONLY a valid JSON object in this exact format (no markdown, no explanation):
{
  "task_type": "general",
  "winner": "<model_tier_of_best_response>",
  "reasoning": "<one sentence explaining the winner>",
  "scores": {
    "<model_tier>": {
      "correctness": <1-10>,
      "completeness": <1-10>,
      "quality": <1-10>,
      "clarity": <1-10>,
      "adherence": <1-10>
    }
  }
}
INSTRUCTIONS
	return 0
}

# Parse winner, task_type, and reasoning from judge JSON.
# Outputs three lines: winner, task_type, reasoning.
# Args: judge_json err_log
_judge_parse_json_fields() {
	local judge_json="$1"
	local err_log="$2"
	echo "$judge_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
r = d.get('reasoning', '')[:500]
r = ''.join(c for c in r if c.isprintable() or c in (' ', '\t'))
print(d.get('winner', ''))
print(d.get('task_type', 'general'))
print(r)
" 2>>"$err_log" || true
	return 0
}

# Sanitize task_type against known allowlist; echoes validated value.
# Args: task_type
_judge_validate_task_type() {
	local task_type="$1"
	local -a valid_task_types=(general code review analysis debug refactor test docs security)
	local vt
	for vt in "${valid_task_types[@]}"; do
		if [[ "$task_type" == "$vt" ]]; then
			echo "$task_type"
			return 0
		fi
	done
	echo "general"
	return 0
}

# Sanitize winner against models_with_output list; echoes validated value or empty.
# Args: winner models_with_output...
_judge_validate_winner() {
	local winner="$1"
	shift
	local -a models_with_output=("$@")
	if [[ -z "$winner" ]]; then
		return 0
	fi
	local m
	for m in "${models_with_output[@]}"; do
		if [[ "$winner" == "$m" ]]; then
			echo "$winner"
			return 0
		fi
	done
	print_warning "Judge returned unknown winner '${winner}' — ignoring"
	return 0
}

# Append per-model score args to score_args array from judge JSON.
# Args: arg1=judge_json arg2=err_log arg3+=models_with_output
# Outputs one line per model: "--model M --correctness C ..."
_judge_build_score_args() {
	local judge_json="$1"
	local err_log="$2"
	shift 2
	local -a models_with_output=("$@")
	local model_tier
	for model_tier in "${models_with_output[@]}"; do
		local scores_line
		scores_line=$(echo "$judge_json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
s = d.get('scores', {}).get('${model_tier}', {})
print(s.get('correctness', 0), s.get('completeness', 0), s.get('quality', 0), s.get('clarity', 0), s.get('adherence', 0))
" 2>>"$err_log" || echo "0 0 0 0 0")
		local corr comp qual clar adhr
		read -r corr comp qual clar adhr <<<"$scores_line"
		corr=$(_clamp_score "$corr")
		comp=$(_clamp_score "$comp")
		qual=$(_clamp_score "$qual")
		clar=$(_clamp_score "$clar")
		adhr=$(_clamp_score "$adhr")
		echo "--model ${model_tier} --correctness ${corr} --completeness ${comp} --quality ${qual} --clarity ${clar} --adherence ${adhr}"
	done
	return 0
}

# Judge scoring for cross-review (t1329)
# Dispatches all model outputs to a judge model, parses structured JSON scores,
# records results via cmd_score, and feeds into the pattern tracker.
# Defined before cmd_cross_review (its caller) for readability.
#
# Args:
#   arg1 - original prompt
#   arg2 - models_str (comma-separated)
#   arg3 - output_dir
#   arg4 - judge_model tier
#   arg5 - prompt_version (may be empty)
#   arg6 - prompt_file (may be empty)
#   arg7+ - model_names array
# Record judge scores: parse JSON, build score_args, call cmd_score.
# Args: arg1=judge_json arg2=judge_err_log arg3=original_prompt arg4=task_type arg5=winner
#       arg6=judge_model arg7=prompt_version arg8=prompt_file arg9+=models_with_output
_judge_record_scores() {
	local judge_json="$1"
	local judge_err_log="$2"
	local original_prompt="$3"
	local task_type="$4"
	local winner="$5"
	local judge_model="$6"
	local prompt_version="$7"
	local prompt_file="$8"
	shift 8
	local -a models_with_output=("$@")

	local -a score_args=(
		--task "$original_prompt"
		--type "$task_type"
		--evaluator "$judge_model"
	)
	[[ -n "$winner" ]] && score_args+=(--winner "$winner")
	[[ -n "$prompt_version" ]] && score_args+=(--prompt-version "$prompt_version")
	[[ -n "$prompt_file" ]] && score_args+=(--prompt-file "$prompt_file")

	local score_line
	while IFS= read -r score_line; do
		[[ -z "$score_line" ]] && continue
		# shellcheck disable=SC2206
		local -a line_args=($score_line)
		score_args+=("${line_args[@]}")
	done < <(_judge_build_score_args "$judge_json" "$judge_err_log" "${models_with_output[@]}")

	cmd_score "${score_args[@]}"
	return 0
}

_cross_review_judge_score() {
	local original_prompt="$1"
	local models_str="$2"
	local output_dir="$3"
	local judge_model="$4"
	local prompt_version="$5"
	local prompt_file="$6"
	shift 6
	local -a model_names=("$@")
	local judge_err_log="${output_dir}/judge-errors.log"
	local judge_key
	if ! judge_key=$(_cross_review_model_key "$judge_model"); then
		print_error "Invalid judge model identifier: $judge_model"
		return 1
	fi
	local judge_output_file="${output_dir}/judge-${judge_key}.json"
	if [[ ! -x "${SCRIPT_DIR}/runner-helper.sh" ]]; then
		print_warning "runner-helper.sh not found — skipping judge scoring"
		return 0
	fi

	echo "=== JUDGE SCORING (${judge_model}) ==="
	echo ""

	# Build judge prompt from model outputs
	local judge_prompt
	judge_prompt=$(_judge_build_prompt "$output_dir" "20000" "$original_prompt" "${model_names[@]}")

	# Collect models that produced output
	local -a models_with_output=()
	local model_tier
	for model_tier in "${model_names[@]}"; do
		local model_key
		model_key=$(_cross_review_model_key "$model_tier") || continue
		[[ -f "${output_dir}/${model_key}.txt" && -s "${output_dir}/${model_key}.txt" ]] &&
			models_with_output+=("$model_tier")
	done
	if [[ ${#models_with_output[@]} -lt 2 ]]; then
		print_warning "Not enough model outputs for judge scoring (need 2+)"
		return 0
	fi

	judge_prompt+=$(_judge_scoring_instructions)

	local judge_json
	judge_json=$(_judge_dispatch "$judge_model" "$judge_prompt" "$output_dir") || {
		print_warning "Could not parse judge JSON output. Check ${output_dir}/judge-errors.log"
		return 0
	}

	# Parse and sanitize winner/task_type/reasoning
	local parsed_fields winner task_type reasoning
	parsed_fields=$(_judge_parse_json_fields "$judge_json" "$judge_err_log")
	if [[ -n "$parsed_fields" ]]; then
		winner=$(echo "$parsed_fields" | head -1)
		task_type=$(echo "$parsed_fields" | sed -n '2p')
		reasoning=$(echo "$parsed_fields" | sed -n '3p')
	else
		winner="" task_type="general" reasoning=""
	fi
	task_type=$(_judge_validate_task_type "$task_type")
	winner=$(_judge_validate_winner "$winner" "${models_with_output[@]}")

	echo "  Judge winner: ${winner:-unknown}"
	[[ -n "$reasoning" ]] && echo "  Reasoning: ${reasoning}"
	echo ""

	_judge_record_scores "$judge_json" "$judge_err_log" "$original_prompt" \
		"$task_type" "$winner" "$judge_model" "$prompt_version" "$prompt_file" \
		"${models_with_output[@]}"

	echo "Judge scores recorded. Judge output: $judge_output_file"
	echo ""
	return 0
}

#######################################
# Cross-model review: dispatch same prompt to multiple models (t132.8, t1329)
# Usage: compare-models-helper.sh cross-review --prompt "review this code" \
#          [--models "provider/model-a,provider/model-b"] [--workdir path]
#          [--timeout N] [--output dir]
#          [--score] [--judge <model>]
# Dispatches via runner-helper.sh in parallel, collects outputs, produces summary.
# With --score: feeds outputs to a thinking-tier judge for structured scoring
# and records results in the model-comparisons DB + pattern tracker.
#######################################

# Parse arguments for cmd_cross_review
# Bash 3.2 compatible: printf -v for scalar writes, ${!var} for reads.
_cross_review_parse_args() {
	local _r_prompt="$1" _r_models="$2" _r_workdir="$3" _r_timeout="$4"
	local _r_output="$5" _r_score="$6" _r_judge="$7" _r_version="$8" _r_file="$9"
	shift 9
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--prompt)
			[[ $# -lt 2 ]] && { print_error "--prompt requires a value"; return 1; }
			printf -v "$_r_prompt" '%s' "$2"; shift 2 ;;
		--models)
			[[ $# -lt 2 ]] && { print_error "--models requires a value"; return 1; }
			printf -v "$_r_models" '%s' "$2"; shift 2 ;;
		--workdir)
			[[ $# -lt 2 ]] && { print_error "--workdir requires a value"; return 1; }
			printf -v "$_r_workdir" '%s' "$2"; shift 2 ;;
		--timeout)
			[[ $# -lt 2 ]] && { print_error "--timeout requires a value"; return 1; }
			printf -v "$_r_timeout" '%s' "$2"; shift 2 ;;
		--output)
			[[ $# -lt 2 ]] && { print_error "--output requires a value"; return 1; }
			printf -v "$_r_output" '%s' "$2"; shift 2 ;;
		--score)
			printf -v "$_r_score" '%s' true; shift ;;
		--judge)
			[[ $# -lt 2 ]] && { print_error "--judge requires a value"; return 1; }
			local _judge_val="$2"
			if ! _cross_review_model_key "$_judge_val" >/dev/null; then
				print_error "Invalid judge model identifier: $_judge_val"
				return 1
			fi
			printf -v "$_r_judge" '%s' "$_judge_val"; shift 2 ;;
		--prompt-version)
			[[ $# -lt 2 ]] && { print_error "--prompt-version requires a value"; return 1; }
			printf -v "$_r_version" '%s' "$2"; shift 2 ;;
		--prompt-file)
			[[ $# -lt 2 ]] && { print_error "--prompt-file requires a value"; return 1; }
			printf -v "$_r_file" '%s' "$2"; shift 2 ;;
		*)
			print_error "Unknown option: $1"; return 1 ;;
		esac
	done
	return 0
}

# Display diff summary for cross-review results
_cross_review_show_diff() {
	local output_dir="$1"
	shift
	local -a model_names=("$@")

	# Word count comparison
	echo "Response sizes:"
	for model_tier in "${model_names[@]}"; do
		local model_key
		model_key=$(_cross_review_model_key "$model_tier") || continue
		local result_file="${output_dir}/${model_key}.txt"
		if [[ -f "$result_file" && -s "$result_file" ]]; then
			local wc_result
			wc_result=$(wc -w <"$result_file" | tr -d ' ')
			echo "  ${model_tier}: ${wc_result} words"
		fi
	done
	echo ""

	# If exactly 2 models, show a simple diff
	if [[ ${#model_names[@]} -eq 2 ]]; then
		local key_a key_b
		key_a=$(_cross_review_model_key "${model_names[0]}") || return 1
		key_b=$(_cross_review_model_key "${model_names[1]}") || return 1
		local file_a="${output_dir}/${key_a}.txt"
		local file_b="${output_dir}/${key_b}.txt"
		if [[ -f "$file_a" && -f "$file_b" ]]; then
			echo "Diff (${model_names[0]} vs ${model_names[1]}):"
			local diff_output diff_status
			diff_output=$(diff --unified=3 "$file_a" "$file_b" 2>/dev/null) && diff_status=$? || diff_status=$?
			if [[ "$diff_status" -le 1 && -n "$diff_output" ]]; then
				echo "$diff_output" | head -100
			else
				echo "  (files are identical or diff unavailable)"
			fi
			echo ""
		fi
	fi
	return 0
}

# Dispatch one model in a subshell for cross-review; writes result to output_dir.
# Args: arg1=runner_helper arg2=runner_name arg3=model_tier arg4=prompt arg5=review_timeout arg6=workdir arg7=output_dir
_cross_review_dispatch_one() {
	local runner_helper="$1"
	local runner_name="$2"
	local model_tier="$3"
	local prompt="$4"
	local review_timeout="$5"
	local workdir="$6"
	local output_dir="$7"
	local model_key
	model_key=$(_cross_review_model_key "$model_tier") || return 1
	local model_err_log="${output_dir}/${model_key}-errors.log"
	local result_file="${output_dir}/${model_key}.txt"
	local model_failed=0

	"$runner_helper" create "$runner_name" \
		--model "$model_tier" \
		--description "Cross-review: $model_tier" \
		--workdir "$workdir" 2>>"$model_err_log" || model_failed=1

	"$runner_helper" run "$runner_name" "$prompt" \
		--model "$model_tier" \
		--timeout "$review_timeout" \
		--format json 2>>"$model_err_log" >"${output_dir}/${model_key}.json" || model_failed=1

	# Extract text response from JSON
	if [[ -f "${output_dir}/${model_key}.json" ]]; then
		jq -r '.parts[]? | select(.type == "text") | .text' \
			"${output_dir}/${model_key}.json" 2>>"$model_err_log" >"$result_file" || model_failed=1
	fi

	# Clean up runner (always attempt cleanup, even on failure)
	"$runner_helper" destroy "$runner_name" --force 2>>"$model_err_log" || true

	# Fail if no usable output was produced
	[[ -s "$result_file" ]] || model_failed=1
	return "$model_failed"
}

# Wait for parallel pids and report per-model status.
# Args: arg1=output_dir; remaining args alternate: pid model_name ...
# Outputs count of failures to stdout as last line "failed=N".
_cross_review_wait_results() {
	local output_dir="$1"
	shift
	local failed=0
	while [[ $# -ge 2 ]]; do
		local pid="$1"
		local model_name="$2"
		shift 2
		if ! wait "$pid" 2>/dev/null; then
			local model_key
			model_key=$(_cross_review_model_key "$model_name") || model_key="invalid-model"
			local err_log="${output_dir}/${model_key}-errors.log"
			echo "  ${model_name}: failed (see ${err_log})"
			failed=$((failed + 1))
		else
			echo "  ${model_name}: done"
		fi
	done
	echo "failed=${failed}"
	return 0
}

cmd_cross_review() {
	local prompt="" models_str="" workdir="" review_timeout="600" output_dir=""
	local score_flag=false judge_model="thinking"
	local prompt_version="" prompt_file=""

	# Parse arguments
	_cross_review_parse_args prompt models_str workdir review_timeout output_dir score_flag judge_model prompt_version prompt_file "$@" || return 1

	if [[ -z "$prompt" ]]; then
		print_error "--prompt is required"
		echo "Usage: compare-models-helper.sh cross-review --prompt \"review this code\" [--models \"provider/model-a,provider/model-b\"]"
		return 1
	fi

	# Default: compare every configured standard-tier model on the same workload.
	if [[ -z "$models_str" ]]; then
		models_str=$(_cross_review_models_for_tier standard) || {
			print_error "The standard routing tier must contain at least two valid models; pass --models explicitly"
			return 1
		}
	fi

	# Set up output directory and workdir
	[[ -z "$output_dir" ]] && output_dir="${HOME}/.aidevops/.agent-workspace/tmp/cross-review-$(date +%Y%m%d%H%M%S)"
	mkdir -p "$output_dir"
	[[ -z "$workdir" ]] && workdir="$(pwd)"

	local runner_helper="${SCRIPT_DIR}/runner-helper.sh"
	if [[ ! -x "$runner_helper" ]]; then
		print_error "runner-helper.sh not found at $runner_helper"
		return 1
	fi

	# Parse and validate models list
	local -a model_array=()
	IFS=',' read -ra model_array <<<"$models_str"
	if [[ ${#model_array[@]} -lt 2 ]]; then
		print_error "At least 2 models required for cross-review (got ${#model_array[@]})"
		return 1
	fi

	echo ""
	echo "Cross-Model Review"
	echo "==================="
	echo "Models: ${models_str}"
	echo "Output: ${output_dir}"
	echo "Timeout: ${review_timeout}s per model"
	echo ""

	# Dispatch all models in parallel and wait
	local -a model_names=()
	_cross_review_dispatch_all "$runner_helper" "$prompt" "$review_timeout" \
		"$workdir" "$output_dir" model_names "${model_array[@]}"

	# Collect and display results
	local results_found=0
	local model_tier
	for model_tier in "${model_names[@]}"; do
		local model_key
		model_key=$(_cross_review_model_key "$model_tier") || continue
		local result_file="${output_dir}/${model_key}.txt"
		if [[ -f "$result_file" && -s "$result_file" ]]; then
			results_found=$((results_found + 1))
			echo "=== ${model_tier} ==="
			echo ""
			cat "$result_file"
			echo ""
			echo "---"
			echo ""
		fi
	done

	if [[ "$results_found" -lt 2 ]]; then
		print_warning "Only $results_found model(s) returned results. Need at least 2 for comparison."
		echo "Check output directory: $output_dir"
		return 1
	fi

	# Generate diff summary
	echo "=== DIFF SUMMARY ==="
	echo ""
	echo "Models compared: ${models_str}"
	echo "Results: ${results_found}/${#model_names[@]} successful"
	echo ""
	_cross_review_show_diff "$output_dir" "${model_names[@]}"
	echo "Full results saved to: $output_dir"
	echo ""

	# Judge scoring pipeline (t1329)
	if [[ "$score_flag" == "true" ]]; then
		_cross_review_judge_score \
			"$prompt" "$models_str" "$output_dir" "$judge_model" \
			"$prompt_version" "$prompt_file" "${model_names[@]}"
	fi

	return 0
}

# Dispatch all models in parallel and wait for completion.
# Populates the array (passed by name) with validated model names.
# Args: arg1=runner_helper arg2=prompt arg3=timeout arg4=workdir arg5=output_dir arg6=array_name arg7+=model_array
# Bash 3.2 compatible: uses eval for array ops instead of local -n nameref.
_cross_review_dispatch_all() {
	local runner_helper="$1"
	local prompt="$2"
	local review_timeout="$3"
	local workdir="$4"
	local output_dir="$5"
	local _r_model_names="$6"
	shift 6
	local -a model_array=("$@")

	local -a pids=()
	local model_tier model_ordinal=0
	for model_tier in "${model_array[@]}"; do
		model_tier="${model_tier// /}"
		[[ -z "$model_tier" ]] && continue
		local model_key
		if ! model_key=$(_cross_review_model_key "$model_tier"); then
			print_warning "Skipping invalid model identifier: $model_tier"
			continue
		fi
		model_ordinal=$((model_ordinal + 1))
		local runner_name
		runner_name=$(_cross_review_runner_name model "$model_ordinal") || return 1
		eval "${_r_model_names}+=(\"\$model_tier\")"
		local resolved_model
		resolved_model=$(resolve_model_tier "$model_tier")
		echo "  Dispatching to ${model_tier} (${resolved_model})..."
		_cross_review_dispatch_one "$runner_helper" "$runner_name" "$model_tier" \
			"$prompt" "$review_timeout" "$workdir" "$output_dir" &
		pids+=($!)
	done

	echo ""
	echo "Waiting for ${#pids[@]} models to respond..."
	local -a wait_args=()
	local i _name
	for i in "${!pids[@]}"; do
		eval "_name=\${${_r_model_names}[$i]}"
		wait_args+=("${pids[$i]}" "$_name")
	done
	local wait_output
	wait_output=$(_cross_review_wait_results "$output_dir" "${wait_args[@]}")
	echo "$wait_output" | grep -v '^failed='
	echo ""
	return 0
}
