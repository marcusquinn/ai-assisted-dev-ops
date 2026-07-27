#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression coverage for GH#24107: `aidevops update` must not route a
# Homebrew-managed OpenCode binary through npm and collide with Homebrew's
# managed symlink.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TOOL_VERSION_CHECK="$REPO_ROOT/.agents/scripts/tool-version-check.sh"
SHARED_CONSTANTS="$REPO_ROOT/.agents/scripts/shared-constants.sh"
HEADLESS_RUNTIME_LIB="$REPO_ROOT/.agents/scripts/headless-runtime-lib.sh"

if [[ ! -f "$TOOL_VERSION_CHECK" || ! -f "$SHARED_CONSTANTS" || ! -f "$HEADLESS_RUNTIME_LIB" ]]; then
	printf 'FAIL: cannot find OpenCode version policy sources\n' >&2
	exit 1
fi

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/t24107-XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SYSTEM_PATH="$PATH"

PASS=0
FAIL=0

assert_eq() {
	local desc="$1"
	local expected="$2"
	local actual="$3"

	if [[ "$expected" == "$actual" ]]; then
		printf '  PASS: %s\n' "$desc"
		PASS=$((PASS + 1))
		return 0
	fi

	printf '  FAIL: %s -- expected %s, got %s\n' "$desc" "$expected" "$actual" >&2
	FAIL=$((FAIL + 1))
	return 0
}

extract_function() {
	awk '
		/^_opencode_upgrade_cmd\(\)/, /^}$/ { print; next }
	' "$TOOL_VERSION_CHECK" >"$SANDBOX/extract.sh"
	awk '
		/^_enforce_opencode_version_pin\(\)/, /^}$/ { print; next }
	' "$HEADLESS_RUNTIME_LIB" >>"$SANDBOX/extract.sh"
	if ! grep -q '^_opencode_upgrade_cmd()' "$SANDBOX/extract.sh" ||
		! grep -q '^_enforce_opencode_version_pin()' "$SANDBOX/extract.sh"; then
		printf 'FAIL: extraction did not capture OpenCode version functions\n' >&2
		exit 1
	fi
	return 0
}

source_extracted() {
	# shellcheck source=/dev/null
	source "$SANDBOX/extract.sh"
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

extract_function

printf 'Test 0: OpenCode remains pinned to the last verified headless release\n'
# shellcheck source=../shared-constants.sh
source "$SHARED_CONSTANTS"
assert_eq "OpenCode headless regression pin" "1.18.5" "$OPENCODE_PINNED_VERSION"

printf 'Test 1: Homebrew OpenCode chooses brew instead of npm\n'
mkdir -p "$SANDBOX/opt/homebrew/bin" "$SANDBOX/opt/homebrew/Cellar/opencode/1.15.10/bin" "$SANDBOX/opt/homebrew/opt" "$SANDBOX/homebrew-case"
write_executable "$SANDBOX/opt/homebrew/Cellar/opencode/1.15.10/bin/opencode" '#!/usr/bin/env bash
printf "1.15.10\n"'
ln -s "../Cellar/opencode/1.15.10" "$SANDBOX/opt/homebrew/opt/opencode"
ln -s "../Cellar/opencode/1.15.10/bin/opencode" "$SANDBOX/opt/homebrew/bin/opencode"
# shellcheck disable=SC2016 # Literal stub body; quoted SANDBOX segments are expanded by the outer script.
write_executable "$SANDBOX/opt/homebrew/bin/brew" '#!/usr/bin/env bash
case "${1:-}" in
--prefix)
	if [[ "${2:-}" == "opencode" ]]; then
		printf "%s\n" "'"$SANDBOX"'/opt/homebrew/opt/opencode"
	else
		printf "%s\n" "'"$SANDBOX"'/opt/homebrew"
	fi
	;;
list)
	[[ "${2:-}" == "--versions" && "${3:-}" == "opencode" ]] || exit 1
	printf "opencode 1.15.10\n"
	;;
upgrade | reinstall)
	printf "%s %s\n" "$1" "${2:-}" >>"'"$SANDBOX"'/homebrew-case/calls"
	;;
*) exit 1 ;;
esac'
# shellcheck disable=SC2016 # Literal stub body; quoted SANDBOX segments are expanded by the outer script.
write_executable "$SANDBOX/homebrew-case/npm" '#!/usr/bin/env bash
printf "npm %s\n" "$*" >>"'"$SANDBOX"'/homebrew-case/calls"'
(
	source_extracted
	cmd="$(_opencode_upgrade_cmd 1.15.10)"
	PATH="$SANDBOX/opt/homebrew/bin:$SANDBOX/homebrew-case:$SYSTEM_PATH" bash -c "$cmd"
)
assert_eq "Homebrew OpenCode upgrade command" "upgrade opencode" "$(tr '\n' ';' <"$SANDBOX/homebrew-case/calls" | sed 's/;$//')"

