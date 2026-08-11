#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# t2891: Smoke test for the active setup_opencode_cli function in
# .agents/scripts/setup/modules/tool-install.sh — the function that's actually sourced
# by setup.sh (line 753), as opposed to the orphan stub in
# .agents/scripts/setup/_services.sh that t2888 fixed.
#
# Strategy: source tool-install.sh in a sandbox, stub print_*, setup_prompt,
# run_with_spinner, npm_global_install. Verify the validator + force-heal
# logic without actually installing global packages.
#
# This complements .agents/scripts/tests/test-setup-opencode-cli.sh (t2888),
# which tests the orphan _services.sh stub. Both must keep their validator
# semantics in lockstep with t2887's headless-runtime-lib.sh::_validate_opencode_binary.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
TOOL_INSTALL="$REPO_ROOT/.agents/scripts/setup/modules/tool-install.sh"
SETUP_COMMON="$REPO_ROOT/.agents/scripts/setup/_common.sh"

if [[ ! -f "$TOOL_INSTALL" ]]; then
	echo "FAIL: cannot find $TOOL_INSTALL" >&2
	exit 1
fi
if [[ ! -f "$SETUP_COMMON" ]]; then
	echo "FAIL: cannot find $SETUP_COMMON" >&2
	exit 1
fi

SANDBOX="$(mktemp -d -t t2891-XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "$SANDBOX/home" "$SANDBOX/bin" "$SANDBOX/npm-stub"
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

# Source tool-install.sh in a subshell with stubs. tool-install.sh is large
# (~1900 lines) so we extract just the three relevant functions to avoid
# pulling in unrelated dependencies.
extract_functions() {
	# Use awk to extract the three functions by name.
	awk '
		/^_setup_opencode_timeout_cmd\(\)/, /^}$/ { print; next }
		/^_setup_opencode_version_output\(\)/, /^}$/ { print; next }
		/^_setup_opencode_help_output\(\)/, /^}$/ { print; next }
		/^_setup_opencode_help_identifies_opencode\(\)/, /^}$/ { print; next }
		/^_setup_opencode_first_line\(\)/, /^}$/ { print; next }
		/^_setup_opencode_homebrew_owner_action\(\)/, /^}$/ { print; next }
		/^_setup_opencode_print_manual_install_hint\(\)/, /^}$/ { print; next }
		/^_setup_opencode_node_path_for_binary\(\)/, /^}$/ { print; next }
		/^_setup_opencode_binary_is_ephemeral\(\)/, /^}$/ { print; next }
		/^_setup_clear_canary_negative_cache\(\)/, /^}$/ { print; next }
		/^_setup_ensure_opencode_stable_shim\(\)/, /^}$/ { print; next }
		/^_setup_find_valid_opencode_binary\(\)/, /^}$/ { print; next }
		/^_setup_validate_opencode_binary\(\)/, /^}$/ { print; next }
		/^_setup_opencode_force_heal\(\)/, /^}$/ { print; next }
		/^setup_opencode_cli\(\)/, /^}$/ { print; next }
	' "$TOOL_INSTALL" >"$SANDBOX/extract.sh"
	# Verify extraction worked
	if ! grep -q "^_setup_validate_opencode_binary()" "$SANDBOX/extract.sh"; then
		echo "FAIL: extraction did not capture _setup_validate_opencode_binary" >&2
		exit 1
	fi
	return 0
}
extract_functions

extract_common_npm_global_install() {
	awk '
		/^_npm_global_install_via_npm\(\)/, /^}$/ { print; next }
		/^npm_global_install\(\)/, /^}$/ { print; next }
	' "$SETUP_COMMON" >"$SANDBOX/common-extract.sh"
	if ! grep -q "^_npm_global_install_via_npm()" "$SANDBOX/common-extract.sh" || \
		! grep -q "^npm_global_install()" "$SANDBOX/common-extract.sh"; then
		echo "FAIL: extraction did not capture npm_global_install" >&2
		exit 1
	fi
	return 0
}
extract_common_npm_global_install

