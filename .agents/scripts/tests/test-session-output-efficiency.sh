#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
HELPER="${SCRIPT_DIR}/../session-output-efficiency-helper.sh"
REVIEW_HELPER="${SCRIPT_DIR}/../session-review-helper.sh"
TMPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_TEST"' EXIT

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

assert_omits() {
	local name="$1"
	local needle="$2"
	local haystack="$3"
	if [[ "$haystack" != *"$needle"* ]]; then
		pass "$name"
	else
		fail "$name" "unexpected ${needle}"
	fi
	return 0
}

normalized_fixture="${TMPDIR_TEST}/normalized.jsonl"
starvation_fixture="${TMPDIR_TEST}/starvation.jsonl"
claude_fixture="${TMPDIR_TEST}/claude.jsonl"
opencode_db="${TMPDIR_TEST}/opencode history?#.db"
active_data_home="${TMPDIR_TEST}/active-data"
active_opencode_db="${active_data_home}/opencode/opencode.db"
mkdir -p "${active_data_home}/opencode"

python3 - "$normalized_fixture" "$starvation_fixture" "$claude_fixture" "$opencode_db" "$active_opencode_db" <<'PY'
import json
import sqlite3
import sys

normalized_path, starvation_path, claude_path, database_path, active_database_path = sys.argv[1:]
repeated = "unchanged status snapshot SECRET-MARKER " + ("x" * 100)
oversized = "large setup output " + ("y" * 9000)
duplicate = "duplicate tool result " + ("d" * 100)
repeated_line = "repeated line inside one model-visible result " + ("l" * 40)
block = "\n".join([
    "block line alpha " + ("a" * 40),
    "block line beta " + ("b" * 40),
    "block line gamma " + ("c" * 40),
])
fragment_output = "\n".join([repeated_line, repeated_line, repeated_line, block, block])
huge_fragment_output = "\n".join(["very large repeated fragment " + ("z" * 80)] * 1500)
receipt = "\n".join([
    "output_id: out_123_example",
    "outcome: succeeded",
    "exit_code: 0",
    "process_exit: 0",
    "evidence: bytes=23067 lines=134 sensitive_redacted=0 basis=exit-code",
])
json_receipt = json.dumps({
    "schema": "aidevops.operation-result/v1",
    "evidence": {"bytes": 4096},
})

with open(normalized_path, "w", encoding="utf-8") as handle:
    for _ in range(3):
        handle.write(json.dumps({"tool": "bash", "input": {"command": "poll"}, "output": repeated}) + "\n")
    handle.write(json.dumps({"tool": "bash", "input": {"command": "poll"}, "output": "changed status"}) + "\n")
    handle.write(json.dumps({"tool": "bash", "input": {"command": "setup"}, "output": oversized, "success": True}) + "\n")
    handle.write(json.dumps({"tool": "bash", "input": {"command": "fragments"}, "output": fragment_output, "success": True}) + "\n")
    handle.write(json.dumps({"tool": "bash", "input": {"command": "huge-fragments"}, "output": huge_fragment_output, "success": True}) + "\n")
    handle.write(json.dumps({"tool": "read", "input": {"path": "one"}, "output": duplicate, "success": True}) + "\n")
    handle.write(json.dumps({"tool": "read", "input": {"path": "two"}, "output": duplicate, "success": True}) + "\n")
    handle.write(json.dumps({"tool": "bash", "input": {"command": "receipt"}, "output": receipt, "success": True}) + "\n")
    handle.write(json.dumps({"tool": "bash", "input": {"command": "json-receipt"}, "output": json_receipt, "success": True}) + "\n")
    handle.write(json.dumps({"tool": "bash", "input": {"command": "fallback"}, "output": "output_sandbox: evidence store unavailable; running with native output\nnative output", "success": True}) + "\n")
    handle.write(json.dumps({"tool": "bash", "input": {"command": "exact"}, "output": "output_sandbox: bypass exact/verbatim command\nexact output", "success": True}) + "\n")

with open(starvation_path, "w", encoding="utf-8") as handle:
    for group_index in range(6):
        duplicate_output = f"duplicate group {group_index} " + ("d" * 100)
        for input_index in range(2):
            handle.write(json.dumps({
                "tool": "bash",
                "input": {"command": f"PRIVATE-STARVATION-{group_index}-{input_index}"},
                "output": duplicate_output,
                "success": True,
            }) + "\n")
    handle.write(json.dumps({"tool": "bash", "input": {}, "output": "b" * 9000, "success": True}) + "\n")
    handle.write(json.dumps({"tool": "read", "input": {}, "output": "r" * 10000, "success": True}) + "\n")

