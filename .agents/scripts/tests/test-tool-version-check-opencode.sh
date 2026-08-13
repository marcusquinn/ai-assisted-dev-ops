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

TEST_TMP_PARENT="${AIDEVOPS_TEMP_DIR:-${HOME}/.aidevops/.agent-workspace/tmp}"
mkdir -p "$TEST_TMP_PARENT"
SANDBOX="$(mktemp -d "${TEST_TMP_PARENT}/t24107-XXXXXX")"
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
		/^aidevops_opencode_pin_applies\(\)/, /^}/ { print; next }
	' "$SHARED_CONSTANTS" >"$SANDBOX/extract.sh"
	awk '
		/^_opencode_upgrade_cmd\(\)/, /^}$/ { print; next }
	' "$TOOL_VERSION_CHECK" >>"$SANDBOX/extract.sh"
	awk '
		/^_validate_opencode_binary\(\)/, /^}/ { print; next }
		/^_resolve_headless_opencode_install_binary\(\)/, /^}/ { print; next }
		/^_provision_headless_opencode_runtime\(\)/, /^}/ { print; next }
		/^_enforce_opencode_version_pin\(\)/, /^}$/ { print; next }
	' "$HEADLESS_RUNTIME_LIB" >>"$SANDBOX/extract.sh"
	if ! grep -q '^aidevops_opencode_pin_applies()' "$SANDBOX/extract.sh" ||
		! grep -q '^_opencode_upgrade_cmd()' "$SANDBOX/extract.sh" ||
		! grep -q '^_validate_opencode_binary()' "$SANDBOX/extract.sh" ||
		! grep -q '^_resolve_headless_opencode_install_binary()' "$SANDBOX/extract.sh" ||
		! grep -q '^_provision_headless_opencode_runtime()' "$SANDBOX/extract.sh" ||
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
assert_eq "OpenCode headless regression pin" "1.18.16" "$OPENCODE_PINNED_VERSION"

printf 'Test 0a: routine freshness tracks registry outside Linux headless dispatch\n'
mkdir -p "$SANDBOX/routine-freshness/bin"
printf '1.18.9\n' >"$SANDBOX/routine-freshness/opencode-version"
# shellcheck disable=SC2016 # Literal stub body; quoted SANDBOX segments are expanded by the outer script.
write_executable "$SANDBOX/routine-freshness/bin/opencode" '#!/usr/bin/env bash
version=$(<"'"$SANDBOX"'/routine-freshness/opencode-version")
printf "%s\n" "$version"'
for cli in claude codex repomix dspyground mcp-local-wp beads-ui bdui chrome-devtools-mcp playwriter macos-automator-mcp claude-code-mcp gws; do
	write_executable "$SANDBOX/routine-freshness/bin/$cli" '#!/usr/bin/env bash
printf "9.99.9\n"'
done
# shellcheck disable=SC2016 # Literal stub body; quoted SANDBOX segments are expanded by the outer script.
write_executable "$SANDBOX/routine-freshness/bin/npm" '#!/usr/bin/env bash
case "${1:-}" in
view) printf "9.99.9\n" ;;
install) printf "%s\n" "$*" >>"'"$SANDBOX"'/routine-freshness/calls" ;;
*) exit 1 ;;
esac'
routine_output=$(PATH="$SANDBOX/routine-freshness/bin:$SYSTEM_PATH" "$TOOL_VERSION_CHECK" --category npm --update --quiet)
assert_eq "general tool update installs registry latest" "install -g opencode-ai@latest" "$(tr '\n' ';' <"$SANDBOX/routine-freshness/calls" | sed 's/;$//')"

routine_json=$(PATH="$SANDBOX/routine-freshness/bin:$SYSTEM_PATH" "$TOOL_VERSION_CHECK" --category npm --json)
opencode_json=$(printf '%s\n' "$routine_json" | grep '"name": "OpenCode"')
assert_eq "registry release is actionable outside pin scope" "1" "$([[ "$opencode_json" == *'"latest": "9.99.9", "status": "outdated"'* ]] && printf '1\n' || printf '0\n')"

