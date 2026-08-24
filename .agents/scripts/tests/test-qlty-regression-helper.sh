#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for deterministic isolated-clone Qlty scans (GH#28162).

set -u

TESTS_RUN=0
TESTS_FAILED=0

assert_rc() {
	local _label="$1"
	local _expected="$2"
	local _actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [ "$_expected" = "$_actual" ]; then
		printf 'PASS: %s\n' "$_label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf 'FAIL: %s (expected %s, got %s)\n' "$_label" "$_expected" "$_actual"
	fi
	return 0
}

assert_contains() {
	local _label="$1"
	local _needle="$2"
	local _haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$_haystack" == *"$_needle"* ]]; then
		printf 'PASS: %s\n' "$_label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf 'FAIL: %s (missing %s)\n' "$_label" "$_needle"
	fi
	return 0
}

resolve_git() {
	local _candidate=""
	while IFS= read -r _candidate; do
		case "$_candidate" in
		*/.aidevops/*/agents/scripts/git | */.aidevops/agents/scripts/git | */.aidevops/bin/git | */.agents/scripts/git) continue ;;
		esac
		printf '%s\n' "$_candidate"
		return 0
	done < <(type -a -p git 2>/dev/null || true)
	return 1
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$SCRIPT_DIR/qlty-regression-helper.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/qlty-regression-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT
REPO="$TMP_ROOT/repo"
BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$REPO" "$BIN_DIR"

cat >"$BIN_DIR/qlty" <<'STUB'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "--version" ]; then
	printf 'qlty 0.635.0 linux-x64\n'
	exit 0
fi
if [ "${QLTY_STUB_MODE:-parity}" = "base-fail" ] && [ "$(basename "$PWD")" = "base-worktree" ]; then
	printf 'simulated base failure\n' >&2
	exit 2
fi
if [ "${QLTY_STUB_MODE:-parity}" = "mismatch" ] && [ "$(basename "$PWD")" = "head-worktree" ]; then
	printf '%s\n' '{"runs":[{"results":[{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"a.sh"}}}]},{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"b.sh"}}}]}]}]}'
	exit 0
fi
if [ "${QLTY_STUB_MODE:-parity}" = "head-fail" ] && [ "$(basename "$PWD")" = "head-worktree" ]; then
	printf 'simulated head failure\n' >&2
	exit 2
fi
if [ "${QLTY_STUB_MODE:-parity}" = "cache-sensitive" ]; then
	if [ -z "${XDG_CACHE_HOME:-}" ]; then
		printf 'missing isolated cache\n' >&2
		exit 2
	fi
	if [ ! -f "$XDG_CACHE_HOME/warmed" ]; then
		: >"$XDG_CACHE_HOME/warmed"
		printf '%s\n' '{"runs":[{"results":[{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"cold-a.sh"}}}]},{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"cold-b.sh"}}}]},{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"cold-c.sh"}}}]},{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"a.sh"}}}]}]}]}'
	else
		printf '%s\n' '{"runs":[{"results":[{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"a.sh"}}}]}]}]}'
	fi
	exit 0
fi
if [ "${QLTY_STUB_MODE:-parity}" = "second-pass-unstable" ]; then
	if [ -z "${XDG_CACHE_HOME:-}" ]; then
		printf 'missing isolated cache\n' >&2
		exit 2
	fi
	run_count=0
	if [ -f "$XDG_CACHE_HOME/run-count" ]; then
		run_count=$(cat "$XDG_CACHE_HOME/run-count")
	fi
	run_count=$((run_count + 1))
	printf '%s\n' "$run_count" >"$XDG_CACHE_HOME/run-count"
	if [ "$run_count" -eq 2 ]; then
		printf '%s\n' '{"runs":[{"results":[{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"transient-a.sh"}}}]},{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"transient-b.sh"}}}]},{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"transient-c.sh"}}}]}]}]}'
	else
		printf '%s\n' '{"runs":[{"results":[{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"a.sh"}}}]}]}]}'
	fi
	exit 0
