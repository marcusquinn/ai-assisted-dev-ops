#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-gh-wrapper-auto-sig-body-file.sh — regression guard for GH#23304.
#
# Verifies that wrapper-created PRs/comments using --body-file receive the same
# aidevops signature footer as --body without mutating the caller-owned file and
# without duplicating an existing signature marker.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
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

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

export AIDEVOPS_SIG_CLI="OpenCode"
export AIDEVOPS_SIG_CLI_VERSION="test"
export AIDEVOPS_SIG_MODEL="openai/gpt-5.5"
export AIDEVOPS_SIG_TOKENS="1"

export GH_ARGV_RECORD_FILE="${TEST_ROOT}/gh_argv.log"
export GH_BODY_CAPTURE_FILE="${TEST_ROOT}/gh_body_capture.log"
MOCK_BIN_DIR="${TEST_ROOT}/mockbin"
mkdir -p "$MOCK_BIN_DIR"
cat >"${MOCK_BIN_DIR}/gh" <<'MOCK'
#!/usr/bin/env bash
for arg in "$@"; do
	printf '<%s>\n' "$arg" >>"${GH_ARGV_RECORD_FILE}"
done
while [[ $# -gt 0 ]]; do
	case "$1" in
	--body-file)
		if [[ $# -gt 1 && -r "$2" ]]; then
			cat "$2" >>"${GH_BODY_CAPTURE_FILE}"
			printf '\n--END-BODY--\n' >>"${GH_BODY_CAPTURE_FILE}"
		fi
		shift 2
		;;
	--body-file=*)
		body_file="${1#--body-file=}"
		if [[ -r "$body_file" ]]; then
			cat "$body_file" >>"${GH_BODY_CAPTURE_FILE}"
			printf '\n--END-BODY--\n' >>"${GH_BODY_CAPTURE_FILE}"
		fi
		shift
		;;
	*)
		shift
		;;
	esac
done
case "${1:-} ${2:-}" in
"pr create") printf '%s\n' "https://example.invalid/test/repo/pull/1" ;;
esac
exit 0
MOCK
chmod +x "${MOCK_BIN_DIR}/gh"
export PATH="${MOCK_BIN_DIR}:${PATH}"

SHARED_GH="${TEST_SCRIPTS_DIR}/shared-gh-wrappers.sh"
if [[ ! -f "$SHARED_GH" ]]; then
	printf 'FAIL setup: %s not found\n' "$SHARED_GH" >&2
	exit 1
fi
# shellcheck source=/dev/null
source "$SHARED_GH" >/dev/null 2>&1 || true

_ensure_origin_labels_for_args() { return 0; }
_gh_should_fallback_to_rest() { return 1; }
_rest_should_fallback() { return 1; }
_gh_auto_link_sub_issue() { return 0; }
session_origin_label() { printf '%s' "origin:worker"; return 0; }
detect_session_origin() { printf '%s' "worker"; return 0; }

reset_capture() {
	: >"$GH_ARGV_RECORD_FILE"
	: >"$GH_BODY_CAPTURE_FILE"
	return 0
}

count_captured_signatures() {
	grep -c '<!-- aidevops:sig -->' "$GH_BODY_CAPTURE_FILE" 2>/dev/null || printf '0\n'
	return 0
}

assert_body_file_signed() {
	local name="$1" command_name="$2"
	local body_file="${TEST_ROOT}/${command_name}.md"
	printf '## Summary\n\nBody\n' >"$body_file"
	reset_capture
	if [[ "$command_name" == "pr-create" ]]; then
		gh_create_pr --repo o/r --title "Fix body-file signing" --body-file "$body_file" >/dev/null 2>&1
	else
		gh_pr_comment 1 --repo o/r --body-file "$body_file" >/dev/null 2>&1
	fi
	if [[ "$(count_captured_signatures)" == "1" ]] && ! grep -q '<!-- aidevops:sig -->' "$body_file"; then
		print_result "$name" 0
	else
		print_result "$name" 1 "captured signatures=$(count_captured_signatures), original_mutated=$(grep -c '<!-- aidevops:sig -->' "$body_file" 2>/dev/null || printf '0')"
	fi
	return 0
}

assert_existing_signature_not_duplicated() {
	local body_file="${TEST_ROOT}/already-signed.md"
	printf '## Summary\n\nBody\n\n<!-- aidevops:sig -->\n---\n[aidevops.sh](https://aidevops.sh) existing\n' >"$body_file"
	reset_capture
	gh_pr_comment 1 --repo o/r --body-file="$body_file" >/dev/null 2>&1
	if [[ "$(count_captured_signatures)" == "1" ]]; then
		print_result "body-file existing signature is not duplicated" 0
	else
		print_result "body-file existing signature is not duplicated" 1 "captured signatures=$(count_captured_signatures)"
	fi
	return 0
}

assert_signed_relative_body_file_normalized() {
	local rel_dir="relative-bodies"
	local body_name="already-signed-relative.md"
	local body_file="${TEST_ROOT}/${rel_dir}/${body_name}"
	mkdir -p "${TEST_ROOT}/${rel_dir}"
	printf '## Summary\n\nBody\n\n<!-- aidevops:sig -->\n---\n[aidevops.sh](https://aidevops.sh) existing\n' >"$body_file"
	reset_capture
	(
		cd "$TEST_ROOT" || exit 1
		gh_create_pr --repo o/r --title "Fix relative body-file" --body-file "${rel_dir}/${body_name}" >/dev/null 2>&1
	)
	local abs_count rel_count
	abs_count=$(grep -c "<${body_file}>" "$GH_ARGV_RECORD_FILE" 2>/dev/null || true)
	rel_count=$(grep -c "<${rel_dir}/${body_name}>" "$GH_ARGV_RECORD_FILE" 2>/dev/null || true)
	if [[ "$abs_count" == "1" && "$rel_count" == "0" ]]; then
		print_result "signed relative --body-file is normalized before gh" 0
	else
		print_result "signed relative --body-file is normalized before gh" 1 "abs_count=${abs_count}, rel_count=${rel_count}"
	fi
	return 0
}

