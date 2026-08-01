#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2086
# =============================================================================
# Local Linters — Validators Sub-Library
# =============================================================================
# Static pattern validation, shell linting, and secret scanning functions
# extracted from linters-local.sh (GH#21296).
#
# Includes:
#   - Return statement validation (S7682)
#   - Positional parameter checks (S7679)
#   - String literal duplication (S1192)
#   - Forbidden exec FD lock detection (GH#18668)
#   - shfmt syntax checking
#   - ShellCheck validation
#   - ShellCheck RC parity (GH#19877)
#   - Secretlint scanning
#   - Secret safety policy
#
# Usage: source "${SCRIPT_DIR}/linters-local-validators.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_success, print_warning,
#     safe_grep_count, timeout_sec, _save_cleanup_scope, push_cleanup, _run_cleanups)
#   - Constants: MAX_RETURN_ISSUES, MAX_POSITIONAL_ISSUES, MAX_STRING_LITERAL_ISSUES
#     (defined in orchestrator before sourcing)
#   - ALL_SH_FILES array (populated by collect_shell_files in orchestrator)
#
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_LINTERS_LOCAL_VALIDATORS_LOADED:-}" ]] && return 0
_LINTERS_LOCAL_VALIDATORS_LOADED=1

# Defensive SCRIPT_DIR fallback (matches issue-sync-lib.sh pattern)
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Functions ---

check_git_diff_whitespace() {
	echo -e "${BLUE}Checking Git Diff Whitespace...${NC}"

	if ! git rev-parse --git-dir >/dev/null 2>&1; then
		print_warning "git diff --check: not a git repository"
		return 0
	fi

	local base_ref=""
	local exit_code=0
	base_ref=$(_linters_local_base_ref 2>/dev/null || true)

	if [[ -n "$base_ref" ]]; then
		git diff --check "$base_ref"...HEAD || exit_code=1
	fi
	git diff --check || exit_code=1
	git diff --cached --check || exit_code=1

	if [[ "$exit_code" -eq 0 ]]; then
		print_success "git diff --check: no whitespace errors"
		return 0
	fi

	print_error "git diff --check: whitespace errors detected"
	return 1
}

