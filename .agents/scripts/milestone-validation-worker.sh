#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# milestone-validation-worker.sh - Milestone validation for mission system
# Part of aidevops framework: https://aidevops.sh
#
# Specialised worker dispatched after all features in a milestone complete.
# Pulls the mission branch, exercises the product path, runs configured or
# repository-required checks, optionally runs existing Playwright browser tests
# (UI missions), reports specific failures, and creates linked fix tasks.
#
# Usage:
#   milestone-validation-worker.sh <mission-file> <milestone-number> [options]
#
# Arguments:
#   mission-file       Path to mission.md state file
#   milestone-number   Milestone number to validate (e.g., 1, 2, 3)
#
# Options:
#   --repo-path <path>         Path to project repository (default: inferred from mission file)
#   --browser-tests            Run Playwright browser tests (for UI milestones)
#   --browser-qa               Run visual QA via browser-qa-worker.sh (screenshots, links, errors)
#   --browser-qa-flows <json>  JSON array of URLs for browser QA (default: extracted from mission)
#   --browser-url <url>        Base URL for browser tests/QA (default: http://localhost:3000)
#   --max-retries <n>          Max validation retry attempts (default: 3)
#   --create-fix-tasks         Create fix tasks on failure (default: true)
#   --no-fix-tasks             Skip fix task creation on failure
#   --report-only              Run validation but don't update mission state
#   --json                     Emit a single machine-readable JSON object to stdout (suppresses human-readable output)
#   --verbose                  Verbose output
#   --help                     Show this help message
#
# Exit codes:
#   0 - Validation passed
#   1 - Validation failed (issues found)
#   2 - Configuration error (missing args, bad paths)
#   3 - Mission state error (milestone not ready for validation)
#
# Examples:
#   milestone-validation-worker.sh ~/Git/myproject/todo/missions/m-20260227-abc123/mission.md 1
#   milestone-validation-worker.sh mission.md 2 --browser-tests --browser-url http://localhost:8080
#   milestone-validation-worker.sh mission.md 2 --browser-qa --browser-url http://localhost:3000
#   milestone-validation-worker.sh mission.md 1 --report-only --verbose

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# =============================================================================
# Logging
# =============================================================================

# Colors (RED, GREEN, YELLOW, BLUE, NC) provided by shared-constants.sh

_mv_timestamp() {
	date -u +"%Y-%m-%dT%H:%M:%SZ"
	return 0
}

log_info() {
	local msg="$1"
	if [[ "${JSON_OUTPUT:-false}" == "true" ]]; then
		echo -e "[$(_mv_timestamp)] [INFO] ${msg}" >&2
	else
		echo -e "[$(_mv_timestamp)] [INFO] ${msg}"
	fi
	return 0
}

log_error() {
	local msg="$1"
	echo -e "[$(_mv_timestamp)] ${RED}[ERROR]${NC} ${msg}" >&2
	return 0
}

log_success() {
	local msg="$1"
	if [[ "${JSON_OUTPUT:-false}" == "true" ]]; then
		echo -e "[$(_mv_timestamp)] ${GREEN}[OK]${NC} ${msg}" >&2
	else
		echo -e "[$(_mv_timestamp)] ${GREEN}[OK]${NC} ${msg}"
	fi
	return 0
}

log_warn() {
	local msg="$1"
	if [[ "${JSON_OUTPUT:-false}" == "true" ]]; then
		echo -e "[$(_mv_timestamp)] ${YELLOW}[WARN]${NC} ${msg}" >&2
	else
		echo -e "[$(_mv_timestamp)] ${YELLOW}[WARN]${NC} ${msg}"
	fi
	return 0
}

# =============================================================================
# Configuration
# =============================================================================

MISSION_FILE=""
MILESTONE_NUM=""
REPO_PATH=""
BROWSER_TESTS=false
BROWSER_QA=false
BROWSER_QA_FLOWS=""
BROWSER_URL="http://localhost:3000"
MV_MAX_RETRIES=3
CREATE_FIX_TASKS=true
REPORT_ONLY=false
JSON_OUTPUT=false
VERBOSE=false
readonly MV_CHECK_TEST_SUITE="Test suite"

# Validation results
VALIDATION_PASSED=true
VALIDATION_FAILURES=()
VALIDATION_WARNINGS=()
VALIDATION_CHECKS_RUN=0
VALIDATION_CHECKS_PASSED=0
VALIDATION_CHECKS_FAILED=0
VALIDATION_CHECKS_SKIPPED=0

# =============================================================================
# Helpers
# =============================================================================

# Detect the Node.js package manager for a given repo path.
# Prints one of: bun, pnpm, yarn, npm (default).
detect_pkg_manager() {
	local repo_path="$1"
	if [[ -f "$repo_path/bun.lockb" ]] || [[ -f "$repo_path/bun.lock" ]]; then
		echo "bun"
	elif [[ -f "$repo_path/pnpm-lock.yaml" ]]; then
		echo "pnpm"
	elif [[ -f "$repo_path/yarn.lock" ]]; then
		echo "yarn"
	else
		echo "npm"
	fi
	return 0
}

# =============================================================================
# Help
# =============================================================================

show_help() {
	awk '
		NR == 1 { next }
		/^$/ { exit }
		/^#/ {
			sub(/^# ?/, "")
			print
		}
	' "$0"
	return 0
}

# =============================================================================
# Logging
# =============================================================================

log_verbose() {
	local msg="$1"
	if [[ "$VERBOSE" == "true" ]]; then
		log_info "$msg"
	fi
	return 0
}

record_pass() {
	local check_name="$1"
	VALIDATION_CHECKS_RUN=$((VALIDATION_CHECKS_RUN + 1))
	VALIDATION_CHECKS_PASSED=$((VALIDATION_CHECKS_PASSED + 1))
	log_success "PASS: $check_name"
	return 0
}

