#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local passed="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))

	if [[ "$passed" -eq 0 ]]; then
		printf 'PASS %s\n' "$test_name"
		return 0
	fi

	printf 'FAIL %s\n' "$test_name"
	if [[ -n "$message" ]]; then
		printf '       %s\n' "$message"
	fi
	TESTS_FAILED=$((TESTS_FAILED + 1))
	return 0
}

assert_file_lacks() {
	local file_path="$1"
	local pattern="$2"
	local test_name="$3"

	if grep -q -- "$pattern" "$file_path"; then
		print_result "$test_name" 1 "unexpected pattern in ${file_path#"$REPO_ROOT"/}"
		return 0
	fi

	print_result "$test_name" 0
	return 0
}

test_runtime_generator_does_not_register_removed_mcp() {
	local aug="aug"
	local gie="gie"
	local removed_mcp="${aug}${gie}-mcp"
	local removed_context="${aug}ment-context-engine"
	local generator="$REPO_ROOT/.agents/scripts/generate-runtime-config-mcp.sh"
	local claude_generator="$REPO_ROOT/.agents/scripts/generate-claude-agents.sh"

	assert_file_lacks "$generator" "$removed_mcp" "runtime generator omits removed Auggie MCP"
	assert_file_lacks "$generator" "$removed_context" "runtime generator omits removed Augment MCP"
	assert_file_lacks "$claude_generator" "$removed_mcp" "Claude generator omits removed Auggie MCP"
	return 0
}

test_removed_mcp_templates_are_deleted() {
	local aug="aug"
	local removed_context="${aug}ment-context-engine"
	local removed_files=(
		"$REPO_ROOT/.agents/tools/context/${removed_context}.md"
		"$REPO_ROOT/configs/${removed_context}-config.json.txt"
		"$REPO_ROOT/configs/mcp-templates/${removed_context}.json"
	)

	local removed_file
	for removed_file in "${removed_files[@]}"; do
		if [[ -e "$removed_file" ]]; then
			print_result "removed Augment MCP templates are deleted" 1 "still exists: ${removed_file#"$REPO_ROOT"/}"
			return 0
		fi
	done

	print_result "removed Augment MCP templates are deleted" 0
	return 0
}

test_opencode_registry_does_not_start_removed_binary() {
	local aug="aug"
	local gie="gie"
	local registry="$REPO_ROOT/.agents/plugins/opencode-aidevops/mcp-registry.mjs"
	local binary_name="${aug}${gie}"
	local command_pattern="command: \[\"${binary_name}\", \"--mcp\"\]"

	assert_file_lacks "$registry" "$command_pattern" "OpenCode registry does not start removed MCP binary"
	return 0
}

test_migration_removes_stale_entries() {
	local tmp_config
	tmp_config="$(mktemp)"

	local aug="aug"
	local gie="gie"
	local removed_mcp="${aug}${gie}-mcp"
	local removed_context="${aug}ment-context-engine"

	printf '{"mcp":{"%s":{},"context7":{}},"mcpServers":[{"name":"%s"},{"name":"Augment-Context-Engine"},{"name":"sentry"}],"servers":{"augmentcode":{},"filesystem":{}},"tools":{"%s_*":true,"%s_*":true,"context7_*":true},"agent":{"Build":{"tools":{"%s_*":true,"%s_*":true,"context7_*":true}}}}\n' \
		"$removed_mcp" "$removed_context" "$removed_mcp" "$removed_context" "$removed_mcp" "$removed_context" >"$tmp_config"

	# shellcheck source=/dev/null
	source "$REPO_ROOT/.agents/scripts/setup/modules/migrations.sh"
	_remove_deprecated_mcp_entries "$tmp_config"

	if jq -e --arg removed_mcp "$removed_mcp" --arg removed_context "$removed_context" \
		'(.mcp[$removed_mcp] // (.mcpServers[]? | select(.name == $removed_context or .name == "Augment-Context-Engine")) // .servers.augmentcode // .tools[$removed_mcp + "_*"] // .tools[$removed_context + "_*"] // .agent.Build.tools[$removed_mcp + "_*"] // .agent.Build.tools[$removed_context + "_*"])' \
		"$tmp_config" >/dev/null; then
		print_result "migration removes stale Auggie/Augment config entries" 1 "stale entry remained"
		rm -f "$tmp_config"
		return 0
	fi

	if jq -e '.mcp.context7 and any(.mcpServers[]; .name == "sentry") and .servers.filesystem and .tools["context7_*"] and .agent.Build.tools["context7_*"]' "$tmp_config" >/dev/null; then
		print_result "migration removes stale Auggie/Augment config entries" 0
		rm -f "$tmp_config"
		return 0
	fi

	print_result "migration removes stale Auggie/Augment config entries" 1 "unrelated MCP entry was removed"
	rm -f "$tmp_config"
	return 0
}

