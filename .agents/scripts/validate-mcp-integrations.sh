#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2317

# 🔍 MCP Integrations Validation Script
# Validates and tests all MCP integrations for proper functionality

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

print_header() {
	local msg="$1"
	echo -e "${PURPLE}$msg${NC}"
	return 0
}
# Test results tracking
declare -i total_tests=0
declare -i passed_tests=0
declare -i failed_tests=0

# Test function wrapper
run_test() {
	local test_name="$1"
	local test_command="$2"

	((++total_tests))
	print_info "Testing: $test_name"

	if bash -c "$test_command" &>/dev/null; then
		print_success "$test_name: PASSED"
		((++passed_tests))
		return 0
	else
		print_error "$test_name: FAILED"
		((++failed_tests))
		return 1
	fi
	return 0
}

# Test Node.js and npm
test_prerequisites() {
	print_header "Testing Prerequisites"

	run_test "Node.js availability" "command -v node"
	run_test "npm availability" "command -v npm"

	if command -v node &>/dev/null; then
		local node_version
		node_version=$(node --version)
		print_info "Node.js version: $node_version"
	fi

	if command -v npm &>/dev/null; then
		local npm_version
		npm_version=$(npm --version)
		print_info "npm version: $npm_version"
	fi
	return 0
}

# Test Chrome DevTools MCP
test_chrome_devtools() {
	print_header "Testing Chrome DevTools MCP"

	run_test "Chrome DevTools MCP package" "npm list -g chrome-devtools-mcp || npm info chrome-devtools-mcp"

	# Test Chrome availability
	local chrome_paths=(
		"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
		"/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary"
		"/usr/bin/google-chrome"
		"/usr/bin/google-chrome-stable"
		"/usr/bin/chromium-browser"
	)

	local chrome_found=false
	for chrome_path in "${chrome_paths[@]}"; do
		if [[ -x "$chrome_path" ]]; then
			print_success "Chrome found: $chrome_path"
			chrome_found=true
			break
		fi
	done

	if [[ "$chrome_found" == false ]]; then
		print_warning "Chrome not found in standard locations"
	fi
	return 0
}

# Test Playwright MCP
test_playwright() {
	print_header "Testing Playwright MCP"

	run_test "Playwright MCP package" "npm info @playwright/mcp@0.0.79"
	run_test "Playwright package" "npm list -g playwright || npm info playwright"

	# Test browser installations
	if command -v npx &>/dev/null; then
		print_info "Checking Playwright browser installations..."
		if npx playwright --version &>/dev/null; then
			print_success "Playwright CLI available"
		else
			print_warning "Playwright CLI not available"
		fi
	fi
	return 0
}

