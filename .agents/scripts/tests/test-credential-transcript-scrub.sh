#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-credential-transcript-scrub.sh — GH#20207 regression guard.
#
# Verifies that credential-transcript-scrub.py redacts all 10 known token-prefix
# families and unknown-format values under sensitive field names, while meeting
# the <5ms/10KB performance budget.
#
# Tests:
#   1.  gho_ token redacted in plain string tool_response
#   2.  ghp_ token redacted in nested dict tool_response
#   3.  sk-  token redacted (OpenAI / Anthropic API keys)
#   4.  ghs_ token redacted (GitHub server-to-server)
#   5.  ghu_ token redacted (GitHub user-to-server)
#   6.  github_pat_ token redacted (fine-grained PAT)
#   7.  glpat- token redacted (GitLab PAT)
#   8.  xoxb- token redacted (Slack bot token)
#   9.  xoxp- token redacted (Slack user token)
#   10. GOCSPX- token redacted (Google OAuth client secret)
#   11. Clean input produces no output (fast-path, no redaction)
#   12. Token shorter than 10 chars NOT redacted (below minimum body length)
#   13. Multiple tokens in one payload all redacted
#   14. Nested JSON object tool_response scrubbed recursively
#   15-18. Named-field positive and conservative negative cases
#   18b. Standalone PEM private-key redaction
#   19. Malformed JSON produces no output and exits 0 (fail-open)
#   20-26. Word-boundary false-positive regression cases
#   27-29. Known-prefix, named-field, and unmatched-PEM performance
#
# Usage: bash test-credential-transcript-scrub.sh

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
HOOKS_DIR="$(cd "${SCRIPT_DIR_TEST}/../../hooks" && pwd)" || exit 1
HOOK_SCRIPT="$HOOKS_DIR/credential-transcript-scrub.py"

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

pass() {
	local label="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$label"
	return 0
}

fail() {
	local label="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$label"
	return 0
}

# Helpers
run_hook() {
	local payload="$1"
	echo "$payload" | python3 "$HOOK_SCRIPT"
	return 0
}

assert_redacted() {
	local label="$1"
	local payload="$2"
	local output
	output=$(run_hook "$payload")
	if echo "$output" | python3 -c "import json,sys; d=json.load(sys.stdin); assert d.get('redacted_credential') is True" 2>/dev/null; then
		pass "$label — credential redacted"
	else
		fail "$label — expected redacted_credential:true, got: $output"
	fi
	if echo "$output" | python3 -c "
import json, sys
d = json.load(sys.stdin)
resp = d.get('tool_response', '')
# Check that no raw token prefix family appears in the output
import re
pat = re.compile(r'(sk-|GOCSPX-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{10,}')
if isinstance(resp, str):
    assert not pat.search(resp), f'token still present: {resp}'
elif isinstance(resp, dict):
    flat = json.dumps(resp)
    assert not pat.search(flat), f'token still present in dict: {flat}'
" 2>/dev/null; then
		pass "$label — token absent from output"
	else
		fail "$label — raw credential token still present in output"
	fi
	return 0
}

assert_no_output() {
	local label="$1"
	local payload="$2"
	local output
	output=$(run_hook "$payload")
	if [[ -z "$output" ]]; then
		pass "$label — no output (fast-path)"
	else
		fail "$label — expected empty output, got: $output"
	fi
	return 0
}

assert_exit_zero() {
	local label="$1"
	local payload="$2"
	if echo "$payload" | python3 "$HOOK_SCRIPT" >/dev/null 2>&1; then
		pass "$label — exits 0"
	else
		fail "$label — expected exit 0, got non-zero"
	fi
	return 0
}

# ── Preflight ──────────────────────────────────────────────────────────────

printf '%s\n' "${TEST_BLUE}Credential Transcript Scrub Hook — Test Suite${TEST_NC}"
printf '%s\n' "=================================================="

if [[ ! -f "$HOOK_SCRIPT" ]]; then
	printf '%sFAIL%s Hook not found: %s\n' "$TEST_RED" "$TEST_NC" "$HOOK_SCRIPT"
	exit 1
fi
if ! command -v python3 &>/dev/null; then
	printf '%sFAIL%s python3 not found\n' "$TEST_RED" "$TEST_NC"
	exit 1
fi
printf '  Hook: %s\n\n' "$HOOK_SCRIPT"

# ── Token-family tests (1–10) ──────────────────────────────────────────────

printf '%s\n' "${TEST_BLUE}Token family coverage${TEST_NC}"