fi
if [ "${QLTY_STUB_MODE:-parity}" = "never-stable" ]; then
	run_count=0
	if [ -f "$XDG_CACHE_HOME/run-count" ]; then
		run_count=$(cat "$XDG_CACHE_HOME/run-count")
	fi
	run_count=$((run_count + 1))
	printf '%s\n' "$run_count" >"$XDG_CACHE_HOME/run-count"
	printf '{"runs":[{"results":[{"ruleId":"qlty:unstable","locations":[{"physicalLocation":{"artifactLocation":{"uri":"attempt-%s.sh"}}}]}]}]}\n' "$run_count"
	exit 0
fi
if [ "${QLTY_STUB_MODE:-parity}" = "topology-sensitive" ]; then
	if [ "$(basename "$PWD")" = "repo" ]; then
		printf '%s\n' '{"runs":[{"results":[{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"direct-only.sh"}}}]}]}]}'
	else
		printf '%s\n' '{"runs":[{"results":[{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"a.sh"}}}]}]}]}'
	fi
	exit 0
fi
if [ "${QLTY_STUB_MODE:-parity}" = "unchanged-file-regression" ] && [ "$(basename "$PWD")" = "head-worktree" ]; then
	printf '%s\n' '{"runs":[{"results":[{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"a.sh"}}}]},{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"unchanged.py"}}}]}]}]}'
	exit 0
fi
if [ "${QLTY_STUB_MODE:-parity}" = "changed-file-regression" ] && [ "$(basename "$PWD")" = "head-worktree" ]; then
	printf '%s\n' '{"runs":[{"results":[{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"a.sh"}}}]},{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"a.sh"}}}],"relatedLocations":[{"physicalLocation":{"artifactLocation":{"uri":"VERSION"}}}]}]}]}'
	exit 0
fi
printf '%s\n' '{"runs":[{"results":[{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"a.sh"}}}]}]}]}'
exit 0
STUB
chmod +x "$BIN_DIR/qlty"
GIT_PATH=$(resolve_git || true)
if [ -z "$GIT_PATH" ]; then
	printf 'git not found\n' >&2
	exit 1
fi
ln -s "$GIT_PATH" "$BIN_DIR/git"

(
	cd "$REPO" || exit 1
	"$GIT_PATH" init --quiet
	"$GIT_PATH" config user.name "Qlty Test"
	"$GIT_PATH" config user.email "qlty-test@example.invalid"
	"$GIT_PATH" config commit.gpgsign false
	printf 'sample\n' >a.sh
	"$GIT_PATH" add a.sh
	"$GIT_PATH" commit --quiet -m "fixture"
) || exit 1

PATH="$BIN_DIR:$PATH"
export PATH

QLTY_STUB_MODE=parity
export QLTY_STUB_MODE
parity_output=$(cd "$REPO" && "$HELPER" --base HEAD --head HEAD 2>&1)
parity_rc=$?
assert_rc "same tree passes with equivalent standalone-clone scans" "0" "$parity_rc"
assert_contains "base metadata identifies isolated clone" "mode=isolated-clone" "$parity_output"
assert_contains "head metadata identifies isolated clone" "head metadata: version=qlty 0.635.0 linux-x64" "$parity_output"
assert_contains "head metadata records equivalent scan mode" "mode=isolated-clone" "$parity_output"
assert_contains "same-tree identity parity is explicit" "identical normalized SARIF identities" "$parity_output"
assert_contains "resolved Qlty version is logged" "version=qlty 0.635.0 linux-x64" "$parity_output"
assert_contains "per-rule counts are logged" $'1\tqlty:similar-code' "$parity_output"

QLTY_STUB_MODE=cache-sensitive
export QLTY_STUB_MODE
cache_sensitive_output=$(cd "$REPO" && "$HELPER" --base HEAD --head HEAD 2>&1)
cache_sensitive_rc=$?
assert_rc "cold-cache-only similar-code findings do not affect same-tree scans" "0" "$cache_sensitive_rc"
assert_contains "both authoritative scans use warm-cache counts" "base: 1  head: 1  delta: 0" "$cache_sensitive_output"

QLTY_STUB_MODE=second-pass-unstable
export QLTY_STUB_MODE
unstable_output=$(cd "$REPO" && "$HELPER" --base HEAD --head HEAD 2>&1)
unstable_rc=$?
assert_rc "one unstable second pass cannot affect same-tree scans" "0" "$unstable_rc"
assert_contains "three-scan identity consensus is reported" "identities stabilized after 3 scans" "$unstable_output"
assert_contains "consensus scan retains stable counts" "base: 1  head: 1  delta: 0" "$unstable_output"