record_fail() {
	local check_name="$1"
	local detail="${2:-}"
	VALIDATION_PASSED=false
	VALIDATION_CHECKS_RUN=$((VALIDATION_CHECKS_RUN + 1))
	VALIDATION_CHECKS_FAILED=$((VALIDATION_CHECKS_FAILED + 1))
	VALIDATION_FAILURES+=("$check_name: $detail")
	log_error "FAIL: $check_name — $detail"
	return 0
}

record_skip() {
	local check_name="$1"
	local reason="${2:-}"
	VALIDATION_CHECKS_RUN=$((VALIDATION_CHECKS_RUN + 1))
	VALIDATION_CHECKS_SKIPPED=$((VALIDATION_CHECKS_SKIPPED + 1))
	log_info "SKIP: $check_name — $reason"
	return 0
}

record_warning() {
	local check_name="$1"
	local detail="${2:-}"
	VALIDATION_WARNINGS+=("$check_name: $detail")
	log_warn "WARN: $check_name — $detail"
	return 0
}

# Reset validation state for retry attempts
reset_validation_state() {
	VALIDATION_PASSED=true
	VALIDATION_FAILURES=()
	VALIDATION_WARNINGS=()
	VALIDATION_CHECKS_RUN=0
	VALIDATION_CHECKS_PASSED=0
	VALIDATION_CHECKS_FAILED=0
	VALIDATION_CHECKS_SKIPPED=0
	return 0
}

# =============================================================================
# Argument Parsing
# =============================================================================

# Require a non-empty value for a flag that takes an argument.
# Usage: require_value "--flag-name" "${2-}" || return 2
require_value() {
	local flag="$1"
	local value="${2-}"
	if [[ -z "$value" || "$value" == --* ]]; then
		log_error "$flag requires a value"
		return 2
	fi
	return 0
}

# Validate parsed inputs after option parsing completes.
# Checks mission file, milestone number, and repo path.
validate_parsed_inputs() {
	# Validate mission file exists
	if [[ ! -f "$MISSION_FILE" ]]; then
		log_error "Mission file not found: $MISSION_FILE"
		return 2
	fi

	# Resolve to absolute path
	MISSION_FILE="$(cd "$(dirname "$MISSION_FILE")" && pwd)/$(basename "$MISSION_FILE")"

	# Validate milestone number is numeric (bash-native — avoids fork for echo+grep)
	if [[ ! "$MILESTONE_NUM" =~ ^[0-9]+$ ]]; then
		log_error "Invalid milestone number: $MILESTONE_NUM (expected numeric)"
		return 2
	fi

	# Infer repo path from mission file if not provided
	if [[ -z "$REPO_PATH" ]]; then
		REPO_PATH=$(infer_repo_path "$MISSION_FILE")
		if [[ -z "$REPO_PATH" ]]; then
			log_error "Could not infer repo path from mission file. Use --repo-path."
			return 2
		fi
	fi

	# Validate repo path
	if [[ ! -d "$REPO_PATH" ]]; then
		log_error "Repository path not found: $REPO_PATH"
		return 2
	fi

	if [[ ! -d "$REPO_PATH/.git" ]] && ! git -C "$REPO_PATH" rev-parse --git-dir >/dev/null 2>&1; then
		log_error "Not a git repository: $REPO_PATH"
		return 2
	fi

	return 0
}

# Parse the optional flags after positional arguments.
# Modifies global config variables (REPO_PATH, BROWSER_TESTS, etc.).
# Returns 2 on invalid option or missing value.
_parse_args_options() {
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--repo-path)
			require_value "$arg" "${2-}" || return 2
			REPO_PATH="$2"
			shift 2
			;;
		--browser-tests)
			BROWSER_TESTS=true
			shift
			;;
		--browser-qa)
			BROWSER_QA=true
			shift
			;;
		--browser-qa-flows)
			require_value "$arg" "${2-}" || return 2
			BROWSER_QA_FLOWS="$2"
			shift 2
			;;
		--browser-url)
			require_value "$arg" "${2-}" || return 2
			BROWSER_URL="$2"
			shift 2
			;;
		--max-retries)
			require_value "$arg" "${2-}" || return 2
			if ! echo "$2" | grep -qE '^[1-9][0-9]*$'; then
				log_error "--max-retries requires a positive integer (>=1), got: $2"
				return 2
			fi
			MV_MAX_RETRIES="$2"
			shift 2
			;;
		--create-fix-tasks)
			CREATE_FIX_TASKS=true
			shift
			;;
		--no-fix-tasks)
			CREATE_FIX_TASKS=false
			shift
			;;
		--report-only)
			REPORT_ONLY=true
			shift
			;;
		--json)
			JSON_OUTPUT=true
			shift
			;;
		--verbose)
			VERBOSE=true
			shift
			;;
		--help | -h)
			show_help
			exit 0
			;;
		*)
			log_error "Unknown option: $arg"
			show_help
			return 2
			;;
		esac
	done
	return 0
}

