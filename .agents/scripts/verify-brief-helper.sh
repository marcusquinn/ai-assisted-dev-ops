#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# verify-brief-helper.sh — Parse and run verify: blocks from task briefs
#
# Usage:
#   verify-brief-helper.sh verify <brief-path>   Run all method:bash verify blocks
#   verify-brief-helper.sh list   <brief-path>   List verify blocks without running
#   verify-brief-helper.sh help                   Show usage
#
# Exit codes:
#   0 — all bash verify blocks passed (or no blocks found)
#   1 — one or more bash verify blocks failed
#   2 — usage error (missing args, file not found)
#   3 — verification could not complete because of infrastructure failure

set -euo pipefail

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_usage() {
	cat <<'EOF'
Usage: verify-brief-helper.sh <command> [brief-path]

Commands:
  verify          <path>   Run all method:bash verify blocks from the brief
  list            <path>   List verify blocks without executing
  check-preflight <path>   Validate Pre-flight block is present and populated (t2409)
  check-readiness <path>   Validate schema-v2 dispatch readiness (legacy compatible)
  help                     Show this help
EOF
	return 0
}

_log() {
	local level="$1"
	shift
	local msg="$*"
	printf '[%s] %s\n' "$level" "$msg" >&2
	return 0
}

_is_infrastructure_failure() {
	local output="$1"

	if printf '%s\n' "$output" | grep -qiE \
		'gh CLI cannot authenticate an API request|not logged into any GitHub hosts|gh: Bad credentials|GraphQL: Bad credentials|Resource not accessible by integration|could not resolve host|temporary failure in name resolution|network is unreachable'; then
		return 0
	fi

	return 1
}

_redact_auth_tokens() {
	local output="$1"
	local token=""

	for token in "${GH_TOKEN:-}" "${GITHUB_TOKEN:-}"; do
		if [[ -n "$token" ]]; then
			output="${output//"$token"/[REDACTED]}"
		fi
	done
	printf '%s' "$output"
	return 0
}

