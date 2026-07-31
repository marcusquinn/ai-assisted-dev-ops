#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TEST_ROOT="$(mktemp -d -t aidevops-runtime-command-reconciliation.XXXXXX)"
TEST_HOME="$TEST_ROOT/home"

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

mkdir -p \
	"$TEST_HOME/.aidevops/agents/commands" \
	"$TEST_HOME/.aidevops/agents/scripts/commands" \
	"$TEST_HOME/.config/opencode/command"
ln -s "$REPO_ROOT/.agents/scripts/lib" "$TEST_HOME/.aidevops/agents/scripts/lib"
printf '%s\n' '# build command' >"$TEST_HOME/.aidevops/agents/commands/aidevops-build-plus.md"
printf '%s\n' '# session command' >"$TEST_HOME/.aidevops/agents/scripts/commands/session-analysis.md"

HOME="$TEST_HOME"
# shellcheck source=../generate-runtime-config.sh
source "$REPO_ROOT/.agents/scripts/generate-runtime-config.sh"

printf '%s\n' '{"autoupdate":false,"agent":{}}' >"$TEST_HOME/.config/opencode/opencode.json"
if ! _opencode_managed_config_matches_source || ! _opencode_agent_output_matches_source; then
	printf '%s\n' 'FAIL: managed autoupdate=false failed parity verification' >&2
	exit 1
fi

printf '%s\n' '{"agent":{}}' >"$TEST_HOME/.config/opencode/opencode.json"
if _opencode_managed_config_matches_source; then
	printf '%s\n' 'FAIL: missing managed autoupdate setting passed parity verification' >&2
	exit 1
fi

printf '%s\n' '{"autoupdate":true,"agent":{},"custom":"preserve"}' >"$TEST_HOME/.config/opencode/opencode.json"
if _opencode_managed_config_matches_source; then
	printf '%s\n' 'FAIL: enabled OpenCode autoupdate passed parity verification' >&2
	exit 1
fi

_generate_for_runtime opencode agents >/dev/null
if ! jq -e '.autoupdate == false and .custom == "preserve"' "$TEST_HOME/.config/opencode/opencode.json" >/dev/null; then
	printf '%s\n' 'FAIL: unified OpenCode config generation did not disable autoupdate while preserving unrelated keys' >&2
	exit 1
fi
_generate_for_runtime opencode agents >/dev/null
if ! jq -e '.autoupdate == false and .custom == "preserve"' "$TEST_HOME/.config/opencode/opencode.json" >/dev/null; then
	printf '%s\n' 'FAIL: repeated unified OpenCode config generation did not preserve managed autoupdate state' >&2
	exit 1
fi

if _opencode_command_output_matches_source; then
	printf '%s\n' 'FAIL: missing generated commands passed parity verification' >&2
	exit 1
fi

_generate_commands_for_runtime opencode >/dev/null
if ! _opencode_command_output_matches_source; then
	printf '%s\n' 'FAIL: complete generated command set failed parity verification' >&2
	exit 1
fi

printf '%s\n' '# stale generated session command' >"$TEST_HOME/.config/opencode/command/aidevops-session-analysis.md"
if _opencode_command_output_matches_source; then
	printf '%s\n' 'FAIL: stale generated command content passed parity verification' >&2
	exit 1
fi

rm -f "$TEST_HOME/.config/opencode/command/aidevops-session-analysis.md"
if _opencode_command_output_matches_source; then
	printf '%s\n' 'FAIL: deleted generated command was not detected' >&2
	exit 1
fi

_generate_for_runtime opencode commands >/dev/null
if ! _opencode_command_output_matches_source; then
	printf '%s\n' 'FAIL: normal runtime generation did not repair deleted command output' >&2
	exit 1
fi

FAIL_GENERATOR="$TEST_ROOT/fail-generator.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 9' >"$FAIL_GENERATOR"
if bash -c '
	source "$1"
	print_info() { return 0; }
	print_success() { return 0; }
	print_warning() { return 0; }
	_run_generator "$2" "start" "success" "failure"
' _ "$REPO_ROOT/.agents/scripts/setup/modules/config.sh" "$FAIL_GENERATOR" 2>/dev/null; then
	printf '%s\n' 'FAIL: setup generator wrapper normalized runtime reconciliation failure' >&2
	exit 1
fi

printf '%s\n' 'PASS: runtime reconciliation detects drift, repairs output, and propagates failures'
exit 0
