#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-email-ingest.sh — Tests for email-ingest-helper.sh and email_parse.py
#
# Usage: bash .agents/tests/test-email-ingest.sh
#
# Tests cover: plaintext emails, HTML-only, multipart with attachments,
# tracking pixel removal, Unicode handling, parent-child source linking,
# meta.json field validation, and knowledge-helper.sh routing.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../scripts/email-ingest-helper.sh"
KNOWLEDGE_HELPER="${SCRIPT_DIR}/../scripts/knowledge-helper.sh"
EMAIL_PARSER="${SCRIPT_DIR}/../scripts/email_parse.py"
FIXTURES="${SCRIPT_DIR}/fixtures/sample-emails"

# ---------------------------------------------------------------------------
# Test framework (matches test-knowledge-cli.sh pattern)
# ---------------------------------------------------------------------------

_PASS=0
_FAIL=0

_pass() {
	local name="$1"
	printf "[PASS] %s\n" "$name"
	_PASS=$((_PASS + 1))
	return 0
}
_fail() {
	local name="$1" msg="$2"
	printf "[FAIL] %s — %s\n" "$name" "$msg"
	_FAIL=$((_FAIL + 1))
	return 0
}

assert_eq() {
	local name="$1" got="$2" want="$3"
	if [[ "$got" == "$want" ]]; then
		_pass "$name"
	else
		_fail "$name" "got='$got' want='$want'"
	fi
	return 0
}

assert_contains() {
	local name="$1" haystack="$2" needle="$3"
	if echo "$haystack" | grep -q "$needle" 2>/dev/null; then
		_pass "$name"
	else
		_fail "$name" "string does not contain '$needle'"
	fi
	return 0
}

assert_not_contains() {
	local name="$1" haystack="$2" needle="$3"
	if echo "$haystack" | grep -q "$needle" 2>/dev/null; then
		_fail "$name" "string unexpectedly contains '$needle'"
	else
		_pass "$name"
	fi
	return 0
}

assert_file_exists() {
	local name="$1" path="$2"
	if [[ -e "$path" ]]; then
		_pass "$name"
	else
		_fail "$name" "path not found: $path"
	fi
	return 0
}

assert_json_field() {
	local name="$1" json_file="$2" field="$3" want="$4"
	local got
	got=$(jq -r "$field" "$json_file" 2>/dev/null || echo "__jq_error__")
	if [[ "$got" == "$want" ]]; then
		_pass "$name"
	else
		_fail "$name" "meta.json $field: got='$got' want='$want'"
	fi
	return 0
}

