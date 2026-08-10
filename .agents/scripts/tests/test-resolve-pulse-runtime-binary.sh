#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-resolve-pulse-runtime-binary.sh — t2954 / GH#21199 regression guard.
#
# Verifies that `_resolve_pulse_runtime_binary` in .agents/scripts/setup/modules/schedulers.sh:
#
#   1. Sweeps Node version manager install roots ($HOME/.nvm,
#      $HOME/.volta, $HOME/.local/share/fnm) for an opencode binary —
#      not just the legacy fixed paths. Pre-fix, an nvm-only Linux
#      runner would never hit any candidate in step 4 and silently fall
#      through to step 5 (/opt/homebrew/bin/opencode, which doesn't
#      exist on Linux).
#
#   2. Validates every accepted candidate with
#      _setup_validate_opencode_binary — rejects the Anthropic claude
#      CLI even when it occupies the `opencode` bin name, so a wrong
#      product cannot be persisted.
#
#   3. Validates the persisted file at read-time and re-resolves on
#      failure (rather than trusting a stale wrong-product entry from
#      a pre-fix runner that locked in claude as OPENCODE_BIN).
#
#   4. Picks the most-recent Node version when multiple are installed
#      (sort -rV).
#
#   5. Fnm-style paths (with the extra `installation/` segment) are
#      detected alongside nvm/volta `bin/` paths.
#
#   6. Normalizes accepted Node-manager binaries to a daemon-visible
#      ~/.local/bin/opencode shim so systemd workers do not depend on shell init.
#
# Failure history: alex-solovyev's Linux runner went 9 days (Apr 18-27,
# 2026) with 0/3 workers dispatching after the t2176 setup re-run wrote
# `~/.config/aidevops/scheduler-runtime-bin = ~/.local/bin/claude`,
# which the legacy step-4 candidate loop happily accepted because no
# product validation existed and `~/.nvm/versions/node/v24.13.1/bin/opencode`
# was never even considered.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_REPO_ROOT="$(cd "$TEST_SCRIPTS_DIR/../.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# Build a fake $HOME with a synthetic Node version manager layout.
# $1 = fixture root (will become $HOME).
# $2 = "opencode" or "claude" — controls product identity emitted by binaries.
# $3 = Node manager: "nvm" | "volta" | "fnm".
# $4 = Node version label (e.g. "v24.13.1" or "20.10.0").
build_fixture_node_install() {
	local _home="$1" _product="$2" _mgr="$3" _ver="$4" _needs_node="${5:-0}"
	local _bin_dir _bin_path _ver_str

	case "$_product" in
		opencode) _ver_str="1.14.27" ;;
		claude)   _ver_str="2.1.120 (Claude Code)" ;;
		*) printf 'unknown product: %s\n' "$_product" >&2; return 1 ;;
	esac

	case "$_mgr" in
		nvm)
			_bin_dir="$_home/.nvm/versions/node/$_ver/bin"
			;;
		volta)
			_bin_dir="$_home/.volta/tools/image/node/$_ver/bin"
			;;
		fnm)
			_bin_dir="$_home/.local/share/fnm/node-versions/$_ver/installation/bin"
			;;
		*) printf 'unknown mgr: %s\n' "$_mgr" >&2; return 1 ;;
	esac

	mkdir -p "$_bin_dir"
	# Stub binary always named "opencode" (the bin slot is product-agnostic;
	# `command -v opencode` finds whatever owns the name). The product
	# identity is what `--version` prints — that's what the validator reads.
	_bin_path="$_bin_dir/opencode"
cat >"$_bin_path" <<EOF
#!/bin/sh
if [ "$_needs_node" = "1" ] && ! command -v node >/dev/null 2>&1; then
	exit 127
fi
case "\$1" in
--version) echo '$_ver_str' ;;
--help) echo 'opencode run [message]' ;;
*) echo "stub" ;;
esac
EOF
	if [[ "$_needs_node" == "1" ]]; then
		cat >"$_bin_dir/node" <<'EOF'
#!/bin/sh
exit 0
EOF
		chmod +x "$_bin_dir/node"
	fi
	chmod +x "$_bin_path"
	printf '%s' "$_bin_path"
	return 0
}

