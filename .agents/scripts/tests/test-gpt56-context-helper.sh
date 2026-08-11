#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../gpt56-context-helper.sh"
TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME"
MOCK_BIN="${TEST_HOME}/bin"
PLUGIN_ENTRY="${TEST_HOME}/agents/plugins/opencode-aidevops/index.mjs"
mkdir -p "$MOCK_BIN" "${PLUGIN_ENTRY%/*}"
printf '%s\n' '// mock plugin entry' >"$PLUGIN_ENTRY"

cat >"${MOCK_BIN}/opencode" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "debug" && "${2:-}" == "config" ]]; then
	printf '{"plugin":["file://%s"]}\n' "${AIDEVOPS_PLUGIN_ENTRY:?}"
	exit 0
fi
if [[ "${1:-}" != "models" || "${2:-}" != "openai" || "${3:-}" != "--verbose" ]]; then
	printf '%s\n' "unexpected packaged OpenCode invocation: $*" >&2
	exit 2
fi
if [[ "${MOCK_PLUGIN_ACTIVE:-1}" != "1" ]]; then
	printf '%s\n' 'mock packaged OpenCode plugin import failed at $HOME/plugin.mjs' >&2
	exit 1
fi
jq -cn --arg nonce "${AIDEVOPS_PLUGIN_HEALTH_PROBE_NONCE:?}" \
	'{schema:"aidevops.opencode-plugin-health/v1",nonce:$nonce,
	stages:["imported","factory_initialized","config_applied"],details:{
	factory_initialized:{config_hook:true,terminal_title_status:true},
	config_applied:{terminal_title_status:true,gpt56_limits:{context:300000,input:260000,output:128000}}}}' \
	>"${AIDEVOPS_PLUGIN_HEALTH_PROBE_FILE:?}"
printf '%s\n' 'openai/gpt-5.6-sol limit: context=300000 input=260000 output=128000'
MOCK
chmod +x "${MOCK_BIN}/opencode"
export PATH="${MOCK_BIN}:${PATH}"
export AIDEVOPS_PLUGIN_ENTRY="$PLUGIN_ENTRY"

assert_contains() {
	local haystack="$1"
	local needle="$2"
	if [[ "$haystack" != *"$needle"* ]]; then
		printf 'Expected output to contain: %s\nActual: %s\n' "$needle" "$haystack" >&2
		return 1
	fi
	return 0
}

output=$(bash "$HELPER" status)
assert_contains "$output" "requested: enabled"
assert_contains "$output" "configured/discovered: true"
assert_contains "$output" "effective state: active"
assert_contains "$output" "context=300000, input=260000, output=128000"
assert_contains "$output" "Terminal-title status hook: registered"

output=$(MOCK_PLUGIN_ACTIVE=0 bash "$HELPER" status)
assert_contains "$output" "inactive or initialization failed"
assert_contains "$output" "mock packaged OpenCode plugin import failed at \$HOME/plugin.mjs"
assert_contains "$output" "requested state not confirmed"

output=$(OPENCODE_BIN="${TEST_HOME}/missing-opencode" bash "$HELPER" status)
assert_contains "$output" "unavailable (OpenCode is not installed)"

bash "$HELPER" disable >/dev/null
[[ "$(jq -r '.runtime.opencode.gpt56_context_cap' "$HOME/.config/aidevops/settings.json")" == "false" ]]
output=$(bash "$HELPER" status)
assert_contains "$output" "requested: disabled"

bash "$HELPER" enable >/dev/null
[[ "$(jq -r '.runtime.opencode.gpt56_context_cap' "$HOME/.config/aidevops/settings.json")" == "true" ]]

printf '%s\n' "PASS: gpt56 context helper"