QLTY_STUB_MODE=topology-sensitive
export QLTY_STUB_MODE
topology_sensitive_output=$(cd "$REPO" && "$HELPER" --base HEAD --head HEAD 2>&1)
topology_sensitive_rc=$?
assert_rc "topology-sensitive findings cannot skew same-tree comparisons" "0" "$topology_sensitive_rc"
assert_contains "both refs use equivalent topology" "base: 1  head: 1  delta: 0" "$topology_sensitive_output"

printf 'metadata only\n' >"$REPO/VERSION"
(cd "$REPO" && "$GIT_PATH" add VERSION && "$GIT_PATH" commit --quiet -m "metadata fixture") || exit 1
metadata_output=$(cd "$REPO" && "$HELPER" --base HEAD^ --head HEAD 2>&1)
metadata_rc=$?
assert_rc "metadata-only commit diff-scopes unchanged source findings" "0" "$metadata_rc"
assert_contains "metadata-only scan reports zero delta" "base: 0  head: 0  delta: 0" "$metadata_output"

QLTY_STUB_MODE=unchanged-file-regression
export QLTY_STUB_MODE
unchanged_regression_output=$(cd "$REPO" && "$HELPER" --base HEAD^ --head HEAD 2>&1)
unchanged_regression_rc=$?
assert_rc "new similar-code findings confined to unchanged files do not regress" "0" "$unchanged_regression_rc"
assert_contains "unchanged duplicate clusters are diff-scoped" "base: 0  head: 0  delta: 0" "$unchanged_regression_output"

QLTY_STUB_MODE=changed-file-regression
export QLTY_STUB_MODE
changed_regression_output=$(cd "$REPO" && "$HELPER" --base HEAD^ --head HEAD 2>&1)
changed_regression_rc=$?
assert_rc "similar-code clusters involving a changed related location still regress" "1" "$changed_regression_rc"
assert_contains "changed duplicate cluster remains counted" "base: 0  head: 1  delta: 1" "$changed_regression_output"

QLTY_STUB_MODE=mismatch
export QLTY_STUB_MODE
mismatch_output=$(cd "$REPO" && "$HELPER" --base HEAD --head HEAD 2>&1)
mismatch_rc=$?
assert_rc "same-tree normalized mismatch blocks" "1" "$mismatch_rc"
assert_contains "mismatch includes tree evidence" "produced different normalized SARIF identities" "$mismatch_output"
assert_contains "mismatch includes normalized URI difference" $'+qlty:similar-code\tb.sh' "$mismatch_output"

QLTY_STUB_MODE=head-fail
export QLTY_STUB_MODE
head_failure_output=$(cd "$REPO" && "$HELPER" --base HEAD --head HEAD 2>&1)
head_failure_rc=$?
assert_rc "head scan failure stops before SARIF parsing" "2" "$head_failure_rc"
assert_contains "head scan failure identifies the failed ref" "failed to scan head" "$head_failure_output"

QLTY_STUB_MODE=base-fail
export QLTY_STUB_MODE
fallback_output=$(cd "$REPO" && "$HELPER" --base HEAD --head HEAD 2>&1)
fallback_rc=$?
assert_rc "base scan failure is non-passing" "2" "$fallback_rc"
assert_contains "base failure refuses a synthetic clean delta" "refusing a synthetic clean delta" "$fallback_output"

QLTY_STUB_MODE=never-stable
export QLTY_STUB_MODE
never_stable_output=$(cd "$REPO" && "$HELPER" --base HEAD --head HEAD 2>&1)
never_stable_rc=$?
assert_rc "unstable scanner identities are non-passing" "2" "$never_stable_rc"
assert_contains "unstable scanner reports explicit inconclusive state" "INCONCLUSIVE: unstable normalized identities" "$never_stable_output"
assert_contains "unstable scanner reports attempt diagnostics" "attempts: 1:rc=0,count=1;2:rc=0,count=1;3:rc=0,count=1" "$never_stable_output"

if [ "$TESTS_FAILED" -eq 0 ]; then
	printf 'All %s tests passed\n' "$TESTS_RUN"
	exit 0
fi
printf '%s of %s tests failed\n' "$TESTS_FAILED" "$TESTS_RUN"
exit 1