printf 'Test 1b: npm OpenCode inside brew prefix still chooses npm\n'
mkdir -p "$SANDBOX/opt/homebrew/npm-global/bin" "$SANDBOX/brew-prefix-npm-case"
write_executable "$SANDBOX/opt/homebrew/npm-global/bin/opencode" '#!/usr/bin/env bash
printf "1.15.10\n"'
# shellcheck disable=SC2016 # Literal stub body; quoted SANDBOX segments are expanded by the outer script.
write_executable "$SANDBOX/brew-prefix-npm-case/npm" '#!/usr/bin/env bash
printf "npm %s\n" "$*" >>"'"$SANDBOX"'/brew-prefix-npm-case/calls"'
(
	source_extracted
	cmd="$(_opencode_upgrade_cmd 1.15.10)"
	PATH="$SANDBOX/opt/homebrew/npm-global/bin:$SANDBOX/opt/homebrew/bin:$SANDBOX/brew-prefix-npm-case:$SYSTEM_PATH" bash -c "$cmd"
)
assert_eq "npm OpenCode under brew prefix command" "npm install -g opencode-ai@1.15.10" "$(tr '\n' ';' <"$SANDBOX/brew-prefix-npm-case/calls" | sed 's/;$//')"

printf 'Test 2: bun OpenCode still chooses bun\n'
mkdir -p "$SANDBOX/home/.bun/bin" "$SANDBOX/bun-case"
write_executable "$SANDBOX/home/.bun/bin/opencode" '#!/usr/bin/env bash
printf "1.15.10\n"'
# shellcheck disable=SC2016 # Literal stub body; quoted SANDBOX segments are expanded by the outer script.
write_executable "$SANDBOX/bun-case/bun" '#!/usr/bin/env bash
printf "bun %s\n" "$*" >>"'"$SANDBOX"'/bun-case/calls"'
# shellcheck disable=SC2016 # Literal stub body; quoted SANDBOX segments are expanded by the outer script.
write_executable "$SANDBOX/bun-case/npm" '#!/usr/bin/env bash
printf "npm %s\n" "$*" >>"'"$SANDBOX"'/bun-case/calls"'
(
	source_extracted
	cmd="$(_opencode_upgrade_cmd 1.15.10)"
	PATH="$SANDBOX/home/.bun/bin:$SANDBOX/bun-case:$SYSTEM_PATH" bash -c "$cmd"
)
assert_eq "bun OpenCode upgrade command" "bun install -g opencode-ai@1.15.10" "$(tr '\n' ';' <"$SANDBOX/bun-case/calls" | sed 's/;$//')"

printf 'Test 3: non-Homebrew/non-bun OpenCode falls back to npm\n'
mkdir -p "$SANDBOX/npm-bin" "$SANDBOX/npm-case"
write_executable "$SANDBOX/npm-bin/opencode" '#!/usr/bin/env bash
printf "1.15.10\n"'
# shellcheck disable=SC2016 # Literal stub body; quoted SANDBOX segments are expanded by the outer script.
write_executable "$SANDBOX/npm-case/npm" '#!/usr/bin/env bash
printf "npm %s\n" "$*" >>"'"$SANDBOX"'/npm-case/calls"'
(
	source_extracted
	cmd="$(_opencode_upgrade_cmd 1.15.10)"
	PATH="$SANDBOX/npm-bin:$SANDBOX/npm-case:$SYSTEM_PATH" bash -c "$cmd"
)
assert_eq "npm OpenCode upgrade command" "npm install -g opencode-ai@1.15.10" "$(tr '\n' ';' <"$SANDBOX/npm-case/calls" | sed 's/;$//')"

printf 'Test 4: headless version guard restores the pinned release\n'
mkdir -p "$SANDBOX/version-guard"
write_executable "$SANDBOX/version-guard/opencode" '#!/usr/bin/env bash
printf "1.18.7\n"'
# shellcheck disable=SC2016 # Literal stub body; quoted SANDBOX segments are expanded by the outer script.
write_executable "$SANDBOX/version-guard/npm" '#!/usr/bin/env bash
printf "%s\n" "$*" >>"'"$SANDBOX"'/version-guard/calls"'
(
	source_extracted
	OPENCODE_BIN_DEFAULT="$SANDBOX/version-guard/opencode"
	print_warning() { return 0; }
	print_info() { return 0; }
	PATH="$SANDBOX/version-guard:$SYSTEM_PATH" _enforce_opencode_version_pin
)
assert_eq "headless pin reinstall command" "install -g opencode-ai@1.18.5" "$(tr '\n' ';' <"$SANDBOX/version-guard/calls" | sed 's/;$//')"

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi

exit 0