# Build a fake legacy fixed path (e.g. ~/.local/bin/opencode).
build_fixture_fixed_path() {
	local _home="$1" _product="$2" _path="$3"
	local _bin_dir _ver_str

	case "$_product" in
		opencode) _ver_str="1.14.27" ;;
		claude)   _ver_str="2.1.120 (Claude Code)" ;;
		*) return 1 ;;
	esac

	_bin_dir=$(dirname "$_home/$_path")
	mkdir -p "$_bin_dir"
	cat >"$_home/$_path" <<EOF
#!/bin/sh
case "\$1" in
--version) echo '$_ver_str' ;;
--help)
  if [ "$_product" = "opencode" ]; then
    echo 'opencode run [message]'
  else
    echo 'claude help'
  fi
  ;;
*) echo "stub" ;;
esac
EOF
	chmod +x "$_home/$_path"
	printf '%s' "$_home/$_path"
	return 0
}

# Run the resolver in a subshell with overridden $HOME and a sanitized
# PATH (no real opencode on PATH so step 3 falls through). Returns
# resolver stdout.
run_resolver() {
	local _fixture_home="$1"
	# Subshell isolates env modifications from the parent test harness.
	(
		export HOME="$_fixture_home"
		# Strip system bin dirs that might host a real opencode/claude;
		# keep /usr/bin and /bin so head/find/sort/printf still resolve.
		export PATH="/usr/bin:/bin"
		_resolve_pulse_runtime_binary
	)
}

run_resolver_with_path() {
	local _fixture_home="$1" _path_prefix="$2"
	(
		export HOME="$_fixture_home"
		export PATH="$_path_prefix:/usr/bin:/bin"
		_resolve_pulse_runtime_binary
	)
}

run_resolver_with_explicit_bin() {
	local _fixture_home="$1" _explicit_bin="$2"
	(
		export HOME="$_fixture_home"
		export PATH="/usr/bin:/bin"
		export OPENCODE_BIN="$_explicit_bin"
		_resolve_pulse_runtime_binary
	)
}

# --- Source the resolver and validator ---
# tool-install.sh defines _setup_validate_opencode_binary;
# schedulers.sh defines _resolve_pulse_runtime_binary and the helpers.
# Both have `set -euo pipefail` at the top — capture and restore.
set +e
# shellcheck disable=SC1091
source "$TEST_REPO_ROOT/.agents/scripts/setup/modules/tool-install.sh" 2>/dev/null || true
# shellcheck disable=SC1091
source "$TEST_REPO_ROOT/.agents/scripts/setup/modules/schedulers.sh" 2>/dev/null || true
set +e

if ! declare -F _resolve_pulse_runtime_binary >/dev/null; then
	echo "FAIL: _resolve_pulse_runtime_binary not defined after sourcing"
	exit 1
fi

if ! declare -F _setup_validate_opencode_binary >/dev/null; then
	echo "FAIL: _setup_validate_opencode_binary not defined after sourcing"
	exit 1
fi

# --- Tests ---

# Test 1: nvm path discovery. Plain $HOME with only ~/.nvm populated.
fixture1=$(mktemp -d 2>/dev/null || mktemp -d -t t2954a)
build_fixture_node_install "$fixture1" "opencode" "nvm" "v24.13.1" >/dev/null
expected1="$fixture1/.local/bin/opencode"
result1=$(run_resolver "$fixture1")
if [[ "$result1" == "$expected1" ]]; then
	print_result "nvm path discovery — normalizes to ~/.local/bin/opencode shim" 0
else
	print_result "nvm path discovery — normalizes to ~/.local/bin/opencode shim" 1 \
		"expected=$expected1 got=$result1"
fi
rm -rf "$fixture1"

# Test 2: volta path discovery.
fixture2=$(mktemp -d 2>/dev/null || mktemp -d -t t2954b)
build_fixture_node_install "$fixture2" "opencode" "volta" "20.10.0" >/dev/null
expected2="$fixture2/.local/bin/opencode"
result2=$(run_resolver "$fixture2")
if [[ "$result2" == "$expected2" ]]; then
	print_result "volta path discovery — normalizes to ~/.local/bin/opencode shim" 0
else
	print_result "volta path discovery — normalizes to ~/.local/bin/opencode shim" 1 \
		"expected=$expected2 got=$result2"
fi
rm -rf "$fixture2"

# Test 3: fnm path discovery (extra `installation/` segment).
fixture3=$(mktemp -d 2>/dev/null || mktemp -d -t t2954c)
build_fixture_node_install "$fixture3" "opencode" "fnm" "v22.5.0" >/dev/null
expected3="$fixture3/.local/bin/opencode"
result3=$(run_resolver "$fixture3")
if [[ "$result3" == "$expected3" ]]; then
	print_result "fnm path discovery — normalizes to ~/.local/bin/opencode shim" 0
