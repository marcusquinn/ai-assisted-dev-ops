#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-credential-sanitizer.sh — t2458 unit tests.
#
# Asserts that `sanitize_url()` and `scrub_credentials()` from
# shared-constants.sh correctly strip:
#   - Credential authority components (scheme://user:pass@host, scheme://token@host)
#   - Known token prefixes (sk-, ghp_, gho_, ghs_, ghu_, github_pat_,
#     glpat-, xoxb-, xoxp-) anywhere in the text.
#
# Production origin: a session observed a gho_* token in tool output after a
# helper echoed `git remote get-url origin` verbatim. The sanitizer is the
# primary defence; this test locks its invariants.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

# shellcheck source=../shared-constants.sh
source "${SCRIPTS_DIR}/shared-constants.sh"

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

_assert_eq() {
	local label="$1"
	local expected="$2"
	local actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$actual" == "$expected" ]]; then
		printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '       expected: %q\n' "$expected"
		printf '       got:      %q\n' "$actual"
	fi
	return 0
}

_assert_notcontains() {
	local label="$1"
	local needle="$2"
	local haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$haystack" != *"$needle"* ]]; then
		printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$label"
		printf '       haystack still contains %q: %q\n' "$needle" "$haystack"
	fi
	return 0
}

echo "[test] sanitize_url — URL authority stripping"
_assert_eq "gho_ token in https URL authority is stripped" \
	"https://github.com/owner/repo.git" \
	"$(sanitize_url "https://gho_ABCDEFGHIJ1234567890@github.com/owner/repo.git")"

_assert_eq "user:pass@ form is stripped" \
	"https://example.com/path" \
	"$(sanitize_url "https://user:hunter2@example.com/path")"

_assert_eq "clean https URL passes through unchanged" \
	"https://github.com/owner/repo.git" \
	"$(sanitize_url "https://github.com/owner/repo.git")"

_assert_eq "ssh git@ form preserved (not a credential)" \
	"git@github.com:owner/repo.git" \
	"$(sanitize_url "git@github.com:owner/repo.git")"

_assert_eq "ssh:// scheme with token is stripped" \
	"ssh://example.com/path" \
	"$(sanitize_url "ssh://tokenvalue1234@example.com/path")"

_assert_eq "empty input produces empty output" \
	"" \
	"$(sanitize_url "")"

echo ""
echo "[test] sanitize_url — token embedded in query string"
_assert_notcontains "github_pat_ in query string scrubbed" \
	"github_pat_11ABCDEFG_abcdefghijklmnop" \
	"$(sanitize_url "https://example.com/callback?token=github_pat_11ABCDEFG_abcdefghijklmnop")"

_assert_notcontains "glpat- in query string scrubbed" \
	"glpat-abcdefghijklmnop1234" \
	"$(sanitize_url "https://example.com/?key=glpat-abcdefghijklmnop1234")"

echo ""
echo "[test] scrub_credentials — token prefix matrix"
for prefix in "sk-" "GOCSPX-" "ghp_" "gho_" "ghs_" "ghu_" "github_pat_" "glpat-" "xoxb-" "xoxp-"; do
	fake_token="${prefix}abcdefghij1234567890"
	input="prefix: ${fake_token} suffix"
	result=$(scrub_credentials "$input")
	_assert_notcontains "${prefix} redacted from text" "$fake_token" "$result"
done

echo ""
echo "[test] scrub_credentials — short tokens preserved (boundary)"
_assert_eq "token with <10 chars after prefix is NOT redacted" \
	"not a token: sk-abc short" \
	"$(scrub_credentials "not a token: sk-abc short")"

echo ""
echo "[test] scrub_credentials — multiple tokens in one string"
multi=$(scrub_credentials "GH token ghp_abcdefghij1234567890 and slack xoxb-abcdefghij1234567890")
_assert_notcontains "both tokens replaced (ghp_)" "ghp_abcdefghij1234567890" "$multi"
_assert_notcontains "both tokens replaced (xoxb-)" "xoxb-abcdefghij1234567890" "$multi"

echo ""
echo "[test] scrub_credentials — clean input unchanged"
_assert_eq "no tokens → verbatim" \
	"the quick brown fox" \
	"$(scrub_credentials "the quick brown fox")"

echo ""
echo "[test] scrub_credentials — word-boundary anchor (t2892, GH#21026)"
# These strings contain literal credential prefixes (sk-, ghp_, etc.) embedded
# inside identifiers, but are NOT credentials. Without the word-boundary
# anchor in the regex, `task-failure-handler` matched the substring
# `sk-failure-handler` (16-char body suffix passes the {10,} length gate)
# and was corrupted to `ta[redacted-credential]` in tool output and
# (more critically) in committed source files written by workers whose
# tool stream was scrubbed before the worker read it.
_assert_eq "task-failure-handler NOT scrubbed (mid-word sk-)" \
	"./task-failure-handler" \
	"$(scrub_credentials "./task-failure-handler")"

_assert_eq "task-decompose-helper NOT scrubbed (mid-word sk-)" \
	"task-decompose-helper.sh" \
	"$(scrub_credentials "task-decompose-helper.sh")"

_assert_eq "task-runner-helper NOT scrubbed (mid-word sk-)" \
	"task-runner-helper.sh" \
	"$(scrub_credentials "task-runner-helper.sh")"

_assert_eq "task-id-collision-guard NOT scrubbed" \
	"task-id-collision-guard.yml" \
	"$(scrub_credentials "task-id-collision-guard.yml")"

_assert_eq "agent-task-failure-handler id NOT scrubbed" \
	"agent-task-failure-handler" \
	"$(scrub_credentials "agent-task-failure-handler")"

# Real credentials must still be redacted across boundary contexts.
_assert_notcontains "real sk- at start-of-line still redacted" \
	"sk-abcdefghij1234567890" \
	"$(scrub_credentials "sk-abcdefghij1234567890")"

_assert_notcontains "real ghp_ after space still redacted" \
	"ghp_abcdefghij1234567890" \
	"$(scrub_credentials "Bearer ghp_abcdefghij1234567890")"

_assert_notcontains "real sk- after colon still redacted" \
	"sk-abcdefghij1234567890" \
	"$(scrub_credentials "key:sk-abcdefghij1234567890")"

_assert_notcontains "real github_pat_ in URL query still redacted" \
	"github_pat_abcdefghij1234567890" \
	"$(scrub_credentials "https://example.com/?token=github_pat_abcdefghij1234567890")"

echo ""
printf '%d test(s), %d failure(s)\n' "$TESTS_RUN" "$TESTS_FAILED"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