check_return_statements() {
	echo -e "${BLUE}Checking Return Statements (S7682)...${NC}"

	local violations=0
	local files_checked=0

	for file in "${ALL_SH_FILES[@]}"; do
		[[ -f "$file" ]] || continue
		((++files_checked))

		# Count multi-line functions (exclude one-liners like: func() { echo "x"; })
		# One-liners don't need explicit return statements
		local functions_count
		functions_count=$(safe_grep_count "^[a-zA-Z_][a-zA-Z0-9_]*() {$" "$file")

		# Count all return patterns: return 0, return 1, return $var, return $((expr))
		local return_statements
		return_statements=$(grep -cE "return [0-9]+|return \\\$" "$file" 2>/dev/null || echo "0")

		# Also count exit statements at script level (exit 0, exit $?)
		local exit_statements
		exit_statements=$(grep -cE "^exit [0-9]+|^exit \\\$" "$file" 2>/dev/null || echo "0")

		# Ensure variables are numeric
		functions_count=${functions_count//[^0-9]/}
		return_statements=${return_statements//[^0-9]/}
		exit_statements=${exit_statements//[^0-9]/}
		functions_count=${functions_count:-0}
		return_statements=${return_statements:-0}
		exit_statements=${exit_statements:-0}

		# Total returns = return statements + exit statements (for main)
		local total_returns=$((return_statements + exit_statements))

		if [[ $total_returns -lt $functions_count ]]; then
			((++violations))
			print_warning "Missing return statements in $file"
		fi
	done

	echo "Files checked: $files_checked"
	echo "Files with violations: $violations"

	if [[ $violations -le $MAX_RETURN_ISSUES ]]; then
		print_success "Return statements: $violations violations (within threshold)"
	else
		print_error "Return statements: $violations violations (exceeds threshold of $MAX_RETURN_ISSUES)"
		return 1
	fi

	return 0
}

check_positional_parameters() {
	echo -e "${BLUE}Checking Positional Parameters (S7679)...${NC}"

	local violations=0

	# Find direct usage of positional parameters inside functions (not in local assignments)
	# Exclude: heredocs (<<), awk scripts, main script body, and local assignments
	local tmp_file
	tmp_file=$(mktemp)
	_save_cleanup_scope
	trap '_run_cleanups' RETURN
	push_cleanup "rm -f '${tmp_file}'"

	# Only check inside function bodies, exclude heredocs, awk/sed patterns, and comments
	for file in "${ALL_SH_FILES[@]}"; do
		if [[ -f "$file" ]]; then
			# Use awk to find $1-$9 usage inside functions, excluding:
			# - local assignments (local var="$1")
			# - heredocs (<<EOF ... EOF)
			# - awk/sed scripts (contain $1, $2 for field references)
			# - comments (lines starting with #)
			# - echo/print statements showing usage examples
			awk '
            /^[a-zA-Z_][a-zA-Z0-9_]*\(\)[[:space:]]*\{/ { in_func=1; next }
            in_func && /^\}$/ { in_func=0; next }
            /<<.*EOF/ || /<<.*"EOF"/ || /<<-.*EOF/ { in_heredoc=1; next }
            in_heredoc && /^EOF/ { in_heredoc=0; next }
            in_heredoc { next }
            # Track multi-line awk scripts (awk ... single-quote opens, closes on later line)
            /awk[[:space:]]+\047[^\047]*$/ { in_awk=1; next }
            in_awk && /\047/ { in_awk=0; next }
            in_awk { next }
            # Skip single-line awk/sed scripts (they use $1, $2 for fields)
            /awk.*\047.*\047/ { next }
            /awk.*".*"/ { next }
            /sed.*\047/ || /sed.*"/ { next }
            # Skip comments and usage examples
            /^[[:space:]]*#/ { next }
            /echo.*\$[1-9]/ { next }
            /print.*\$[1-9]/ { next }
            /Usage:/ { next }
            # Skip currency/pricing patterns: $[1-9] followed by digit, decimal, comma,
            # slash (e.g. $28/mo, $1.99, $1,000), pipe (markdown table), or common
            # currency/pricing unit words (per, mo, month, flat, etc.).
            /\$[1-9][0-9.,\/]/ { next }
            /\$[1-9][[:space:]]*\|/ { next }
            /\$[1-9][[:space:]]+(per|mo(nth)?|year|yr|day|week|hr|hour|flat|each|off|fee|plan|tier|user|seat|unit|addon|setup|trial|credit|annual|quarterly|monthly)[[:space:][:punct:]]/ { next }
            /\$[1-9][[:space:]]+(per|mo(nth)?|year|yr|day|week|hr|hour|flat|each|off|fee|plan|tier|user|seat|unit|addon|setup|trial|credit|annual|quarterly|monthly)$/ { next }
            in_func && /\$[1-9]/ && !/local.*=.*\$[1-9]/ {
                print FILENAME ":" NR ": " $0
            }
            ' "$file" >>"$tmp_file"
		fi
	done

	if [[ -s "$tmp_file" ]]; then
		violations=$(wc -l <"$tmp_file")
		violations=${violations//[^0-9]/}
		violations=${violations:-0}

		if [[ $violations -gt 0 ]]; then
			print_warning "Found $violations positional parameter violations:"
			head -10 "$tmp_file"
			if [[ $violations -gt 10 ]]; then
				echo "... and $((violations - 10)) more"
			fi
		fi
	fi

	rm -f "$tmp_file"

	if [[ $violations -le $MAX_POSITIONAL_ISSUES ]]; then
		print_success "Positional parameters: $violations violations (within threshold)"
	else
		print_error "Positional parameters: $violations violations (exceeds threshold of $MAX_POSITIONAL_ISSUES)"
		return 1
	fi

	return 0
}

check_string_literals() {
	echo -e "${BLUE}Checking String Literals (S1192)...${NC}"

	local violations=0
	local debt_files=0
	local repo_root baseline_ref changed_shell_files
	repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
	baseline_ref=$(git -C "$repo_root" merge-base HEAD origin/main 2>/dev/null || printf '%s' 'origin/main')
	changed_shell_files=$(git -C "$repo_root" diff --name-only "$baseline_ref" -- '*.sh' 2>/dev/null || true)
	if [[ -z "$changed_shell_files" ]]; then
		print_success "String literals: no changed shell files"
		return 0
	fi

	for file in "${ALL_SH_FILES[@]}"; do
		[[ -f "$file" ]] || continue
		if [[ "$file" == *"/tests/"* ]] || [[ "$(basename "$file")" == test-*.sh ]]; then
			continue
		fi

		# Diff-scope the expensive string-literal scan. Pre-existing repository-wide
		# debt is not actionable for unrelated changes and must not block local
		# preflight.
		local repeated_strings baseline_strings rel_file base_content file_abs file_dir
		file_dir=$(cd "$(dirname "$file")" && pwd -P)
		file_abs="${file_dir}/$(basename "$file")"
		rel_file=${file_abs#"$repo_root"/}
		if ! printf '%s\n' "$changed_shell_files" | grep -qxF "$rel_file"; then
			continue
		fi

		repeated_strings=$(_linters_count_repeated_literals <"$file")
		[[ "$repeated_strings" =~ ^[0-9]+$ ]] || repeated_strings=0

		baseline_strings=0
		base_content=$(git -C "$repo_root" show "${baseline_ref}:${rel_file}" 2>/dev/null || true)
		if [[ -n "$base_content" ]]; then
			baseline_strings=$(printf '%s\n' "$base_content" | _linters_count_repeated_literals)
			[[ "$baseline_strings" =~ ^[0-9]+$ ]] || baseline_strings=0
		fi

		if ((repeated_strings > baseline_strings)); then
			local new_strings=$((repeated_strings - baseline_strings))
			((violations += new_strings))
			print_error "$file has $new_strings new repeated string literal(s) (baseline: $baseline_strings, current: $repeated_strings)"
			_linters_show_repeated_literals <"$file"
		elif ((repeated_strings > 0)); then
			((debt_files += 1))
			print_warning "$file has $repeated_strings pre-existing repeated string literal(s) (not blocking)"
		fi
	done

	if [[ $violations -eq 0 ]]; then
		print_success "String literals: no new repeated string literals (${debt_files} file(s) with pre-existing debt)"
	else
		print_error "String literals: $violations new repeated string literal regression(s)"
		return 1
	fi

	return 0
}

_linters_count_repeated_literals() {
	grep -v '^[[:space:]]*#' |
		sed -E '
			s/"\$[A-Za-z_][A-Za-z0-9_]*"//g
			s/"\$\{[^}]*\}"//g
			s/"\$@"//g
			s/"\$[0-9*#?$!-]"//g
		' |
		grep -oE '"[^"]{4,}"' |
		grep -vE '^"[0-9]+\.?[0-9]*"$' |
		grep -vE '^"\$' |
		sort | uniq -c | awk '$1 >= 3' | wc -l | tr -d '[:space:]'
	return 0
}

_linters_show_repeated_literals() {
	grep -v '^[[:space:]]*#' |
		sed -E '
			s/"\$[A-Za-z_][A-Za-z0-9_]*"//g
			s/"\$\{[^}]*\}"//g
			s/"\$@"//g
			s/"\$[0-9*#?$!-]"//g
		' |
		grep -oE '"[^"]{4,}"' |
		grep -vE '^"[0-9]+\.?[0-9]*"$' |
		grep -vE '^"\$' |
		sort | uniq -c | awk '$1 >= 3 {print "  " $1 "x: " $2}' | head -3
	return 0
}

# check_forbidden_exec_fd (GH#18668): categorical block on persistent FD-based
# file locks in pulse-adjacent scripts. Matches any `exec N>PATH` where PATH
# references a `.aidevops/logs/*.lock` or `pulse-*.lock` file.
#
# Rationale: bash has no built-in for fcntl(F_SETFD, FD_CLOEXEC), so any FD
# opened with `exec N>` is inherited by every child process (including
# daemonising git hooks and ancillary workers). This caused four recurring
# deadlock incidents (GH#18094, GH#18141, GH#18264, GH#18668) before the
# flock layer was dropped in favour of mkdir atomicity. See
# reference/bash-fd-locking.md for the full post-mortem and policy.
#
# The rule is a hard block (not a ratchet) because the policy is categorical:
# there is no legitimate reason for the pulse to hold a persistent FD.
# Short-lived flock inside a single helper (e.g. audit-log-helper.sh) is
# permitted because the FD dies with the helper and does not get inherited
# across process spawning.
check_forbidden_exec_fd() {
	echo -e "${BLUE}Checking Forbidden exec FD Locks (GH#18668)...${NC}"

	local violations=0
	local violation_lines=""

	for file in "${ALL_SH_FILES[@]}"; do
		[[ -f "$file" ]] || continue
		# Skip the post-mortem doc itself (it quotes the forbidden pattern
		# in a bash code block), the reference docs, the linter itself
		# (defines the rule), and archived code.
		case "$file" in
		*/_archive/*) continue ;;
		*/reference/*) continue ;;
		*/linters-local*.sh) continue ;;
		esac

		# Match: exec N>path, exec N>>path, or exec N>"$VAR" where the
		# target path (literal or expanded) suggests a lock file.
		# The grep is intentionally narrow — it matches the exact shape
		# of the forbidden pattern, not "all flock usage".
		local matches
		matches=$(grep -nE '^[[:space:]]*exec[[:space:]]+[0-9]+>[^&]' "$file" 2>/dev/null || true)
		if [[ -z "$matches" ]]; then
			continue
		fi

		# Filter to only lock-suggestive targets: .lock, .lockfile, LOCKFILE
		# variable references, or .aidevops/logs paths.
		local filtered
		filtered=$(printf '%s\n' "$matches" | grep -E '\.lock|LOCKFILE|\.aidevops/logs' 2>/dev/null || true)
		if [[ -z "$filtered" ]]; then
			continue
		fi

		while IFS= read -r line; do
			[[ -z "$line" ]] && continue
			violations=$((violations + 1))
			violation_lines+="${file}:${line}"$'\n'
		done <<<"$filtered"
	done

	if [[ $violations -eq 0 ]]; then
		print_success "Forbidden exec FD locks: 0 violations (policy upheld)"
		return 0
	fi

	print_error "Forbidden exec FD locks: $violations violation(s)"
	printf '%s' "$violation_lines" | head -10
	if [[ $violations -gt 10 ]]; then
		echo "... and $((violations - 10)) more"
	fi
	print_info "Persistent FD-based locks in bash cannot set CLOEXEC — daemonising"
	print_info "children inherit the FD and deadlock the next pulse cycle."
	print_info "Use mkdir-based atomic locking instead. See:"
	print_info "  .agents/reference/bash-fd-locking.md"
	return 1
}

run_shfmt() {
	echo -e "${BLUE}Running shfmt Syntax Check (fast pre-pass)...${NC}"

	if ! command -v shfmt &>/dev/null; then
		print_warning "shfmt not installed (install: brew install shfmt)"
		return 0
	fi

	local violations=0
	local files_checked=0

	files_checked=${#ALL_SH_FILES[@]}

	if [[ $files_checked -eq 0 ]]; then
		print_success "shfmt: No shell files to check"
		return 0
	fi

	# Batch check: shfmt -l lists files that differ from formatted output (syntax errors)
	local result
	result=$(shfmt -l "${ALL_SH_FILES[@]}" 2>&1) || true
	if [[ -n "$result" ]]; then
		violations=$(echo "$result" | wc -l | tr -d ' ')
	fi

	if [[ $violations -eq 0 ]]; then
		print_success "shfmt: $files_checked files passed syntax check"
	else
		print_warning "shfmt: $violations files have formatting differences (advisory)"
		echo "$result" | head -5
		if [[ $violations -gt 5 ]]; then
			echo "... and $((violations - 5)) more"
		fi
		print_info "Auto-fix: find .agents/scripts -name '*.sh' -not -path '*/_archive/*' -exec shfmt -w {} +"
	fi

	# shfmt is advisory, not blocking
	return 0
}

run_shellcheck() {
	echo -e "${BLUE}Running ShellCheck Validation...${NC}"

	if ! command -v shellcheck &>/dev/null; then
		print_warning "shellcheck not installed (install: brew install shellcheck)"
		return 0
	fi

	if [[ ${#ALL_SH_FILES[@]} -eq 0 ]]; then
		print_success "ShellCheck: No shell files to check"
		return 0
	fi

	# ShellCheck invocation — no source following.
	#
	# SC1091 is disabled globally in .shellcheckrc. We no longer pass -x
	# (--external-sources) or -P SCRIPTDIR because source-path=SCRIPTDIR
	# combined with -x caused exponential memory expansion (11 GB RSS,
	# kernel panics — GH#2915). Bounded batches retain timeout + ulimit
	# defence while avoiding one ShellCheck and timeout process per file.
	local violations=0
	local result=""
	local timed_out=0
	local incomplete=0
	local file_count=${#ALL_SH_FILES[@]}

	local sc_timeout=30
	local batch_size="${LINTERS_LOCAL_SHELLCHECK_BATCH_SIZE:-50}"
	[[ "$batch_size" =~ ^[0-9]+$ ]] && [[ "$batch_size" -gt 0 ]] || batch_size=50
	local offset=0
	local file_result sc_exit fallback_file fallback_result fallback_exit
	local batch=()
	while [[ "$offset" -lt "$file_count" ]]; do
		batch=("${ALL_SH_FILES[@]:offset:batch_size}")
		file_result=""
		sc_exit=0
		file_result=$(
			ulimit -v 1048576 2>/dev/null || true
			timeout_sec "$sc_timeout" shellcheck --severity=warning --format=gcc "${batch[@]}" 2>&1
		) || sc_exit=$?

		if [[ "$sc_exit" -ne 0 && "$sc_exit" -ne 1 ]]; then
			print_warning "ShellCheck: batch at offset ${offset} exited ${sc_exit}; retrying ${#batch[@]} file(s) individually"
			for fallback_file in "${batch[@]}"; do
				fallback_result=""
				fallback_exit=0
				fallback_result=$(
					ulimit -v 1048576 2>/dev/null || true
					timeout_sec "$sc_timeout" shellcheck --severity=warning --format=gcc "$fallback_file" 2>&1
				) || fallback_exit=$?
				if [[ "$fallback_exit" -eq 124 ]]; then
					timed_out=$((timed_out + 1))
					incomplete=$((incomplete + 1))
					print_warning "ShellCheck: $fallback_file timed out after ${sc_timeout}s"
				elif [[ "$fallback_exit" -eq 1 && -n "$fallback_result" ]]; then
					result="${result}${fallback_result}"$'\n'
				elif [[ "$fallback_exit" -ne 0 ]]; then
					incomplete=$((incomplete + 1))
					print_error "ShellCheck: $fallback_file failed without lint diagnostics (exit ${fallback_exit})"
				fi
			done
			offset=$((offset + batch_size))
			continue
		fi
		if [[ "$sc_exit" -eq 1 && -z "$file_result" ]]; then
			incomplete=$((incomplete + ${#batch[@]}))
			print_error "ShellCheck: batch at offset ${offset} failed without lint diagnostics"
		fi
		if [[ -n "$file_result" ]]; then
			result="${result}${file_result}"$'\n'
		fi
		offset=$((offset + batch_size))
	done

	if [[ -n "$result" ]]; then
		# Count unique files with violations (grep -c avoids SC2126)
		violations=$(echo "$result" | grep -v '^$' | cut -d: -f1 | sort -u | grep -c . || true)
		local issue_count
		issue_count=$(echo "$result" | grep -vc '^$' || true)

		print_error "ShellCheck: $violations files with $issue_count issues"
		# Show first few issues
		echo "$result" | grep -v '^$' | head -10
		if [[ $issue_count -gt 10 ]]; then
			echo "... and $((issue_count - 10)) more"
		fi
		if [[ $timed_out -gt 0 ]]; then
			print_warning "ShellCheck: $timed_out file(s) timed out (recursive source expansion)"
		fi
		return 1
	fi
	if [[ "$incomplete" -gt 0 ]]; then
		print_error "ShellCheck: ${incomplete} file(s) were not checked completely"
		return 1
	fi

	print_success "ShellCheck: ${file_count} files passed (no warnings)"
	return 0
}

# Check shellcheckrc parity (GH#19877)
# Verifies that every disable= directive in root .shellcheckrc is also
# present in .agents/scripts/.shellcheckrc. ShellCheck's rcfile discovery
# stops at the first match walking up, so the scripts-dir rcfile takes
# precedence and must carry all root disables.
check_shellcheckrc_parity() {
	echo -e "${BLUE}Checking ShellCheck RC Parity...${NC}"

	local root_rc=".shellcheckrc"
	local scripts_rc=".agents/scripts/.shellcheckrc"

	if [[ ! -f "$root_rc" ]]; then
		print_warning "shellcheckrc parity: root .shellcheckrc not found"
		return 0
	fi
	if [[ ! -f "$scripts_rc" ]]; then
		print_warning "shellcheckrc parity: scripts-dir .shellcheckrc not found"
		return 0
	fi

	local root_disables scripts_disables
	root_disables=$(grep -E '^disable=SC[0-9]+' "$root_rc" | sort || true)
	scripts_disables=$(grep -E '^disable=SC[0-9]+' "$scripts_rc" | sort || true)

	local missing=""
	local code
	while IFS= read -r code; do
		[[ -z "$code" ]] && continue
		if ! grep -qxF "$code" <<<"$scripts_disables"; then
			missing="${missing}  ${code}\n"
		fi
	done <<<"$root_disables"

	if [[ -n "$missing" ]]; then
		print_error "shellcheckrc parity: scripts-dir rcfile is missing disables from root"
		echo -e "  Missing directives (add to .agents/scripts/.shellcheckrc):"
		echo -e "$missing"
		echo "  ShellCheck only reads ONE .shellcheckrc — the first found walking up."
		echo "  Scripts in .agents/scripts/ use the scripts-dir rcfile, not root."
		return 1
	fi

	print_success "shellcheckrc parity: all root disables present in scripts-dir rcfile"
	return 0
}

# Check for secrets in codebase
check_secrets() {
	echo -e "${BLUE}Checking for Exposed Secrets (Secretlint)...${NC}"

	local secretlint_script=".agents/scripts/secretlint-helper.sh"
	local violations=0
	local secretlint_targets=("**/*")
	if [[ "${LINTERS_LOCAL_MODE:-full}" == "changed" ]] && declare -F linters_local_changed_files_matching >/dev/null 2>&1; then
		secretlint_targets=()
		local changed_targets=""
		changed_targets=$(linters_local_changed_files_matching '.+')
		local changed_file
		while IFS= read -r changed_file; do
			[[ -n "$changed_file" && -f "$changed_file" ]] || continue
			secretlint_targets+=("$changed_file")
		done <<<"$changed_targets"
		if [[ ${#secretlint_targets[@]} -eq 0 ]]; then
			print_success "Secretlint: no changed files to scan"
			return 0
		fi
		print_info "Secretlint: changed-file mode (${#secretlint_targets[@]} file(s))"
	fi

	# Check if secretlint is available (global, local, or main repo for worktrees)
	local secretlint_cmd=""
	if command -v secretlint &>/dev/null; then
		secretlint_cmd="secretlint"
	elif [[ -f "node_modules/.bin/secretlint" ]]; then
		secretlint_cmd="./node_modules/.bin/secretlint"
	else
		# Check main repo node_modules (handles git worktrees)
		local repo_root
		repo_root=$(git rev-parse --git-common-dir 2>/dev/null | xargs -I{} sh -c 'cd "{}/.." && pwd' 2>/dev/null || echo "")
		if [[ -n "$repo_root" ]] && [[ "$repo_root" != "$(pwd)" ]] && [[ -f "$repo_root/node_modules/.bin/secretlint" ]]; then
			secretlint_cmd="$repo_root/node_modules/.bin/secretlint"
		fi
	fi

	if [[ -n "$secretlint_cmd" ]]; then

		if [[ -f ".secretlintrc.json" ]]; then
			# Run scan and capture exit code
			if "$secretlint_cmd" "${secretlint_targets[@]}" --format compact 2>/dev/null; then
				print_success "Secretlint: No secrets detected"
			else
				violations=1
				print_error "Secretlint: Potential secrets detected!"
				print_info "Run: bash $secretlint_script scan (for detailed results)"
			fi
		else
			print_warning "Secretlint: Configuration not found"
			print_info "Run: bash $secretlint_script init"
		fi
	elif command -v docker &>/dev/null; then
		if [[ "${LINTERS_LOCAL_MODE:-full}" == "changed" ]]; then
			print_warning "Secretlint: native CLI unavailable; Docker broad scan skipped in changed mode"
			print_info "CI/full mode remains authoritative for full-repo secretlint coverage"
			return 0
		fi
		local sl_timeout=60
		print_info "Secretlint: Using Docker for scan (${sl_timeout}s timeout)..."

		# timeout_sec (from shared-constants.sh) handles macOS + Linux portably
		local docker_result
		docker_result=$(timeout_sec "$sl_timeout" docker run --init -v "$(pwd)":"$(pwd)" -w "$(pwd)" --rm secretlint/secretlint secretlint "**/*" --format compact 2>&1) || true

		if [[ -z "$docker_result" ]] || [[ "$docker_result" == *"0 problems"* ]]; then
			print_success "Secretlint: No secrets detected"
		elif [[ "$docker_result" == *"timed out"* ]] || [[ "$docker_result" == *"timeout"* ]]; then
			print_warning "Secretlint: Timed out (skipped)"
			print_info "Install native secretlint for faster scans: npm install -g secretlint"
		else
			violations=1
			print_error "Secretlint: Potential secrets detected!"
		fi
	else
		print_warning "Secretlint: Not installed (install with: npm install secretlint)"
		print_info "Run: bash $secretlint_script install"
	fi

	return $violations
}

check_secret_policy() {
	echo -e "${BLUE}Checking Secret Safety Policy...${NC}"

	local project_policy_script=".agents/scripts/safety-policy-check.sh"
	local deployed_policy_script="${SCRIPT_DIR}/safety-policy-check.sh"
	local path_policy_script=""
	local path_policy_type=""
	local policy_script=""

	if [[ -e "$project_policy_script" || -L "$project_policy_script" ]]; then
		if [[ ! -f "$project_policy_script" || ! -x "$project_policy_script" ]]; then
			print_error "Project policy checker is not an executable regular file: $project_policy_script"
			return 1
		fi
		policy_script="$project_policy_script"
	elif [[ -f "$deployed_policy_script" && -x "$deployed_policy_script" ]]; then
		policy_script="$deployed_policy_script"
	else
		path_policy_type=$(builtin type -t safety-policy-check.sh 2>/dev/null || true)
		if [[ "$path_policy_type" == "file" ]]; then
			path_policy_script=$(command -v safety-policy-check.sh 2>/dev/null || true)
		fi
		if [[ -z "$path_policy_script" || ! -f "$path_policy_script" || ! -x "$path_policy_script" ]]; then
			print_error "Missing executable policy checker: checked $project_policy_script, $deployed_policy_script, and PATH"
			return 1
		fi
		policy_script="$path_policy_script"
	fi

	if bash "$policy_script"; then
		print_success "Secret safety policy checks passed"
		return 0
	fi

	print_error "Secret safety policy check failed"
	return 1
}
