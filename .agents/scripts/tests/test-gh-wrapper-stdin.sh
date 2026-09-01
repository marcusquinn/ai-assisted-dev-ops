#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1
TMP="$(mktemp -d -t gh-wrapper-stdin.XXXXXX)" || exit 1
trap 'rm -rf "$TMP"' EXIT

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	local message="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$message"
	return 0
}

fail() {
	local message="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s\n' "$message"
	[[ -n "$detail" ]] && printf '     %s\n' "$detail"
	return 0
}

export AIDEVOPS_TEMP_DIR="${TMP}/bodies"
export AIDEVOPS_GH_SECONDARY_COOLDOWN_OVERRIDE=1
mkdir -p "$AIDEVOPS_TEMP_DIR"
CAPTURED_BODY="${TMP}/captured-body.md"
CAPTURED_MODE="${TMP}/captured-mode.txt"
GH_CALLS="${TMP}/gh-calls.log"
NATIVE_BODY="${TMP}/native-body.md"
REST_BODY="${TMP}/rest-body.md"
export CAPTURED_BODY CAPTURED_MODE GH_CALLS NATIVE_BODY REST_BODY

gh() {
	local previous=""
	local argument body_file=""
	printf '%s\n' "$*" >>"$GH_CALLS"
	for argument in "$@"; do
		if [[ "$previous" == "--body-file" ]]; then
			(stat -f '%Lp' "$argument" 2>/dev/null || stat -c '%a' "$argument") >"$CAPTURED_MODE"
			cp "$argument" "$CAPTURED_BODY"
			break
		fi
		case "$argument" in
		--body-file=*)
			body_file="${argument#--body-file=}"
			(stat -f '%Lp' "$body_file" 2>/dev/null || stat -c '%a' "$body_file") >"$CAPTURED_MODE"
			cp "$body_file" "$CAPTURED_BODY"
			break
			;;
		esac
		previous="$argument"
	done
	if [[ "${1:-} ${2:-}" == "api repos/test/repo" ]]; then
		printf 'false\n'
		return 0
	fi
	if [[ "${1:-} ${2:-}" == "api graphql" ]]; then
		printf 'false\n'
		return 0
	fi
	if [[ "${1:-} ${2:-}" == "api /repos/test/repo/issues/999" ]]; then
		printf 'origin:interactive\n'
		return 0
	fi
	if [[ "${STUB_CREATE_FAIL:-0}" == "1" && "${1:-} ${2:-}" == "issue create" ]]; then
		cp "$CAPTURED_BODY" "$NATIVE_BODY"
		return 1
	fi
	if [[ "${STUB_COMMENT_FAIL:-0}" == "1" && "${1:-} ${2:-}" == "pr comment" ]]; then
		cp "$CAPTURED_BODY" "$NATIVE_BODY"
		return 1
	fi
	if [[ "${1:-} ${2:-}" == "pr create" ]]; then
		printf 'https://github.com/test/repo/pull/999\n'
	else
		printf 'https://github.com/test/repo/issues/999\n'
	fi
	return 0
}
export -f gh

export AIDEVOPS_CONFIG_FILE="${TMP}/missing-config.jsonc"
# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh" >/dev/null 2>&1 || exit 1

printf 'Multiline body\nsecond line\n' |
	gh_create_issue --repo test/repo --title "A substantive issue" --body-file - >/dev/null 2>&1
create_rc=$?
if [[ $create_rc -eq 0 && -f "$CAPTURED_BODY" ]] &&
	grep -q 'Multiline body' "$CAPTURED_BODY" &&
	[[ "$(grep -c '<!-- aidevops:sig -->' "$CAPTURED_BODY")" -eq 1 ]]; then
	pass "issue create buffers stdin and appends one signature"
else
	fail "issue create buffers stdin and appends one signature" "rc=${create_rc}"
fi

if [[ "$(<"$CAPTURED_MODE")" == "600" ]]; then
	pass "stdin body is buffered with mode 600"
else
	fail "stdin body is buffered with mode 600" "mode=$(<"$CAPTURED_MODE")"
fi