parse_args() {
	# Check for --help before positional arg validation
	for arg in "$@"; do
		if [[ "$arg" == "--help" || "$arg" == "-h" ]]; then
			show_help
			exit 0
		fi
	done

	if [[ $# -lt 2 ]]; then
		log_error "Missing required arguments: mission-file and milestone-number"
		show_help
		return 2
	fi

	MISSION_FILE="$1"
	MILESTONE_NUM="$2"
	shift 2

	_parse_args_options "$@" || return $?

	validate_parsed_inputs
}

# =============================================================================
# Mission State Helpers
# =============================================================================

# Infer the repo path from the mission file location.
# Mission files live in {repo}/todo/missions/{id}/mission.md or ~/.aidevops/missions/{id}/mission.md.
# Also checks the frontmatter 'repo:' field.
infer_repo_path() {
	local mission_file="$1"
	local mission_dir
	mission_dir="$(dirname "$mission_file")"

	# Check frontmatter for repo: field
	local repo_field
	repo_field=$(grep -E '^repo:' "$mission_file" 2>/dev/null | head -1 | sed 's/^repo:[[:space:]]*//' | sed 's/[[:space:]]*$//' | tr -d '"' || echo "")
	if [[ -n "$repo_field" && -d "$repo_field" ]]; then
		echo "$repo_field"
		return 0
	fi

	# Walk up from mission dir looking for .git
	local check_dir="$mission_dir"
	local max_depth=6
	local depth=0
	while [[ "$depth" -lt "$max_depth" && "$check_dir" != "/" ]]; do
		if [[ -d "$check_dir/.git" ]] || git -C "$check_dir" rev-parse --git-dir >/dev/null 2>&1; then
			echo "$check_dir"
			return 0
		fi
		check_dir="$(dirname "$check_dir")"
		depth=$((depth + 1))
	done

	echo ""
	return 1
}

# Read the milestone status from the mission file.
# Looks for: **Status:** <value> under ### Milestone N: or ### MN:
get_milestone_status() {
	local mission_file="$1"
	local milestone_num="$2"

	# Match both "### Milestone N:" and "### MN:" formats
	local status
	status=$(awk -v mnum="$milestone_num" '
		$0 ~ "^### (Milestone |M)" mnum "[: ]" { found=1; next }
		found && /^\*\*Status:\*\*/ {
			gsub(/.*\*\*Status:\*\*[[:space:]]*/, "")
			gsub(/[[:space:]]*<!--.*/, "")
			gsub(/[[:space:]]*$/, "")
			print
			exit
		}
		found && /^### / { exit }
	' "$mission_file" 2>/dev/null || echo "")

	echo "$status"
	return 0
}

# Read the milestone validation criteria from the mission file.
get_milestone_validation() {
	local mission_file="$1"
	local milestone_num="$2"

	local validation
	validation=$(awk -v mnum="$milestone_num" '
		$0 ~ "^### (Milestone |M)" mnum "[: ]" { found=1; next }
		found && /^\*\*Validation:\*\*/ {
			gsub(/.*\*\*Validation:\*\*[[:space:]]*/, "")
			gsub(/[[:space:]]*$/, "")
			print
			exit
		}
		found && /^### / { exit }
	' "$mission_file" 2>/dev/null || echo "")

	echo "$validation"
	return 0
}

# Read the mission mode (poc or full) from frontmatter
get_mission_mode() {
	local mission_file="$1"

	local mode
	mode=$(grep -E '^mode:' "$mission_file" 2>/dev/null | head -1 | sed 's/^mode:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | tr -d '"' || echo "full")

	echo "$mode"
	return 0
}

# Read the mission ID from frontmatter
get_mission_id() {
	local mission_file="$1"

	local mid
	mid=$(grep -E '^id:' "$mission_file" 2>/dev/null | head -1 | sed 's/^id:[[:space:]]*//' | sed 's/[[:space:]]*#.*//' | tr -d '"' || echo "")

	echo "$mid"
	return 0
}

# Update milestone status in the mission file
update_milestone_status() {
	local mission_file="$1"
	local milestone_num="$2"
	local new_status="$3"

	if [[ "$REPORT_ONLY" == "true" ]]; then
		log_verbose "Report-only mode: would set milestone $milestone_num status to $new_status"
		return 0
	fi

	# Use awk to find and replace the status line under the correct milestone
	local tmp_file
	tmp_file=$(mktemp)
	trap 'rm -f "${tmp_file:-}"' RETURN

	awk -v mnum="$milestone_num" -v new_status="$new_status" '
		$0 ~ "^### (Milestone |M)" mnum "[: ]" { found=1 }
		found && /^\*\*Status:\*\*/ {
			# Preserve comment if present
			comment = ""
			if (match($0, /<!--.*-->/)) {
				comment = " " substr($0, RSTART, RLENGTH)
			}
			print "**Status:** " new_status comment
			found=0
			next
		}
		found && /^### / { found=0 }
		{ print }
	' "$mission_file" >"$tmp_file"

	if [[ -s "$tmp_file" ]]; then
		mv "$tmp_file" "$mission_file"
		log_verbose "Updated milestone $milestone_num status to: $new_status"
	else
		log_error "Failed to update milestone status (empty output)"
		return 1
	fi

	return 0
}

# Append an entry to the mission progress log
append_progress_log() {
	local mission_file="$1"
	local event="$2"
	local details="$3"

	if [[ "$REPORT_ONLY" == "true" ]]; then
		log_verbose "Report-only mode: would log event: $event"
		return 0
	fi

	local timestamp
	timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	# Append a progress log row before ## Retrospective
	local tmp_file
	tmp_file=$(mktemp)

	awk -v ts="$timestamp" -v ev="$event" -v det="$details" '
		/^## Retrospective/ {
			print "| " ts " | " ev " | " det " |"
			print ""
		}
		{ print }
	' "$mission_file" >"$tmp_file"

	if [[ -s "$tmp_file" ]]; then
		mv "$tmp_file" "$mission_file"
	fi
	rm -f "$tmp_file" 2>/dev/null || true

	return 0
}

# =============================================================================
# Validation Checks
# =============================================================================

# Run Node.js test suite via detected package manager.
_run_node_tests() {
	local repo_path="$1"
	local has_test=0
	if grep -q '"test"' "$repo_path/package.json" 2>/dev/null; then
		has_test=1
	fi

	if [[ "$has_test" -gt 0 ]]; then
		local test_output
		local test_exit=0
		local pkg_cmd
		pkg_cmd=$(detect_pkg_manager "$repo_path")

		test_output=$(cd "$repo_path" && $pkg_cmd test 2>&1) || test_exit=$?

		if [[ $test_exit -eq 0 ]]; then
			record_pass "Test suite ($pkg_cmd test)"
		else
			local failure_summary
			failure_summary=$(echo "$test_output" | grep -iE '(FAIL|Error|failed|✗|✘)' | head -10 || echo "Exit code: $test_exit")
			record_fail "Test suite ($pkg_cmd test)" "$failure_summary"
		fi
	else
		record_skip "$MV_CHECK_TEST_SUITE" "No 'test' script in package.json"
	fi
	return 0
}

# Run Python test suite via pytest.
_run_python_tests() {
	local repo_path="$1"
	local test_output
	local test_exit=0

	if [[ -x "$repo_path/.venv/bin/pytest" ]]; then
		test_output=$(cd "$repo_path" && .venv/bin/pytest --tb=short 2>&1) || test_exit=$?
	elif command -v pytest >/dev/null 2>&1; then
		test_output=$(cd "$repo_path" && pytest --tb=short 2>&1) || test_exit=$?
	else
		record_skip "Test suite (pytest)" "pytest not found"
		return 0
	fi

	if [[ $test_exit -eq 0 ]]; then
		record_pass "Test suite (pytest)"
	else
		local failure_summary
		failure_summary=$(echo "$test_output" | grep -E '(FAILED|ERROR|short test summary)' | head -10 || echo "Exit code: $test_exit")
		record_fail "Test suite (pytest)" "$failure_summary"
	fi
	return 0
}

# Run Rust test suite via cargo.
_run_rust_tests() {
	local repo_path="$1"
	local test_output
	local test_exit=0
	test_output=$(cd "$repo_path" && cargo test 2>&1) || test_exit=$?

	if [[ $test_exit -eq 0 ]]; then
		record_pass "Test suite (cargo test)"
	else
		local failure_summary
		failure_summary=$(echo "$test_output" | grep -E '(FAILED|failures:)' | head -10 || echo "Exit code: $test_exit")
		record_fail "Test suite (cargo test)" "$failure_summary"
	fi
	return 0
}

# Run Go test suite.
_run_go_tests() {
	local repo_path="$1"
	local test_output
	local test_exit=0
	test_output=$(cd "$repo_path" && go test ./... 2>&1) || test_exit=$?

	if [[ $test_exit -eq 0 ]]; then
		record_pass "Test suite (go test)"
	else
		local failure_summary
		failure_summary=$(echo "$test_output" | grep -E '(FAIL|--- FAIL)' | head -10 || echo "Exit code: $test_exit")
		record_fail "Test suite (go test)" "$failure_summary"
	fi
	return 0
}

# Run ShellCheck on shell scripts in .agents/scripts/.
_run_shell_tests() {
	local repo_path="$1"
	if command -v shellcheck >/dev/null 2>&1; then
		local sc_output
		local sc_exit=0
		sc_output=$(find "$repo_path/.agents/scripts" -type f -name "*.sh" -exec shellcheck {} + 2>&1) || sc_exit=$?

		if [[ $sc_exit -eq 0 ]]; then
			record_pass "ShellCheck validation"
		else
			local failure_count
			failure_count=$(echo "$sc_output" | safe_grep_count "^In ")
			record_fail "ShellCheck validation" "$failure_count files with issues"
		fi
	else
		record_skip "ShellCheck validation" "shellcheck not installed"
	fi
	return 0
}

# Detect and run the project's test suite.
# Dispatches to language-specific helpers based on project markers.
run_test_suite() {
	local repo_path="$1"

	log_info "Running test suite..."

	if [[ -f "$repo_path/package.json" ]]; then
		_run_node_tests "$repo_path"
	elif [[ -f "$repo_path/pytest.ini" ]] ||
		{ [[ -f "$repo_path/pyproject.toml" ]] && grep -qi 'pytest' "$repo_path/pyproject.toml"; } ||
		{ [[ -f "$repo_path/setup.cfg" ]] && grep -qiE '\[tool:pytest\]|pytest' "$repo_path/setup.cfg"; } ||
		{ [[ -f "$repo_path/setup.py" ]] && grep -qi 'pytest' "$repo_path/setup.py"; } ||
		{ [[ -f "$repo_path/requirements.txt" ]] && grep -qi 'pytest' "$repo_path/requirements.txt"; } ||
		{ [[ -f "$repo_path/requirements-dev.txt" ]] && grep -qi 'pytest' "$repo_path/requirements-dev.txt"; }; then
		_run_python_tests "$repo_path"
	elif [[ -f "$repo_path/pyproject.toml" ]] || [[ -f "$repo_path/setup.py" ]]; then
		record_skip "$MV_CHECK_TEST_SUITE" "No configured Python test runner found"
	elif [[ -f "$repo_path/Cargo.toml" ]]; then
		_run_rust_tests "$repo_path"
	elif [[ -f "$repo_path/go.mod" ]]; then
		_run_go_tests "$repo_path"
	elif [[ -d "$repo_path/.agents/scripts" ]]; then
		_run_shell_tests "$repo_path"
	else
		record_skip "$MV_CHECK_TEST_SUITE" "No recognised test framework found"
	fi
	return 0
}

# Run the project build
run_build() {
	local repo_path="$1"

	log_info "Running build..."

	if [[ -f "$repo_path/package.json" ]]; then
		local has_build
		has_build=$(safe_grep_count '"build"' "$repo_path/package.json")

		if [[ "$has_build" -gt 0 ]]; then
			local build_output
			local build_exit=0

			local pkg_cmd
			pkg_cmd=$(detect_pkg_manager "$repo_path")

			build_output=$(cd "$repo_path" && $pkg_cmd run build 2>&1) || build_exit=$?

			if [[ $build_exit -eq 0 ]]; then
				record_pass "Build ($pkg_cmd run build)"
			else
				local failure_summary
				failure_summary=$(echo "$build_output" | grep -iE '(error|Error|ERROR|failed)' | head -10 || echo "Exit code: $build_exit")
				record_fail "Build ($pkg_cmd run build)" "$failure_summary"
			fi
			return 0
		else
			record_skip "Build" "No 'build' script in package.json"
			return 0
		fi
	fi

	# Rust
	if [[ -f "$repo_path/Cargo.toml" ]]; then
		local build_output
		local build_exit=0
		build_output=$(cd "$repo_path" && cargo build 2>&1) || build_exit=$?

		if [[ $build_exit -eq 0 ]]; then
			record_pass "Build (cargo build)"
		else
			local failure_summary
			failure_summary=$(echo "$build_output" | grep -E '(error\[|cannot find)' | head -10 || echo "Exit code: $build_exit")
			record_fail "Build (cargo build)" "$failure_summary"
		fi
		return 0
	fi

	# Go
	if [[ -f "$repo_path/go.mod" ]]; then
		local build_output
		local build_exit=0
		build_output=$(cd "$repo_path" && go build ./... 2>&1) || build_exit=$?

		if [[ $build_exit -eq 0 ]]; then
			record_pass "Build (go build)"
		else
			local failure_summary
			failure_summary=$(echo "$build_output" | head -10 || echo "Exit code: $build_exit")
			record_fail "Build (go build)" "$failure_summary"
		fi
		return 0
	fi

	record_skip "Build" "No recognised build system found"
	return 0
}

# Run linter checks
run_linter() {
	local repo_path="$1"

	log_info "Running linter checks..."

	# Check for project-level linter config
	if [[ -f "$repo_path/package.json" ]]; then
		local has_lint
		has_lint=$(safe_grep_count '"lint"' "$repo_path/package.json")

		if [[ "$has_lint" -gt 0 ]]; then
			local lint_output
			local lint_exit=0

			local pkg_cmd
			pkg_cmd=$(detect_pkg_manager "$repo_path")

			lint_output=$(cd "$repo_path" && $pkg_cmd run lint 2>&1) || lint_exit=$?

			if [[ $lint_exit -eq 0 ]]; then
				record_pass "Linter ($pkg_cmd run lint)"
			else
				local issue_count
				issue_count=$(echo "$lint_output" | grep -cE '(error|warning)' || echo "unknown")
				record_fail "Linter ($pkg_cmd run lint)" "$issue_count issues found"
			fi
			return 0
		fi
	fi

	# TypeScript type checking
	if [[ -f "$repo_path/tsconfig.json" ]]; then
		local tsc_bin="${repo_path}/node_modules/.bin/tsc"
		if [[ -x "$tsc_bin" ]]; then
			local tsc_output
			local tsc_exit=0
			tsc_output=$(cd "$repo_path" && "$tsc_bin" --noEmit 2>&1) || tsc_exit=$?

			if [[ $tsc_exit -eq 0 ]]; then
				record_pass "TypeScript type check"
			else
				local error_count
				error_count=$(echo "$tsc_output" | grep -c "error TS" || echo "unknown")
				record_fail "TypeScript type check" "$error_count type errors"
			fi
		else
			record_skip "TypeScript type check" "repository-local TypeScript compiler not installed"
		fi
		return 0
	fi

	# Python linting
	if [[ -f "$repo_path/pyproject.toml" ]] || [[ -f "$repo_path/setup.py" ]]; then
		if command -v ruff >/dev/null 2>&1; then
			local lint_output
			local lint_exit=0
			lint_output=$(cd "$repo_path" && ruff check . 2>&1) || lint_exit=$?

			if [[ $lint_exit -eq 0 ]]; then
				record_pass "Linter (ruff)"
			else
				local issue_count
				issue_count=$(echo "$lint_output" | grep -c "Found" || echo "unknown")
				record_fail "Linter (ruff)" "$issue_count issues"
			fi
			return 0
		fi
	fi

	record_skip "Linter" "No recognised linter configuration found"
	return 0
}

# Run Playwright browser tests
run_browser_tests() {
	local repo_path="$1"
	local base_url="$2"

	if [[ "$BROWSER_TESTS" != "true" ]]; then
		record_skip "Browser tests" "Not requested (use --browser-tests)"
		return 0
	fi

	log_info "Running Playwright browser tests..."

	# Check for Playwright config
	local pw_config=""
	for config_name in "playwright.config.ts" "playwright.config.js" "playwright.config.mjs"; do
		if [[ -f "$repo_path/$config_name" ]]; then
			pw_config="$config_name"
			break
		fi
	done

	if [[ -z "$pw_config" ]]; then
		record_skip "Browser tests (Playwright)" "No playwright config found"
		return 0
	fi

	# Use only an existing repository-local Playwright binary; never auto-install.
	local playwright_bin="${repo_path}/node_modules/.bin/playwright"
	if [[ ! -x "$playwright_bin" ]]; then
		record_skip "Browser tests (Playwright)" "repository-local Playwright not installed"
		return 0
	fi

	local pw_output
	local pw_exit=0
	pw_output=$(cd "$repo_path" && BASE_URL="$base_url" "$playwright_bin" test 2>&1) || pw_exit=$?

	if [[ $pw_exit -eq 0 ]]; then
		record_pass "Browser tests (Playwright)"
	else
		local failure_summary
		failure_summary=$(echo "$pw_output" | grep -E '(✘|failed|Error|FAIL)' | head -10 || echo "Exit code: $pw_exit")
		record_fail "Browser tests (Playwright)" "$failure_summary"
	fi

	return 0
}

# Run browser QA (visual testing via browser-qa-worker.sh)
run_browser_qa() {
	local base_url="$1"

	if [[ "$BROWSER_QA" != "true" ]]; then
		record_skip "Browser QA" "Not requested (use --browser-qa)"
		return 0
	fi

	log_info "Running browser QA..."

	local bqa_script="${SCRIPT_DIR}/browser-qa-worker.sh"
	if [[ ! -f "$bqa_script" ]]; then
		record_skip "Browser QA" "browser-qa-worker.sh not found"
		return 0
	fi

	# Determine output directory
	local qa_output_dir
	local mission_dir
	mission_dir="$(dirname "$MISSION_FILE")"
	if [[ -d "$mission_dir" ]]; then
		qa_output_dir="${mission_dir}/assets/qa"
	else
		qa_output_dir="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}/browser-qa-$(date +%Y%m%d-%H%M%S)"
	fi

	# Build arguments
	local bqa_args=()
	bqa_args+=("--url" "$base_url")
	bqa_args+=("--output-dir" "$qa_output_dir")
	bqa_args+=("--format" "summary")

	if [[ -n "$BROWSER_QA_FLOWS" ]]; then
		bqa_args+=("--flows" "$BROWSER_QA_FLOWS")
	elif [[ -n "$MISSION_FILE" && -n "$MILESTONE_NUM" ]]; then
		bqa_args+=("--mission-file" "$MISSION_FILE")
		bqa_args+=("--milestone" "$MILESTONE_NUM")
	fi

	if [[ "$VERBOSE" == "true" ]]; then
		bqa_args+=("--verbose")
	fi

	local bqa_output
	local bqa_exit=0
	bqa_output=$(bash "$bqa_script" "${bqa_args[@]}" 2>&1) || bqa_exit=$?

	if [[ "$VERBOSE" == "true" ]]; then
		echo "$bqa_output"
	fi

	case $bqa_exit in
	0)
		record_pass "Browser QA (visual testing)"
		;;
	1)
		local failure_summary
		failure_summary=$(echo "$bqa_output" | grep -E '(FAIL|failed|error|broken)' | head -10 || echo "Exit code: $bqa_exit")
		record_fail "Browser QA (visual testing)" "$failure_summary"
		;;
	2)
		record_skip "Browser QA" "Configuration error — check Playwright installation"
		;;
	*)
		record_fail "Browser QA (visual testing)" "Unexpected exit code: $bqa_exit"
		;;
	esac

	return 0
}

