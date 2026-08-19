#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Testing Setup Helper - Existing testing-infrastructure inventory and verification
# =============================================================================
# Discovers existing test infrastructure and classifies bundle quality-gate
# candidates. It never installs runners or generates infrastructure.
#
# Usage:
#   testing-setup-helper.sh discover [project-path]    Scan for existing test infra
#   testing-setup-helper.sh gaps [project-path]        Classify bundle candidates
#   testing-setup-helper.sh status [project-path]      Show current test health
#   testing-setup-helper.sh verify [project-path]      Run discovered existing checks
#   testing-setup-helper.sh help                       Show this help
#
# Integration with /testing-setup command:
#   The command doc (commands/testing-setup.md) drives the interactive flow.
#   This helper provides the deterministic detection and verification logic.
#
# Depends on:
#   - bundle-helper.sh (bundle detection and resolution)
#   - shared-constants.sh (print_*, color codes)
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit

# Source shared-constants if available
if [[ -f "${SCRIPT_DIR}/shared-constants.sh" ]]; then
	# shellcheck source=shared-constants.sh
	source "${SCRIPT_DIR}/shared-constants.sh"
else
	print_error() {
		echo "ERROR: $*" >&2
		return 0
	}
	print_success() {
		echo "OK: $*"
		return 0
	}
	print_warning() {
		echo "WARN: $*" >&2
		return 0
	}
	print_info() {
		echo "INFO: $*" >&2
		return 0
	}
fi

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

readonly TESTING_CONFIG_FILE=".aidevops-testing.json"
readonly CONFIG_UNKNOWN="unknown"

# =============================================================================
# Utility Functions
# =============================================================================

# Find the first config file matching one or more glob patterns in a directory.
# Returns the basename, or CONFIG_UNKNOWN if no match found.
# Usage: get_first_config_file /path/to/project "pattern1" "pattern2" ...
get_first_config_file() {
	local project_dir="$1"
	shift
	local result=""
	local pattern
	for pattern in "$@"; do
		result=$(compgen -G "${project_dir}/${pattern}" 2>/dev/null | head -1) || true
		[[ -n "$result" ]] && break
	done
	if [[ -n "$result" ]]; then
		basename "$result" 2>/dev/null || echo "$CONFIG_UNKNOWN"
	else
		echo "$CONFIG_UNKNOWN"
	fi
	return 0
}

resolve_project_path() {
	local path="${1:-.}"
	path="$(cd "$path" 2>/dev/null && pwd)" || {
		print_error "Cannot resolve project path: $1"
		return 1
	}
	echo "$path"
	return 0
}

# Check if a file matching a glob pattern exists in the project
# Uses compgen for safe glob matching without ls word-splitting issues
has_file() {
	local project_dir="$1"
	local pattern="$2"
	local matches
	matches=$(compgen -G "${project_dir}/${pattern}" 2>/dev/null) || true
	[[ -n "$matches" ]]
}

# Check if a directory exists in the project
has_dir() {
	local project_dir="$1"
	local dirname="$2"
	[[ -d "${project_dir}/${dirname}" ]]
}

# Check if package.json has a specific devDependency
has_npm_dep() {
	local project_dir="$1"
	local dep_name="$2"
	local pkg_file="${project_dir}/package.json"
	if [[ -f "$pkg_file" ]]; then
		jq -e --arg d "$dep_name" \
			'(.devDependencies[$d] // .dependencies[$d]) != null' \
			"$pkg_file" >/dev/null 2>&1
		return $?
	fi
	return 1
}

# Check if package.json has a specific script
has_npm_script() {
	local project_dir="$1"
	local script_name="$2"
	local pkg_file="${project_dir}/package.json"
	if [[ -f "$pkg_file" ]]; then
		jq -e --arg s "$script_name" '.scripts[$s] != null' \
			"$pkg_file" >/dev/null 2>&1
		return $?
	fi
	return 1
}

# =============================================================================
# Per-Runner Discovery Helpers
# =============================================================================

# Detect Jest and append to runners JSON array (stdout)
_discover_jest() {
	local project_dir="$1"
	local runners="$2"
	if has_npm_dep "$project_dir" "jest"; then
		local configured="false"
		if has_file "$project_dir" "jest.config.*" ||
			jq -e '.jest' "${project_dir}/package.json" >/dev/null 2>&1; then
			configured="true"
		fi
		runners=$(echo "$runners" | jq --arg c "$configured" \
			'. + [{"name":"jest","source":"package.json devDependencies","configured":($c == "true")}]')
	fi
	echo "$runners"
	return 0
}

# Detect Vitest and append to runners JSON array (stdout)
_discover_vitest() {
	local project_dir="$1"
	local runners="$2"
	if has_npm_dep "$project_dir" "vitest"; then
		local configured="false"
		if has_file "$project_dir" "vitest.config.*" || has_file "$project_dir" "vite.config.*"; then
			configured="true"
		fi
		runners=$(echo "$runners" | jq --arg c "$configured" \
			'. + [{"name":"vitest","source":"package.json devDependencies","configured":($c == "true")}]')
	fi
	echo "$runners"
	return 0
}