source_extracted() {
	# shellcheck disable=SC2317
	print_info() { echo "INFO: $*"; return 0; }
	# shellcheck disable=SC2317
	print_success() { echo "OK: $*"; return 0; }
	# shellcheck disable=SC2317
	print_warning() { echo "WARN: $*"; return 0; }
	# shellcheck disable=SC2317
	setup_prompt() {
		local _var="$1"
		local _prompt="$2"
		local _default="$3"
		: "$_prompt"
		printf -v "$_var" '%s' "$_default"
		return $?
	}
	# shellcheck disable=SC2317
	run_with_spinner() { shift; "$@"; return $?; }
	# shellcheck disable=SC2317
	npm_global_install() {
		# Simulate install: drop a fake 'opencode' shim into the sandbox PATH
		# that returns a real-shaped opencode version.
		echo "[npm_global_install stub] $*" >&2
		cat >"$SANDBOX/bin/opencode" <<'INNER_EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "1.14.25"
[[ "${1:-}" == "--help" ]] && echo "opencode run [message..]     run opencode with a message"
exit 0
INNER_EOF
		chmod +x "$SANDBOX/bin/opencode"
		return 0
	}
	export -f print_info print_success print_warning setup_prompt run_with_spinner npm_global_install 2>/dev/null || true
	# shellcheck disable=SC1090
	source "$SANDBOX/extract.sh"
	return 0
}

# --- Test 1: validator on real opencode ------------------------------------
echo "Test 1: _setup_validate_opencode_binary on real opencode shim"
cat >"$SANDBOX/bin/opencode-real" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "1.14.25"
[[ "${1:-}" == "--help" ]] && echo "opencode run [message..]     run opencode with a message"
exit 0
EOF
chmod +x "$SANDBOX/bin/opencode-real"
(
	source_extracted
	rc=0
	_setup_validate_opencode_binary "$SANDBOX/bin/opencode-real" || rc=$?
	echo "$rc"
) >"$SANDBOX/out1" 2>&1
assert_eq "real opencode -> rc=0" "0" "$(tail -1 "$SANDBOX/out1")"

# --- Test 1b: validator accepts equivalent help formatting ------------------
echo "Test 1b: _setup_validate_opencode_binary accepts flexible help format"
cat >"$SANDBOX/bin/opencode-flex-help" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "1.14.25"
[[ "${1:-}" == "--help" ]] && printf '%s\n' "Usage: opencode run <message>" "Commands:" "  run  Execute a prompt"
exit 0
EOF
chmod +x "$SANDBOX/bin/opencode-flex-help"
(
	source_extracted
	rc=0
	_setup_validate_opencode_binary "$SANDBOX/bin/opencode-flex-help" || rc=$?
	echo "$rc"
) >"$SANDBOX/out1b" 2>&1
assert_eq "flex help opencode -> rc=0" "0" "$(tail -1 "$SANDBOX/out1b")"

# --- Test 1c: PATH helpers reject relative bin dirs and empty PATH colons ----
echo "Test 1c: _setup_opencode_node_path_for_binary avoids relative PATH entries"
(
	source_extracted
	_setup_opencode_node_path_for_binary "opencode"
) >"$SANDBOX/out1c" 2>&1
relative_path_value=$(tail -1 "$SANDBOX/out1c")
case "$relative_path_value" in
	.* | *:.:* | *:.) assert_eq "relative bin dir omitted from PATH" "no-relative" "relative" ;;
	*) assert_eq "relative bin dir omitted from PATH" "no-relative" "no-relative" ;;
esac

echo "Test 1d: _setup_opencode_help_output avoids trailing colon with empty PATH"
cat >"$SANDBOX/bin/opencode-path-check" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]]; then
	[[ "$PATH" == *: ]] && exit 42
	echo "opencode run [message..]     run opencode with a message"
	exit 0
fi
exit 0
EOF
chmod +x "$SANDBOX/bin/opencode-path-check"
(
	source_extracted
	PATH="" _setup_opencode_help_output "$SANDBOX/bin/opencode-path-check"
) >"$SANDBOX/out1d" 2>&1 || rc1d=$?
assert_eq "empty PATH expansion has no trailing colon" "0" "${rc1d:-0}"

# --- Test 2: validator on claude CLI shim ----------------------------------
echo "Test 2: _setup_validate_opencode_binary on claude CLI shim"
cat >"$SANDBOX/bin/opencode-claude" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "2.1.119 (Claude Code)"
[[ "${1:-}" == "--help" ]] && echo "Claude Code"
EOF
chmod +x "$SANDBOX/bin/opencode-claude"
(
	source_extracted
	rc=0
	_setup_validate_opencode_binary "$SANDBOX/bin/opencode-claude" || rc=$?
	echo "$rc"
) >"$SANDBOX/out2" 2>&1
assert_eq "claude shim -> rc=1" "1" "$(tail -1 "$SANDBOX/out2")"