# Run milestone-specific validation criteria
run_custom_validation() {
	local repo_path="$1"
	local validation_criteria="$2"

	if [[ -z "$validation_criteria" ]]; then
		record_skip "Custom validation" "No validation criteria defined for milestone"
		return 0
	fi

	log_info "Evaluating milestone validation criteria: $validation_criteria"

	# The validation criteria is a human-readable string from the mission file.
	# We can't execute it directly — it's guidance for the orchestrator agent.
	# Record it as a check that needs agent-level evaluation.
	record_pass "Custom validation criteria recorded"
	log_info "Criteria for agent evaluation: $validation_criteria"

	return 0
}

# Check dependency availability without installing anything.
check_dependencies() {
	local repo_path="$1"

	log_info "Checking existing dependencies..."

	if [[ -f "$repo_path/package.json" ]]; then
		if [[ ! -d "$repo_path/node_modules" ]] &&
			[[ ! -f "$repo_path/.pnp.cjs" ]] && [[ ! -f "$repo_path/.pnp.js" ]]; then
			record_fail "Dependency availability" "Node dependencies are missing; milestone validation never installs packages"
			return 1
		fi
		record_pass "Existing Node dependencies available"
		return 0
	fi

	# Python
	if [[ -f "$repo_path/requirements.txt" ]] || [[ -f "$repo_path/pyproject.toml" ]]; then
		record_pass "Dependencies (Python — manual verification)"
		return 0
	fi

	record_skip "Dependency check" "No dependency manifest found"
	return 0
}

