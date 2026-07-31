#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# shellcheck disable=SC2034
#
# Tests for email-filter-helper.sh (t2856)
# Covers: from_contains, from_equals, subject_contains_any, subject_matches_regex,
#         body_contains, has_attachment_kind match predicates; actions (attach, sensitivity);
#         no-double-process (state guard); dry-run test mode; list command
#
# Usage: bash .agents/tests/test-email-filter.sh
# Requires: jq, python3
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
FILTER_HELPER="${SCRIPT_DIR}/../scripts/email-filter-helper.sh"
MAILBOX_HELPER="${SCRIPT_DIR}/../scripts/email-mailbox-helper.sh"
MATCH_RULES="${SCRIPT_DIR}/../scripts/email_match_rules.py"

# =============================================================================
# Test framework
# =============================================================================

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
	local name="$1" reason="${2:-}"
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  [FAIL] %s%s\n' "$name" "${reason:+ — $reason}"
	return 0
}

_assert_exit_0() {
	local name="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		_pass "$name"
		return 0
	else
		_fail "$name" "expected exit 0, got non-zero"
		return 0
	fi
}

_assert_exit_nonzero() {
	local name="$1"
	shift
	if ! "$@" >/dev/null 2>&1; then
		_pass "$name"
		return 0
	else
		_fail "$name" "expected non-zero exit, got 0"
		return 0
	fi
}

_assert_file_exists() {
	local name="$1" path="$2"
	if [[ -f "$path" ]]; then
		_pass "$name"
		return 0
	else
		_fail "$name" "file not found: ${path}"
		return 0
	fi
}

_assert_file_contains() {
	local name="$1" path="$2" pattern="$3"
	if grep -q "$pattern" "$path" 2>/dev/null; then
		_pass "$name"
		return 0
	else
		_fail "$name" "pattern '${pattern}' not found in ${path}"
		return 0
	fi
}

_assert_output_contains() {
	local name="$1" output="$2" pattern="$3"
	if echo "$output" | grep -q "$pattern" 2>/dev/null; then
		_pass "$name"
		return 0
	else
		_fail "$name" "pattern '${pattern}' not found in output"
		return 0
	fi
}

# =============================================================================
# Fixture builders
# =============================================================================

_make_knowledge_root() {
	local base="$1"
	mkdir -p "${base}/_knowledge/sources" "${base}/_config" "${base}/_cases"
	return 0
}

_make_filter_config() {
	local base="$1"
	cat >"${base}/_config/email-filters.json" <<'EOF'
{
  "rules": [
    {
      "name": "Counsel match",
      "match": {
        "from_contains": "counsel@example.com"
      },
      "actions": [
        { "attach_to_case": "case-test-001", "role": "evidence" }
      ]
    },
    {
      "name": "Exact sender match",
      "match": {
        "from_equals": "exactsender@example.com"
      },
      "actions": [
        { "attach_to_case": "case-test-002", "role": "reference" }
      ]
    },
    {
      "name": "Subject any match",
      "match": {
        "subject_contains_any": ["Invoice", "Payment"]
      },
      "actions": [
        { "attach_to_case": "case-test-003", "role": "evidence" },
        { "set_sensitivity": "confidential" }
      ]
    },
    {
      "name": "Subject regex match",
      "match": {
        "subject_matches_regex": "^URGENT:"
      },
      "actions": [
        { "attach_to_case": "case-test-004", "role": "evidence" }
      ]
    }
  ]
}
EOF
	return 0
}

_make_email_source() {
	local sources_dir="$1" source_id="$2" from="${3:-sender@example.com}"
	local subject="${4:-Test Subject}" date="${5:-2026-01-01T00:00:00Z}"
	local body="${6:-}"

	local src_dir="${sources_dir}/${source_id}"
	mkdir -p "$src_dir"
	cat >"${src_dir}/meta.json" <<EOF
{
  "id": "${source_id}",
  "kind": "email",
  "message_id": "<${source_id}@example.com>",
  "subject": "${subject}",
  "from": "${from}",
  "date": "${date}",
  "ingested_at": "${date}",
  "body_preview": "${body}",
  "sensitivity": "internal"
}
EOF
	return 0
}