remaining_files=$(printf '%s\n' "$AIDEVOPS_TEMP_DIR"/* 2>/dev/null | grep -vc '\*$' || true)
if [[ "$remaining_files" -eq 0 ]]; then
	pass "stdin body temp file is removed after create"
else
	fail "stdin body temp file is removed after create" "remaining=${remaining_files}"
fi

_rest_should_fallback() { return 0; }
_rest_issue_create() {
	local previous=""
	local argument body_file=""
	for argument in "$@"; do
		if [[ "$previous" == "--body-file" ]]; then
			body_file="$argument"
			break
		fi
		case "$argument" in
		--body-file=*)
			body_file="${argument#--body-file=}"
			break
			;;
		esac
		previous="$argument"
	done
	cp "$body_file" "$REST_BODY"
	printf 'https://github.com/test/repo/issues/1000\n'
	return 0
}
export STUB_CREATE_FAIL=1
printf 'Fallback body\n' | gh_create_issue --repo test/repo --assignee testuser \
	--title "Fallback preserves stdin" --body-file - >/dev/null 2>&1
fallback_rc=$?
unset STUB_CREATE_FAIL
if [[ $fallback_rc -eq 0 && -f "$NATIVE_BODY" && -f "$REST_BODY" ]] &&
	cmp -s "$NATIVE_BODY" "$REST_BODY" &&
	[[ "$(grep -c '<!-- aidevops:sig -->' "$REST_BODY")" -eq 1 ]]; then
	pass "native and REST fallback reuse the same once-signed stdin body"
else
	fail "native and REST fallback reuse the same once-signed stdin body" "rc=${fallback_rc}"
fi

_rest_pr_comment() {
	local previous=""
	local argument body_file=""
	for argument in "$@"; do
		if [[ "$previous" == "--body-file" ]]; then
			body_file="$argument"
			break
		fi
		case "$argument" in
		--body-file=*)
			body_file="${argument#--body-file=}"
			break
			;;
		esac
		previous="$argument"
	done
	cp "$body_file" "$REST_BODY"
	printf 'https://github.com/test/repo/pull/1001#issuecomment-3\n'
	return 0
}
: >"$NATIVE_BODY"
: >"$REST_BODY"
export STUB_COMMENT_FAIL=1
printf 'Comment fallback body\n' | gh_pr_comment 456 --repo test/repo \
	--body-file - >/dev/null 2>&1
comment_fallback_rc=$?
unset STUB_COMMENT_FAIL
if [[ $comment_fallback_rc -eq 0 && -s "$NATIVE_BODY" && -s "$REST_BODY" ]] &&
	cmp -s "$NATIVE_BODY" "$REST_BODY" &&
	[[ "$(grep -c '<!-- aidevops:sig -->' "$REST_BODY")" -eq 1 ]]; then
	pass "native and REST comment fallback reuse the same once-signed stdin body"
else
	fail "native and REST comment fallback reuse the same once-signed stdin body" \
		"rc=${comment_fallback_rc}"
fi

: >"$GH_CALLS"
printf 'Pull request body\n' |
	gh_create_pr --repo test/repo --title "A substantive PR" --body-file=- >/dev/null 2>&1
pr_create_rc=$?
if [[ $pr_create_rc -eq 0 ]] && grep -q 'Pull request body' "$CAPTURED_BODY" &&
	[[ "$(grep -c '<!-- aidevops:sig -->' "$CAPTURED_BODY")" -eq 1 ]]; then
	pass "PR create accepts equals-form stdin and appends one signature"
else
	fail "PR create accepts equals-form stdin and appends one signature" "rc=${pr_create_rc}"
fi

: >"$GH_CALLS"
printf '' | gh_create_pr --repo test/repo --title "A substantive PR" --body-file - >/dev/null 2>&1
empty_rc=$?
if [[ $empty_rc -eq 1 && ! -s "$GH_CALLS" ]]; then
	pass "empty stdin is rejected before a GitHub write"
else
	fail "empty stdin is rejected before a GitHub write" "rc=${empty_rc}"
fi

: >"$GH_CALLS"
printf '%s\n' '<!-- aidevops:sig -->' |
	gh_create_pr --repo test/repo --title "A substantive PR" --body-file - >/dev/null 2>&1
signature_only_rc=$?
if [[ $signature_only_rc -eq 1 && ! -s "$GH_CALLS" ]]; then
	pass "signature-only stdin is rejected before a GitHub write"
else
	fail "signature-only stdin is rejected before a GitHub write" "rc=${signature_only_rc}"
fi

STUB_BIN="${TMP}/bin"
mkdir -p "$STUB_BIN"
cat >"${STUB_BIN}/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_CALLS"
case "${1:-} ${2:-}" in
"issue view" | "pr view") printf '%s\n' '{"title":"Existing","body":"Existing","labels":[]}' ;;
"api repos/test/repo" | "api graphql") printf '%s\n' 'false' ;;
"api /repos/test/repo/issues/999") printf '%s\n' 'origin:interactive' ;;
"issue create") printf '%s\n' 'https://github.com/test/repo/issues/999' ;;
"issue comment") printf '%s\n' 'https://github.com/test/repo/issues/999#issuecomment-1' ;;
"pr create") printf '%s\n' 'https://github.com/test/repo/pull/999' ;;
"pr comment") printf '%s\n' 'https://github.com/test/repo/pull/999#issuecomment-2' ;;
esac
exit 0
STUB
chmod +x "${STUB_BIN}/gh"

EXECUTABLE_CREATE_BODY="${TMP}/executable-create-body.md"
printf 'Executable path-backed issue body\n' >"$EXECUTABLE_CREATE_BODY"
: >"$GH_CALLS"
PATH="${STUB_BIN}:$PATH" "${SCRIPTS_DIR}/gh-write-helper.sh" issue create \
	--repo test/repo --title "Executable issue create" \
	--body-file "$EXECUTABLE_CREATE_BODY" >/dev/null 2>&1
issue_create_rc=$?
if [[ $issue_create_rc -eq 0 ]] && [[ "$(grep -c '^issue create ' "$GH_CALLS")" -eq 1 ]]; then
	pass "standalone helper routes path-backed issue creation exactly once"
else
	fail "standalone helper routes path-backed issue creation exactly once" "rc=${issue_create_rc}"
fi

: >"$GH_CALLS"
printf 'Executable streamed PR body\n' | PATH="${STUB_BIN}:$PATH" \
	"${SCRIPTS_DIR}/gh-write-helper.sh" pr create --repo test/repo \
	--title "Executable PR create" --body-file - >/dev/null 2>&1
pr_create_helper_rc=$?
if [[ $pr_create_helper_rc -eq 0 ]] && [[ "$(grep -c '^pr create ' "$GH_CALLS")" -eq 1 ]]; then
	pass "standalone helper routes streamed PR creation exactly once"
else
	fail "standalone helper routes streamed PR creation exactly once" "rc=${pr_create_helper_rc}"
fi

EXECUTABLE_COMMENT_BODY="${TMP}/executable-comment-body.md"
printf 'Executable path-backed issue comment\n' >"$EXECUTABLE_COMMENT_BODY"
: >"$GH_CALLS"
PATH="${STUB_BIN}:$PATH" "${SCRIPTS_DIR}/gh-write-helper.sh" issue comment 123 \
	--repo test/repo --body-file "$EXECUTABLE_COMMENT_BODY" >/dev/null 2>&1
issue_comment_rc=$?
if [[ $issue_comment_rc -eq 0 ]] && [[ "$(grep -c '^issue comment 123 ' "$GH_CALLS")" -eq 1 ]] &&
	grep -q 'Executable path-backed issue comment' "$CAPTURED_BODY" &&
	[[ "$(grep -c '<!-- aidevops:sig -->' "$CAPTURED_BODY")" -eq 1 ]]; then
	pass "standalone helper routes a path-backed issue comment with one signature"
else
	fail "standalone helper routes a path-backed issue comment with one signature" \
		"rc=${issue_comment_rc}"
fi

: >"$GH_CALLS"
printf 'Executable streamed PR comment\n' | PATH="${STUB_BIN}:$PATH" \
	"${SCRIPTS_DIR}/gh-write-helper.sh" pr comment 456 --repo test/repo \
	--body-file - >/dev/null 2>&1
pr_comment_rc=$?
if [[ $pr_comment_rc -eq 0 ]] && [[ "$(grep -c '^pr comment 456 ' "$GH_CALLS")" -eq 1 ]] &&
	grep -q 'Executable streamed PR comment' "$CAPTURED_BODY" &&
	[[ "$(grep -c '<!-- aidevops:sig -->' "$CAPTURED_BODY")" -eq 1 ]]; then
	pass "standalone helper routes a streamed PR comment with one signature"
else
	fail "standalone helper routes a streamed PR comment with one signature" "rc=${pr_comment_rc}"
fi

: >"$GH_CALLS"
printf '' | PATH="${STUB_BIN}:$PATH" "${SCRIPTS_DIR}/gh-write-helper.sh" issue comment 123 \
	--repo test/repo --body-file - >/dev/null 2>&1
empty_comment_rc=$?
if [[ $empty_comment_rc -eq 1 && ! -s "$GH_CALLS" ]]; then
	pass "standalone helper rejects an empty comment before a GitHub write"
else
	fail "standalone helper rejects an empty comment before a GitHub write" "rc=${empty_comment_rc}"
fi

: >"$GH_CALLS"
printf '%s\n' '<!-- aidevops:sig -->' | PATH="${STUB_BIN}:$PATH" \
	"${SCRIPTS_DIR}/gh-write-helper.sh" pr comment 456 --repo test/repo \
	--body-file - >/dev/null 2>&1
signature_only_comment_rc=$?
if [[ $signature_only_comment_rc -eq 1 && ! -s "$GH_CALLS" ]]; then
	pass "standalone helper rejects a signature-only comment before a GitHub write"
else
	fail "standalone helper rejects a signature-only comment before a GitHub write" \
		"rc=${signature_only_comment_rc}"
fi

: >"$GH_CALLS"
printf '' | PATH="${STUB_BIN}:$PATH" "${SCRIPTS_DIR}/gh-write-helper.sh" issue create \
	--repo test/repo --title "Rejected empty issue" --body-file - >/dev/null 2>&1
empty_helper_rc=$?
if [[ $empty_helper_rc -eq 1 && ! -s "$GH_CALLS" ]]; then
	pass "standalone helper rejects an empty create body before a GitHub write"
else
	fail "standalone helper rejects an empty create body before a GitHub write" "rc=${empty_helper_rc}"
fi

: >"$GH_CALLS"
PATH="${STUB_BIN}:$PATH" "${SCRIPTS_DIR}/gh-write-helper.sh" issue delete 123 \
	--repo test/repo >/dev/null 2>&1
unsupported_helper_rc=$?
if [[ $unsupported_helper_rc -eq 2 && ! -s "$GH_CALLS" ]]; then
	pass "standalone helper rejects unsupported actions before a GitHub write"
else
	fail "standalone helper rejects unsupported actions before a GitHub write" "rc=${unsupported_helper_rc}"
fi

: >"$GH_CALLS"
printf 'Edited body\n' | PATH="${STUB_BIN}:$PATH" \
	"${SCRIPTS_DIR}/gh-write-helper.sh" issue edit 123 --repo test/repo --body-file - >/dev/null 2>&1
edit_rc=$?
if [[ $edit_rc -eq 0 ]] && grep -q '^issue edit 123 ' "$GH_CALLS"; then
	pass "standalone helper performs a safe issue edit"
else
	fail "standalone helper performs a safe issue edit" "rc=${edit_rc}"
fi

remaining_files=$(printf '%s\n' "$AIDEVOPS_TEMP_DIR"/* 2>/dev/null | grep -vc '\*$' || true)
if [[ "$remaining_files" -eq 0 ]]; then
	pass "standalone helper removes its stdin body temp file"
else
	fail "standalone helper removes its stdin body temp file" "remaining=${remaining_files}"
fi

: >"$GH_CALLS"
PATH="${STUB_BIN}:$PATH" "${SCRIPTS_DIR}/gh-write-helper.sh" \
	pr edit 456 --repo test/repo --add-label reviewed >/dev/null 2>&1
label_rc=$?
if [[ $label_rc -eq 0 ]] && grep -q '^pr edit 456 .*--add-label reviewed' "$GH_CALLS"; then
	pass "standalone helper permits audited relationship and label edits"
else
	fail "standalone helper permits audited relationship and label edits" "rc=${label_rc}"
fi

if [[ $TESTS_FAILED -eq 0 ]]; then
	printf '%d/%d tests passed\n' "$TESTS_RUN" "$TESTS_RUN"
	exit 0
fi
printf '%d/%d tests failed\n' "$TESTS_FAILED" "$TESTS_RUN"
exit 1