printf 'Test 0b: routine freshness repairs genuine drift from the OpenCode pin\n'
printf '1.18.8\n' >"$SANDBOX/routine-freshness/opencode-version"
PATH="$SANDBOX/routine-freshness/bin:$SYSTEM_PATH" "$TOOL_VERSION_CHECK" --category npm --update --quiet >/dev/null
assert_eq "general drift repair installs registry latest" "install -g opencode-ai@latest;install -g opencode-ai@latest" "$(tr '\n' ';' <"$SANDBOX/routine-freshness/calls" | sed 's/;$//')"

printf 'Test 0c: routine freshness restores versions newer than the safety pin\n'
: >"$SANDBOX/routine-freshness/calls"
printf '1.19.0\n' >"$SANDBOX/routine-freshness/opencode-version"
PATH="$SANDBOX/routine-freshness/bin:$SYSTEM_PATH" "$TOOL_VERSION_CHECK" --category npm --update --quiet >/dev/null
assert_eq "general newer release still tracks registry, not headless pin" "install -g opencode-ai@latest" "$(tr '\n' ';' <"$SANDBOX/routine-freshness/calls" | sed 's/;$//')"

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

printf 'Test 4: headless guard provisions an isolated pin without changing newer general install\n'
mkdir -p "$SANDBOX/version-guard/runtime" "$SANDBOX/version-guard/bin" "$SANDBOX/version-guard/state"
write_executable "$SANDBOX/version-guard/runtime/opencode" '#!/usr/bin/env bash
printf "1.18.17\n"'
# shellcheck disable=SC2016 # Literal stub body; quoted SANDBOX segments are expanded by the outer script.
write_executable "$SANDBOX/version-guard/bin/npm" '#!/usr/bin/env bash
printf "%s\n" "$*" >>"'"$SANDBOX"'/version-guard/calls"
prefix=""
while [[ "$#" -gt 0 ]]; do
  if [[ "$1" == "--prefix" ]]; then prefix="$2"; shift 2; continue; fi
  shift
done
mkdir -p "$prefix/node_modules/opencode-linux-x64/bin"
cat >"$prefix/node_modules/opencode-linux-x64/bin/opencode" <<"BIN"
#!/usr/bin/env bash
printf "1.18.16\n"
BIN
chmod +x "$prefix/node_modules/opencode-linux-x64/bin/opencode"'
guard_rc=0
headless_bin=""
(
	source_extracted
	OPENCODE_BIN_DEFAULT="$SANDBOX/version-guard/runtime/opencode"
	HEADLESS_OPENCODE_BIN="$OPENCODE_BIN_DEFAULT"
	STATE_DIR="$SANDBOX/version-guard/state"
	AIDEVOPS_TEST_UNAME_M="x86_64"
	AIDEVOPS_OPENCODE_PIN_PLATFORM_OVERRIDE="Linux"
	print_warning() { return 0; }
	print_info() { return 0; }
	print_error() { return 0; }
	PATH="$SANDBOX/version-guard/bin:$SYSTEM_PATH" _enforce_opencode_version_pin
	printf '%s\n' "$HEADLESS_OPENCODE_BIN" >"$SANDBOX/version-guard/headless-bin"
) || guard_rc=$?
assert_eq "headless pin repair status" "0" "$guard_rc"
headless_bin=$(<"$SANDBOX/version-guard/headless-bin")
assert_eq "general install remains newer" "1.18.17" "$("$SANDBOX/version-guard/runtime/opencode")"
assert_eq "isolated headless runtime is pinned" "1.18.16" "$("$headless_bin")"
install_call=$(<"$SANDBOX/version-guard/calls")
[[ "$install_call" == "install --ignore-scripts --no-audit --no-fund --prefix "*"/opencode-runtimes/.1.18.16.install."*"/prefix opencode-ai@1.18.16" ]] && install_shape="valid" || install_shape="invalid"
assert_eq "isolated install requests exact pin" "valid" "$install_shape"

