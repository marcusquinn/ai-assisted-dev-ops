#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# complexity-scan-helper.sh — Deterministic complexity scan (GH#15285)
#
# Replaces per-file LLM complexity analysis with shell-based heuristics:
# line count, function count, nesting depth. Uses hash comparison against
# simplification-state.json to skip unchanged files. Completes in <30s
# for typical repos (vs 5-8 min with LLM analysis).
#
# Daily LLM sweep is reserved for stall detection only — when the
# simplification debt count hasn't reduced in 6h.
#
# Usage:
#   complexity-scan-helper.sh scan <repo_path> [--state-file <path>] [--format json|pipe] [--type sh|md|py|js|all]
#   complexity-scan-helper.sh sweep-check <repo_slug> [--stall-hours 6]
#   complexity-scan-helper.sh metrics <file_path>
#   complexity-scan-helper.sh ratchet-check [repo_path] [gap]
#   complexity-scan-helper.sh help
#
# Exit codes: 0 = success, 1 = error, 2 = no changes detected

set -euo pipefail

# shellcheck disable=SC2155

#######################################
# Configuration defaults
#######################################
COMPLEXITY_FUNC_LINE_THRESHOLD="${COMPLEXITY_FUNC_LINE_THRESHOLD:-100}"
COMPLEXITY_FILE_VIOLATION_THRESHOLD="${COMPLEXITY_FILE_VIOLATION_THRESHOLD:-1}"
COMPLEXITY_MD_MIN_LINES="${COMPLEXITY_MD_MIN_LINES:-500}"
COMPLEXITY_NESTING_DEPTH_THRESHOLD="${COMPLEXITY_NESTING_DEPTH_THRESHOLD:-8}"
SWEEP_STALL_HOURS="${SWEEP_STALL_HOURS:-6}"
SWEEP_LAST_RUN_FILE="${HOME}/.aidevops/logs/complexity-llm-sweep-last-run"
SWEEP_DEBT_SNAPSHOT="${HOME}/.aidevops/logs/complexity-debt-snapshot"

#######################################
# Logging
#######################################
_log() {
	local level="$1"
	shift
	printf '[complexity-scan] %s: %s\n' "$level" "$*" >&2
	return 0
}

#######################################
# Compute shell-based heuristics for a single file.
# Arguments: $1 - file_path (absolute)
# Output: pipe-delimited metrics to stdout
#   line_count|func_count|long_func_count|max_nesting|file_type
#######################################
#######################################
# Compute shell-specific function/nesting metrics.
# Nesting depth is measured per-function (resets at each function boundary)
# to avoid false positives from accumulated depth across the whole file
# (GH#15356). Global accumulation inflates depth for files with many
# short functions defined at the same level (e.g., test suites).
# Arguments: $1 - file_path
# Output: "func_count|long_func_count|max_nesting"
#######################################
_compute_shell_metrics() {
	local file_path="$1"
	local awk_result
	awk_result=$(awk '
		BEGIN { fc=0; lfc=0; global_max_nest=0; cur_nest=0; in_func=0; func_max_nest=0 }
		/^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ {
			fc++; fname=$1; sub(/\(\)/, "", fname); start=NR
			in_func=1; func_max_nest=0; cur_nest=1; next
		}
		in_func && /^\}$/ {
			lines=NR-start
			if (lines > '"$COMPLEXITY_FUNC_LINE_THRESHOLD"') lfc++
			if (func_max_nest > global_max_nest) global_max_nest = func_max_nest
			in_func=0; cur_nest=0; fname=""; next
		}
		in_func {
			if (/\{[[:space:]]*$/ || /\bthen\b/ || /\bdo\b/) { cur_nest++; if (cur_nest > func_max_nest) func_max_nest = cur_nest }
			if (/^\}/ || /\bfi\b/ || /\bdone\b/ || /\besac\b/) { if (cur_nest > 0) cur_nest-- }
		}
		END { printf "%d|%d|%d", fc, lfc, global_max_nest }
	' "$file_path" 2>/dev/null) || awk_result="0|0|0"
	printf '%s' "$awk_result"
	return 0
}