# Detect Pytest via repository declarations (not runtime environment) and append to runners JSON array (stdout)
# Checks: pytest.ini, pyproject.toml [tool.pytest], setup.cfg [tool:pytest], setup.py,
# requirements.txt, requirements-dev.txt
_discover_pytest() {
	local project_dir="$1"
	local runners="$2"
	local _pytest_source=""
	if [[ -f "${project_dir}/pytest.ini" ]]; then
		_pytest_source="pytest.ini"
	elif [[ -f "${project_dir}/pyproject.toml" ]] &&
		grep -qE '\[tool\.pytest' "${project_dir}/pyproject.toml" 2>/dev/null; then
		_pytest_source="pyproject.toml"
	elif [[ -f "${project_dir}/pyproject.toml" ]] &&
		grep -qi 'pytest' "${project_dir}/pyproject.toml" 2>/dev/null; then
		_pytest_source="pyproject.toml"
	elif [[ -f "${project_dir}/setup.cfg" ]] &&
		grep -qE '\[tool:pytest\]|tests_require.*pytest' "${project_dir}/setup.cfg" 2>/dev/null; then
		_pytest_source="setup.cfg"
	elif [[ -f "${project_dir}/setup.py" ]] &&
		grep -qi 'pytest' "${project_dir}/setup.py" 2>/dev/null; then
		_pytest_source="setup.py"
	elif [[ -f "${project_dir}/requirements.txt" ]] &&
		grep -qi 'pytest' "${project_dir}/requirements.txt" 2>/dev/null; then
		_pytest_source="requirements.txt"
	elif [[ -f "${project_dir}/requirements-dev.txt" ]] &&
		grep -qi 'pytest' "${project_dir}/requirements-dev.txt" 2>/dev/null; then
		_pytest_source="requirements-dev.txt"
	fi
	if [[ -n "$_pytest_source" ]]; then
		local configured="false"
		if [[ -f "${project_dir}/pytest.ini" ]] ||
			{ [[ -f "${project_dir}/pyproject.toml" ]] &&
				grep -q '\[tool\.pytest' "${project_dir}/pyproject.toml" 2>/dev/null; } ||
			{ [[ -f "${project_dir}/setup.cfg" ]] &&
				grep -qE '\[tool:pytest\]' "${project_dir}/setup.cfg" 2>/dev/null; }; then
			configured="true"
		fi
		runners=$(echo "$runners" | jq --arg c "$configured" --arg s "$_pytest_source" \
			'. + [{"name":"pytest","source":$s,"configured":($c == "true")}]')
	fi
	echo "$runners"
	return 0
}

# Detect Cargo test (Rust) and append to runners JSON array (stdout)
_discover_cargo_test() {
	local project_dir="$1"
	local runners="$2"
	if [[ -f "${project_dir}/Cargo.toml" ]]; then
		runners=$(echo "$runners" | jq \
			'. + [{"name":"cargo-test","source":"Cargo.toml","configured":true}]')
	fi
	echo "$runners"
	return 0
}

# Detect Go test and append to runners JSON array (stdout)
_discover_go_test() {
	local project_dir="$1"
	local runners="$2"
	if [[ -f "${project_dir}/go.mod" ]]; then
		runners=$(echo "$runners" | jq \
			'. + [{"name":"go-test","source":"go.mod","configured":true}]')
	fi
	echo "$runners"
	return 0
}

# Detect Bats (Bash testing) and append to runners JSON array (stdout)
_discover_bats() {
	local project_dir="$1"
	local runners="$2"
	if has_file "$project_dir" "*.bats" || has_file "$project_dir" "test/*.bats"; then
		runners=$(echo "$runners" | jq \
			'. + [{"name":"bats","source":".bats files","configured":true}]')
	fi
	echo "$runners"
	return 0
}

# Detect Bash test scripts (aidevops pattern) and append to runners JSON array (stdout)
_discover_bash_tests() {
	local project_dir="$1"
	local runners="$2"
	local bash_test_count=0
	if has_dir "$project_dir" "tests"; then
		bash_test_count=$(find "${project_dir}/tests" -maxdepth 1 -name "test-*.sh" 2>/dev/null | wc -l | tr -d ' ')
	fi
	if [[ "$bash_test_count" -gt 0 ]]; then
		runners=$(echo "$runners" | jq --arg c "$bash_test_count" \
			'. + [{"name":"bash-tests","source":"tests/test-*.sh","configured":true,"count":($c | tonumber)}]')
	fi
	echo "$runners"
	return 0
}