printf 'Test 4b: existing isolated pin is reused without package-manager mutation\n'
reuse_rc=0
(
	source_extracted
	STATE_DIR="$SANDBOX/version-guard/state"
	OPENCODE_BIN_DEFAULT="$SANDBOX/version-guard/runtime/opencode"
	HEADLESS_OPENCODE_BIN="$OPENCODE_BIN_DEFAULT"
	AIDEVOPS_TEST_UNAME_M="x86_64"
	AIDEVOPS_OPENCODE_PIN_PLATFORM_OVERRIDE="Linux"
	print_warning() { return 0; }
	print_info() { return 0; }
	print_error() { return 0; }
	PATH="$SANDBOX/version-guard/bin:$SYSTEM_PATH" _enforce_opencode_version_pin
) || reuse_rc=$?
assert_eq "existing isolated runtime reuse status" "0" "$reuse_rc"
assert_eq "existing isolated runtime avoids second install" "1" "$(wc -l <"$SANDBOX/version-guard/calls" | tr -d ' ')"

printf 'Test 5: headless version guard fails closed when isolated provisioning fails\n'
mkdir -p "$SANDBOX/version-install-failure/state"
write_executable "$SANDBOX/version-install-failure/opencode" '#!/usr/bin/env bash
printf "1.18.17\n"'
write_executable "$SANDBOX/version-install-failure/npm" '#!/usr/bin/env bash
exit 42'
guard_rc=0
(
	source_extracted
	STATE_DIR="$SANDBOX/version-install-failure/state"
	OPENCODE_BIN_DEFAULT="$SANDBOX/version-install-failure/opencode"
	HEADLESS_OPENCODE_BIN="$OPENCODE_BIN_DEFAULT"
	AIDEVOPS_TEST_UNAME_M="x86_64"
	AIDEVOPS_OPENCODE_PIN_PLATFORM_OVERRIDE="Linux"
	print_warning() { return 0; }
	print_info() { return 0; }
	print_error() { return 0; }
	PATH="$SANDBOX/version-install-failure:$SYSTEM_PATH" _enforce_opencode_version_pin
) || guard_rc=$?
assert_eq "headless failed reinstall status" "1" "$guard_rc"

printf 'Test 6: non-Linux headless dispatch keeps the general binary\n'
scope_rc=0
(
	source_extracted
	OPENCODE_BIN_DEFAULT="$SANDBOX/version-guard/runtime/opencode"
	HEADLESS_OPENCODE_BIN="unexpected"
	AIDEVOPS_OPENCODE_PIN_PLATFORM_OVERRIDE="Darwin"
	print_warning() { return 0; }
	print_info() { return 0; }
	print_error() { return 0; }
	_enforce_opencode_version_pin
	printf '%s\n' "$HEADLESS_OPENCODE_BIN" >"$SANDBOX/version-guard/non-linux-bin"
) || scope_rc=$?
assert_eq "non-Linux scope status" "0" "$scope_rc"
assert_eq "non-Linux uses general binary" "$SANDBOX/version-guard/runtime/opencode" "$(<"$SANDBOX/version-guard/non-linux-bin")"

printf 'Test 7: headless run and auth paths consume the isolated runtime binding\n'
model_source="$REPO_ROOT/.agents/scripts/headless-runtime-model.sh"
provider_source="$REPO_ROOT/.agents/scripts/headless-runtime-provider.sh"
# shellcheck disable=SC2016 # Literal source pattern, not a shell expansion.
binding_count=$(grep -c 'HEADLESS_OPENCODE_BIN:-\$OPENCODE_BIN_DEFAULT' "$model_source" "$provider_source" | awk -F: '{ total += $2 } END { print total + 0 }')
assert_eq "isolated runtime reaches run and auth call sites" "3" "$binding_count"

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi

exit 0