assert_json_field_not_empty() {
	local name="$1" json_file="$2" field="$3"
	local got
	got=$(jq -r "$field" "$json_file" 2>/dev/null || echo "")
	if [[ -n "$got" && "$got" != "null" && "$got" != "" ]]; then
		_pass "$name"
	else
		_fail "$name" "meta.json $field is empty or null"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Setup: isolated tmp directory with mocked repos.json
# ---------------------------------------------------------------------------

TMP_DIR=$(mktemp -d)
REPO_PATH="${TMP_DIR}/test-repo"
mkdir -p "$REPO_PATH"

MOCK_REPOS_JSON="${TMP_DIR}/repos.json"
cat >"$MOCK_REPOS_JSON" <<EOF
{
  "initialized_repos": [
    {
      "path": "${REPO_PATH}",
      "slug": "test/repo",
      "knowledge": "repo",
      "platform": "local"
    }
  ],
  "git_parent_dirs": []
}
EOF

export REPOS_FILE="$MOCK_REPOS_JSON"
export PERSONAL_PLANE_BASE="${TMP_DIR}/personal-plane"
export AIDEVOPS_VAULT_DIR="${TMP_DIR}/vault-disabled"

# Provision the knowledge tree
bash "$KNOWLEDGE_HELPER" provision "$REPO_PATH" >/dev/null 2>&1

KNOWLEDGE_ROOT="${REPO_PATH}/_knowledge"
SOURCES="${KNOWLEDGE_ROOT}/sources"

cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

# Find first source dir matching a prefix (avoids ls|grep per SC2010)
_find_source() {
	local prefix="$1"
	local dir
	for dir in "${SOURCES}/${prefix}"*; do
		[[ -d "$dir" ]] && basename "$dir" && return 0
	done
	echo ""
	return 0
}

# Find last source dir matching a prefix
_find_source_last() {
	local prefix="$1"
	local last=""
	local dir
	for dir in "${SOURCES}/${prefix}"*; do
		[[ -d "$dir" ]] && last="$(basename "$dir")"
	done
	echo "$last"
	return 0
}

_write_collection_sidecar() {
	local eml_path="$1"
	local transport="$2"
	local message_key="$3"
	python3 - "$SCRIPT_DIR/../scripts" "$eml_path" "$transport" "$message_key" <<'PYEOF'
import sys

sys.path.insert(0, sys.argv[1])
from email_collection_receipts import ReceiptContext, write_collection_receipt  # noqa: E402

rules = [{
    "id": "case-rule",
    "collection": True,
    "match": {"all": [{
        "field": "subject", "operator": "reference", "value": "PRIVATE-123",
    }]},
}]
if sys.argv[3] == "imap":
    rules.append({
        "id": "overlap-rule",
        "collection": True,
        "match": {"all": [{
            "field": "from", "operator": "exact_address", "value": "private@example.test",
        }]},
    })
write_collection_receipt(
    sys.argv[2],
    ReceiptContext(sys.argv[3], "work", "INBOX", sys.argv[4]),
    rules,
)
PYEOF
	return 0
}

# ---------------------------------------------------------------------------
# Section 1: Python parser tests (email_parse.py)
# ---------------------------------------------------------------------------

echo ""
echo "=== Section 1: email_parse.py parser tests ==="
echo ""

# Test 1: Parse plaintext email
PARSE_OUT_DIR="${TMP_DIR}/parse-plaintext"
mkdir -p "$PARSE_OUT_DIR"
PARSE_JSON=$(python3 "$EMAIL_PARSER" "$FIXTURES/plaintext.eml" --output-dir "$PARSE_OUT_DIR" 2>/dev/null)

assert_contains "parse:plaintext: from field" "$PARSE_JSON" "sender@example.com"
assert_contains "parse:plaintext: to field" "$PARSE_JSON" "recipient@example.com"
assert_contains "parse:plaintext: subject" "$PARSE_JSON" "Plain text test email"
assert_contains "parse:plaintext: message_id" "$PARSE_JSON" "test-001@example.com"

body_text_path=$(echo "$PARSE_JSON" | jq -r '.body_text_path')
assert_file_exists "parse:plaintext: body_text_path exists" "$body_text_path"

body_html_path=$(echo "$PARSE_JSON" | jq -r '.body_html_path')
assert_eq "parse:plaintext: no body_html_path" "$body_html_path" ""

att_count=$(echo "$PARSE_JSON" | jq '.attachments | length')
assert_eq "parse:plaintext: zero attachments" "$att_count" "0"

# Test 2: Parse HTML-only email
PARSE_HTML_DIR="${TMP_DIR}/parse-html"
mkdir -p "$PARSE_HTML_DIR"
PARSE_HTML_JSON=$(python3 "$EMAIL_PARSER" "$FIXTURES/html-only.eml" --output-dir "$PARSE_HTML_DIR" 2>/dev/null)

html_body_path=$(echo "$PARSE_HTML_JSON" | jq -r '.body_html_path')
assert_file_exists "parse:html-only: body_html_path exists" "$html_body_path"

# HTML-only should also generate a text body via html_to_text
text_body_path=$(echo "$PARSE_HTML_JSON" | jq -r '.body_text_path')
assert_file_exists "parse:html-only: body_text_path generated from HTML" "$text_body_path"

# Test 3: Parse email with attachments
PARSE_ATT_DIR="${TMP_DIR}/parse-att"
mkdir -p "$PARSE_ATT_DIR"
PARSE_ATT_JSON=$(python3 "$EMAIL_PARSER" "$FIXTURES/with-attachment.eml" --output-dir "$PARSE_ATT_DIR" 2>/dev/null)

att_count=$(echo "$PARSE_ATT_JSON" | jq '.attachments | length')
assert_eq "parse:attachment: two attachments" "$att_count" "2"

att0_filename=$(echo "$PARSE_ATT_JSON" | jq -r '.attachments[0].filename')
assert_eq "parse:attachment: first filename" "$att0_filename" "report.txt"

att1_filename=$(echo "$PARSE_ATT_JSON" | jq -r '.attachments[1].filename')
assert_eq "parse:attachment: second filename" "$att1_filename" "data.csv"

# Check CC header
assert_contains "parse:attachment: cc field" "$PARSE_ATT_JSON" "manager@example.com"
# Check In-Reply-To
assert_contains "parse:attachment: in_reply_to" "$PARSE_ATT_JSON" "original-thread@example.com"

# Test 4: Parse Unicode/quoted-printable email
PARSE_UNI_DIR="${TMP_DIR}/parse-unicode"
mkdir -p "$PARSE_UNI_DIR"
PARSE_UNI_JSON=$(python3 "$EMAIL_PARSER" "$FIXTURES/unicode-subject.eml" --output-dir "$PARSE_UNI_DIR" 2>/dev/null)

# Subject should be decoded from base64 encoded UTF-8
uni_subject=$(echo "$PARSE_UNI_JSON" | jq -r '.subject')
assert_contains "parse:unicode: subject has diacritics" "$uni_subject" "diacritics"

# Body should contain decoded quoted-printable chars
uni_text_path=$(echo "$PARSE_UNI_JSON" | jq -r '.body_text_path')
if [[ -n "$uni_text_path" && -f "$uni_text_path" ]]; then
	uni_body=$(cat "$uni_text_path")
	assert_contains "parse:unicode: body has decoded chars" "$uni_body" "diacritics"
	_pass "parse:unicode: body file readable"
else
	_fail "parse:unicode: body file not created" "path=$uni_text_path"
fi

# ---------------------------------------------------------------------------
# Section 2: email-ingest-helper.sh integration tests
# ---------------------------------------------------------------------------

echo ""
echo "=== Section 2: email-ingest-helper.sh ingestion tests ==="
echo ""

# Test 5: Ingest plaintext email
ingest_out=$(bash "$HELPER" ingest "$FIXTURES/plaintext.eml" --repo-path "$REPO_PATH" 2>&1)
assert_contains "ingest:plaintext: success message" "$ingest_out" "Ingested email"

# Find the created source dir
SRC_PLAIN=$(_find_source "plain")
if [[ -n "$SRC_PLAIN" ]]; then
	SRC_PLAIN_DIR="${SOURCES}/${SRC_PLAIN}"
	assert_file_exists "ingest:plaintext: meta.json" "${SRC_PLAIN_DIR}/meta.json"
	assert_file_exists "ingest:plaintext: text.txt" "${SRC_PLAIN_DIR}/text.txt"
	assert_json_field "ingest:plaintext: kind=email" "${SRC_PLAIN_DIR}/meta.json" '.kind' "email"
	assert_json_field "ingest:plaintext: from" "${SRC_PLAIN_DIR}/meta.json" '.from' "sender@example.com"
	assert_json_field "ingest:plaintext: to" "${SRC_PLAIN_DIR}/meta.json" '.to' "recipient@example.com"
	assert_json_field_not_empty "ingest:plaintext: message_id set" "${SRC_PLAIN_DIR}/meta.json" '.message_id'
	assert_json_field_not_empty "ingest:plaintext: sha256 set" "${SRC_PLAIN_DIR}/meta.json" '.sha256'
	assert_json_field_not_empty "ingest:plaintext: body_text_sha set" "${SRC_PLAIN_DIR}/meta.json" '.body_text_sha'
else
	_fail "ingest:plaintext: source dir not created" "no dir matching 'plain' in $SOURCES"
fi

# Test 6: Ingest HTML-only email — tracking pixel stripped
ingest_html_out=$(bash "$HELPER" ingest "$FIXTURES/html-only.eml" --repo-path "$REPO_PATH" 2>&1)
assert_contains "ingest:html-only: success" "$ingest_html_out" "Ingested email"

SRC_HTML=$(_find_source "html")
if [[ -n "$SRC_HTML" ]]; then
	SRC_HTML_DIR="${SOURCES}/${SRC_HTML}"
	assert_file_exists "ingest:html-only: body.html" "${SRC_HTML_DIR}/body.html"
	assert_file_exists "ingest:html-only: text.txt generated" "${SRC_HTML_DIR}/text.txt"

	# Verify tracking pixel was stripped
	stored_html=$(cat "${SRC_HTML_DIR}/body.html")
	assert_not_contains "ingest:html-only: tracker pixel stripped" "$stored_html" "tracker.example.com/pixel.gif"
	assert_contains "ingest:html-only: tracker comment present" "$stored_html" "tracker stripped"

	# Verify UTM parameters stripped
	assert_not_contains "ingest:html-only: UTM params stripped" "$stored_html" "utm_source"

	assert_json_field "ingest:html-only: kind=email" "${SRC_HTML_DIR}/meta.json" '.kind' "email"
else
	_fail "ingest:html-only: source dir not created" "no dir matching 'html' in $SOURCES"
fi

# Test 7: Ingest email with attachments — parent + child sources
ingest_att_out=$(bash "$HELPER" ingest "$FIXTURES/with-attachment.eml" --repo-path "$REPO_PATH" 2>&1)
assert_contains "ingest:attachment: success" "$ingest_att_out" "Ingested email"

SRC_ATT=$(_find_source "with-attachment")
if [[ -n "$SRC_ATT" ]]; then
	SRC_ATT_DIR="${SOURCES}/${SRC_ATT}"
	assert_file_exists "ingest:attachment: parent meta" "${SRC_ATT_DIR}/meta.json"

	# Check parent meta has attachments array
	att_child_count=$(jq '.attachments | length' "${SRC_ATT_DIR}/meta.json" 2>/dev/null || echo "0")
	assert_eq "ingest:attachment: 2 child refs in parent" "$att_child_count" "2"

	# Verify child sources exist
	child0_id=$(jq -r '.attachments[0].source_id' "${SRC_ATT_DIR}/meta.json" 2>/dev/null || echo "")
	if [[ -n "$child0_id" ]]; then
		CHILD0_DIR="${SOURCES}/${child0_id}"
		assert_file_exists "ingest:attachment: child0 dir" "$CHILD0_DIR"
		assert_file_exists "ingest:attachment: child0 meta" "${CHILD0_DIR}/meta.json"
		assert_json_field "ingest:attachment: child0 kind=attachment" "${CHILD0_DIR}/meta.json" '.kind' "attachment"
		assert_json_field "ingest:attachment: child0 parent_source" "${CHILD0_DIR}/meta.json" '.parent_source' "$SRC_ATT"
		assert_json_field_not_empty "ingest:attachment: child0 filename" "${CHILD0_DIR}/meta.json" '.attachment_filename'
	else
		_fail "ingest:attachment: child0 source_id not found" "meta attachments empty"
	fi

	child1_id=$(jq -r '.attachments[1].source_id' "${SRC_ATT_DIR}/meta.json" 2>/dev/null || echo "")
	if [[ -n "$child1_id" ]]; then
		CHILD1_DIR="${SOURCES}/${child1_id}"
		assert_file_exists "ingest:attachment: child1 dir" "$CHILD1_DIR"
		assert_json_field "ingest:attachment: child1 parent_source" "${CHILD1_DIR}/meta.json" '.parent_source' "$SRC_ATT"
	else
		_fail "ingest:attachment: child1 source_id not found" "missing"
	fi

	# Check email threading fields
	assert_json_field_not_empty "ingest:attachment: in_reply_to" "${SRC_ATT_DIR}/meta.json" '.in_reply_to'
	assert_json_field_not_empty "ingest:attachment: references" "${SRC_ATT_DIR}/meta.json" '.references'
	assert_json_field "ingest:attachment: cc" "${SRC_ATT_DIR}/meta.json" '.cc' "manager@example.com"
else
	_fail "ingest:attachment: source dir not created" "no dir matching 'with-attachment' in $SOURCES"
fi

# Test 8: knowledge-helper.sh add routes .eml to email handler
ingest_via_add=$(bash "$KNOWLEDGE_HELPER" add "$FIXTURES/plaintext.eml" --repo-path "$REPO_PATH" 2>&1)
assert_contains "routing:add: routed to email handler" "$ingest_via_add" "Ingested email"

# ---------------------------------------------------------------------------
# Section 3: Sanitisation tests
# ---------------------------------------------------------------------------

echo ""
echo "=== Section 3: Sanitisation tests ==="
echo ""

# Test 9: Sanitisation idempotency and canonical message deduplication
if [[ -n "${SRC_HTML:-}" ]]; then
	first_html=$(cat "${SOURCES}/${SRC_HTML}/body.html")
	# Re-ingest the same message; canonical identity must be reused.
	bash "$HELPER" ingest "$FIXTURES/html-only.eml" --repo-path "$REPO_PATH" >/dev/null 2>&1
	SRC_HTML2=$(_find_source_last "html")
	if [[ -n "$SRC_HTML2" && "$SRC_HTML2" == "$SRC_HTML" ]]; then
		second_html=$(cat "${SOURCES}/${SRC_HTML2}/body.html")
		assert_eq "sanitisation:idempotent: same canonical output" "$first_html" "$second_html"
		_pass "ingest:duplicate: reuses canonical email source"
	else
		_fail "ingest:duplicate: reuses canonical email source" "first=$SRC_HTML second=$SRC_HTML2"
	fi
else
	_pass "sanitisation:idempotent: skipped (no html source)"
fi

# Test 10: Verify meta.json version field
if [[ -n "${SRC_PLAIN:-}" ]]; then
	assert_json_field "meta:version: version=1" "${SOURCES}/${SRC_PLAIN}/meta.json" '.version' "1"
fi

# Test 11: Duplicate transports merge collection provenance into one canonical source
if [[ -n "${SRC_PLAIN:-}" ]]; then
	COLLECTED_IMAP="${TMP_DIR}/collected-imap.eml"
	cp "$FIXTURES/plaintext.eml" "$COLLECTED_IMAP"
	_write_collection_sidecar "$COLLECTED_IMAP" "imap" "uid-101"
	imap_ingest=$(bash "$HELPER" ingest "$COLLECTED_IMAP" --repo-path "$REPO_PATH" 2>&1)
	assert_contains "ingest:collection: pre-existing canonical reused" "$imap_ingest" "existing canonical"
	assert_json_field "ingest:collection: first transport reference merged" \
		"${SOURCES}/${SRC_PLAIN}/meta.json" '.collection_refs | length' "1"
	assert_json_field "ingest:collection: overlapping rules preserved" \
		"${SOURCES}/${SRC_PLAIN}/meta.json" '.collection_refs[0].rules | length' "2"

	COLLECTED_JMAP="${TMP_DIR}/collected-jmap.eml"
	cp "$FIXTURES/plaintext.eml" "$COLLECTED_JMAP"
	_write_collection_sidecar "$COLLECTED_JMAP" "jmap" "email-101"
	jmap_ingest=$(bash "$HELPER" ingest "$COLLECTED_JMAP" --repo-path "$REPO_PATH" 2>&1)
	assert_contains "ingest:collection: second duplicate reused" "$jmap_ingest" "existing canonical"
	assert_json_field "ingest:collection: multiple transport references merged" \
		"${SOURCES}/${SRC_PLAIN}/meta.json" '.collection_refs | length' "2"
	collection_refs=$(jq -c '.collection_refs' "${SOURCES}/${SRC_PLAIN}/meta.json")
	assert_not_contains "ingest:collection: references redact filter literals" \
		"$collection_refs" "PRIVATE-123"

	MALFORMED_EML="${TMP_DIR}/malformed-receipt.eml"
	cp "$FIXTURES/plaintext.eml" "$MALFORMED_EML"
	cat >"${MALFORMED_EML}.collection.json" <<'EOF'
{"version":1,"transport":"imap","mailbox_id":"work","folder":"INBOX","message_key":"uid-102","rules":[{"id":"case-rule","digest":"0000000000000000","literal":"PRIVATE-123"}]}
EOF
	if bash "$HELPER" ingest "$MALFORMED_EML" --repo-path "$REPO_PATH" >/dev/null 2>&1; then
		_fail "ingest:collection: malformed receipt fails closed" "ingestion unexpectedly succeeded"
	else
		_pass "ingest:collection: malformed receipt fails closed"
	fi
	assert_json_field "ingest:collection: malformed receipt leaves canonical references unchanged" \
		"${SOURCES}/${SRC_PLAIN}/meta.json" '.collection_refs | length' "2"
else
	_fail "ingest:collection: provenance fixtures" "plaintext canonical source unavailable"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------

echo ""
echo "========================="
echo "Results: ${_PASS} passed, ${_FAIL} failed"
echo "========================="

if [[ "$_FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