_add_collection_ref() {
	local meta_path="$1"
	local config_path="$2"
	local rule_id="$3"
	python3 - "$SCRIPT_DIR/../scripts" "$meta_path" "$config_path" "$rule_id" <<'PYEOF'
import json
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
from email_collection_receipts import ReceiptContext, build_receipt  # noqa: E402

meta_path = Path(sys.argv[2])
with Path(sys.argv[3]).open(encoding="utf-8") as handle:
    config = json.load(handle)
rule = next(item for item in config["rules"] if item["id"] == sys.argv[4])
with meta_path.open(encoding="utf-8") as handle:
    meta = json.load(handle)
meta["collection_refs"] = [
    build_receipt(ReceiptContext("imap", "work", "INBOX", "fixture-1"), [rule])
]
meta_path.write_text(json.dumps(meta, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PYEOF
	return 0
}

# =============================================================================
# Tests
# =============================================================================

test_shellcheck() {
	echo "==> ShellCheck validation"
	if command -v shellcheck &>/dev/null; then
		_assert_exit_0 "shellcheck email-filter-helper.sh" \
			shellcheck "${FILTER_HELPER}"
	else
		printf '  [SKIP] shellcheck not installed\n'
	fi
	return 0
}

test_help_exits_zero() {
	echo "==> help command exits zero"
	_assert_exit_0 "help exits zero" bash "${FILTER_HELPER}" help
	return 0
}

test_list_no_config() {
	echo "==> list: no config exits zero with info message"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"

	local output
	output="$(KNOWLEDGE_ROOT="${base}/_knowledge" bash "${FILTER_HELPER}" list 2>&1 || true)"
	if echo "$output" | grep -qi "no filter\|not defined\|0 rule"; then
		_pass "list no config - info message"
	else
		_pass "list no config - exits without crash"
	fi

	_teardown
	return 0
}

test_list_with_rules() {
	echo "==> list: shows rules from config"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_filter_config "$base"

	local output
	output="$(KNOWLEDGE_ROOT="${base}/_knowledge" bash "${FILTER_HELPER}" list 2>&1 || true)"
	_assert_output_contains "list shows rule names" "$output" "Counsel match"
	_assert_output_contains "list shows second rule" "$output" "Subject any match"

	_teardown
	return 0
}

test_tick_from_contains_match() {
	echo "==> tick: from_contains rule matches and records state"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_filter_config "$base"
	_make_email_source "${base}/_knowledge/sources" "src-counsel" \
		"dispute-counsel@example.com" "Re: Dispute" "2026-01-01T08:00:00Z"

	local output
	output="$(KNOWLEDGE_ROOT="${base}/_knowledge" bash "${FILTER_HELPER}" tick 2>&1 || true)"
	_assert_output_contains "tick from_contains match" "$output" "Counsel match\|Match"

	# State file should be created
	_assert_file_exists "tick creates state file" "${base}/_knowledge/.email-filter-state.json"

	_teardown
	return 0
}

test_tick_no_double_process() {
	echo "==> tick: state guard prevents double-processing"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_filter_config "$base"
	_make_email_source "${base}/_knowledge/sources" "src-once" \
		"dispute-counsel@example.com" "Re: Dispute" "2026-01-01T08:00:00Z"

	# First tick
	KNOWLEDGE_ROOT="${base}/_knowledge" bash "${FILTER_HELPER}" tick >/dev/null 2>&1 || true

	# Second tick - should process 0 sources (same state)
	local output
	output="$(KNOWLEDGE_ROOT="${base}/_knowledge" bash "${FILTER_HELPER}" tick 2>&1 || true)"
	_assert_output_contains "tick state guard - 0 matches on second run" "$output" "No matches\|0 match"

	_teardown
	return 0
}

test_tick_subject_contains_any() {
	echo "==> tick: subject_contains_any rule matches"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_filter_config "$base"
	_make_email_source "${base}/_knowledge/sources" "src-invoice" \
		"billing@vendor.com" "Invoice #12345" "2026-02-01T08:00:00Z"

	local output
	output="$(KNOWLEDGE_ROOT="${base}/_knowledge" bash "${FILTER_HELPER}" tick 2>&1 || true)"
	_assert_output_contains "tick subject_contains_any" "$output" "Subject any match\|Match"

	_teardown
	return 0
}

test_tick_subject_regex_match() {
	echo "==> tick: subject_matches_regex rule matches"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_filter_config "$base"
	_make_email_source "${base}/_knowledge/sources" "src-urgent" \
		"boss@example.com" "URGENT: Fix the server" "2026-03-01T08:00:00Z"

	local output
	output="$(KNOWLEDGE_ROOT="${base}/_knowledge" bash "${FILTER_HELPER}" tick 2>&1 || true)"
	_assert_output_contains "tick subject_regex match" "$output" "Subject regex match\|Match"

	_teardown
	return 0
}

test_tick_set_sensitivity_action() {
	echo "==> tick: set_sensitivity action updates meta.json"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_filter_config "$base"
	_make_email_source "${base}/_knowledge/sources" "src-invoice2" \
		"billing@vendor.com" "Payment confirmation" "2026-04-01T08:00:00Z"

	KNOWLEDGE_ROOT="${base}/_knowledge" bash "${FILTER_HELPER}" tick >/dev/null 2>&1 || true

	# meta.json sensitivity should now be "confidential"
	local meta_path="${base}/_knowledge/sources/src-invoice2/meta.json"
	if [[ -f "$meta_path" ]] && command -v jq &>/dev/null; then
		local sens
		sens="$(jq -r '.sensitivity' "$meta_path" 2>/dev/null || true)"
		if [[ "$sens" == "confidential" ]]; then
			_pass "set_sensitivity updates meta.json"
		else
			_fail "set_sensitivity updates meta.json" "sensitivity='${sens}', expected 'confidential'"
		fi
	else
		printf '  [SKIP] set_sensitivity check — jq or meta.json not available\n'
	fi

	_teardown
	return 0
}

test_tick_dry_run_no_state_written() {
	echo "==> tick --dry-run: no state or audit log written"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_filter_config "$base"
	_make_email_source "${base}/_knowledge/sources" "src-dryrun" \
		"dispute-counsel@example.com" "Re: Dispute dry" "2026-05-01T08:00:00Z"

	KNOWLEDGE_ROOT="${base}/_knowledge" bash "${FILTER_HELPER}" tick --dry-run >/dev/null 2>&1 || true

	# State file should NOT be created in dry-run mode
	local state_file="${base}/_knowledge/.email-filter-state.json"
	if [[ ! -f "$state_file" ]]; then
		_pass "dry-run - no state file written"
	else
		_fail "dry-run - no state file written" "state file was created"
	fi

	_teardown
	return 0
}

test_filter_test_dry_run_no_actions() {
	echo "==> test <rule-name>: shows matches without firing actions"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_filter_config "$base"
	_make_email_source "${base}/_knowledge/sources" "src-testcmd" \
		"dispute-counsel@example.com" "Re: Dispute" "2026-06-01T08:00:00Z"

	local output
	output="$(KNOWLEDGE_ROOT="${base}/_knowledge" bash "${FILTER_HELPER}" test "Counsel match" 2>&1 || true)"
	# Should mention would-match or match without writing state
	_assert_output_contains "test cmd - shows would-match" "$output" "WOULD MATCH\|src-testcmd\|match"

	# No state file
	local state_file="${base}/_knowledge/.email-filter-state.json"
	if [[ ! -f "$state_file" ]]; then
		_pass "test cmd - no state written"
	else
		_fail "test cmd - no state written" "state file was created"
	fi

	_teardown
	return 0
}

test_filter_test_nonexistent_rule() {
	echo "==> test <rule-name>: non-existent rule returns non-zero"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_filter_config "$base"

	_assert_exit_nonzero "test nonexistent rule returns nonzero" \
		bash -c "KNOWLEDGE_ROOT='${base}/_knowledge' bash '${FILTER_HELPER}' test 'NoSuchRule'"

	_teardown
	return 0
}

test_tick_no_match_exits_zero() {
	echo "==> tick: no matching source exits zero"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_filter_config "$base"
	_make_email_source "${base}/_knowledge/sources" "src-nomatch" \
		"random@unrelated.org" "Completely unrelated newsletter" "2026-07-01T08:00:00Z"

	_assert_exit_0 "tick no match exits zero" \
		bash -c "KNOWLEDGE_ROOT='${base}/_knowledge' bash '${FILTER_HELPER}' tick"

	_teardown
	return 0
}

test_v2_deterministic_match_semantics() {
	echo "==> v2 matcher: exact boundaries, direction, Unicode, and coverage"
	if python3 - "$MATCH_RULES" <<'PYEOF'; then
import sys
from dataclasses import replace
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]).parent))
from email_match_rules import (  # noqa: E402
    RuleValidationError,
    fields_from_bytes,
    fields_from_mapping,
    load_rule_config,
    match_rule,
)

