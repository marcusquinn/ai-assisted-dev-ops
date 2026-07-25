#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# comprehension-benchmark-helper.sh — Benchmark instruction comprehension across workload tiers
# Resolves simple/standard/thinking through the runtime model mapping, using
# deterministic scoring first and model adjudication second.
#
# Usage:
#   comprehension-benchmark-helper.sh test <scenario.yaml>     # Test one file
#   comprehension-benchmark-helper.sh sweep                     # Run all tests
#   comprehension-benchmark-helper.sh report                    # Generate summary
#   comprehension-benchmark-helper.sh update-state              # Write tier_minimum to state
#   comprehension-benchmark-helper.sh pre-filter <agent.md>     # Structural heuristics only
#
# Exit codes: 0=expected tier matched, 1=error, unresolved scenario, or mismatch

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)" || exit 1
TESTS_DIR="${COMPREHENSION_TESTS_DIR:-${REPO_ROOT}/.agents/tests/comprehension}"
STATE_FILE="${COMPREHENSION_STATE_FILE:-${REPO_ROOT}/.agents/configs/simplification-state.json}"
RESULTS_DIR="${COMPREHENSION_RESULTS_DIR:-${TESTS_DIR}/results}"
AI_RESEARCH_HELPER="${COMPREHENSION_AI_HELPER:-${SCRIPT_DIR}/ai-research-helper.sh}"

# Source shared constants if available
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=shared-constants.sh
	source "${SCRIPT_DIR}/shared-constants.sh"
fi

# Logging
log_info() {
	local msg="$1"
	echo "[BENCH] $msg" >&2
	return 0
}
log_error() {
	local msg="$1"
	echo "[BENCH:ERROR] $msg" >&2
	return 0
}
log_pass() {
	local msg="$1"
	echo "[BENCH:PASS] $msg" >&2
	return 0
}
log_fail() {
	local msg="$1"
	echo "[BENCH:FAIL] $msg" >&2
	return 0
}

# Tier ordering for escalation
tier_order() {
	local tier="$1"
	case "$tier" in
	simple) echo 1 ;;
	standard) echo 2 ;;
	thinking) echo 3 ;;
	*) echo 0 ;;
	esac
	return 0
}

tier_name() {
	local order="$1"
	case "$order" in
	1) echo "simple" ;;
	2) echo "standard" ;;
	3) echo "thinking" ;;
	*) echo "unknown" ;;
	esac
	return 0
}

#######################################
# Parse YAML scenario file using python3
# Arguments: $1 — path to YAML file
# Output: JSON on stdout
# Returns: 0 on success, 1 on failure
#######################################
parse_yaml() {
	local yaml_file="$1"
	if [[ ! -f "$yaml_file" ]]; then
		log_error "Scenario file not found: $yaml_file"
		return 1
	fi
	python3 -c "
import sys, yaml, json
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
print(json.dumps(data))
" "$yaml_file" 2>/dev/null || {
		log_error "Failed to parse YAML: $yaml_file"
		return 1
	}
	return 0
}

#######################################
# Structural pre-filter: cheap heuristics before model calls
# Arguments: $1 — path to agent file
# Output: complexity rating (simple|moderate|complex) on stdout
# Returns: 0 always
#######################################
pre_filter() {
	local agent_file="$1"
	if [[ ! -f "$agent_file" ]]; then
		echo "unknown"
		return 0
	fi

	local line_count
	line_count="$(wc -l <"$agent_file" 2>/dev/null)" || line_count=0
	line_count="${line_count// /}"

	local cross_refs
	cross_refs="$(grep -cE '\.(md|sh|json|yaml|txt)' "$agent_file" 2>/dev/null)" || cross_refs=0

	local code_blocks
	code_blocks="$(grep -c '```' "$agent_file" 2>/dev/null)" || code_blocks=0

	local table_rows
	table_rows="$(grep -cE '^\|' "$agent_file" 2>/dev/null)" || table_rows=0

	local nesting_depth
	nesting_depth="$(grep -cE '^#{3,}' "$agent_file" 2>/dev/null)" || nesting_depth=0

	# Scoring: simple < 50 lines, few refs; complex > 120 lines or many refs
	local score=0
	if [[ "$line_count" -gt 120 ]]; then score=$((score + 3)); fi
	if [[ "$line_count" -gt 60 ]]; then score=$((score + 1)); fi
	if [[ "$cross_refs" -gt 10 ]]; then score=$((score + 2)); fi
	if [[ "$cross_refs" -gt 5 ]]; then score=$((score + 1)); fi
	if [[ "$code_blocks" -gt 6 ]]; then score=$((score + 1)); fi
	if [[ "$table_rows" -gt 10 ]]; then score=$((score + 1)); fi
	if [[ "$nesting_depth" -gt 5 ]]; then score=$((score + 1)); fi

	if [[ "$score" -le 2 ]]; then
		echo "simple"
	elif [[ "$score" -le 5 ]]; then
		echo "moderate"
	else
		echo "complex"
	fi
	return 0
}

