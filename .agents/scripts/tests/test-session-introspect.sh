#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-session-introspect.sh — t2177 regression guard for session-introspect-helper.sh
#
# Seeds a temp SQLite DB mirroring the observability schema used by the
# opencode-aidevops plugin, runs each subcommand, and asserts expected
# output strings (text + JSON modes).

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1
HELPER="${SCRIPTS_DIR}/session-introspect-helper.sh"

if [[ -t 1 ]]; then
	GREEN=$'\033[0;32m' RED=$'\033[0;31m' NC=$'\033[0m'
else
	GREEN="" RED="" NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$GREEN" "$NC" "$1"
}
fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$RED" "$NC" "$1"
	[[ -n "${2:-}" ]] && printf '       %s\n' "$2"
}

TMP=$(mktemp -d -t t2177.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

DB="${TMP}/introspect.db"
export AIDEVOPS_INTROSPECT_DB="$DB"

# ----------------------------------------------------------------------------
# Seed DB
# ----------------------------------------------------------------------------
sqlite3 "$DB" <<'SQL'
CREATE TABLE tool_calls (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp TEXT NOT NULL,
  session_id TEXT NOT NULL,
  message_id TEXT,
  call_id TEXT,
  tool_name TEXT NOT NULL,
  intent TEXT,
  success INTEGER DEFAULT 1,
  duration_ms INTEGER,
  metadata TEXT,
  outcome_category TEXT
);

CREATE TABLE session_summaries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  session_id TEXT NOT NULL UNIQUE,
  first_seen TEXT NOT NULL,
  last_seen TEXT NOT NULL,
  request_count INTEGER DEFAULT 0,
  total_tokens_input INTEGER DEFAULT 0,
  total_tokens_output INTEGER DEFAULT 0,
  total_cost REAL DEFAULT 0.0,
  total_tool_calls INTEGER DEFAULT 0,
  total_errors INTEGER DEFAULT 0,
  project_path TEXT,
  models_used TEXT
);

-- Session A (most recent — becomes the "current" for default lookup)
INSERT INTO tool_calls (timestamp, session_id, tool_name, intent, success, duration_ms, metadata, outcome_category) VALUES
 ('2026-04-18T04:00:00Z', 'sess-A', 'Read',   'scanning file index',           1, 120, '{"args":{"filePath":"/repo/a.sh"}}', NULL),
 ('2026-04-18T04:00:05Z', 'sess-A', 'Read',   'reading auth handler',          1,  90, '{"args":{"filePath":"/repo/b.sh"}}', 'success'),
 ('2026-04-18T04:00:10Z', 'sess-A', 'Read',   'rechecking auth handler',       1,  88, '{"args":{"filePath":"/repo/b.sh"}}', 'success'),
 ('2026-04-18T04:00:15Z', 'sess-A', 'Read',   're-reading auth handler',       1,  95, '{"args":{"filePath":"/repo/b.sh"}}', 'success'),
 ('2026-04-18T04:00:20Z', 'sess-A', 'Read',   'reading auth handler AGAIN',    1,  80, '{"args":{"filePath":"/repo/b.sh"}}', 'success'),
 ('2026-04-18T04:00:25Z', 'sess-A', 'Edit',   'patching auth handler',         1, 240, '{"args":{"filePath":"/repo/b.sh"}}', 'success'),
 ('2026-04-18T04:00:30Z', 'sess-A', 'Bash',   'running shellcheck',            0, 850, '{}', 'command_failure'),
 ('2026-04-18T04:00:35Z', 'sess-A', 'Bash',   NULL,                            0, 910, '{}', 'policy_block'),
 ('2026-04-18T04:00:40Z', 'sess-A', 'Bash',   'running shellcheck final',      1, 780, '{"intent_source":"fallback"}', 'success'),
 ('2026-04-18T04:00:45Z', 'sess-A', 'Task',   '',                              0,  50, '{}', 'tool_error');

INSERT INTO session_summaries (session_id, first_seen, last_seen, request_count, total_tool_calls, total_errors, total_cost, models_used)
VALUES ('sess-A', '2026-04-18T04:00:00Z', '2026-04-18T04:00:45Z', 10, 10, 3, 0.0184, 'claude-sonnet-4');