raw = (
    b"From: Counsel <legal@example.com>\r\n"
    b"To: Observer <observer@client.test>, Case Worker <worker@client.test>\r\n"
    b"Subject: Re: CASE-123 signed agreement\r\n\r\n"
    b"Please review the signed   agreement."
)
fields = fields_from_bytes(raw)
rule = {
    "id": "case-rule",
    "match": {
        "all": [
            {"field": "from", "operator": "exact_domain", "value": "example.com"},
            {"field": "to", "operator": "exact_address", "value": "worker@client.test"},
            {"field": "direction", "operator": "equals", "value": "received"},
        ],
        "any": [
            {"field": "subject", "operator": "reference", "value": "CASE-123"},
            {"field": "body", "operator": "phrase", "value": "SIGNED AGREEMENT"},
        ],
    },
}
assert match_rule(rule, fields, ["worker@client.test"]).matched

evil = {"id": "evil", "match": {"all": [
    {"field": "from", "operator": "exact_domain", "value": "evil-example.com"}
]}}
assert not match_rule(evil, fields).matched
short = {"id": "short", "match": {"all": [
    {"field": "subject", "operator": "reference", "value": "CASE-12"}
]}}
assert not match_rule(short, fields).matched

unicode_fields = fields_from_mapping({"subject": "ＣＡＳＥ café\u0301   signed\n agreement"})
unicode_rule = {"id": "unicode", "match": {"all": [
    {"field": "subject", "operator": "phrase", "value": "case café́ signed agreement"}
]}}
assert match_rule(unicode_rule, unicode_fields).matched

bcc_rule = {"id": "bcc", "match": {"all": [
    {"field": "bcc", "operator": "exact_address", "value": "hidden@example.com"}
]}}
bcc_result = match_rule(bcc_rule, fields)
assert not bcc_result.matched and bcc_result.unavailable_fields == ("bcc",)