# Python helper directory
LIB_DIR="${SCRIPT_DIR}/comprehension-lib"

#######################################
# Run deterministic checks on model output
# Arguments: $1 — model output, $2 — expected JSON
# Output: JSON result on stdout
# Returns: 0=pass, 1=fail, 2=ambiguous
#######################################
deterministic_check() {
	local output="$1"
	local expected_json="$2"

	python3 "${LIB_DIR}/deterministic_check.py" "$output" "$expected_json" 2>/dev/null || {
		echo '{"pass": false, "checks": [], "ambiguous": true}'
		return 2
	}
	return 0
}

#######################################
# Detect fast-fail escalation triggers
# Arguments: $1 — output, $2 — triggers JSON, $3 — full prompt, $4 — expected JSON
# Output: trigger name if detected, empty if none
# Returns: 0=no trigger, 1=trigger detected
#######################################
detect_fast_fail() {
	local output="$1"
	local triggers_json="$2"
	local prompt="$3"
	local expected_json="$4"

	python3 "${LIB_DIR}/detect_fast_fail.py" "$output" "$triggers_json" "$prompt" "$expected_json" 2>/dev/null
	return $?
}

#######################################
# Build the full prompt for a scenario
# Arguments: $1 — agent file path, $2 — task prompt
# Output: full prompt on stdout
# Returns: 0=success, 1=file not found
#######################################
build_scenario_prompt() {
	local agent_file="$1"
	local task_prompt="$2"
	local full_path="${REPO_ROOT}/${agent_file}"

	if [[ ! -f "$full_path" ]]; then
		return 1
	fi

	local agent_content
	agent_content=$(cat "$full_path" 2>/dev/null || echo "")

	printf '%s\n\n--- BEGIN AGENT FILE: %s ---\n%s\n--- END AGENT FILE ---\n\nNow respond to this task:\n%s\n\nRespond concisely and precisely. Follow the agent file instructions exactly.' \
		"You are reading the following agent instruction file. Follow its instructions precisely." \
		"$agent_file" "$agent_content" "$task_prompt"
	return 0
}

#######################################
# Run adjudication on ambiguous results
# Arguments: $1 — expected JSON, $2 — model output, $3 — tier, $4 — reference answer
# Output: "pass" or "fail" on stdout
# Returns: 0=pass, 1=fail
#######################################
run_adjudication() {
	local expected_json="$1"
	local model_output="$2"
	local tier="$3"
	local reference_answer="$4"

	local adjudication_tier="simple"
	[[ "$tier" != "simple" ]] && adjudication_tier="standard"

	local adj_prompt
	adj_prompt="Compare this model output against the expected behavior. Answer PASS or FAIL with a one-line reason.

Expected behavior: ${expected_json}

Reference answer: ${reference_answer:-not supplied}

Model output:
${model_output}

Answer format: PASS: <reason> or FAIL: <reason>"

	local adj_result
	adj_result=$("$AI_RESEARCH_HELPER" --prompt "$adj_prompt" --model "$adjudication_tier" --max-tokens 100 2>/dev/null) || {
		echo "fail"
		return 1
	}

	local adj_lower
	adj_lower=$(echo "$adj_result" | tr '[:upper:]' '[:lower:]')
	if echo "$adj_lower" | grep -q "^pass"; then
		echo "pass:${adjudication_tier}"
		return 0
	fi
	echo "fail:${adjudication_tier}:$(echo "$adj_result" | head -c 200 | tr '\n' ' ')"
	return 1
}