#######################################
# Compute Python-specific function/nesting metrics.
# Counts def/async def as functions; measures nesting via indentation depth.
# Arguments: $1 - file_path
# Output: "func_count|long_func_count|max_nesting"
#######################################
_compute_python_metrics() {
	local file_path="$1"
	local awk_result
	awk_result=$(awk '
		BEGIN { fc=0; lfc=0; global_max_nest=0; in_func=0; func_start=0; func_indent=0 }
		/^[[:space:]]*def [a-zA-Z_]/ || /^[[:space:]]*async def [a-zA-Z_]/ {
			if (in_func) {
				lines = NR - func_start
				if (lines > '"$COMPLEXITY_FUNC_LINE_THRESHOLD"') lfc++
			}
			fc++; func_start=NR; in_func=1
			match($0, /^[[:space:]]*/)
			func_indent = RLENGTH
			next
		}
		in_func {
			if (/^[[:space:]]*$/) next
			match($0, /^[[:space:]]*/)
			indent = RLENGTH
			nest = int((indent - func_indent) / 4)
			if (nest < 0) { in_func=0; next }
			if (nest > global_max_nest) global_max_nest = nest
		}
		END {
			if (in_func) {
				lines = NR - func_start
				if (lines > '"$COMPLEXITY_FUNC_LINE_THRESHOLD"') lfc++
			}
			printf "%d|%d|%d", fc, lfc, global_max_nest
		}
	' "$file_path" 2>/dev/null) || awk_result="0|0|0"
	printf '%s' "$awk_result"
	return 0
}

#######################################
# Compute JavaScript/TypeScript-specific function/nesting metrics.
# Counts explicit function declarations and assignments; measures brace nesting.
# Avoids broad regexes that match ordinary function calls.
# Arguments: $1 - file_path
# Output: "func_count|long_func_count|max_nesting"
#######################################
_compute_js_metrics() {
	local file_path="$1"
	local awk_result
	awk_result=$(awk '
		BEGIN { fc=0; lfc=0; global_max_nest=0; cur_nest=0; in_func=0; func_start=0; func_max_nest=0 }
		/^[[:space:]]*(export[[:space:]]+)?(default[[:space:]]+)?(async[[:space:]]+)?function([[:space:]]+\*?[A-Za-z_$][A-Za-z0-9_$]*)?[[:space:]]*\([^)]*\)[[:space:]]*\{/ ||
		/^[[:space:]]*(const|let|var)[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*=[[:space:]]*(async[[:space:]]+)?function[[:space:]]*\([^)]*\)[[:space:]]*\{/ ||
		/^[[:space:]]*(const|let|var)[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*=[[:space:]]*(async[[:space:]]+)?\([^)]*\)[[:space:]]*=>[[:space:]]*\{/ ||
		/^[[:space:]]*[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*:[[:space:]]*(async[[:space:]]+)?function[[:space:]]*\([^)]*\)[[:space:]]*\{/ {
			if (in_func && cur_nest == 0) {
				lines = NR - func_start
				if (lines > '"$COMPLEXITY_FUNC_LINE_THRESHOLD"') lfc++
			}
			fc++; func_start=NR; in_func=1; func_max_nest=0; cur_nest=1; next
		}
		in_func {
			gsub(/"[^"]*"/, ""); gsub(/'\''[^'\'']*'\''/, ""); gsub(/`[^`]*`/, "")
			n = gsub(/\{/, "{"); cur_nest += n
			m = gsub(/\}/, "}"); cur_nest -= m
			if (cur_nest > func_max_nest) func_max_nest = cur_nest
			if (cur_nest <= 0) {
				lines = NR - func_start
				if (lines > '"$COMPLEXITY_FUNC_LINE_THRESHOLD"') lfc++
				if (func_max_nest > global_max_nest) global_max_nest = func_max_nest
				in_func=0; cur_nest=0
			}
		}
		END {
			if (in_func) {
				if (func_max_nest > global_max_nest) global_max_nest = func_max_nest
			}
			printf "%d|%d|%d", fc, lfc, global_max_nest
		}
	' "$file_path" 2>/dev/null) || awk_result="0|0|0"
	printf '%s' "$awk_result"
	return 0
}

#######################################
# Compute markdown-specific heading/nesting metrics.
# Counts headings as "functions"; nesting = heading depth.
# Arguments: $1 - file_path
# Output: "func_count|long_func_count|max_nesting"
#######################################
_compute_markdown_metrics() {
	local file_path="$1"
	local func_count max_nesting
	func_count=$(grep -c '^#' "$file_path" 2>/dev/null || true)
	max_nesting=$(awk '/^#{1,6} / { n=0; for(i=1;i<=length($1);i++) if(substr($1,i,1)=="#") n++; if(n>max) max=n } END { print max+0 }' "$file_path" 2>/dev/null) || max_nesting=0
	printf '%s|0|%s' "$func_count" "$max_nesting"
	return 0
}

#######################################
# Compute shell-based heuristics for a single file.
# Dispatches to language-specific helpers based on file extension.
# Arguments: $1 - file_path (absolute)
# Output: pipe-delimited metrics to stdout
#   line_count|func_count|long_func_count|max_nesting|file_type
#######################################
compute_file_metrics() {
	local file_path="$1"

	if [[ ! -f "$file_path" ]]; then
		echo "0|0|0|0|unknown"
		return 1
	fi

	local ext="${file_path##*.}"
	local file_type="unknown"
	case "$ext" in
	sh | bash) file_type="shell" ;;
	md) file_type="markdown" ;;
	py) file_type="python" ;;
	ts | js | mjs) file_type="javascript" ;;
	*) file_type="other" ;;
	esac

	local line_count=0
	line_count=$(wc -l <"$file_path" 2>/dev/null | tr -d ' ') || line_count=0

	local lang_metrics="0|0|0"
	case "$file_type" in
	shell) lang_metrics=$(_compute_shell_metrics "$file_path") ;;
	python) lang_metrics=$(_compute_python_metrics "$file_path") ;;
	javascript) lang_metrics=$(_compute_js_metrics "$file_path") ;;
	markdown) lang_metrics=$(_compute_markdown_metrics "$file_path") ;;
	esac

	local func_count long_func_count max_nesting
	func_count=$(printf '%s' "$lang_metrics" | cut -d'|' -f1)
	long_func_count=$(printf '%s' "$lang_metrics" | cut -d'|' -f2)
	max_nesting=$(printf '%s' "$lang_metrics" | cut -d'|' -f3)

	printf '%s|%s|%s|%s|%s' "$line_count" "$func_count" "$long_func_count" "$max_nesting" "$file_type"
	return 0
}