with open(claude_path, "w", encoding="utf-8") as handle:
    for call_id in ("call-1", "call-2"):
        handle.write(json.dumps({"type": "assistant", "message": {"content": [
            {"type": "tool_use", "id": call_id, "name": "Bash", "input": {"command": "poll"}}
        ]}}) + "\n")
        handle.write(json.dumps({"type": "user", "message": {"content": [
            {"type": "tool_result", "tool_use_id": call_id, "content": repeated}
        ]}}) + "\n")

connection = sqlite3.connect(database_path)
connection.execute("CREATE TABLE part (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)")
for index in range(2):
    part = {
        "type": "tool",
        "tool": "bash",
        "state": {"status": "completed", "input": {"command": "poll"}, "output": repeated},
    }
    connection.execute(
        "INSERT INTO part (id, session_id, time_created, data) VALUES (?, ?, ?, ?)",
        (f"part-{index}", "session-test", index, json.dumps(part)),
    )
connection.commit()
connection.close()

connection = sqlite3.connect(active_database_path)
connection.execute("CREATE TABLE session (id TEXT PRIMARY KEY)")
connection.execute("CREATE TABLE part (id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT)")
connection.execute("INSERT INTO session (id) VALUES ('active-session')")
connection.execute("INSERT INTO session (id) VALUES ('not-ready-session')")
for index in range(2):
    part = {
        "type": "tool",
        "tool": "bash",
        "state": {"status": "completed", "input": {"command": "poll"}, "output": repeated},
    }
    connection.execute(
        "INSERT INTO part (id, session_id, time_created, data) VALUES (?, ?, ?, ?)",
        (f"active-part-{index}", "active-session", index, json.dumps(part)),
    )
unrelated_part = {
    "type": "tool",
    "tool": "read",
    "state": {"status": "completed", "input": {}, "output": "UNRELATED-RECENT-SESSION"},
}
connection.execute(
    "INSERT INTO part (id, session_id, time_created, data) VALUES (?, ?, ?, ?)",
    ("unrelated-part", "unrelated-recent-session", 1, json.dumps(unrelated_part)),
)
connection.commit()
connection.close()
PY

text_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --input "$normalized_fixture")
assert_contains "text reports one repeated group" "Repeated unchanged snapshots: 1 groups, 2 redundant results" "$text_output"
assert_contains "text reports oversized output" "Oversized tool results: 2" "$text_output"
assert_contains "text identifies unchanged snapshots" "unchanged-snapshot" "$text_output"
assert_contains "text identifies duplicate tool output" "Duplicate tool-output groups: 1" "$text_output"
assert_contains "text identifies repeated blocks" "Repeated line/block groups:" "$text_output"
assert_contains "text distinguishes receipt background evidence" "27163 declared bytes across 2 receipts" "$text_output"
assert_contains "text reports raw fallback and exact bypass" "Raw fallback / exact-output bypass results: 1 / 1" "$text_output"
assert_omits "text omits raw output" "SECRET-MARKER" "$text_output"

json_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --input "$normalized_fixture" --json)
if python3 -c 'import json,sys; report=json.load(sys.stdin); stats=report["stats"]; visibility=report["visibility"]; assert report["schema"] == "aidevops.session-output-efficiency/v1"; assert stats["redundant_tool_results"] == 2; assert stats["duplicate_output_groups"] == 1; assert stats["repeated_line_groups"] == 2; assert stats["repeated_block_groups"] >= 1; assert stats["oversized_tool_results"] == 2; assert stats["successful_oversized_results"] == 2; assert stats["raw_fallback_results"] == 1; assert stats["exact_output_bypass_results"] == 1; assert visibility["receipt_results"] == 2; assert visibility["declared_background_evidence_bytes"] == 27163; assert visibility["background_content_scanned"] is False; assert report["category_summary"]' <<<"$json_output"; then
	pass "JSON contract exposes aggregate metrics"
else
	fail "JSON contract exposes aggregate metrics"
fi

starvation_json=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --input "$starvation_fixture" --max-findings 5 --json)
if python3 -c 'import json,sys; report=json.load(sys.stdin); assert len(report["findings"]) == 5; assert {item["kind"] for item in report["findings"]} == {"duplicate-output"}; summary={item["kind"]: item for item in report["category_summary"]}; assert list(summary) == ["duplicate-output", "success-verbosity", "oversized-output"]; assert summary["oversized-output"] == {"kind": "oversized-output", "finding_count": 2, "occurrences": 2, "aggregate_bytes": 19000, "leading_tool": "read"}' <<<"$starvation_json"; then
	pass "category summary prevents detailed-finding starvation"
else
	fail "category summary prevents detailed-finding starvation"
fi
assert_omits "category summary omits private inputs" "PRIVATE-STARVATION" "$starvation_json"

starvation_text=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --input "$starvation_fixture" --max-findings 5)
assert_contains "text renders oversized category coverage" "oversized-output: groups=2, occurrences=2, aggregate_bytes=19000, leading_tool=read" "$starvation_text"

