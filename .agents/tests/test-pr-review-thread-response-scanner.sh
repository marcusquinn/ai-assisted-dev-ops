#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCANNER="${SCRIPT_DIR}/../scripts/pr-review-thread-response-scanner.sh"

TESTS_PASSED=0
TESTS_FAILED=0
TEST_TMPDIR=""

_setup() {
	TEST_TMPDIR="$(mktemp -d)"
	return 0
}

_teardown() {
	[[ -n "$TEST_TMPDIR" && -d "$TEST_TMPDIR" ]] && rm -rf "$TEST_TMPDIR"
	return 0
}

_pass() {
	local name="$1"
	TESTS_PASSED=$((TESTS_PASSED + 1))
	printf '  [PASS] %s\n' "$name"
	return 0
}

_fail() {
	local name="$1"
	local reason="${2:-}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  [FAIL] %s%s\n' "$name" "${reason:+ — $reason}"
	return 0
}

_write_fake_gh() {
	local fake_bin="$1"
	mkdir -p "$fake_bin"
	cat >"${fake_bin}/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "pr" && "${2:-}" == "list" ]]; then
	printf '123\tReview thread fixture\tfalse\t\tfixture-branch\t1111111111111111111111111111111111111111\tcollaborator\n'
	exit 0
fi

if [[ "${1:-}" == "pr" && "${2:-}" == "view" ]]; then
	if [[ "$*" == *"--json isCrossRepository"* ]]; then
		printf 'false\n'
	else
		printf 'Review thread fixture\tfixture-branch\t1111111111111111111111111111111111111111\tcollaborator\n'
	fi
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "graphql" ]]; then
	printf '%s\n' "$*" >>"${FAKE_GH_CAPTURE:?}"
	if [[ "$*" == *"addPullRequestReviewThreadReply"* ]]; then
		while [[ "$#" -gt 0 ]]; do
			if [[ ( "${1:-}" == "-F" || "${1:-}" == "-f" ) && "${2:-}" == body=* ]]; then
				printf '%s' "${2#body=}" >"${FAKE_GH_REPLY_CAPTURE:?}"
				printf '%s' "${1:-}" >"${FAKE_GH_REPLY_FLAG_CAPTURE:-/dev/null}"
				break
			fi
			shift
		done
		printf '%s\n' '{"data":{"addPullRequestReviewThreadReply":{"comment":{"id":"COMMENT_1","url":""}}}}'
		exit 0
	fi
	if [[ "$*" == *"-F thread="* && "$*" == *"comments(first: 1)"* ]]; then
		printf '%s\n' '{"data":{"node":{"comments":{"nodes":[{"author":{"login":"gemini-code-assist"}}]}}}}'
		exit 0
	fi
	printf '%s\n' '{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[{"id":"THREAD_1","isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":{"login":"coderabbitai"},"path":"script.sh","line":12,"url":"","body":"fixture","diffHunk":"@@","updatedAt":"2026-06-01T00:00:00Z"}]}}]}}}}}'
	exit 0
fi

if [[ "${1:-}" == "api" && "${2:-}" == "rate_limit" ]]; then
	if [[ "$*" == *"--jq"* ]]; then
		printf '%s\n' '100'
		exit 0
	fi
	printf '%s\n' '{"resources":{"graphql":{"remaining":100},"core":{"remaining":100}}}'
	exit 0
fi

printf 'unexpected gh invocation: %s\n' "$*" >&2
exit 2
FAKE_GH
	chmod +x "${fake_bin}/gh"
	return 0
}

_write_fake_git() {
	local fake_bin="$1"
	cat >"${fake_bin}/git" <<'FAKE_GIT'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$*" == *"check-ref-format --branch"* ]]; then
	exit 0
fi
if [[ "$*" == *"worktree list --porcelain"* ]]; then
	printf 'worktree %s\nHEAD %s\nbranch refs/heads/fixture-branch\n\n' \
		"${FAKE_WORKTREE_PATH:?}" '1111111111111111111111111111111111111111'
	exit 0
fi
if [[ "$*" == *"rev-parse HEAD"* ]]; then
	printf '1111111111111111111111111111111111111111\n'
	exit 0
fi
exit 1
FAKE_GIT
	chmod +x "${fake_bin}/git"
	return 0
}

test_scan_passes_nonempty_owner_and_name_to_graphql() {
	printf '==> scan passes parsed repo owner/name to GraphQL\n'
	_setup
	local fake_bin="${TEST_TMPDIR}/bin"
	local capture="${TEST_TMPDIR}/gh-args.log"
	local output=""
	_write_fake_gh "$fake_bin"

	output="$(FAKE_GH_CAPTURE="$capture" PATH="${fake_bin}:$PATH" "$SCANNER" scan "marcusquinn/aidevops")"
	if [[ "$output" == 123$'\t'* ]]; then
		_pass "scan emits unresolved review-thread candidate"
	else
		_fail "scan emits unresolved review-thread candidate" "output: ${output}"
	fi

	if grep -q -- '-F owner=marcusquinn' "$capture" && grep -q -- '-F name=aidevops' "$capture"; then
		_pass "GraphQL owner/name flags are non-empty"
	else
		_fail "GraphQL owner/name flags are non-empty" "captured: $(tr '\n' ';' <"$capture")"
	fi

	_teardown
	return 0
}