assert_missing_body_file_rejected_before_gh() {
	reset_capture
	if gh_create_pr --repo o/r --title "Reject missing body-file" --body-file "missing-body.md" >/dev/null 2>"${TEST_ROOT}/missing.err"; then
		print_result "missing --body-file is rejected before gh" 1 "wrapper returned success"
		return 0
	fi
	local gh_calls rejection_count
	gh_calls=$(wc -l <"$GH_ARGV_RECORD_FILE" | tr -d '[:space:]')
	rejection_count=$(grep -c "body-file 'missing-body.md' does not exist" "${TEST_ROOT}/missing.err" 2>/dev/null || true)
	if [[ "$gh_calls" == "0" && "$rejection_count" == "1" ]]; then
		print_result "missing --body-file is rejected before gh" 0
	else
		print_result "missing --body-file is rejected before gh" 1 "gh_calls=${gh_calls}, rejection_count=${rejection_count}"
	fi
	return 0
}

assert_signature_only_body_rejected_before_gh() {
	reset_capture
	local sig_only_body=$'\n<!-- aidevops:sig -->\n---\n[aidevops.sh](https://aidevops.sh) existing\n'
	if gh_create_pr --repo o/r --title "Reject signature-only body" --body "$sig_only_body" >/dev/null 2>"${TEST_ROOT}/sig-only-body.err"; then
		print_result "signature-only --body is rejected before gh" 1 "wrapper returned success"
		return 0
	fi
	local gh_calls rejection_count
	gh_calls=$(wc -l <"$GH_ARGV_RECORD_FILE" | tr -d '[:space:]')
	rejection_count=$(grep -c "empty body (after trimming whitespace)" "${TEST_ROOT}/sig-only-body.err" 2>/dev/null || true)
	if [[ "$gh_calls" == "0" && "$rejection_count" == "1" ]]; then
		print_result "signature-only --body is rejected before gh" 0
	else
		print_result "signature-only --body is rejected before gh" 1 "gh_calls=${gh_calls}, rejection_count=${rejection_count}"
	fi
	return 0
}

assert_signature_only_body_file_rejected_before_gh() {
	reset_capture
	local body_file="${TEST_ROOT}/signature-only.md"
	printf '\n<!-- aidevops:sig -->\n---\n[aidevops.sh](https://aidevops.sh) existing\n' >"$body_file"
	if gh_create_pr --repo o/r --title "Reject signature-only body-file" --body-file "$body_file" >/dev/null 2>"${TEST_ROOT}/sig-only-file.err"; then
		print_result "signature-only --body-file is rejected before gh" 1 "wrapper returned success"
		return 0
	fi
	local gh_calls rejection_count
	gh_calls=$(wc -l <"$GH_ARGV_RECORD_FILE" | tr -d '[:space:]')
	rejection_count=$(grep -c "has no content before signature footer" "${TEST_ROOT}/sig-only-file.err" 2>/dev/null || true)
	if [[ "$gh_calls" == "0" && "$rejection_count" == "1" ]]; then
		print_result "signature-only --body-file is rejected before gh" 0
	else
		print_result "signature-only --body-file is rejected before gh" 1 "gh_calls=${gh_calls}, rejection_count=${rejection_count}"
	fi
	return 0
}

assert_ephemeral_comment_uses_exact_shim_without_rest_retry() {
	local body_dir="${TEST_ROOT}/aidevops-triage-comment.Ab12Cd"
	local body_file="${body_dir}/comment.md"
	mkdir -p "$body_dir"
	printf 'Validated review\n\n<!-- aidevops:sig -->\n---\nexisting\n' >"$body_file"
	local exact_command=""
	local rest_calls=0
	_gh_with_timeout() {
		local op_class="$1"
		shift
		: "$op_class"
		exact_command="${1:-}"
		return 1
	}
	_rest_should_fallback() {
		rest_calls=$((rest_calls + 1))
		return 0
	}

	local call_status=0
	AIDEVOPS_GH_EPHEMERAL_BODY_FILE="$body_file" \
		gh_issue_comment 1 --repo o/r --body-file "$body_file" \
		>/dev/null 2>&1 || call_status=$?
	if [[ "$call_status" -ne 0 && "$rest_calls" -eq 0 && \
		"$exact_command" == "${TEST_SCRIPTS_DIR}/gh" && -f "$body_file" ]]; then
		print_result "ephemeral comment requires exact shim and disables REST retry" 0
	else
		print_result "ephemeral comment requires exact shim and disables REST retry" 1 \
			"status=${call_status}, rest_calls=${rest_calls}, command=${exact_command}, body_exists=$([[ -f "$body_file" ]] && printf yes || printf no)"
	fi
	return 0
}

assert_body_file_signed "gh_create_pr --body-file signs temp body" "pr-create"
assert_body_file_signed "gh_pr_comment --body-file signs temp body" "pr-comment"
assert_existing_signature_not_duplicated
assert_signed_relative_body_file_normalized
assert_missing_body_file_rejected_before_gh
assert_signature_only_body_rejected_before_gh
assert_signature_only_body_file_rejected_before_gh
assert_ephemeral_comment_uses_exact_shim_without_rest_retry

printf '\n%d tests run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