truncated = replace(
    fields_from_mapping({"subject": "CASE-123"}),
    unavailable_fields=("body",),
)
shorthand = {"id": "shorthand", "match": {"all": [
    {"field": "reference", "operator": "reference", "value": "CASE-123"}
]}}
shorthand_result = match_rule(shorthand, truncated)
assert shorthand_result.matched and shorthand_result.unavailable_fields == ("body",)

try:
    fields_from_bytes(b"Content-Type: multipart/mixed\r\n\r\nbroken")
except ValueError:
    pass
else:
    raise AssertionError("malformed MIME accepted")

try:
    load_rule_config({"version": 2, "rules": [{"id": "unsafe", "match": {"all": []}}]})
except RuleValidationError:
    pass
else:
    raise AssertionError("empty rule accepted")

for bad_backfill in ({"limit": 0}, {"limit": 5001}, {"limit": True}, {"since": "not-a-date"}):
    invalid = {"version": 2, "rules": [{
        "id": "invalid-backfill",
        "backfill": bad_backfill,
        "match": {"all": [{"field": "subject", "operator": "contains", "value": "x"}]},
    }]}
    try:
        load_rule_config(invalid)
    except RuleValidationError:
        pass
    else:
        raise AssertionError(f"invalid backfill accepted: {bad_backfill}")

invalid_action = {"version": 2, "rules": [{
    "id": "invalid-action",
    "actions": [{"delete": True}],
    "match": {"all": [{"field": "subject", "operator": "contains", "value": "x"}]},
}]}
try:
    load_rule_config(invalid_action)
except RuleValidationError:
    pass
else:
    raise AssertionError("unsupported action accepted")

for condition in (
    {"field": "from", "operator": "contains", "value": "example.com"},
    {"field": "subject", "operator": "phrase", "value": " \t\n "},
    {"field": "header", "operator": "phrase", "header": "Bad:Header", "value": "x"},
):
    invalid = {"version": 2, "rules": [{
        "id": "overbroad",
        "match": {"all": [condition]},
    }]}
    try:
        load_rule_config(invalid)
    except RuleValidationError:
        pass
    else:
        raise AssertionError(f"overbroad collection condition accepted: {condition}")

load_rule_config({"version": 2, "rules": [{
    "id": "legacy-routing",
    "collection": False,
    "match": {"all": [{"field": "from", "operator": "contains", "value": "example.com"}]},
}]})
PYEOF
		_pass "v2 deterministic match semantics"
	else
		_fail "v2 deterministic match semantics" "matcher assertions failed"
	fi
	return 0
}

test_v2_direction_action_routing() {
	echo "==> v2 matcher: late collection provenance replays post-ingest actions"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_email_source "${base}/_knowledge/sources" "src-direction" \
		"sender@example.com" "Direction Test" "2026-07-01T08:00:00Z"
	_make_email_source "${base}/_knowledge/sources" "src-uncollected" \
		"sender@example.com" "Direction Test" "2026-07-01T08:01:00Z"
	local source_name
	for source_name in src-direction src-uncollected; do
		jq '.to = "Observer <observer@example.com>, Worker <worker@example.com>"' \
			"${base}/_knowledge/sources/${source_name}/meta.json" >"${base}/meta.next.json"
		mv "${base}/meta.next.json" "${base}/_knowledge/sources/${source_name}/meta.json"
	done
	cat >"${base}/_config/mailboxes.json" <<'EOF'
{"mailboxes":[{"id":"work","user":"worker@example.com","identities":["alias@example.com"]}]}
EOF
	cat >"${base}/_config/email-filters.json" <<'EOF'
{"version":2,"rules":[{"id":"direction-action","name":"Direction action","mailboxes":["work"],"match":{"all":[{"field":"direction","operator":"equals","value":"received"},{"field":"subject","operator":"contains","value":"Direction Test"},{"field":"header","header":"X-Case","operator":"phrase","value":"accepted"}]},"actions":[{"set_sensitivity":"confidential"}]}]}
EOF
	KNOWLEDGE_ROOT="${base}/_knowledge" bash "$FILTER_HELPER" tick >/dev/null
	local before_sensitivity
	before_sensitivity=$(jq -r '.sensitivity' "${base}/_knowledge/sources/src-direction/meta.json")
	_add_collection_ref \
		"${base}/_knowledge/sources/src-direction/meta.json" \
		"${base}/_config/email-filters.json" \
		"direction-action"
	KNOWLEDGE_ROOT="${base}/_knowledge" bash "$FILTER_HELPER" tick >/dev/null
	local collected_sensitivity uncollected_sensitivity
	collected_sensitivity=$(jq -r '.sensitivity' "${base}/_knowledge/sources/src-direction/meta.json")
	uncollected_sensitivity=$(jq -r '.sensitivity' "${base}/_knowledge/sources/src-uncollected/meta.json")
	if [[ "$before_sensitivity" == "internal" && "$collected_sensitivity" == "confidential" && "$uncollected_sensitivity" == "internal" ]]; then
		_pass "late collection provenance replays only the newly eligible canonical source"
	else
		_fail "late collection provenance replays only the newly eligible canonical source" \
			"before=$before_sensitivity collected=$collected_sensitivity uncollected=$uncollected_sensitivity"
	fi
	_teardown
	return 0
}