# --- Test 2b: validator rejects multi-digit non-opencode majors ------------
echo "Test 2b: _setup_validate_opencode_binary rejects major >=10"
cat >"$SANDBOX/bin/opencode-major10" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "10.0.0"
[[ "${1:-}" == "--help" ]] && echo "opencode run [message..]     run opencode with a message"
EOF
chmod +x "$SANDBOX/bin/opencode-major10"
(
	source_extracted
	rc=0
	_setup_validate_opencode_binary "$SANDBOX/bin/opencode-major10" || rc=$?
	echo "$rc"
) >"$SANDBOX/out2b" 2>&1
assert_eq "major 10 shim -> rc=1" "1" "$(tail -1 "$SANDBOX/out2b")"

# --- Test 2c: validator rejects Qwen Code semver-compatible output ----------
echo "Test 2c: _setup_validate_opencode_binary rejects qwen CLI shim"
cat >"$SANDBOX/bin/opencode-qwen" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "0.2.1"
[[ "${1:-}" == "--help" ]] && echo "Qwen Code - Launch an interactive CLI"
EOF
chmod +x "$SANDBOX/bin/opencode-qwen"
(
	source_extracted
	rc=0
	_setup_validate_opencode_binary "$SANDBOX/bin/opencode-qwen" || rc=$?
	echo "$rc"
) >"$SANDBOX/out2c" 2>&1
assert_eq "qwen shim -> rc=1" "1" "$(tail -1 "$SANDBOX/out2c")"

# --- Test 3: validator on missing path -------------------------------------
echo "Test 3: _setup_validate_opencode_binary on missing path"
(
	source_extracted
	rc=0
	_setup_validate_opencode_binary "$SANDBOX/bin/does-not-exist" || rc=$?
	echo "$rc"
) >"$SANDBOX/out3" 2>&1
assert_eq "missing path -> rc=2" "2" "$(tail -1 "$SANDBOX/out3")"

# --- Test 3b: validator bounds hanging --version ---------------------------
echo "Test 3b: _setup_validate_opencode_binary bounds hanging --version"
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
	source_extracted
	export AIDEVOPS_OPENCODE_VERSION_TIMEOUT=1
	SECONDS=0
	rc=0
	_setup_validate_opencode_binary "$SANDBOX/bin/opencode-slow" || rc=$?
	printf 'rc=%s elapsed=%s\n' "$rc" "$SECONDS"
) >"$SANDBOX/out3b" 2>&1
rc3b=$(grep '^rc=' "$SANDBOX/out3b" | tail -1)
elapsed3b="${rc3b##*elapsed=}"
rc3b="${rc3b%% elapsed=*}"
assert_eq "hanging version -> rc=2" "rc=2" "$rc3b"
if [[ "$elapsed3b" =~ ^[0-9]+$ ]] && [[ "$elapsed3b" -le 3 ]]; then
	assert_eq "hanging version returns within bound" "bounded" "bounded"
else
	assert_eq "hanging version returns within bound" "elapsed<=3" "elapsed=${elapsed3b}"
fi

# --- Test 4: setup_opencode_cli skip when valid + persists path ------------
echo "Test 4: setup_opencode_cli skip-when-valid path"
rm -f "$HOME/.aidevops/.opencode-bin-resolved"
cp "$SANDBOX/bin/opencode-real" "$SANDBOX/bin/opencode"
(
	source_extracted
	export PATH="$SANDBOX/bin:$PATH"
	rc=0
	setup_opencode_cli || rc=$?
	echo "rc=$rc"
	cat "$HOME/.aidevops/.opencode-bin-resolved" 2>/dev/null || echo "MISSING"
) >"$SANDBOX/out4" 2>&1
rc4=$(grep '^rc=' "$SANDBOX/out4" | tail -1)
resolved4=$(tail -1 "$SANDBOX/out4")
assert_eq "skip-when-valid rc" "rc=0" "$rc4"
assert_eq "skip-when-valid resolved-path file" "$HOME/.local/bin/opencode" "$resolved4"