# =============================================================================
# Fix Task Creation
# =============================================================================

# Create fix tasks for validation failures
create_fix_tasks() {
	local mission_file="$1"
	local milestone_num="$2"
	local repo_path="$3"

	if [[ "$CREATE_FIX_TASKS" != "true" ]]; then
		log_verbose "Fix task creation disabled"
		return 0
	fi

	if [[ "$REPORT_ONLY" == "true" ]]; then
		log_verbose "Report-only mode: would create fix tasks"
		return 0
	fi

	if [[ ${#VALIDATION_FAILURES[@]} -eq 0 ]]; then
		return 0
	fi

	local mission_id
	mission_id=$(get_mission_id "$mission_file")
	local mission_mode
	mission_mode=$(get_mission_mode "$mission_file")

	log_info "Creating fix tasks for ${#VALIDATION_FAILURES[@]} failure(s)..."

	local failure_idx=0
	for failure in "${VALIDATION_FAILURES[@]}"; do
		failure_idx=$((failure_idx + 1))
		local fix_title="Fix milestone $milestone_num validation: $failure"

		# Truncate title if too long
		if [[ ${#fix_title} -gt 120 ]]; then
			fix_title="${fix_title:0:117}..."
		fi

		if [[ "$mission_mode" == "full" ]]; then
			# Full mode: create GitHub issue
			local repo_slug
			repo_slug=$(git -C "$repo_path" remote get-url origin 2>/dev/null | sed 's|.*github.com[:/]||' | sed 's|\.git$||' || echo "")

			if [[ -n "$repo_slug" ]]; then
				local issue_body
				issue_body="## Milestone Validation Fix

**Mission:** \`$mission_id\`
**Milestone:** $milestone_num
**Failure:** $failure

**Context:** This task was auto-created by the milestone validation worker after milestone $milestone_num failed validation.

**What to fix:** Address the specific failure described above.

**Validation criteria:** Re-run milestone validation after fix to confirm resolution."

				# Append signature footer
				local mv_sig=""
				mv_sig=$("${HOME}/.aidevops/agents/scripts/gh-signature-helper.sh" footer --body "$issue_body" 2>/dev/null || true)
				issue_body="${issue_body}${mv_sig}"

				local issue_url
				gh label create "source:mission-validation" --repo "$repo_slug" \
					--description "Auto-created by milestone-validation-worker.sh" \
					--color "C2E0C6" --force 2>/dev/null || true
				issue_url=$(gh_create_issue --repo "$repo_slug" \
					--title "$fix_title" \
					--body "$issue_body" \
					--label "bug,mission:$mission_id,source:mission-validation" 2>/dev/null || echo "")

				if [[ -n "$issue_url" ]]; then
					log_success "Created fix issue: $issue_url"
				else
					log_warn "Failed to create GitHub issue for: $fix_title"
				fi
			else
				log_warn "No GitHub remote found — cannot create fix issue"
			fi
		else
			# POC mode: just log the fix needed
			log_info "Fix needed (POC mode): $fix_title"
		fi
	done

	return 0
}

# =============================================================================
# Report Generation
# =============================================================================

# Emit a machine-readable JSON summary to stdout.
# Used when --json flag is set; suppresses human-readable output.
generate_json_report() {
	local mission_file="$1"
	local milestone_num="$2"
	local exit_code="$3"

	local mission_id
	mission_id=$(get_mission_id "$mission_file")

	# Build failures JSON array
	local failures_json="["
	local first=true
	for failure in "${VALIDATION_FAILURES[@]}"; do
		if [[ "$first" == "true" ]]; then
			first=false
		else
			failures_json+=","
		fi
		# Escape double-quotes in failure message
		local escaped_failure
		escaped_failure="${failure//\"/\\\"}"
		failures_json+="{\"message\":\"${escaped_failure}\"}"
	done
	failures_json+="]"

	# Build warnings JSON array
	local warnings_json="["
	first=true
	for warning in "${VALIDATION_WARNINGS[@]}"; do
		if [[ "$first" == "true" ]]; then
			first=false
		else
			warnings_json+=","
		fi
		local escaped_warning
		escaped_warning="${warning//\"/\\\"}"
		warnings_json+="{\"message\":\"${escaped_warning}\"}"
	done
	warnings_json+="]"

	local passed_str="false"
	if [[ "$VALIDATION_PASSED" == "true" ]]; then
		passed_str="true"
	fi

	printf '{"mission_id":"%s","milestone":%s,"total_checks":%s,"passed_count":%s,"failed_count":%s,"skipped_count":%s,"warnings_count":%s,"passed":%s,"failures":%s,"warnings":%s,"exit_code":%s}\n' \
		"$mission_id" \
		"$milestone_num" \
		"$VALIDATION_CHECKS_RUN" \
		"$VALIDATION_CHECKS_PASSED" \
		"$VALIDATION_CHECKS_FAILED" \
		"$VALIDATION_CHECKS_SKIPPED" \
		"${#VALIDATION_WARNINGS[@]}" \
		"$passed_str" \
		"$failures_json" \
		"$warnings_json" \
		"$exit_code"

	return 0
}

generate_report() {
	local mission_file="$1"
	local milestone_num="$2"

	local mission_id
	mission_id=$(get_mission_id "$mission_file")

	echo ""
	echo -e "${BLUE}========================================${NC}"
	echo -e "${BLUE}  Milestone Validation Report${NC}"
	echo -e "${BLUE}========================================${NC}"
	echo ""
	echo "Mission:    $mission_id"
	echo "Milestone:  $milestone_num"
	echo "Timestamp:  $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
	echo "Mode:       $(get_mission_mode "$mission_file")"
	echo ""
	echo -e "  ${GREEN}Passed:${NC}   $VALIDATION_CHECKS_PASSED"
	echo -e "  ${RED}Failed:${NC}   $VALIDATION_CHECKS_FAILED"
	echo -e "  ${BLUE}Skipped:${NC}  $VALIDATION_CHECKS_SKIPPED"
	echo -e "  Total:    $VALIDATION_CHECKS_RUN"
	echo ""

	if [[ ${#VALIDATION_FAILURES[@]} -gt 0 ]]; then
		echo -e "${RED}Failures:${NC}"
		for failure in "${VALIDATION_FAILURES[@]}"; do
			echo "  - $failure"
		done
		echo ""
	fi

	if [[ ${#VALIDATION_WARNINGS[@]} -gt 0 ]]; then
		echo -e "${YELLOW}Warnings:${NC}"
		for warning in "${VALIDATION_WARNINGS[@]}"; do
			echo "  - $warning"
		done
		echo ""
	fi

	if [[ "$VALIDATION_PASSED" == "true" ]]; then
		echo -e "${GREEN}MILESTONE $milestone_num VALIDATION PASSED${NC}"
	else
		echo -e "${RED}MILESTONE $milestone_num VALIDATION FAILED${NC}"
	fi
	echo ""

	return 0
}

# =============================================================================
# Main
# =============================================================================

# Check whether the milestone is in a state that allows validation.
# Returns 0 to proceed, 1 to skip (already passed), or 3 for state error.
check_milestone_readiness() {
	local milestone_status
	milestone_status=$(get_milestone_status "$MISSION_FILE" "$MILESTONE_NUM")
	log_verbose "Current milestone status: '$milestone_status'"

	case "$milestone_status" in
	active | validating | "")
		# OK to proceed
		;;
	passed)
		log_info "Milestone $MILESTONE_NUM already passed validation"
		return 1
		;;
	pending)
		log_error "Milestone $MILESTONE_NUM is still pending — features not yet dispatched"
		return 3
		;;
	failed)
		log_info "Re-validating previously failed milestone $MILESTONE_NUM"
		;;
	*)
		log_warn "Unexpected milestone status: '$milestone_status' — proceeding with validation"
		;;
	esac
	return 0
}

# Run all validation checks with retry support.
# Sets VALIDATION_PASSED and populates failure/warning arrays.
# Sets MV_FINAL_ATTEMPT (global) to the final attempt number — do NOT capture
# this function in a subshell ($(...)) as that swallows all log output.
MV_FINAL_ATTEMPT=1
run_validation_with_retries() {
	local validation_criteria="$1"
	local dependencies_available=true
	MV_FINAL_ATTEMPT=1

	while [[ $MV_FINAL_ATTEMPT -le $MV_MAX_RETRIES ]]; do
		if [[ $MV_FINAL_ATTEMPT -gt 1 ]]; then
			log_info "Retry attempt $MV_FINAL_ATTEMPT/$MV_MAX_RETRIES..."
			reset_validation_state
			# Brief pause before retry to allow transient issues to resolve
			sleep 2
		fi

		dependencies_available=true
		if check_dependencies "$REPO_PATH"; then
			run_test_suite "$REPO_PATH"
			run_build "$REPO_PATH"
			run_linter "$REPO_PATH"
			run_browser_tests "$REPO_PATH" "$BROWSER_URL"
		else
			dependencies_available=false
			record_skip "Configured project checks" "Dependencies unavailable; no installation attempted"
		fi
		run_browser_qa "$BROWSER_URL"
		run_custom_validation "$REPO_PATH" "$validation_criteria"
		if [[ "$dependencies_available" != "true" ]]; then
			break
		fi

		if [[ "$VALIDATION_PASSED" == "true" ]]; then
			break
		fi

		if [[ $MV_FINAL_ATTEMPT -lt $MV_MAX_RETRIES ]]; then
			log_warn "Validation failed on attempt $MV_FINAL_ATTEMPT/$MV_MAX_RETRIES — retrying..."
		fi
		MV_FINAL_ATTEMPT=$((MV_FINAL_ATTEMPT + 1))
	done

	return 0
}

# Update mission state, generate report, and create fix tasks based on results.
handle_validation_result() {
	local attempt="$1"

	# Determine final exit code before report generation
	local final_exit=0
	if [[ "$VALIDATION_PASSED" != "true" ]]; then
		final_exit=1
	fi

	# Generate report (for final attempt)
	if [[ "$JSON_OUTPUT" == "true" ]]; then
		generate_json_report "$MISSION_FILE" "$MILESTONE_NUM" "$final_exit"
	else
		generate_report "$MISSION_FILE" "$MILESTONE_NUM"
	fi

	# Update mission state based on results
	if [[ "$VALIDATION_PASSED" == "true" ]]; then
		local attempt_note=""
		if [[ $attempt -gt 1 ]]; then
			attempt_note=" (passed on attempt $attempt)"
		fi
		update_milestone_status "$MISSION_FILE" "$MILESTONE_NUM" "passed"
		append_progress_log "$MISSION_FILE" "Milestone $MILESTONE_NUM validated" "All checks passed ($VALIDATION_CHECKS_PASSED/$VALIDATION_CHECKS_RUN)${attempt_note}"
		return 0
	else
		update_milestone_status "$MISSION_FILE" "$MILESTONE_NUM" "failed"
		append_progress_log "$MISSION_FILE" "Milestone $MILESTONE_NUM validation failed" "${#VALIDATION_FAILURES[@]} failure(s) after $attempt attempt(s): ${VALIDATION_FAILURES[*]}"
		create_fix_tasks "$MISSION_FILE" "$MILESTONE_NUM" "$REPO_PATH"
		return 1
	fi
}

main() {
	local parse_exit=0
	parse_args "$@" || parse_exit=$?
	if [[ $parse_exit -ne 0 ]]; then
		return $parse_exit
	fi

	log_info "Starting milestone validation"
	log_info "Mission: $MISSION_FILE"
	log_info "Milestone: $MILESTONE_NUM"
	log_info "Repo: $REPO_PATH"

	# Verify milestone is ready for validation
	local readiness_exit=0
	check_milestone_readiness || readiness_exit=$?
	if [[ $readiness_exit -eq 1 ]]; then
		return 0
	elif [[ $readiness_exit -gt 1 ]]; then
		return $readiness_exit
	fi

	# Update status to validating
	update_milestone_status "$MISSION_FILE" "$MILESTONE_NUM" "validating"

	# Read validation criteria
	local validation_criteria
	validation_criteria=$(get_milestone_validation "$MISSION_FILE" "$MILESTONE_NUM")
	log_verbose "Validation criteria: $validation_criteria"

	# Pull latest changes
	log_info "Pulling latest changes..."
	local pull_exit=0
	git -C "$REPO_PATH" pull --rebase 2>/dev/null || pull_exit=$?
	if [[ $pull_exit -ne 0 ]]; then
		record_warning "Git pull" "Pull failed (exit $pull_exit) — validating current state"
	fi

	# Run validation checks with retry support
	# Result stored in MV_FINAL_ATTEMPT global (not stdout capture — avoids swallowing log output)
	run_validation_with_retries "$validation_criteria"

	# Handle results: report, state update, fix tasks
	handle_validation_result "$MV_FINAL_ATTEMPT"
}

main "$@"