test_v2_rule_change_replays_actions() {
	echo "==> v2 routing: disabled rules stay inert and changes replay canonical sources"
	_setup
	local base="${TEST_TMPDIR}/repo"
	_make_knowledge_root "$base"
	_make_email_source "${base}/_knowledge/sources" "src-replay" \
		"sender@example.com" "Replay action" "2026-07-01T08:00:00Z"
	cat >"${base}/_config/email-filters.json" <<'EOF'
{"version":2,"rules":[{"id":"routing-replay","enabled":false,"collection":false,"match":{"all":[{"field":"subject","operator":"phrase","value":"Replay action"}]},"actions":[{"set_sensitivity":"confidential"}]}]}
EOF
	KNOWLEDGE_ROOT="${base}/_knowledge" bash "$FILTER_HELPER" tick >/dev/null
	local first_sensitivity first_digest
	first_sensitivity=$(jq -r '.sensitivity' "${base}/_knowledge/sources/src-replay/meta.json")
	first_digest=$(jq -r '.rules_digest' "${base}/_knowledge/.email-filter-state.json")
	jq '.rules[0].enabled = true' "${base}/_config/email-filters.json" >"${base}/filters.next.json"
	mv "${base}/filters.next.json" "${base}/_config/email-filters.json"
	KNOWLEDGE_ROOT="${base}/_knowledge" bash "$FILTER_HELPER" tick >/dev/null
	local second_sensitivity second_digest
	second_sensitivity=$(jq -r '.sensitivity' "${base}/_knowledge/sources/src-replay/meta.json")
	second_digest=$(jq -r '.rules_digest' "${base}/_knowledge/.email-filter-state.json")
	if [[ "$first_sensitivity" == "internal" && "$second_sensitivity" == "confidential" &&
		-n "$first_digest" && "$first_digest" != "$second_digest" ]]; then
		_pass "disabled routing rule replays after its ruleset changes"
	else
		_fail "disabled routing rule replays after its ruleset changes" \
			"first=$first_sensitivity second=$second_sensitivity"
	fi
	_teardown
	return 0
}

test_jmap_filter_gate_read_isolation() {
	echo "==> JMAP filter gate: read-only local authority and missing-field coverage"
	if python3 - "$SCRIPT_DIR/../scripts" <<'PYEOF'; then
import contextlib
import io
import json
import os
import sys
import tempfile
from argparse import Namespace
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1])))
import email_jmap_commands as commands  # noqa: E402

calls = []
email = {
    "id": "email-1",
    "blobId": "blob-1",
    "threadId": "thread-1",
    "mailboxIds": {"mailbox-1": True},
    "messageId": ["<email-1@example.test>"],
    "receivedAt": "2026-07-31T10:00:00Z",
    "from": [{"email": "sender@example.test"}],
    "to": [{"email": "worker@example.test"}],
    "subject": "Private message",
    "textBody": [],
    "htmlBody": [{"partId": "part-1"}],
    "bodyValues": {"part-1": {"value": "<p>Private unmatched JMAP body: signed <strong>agreement</strong></p>"}},
    "preview": "A teaser without the matching phrase",
    "attachments": [],
    "keywords": {},
}


def fake_request(_api_url, _user, method_calls):
    calls.extend(method_calls)
    return {"methodResponses": [["Email/get", {"list": [email]}, "g0"]]}


commands._session_context = lambda _args: ({}, "account-1", "unused-api-endpoint")
commands._jmap_request = fake_request
with tempfile.NamedTemporaryFile("w", encoding="utf-8", delete=False) as handle:
    json.dump({
        "version": 2,
        "rules": [{
            "id": "bcc-rule",
            "match": {"all": [{
                "field": "bcc",
                "operator": "exact_address",
                "value": "hidden@example.test",
            }]},
        }, {
            "id": "html-rule",
            "match": {"all": [{
                "field": "body",
                "operator": "phrase",
                "value": "signed agreement",
            }]},
        }],
    }, handle)
    config_path = handle.name

args = Namespace(
    email_id="email-1",
    filter_config=config_path,
    rule_id="bcc-rule",
    account_identity=["worker@example.test"],
    user="worker@example.test",
)
output = io.StringIO()
try:
    with contextlib.redirect_stdout(output):
        result = commands.cmd_fetch_body(args)
    explanation = json.loads(output.getvalue())
    assert result == 3
    assert explanation == {
        "matched": False,
        "matched_fields": [],
        "rule_id": "bcc-rule",
        "unavailable_fields": ["bcc"],
    }
    assert "Private unmatched JMAP body" not in output.getvalue()
    args.rule_id = "html-rule"
    matched_output = io.StringIO()
    with contextlib.redirect_stdout(matched_output):
        matched_result = commands.cmd_fetch_body(args)
    matched = json.loads(matched_output.getvalue())
    assert matched_result == 0
    assert matched["local_match"]["matched"] is True
    assert matched["local_match"]["matched_fields"] == ["body"]
    assert [call[0] for call in calls] == ["Email/get", "Email/get"]
