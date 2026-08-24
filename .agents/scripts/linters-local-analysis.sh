#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2086
# =============================================================================
# Local Linters — Analysis Sub-Library
# =============================================================================
# Code quality analysis, formatting checks, and miscellaneous validation
# functions extracted from linters-local.sh (GH#21296).
#
# Includes:
#   - SonarCloud status (remote API)
#   - Qlty maintainability (local CLI + cloud badge)
#   - Markdown lint (markdownlint-cli2)
#   - TOON syntax validation
#   - Function complexity (Codacy alignment — GH#4939)
#   - Nesting depth (Codacy alignment — GH#4939)
#   - File size (ratchet gate — t2938)
#   - Python complexity (Lizard + Pyflakes)
#   - Remote CLI status
#   - Skill frontmatter validation
#   - Pulse wrapper canary (GH#18790)
#   - Bash 3.2 compatibility
#
# Usage: source "${SCRIPT_DIR}/linters-local-analysis.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning,
#     safe_grep_count, timeout_sec, _save_cleanup_scope, push_cleanup, _run_cleanups)
#   - lint-file-discovery.sh (lint_python_files_local, LINT_PY_FILES_LOCAL)
#   - Constants: MAX_TOTAL_ISSUES, MAX_FUNCTION_LENGTH_WARN, MAX_FUNCTION_LENGTH_BLOCK,
#     MAX_FUNCTION_LENGTH_VIOLATIONS, MAX_NESTING_DEPTH_WARN, MAX_NESTING_DEPTH_BLOCK,
#     MAX_NESTING_VIOLATIONS, MAX_FILE_LINES_WARN, MAX_FILE_LINES_BLOCK
#     (defined in orchestrator before sourcing)
#   - ALL_SH_FILES array (populated by collect_shell_files in orchestrator)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_LINTERS_LOCAL_ANALYSIS_LOADED:-}" ]] && return 0
_LINTERS_LOCAL_ANALYSIS_LOADED=1

# Defensive SCRIPT_DIR fallback (matches issue-sync-lib.sh pattern)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