# --- Test 4b: setup_opencode_cli accepts valid Homebrew opencode ------------
echo "Test 4b: setup_opencode_cli accepts valid Homebrew opencode"
rm -f "$HOME/.aidevops/.opencode-bin-resolved"
mkdir -p "$SANDBOX/homebrew/bin"
cp "$SANDBOX/bin/opencode-real" "$SANDBOX/homebrew/bin/opencode"
(
	source_extracted
	export PATH="$SANDBOX/homebrew/bin:$PATH"
	npm_global_install() {
		printf '%s\n' "unexpected npm_global_install $*" >&2
		return 1
	}
	export -f npm_global_install 2>/dev/null || true
	rc=0
	setup_opencode_cli || rc=$?
	echo "rc=$rc"
	cat "$HOME/.aidevops/.opencode-bin-resolved" 2>/dev/null || echo "MISSING"
) >"$SANDBOX/out4b" 2>&1
rc4b=$(grep '^rc=' "$SANDBOX/out4b" | tail -1)
resolved4b=$(tail -1 "$SANDBOX/out4b")
homebrew_install_invoked=$(grep -c "unexpected npm_global_install" "$SANDBOX/out4b" || true)
homebrew_sudo_hint=$(grep -c "sudo npm install" "$SANDBOX/out4b" || true)
assert_eq "valid Homebrew opencode rc" "rc=0" "$rc4b"
assert_eq "valid Homebrew opencode resolved" "$HOME/.local/bin/opencode" "$resolved4b"
assert_eq "valid Homebrew opencode avoids installer" "0" "$homebrew_install_invoked"
assert_eq "valid Homebrew opencode avoids sudo npm hint" "0" "$homebrew_sudo_hint"

# --- Test 5: setup_opencode_cli auto-heal on wrong package -----------------
# Critical t2891 path: when 'opencode' resolves to claude CLI (rc=1),
# the function MUST trigger force-heal (calls npm_global_install) and
# NOT return early like the pre-fix code did.
echo "Test 5: setup_opencode_cli force-heal on claude CLI shim"
rm -f "$HOME/.aidevops/.opencode-bin-resolved"
cp "$SANDBOX/bin/opencode-claude" "$SANDBOX/bin/opencode"
(
	source_extracted
	export PATH="$SANDBOX/bin:$PATH"
	rc=0
	setup_opencode_cli || rc=$?
	echo "rc=$rc"
) >"$SANDBOX/out5" 2>&1
rc5=$(grep '^rc=' "$SANDBOX/out5" | tail -1)
heal_warned=$(grep -c "wrong package" "$SANDBOX/out5" || true)
heal_invoked=$(grep -c "npm_global_install stub" "$SANDBOX/out5" || true)
post_heal_success=$(grep -c "OpenCode CLI:.*1\.14\.25" "$SANDBOX/out5" || true)
assert_eq "force-heal rc" "rc=0" "$rc5"
assert_eq "force-heal warned about wrong package" "1" "$heal_warned"
assert_eq "force-heal invoked installer" "1" "$heal_invoked"
assert_eq "post-heal validation success" "1" "$post_heal_success"

# --- Test 6: post-heal persists resolved path ------------------------------
echo "Test 6: post-heal persisted resolved path"
[[ -f "$HOME/.aidevops/.opencode-bin-resolved" ]] && resolved6=$(cat "$HOME/.aidevops/.opencode-bin-resolved") || resolved6="MISSING"
assert_eq "post-heal resolved-path file populated" "$HOME/.local/bin/opencode" "$resolved6"

# --- Test 6b: bad stable shim is rewritten from another valid install -------
echo "Test 6b: setup_opencode_cli rewrites qwen stable shim from valid bun install"
rm -f "$HOME/.aidevops/.opencode-bin-resolved"
mkdir -p "$HOME/.local/bin" "$HOME/.bun/bin"
cp "$SANDBOX/bin/opencode-qwen" "$HOME/.local/bin/opencode"
cp "$SANDBOX/bin/opencode-real" "$HOME/.bun/bin/opencode"
(
	source_extracted
	export PATH="$HOME/.local/bin:$HOME/.bun/bin:$PATH"
	rc=0
	setup_opencode_cli || rc=$?
	echo "rc=$rc"
	cat "$HOME/.aidevops/.opencode-bin-resolved" 2>/dev/null || echo "MISSING"
) >"$SANDBOX/out6b" 2>&1
rc6b=$(grep '^rc=' "$SANDBOX/out6b" | tail -1)
resolved6b=$(tail -1 "$SANDBOX/out6b")
assert_eq "qwen stable shim heal rc" "rc=0" "$rc6b"
assert_eq "qwen stable shim rewritten" "$HOME/.local/bin/opencode" "$resolved6b"
if "$HOME/.local/bin/opencode" --help 2>/dev/null | grep -q 'opencode run \[message\.\.\]'; then
	assert_eq "qwen shim now points to valid opencode" "rewritten" "rewritten"
