#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-repo-verify-pre-push-hook.sh — End-to-end tests for the t3224 repo-verify
# pre-push hook (.agents/hooks/repo-verify-pre-push.sh).
#
# Verifies:
#   1. AIDEVOPS_PREPUSH_REPO_VERIFY=0 short-circuits to exit 0
#   2. GITHUB_ACTIONS=true short-circuits to exit 0
#   3. Outside a git repo: exit 0 (no-op)
#  3b. HOME unset does not trigger a set -u failure
#   4. No verify config anywhere: silent skip (exit 0)
#   5. .aidevops.json `.verify.enabled=false` opts out (exit 0)
#   6. .aidevops.json with a passing format command: exit 0
#   7. .aidevops.json with a failing format command, autofix off, mentor exit 1
#   8. .aidevops.json with failing format + AUTOFIX=1 + working fix command: exit 0
#   9. package.json detection: pnpm-lock.yaml chooses 'pnpm run ...'
#  10. package.json: format:fix script is preferred over format_fix
#  11. defaults conf: Cargo.toml triggers RUST_CARGO toolchain (cargo fmt --check)
#  12. typecheck failure NEVER auto-fixes — exit 1 even with AUTOFIX=1
#  13. Missing bun-installed tsc is diagnosed as missing dev dependencies
#  14. Proven task-id counter-only CAS push skips a missing TypeScript install
#  15. Mixed-file task-id-counter push falls back to repository verification
#  16. Normal-branch counter-only push falls back to repository verification
#  17. Working tree dirty: warn + skip (exit 0)
#  18. shellcheck on the hook itself
#
# Tests are hermetic: each scenario builds a temporary git repo and invokes
# the hook as a subprocess. No network, no live GitHub API, no aidevops state.

set -u

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

# Resolve hook path against this test file's location (worktree-aware)
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="${SCRIPT_DIR}/../../hooks/repo-verify-pre-push.sh"

if [[ ! -f "$HOOK" ]]; then
	echo "FATAL: hook not found at $HOOK" >&2
	exit 2
fi

# Some installers may have stripped +x; ensure the hook is executable for
# subprocess invocation. We invoke via `bash` explicitly anyway, but a sane
# +x bit also pleases shellcheck and matches deployed state.
chmod +x "$HOOK" 2>/dev/null || true

# ----- helpers ------------------------------------------------------------

assert_eq() {
	local _label="$1"
	local _expected="$2"
	local _actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$_expected" == "$_actual" ]]; then
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$_label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$_label"
		printf '  expected: %s\n' "$_expected"
		printf '  got:      %s\n' "$_actual"
	fi
	return 0
}

assert_contains() {
	local _label="$1"
	local _needle="$2"
	local _haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$_haystack" | grep -qF -- "$_needle" 2>/dev/null; then
		printf '%sPASS%s: %s\n' "$TEST_GREEN" "$TEST_NC" "$_label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: %s\n' "$TEST_RED" "$TEST_NC" "$_label"
		printf '  expected to find: %s\n' "$_needle"
		printf '  in stderr (last 200 chars): %s\n' "${_haystack:0:200}"
	fi
	return 0
}

# Build a fresh temp git repo, return its path on stdout.
_mk_repo() {
	local _dir
	_dir=$(mktemp -d -t aidevops-prepush-test.XXXXXX)
	(
		cd "$_dir" || exit 1
		/usr/bin/git init -q
		/usr/bin/git config user.email "test@example.com"
		/usr/bin/git config user.name "Test"
		/usr/bin/git config commit.gpgsign false
		printf 'placeholder\n' >.gitkeep
		/usr/bin/git add .gitkeep
		/usr/bin/git commit -q -m 'initial'
	) >/dev/null
	printf '%s\n' "$_dir"
	return 0
}

# Run the hook against $1=repo dir with extra env from $2..., capture exit + stderr.
# Stdout: <exit_code>\n<stderr_blob>
_run_hook() {
	local _repo="$1"
	shift
	local _stdin_data="${HOOK_STDIN:-}"
	local _err
	_err=$(mktemp -t aidevops-prepush-test-stderr.XXXXXX)
	local _ec=0
	(
		cd "$_repo" || exit 1
		# shellcheck disable=SC2068
		# Intentional unquoted expansion: each arg is a 'KEY=value' env assignment
		env -u FULL_LOOP_HEADLESS -u AIDEVOPS_HEADLESS -u OPENCODE_HEADLESS \
			-u AIDEVOPS_PREPUSH_AUTOFIX -u AIDEVOPS_PREPUSH_REPO_VERIFY \
			-u AIDEVOPS_PREPUSH_REPO_VERIFY_DEBUG -u GITHUB_ACTIONS \
			PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" $@ bash "$HOOK" <<<"$_stdin_data"
	) 2>"$_err"
	_ec=$?
	printf '%s\n' "$_ec"
	cat "$_err"
	rm -f "$_err"
	return 0
}

