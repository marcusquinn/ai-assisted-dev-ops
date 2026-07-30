#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# t2888: Smoke test for setup_opencode_cli + _setup_validate_opencode_binary.
#
# Validates the install/heal logic added to .agents/scripts/setup/_services.sh.
# Companion to t2887 (which tests the runtime canary validator). This test
# focuses on the SETUP-time validator + behavioural shape of setup_opencode_cli
# without actually performing global npm/bun installs (we shim them).
#
# Test strategy:
#   1. Source _services.sh in a subshell with print_*, $HOME, PATH stubbed
#      so the script doesn't touch the real environment.
#   2. Verify _setup_validate_opencode_binary returns the right rc for each
#      synthetic binary (real opencode, claude CLI shim, missing, garbage).
#   3. Verify setup_opencode_cli writes ~/.aidevops/.opencode-bin-resolved
#      on the success path and returns 0 on the install-fail path
#      (fail-open contract).
#   4. Verify setup writes a daemon-safe ~/.local/bin/opencode shim and clears
#      stale canary negative cache after a successful repair.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SERVICES_LIB="$REPO_ROOT/.agents/scripts/setup/_services.sh"

if [[ ! -f "$SERVICES_LIB" ]]; then
	echo "FAIL: cannot find $SERVICES_LIB" >&2
	exit 1
fi

# Sandbox dir for fake $HOME + fake bin shims.
SANDBOX="$(mktemp -d -t t2888-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/home" "$SANDBOX/bin"
export HOME="$SANDBOX/home"

PASS=0
FAIL=0

assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		echo "  PASS: $desc"
		PASS=$((PASS + 1))
		return 0
	fi
	echo "  FAIL: $desc -- expected '$expected', got '$actual'" >&2
	FAIL=$((FAIL + 1))
	return 1
}

# Source the lib in a subshell with stubbed print helpers.
source_lib() {
	# shellcheck disable=SC2317  # functions used after sourcing in subshell
	print_info() { echo "INFO: $*"; return 0; }
	# shellcheck disable=SC2317
	print_success() { echo "OK: $*"; return 0; }
	# shellcheck disable=SC2317
	print_warning() { echo "WARN: $*"; return 0; }
	export -f print_info print_success print_warning 2>/dev/null || true
	# shellcheck disable=SC1090
	source "$SERVICES_LIB"
	return 0
}

# --- Test 1: validator rc for a real-shaped opencode binary -----------------
echo "Test 1: _setup_validate_opencode_binary on real opencode shim"
cat >"$SANDBOX/bin/opencode-real" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "1.14.25"
[[ "${1:-}" == "--help" ]] && echo "opencode run [message..]     run opencode with a message"
exit 0
EOF
chmod +x "$SANDBOX/bin/opencode-real"

(
	source_lib
	rc=0
	_setup_validate_opencode_binary "$SANDBOX/bin/opencode-real" || rc=$?
	echo "$rc"
) >"$SANDBOX/out1" 2>&1
rc1=$(tail -1 "$SANDBOX/out1")
assert_eq "real opencode -> rc=0" "0" "$rc1"

# --- Test 1b: validator rc for equivalent help formatting -------------------
echo "Test 1b: _setup_validate_opencode_binary accepts flexible help format"
cat >"$SANDBOX/bin/opencode-flex-help" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "1.14.25"
[[ "${1:-}" == "--help" ]] && printf '%s\n' "Usage: opencode run <message>" "Commands:" "  run  Execute a prompt"
exit 0
EOF
chmod +x "$SANDBOX/bin/opencode-flex-help"

(
	source_lib
	rc=0
	_setup_validate_opencode_binary "$SANDBOX/bin/opencode-flex-help" || rc=$?
	echo "$rc"
) >"$SANDBOX/out1b" 2>&1
rc1b=$(tail -1 "$SANDBOX/out1b")
assert_eq "flex help opencode -> rc=0" "0" "$rc1b"

# --- Test 2: validator rc for claude CLI shim -------------------------------
echo "Test 2: _setup_validate_opencode_binary on claude CLI shim"
cat >"$SANDBOX/bin/opencode-claude" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "2.1.119 (Claude Code)"
[[ "${1:-}" == "--help" ]] && echo "Claude Code"
EOF
chmod +x "$SANDBOX/bin/opencode-claude"