else
	assert_eq "qwen shim now points to valid opencode" "rewritten" "not-rewritten"
fi

# --- Test 7: auto-heal bounds hanging installer ----------------------------
echo "Test 7: setup_opencode_cli bounds hanging auto-heal installer"
rm -f "$HOME/.aidevops/.opencode-bin-resolved"
rm -f "$HOME/.bun/bin/opencode"
cp "$SANDBOX/bin/opencode-claude" "$SANDBOX/bin/opencode"
(
	source_extracted
	npm_global_install() {
		sleep 5
		return 0
	}
	export -f npm_global_install 2>/dev/null || true
	export PATH="$SANDBOX/bin:$PATH"
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
assert_eq "hanging auto-heal fail-opens" "rc=0" "$rc7"
if [[ "$elapsed7" =~ ^[0-9]+$ ]] && [[ "$elapsed7" -le 12 ]]; then
	assert_eq "hanging auto-heal returns within bound" "bounded" "bounded"
else
	assert_eq "hanging auto-heal returns within bound" "elapsed<=12" "elapsed=${elapsed7}"
fi

# --- Test 7b: first install chooses npm when npm and bun are both present ----
echo "Test 7b: setup_opencode_cli first install prompt prefers npm over bun"
rm -f "$HOME/.aidevops/.opencode-bin-resolved" "$SANDBOX/bin/opencode"
cat >"$SANDBOX/bin/npm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat >"$SANDBOX/bin/bun" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SANDBOX/bin/npm" "$SANDBOX/bin/bun"
(
	source_extracted
	setup_prompt() {
		local _var="$1"
		local _prompt="$2"
		local _default="$3"
		printf '%s\n' "$_prompt"
		printf -v "$_var" '%s' "$_default"
		return $?
	}
	export -f setup_prompt 2>/dev/null || true
	export PATH="$SANDBOX/bin:/usr/bin:/bin"
	rc=0
	setup_opencode_cli || rc=$?
	echo "rc=$rc"
) >"$SANDBOX/out7b" 2>&1
rc7b=$(grep '^rc=' "$SANDBOX/out7b" | tail -1)
npm_prompt7b=$(grep -c "Install OpenCode via npm" "$SANDBOX/out7b" || true)
bun_prompt7b=$(grep -c "Install OpenCode via bun" "$SANDBOX/out7b" || true)
assert_eq "first install npm+bun rc" "rc=0" "$rc7b"
assert_eq "first install prompt uses npm" "1" "$npm_prompt7b"
assert_eq "first install prompt avoids bun" "0" "$bun_prompt7b"

# --- Test 8: install failure hint matches selected installer -----------------
echo "Test 8: setup_opencode_cli install failure omits hard-coded sudo npm hint"
rm -f "$HOME/.aidevops/.opencode-bin-resolved" "$SANDBOX/bin/opencode" "$SANDBOX/bin/bun"
cat >"$SANDBOX/bin/npm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SANDBOX/bin/npm"
(
	source_extracted
	npm_global_install() {
		printf '%s\n' "installer failed: permission denied" >&2
		return 1
	}
	export -f npm_global_install 2>/dev/null || true
	export PATH="$SANDBOX/bin:/usr/bin:/bin"
	rc=0
	setup_opencode_cli || rc=$?
	echo "rc=$rc"
) >"$SANDBOX/out8" 2>&1
rc8=$(grep '^rc=' "$SANDBOX/out8" | tail -1)
sudo_hint8=$(grep -c "sudo npm install" "$SANDBOX/out8" || true)
npm_hint8=$(grep -c "Try manually: npm install -g opencode-ai" "$SANDBOX/out8" || true)
assert_eq "install failure rc" "rc=0" "$rc8"
assert_eq "install failure has no sudo npm hint" "0" "$sudo_hint8"
assert_eq "install failure uses npm hint" "1" "$npm_hint8"

# --- Test 9: Homebrew-owned invalid binary gets brew remediation ------------
echo "Test 9: setup_opencode_cli failure hint respects Homebrew ownership"
rm -f "$HOME/.aidevops/.opencode-bin-resolved" "$SANDBOX/bin/opencode"
mkdir -p "$SANDBOX/homebrew/bin" "$SANDBOX/homebrew/Cellar/opencode/1.0.0/bin"
cat >"$SANDBOX/homebrew/bin/opencode" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "--version" ]] && echo "not-a-version"
[[ "${1:-}" == "--help" ]] && echo "not opencode"
exit 0
EOF
chmod +x "$SANDBOX/homebrew/bin/opencode"
cat >"$SANDBOX/bin/brew" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "--prefix" && "\${2:-}" == "opencode" ]]; then
	printf '%s\n' "$SANDBOX/homebrew"
	exit 0