# ----- tests --------------------------------------------------------------

echo "${TEST_BLUE}=== test-repo-verify-pre-push-hook.sh (t3224) ===${TEST_NC}"

# Test 1: AIDEVOPS_PREPUSH_REPO_VERIFY=0 — fast bypass
{
	repo=$(_mk_repo)
	out=$(_run_hook "$repo" AIDEVOPS_PREPUSH_REPO_VERIFY=0)
	ec=$(printf '%s' "$out" | head -n 1)
	assert_eq '1. AIDEVOPS_PREPUSH_REPO_VERIFY=0 → exit 0' '0' "$ec"
	rm -rf "$repo"
}

# Test 2: GITHUB_ACTIONS=true — CI runs verify itself
{
	repo=$(_mk_repo)
	out=$(_run_hook "$repo" GITHUB_ACTIONS=true)
	ec=$(printf '%s' "$out" | head -n 1)
	assert_eq '2. GITHUB_ACTIONS=true → exit 0' '0' "$ec"
	rm -rf "$repo"
}

# Test 3: outside a git repo
{
	non_repo=$(mktemp -d -t aidevops-nonrepo.XXXXXX)
	out=$(_run_hook "$non_repo")
	ec=$(printf '%s' "$out" | head -n 1)
	assert_eq '3. outside git repo → exit 0' '0' "$ec"
	rm -rf "$non_repo"
}

# Test 3b: HOME may be absent in restricted hook environments
{
	repo=$(_mk_repo)
	(
		cd "$repo" || exit 1
		env -u HOME PATH="/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin" bash "$HOOK" </dev/null
	) >/dev/null 2>&1
	ec=$?
	assert_eq '3b. HOME unset → exit 0' '0' "$ec"
	rm -rf "$repo"
}

# Test 4: no verify config of any kind
{
	repo=$(_mk_repo)
	out=$(_run_hook "$repo" AIDEVOPS_PREPUSH_REPO_VERIFY_DEBUG=1)
	ec=$(printf '%s' "$out" | head -n 1)
	stderr=$(printf '%s' "$out" | tail -n +2)
	assert_eq '4. no config → exit 0 (silent skip)' '0' "$ec"
	assert_contains '4b. no config → debug mentions skip' 'skipping' "$stderr"
	rm -rf "$repo"
}

# Test 5: .aidevops.json explicit opt-out
{
	repo=$(_mk_repo)
	cat >"$repo/.aidevops.json" <<'JSON'
{ "verify": { "enabled": false, "format": "false" } }
JSON
	(cd "$repo" && /usr/bin/git add .aidevops.json && /usr/bin/git commit -q -m 'add config')
	out=$(_run_hook "$repo")
	ec=$(printf '%s' "$out" | head -n 1)
	stderr=$(printf '%s' "$out" | tail -n +2)
	assert_eq '5. enabled:false → exit 0' '0' "$ec"
	assert_contains '5b. enabled:false → opt-out logged' 'opts out' "$stderr"
	rm -rf "$repo"
}

# Test 6: .aidevops.json with a trivially passing format command
{
	repo=$(_mk_repo)
	cat >"$repo/.aidevops.json" <<'JSON'
{ "verify": { "format": "true" } }
JSON
	(cd "$repo" && /usr/bin/git add .aidevops.json && /usr/bin/git commit -q -m 'add config')
	out=$(_run_hook "$repo")
	ec=$(printf '%s' "$out" | head -n 1)
	stderr=$(printf '%s' "$out" | tail -n +2)
	assert_eq '6. passing format → exit 0' '0' "$ec"
	assert_contains '6b. passing format → success log' 'all verify checks passed' "$stderr"
	rm -rf "$repo"
}

# Test 7: .aidevops.json failing format, no autofix command, AUTOFIX=0 → mentor + block
{
	repo=$(_mk_repo)
	cat >"$repo/.aidevops.json" <<'JSON'
{ "verify": { "format": "false" } }
JSON
	(cd "$repo" && /usr/bin/git add .aidevops.json && /usr/bin/git commit -q -m 'add config')
	out=$(_run_hook "$repo" AIDEVOPS_PREPUSH_AUTOFIX=0)
	ec=$(printf '%s' "$out" | head -n 1)
	stderr=$(printf '%s' "$out" | tail -n +2)
	assert_eq '7. failing format + autofix off → exit 1' '1' "$ec"
	assert_contains '7b. failure mentor: resolution section' 'Resolution:' "$stderr"
	assert_contains '7c. failure mentor: bypass hint' 'AIDEVOPS_PREPUSH_REPO_VERIFY=0' "$stderr"
	rm -rf "$repo"
}

