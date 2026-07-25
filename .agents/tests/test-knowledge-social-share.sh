#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-share.sh — Encrypted social workspace isolation tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
SOCIAL_HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
TMP_DIR=$(mktemp -d)
OWNER_BASE="${TMP_DIR}/owner"
MEMBER_BASE="${TMP_DIR}/member"
OWNER_TEAM="${OWNER_BASE}/team-corpus"
MEMBER_TEAM="${MEMBER_BASE}/team-corpus"
ARCHIVE="${TMP_DIR}/archive.json"
BUNDLE="${TMP_DIR}/bundle.json"
PASS=0
FAIL=0

cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

assert_pass() {
	local description="$1"
	shift
	if "$@"; then
		PASS=$((PASS + 1))
		printf '  PASS  %s\n' "$description"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL  %s\n' "$description"
	fi
	return 0
}

assert_fail() {
	local description="$1"
	shift
	if "$@"; then
		FAIL=$((FAIL + 1))
		printf '  FAIL  %s (unexpected success)\n' "$description"
	else
		PASS=$((PASS + 1))
		printf '  PASS  %s\n' "$description"
	fi
	return 0
}

contains_no_plaintext() {
	local bundle="$1"
	if rg -q 'workspace secret evidence|team-corpus|/owner|/member' "$bundle"; then
		return 1
	fi
	return 0
}

query_has_result() {
	local base="$1"
	local result
	result=$("$SOCIAL_HELPER" query --base "$base" --alias workspace:team --query secret)
	python3 -c 'import json,sys; assert len(json.loads(sys.argv[1])["results"]) == 1' "$result"
	return 0
}

printf 'Encrypted social workspace tests\n'
for base in "$OWNER_BASE" "$MEMBER_BASE"; do
	mkdir -p "$base/_knowledge"
	chmod 0700 "$base" "$base/_knowledge"
	"$CORPUS_HELPER" provision --base "$base" >/dev/null
done

"$SOCIAL_HELPER" share-keygen --base "$OWNER_BASE" \
	--private-key "$OWNER_BASE/owner-private.json" --public-key "$OWNER_BASE/owner-public.json" >/dev/null
"$SOCIAL_HELPER" share-keygen --base "$MEMBER_BASE" \
	--private-key "$MEMBER_BASE/member-private.json" --public-key "$MEMBER_BASE/member-public.json" >/dev/null

mkdir -p "$OWNER_TEAM" "$MEMBER_TEAM"
chmod 0700 "$OWNER_TEAM" "$MEMBER_TEAM"
python3 - "$OWNER_BASE" "$OWNER_TEAM" <<'PY'
import json
import sqlite3
import sys
from pathlib import Path

base = Path(sys.argv[1])
root = Path(sys.argv[2])
principal = json.loads((base / "_config/principal.json").read_text())["principal_id"]
db = sqlite3.connect(base / "catalog.db")
db.execute("INSERT INTO workspaces VALUES('wsp_team','workspace','active')")
db.execute("INSERT INTO workspace_memberships VALUES('wsp_team',?,'owner','active')", (principal,))
db.execute("INSERT INTO corpora VALUES('cor_team','wsp_team',?,'confidential','active')", (str(root),))
db.execute("INSERT INTO corpus_aliases VALUES('workspace:team','cor_team')")
for capability in ("knowledge.read", "knowledge.write", "knowledge.manage"):
    db.execute("INSERT INTO corpus_grants VALUES('cor_team',?,'owner',?,'corpus','active')", (principal, capability))
db.commit()
db.close()
PY

