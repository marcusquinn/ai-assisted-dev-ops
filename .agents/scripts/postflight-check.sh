#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034,SC2155
# Postflight Verification Script
# Verifies release health after tag creation and GitHub release publication
#
# Usage: ./postflight-check.sh [--quick|--full|--ci-only|--security-only]
#
# Author: AI DevOps Framework
# Version: 1.0.0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

# Configuration
readonly TIMEOUT_CI=600    # 10 minutes for CI/CD
readonly TIMEOUT_TOOLS=300 # 5 minutes for code review tools
readonly POLL_INTERVAL=30  # Check every 30 seconds
readonly MAX_ATTEMPTS=20   # Maximum polling attempts

# Repository info
readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || exit
readonly SONAR_PROJECT_KEY="marcusquinn_aidevops"
# Save the original working directory for git operations (supports worktrees)
readonly ORIGINAL_PWD="$PWD"

# Counters
PASSED=0
FAILED=0
WARNINGS=0
SKIPPED=0
POSTFLIGHT_COMMIT_SHA=""

print_header() {
	echo -e "${BLUE}========================================${NC}"
	echo -e "${BLUE}  Postflight Verification${NC}"
	echo -e "${BLUE}========================================${NC}"
	echo "Started: $(date)"
	echo ""
	return 0
}

print_skip() {
	local message="$1"
	echo -e "${BLUE}SKIPPED${NC} $message"
	((++SKIPPED))
	return 0
}

print_section() {
	local title="$1"
	echo ""
	echo -e "${BLUE}--- $title ---${NC}"
	return 0
}

count_success() {
	local message="$1"
	print_success "$message"
	((++PASSED))
	return 0
}

count_failure() {
	local message="$1"
	print_error "$message"
	FAILED=$((FAILED + 1))
	return 0
}

count_warning() {
	local message="$1"
	print_warning "$message"
	((++WARNINGS))
	return 0
}

# Check if gh CLI is available and authenticated
check_gh_cli() {
	if ! command -v gh &>/dev/null; then
		print_error "GitHub CLI (gh) not installed"
		return 1
	fi

	if ! gh auth status &>/dev/null; then
		print_error "GitHub CLI not authenticated. Run: gh auth login"
		return 1
	fi

	return 0
}

# Get repository owner and name from original directory (works with worktrees)
get_repo_info() {
	local remote_url
	# Use original working directory's git context (saved before cd to REPO_ROOT)
	remote_url=$(git -C "$ORIGINAL_PWD" remote get-url origin 2>/dev/null || echo "")

	if [[ -z "$remote_url" ]]; then
		echo ""
		return 1
	fi

	# Extract owner/repo from various URL formats using parameter expansion
	# (bash 3.2 compatible - regex capture groups don't work reliably on macOS)
	local repo_path
	if [[ "$remote_url" == *"github.com"* ]]; then
		# Handle HTTPS: https://github.com/owner/repo.git
		if [[ "$remote_url" == *"github.com/"* ]]; then
			repo_path="${remote_url#*github.com/}"
		# Handle SSH: git@github.com:owner/repo.git
		elif [[ "$remote_url" == *"github.com:"* ]]; then
			repo_path="${remote_url#*github.com:}"
		else
			echo ""
			return 1
		fi
		# Remove .git suffix if present
		repo_path="${repo_path%.git}"
		if [[ -n "$repo_path" && "$repo_path" == *"/"* ]]; then
			echo "$repo_path"
			return 0
		fi
	fi

	echo ""
	return 1
}

# Load check runs whose suites belong to release-triggered workflows on one SHA.
load_release_owned_checks() {
	local repo="$1"
	local release_sha="$2"
	local release_tag="${POSTFLIGHT_RELEASE_TAG:-}"
	local check_runs_response release_runs_response recovery_runs_response
	check_runs_response=$(gh api --paginate --slurp \
		"repos/${repo}/commits/${release_sha}/check-runs?per_page=100" 2>/dev/null |
		jq -c -f "$SCRIPT_DIR/jq/flatten-check-run-pages.jq") || return 1
	release_runs_response=$(gh api --paginate --slurp \
		"repos/${repo}/actions/runs?head_sha=${release_sha}&per_page=100" 2>/dev/null) || return 1
	if [[ -n "$release_tag" ]]; then
		recovery_runs_response=$(gh api --paginate --slurp \
			"repos/${repo}/actions/workflows/publish-packages.yml/runs?event=workflow_dispatch&per_page=100" \
			2>/dev/null) || return 1
	else
		recovery_runs_response='{"workflow_runs":[]}'
	fi
	jq -c \
		--arg release_sha "$release_sha" \
		--arg release_tag "$release_tag" \
		--arg self_name "Verify Release Health" \
		--slurpfile release_run_documents <(printf '%s\n' "$release_runs_response") \
		--slurpfile recovery_run_documents <(printf '%s\n' "$recovery_runs_response") \
		-f "$SCRIPT_DIR/jq/release-owned-check-runs.jq" \
		<<<"$check_runs_response"
	return $?
}