# Detect agent test helper (aidevops-specific) and append to runners JSON array (stdout)
_discover_agent_tests() {
	local project_dir="$1"
	local runners="$2"
	if [[ -f "${project_dir}/.agents/scripts/agent-test-helper.sh" ]]; then
		local suite_count=0
		if has_dir "$project_dir" ".agents/tests"; then
			suite_count=$(find "${project_dir}/.agents/tests" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
		fi
		runners=$(echo "$runners" | jq --arg c "$suite_count" \
			'. + [{"name":"agent-tests","source":"agent-test-helper.sh","configured":true,"suites":($c | tonumber)}]')
	fi
	echo "$runners"
	return 0
}

# Detect Playwright and append to runners JSON array (stdout)
_discover_playwright() {
	local project_dir="$1"
	local runners="$2"
	if has_npm_dep "$project_dir" "@playwright/test" || has_npm_dep "$project_dir" "playwright"; then
		local configured="false"
		if has_file "$project_dir" "playwright.config.*"; then
			configured="true"
		fi
		runners=$(echo "$runners" | jq --arg c "$configured" \
			'. + [{"name":"playwright","source":"package.json","configured":($c == "true")}]')
	fi
	echo "$runners"
	return 0
}

# Detect Cypress and append to runners JSON array (stdout)
_discover_cypress() {
	local project_dir="$1"
	local runners="$2"
	if has_npm_dep "$project_dir" "cypress"; then
		local configured="false"
		if has_file "$project_dir" "cypress.config.*"; then
			configured="true"
		fi
		runners=$(echo "$runners" | jq --arg c "$configured" \
			'. + [{"name":"cypress","source":"package.json","configured":($c == "true")}]')
	fi
	echo "$runners"
	return 0
}

# =============================================================================
# Discovery Functions
# =============================================================================

# Discover test runners present in the project
# Output: JSON array of {name, source, configured} objects
discover_runners() {
	local project_dir="$1"
	local runners="[]"

	runners=$(_discover_jest "$project_dir" "$runners")
	runners=$(_discover_vitest "$project_dir" "$runners")
	runners=$(_discover_pytest "$project_dir" "$runners")
	runners=$(_discover_cargo_test "$project_dir" "$runners")
	runners=$(_discover_go_test "$project_dir" "$runners")
	runners=$(_discover_bats "$project_dir" "$runners")
	runners=$(_discover_bash_tests "$project_dir" "$runners")
	runners=$(_discover_agent_tests "$project_dir" "$runners")
	runners=$(_discover_playwright "$project_dir" "$runners")
	runners=$(_discover_cypress "$project_dir" "$runners")

	echo "$runners"
	return 0
}

# Discover linter configurations present in the project
# Output: JSON array of {name, config_file, status} objects
discover_linters() {
	local project_dir="$1"
	local linters="[]"

	# ESLint
	if has_file "$project_dir" ".eslintrc*" || has_file "$project_dir" "eslint.config.*" ||
		has_file "$project_dir" ".eslintrc.json" || has_file "$project_dir" ".eslintrc.js"; then
		local config_file
		config_file=$(get_first_config_file "$project_dir" ".eslintrc*" "eslint.config.*")
		linters=$(echo "$linters" | jq --arg f "$config_file" \
			'. + [{"name":"eslint","config_file":$f,"status":"configured"}]')
	elif has_npm_dep "$project_dir" "eslint"; then
		linters=$(echo "$linters" | jq \
			'. + [{"name":"eslint","config_file":"none","status":"installed-not-configured"}]')
	fi

	# Prettier
	if has_file "$project_dir" ".prettierrc*" || has_file "$project_dir" "prettier.config.*"; then
		local config_file
		config_file=$(get_first_config_file "$project_dir" ".prettierrc*" "prettier.config.*")
		linters=$(echo "$linters" | jq --arg f "$config_file" \
			'. + [{"name":"prettier","config_file":$f,"status":"configured"}]')
	elif has_npm_dep "$project_dir" "prettier"; then
		linters=$(echo "$linters" | jq \
			'. + [{"name":"prettier","config_file":"none","status":"installed-not-configured"}]')
	fi

	# TypeScript
	if [[ -f "${project_dir}/tsconfig.json" ]]; then
		linters=$(echo "$linters" | jq \
			'. + [{"name":"typescript-check","config_file":"tsconfig.json","status":"configured"}]')
	fi

	# ShellCheck
	if [[ -f "${project_dir}/.shellcheckrc" ]]; then
		linters=$(echo "$linters" | jq \
			'. + [{"name":"shellcheck","config_file":".shellcheckrc","status":"configured"}]')
	elif command -v shellcheck >/dev/null 2>&1; then
		linters=$(echo "$linters" | jq \
			'. + [{"name":"shellcheck","config_file":"none","status":"available"}]')
	fi

	# Secretlint
	if [[ -f "${project_dir}/.secretlintrc.json" ]] || [[ -f "${project_dir}/.secretlintrc" ]]; then
		linters=$(echo "$linters" | jq \
			'. + [{"name":"secretlint","config_file":".secretlintrc.json","status":"configured"}]')
	fi

	# Markdownlint
	if [[ -f "${project_dir}/.markdownlint.json" ]] || [[ -f "${project_dir}/.markdownlint.jsonc" ]] ||
		[[ -f "${project_dir}/.markdownlint-cli2.jsonc" ]]; then
		local config_file
		config_file=$(get_first_config_file "$project_dir" ".markdownlint*")
		linters=$(echo "$linters" | jq --arg f "$config_file" \
			'. + [{"name":"markdownlint","config_file":$f,"status":"configured"}]')
	fi

	# Hadolint (Dockerfile linting)
	if [[ -f "${project_dir}/.hadolint.yaml" ]]; then
		linters=$(echo "$linters" | jq \
			'. + [{"name":"hadolint","config_file":".hadolint.yaml","status":"configured"}]')
	fi

	echo "$linters"
	return 0
}

# Discover test directories and file counts
discover_test_dirs() {
	local project_dir="$1"
	local dirs="[]"

	local test_dir_names=("tests" "test" "__tests__" "spec" "e2e" "integration")
	for dirname in "${test_dir_names[@]}"; do
		if has_dir "$project_dir" "$dirname"; then
			local file_count
			file_count=$(find "${project_dir}/${dirname}" -type f \( -name "*.test.*" -o -name "*.spec.*" -o -name "test_*" -o -name "test-*" -o -name "*_test.*" \) 2>/dev/null | wc -l | tr -d ' ')
			dirs=$(echo "$dirs" | jq --arg d "$dirname" --arg c "$file_count" \
				'. + [{"directory":$d,"test_files":($c | tonumber)}]')
		fi
	done

	echo "$dirs"
	return 0
}

# Discover CI pipeline test integration
discover_ci() {
	local project_dir="$1"
	local ci="[]"

	# GitHub Actions
	if has_dir "$project_dir" ".github/workflows"; then
		local has_test_step="false"
		if command -v rg >/dev/null 2>&1 && \
			rg -q -e 'npm test|yarn test|pnpm test|pytest|cargo test|go test|bats' \
				"${project_dir}/.github/workflows/" 2>/dev/null; then
			has_test_step="true"
		elif ! command -v rg >/dev/null 2>&1 && \
			grep -rEq 'npm test|yarn test|pnpm test|pytest|cargo test|go test|bats' \
				"${project_dir}/.github/workflows/" 2>/dev/null; then
			has_test_step="true"
		fi
		ci=$(echo "$ci" | jq --arg t "$has_test_step" \
			'. + [{"platform":"github-actions","configured":true,"has_test_step":($t == "true")}]')
	fi

	# GitLab CI
	if [[ -f "${project_dir}/.gitlab-ci.yml" ]]; then
		local has_test_step="false"
		if grep -qE '(^test:|^\s+script:.*\b(pytest|npm test|yarn test|pnpm test|cargo test|go test|bats)\b)' \
			"${project_dir}/.gitlab-ci.yml" 2>/dev/null; then
			has_test_step="true"
		fi
		ci=$(echo "$ci" | jq --arg t "$has_test_step" \
			'. + [{"platform":"gitlab-ci","configured":true,"has_test_step":($t == "true")}]')
	fi

	echo "$ci"
	return 0
}

# Discover coverage configuration
discover_coverage() {
	local project_dir="$1"
	local coverage='{"enabled":false}'

	# NYC / Istanbul
	if [[ -f "${project_dir}/.nycrc" ]] || [[ -f "${project_dir}/.nycrc.json" ]]; then
		coverage='{"enabled":true,"tool":"nyc","config_file":".nycrc"}'
	fi

	# c8 (via vitest or standalone)
	if has_npm_dep "$project_dir" "c8"; then
		coverage='{"enabled":true,"tool":"c8","config_file":"package.json"}'
	fi

	# Jest coverage (check if --coverage is in test script)
	if has_npm_script "$project_dir" "test:coverage" ||
		has_npm_script "$project_dir" "coverage"; then
		coverage='{"enabled":true,"tool":"jest-coverage","config_file":"package.json"}'
	fi

	# Coverage directory exists
	if has_dir "$project_dir" "coverage" &&
		[[ "$(echo "$coverage" | jq -r '.enabled')" == "false" ]]; then
		coverage='{"enabled":true,"tool":"unknown","config_file":"none"}'
	fi

	echo "$coverage"
	return 0
}

# =============================================================================
# Main Discovery Command
# =============================================================================

cmd_discover() {
	local project_dir
	project_dir=$(resolve_project_path "${1:-.}") || return 1

	local runners linters test_dirs ci coverage

	runners=$(discover_runners "$project_dir")
	linters=$(discover_linters "$project_dir")
	test_dirs=$(discover_test_dirs "$project_dir")
	ci=$(discover_ci "$project_dir")
	coverage=$(discover_coverage "$project_dir")

	# Compose full discovery result
	jq -n \
		--arg path "$project_dir" \
		--arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--argjson runners "$runners" \
		--argjson linters "$linters" \
		--argjson test_dirs "$test_dirs" \
		--argjson ci "$ci" \
		--argjson coverage "$coverage" \
		'{
			project_path: $path,
			discovered_at: $ts,
			test_runners: $runners,
			linters: $linters,
			test_directories: $test_dirs,
			ci_pipelines: $ci,
			coverage: $coverage
		}'

	return 0
}

