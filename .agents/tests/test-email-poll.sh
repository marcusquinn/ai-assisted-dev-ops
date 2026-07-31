#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Tests for email-poll-helper.sh and email_poll.py (t2855)
# =============================================================================
# Run: bash .agents/tests/test-email-poll.sh
#
# Tests:
#   1. tick happy path — polls mailbox, writes .eml files, updates state
#   2. missing credentials handling — graceful error, no crash
#   3. IMAP connection failure — graceful error, continues
#   4. state persistence across runs — deduplication via last-seen UID
#   5. backfill with date filter — fetches from given date
#   6. dry-run test mode — no files written, no state committed
#   7. list command — shows mailbox info from config + state
#
# Mocking strategy: patches imaplib via PYTHONPATH override (no real connections)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/../scripts"
POLL_PY="${SCRIPTS_DIR}/email_poll.py"
POLL_HELPER="${SCRIPTS_DIR}/email-poll-helper.sh"

PASS=0
FAIL=0
TEST_TMPDIR=""

# ---------------------------------------------------------------------------
# Test infrastructure
# ---------------------------------------------------------------------------

setup() {
	TEST_TMPDIR=$(mktemp -d)
	return 0
}

teardown() {
	[[ -n "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
	return 0
}

pass() {
	local name="$1"
	PASS=$((PASS + 1))
	echo "[PASS] $name"
	return 0
}

fail() {
	local name="$1" reason="${2:-}"
	FAIL=$((FAIL + 1))
	echo "[FAIL] $name${reason:+ — $reason}"
	return 0
}

# ---------------------------------------------------------------------------
# Create fake imaplib modules via Python (avoids heredoc expansion issues)
# ---------------------------------------------------------------------------

create_mock_imap_happy() {
	# Creates a mock imaplib that returns one message with the given UID
	local mock_dir="$1"
	local fake_uid="${2:-1001}"
	python3 - "$mock_dir" "$fake_uid" <<'PYEOF'
import sys, textwrap
mock_dir, fake_uid = sys.argv[1], sys.argv[2]
code = textwrap.dedent(f"""
class IMAP4_SSL:
    def __init__(self, host, port=993):
        pass
    def login(self, user, password):
        return ("OK", [b"Logged in"])
    def select(self, folder, readonly=False):
        return ("OK", [b"1"])
    def uid(self, command, *args):
        uid = {fake_uid}
        if command == "SEARCH":
            return ("OK", [str(uid).encode()])
        if command == "FETCH":
            raw = b"From: sender@example.com\\r\\nSubject: Test\\r\\n\\r\\nBody text"
            header = f"{{uid}} (RFC822 {{{{len(raw)}}}} UID {{uid}})".encode()
            return ("OK", [(header, raw), b")"])
        return ("OK", [b""])
    def logout(self):
        return ("BYE", [b"x"])
""")
with open(f"{mock_dir}/imaplib.py", "w") as f:
    f.write(code)
PYEOF
	return 0
}

create_mock_imap_connfail() {
	local mock_dir="$1"
	python3 - "$mock_dir" <<'PYEOF'
import sys
mock_dir = sys.argv[1]
code = 'class IMAP4_SSL:\n    def __init__(self, host, port=993):\n        raise ConnectionRefusedError(f"Refused: {host}")\n'
with open(f"{mock_dir}/imaplib.py", "w") as f:
    f.write(code)
PYEOF
	return 0
}

create_mock_imap_backfill() {
	local mock_dir="$1"
	python3 - "$mock_dir" <<'PYEOF'
import sys
mock_dir = sys.argv[1]
code = '''class IMAP4_SSL:
    def __init__(self, host, port=993):
        pass
    def login(self, user, password):
        return ("OK", [b"Logged in"])
    def select(self, folder, readonly=False):
        return ("OK", [b"1"])
    def uid(self, command, *args):
        if command == "SEARCH":
            return ("OK", [b"2001 2002"])
        if command == "FETCH":
            raw = b"From: sender@example.com\\r\\n\\r\\nBackfill body"
            h1 = f"2001 (RFC822 {len(raw)} UID 2001)".encode()
            h2 = f"2002 (RFC822 {len(raw)} UID 2002)".encode()
            return ("OK", [(h1, raw), b")", (h2, raw), b")"])
        return ("OK", [b""])
    def logout(self):
        return ("BYE", [b"x"])
'''
with open(f"{mock_dir}/imaplib.py", "w") as f:
    f.write(code)
PYEOF
	return 0
}

create_mock_imap_filtered() {
	local mock_dir="$1"
	python3 - "$mock_dir" <<'PYEOF'
import sys

mock_dir = sys.argv[1]
code = '''class IMAP4_SSL:
    def __init__(self, host, port=993):
        pass
    def login(self, user, password):
        return ("OK", [b"Logged in"])
    def select(self, folder, readonly=False):
        assert readonly is True
        return ("OK", [b"2"])
    def uid(self, command, *args):
        if command == "SEARCH":
            return ("OK", [b"4001 4002"])
        if command == "FETCH":
            assert any("BODY.PEEK[]" in str(arg) for arg in args)
            matching = b"From: counsel@example.com\\r\\nTo: user@filtered-mb.example\\r\\nSubject: CASE-123\\r\\n\\r\\nPrivate matching content"
            unrelated = b"From: news@unrelated.test\\r\\nTo: user@filtered-mb.example\\r\\nSubject: Newsletter\\r\\n\\r\\nPrivate unmatched content"
            h1 = b"4001 (BODY[] {%d} UID 4001)" % len(matching)
            h2 = b"4002 (BODY[] {%d} UID 4002)" % len(unrelated)
            return ("OK", [(h1, matching), b")", (h2, unrelated), b")"])
        return ("OK", [b""])
    def logout(self):
        return ("BYE", [b"x"])
'''
with open(f"{mock_dir}/imaplib.py", "w") as handle:
    handle.write(code)
PYEOF
	return 0
}

# ---------------------------------------------------------------------------
# Shared config factory
# ---------------------------------------------------------------------------

make_mailbox_config() {
	local config_path="$1"
	local mb_id="${2:-test-mb}"
	local password_ref="${3:-TEST_EMAIL_PASSWORD}"
	python3 - "$config_path" "$mb_id" "$password_ref" <<'PYEOF'
import json, sys
config_path, mb_id, pw_ref = sys.argv[1], sys.argv[2], sys.argv[3]
data = {"mailboxes": [{"id": mb_id, "provider": "test", "host": "imap.test.example",
        "port": 993, "user": f"user@{mb_id}.example", "password_ref": pw_ref,
        "folders": ["INBOX"]}]}
with open(config_path, "w") as f:
    json.dump(data, f)
PYEOF
	return 0
}

# ---------------------------------------------------------------------------
# Test: missing config skips optional pulse tick
# ---------------------------------------------------------------------------

test_tick_missing_config_skips() {
	local name="tick: missing mailbox config skips cleanly"
	local tmpdir="${TEST_TMPDIR}/missing-config"
	mkdir -p "$tmpdir"

	local output exit_rc=0
	output=$(cd "$tmpdir" && HOME="$tmpdir/home" bash "$POLL_HELPER" tick 2>&1) || exit_rc=$?

	if [[ "$exit_rc" -eq 0 ]] && [[ "$output" == *"skipped"* ]] && [[ "$output" == *"aidevops email mailbox add"* ]]; then
		pass "$name"
	else
		fail "$name" "exit=$exit_rc output=$output"
	fi
	return 0
}

test_filter_config_validation_fails_closed() {
	local name="tick: collection config fails closed after filtered migration"
	local tmpdir="${TEST_TMPDIR}/filter-config-validation"
	mkdir -p "${tmpdir}/mock" "${tmpdir}/_config" "${tmpdir}/_knowledge/inbox"
	create_mock_imap_happy "${tmpdir}/mock" "9001"
	make_mailbox_config "${tmpdir}/_config/mailboxes.json" "validation-mb" "TEST_EMAIL_PASSWORD"
	printf '%s\n' '{invalid-json' >"${tmpdir}/_config/email-filters.json"

	local invalid_output invalid_rc=0
	invalid_output=$(cd "$tmpdir" && TEST_EMAIL_PASSWORD="testpass" \
		PYTHONPATH="${tmpdir}/mock" bash "$POLL_HELPER" tick 2>&1) || invalid_rc=$?
	local invalid_count
	invalid_count=$(find "${tmpdir}/_knowledge/inbox" -name "*.eml" 2>/dev/null | wc -l | tr -d ' ')

	printf '%s\n' '{"rules":[]}' >"${tmpdir}/_config/email-filters.json"
	local legacy_rc=0
	(cd "$tmpdir" && TEST_EMAIL_PASSWORD="testpass" \
		PYTHONPATH="${tmpdir}/mock" bash "$POLL_HELPER" tick >/dev/null 2>&1) || legacy_rc=$?
	local legacy_count
	legacy_count=$(find "${tmpdir}/_knowledge/inbox" -name "*.eml" 2>/dev/null | wc -l | tr -d ' ')

	printf '%s\n' '{"validation-mb/INBOX/imap/filter/case-rule/digest":{"last_uid_seen":1}}' >"${tmpdir}/_knowledge/.imap-state.json"
	rm -f "${tmpdir}/_knowledge/inbox/"*.eml "${tmpdir}/_config/email-filters.json"
	local missing_output missing_rc=0
	missing_output=$(cd "$tmpdir" && TEST_EMAIL_PASSWORD="testpass" \
		PYTHONPATH="${tmpdir}/mock" bash "$POLL_HELPER" tick 2>&1) || missing_rc=$?

	printf '%s\n' '{"rules":[]}' >"${tmpdir}/_config/email-filters.json"
	local downgrade_rc=0
	(cd "$tmpdir" && TEST_EMAIL_PASSWORD="testpass" \
		PYTHONPATH="${tmpdir}/mock" bash "$POLL_HELPER" tick >/dev/null 2>&1) || downgrade_rc=$?
	local post_migration_count
	post_migration_count=$(find "${tmpdir}/_knowledge/inbox" -name "*.eml" 2>/dev/null | wc -l | tr -d ' ')

	if [[ "$invalid_rc" -ne 0 && "$invalid_count" -eq 0 && "$invalid_output" == *"refusing unfiltered"* &&
		"$legacy_rc" -eq 0 && "$legacy_count" -eq 1 && "$missing_rc" -ne 0 &&
		"$missing_output" == *"refusing unfiltered"* && "$downgrade_rc" -ne 0 && "$post_migration_count" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "invalid_rc=$invalid_rc invalid_count=$invalid_count legacy_rc=$legacy_rc legacy_count=$legacy_count missing_rc=$missing_rc downgrade_rc=$downgrade_rc post_migration_count=$post_migration_count"
	fi
	return 0
}

test_filtered_helper_surfaces_poll_failure() {
	local name="filtered tick: provider failure is nonzero and preserves its checkpoint"
	local tmpdir="${TEST_TMPDIR}/filtered-provider-failure"
	mkdir -p "${tmpdir}/mock" "${tmpdir}/_config" "${tmpdir}/_knowledge/inbox"
	create_mock_imap_connfail "${tmpdir}/mock"
	make_mailbox_config "${tmpdir}/_config/mailboxes.json" "failure-mb" "TEST_EMAIL_PASSWORD"
	cat >"${tmpdir}/_config/email-filters.json" <<'EOF'
{"version":2,"rules":[{"id":"failure-rule","mailboxes":["failure-mb"],"match":{"all":[{"field":"subject","operator":"phrase","value":"case"}]}}]}
EOF
	printf '%s\n' '{"failure-mb/INBOX/imap/filter/failure-rule/prior":{"last_uid_seen":77}}' \
		>"${tmpdir}/_knowledge/.imap-state.json"

	local exit_rc=0
	(cd "$tmpdir" && TEST_EMAIL_PASSWORD="testpass" \
		PYTHONPATH="${tmpdir}/mock" bash "$POLL_HELPER" tick >/dev/null 2>&1) || exit_rc=$?
	local prior_cursor
	prior_cursor=$(jq -r '.["failure-mb/INBOX/imap/filter/failure-rule/prior"].last_uid_seen' \
		"${tmpdir}/_knowledge/.imap-state.json")
	local eml_count
	eml_count=$(find "${tmpdir}/_knowledge/inbox" -name "*.eml" 2>/dev/null | wc -l | tr -d ' ')

	if [[ "$exit_rc" -ne 0 && "$prior_cursor" -eq 77 && "$eml_count" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "exit=$exit_rc prior_cursor=$prior_cursor eml_count=$eml_count"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test: Python syntax check
# ---------------------------------------------------------------------------

test_python_syntax() {
	local name="python syntax: email_poll.py compiles"
	if python3 -m py_compile "$POLL_PY" 2>/dev/null; then
		pass "$name"
	else
		fail "$name" "py_compile failed"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 1: tick happy path
# ---------------------------------------------------------------------------

test_tick_happy_path() {
	local name="tick: fetches messages and writes .eml files"
	local tmpdir="${TEST_TMPDIR}/t1"
	mkdir -p "${tmpdir}/mock" "${tmpdir}/inbox"

	create_mock_imap_happy "${tmpdir}/mock" "1001"
	make_mailbox_config "${tmpdir}/mailboxes.json" "test-mb" "TEST_EMAIL_PASSWORD"

	local result exit_rc=0
	TEST_EMAIL_PASSWORD="testpass" PYTHONPATH="${tmpdir}/mock" \
		python3 "$POLL_PY" tick \
		--config "${tmpdir}/mailboxes.json" \
		--state "${tmpdir}/state.json" \
		--inbox "${tmpdir}/inbox" >"${tmpdir}/result.json" 2>&1 || exit_rc=$?

	local eml_count
	eml_count=$(find "${tmpdir}/inbox" -name "*.eml" 2>/dev/null | wc -l | tr -d ' ')

	if [[ "$eml_count" -ge 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected >=1 .eml, got $eml_count (exit $exit_rc, result: $(cat "${tmpdir}/result.json" 2>/dev/null))"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 2: missing credentials handling
# ---------------------------------------------------------------------------

test_missing_credentials() {
	local name="tick: missing credentials — error recorded, no crash"
	local tmpdir="${TEST_TMPDIR}/t2"
	mkdir -p "${tmpdir}/inbox"

	make_mailbox_config "${tmpdir}/mailboxes.json" "nocreds-mb" "AIDEVOPS_NONEXISTENT_ENV_XYZ999"
	unset AIDEVOPS_NONEXISTENT_ENV_XYZ999 2>/dev/null || true

	local exit_rc=0
	python3 "$POLL_PY" tick \
		--config "${tmpdir}/mailboxes.json" \
		--state "${tmpdir}/state.json" \
		--inbox "${tmpdir}/inbox" >"${tmpdir}/result.json" 2>&1 || exit_rc=$?

	local status
	status=$(python3 -c "
import json, sys
with open('${tmpdir}/result.json') as f:
    d = json.load(f)
r = d.get('results', [{}])[0]
print(r.get('status', ''))
" 2>/dev/null || echo "")

	if [[ "$status" == "credential_error" ]]; then
		pass "$name"
	else
		fail "$name" "expected credential_error, got: $status"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 3: IMAP connection failure — graceful
# ---------------------------------------------------------------------------

test_connection_failure() {
	local name="tick: IMAP connection failure — graceful error, no crash"
	local tmpdir="${TEST_TMPDIR}/t3"
	mkdir -p "${tmpdir}/mock" "${tmpdir}/inbox"

	create_mock_imap_connfail "${tmpdir}/mock"
	make_mailbox_config "${tmpdir}/mailboxes.json" "connfail-mb" "TEST_EMAIL_PASSWORD"

	local exit_rc=0
	TEST_EMAIL_PASSWORD="testpass" PYTHONPATH="${tmpdir}/mock" \
		python3 "$POLL_PY" tick \
		--config "${tmpdir}/mailboxes.json" \
		--state "${tmpdir}/state.json" \
		--inbox "${tmpdir}/inbox" >"${tmpdir}/result.json" 2>&1 || exit_rc=$?

	local status
	status=$(python3 -c "
import json
with open('${tmpdir}/result.json') as f:
    d = json.load(f)
r = d.get('results', [{}])[0]
print(r.get('status', ''))
" 2>/dev/null || echo "")

	if [[ "$status" == "connection_error" ]]; then
		pass "$name"
	else
		fail "$name" "expected connection_error, got: $status"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 4: state persistence across runs — deduplication
# ---------------------------------------------------------------------------

test_state_persistence() {
	local name="tick: subsequent runs fetch only new messages (no duplicates)"
	local tmpdir="${TEST_TMPDIR}/t4"
	mkdir -p "${tmpdir}/mock" "${tmpdir}/inbox"

	create_mock_imap_happy "${tmpdir}/mock" "1001"
	make_mailbox_config "${tmpdir}/mailboxes.json" "dup-mb" "TEST_EMAIL_PASSWORD"

	# First tick
	local exit_rc=0
	TEST_EMAIL_PASSWORD="testpass" PYTHONPATH="${tmpdir}/mock" \
		python3 "$POLL_PY" tick \
		--config "${tmpdir}/mailboxes.json" \
		--state "${tmpdir}/state.json" \
		--inbox "${tmpdir}/inbox" >/dev/null 2>&1 || exit_rc=$?

	local count_first
	count_first=$(find "${tmpdir}/inbox" -name "*.eml" 2>/dev/null | wc -l | tr -d ' ')

	# Second tick — fake still returns UID 1001, but state has last_uid_seen=1001
	exit_rc=0
	TEST_EMAIL_PASSWORD="testpass" PYTHONPATH="${tmpdir}/mock" \
		python3 "$POLL_PY" tick \
		--config "${tmpdir}/mailboxes.json" \
		--state "${tmpdir}/state.json" \
		--inbox "${tmpdir}/inbox" >/dev/null 2>&1 || exit_rc=$?

	local count_second
	count_second=$(find "${tmpdir}/inbox" -name "*.eml" 2>/dev/null | wc -l | tr -d ' ')

	if [[ "$count_first" -eq "$count_second" && "$count_first" -ge 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected equal counts (first=$count_first second=$count_second, both >= 1)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 5: backfill with date filter
# ---------------------------------------------------------------------------

test_backfill_date_filter() {
	local name="backfill: fetches messages from --since date"
	local tmpdir="${TEST_TMPDIR}/t5"
	mkdir -p "${tmpdir}/mock" "${tmpdir}/inbox"

	create_mock_imap_backfill "${tmpdir}/mock"
	make_mailbox_config "${tmpdir}/mailboxes.json" "backfill-mb" "TEST_EMAIL_PASSWORD"

	local exit_rc=0
	TEST_EMAIL_PASSWORD="testpass" PYTHONPATH="${tmpdir}/mock" \
		python3 "$POLL_PY" backfill \
		--config "${tmpdir}/mailboxes.json" \
		--state "${tmpdir}/state.json" \
		--inbox "${tmpdir}/inbox" \
		--mailbox-id "backfill-mb" \
		--since "2026-01-01" \
		--rate-limit 0 >"${tmpdir}/result.json" 2>&1 || exit_rc=$?

	local fetched_count
	fetched_count=$(python3 -c "
import json
with open('${tmpdir}/result.json') as f:
    d = json.load(f)
print(d.get('fetched_count', 0))
" 2>/dev/null || echo "0")

	if [[ "$fetched_count" -ge 1 ]]; then
		pass "$name"
	else
		fail "$name" "expected fetched_count >= 1, got: $fetched_count"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 6: dry-run test mode — no files written
# ---------------------------------------------------------------------------

test_dry_run() {
	local name="test mode: dry-run — no .eml files written, no state committed"
	local tmpdir="${TEST_TMPDIR}/t6"
	mkdir -p "${tmpdir}/mock" "${tmpdir}/inbox"

	create_mock_imap_happy "${tmpdir}/mock" "3001"
	make_mailbox_config "${tmpdir}/mailboxes.json" "dryrun-mb" "TEST_EMAIL_PASSWORD"

	local exit_rc=0
	TEST_EMAIL_PASSWORD="testpass" PYTHONPATH="${tmpdir}/mock" \
		python3 "$POLL_PY" test \
		--config "${tmpdir}/mailboxes.json" \
		--mailbox-id "dryrun-mb" >/dev/null 2>&1 || exit_rc=$?

	local eml_count state_exists=0
	eml_count=$(find "${tmpdir}/inbox" -name "*.eml" 2>/dev/null | wc -l | tr -d ' ')
	[[ -f "${tmpdir}/.imap-state.json" ]] && state_exists=1

	if [[ "$eml_count" -eq 0 && "$state_exists" -eq 0 ]]; then
		pass "$name"
	else
		fail "$name" "expected no .eml (got $eml_count) and no state file (exists: $state_exists)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test 7: list command
# ---------------------------------------------------------------------------

test_list_command() {
	local name="list: shows configured mailboxes"
	local tmpdir="${TEST_TMPDIR}/t7"
	mkdir -p "$tmpdir"

	make_mailbox_config "${tmpdir}/mailboxes.json" "list-mb" "gopass:test/path"

	local exit_rc=0
	python3 "$POLL_PY" list \
		--config "${tmpdir}/mailboxes.json" >"${tmpdir}/result.json" 2>&1 || exit_rc=$?

	local found_id
	found_id=$(python3 -c "
import json
with open('${tmpdir}/result.json') as f:
    d = json.load(f)
ids = [m['id'] for m in d.get('mailboxes', [])]
print(ids[0] if ids else '')
" 2>/dev/null || echo "")

	if [[ "$found_id" == "list-mb" ]]; then
		pass "$name"
	else
		fail "$name" "expected id 'list-mb', got '$found_id'"
	fi
	return 0
}

test_filtered_collection() {
	local name="filtered tick: persists matches only with content-free lineage state"
	local tmpdir="${TEST_TMPDIR}/filtered"
	mkdir -p "${tmpdir}/mock" "${tmpdir}/inbox"
	create_mock_imap_filtered "${tmpdir}/mock"
	make_mailbox_config "${tmpdir}/mailboxes.json" "filtered-mb" "TEST_EMAIL_PASSWORD"
	jq '.mailboxes[0].folders = ["INBOX", "Archive"]' "${tmpdir}/mailboxes.json" \
		>"${tmpdir}/mailboxes.next.json"
	mv "${tmpdir}/mailboxes.next.json" "${tmpdir}/mailboxes.json"
	cat >"${tmpdir}/filters.json" <<'EOF'
{
  "version": 2,
  "rules": [
    {
      "id": "case-rule",
      "mailboxes": ["filtered-mb"],
      "folders": ["INBOX"],
      "backfill": {"limit": 25},
      "match": {"all": [
        {"field": "from", "operator": "exact_domain", "value": "example.com"},
        {"field": "direction", "operator": "equals", "value": "received"},
        {"field": "subject", "operator": "reference", "value": "CASE-123"}
      ]}
    },
    {
      "id": "overlap-rule",
      "mailboxes": ["filtered-mb"],
      "folders": ["INBOX"],
      "backfill": {"limit": 25},
      "match": {"all": [
        {"field": "from", "operator": "exact_address", "value": "counsel@example.com"},
        {"field": "subject", "operator": "reference", "value": "CASE-123"}
      ]}
    }
  ]
}
EOF

	local exit_rc=0
	TEST_EMAIL_PASSWORD="testpass" PYTHONPATH="${tmpdir}/mock" \
		python3 "$POLL_PY" tick \
		--config "${tmpdir}/mailboxes.json" \
		--state "${tmpdir}/state.json" \
		--inbox "${tmpdir}/inbox" \
		--filters "${tmpdir}/filters.json" >"${tmpdir}/result.json" 2>&1 || exit_rc=$?

	local eml_count state_safe=0 result_safe=0 receipt_safe=0 receipt_path=""
	eml_count=$(find "${tmpdir}/inbox" -name "*.eml" 2>/dev/null | wc -l | tr -d ' ')
	local candidate
	for candidate in "${tmpdir}/inbox/"*.eml.collection.json; do
		[[ -f "$candidate" ]] && receipt_path="$candidate"
	done
	if [[ -n "$receipt_path" ]] &&
		jq -e '.transport == "imap" and .mailbox_id == "filtered-mb" and .folder == "INBOX" and (.rules | length) == 2' "$receipt_path" >/dev/null &&
		! grep -q 'example.com\|CASE-123\|Private' "$receipt_path"; then
		receipt_safe=1
	fi
	if [[ -f "${tmpdir}/state.json" ]] && grep -q '/imap/filter/case-rule/' "${tmpdir}/state.json" &&
		grep -q '/imap/filter/overlap-rule/' "${tmpdir}/state.json" &&
		! grep -q 'example.com\|CASE-123\|Private' "${tmpdir}/state.json"; then
		state_safe=1
	fi
	if [[ -f "${tmpdir}/result.json" ]] && grep -q '"scanned": 4' "${tmpdir}/result.json" &&
		grep -q '"fetched_count": 1' "${tmpdir}/result.json"; then
		result_safe=1
	fi

	jq '.rules[1].match.all[1].value = "CASE-999"' "${tmpdir}/filters.json" >"${tmpdir}/filters.next.json"
	mv "${tmpdir}/filters.next.json" "${tmpdir}/filters.json"
	TEST_EMAIL_PASSWORD="testpass" PYTHONPATH="${tmpdir}/mock" \
		python3 "$POLL_PY" tick \
		--config "${tmpdir}/mailboxes.json" \
		--state "${tmpdir}/state.json" \
		--inbox "${tmpdir}/inbox" \
		--filters "${tmpdir}/filters.json" >"${tmpdir}/result-second.json" 2>&1 || exit_rc=$?
	jq '(.rules[].enabled) = false' "${tmpdir}/filters.json" >"${tmpdir}/filters.disabled.json"
	mv "${tmpdir}/filters.disabled.json" "${tmpdir}/filters.json"
	TEST_EMAIL_PASSWORD="testpass" PYTHONPATH="${tmpdir}/mock" \
		python3 "$POLL_PY" tick \
		--config "${tmpdir}/mailboxes.json" \
		--state "${tmpdir}/state.json" \
		--inbox "${tmpdir}/inbox" \
		--filters "${tmpdir}/filters.json" >"${tmpdir}/result-disabled.json" 2>&1 || exit_rc=$?
	local lineage_count
	lineage_count=$(jq '[keys[] | select(contains("/filter/"))] | length' "${tmpdir}/state.json")
	local final_eml_count
	final_eml_count=$(find "${tmpdir}/inbox" -name "*.eml" 2>/dev/null | wc -l | tr -d ' ')
	if [[ "$exit_rc" -eq 0 && "$eml_count" -eq 1 && "$state_safe" -eq 1 && "$result_safe" -eq 1 && "$receipt_safe" -eq 1 ]] &&
		[[ "$lineage_count" -eq 3 ]] && grep -q '"fetched_count": 0' "${tmpdir}/result-second.json" &&
		grep -q '"fetched_count": 0' "${tmpdir}/result-disabled.json" && [[ "$final_eml_count" -eq 1 ]] &&
		grep -q 'Private matching content' "${tmpdir}/inbox/"*.eml &&
		! grep -q 'Private unmatched content' "${tmpdir}/inbox/"*.eml &&
		[[ ! -e "${tmpdir}/inbox/email-filtered-mb-Archive-4001.eml" ]]; then
		pass "$name"
	else
		fail "$name" "exit=$exit_rc eml=$eml_count state_safe=$state_safe result_safe=$result_safe receipt_safe=$receipt_safe lineages=$lineage_count"
	fi
	return 0
}

test_per_rule_candidate_windows() {
	local name="filtered tick: preserves independent rule limits, dates, and cursors"
	if python3 - "$SCRIPTS_DIR" <<'PYEOF'; then
import sys
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(sys.argv[1])))
from email_poll import (  # noqa: E402
    BackfillConfig,
    BackfillContext,
    RuleScanContext,
    _backfill_messages,
    _backfill_state_key,
    _filter_state_key,
    _rule_candidate_uids,
    _scan_poll_message,
)


class FakeConnection:
    def __init__(self):
        self.criteria = []

    def select(self, _folder, readonly=False):
        assert readonly is True
        return "OK", [b"1000"]

    def uid(self, command, *_args):
        assert command == "SEARCH"
        criteria = str(_args[-1])
        self.criteria.append(criteria)
        start = 101 if "UID 101:*" in criteria else 1
        return "OK", [" ".join(str(uid) for uid in range(start, 1001)).encode()]


conn = FakeConnection()
entries = {
    "existing": ({"id": "existing", "backfill": {"limit": 500}}, 100),
    "new": ({"id": "new", "backfill": {"limit": 25, "since": "2026-07-01"}}, 0),
}
selected, evidence = _rule_candidate_uids(conn, "INBOX", entries)
assert selected["existing"] == set(range(101, 601))
assert selected["new"] == set(range(976, 1001))
assert evidence["existing"] == {
    "candidate_total": 900,
    "has_more": True,
    "backfill_truncated": False,
    "mode": "incremental",
}
assert evidence["new"] == {
    "candidate_total": 1000,
    "has_more": True,
    "backfill_truncated": True,
    "mode": "initial",
}
assert any("SINCE 01-Jul-2026" in item for item in conn.criteria)
rule = entries["new"][0]
assert _backfill_state_key("mb", "INBOX", rule, "2026-07-01") != _backfill_state_key(
    "mb", "INBOX", rule, "2026-01-01"
)
backfill_context = BackfillContext(
    mailbox_id="mb",
    folder="INBOX",
    state={},
    config=BackfillConfig(inbox_dir="unused", since_date="2026-01-01"),
    active_rules=[rule],
    account_identities=(),
    filtering_enabled=True,
)
with patch("email_poll._uid_fetch_selected", return_value=[]):
    assert _backfill_messages(conn, backfill_context) == []
backfill_key = _backfill_state_key("mb", "INBOX", rule, "2026-07-01")
assert backfill_context.candidate_uids[backfill_key] == set(range(976, 1001))
assert backfill_context.candidate_evidence[backfill_key]["candidate_total"] == 1000

coverage_rule = {"id": "coverage", "match": {"all": [
    {"field": "bcc", "operator": "exact_address", "value": "hidden@example.test"}
]}}
coverage_key = _filter_state_key("mb", "INBOX", coverage_rule)
assert "/imap/filter/" in coverage_key
scan_context = RuleScanContext(
    rule_keys={coverage_key: coverage_rule},
    rule_cursors={coverage_key: 0},
    pending_states={coverage_key: {
        "last_uid_seen": 0,
        "scanned": 1,
        "matched": 0,
        "coverage_gaps": ["body"],
    }},
    account_identities=(),
    filtering_enabled=True,
    candidate_uids={coverage_key: {1}},
)
folder_result = {
    "scanned": 0,
    "matched_rules": {},
    "coverage_gaps": [],
    "last_polled_at": "2026-07-31T00:00:00Z",
}
assert not _scan_poll_message(
    1,
    b"From: sender@example.test\r\nSubject: no bcc\r\n\r\nbody",
    scan_context,
    folder_result,
)
assert scan_context.pending_states[coverage_key]["coverage_gaps"] == ["bcc", "body"]
PYEOF
		pass "$name"
	else
		fail "$name" "candidate planning assertions failed"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Test: shellcheck
# ---------------------------------------------------------------------------

test_shellcheck() {
	local name="email-poll-helper.sh: shellcheck zero violations"
	if command -v shellcheck &>/dev/null && shellcheck "$POLL_HELPER" 2>/dev/null; then
		pass "$name"
	elif ! command -v shellcheck &>/dev/null; then
		pass "$name (shellcheck not installed, skipped)"
	else
		fail "$name" "shellcheck reported violations"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

main() {
	setup

	test_python_syntax
	test_tick_missing_config_skips
	test_filter_config_validation_fails_closed
	test_filtered_helper_surfaces_poll_failure
	test_tick_happy_path
	test_missing_credentials
	test_connection_failure
	test_state_persistence
	test_backfill_date_filter
	test_dry_run
	test_list_command
	test_filtered_collection
	test_per_rule_candidate_windows
	test_shellcheck

	teardown

	echo ""
	echo "Results: $PASS passed, $FAIL failed"
	if [[ "$FAIL" -gt 0 ]]; then
		return 1
	fi
	return 0
}

main "$@"