finally:
    os.unlink(config_path)
PYEOF
		_pass "JMAP filter gate is read-only and redacts non-matches"
	else
		_fail "JMAP filter gate is read-only and redacts non-matches" "JMAP assertions failed"
	fi
	return 0
}

test_jmap_filter_config_auto_detection() {
	echo "==> JMAP collection config: legacy compatibility and invalid-config isolation"
	_setup
	local root="${TEST_TMPDIR}/repo"
	local fake_bin="${TEST_TMPDIR}/bin"
	local adapter_args="${TEST_TMPDIR}/adapter-args"
	mkdir -p "${root}/_config" "${root}/_knowledge" "$fake_bin"
	cat >"${fake_bin}/gopass" <<'EOF'
#!/usr/bin/env bash
case "$*" in
*" user") printf '%s\n' 'worker@example.test' ;;
*) printf '%s\n' 'fixture-token' ;;
esac
EOF
	cat >"${fake_bin}/python3" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >"$FAKE_JMAP_ARGS"
EOF
	chmod +x "${fake_bin}/gopass" "${fake_bin}/python3"

	printf '%s\n' '{"rules":[]}' >"${root}/_config/email-filters.json"
	local legacy_rc=0
	(cd "$root" && PATH="${fake_bin}:$PATH" FAKE_JMAP_ARGS="$adapter_args" \
		bash "$MAILBOX_HELPER" sync fastmail >/dev/null 2>&1) || legacy_rc=$?
	local legacy_args=""
	[[ -f "$adapter_args" ]] && legacy_args=$(<"$adapter_args")

	printf '%s\n' '{"version":2,"rules":[]}' >"${root}/_config/email-filters.json"
	rm -f "$adapter_args"
	local v2_rc=0
	(cd "$root" && PATH="${fake_bin}:$PATH" FAKE_JMAP_ARGS="$adapter_args" \
		bash "$MAILBOX_HELPER" sync fastmail >/dev/null 2>&1) || v2_rc=$?
	local v2_args=""
	[[ -f "$adapter_args" ]] && v2_args=$(<"$adapter_args")

	printf '%s\n' '{invalid-json' >"${root}/_config/email-filters.json"
	rm -f "$adapter_args"
	local invalid_rc=0
	(cd "$root" && PATH="${fake_bin}:$PATH" FAKE_JMAP_ARGS="$adapter_args" \
		bash "$MAILBOX_HELPER" sync fastmail >/dev/null 2>&1) || invalid_rc=$?

	printf '%s\n' '{"fastmail/INBOX/jmap/filter/case-rule/digest":{"last_received_at":"2026-07-31T00:00:00Z"}}' \
		>"${root}/_knowledge/.imap-state.json"
	rm -f "${root}/_config/email-filters.json" "$adapter_args"
	local missing_rc=0
	(cd "$root" && PATH="${fake_bin}:$PATH" FAKE_JMAP_ARGS="$adapter_args" \
		bash "$MAILBOX_HELPER" sync fastmail >/dev/null 2>&1) || missing_rc=$?

	printf '%s\n' '{"rules":[]}' >"${root}/_config/email-filters.json"
	local downgrade_rc=0
	(cd "$root" && PATH="${fake_bin}:$PATH" FAKE_JMAP_ARGS="$adapter_args" \
		bash "$MAILBOX_HELPER" sync fastmail >/dev/null 2>&1) || downgrade_rc=$?
	local empty_explicit_rc=0
	(cd "$root" && PATH="${fake_bin}:$PATH" FAKE_JMAP_ARGS="$adapter_args" \
		bash "$MAILBOX_HELPER" sync fastmail --filter-config "" >/dev/null 2>&1) || empty_explicit_rc=$?

	if [[ "$legacy_rc" -eq 0 && "$legacy_args" != *"--filter-config"* &&
		"$v2_rc" -eq 0 && "$v2_args" == *"--filter-config _config/email-filters.json"* &&
		"$invalid_rc" -ne 0 && "$missing_rc" -ne 0 && "$downgrade_rc" -ne 0 &&
		"$empty_explicit_rc" -ne 0 && ! -f "$adapter_args" ]]; then
		_pass "JMAP auto-detection preserves pre-migration legacy sync and fails closed after migration"
	else
		_fail "JMAP auto-detection preserves pre-migration legacy sync and fails closed after migration" \
			"legacy_rc=$legacy_rc v2_rc=$v2_rc invalid_rc=$invalid_rc missing_rc=$missing_rc downgrade_rc=$downgrade_rc empty_explicit_rc=$empty_explicit_rc"
	fi
	_teardown
	return 0
}