test_setup_cleanup_updates_supported_app_configs() {
	local test_home
	test_home="$(mktemp -d)"
	mkdir -p "$test_home/.codex" "$test_home/.continue" "$test_home/.cursor" "$test_home/.gemini"

	printf '{"mcpServers":{"auggie-mcp":{"command":"auggie"},"context7":{}}}\n' >"$test_home/.cursor/mcp.json"
	printf '{"mcpServers":{"augment-context-engine":{"command":"auggie"},"sentry":{}}}\n' >"$test_home/.gemini/settings.json"
	printf '{"mcpServers":[{"name":"auggie-mcp","transport":{"command":"auggie"}},{"name":"context7","transport":{}}]}\n' >"$test_home/.continue/config.json"
	printf '[mcp_servers.auggie-mcp]\ncommand = "auggie"\n\n[mcp_servers.context7]\ncommand = "npx"\n' >"$test_home/.codex/config.toml"
	printf 'mcpServers:\n  auggie-mcp:\n    command: "auggie"\n  context7:\n    command: "npx"\n' >"$test_home/.aider.conf.yml"

	(
		export HOME="$test_home"
		find_opencode_config() { return 1; }
		create_backup_with_rotation() { return 0; }
		print_info() { return 0; }
		# shellcheck source=/dev/null
		source "$REPO_ROOT/.agents/scripts/setup/modules/migrations.sh"
		cleanup_deprecated_mcps
	)

	if jq -e '.mcpServers["auggie-mcp"]' "$test_home/.cursor/mcp.json" >/dev/null ||
		jq -e '.mcpServers["augment-context-engine"]' "$test_home/.gemini/settings.json" >/dev/null ||
		jq -e '.mcpServers[]? | select(.name == "auggie-mcp")' "$test_home/.continue/config.json" >/dev/null ||
		grep -Eq 'auggie-mcp|augment-context-engine' "$test_home/.codex/config.toml" "$test_home/.aider.conf.yml"; then
		print_result "setup cleanup removes Auggie MCP from supported app configs" 1 "stale app entry remained"
		rm -rf "$test_home"
		return 0
	fi

	if jq -e '.mcpServers.context7' "$test_home/.cursor/mcp.json" >/dev/null &&
		jq -e '.mcpServers.sentry' "$test_home/.gemini/settings.json" >/dev/null &&
		jq -e 'any(.mcpServers[]; .name == "context7")' "$test_home/.continue/config.json" >/dev/null &&
		grep -q '^\[mcp_servers.context7\]' "$test_home/.codex/config.toml" &&
		grep -q '^  context7:' "$test_home/.aider.conf.yml" &&
		[[ -f "$test_home/.aidevops/.migrations/cleanup-deprecated-mcps-v4" ]]; then
		print_result "setup cleanup removes Auggie MCP from supported app configs" 0
		rm -rf "$test_home"
		return 0
	fi

	print_result "setup cleanup removes Auggie MCP from supported app configs" 1 "unrelated app config changed or sentinel missing"
	rm -rf "$test_home"
	return 0
}

main() {
	test_runtime_generator_does_not_register_removed_mcp
	test_removed_mcp_templates_are_deleted
	test_opencode_registry_does_not_start_removed_binary
	test_migration_removes_stale_entries
	test_setup_cleanup_updates_supported_app_configs

	printf '\nRan %s tests, %s failed\n' "$TESTS_RUN" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -ne 0 ]]; then
		exit 1
	fi

	return 0
}

main "$@"