# =============================================================================
# Gap Analysis Command
# =============================================================================

cmd_gaps() {
	local project_dir
	project_dir=$(resolve_project_path "${1:-.}") || return 1

	# Resolve bundle
	local bundle_json
	bundle_json=$("${SCRIPT_DIR}/bundle-helper.sh" resolve "$project_dir" 2>/dev/null) || {
		print_error "Could not resolve project bundle; candidate analysis unavailable"
		return 1
	}

	local bundle_name
	bundle_name=$(echo "$bundle_json" | jq -r '.name // "unknown"')

	# Get report-only bundle candidates. These never imply installation.
	local quality_gates skip_gates
	quality_gates=$(echo "$bundle_json" | jq -r '.quality_gates // []')
	skip_gates=$(echo "$bundle_json" | jq -r '.skip_gates // []')

	# Run discovery
	local discovery
	discovery=$(cmd_discover "$project_dir")

	# Build gap analysis
	local found_names
	found_names=$(echo "$discovery" | jq -r '[.test_runners[].name, .linters[].name] | .[]')

	local ready=()
	local needs_attention=()
	local missing=()
	local skipped=()

	while IFS= read -r gate; do
		[[ -z "$gate" ]] && continue

		# A composed quality gate overrides a skip declaration from another bundle.
		if echo "$skip_gates" | jq -e --arg g "$gate" 'index($g) != null' >/dev/null 2>&1 &&
			! echo "$quality_gates" | jq -e --arg g "$gate" 'index($g) != null' >/dev/null 2>&1; then
			skipped+=("$gate")
			continue
		fi

		# Check if gate is found in discovery
		if echo "$found_names" | grep -qx "$gate" 2>/dev/null; then
			# Check if it's properly configured
			local is_configured
			is_configured=$(echo "$discovery" | jq -r --arg g "$gate" \
				'[.test_runners[], .linters[]] | map(select(.name == $g)) | .[0].configured // .[0].status' 2>/dev/null || echo "unknown")
			if [[ "$is_configured" == "true" ]] || [[ "$is_configured" == "configured" ]]; then
				ready+=("$gate")
			else
				needs_attention+=("$gate")
			fi
		else
			missing+=("$gate")
		fi
	done < <(echo "$quality_gates" | jq -r '.[]')

	# Helper: convert bash array to JSON array, handling empty arrays correctly
	_arr_to_json() {
		if [[ $# -eq 0 ]]; then
			echo '[]'
		else
			printf '%s\n' "$@" | jq -R 'select(length > 0)' | jq -s .
		fi
		return 0
	}

	# Output as JSON
	jq -n \
		--arg bundle "$bundle_name" \
		--arg path "$project_dir" \
		--argjson ready "$(_arr_to_json "${ready[@]+"${ready[@]}"}")" \
		--argjson needs_attention "$(_arr_to_json "${needs_attention[@]+"${needs_attention[@]}"}")" \
		--argjson missing "$(_arr_to_json "${missing[@]+"${missing[@]}"}")" \
		--argjson skipped "$(_arr_to_json "${skipped[@]+"${skipped[@]}"}")" \
		'{
			bundle: $bundle,
			project_path: $path,
			candidate_only: true,
			action: "report_only",
			ready: $ready,
			needs_attention: $needs_attention,
			missing: $missing,
			unconfigured_candidates: $missing,
			skipped_by_bundle: $skipped
		}'

	return 0
}

# =============================================================================
# Status Command
# =============================================================================

cmd_status() {
	local project_dir
	project_dir=$(resolve_project_path "${1:-.}") || return 1

	local config_file="${project_dir}/${TESTING_CONFIG_FILE}"

	echo ""
	echo "=== Testing Infrastructure Status ==="
	echo ""

	# Check for .aidevops-testing.json
	if [[ -f "$config_file" ]]; then
		local bundle configured_at
		bundle=$(jq -r '.bundle // "unknown"' "$config_file")
		configured_at=$(jq -r '.configured_at // "unknown"' "$config_file")
		echo "  Config:     ${config_file}"
		echo "  Bundle:     ${bundle}"
		echo "  Configured: ${configured_at}"
	else
		echo "  Config:     not found (optional; no action implied)"
	fi

	echo ""

	# Run discovery and show summary
	local discovery
	discovery=$(cmd_discover "$project_dir")

	local runner_count linter_count test_dir_count
	runner_count=$(echo "$discovery" | jq '.test_runners | length')
	linter_count=$(echo "$discovery" | jq '.linters | length')
	test_dir_count=$(echo "$discovery" | jq '.test_directories | length')
	local coverage_enabled
	coverage_enabled=$(echo "$discovery" | jq -r '.coverage.enabled')

	echo "  Test runners:  ${runner_count}"
	echo "$discovery" | jq -r '.test_runners[] | "    - \(.name) (\(.source))"'

	echo "  Linters:       ${linter_count}"
	echo "$discovery" | jq -r '.linters[] | "    - \(.name) [\(.status)]"'

	echo "  Test dirs:     ${test_dir_count}"
	echo "$discovery" | jq -r '.test_directories[] | "    - \(.directory)/ (\(.test_files) test files)"'

	echo "  Coverage:      ${coverage_enabled}"
	if [[ "$coverage_enabled" == "true" ]]; then
		echo "$discovery" | jq -r '"    - \(.coverage.tool) (\(.coverage.config_file))"'
	fi

	echo "  CI pipelines:"
	local ci_count
	ci_count=$(echo "$discovery" | jq '.ci_pipelines | length')
	if [[ "$ci_count" -gt 0 ]]; then
		echo "$discovery" | jq -r '.ci_pipelines[] | "    - \(.platform) (test step: \(.has_test_step))"'
	else
		echo "    - none detected"
	fi

	echo ""
	return 0
}

# =============================================================================
# Verify Helpers
# =============================================================================

# Run a single test runner by name. Updates pass_count/fail_count/skip_count via
# output lines that the caller accumulates. Prints [pass]/[fail]/[skip] lines.
# Usage: _verify_runner <runner_name> <project_dir>
# Returns: 0 always (caller reads stdout for result)
_verify_runner() {
	local runner_name="$1"
	local project_dir="$2"

	case "$runner_name" in
	bats)
		if command -v bats >/dev/null 2>&1; then
			local bats_errors=0
			while IFS= read -r bats_file; do
				[[ -f "$bats_file" ]] || continue
				if ! bats --tap "$bats_file" >/dev/null 2>&1; then
					bats_errors=$((bats_errors + 1))
				fi
			done < <(find "$project_dir" -name "*.bats" -not -path "*/.git/*" 2>/dev/null)
			if [[ "$bats_errors" -eq 0 ]]; then
				echo "pass:bats"
			else
				echo "fail:bats (${bats_errors} test files failed)"
			fi
		else
			echo "skip:bats (not installed)"
		fi
		;;
	jest)
		if (cd "$project_dir" && npx --no-install jest --passWithNoTests --silent 2>/dev/null); then
			echo "pass:jest"
		else
			echo "fail:jest"
		fi
		;;
	vitest)
		if (cd "$project_dir" && npx --no-install vitest run --silent 2>/dev/null); then
			echo "pass:vitest"
		else
			echo "fail:vitest"
		fi
		;;
	pytest)
		if (cd "$project_dir" && python -m pytest --quiet 2>/dev/null); then
			echo "pass:pytest"
		else
			echo "fail:pytest"
		fi
		;;
	cargo-test)
		if (cd "$project_dir" && cargo test --quiet 2>/dev/null); then
			echo "pass:cargo test"
		else
			echo "fail:cargo test"
		fi
		;;
	go-test)
		if (cd "$project_dir" && go test ./... 2>/dev/null); then
			echo "pass:go test"
		else
			echo "fail:go test"
		fi
		;;
	bash-tests)
		local test_pass=0
		local test_fail=0
		for test_file in "${project_dir}"/tests/test-*.sh; do
			[[ -f "$test_file" ]] || continue
			if bash -n "$test_file" 2>/dev/null; then
				test_pass=$((test_pass + 1))
			else
				test_fail=$((test_fail + 1))
			fi
		done
		if [[ "$test_fail" -eq 0 ]]; then
			echo "pass:bash-tests (${test_pass} scripts pass syntax check)"
		else
			echo "fail:bash-tests (${test_fail} syntax errors)"
		fi
		;;
	agent-tests)
		echo "skip:agent-tests (requires interactive CLI)"
		;;
	playwright | cypress)
		echo "skip:${runner_name} (E2E tests require browser environment)"
		;;
	*)
		echo "skip:${runner_name} (no verify handler)"
		;;
	esac
	return 0
}