# ---------------------------------------------------------------------------
# Parse verify blocks from a brief markdown file
#
# Extracts fenced yaml code blocks that contain a verify: key.
# Output: one record per block on stdout, fields tab-separated:
#   <index>\t<method>\t<run_or_prompt>
#
# method is "bash" or "manual"; run_or_prompt is the run: or prompt: value.
# ---------------------------------------------------------------------------
_parse_verify_blocks() {
	local brief_path="$1"
	local in_yaml_block=0
	local block_content=""
	local block_index=0

	while IFS= read -r line; do
		# Detect start of a yaml fenced block
		if [[ $in_yaml_block -eq 0 ]] && echo "$line" | grep -qE '^[[:space:]]*```ya?ml[[:space:]]*$'; then
			in_yaml_block=1
			block_content=""
			continue
		fi

		# Detect end of fenced block
		if [[ $in_yaml_block -eq 1 ]] && echo "$line" | grep -qE '^[[:space:]]*```[[:space:]]*$'; then
			in_yaml_block=0

			# Check if block contains verify:
			if echo "$block_content" | grep -q 'verify:'; then
				block_index=$((block_index + 1))

				# Extract method (|| true guards against set -e in process substitution)
				local method=""
				method=$(echo "$block_content" | grep -oE 'method:[[:space:]]*[^[:space:]]+' | head -1 | sed 's/method:[[:space:]]*//' || true)

				# Extract run: value (everything after run: with surrounding quotes stripped)
				# Handles inline strings and YAML block scalars (| or >)
				local run_value=""
				local run_line=""
				run_line=$(echo "$block_content" | { grep '^[[:space:]]*run:' || true; } | head -1)
				if [[ -n "$run_line" ]]; then
					local raw_value=""
					raw_value=$(echo "$run_line" | sed 's/^[[:space:]]*run:[[:space:]]*//')
					# Detect YAML block scalar indicators (| or >)
					if [[ "$raw_value" == "|" || "$raw_value" == ">" || "$raw_value" == "|-" || "$raw_value" == ">-" ]]; then
						# Collect indented continuation lines after run:
						# Join with "; " to produce a single-line bash command
						local collecting=0
						local multiline=""
						while IFS= read -r bline; do
							if [[ $collecting -eq 1 ]]; then
								if echo "$bline" | grep -qE '^[[:space:]]+'; then
									# Strip common leading whitespace (up to 6 spaces)
									local stripped=""
									stripped=$(echo "$bline" | sed 's/^[[:space:]]\{1,6\}//')
									if [[ -n "$stripped" ]]; then
										if [[ -n "$multiline" ]]; then
											multiline="${multiline}; ${stripped}"
										else
											multiline="$stripped"
										fi
									fi
								else
									break
								fi
							fi
							if echo "$bline" | grep -qE '^[[:space:]]*run:'; then
								collecting=1
							fi
						done <<<"$block_content"
						run_value="$multiline"
					else
						# Inline value — strip surrounding quotes and unescape
						run_value=$(echo "$raw_value" | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/" | sed 's/\\"/"/g')
					fi
				fi

				# Extract prompt: value (for manual blocks)
				local prompt_value=""
				prompt_value=$(echo "$block_content" | { grep '^[[:space:]]*prompt:' || true; } | head -1 | sed 's/^[[:space:]]*prompt:[[:space:]]*//' | sed 's/^"\(.*\)"$/\1/' | sed "s/^'\(.*\)'$/\1/")

				local value="$run_value"
				if [[ -z "$value" ]]; then
					value="$prompt_value"
				fi

				printf '%d\t%s\t%s\n' "$block_index" "$method" "$value"
			fi
			continue
		fi

		# Accumulate content inside yaml block
		if [[ $in_yaml_block -eq 1 ]]; then
			block_content="${block_content}${line}
"
		fi
	done <"$brief_path"

	return 0
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

_cmd_list() {
	local brief_path="$1"

	if [[ ! -f "$brief_path" ]]; then
		_log "ERROR" "Brief not found: $brief_path"
		return 2
	fi

	local found=0
	while IFS=$'\t' read -r idx method value; do
		found=1
		printf 'Block %d: method=%s\n' "$idx" "$method"
		if [[ "$method" == "bash" ]]; then
			printf '  run: %s\n' "$value"
		elif [[ "$method" == "manual" ]]; then
			printf '  prompt: %s\n' "$value"
		fi
	done < <(_parse_verify_blocks "$brief_path")

	if [[ $found -eq 0 ]]; then
		_log "INFO" "No verify: blocks found in $brief_path"
	fi

	return 0
}

_cmd_verify() {
	local brief_path="$1"

	if [[ ! -f "$brief_path" ]]; then
		_log "ERROR" "Brief not found: $brief_path"
		return 2
	fi

	local total=0
	local passed=0
	local failed=0
	local infrastructure_failed=0
	local skipped=0
	local fail_details=""
	local infrastructure_details=""

	while IFS=$'\t' read -r idx method value; do
		total=$((total + 1))

		if [[ "$method" == "manual" ]]; then
			skipped=$((skipped + 1))
			printf 'SKIP  [%d] (manual) %s\n' "$idx" "$value"
			continue
		fi

		if [[ "$method" != "bash" ]]; then
			skipped=$((skipped + 1))
			printf 'SKIP  [%d] (unknown method: %s)\n' "$idx" "$method"
			continue
		fi

		if [[ -z "$value" ]]; then
			skipped=$((skipped + 1))
			printf 'SKIP  [%d] (empty run command)\n' "$idx"
			continue
		fi

		printf 'RUN   [%d] %s\n' "$idx" "$value"

		# Execute with timeout; capture output and exit code
		local exit_code=0
		local output=""
		output=$(timeout 120 bash -c "$value" 2>&1) || exit_code=$?
		output=$(_redact_auth_tokens "$output")

		if [[ $exit_code -eq 0 ]]; then
			passed=$((passed + 1))
			printf 'PASS  [%d]\n' "$idx"
		elif _is_infrastructure_failure "$output"; then
			infrastructure_failed=$((infrastructure_failed + 1))
			printf 'INFRA [%d] exit_code=%d — verification environment unavailable\n' "$idx" "$exit_code"
			if [[ -n "$output" ]]; then
				printf '  output: %s\n' "$output"
			fi
			infrastructure_details="${infrastructure_details}Block ${idx} (exit ${exit_code}): ${value}\n"
		else
			failed=$((failed + 1))
			printf 'FAIL  [%d] exit_code=%d\n' "$idx" "$exit_code"
			if [[ -n "$output" ]]; then
				printf '  output: %s\n' "$output"
			fi
			fail_details="${fail_details}Block ${idx} (exit ${exit_code}): ${value}\n"
		fi
	done < <(_parse_verify_blocks "$brief_path")

	# Summary
	printf '\n--- Summary ---\n'
	printf 'Total: %d  Passed: %d  Failed: %d  Infrastructure: %d  Skipped: %d\n' \
		"$total" "$passed" "$failed" "$infrastructure_failed" "$skipped"

	if [[ $total -eq 0 ]]; then
		_log "INFO" "No verify: blocks found — nothing to check"
		return 0
	fi

	if [[ $failed -gt 0 ]]; then
		printf '\nFailed blocks:\n'
		printf '%b' "$fail_details"
	fi

	if [[ $infrastructure_failed -gt 0 ]]; then
		printf '\nInfrastructure failures (retry with network access and authenticated gh):\n'
		printf '%b' "$infrastructure_details"
	fi

	if [[ $failed -gt 0 ]]; then
		return 1
	fi

	if [[ $infrastructure_failed -gt 0 ]]; then
		return 3
	fi

	return 0
}

# ---------------------------------------------------------------------------
# Pre-flight validation (t2409)
# ---------------------------------------------------------------------------

_cmd_check_preflight() {
	local brief_path="$1"

	if [[ ! -f "$brief_path" ]]; then
		_log "ERROR" "File not found: $brief_path"
		return 2
	fi

	local in_preflight=0
	local found_preflight=0
	local total_boxes=0
	local checked_boxes=0
	local placeholder_boxes=0
	local errors=""

	while IFS= read -r line; do
		# Detect Pre-flight section
		if echo "$line" | grep -qE '^##[[:space:]]+Pre-flight'; then
			in_preflight=1
			found_preflight=1
			continue
		fi

		# Detect next section
		if [[ $in_preflight -eq 1 ]] && echo "$line" | grep -qE '^##[[:space:]]' && ! echo "$line" | grep -qE 'Pre-flight'; then
			break
		fi

		[[ $in_preflight -eq 0 ]] && continue

		# Skip HTML comments and blank lines
		echo "$line" | grep -qE '^\s*<!--' && continue
		[[ -z "$line" ]] && continue

		# Detect checkbox lines: - [ ] or - [x]
		if echo "$line" | grep -qE '^\s*-\s+\[[[:space:]x]\]'; then
			total_boxes=$((total_boxes + 1))

			if echo "$line" | grep -qE '^\s*-\s+\[x\]'; then
				checked_boxes=$((checked_boxes + 1))
			else
				local box_text
				box_text=$(echo "$line" | sed 's/^\s*-\s\[[[:space:]x]\]\s*//')
				errors="${errors}UNCHECKED: ${box_text}\n"
			fi

			# Check for unfilled template placeholders (angle-bracket tokens like <query>, <N>)
			# Template placeholders appear as <word> or <multi-word phrase> — they
			# may be inside or outside backticks, both count as unfilled.
			if echo "$line" | grep -qE '<[a-zA-Z].*>'; then
				placeholder_boxes=$((placeholder_boxes + 1))
				local box_text
				box_text=$(echo "$line" | sed 's/^\s*-\s\[[[:space:]x]\]\s*//')
				errors="${errors}PLACEHOLDER: ${box_text}\n"
			fi
		fi
	done <"$brief_path"

	# Report results
	if [[ $found_preflight -eq 0 ]]; then
		printf 'FAIL  Missing ## Pre-flight section\n'
		return 1
	fi

	if [[ $total_boxes -eq 0 ]]; then
		printf 'FAIL  ## Pre-flight section has no checkboxes\n'
		return 1
	fi

	if [[ -n "$errors" ]]; then
		printf '%b' "$errors"
	fi

	printf '\n--- Pre-flight Summary ---\n'
	printf 'Total: %d  Checked: %d  Unchecked: %d  Placeholders: %d\n' \
		"$total_boxes" "$checked_boxes" "$((total_boxes - checked_boxes))" "$placeholder_boxes"

	if [[ $checked_boxes -lt $total_boxes ]]; then
		printf 'FAIL  %d of %d Pre-flight boxes unchecked\n' "$((total_boxes - checked_boxes))" "$total_boxes"
		return 1
	fi

	if [[ $placeholder_boxes -gt 0 ]]; then
		printf 'FAIL  %d Pre-flight box(es) contain unfilled template placeholders\n' "$placeholder_boxes"
		return 1
	fi

	printf 'PASS  All %d Pre-flight boxes checked and populated\n' "$total_boxes"
	return 0
}

_cmd_check_readiness() {
	local -a _args=("$@")
	local brief_path="${_args[0]:-}"
	local helper_path=""
	local body=""

	if [[ -z "$brief_path" || ! -f "$brief_path" ]]; then
		_log "ERROR" "File not found: ${brief_path:-<missing>}"
		return 2
	fi

	helper_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/brief-readiness-helper.sh"
	if [[ ! -f "$helper_path" ]]; then
		_log "ERROR" "Readiness helper not found: $helper_path"
		return 2
	fi

	body=$(<"$brief_path")
	if bash "$helper_path" check --body "$body"; then
		return 0
	fi
	return 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	local -a args=("$@")
	local cmd="${args[0]:-help}"
	local target_path="${args[1]:-}"
	local command_status=0

	case "$cmd" in
	verify)
		if [[ -z "$target_path" ]]; then
			_log "ERROR" "Missing brief path. Usage: verify-brief-helper.sh verify <path>"
			return 2
		fi
		_cmd_verify "$target_path" || command_status=$?
		;;
	list)
		if [[ -z "$target_path" ]]; then
			_log "ERROR" "Missing brief path. Usage: verify-brief-helper.sh list <path>"
			return 2
		fi
		_cmd_list "$target_path" || command_status=$?
		;;
	check-preflight)
		if [[ -z "$target_path" ]]; then
			_log "ERROR" "Missing brief path. Usage: verify-brief-helper.sh check-preflight <path>"
			return 2
		fi
		_cmd_check_preflight "$target_path" || command_status=$?
		;;
	check-readiness)
		if [[ -z "$target_path" ]]; then
			_log "ERROR" "Missing brief path. Usage: verify-brief-helper.sh check-readiness <path>"
			return 2
		fi
		_cmd_check_readiness "$target_path" || command_status=$?
		;;
	help | --help | -h)
		_usage
		return 0
		;;
	*)
		_log "ERROR" "Unknown command: $cmd"
		_usage
		return 2
		;;
	esac

	if [[ "$command_status" -eq 0 ]]; then
		return 0
	fi
	if [[ "$command_status" -eq 2 || "$command_status" -eq 3 ]]; then
		return "$command_status"
	fi
	return 1
}

main "$@"