else
	print_result "fnm path discovery — normalizes to ~/.local/bin/opencode shim" 1 \
		"expected=$expected3 got=$result3"
fi
rm -rf "$fixture3"

# Test 4: Most-recent Node version wins (sort -rV).
fixture4=$(mktemp -d 2>/dev/null || mktemp -d -t t2954d)
build_fixture_node_install "$fixture4" "opencode" "nvm" "v18.20.0" >/dev/null
build_fixture_node_install "$fixture4" "opencode" "nvm" "v22.5.0" >/dev/null
build_fixture_node_install "$fixture4" "opencode" "nvm" "v24.13.1" >/dev/null
expected4="$fixture4/.local/bin/opencode"
result4=$(run_resolver "$fixture4")
if [[ "$result4" == "$expected4" ]] && grep -q 'v24.13.1' "$result4" 2>/dev/null; then
	print_result "most-recent Node version wins — v24 over v22 over v18" 0
else
	print_result "most-recent Node version wins — v24 over v22 over v18" 1 \
		"expected=$expected4 got=$result4"
fi
rm -rf "$fixture4"

# Test 5: Claude rejection at sweep-time. nvm contains a claude-stub
# (wrong product) — resolver must skip it and return empty when no real
# OpenCode exists. Empty is safer than a fake legacy fallback because it
# fails clear instead of persisting or launching the wrong runtime.
fixture5=$(mktemp -d 2>/dev/null || mktemp -d -t t2954e)
build_fixture_node_install "$fixture5" "claude" "nvm" "v24.13.1" >/dev/null
result5=$(run_resolver "$fixture5")
persisted_file5="$fixture5/.config/aidevops/scheduler-runtime-bin"
claude_path5="$fixture5/.nvm/versions/node/v24.13.1/bin/opencode"
if [[ -z "$result5" ]]; then
	print_result "claude binary in nvm path — rejected; resolver returns empty" 0
else
	print_result "claude binary in nvm path — rejected; resolver returns empty" 1 \
		"expected empty result, got: $result5"
fi
if [[ ! -f "$persisted_file5" ]] || \
	[[ "$(cat "$persisted_file5" 2>/dev/null)" != "$claude_path5" ]]; then
	print_result "claude binary — not persisted as OPENCODE_BIN" 0
else
	print_result "claude binary — not persisted as OPENCODE_BIN" 1 \
		"persisted file contains claude path"
fi
rm -rf "$fixture5"

# Test 5b: Claude fixed path must not be considered an OpenCode fallback.
fixture5b=$(mktemp -d 2>/dev/null || mktemp -d -t t2954e2)
claude_path5b=$(build_fixture_fixed_path "$fixture5b" "claude" ".local/bin/claude")
result5b=$(run_resolver "$fixture5b")
if [[ -z "$result5b" ]]; then
	print_result "claude fixed path — not returned as OpenCode fallback" 0
else
	print_result "claude fixed path — not returned as OpenCode fallback" 1 \
		"expected empty result, got=$result5b claude=$claude_path5b"
fi
rm -rf "$fixture5b"

# Test 6: Stale wrong-product persisted file — validator drops it and
# resolver re-resolves to the real opencode binary present in nvm.
# Mirrors alex-solovyev's runner state pre-heal: persisted = claude.
fixture6=$(mktemp -d 2>/dev/null || mktemp -d -t t2954f)
build_fixture_node_install "$fixture6" "opencode" "nvm" "v24.13.1" >/dev/null
expected6="$fixture6/.local/bin/opencode"
# Plant a claude stub at a separate fixed path and persist that path.
claude_stub6=$(build_fixture_fixed_path "$fixture6" "claude" ".local/bin/claude")
mkdir -p "$fixture6/.config/aidevops"
printf '%s\n' "$claude_stub6" >"$fixture6/.config/aidevops/scheduler-runtime-bin"
result6=$(run_resolver "$fixture6")
if [[ "$result6" == "$expected6" ]]; then
	print_result "stale claude in persisted file — dropped, re-resolves to nvm opencode" 0
else
	print_result "stale claude in persisted file — dropped, re-resolves to nvm opencode" 1 \
		"expected=$expected6 got=$result6"