# Check GitHub Actions CI/CD status using release-owned exact-SHA evidence.
check_cicd_status() {
	print_section "CI/CD Pipeline Status"

	if ! check_gh_cli; then
		FAILED=$((FAILED + 1))
		return 1
	fi

	local repo release_sha release_checks
	repo=$(get_repo_info)
	if [[ -z "$repo" ]]; then
		count_failure "Could not determine repository"
		return 1
	fi
	print_info "Repository: $repo"
	release_sha="${POSTFLIGHT_COMMIT_SHA:-$(git -C "$ORIGINAL_PWD" rev-parse HEAD 2>/dev/null || true)}"
	if [[ -z "$release_sha" ]]; then
		count_failure "Could not determine exact release commit"
		return 1
	fi
	print_info "Release commit: $release_sha"
	release_checks=$(load_release_owned_checks "$repo" "$release_sha") || {
		count_failure "Could not load release-owned workflow evidence"
		return 1
	}

	local unrelated_count
	unrelated_count=$(jq '.unrelated_workflow_runs | length' <<<"$release_checks")
	if [[ "$unrelated_count" -gt 0 ]]; then
		count_warning "$unrelated_count unrelated issue/comment workflow run(s) excluded from release evidence"
		jq -r '.unrelated_workflow_runs[] | "  - \(.name) [event=\(.event), id=\(.id)]"' <<<"$release_checks"
	fi

	local attempt=0 pending_count
	pending_count=$(jq '[.check_runs[] | select(.status != "completed")] | length' <<<"$release_checks")
	while [[ "$pending_count" -gt 0 && "$attempt" -lt "$MAX_ATTEMPTS" ]]; do
		((++attempt))
		print_info "Waiting for $pending_count release-owned check(s) (attempt $attempt/$MAX_ATTEMPTS)"
		sleep "$POLL_INTERVAL"
		release_checks=$(load_release_owned_checks "$repo" "$release_sha") || continue
		pending_count=$(jq '[.check_runs[] | select(.status != "completed")] | length' <<<"$release_checks")
	done

	local required_count failed_count
	required_count=$(jq '.check_runs | length' <<<"$release_checks")
	if [[ "$required_count" -eq 0 ]]; then
		count_failure "No release-owned check-run evidence exists for $release_sha"
		return 1
	fi
	if [[ "$pending_count" -gt 0 ]]; then
		count_failure "$pending_count release-owned check(s) remained non-terminal after timeout"
		jq -r '.check_runs[] | select(.status != "completed") | "  - \(.name): \(.status)"' <<<"$release_checks"
		return 1
	fi

	failed_count=$(jq '[.check_runs[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required")] | length' <<<"$release_checks")
	if [[ "$failed_count" -gt 0 ]]; then
		count_failure "$failed_count required release-owned check(s) failed"
		jq -r '.check_runs[] | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required") | "  - \(.name): \(.conclusion)"' <<<"$release_checks"
		return 1
	fi

	count_success "$required_count required release-owned check(s) passed"
	local advisory_pending
	advisory_pending=$(jq '[.advisory_check_runs[] | select(.status != "completed")] | length' <<<"$release_checks")
	if [[ "$advisory_pending" -gt 0 ]]; then
		count_warning "$advisory_pending non-required advisory check(s) remain non-terminal"
	fi
	return 0
}

