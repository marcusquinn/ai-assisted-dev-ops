#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression test for GH#22270: enabled plugin namespaces appear in the shared
# subagent discovery index without startup-time reads of every plugin file.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)" || exit 1
TEST_HOME=""
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

print_result() {
	local test_name="$1"
	local status="$2"
	local message="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$status" -eq 0 ]]; then
		echo "PASS $test_name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo "FAIL $test_name"
		if [[ -n "$message" ]]; then
			echo "  $message"
		fi
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

setup() {
	TEST_HOME=$(mktemp -d)
	trap teardown EXIT

	local agents_dir="$TEST_HOME/.aidevops/agents"
	local config_dir="$TEST_HOME/.config/aidevops"
	mkdir -p "$agents_dir/scripts" "$agents_dir/example-plugin" \
		"$agents_dir/business" "$agents_dir/public-relations" \
		"$agents_dir/tools/design/library/brands/example" "$config_dir"
	cp "$REPO_ROOT/.agents/scripts/subagent-index-helper.sh" "$agents_dir/scripts/"
	cp "$REPO_ROOT/.agents/scripts/plugin-loader-helper.sh" "$agents_dir/scripts/"
	cp "$REPO_ROOT/.agents/scripts/plugin-source-trust-lib.sh" "$agents_dir/scripts/"
	cp "$REPO_ROOT/.agents/scripts/managed-label-provisioning-lib.sh" "$agents_dir/scripts/"
	cp "$REPO_ROOT/.agents/scripts/privacy-guard-helper.sh" "$agents_dir/scripts/"
	cp "$REPO_ROOT/.agents/scripts/portable-stat.sh" "$agents_dir/scripts/"
	cp "$REPO_ROOT"/.agents/scripts/shared-*.sh "$agents_dir/scripts/"
	chmod +x "$agents_dir/scripts/subagent-index-helper.sh" "$agents_dir/scripts/plugin-loader-helper.sh"

	cat >"$agents_dir/example-plugin/plugin.json" <<'JSON'
{"name":"Example Plugin","version":"1.0.0","description":"Example plugin agents","agents":[{"file":"example-agent.md","name":"example-agent","description":"Example agent","model":"standard"}]}
JSON
	cat >"$agents_dir/example-plugin/example-agent.md" <<'EOF_AGENT'
---
name: example-agent
mode: subagent
---
# Example Agent
EOF_AGENT
	cat >"$agents_dir/public-relations/media-list-builder.md" <<'EOF_AGENT'
# Media List Builder
EOF_AGENT
	cat >"$agents_dir/business/accounting.md" <<'EOF_AGENT'
# Accounting
EOF_AGENT
	cat >"$agents_dir/tools/design/library/brands/example/DESIGN.md" <<'EOF_AGENT'
# Example Design Catalogue
EOF_AGENT
	# shellcheck source=/dev/null
	source "$REPO_ROOT/.agents/scripts/plugin-source-trust-lib.sh"
	local inventory_tsv="$TEST_HOME/inventory.tsv"
	local inventory_json="$TEST_HOME/inventory.json"
	local tree_digest=""
	tree_digest=$(plugin_trust_tree_metadata "$agents_dir/example-plugin" "$inventory_tsv" "$inventory_json")
	jq -n --arg digest "$tree_digest" --slurpfile inventory "$inventory_json" '{plugins:[{
		name:"Example Plugin", repo:"local", branch:"main", namespace:"example-plugin",
		enabled:true, trusted_commit:"1111111111111111111111111111111111111111",
		deployed_commit:"1111111111111111111111111111111111111111",
		deployed_tree_digest:$digest, deployed_tree_inventory:$inventory[0], hooks_enabled:false
	}]}' >"$config_dir/plugins.json"
	return 0
}

teardown() {
	if [[ -n "$TEST_HOME" && -d "$TEST_HOME" ]]; then
		rm -rf "$TEST_HOME"
	fi
	return 0
}