-- Session B (older)
INSERT INTO tool_calls (timestamp, session_id, tool_name, intent, success, duration_ms, metadata, outcome_category) VALUES
 ('2026-04-17T10:00:00Z', 'sess-B', 'Read',   'initial context scan',          1, 100, '{"args":{"filePath":"/repo/c.sh"}}', 'success'),
 ('2026-04-17T10:00:05Z', 'sess-B', 'Write',  'creating new helper',           1, 200, '{"args":{"filePath":"/repo/new.sh"}}', 'success');

INSERT INTO session_summaries (session_id, first_seen, last_seen, request_count, total_tool_calls, total_errors, total_cost, models_used)
VALUES ('sess-B', '2026-04-17T10:00:00Z', '2026-04-17T10:00:05Z', 2, 2, 0, 0.0041, 'claude-sonnet-4');

-- Session C (legacy all-missing intent rows)
INSERT INTO tool_calls (timestamp, session_id, tool_name, intent, success, duration_ms, metadata, outcome_category) VALUES
 ('2026-04-16T10:00:00Z', 'sess-C', 'Read', NULL,  1, 100, '{}', 'success'),
 ('2026-04-16T10:00:05Z', 'sess-C', 'Bash', '   ', 0, 200, '{}', 'command_failure');

INSERT INTO session_summaries (session_id, first_seen, last_seen, request_count, total_tool_calls, total_errors, total_cost, models_used)
VALUES ('sess-C', '2026-04-16T10:00:00Z', '2026-04-16T10:00:05Z', 2, 2, 1, 0.0021, 'legacy-model');
SQL

# ----------------------------------------------------------------------------
# Tests
# ----------------------------------------------------------------------------

assert_contains() {
	local name="$1" haystack="$2" needle="$3"
	if printf '%s' "$haystack" | grep -qF -- "$needle"; then
		pass "$name"
	else
		fail "$name" "expected to contain '$needle'"
	fi
}

printf '\n%s=== recent (default session = sess-A, most recent) ===%s\n' "$GREEN" "$NC"
out=$("$HELPER" recent 2>&1) || true
assert_contains "recent: shows current session ID"    "$out" "sess-A"
assert_contains "recent: shows Edit tool call"        "$out" "Edit"
assert_contains "recent: shows Bash error (✗)"        "$out" "✗"

printf '\n%s=== recent with limit ===%s\n' "$GREEN" "$NC"
out=$("$HELPER" recent 3 2>&1) || true
count=$(echo "$out" | grep -c "^2026-04-18" || true)
if [[ "$count" == "3" ]]; then
	pass "recent 3: shows exactly 3 rows"
else
	fail "recent 3: expected 3 rows, got $count" "$out"
fi

printf '\n%s=== patterns ===%s\n' "$GREEN" "$NC"
out=$("$HELPER" patterns 2>&1) || true
assert_contains "patterns: shows session ID"         "$out" "sess-A"
assert_contains "patterns: shows total calls"        "$out" "10 total"
assert_contains "patterns: shows error count"        "$out" "3 error"
assert_contains "patterns: separates command failures" "$out" "command_failure"
assert_contains "patterns: separates policy blocks"  "$out" "policy_block"
assert_contains "patterns: separates tool errors"    "$out" "tool_error"
assert_contains "patterns: preserves unknown legacy outcomes" "$out" "legacy_unknown"
assert_contains "patterns: reports repeated-path evidence" "$out" "/repo/b.sh"
assert_contains "patterns: requires contextual interpretation" "$out" "Interpret in context"
assert_contains "patterns: reports mixed intent coverage" "$out" "8 populated, 2 missing (80.0% coverage)"
assert_contains "patterns: distinguishes intent provenance" "$out" "7 explicit, 1 fallback (70.0% explicit coverage)"
assert_contains "patterns: warns when intent is missing" "$out" "missing intents limit reliable root-cause clustering"

out=$($HELPER patterns --session sess-B 2>&1) || true
assert_contains "patterns: reports complete intent coverage" "$out" "2 populated, 0 missing (100.0% coverage)"
out=$($HELPER patterns --session sess-C 2>&1) || true
assert_contains "patterns: reports zero intent coverage" "$out" "0 populated, 2 missing (0.0% coverage)"

printf '\n%s=== errors ===%s\n' "$GREEN" "$NC"
out=$("$HELPER" errors 2>&1) || true
assert_contains "errors: shows failed Bash call"     "$out" "shellcheck"
assert_contains "errors: shows outcome category"     "$out" "command_failure"
assert_contains "errors: excludes succeeded calls"   "$out" "3 error"
assert_contains "errors: marks missing intent"        "$out" "<missing>"

