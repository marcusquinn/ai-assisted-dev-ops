#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# t1992: Regression test for the daily quality sweep serialization.
#
# The original implementation of `_run_sweep_tools` / `_quality_sweep_for_repo`
# wrote 12 fields with `printf '%s\n'` and read them back with `IFS= read -r`.
# That pattern only worked for single-line values; every multi-line section
# (ShellCheck, Qlty, SonarCloud, Codacy, CodeRabbit, review_scan) was
# truncated to its first line, with the remainder leaking into the next
# variable.
#
# This test stubs the per-tool `_sweep_*` functions to return known multi-line
# fixtures and then asserts that each section round-trips byte-for-byte
# through `_run_sweep_tools` (writer) into the caller (reader).
#
# Run:
#   bash .agents/scripts/tests/test-quality-sweep-serialization.sh
#
# shellcheck disable=SC1090,SC1091

set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${TEST_SCRIPT_DIR}/.." && pwd)" || exit 1

# Isolate from real state files
TMP_HOME=$(mktemp -d)
export HOME="$TMP_HOME"
export LOGFILE="${TMP_HOME}/test.log"
export QUALITY_SWEEP_STATE_DIR="${TMP_HOME}/state"
mkdir -p "$QUALITY_SWEEP_STATE_DIR"

# Source dependencies. stats-functions.sh expects shared-constants and
# worker-lifecycle-common to be sourced first.
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/shared-constants.sh"
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/worker-lifecycle-common.sh"
# shellcheck source=/dev/null
source "${SCRIPTS_DIR}/stats-functions.sh"

TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

print_result() {
	local name="$1"
	local rc="$2"
	local detail="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		echo "PASS $name"
		TESTS_PASSED=$((TESTS_PASSED + 1))
	else
		echo "FAIL $name"
		[[ -n "$detail" ]] && printf '  %s\n' "$detail"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
	return 0
}

# --- Fixtures ---
# Every section uses multi-line markdown with embedded newlines, which the
# original `IFS= read -r` chain truncated to the first line.

FIXTURE_SHELLCHECK="### ShellCheck (3 files scanned)

- **Errors**: 1
- **Warnings**: 2
- **Notes**: 4

