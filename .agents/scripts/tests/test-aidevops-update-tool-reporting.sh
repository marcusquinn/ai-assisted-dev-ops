#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#29712: the default aidevops update path reports
# key-tool drift without prompting or mutating unrelated global tools.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
UPDATE_LIB="$REPO_ROOT/.agents/scripts/aidevops-cli/aidevops-update-lib.sh"
TEST_TMP_PARENT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEST_TMP_PARENT"
SANDBOX="$(mktemp -d "${TEST_TMP_PARENT}/gh29712-XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT

SYSTEM_PATH="$PATH"
PASS_COUNT=0
FAIL_COUNT=0
REPORT_OUTPUT=""
REPORT_RC=0
MUTATION_LOG="$SANDBOX/state/mutation-calls"

pass() {
	local name="$1"
	printf 'PASS: %s\n' "$name"
	PASS_COUNT=$((PASS_COUNT + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	printf 'FAIL: %s — %s\n' "$name" "$detail" >&2
	FAIL_COUNT=$((FAIL_COUNT + 1))
	return 0
}

assert_eq() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$actual" == "$expected" ]]; then
		pass "$name"
	else
		fail "$name" "expected ${expected}, got ${actual}"
	fi
	return 0
}

assert_contains() {
	local name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "missing ${needle}"
	fi
	return 0
}

assert_not_contains() {
	local name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		fail "$name" "unexpected ${needle}"
	else
		pass "$name"
	fi
	return 0
}

assert_no_mutation() {
	local name="$1"
	local calls=""
	if [[ -s "$MUTATION_LOG" ]]; then
		calls=$(<"$MUTATION_LOG")
		fail "$name" "tool checker was invoked: ${calls}"
	else
		pass "$name"
	fi
	return 0
}

extract_function() {
	local output_file="$1"
	awk '
		/^_update_check_tools\(\)[[:space:]]*\{/ { capturing = 1 }
		capturing {
			print
			line = $0
			open_count = gsub(/\{/, "", line)
			line = $0
			close_count = gsub(/\}/, "", line)
			depth += open_count - close_count
			if (depth == 0) exit
		}
	' "$UPDATE_LIB" >"$output_file"
	if [[ ! -s "$output_file" ]]; then
		printf 'FAIL: could not extract _update_check_tools\n' >&2
		exit 1
	fi
	return 0
}

write_executable() {
	local path="$1"
	local body="$2"
	mkdir -p "$(dirname "$path")"
	printf '%s\n' "$body" >"$path"
	chmod +x "$path"
	return 0
}

set_versions() {
	local opencode_installed="$1"
	local opencode_registry="$2"
	local gh_installed="$3"
	local gh_registry="$4"
	printf '%s\n' "$opencode_installed" >"$SANDBOX/state/opencode-installed"
	printf '%s\n' "$opencode_registry" >"$SANDBOX/state/opencode-registry"
	printf '%s\n' "$gh_installed" >"$SANDBOX/state/gh-installed"
	printf '%s\n' "$gh_registry" >"$SANDBOX/state/gh-registry"
	rm -f "$MUTATION_LOG"
	return 0
}

run_report() {
	local input="${1:-y}"
	REPORT_RC=0
	REPORT_OUTPUT=$(_update_check_tools <<<"$input" 2>&1) || REPORT_RC=$?
	return 0
}

print_header() {
	local message="$1"
	printf 'HEADER %s\n' "$message"
	return 0
}

print_info() {
	local message="$1"
	printf 'INFO %s\n' "$message"
	return 0
}

print_warning() {
	local message="$1"
	printf 'WARN %s\n' "$message"
	return 0
}

print_success() {
	local message="$1"
	printf 'OK %s\n' "$message"
	return 0
}

_timeout_cmd() {
	local timeout_seconds="$1"
	shift
	if [[ "$timeout_seconds" -lt 1 ]]; then
		return 1
	fi
	if "$@"; then
		return 0
	fi
	return 1
}

aidevops_gh_slurp_supported() {
	return 0
}

get_public_release_tag() {
	local repository="$1"
	if [[ -n "$repository" ]]; then
		return 1
	fi
	return 1
}

mkdir -p "$SANDBOX/state" "$SANDBOX/bin" "$SANDBOX/framework/scripts"
export TOOL_REPORT_STATE_DIR="$SANDBOX/state"

# shellcheck disable=SC2016 # Stub variables expand only when the generated script runs.
write_executable "$SANDBOX/bin/opencode" '#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] || exit 1
version=$(<"${TOOL_REPORT_STATE_DIR}/opencode-installed")
printf "%s\n" "$version"'

# shellcheck disable=SC2016 # Stub variables expand only when the generated script runs.
write_executable "$SANDBOX/bin/gh" '#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] || exit 1
version=$(<"${TOOL_REPORT_STATE_DIR}/gh-installed")
printf "gh version %s\n" "$version"'

# shellcheck disable=SC2016 # Stub variables expand only when the generated script runs.
write_executable "$SANDBOX/bin/npm" '#!/usr/bin/env bash
[[ "${1:-}" == "view" && "${2:-}" == "opencode-ai" ]] || exit 1
latest=$(<"${TOOL_REPORT_STATE_DIR}/opencode-registry")
[[ "$latest" != "failure" ]] || exit 1
printf "%s\n" "$latest"'

# shellcheck disable=SC2016 # Stub variables expand only when the generated script runs.
write_executable "$SANDBOX/bin/brew" '#!/usr/bin/env bash
[[ "${1:-}" == "info" && "${3:-}" == "gh" ]] || exit 1
latest=$(<"${TOOL_REPORT_STATE_DIR}/gh-registry")
[[ "$latest" != "failure" ]] || exit 1
printf "{\"formulae\":[{\"versions\":{\"stable\":\"%s\"}}]}\n" "$latest"'

# shellcheck disable=SC2016 # Stub variables expand only when the generated script runs.
write_executable "$SANDBOX/framework/scripts/tool-version-check.sh" '#!/usr/bin/env bash
printf "%s\n" "$*" >>"${TOOL_REPORT_STATE_DIR}/mutation-calls"'

EXTRACTED_FUNCTION="$SANDBOX/update-check-tools.sh"
extract_function "$EXTRACTED_FUNCTION"
# shellcheck source=/dev/null
source "$EXTRACTED_FUNCTION"
FUNCTION_SOURCE=$(<"$EXTRACTED_FUNCTION")

PATH="$SANDBOX/bin:$SYSTEM_PATH"
export PATH
AGENTS_DIR="$SANDBOX/framework"
OPENCODE_PINNED_VERSION="1.18.9"
OPENCODE_PIN_PLATFORM="Linux"
OPENCODE_PIN_RUNTIME_MODE="headless"
OPENCODE_PIN_INTRODUCED_DATE="2026-07-30"
OPENCODE_PIN_LAST_CANARY_DATE="2026-07-30"
OPENCODE_PIN_LAST_CANARY_RESULT="pass:1.18.9"
OPENCODE_PIN_REVIEW_DEADLINE="2026-08-06"
OPENCODE_PLUGIN_TESTED_VERSION="1.18.9"

assert_not_contains "source removes the interactive update prompt" \
	'read -r -p "Run full tool update check?' "$FUNCTION_SOURCE"
assert_not_contains "source removes the mutating tool-check call" \
	"bash \"\$tool_check_script\" --update" "$FUNCTION_SOURCE"

set_versions "1.18.9" "9.99.9" "2.99.0" "2.99.0"
run_report "y"
assert_eq "matching compatibility pin returns success" "0" "$REPORT_RC"
assert_contains "registry release remains actionable globally" "opencode (1.18.9 -> 9.99.9)" "$REPORT_OUTPUT"
assert_contains "scoped compatibility pin remains visible" "OpenCode compatibility pin: installed=1.18.9, pinned=1.18.9, registry=9.99.9" "$REPORT_OUTPUT"
assert_contains "pin canary evidence remains visible" "last-canary=2026-07-30 (pass:1.18.9)" "$REPORT_OUTPUT"
assert_contains "plugin tested version remains visible" "plugin-tested=1.18.9" "$REPORT_OUTPUT"
assert_no_mutation "matching compatibility pin does not mutate"

set_versions "1.18.8" "9.99.9" "2.99.0" "2.99.0"
run_report "y"
assert_eq "older compatibility drift returns success" "0" "$REPORT_RC"
assert_contains "older global install reports registry latest" "opencode (1.18.8 -> 9.99.9)" "$REPORT_OUTPUT"
assert_contains "stale report names explicit update command" "aidevops update-tools --update" "$REPORT_OUTPUT"
assert_contains "stale report confirms no mutation" "No global tools were changed" "$REPORT_OUTPUT"
assert_not_contains "stale report has no full-update prompt" "Run full tool update check?" "$REPORT_OUTPUT"
assert_no_mutation "affirmative stdin cannot trigger mutation"

set_versions "1.19.0" "9.99.9" "2.99.0" "2.99.0"
run_report "y"
assert_contains "newer global install reports registry latest" "opencode (1.19.0 -> 9.99.9)" "$REPORT_OUTPUT"
assert_no_mutation "newer compatibility drift does not mutate"

set_versions "1.18.9" "9.99.9" "2.98.0" "2.99.0"
run_report "y"
assert_contains "GitHub CLI drift remains visible" "gh (2.98.0 -> 2.99.0)" "$REPORT_OUTPUT"
assert_no_mutation "GitHub CLI drift does not mutate"

set_versions "1.18.9" "failure" "2.99.0" "failure"
run_report "y"
assert_eq "registry lookup failures remain non-fatal" "0" "$REPORT_RC"
assert_no_mutation "registry lookup failures do not mutate"

printf '%s passed, %s failed\n' "$PASS_COUNT" "$FAIL_COUNT"
if [[ "$FAIL_COUNT" -ne 0 ]]; then
	exit 1
fi
exit 0