claude_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --runtime claude-code --input "$claude_fixture")
assert_contains "Claude JSONL tool results are correlated" "Repeated unchanged snapshots: 1 groups, 1 redundant results" "$claude_output"

database_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --runtime opencode --db "$opencode_db" --session session-test)
assert_contains "OpenCode database tool parts are analysed" "Repeated unchanged snapshots: 1 groups, 1 redundant results" "$database_output"

active_output=$(XDG_DATA_HOME="$active_data_home" OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --runtime opencode --session active-session --json)
if python3 -c 'import json,sys; report=json.load(sys.stdin); assert report["session"] == "active-session"; assert report["stats"]["completed_tool_results"] == 2' <<<"$active_output"; then
	pass "active OpenCode store resolves the exact current session"
else
	fail "active OpenCode store resolves the exact current session"
fi
assert_omits "active aggregate report omits raw output" "SECRET-MARKER" "$active_output"
assert_omits "active analysis does not substitute an unrelated recent session" "UNRELATED-RECENT-SESSION" "$active_output"

mapped_output=$(
	XDG_DATA_HOME="$active_data_home" \
		AIDEVOPS_SESSION_ID="framework-session" \
		OPENCODE_SESSION_ID="stale-opencode-session" \
		AIDEVOPS_OPENCODE_SESSION_ID="active-session" \
		"$HELPER" --runtime opencode --session framework-session --json
)
if python3 -c 'import json,sys; report=json.load(sys.stdin); assert report["session"] == "active-session"; assert report["stats"]["completed_tool_results"] == 2' <<<"$mapped_output"; then
	pass "explicit framework-to-OpenCode identity mapping is honoured"
else
	fail "explicit framework-to-OpenCode identity mapping is honoured"
fi

set +e
unmapped_output=$(
	AIDEVOPS_SESSION_ID="framework-session" \
		AIDEVOPS_OPENCODE_SESSION_ID='' \
		OPENCODE_SESSION_ID="active-session" \
		"$HELPER" --runtime opencode --db "$active_opencode_db" --session framework-session --json 2>&1
)
unmapped_rc=$?
mismatched_output=$(OPENCODE_SESSION_ID='' AIDEVOPS_OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --runtime opencode --db "$active_opencode_db" --session missing-active-session --json 2>&1)
mismatched_rc=$?
set -e
[[ "$unmapped_rc" -eq 2 ]] && pass "framework identity requires an explicit OpenCode mapping" || fail "framework identity requires an explicit OpenCode mapping" "got ${unmapped_rc}"
[[ "$mismatched_rc" -eq 2 ]] && pass "mismatched active identifier remains unavailable" || fail "mismatched active identifier remains unavailable" "got ${mismatched_rc}"
assert_omits "mismatched identity does not expose unrelated recent sessions" "UNRELATED-RECENT-SESSION" "${unmapped_output}${mismatched_output}"

set +e
missing_session_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --runtime opencode --db "$opencode_db" --session absent-session 2>&1)
missing_session_rc=$?
invalid_session_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --runtime opencode --db "$opencode_db" --session '../*' 2>&1)
invalid_session_rc=$?
not_ready_output=$(XDG_DATA_HOME="$active_data_home" OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --runtime opencode --session not-ready-session --json 2>&1)
not_ready_rc=$?
set -e
[[ "$missing_session_rc" -eq 2 ]] && pass "missing database session is unavailable" || fail "missing database session is unavailable" "got ${missing_session_rc}"
[[ "$invalid_session_rc" -eq 2 ]] && pass "unsafe session filter is rejected" || fail "unsafe session filter is rejected" "got ${invalid_session_rc}"
[[ "$not_ready_rc" -eq 2 ]] && pass "active session without parts is not reported as zero activity" || fail "active session without parts is not reported as zero activity" "got ${not_ready_rc}"
assert_contains "active session without parts reports not-ready state" "session transcript is not ready" "$not_ready_output"
assert_omits "session errors do not expose database path" "$opencode_db" "${missing_session_output}${invalid_session_output}"

review_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$REVIEW_HELPER" output-efficiency --input "$normalized_fixture" --json)
assert_contains "session review delegates output analysis" '"schema":"aidevops.session-output-efficiency/v1"' "$review_output"

set +e
invalid_output=$(OPENCODE_SESSION_ID='' CLAUDE_SESSION_ID='' "$HELPER" --input "${TMPDIR_TEST}/missing.jsonl" 2>&1)
invalid_rc=$?
set -e
[[ "$invalid_rc" -eq 2 ]] && pass "missing transcript returns usage error" || fail "missing transcript returns usage error" "got ${invalid_rc}"
assert_omits "missing transcript does not expose requested path" "$TMPDIR_TEST" "$invalid_output"

printf '%s passed, %s failed\n' "$pass_count" "$fail_count"
[[ "$fail_count" -eq 0 ]]