test_reply_recognises_existing_mention_after_whitespace_and_comment() {
	printf '==> reply recognises author mention after blank/comment lines\n'
	_setup
	local fake_bin="${TEST_TMPDIR}/bin"
	local capture="${TEST_TMPDIR}/gh-args.log"
	local reply_capture="${TEST_TMPDIR}/reply-body.txt"
	local body_file="${TEST_TMPDIR}/body.md"
	local expected=$'   \n\t<!-- generated marker -->  \n@gemini-code-assist already handled'
	_write_fake_gh "$fake_bin"
	printf '%s' "$expected" >"$body_file"

	if FAKE_GH_CAPTURE="$capture" FAKE_GH_REPLY_CAPTURE="$reply_capture" PATH="${fake_bin}:$PATH" "$SCANNER" reply "marcusquinn/aidevops" "THREAD_1" "$body_file"; then
		_pass "reply command succeeds"
	else
		_fail "reply command succeeds"
	fi

	local actual=""
	actual="$(<"$reply_capture")"
	if [[ "$actual" == "$expected" ]]; then
		_pass "existing mention is not duplicated"
	else
		_fail "existing mention is not duplicated" "body: ${actual}"
	fi

	_teardown
	return 0
}

test_reply_prepends_author_when_first_content_is_not_mention() {
	printf '==> reply prepends author when first content is not a mention\n'
	_setup
	local fake_bin="${TEST_TMPDIR}/bin"
	local capture="${TEST_TMPDIR}/gh-args.log"
	local reply_capture="${TEST_TMPDIR}/reply-body.txt"
	local body_file="${TEST_TMPDIR}/body.md"
	local body=$'   \n<!-- generated marker-->\nPlease fix this.'
	local expected="@gemini-code-assist ${body}"
	_write_fake_gh "$fake_bin"
	printf '%s' "$body" >"$body_file"

	if FAKE_GH_CAPTURE="$capture" FAKE_GH_REPLY_CAPTURE="$reply_capture" PATH="${fake_bin}:$PATH" "$SCANNER" reply "marcusquinn/aidevops" "THREAD_1" "$body_file"; then
		_pass "reply command succeeds without existing mention"
	else
		_fail "reply command succeeds without existing mention"
	fi

	local actual=""
	actual="$(<"$reply_capture")"
	if [[ "$actual" == "$expected" ]]; then
		_pass "author mention is prepended"
	else
		_fail "author mention is prepended" "body: ${actual}"
	fi

	_teardown
	return 0
}

test_dispatch_prompt_includes_thread_fingerprint() {
	printf '==> dispatch prompt includes unresolved thread IDs\n'
	_setup
	local fake_bin="${TEST_TMPDIR}/bin"
	local capture="${TEST_TMPDIR}/gh-args.log"
	local fake_headless="${TEST_TMPDIR}/headless-runtime-helper.sh"
	local state_dir="${TEST_TMPDIR}/state"
	local prompt_file="${state_dir}/marcusquinn-aidevops-123-prompt.md"
	local worker_path="${TEST_TMPDIR}/existing-review-worktree"
	_write_fake_gh "$fake_bin"
	_write_fake_git "$fake_bin"
	mkdir -p "$(dirname "$fake_headless")"
	mkdir -p "$worker_path"
	cat >"$fake_headless" <<'FAKE_HEADLESS'
#!/usr/bin/env bash
set -euo pipefail
exit 0
FAKE_HEADLESS
	chmod +x "$fake_headless"

	if FAKE_GH_CAPTURE="$capture" \
		FAKE_WORKTREE_PATH="$worker_path" \
		AIDEVOPS_PR_REVIEW_THREAD_RESPONSE_STATE_DIR="$state_dir" \
		HEADLESS_RUNTIME_HELPER="$fake_headless" \
		PATH="${fake_bin}:$PATH" \
		"$SCANNER" dispatch-pr "marcusquinn/aidevops" "$TEST_TMPDIR" "123"; then
		_pass "dispatch-pr succeeds"
	else
		_fail "dispatch-pr succeeds"
	fi

	if [[ -f "$prompt_file" ]] && grep -q -- 'Assigned review threads in this batch (1): THREAD_1:' "$prompt_file"; then
		_pass "prompt exposes GraphQL thread ID fingerprint"
	else
		_fail "prompt exposes GraphQL thread ID fingerprint" "prompt: ${prompt_file}"
	fi

	_teardown
	return 0
}

main() {
	test_scan_passes_nonempty_owner_and_name_to_graphql
	test_reply_recognises_existing_mention_after_whitespace_and_comment
	test_reply_prepends_author_when_first_content_is_not_mention
	test_dispatch_prompt_includes_thread_fingerprint
	printf 'Results: %d passed, %d failed\n' "$TESTS_PASSED" "$TESTS_FAILED"
	if [[ "$TESTS_FAILED" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