#######################################
# Format a JSON result object
# Arguments: $1=scenario, $2=tier, $3=result, $4=method, $5=extra_json (optional)
# Output: JSON on stdout
#######################################
format_result() {
	local scenario="$1"
	local tier="$2"
	local result="$3"
	local method="$4"
	local extra="${5:-}"

	local base='{"scenario":"'"$scenario"'","tier":"'"$tier"'","result":"'"$result"'","method":"'"$method"'"'
	if [[ -n "$extra" ]]; then
		echo "${base},${extra}}"
	else
		echo "${base}}"
	fi
	return 0
}

#######################################
# Run a single scenario against a model tier
# Arguments: $1 — agent file, $2 — scenario JSON, $3 — tier
# Output: JSON result on stdout
# Returns: 0=pass, 1=fail
#######################################
run_scenario() {
	local agent_file="$1"
	local scenario_json="$2"
	local tier="$3"

	local scenario_name
	scenario_name=$(echo "$scenario_json" | jq -r '.name // "unnamed"')
	local prompt
	prompt=$(echo "$scenario_json" | jq -r '.prompt // ""')
	local expected_json
	expected_json=$(echo "$scenario_json" | jq -c '.expected // {}')
	local fast_fail_json
	fast_fail_json=$(echo "$scenario_json" | jq -c '.fast_fail_triggers // []')
	local reference_answer
	reference_answer=$(echo "$scenario_json" | jq -r '.reference_answer // ""')

	log_info "Running scenario '$scenario_name' at tier=$tier"

	# Build prompt
	local full_prompt
	full_prompt=$(build_scenario_prompt "$agent_file" "$prompt") || {
		format_result "$scenario_name" "$tier" "error" "setup" '"reason":"agent_file_not_found"'
		return 1
	}

	# Call model
	local model_output
	model_output=$("$AI_RESEARCH_HELPER" --prompt "$full_prompt" --model "$tier" --max-tokens 500 2>/dev/null) || {
		format_result "$scenario_name" "$tier" "error" "api" '"reason":"model_call_failed"'
		return 1
	}

	# Check fast-fail triggers
	local ff_result
	ff_result=$(detect_fast_fail "$model_output" "$fast_fail_json" "$full_prompt" "$expected_json" 2>/dev/null) || true
	if [[ -n "$ff_result" ]]; then
		log_fail "Fast-fail: $ff_result (scenario=$scenario_name, tier=$tier)"
		format_result "$scenario_name" "$tier" "fast_fail" "escalation" '"trigger":"'"$ff_result"'"'
		return 1
	fi

	# Deterministic checks
	local det_result
	det_result=$(deterministic_check "$model_output" "$expected_json" 2>/dev/null) || true
	local det_pass
	det_pass=$(echo "$det_result" | jq -r '.pass // false')
	local det_ambiguous
	det_ambiguous=$(echo "$det_result" | jq -r '.ambiguous // false')
	local det_hard_fail
	det_hard_fail=$(echo "$det_result" | jq -r '.hard_fail // false')

	# Clear pass
	if [[ "$det_pass" == "true" && "$det_ambiguous" != "true" ]]; then
		log_pass "Deterministic pass (scenario=$scenario_name, tier=$tier)"
		format_result "$scenario_name" "$tier" "pass" "deterministic" '"checks":'"$det_result"
		return 0
	fi

	# Objective length violations are hard failures. Missing or forbidden wording
	# remains ambiguous because synonyms, quotation, and negation need adjudication.
	if [[ "$det_hard_fail" == "true" ]]; then
		log_fail "Deterministic fail (scenario=$scenario_name, tier=$tier)"
		format_result "$scenario_name" "$tier" "fail" "deterministic" '"checks":'"$det_result"
		return 1
	fi
	if [[ "$det_pass" == "false" && "$det_ambiguous" != "true" ]]; then
		log_fail "Deterministic fail (scenario=$scenario_name, tier=$tier)"
		format_result "$scenario_name" "$tier" "fail" "deterministic" '"checks":'"$det_result"
		return 1
	fi

	# Ambiguous — adjudicate
	log_info "Ambiguous, adjudicating (scenario=$scenario_name, tier=$tier)"
	local adj_out
	adj_out=$(run_adjudication "$expected_json" "$model_output" "$tier" "$reference_answer" 2>/dev/null) || true
	local adj_verdict="${adj_out%%:*}"

	if [[ "$adj_verdict" == "pass" ]]; then
		log_pass "Adjudication pass (scenario=$scenario_name, tier=$tier)"
		format_result "$scenario_name" "$tier" "pass" "adjudication"
		return 0
	fi
	log_fail "Adjudication fail (scenario=$scenario_name, tier=$tier)"
	format_result "$scenario_name" "$tier" "fail" "adjudication"
	return 1
}