(
	source_lib
	rc=0
	_setup_validate_opencode_binary "$SANDBOX/bin/opencode-claude" || rc=$?
	echo "$rc"
) >"$SANDBOX/out2" 2>&1
rc2=$(tail -1 "$SANDBOX/out2")
assert_eq "claude shim -> rc=1" "1" "$rc2"

# --- Test 2b: validator rc for Qwen Code shim -------------------------------
echo "Test 2b: _setup_validate_opencode_binary rejects qwen CLI shim"
cat >"$SANDBOX/bin/opencode-qwen" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "0.2.1"
[[ "${1:-}" == "--help" ]] && echo "Qwen Code - Launch an interactive CLI"
EOF
chmod +x "$SANDBOX/bin/opencode-qwen"

(
	source_lib
	rc=0
	_setup_validate_opencode_binary "$SANDBOX/bin/opencode-qwen" || rc=$?
	echo "$rc"
) >"$SANDBOX/out2b" 2>&1
rc2b=$(tail -1 "$SANDBOX/out2b")
assert_eq "qwen shim -> rc=1" "1" "$rc2b"

# --- Test 3: validator rc for missing binary --------------------------------
echo "Test 3: _setup_validate_opencode_binary on missing path"
(
	source_lib
	rc=0
	_setup_validate_opencode_binary "$SANDBOX/bin/does-not-exist" || rc=$?
	echo "$rc"
) >"$SANDBOX/out3" 2>&1
rc3=$(tail -1 "$SANDBOX/out3")
assert_eq "missing path -> rc=2" "2" "$rc3"

# --- Test 4: validator rc for garbage version output ------------------------
echo "Test 4: _setup_validate_opencode_binary on garbage shim"
cat >"$SANDBOX/bin/opencode-garbage" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "not-a-version"
[[ "${1:-}" == "--help" ]] && echo "not opencode"
EOF
chmod +x "$SANDBOX/bin/opencode-garbage"

(
	source_lib
	rc=0
	_setup_validate_opencode_binary "$SANDBOX/bin/opencode-garbage" || rc=$?
	echo "$rc"
) >"$SANDBOX/out4" 2>&1
rc4=$(tail -1 "$SANDBOX/out4")
assert_eq "garbage version -> rc=1" "1" "$rc4"

# --- Test 4b: validator timeout for hanging --version -----------------------
echo "Test 4b: _setup_validate_opencode_binary bounds hanging --version"
cat >"$SANDBOX/bin/opencode-slow" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
	sleep 5
	echo "1.14.25"
fi
[[ "${1:-}" == "--help" ]] && echo "opencode run [message..]     run opencode with a message"
EOF
chmod +x "$SANDBOX/bin/opencode-slow"

(
	source_lib
	export AIDEVOPS_OPENCODE_VERSION_TIMEOUT=1
	SECONDS=0
	rc=0
	_setup_validate_opencode_binary "$SANDBOX/bin/opencode-slow" || rc=$?
	printf 'rc=%s elapsed=%s\n' "$rc" "$SECONDS"
) >"$SANDBOX/out4b" 2>&1
rc4b=$(grep '^rc=' "$SANDBOX/out4b" | tail -1)
elapsed4b="${rc4b##*elapsed=}"
rc4b="${rc4b%% elapsed=*}"
assert_eq "hanging version -> rc=2" "rc=2" "$rc4b"
if [[ "$elapsed4b" =~ ^[0-9]+$ ]] && [[ "$elapsed4b" -le 3 ]]; then
	assert_eq "hanging version returns within bound" "bounded" "bounded"
else
	assert_eq "hanging version returns within bound" "elapsed<=3" "elapsed=${elapsed4b}"
fi