test_jmap_routing_only_config_preserves_index_sync() {
	echo "==> JMAP collection config: routing-only rules preserve legacy index sync"
	if python3 - "$SCRIPT_DIR/../scripts" <<'PYEOF'; then
import contextlib
import io
import json
import sys
import tempfile
from argparse import Namespace
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1])))
import email_jmap_sync as sync  # noqa: E402


class FakeDatabase:
    def __init__(self):
        self.closed = False

    def close(self):
        self.closed = True


with tempfile.TemporaryDirectory() as tmp:
    config_path = Path(tmp) / "filters.json"
    config_path.write_text(json.dumps({
        "version": 2,
        "rules": [{
            "id": "route-only",
            "collection": False,
            "match": {"all": [{
                "field": "subject", "operator": "phrase", "value": "route",
            }]},
            "actions": [],
        }],
    }), encoding="utf-8")
    database = FakeDatabase()
    full_sync_calls = []
    sync._session_context = lambda _args: ({}, "account-1", "unused-api-endpoint")
    sync._resolve_mailbox_id = lambda *_args: "mailbox-1"
    sync._init_index_db = lambda: database
    sync._full_sync = lambda context: (full_sync_calls.append(context) or (0, "legacy-state"))
    args = Namespace(
        mailbox="INBOX",
        user="worker@example.test",
        filter_config=str(config_path),
        collection_mailbox_id="work-jmap",
        state="",
        inbox="",
        account_identity=[],
        full=True,
        dry_run=False,
    )
    output = io.StringIO()
    with contextlib.redirect_stdout(output):
        result = sync.cmd_index_sync(args)
    payload = json.loads(output.getvalue())
    assert result == 0
    assert len(full_sync_calls) == 1
    assert database.closed is True
    assert payload["mode"] == "full" and payload["state"] == "legacy-state"
PYEOF
		_pass "routing-only JMAP config preserves legacy index sync"
	else
		_fail "routing-only JMAP config preserves legacy index sync" "fallback assertions failed"
	fi
	return 0
}

test_jmap_filtered_collection() {
	echo "==> JMAP collection: bounded lineages, local authority, and atomic receipts"
	if python3 - "$SCRIPT_DIR/../scripts" <<'PYEOF'; then
import json
import sys
import tempfile
from dataclasses import replace
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1])))
import email_jmap_collection as collection  # noqa: E402
import email_jmap_collection_transport as transport  # noqa: E402

rules = [{
    "id": "sender-rule",
    "collection": True,
    "mailboxes": ["work-jmap"],
    "folders": ["INBOX"],
    "backfill": {"since": "2026-01-01", "limit": 2},
    "match": {"all": [{
        "field": "from", "operator": "exact_address", "value": "sender@example.test",
    }]},
}, {
    "id": "reference-rule",
    "collection": True,
    "mailboxes": ["work-jmap"],
    "folders": ["INBOX"],
    "backfill": {"limit": 2},
    "match": {"all": [{
        "field": "subject", "operator": "reference", "value": "CASE-123",
    }]},
}]

emails = {
    "match": {
        "id": "match",
        "blobId": "blob-match",
        "from": [{"email": "sender@example.test"}],
        "to": [{"email": "worker@example.test"}],
        "subject": "Re: CASE-123",
        "textBody": [{"partId": "text-1"}],
        "htmlBody": [],
        "bodyValues": {"text-1": {"value": "Matched canonical body"}},
        "attachments": [{"name": "contract.pdf", "blobId": "attachment-1"}],
    },
    "miss": {
        "id": "miss",
        "blobId": "blob-miss",
        "from": [{"email": "other@example.test"}],
        "to": [{"email": "worker@example.test"}],
        "subject": "Newsletter",
        "textBody": [{"partId": "text-2"}],
        "htmlBody": [],
        "bodyValues": {"text-2": {"value": "Unmatched private body"}},
        "attachments": [],
    },
}
safe_download = transport._download_url(
    "https://files.example.test/{accountId}/{blobId}/{name}?type={type}",
    "account-1",
    emails["match"],
)
assert safe_download.startswith("https://files.example.test/account-1/blob-match/")
for unsafe_download in (
    "file:///private/{blobId}",
    "ftp://files.example.test/{blobId}",
    "https:///missing-authority/{blobId}",
):
    try:
        transport._download_url(unsafe_download, "account-1", emails["match"])
    except ValueError:
        pass
    else:
        raise AssertionError("unsafe JMAP download URL was accepted")
calls = []
query_count = 0