# Run a single linter by name. Prints pass:/fail:/skip: lines for the caller.
# Usage: _verify_linter <linter_name> <project_dir>
_verify_linter() {
	local linter_name="$1"
	local project_dir="$2"

	case "$linter_name" in
	eslint)
		if (cd "$project_dir" && npx --no-install eslint . --quiet 2>/dev/null); then
			echo "pass:eslint"
		else
			echo "fail:eslint"
		fi
		;;
	prettier)
		if (cd "$project_dir" && npx --no-install prettier --check . 2>/dev/null); then
			echo "pass:prettier"
		else
			echo "fail:prettier"
		fi
		;;
	typescript-check)
		if (cd "$project_dir" && npx --no-install tsc --noEmit 2>/dev/null); then
			echo "pass:typescript-check"
		else
			echo "fail:typescript-check"
		fi
		;;
	shellcheck)
		_verify_linter_shellcheck "$project_dir"
		;;
	secretlint)
		_verify_linter_secretlint "$project_dir"
		;;
	markdownlint)
		_verify_linter_markdownlint "$project_dir"
		;;
	hadolint)
		_verify_linter_hadolint "$project_dir"
		;;
	*)
		echo "skip:${linter_name}"
		;;
	esac
	return 0
}

# Verify shellcheck across all .sh files in the project
_verify_linter_shellcheck() {
	local project_dir="$1"
	if command -v shellcheck >/dev/null 2>&1; then
		local sc_errors=0
		while IFS= read -r sh_file; do
			[[ -f "$sh_file" ]] || continue
			if ! shellcheck "$sh_file" >/dev/null 2>&1; then
				sc_errors=$((sc_errors + 1))
			fi
		done < <(find "$project_dir" -name "*.sh" -not -path "*/node_modules/*" -not -path "*/.git/*" 2>/dev/null)
		if [[ "$sc_errors" -eq 0 ]]; then
			echo "pass:shellcheck"
		else
			echo "fail:shellcheck (${sc_errors} files with issues)"
		fi
	else
		echo "skip:shellcheck (not installed)"
	fi
	return 0
}