# Test 8: failing format + autofix command that "fixes" by replacing config → exit 0
{
	repo=$(_mk_repo)
	# format fails on first call. fix_cmd makes format pass on the next call by
	# replacing the config. We run AUTOFIX=1 so the hook should run fix, amend,
	# re-check, and pass.
	cat >"$repo/.aidevops.json" <<'JSON'
{ "verify": { "format": "test ! -f .needs-fmt", "format_fix": "rm -f .needs-fmt" } }
JSON
	touch "$repo/.needs-fmt"
	(cd "$repo" && /usr/bin/git add .aidevops.json .needs-fmt && /usr/bin/git commit -q -m 'add config + sentinel')
	out=$(_run_hook "$repo" AIDEVOPS_PREPUSH_AUTOFIX=1)
	ec=$(printf '%s' "$out" | head -n 1)
	stderr=$(printf '%s' "$out" | tail -n +2)
	assert_eq '8. autofix amends + recheck passes → exit 0' '0' "$ec"
	assert_contains '8b. autofix log: amended into HEAD' 'amended into HEAD' "$stderr"
	rm -rf "$repo"
}

# Test 9: package.json + pnpm-lock.yaml → 'pnpm run lint'
{
	repo=$(_mk_repo)
	cat >"$repo/package.json" <<'JSON'
{ "name": "fixture", "scripts": { "lint": "false" } }
JSON
	touch "$repo/pnpm-lock.yaml"
	(cd "$repo" && /usr/bin/git add . && /usr/bin/git commit -q -m 'add pkg + lock')
	# Use debug to surface 'pm=pnpm' in stderr
	out=$(_run_hook "$repo" AIDEVOPS_PREPUSH_REPO_VERIFY_DEBUG=1 AIDEVOPS_PREPUSH_AUTOFIX=0)
	stderr=$(printf '%s' "$out" | tail -n +2)
	assert_contains '9. package.json + pnpm-lock → pm=pnpm' 'package-json(pnpm)' "$stderr"
	assert_contains '9b. package.json → "pnpm run lint" command echoed' 'pnpm run lint' "$stderr"
	rm -rf "$repo"
}

# Test 10: format:fix is preferred over format_fix
{
	repo=$(_mk_repo)
	cat >"$repo/package.json" <<'JSON'
{ "name": "fixture", "scripts": {
	"format:check": "false",
	"format:fix": "echo USED_COLON",
	"format_fix": "echo USED_UNDER"
} }
JSON
	touch "$repo/pnpm-lock.yaml"
	(cd "$repo" && /usr/bin/git add . && /usr/bin/git commit -q -m 'add pkg')
	# AUTOFIX=1 + failing format → hook should invoke format_fix. We expect
	# 'USED_COLON' (preferred), not 'USED_UNDER'.
	out=$(_run_hook "$repo" AIDEVOPS_PREPUSH_AUTOFIX=1 AIDEVOPS_PREPUSH_REPO_VERIFY_DEBUG=1)
	stderr=$(printf '%s' "$out" | tail -n +2)
	# Hook's autofix log line names the chosen fix command
	assert_contains '10. format:fix preferred over format_fix' 'pnpm run format:fix' "$stderr"
	rm -rf "$repo"
}

# Test 11: defaults conf — Cargo.toml triggers RUST_CARGO
{
	repo=$(_mk_repo)
	# Minimal Cargo.toml; we don't care if cargo is installed. The hook will
	# attempt 'cargo fmt -- --check' which fails fast (cargo not present in
	# CI) — we only assert the toolchain RUST_CARGO got matched.
	cat >"$repo/Cargo.toml" <<'TOML'
[package]
name = "fixture"
version = "0.0.1"
TOML
	(cd "$repo" && /usr/bin/git add Cargo.toml && /usr/bin/git commit -q -m 'add cargo')
	out=$(_run_hook "$repo" AIDEVOPS_PREPUSH_REPO_VERIFY_DEBUG=1 AIDEVOPS_PREPUSH_AUTOFIX=0)
	stderr=$(printf '%s' "$out" | tail -n +2)
	assert_contains '11. Cargo.toml → defaults RUST_CARGO matched' 'defaults(RUST_CARGO)' "$stderr"
	rm -rf "$repo"
}