#######################################
# Check file hash against simplification state.
# Arguments: $1 - repo_path, $2 - file_path (repo-relative), $3 - state_file
# Output: "unchanged" | "recheck" | "new"
#######################################
check_file_state() {
	local repo_path="$1"
	local file_path="$2"
	local state_file="$3"

	if [[ ! -f "$state_file" ]]; then
		echo "new"
		return 0
	fi

	# Check both .files (canonical) and top-level (legacy) locations.
	# Legacy entries existed before the .files wrapper was introduced and
	# caused the scanner to treat already-simplified files as "new",
	# re-filing duplicate issues every pulse cycle.
	local recorded_hash
	recorded_hash=$(jq -r --arg fp "$file_path" '(.files[$fp].hash // .[$fp].hash) // empty' "$state_file" 2>/dev/null) || recorded_hash=""

	if [[ -z "$recorded_hash" ]]; then
		echo "new"
		return 0
	fi

	local full_path="${repo_path}/${file_path}"
	if [[ ! -f "$full_path" ]]; then
		echo "new"
		return 0
	fi

	local current_hash
	current_hash=$(git -C "$repo_path" hash-object "$full_path" 2>/dev/null) || current_hash=""

	if [[ "$current_hash" == "$recorded_hash" ]]; then
		echo "unchanged"
		return 0
	fi

	echo "recheck"
	return 0
}

