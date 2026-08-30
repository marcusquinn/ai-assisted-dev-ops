#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/privacy-filter-helper.sh"
TEST_ROOT="$(mktemp -d)"
BIN_DIR="${TEST_ROOT}/bin"
HOME_DIR="${TEST_ROOT}/home"
CLEAN_FILE="${TEST_ROOT}/clean.txt"
MATCH_FILE="${TEST_ROOT}/match.txt"
TESTS=0
FAILURES=0
RUN_OUTPUT=""
RUN_STATUS=0

cleanup() {
	rm -rf "$TEST_ROOT"
	return 0
}
trap cleanup EXIT

pass() {
	local name="$1"
	TESTS=$((TESTS + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	TESTS=$((TESTS + 1))
	FAILURES=$((FAILURES + 1))
	printf 'FAIL %s: %s\n' "$name" "$detail"
	return 0
}

run_scan() {
	local fixture="$1"
	local target="$2"
	RUN_OUTPUT=""
	RUN_STATUS=0
	RUN_OUTPUT=$(HOME="$HOME_DIR" SECRETLINT_FIXTURE="$fixture" PATH="$BIN_DIR:$PATH" \
		"$HELPER" scan "$target" 2>&1) || RUN_STATUS=$?
	return 0
}

assert_status() {
	local name="$1"
	local expected="$2"
	if [[ "$RUN_STATUS" -eq "$expected" ]]; then
		pass "$name"
	else
		fail "$name" "expected status $expected, got $RUN_STATUS; output=${RUN_OUTPUT}"
	fi
	return 0
}

assert_contains() {
	local name="$1"
	local expected="$2"
	if [[ "$RUN_OUTPUT" == *"$expected"* ]]; then
		pass "$name"
	else
		fail "$name" "missing '${expected}'; output=${RUN_OUTPUT}"
	fi
	return 0
}

assert_not_contains() {
	local name="$1"
	local unexpected="$2"
	if [[ "$RUN_OUTPUT" != *"$unexpected"* ]]; then
		pass "$name"
	else
		fail "$name" "unexpected '${unexpected}'; output=${RUN_OUTPUT}"
	fi
	return 0
}

mkdir -p "$BIN_DIR" "$HOME_DIR"
printf 'plain fixture content\n' >"$CLEAN_FILE"
printf 'contact fixture@example.invalid\n' >"$MATCH_FILE"

cat >"${BIN_DIR}/secretlint" <<'EOF'
#!/usr/bin/env bash
case "${SECRETLINT_FIXTURE:-clean}" in
clean)
	exit 0
	;;
finding)
	printf 'fixture:1:1 secretlint finding\n'
	exit 1
	;;
fatal)
	printf 'Error: secretlint config is not found\n' >&2
	exit 2
	;;
execution)
	printf 'scanner could not execute\n' >&2
	exit 7
	;;
*)
	exit 9
	;;
esac
EOF
chmod +x "${BIN_DIR}/secretlint"

run_scan clean "$CLEAN_FILE"
assert_status "clean Secretlint scan succeeds" 0
assert_contains "clean Secretlint scan reports success" "Secretlint: No secrets detected"

run_scan finding "$CLEAN_FILE"
assert_status "Secretlint finding remains blocking" 1
assert_contains "Secretlint finding is classified as content" "Secretlint: Potential secrets found!"
assert_contains "Secretlint finding increments the privacy total" "Found 1 potential privacy issues"

run_scan fatal "$CLEAN_FILE"
assert_status "Secretlint fatal error does not synthesize a finding" 0
assert_contains "Secretlint fatal error is reported explicitly" "configuration or execution error (exit 2)"
assert_not_contains "Secretlint fatal error is not called a secret" "Potential secrets found"
assert_contains "built-in scan still completes after fatal error" "No privacy-sensitive content detected"

run_scan execution "$CLEAN_FILE"
assert_status "Secretlint execution failure does not synthesize a finding" 0
assert_contains "Secretlint execution failure includes its status" "configuration or execution error (exit 7)"
assert_not_contains "Secretlint execution failure is not called a secret" "Potential secrets found"

run_scan fatal "$MATCH_FILE"
assert_status "built-in privacy match remains blocking" 1
assert_contains "built-in privacy match is reported" "Found 1 potential privacy issues"

printf '%s tests, %s failures\n' "$TESTS" "$FAILURES"
[[ "$FAILURES" -eq 0 ]]