# --- Test 5: setup_opencode_cli skips install when current binary is valid --
echo "Test 5: setup_opencode_cli skip-when-valid + persists resolved path"
(
	source_lib
	export OPENCODE_BIN="$SANDBOX/bin/opencode-real"
	rc=0
	setup_opencode_cli || rc=$?
	echo "rc=$rc"
	cat "$HOME/.aidevops/.opencode-bin-resolved" 2>/dev/null || echo "MISSING"
) >"$SANDBOX/out5" 2>&1
rc5=$(grep '^rc=' "$SANDBOX/out5" | tail -1)
resolved5=$(tail -1 "$SANDBOX/out5")
assert_eq "skip-when-valid rc" "rc=0" "$rc5"
assert_eq "skip-when-valid resolved-path file" "$HOME/.local/bin/opencode" "$resolved5"
if HOME="$HOME" PATH="/usr/bin:/bin" "$resolved5" --version >/dev/null 2>&1; then
	assert_eq "stable shim runs in sanitized PATH" "ok" "ok"
else
	assert_eq "stable shim runs in sanitized PATH" "ok" "failed"
fi
if grep -q 'PATH:+:' "$resolved5" && ! grep -q 'PATH:-}' "$resolved5"; then
	assert_eq "stable shim avoids trailing empty PATH component" "safe" "safe"
else
	assert_eq "stable shim avoids trailing empty PATH component" "safe" "unsafe"
fi

# --- Test 5b: setup_opencode_cli clears stale canary negative cache ----------
echo "Test 5b: setup_opencode_cli clears canary negative cache after repair"
rm -f "$HOME/.aidevops/.opencode-bin-resolved" "$HOME/.local/bin/opencode"
mkdir -p "$HOME/.aidevops/.agent-workspace/headless-runtime"
printf '0\n' >"$HOME/.aidevops/.agent-workspace/headless-runtime/canary-last-fail"
printf 'config_error\n' >"$HOME/.aidevops/.agent-workspace/headless-runtime/canary-last-fail.reason"
(
	source_lib
	export OPENCODE_BIN="$SANDBOX/bin/opencode-real"
	rc=0
	setup_opencode_cli || rc=$?
	echo "rc=$rc"
) >"$SANDBOX/out5b" 2>&1
rc5b=$(grep '^rc=' "$SANDBOX/out5b" | tail -1)
assert_eq "cache-clear setup rc" "rc=0" "$rc5b"
if [[ ! -f "$HOME/.aidevops/.agent-workspace/headless-runtime/canary-last-fail" ]] && \
	[[ ! -f "$HOME/.aidevops/.agent-workspace/headless-runtime/canary-last-fail.reason" ]]; then
	assert_eq "stale canary negative cache cleared" "cleared" "cleared"
else
	assert_eq "stale canary negative cache cleared" "cleared" "present"
fi

# --- Test 5c: daemon shim PATH never contains current-directory entries ------
echo "Test 5c: _setup_opencode_node_path_for_binary omits unsafe relative entries"
(
	source_lib
	_setup_opencode_node_path_for_binary "opencode"
) >"$SANDBOX/out5c" 2>&1
path5c=$(tail -1 "$SANDBOX/out5c")
case "$path5c" in
	""|:*|*::*|*:.:*|*:.|.*)
		assert_eq "daemon shim path excludes empty/dot entries" "safe" "$path5c"
		;;
	*)
		assert_eq "daemon shim path excludes empty/dot entries" "safe" "safe"
		;;
esac

# --- Test 5d: bad stable shim is rewritten from another valid install --------
echo "Test 5d: setup_opencode_cli rewrites qwen stable shim from valid bun install"
rm -f "$HOME/.aidevops/.opencode-bin-resolved"
mkdir -p "$HOME/.local/bin" "$HOME/.bun/bin"
cp "$SANDBOX/bin/opencode-qwen" "$HOME/.local/bin/opencode"
cp "$SANDBOX/bin/opencode-real" "$HOME/.bun/bin/opencode"
(
	source_lib
	# Test 5d covers invalid-shim healing; temporary-path classification has
	# dedicated coverage in tests/test-opencode-stable-shim.sh.
	# shellcheck disable=SC2329  # Called through setup_opencode_cli from the sourced library.
	_setup_opencode_binary_is_ephemeral() {
		local bin="$1"

		if [[ "$bin" == "$HOME/.bun/bin/opencode" ]]; then
			return 1
		fi

		return 0
	}
	export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"
	export OPENCODE_BIN=""
	rc=0
	setup_opencode_cli || rc=$?
	echo "rc=$rc"
	cat "$HOME/.aidevops/.opencode-bin-resolved" 2>/dev/null || echo "MISSING"
) >"$SANDBOX/out5d" 2>&1
rc5d=$(grep '^rc=' "$SANDBOX/out5d" | tail -1)
resolved5d=$(tail -1 "$SANDBOX/out5d")
assert_eq "qwen stable shim heal rc" "rc=0" "$rc5d"
assert_eq "qwen stable shim rewritten" "$HOME/.local/bin/opencode" "$resolved5d"
if "$HOME/.local/bin/opencode" --help 2>/dev/null | grep -q 'opencode run \[message\.\.\]'; then
	assert_eq "qwen shim now points to valid opencode" "rewritten" "rewritten"