# Verify secretlint — tries system binary then npx fallback
_verify_linter_secretlint() {
	local project_dir="$1"
	local linter_cmd=()
	if command -v secretlint >/dev/null 2>&1; then
		linter_cmd=(secretlint "**/*")
	elif command -v npx >/dev/null 2>&1 && (cd "$project_dir" && npx --no-install secretlint --version >/dev/null 2>&1); then
		linter_cmd=(npx --no-install secretlint "**/*")
	fi
	if [[ ${#linter_cmd[@]} -gt 0 ]]; then
		if (cd "$project_dir" && "${linter_cmd[@]}" 2>/dev/null); then
			echo "pass:secretlint"
		else
			echo "fail:secretlint"
		fi
	else
		echo "skip:secretlint (not installed)"
	fi
	return 0
}

# Verify markdownlint — tries system binary then npx fallback
_verify_linter_markdownlint() {
	local project_dir="$1"
	local linter_cmd=()
	if command -v markdownlint-cli2 >/dev/null 2>&1; then
		linter_cmd=(markdownlint-cli2 "**/*.md")
	elif command -v npx >/dev/null 2>&1 && (cd "$project_dir" && npx --no-install markdownlint-cli2 --version >/dev/null 2>&1); then
		linter_cmd=(npx --no-install markdownlint-cli2 "**/*.md")
	fi
	if [[ ${#linter_cmd[@]} -gt 0 ]]; then
		if (cd "$project_dir" && "${linter_cmd[@]}" 2>/dev/null); then
			echo "pass:markdownlint"
		else
			echo "fail:markdownlint"
		fi
	else
		echo "skip:markdownlint (not installed)"
	fi
	return 0
}

# Verify hadolint across all Dockerfiles in the project
_verify_linter_hadolint() {
	local project_dir="$1"
	if command -v hadolint >/dev/null 2>&1; then
		local hl_errors=0
		while IFS= read -r dockerfile; do
			[[ -f "$dockerfile" ]] || continue
			if ! hadolint "$dockerfile" >/dev/null 2>&1; then
				hl_errors=$((hl_errors + 1))
			fi
		done < <(find "$project_dir" -name "Dockerfile*" -not -path "*/.git/*" 2>/dev/null)
		if [[ "$hl_errors" -eq 0 ]]; then
			echo "pass:hadolint"
		else
			echo "fail:hadolint (${hl_errors} Dockerfiles with issues)"
		fi
	else
		echo "skip:hadolint (not installed)"
	fi
	return 0
}

# Run all discovered test runners and accumulate pass/fail/skip counts.
# Prints [pass]/[fail]/[skip] lines and returns counts via stdout on last line.
# Usage: _verify_runners <discovery_json> <project_dir>
_verify_runners() {
	local discovery="$1"
	local project_dir="$2"
	local pass_count=0
	local fail_count=0
	local skip_count=0

	while IFS= read -r runner_name; do
		[[ -z "$runner_name" ]] && continue
		local result
		result=$(_verify_runner "$runner_name" "$project_dir")
		local status="${result%%:*}"
		local label="${result#*:}"
		echo "  [${status}] ${label}"
		case "$status" in
		pass) pass_count=$((pass_count + 1)) ;;
		fail) fail_count=$((fail_count + 1)) ;;
		*) skip_count=$((skip_count + 1)) ;;
		esac
	done < <(echo "$discovery" | jq -r '.test_runners[].name')

	echo "counts:${pass_count}:${fail_count}:${skip_count}"
	return 0
}

# Run all discovered linters and accumulate pass/fail/skip counts.
# Prints [pass]/[fail]/[skip] lines and returns counts via stdout on last line.
# Usage: _verify_linters <discovery_json> <project_dir>
_verify_linters() {
	local discovery="$1"
	local project_dir="$2"
	local pass_count=0
	local fail_count=0
	local skip_count=0

	while IFS= read -r linter_name; do
		[[ -z "$linter_name" ]] && continue
		local result
		result=$(_verify_linter "$linter_name" "$project_dir")
		local status="${result%%:*}"
		local label="${result#*:}"
		echo "  [${status}] ${label}"
		case "$status" in
		pass) pass_count=$((pass_count + 1)) ;;
		fail) fail_count=$((fail_count + 1)) ;;
		*) skip_count=$((skip_count + 1)) ;;
		esac
	done < <(echo "$discovery" | jq -r '.linters[].name')

	echo "counts:${pass_count}:${fail_count}:${skip_count}"
	return 0
}

