#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Ubuntu lifecycle smoke for the real setup and CLI entry points (GH#29414).
# Runs the supported agents-only setup scope under an isolated HOME, then uses
# the repository CLI to verify the activated runtime bundle can be resolved.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
SETUP_SCRIPT="${REPO_ROOT}/setup.sh"
CLI_SCRIPT="${REPO_ROOT}/aidevops.sh"

if [[ "$(uname -s)" != "Linux" ]]; then
	printf 'SKIP Linux lifecycle smoke requires Linux\n'
	exit 0
fi

SANDBOX_ROOT="$(mktemp -d)"
SANDBOX_HOME="${SANDBOX_ROOT}/home"
SANDBOX_BIN="${SANDBOX_ROOT}/bin"
SETUP_LOG="${SANDBOX_ROOT}/setup.log"
STATUS_LOG="${SANDBOX_ROOT}/status.log"

cleanup() {
	rm -rf "$SANDBOX_ROOT"
	return 0
}
trap cleanup EXIT

print_log() {
	local log_file="$1"
	while IFS= read -r line || [[ -n "$line" ]]; do
		printf '  %s\n' "$line" >&2
	done <"$log_file"
	return 0
}

run_step() {
	local label="$1"
	local output_file="$2"
	local rc=0
	shift 2

	printf 'RUN %s\n' "$label"
	if "$@" >"$output_file" 2>&1; then
		printf 'PASS %s\n' "$label"
		return 0
	else
		rc=$?
	fi

	printf 'FAIL %s (exit %d)\n' "$label" "$rc" >&2
	printf '  repository: %s\n' "$REPO_ROOT" >&2
	printf '  sandbox HOME: %s\n' "$SANDBOX_HOME" >&2
	printf '  command:' >&2
	printf ' %q' "$@" >&2
	printf '\n  output (%s):\n' "$output_file" >&2
	print_log "$output_file"
	return "$rc"
}

assert_log_contains() {
	local label="$1"
	local log_file="$2"
	local expected="$3"
	if grep -Fq "$expected" "$log_file"; then
		printf 'PASS %s\n' "$label"
		return 0
	fi
	printf 'FAIL %s: missing %q in %s\n' "$label" "$expected" "$log_file" >&2
	print_log "$log_file"
	return 1
}

mkdir -p \
	"${SANDBOX_HOME}/.config" \
	"${SANDBOX_HOME}/.cache" \
	"${SANDBOX_HOME}/.local/share" \
	"$SANDBOX_BIN"

# `aidevops status` normally checks the latest version over HTTPS. The smoke is
# intentionally network-free, so this curl shim makes that optional lookup
# report "unknown" while leaving the real setup and CLI code paths intact.
printf '%s\n' '#!/usr/bin/env bash' 'exit 22' >"${SANDBOX_BIN}/curl"
chmod 700 "${SANDBOX_BIN}/curl"

TEST_PATH="${SANDBOX_BIN}:/usr/local/bin:/usr/bin:/bin"

run_step "setup.sh agents scope in isolated HOME" "$SETUP_LOG" \
	env -u SUDO_USER \
	HOME="$SANDBOX_HOME" \
	XDG_CONFIG_HOME="${SANDBOX_HOME}/.config" \
	XDG_CACHE_HOME="${SANDBOX_HOME}/.cache" \
	XDG_DATA_HOME="${SANDBOX_HOME}/.local/share" \
	PATH="$TEST_PATH" \
	AIDEVOPS_SETUP_LOCK_DIR="${SANDBOX_HOME}/.aidevops/locks/linux-lifecycle-smoke.lock.d" \
	AIDEVOPS_RELEASE_LANE_ISOLATED_CI=1 \
	AIDEVOPS_SKIP_PULSE_RESTART=1 \
	bash "$SETUP_SCRIPT" --non-interactive --stage agents

assert_log_contains "setup reaches completion sentinel" "$SETUP_LOG" "[SETUP_COMPLETE]"

if [[ ! -L "${SANDBOX_HOME}/.aidevops/agents" || ! -f "${SANDBOX_HOME}/.aidevops/agents/VERSION" ]]; then
	printf 'FAIL setup did not activate a runtime bundle under %s\n' "${SANDBOX_HOME}/.aidevops/agents" >&2
	print_log "$SETUP_LOG"
	exit 1
fi

EXPECTED_VERSION="$(tr -d '[:space:]' <"${REPO_ROOT}/VERSION")"
run_step "repo-local aidevops.sh status against deployed agents" "$STATUS_LOG" \
	env -u SUDO_USER \
	HOME="$SANDBOX_HOME" \
	XDG_CONFIG_HOME="${SANDBOX_HOME}/.config" \
	XDG_CACHE_HOME="${SANDBOX_HOME}/.cache" \
	XDG_DATA_HOME="${SANDBOX_HOME}/.local/share" \
	PATH="$TEST_PATH" \
	AIDEVOPS_AGENTS_DIR="${SANDBOX_HOME}/.aidevops/agents" \
	bash "$CLI_SCRIPT" status

assert_log_contains "CLI resolves deployed version" "$STATUS_LOG" "Installed: ${EXPECTED_VERSION}"
assert_log_contains "CLI resolves isolated agents path" "$STATUS_LOG" "Agents: ${SANDBOX_HOME}/.aidevops/agents"
assert_log_contains "CLI verifies activated runtime bundle" "$STATUS_LOG" "Active runtime bundle metadata is coherent"

printf 'PASS Linux lifecycle smoke completed without host HOME or network access\n'