printf '\n%s=== sessions ===%s\n' "$GREEN" "$NC"
out=$("$HELPER" sessions 2>&1) || true
assert_contains "sessions: shows sess-A"             "$out" "sess-A"
assert_contains "sessions: shows sess-B"             "$out" "sess-B"
assert_contains "sessions: shows cost column"        "$out" "0.0184"

printf '\n%s=== explicit --session flag ===%s\n' "$GREEN" "$NC"
out=$("$HELPER" recent --session sess-B 2>&1) || true
assert_contains "recent --session sess-B: uses override" "$out" "sess-B"
if ! printf '%s' "$out" | grep -q 'sess-A'; then
	pass "recent --session sess-B: excludes sess-A"
else
	fail "recent --session sess-B: leaked sess-A rows" "$out"
fi

printf '\n%s=== JSON output ===%s\n' "$GREEN" "$NC"
if command -v jq >/dev/null 2>&1; then
	out=$("$HELPER" recent --json 2>&1) || true
	if printf '%s' "$out" | jq -e '.session == "sess-A"' >/dev/null 2>&1; then
		pass "recent --json: valid JSON with session field"
	else
		fail "recent --json: not valid JSON or wrong session" "$out"
	fi

	out=$("$HELPER" patterns --json 2>&1) || true
	if printf '%s' "$out" | jq -e '.repeated_file_access.evidence | length > 0' >/dev/null 2>&1; then
		pass "patterns --json: surfaces repeated-path evidence"
	else
		fail "patterns --json: missing repeated_file_access.evidence" "$out"
	fi
	if printf '%s' "$out" | jq -e '
		.calls.outcomes.command_failure == 1 and
		.calls.outcomes.policy_block == 1 and
		.calls.outcomes.tool_error == 1 and
		.calls.outcomes.legacy_unknown == 1 and
		.calls.intent_coverage.populated == 8 and
		.calls.intent_coverage.missing == 2 and
		.calls.intent_coverage.percentage == 80 and
		.calls.intent_coverage.explicit == 7 and
		.calls.intent_coverage.fallback == 1 and
		.calls.intent_coverage.explicit_percentage == 70
	' >/dev/null 2>&1; then
		pass "patterns --json: separates outcomes and reports intent coverage"
	else
		fail "patterns --json: missing outcome or intent coverage counters" "$out"
	fi

	out=$("$HELPER" errors --json 2>&1) || true
	if printf '%s' "$out" | jq -e '
		(.errors | map(.category) | index("policy_block") != null) and
		(.errors | map(.intent) | index("<missing>") != null)
	' >/dev/null 2>&1; then
		pass "errors --json: includes outcomes and missing intent markers"
	else
		fail "errors --json: missing outcomes or intent marker" "$out"
	fi

	out=$("$HELPER" sessions --json 2>&1) || true
	if printf '%s' "$out" | jq -e 'length == 3' >/dev/null 2>&1; then
		pass "sessions --json: returns 3 sessions"
	else
		fail "sessions --json: wrong length" "$out"
	fi
else
	printf '  (skipped JSON tests — jq not installed)\n'
fi

printf '\n%s=== --since filter ===%s\n' "$GREEN" "$NC"
out=$("$HELPER" recent --since 1 2>&1) || true
# All sess-A entries are from 2026-04-18 — in 2026, "--since 1" should match none
# unless the system clock is in the test window. Just check it doesn't error.
if printf '%s' "$out" | grep -q 'Session:'; then
	pass "recent --since 1: runs without error"
else
	fail "recent --since 1: unexpected output" "$out"
fi

printf '\n%s=== Error handling: missing DB ===%s\n' "$GREEN" "$NC"
AIDEVOPS_INTROSPECT_DB="/nonexistent/missing.db" out=$("$HELPER" recent 2>&1) && rc=0 || rc=$?
if [[ "$rc" != "0" ]] && printf '%s' "$out" | grep -q 'not found'; then
	pass "recent: fails cleanly on missing DB"
else
	fail "recent: should fail with 'not found' message" "$out"
fi

printf '\n%s=== Summary ===%s\n' "$GREEN" "$NC"
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$GREEN" "$TESTS_RUN" "$NC"
	exit 0
else
	printf '%s%d/%d tests failed%s\n' "$RED" "$TESTS_FAILED" "$TESTS_RUN" "$NC"
	exit 1
fi
