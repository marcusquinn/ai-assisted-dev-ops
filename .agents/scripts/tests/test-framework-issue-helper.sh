#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Regression tests for framework-issue-helper.sh duplicate issue parsing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HELPER="${SCRIPT_DIR}/../framework-issue-helper.sh"

PASS=0
FAIL=0

pass() {
	local name="$1"
	PASS=$((PASS + 1))
	printf 'PASS: %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	FAIL=$((FAIL + 1))
	printf 'FAIL: %s — %s\n' "$name" "$detail"
	return 0
}

assert_contains() {
	local output="$1"
	local expected="$2"
	local name="$3"

	if grep -Fq -- "$expected" <<<"$output"; then
		pass "$name"
	else
		fail "$name" "expected ${expected}; got: ${output}"
	fi
	return 0
}

assert_not_contains() {
	local output="$1"
	local unexpected="$2"
	local name="$3"

	if grep -Fq -- "$unexpected" <<<"$output"; then
		fail "$name" "unexpected ${unexpected}; got: ${output}"
	else
		pass "$name"
	fi
	return 0
}

run_case() {
	local duplicate_value="$1"
	local created_url="$2"
	local stub_dir="$3"
	local output_file="$4"

	cat >"${stub_dir}/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${TEST_GH_TRACE:-}" ]]; then
	printf '%s\n' "$*" >>"$TEST_GH_TRACE"
fi

if [[ "${1:-}" == "auth" && "${2:-}" == "status" ]]; then
	[[ "${TEST_AUTH_STATUS_FAIL:-0}" == "1" ]] && exit 1
	exit 0
fi

if [[ "${1:-}" == "issue" && "${2:-}" == "list" ]]; then
	printf '%s\n' "${TEST_DUPLICATE_VALUE:-}"
	exit 0
fi

if [[ "${1:-}" == "issue" && "${2:-}" == "create" ]]; then
	printf '%s\n' "${TEST_CREATED_URL:-https://github.com/marcusquinn/aidevops/issues/9001}"
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "graphql" ]]; then
	printf '"testuser"\n'
	exit 0
fi

exit 0
EOF
	chmod +x "${stub_dir}/gh"

	if TEST_DUPLICATE_VALUE="$duplicate_value" \
		TEST_CREATED_URL="$created_url" \
		PATH="${stub_dir}:$PATH" \
		"$HELPER" log --title "fix: duplicate parser regression" --body "body" >"$output_file" 2>&1; then
		return 0
	fi

	return 1
}

run_auto_dispatch_case() {
	local stub_dir="$1"
	local output_file="$2"
	local trace_file="$3"

	if TEST_DUPLICATE_VALUE="" \
		TEST_CREATED_URL="https://github.com/marcusquinn/aidevops/issues/9100" \
		TEST_GH_TRACE="$trace_file" \
		PATH="${stub_dir}:$PATH" \
		"$HELPER" log --title "fix: auto dispatch labels" --body "body" --label bug --auto-dispatch --tier standard >"$output_file" 2>&1; then
		return 0
	fi

	return 1
}

run_auto_dispatch_equals_case() {
	local stub_dir="$1"
	local output_file="$2"
	local trace_file="$3"

	if TEST_DUPLICATE_VALUE="" \
		TEST_CREATED_URL="https://github.com/marcusquinn/aidevops/issues/9101" \
		TEST_GH_TRACE="$trace_file" \
		PATH="${stub_dir}:$PATH" \
		"$HELPER" log --title="fix: auto dispatch equals labels" --body="body" --label=enhancement --auto-dispatch --tier=thinking >"$output_file" 2>&1; then
		return 0
	fi

	return 1
}

run_default_dispatch_case() {
	local stub_dir="$1"
	local output_file="$2"
	local trace_file="$3"

	if TEST_DUPLICATE_VALUE="" \
		TEST_CREATED_URL="https://github.com/marcusquinn/aidevops/issues/9104" \
		TEST_GH_TRACE="$trace_file" \
		PATH="${stub_dir}:$PATH" \
		"$HELPER" log --title "fix: default dispatch labels" --body "body" --label bug >"$output_file" 2>&1; then
		return 0
	fi

	return 1
}