# =============================================================================
# Verify Command
# =============================================================================

cmd_verify() {
	local project_dir
	project_dir=$(resolve_project_path "${1:-.}") || return 1

	echo ""
	echo "=== Test Verification ==="
	echo ""

	# Discover what's available
	local discovery
	discovery=$(cmd_discover "$project_dir")

	local pass_count=0
	local fail_count=0
	local skip_count=0

	# Run test runners
	local runner_output runner_counts
	runner_output=$(_verify_runners "$discovery" "$project_dir")
	runner_counts=$(echo "$runner_output" | grep '^counts:' | tail -1)
	printf '%s\n' "$runner_output" | sed '/^counts:/d'

	if [[ -n "$runner_counts" ]]; then
		local rp rf rs
		rp=$(echo "$runner_counts" | cut -d: -f2)
		rf=$(echo "$runner_counts" | cut -d: -f3)
		rs=$(echo "$runner_counts" | cut -d: -f4)
		pass_count=$((pass_count + rp))
		fail_count=$((fail_count + rf))
		skip_count=$((skip_count + rs))
	fi

	# Run linters
	local linter_output linter_counts
	linter_output=$(_verify_linters "$discovery" "$project_dir")
	linter_counts=$(echo "$linter_output" | grep '^counts:' | tail -1)
	printf '%s\n' "$linter_output" | sed '/^counts:/d'

	if [[ -n "$linter_counts" ]]; then
		local lp lf ls
		lp=$(echo "$linter_counts" | cut -d: -f2)
		lf=$(echo "$linter_counts" | cut -d: -f3)
		ls=$(echo "$linter_counts" | cut -d: -f4)
		pass_count=$((pass_count + lp))
		fail_count=$((fail_count + lf))
		skip_count=$((skip_count + ls))
	fi

	echo ""
	echo "  Results: ${pass_count} passed, ${fail_count} failed, ${skip_count} skipped"
	echo ""

	if [[ "$fail_count" -gt 0 ]]; then
		return 1
	fi
	return 0
}