test_plugin_namespace_indexed() {
	local output=""
	local status=0
	output=$(HOME="$TEST_HOME" AIDEVOPS_AGENTS_DIR="$TEST_HOME/.aidevops/agents" "$TEST_HOME/.aidevops/agents/scripts/subagent-index-helper.sh" generate 2>&1)
	status=$?
	if [[ "$status" -ne 0 ]]; then
		print_result "generate includes plugin namespace" 1 "$output"
		return 0
	fi

	local index_file="$TEST_HOME/.aidevops/agents/subagent-index.toon"
	if [[ ! -f "$index_file" ]]; then
		print_result "generate includes plugin namespace" 1 "index file not created"
		return 0
	fi

	if grep -q '^<!--TOON:plugin_agents\[1\]{folder,purpose,key_files}:$' "$index_file" &&
		grep -q '^example-plugin/,Example plugin agents,example-agent$' "$index_file"; then
		print_result "generate includes plugin namespace" 0
	else
		print_result "generate includes plugin namespace" 1 "plugin entry missing from index"
	fi
	return 0
}

test_check_validates_plugin_cardinality() {
	local output=""
	local status=0
	output=$(HOME="$TEST_HOME" AIDEVOPS_AGENTS_DIR="$TEST_HOME/.aidevops/agents" "$TEST_HOME/.aidevops/agents/scripts/subagent-index-helper.sh" check 2>&1)
	status=$?
	if [[ "$status" -eq 0 && "$output" == *"Declared plugin rows: 1"* && "$output" == *"Actual plugin rows: 1"* ]]; then
		print_result "check validates plugin cardinality" 0
	else
		print_result "check validates plugin cardinality" 1 "$output"
	fi
	return 0
}

test_shared_routes_preserved_without_design_catalogue() {
	local index_file="$TEST_HOME/.aidevops/agents/subagent-index.toon"
	local first_index="$TEST_HOME/first-subagent-index.toon"
	local output=""
	local status=0

	output=$(HOME="$TEST_HOME" AIDEVOPS_AGENTS_DIR="$TEST_HOME/.aidevops/agents" "$TEST_HOME/.aidevops/agents/scripts/subagent-index-helper.sh" generate 2>&1)
	status=$?
	if [[ "$status" -ne 0 ]]; then
		print_result "shared routes exclude design catalogue" 1 "$output"
		return 0
	fi

	cp "$index_file" "$first_index"
	output=$(HOME="$TEST_HOME" AIDEVOPS_AGENTS_DIR="$TEST_HOME/.aidevops/agents" "$TEST_HOME/.aidevops/agents/scripts/subagent-index-helper.sh" generate 2>&1)
	status=$?

	if [[ "$status" -eq 0 ]] &&
		grep -q '^business/,business subagents,accounting$' "$index_file" &&
		grep -q '^public-relations/,public-relations subagents,media-list-builder$' "$index_file" &&
		! grep -q 'tools/design/library' "$index_file" &&
		cmp -s "$first_index" "$index_file"; then
		print_result "shared routes exclude design catalogue" 0
	else
		print_result "shared routes exclude design catalogue" 1 "expected deterministic public-relations route without design catalogue"
	fi
	return 0
}

test_unset_globals_do_not_read_stdin() {
	local helper="$TEST_HOME/.aidevops/agents/scripts/subagent-index-helper.sh"
	local output=""
	local status=0

	output=$(bash -c '
		helper_path="$2"
		set -- help
		source "$helper_path" >/dev/null
		unset AGENTS_DIR SUBAGENT_DIRS INDEX_FILE
		count_subagent_markdown_files
		count_index_leaf_entries
		check_toon_cardinality "plugin_agents" "plugin" "s/^x$/x/p" "regenerate"
	' bash help "$helper" 2>&1)
	status=$?

	if [[ "$status" -eq 0 && "$output" == $'0\n0' ]]; then
		print_result "unset globals do not read stdin" 0
	else
		print_result "unset globals do not read stdin" 1 "$output"
	fi
	return 0
}

main() {
	setup
	test_plugin_namespace_indexed
	test_check_validates_plugin_cardinality
	test_shared_routes_preserved_without_design_catalogue
	test_unset_globals_do_not_read_stdin

	echo ""
	echo "Tests run: $TESTS_RUN"
	echo "Passed: $TESTS_PASSED"
	echo "Failed: $TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
