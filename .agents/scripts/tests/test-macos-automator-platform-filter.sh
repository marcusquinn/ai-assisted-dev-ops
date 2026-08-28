#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#29310: the macOS Automator MCP must not be
# installed or checked for updates on non-Darwin hosts.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
MCP_SETUP="$REPO_ROOT/.agents/scripts/setup/modules/mcp-setup.sh"
TOOL_VERSION_CHECK="$REPO_ROOT/.agents/scripts/tool-version-check.sh"
TEST_TMP_PARENT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEST_TMP_PARENT"
SANDBOX="$(mktemp -d "${TEST_TMP_PARENT}/gh29310-XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

PASS=0
FAIL=0

record_result() {
	local description="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		printf 'PASS: %s\n' "$description"
		PASS=$((PASS + 1))
		return 0
	fi
	printf 'FAIL: %s -- expected %s, got %s\n' "$description" "$expected" "$actual" >&2
	FAIL=$((FAIL + 1))
	return 0
}

run_setup_case() (
	TEST_CASE_PLATFORM="$1"
	local call_log="$2"
	# shellcheck source=../setup/modules/mcp-setup.sh
	source "$MCP_SETUP"
	uname() {
		printf '%s\n' "$TEST_CASE_PLATFORM"
		return 0
	}
	print_info() { return 0; }
	print_warning() { return 0; }
	print_success() { return 0; }
	npm_global_install() {
		local package="$1"
		printf '%s\n' "$package" >>"$call_log"
		return 0
	}
	run_with_spinner() {
		local description="$1"
		shift
		[[ -n "$description" ]] || return 1
		"$@"
		return $?
	}
	_install_mcp_packages_node
	return $?
)

extract_tool_functions() {
	local output="$1"
	awk '
		/^_tool_package_supported_on_platform\(\)/, /^}$/ { print; next }
		/^check_category\(\)/, /^}$/ { print; next }
	' "$TOOL_VERSION_CHECK" >"$output"
	grep -q '^_tool_package_supported_on_platform()' "$output" || return 1
	grep -q '^check_category()' "$output" || return 1
	return 0
}

run_tool_case() (
	TEST_CASE_PLATFORM="$1"
	local call_log="$2"
	local extracted="$SANDBOX/tool-functions.sh"
	extract_tool_functions "$extracted" || return 1
	JSON_OUTPUT=true
	QUIET=true
	BOLD=""
	CYAN=""
	NC=""
	uname() {
		printf '%s\n' "$TEST_CASE_PLATFORM"
		return 0
	}
	check_tool() {
		local category="$1"
		local name="$2"
		local cmd="$3"
		local ver_flag="$4"
		local package="$5"
		local update_cmd="$6"
		printf '%s|%s|%s|%s|%s|%s\n' "$category" "$name" "$cmd" "$ver_flag" "$package" "$update_cmd" >>"$call_log"
		return 0
	}
	# shellcheck source=/dev/null
	source "$extracted"
	check_category "NPM" \
		"npm|Automator|macos-automator-mcp|--version|@steipete/macos-automator-mcp|update automator" \
		"npm|Playwriter|playwriter|--version|playwriter|update playwriter"
	return $?
)

linux_setup_log="$SANDBOX/linux-setup.log"
darwin_setup_log="$SANDBOX/darwin-setup.log"
linux_tool_log="$SANDBOX/linux-tool.log"
darwin_tool_log="$SANDBOX/darwin-tool.log"
: >"$linux_setup_log"
: >"$darwin_setup_log"
: >"$linux_tool_log"
: >"$darwin_tool_log"

run_setup_case Linux "$linux_setup_log"
run_setup_case Darwin "$darwin_setup_log"
run_tool_case Linux "$linux_tool_log"
run_tool_case Darwin "$darwin_tool_log"

record_result "Linux setup skips macOS Automator MCP" "0" "$(grep -c 'macos-automator-mcp' "$linux_setup_log" || true)"
record_result "Darwin setup retains macOS Automator MCP" "1" "$(grep -c 'macos-automator-mcp' "$darwin_setup_log" || true)"
record_result "Linux freshness skips macOS Automator MCP" "0" "$(grep -c 'macos-automator-mcp' "$linux_tool_log" || true)"
record_result "Darwin freshness retains macOS Automator MCP" "1" "$(grep -c 'macos-automator-mcp' "$darwin_tool_log" || true)"
record_result "Linux setup retains pinned cross-platform MCPs" "1" "$(grep -c 'playwriter@0.5.0' "$linux_setup_log" || true)"
record_result "Linux freshness retains cross-platform MCPs" "1" "$(grep -c '|playwriter|' "$linux_tool_log" || true)"

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
exit 0