# =============================================================================
# Help Command
# =============================================================================

cmd_help() {
	cat <<'HELP'
Testing Setup Helper - Existing testing-infrastructure inventory and verification

Usage:
  testing-setup-helper.sh <command> [project-path]

Commands:
  discover [path]    Scan project for existing test infrastructure (JSON output)
  gaps [path]        Classify bundle quality-gate candidates (report-only JSON)
  status [path]      Show human-readable test infrastructure status
  verify [path]      Explicitly run discovered existing test runners and linters
  help               Show this help

Options:
  project-path       Path to project root (default: current directory)

Examples:
  testing-setup-helper.sh discover ~/Git/my-app
  testing-setup-helper.sh gaps .
  testing-setup-helper.sh status
  testing-setup-helper.sh verify ~/Git/my-project

Integration:
  This helper is used by the explicitly invoked /testing-setup workflow. It
  inventories and verifies existing tooling; candidate output never authorises
  installation or configuration.

Related:
  /testing-setup                    Interactive setup command
  bundle-helper.sh resolve [path]   Detect project bundle
  linters-local.sh                  Local quality checks
  agent-test-helper.sh              Agent-specific testing
HELP
	return 0
}

# =============================================================================
# Main
# =============================================================================

main() {
	local command="${1:-help}"
	shift || true

	case "$command" in
	discover) cmd_discover "$@" ;;
	gaps) cmd_gaps "$@" ;;
	status) cmd_status "$@" ;;
	verify) cmd_verify "$@" ;;
	help | --help | -h) cmd_help ;;
	*)
		print_error "Unknown command: ${command}. Run 'testing-setup-helper.sh help' for usage."
		cmd_help
		return 1
		;;
	esac
	return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	main "$@"
fi