check_sonarcloud_status() {
	echo -e "${BLUE}Checking SonarCloud Status (remote API)...${NC}"
	local remote_timeout="${LINTERS_LOCAL_REMOTE_TIMEOUT_SECONDS:-15}"

	# Check quality gate status first — this drives the badge colour
	local gate_response
	if gate_response=$(curl -sS --connect-timeout 5 --max-time "$remote_timeout" "https://sonarcloud.io/api/qualitygates/project_status?projectKey=marcusquinn_aidevops" 2>/dev/null); then
		local gate_status
		gate_status=$(echo "$gate_response" | jq -r '.projectStatus.status // "UNKNOWN"')
		if [[ "$gate_status" == "OK" ]]; then
			print_success "SonarCloud Quality Gate: PASSED (badge is green)"
		elif [[ "$gate_status" == "ERROR" ]]; then
			print_error "SonarCloud Quality Gate: FAILED (badge is red)"
			# Show which conditions are failing
			local failing_conditions
			failing_conditions=$(echo "$gate_response" | jq -r '
				[.projectStatus.conditions[]? | select(.status == "ERROR") |
				"  \(.metricKey): actual=\(.actualValue), required \(.comparator) \(.errorThreshold)"]
				| join("\n")
			') || failing_conditions=""
			if [[ -n "$failing_conditions" ]]; then
				echo "Failing conditions:"
				echo "$failing_conditions"
			fi
		else
			print_warning "SonarCloud Quality Gate: ${gate_status}"
		fi
	fi

	local response
	if response=$(curl -sS --connect-timeout 5 --max-time "$remote_timeout" "https://sonarcloud.io/api/issues/search?componentKeys=marcusquinn_aidevops&impactSoftwareQualities=MAINTAINABILITY&resolved=false&ps=1&facets=rules" 2>/dev/null); then
		local total_issues
		total_issues=$(echo "$response" | jq -r '.total // 0')

		echo "Total Issues: $total_issues"

		if [[ $total_issues -le $MAX_TOTAL_ISSUES ]]; then
			print_success "SonarCloud: $total_issues issues (within threshold of $MAX_TOTAL_ISSUES)"
		else
			print_warning "SonarCloud: $total_issues issues (exceeds threshold of $MAX_TOTAL_ISSUES)"
		fi

		# Show top rules by issue count for targeted fixes
		echo "Top rules (fix these for maximum badge improvement):"
		echo "$response" | jq -r '.facets[0].values[:10][] | "  \(.val): \(.count) issues"'
	else
		print_error "Failed to fetch SonarCloud status"
		return 1
	fi

	return 0
}

check_qlty_cloud_grade() {
	local repo_slug=""
	local badge_svg=""
	local grade=""
	repo_slug=$(git remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||;s|\.git$||') || repo_slug=""
	if [[ -z "$repo_slug" ]]; then
		return 0
	fi
	badge_svg=$(curl -sS --fail --connect-timeout 5 --max-time 10 \
		"https://qlty.sh/gh/${repo_slug}/maintainability.svg" 2>/dev/null) || badge_svg=""
	if [[ -z "$badge_svg" ]]; then
		return 0
	fi
	grade=$(python3 -c "
import sys, re
svg = sys.stdin.read()
colors = {'#22C55E':'A','#84CC16':'B','#EAB308':'C','#F97316':'D','#EF4444':'F'}
for c in re.findall(r'fill=\"(#[A-F0-9]+)\"', svg):
    if c in colors:
        print(colors[c])
        sys.exit(0)
print('UNKNOWN')
" <<<"$badge_svg" 2>/dev/null) || grade="UNKNOWN"
	if [[ "$grade" == "A" || "$grade" == "B" ]]; then
		print_success "Qlty Cloud grade: ${grade}"
	elif [[ "$grade" == "C" ]]; then
		print_warning "Qlty Cloud grade: ${grade} (target: A)"
	elif [[ "$grade" == "D" || "$grade" == "F" ]]; then
		print_error "Qlty Cloud grade: ${grade} (needs significant improvement)"
	else
		echo "Qlty Cloud grade: ${grade}"
	fi
	return 0
}

check_qlty_maintainability() {
	echo -e "${BLUE}Checking Qlty Maintainability...${NC}"

	local qlty_bin="${HOME}/.qlty/bin/qlty"
	if [[ ! -x "$qlty_bin" ]]; then
		print_warning "Qlty CLI not installed (run: curl https://qlty.sh | bash)"
		return 0
	fi

	if [[ ! -f ".qlty/qlty.toml" && ! -f ".qlty.toml" ]]; then
		print_warning "No qlty.toml found (run: qlty init)"
		return 0
	fi

	# Use a disposable cache and bounded normalized-identity consensus. Scanner
	# uncertainty is diagnostic and must never be rendered as a clean zero.
	local sarif_output=""
	local first_sarif=""
	local second_sarif=""
	local third_sarif=""
	local cache_dir=""
	local first_ids=""
	local second_ids=""
	local third_ids=""
	cache_dir=$(mktemp -d "${TMPDIR:-/tmp}/qlty-local-cache.XXXXXX") || {
		print_warning "Qlty status: inconclusive (failed to create isolated cache)"
		return 0
	}
	first_sarif=$(XDG_CACHE_HOME="$cache_dir" "$qlty_bin" smells --all --sarif --no-snippets --quiet 2>/dev/null) || true
	second_sarif=$(XDG_CACHE_HOME="$cache_dir" "$qlty_bin" smells --all --sarif --no-snippets --quiet 2>/dev/null) || true
	if ! printf '%s\n' "$first_sarif" | jq -e '.runs[0].results | type == "array"' >/dev/null 2>&1 ||
		! printf '%s\n' "$second_sarif" | jq -e '.runs[0].results | type == "array"' >/dev/null 2>&1; then
		rm -rf "$cache_dir"
		print_warning "Qlty status: inconclusive (empty or invalid SARIF); no numeric result recorded"
		return 0
	fi
	first_ids=$(printf '%s\n' "$first_sarif" | jq -r '.runs[0].results[] | [(.ruleId // "unknown"), ([.locations[]?.physicalLocation?.artifactLocation?.uri? | select(. != null)] | sort | join("|"))] | @tsv' | LC_ALL=C sort)
	second_ids=$(printf '%s\n' "$second_sarif" | jq -r '.runs[0].results[] | [(.ruleId // "unknown"), ([.locations[]?.physicalLocation?.artifactLocation?.uri? | select(. != null)] | sort | join("|"))] | @tsv' | LC_ALL=C sort)
	if [[ "$first_ids" == "$second_ids" ]]; then
		sarif_output="$second_sarif"
	else
		third_sarif=$(XDG_CACHE_HOME="$cache_dir" "$qlty_bin" smells --all --sarif --no-snippets --quiet 2>/dev/null) || true
		if ! printf '%s\n' "$third_sarif" | jq -e '.runs[0].results | type == "array"' >/dev/null 2>&1; then
			rm -rf "$cache_dir"
			print_warning "Qlty status: inconclusive (invalid third SARIF); no numeric result recorded"
			return 0
		fi
		third_ids=$(printf '%s\n' "$third_sarif" | jq -r '.runs[0].results[] | [(.ruleId // "unknown"), ([.locations[]?.physicalLocation?.artifactLocation?.uri? | select(. != null)] | sort | join("|"))] | @tsv' | LC_ALL=C sort)
		if [[ "$first_ids" == "$third_ids" || "$second_ids" == "$third_ids" ]]; then
			sarif_output="$third_sarif"
		else
			rm -rf "$cache_dir"
			print_warning "Qlty status: inconclusive (unstable normalized identities); no numeric result recorded"
			return 0
		fi
	fi
	rm -rf "$cache_dir"

	if [[ -n "$sarif_output" ]]; then
		local smell_count
		smell_count=$(echo "$sarif_output" | jq '.runs[0].results | length' 2>/dev/null) || smell_count="inconclusive"
		if [[ ! "$smell_count" =~ ^[0-9]+$ ]]; then
			print_warning "Qlty status: inconclusive (unparseable count); no numeric result recorded"
			return 0
		fi

		if [[ "$smell_count" -eq 0 ]]; then
			print_success "Qlty: 0 smells (clean)"
		elif [[ "$smell_count" -le 20 ]]; then
			print_success "Qlty: ${smell_count} smells (good)"
		elif [[ "$smell_count" -le 50 ]]; then
			print_warning "Qlty: ${smell_count} smells (needs attention)"
		else
			print_warning "Qlty: ${smell_count} smells (high — impacts maintainability grade)"
		fi

		# Show top rules for targeted fixes
		if [[ "$smell_count" -gt 0 ]]; then
			echo "Top smell types:"
			echo "$sarif_output" | jq -r '
				[.runs[0].results[].ruleId] | group_by(.) |
				map({rule: .[0], count: length}) | sort_by(-.count)[:5][] |
				"  \(.rule): \(.count)"
			' 2>/dev/null

			echo "Top files:"
			echo "$sarif_output" | jq -r '
				[.runs[0].results[].locations[0].physicalLocation.artifactLocation.uri] |
				group_by(.) | map({file: .[0], count: length}) | sort_by(-.count)[:5][] |
				"  \(.file): \(.count) smells"
			' 2>/dev/null
		fi
	else
		print_warning "Qlty analysis returned empty"
	fi

	check_qlty_cloud_grade

	return 0
}

# Resolve the markdownlint binary path, or return empty string if not found.
_find_markdownlint_cmd() {
	if command -v markdownlint &>/dev/null; then
		echo "markdownlint"
	elif command -v markdownlint-cli2 &>/dev/null; then
		echo "markdownlint-cli2"
	elif [[ -f "node_modules/.bin/markdownlint" ]]; then
		echo "node_modules/.bin/markdownlint"
	elif [[ -f "node_modules/.bin/markdownlint-cli2" ]]; then
		echo "node_modules/.bin/markdownlint-cli2"
	fi
	return 0
}

# Populate md_files and check_mode for check_markdown_lint.
# Outputs two lines: first is check_mode ("changed"|"all"), rest are file paths.
# Callers split on the first line to get mode, remainder for files.
_collect_markdown_files() {
	local md_files check_mode="changed"

	if [[ "${LINTERS_LOCAL_MODE:-full}" == "changed" ]] && declare -F linters_local_changed_files_matching >/dev/null 2>&1; then
		md_files=$(linters_local_changed_files_matching '\.md$')
		echo "$check_mode"
		echo "$md_files"
		return 0
	fi

	if git rev-parse --git-dir >/dev/null 2>&1; then
		md_files=$(git diff --name-only --diff-filter=ACMR HEAD -- '*.md' 2>/dev/null)

		if [[ -z "$md_files" ]]; then
			local base_branch
			base_branch=$(git merge-base HEAD main 2>/dev/null || git merge-base HEAD master 2>/dev/null || echo "")
			if [[ -n "$base_branch" ]]; then
				md_files=$(git diff --name-only "$base_branch" HEAD -- '*.md' 2>/dev/null)
			fi
		fi

		if [[ -z "$md_files" ]]; then
			md_files=$(git ls-files '.agents/**/*.md' 2>/dev/null)
			check_mode="all"
		fi
	else
		md_files=$(find . -name "*.md" -type f 2>/dev/null | grep -v node_modules)
		check_mode="all"
	fi

	echo "$check_mode"
	echo "$md_files"
	return 0
}

# Report markdownlint output and return appropriate exit code.
# Arguments: $1=lint_output $2=lint_exit $3=check_mode
_report_markdown_result() {
	local lint_output="$1"
	local lint_exit="$2"
	local check_mode="$3"
	local violations=0

	if [[ -n "$lint_output" ]]; then
		local violation_count
		violation_count=$(echo "$lint_output" | grep -c "MD[0-9]" 2>/dev/null) || violation_count=0
		if ! [[ "$violation_count" =~ ^[0-9]+$ ]]; then
			violation_count=0
		fi
		violations=$violation_count

		if [[ $violations -gt 0 ]]; then
			echo "$lint_output" | head -10
			if [[ $violations -gt 10 ]]; then
				echo "... and $((violations - 10)) more"
			fi
			print_info "Run: markdownlint --fix <file> (or markdownlint-cli2 --fix <glob>)"
			if [[ "$check_mode" == "changed" ]]; then
				print_error "Markdown: $violations style issues in changed files (BLOCKING)"
				return 1
			else
				print_warning "Markdown: $violations style issues found (advisory)"
				return 0
			fi
		elif [[ $lint_exit -ne 0 ]]; then
			print_error "Markdown: markdownlint failed with exit code $lint_exit (non-rule error)"
			echo "$lint_output"
			[[ "$check_mode" == "changed" ]] && return 1
			return 0
		fi
	elif [[ $lint_exit -ne 0 ]]; then
		print_error "Markdown: markdownlint failed with exit code $lint_exit (no output)"
		[[ "$check_mode" == "changed" ]] && return 1
		return 0
	fi

	print_success "Markdown: No style issues found"
	return 0
}

# Check AI-Powered Quality CLIs integration
check_markdown_lint() {
	print_info "Checking Markdown Style..."

	local markdownlint_cmd
	markdownlint_cmd=$(_find_markdownlint_cmd)

	# Collect files and mode (first line = mode, rest = file paths)
	local collected check_mode md_files
	collected=$(_collect_markdown_files)
	check_mode=$(echo "$collected" | head -1)
	md_files=$(echo "$collected" | tail -n +2)

	if [[ -z "$md_files" ]]; then
		print_success "Markdown: No markdown files to check"
		return 0
	fi

	if [[ -n "$markdownlint_cmd" ]]; then
		local lint_output lint_exit=0
		lint_output=$($markdownlint_cmd $md_files 2>&1) || lint_exit=$?
		_report_markdown_result "$lint_output" "$lint_exit" "$check_mode"
		return $?
	fi

	# Fallback: markdownlint not installed
	# NOTE: Without markdownlint, we can't reliably detect MD031/MD040 violations
	# because we can't distinguish opening fences (need language) from closing fences (always bare)
	print_warning "Markdown: markdownlint not installed - cannot perform full lint checks"
	print_info "Install: npm install -g markdownlint-cli2 (or markdownlint-cli)"
	print_info "Then re-run to get blocking checks for changed files"
	return 0
}

# Check TOON file syntax
check_toon_syntax() {
	print_info "Checking TOON Syntax..."

	local toon_files
	local violations=0

	# Find .toon files in the repo
	if git rev-parse --git-dir >/dev/null 2>&1; then
		toon_files=$(git ls-files '*.toon' 2>/dev/null)
	else
		toon_files=$(find . -name "*.toon" -type f 2>/dev/null | grep -v node_modules)
	fi

	if [[ -z "$toon_files" ]]; then
		print_success "TOON: No .toon files to check"
		return 0
	fi

	local file_count
	file_count=$(echo "$toon_files" | wc -l | tr -d ' ')

	# Use toon-lsp check if available, otherwise basic validation
	if command -v toon-lsp &>/dev/null; then
		while IFS= read -r file; do
			if [[ -f "$file" ]]; then
				local result
				result=$(toon-lsp check "$file" 2>&1)
				local exit_code=$?
				if [[ $exit_code -ne 0 ]] || [[ "$result" == *"error"* ]]; then
					((++violations))
					print_warning "TOON syntax issue in $file"
				fi
			fi
		done <<<"$toon_files"
	else
		# Fallback: basic structure validation (non-empty check)
		while IFS= read -r file; do
			if [[ -f "$file" ]] && [[ ! -s "$file" ]]; then
				((++violations))
				print_warning "TOON: Empty file $file"
			fi
		done <<<"$toon_files"
	fi

	if [[ $violations -eq 0 ]]; then
		print_success "TOON: All $file_count files valid"
	else
		print_warning "TOON: $violations of $file_count files with issues"
	fi

	return 0
}

# =============================================================================
# Function Complexity Check (Codacy alignment — GH#4939)
# =============================================================================
# Codacy flags functions exceeding length thresholds. This local check catches
# the same issues before code reaches Codacy, preventing quality gate failures.
# Aligned with Codacy's ShellCheck + complexity engine.

_COMPLEXITY_METRIC_FUNCTION="function-complexity"
_COMPLEXITY_METRIC_NESTING="nesting-depth"

_complexity_merge_base() {
	local base_ref="${LINTERS_LOCAL_COMPLEXITY_BASE_REF:-origin/main}"
	local head_ref="${LINTERS_LOCAL_COMPLEXITY_HEAD_REF:-HEAD}"

	git merge-base "$head_ref" "$base_ref" 2>/dev/null
	return $?
}

_complexity_changed_shell_files() {
	local base_ref="$1"
	local changed_files_buffer=""
	local chunk=""

	[[ -n "$base_ref" ]] && chunk=$(git diff --name-only "$base_ref"...HEAD 2>/dev/null || true)
	changed_files_buffer="$chunk"

	chunk=$(git diff --name-only 2>/dev/null || true)
	[[ -n "$chunk" ]] && changed_files_buffer=$(printf '%s\n%s\n' "$changed_files_buffer" "$chunk")

	chunk=$(git diff --cached --name-only 2>/dev/null || true)
	[[ -n "$chunk" ]] && changed_files_buffer=$(printf '%s\n%s\n' "$changed_files_buffer" "$chunk")

	printf '%s\n' "$changed_files_buffer" | grep -E '\.sh$' | grep -Ev '_archive/' | sort -u || true
	return 0
}

_scan_function_complexity_file() {
	local file="$1"
	local rel_file="$2"
	local out_file="$3"

	awk -v file="$rel_file" -v block="$MAX_FUNCTION_LENGTH_BLOCK" '
		/^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ {
			fname = $1
			sub(/\(\).*/, "", fname)
			start = NR
			next
		}
		fname && /^[[:space:]]*\}[[:space:]]*$/ {
			lines = NR - start; if (lines > block) { printf "%s\t%s\t%d\n", file, fname, lines }
			fname = ""
		}
	' "$file" >>"$out_file"
	return 0
}

_scan_function_complexity_git_blob() {
	local base_ref="$1"
	local rel_file="$2"
	local out_file="$3"

	git show "${base_ref}:${rel_file}" 2>/dev/null | awk -v file="$rel_file" -v block="$MAX_FUNCTION_LENGTH_BLOCK" '
		/^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ {
			fname = $1
			sub(/\(\).*/, "", fname)
			start = NR
			next
		}
		fname && /^[[:space:]]*\}[[:space:]]*$/ {
			lines = NR - start; if (lines > block) { printf "%s\t%s\t%d\n", file, fname, lines }
			fname = ""
		}
	' >>"$out_file"
	return 0
}

_nesting_depth_awk_program() {
	cat <<'AWK'
function emit_result(current_file) {
	current_file = (file != "" ? file : previous_file)
	if (summary == 1) {
		if (max_depth > block) {
			printf "BLOCK %s:%d max nesting depth %d (max %d)\n", current_file, max_line, max_depth, block
		} else if (max_depth > warn) {
			printf "WARN %s:%d max nesting depth %d (max %d)\n", current_file, max_line, max_depth, warn
		}
	} else if (max_depth > block) {
		printf "%s\tNEST\t%d\n", current_file, max_depth
	}
}
FNR == 1 {
	if (NR > 1) emit_result()
	depth = 0; max_depth = 0; max_line = 0; heredoc = ""
	previous_file = (file != "" ? file : FILENAME)
}
heredoc != "" { end_line = $0; sub(/^[\t]+/, "", end_line); if (end_line == heredoc) { heredoc = "" }; next }
/<</ { marker = $0; sub(/^.*<</, "", marker); sub(/^-/, "", marker); gsub(/^[ \t]+|[ \t]+$/, "", marker); gsub(/^["\047]|["\047]$/, "", marker); sub(/[ \t].*$/, "", marker); if (marker ~ /^[A-Za-z_][A-Za-z0-9_]*$/) { heredoc = marker; next } }
/^[[:space:]]*#/ { next }
/^[[:space:]]*(if|for|while|until|case)[[:space:]]/ { depth++; max_depth = (depth > max_depth ? depth : max_depth); max_line = (depth == max_depth ? FNR : max_line) }
/^[[:space:]]*(fi|done|esac)($|[[:space:]])/ { if (depth > 0) depth-- }
END { emit_result() }
AWK
	return 0
}

_scan_nesting_depth_file() {
	local file="$1"
	local rel_file="$2"
	local out_file="$3"

	awk -v file="$rel_file" -v block="$MAX_NESTING_DEPTH_BLOCK" "$(_nesting_depth_awk_program)" "$file" >>"$out_file"
	return 0
}

_scan_nesting_depth_git_blob() {
	local base_ref="$1"
	local rel_file="$2"
	local out_file="$3"

	git show "${base_ref}:${rel_file}" 2>/dev/null | awk -v file="$rel_file" -v block="$MAX_NESTING_DEPTH_BLOCK" "$(_nesting_depth_awk_program)" >>"$out_file"
	return 0
}

_print_new_complexity_regressions() {
	local new_file="$1"
	local label="$2"
	local count
	count=$(safe_grep_count '.' "$new_file")
	count=${count//[^0-9]/}
	count=${count:-0}

	[[ "$count" -eq 0 ]] && return 0

	print_error "$label: $count new changed-file blocking regression(s)"
	awk -F '\t' '{ printf "  %s:%s %s\n", $1, $2, $3 }' "$new_file" | head -10
	[[ "$count" -gt 10 ]] && echo "  ... and $((count - 10)) more"
	return 1
}

_scan_changed_complexity_base_file() {
	local metric="$1"
	local base_ref="$2"
	local rel_file="$3"
	local base_scan="$4"

	git cat-file -e "${base_ref}:${rel_file}" 2>/dev/null || return 0

	[[ "$metric" == "$_COMPLEXITY_METRIC_FUNCTION" ]] && _scan_function_complexity_git_blob "$base_ref" "$rel_file" "$base_scan"
	[[ "$metric" == "$_COMPLEXITY_METRIC_NESTING" ]] && _scan_nesting_depth_git_blob "$base_ref" "$rel_file" "$base_scan"
	return 0
}

_scan_changed_complexity_head_file() {
	local metric="$1"
	local rel_file="$2"
	local head_scan="$3"

	[[ -f "$rel_file" ]] || return 0

	[[ "$metric" == "$_COMPLEXITY_METRIC_FUNCTION" ]] && _scan_function_complexity_file "$rel_file" "$rel_file" "$head_scan"
	[[ "$metric" == "$_COMPLEXITY_METRIC_NESTING" ]] && _scan_nesting_depth_file "$rel_file" "$rel_file" "$head_scan"
	return 0
}

_check_changed_file_complexity_regressions() {
	local metric="$1"
	local label="$2"
	local base_ref changed_files base_scan head_scan new_scan
	base_ref=$(_complexity_merge_base) || base_ref=""

	[[ -n "$base_ref" ]] || {
		print_warning "$label: no merge-base with origin/main; treating total scan as advisory"
		return 0
	}

	changed_files=$(_complexity_changed_shell_files "$base_ref")
	[[ -n "$changed_files" ]] || {
		print_info "$label: no changed shell files; historical debt is advisory"
		return 0
	}

	base_scan=$(mktemp)
	head_scan=$(mktemp)
	new_scan=$(mktemp)
	push_cleanup "rm -f '${base_scan}' '${head_scan}' '${new_scan}'"

	local rel_file
	printf '%s\n' "$changed_files" | while IFS= read -r rel_file; do
		[[ -n "$rel_file" ]] || continue
		_scan_changed_complexity_base_file "$metric" "$base_ref" "$rel_file" "$base_scan"
		_scan_changed_complexity_head_file "$metric" "$rel_file" "$head_scan"
	done

	awk -F '\t' 'FILENAME == ARGV[1] { seen[$1 "\t" $2] = 1; next } !seen[$1 "\t" $2] { print }' \
		"$base_scan" "$head_scan" >"$new_scan"

	_print_new_complexity_regressions "$new_scan" "$label"
	return $?
}

check_function_complexity() {
	echo -e "${BLUE}Checking Function Complexity (Codacy alignment)...${NC}"

	local block_violations=0
	local warn_violations=0
	local tmp_file
	tmp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_file}'"

	if [[ ${#ALL_SH_FILES[@]} -gt 0 ]]; then
		# Scan the shared inventory in one process instead of one awk per file.
		awk -v warn="$MAX_FUNCTION_LENGTH_WARN" -v block="$MAX_FUNCTION_LENGTH_BLOCK" '
			FNR == 1 { fname = "" }
			/^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ {
				fname = $1
				sub(/\(\)/, "", fname)
				start = FNR
				next
			}
			fname && /^[[:space:]]*\}[[:space:]]*$/ {
				lines = FNR - start
				if (lines > block) {
					printf "BLOCK %s:%d %s() %d lines (max %d)\n", FILENAME, start, fname, lines, block
				} else if (lines > warn) {
					printf "WARN %s:%d %s() %d lines (max %d)\n", FILENAME, start, fname, lines, warn
				}
				fname = ""
			}
		' "${ALL_SH_FILES[@]}" >>"$tmp_file"
	fi

	if [[ -s "$tmp_file" ]]; then
		block_violations=$(safe_grep_count '^BLOCK' "$tmp_file")
		warn_violations=$(safe_grep_count '^WARN' "$tmp_file")
		block_violations=${block_violations//[^0-9]/}
		warn_violations=${warn_violations//[^0-9]/}
		block_violations=${block_violations:-0}
		warn_violations=${warn_violations:-0}

		if [[ "$block_violations" -gt 0 ]]; then
			print_error "Function complexity: $block_violations functions exceed ${MAX_FUNCTION_LENGTH_BLOCK} lines (must refactor)"
			grep '^BLOCK' "$tmp_file" | sed 's/^BLOCK /  /' | head -10
			if [[ "$block_violations" -gt 10 ]]; then
				echo "  ... and $((block_violations - 10)) more"
			fi
		fi

		if [[ "$warn_violations" -gt 0 ]]; then
			print_warning "Function complexity: $warn_violations functions exceed ${MAX_FUNCTION_LENGTH_WARN} lines (advisory)"
			grep '^WARN' "$tmp_file" | sed 's/^WARN /  /' | head -5
			if [[ "$warn_violations" -gt 5 ]]; then
				echo "  ... and $((warn_violations - 5)) more"
			fi
		fi
	fi

	local total=$((block_violations + warn_violations))
	if ! _check_changed_file_complexity_regressions "$_COMPLEXITY_METRIC_FUNCTION" "Function complexity"; then
		return 1
	fi

	if [[ "$block_violations" -gt "$MAX_FUNCTION_LENGTH_VIOLATIONS" ]]; then
		print_warning "Function complexity: $block_violations historical blocking violations exceed baseline threshold $MAX_FUNCTION_LENGTH_VIOLATIONS (advisory unless changed-file regression)"
		return 0
	fi

	print_success "Function complexity: $total oversized functions ($block_violations blocking, $warn_violations advisory)"
	return 0
}

# =============================================================================
# Nesting Depth Check (Codacy alignment — GH#4939)
# =============================================================================
# Codacy flags deeply nested control flow (if/for/while/case). Deep nesting
# indicates functions that should be decomposed. This catches the same pattern
# locally.

check_nesting_depth() {
	echo -e "${BLUE}Checking Nesting Depth (Codacy alignment)...${NC}"

	local block_violations=0
	local warn_violations=0
	local tmp_file
	tmp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_file}'"

	if [[ ${#ALL_SH_FILES[@]} -gt 0 ]]; then
		# This is a heuristic — not a full parser — but one process is sufficient
		# because the awk program resets and emits metrics at each file boundary.
		awk -v warn="$MAX_NESTING_DEPTH_WARN" -v block="$MAX_NESTING_DEPTH_BLOCK" -v summary=1 \
			"$(_nesting_depth_awk_program)" "${ALL_SH_FILES[@]}" >>"$tmp_file"
	fi

	if [[ -s "$tmp_file" ]]; then
		block_violations=$(safe_grep_count '^BLOCK' "$tmp_file")
		warn_violations=$(safe_grep_count '^WARN' "$tmp_file")
		block_violations=${block_violations//[^0-9]/}
		warn_violations=${warn_violations//[^0-9]/}
		block_violations=${block_violations:-0}
		warn_violations=${warn_violations:-0}

		if [[ "$block_violations" -gt 0 ]]; then
			print_error "Nesting depth: $block_violations files exceed depth ${MAX_NESTING_DEPTH_BLOCK} (must refactor)"
			grep '^BLOCK' "$tmp_file" | sed 's/^BLOCK /  /' | head -10
		fi

		if [[ "$warn_violations" -gt 0 ]]; then
			print_warning "Nesting depth: $warn_violations files exceed depth ${MAX_NESTING_DEPTH_WARN} (advisory)"
			grep '^WARN' "$tmp_file" | sed 's/^WARN /  /' | head -5
		fi
	fi

	local total=$((block_violations + warn_violations))
	if ! _check_changed_file_complexity_regressions "$_COMPLEXITY_METRIC_NESTING" "Nesting depth"; then
		return 1
	fi

	if [[ "$block_violations" -gt "$MAX_NESTING_VIOLATIONS" ]]; then
		print_warning "Nesting depth: $block_violations historical blocking violations exceed baseline threshold $MAX_NESTING_VIOLATIONS (advisory unless changed-file regression)"
		return 0
	fi

	print_success "Nesting depth: $total files with deep nesting ($block_violations blocking, $warn_violations advisory)"
	return 0
}

append_file_size_result() {
	local file="$1"
	local result_file="$2"
	local warn_limit="$3"
	local block_limit="$4"

	[[ -f "$file" ]] || return 0

	local line_count
	line_count=$(wc -l <"$file")
	line_count=${line_count//[^0-9]/}
	line_count=${line_count:-0}

	if [[ "$line_count" -gt "$block_limit" ]]; then
		printf 'BLOCK %s: %d lines (max %d)\n' "$file" "$line_count" "$block_limit" >>"$result_file"
	elif [[ "$line_count" -gt "$warn_limit" ]]; then
		printf 'WARN %s: %d lines (max %d)\n' "$file" "$line_count" "$warn_limit" >>"$result_file"
	fi

	return 0
}

# =============================================================================
# File Size Check — ratchet-based gate (t2938)
# =============================================================================
# Block only when this commit introduces a net increase in non-README Markdown
# files >500 lines, or adds a brand-new non-README Markdown file >500 lines.
# Code file size is not gated here; function-complexity/nesting-depth gates
# provide more actionable code limits. Pre-existing debt does not block.
# Framework rule: t2228 — "Any gate MUST be ratchet-based: block only on regressions."
#
# Parity: matches the per-file regression check in code-quality.yml "File size check"
# step, which already uses complexity-regression-helper.sh with the same semantics.
#
# The local display mirrors the ratchet scope: non-README Markdown only.

check_file_size() {
	echo -e "${BLUE}Checking File Size (ratchet gate — t2938)...${NC}"

	local block_violations=0
	local warn_violations=0
	local tmp_file
	tmp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_file}'"

	local md_files=""
	md_files=$(git ls-files '*.md' 2>/dev/null | grep -Ev '(^|/)README\.md$|_archive/' || true)
	while IFS= read -r file; do
		[[ -n "$file" ]] || continue
		append_file_size_result "$file" "$tmp_file" "$MAX_FILE_LINES_WARN" "$MAX_FILE_LINES_BLOCK"
	done <<<"$md_files"

	if [[ -s "$tmp_file" ]]; then
		block_violations=$(safe_grep_count '^BLOCK' "$tmp_file")
		warn_violations=$(safe_grep_count '^WARN' "$tmp_file")
		block_violations=${block_violations//[^0-9]/}
		warn_violations=${warn_violations//[^0-9]/}
		block_violations=${block_violations:-0}
		warn_violations=${warn_violations:-0}

		# Advisory display — show non-README Markdown files for developer awareness.
		# These are informational; the ratchet gate below decides whether to block.
		if [[ "$block_violations" -gt 0 ]]; then
			print_warning "File size: $block_violations non-README Markdown files exceed ${MAX_FILE_LINES_BLOCK} lines (should be split or indexed)"
			grep '^BLOCK' "$tmp_file" | sed 's/^BLOCK /  /' | head -10
		fi

		if [[ "$warn_violations" -gt 0 ]]; then
			print_warning "File size: $warn_violations files exceed ${MAX_FILE_LINES_WARN} lines (advisory)"
			grep '^WARN' "$tmp_file" | sed 's/^WARN /  /' | head -5
		fi
	fi

	# --- Ratchet gate: block only on net regression against origin base ---
	local helper_script="${SCRIPT_DIR}/file-size-regression-helper.sh"

	if [[ ! -x "$helper_script" ]]; then
		local total=$((block_violations + warn_violations))
		print_warning "File size: helper not found — gate skipped (fail-open). $total oversized files total."
		return 0
	fi

	local ratchet_exit=0
	"$helper_script" check || ratchet_exit=$?

	if [[ "$ratchet_exit" -eq 0 ]]; then
		local total=$((block_violations + warn_violations))
		print_success "File size: no regression. $total oversized non-README Markdown files ($block_violations over ${MAX_FILE_LINES_BLOCK}, $warn_violations advisory). Tracked by #21146."
		return 0
	fi

	print_error "File size: regression — new non-README Markdown file(s) added over ${MAX_FILE_LINES_BLOCK} lines. Split/index before committing, or add the 'complexity-bump-ok' label in the PR."
	return 1
}

# =============================================================================
# Python Complexity Check (Codacy alignment — GH#4939)
# =============================================================================
# Codacy uses Lizard for cyclomatic complexity analysis on Python files.
# This local check runs the same tool with the same threshold (CCN > 8)
# to catch complexity issues before they reach Codacy.
# Also checks for unused imports (pyflakes) and security patterns (semgrep-lite).

check_python_complexity() {
	echo -e "${BLUE}Checking Python Complexity (Codacy alignment)...${NC}"

	# Collect Python files (shared discovery)
	lint_python_files_local
	local py_files=("${LINT_PY_FILES_LOCAL[@]}")

	if [[ ${#py_files[@]} -eq 0 ]]; then
		print_info "No Python files found in .agents/scripts/"
		return 0
	fi

	local violations=0
	local warnings=0

	# Check 1: Lizard cyclomatic complexity (same tool Codacy uses)
	if command -v lizard &>/dev/null; then
		local lizard_out
		lizard_out=$(lizard --CCN 8 --warnings_only "${py_files[@]}" 2>/dev/null || true)
		if [[ -n "$lizard_out" ]]; then
			local lizard_count
			lizard_count=$(echo "$lizard_out" | safe_grep_count "warning:")
			lizard_count=${lizard_count//[^0-9]/}
			lizard_count=${lizard_count:-0}
			violations=$((violations + lizard_count))

			if [[ "$lizard_count" -gt 0 ]]; then
				print_warning "Lizard: $lizard_count functions exceed cyclomatic complexity 8"
				echo "$lizard_out" | grep "warning:" | head -10
				if [[ "$lizard_count" -gt 10 ]]; then
					echo "  ... and $((lizard_count - 10)) more"
				fi
			fi
		fi
	else
		print_info "Lizard not installed (pipx install lizard) — skipping cyclomatic complexity"
	fi

	# Check 2: Pyflakes for unused imports (Codacy uses Prospector/pyflakes)
	if command -v pyflakes &>/dev/null; then
		local pyflakes_out
		pyflakes_out=$(pyflakes "${py_files[@]}" 2>/dev/null || true)
		if [[ -n "$pyflakes_out" ]]; then
			local pyflakes_count
			pyflakes_count=$(echo "$pyflakes_out" | safe_grep_count .)
			pyflakes_count=${pyflakes_count//[^0-9]/}
			pyflakes_count=${pyflakes_count:-0}
			warnings=$((warnings + pyflakes_count))

			if [[ "$pyflakes_count" -gt 0 ]]; then
				print_warning "Pyflakes: $pyflakes_count issues (unused imports, undefined names)"
				echo "$pyflakes_out" | head -10
				if [[ "$pyflakes_count" -gt 10 ]]; then
					echo "  ... and $((pyflakes_count - 10)) more"
				fi
			fi
		fi
	else
		print_info "Pyflakes not installed (pipx install pyflakes) — skipping import checks"
	fi

	local total=$((violations + warnings))
	# Python complexity is advisory for now — Codacy is the hard gate.
	# This gives early feedback without blocking local development.
	if [[ "$total" -eq 0 ]]; then
		print_success "Python complexity: ${#py_files[@]} files checked, no issues"
	else
		print_warning "Python complexity: $total issues ($violations complexity, $warnings pyflakes)"
	fi
	return 0
}

check_remote_cli_status() {
	print_info "Remote Audit CLIs Status (use /code-audit-remote for full analysis)..."

	# Secretlint
	local secretlint_script=".agents/scripts/secretlint-helper.sh"
	if [[ -f "$secretlint_script" ]]; then
		# Check global, local, and main repo node_modules (worktree support)
		local sl_found=false
		if command -v secretlint &>/dev/null || [[ -f "node_modules/.bin/secretlint" ]]; then
			sl_found=true
		else
			local sl_repo_root
			sl_repo_root=$(git rev-parse --git-common-dir 2>/dev/null | xargs -I{} sh -c 'cd "{}/.." && pwd' 2>/dev/null || echo "")
			if [[ -n "$sl_repo_root" ]] && [[ "$sl_repo_root" != "$(pwd)" ]] && [[ -f "$sl_repo_root/node_modules/.bin/secretlint" ]]; then
				sl_found=true
			fi
		fi
		if [[ "$sl_found" == "true" ]]; then
			print_success "Secretlint: Ready"
		else
			print_info "Secretlint: Available for setup"
		fi
	fi

	# CodeRabbit CLI
	local coderabbit_script=".agents/scripts/coderabbit-cli.sh"
	if [[ -f "$coderabbit_script" ]]; then
		if bash "$coderabbit_script" status >/dev/null 2>&1; then
			print_success "CodeRabbit CLI: Ready"
		else
			print_info "CodeRabbit CLI: Available for setup"
		fi
	fi

	# Codacy CLI
	local codacy_script=".agents/scripts/codacy-cli.sh"
	if [[ -f "$codacy_script" ]]; then
		if bash "$codacy_script" status >/dev/null 2>&1; then
			print_success "Codacy CLI: Ready"
		else
			print_info "Codacy CLI: Available for setup"
		fi
	fi

	# SonarScanner CLI
	local sonar_script=".agents/scripts/sonarscanner-cli.sh"
	if [[ -f "$sonar_script" ]]; then
		if bash "$sonar_script" status >/dev/null 2>&1; then
			print_success "SonarScanner CLI: Ready"
		else
			print_info "SonarScanner CLI: Available for setup"
		fi
	fi

	return 0
}

# =============================================================================
# Skill Frontmatter Validation
# =============================================================================
# Validates that all imported skills registered in skill-sources.json have a
# 'name' field in their YAML frontmatter matching the registered skill name.
# This prevents opencode startup errors from missing name fields.

check_skill_frontmatter() {
	echo -e "${BLUE}Checking Skill Frontmatter...${NC}"

	local skill_sources=".agents/configs/skill-sources.json"

	if [[ ! -f "$skill_sources" ]]; then
		print_info "No skill-sources.json found (skipping)"
		return 0
	fi

	if ! command -v jq &>/dev/null; then
		print_info "jq not available (skipping skill frontmatter check)"
		return 0
	fi

	local skill_count
	if ! skill_count=$(jq -er '
		if (.skills | type) == "array" then (.skills | length)
		else error(".skills must be an array")
		end
	' "$skill_sources" 2>/dev/null); then
		print_error "Invalid $skill_sources (cannot parse .skills array)"
		return 1
	fi

	if [[ "$skill_count" -eq 0 ]]; then
		print_info "No imported skills to validate"
		return 0
	fi

	local errors=0
	local checked=0

	local skill_entries
	if ! skill_entries=$(jq -er '.skills[] | "\(.name)|\(.local_path)"' "$skill_sources" 2>/dev/null); then
		print_error "Failed to read skill entries from $skill_sources"
		return 1
	fi

	while IFS='|' read -r name local_path; do
		if [[ ! -f "$local_path" ]]; then
			print_warning "Skill file missing: $local_path (skill: $name)"
			((++errors))
			continue
		fi

		# Extract name from YAML frontmatter (initial block only)
		local fm_name
		fm_name=$(awk '
			NR == 1 && /^---$/ { in_fm = 1; next }
			in_fm && /^---$/ { exit }
			in_fm && /^[[:space:]]*name:[[:space:]]*/ {
				sub(/^[[:space:]]*name:[[:space:]]*/, "")
				sub(/[[:space:]]+#.*$/, "")
				gsub(/^["'"'"']|["'"'"']$/, "")
				print
				exit
			}
		' "$local_path")

		if [[ -z "$fm_name" ]]; then
			print_error "Missing 'name' field in frontmatter: $local_path (expected: $name)"
			((++errors))
		elif [[ "$fm_name" != "$name" ]]; then
			print_error "Name mismatch in $local_path: got '$fm_name', expected '$name'"
			((++errors))
		fi

		((++checked))
	done <<<"$skill_entries"

	if [[ $errors -eq 0 ]]; then
		print_success "Skill frontmatter: $checked skills validated, all have correct 'name' field"
	else
		print_error "Skill frontmatter: $errors error(s) in $checked skills"
		return 1
	fi

	return 0
}

# =============================================================================
# Pulse Wrapper Canary (GH#18790)
# =============================================================================
# Runs pulse-wrapper.sh --canary in a sandboxed HOME. Catches the set -e
# exit-code propagation regression class (GH#18770) that static analysis
# cannot detect. Fast: exits after acquire_instance_lock, no side effects.

check_pulse_canary() {
	echo -e "${BLUE}Checking Pulse Wrapper Canary (GH#18790)...${NC}"

	local wrapper_script=".agents/scripts/pulse-wrapper.sh"
	if [[ ! -f "$wrapper_script" ]]; then
		print_error "pulse-wrapper.sh not found at $wrapper_script"
		return 1
	fi

	local sandbox rc output sandbox_home defaults_source defaults_target
	sandbox=$(mktemp -d)
	sandbox_home="${sandbox}/home"
	defaults_source=".agents/configs/aidevops.defaults.jsonc"
	defaults_target="${sandbox_home}/.aidevops/agents/configs/aidevops.defaults.jsonc"
	mkdir -p "${sandbox_home}/.aidevops/agents/configs"
	if [[ -f "$defaults_source" ]]; then
		cp "$defaults_source" "$defaults_target"
	fi

	output=$(
		HOME="$sandbox_home" \
			FULL_LOOP_HEADLESS=1 \
			timeout_sec 30 bash "$wrapper_script" --canary 2>&1
	)
	rc=$?
	rm -rf "$sandbox"

	if [[ "$rc" -eq 0 ]]; then
		print_success "Pulse canary: ok (sourcing + _pulse_handle_self_check + acquire_instance_lock)"
		return 0
	fi

	if [[ "$rc" -eq 124 || "$rc" -eq 143 ]]; then
		print_warning "Pulse canary infrastructure timeout/interruption (exit $rc). Output: ${output}"
		print_info "Canary source-code regression classification is reserved for non-timeout exits; rerun bash .agents/scripts/tests/test-pulse-wrapper-canary.sh for the focused runtime check."
		return 0
	fi

	print_error "Pulse canary failed (exit $rc). Output: ${output}"
	print_info "This indicates a set -e exit-code regression in pulse-wrapper.sh (see GH#18770)."
	return 1
}

# =============================================================================
# Bash 3.2 Compatibility Check
# =============================================================================
# macOS ships bash 3.2.57. Bash 4.0+ features silently crash or produce wrong
# results — no error message, just broken behaviour. ShellCheck does NOT catch
# most version incompatibilities, so this is a dedicated scanner.

# _scan_bash32_file: scan a single file for bash 4.0+ incompatibilities.
# Appends findings to tmp_file. Args: $1=file $2=tmp_file
# Returns: 0 always.
_scan_bash32_file() {
	local file="$1"
	local tmp_file="$2"

	# declare -A / local -A (associative arrays — bash 4.0+)
	grep -nE '^[[:space:]]*(declare|local)[[:space:]]+-A[[:space:]]' "$file" 2>/dev/null | while IFS= read -r line; do
		printf '%s:%s [associative array — bash 4.0+]\n' "$file" "$line" >>"$tmp_file"
	done

	# mapfile / readarray (bash 4.0+)
	grep -nE '^[[:space:]]*(mapfile|readarray)[[:space:]]' "$file" 2>/dev/null | while IFS= read -r line; do
		printf '%s:%s [mapfile/readarray — bash 4.0+]\n' "$file" "$line" >>"$tmp_file"
	done

	# ${var,,} / ${var^^} case conversion (bash 4.0+)
	# Exclude comments — grep -n prefixes "NNN:" so comments appear as "NNN:\s*#"
	# shellcheck disable=SC2016 # Literal ${ pattern for compatibility scanning.
	grep -n ',,}' "$file" 2>/dev/null | grep '\${' | grep -vE '^[0-9]+:[[:space:]]*#' | while IFS= read -r line; do
		printf '%s:%s [case conversion ,,} — bash 4.0+]\n' "$file" "$line" >>"$tmp_file"
	done
	# shellcheck disable=SC2016 # Literal ${ pattern for compatibility scanning.
	grep -n '^^}' "$file" 2>/dev/null | grep '\${' | grep -vE '^[0-9]+:[[:space:]]*#' | while IFS= read -r line; do
		printf '%s:%s [case conversion ^^} — bash 4.0+]\n' "$file" "$line" >>"$tmp_file"
	done

	# declare -n / local -n namerefs (bash 4.3+)
	grep -nE '^[[:space:]]*(declare|local)[[:space:]]+-n[[:space:]]' "$file" 2>/dev/null | while IFS= read -r line; do
		printf '%s:%s [nameref — bash 4.3+]\n' "$file" "$line" >>"$tmp_file"
	done

	# coproc (bash 4.0+)
	grep -nE '^[[:space:]]*coproc[[:space:]]' "$file" 2>/dev/null | while IFS= read -r line; do
		printf '%s:%s [coproc — bash 4.0+]\n' "$file" "$line" >>"$tmp_file"
	done

	# &>> append-both (bash 4.0+)
	grep -n '&>>' "$file" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | while IFS= read -r line; do
		printf '%s:%s [&>> append — bash 4.0+]\n' "$file" "$line" >>"$tmp_file"
	done

	# "\t" or "\n" in string concatenation (likely wants $'\t' or $'\n')
	# Only flag += or = assignments, not awk/sed/printf/echo -e/python contexts
	grep -nE '\+="\\[tn]|="\\[tn]' "$file" 2>/dev/null |
		grep -vE '^[0-9]+:[[:space:]]*#' |
		grep -vE 'awk|sed|printf|echo.*-e|python|f\.write|gsub|join|split|print |replace|coords|excerpt|delimiter|regex|pattern' |
		while IFS= read -r line; do
			printf '%s:%s ["\t"/"\n" — use $'"'"'\\t'"'"' or $'"'"'\\n'"'"' for actual whitespace]\n' "$file" "$line" >>"$tmp_file"
		done
	return 0
}

_bash32_helper_path() {
	printf '%s/complexity-regression-helper.sh\n' "$SCRIPT_DIR"
	return 0
}

_bash32_timeout_seconds() {
	local timeout_seconds="${LINTERS_LOCAL_BASH32_TIMEOUT:-120}"
	if [[ ! "$timeout_seconds" =~ ^[0-9]+$ ]] || [[ "$timeout_seconds" -lt 1 ]]; then
		timeout_seconds=120
	fi
	printf '%s\n' "$timeout_seconds"
	return 0
}

_bash32_merge_base() {
	local base_ref="${LINTERS_LOCAL_BASH32_BASE_REF:-origin/main}"
	local head_ref="${LINTERS_LOCAL_BASH32_HEAD_REF:-HEAD}"

	git merge-base "$head_ref" "$base_ref" 2>/dev/null
	return $?
}

_bash32_current_branch() {
	git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'unknown\n'
	return 0
}

_bash32_run_helper() {
	local mode="$1"
	local base_ref="${2:-}"
	local output_file="$3"
	local helper_script
	helper_script=$(_bash32_helper_path)
	local timeout_seconds
	timeout_seconds=$(_bash32_timeout_seconds)

	if [[ ! -x "$helper_script" ]]; then
		print_warning "Bash 3.2 compatibility: regression helper not executable at $helper_script"
		return 2
	fi

	local rc=0
	if [[ "$mode" == "regression" ]]; then
		# CI parity: use the same per-violation regression helper as the GitHub
		# Bash 3.2 job, scoped from merge-base to HEAD, instead of re-scanning all
		# historical debt locally. Keep timeout_sec output redirected so the
		# portable macOS fallback can clean up the whole process group reliably.
		timeout_sec "$timeout_seconds" "$helper_script" check \
			--metric bash32-compat \
			--base "$base_ref" \
			--head "${LINTERS_LOCAL_BASH32_HEAD_REF:-HEAD}" \
			>"$output_file" 2>&1 || rc=$?
	else
		timeout_sec "$timeout_seconds" "$helper_script" check \
			--metric bash32-compat \
			--dry-run \
			>"$output_file" 2>&1 || rc=$?
	fi

	return "$rc"
}

_bash32_print_helper_output() {
	local output_file="$1"
	if [[ -s "$output_file" ]]; then
		cat "$output_file"
	fi
	return 0
}

_bash32_run_advisory_total() {
	local tmp_file="$1"
	local rc=0
	_bash32_run_helper "dry-run" "" "$tmp_file" || rc=$?

	if [[ "$rc" -eq 124 ]]; then
		print_warning "Bash 3.2 compatibility: advisory total scan timed out after $(_bash32_timeout_seconds)s"
		print_info "Use CI-equivalent regression mode on feature branches: complexity-regression-helper.sh check --metric bash32-compat --base <merge-base> --head HEAD"
		return 0
	fi

	if [[ "$rc" -ne 0 ]]; then
		print_warning "Bash 3.2 compatibility: advisory total scan skipped (helper exit $rc)"
		_bash32_print_helper_output "$tmp_file"
		return 0
	fi

	_bash32_print_helper_output "$tmp_file"
	print_success "Bash 3.2 compatibility: advisory total scan completed"
	return 0
}

check_bash32_compat() {
	echo -e "${BLUE}Checking Bash 3.2 Compatibility...${NC}"

	local tmp_file
	tmp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_file}'"

	local branch_name
	branch_name=$(_bash32_current_branch)
	local base_ref=""
	local rc=0

	case "$branch_name" in
	main | master)
		print_info "Canonical branch detected; running bounded advisory total scan instead of blocking on historical debt."
		_bash32_run_advisory_total "$tmp_file"
		return 0
		;;
	*)
		base_ref=$(_bash32_merge_base) || base_ref=""
		;;
	esac

	if [[ -z "$base_ref" ]]; then
		print_warning "Bash 3.2 compatibility: no merge-base with origin/main; running bounded advisory total scan."
		_bash32_run_advisory_total "$tmp_file"
		return 0
	fi

	_bash32_run_helper "regression" "$base_ref" "$tmp_file" || rc=$?
	if [[ "$rc" -eq 0 ]]; then
		_bash32_print_helper_output "$tmp_file"
		print_success "Bash 3.2 compatibility: no new Bash 3.2 regressions"
		return 0
	fi

	if [[ "$rc" -eq 124 ]]; then
		print_warning "Bash 3.2 compatibility: regression scan timed out after $(_bash32_timeout_seconds)s"
		print_info "Run CI-equivalent check directly: complexity-regression-helper.sh check --metric bash32-compat --base $base_ref --head HEAD"
		return 0
	fi

	_bash32_print_helper_output "$tmp_file"
	if [[ "$rc" -eq 1 ]]; then
		print_error "Bash 3.2 compatibility: new Bash 3.2 regression found"
		return 1
	fi

	print_warning "Bash 3.2 compatibility: regression helper failed (exit $rc); treating as warning so local linters can finish."
	print_info "CI uses the same helper and remains authoritative for this gate."

	return 0
}