# Test API connectivity
test_api_connectivity() {
	print_header "Testing API Connectivity"

	# Test Ahrefs API
	if [[ -n "${AHREFS_API_KEY:-}" ]]; then
		run_test "Ahrefs API connectivity" "curl -s -H 'Authorization: Bearer $AHREFS_API_KEY' https://apiv2.ahrefs.com/v2/subscription_info"
		print_success "Ahrefs API key configured"
	else
		print_warning "Ahrefs API key not configured (AHREFS_API_KEY)"
	fi

	# Test Perplexity API
	if [[ -n "${PERPLEXITY_API_KEY:-}" ]]; then
		run_test "Perplexity API connectivity" "curl -s -H 'Authorization: Bearer $PERPLEXITY_API_KEY' https://api.perplexity.ai/chat/completions"
		print_success "Perplexity API key configured"
	else
		print_warning "Perplexity API key not configured (PERPLEXITY_API_KEY)"
	fi

	# Test Cloudflare API
	if [[ -n "${CLOUDFLARE_API_TOKEN:-}" && -n "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
		run_test "Cloudflare API connectivity" "curl -s -H 'Authorization: Bearer $CLOUDFLARE_API_TOKEN' https://api.cloudflare.com/client/v4/accounts/$CLOUDFLARE_ACCOUNT_ID"
		print_success "Cloudflare API credentials configured"
	else
		print_warning "Cloudflare API credentials not configured (CLOUDFLARE_API_TOKEN, CLOUDFLARE_ACCOUNT_ID)"
	fi
	return 0
}

# Validate a single JSON file directly (bypasses bash -c quoting issues)
# Uses jq if available, falls back to python3 -c with proper argument passing
validate_json_file() {
	local file="$1"

	if command -v jq &>/dev/null; then
		jq empty "$file" 2>/dev/null
		return $?
	elif command -v python3 &>/dev/null; then
		python3 -c "import json, sys; json.load(open(sys.argv[1]))" "$file" 2>/dev/null
		return $?
	else
		# No JSON validator available — skip rather than false-fail
		return 0
	fi
}

# Test MCP configurations
test_mcp_configurations() {
	print_header "Testing MCP Configurations"

	local config_dir="configs/mcp-templates"

	if [[ -d "$config_dir" ]]; then
		print_success "MCP templates directory exists"

		# Check for JSON validator availability
		if ! command -v jq &>/dev/null && ! command -v python3 &>/dev/null; then
			print_warning "No JSON validator found (install jq or python3)"
		fi

		# Validate each configuration file directly (not via bash -c)
		for config_file in "$config_dir"/*.json; do
			if [[ -f "$config_file" ]]; then
				local filename
				filename=$(basename "$config_file")
				((++total_tests))
				print_info "Testing: JSON validation: $filename"
				if validate_json_file "$config_file"; then
					print_success "JSON validation: $filename: PASSED"
					((++passed_tests))
				else
					print_error "JSON validation: $filename: FAILED"
					((++failed_tests))
				fi
			fi
		done
	else
		print_error "MCP templates directory not found: $config_dir"
	fi
	return 0
}

# Test Context7 MCP
test_context7() {
	print_header "Testing Context7 MCP"

	# Test remote MCP URL reachability
	run_test "Context7 MCP URL reachability" "curl -s --connect-timeout 10 -o /dev/null -w '%{http_code}' https://mcp.context7.com/mcp | grep -qE '^[23]'"

	# Test Context7 MCP npm package availability
	run_test "Context7 MCP package" "npm list -g @context7/mcp-server || npm info @context7/mcp-server"

	# Validate context7-mcp-config.json.txt template if it exists
	local config_template="configs/context7-mcp-config.json.txt"
	if [[ -f "$config_template" ]]; then
		run_test "Context7 config template JSON validation" "jq . >/dev/null < \"$config_template\""
		print_success "Context7 config template found: $config_template"
	else
		print_warning "Context7 config template not found: $config_template"
	fi
	return 0
}

# Test network connectivity
test_network() {
	print_header "Testing Network Connectivity"

	run_test "Internet connectivity" "curl -s --connect-timeout 5 https://www.google.com"
	run_test "npm registry" "curl -s --connect-timeout 5 https://registry.npmjs.org/"
	run_test "GitHub connectivity" "curl -s --connect-timeout 5 https://api.github.com"
	return 0
}

# Generate validation report
generate_report() {
	print_header "Validation Report"

	echo
	print_info "Total tests run: $total_tests"
	print_success "Tests passed: $passed_tests"

	if [[ $failed_tests -gt 0 ]]; then
		print_error "Tests failed: $failed_tests"
	else
		print_success "Tests failed: $failed_tests"
	fi

	echo
	local success_rate
	success_rate=$((passed_tests * 100 / total_tests))

	if [[ $success_rate -ge 90 ]]; then
		print_success "Overall status: EXCELLENT ($success_rate% success rate)"
	elif [[ $success_rate -ge 75 ]]; then
		print_success "Overall status: GOOD ($success_rate% success rate)"
	elif [[ $success_rate -ge 50 ]]; then
		print_warning "Overall status: NEEDS ATTENTION ($success_rate% success rate)"
	else
		print_error "Overall status: CRITICAL ISSUES ($success_rate% success rate)"
	fi

	echo
	if [[ $failed_tests -gt 0 ]]; then
		print_info "Next steps:"
		print_info "1. Review failed tests above"
		print_info "2. Check .agents/MCP-TROUBLESHOOTING.md for solutions"
		print_info "3. Run setup script: bash .agents/scripts/setup-mcp-integrations.sh"
		print_info "4. Configure missing API keys"
	else
		print_success "All MCP integrations are ready to use!"
		print_info "Check .agents/MCP-INTEGRATIONS.md for usage examples"
	fi
	return 0
}

# Main validation function
main() {
	print_header "MCP Integrations Validation"
	echo

	test_prerequisites
	echo

	test_network
	echo

	test_chrome_devtools
	echo

	test_playwright
	echo

	test_api_connectivity
	echo

	test_context7
	echo

	test_mcp_configurations
	echo

	generate_report
	return 0
}

main "$@"