#######################################
# Batch hash check — compute all current hashes in one pass, compare
# against state file. This is the core performance optimization: instead
# of calling git hash-object per file, we use git ls-files with hash info.
#
# Arguments: $1 - repo_path, $2 - state_file, $3 - file_pattern (e.g., '*.sh')
# Output: lines of "status|file_path" where status is new/recheck/unchanged
#######################################
batch_hash_check() {
	local repo_path="$1"
	local state_file="$2"
	local file_pattern="$3"

	# Get all tracked files matching pattern with their current blob hashes
	# Format: <mode> <hash> <stage>\t<file>
	local git_ls_output
	git_ls_output=$(git -C "$repo_path" ls-files -s "$file_pattern" 2>/dev/null) || {
		_log "WARN" "git ls-files failed for pattern: $file_pattern"
		return 1
	}

	if [[ -z "$git_ls_output" ]]; then
		return 0
	fi

	# If no state file, everything is "new"
	if [[ ! -f "$state_file" ]]; then
		while IFS=$'\t' read -r _mode_hash file_path; do
			[[ -n "$file_path" ]] || continue
			echo "new|${file_path}"
		done <<<"$git_ls_output"
		return 0
	fi

	# Load state file hashes into an associative-style lookup via jq.
	# Merges both .files (canonical) and top-level (legacy) entries,
	# with .files taking precedence on overlap.
	# Output: one line per entry "file_path\thash"
	local state_hashes
	state_hashes=$(jq -r '
		# Collect legacy top-level entries (keys that look like file paths)
		([to_entries[] | select(.key != "files" and (.key | startswith("."))) | {key: .key, value: .value.hash}] | from_entries) as $legacy |
		# Collect canonical .files entries
		([.files // {} | to_entries[] | {key: .key, value: .value.hash}] | from_entries) as $canonical |
		# Merge: canonical wins on overlap
		($legacy + $canonical) | to_entries[] | "\(.key)\t\(.value)"
	' "$state_file" 2>/dev/null) || state_hashes=""

	# Build a temp file for state lookup (faster than repeated jq calls)
	local state_tmp
	state_tmp=$(mktemp)
	# shellcheck disable=SC2064
	trap "rm -f '$state_tmp'" EXIT
	printf '%s\n' "$state_hashes" >"$state_tmp"

	while IFS=$'\t' read -r mode_hash file_path; do
		[[ -n "$file_path" ]] || continue
		# Extract hash from mode_hash (format: "100644 <hash> 0")
		local current_hash
		current_hash=$(echo "$mode_hash" | awk '{print $2}')

		# Look up recorded hash
		local recorded_hash
		recorded_hash=$(grep -F "$file_path" "$state_tmp" 2>/dev/null | head -1 | cut -f2) || recorded_hash=""

		if [[ -z "$recorded_hash" ]]; then
			echo "new|${file_path}"
		elif [[ "$current_hash" == "$recorded_hash" ]]; then
			echo "unchanged|${file_path}"
		else
			echo "recheck|${file_path}"
		fi
	done <<<"$git_ls_output"

	rm -f "$state_tmp"
	# Remove the trap since we cleaned up manually
	trap - EXIT
	return 0
}

#######################################
# Check if a markdown file is mostly frontmatter (stub file).
# Returns 0 if the file should be skipped, 1 if it has enough content.
# Arguments: $1 - full_path, $2 - line_count
#######################################
_is_frontmatter_stub() {
	local full_path="$1"
	local line_count="$2"
	local frontmatter_end=0

	if ! head -1 "$full_path" 2>/dev/null | grep -q '^---$'; then
		return 1
	fi

	frontmatter_end=$(awk 'NR==1 && /^---$/ { in_fm=1; next } in_fm && /^---$/ { print NR; exit }' "$full_path" 2>/dev/null)
	frontmatter_end=${frontmatter_end:-0}

	[[ "$frontmatter_end" -eq 0 ]] && return 1

	local content_lines=$((line_count - frontmatter_end))
	local threshold=$(((line_count * 40) / 100))
	[[ "$content_lines" -lt "$threshold" ]] && return 0
	return 1
}

# Exclusion patterns shared by scan phases
_EXCLUDED_DIRS='_archive/|/templates/|/todo/'
_EXCLUDED_FILES='/README\.md$|-history\.md$|/configs/.*\.md$|CHANGELOG\.md$'
_PROTECTED_PATTERN='prompts/build\.txt|^\.agents/AGENTS\.md|^AGENTS\.md|scripts/commands/pulse\.md'

#######################################
# Scan shell files for complexity violations.
# Arguments: $1 - repo_path, $2 - state_file
# Output: pipe-delimited results to stdout (one line per violation)
#######################################
_scan_shell_files() {
	local repo_path="$1"
	local state_file="$2"

	local check_results
	check_results=$(batch_hash_check "$repo_path" "$state_file" '*.sh') || check_results=""
	[[ -z "$check_results" ]] && return 0

	while IFS='|' read -r status file_path; do
		[[ -n "$file_path" ]] || continue
		echo "$file_path" | grep -qE "$_EXCLUDED_DIRS" && continue
		[[ "$status" == "unchanged" ]] && continue

		local full_path="${repo_path}/${file_path}"
		local metrics
		metrics=$(compute_file_metrics "$full_path") || metrics="0|0|0|0|shell"

		local line_count func_count long_func_count max_nesting file_type
		IFS='|' read -r line_count func_count long_func_count max_nesting file_type <<<"$metrics"

		if [[ "$long_func_count" -ge "$COMPLEXITY_FILE_VIOLATION_THRESHOLD" ]] ||
			[[ "$max_nesting" -gt "$COMPLEXITY_NESTING_DEPTH_THRESHOLD" ]]; then
			printf '%s|%s|%s|%s|%s|%s|%s\n' "$status" "$file_path" "$line_count" "$func_count" "$long_func_count" "$max_nesting" "$file_type"
		fi
	done <<<"$check_results"
	return 0
}

#######################################
# Scan markdown files for complexity violations.
# Arguments: $1 - repo_path, $2 - state_file
# Output: pipe-delimited results to stdout (one line per violation)
#######################################
_scan_md_files() {
	local repo_path="$1"
	local state_file="$2"

	local check_results
	check_results=$(batch_hash_check "$repo_path" "$state_file" '*.md') || check_results=""
	[[ -z "$check_results" ]] && return 0

	while IFS='|' read -r status file_path; do
		[[ -n "$file_path" ]] || continue
		echo "$file_path" | grep -q '^\.agents/' || continue
		echo "$file_path" | grep -qE "$_EXCLUDED_DIRS|$_EXCLUDED_FILES|$_PROTECTED_PATTERN" && continue
		local full_path="${repo_path}/${file_path}"
		local line_count=0
		line_count=$(wc -l <"$full_path" 2>/dev/null | tr -d ' ') || line_count=0
		[[ "$line_count" -lt "$COMPLEXITY_MD_MIN_LINES" ]] && continue
		_is_frontmatter_stub "$full_path" "$line_count" && continue

		local metrics
		metrics=$(compute_file_metrics "$full_path") || metrics="${line_count}|0|0|0|markdown"

		local _lc _fc _lfc max_nesting file_type
		IFS='|' read -r _lc _fc _lfc max_nesting file_type <<<"$metrics"

		printf '%s|%s|%s|%s|0|%s|%s\n' "$status" "$file_path" "$line_count" "$_fc" "$max_nesting" "$file_type"
	done <<<"$check_results"
	return 0
}

#######################################
# Scan Python files for complexity violations.
# Arguments: $1 - repo_path, $2 - state_file
# Output: pipe-delimited results to stdout (one line per violation)
#######################################
_scan_python_files() {
	local repo_path="$1"
	local state_file="$2"

	local check_results
	check_results=$(batch_hash_check "$repo_path" "$state_file" '*.py') || check_results=""
	[[ -z "$check_results" ]] && return 0

	while IFS='|' read -r status file_path; do
		[[ -n "$file_path" ]] || continue
		echo "$file_path" | grep -qE "$_EXCLUDED_DIRS" && continue
		[[ "$status" == "unchanged" ]] && continue

		local full_path="${repo_path}/${file_path}"
		local metrics
		metrics=$(compute_file_metrics "$full_path") || metrics="0|0|0|0|python"

		local line_count func_count long_func_count max_nesting file_type
		IFS='|' read -r line_count func_count long_func_count max_nesting file_type <<<"$metrics"

		if [[ "$long_func_count" -ge "$COMPLEXITY_FILE_VIOLATION_THRESHOLD" ]] ||
			[[ "$max_nesting" -gt "$COMPLEXITY_NESTING_DEPTH_THRESHOLD" ]]; then
			printf '%s|%s|%s|%s|%s|%s|%s\n' "$status" "$file_path" "$line_count" "$func_count" "$long_func_count" "$max_nesting" "$file_type"
		fi
	done <<<"$check_results"
	return 0
}

#######################################
# Scan JavaScript/TypeScript files for complexity violations.
# Handles .js, .mjs, and .ts extensions.
# Arguments: $1 - repo_path, $2 - state_file
# Output: pipe-delimited results to stdout (one line per violation)
#######################################
_scan_js_files() {
	local repo_path="$1"
	local state_file="$2"

	local all_results=""
	local -a js_patterns=("*.js" "*.mjs" "*.ts")
	local ext
	for ext in "${js_patterns[@]}"; do
		local check_results
		check_results=$(batch_hash_check "$repo_path" "$state_file" "$ext") || check_results=""
		[[ -z "$check_results" ]] && continue
		all_results="${all_results}${all_results:+$'\n'}${check_results}"
	done

	[[ -z "$all_results" ]] && return 0

	while IFS='|' read -r status file_path; do
		[[ -n "$file_path" ]] || continue
		echo "$file_path" | grep -qE "$_EXCLUDED_DIRS" && continue
		[[ "$status" == "unchanged" ]] && continue

		local full_path="${repo_path}/${file_path}"
		local metrics
		metrics=$(compute_file_metrics "$full_path") || metrics="0|0|0|0|javascript"

		local line_count func_count long_func_count max_nesting file_type
		IFS='|' read -r line_count func_count long_func_count max_nesting file_type <<<"$metrics"

		if [[ "$long_func_count" -ge "$COMPLEXITY_FILE_VIOLATION_THRESHOLD" ]] ||
			[[ "$max_nesting" -gt "$COMPLEXITY_NESTING_DEPTH_THRESHOLD" ]]; then
			printf '%s|%s|%s|%s|%s|%s|%s\n' "$status" "$file_path" "$line_count" "$func_count" "$long_func_count" "$max_nesting" "$file_type"
		fi
	done <<<"$all_results"
	return 0
}

#######################################
# Format scan results as JSON array.
# Arguments: reads from stdin (pipe-delimited lines)
#######################################
_format_results_json() {
	echo "["
	local first=true
	while IFS='|' read -r status file_path line_count func_count long_func_count max_nesting file_type; do
		[[ -n "$file_path" ]] || continue
		if [[ "$first" == true ]]; then
			first=false
		else
			echo ","
		fi
		printf '  {"status":"%s","file":"%s","lines":%s,"functions":%s,"long_functions":%s,"max_nesting":%s,"type":"%s"}' \
			"$status" "$file_path" "$line_count" "$func_count" "$long_func_count" "$max_nesting" "$file_type"
	done
	echo ""
	echo "]"
	return 0
}

#######################################
# Main scan command — deterministic complexity scan.
# Compares file hashes against simplification-state.json, only computes
# metrics for changed/new files. Outputs results in pipe or JSON format.
#
# Arguments: $1 - repo_path
# Options: --state-file <path>, --format json|pipe, --type sh|md|py|js|all
#######################################
cmd_scan() {
	local repo_path=""
	local state_file=""
	local output_format="pipe"
	local scan_type="all"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--state-file)
			state_file="$2"
			shift 2
			;;
		--format)
			output_format="$2"
			shift 2
			;;
		--type)
			scan_type="$2"
			shift 2
			;;
		*)
			[[ -z "$repo_path" ]] && repo_path="$1"
			shift
			;;
		esac
	done

	if [[ -z "$repo_path" || ! -d "$repo_path" ]]; then
		_log "ERROR" "repo_path is required and must be a directory"
		return 1
	fi

	[[ -z "$state_file" ]] && state_file="${repo_path}/.agents/configs/simplification-state.json"

	local start_time
	start_time=$(date +%s)

	# Use temp files for scan output (subshell counter workaround)
	local results_tmp
	results_tmp=$(mktemp)

	if [[ "$scan_type" == "all" || "$scan_type" == "sh" ]]; then
		_scan_shell_files "$repo_path" "$state_file" >>"$results_tmp"
	fi

	if [[ "$scan_type" == "all" || "$scan_type" == "md" ]]; then
		_scan_md_files "$repo_path" "$state_file" >>"$results_tmp"
	fi

	if [[ "$scan_type" == "all" || "$scan_type" == "py" ]]; then
		_scan_python_files "$repo_path" "$state_file" >>"$results_tmp"
	fi

	if [[ "$scan_type" == "all" || "$scan_type" == "js" ]]; then
		_scan_js_files "$repo_path" "$state_file" >>"$results_tmp"
	fi

	local results
	results=$(cat "$results_tmp")
	rm -f "$results_tmp"

	# Count results from output (counters don't propagate from subshells)
	local changed_files=0
	[[ -n "$results" ]] && changed_files=$(printf '%s\n' "$results" | grep -c '.' 2>/dev/null || true)

	local elapsed=$(($(date +%s) - start_time))
	_log "INFO" "Scan complete in ${elapsed}s: ${changed_files} files with violations found"

	if [[ -z "$results" ]]; then
		_log "INFO" "No files exceed complexity thresholds"
		return 2
	fi

	# Sort by line count (field 3) descending
	results=$(printf '%s' "$results" | sort -t'|' -k3 -rn)

	if [[ "$output_format" == "json" ]]; then
		printf '%s' "$results" | _format_results_json
	else
		printf '%s' "$results"
	fi

	return 0
}