# Check SonarCloud quality gate
check_sonarcloud() {
	print_section "SonarCloud Analysis"

	# Check quality gate status
	local qg_response
	qg_response=$(curl -s "https://sonarcloud.io/api/qualitygates/project_status?projectKey=$SONAR_PROJECT_KEY" 2>/dev/null || echo "")

	if [[ -z "$qg_response" ]]; then
		print_skip "Could not reach SonarCloud API"
		return 0
	fi

	local qg_status
	qg_status=$(echo "$qg_response" | jq -r '.projectStatus.status // "UNKNOWN"')

	if [[ "$qg_status" == "OK" ]]; then
		count_success "SonarCloud quality gate: PASSED"
	elif [[ "$qg_status" == "ERROR" ]]; then
		count_failure "SonarCloud quality gate: FAILED"

		# Get failing conditions
		echo "$qg_response" | jq -r '.projectStatus.conditions[] | select(.status == "ERROR") | "  - \(.metricKey): \(.actualValue) (threshold: \(.errorThreshold))"'
	elif [[ "$qg_status" == "WARN" ]]; then
		count_warning "SonarCloud quality gate: WARNING"
	else
		count_warning "SonarCloud quality gate status: $qg_status"
	fi

	# Get current metrics
	local metrics_response
	metrics_response=$(curl -s "https://sonarcloud.io/api/measures/component?component=$SONAR_PROJECT_KEY&metricKeys=bugs,vulnerabilities,code_smells,security_hotspots" 2>/dev/null || echo "")

	if [[ -n "$metrics_response" ]]; then
		print_info "Current metrics:"
		echo "$metrics_response" | jq -r '.component.measures[] | "  - \(.metric): \(.value)"' 2>/dev/null || true
	fi

	# Check for new issues
	local issues_response
	issues_response=$(curl -s "https://sonarcloud.io/api/issues/search?componentKeys=$SONAR_PROJECT_KEY&resolved=false&severities=BLOCKER,CRITICAL&ps=5" 2>/dev/null || echo "")

	if [[ -n "$issues_response" ]]; then
		local critical_count
		critical_count=$(echo "$issues_response" | jq -r '.total // 0')

		if [[ "$critical_count" -gt 0 ]]; then
			print_warning "$critical_count blocker/critical issues found"
			echo "$issues_response" | jq -r '.issues[] | "  - [\(.severity)] \(.message)"' 2>/dev/null | head -5 || true
		fi
	fi

	return 0
}

# Check Codacy status
check_codacy() {
	print_section "Codacy Analysis"

	local codacy_script="$REPO_ROOT/.agents/scripts/codacy-cli.sh"

	if [[ -f "$codacy_script" ]]; then
		if bash "$codacy_script" status &>/dev/null; then
			print_success "Codacy CLI: Available"
			print_info "Run 'bash $codacy_script analyze' for detailed analysis"
		else
			print_skip "Codacy CLI not configured"
		fi
	else
		print_skip "Codacy CLI script not found"
	fi

	# Check via dashboard link
	print_info "Dashboard: https://app.codacy.com/gh/marcusquinn/aidevops"

	return 0
}

# Check security with Snyk
check_snyk() {
	print_section "Security Scanning (Snyk)"

	if ! command -v snyk &>/dev/null; then
		print_skip "Snyk CLI not installed"
		print_info "Install: brew tap snyk/tap && brew install snyk-cli"
		return 0
	fi

	# Check authentication
	if ! snyk auth check &>/dev/null 2>&1; then
		print_skip "Snyk not authenticated"
		print_info "Run: snyk auth"
		return 0
	fi

	print_info "Running Snyk security scan..."

	local snyk_output
	local snyk_exit=0
	snyk_output=$(snyk test --severity-threshold=high --json 2>/dev/null) || snyk_exit=$?

	if [[ $snyk_exit -eq 0 ]]; then
		count_success "Snyk: No high/critical vulnerabilities"
	elif [[ $snyk_exit -eq 1 ]]; then
		local vuln_count
		vuln_count=$(echo "$snyk_output" | jq -r '.vulnerabilities | length // 0')
		count_failure "Snyk: $vuln_count vulnerabilities found"

		# Show top vulnerabilities
		echo "$snyk_output" | jq -r '.vulnerabilities[:5][] | "  - [\(.severity)] \(.title) in \(.packageName)"' 2>/dev/null || true
	else
		count_warning "Snyk scan completed with warnings"
	fi

	return 0
}

# Check for exposed secrets
check_secrets() {
	print_section "Secret Detection (Secretlint)"

	if command -v secretlint &>/dev/null; then
		print_info "Running Secretlint scan..."

		if secretlint "**/*" --format compact 2>/dev/null; then
			count_success "Secretlint: No secrets detected"
		else
			count_failure "Secretlint: Potential secrets found"
			return 1
		fi
	elif [[ -f "$REPO_ROOT/node_modules/.bin/secretlint" ]]; then
		print_info "Running Secretlint (local)..."

		if "$REPO_ROOT/node_modules/.bin/secretlint" "**/*" --format compact 2>/dev/null; then
			count_success "Secretlint: No secrets detected"
		else
			count_failure "Secretlint: Potential secrets found"
			return 1
		fi
	else
		print_skip "Secretlint not installed"
		print_info "Install: npm install -g secretlint @secretlint/secretlint-rule-preset-recommend"
	fi

	return 0
}