else
	assert_eq "qwen shim now points to valid opencode" "rewritten" "not-rewritten"
fi

# --- Test 6: setup_opencode_cli fail-open when no installer present ---------
echo "Test 6: setup_opencode_cli fail-open when no bun/npm + invalid current"
# Wipe persisted file from previous test so we can confirm it stays absent.
rm -f "$HOME/.aidevops/.opencode-bin-resolved"
rm -f "$HOME/.bun/bin/opencode" "$HOME/.local/bin/opencode"
(
	source_lib
	# Keep the fail-open fixture independent of host-level OpenCode installs.
	# shellcheck disable=SC2329  # Called through setup_opencode_cli from the sourced library.
	_setup_opencode_binary_is_ephemeral() {
		return 0
	}
	# Force minimal PATH so neither bun nor npm resolves; supply only the
	# claude shim under the name 'opencode'.
	rm -f "$SANDBOX/bin/opencode"
	cp "$SANDBOX/bin/opencode-claude" "$SANDBOX/bin/opencode"
	export PATH="$SANDBOX/bin"
	export OPENCODE_BIN=""
	rc=0
	setup_opencode_cli || rc=$?
	echo "rc=$rc"
) >"$SANDBOX/out6" 2>&1
rc6=$(grep '^rc=' "$SANDBOX/out6" | tail -1)
no_installer_msg=$(grep -c "Neither bun nor npm" "$SANDBOX/out6" || true)
assert_eq "fail-open rc" "rc=0" "$rc6"
assert_eq "fail-open emits remediation hint" "1" "$no_installer_msg"

# --- Test 7: setup_opencode_cli bounds hanging installer ---------------------
echo "Test 7: setup_opencode_cli bounds hanging installer"
cat >"$SANDBOX/bin/npm" <<'EOF'
#!/usr/bin/env bash
sleep 5
exit 0
EOF
chmod +x "$SANDBOX/bin/npm"
rm -f "$SANDBOX/bin/bun" "$HOME/.aidevops/.opencode-bin-resolved"
(
	source_lib
	cp "$SANDBOX/bin/opencode-garbage" "$SANDBOX/bin/opencode"
	export PATH="$SANDBOX/bin:/usr/bin:/bin"
	export OPENCODE_BIN=""
	export AIDEVOPS_OPENCODE_VERSION_TIMEOUT=1
	export AIDEVOPS_OPENCODE_INSTALL_TIMEOUT=1
	SECONDS=0
	rc=0
	setup_opencode_cli || rc=$?
	printf 'rc=%s elapsed=%s\n' "$rc" "$SECONDS"
) >"$SANDBOX/out7" 2>&1
rc7=$(grep '^rc=' "$SANDBOX/out7" | tail -1)
elapsed7="${rc7##*elapsed=}"
rc7="${rc7%% elapsed=*}"
assert_eq "hanging installer fail-opens" "rc=0" "$rc7"
if [[ "$elapsed7" =~ ^[0-9]+$ ]] && [[ "$elapsed7" -le 12 ]]; then
	assert_eq "hanging installer returns within bound" "bounded" "bounded"
else
	assert_eq "hanging installer returns within bound" "elapsed<=12" "elapsed=${elapsed7}"
fi

echo ""
echo "===== Results: $PASS passed, $FAIL failed ====="
[[ $FAIL -eq 0 ]] || exit 1
exit 0