assert_redacted "1. gho_ token" \
	'{"tool_response": "remote url: https://gho_ABCDEFGHIJ1234567890@github.com/owner/repo"}'

assert_redacted "2. ghp_ token" \
	'{"tool_response": {"url": "https://ghp_ABCDEFGHIJ1234567890@github.com/owner/repo"}}'

assert_redacted "3. sk- token" \
	'{"tool_response": "API call failed with key sk-abcdefghijklmnopqrstuvwx"}'

assert_redacted "4. ghs_ token" \
	'{"tool_response": "Authorization: Bearer ghs_ABCDEFGHIJ1234567890"}'

assert_redacted "5. ghu_ token" \
	'{"tool_response": "token ghu_ABCDEFGHIJ1234567890 expired"}'

assert_redacted "6. github_pat_ token" \
	'{"tool_response": "fine-grained PAT: github_pat_11ABCDEFGHIJ1234567890"}'

assert_redacted "7. glpat- token" \
	'{"tool_response": "GitLab token: glpat-ABCDEFGHIJ1234567890"}'

assert_redacted "8. xoxb- token" \
	'{"tool_response": "Slack bot: xoxb-ABCDEFGHIJKLM-1234567890-abcdefghij"}'

assert_redacted "9. xoxp- token" \
	'{"tool_response": "Slack user: xoxp-ABCDEFGHIJKLM-1234567890-abcdefghij"}'

GOOGLE_OAUTH_SECRET="GOCSPX-$(printf 'a%.0s' {1..28})"
assert_redacted "10. GOCSPX- token" \
	"{\"tool_response\": \"client_secret=${GOOGLE_OAUTH_SECRET}\"}"

# ── Edge cases ─────────────────────────────────────────────────────────────

printf '\n%s\n' "${TEST_BLUE}Edge cases${TEST_NC}"

assert_no_output "11. Clean input produces no output" \
	'{"tool_response": "git status: clean working tree"}'

assert_no_output "12. Token body shorter than 10 chars not redacted" \
	'{"tool_response": "gho_SHORT123"}'

assert_redacted "13. Multiple tokens all redacted" \
	'{"tool_response": "key1=ghp_ABCDEFGHIJ1234567890 key2=gho_ABCDEFGHIJ1234567890"}'

# Test 14: nested JSON object
NESTED_PAYLOAD='{"tool_response": {"stdout": "token: ghs_ABCDEFGHIJ1234567890", "stderr": "", "exit_code": 0}}'
output14=$(run_hook "$NESTED_PAYLOAD")
if echo "$output14" | python3 -c "
import json, sys
d = json.load(sys.stdin)
assert d.get('redacted_credential') is True, 'not redacted'
resp = d.get('tool_response', {})
assert isinstance(resp, dict), 'tool_response not dict'
assert '[redacted-credential]' in resp.get('stdout', ''), 'token not scrubbed in stdout'
" 2>/dev/null; then
	pass "14. Nested dict tool_response scrubbed recursively"
else
	fail "14. Nested dict tool_response scrubbed recursively — got: $output14"
fi

LONG_NAMED_KEY=$(python3 -c "print('A' * 129 + '_API_KEY')")
NAMED_TEXT_PAYLOAD="{\"tool_response\": \"(RESEND-API-KEY=synthetic_unknown_format_1234567890) API_KEY=opaque-value&other=value TOKEN=opaque-value|next PASSWORD=opaque-value>file API KEY=opaque-value AWS_SECRET_ACCESS_KEY=opaque-value AWS_ACCESS_KEY_ID=opaque-value AccessKeyId=opaque-value SIGNING_KEY=[redacted]opaque API_KEY=(opaque-value) API_KEY=(not set)opaque (SECRET_KEY=not set) ${LONG_NAMED_KEY}=opaque-value\"}"
output15=$(run_hook "$NAMED_TEXT_PAYLOAD")
if echo "$output15" | python3 -c "
import json, sys
response = json.load(sys.stdin).get('tool_response', '')
assert response == '(RESEND-API-KEY=[redacted-credential]) API_KEY=[redacted-credential]&other=value TOKEN=[redacted-credential]|next PASSWORD=[redacted-credential]>file API KEY=[redacted-credential] AWS_SECRET_ACCESS_KEY=[redacted-credential] AWS_ACCESS_KEY_ID=[redacted-credential] AccessKeyId=[redacted-credential] SIGNING_KEY=[redacted-credential] API_KEY=([redacted-credential]) API_KEY=[redacted-credential] (SECRET_KEY=not set) ${LONG_NAMED_KEY}=[redacted-credential]'
" 2>/dev/null; then
	pass "15. Named secrets scrubbed without consuming delimiters"