fi
# After re-resolution, persisted file should now point at the real opencode.
persisted6=$(cat "$fixture6/.config/aidevops/scheduler-runtime-bin" 2>/dev/null || true)
if [[ "$persisted6" == "$expected6" ]]; then
	print_result "persistence updated to validated opencode after stale-claude drop" 0
else
	print_result "persistence updated to validated opencode after stale-claude drop" 1 \
		"persisted=$persisted6 expected=$expected6"
fi
rm -rf "$fixture6"

# Test 7: Persistence round-trip — valid opencode is persisted and re-read.
fixture7=$(mktemp -d 2>/dev/null || mktemp -d -t t2954g)
build_fixture_node_install "$fixture7" "opencode" "nvm" "v22.5.0" >/dev/null
expected7="$fixture7/.local/bin/opencode"
# First run: discovers via nvm sweep, persists.
run_resolver "$fixture7" >/dev/null
persisted7=$(cat "$fixture7/.config/aidevops/scheduler-runtime-bin" 2>/dev/null || true)
if [[ "$persisted7" == "$expected7" ]]; then
	print_result "persistence — valid opencode written to scheduler-runtime-bin" 0
else
	print_result "persistence — valid opencode written to scheduler-runtime-bin" 1 \
		"persisted=$persisted7 expected=$expected7"
fi
# Second run: reads from persisted file (validation passes), returns same path.
result7b=$(run_resolver "$fixture7")
if [[ "$result7b" == "$expected7" ]]; then
	print_result "persistence — second run reads from scheduler-runtime-bin" 0
else
	print_result "persistence — second run reads from scheduler-runtime-bin" 1 \
		"got=$result7b expected=$expected7"
fi
rm -rf "$fixture7"

# Test 8: Legacy fixed path still works as fallback (Linux ~/.local/bin).
fixture8=$(mktemp -d 2>/dev/null || mktemp -d -t t2954h)
expected8=$(build_fixture_fixed_path "$fixture8" "opencode" ".local/bin/opencode")
result8=$(run_resolver "$fixture8")
if [[ "$result8" == "$expected8" ]]; then
	print_result "legacy fixed path — finds opencode in ~/.local/bin (fallback)" 0
else
	print_result "legacy fixed path — finds opencode in ~/.local/bin (fallback)" 1 \
		"expected=$expected8 got=$result8"
fi
rm -rf "$fixture8"

# Test 9: Node-manager binary that requires node in PATH remains runnable via shim.
fixture9=$(mktemp -d 2>/dev/null || mktemp -d -t t2954i)
build_fixture_node_install "$fixture9" "opencode" "nvm" "v24.13.1" "1" >/dev/null
expected9="$fixture9/.local/bin/opencode"
result9=$(run_resolver "$fixture9")
if [[ "$result9" == "$expected9" ]] && HOME="$fixture9" PATH="/usr/bin:/bin" "$result9" --version >/dev/null 2>&1; then
	print_result "stable shim — nvm opencode remains runnable in sanitized systemd PATH" 0
else
	print_result "stable shim — nvm opencode remains runnable in sanitized systemd PATH" 1 \
		"result=$result9 expected=$expected9"
fi
rm -rf "$fixture9"

# Test 10: Wrong-product direct PATH hit is rejected so discovery continues.
fixture10=$(mktemp -d 2>/dev/null || mktemp -d -t t2954j)
build_fixture_fixed_path "$fixture10" "claude" ".path/bin/opencode" >/dev/null
build_fixture_node_install "$fixture10" "opencode" "nvm" "v24.13.1" >/dev/null
expected10="$fixture10/.local/bin/opencode"
result10=$(run_resolver_with_path "$fixture10" "$fixture10/.path/bin")
if [[ "$result10" == "$expected10" ]]; then
	print_result "direct PATH claude hit — rejected, continues to nvm OpenCode" 0
else
	print_result "direct PATH claude hit — rejected, continues to nvm OpenCode" 1 \
		"expected=$expected10 got=$result10"
fi
rm -rf "$fixture10"