#######################################
# Run one scenario with tier escalation (simple → standard → thinking)
# Arguments: $1 — agent file, $2 — scenario JSON
# Output: "tier_name:json_results_array" on stdout
# Returns: 0=passed at some tier
#######################################
escalate_scenario() {
	local agent_file="$1"
	local scenario_json="$2"
	local current_order=1
	local results="[]"

	while [[ "$current_order" -le 3 ]]; do
		local t
		t=$(tier_name "$current_order")
		local result
		result=$(run_scenario "$agent_file" "$scenario_json" "$t" 2>/dev/null) || true
		results=$(echo "$results" | jq --argjson r "$result" '. + [$r]')
		local status
		status=$(echo "$result" | jq -r '.result // "error"')
		if [[ "$status" == "pass" ]]; then
			echo "${t}:${results}"
			return 0
		fi
		current_order=$((current_order + 1))
	done
	echo "unresolved:${results}"
	return 1
}

#######################################
# Test a single scenario file across tiers with escalation
# Arguments: $1 — path to scenario YAML file
# Output: JSON results on stdout
# Returns: 0=success
#######################################
cmd_test() {
	local yaml_file="$1"
	local scenario_data
	scenario_data=$(parse_yaml "$yaml_file") || return 1

	local agent_file
	agent_file=$(echo "$scenario_data" | jq -r '.file // ""')
	local expected_tier
	expected_tier=$(echo "$scenario_data" | jq -r '.tier_minimum // ""')
	local scenario_count
	scenario_count=$(echo "$scenario_data" | jq '.scenarios | length')

	if [[ -z "$agent_file" ]]; then
		log_error "Scenario file is missing a target file: $yaml_file"
		return 1
	fi
	if [[ "$(tier_order "$expected_tier")" -eq 0 ]]; then
		log_error "Scenario file uses a non-canonical tier_minimum '$expected_tier': $yaml_file"
		return 1
	fi
	if ! [[ "$scenario_count" =~ ^[1-9][0-9]*$ ]]; then
		log_error "Scenario file must define at least one scenario: $yaml_file"
		return 1
	fi

	log_info "Testing: $agent_file (expected=$expected_tier, scenarios=$scenario_count)"

	local complexity
	complexity=$(pre_filter "${REPO_ROOT}/${agent_file}")
	log_info "Structural complexity: $complexity"

	local all_results="[]"
	local actual_tier_minimum="simple"
	local unresolved_count=0
	local i=0

	while [[ "$i" -lt "$scenario_count" ]]; do
		local scenario_json
		scenario_json=$(echo "$scenario_data" | jq -c ".scenarios[$i]")

		local esc_output
		local esc_status=0
		esc_output=$(escalate_scenario "$agent_file" "$scenario_json" 2>/dev/null) || esc_status=$?
		local scenario_tier="${esc_output%%:*}"
		local scenario_results="${esc_output#*:}"
		all_results=$(echo "$all_results" | jq --argjson r "$scenario_results" '. + $r')
		if [[ "$esc_status" -ne 0 || "$scenario_tier" == "unresolved" ]]; then
			unresolved_count=$((unresolved_count + 1))
			i=$((i + 1))
			continue
		fi

		# Update minimum tier
		local s_order
		s_order=$(tier_order "$scenario_tier")
		if [[ "$s_order" -eq 0 ]]; then
			unresolved_count=$((unresolved_count + 1))
			i=$((i + 1))
			continue
		fi
		local m_order
		m_order=$(tier_order "$actual_tier_minimum")
		[[ "$s_order" -gt "$m_order" ]] && actual_tier_minimum="$scenario_tier"

		i=$((i + 1))
	done
	if [[ "$unresolved_count" -gt 0 ]]; then
		actual_tier_minimum="unresolved"
	fi

	local matched="false"
	if [[ "$unresolved_count" -eq 0 && "$actual_tier_minimum" == "$expected_tier" ]]; then
		matched="true"
	fi

	local summary
	summary=$(jq -n \
		--arg file "$agent_file" \
		--arg expected "$expected_tier" \
		--arg actual "$actual_tier_minimum" \
		--arg complexity "$complexity" \
		--argjson matched "$matched" \
		--argjson unresolved "$unresolved_count" \
		--argjson results "$all_results" \
		'{file: $file, expected_tier: $expected, actual_tier: $actual, matched: $matched, unresolved_scenarios: $unresolved, complexity: $complexity, results: $results}')

	echo "$summary"

	if [[ "$matched" == "true" ]]; then
		log_pass "RESULT: $agent_file — tier=$actual_tier_minimum (matches expected)"
		return 0
	fi
	log_fail "RESULT: $agent_file — tier=$actual_tier_minimum (expected=$expected_tier, unresolved=$unresolved_count)"
	return 1
}

