#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tests for gh-signature-helper.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
HELPER="${SCRIPT_DIR}/../gh-signature-helper.sh"

PASS=0
FAIL=0

assert_eq() {
	local test_name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected: $expected"
		echo "    actual:   $actual"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_contains() {
	local test_name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" == *"$needle"* ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected to contain: $needle"
		echo "    actual: $haystack"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

assert_not_contains() {
	local test_name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		echo "  PASS: $test_name"
		PASS=$((PASS + 1))
	else
		echo "  FAIL: $test_name"
		echo "    expected NOT to contain: $needle"
		echo "    actual: $haystack"
		FAIL=$((FAIL + 1))
	fi
	return 0
}

echo "=== gh-signature-helper.sh tests ==="
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: generate with explicit CLI, model, tokens
# ─────────────────────────────────────────────────────────────────────────────
echo "Test 1: generate with all explicit fields"
result=$("$HELPER" generate --cli "OpenCode" --cli-version "1.3.3" --model "anthropic/claude-opus-4-6" --tokens 1234)
assert_contains "starts with aidevops" "[aidevops.sh](https://aidevops.sh)" "$result"
assert_contains "contains CLI with plugin for" "plugin for [OpenCode](https://opencode.ai) v1.3.3" "$result"
assert_contains "model strips provider prefix" "with claude-opus-4-6" "$result"
assert_not_contains "no provider prefix" "anthropic/" "$result"
assert_contains "contains formatted tokens" "1,234 tokens on this" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: generate with explicit --tokens 0 (should omit tokens)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 2: explicit --tokens 0 omits tokens"
result=$("$HELPER" generate --cli "Claude Code" --cli-version "2.0.1" --model "anthropic/claude-sonnet-4-6" --tokens 0)
assert_contains "contains Claude Code" "plugin for [Claude Code](https://claude.ai/code) v2.0.1" "$result"
assert_not_contains "no tokens field" "tokens" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: generate with zero tokens (should omit)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 3: zero tokens omitted"
result=$("$HELPER" generate --cli "OpenCode" --model "anthropic/claude-opus-4-6" --tokens 0)
assert_not_contains "zero tokens omitted" "tokens" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: generate with no --model flag (auto-detects from session DB if available)
# GH#12965: model is now auto-detected from the OpenCode session DB, so the
# output may contain a model even without --model. We only verify the CLI
# override works and aidevops branding is present.
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 4: no explicit model (auto-detect from DB)"
result=$("$HELPER" generate --cli "Cursor" --tokens 0)
assert_contains "contains Cursor link" "plugin for [Cursor](https://cursor.com)" "$result"
assert_contains "contains aidevops" "aidevops.sh" "$result"
# Model may or may not be present depending on whether a session DB is available

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: footer command includes --- separator
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 5: footer includes --- separator and HTML marker"
result=$("$HELPER" footer --cli "OpenCode" --cli-version "1.0.0" --model "anthropic/claude-sonnet-4-6" --tokens 5000)
assert_contains "contains HTML sig marker" "<!-- aidevops:sig -->" "$result"
assert_contains "contains ---" "---" "$result"
assert_contains "contains signature" "plugin for [OpenCode](https://opencode.ai) v1.0.0" "$result"
assert_contains "contains tokens" "5,000 tokens on this" "$result"
result=$(AIDEVOPS_SESSION_ORIGIN=interactive "$HELPER" footer --cli "OpenCode" --tokens 0)
assert_contains "interactive footer records issue origin provenance" "<!-- aidevops:origin:interactive -->" "$result"
result=$(AIDEVOPS_SESSION_ORIGIN=worker "$HELPER" footer --cli "OpenCode" --tokens 0)
assert_contains "worker footer records issue origin provenance" "<!-- aidevops:origin:worker -->" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: comma formatting for various numbers
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 6: comma formatting"
result=$("$HELPER" generate --cli "Test" --model "m" --tokens 999)
assert_contains "3-digit no comma" "999 tokens" "$result"

result=$("$HELPER" generate --cli "Test" --model "m" --tokens 1000)
assert_contains "4-digit with comma" "1,000 tokens" "$result"

result=$("$HELPER" generate --cli "Test" --model "m" --tokens 45000)
assert_contains "5-digit with comma" "45,000 tokens" "$result"

result=$("$HELPER" generate --cli "Test" --model "m" --tokens 1234567)
assert_contains "7-digit with commas" "1,234,567 tokens" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: CLI URL mapping for known runtimes
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 7: CLI URL mapping"
result=$("$HELPER" generate --cli "OpenCode" --model "m")
assert_contains "OpenCode URL" "https://opencode.ai" "$result"

result=$("$HELPER" generate --cli "Claude Code" --model "m")
assert_contains "Claude Code URL" "https://claude.ai/code" "$result"

result=$("$HELPER" generate --cli "Cursor" --model "m")
assert_contains "Cursor URL" "https://cursor.com" "$result"

result=$("$HELPER" generate --cli "Aider" --model "m")
assert_contains "Aider URL" "https://aider.chat" "$result"

result=$("$HELPER" generate --cli "Windsurf" --model "m")
assert_contains "Windsurf URL" "https://windsurf.com" "$result"

result=$("$HELPER" generate --cli "Continue" --model "m")
assert_contains "Continue URL" "https://continue.dev" "$result"

result=$("$HELPER" generate --cli "GitHub Copilot" --model "m")
assert_contains "Copilot URL" "https://github.com/features/copilot" "$result"

result=$("$HELPER" generate --cli "Cody" --model "m")
assert_contains "Cody URL" "https://sourcegraph.com/cody" "$result"

result=$("$HELPER" generate --cli "Kilo Code" --model "m")
assert_contains "Kilo Code URL" "https://kilocode.ai" "$result"

result=$("$HELPER" generate --cli "Augment" --model "m")
assert_contains "Augment URL" "https://augmentcode.com" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: unknown CLI gets no link
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 8: unknown CLI has no link"
result=$("$HELPER" generate --cli "SomeNewTool" --model "m")
assert_contains "CLI name present" "SomeNewTool" "$result"
assert_not_contains "no CLI markdown link" "[SomeNewTool](" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 9: env var overrides
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 9: environment variable overrides"
result=$(AIDEVOPS_SIG_CLI="EnvCLI" AIDEVOPS_SIG_CLI_VERSION="9.9.9" AIDEVOPS_SIG_MODEL="test/model" AIDEVOPS_SIG_TOKENS="42000" "$HELPER" generate)
assert_contains "env CLI name" "plugin for EnvCLI" "$result"
assert_contains "env CLI version" "v9.9.9" "$result"
assert_contains "env model strips prefix" "with model" "$result"
assert_contains "env tokens" "42,000 tokens on this" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 10: auto-detect tokens from OpenCode session DB (if running in OpenCode)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 10: auto-detect tokens from session DB"
if [[ "${OPENCODE:-}" == "1" ]] && [[ -r "${HOME}/.local/share/opencode/opencode.db" ]]; then
	result=$("$HELPER" generate --cli "OpenCode" --model "anthropic/claude-opus-4-6")
	assert_contains "auto-detected tokens present" "tokens" "$result"
else
	echo "  SKIP: not running in OpenCode (auto-detect test requires OpenCode session DB)"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 11: session and response time auto-detection (OpenCode only)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 11: session time auto-detection (no response time)"
if [[ "${OPENCODE:-}" == "1" ]] && [[ -r "${HOME}/.local/share/opencode/opencode.db" ]]; then
	result=$("$HELPER" generate --cli "OpenCode" --model "m" --tokens 1)
	assert_contains "session time present" "spent " "$result"
	assert_not_contains "no response time" "to respond" "$result"
else
	echo "  SKIP: not running in OpenCode"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 12: total time with --issue-created
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 12: total time with --issue-created"
two_hours_ago=$(date -u -v-2H "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || date -u -d "2 hours ago" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
if [[ -n "$two_hours_ago" ]]; then
	result=$("$HELPER" generate --cli "Test" --model "m" --tokens 1 --issue-created "$two_hours_ago")
	assert_contains "total time present" "since this issue was created" "$result"
	assert_contains "total time has hours" "h" "$result"
else
	echo "  SKIP: date command does not support relative time"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 13: --solved flag changes total time phrasing
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 13: --solved flag"
if [[ -n "$two_hours_ago" ]]; then
	result=$("$HELPER" generate --cli "Test" --model "m" --tokens 1 --issue-created "$two_hours_ago" --solved)
	assert_contains "solved phrasing" "Solved in " "$result"
	assert_not_contains "no since phrasing" "since this issue" "$result"
else
	echo "  SKIP: date command does not support relative time"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Test 14: issue-created scopes token detection to issue window
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 14: issue-created token scoping"
tmp_home=$(mktemp -d 2>/dev/null || mktemp -d -t sighelper)
mkdir -p "${tmp_home}/.local/share/opencode"
db_path="${tmp_home}/.local/share/opencode/opencode.db"

now_epoch=$(date +%s)
session_created_ms=$(((now_epoch - 3600) * 1000))
pre_msg_ms=$(((now_epoch - 1200) * 1000))
issue_created_epoch=$((now_epoch - 600))
post_msg_ms=$(((now_epoch - 300) * 1000))

issue_created_iso=$(date -u -r "$issue_created_epoch" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
	date -u -d "@${issue_created_epoch}" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")

cwd_sql=$(pwd)
cwd_sql=${cwd_sql//\'/\'\'}

if command -v sqlite3 &>/dev/null; then
	sqlite3 "$db_path" "
CREATE TABLE session (
  id TEXT PRIMARY KEY,
  title TEXT,
  directory TEXT NOT NULL,
  time_created INTEGER NOT NULL
);
CREATE TABLE message (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  time_created INTEGER NOT NULL,
  time_updated INTEGER NOT NULL,
  data TEXT NOT NULL
);
INSERT INTO session (id,title,directory,time_created)
VALUES ('ses_test_scope','sig-test','${cwd_sql}',${session_created_ms});
INSERT INTO message (id,session_id,time_created,time_updated,data)
VALUES
  ('msg_pre','ses_test_scope',${pre_msg_ms},${pre_msg_ms},'{\"tokens\":{\"input\":100,\"output\":10,\"cache\":{\"read\":0,\"write\":0}},\"role\":\"assistant\"}'),
  ('msg_post','ses_test_scope',${post_msg_ms},${post_msg_ms},'{\"tokens\":{\"input\":200,\"output\":20,\"cache\":{\"read\":0,\"write\":0}},\"role\":\"assistant\"}');
"

	if [[ -n "$issue_created_iso" ]]; then
		result=$(XDG_DATA_HOME="${tmp_home}/.local/share" HOME="$tmp_home" "$HELPER" generate --cli "OpenCode" --model "m" --issue-created "$issue_created_iso")
		assert_contains "issue window uses scoped tokens" "220 tokens on this" "$result"
		assert_not_contains "issue window excludes pre-issue tokens" "330 tokens on this" "$result"

		issue_after_epoch=$((now_epoch - 60))
		issue_after_iso=$(date -u -r "$issue_after_epoch" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null ||
			date -u -d "@${issue_after_epoch}" "+%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "")
		if [[ -n "$issue_after_iso" ]]; then
			result=$(XDG_DATA_HOME="${tmp_home}/.local/share" HOME="$tmp_home" "$HELPER" generate --cli "OpenCode" --model "m" --issue-created "$issue_after_iso")
			assert_not_contains "post-window excludes pre-issue fallback" "330 tokens on this" "$result"
			assert_not_contains "post-window omits scoped zero token phrase" "0 tokens on this" "$result"
		else
			echo "  SKIP: could not construct post-window issue-created timestamp"
		fi
	else
		echo "  SKIP: could not construct issue-created timestamp"
	fi
else
	echo "  SKIP: sqlite3 not available"
fi

rm -rf "$tmp_home"

# ─────────────────────────────────────────────────────────────────────────────
# Test 15: help command exits cleanly
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 15: help command"
result=$("$HELPER" help 2>&1)
assert_contains "help shows usage" "Usage:" "$result"
assert_contains "help shows examples" "Examples:" "$result"
assert_contains "help shows record-child" "record-child" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 16: record-child writes to ledger and generate aggregates (t1897)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 16: child-token ledger (record-child + generate aggregation)"
tmp_home_16=$(mktemp -d 2>/dev/null || mktemp -d -t sighelper16)
mkdir -p "${tmp_home_16}/.local/share/opencode"
mkdir -p "${tmp_home_16}/.aidevops/.agent-workspace/tmp"
db_path_16="${tmp_home_16}/.local/share/opencode/opencode.db"

now_epoch_16=$(date +%s)
parent_created_ms_16=$(((now_epoch_16 - 600) * 1000))
child_created_ms_16=$(((now_epoch_16 - 300) * 1000))

cwd_sql_16=$(pwd)
cwd_sql_16=${cwd_sql_16//\'/\'\'}

if command -v sqlite3 &>/dev/null; then
	sqlite3 "$db_path_16" "
CREATE TABLE session (
  id TEXT PRIMARY KEY,
  title TEXT,
  directory TEXT NOT NULL,
  time_created INTEGER NOT NULL
);
CREATE TABLE message (
  id TEXT PRIMARY KEY,
  session_id TEXT NOT NULL,
  time_created INTEGER NOT NULL,
  time_updated INTEGER NOT NULL,
  data TEXT NOT NULL
);
-- Parent session with 500 tokens
INSERT INTO session (id,title,directory,time_created)
VALUES ('ses_parent_test','parent session','${cwd_sql_16}',${parent_created_ms_16});
INSERT INTO message (id,session_id,time_created,time_updated,data)
VALUES ('msg_p1','ses_parent_test',${parent_created_ms_16},${parent_created_ms_16},
  '{\"tokens\":{\"input\":400,\"output\":100,\"cache\":{\"read\":0,\"write\":0}},\"role\":\"assistant\"}');

-- Child session with 200 tokens
INSERT INTO session (id,title,directory,time_created)
VALUES ('ses_child_test','child subagent (@general subagent)','${cwd_sql_16}',${child_created_ms_16});
INSERT INTO message (id,session_id,time_created,time_updated,data)
VALUES ('msg_c1','ses_child_test',${child_created_ms_16},${child_created_ms_16},
  '{\"tokens\":{\"input\":150,\"output\":50,\"cache\":{\"read\":0,\"write\":0}},\"role\":\"assistant\"}');
"

	# Test 16a: record-child without --tokens (auto-detect from DB)
	XDG_DATA_HOME="${tmp_home_16}/.local/share" HOME="$tmp_home_16" "$HELPER" record-child --child ses_child_test --parent ses_parent_test
	ledger_file="${tmp_home_16}/.aidevops/.agent-workspace/tmp/ses_parent_test.children.tsv"
	if [[ -r "$ledger_file" ]]; then
		ledger_content=$(cat "$ledger_file")
		assert_contains "ledger contains child ID" "ses_child_test" "$ledger_content"
		assert_contains "ledger contains auto-detected tokens" "200" "$ledger_content"
	else
		echo "  FAIL: ledger file not created"
		FAIL=$((FAIL + 1))
	fi

	# Test 16b: idempotent — recording same child again is a no-op
	XDG_DATA_HOME="${tmp_home_16}/.local/share" HOME="$tmp_home_16" "$HELPER" record-child --child ses_child_test --parent ses_parent_test
	line_count=$(wc -l <"$ledger_file" | tr -d ' ')
	assert_eq "idempotent record-child" "1" "$line_count"

	# Test 16c: generate includes child tokens (parent 500 + child 200 = 700)
	result=$(OPENCODE_SESSION_ID="ses_parent_test" XDG_DATA_HOME="${tmp_home_16}/.local/share" HOME="$tmp_home_16" "$HELPER" generate --cli "OpenCode" --model "m")
	assert_contains "aggregated tokens (parent + child)" "700 tokens" "$result"

	# Test 16d: record-child with explicit --tokens (non-OpenCode runtime path)
	XDG_DATA_HOME="${tmp_home_16}/.local/share" HOME="$tmp_home_16" "$HELPER" record-child --child ses_other_child --parent ses_parent_test --tokens 300
	result=$(OPENCODE_SESSION_ID="ses_parent_test" XDG_DATA_HOME="${tmp_home_16}/.local/share" HOME="$tmp_home_16" "$HELPER" generate --cli "OpenCode" --model "m")
	assert_contains "aggregated with explicit child (500+200+300)" "1,000 tokens" "$result"
else
	echo "  SKIP: sqlite3 not available"
fi

rm -rf "$tmp_home_16"

# ─────────────────────────────────────────────────────────────────────────────
# Test 17: record-child fails without --child
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 17: record-child requires --child"
result=$("$HELPER" record-child 2>&1) && rc=$? || rc=$?
assert_eq "record-child exits non-zero without --child" "1" "$rc"
assert_contains "error message mentions --child" "--child" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 18: generate with no ledger file (no children) — unchanged behavior
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 18: no ledger = no child tokens added"
tmp_home_18=$(mktemp -d 2>/dev/null || mktemp -d -t sighelper18)
mkdir -p "${tmp_home_18}/.local/share/opencode"
db_path_18="${tmp_home_18}/.local/share/opencode/opencode.db"

now_epoch_18=$(date +%s)
session_created_ms_18=$(((now_epoch_18 - 120) * 1000))
cwd_sql_18=$(pwd)
cwd_sql_18=${cwd_sql_18//\'/\'\'}

if command -v sqlite3 &>/dev/null; then
	sqlite3 "$db_path_18" "
CREATE TABLE session (id TEXT PRIMARY KEY, title TEXT, directory TEXT NOT NULL, time_created INTEGER NOT NULL);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
INSERT INTO session (id,title,directory,time_created)
VALUES ('ses_solo','solo session','${cwd_sql_18}',${session_created_ms_18});
INSERT INTO message (id,session_id,time_created,time_updated,data)
VALUES ('msg_s1','ses_solo',${session_created_ms_18},${session_created_ms_18},
  '{\"tokens\":{\"input\":800,\"output\":200,\"cache\":{\"read\":0,\"write\":0}},\"role\":\"assistant\"}');
"
	result=$(XDG_DATA_HOME="${tmp_home_18}/.local/share" HOME="$tmp_home_18" "$HELPER" generate --cli "OpenCode" --model "m")
	assert_contains "solo session shows own tokens only" "1,000 tokens" "$result"
else
	echo "  SKIP: sqlite3 not available"
fi

rm -rf "$tmp_home_18"

# ─────────────────────────────────────────────────────────────────────────────
# Test 19: OpenCode session selection prefers current session over PID-start
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 19: OpenCode session selection avoids stale PID-start match"
tmp_home_19=$(mktemp -d 2>/dev/null || mktemp -d -t sighelper19)
mkdir -p "${tmp_home_19}/.local/share/opencode"
db_path_19="${tmp_home_19}/.local/share/opencode/opencode.db"

now_epoch_19=$(date +%s)
recent_session_ms_19=$(((now_epoch_19 - 60) * 1000))
stale_pid_session_ms_19=$(((now_epoch_19 - 3600) * 1000))
cwd_sql_19=$(pwd)
cwd_sql_19=${cwd_sql_19//\'/\'\'}

if command -v sqlite3 &>/dev/null; then
	sqlite3 "$db_path_19" "
CREATE TABLE session (id TEXT PRIMARY KEY, title TEXT, directory TEXT NOT NULL, time_created INTEGER NOT NULL);
CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, time_created INTEGER NOT NULL, time_updated INTEGER NOT NULL, data TEXT NOT NULL);
INSERT INTO session (id,title,directory,time_created) VALUES
  ('ses_stale_pid','old opus session near app launch','${cwd_sql_19}',${stale_pid_session_ms_19}),
  ('ses_current','current gpt session','${cwd_sql_19}',${recent_session_ms_19});
INSERT INTO message (id,session_id,time_created,time_updated,data) VALUES
  ('msg_stale','ses_stale_pid',${stale_pid_session_ms_19},${stale_pid_session_ms_19},
   '{\"model\":{\"providerID\":\"anthropic\",\"modelID\":\"claude-opus-4-7\"},\"tokens\":{\"input\":10,\"output\":1,\"cache\":{\"read\":0,\"write\":0}},\"role\":\"assistant\"}'),
  ('msg_current','ses_current',${recent_session_ms_19},${recent_session_ms_19},
   '{\"providerID\":\"openai\",\"modelID\":\"gpt-5.5\",\"tokens\":{\"input\":20,\"output\":2,\"cache\":{\"read\":0,\"write\":0}},\"role\":\"assistant\"}');
"

	result=$(env -u OPENCODE_SESSION_ID -u AIDEVOPS_SIG_SESSION_ID OPENCODE=1 OPENCODE_PID=$$ AIDEVOPS_SIG_MODEL="" XDG_DATA_HOME="${tmp_home_19}/.local/share" HOME="$tmp_home_19" "$HELPER" generate --cli "OpenCode")
	assert_contains "recent session model wins over PID-start match" "with gpt-5.5" "$result"
	assert_contains "recent session tokens used" "22 tokens on this" "$result"
	assert_not_contains "stale PID session model ignored" "claude-opus-4-7" "$result"

	result=$(OPENCODE=1 OPENCODE_SESSION_ID="ses_current" AIDEVOPS_SIG_MODEL="" XDG_DATA_HOME="${tmp_home_19}/.local/share" HOME="$tmp_home_19" "$HELPER" generate --cli "OpenCode")
	assert_contains "explicit OPENCODE_SESSION_ID model used" "with gpt-5.5" "$result"
	assert_contains "explicit OPENCODE_SESSION_ID tokens used" "22 tokens on this" "$result"
else
	echo "  SKIP: sqlite3 not available"
fi

rm -rf "$tmp_home_19"

# ─────────────────────────────────────────────────────────────────────────────
# Test 20: session-mode footer detection uses explicit mode markers only
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 20: session-mode footer detection"
result=$(env -u FULL_LOOP_HEADLESS -u AIDEVOPS_HEADLESS -u OPENCODE_HEADLESS -u AIDEVOPS_SESSION_ORIGIN \
	OPENCODE=1 AIDEVOPS_HEADLESS_VARIANT_STANDARD="high" \
	"$HELPER" generate --cli "OpenCode" --model "m" --tokens 1 --time 60)
assert_contains "variant config alone remains interactive" "with the user in an interactive session" "$result"
assert_not_contains "variant config does not imply worker" "as a headless worker" "$result"

result=$(env -u FULL_LOOP_HEADLESS -u AIDEVOPS_HEADLESS -u OPENCODE_HEADLESS -u AIDEVOPS_SESSION_ORIGIN \
	OPENCODE=true AIDEVOPS_HEADLESS_VARIANT_STANDARD="high" \
	"$HELPER" generate --cli "OpenCode" --model "m" --tokens 1 --time 60)
assert_contains "truthy OPENCODE marks interactive" "with the user in an interactive session" "$result"

result=$(env -u FULL_LOOP_HEADLESS -u AIDEVOPS_HEADLESS -u OPENCODE_HEADLESS -u AIDEVOPS_SESSION_ORIGIN \
	-u OPENCODE_SESSION_ID -u CLAUDE_SESSION_ID OPENCODE=false CLAUDE_CODE=0 \
	"$HELPER" generate --cli "OpenCode" --model "m" --tokens 1 --time 60)
assert_not_contains "false runtime markers do not imply interactive" "with the user in an interactive session" "$result"

result=$(env -u FULL_LOOP_HEADLESS -u AIDEVOPS_HEADLESS -u OPENCODE_HEADLESS -u AIDEVOPS_SESSION_ORIGIN \
	-u OPENCODE_SESSION_ID -u CLAUDE_SESSION_ID OPENCODE=0 CLAUDE_CODE=true \
	"$HELPER" generate --cli "Claude Code" --model "m" --tokens 1 --time 60)
assert_contains "truthy CLAUDE_CODE marks interactive" "with the user in an interactive session" "$result"

result=$(env -u AIDEVOPS_HEADLESS -u OPENCODE_HEADLESS -u AIDEVOPS_SESSION_ORIGIN FULL_LOOP_HEADLESS=true \
	OPENCODE=1 "$HELPER" generate --cli "OpenCode" --model "m" --tokens 1 --time 60)
assert_contains "FULL_LOOP_HEADLESS marks worker" "as a headless worker" "$result"

result=$(env -u FULL_LOOP_HEADLESS -u OPENCODE_HEADLESS -u AIDEVOPS_SESSION_ORIGIN AIDEVOPS_HEADLESS=true \
	OPENCODE=1 "$HELPER" generate --cli "OpenCode" --model "m" --tokens 1 --time 60)
assert_contains "AIDEVOPS_HEADLESS marks worker" "as a headless worker" "$result"

result=$(env -u FULL_LOOP_HEADLESS -u AIDEVOPS_HEADLESS -u AIDEVOPS_SESSION_ORIGIN OPENCODE_HEADLESS=true \
	OPENCODE=1 "$HELPER" generate --cli "OpenCode" --model "m" --tokens 1 --time 60)
assert_contains "OPENCODE_HEADLESS marks worker" "as a headless worker" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Test 21: CI checkout version fallback prevents vunknown signatures
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 21: repo-relative version fallback"
tmp_home_21=$(mktemp -d 2>/dev/null || mktemp -d -t sighelper21)
result=$(HOME="$tmp_home_21" AIDEVOPS_SIG_CLI="OpenCode" AIDEVOPS_SIG_CLI_VERSION="1.14.33" \
	"$HELPER" generate --no-session)
assert_contains "repo VERSION used when HOME has no install" "[aidevops.sh](https://aidevops.sh) v" "$result"
assert_not_contains "signature does not emit vunknown" "vunknown" "$result"
assert_contains "explicit OpenCode version shown" "plugin for [OpenCode](https://opencode.ai) v1.14.33" "$result"
result=$(HOME="$tmp_home_21" OPENCODE_VERSION="1.14.34" "$HELPER" generate --no-session --cli "OpenCode")
assert_contains "OpenCode CLI override still detects version" "plugin for [OpenCode](https://opencode.ai) v1.14.34" "$result"
rm -rf "$tmp_home_21"

# ─────────────────────────────────────────────────────────────────────────────
# Test 22: footer dedup uses only a standalone canonical marker line
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "Test 22: footer dedup requires a standalone canonical marker line"
result=$("$HELPER" footer --body "See aidevops.sh:1715 for the release entry point" \
	--cli "OpenCode" --model "m" --tokens 1)
assert_contains "root script reference still receives footer" "<!-- aidevops:sig -->" "$result"

result=$("$HELPER" footer --body "Documentation mentions <!-- aidevops:sig --> inline" \
	--cli "OpenCode" --model "m" --tokens 1)
assert_contains "inline marker mention still receives footer" "<!-- aidevops:sig -->" "$result"

result=$("$HELPER" footer --body $'Existing footer\n<!-- aidevops:sig -->\n---\nsigned' \
	--cli "OpenCode" --model "m" --tokens 1)
assert_eq "standalone marker suppresses duplicate footer" "" "$result"

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
