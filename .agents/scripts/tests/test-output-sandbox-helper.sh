#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HELPER="${SCRIPT_DIR}/../output-sandbox-helper.sh"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

export AIDEVOPS_OUTPUT_SANDBOX_DIR="${TMPDIR_TEST}/sandbox"

pass_count=0
fail_count=0

pass() {
	local name="$1"
	printf 'PASS: %s\n' "$name"
	pass_count=$((pass_count + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	printf 'FAIL: %s%s\n' "$name" "${detail:+ — $detail}"
	fail_count=$((fail_count + 1))
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

file_mode() {
	local path="$1"
	stat -f '%Lp' "$path" 2>/dev/null || stat -c '%a' "$path" 2>/dev/null
	return 0
}

# shellcheck disable=SC2016 # Inner bash expands $i, not this test harness.
run_output=$("$HELPER" run --success-mode receipt --summary-lines 4 -- bash -c 'for i in 1 2 3 4 5 6; do printf "line%s\n" "$i"; done')
assert_contains "run prints output id" "output_id: out_" "$run_output"
assert_contains "successful run reports outcome" "outcome: succeeded" "$run_output"
assert_not_contains "success receipt hides raw path" "raw_path:" "$run_output"
assert_not_contains "success receipt hides command output" "line1" "$run_output"

output_id=$(printf '%s\n' "$run_output" | awk '/^output_id:/ {print $2; exit}')
show_output=$("$HELPER" show "$output_id" --offset 2 --limit 2)
assert_contains "show returns exact numbered slice" "2: line2" "$show_output"
assert_contains "show respects limit" "3: line3" "$show_output"

# shellcheck disable=SC2016 # Inner bash expands $i, not this test harness.
summary_output=$("$HELPER" run --success-mode summary --summary-lines 4 -- bash -c 'for i in 1 2 3 4 5 6; do printf "line%s\n" "$i"; done')
assert_contains "explicit success summary reports omission" "omitted" "$summary_output"

short_output=$("$HELPER" run -- bash -c 'printf "short successful output\n"')
[[ "$short_output" == "short successful output" ]] && \
	pass "ordinary short successful output remains unchanged" || \
	fail "ordinary short successful output remains unchanged" "got ${short_output}"

verbose_fixture="${TMPDIR_TEST}/test-verbose-output.sh"
# shellcheck disable=SC2016 # Fixture script expands its own loop variables.
printf '%s\n' '#!/usr/bin/env bash' 'for i in $(seq 1 100); do printf "asset %s\n" "$i"; done' 'printf "warning: fixture deprecation\n"' 'printf "Tests: 100 passed, 0 failed\n"' >"$verbose_fixture"
chmod 700 "$verbose_fixture"
verbose_output=$("$HELPER" run -- bash "$verbose_fixture")
assert_contains "verbose success reports command identity" "command: bash" "$verbose_output"
assert_contains "verbose success reports exit status" "exit_status: 0" "$verbose_output"
assert_contains "verbose success preserves warning evidence" "warning: fixture deprecation" "$verbose_output"
assert_contains "verbose success preserves test totals" "Tests: 100 passed, 0 failed" "$verbose_output"
assert_contains "verbose success retains retrievable full log" "full_log: output-sandbox-helper.sh show out_" "$verbose_output"
assert_not_contains "verbose success bounds raw asset listing" "asset 50" "$verbose_output"

# shellcheck disable=SC2016 # Inner bash expands its own loop variables.
arbitrary_output=$("$HELPER" run -- bash -c 'for i in $(seq 1 100); do printf "exact %s\n" "$i"; done')
assert_contains "unrecognized verbose success remains native" "exact 50" "$arbitrary_output"
assert_not_contains "unrecognized verbose success has no compact receipt" "full_log:" "$arbitrary_output"

huge_diagnostic=$(python3 -c 'print("warning: /Users/private/project " + "x" * 20000)')
compact_output=$(printf '%s\n' "$huge_diagnostic" | "$HELPER" compact --command /private/example/bash --duration-ms 42)
compact_bytes=$(printf '%s' "$compact_output" | wc -c | tr -d ' ')
[[ "$compact_bytes" -le 4096 ]] && pass "compact presentation has a hard byte bound" || fail "compact presentation has a hard byte bound" "got ${compact_bytes}"
assert_contains "compact presentation reports duration" "duration_ms: 42" "$compact_output"
assert_contains "compact presentation retains opaque log id" "full_log: output-sandbox-helper.sh show out_" "$compact_output"
assert_not_contains "compact presentation hides private command path" "/private/example" "$compact_output"
assert_not_contains "compact presentation redacts private diagnostic paths" "/Users/private" "$compact_output"
assert_contains "compact presentation marks truncated diagnostics" "[truncated]" "$compact_output"

redacted_compact=$(python3 -c 'print("api_key=" + "x" * 10000)' | "$HELPER" compact --command bash --duration-ms 1)
assert_contains "redaction cannot downgrade compact output to raw" "full_log: output-sandbox-helper.sh show out_" "$redacted_compact"
assert_not_contains "redaction does not expose raw secret marker" "api_key=" "$redacted_compact"

named_secret=$(printf 'warning: NPM_TOKEN=supersecretvalue123\n' | "$HELPER" store --command fixture)
named_secret_id=$(printf '%s\n' "$named_secret" | awk '/^output_id:/ {print $2; exit}')
named_secret_show=$("$HELPER" show "$named_secret_id" 2>&1)
assert_contains "named environment secret is redacted before storage" "NPM_TOKEN=[REDACTED]" "$named_secret_show"
assert_not_contains "named environment secret value is not retained" "supersecretvalue123" "$named_secret_show"

set +e
failure_output=$("$HELPER" run --diagnostic-lines 4 -- bash -c 'printf "routine line\n"; printf "fatal: fixture failed\n" >&2; exit 7')
failure_rc=$?
set -e
[[ "$failure_rc" -eq 7 ]] && pass "failure preserves process exit" || fail "failure preserves process exit" "got ${failure_rc}"
assert_contains "failure reports outcome" "outcome: failed" "$failure_output"
assert_contains "failure shows bounded diagnostic" "fatal: fixture failed" "$failure_output"
assert_not_contains "failure diagnostic omits unrelated full output" "output:" "$failure_output"

set +e
sentinel_output=$("$HELPER" run --expect-text '[EXPECTED_SENTINEL]' -- bash -c 'printf "completed without sentinel\n"')
sentinel_rc=$?
set -e
[[ "$sentinel_rc" -eq 1 ]] && pass "missing expected text fails verified outcome" || fail "missing expected text fails verified outcome" "got ${sentinel_rc}"
assert_contains "missing sentinel records outcome basis" "basis=missing-expected-text" "$sentinel_output"

json_output=$("$HELPER" run --format json -- bash -c 'printf "json fixture\n"')
printf '%s' "$json_output" | jq -e '.schema == "aidevops.operation-result/v1" and .outcome == "succeeded" and .evidence.bytes > 0' >/dev/null && \
	pass "JSON receipt follows operation-result contract" || fail "JSON receipt follows operation-result contract"

sensitive_output=$(printf 'api_key=abcdefghijklmnopqrstuvwxyz123456\n' | "$HELPER" store --command "fixture" --tag secret-test)
assert_contains "sensitive output is flagged" "sensitive_redacted=1" "$sensitive_output"
sensitive_id=$(printf '%s\n' "$sensitive_output" | awk '/^output_id:/ {print $2; exit}')
sensitive_show=$("$HELPER" show "$sensitive_id" 2>&1 || true)
assert_contains "sensitive value redacted" "[REDACTED]" "$sensitive_show"

bypass_output=$("$HELPER" run -- git diff --no-index /dev/null /dev/null 2>&1 || true)
assert_contains "exact diff bypasses sandbox" "output_sandbox: bypass exact/verbatim command" "$bypass_output"

root_mode=$(file_mode "$AIDEVOPS_OUTPUT_SANDBOX_DIR")
raw_mode=$(file_mode "$AIDEVOPS_OUTPUT_SANDBOX_DIR/raw/${output_id}.txt")
[[ "$root_mode" == "700" ]] && pass "sandbox directory is private" || fail "sandbox directory is private" "mode ${root_mode}"
[[ "$raw_mode" == "600" ]] && pass "raw evidence is private" || fail "raw evidence is private" "mode ${raw_mode}"

blocked_parent="${TMPDIR_TEST}/not-a-directory"
printf 'block directory creation\n' >"$blocked_parent"
set +e
fail_open_output=$(AIDEVOPS_OUTPUT_SANDBOX_DIR="${blocked_parent}/sandbox" "$HELPER" run -- bash -c 'printf "native fail-open output\n"' 2>&1)
fail_open_rc=$?
set -e
[[ "$fail_open_rc" -eq 0 ]] && pass "storage failure preserves command success" || fail "storage failure preserves command success" "got ${fail_open_rc}"
assert_contains "storage failure falls back to native output" "native fail-open output" "$fail_open_output"
assert_contains "storage failure explains fallback" "evidence store unavailable" "$fail_open_output"

set +e
late_fail_open_output=$(AIDEVOPS_OUTPUT_SANDBOX_TEST_RECORD_FAIL=1 "$HELPER" run -- bash -c 'printf "late native stdout\n"; printf "late native stderr\n" >&2' 2>&1)
late_fail_open_rc=$?
set -e
[[ "$late_fail_open_rc" -eq 0 ]] && pass "late storage failure preserves command success" || fail "late storage failure preserves command success" "got ${late_fail_open_rc}"
assert_contains "late storage failure returns stdout" "late native stdout" "$late_fail_open_output"
assert_contains "late storage failure returns stderr" "late native stderr" "$late_fail_open_output"
assert_contains "late storage failure explains fallback" "evidence finalization failed" "$late_fail_open_output"

set +e
late_failure_output=$(AIDEVOPS_OUTPUT_SANDBOX_TEST_RECORD_FAIL=1 "$HELPER" run -- bash -c 'printf "late failed command\n"; exit 9' 2>&1)
late_failure_rc=$?
set -e
[[ "$late_failure_rc" -eq 9 ]] && pass "late storage failure preserves command failure" || fail "late storage failure preserves command failure" "got ${late_failure_rc}"
assert_contains "late storage failure returns failed output" "late failed command" "$late_failure_output"

cleanup_output=$("$HELPER" cleanup --max-age-days 0)
assert_contains "cleanup reports deletion count" "deleted:" "$cleanup_output"

stats_output=$("$HELPER" stats)
assert_contains "stats prints output count" "outputs:" "$stats_output"

printf '%s passed, %s failed\n' "$pass_count" "$fail_count"
if [[ "$fail_count" -ne 0 ]]; then
	exit 1
fi