# Test 12: typecheck NEVER autofixes
{
	repo=$(_mk_repo)
	cat >"$repo/.aidevops.json" <<'JSON'
{ "verify": { "typecheck": "false" } }
JSON
	(cd "$repo" && /usr/bin/git add .aidevops.json && /usr/bin/git commit -q -m 'add config')
	# AUTOFIX=1 — but the hook still must NOT invoke an autofix for typecheck.
	out=$(_run_hook "$repo" AIDEVOPS_PREPUSH_AUTOFIX=1)
	ec=$(printf '%s' "$out" | head -n 1)
	stderr=$(printf '%s' "$out" | tail -n +2)
	assert_eq '12. typecheck failure → exit 1 even with AUTOFIX=1' '1' "$ec"
	# Confirm no "amended into HEAD" — autofix path must not have run
	if printf '%s' "$stderr" | grep -qF 'amended into HEAD' 2>/dev/null; then
		TESTS_RUN=$((TESTS_RUN + 1))
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: 12b. typecheck must NOT autofix\n' "$TEST_RED" "$TEST_NC"
		printf '  found "amended into HEAD" in stderr\n'
	else
		TESTS_RUN=$((TESTS_RUN + 1))
		printf '%sPASS%s: 12b. typecheck did not autofix\n' "$TEST_GREEN" "$TEST_NC"
	fi
	rm -rf "$repo"
}

# Test 13: missing bun-installed tsc → dependency remediation
{
	repo=$(_mk_repo)
	cat >"$repo/.aidevops.json" <<'JSON'
{ "verify": { "typecheck": "echo 'tsc: command not found' >&2; false" } }
JSON
	cat >"$repo/package.json" <<'JSON'
{ "name": "fixture", "devDependencies": { "typescript": "^5.0.0" } }
JSON
	printf '{}\n' >"$repo/bun.lock"
	(cd "$repo" && /usr/bin/git add . && /usr/bin/git commit -q -m 'add bun typecheck fixture')
	out=$(_run_hook "$repo" AIDEVOPS_PREPUSH_AUTOFIX=1)
	ec=$(printf '%s' "$out" | head -n 1)
	stderr=$(printf '%s' "$out" | tail -n +2)
	assert_eq '13. missing tsc → exit 1' '1' "$ec"
	assert_contains '13b. missing tsc → dependency diagnosis' 'missing JavaScript dev dependencies' "$stderr"
	assert_contains '13c. missing tsc → exact remediation' 'Run: bun install' "$stderr"
	rm -rf "$repo"
}

# Test 14: a proven task-id-counter CAS update must not need node_modules/tsc
# (regression for GH#29411/GH#29413).
{
	repo=$(_mk_repo)
	cat >"$repo/.aidevops.json" <<'JSON'
{ "verify": { "typecheck": "echo 'tsc: command not found' >&2; false" } }
JSON
	cat >"$repo/package.json" <<'JSON'
{ "name": "fixture", "devDependencies": { "typescript": "^5.0.0" } }
JSON
	printf '{}\n' >"$repo/bun.lock"
	printf '1000\n' >"$repo/.task-counter"
	(cd "$repo" && /usr/bin/git add . && /usr/bin/git commit -q -m 'seed counter')
	old_sha=$(git -C "$repo" rev-parse HEAD)
	printf '1001\n' >"$repo/.task-counter"
	(cd "$repo" && /usr/bin/git add .task-counter && /usr/bin/git commit -q -m 'claim task ID')
	new_sha=$(git -C "$repo" rev-parse HEAD)
	HOOK_STDIN="refs/heads/task-id-counter ${new_sha} refs/heads/task-id-counter ${old_sha}"
	out=$(_run_hook "$repo" AIDEVOPS_PREPUSH_AUTOFIX=0)
	unset HOOK_STDIN
	ec=$(printf '%s' "$out" | head -n 1)
	stderr=$(printf '%s' "$out" | tail -n +2)
	assert_eq '14. counter-only CAS skips missing tsc → exit 0' '0' "$ec"
	assert_contains '14b. counter-only CAS validates invariants' 'counter-only invariants passed' "$stderr"
	if printf '%s' "$stderr" | grep -qF 'running typecheck' 2>/dev/null; then
		TESTS_RUN=$((TESTS_RUN + 1))
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '%sFAIL%s: 14c. counter-only CAS must skip full typecheck\n' "$TEST_RED" "$TEST_NC"
	else
		TESTS_RUN=$((TESTS_RUN + 1))
		printf '%sPASS%s: 14c. counter-only CAS skipped full typecheck\n' "$TEST_GREEN" "$TEST_NC"
	fi
	rm -rf "$repo"
}