**Top findings:**
  - \`a.sh\`: SC1009 missing fi
  - \`b.sh\`: SC2086 quote vars
  - \`c.sh\`: SC1091 sourced file not specified"

FIXTURE_QLTY="### Qlty Maintainability

- **Total smells**: 42
- **By rule**:
  - file-complexity: 12
  - function-complexity: 9
  - duplicate-blocks: 7
  - file-length: 5
  - return-statements: 4
  - identical-blocks: 2
  - similar-blocks: 2
  - parameter-count: 1
- **Top files (highest smell density)**:
  - \`scripts/big.sh\`: 18 smells
  - \`scripts/medium.sh\`: 9 smells
- **Qlty Cloud grade**: B
"

FIXTURE_SONAR="### SonarCloud

- **Quality gate**: ERROR
- **Total issues**: 224
- **High/critical**: 12

**Top rules:**
  - shelldre:S1481: 161
  - shelldre:S1066: 63"

FIXTURE_CODACY="### Codacy

- **Issues**: 17

**By severity:**
  - error: 2
  - warning: 8
  - info: 7"

# Empty section — common case when CodeRabbit posts no findings.
FIXTURE_CODERABBIT=""

# Last field, no trailing newline. Tests that the final section is not
# truncated by the reader.
FIXTURE_REVIEW_SCAN="### Review Scanner

- **Open suggestions**: 5
  - \`pr#100\`: refactor X
  - \`pr#101\`: handle null in Y
  - \`pr#102\`: missing error path"

# --- Stubs ---
# Override the per-tool sweep functions after sourcing. Bash lets you
# redefine a function by name; the new body wins at call time.

_sweep_shellcheck() {
	printf '%s' "$FIXTURE_SHELLCHECK"
	return 0
}

_sweep_qlty() {
	# t2066: grade is now derived from the local smell count by
	# _compute_qlty_grade_from_count — not hard-coded. Compute the expected
	# grade from the fixture count so the test tracks the config thresholds
	# instead of baking in a specific grade letter.
	local expected_grade
	expected_grade=$(_compute_qlty_grade_from_count 42)
	printf '%s|%s|%s' "$FIXTURE_QLTY" "42" "$expected_grade"
	return 0
}

_sweep_sonarcloud() {
	# Original signature: stdout = "section|gate|total|high"
	printf '%s|%s|%s|%s' "$FIXTURE_SONAR" "ERROR" "224" "12"
	return 0
}

_sweep_codacy() {
	printf '%s' "$FIXTURE_CODACY"
	return 0
}

_sweep_coderabbit() {
	printf '%s' "$FIXTURE_CODERABBIT"
	return 0
}

_sweep_review_scanner() {
	printf '%s' "$FIXTURE_REVIEW_SCAN"
	return 0
}

# Stub side-effects so the test stays hermetic.
_save_sweep_state() {
	return 0
}

_create_simplification_issues() {
	return 0
}

# --- Helpers ---

assert_file_eq() {
	local label="$1"
	local file="$2"
	local expected="$3"
	if [[ ! -f "$file" ]]; then
		print_result "$label" 1 "missing file: $file"
		return 0
	fi
	# Use cmp against a temp file so trailing newlines are NOT stripped by
	# command substitution (which would mask the very bug we are guarding
	# against). `$(cat file)` would silently lose the trailing \n.
	local expected_tmp
	expected_tmp=$(mktemp)
	printf '%s' "$expected" >"$expected_tmp"
	if cmp -s "$file" "$expected_tmp"; then
		print_result "$label" 0
		rm -f "$expected_tmp"
	else
		local actual_dump
		actual_dump=$(od -c "$file" | head -20)
		print_result "$label" 1 "$(printf 'cmp diff: %s vs %s\n%s' "$file" "$expected_tmp" "$actual_dump")"
		rm -f "$expected_tmp"
	fi
	return 0
}

# --- Run the writer ---

SECTIONS_DIR=$(_run_sweep_tools "owner/repo" "/tmp/fake-repo")

if [[ -z "$SECTIONS_DIR" || ! -d "$SECTIONS_DIR" ]]; then
	print_result "_run_sweep_tools returns sections dir" 1 "got: $SECTIONS_DIR"
	echo "Tests run: $TESTS_RUN passed: $TESTS_PASSED failed: $TESTS_FAILED"
	exit 1
fi
print_result "_run_sweep_tools returns sections dir" 0

# --- Assertions ---

# 1. Multi-line shellcheck section round-trips byte-for-byte.
assert_file_eq "shellcheck section round-trips multi-line content" \
	"${SECTIONS_DIR}/shellcheck" "$FIXTURE_SHELLCHECK"

# 2. Multi-line qlty section round-trips byte-for-byte.
assert_file_eq "qlty section round-trips 13-line content" \
	"${SECTIONS_DIR}/qlty" "$FIXTURE_QLTY"

# 3. Multi-line sonar section round-trips and adjacent integer metadata
#    is read independently from the right files.
assert_file_eq "sonar section round-trips multi-line content" \
	"${SECTIONS_DIR}/sonar" "$FIXTURE_SONAR"
assert_file_eq "sweep_gate_status read independently of sonar_section" \
	"${SECTIONS_DIR}/sweep_gate_status" "ERROR"
assert_file_eq "sweep_total_issues read independently of sonar_section" \
	"${SECTIONS_DIR}/sweep_total_issues" "224"
assert_file_eq "sweep_high_critical read independently of sonar_section" \
	"${SECTIONS_DIR}/sweep_high_critical" "12"

# 4. Empty coderabbit section round-trips as empty string.
assert_file_eq "coderabbit section survives empty payload" \
	"${SECTIONS_DIR}/coderabbit" "$FIXTURE_CODERABBIT"

# 5. Last field (review_scan) survives even when previous section has no
#    trailing newline. This was the worst regression in the original
#    `IFS= read -r` chain — the last field commonly came back empty or
#    contained the tail of a previous section.
assert_file_eq "review_scan section survives as last field" \
	"${SECTIONS_DIR}/review_scan" "$FIXTURE_REVIEW_SCAN"

# 6. tool_count and qlty metadata survive too (sanity check on numeric fields).
assert_file_eq "tool_count is captured (5 tools succeeded + coderabbit always-on)" \
	"${SECTIONS_DIR}/tool_count" "6"
assert_file_eq "qlty_smell_count read independently of qlty_section" \
	"${SECTIONS_DIR}/qlty_smell_count" "42"
# t2066: grade is derived from the smell count via _compute_qlty_grade_from_count.
# Derive the expected value the same way so the test doesn't hard-code a grade
# letter — if the config thresholds are retuned, the test will still pass
# without manual edit. This closes the AC "test-quality-sweep-serialization.sh
# asserts against a computed-from-count value so the test doesn't hard-code".
EXPECTED_GRADE=$(_compute_qlty_grade_from_count 42)
assert_file_eq "qlty_grade read independently of qlty_section (derived from count)" \
	"${SECTIONS_DIR}/qlty_grade" "$EXPECTED_GRADE"

# t2066: directly test the grade-from-count mapping against known buckets.
# Fails loudly if QLTY_GRADE_*_MAX thresholds drift away from the documented
# bucket boundaries. If the config is intentionally retuned, update these
# boundary cases accordingly.
test_grade_mapping() {
	local label="$1" count="$2" expected="$3"
	local actual
	actual=$(_compute_qlty_grade_from_count "$count")
	if [[ "$actual" == "$expected" ]]; then
		print_result "grade mapping: $label" 0
	else
		print_result "grade mapping: $label" 1 "count=$count expected=$expected actual=$actual"
	fi
	return 0
}
test_grade_mapping "0 smells → A" 0 A
test_grade_mapping "20 smells → A (upper bound)" 20 A
test_grade_mapping "21 smells → B (lower bound)" 21 B
test_grade_mapping "45 smells → B (upper bound)" 45 B
test_grade_mapping "46 smells → C (lower bound)" 46 C
test_grade_mapping "90 smells → C (upper bound)" 90 C
test_grade_mapping "91 smells → D (lower bound)" 91 D
test_grade_mapping "150 smells → D (upper bound)" 150 D
test_grade_mapping "151 smells → F (lower bound)" 151 F
test_grade_mapping "500 smells → F" 500 F
test_grade_mapping "non-numeric → UNKNOWN" "not-a-number" UNKNOWN

# 7. _quality_sweep_for_repo end-to-end smoke test: stub the issue/comment
#    helpers so it doesn't hit the network, then verify the full pipeline reads
#    every section back into a local variable. The stub writes the captured body
#    to a file because the real call site runs in a subshell.
export CAPTURED_COMMENT_FILE="${TMP_HOME}/captured-comment"
: >"$CAPTURED_COMMENT_FILE"

_ensure_quality_issue() {
	echo "9999"
	return 0
}
_update_quality_issue_body() {
	return 0
}
gh_issue_comment() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--body)
			printf '%s' "$2" >"$CAPTURED_COMMENT_FILE"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done
	return 0
}

rm -rf "$SECTIONS_DIR"
_quality_sweep_for_repo "owner/repo" "/tmp/fake-repo"
CAPTURED_COMMENT=$(cat "$CAPTURED_COMMENT_FILE")

if [[ "$CAPTURED_COMMENT" == *"$FIXTURE_SHELLCHECK"* ]]; then
	print_result "end-to-end: posted comment contains full shellcheck section" 0
else
	print_result "end-to-end: posted comment contains full shellcheck section" 1 "comment was: $CAPTURED_COMMENT"
fi

if [[ "$CAPTURED_COMMENT" == *"$FIXTURE_QLTY"* ]]; then
	print_result "end-to-end: posted comment contains full qlty section" 0
else
	print_result "end-to-end: posted comment contains full qlty section" 1
fi

if [[ "$CAPTURED_COMMENT" == *"$FIXTURE_SONAR"* ]]; then
	print_result "end-to-end: posted comment contains full sonar section" 0
else
	print_result "end-to-end: posted comment contains full sonar section" 1
fi

if [[ "$CAPTURED_COMMENT" == *"$FIXTURE_CODACY"* ]]; then
	print_result "end-to-end: posted comment contains full codacy section" 0
else
	print_result "end-to-end: posted comment contains full codacy section" 1
fi

if [[ "$CAPTURED_COMMENT" == *"$FIXTURE_REVIEW_SCAN"* ]]; then
	print_result "end-to-end: posted comment contains full review_scan section" 0
else
	print_result "end-to-end: posted comment contains full review_scan section" 1
fi

# Cleanup
rm -rf "$TMP_HOME"

echo
echo "Tests run: $TESTS_RUN passed: $TESTS_PASSED failed: $TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
