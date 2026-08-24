#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-qlty-smell-threshold-helper.sh — regression tests for GH#26017

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

assert_rc() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected rc: $expected"
		echo "  actual rc:   $actual"
	fi
	return 0
}

assert_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected to find: $(printf '%q' "$needle")"
		echo "  in output:        $(printf '%q' "${haystack:0:300}")"
	fi
	return 0
}

assert_not_contains() {
	local label="$1"
	local needle="$2"
	local haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected not to find: $(printf '%q' "$needle")"
	else
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	fi
	return 0
}

write_stub_qlty() {
	local mode="$1" bin_dir="$2"
	mkdir -p "$bin_dir"
	cat >"$bin_dir/qlty" <<'STUB'
#!/usr/bin/env bash
set -u
if [[ "${1:-}" == "--version" ]]; then
	printf 'qlty test-stub\n'
	exit 0
fi
case "${QLTY_STUB_MODE:-empty}" in
	empty)
		printf 'simulated qlty empty output\n' >&2
		exit 0
		;;
	empty-fail)
		printf 'simulated qlty empty failure diagnostics\n' >&2
		exit 2
		;;
	blank)
		printf '  \n\t\n'
		printf 'simulated qlty blank output\n' >&2
		exit 0
		;;
	invalid)
		printf 'simulated non-sarif stdout\n'
		printf 'simulated qlty invalid output diagnostics\n' >&2
		exit 0
		;;
	pass)
		printf '{"runs":[{"results":[{"ruleId":"file-complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"ok.py"}}}]}]}]}'
		exit 0
		;;
	cache-sensitive)
		if [ -z "${XDG_CACHE_HOME:-}" ]; then
			printf 'missing isolated cache\n' >&2
			exit 2
		fi
		if [ ! -f "$XDG_CACHE_HOME/warmed" ]; then
			: >"$XDG_CACHE_HOME/warmed"
			printf '{"runs":[{"results":[{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"cold-a.py"}}}]},{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"cold-b.py"}}}]},{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"cold-c.py"}}}]}]}]}'
		else
			printf '{"runs":[{"results":[{"ruleId":"file-complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"stable.py"}}}]}]}]}'
		fi
		exit 0
		;;
	never-stable)
		if [ -z "${XDG_CACHE_HOME:-}" ]; then
			exit 2
		fi
		run_count=0
		if [ -f "$XDG_CACHE_HOME/run-count" ]; then
			run_count=$(cat "$XDG_CACHE_HOME/run-count")
		fi
		run_count=$((run_count + 1))
		printf '%s\n' "$run_count" >"$XDG_CACHE_HOME/run-count"
		printf '{"runs":[{"results":[{"ruleId":"qlty:unstable","locations":[{"physicalLocation":{"artifactLocation":{"uri":"attempt-%s.py"}}}]}]}]}' "$run_count"
		exit 0
		;;
	topology-sensitive)
		if [ -d .git ]; then
			printf '{"runs":[{"results":[{"ruleId":"file-complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"stable.py"}}}]}]}]}'
		else
			printf '{"runs":[{"results":[{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"direct-a.py"}}}]},{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"direct-b.py"}}}]},{"ruleId":"qlty:similar-code","locations":[{"physicalLocation":{"artifactLocation":{"uri":"direct-c.py"}}}]}]}]}'
		fi
		exit 0
		;;
	fail)
		printf '{"runs":[{"results":[{"ruleId":"file-complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"a.py"}}}]},{"ruleId":"function-complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"b.py"}}}]},{"ruleId":"function-complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"b.py"}}}]}]}]}'
		exit 0
		;;
	missing-location)
		printf '{"runs":[{"results":[{"ruleId":"file-complexity","locations":[{"physicalLocation":{"artifactLocation":{"uri":"a.py"}}}]},{"ruleId":"global-complexity"},{"locations":[]}]}]}'
		exit 0
		;;
esac
exit 1
STUB
	chmod +x "$bin_dir/qlty"
	QLTY_STUB_MODE="$mode"
	export QLTY_STUB_MODE
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$SCRIPT_DIR/qlty-smell-threshold-helper.sh"
WORKFLOW="$SCRIPT_DIR/../../.github/workflows/code-quality.yml"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/qlty-threshold-test.XXXXXX")
trap 'rm -rf "$TMP_ROOT"' EXIT