else
	fail "15. Named secrets scrubbed without consuming delimiters — got: $output15"
fi

NAMED_OBJECT_PAYLOAD='{"tool_response": {"environment": {"RECRAFT_API_KEY": "synthetic_unknown_format_1234567890", "TOKEN": 1234567890, "PRIVATE_KEY": {"material": "synthetic_unknown_format_1234567890"}, "SECRET_KEY": null}}}'
output16=$(run_hook "$NAMED_OBJECT_PAYLOAD")
if echo "$output16" | python3 -c "
import json, sys
response = json.load(sys.stdin).get('tool_response', {})
assert response['environment']['RECRAFT_API_KEY'] == '[redacted-credential]'
assert response['environment']['TOKEN'] == '[redacted-credential]'
assert response['environment']['PRIVATE_KEY'] == '[redacted-credential]'
assert response['environment']['SECRET_KEY'] is None
" 2>/dev/null; then
	pass "16. Sensitive structured values scrubbed regardless of type"
else
	fail "16. Sensitive structured values scrubbed regardless of type — got: $output16"
fi

assert_no_output "17. Sensitive placeholders remain unchanged" \
	'{"tool_response": "API_KEY=[REDACTED] PRIVATE_KEY=[redacted-private-key] SECRET_KEY=(not set) ACCESS_TOKEN=null"}'

assert_no_output "18. Sensitive-name substrings remain unchanged" \
	'{"tool_response": "TOKEN_COUNT=3 PASSWORD_POLICY=strict MONKEY_TOKENIZER=enabled"}'

PEM_PAYLOAD='{"tool_response": "-----BEGIN OPENSSH PRIVATE KEY-----\nsynthetic-material\n-----END OPENSSH PRIVATE KEY-----"}'
output_pem=$(run_hook "$PEM_PAYLOAD")
if echo "$output_pem" | python3 -c "
import json, sys
assert json.load(sys.stdin).get('tool_response') == '[redacted-private-key]'
" 2>/dev/null; then
	pass "18b. Standalone PEM private key scrubbed"
else
	fail "18b. Standalone PEM private key scrubbed — got: $output_pem"
fi

# Test 19: malformed JSON exits 0
assert_exit_zero "19. Malformed JSON exits 0 (fail-open)" \
	"not-valid-json"

# ── Word-boundary anchor regression (t2892, GH#21026) ──────────────────────

printf '\n%s\n' "${TEST_BLUE}Word-boundary anchor (t2892)${TEST_NC}"

# Without the word-boundary anchor `(?:^|(?<=[^A-Za-z0-9_-]))`, the regex
# matches credential prefixes embedded inside identifiers. Canonical failure:
# `task-failure-handler` matched the substring `sk-failure-handler`
# (16-char body suffix passes the {10,} gate) and was rewritten to
# `ta[redacted-credential]` — corrupting committed source on
# example-repo/develop and breaking 4 PRs (#3168, #3155, #3068, #2984).
# The hook scrubs tool stream content fed to the model; the same regex bug
# in `shared-constants.sh::scrub_credentials` corrupts source files at
# write-time. All three locations must agree on the boundary anchor.

assert_no_output "20. task-failure-handler NOT scrubbed (mid-word sk-)" \
	'{"tool_response": "import { handler } from \"./task-failure-handler\""}'

assert_no_output "21. task-decompose-helper NOT scrubbed (mid-word sk-)" \
	'{"tool_response": "Calling task-decompose-helper.sh now"}'

assert_no_output "22. agent-task-failure-handler id NOT scrubbed" \
	'{"tool_response": "inngest function id: agent-task-failure-handler"}'

assert_no_output "23. task-id-collision-guard NOT scrubbed" \
	'{"tool_response": "workflow: task-id-collision-guard.yml"}'

# Real credentials must still be redacted across boundary contexts.
assert_redacted "24. real sk- after space still redacted (control)" \
	'{"tool_response": "API key sk-abcdefghij1234567890 invalid"}'

assert_redacted "25. real sk- at start of string still redacted" \
	'{"tool_response": "sk-abcdefghij1234567890"}'

assert_redacted "26. real ghp_ after colon still redacted" \
	'{"tool_response": "token:ghp_abcdefghij1234567890"}'

# ── Performance budget ─────────────────────────────────────────────────────

printf '\n%s\n' "${TEST_BLUE}Performance (<5ms per 10KB)${TEST_NC}"