#######################################
# Sweep: run all test scenarios
# Output: JSON array of results on stdout
# Returns: 0=success
#######################################
cmd_sweep() {
	if [[ ! -d "$TESTS_DIR" ]]; then
		log_error "Tests directory not found: $TESTS_DIR"
		return 1
	fi

	local all_results="[]"
	local pass_count=0
	local fail_count=0
	local error_count=0
	local total_count=0

	local yaml_file=""
	for yaml_file in "$TESTS_DIR"/*.yaml; do
		[[ -f "$yaml_file" ]] || continue
		total_count=$((total_count + 1))
		local result
		local test_status=0
		result=$(cmd_test "$yaml_file" 2>/dev/null) || test_status=$?

		if [[ -n "$result" ]] && echo "$result" | jq -e 'type == "object"' >/dev/null 2>&1; then
			all_results=$(echo "$all_results" | jq --argjson r "$result" '. + [$r]')
			local matched
			matched=$(echo "$result" | jq -r '.matched // false')
			if [[ "$test_status" -eq 0 && "$matched" == "true" ]]; then
				pass_count=$((pass_count + 1))
			else
				fail_count=$((fail_count + 1))
			fi
		else
			error_count=$((error_count + 1))
			local error_result
			error_result=$(jq -n --arg scenario_file "$yaml_file" '{scenario_file: $scenario_file, error: "test_execution_failed"}')
			all_results=$(echo "$all_results" | jq --argjson r "$error_result" '. + [$r]')
		fi
	done

	log_info "Sweep complete: $total_count files, $pass_count matched expected, $fail_count mismatched, $error_count errors"

	local sweep_result
	sweep_result=$(jq -n \
		--argjson results "$all_results" \
		--arg total "$total_count" \
		--arg pass "$pass_count" \
		--arg fail "$fail_count" \
		--arg errors "$error_count" \
		'{summary: {total: ($total|tonumber), matched: ($pass|tonumber), mismatched: ($fail|tonumber), errors: ($errors|tonumber)}, results: $results}')

	mkdir -p "$RESULTS_DIR"
	local results_file="${RESULTS_DIR}/latest-sweep.json"
	local temporary_results=""
	temporary_results=$(mktemp "${RESULTS_DIR}/.latest-sweep.XXXXXX") || return 1
	printf '%s\n' "$sweep_result" >"$temporary_results"
	mv "$temporary_results" "$results_file"
	printf '%s\n' "$sweep_result"

	if [[ "$total_count" -eq 0 || "$fail_count" -gt 0 || "$error_count" -gt 0 ]]; then
		return 1
	fi
	return 0
}

#######################################
# Report: generate human-readable summary
# Returns: 0=success
#######################################
cmd_report() {
	log_info "Generating comprehension benchmark report..."

	local results_file="${RESULTS_DIR}/latest-sweep.json"
	if [[ ! -f "$results_file" ]]; then
		log_info "No sweep results found. Running sweep first..."
		cmd_sweep >/dev/null 2>&1 || true
	fi

	if [[ ! -f "$results_file" ]]; then
		log_error "No results to report"
		return 1
	fi

	echo "# Comprehension Benchmark Report"
	echo ""
	echo "| File | Complexity | Expected Tier | Actual Tier | Match |"
	echo "|------|-----------|---------------|-------------|-------|"

	jq -r '.results[] | "| \(.file) | \(.complexity) | \(.expected_tier) | \(.actual_tier) | \(if .expected_tier == .actual_tier then "yes" else "NO" end) |"' "$results_file" 2>/dev/null || true

	echo ""
	jq -r '"**Summary:** \(.summary.total) files tested, \(.summary.matched) matched expected tier, \(.summary.mismatched) mismatched"' "$results_file" 2>/dev/null || true
	local failed
	failed=$(jq -r '(.summary.mismatched // 0) + (.summary.errors // 0)' "$results_file" 2>/dev/null || echo 1)
	if [[ "$failed" -gt 0 ]]; then
		return 1
	fi
	return 0
}

#######################################
# Update simplification-state.json with tier_minimum results
# Returns: 0=success, 1=error
#######################################
cmd_update_state() {
	local results_file="${RESULTS_DIR}/latest-sweep.json"
	if [[ ! -f "$results_file" ]]; then
		log_error "No sweep results found. Run 'sweep' first."
		return 1
	fi

	if [[ ! -f "$STATE_FILE" ]]; then
		log_error "State file not found: $STATE_FILE"
		return 1
	fi
	if ! jq -e '(.summary.mismatched // 0) == 0 and (.summary.errors // 0) == 0 and (.summary.total // 0) > 0' "$results_file" >/dev/null 2>&1; then
		log_error "Refusing state update from an incomplete or mismatched sweep"
		return 1
	fi

	# Update state file with tier_minimum for each tested file
	python3 "${LIB_DIR}/update_state.py" "$results_file" "$STATE_FILE" || {
		log_error "Failed to update state file"
		return 1
	}
	return 0
}

#######################################
# Pre-filter command: structural heuristics only
# Arguments: $1 — agent file path
# Returns: 0=success
#######################################
cmd_pre_filter() {
	local agent_file="$1"
	local complexity
	complexity=$(pre_filter "$agent_file")

	local line_count
	line_count="$(wc -l <"$agent_file" 2>/dev/null)" || line_count=0
	line_count="${line_count// /}"
	local cross_refs
	cross_refs="$(grep -cE '\.(md|sh|json|yaml|txt)' "$agent_file" 2>/dev/null)" || cross_refs=0

	echo "File: $agent_file"
	echo "Lines: $line_count"
	echo "Cross-references: $cross_refs"
	echo "Complexity: $complexity"

	case "$complexity" in
	simple) echo "Predicted tier: simple" ;;
	moderate) echo "Predicted tier: standard" ;;
	complex) echo "Predicted tier: thinking" ;;
	*) echo "Predicted tier: unknown" ;;
	esac
	return 0
}

#######################################
# Main entry point
#######################################
main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	test)
		if [[ -z "${1:-}" ]]; then
			log_error "Usage: $0 test <scenario.yaml>"
			return 1
		fi
		cmd_test "$1"
		;;
	sweep)
		cmd_sweep
		;;
	report)
		cmd_report
		;;
	update-state)
		cmd_update_state
		;;
	pre-filter)
		if [[ -z "${1:-}" ]]; then
			log_error "Usage: $0 pre-filter <agent-file.md>"
			return 1
		fi
		cmd_pre_filter "$1"
		;;
	help | --help | -h)
		echo "Usage: $0 {test|sweep|report|update-state|pre-filter|help}"
		echo ""
		echo "Commands:"
		echo "  test <file.yaml>      Run comprehension tests for one scenario file"
		echo "  sweep                 Run all tests in .agents/tests/comprehension/"
		echo "  report                Generate human-readable summary"
		echo "  update-state          Write tier_minimum to simplification-state.json"
		echo "  pre-filter <file.md>  Structural heuristics only (no model calls)"
		echo "  help                  Show this help"
		return 0
		;;
	*)
		log_error "Unknown command: $command"
		echo "Usage: $0 {test|sweep|report|update-state|pre-filter|help}" >&2
		return 1
		;;
	esac
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