run_manual_hold_case() {
	local stub_dir="$1"
	local output_file="$2"
	local trace_file="$3"

	if TEST_DUPLICATE_VALUE="" \
		TEST_CREATED_URL="https://github.com/marcusquinn/aidevops/issues/9105" \
		TEST_GH_TRACE="$trace_file" \
		PATH="${stub_dir}:$PATH" \
		"$HELPER" log --title "fix: durable manual hold" --body "body" --label bug \
		--no-auto-dispatch --hold-reason "Requires an unresolved authority decision" >"$output_file" 2>&1; then
		return 0
	fi

	return 1
}

run_flag_value_case() {
	local stub_dir="$1"
	local output_file="$2"
	local trace_file="$3"

	if TEST_DUPLICATE_VALUE="" \
		TEST_CREATED_URL="https://github.com/marcusquinn/aidevops/issues/9103" \
		TEST_GH_TRACE="$trace_file" \
		PATH="${stub_dir}:$PATH" \
		"$HELPER" log --title "--title-looking value" --body "body with spaces" --label "triage label" --tier "custom-tier" >"$output_file" 2>&1; then
		return 0
	fi

	return 1
}

run_missing_value_case() {
	local stub_dir="$1"
	local output_file="$2"

	if TEST_DUPLICATE_VALUE="" \
		TEST_CREATED_URL="https://github.com/marcusquinn/aidevops/issues/9102" \
		PATH="${stub_dir}:$PATH" \
		"$HELPER" log --title >"$output_file" 2>&1; then
		return 0
	fi

	return 1
}