fi
if [[ "\${1:-}" == "--prefix" ]]; then
	printf '%s\n' "$SANDBOX/homebrew"
	exit 0
fi
exit 1
EOF
chmod +x "$SANDBOX/bin/brew"
(
	source_extracted
	npm_global_install() { return 1; }
	export -f npm_global_install 2>/dev/null || true
	export PATH="$SANDBOX/homebrew/bin:$SANDBOX/bin:/usr/bin:/bin"
	rc=0
	setup_opencode_cli || rc=$?
	echo "rc=$rc"
) >"$SANDBOX/out9" 2>&1
rc9=$(grep '^rc=' "$SANDBOX/out9" | tail -1)
brew_hint9=$(grep -c "brew reinstall opencode" "$SANDBOX/out9" || true)
sudo_hint9=$(grep -c "sudo npm install" "$SANDBOX/out9" || true)
assert_eq "homebrew remediation rc" "rc=0" "$rc9"
assert_eq "homebrew remediation uses brew" "1" "$brew_hint9"
assert_eq "homebrew remediation has no sudo npm hint" "0" "$sudo_hint9"

# --- Test 10: shared installer policy uses npm first for OpenCode -----------
echo "Test 10: npm_global_install prefers npm for opencode-ai when bun also exists"
mkdir -p "$SANDBOX/install-policy/bin" "$SANDBOX/install-policy/prefix/lib"
cat >"$SANDBOX/install-policy/bin/npm" <<EOF
#!/usr/bin/env bash
if [[ "\${1:-}" == "config" && "\${2:-}" == "get" && "\${3:-}" == "prefix" ]]; then
	printf '%s\n' "$SANDBOX/install-policy/prefix"
	exit 0
fi
printf 'npm %s\n' "\$*" >>"$SANDBOX/install-policy/calls"
exit 0
EOF
cat >"$SANDBOX/install-policy/bin/bun" <<EOF
#!/usr/bin/env bash
printf 'bun %s\n' "\$*" >>"$SANDBOX/install-policy/calls"
exit 0
EOF
chmod +x "$SANDBOX/install-policy/bin/npm" "$SANDBOX/install-policy/bin/bun"
(
	# shellcheck source=/dev/null
	source "$SANDBOX/common-extract.sh"
	export PATH="$SANDBOX/install-policy/bin:/usr/bin:/bin"
	npm_global_install opencode-ai@latest
) >"$SANDBOX/out10" 2>&1
assert_eq "opencode-ai with npm+bun uses npm" "npm install -g opencode-ai@latest" "$(cat "$SANDBOX/install-policy/calls")"

echo "Test 10b: npm_global_install keeps bun-first policy for other packages"
rm -f "$SANDBOX/install-policy/calls"
(
	# shellcheck source=/dev/null
	source "$SANDBOX/common-extract.sh"
	export PATH="$SANDBOX/install-policy/bin:/usr/bin:/bin"
	npm_global_install serve-sim@latest
) >"$SANDBOX/out10b" 2>&1
assert_eq "generic packages still use bun first" "bun install -g serve-sim@latest" "$(cat "$SANDBOX/install-policy/calls")"

echo "Test 10c: npm_global_install falls back to bun for opencode-ai without npm"
rm -f "$SANDBOX/install-policy/calls" "$SANDBOX/install-policy/bin/npm"
ln -sf /bin/bash "$SANDBOX/install-policy/bin/bash"
(
	# shellcheck source=/dev/null
	source "$SANDBOX/common-extract.sh"
	export PATH="$SANDBOX/install-policy/bin"
	npm_global_install opencode-ai@latest
) >"$SANDBOX/out10c" 2>&1
assert_eq "opencode-ai bun-only fallback" "bun install -g opencode-ai@latest" "$(cat "$SANDBOX/install-policy/calls")"