# Build a ~10KB payload with one embedded credential.
# The 5ms budget is for the processing cost (regex + JSON parse/serialise),
# not the Python process startup cost (~50ms fixed per-invocation).
# We measure using scrub_elapsed_ms reported by the hook itself,
# and by running the regex in-process for a microbenchmark.
FILLER=$(python3 -c "print('x' * 9900)")
PERF_PAYLOAD="{\"tool_response\": \"${FILLER} gho_ABCDEFGHIJ1234567890 end\"}"

# Method A: use the scrub_elapsed_ms field reported by the hook
ELAPSED_MS=$(echo "$PERF_PAYLOAD" | python3 "$HOOK_SCRIPT" 2>/dev/null | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    print(d.get('scrub_elapsed_ms', 'N/A'))
except Exception:
    print('N/A')
")

printf '  Hook-reported scrub_elapsed_ms: %sms (excludes Python startup)\n' "$ELAPSED_MS"

# Method B: in-process microbenchmark (most accurate for the regex itself)
BENCH_MS=$(python3 -c "
import re, time, json

CREDENTIAL_PATTERN = re.compile(
    r'(sk-|GOCSPX-|ghp_|gho_|ghs_|ghu_|github_pat_|glpat-|xoxb-|xoxp-)[A-Za-z0-9_-]{10,}',
    re.ASCII,
)
filler = 'x' * 9900
payload_str = json.dumps({'tool_response': f'{filler} gho_ABCDEFGHIJ1234567890 end'})

runs = 500
start = time.monotonic_ns()
for _ in range(runs):
    CREDENTIAL_PATTERN.sub('[redacted-credential]', payload_str)
end = time.monotonic_ns()
avg_ms = (end - start) / runs / 1_000_000
print(round(avg_ms, 4))
")

printf '  In-process regex per 10KB (%d runs): %sms\n' 500 "$BENCH_MS"

if python3 -c "import sys; sys.exit(0 if float('$BENCH_MS') < 5 else 1)" 2>/dev/null; then
	pass "27. Performance: ${BENCH_MS}ms per 10KB in-process (budget: <5ms)"
else
	fail "27. Performance: ${BENCH_MS}ms per 10KB in-process exceeds 5ms budget"
fi

NAMED_BENCH_MS=$(python3 -c "
import runpy, time

scrub_credentials = runpy.run_path('$HOOK_SCRIPT')['scrub_credentials']
payload_str = 'A ' * 5000
runs = 100
scrub_credentials(payload_str)
start = time.monotonic_ns()
for _ in range(runs):
    scrubbed, count = scrub_credentials(payload_str)
end = time.monotonic_ns()
assert scrubbed == payload_str and count == 0
avg_ms = (end - start) / runs / 1_000_000
print(round(avg_ms, 4))
")

printf '  In-process named scrub per 10KB (%d runs): %sms\n' 100 "$NAMED_BENCH_MS"
if python3 -c "import sys; sys.exit(0 if float('$NAMED_BENCH_MS') < 5 else 1)" 2>/dev/null; then
	pass "28. Named-field performance: ${NAMED_BENCH_MS}ms per 10KB (budget: <5ms)"
else
	fail "28. Named-field performance: ${NAMED_BENCH_MS}ms per 10KB exceeds 5ms budget"
fi

PEM_BENCH_MS=$(python3 -c "
import runpy, time

scrub_credentials = runpy.run_path('$HOOK_SCRIPT')['scrub_credentials']
payload_str = '-----BEGIN OPENSSH PRIVATE KEY-----\n' * 250
runs = 100
scrub_credentials(payload_str)
start = time.monotonic_ns()
for _ in range(runs):
    scrubbed, count = scrub_credentials(payload_str)
end = time.monotonic_ns()
assert scrubbed == payload_str and count == 0
avg_ms = (end - start) / runs / 1_000_000
print(round(avg_ms, 4))
")

printf '  In-process unmatched PEM scan per 10KB (%d runs): %sms\n' 100 "$PEM_BENCH_MS"
if python3 -c "import sys; sys.exit(0 if float('$PEM_BENCH_MS') < 5 else 1)" 2>/dev/null; then
	pass "29. Unmatched-PEM performance: ${PEM_BENCH_MS}ms per 10KB (budget: <5ms)"
else
	fail "29. Unmatched-PEM performance: ${PEM_BENCH_MS}ms per 10KB exceeds 5ms budget"
fi
printf '  Note: subprocess launch adds ~50ms Python startup; in-process cost shown above.\n'

# ── Summary ────────────────────────────────────────────────────────────────

printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d/%d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