CONF="$TMP_ROOT/complexity-thresholds.conf"
printf 'QLTY_SMELL_THRESHOLD=2\n' >"$CONF"
BIN_DIR="$TMP_ROOT/bin"
PATH="$BIN_DIR:$PATH"
export PATH

echo "${TEST_BLUE}=== GH#26017: qlty smell threshold helper tests ===${TEST_NC}"
echo ""

qlty_threshold_job=$(awk '
	/^  qlty-smell-threshold:/ { in_job = 1 }
	in_job { print }
	/^  sonarcloud:/ { exit }
' "$WORKFLOW")
assert_contains "absolute threshold checkout preserves git history" "fetch-depth: 0" "$qlty_threshold_job"

write_stub_qlty empty "$BIN_DIR"
empty_output=$("$HELPER" "$CONF" 2>&1)
empty_rc=$?
assert_rc "empty SARIF output is warning-only" "0" "$empty_rc"
assert_contains "empty SARIF warning emitted" "empty SARIF output" "$empty_output"
assert_contains "empty SARIF explains diagnostic-only scope" "Absolute threshold status: diagnostic-only" "$empty_output"
assert_contains "empty SARIF includes command context" "smells --all --sarif --no-snippets --quiet" "$empty_output"
assert_contains "empty SARIF includes qlty version" "Qlty version: qlty test-stub" "$empty_output"
assert_contains "empty SARIF includes stderr diagnostics" "simulated qlty empty output" "$empty_output"

write_stub_qlty empty-fail "$BIN_DIR"
empty_fail_output=$("$HELPER" "$CONF" 2>&1)
empty_fail_rc=$?
assert_rc "empty SARIF output with qlty failure is warning-only" "0" "$empty_fail_rc"
assert_contains "empty SARIF failure includes qlty exit code" "qlty smells exit code: 2" "$empty_fail_output"
assert_contains "empty SARIF failure includes stderr diagnostics" "simulated qlty empty failure diagnostics" "$empty_fail_output"

write_stub_qlty blank "$BIN_DIR"
blank_output=$("$HELPER" "$CONF" 2>&1)
blank_rc=$?
assert_rc "blank SARIF output is warning-only" "0" "$blank_rc"
assert_contains "blank SARIF warning emitted" "empty SARIF output" "$blank_output"

write_stub_qlty invalid "$BIN_DIR"
invalid_output=$("$HELPER" "$CONF" 2>&1)
invalid_rc=$?
assert_rc "invalid SARIF output is warning-only" "0" "$invalid_rc"
assert_contains "invalid SARIF warning emitted" "invalid SARIF output" "$invalid_output"
assert_contains "invalid SARIF includes stdout preview" "simulated non-sarif stdout" "$invalid_output"
assert_contains "invalid SARIF includes stderr diagnostics" "simulated qlty invalid output diagnostics" "$invalid_output"

write_stub_qlty pass "$BIN_DIR"
pass_output=$("$HELPER" "$CONF" 2>&1)
pass_rc=$?
assert_rc "valid SARIF below threshold passes" "0" "$pass_rc"
assert_contains "valid SARIF reports headroom" "Within threshold" "$pass_output"
assert_contains "valid SARIF reports qlty version" "Qlty version: qlty test-stub" "$pass_output"
assert_contains "valid SARIF reports scan mode" "Scan mode: isolated-clone" "$pass_output"
assert_contains "valid SARIF reports logical root" "Scan root: repository-root" "$pass_output"
assert_contains "valid SARIF reports normalized count" "Normalized result count: 1" "$pass_output"
assert_contains "valid SARIF reports per-rule counts" $'  1\tfile-complexity' "$pass_output"

write_stub_qlty cache-sensitive "$BIN_DIR"
cache_sensitive_output=$($HELPER "$CONF" 2>&1)
cache_sensitive_rc=$?
assert_rc "cold-cache-only similar-code findings do not affect the gate" "0" "$cache_sensitive_rc"
assert_contains "absolute scan warms an isolated cache" "Warming isolated qlty cache" "$cache_sensitive_output"
assert_contains "authoritative scan uses the stable warm-cache count" "Normalized result count: 1" "$cache_sensitive_output"
assert_not_contains "cold-cache-only similar-code identities are discarded" "cold-a.py" "$cache_sensitive_output"

repeated_cache_output=$($HELPER "$CONF" 2>&1)
repeated_cache_rc=$?
assert_rc "repeated isolated-cache scan remains stable" "0" "$repeated_cache_rc"
assert_contains "repeated scan retains stable count" "Normalized result count: 1" "$repeated_cache_output"

write_stub_qlty never-stable "$BIN_DIR"
never_stable_output=$($HELPER "$CONF" 2>&1)
never_stable_rc=$?
assert_rc "unstable identities are diagnostic-only" "0" "$never_stable_rc"
assert_contains "unstable identities return explicit inconclusive state" "Absolute threshold status: inconclusive (unstable normalized identities)" "$never_stable_output"
assert_contains "unstable identities include attempt diagnostics" "Attempts: 1:rc=0,count=1;2:rc=0,count=1;3:rc=0,count=1" "$never_stable_output"
assert_not_contains "unstable identities cannot emit threshold remediation" "QLTY_REMEDIATION_EVIDENCE=" "$never_stable_output"

write_stub_qlty topology-sensitive "$BIN_DIR"
topology_sensitive_output=$($HELPER "$CONF" 2>&1)
topology_sensitive_rc=$?
assert_rc "direct-checkout-only similar-code findings do not affect the gate" "0" "$topology_sensitive_rc"
assert_contains "absolute scan uses standalone clone topology" "Creating standalone clone" "$topology_sensitive_output"
assert_contains "standalone clone retains stable count" "Normalized result count: 1" "$topology_sensitive_output"
assert_not_contains "direct-checkout-only identities are excluded" "direct-a.py" "$topology_sensitive_output"

write_stub_qlty fail "$BIN_DIR"
fail_output=$("$HELPER" "$CONF" 2>&1)
fail_rc=$?
assert_rc "valid SARIF above threshold fails" "1" "$fail_rc"
assert_contains "threshold failure remains blocking" "Qlty smell regression" "$fail_output"
assert_contains "threshold failure emits machine-readable remediation evidence" \
	'QLTY_REMEDIATION_EVIDENCE={"schema":"aidevops.qlty-remediation.v1","actual":3,"threshold":2,"deficit":1' \
	"$fail_output"
assert_contains "threshold failure attributes file distribution" '"file":"b.py","count":2' "$fail_output"
assert_contains "threshold failure keeps new PR smells blocking" "New PR smells remain blocking" "$fail_output"
assert_contains "threshold failure rejects baseline inflation" "Do not raise QLTY_SMELL_THRESHOLD" "$fail_output"

write_stub_qlty missing-location "$BIN_DIR"
missing_location_output=$("$HELPER" "$CONF" 2>&1)
missing_location_rc=$?
assert_rc "SARIF findings without physical locations remain blocking" "1" "$missing_location_rc"
assert_contains "location-less SARIF still emits remediation evidence" \
	'QLTY_REMEDIATION_EVIDENCE={"schema":"aidevops.qlty-remediation.v1","actual":3,"threshold":2,"deficit":1' \
	"$missing_location_output"
assert_contains "remediation evidence keeps located file attribution" '"files":[{"file":"a.py","count":1}]' "$missing_location_output"
assert_contains "remediation evidence omits missing rule identifiers" '"rules":[{"rule":"file-complexity","count":1},{"rule":"global-complexity","count":1}]' "$missing_location_output"
assert_contains "console breakdown keeps located file attribution" $'  1\ta.py' "$missing_location_output"
assert_contains "console breakdown keeps available rule identifiers" $'  1\tglobal-complexity' "$missing_location_output"
assert_not_contains "console breakdown omits missing values" $'\tnull' "$missing_location_output"
assert_not_contains "console breakdown does not emit jq errors" "jq: error" "$missing_location_output"

echo ""
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	echo "${TEST_GREEN}All $TESTS_RUN tests passed${TEST_NC}"
	exit 0
fi

echo "${TEST_RED}$TESTS_FAILED of $TESTS_RUN tests failed${TEST_NC}"
exit 1