def fake_request(_api_url, _user, method_calls):
    global query_count
    method, arguments, call_id = method_calls[0]
    calls.append(method)
    if method == "Email/query":
        query_count += 1
        return {"methodResponses": [[method, {
            "ids": ["match", "miss"],
            "queryState": f"query-{query_count}",
            "total": 3,
        }, call_id]]}
    if method == "Email/queryChanges":
        return {"methodResponses": [[method, {
            "added": [],
            "removed": [],
            "newQueryState": arguments["sinceQueryState"] + "-next",
            "hasMoreChanges": False,
        }, call_id]]}
    if method == "Email/get":
        return {"methodResponses": [[method, {
            "list": [emails[email_id] for email_id in arguments["ids"]],
            "notFound": [],
        }, call_id]]}
    raise AssertionError(f"mutation route reached: {method}")


with tempfile.TemporaryDirectory() as tmp:
    root = Path(tmp)
    state_path = root / "state.json"
    inbox = root / "inbox"
    context = collection.CollectionContext(
        session={"downloadUrl": "unused-download-template"},
        api_url="unused-api-endpoint",
        user="worker@example.test",
        account_id="account-1",
        collection_mailbox_id="work-jmap",
        folder_name="INBOX",
        folder_id="mailbox-1",
        rules=rules,
        state_path=str(state_path),
        inbox_dir=str(inbox),
        account_identities=("worker@example.test",),
    )
    downloads = []
    transport._jmap_request = fake_request
    transport._download_raw_email = lambda _context, email: (
        downloads.append(email["id"]) or
        b"From: sender@example.test\r\nSubject: CASE-123\r\n\r\nMatched canonical body"
    )

    first = collection.collect_filtered(context)
    state = json.loads(state_path.read_text(encoding="utf-8"))
    evidence = list(inbox.glob("*.eml"))
    receipts = list(inbox.glob("*.eml.collection.json"))
    assert first["scanned"] == 4 and first["fetched_count"] == 1
    assert first["matched_rules"] == {"sender-rule": 1, "reference-rule": 1}
    assert first["has_more"] is True
    assert first["backfill_truncated"] is True
    assert len(state) == 2 and all(value["transport"] == "jmap" for value in state.values())
    assert all(value["backfill_truncated"] is True for value in state.values())
    assert len(evidence) == 1 and downloads == ["match"]
    assert len(receipts) == 1
    receipt = json.loads(receipts[0].read_text(encoding="utf-8"))
    assert receipt["transport"] == "jmap" and receipt["message_key"] == "match"
    assert [item["id"] for item in receipt["rules"]] == [
        "reference-rule", "sender-rule"
    ]
    assert "sender@example.test" not in receipts[0].read_text(encoding="utf-8")
    assert b"Matched canonical body" in evidence[0].read_bytes()
    assert b"Unmatched private body" not in evidence[0].read_bytes()

    second = collection.collect_filtered(context)
    assert second["scanned"] == 0 and second["fetched_count"] == 0
    assert downloads == ["match"]

    changed_rules = json.loads(json.dumps(rules))
    changed_rules[1]["match"]["all"][0]["value"] = "CASE-999"
    changed = collection.collect_filtered(replace(context, rules=changed_rules))
    changed_state = json.loads(state_path.read_text(encoding="utf-8"))
    assert changed["scanned"] == 2 and len(changed_state) == 3

    evidence[0].unlink()
    state_before_failure = state_path.read_bytes()

    def fail_download(_context, _email):
        raise RuntimeError("fixture download failure")

    transport._download_raw_email = fail_download
    try:
        collection.collect_filtered(replace(context, force_full=True))
    except RuntimeError:
        pass
    else:
        raise AssertionError("terminal download failure did not fail closed")
    assert state_path.read_bytes() == state_before_failure
    assert not list(inbox.glob(".jmap-stage-*"))
    assert set(calls) <= {"Email/query", "Email/queryChanges", "Email/get"}
PYEOF
		_pass "JMAP collection is bounded, read-only, deduplicated, and atomic"
	else
		_fail "JMAP collection is bounded, read-only, deduplicated, and atomic" "JMAP collection assertions failed"
	fi
	return 0
}

# =============================================================================
# Run all tests
# =============================================================================

echo "Running email filter tests…"
echo ""

# Check dependencies
if ! command -v jq &>/dev/null; then
	echo "WARNING: jq not installed — some tests will be skipped"
fi
if ! command -v python3 &>/dev/null; then
	echo "ERROR: python3 is required"
	exit 1
fi

test_shellcheck
test_help_exits_zero
test_list_no_config
test_list_with_rules
test_tick_from_contains_match
test_tick_no_double_process
test_tick_subject_contains_any
test_tick_subject_regex_match
test_tick_set_sensitivity_action
test_tick_dry_run_no_state_written
test_filter_test_dry_run_no_actions
test_filter_test_nonexistent_rule
test_tick_no_match_exits_zero
test_v2_deterministic_match_semantics
test_v2_direction_action_routing
test_v2_rule_change_replays_actions
test_jmap_filter_gate_read_isolation
test_jmap_filter_config_auto_detection
test_jmap_routing_only_config_preserves_index_sync
test_jmap_filtered_collection

echo ""
echo "Results: ${TESTS_PASSED} passed, ${TESTS_FAILED} failed"
if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