cat >"$ARCHIVE" <<'JSON'
{"provider":"xapi","connection_id":"conn_shared_001","remote_account_id":"acct-shared","exported_at":"2026-07-25T00:00:00Z","accounts":[],"objects":[{"object_type":"post","remote_id":"shared-post-1","account_remote_id":"acct-shared","text":"workspace secret evidence","observed_at":"2026-07-25T00:00:00Z","evidence_class":"authored"}],"activities":[],"media":[],"coverage":[]}
JSON
chmod 0600 "$ARCHIVE"
"$SOCIAL_HELPER" provision --base "$OWNER_BASE" --alias workspace:team >/dev/null
"$SOCIAL_HELPER" import-archive --base "$OWNER_BASE" --alias workspace:team --archive "$ARCHIVE" >/dev/null
"$SOCIAL_HELPER" share-grant --base "$OWNER_BASE" --alias workspace:team \
	--public-key "$OWNER_BASE/owner-public.json" >/dev/null
"$SOCIAL_HELPER" share-grant --base "$OWNER_BASE" --alias workspace:team \
	--public-key "$MEMBER_BASE/member-public.json" >/dev/null
"$SOCIAL_HELPER" share-export --base "$OWNER_BASE" --alias workspace:team \
	--recipient-key "$MEMBER_BASE/member-public.json" --sender-key "$OWNER_BASE/owner-private.json" \
	--output "$BUNDLE" >/dev/null

assert_pass "transport contains ciphertext without plaintext or private paths" contains_no_plaintext "$BUNDLE"

# Simulate authenticated membership-state delivery to a second trusted device.
cp "$OWNER_BASE/catalog.db" "$MEMBER_BASE/catalog.db"
chmod 0600 "$MEMBER_BASE/catalog.db"
python3 - "$MEMBER_BASE/catalog.db" "$MEMBER_TEAM" <<'PY'
import sqlite3
import sys
db = sqlite3.connect(sys.argv[1])
db.execute("UPDATE corpora SET location_ref=? WHERE corpus_id='cor_team'", (sys.argv[2],))
db.commit()
db.close()
PY

tampered_bundle="${TMP_DIR}/tampered-bundle.json"
cp "$BUNDLE" "$tampered_bundle"
python3 - "$tampered_bundle" <<'PY'
import json
import sys
path = sys.argv[1]
bundle = json.load(open(path, encoding="utf-8"))
bundle["signature"] = ("A" if bundle["signature"][0] != "A" else "B") + bundle["signature"][1:]
json.dump(bundle, open(path, "w", encoding="utf-8"), sort_keys=True, separators=(",", ":"))
PY
assert_fail "tampered sender signature is rejected before local import" \
	"$SOCIAL_HELPER" share-import --base "$MEMBER_BASE" --alias workspace:team \
	--private-key "$MEMBER_BASE/member-private.json" --bundle "$tampered_bundle"

"$SOCIAL_HELPER" share-import --base "$MEMBER_BASE" --alias workspace:team \
	--private-key "$MEMBER_BASE/member-private.json" --bundle "$BUNDLE" >/dev/null
assert_pass "authorized member decrypts and rebuilds a local searchable index" query_has_result "$MEMBER_BASE"

member_id=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["principal_id"])' "$MEMBER_BASE/member-public.json")
"$SOCIAL_HELPER" share-revoke --base "$OWNER_BASE" --alias workspace:team --principal-id "$member_id" >/dev/null
cp "$OWNER_BASE/catalog.db" "$MEMBER_BASE/catalog.db"
chmod 0600 "$MEMBER_BASE/catalog.db"
python3 - "$MEMBER_BASE/catalog.db" "$MEMBER_TEAM" <<'PY'
import sqlite3
import sys
db = sqlite3.connect(sys.argv[1])
db.execute("UPDATE corpora SET location_ref=? WHERE corpus_id='cor_team'", (sys.argv[2],))
db.commit()
db.close()
PY

assert_fail "revoked member cannot query a locally cached index" \
	"$SOCIAL_HELPER" query --base "$MEMBER_BASE" --alias workspace:team --query secret
assert_fail "revoked member cannot replay an old encrypted bundle" \
	"$SOCIAL_HELPER" share-import --base "$MEMBER_BASE" --alias workspace:team \
	--private-key "$MEMBER_BASE/member-private.json" --bundle "$BUNDLE"

printf '\nResults: %s passed, %s failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