# Test 11: Daemon PATH construction never injects current-directory entries
# when the OpenCode path is empty or relative.
fixture11=$(mktemp -d 2>/dev/null || mktemp -d -t t2954k)
(
	export HOME="$fixture11"
	path_empty=$(_pulse_daemon_path_for_opencode "")
	path_relative=$(_pulse_daemon_path_for_opencode "opencode")
	printf '%s\n%s\n' "$path_empty" "$path_relative"
) >"$fixture11/out"
{
	IFS= read -r path11_empty
	IFS= read -r path11_relative
} <"$fixture11/out"
case "$path11_empty" in
	""|:*|*::*|*:.:*|*:.|.*)
		print_result "daemon PATH — empty/relative opencode excludes current directory" 1 \
			"empty=$path11_empty relative=$path11_relative"
		;;
	*)
		case "$path11_relative" in
			""|:*|*::*|*:.:*|*:.|.*)
				print_result "daemon PATH — empty/relative opencode excludes current directory" 1 \
					"empty=$path11_empty relative=$path11_relative"
				;;
			*)
				print_result "daemon PATH — empty/relative opencode excludes current directory" 0
				;;
		esac
		;;
esac
rm -rf "$fixture11"

# Test 12: An explicit runtime binary survives a minimal systemd PATH and is
# normalized to the daemon-safe shim. This is the auto-update regeneration
# path that previously dropped OPENCODE_BIN and selected /usr/bin/opencode.
fixture12=$(mktemp -d 2>/dev/null || mktemp -d -t t2954l)
explicit12=$(build_fixture_node_install "$fixture12" "opencode" "nvm" "v24.13.1")
expected12="$fixture12/.local/bin/opencode"
result12=$(run_resolver_with_explicit_bin "$fixture12" "$explicit12")
persisted12=$(cat "$fixture12/.config/aidevops/scheduler-runtime-bin" 2>/dev/null || true)
if [[ "$result12" == "$expected12" && "$persisted12" == "$expected12" ]]; then
	print_result "explicit OPENCODE_BIN — normalized and persisted under minimal PATH" 0
else
	print_result "explicit OPENCODE_BIN — normalized and persisted under minimal PATH" 1 \
		"result=$result12 persisted=$persisted12 expected=$expected12"
fi
rm -rf "$fixture12"

# Test 13: Login-shell startup output cannot pollute the discovered path.
login_shell_output13=$'startup banner\n__AIDEVOPS_OPENCODE__/home/test/.nvm/bin/opencode\n'
result13=$(printf '%s' "$login_shell_output13" | _pulse_extract_login_shell_opencode_binary)
if [[ "$result13" == "/home/test/.nvm/bin/opencode" ]]; then
	print_result "login-shell discovery — ignores startup output" 0
else
	print_result "login-shell discovery — ignores startup output" 1 \
		"result=$result13"
fi

# Test 14: A failed shim write must fail immediately without reporting a path.
fixture14=$(mktemp -d 2>/dev/null || mktemp -d -t t2954n)
explicit14=$(build_fixture_node_install "$fixture14" "opencode" "nvm" "v24.13.1")
shim14=$(_pulse_write_direct_opencode_shim "$explicit14")
before14=$(cat "$shim14")
if grep -Fq "\${HOME:+:\$HOME/.local/bin}" "$shim14" && \
	grep -Fq '# aidevops:terminal-title-owner' "$shim14" && \
	grep -Fq "OPENCODE_DISABLE_TERMINAL_TITLE=\"\${OPENCODE_DISABLE_TERMINAL_TITLE:-1}\"" "$shim14"; then
	print_result "stable shim — runtime paths and terminal-title ownership are preserved" 0
else
	print_result "stable shim — runtime paths and terminal-title ownership are preserved" 1
fi
cat() {
	return 1
}
result14=$(_pulse_write_direct_opencode_shim "$explicit14" 2>/dev/null)
rc14=$?
unset -f cat
after14=$(cat "$shim14")
if [[ "$rc14" -ne 0 && -z "$result14" && "$after14" == "$before14" ]]; then
	print_result "stable shim — write failure preserves the existing shim" 0
else
	print_result "stable shim — write failure preserves the existing shim" 1 \
		"rc=$rc14 result=$result14"
fi
rm -rf "$fixture14"

# Test 15: An empty HOME fails closed before any root-level fallback is built.
result15=$(HOME="" _resolve_pulse_runtime_binary 2>/dev/null)
rc15=$?
if [[ "$rc15" -ne 0 && -z "$result15" ]]; then
	print_result "runtime resolution — empty HOME fails without a root-level path" 0
else
	print_result "runtime resolution — empty HOME fails without a root-level path" 1 \
		"rc=$rc15 result=$result15"
fi

# --- Summary ---
echo ""
echo "Tests run: $TESTS_RUN"
echo "Failed:    $TESTS_FAILED"

if [[ "$TESTS_FAILED" -eq 0 ]]; then
	exit 0
fi
exit 1