#######################################
# Sweep check — determine if daily LLM sweep is needed.
# Conditions for sweep:
#   1. Last sweep was >24h ago (or never run)
#   2. Simplification debt count hasn't decreased in SWEEP_STALL_HOURS
#
# Arguments: $1 - repo_slug
# Options: --stall-hours N
# Output: "needed" or "not-needed" with reason
# Exit: 0 = sweep needed, 1 = not needed
#######################################
cmd_sweep_check() {
	local repo_slug=""
	local stall_hours="$SWEEP_STALL_HOURS"

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--stall-hours)
			stall_hours="$2"
			shift 2
			;;
		*)
			if [[ -z "$repo_slug" ]]; then
				repo_slug="$1"
			fi
			shift
			;;
		esac
	done

	if [[ -z "$repo_slug" ]]; then
		_log "ERROR" "repo_slug is required"
		return 1
	fi

	local now_epoch
	now_epoch=$(date +%s)

	# Check 1: Has it been >24h since last sweep?
	if [[ -f "$SWEEP_LAST_RUN_FILE" ]]; then
		local last_sweep
		last_sweep=$(cat "$SWEEP_LAST_RUN_FILE" 2>/dev/null || echo "0")
		[[ "$last_sweep" =~ ^[0-9]+$ ]] || last_sweep=0
		local sweep_elapsed=$((now_epoch - last_sweep))
		if [[ "$sweep_elapsed" -lt 86400 ]]; then
			local hours_remaining=$(((86400 - sweep_elapsed) / 3600))
			echo "not-needed|sweep ran ${sweep_elapsed}s ago (${hours_remaining}h until next)"
			return 1
		fi
	fi

	# Check 2: Has debt count stalled?
	local current_debt=0
	current_debt=$(gh api graphql -f query="query { repository(owner:\"${repo_slug%%/*}\", name:\"${repo_slug##*/}\") { issues(labels:[\"function-complexity-debt\"], states:OPEN) { totalCount } } }" \
		--jq '.data.repository.issues.totalCount' 2>/dev/null) || current_debt=0

	if [[ -f "$SWEEP_DEBT_SNAPSHOT" ]]; then
		local snapshot_data
		snapshot_data=$(cat "$SWEEP_DEBT_SNAPSHOT" 2>/dev/null) || snapshot_data=""
		local snapshot_epoch snapshot_count
		snapshot_epoch=$(echo "$snapshot_data" | cut -d'|' -f1)
		snapshot_count=$(echo "$snapshot_data" | cut -d'|' -f2)
		[[ "$snapshot_epoch" =~ ^[0-9]+$ ]] || snapshot_epoch=0
		[[ "$snapshot_count" =~ ^[0-9]+$ ]] || snapshot_count=0

		local stall_seconds=$((stall_hours * 3600))
		local snapshot_age=$((now_epoch - snapshot_epoch))

		if [[ "$snapshot_age" -ge "$stall_seconds" ]]; then
			# No sweep needed when debt is already zero — nothing to act on (GH#17396)
			if [[ "$current_debt" -eq 0 ]]; then
				echo "${now_epoch}|0" >"$SWEEP_DEBT_SNAPSHOT"
				echo "not-needed|debt is zero, no sweep required"
				return 1
			fi
			if [[ "$current_debt" -ge "$snapshot_count" ]]; then
				# Net count hasn't decreased — but check throughput before declaring stall (GH#18286).
				# If issues were closed in the stall window, the system is working (new issues
				# are being created at a similar rate). A true stall means zero closures.
				local recent_closures=0
				local since_date
				since_date=$(date -u -d "@$((now_epoch - stall_seconds))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) ||
					since_date=$(date -u -r "$((now_epoch - stall_seconds))" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null) ||
					since_date=""
				if [[ -n "$since_date" ]]; then
					recent_closures=$(gh api graphql -f query="query { search(query:\"repo:${repo_slug} label:function-complexity-debt is:issue is:closed closed:>${since_date}\", type:ISSUE) { issueCount } }" \
						--jq '.data.search.issueCount' 2>/dev/null) || recent_closures=0
					[[ "$recent_closures" =~ ^[0-9]+$ ]] || recent_closures=0
				fi
				if [[ "$recent_closures" -gt 0 ]]; then
					# Active throughput — system is working, not stalled. Update snapshot.
					echo "${now_epoch}|${current_debt}" >"$SWEEP_DEBT_SNAPSHOT"
					echo "not-needed|debt at ${current_debt} but ${recent_closures} issues closed in ${stall_hours}h (active throughput)"
					return 1
				fi
				# GH#30770: a flat debt count is also healthy when every open item
				# is already queued, running, or awaiting PR review. Keep this
				# standalone check aligned with the pulse inline sweep guard.
				local debt_issues_json=""
				debt_issues_json=$(gh issue list --repo "$repo_slug" \
					--label "function-complexity-debt" --state open --limit 500 \
					--json number,title,labels 2>/dev/null) || debt_issues_json=""
				local actionable_count=""
				local active_count=""
				if [[ -n "$debt_issues_json" ]]; then
					actionable_count=$(printf '%s' "$debt_issues_json" | jq '[.[] | select(.title | test("stalled|LLM sweep") | not)] | length' 2>/dev/null) || actionable_count=""
					active_count=$(printf '%s' "$debt_issues_json" | jq '
						[.[] | select(.title | test("stalled|LLM sweep") | not)] |
						[.[] | select(.labels | map(.name) |
							(index("status:queued") or index("status:in-progress") or index("status:in-review")))] |
						length' 2>/dev/null) || active_count=""
				fi
				if [[ "$actionable_count" =~ ^[0-9]+$ && "$active_count" =~ ^[0-9]+$ && "$actionable_count" -gt 0 && "$active_count" -ge "$actionable_count" ]]; then
					echo "${now_epoch}|${current_debt}" >"$SWEEP_DEBT_SNAPSHOT"
					echo "not-needed|all ${actionable_count} debt issues are active or in review"
					return 1
				fi
				# Zero throughput — genuine stall, sweep needed
				echo "needed|debt stalled at ${current_debt} for ${stall_hours}h+ (was ${snapshot_count}, 0 closures)"
				# Update snapshot for next check
				echo "${now_epoch}|${current_debt}" >"$SWEEP_DEBT_SNAPSHOT"
				return 0
			else
				# Debt decreased — update snapshot, no sweep needed
				echo "${now_epoch}|${current_debt}" >"$SWEEP_DEBT_SNAPSHOT"
				echo "not-needed|debt decreased from ${snapshot_count} to ${current_debt}"
				return 1
			fi
		else
			echo "not-needed|snapshot too recent (${snapshot_age}s old, need ${stall_seconds}s)"
			return 1
		fi
	fi

	# No snapshot exists — create one. Skip sweep if debt is already zero (GH#17396).
	echo "${now_epoch}|${current_debt}" >"$SWEEP_DEBT_SNAPSHOT"
	if [[ "$current_debt" -eq 0 ]]; then
		echo "not-needed|initial snapshot created, debt is zero"
		return 1
	fi
	echo "needed|initial sweep (no prior snapshot, current debt: ${current_debt})"
	return 0
}

#######################################
# Record that a sweep was performed.
#######################################
cmd_sweep_done() {
	local now_epoch
	now_epoch=$(date +%s)
	echo "$now_epoch" >"$SWEEP_LAST_RUN_FILE"
	_log "INFO" "LLM sweep recorded at $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
	return 0
}

#######################################
# Metrics command — compute metrics for a single file.
# Arguments: $1 - file_path (absolute)
#######################################
cmd_metrics() {
	local file_path="$1"

	if [[ -z "$file_path" || ! -f "$file_path" ]]; then
		_log "ERROR" "file_path is required and must exist"
		return 1
	fi

	local metrics
	metrics=$(compute_file_metrics "$file_path") || {
		_log "ERROR" "Failed to compute metrics for $file_path"
		return 1
	}

	local line_count func_count long_func_count max_nesting file_type
	IFS='|' read -r line_count func_count long_func_count max_nesting file_type <<<"$metrics"

	printf 'File: %s\n' "$file_path"
	printf 'Type: %s\n' "$file_type"
	printf 'Lines: %s\n' "$line_count"
	printf 'Functions: %s\n' "$func_count"
	printf 'Long functions (>%s lines): %s\n' "$COMPLEXITY_FUNC_LINE_THRESHOLD" "$long_func_count"
	printf 'Max nesting depth: %s\n' "$max_nesting"
	return 0
}

#######################################
# Ratchet check — compare actual violation counts against thresholds.
# When actual count is below threshold by more than gap, outputs proposed
# new thresholds (actual + 2 buffer). Returns 0 if ratchet-down is possible.
#
# Arguments: $1 - repo_path (default: .)
#            $2 - gap (default: 5)
# Output: proposed threshold lines to stdout when ratchet-down is available
# Exit: 0 = ratchet-down possible, 1 = thresholds already tight or error
#######################################
cmd_ratchet_check() {
	local repo_path="${1:-.}"
	local gap="${2:-5}"
	local conf_file="${repo_path}/.agents/configs/complexity-thresholds.conf"

	if [[ ! -f "$conf_file" ]]; then
		_log "ERROR" "Config not found: $conf_file"
		return 1
	fi

	# Read current thresholds from config
	local func_threshold nest_threshold size_threshold bash32_threshold
	func_threshold=$(grep '^FUNCTION_COMPLEXITY_THRESHOLD=' "$conf_file" | cut -d= -f2)
	nest_threshold=$(grep '^NESTING_DEPTH_THRESHOLD=' "$conf_file" | cut -d= -f2)
	size_threshold=$(grep '^FILE_SIZE_THRESHOLD=' "$conf_file" | cut -d= -f2)
	bash32_threshold=$(grep '^BASH32_COMPAT_THRESHOLD=' "$conf_file" | cut -d= -f2)

	# Validate thresholds are numeric
	for val in "$func_threshold" "$nest_threshold" "$size_threshold" "$bash32_threshold"; do
		if [[ ! "$val" =~ ^[0-9]+$ ]]; then
			_log "ERROR" "Non-numeric threshold value: $val"
			return 1
		fi
	done

	# Discover shell files using same logic as CI (git ls-files)
	local sh_files
	sh_files=$(git -C "$repo_path" ls-files '*.sh' 2>/dev/null |
		grep -Ev 'archived/|\.archive/|vendor/|node_modules/' || true)

	if [[ -z "$sh_files" ]]; then
		_log "ERROR" "No shell files found in $repo_path"
		return 1
	fi

	# Count function complexity violations (>100 lines per function)
	local actual_func=0
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		local full_path="${repo_path}/${file}"
		[[ -f "$full_path" ]] || continue
		local result
		result=$(awk '
			/^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ { fname=$1; sub(/\(\)/, "", fname); start=NR; next }
			fname && /^\}$/ { lines=NR-start; if(lines>100) print "BLOCK"; fname="" }
		' "$full_path" 2>/dev/null) || result=""
		if [[ -n "$result" ]]; then
			local count
			count=$(printf '%s\n' "$result" | grep -c '.' 2>/dev/null || true)
			actual_func=$((actual_func + count))
		fi
	done <<<"$sh_files"

	# Count nesting depth violations (>8 levels per file)
	local actual_nest=0
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		local full_path="${repo_path}/${file}"
		[[ -f "$full_path" ]] || continue
		local max_depth
		max_depth=$(awk '
			BEGIN { depth=0; max_depth=0 }
			/^[[:space:]]*#/ { next }
			/[[:space:]]*(if|for|while|until|case)[[:space:]]/ { depth++; if(depth>max_depth) max_depth=depth }
			/[[:space:]]*(fi|done|esac)[[:space:]]*$/ || /^[[:space:]]*(fi|done|esac)$/ { if(depth>0) depth-- }
			END { print max_depth }
		' "$full_path" 2>/dev/null) || max_depth=0
		if [[ "$max_depth" -gt 8 ]]; then
			actual_nest=$((actual_nest + 1))
		fi
	done <<<"$sh_files"

	# Count file size violations (>1500 lines)
	local actual_size=0
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		local full_path="${repo_path}/${file}"
		[[ -f "$full_path" ]] || continue
		local lc
		lc=$(wc -l <"$full_path" 2>/dev/null) || lc=0
		if [[ "$lc" -gt 1500 ]]; then
			actual_size=$((actual_size + 1))
		fi
	done <<<"$sh_files"

	# Count Bash 3.2 compatibility violations
	local actual_bash32=0
	local self_skip="linters-local.sh"
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		local full_path="${repo_path}/${file}"
		[[ -f "$full_path" ]] || continue
		local basename_file
		basename_file=$(basename "$file")
		[[ "$basename_file" = "$self_skip" ]] && continue

		# "\t" or "\n" in string assignments
		local matches
		matches=$(grep -nE '\+="\\[tn]|="\\[tn]' "$full_path" 2>/dev/null |
			grep -vE '^[0-9]+:[[:space:]]*#' |
			grep -vE 'awk|sed|printf|echo.*-e|python|f\.write|gsub|join|split|print |replace|coords|excerpt|delimiter|regex|pattern' ||
			true)
		if [[ -n "$matches" ]]; then
			local cnt
			cnt=$(printf '%s\n' "$matches" | grep -c '.' 2>/dev/null || true)
			actual_bash32=$((actual_bash32 + cnt))
		fi

		# Associative arrays (bash 4.0+)
		local assoc
		assoc=$(grep -nE '^[[:space:]]*(declare|local|typeset)[[:space:]]+-A[[:space:]]' "$full_path" 2>/dev/null |
			grep -vE '^[0-9]+:[[:space:]]*#' || true)
		if [[ -n "$assoc" ]]; then
			local cnt2
			cnt2=$(printf '%s\n' "$assoc" | grep -c '.' 2>/dev/null || true)
			actual_bash32=$((actual_bash32 + cnt2))
		fi

		# Namerefs (bash 4.3+)
		local nameref
		nameref=$(grep -nE '^[[:space:]]*(declare|local)[[:space:]]+-n[[:space:]]' "$full_path" 2>/dev/null |
			grep -vE '^[0-9]+:[[:space:]]*#' || true)
		if [[ -n "$nameref" ]]; then
			local cnt3
			cnt3=$(printf '%s\n' "$nameref" | grep -c '.' 2>/dev/null || true)
			actual_bash32=$((actual_bash32 + cnt3))
		fi
	done <<<"$sh_files"

	_log "INFO" "Actual violations — func:${actual_func} nest:${actual_nest} size:${actual_size} bash32:${actual_bash32}"
	_log "INFO" "Current thresholds — func:${func_threshold} nest:${nest_threshold} size:${size_threshold} bash32:${bash32_threshold}"

	# Compare and output proposals (buffer of +2 above actual to prevent flapping)
	local proposed=0

	if [[ $((func_threshold - actual_func)) -ge "$gap" ]]; then
		local new_func=$((actual_func + 2))
		printf 'FUNCTION_COMPLEXITY_THRESHOLD: %d → %d (actual: %d, gap: %d)\n' \
			"$func_threshold" "$new_func" "$actual_func" "$((func_threshold - actual_func))"
		proposed=$((proposed + 1))
	fi

	if [[ $((nest_threshold - actual_nest)) -ge "$gap" ]]; then
		local new_nest=$((actual_nest + 2))
		printf 'NESTING_DEPTH_THRESHOLD: %d → %d (actual: %d, gap: %d)\n' \
			"$nest_threshold" "$new_nest" "$actual_nest" "$((nest_threshold - actual_nest))"
		proposed=$((proposed + 1))
	fi

	if [[ $((size_threshold - actual_size)) -ge "$gap" ]]; then
		local new_size=$((actual_size + 2))
		printf 'FILE_SIZE_THRESHOLD: %d → %d (actual: %d, gap: %d)\n' \
			"$size_threshold" "$new_size" "$actual_size" "$((size_threshold - actual_size))"
		proposed=$((proposed + 1))
	fi

	if [[ $((bash32_threshold - actual_bash32)) -ge "$gap" ]]; then
		local new_bash32=$((actual_bash32 + 2))
		printf 'BASH32_COMPAT_THRESHOLD: %d → %d (actual: %d, gap: %d)\n' \
			"$bash32_threshold" "$new_bash32" "$actual_bash32" "$((bash32_threshold - actual_bash32))"
		proposed=$((proposed + 1))
	fi

	if [[ "$proposed" -gt 0 ]]; then
		_log "INFO" "Ratchet-down available: $proposed threshold(s) can be lowered"
		return 0
	fi

	_log "INFO" "No ratchet-down available: all thresholds within gap of $gap"
	return 1
}

#######################################
# Help
#######################################
cmd_help() {
	cat <<'HELP'
complexity-scan-helper.sh — Deterministic complexity scan (GH#15285)

COMMANDS
  scan <repo_path> [options]    Fast deterministic scan using shell heuristics
    --state-file <path>         Path to simplification-state.json
    --format json|pipe          Output format (default: pipe)
    --type sh|md|py|js|all      File types to scan (default: all)
                                  py = .py files, js = .js/.mjs/.ts files

  sweep-check <repo_slug>      Check if daily LLM sweep is needed
    --stall-hours N             Hours of stall before sweep (default: 6)

  sweep-done                    Record that LLM sweep was performed

  metrics <file_path>           Compute metrics for a single file

  ratchet-check [repo_path] [gap]
                                Compare actual violation counts against thresholds.
                                Outputs proposed new thresholds when gap >= minimum.
                                repo_path: path to repo root (default: .)
                                gap: minimum gap to trigger proposal (default: 5)
                                Exit 0: ratchet-down available, Exit 1: thresholds tight

  help                          Show this help

OUTPUT FORMAT (pipe)
  status|file_path|line_count|func_count|long_func_count|max_nesting|file_type

  status: new, recheck, unchanged
  file_type: shell, markdown, python, javascript, other

ENVIRONMENT
  COMPLEXITY_FUNC_LINE_THRESHOLD     Function length threshold (default: 100)
  COMPLEXITY_FILE_VIOLATION_THRESHOLD Min violations per file (default: 1)
  COMPLEXITY_MD_MIN_LINES            Min lines for .md files (default: 500)
  COMPLEXITY_NESTING_DEPTH_THRESHOLD Max nesting depth (default: 8)
  SWEEP_STALL_HOURS                  Hours before LLM sweep triggers (default: 6)
HELP
	return 0
}

#######################################
# Main dispatch
#######################################
main() {
	local cmd="${1:-help}"
	shift || true

	case "$cmd" in
	scan) cmd_scan "$@" ;;
	sweep-check) cmd_sweep_check "$@" ;;
	sweep-done) cmd_sweep_done ;;
	metrics) cmd_metrics "$@" ;;
	ratchet-check) cmd_ratchet_check "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		_log "ERROR" "Unknown command: $cmd"
		cmd_help
		return 1
		;;
	esac
}

main "$@"