# Test 15: mixed content on the counter branch cannot receive the exemption.
{
	repo=$(_mk_repo)
	cat >"$repo/.aidevops.json" <<'JSON'
{ "verify": { "typecheck": "false" } }
JSON
	printf '1000\n' >"$repo/.task-counter"
	(cd "$repo" && /usr/bin/git add . && /usr/bin/git commit -q -m 'seed counter')
	old_sha=$(git -C "$repo" rev-parse HEAD)
	printf '1001\n' >"$repo/.task-counter"
	printf 'not a counter update\n' >"$repo/code.txt"
	(cd "$repo" && /usr/bin/git add . && /usr/bin/git commit -q -m 'mixed counter update')
	new_sha=$(git -C "$repo" rev-parse HEAD)
	HOOK_STDIN="refs/heads/task-id-counter ${new_sha} refs/heads/task-id-counter ${old_sha}"
	out=$(_run_hook "$repo" AIDEVOPS_PREPUSH_AUTOFIX=0)
	unset HOOK_STDIN
	ec=$(printf '%s' "$out" | head -n 1)
	stderr=$(printf '%s' "$out" | tail -n +2)
	assert_eq '15. mixed counter push → full verification blocks' '1' "$ec"
	assert_contains '15b. mixed counter push → typecheck runs' 'running typecheck' "$stderr"
	rm -rf "$repo"
}

# Test 16: only the dedicated task-id-counter branch receives the exemption.
{
	repo=$(_mk_repo)
	cat >"$repo/.aidevops.json" <<'JSON'
{ "verify": { "typecheck": "false" } }
JSON
	printf '1000\n' >"$repo/.task-counter"
	(cd "$repo" && /usr/bin/git add . && /usr/bin/git commit -q -m 'seed counter')
	old_sha=$(git -C "$repo" rev-parse HEAD)
	printf '1001\n' >"$repo/.task-counter"
	(cd "$repo" && /usr/bin/git add .task-counter && /usr/bin/git commit -q -m 'normal branch counter update')
	new_sha=$(git -C "$repo" rev-parse HEAD)
	HOOK_STDIN="refs/heads/feature-test ${new_sha} refs/heads/feature-test ${old_sha}"
	out=$(_run_hook "$repo" AIDEVOPS_PREPUSH_AUTOFIX=0)
	unset HOOK_STDIN
	ec=$(printf '%s' "$out" | head -n 1)
	stderr=$(printf '%s' "$out" | tail -n +2)
	assert_eq '16. normal branch counter push → full verification blocks' '1' "$ec"
	assert_contains '16b. normal branch counter push → typecheck runs' 'running typecheck' "$stderr"
	rm -rf "$repo"
}

# Test 17: dirty working tree → warn + skip
{
	repo=$(_mk_repo)
	cat >"$repo/.aidevops.json" <<'JSON'
{ "verify": { "format": "true" } }
JSON
	(cd "$repo" && /usr/bin/git add .aidevops.json && /usr/bin/git commit -q -m 'add config')
	# Leave an uncommitted file behind to dirty the WT
	printf 'untracked\n' >"$repo/.dirty"
	out=$(_run_hook "$repo")
	ec=$(printf '%s' "$out" | head -n 1)
	stderr=$(printf '%s' "$out" | tail -n +2)
	assert_eq '17. dirty WT → exit 0 (warn + skip)' '0' "$ec"
	assert_contains '17b. dirty WT → warn message present' 'working tree has uncommitted changes' "$stderr"
	rm -rf "$repo"
}

# Test 18: shellcheck on the hook itself (regression — quality gate)
{
	if command -v shellcheck >/dev/null 2>&1; then
		TESTS_RUN=$((TESTS_RUN + 1))
		if shellcheck "$HOOK" >/dev/null 2>&1; then
			printf '%sPASS%s: 18. hook passes shellcheck\n' "$TEST_GREEN" "$TEST_NC"
		else
			TESTS_FAILED=$((TESTS_FAILED + 1))
			printf '%sFAIL%s: 18. hook fails shellcheck\n' "$TEST_RED" "$TEST_NC"
			shellcheck "$HOOK" || true
		fi
	else
		printf '%sSKIP%s: 18. shellcheck not installed\n' "$TEST_BLUE" "$TEST_NC"
	fi
}

# ----- summary ------------------------------------------------------------

echo
echo "${TEST_BLUE}--- summary ---${TEST_NC}"
echo "Tests run:    $TESTS_RUN"
echo "Tests failed: $TESTS_FAILED"
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	echo "${TEST_GREEN}OK${TEST_NC}"
	exit 0
fi
echo "${TEST_RED}FAILED${TEST_NC}"
exit 1