TMP_DIR=$(mktemp -d -t framework-issue-helper-test.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

empty_output="${TMP_DIR}/empty.out"
run_case "[]" "https://github.com/marcusquinn/aidevops/issues/9001" "${TMP_DIR}" "$empty_output"
empty_text=$(<"$empty_output")
assert_contains "$empty_text" "status=created" "empty array result continues to issue creation"
assert_not_contains "$empty_text" "status=duplicate" "empty array result is not duplicate"
assert_not_contains "$empty_text" "issue_num=[]" "empty array result never emits issue_num=[]"

malformed_output="${TMP_DIR}/malformed.out"
run_case "not-a-number" "https://github.com/marcusquinn/aidevops/issues/9002" "${TMP_DIR}" "$malformed_output"
malformed_text=$(<"$malformed_output")
assert_contains "$malformed_text" "status=created" "malformed duplicate result continues to issue creation"
assert_not_contains "$malformed_text" "status=duplicate" "malformed duplicate result is not duplicate"

api_auth_output="${TMP_DIR}/api-auth.out"
TEST_AUTH_STATUS_FAIL=1 run_case "[]" \
	"https://github.com/marcusquinn/aidevops/issues/9004" "${TMP_DIR}" "$api_auth_output"
api_auth_text=$(<"$api_auth_output")
assert_contains "$api_auth_text" "status=created" \
	"working API token overrides stale keyring auth status"

valid_output="${TMP_DIR}/valid.out"
run_case "12345" "https://github.com/marcusquinn/aidevops/issues/9003" "${TMP_DIR}" "$valid_output"
valid_text=$(<"$valid_output")
assert_contains "$valid_text" "status=duplicate" "valid duplicate result skips creation"
assert_contains "$valid_text" "issue_num=12345" "valid duplicate result emits numeric issue number"
assert_contains "$valid_text" "issue_url=https://github.com/marcusquinn/aidevops/issues/12345" "valid duplicate result emits valid issue URL"

invalid_create_output="${TMP_DIR}/invalid-create.out"
if run_case "" "https://github.com/marcusquinn/aidevops/issues/[]" "${TMP_DIR}" "$invalid_create_output"; then
	fail "invalid created issue URL is rejected" "helper succeeded for invalid created URL"
else
	invalid_create_text=$(<"$invalid_create_output")
	assert_not_contains "$invalid_create_text" "issue_url=https://github.com/marcusquinn/aidevops/issues/[]" "invalid created issue URL is not emitted"
fi

default_dispatch_output="${TMP_DIR}/default-dispatch.out"
default_dispatch_trace="${TMP_DIR}/default-dispatch.trace"
if run_default_dispatch_case "${TMP_DIR}" "$default_dispatch_output" "$default_dispatch_trace"; then
	default_dispatch_text=$(<"$default_dispatch_output")
	default_dispatch_calls=$(<"$default_dispatch_trace")
	assert_contains "$default_dispatch_text" "status=created" "default dispatch case creates issue"
	assert_contains "$default_dispatch_calls" "--label auto-dispatch" "framework issues auto-dispatch by default"
	assert_contains "$default_dispatch_calls" "--label tier:standard" "default dispatch uses tier standard"
	assert_contains "$default_dispatch_calls" "--label status:available" "default dispatch includes available status"
	assert_not_contains "$default_dispatch_calls" "--label no-auto-dispatch" "default dispatch does not add a manual hold"
else
	fail "default dispatch case creates issue" "helper failed"
fi

manual_hold_output="${TMP_DIR}/manual-hold.out"
manual_hold_trace="${TMP_DIR}/manual-hold.trace"
if run_manual_hold_case "${TMP_DIR}" "$manual_hold_output" "$manual_hold_trace"; then
	manual_hold_text=$(<"$manual_hold_output")
	manual_hold_calls=$(<"$manual_hold_trace")
	assert_contains "$manual_hold_text" "status=created" "documented manual hold creates issue"
	assert_contains "$manual_hold_calls" "--label no-auto-dispatch" "documented manual hold adds no-auto-dispatch"
	assert_contains "$manual_hold_calls" "--label status:blocked" "documented manual hold uses blocked status"
	assert_contains "$manual_hold_calls" "## Dispatch Hold" "documented manual hold records a body section"
	assert_contains "$manual_hold_calls" "Requires an unresolved authority decision" "documented manual hold records its reason"
	assert_not_contains "$manual_hold_calls" "--label auto-dispatch" "documented manual hold excludes auto-dispatch"
else
	fail "documented manual hold creates issue" "helper failed"
fi

missing_hold_reason_output="${TMP_DIR}/missing-hold-reason.out"
missing_hold_reason_trace="${TMP_DIR}/missing-hold-reason.trace"
if TEST_DUPLICATE_VALUE="" TEST_GH_TRACE="$missing_hold_reason_trace" PATH="${TMP_DIR}:$PATH" \
	"$HELPER" log --title "fix: undocumented manual hold" --body "body" --no-auto-dispatch >"$missing_hold_reason_output" 2>&1; then
	fail "undocumented manual hold is rejected" "helper succeeded without --hold-reason"
else
	missing_hold_reason_text=$(<"$missing_hold_reason_output")
	assert_contains "$missing_hold_reason_text" "requires --hold-reason" "undocumented manual hold explains the required reason"
	if [[ -f "$missing_hold_reason_trace" ]]; then
		missing_hold_reason_calls=$(<"$missing_hold_reason_trace")
		assert_not_contains "$missing_hold_reason_calls" "issue create" "undocumented manual hold creates no issue"
	else
		pass "undocumented manual hold creates no issue"
	fi
fi

auto_dispatch_output="${TMP_DIR}/auto-dispatch.out"
auto_dispatch_trace="${TMP_DIR}/auto-dispatch.trace"
if run_auto_dispatch_case "${TMP_DIR}" "$auto_dispatch_output" "$auto_dispatch_trace"; then
	auto_dispatch_text=$(<"$auto_dispatch_output")
	auto_dispatch_calls=$(<"$auto_dispatch_trace")
	assert_contains "$auto_dispatch_text" "status=created" "auto-dispatch case creates issue"
	assert_contains "$auto_dispatch_calls" "issue create" "auto-dispatch case uses issue creation"
	assert_contains "$auto_dispatch_calls" "--label bug" "auto-dispatch case preserves requested label"
	assert_contains "$auto_dispatch_calls" "--label auto-dispatch" "auto-dispatch case passes auto-dispatch at create time"
	assert_contains "$auto_dispatch_calls" "--label tier:standard" "auto-dispatch case passes tier at create time"
	assert_contains "$auto_dispatch_calls" "--label status:available" "auto-dispatch case includes worker-ready status label"
	assert_not_contains "$auto_dispatch_calls" "issue edit" "auto-dispatch case avoids post-create issue edits"
else
	fail "auto-dispatch case creates issue" "helper failed"
fi

auto_dispatch_equals_output="${TMP_DIR}/auto-dispatch-equals.out"
auto_dispatch_equals_trace="${TMP_DIR}/auto-dispatch-equals.trace"
if run_auto_dispatch_equals_case "${TMP_DIR}" "$auto_dispatch_equals_output" "$auto_dispatch_equals_trace"; then
	auto_dispatch_equals_text=$(<"$auto_dispatch_equals_output")
	auto_dispatch_equals_calls=$(<"$auto_dispatch_equals_trace")
	assert_contains "$auto_dispatch_equals_text" "status=created" "auto-dispatch equals case creates issue"
	assert_contains "$auto_dispatch_equals_calls" "--label enhancement" "auto-dispatch equals case parses --label=value"
	assert_contains "$auto_dispatch_equals_calls" "--label auto-dispatch" "auto-dispatch equals case passes auto-dispatch"
	assert_contains "$auto_dispatch_equals_calls" "--label tier:thinking" "auto-dispatch equals case parses --tier=value"
	assert_contains "$auto_dispatch_equals_calls" "--label status:available" "auto-dispatch equals case includes worker-ready status label"
else
	fail "auto-dispatch equals case creates issue" "helper failed"
fi

flag_value_output="${TMP_DIR}/flag-value.out"
flag_value_trace="${TMP_DIR}/flag-value.trace"
if run_flag_value_case "${TMP_DIR}" "$flag_value_output" "$flag_value_trace"; then
	flag_value_text=$(<"$flag_value_output")
	flag_value_calls=$(<"$flag_value_trace")
	assert_contains "$flag_value_text" "status=created" "space-separated flag values create issue"
	assert_contains "$flag_value_calls" "--title --title-looking value" "space-separated title preserves leading dash value"
	assert_contains "$flag_value_calls" "--body body with spaces" "space-separated body preserves spaces"
	assert_contains "$flag_value_calls" "--label triage label" "space-separated label preserves spaces"
	assert_contains "$flag_value_calls" "--label tier:custom-tier" "space-separated tier creates tier label"
else
	fail "space-separated flag values create issue" "helper failed"
fi

missing_value_output="${TMP_DIR}/missing-value.out"
if run_missing_value_case "${TMP_DIR}" "$missing_value_output"; then
	fail "missing option value is rejected" "helper succeeded without a required value"
else
	missing_value_text=$(<"$missing_value_output")
	assert_contains "$missing_value_text" "--title requires a value" "missing option value explains the failing flag"
fi

help_output="${TMP_DIR}/help.out"
"$HELPER" help >"$help_output" 2>&1
help_text=$(<"$help_output")
assert_contains "$help_text" "--auto-dispatch" "usage documents auto-dispatch flag"
assert_contains "$help_text" "--tier TIER" "usage documents tier flag"
assert_contains "$help_text" "--no-auto-dispatch" "usage documents durable manual hold flag"
assert_contains "$help_text" "--hold-reason TEXT" "usage documents required hold reason"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi

exit 0