echo "Test 11: stable shim rejects ephemeral target for persistent HOME"
mkdir -p "$SANDBOX/ephemeral/bin" "$SANDBOX/persistent-home"
cat >"$SANDBOX/ephemeral/bin/opencode" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
--version) printf '1.18.9\n' ;;
--help) printf 'opencode run [message]\n' ;;
*) printf 'stub\n' ;;
esac
EOF
chmod +x "$SANDBOX/ephemeral/bin/opencode"
shim_rc=0
(
	source_extracted
	export HOME="$SANDBOX/persistent-home"
	_setup_opencode_binary_is_ephemeral() {
		local bin="$1"
		case "$bin" in
		"$SANDBOX/ephemeral"/*) return 0 ;;
		"$SANDBOX/persistent-home/.aidevops-home") return 1 ;;
		*) return 1 ;;
		esac
	}
	_setup_ensure_opencode_stable_shim "$SANDBOX/ephemeral/bin/opencode"
) >"$SANDBOX/ephemeral/stdout" 2>"$SANDBOX/ephemeral/stderr" || shim_rc=$?
assert_eq "ephemeral target rejected" "1" "$shim_rc"
if [[ -e "$SANDBOX/persistent-home/.local/bin/opencode" ]]; then
	assert_eq "ephemeral rejection avoids shim write" "absent" "present"
else
	assert_eq "ephemeral rejection avoids shim write" "absent" "absent"
fi

echo "Test 12: stable shim repairs terminal-title ownership and preserves overrides"
shim_home="$SANDBOX/shim-home"
real_dir="$SANDBOX/stable-opencode/bin"
shim_path="$shim_home/.local/bin/opencode"
mkdir -p "$real_dir" "$(dirname "$shim_path")"
cat >"$real_dir/opencode" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
--version) printf '1.18.9\n' ;;
--help) printf 'opencode run [message]\n' ;;
env-check) printf '%s|%s\n' "${AIDEVOPS_TERMINAL_TITLE_OWNER:-}" "${OPENCODE_DISABLE_TERMINAL_TITLE:-}" ;;
esac
EOF
chmod +x "$real_dir/opencode"
cat >"$shim_path" <<EOF
#!/usr/bin/env bash
# Generated by aidevops setup: daemon-safe OpenCode shim.
exec "$real_dir/opencode" "\$@"
EOF
chmod +x "$shim_path"
(
	source_extracted
	export HOME="$shim_home"
	export PATH="$real_dir:$PATH"
	_setup_opencode_binary_is_ephemeral() { return 1; }
	_setup_ensure_opencode_stable_shim "$shim_path"
) >"$SANDBOX/out12" 2>&1
assert_eq "old managed shim is repaired" "$shim_path" "$(tail -1 "$SANDBOX/out12")"
if grep -Fq '# aidevops:terminal-title-owner' "$shim_path"; then
	assert_eq "repaired shim records title ownership" "present" "present"
else
	assert_eq "repaired shim records title ownership" "present" "absent"
fi
assert_eq "repaired shim defaults to aidevops ownership" "aidevops|1" "$(env -u AIDEVOPS_TERMINAL_TITLE_OWNER -u OPENCODE_DISABLE_TERMINAL_TITLE "$shim_path" env-check)"
assert_eq "repaired shim preserves explicit OpenCode title flag" "aidevops|false" "$(OPENCODE_DISABLE_TERMINAL_TITLE=false "$shim_path" env-check)"
assert_eq "native owner leaves OpenCode title writer enabled" "native|" "$(env -u OPENCODE_DISABLE_TERMINAL_TITLE AIDEVOPS_TERMINAL_TITLE_OWNER=native "$shim_path" env-check)"
shim_checksum=$(cksum "$shim_path")
(
	source_extracted
	export HOME="$shim_home"
	export PATH="$real_dir:$PATH"
	_setup_opencode_binary_is_ephemeral() { return 1; }
	_setup_ensure_opencode_stable_shim "$shim_path"
) >/dev/null 2>&1
assert_eq "title-owning shim regeneration is idempotent" "$shim_checksum" "$(cksum "$shim_path")"

echo ""
echo "===== Results: $PASS passed, $FAIL failed ====="
[[ $FAIL -eq 0 ]] || exit 1
exit 0