# Check npm audit (if applicable)
check_npm_audit() {
	print_section "Dependency Audit"

	if [[ -f "$REPO_ROOT/package.json" ]]; then
		if [[ ! -f "$REPO_ROOT/package-lock.json" && ! -f "$REPO_ROOT/npm-shrinkwrap.json" ]]; then
			print_skip "npm audit skipped (no npm lockfile present)"
			return 0
		fi

		if command -v npm &>/dev/null; then
			print_info "Running npm audit..."

			local audit_output
			local audit_exit=0
			audit_output=$(npm audit --audit-level=high --json 2>/dev/null) || audit_exit=$?

			if [[ $audit_exit -eq 0 ]]; then
				print_success "npm audit: No high/critical vulnerabilities"
			else
				local vuln_count
				vuln_count=$(echo "$audit_output" | jq -r '.metadata.vulnerabilities.high + .metadata.vulnerabilities.critical // 0')
				print_warning "npm audit: $vuln_count high/critical vulnerabilities"
			fi
		else
			print_skip "npm not available"
		fi
	else
		print_skip "No package.json found"
	fi

	return 0
}

# Print summary
print_summary() {
	echo ""
	echo -e "${BLUE}========================================${NC}"
	echo -e "${BLUE}  Summary${NC}"
	echo -e "${BLUE}========================================${NC}"
	echo "Finished: $(date)"
	echo ""
	echo -e "  ${GREEN}Passed:${NC}   $PASSED"
	echo -e "  ${RED}Failed:${NC}   $FAILED"
	echo -e "  ${YELLOW}Warnings:${NC} $WARNINGS"
	echo -e "  ${BLUE}Skipped:${NC}  $SKIPPED"
	echo ""

	if [[ $FAILED -gt 0 ]]; then
		echo -e "${RED}POSTFLIGHT VERIFICATION FAILED${NC}"
		echo ""
		echo "Recommended actions:"
		echo "  1. Review failed checks above"
		echo "  2. Consider rollback if critical issues found"
		echo "  3. See: .agents/workflows/postflight.md#rollback-procedures"
		return 1
	elif [[ $WARNINGS -gt 0 ]]; then
		echo -e "${YELLOW}POSTFLIGHT VERIFICATION PASSED WITH WARNINGS${NC}"
		echo ""
		echo "Review warnings above and address in next release if needed."
		return 0
	else
		echo -e "${GREEN}POSTFLIGHT VERIFICATION PASSED${NC}"
		return 0
	fi
}

# Show usage
show_usage() {
	echo "Usage: $0 [OPTIONS]"
	echo ""
	echo "Options:"
	echo "  --quick         Run quick checks only (CI/CD + SonarCloud)"
	echo "  --full          Run all checks (default)"
	echo "  --ci-only       Run CI/CD checks only"
	echo "  --security-only Run security checks only"
	echo "  --sha SHA       Verify CI evidence for this exact release commit"
	echo "  --help          Show this help message"
	echo ""
	echo "Examples:"
	echo "  $0              # Run full postflight verification"
	echo "  $0 --quick      # Quick check after minor release"
	echo "  $0 --security   # Security-focused verification"
	return 0
}

# Main function
main() {
	local mode="full"

	# Parse arguments
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--quick)
			mode="quick"
			shift
			;;
		--full)
			mode="full"
			shift
			;;
		--ci-only)
			mode="ci-only"
			shift
			;;
		--security-only)
			mode="security-only"
			shift
			;;
		--sha)
			if [[ $# -lt 2 || -z "${2:-}" ]]; then
				echo "--sha requires a commit SHA"
				return 1
			fi
			POSTFLIGHT_COMMIT_SHA="$2"
			shift 2
			;;
		--help | -h)
			show_usage
			return 0
			;;
		*)
			echo "Unknown option: $arg"
			show_usage
			return 1
			;;
		esac
	done

	print_header

	cd "$REPO_ROOT" || exit

	case "$mode" in
	quick)
		check_cicd_status || true
		check_sonarcloud || true
		;;
	ci-only)
		check_cicd_status || true
		;;
	security-only)
		check_snyk || true
		check_secrets || true
		check_npm_audit || true
		;;
	full)
		check_cicd_status || true
		check_sonarcloud || true
		check_codacy || true
		;;
	*)
		print_error "Unknown mode: $mode"
		return 1
		;;
	esac

	print_summary
	return $?
}

main "$@"
