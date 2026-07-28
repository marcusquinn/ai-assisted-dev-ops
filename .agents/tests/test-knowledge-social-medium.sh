#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-medium.sh — Medium native account export importer tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
TMP_DIR=$(mktemp -d)
BASE="${TMP_DIR}/knowledge"
ROOT="${BASE}/_knowledge"
ARCHIVE="${TMP_DIR}/medium-export.zip"
PASS=0
FAIL=0

cleanup() {
	rm -rf "$TMP_DIR"
	return 0
}
trap cleanup EXIT

assert_eq() {
	local description="$1"
	local actual="$2"
	local expected="$3"
	if [[ "$actual" == "$expected" ]]; then
		PASS=$((PASS + 1))
		printf '  PASS  %s\n' "$description"
	else
		FAIL=$((FAIL + 1))
		printf '  FAIL  %s (expected=%s actual=%s)\n' \
			"$description" "$expected" "$actual"
	fi
	return 0
}

json_field() {
	local payload="$1"
	local field="$2"
	python3 -c \
		'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' \
		"$payload" "$field"
	return 0
}

sql_value() {
	local query="$1"
	python3 - "$ROOT/index/social.db" "$query" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute(sys.argv[2]).fetchone()[0])
PY
	return 0
}

raw_count() {
	local connection_id="$1"
	python3 - "$ROOT/sources/social/raw/medium/$connection_id" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
print(len(list(root.rglob("*.json.gz"))) if root.exists() else 0)
PY
	return 0
}

expect_import_failure() {
	local description="$1"
	local archive="$2"
	local connection_id="$3"
	local account_id="$4"
	shift 4
	if "$HELPER" import-medium-archive --base "$BASE" --alias personal:default \
		--archive "$archive" --connection-id "$connection_id" \
		--account-id "$account_id" --username fixture \
		--exported-at 2026-07-28T08:00:00Z "$@" >/dev/null 2>&1; then
		assert_eq "$description" accepted rejected
	else
		assert_eq "$description" rejected rejected
	fi
	return 0
}

make_archive() {
	local target="$1"
	local mode="$2"
	python3 "${SCRIPT_DIR}/fixtures/medium-archive-fixture.py" "$target" "$mode"
	return 0
}

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$HELPER" provision --base "$BASE" --alias personal:default >/dev/null

printf 'Medium account export importer tests\n'

help_output=$("$HELPER" help)
if [[ "$help_output" == *"import-medium-archive"* && "$help_output" == *"MEDIUM_USER_ID"* ]]; then
	assert_eq "help exposes the identity-bound Medium archive route" advertised advertised
else
	assert_eq "help exposes the identity-bound Medium archive route" missing advertised
fi

python3 - "$SCRIPT_DIR/../scripts" <<'PY'
import ast
import sys
from pathlib import Path

scripts = Path(sys.argv[1])
targets = [
    scripts / "knowledge_social_medium.py",
    scripts / "_knowledge_social_medium.py",
    scripts / "_knowledge_social_medium_html.py",
]
for target in targets:
    source = target.read_text(encoding="utf-8")
    tree = ast.parse(source)
    imports = {
        alias.name
        for node in ast.walk(tree)
        if isinstance(node, ast.Import)
        for alias in node.names
    }
    imports.update(
        node.module or "" for node in ast.walk(tree) if isinstance(node, ast.ImportFrom)
    )
    assert "urllib.request" not in imports
    assert "socket" not in imports
    assert not any(
        "outbound" in name or "browser" in name or "operations" in name
        for name in imports
    )
    assert "subprocess" not in imports
    assert "urlopen(" not in source and "requests." not in source
PY
assert_eq "Medium importer has no network or outbound mutation reachability" isolated isolated

make_archive "$ARCHIVE" valid
runtime_isolation=$(
	python3 - "$ARCHIVE" "$SCRIPT_DIR/../scripts" "$TMP_DIR/runtime-root" <<'PY'
import importlib.abc
import os
import socket
import subprocess
import sys
from pathlib import Path


class MutationImportBlocker(importlib.abc.MetaPathFinder):
    blocked = (
        "_knowledge_social_outbound",
        "knowledge_social_browser",
        "knowledge_social_operations",
    )

    def find_spec(self, fullname, _path, _target=None):
        if fullname.startswith(self.blocked):
            raise AssertionError(f"mutation module import attempted: {fullname}")
        return None


def blocked_runtime(*_args, **_kwargs):
    raise AssertionError("network, subprocess, or mutation execution attempted")


sys.meta_path.insert(0, MutationImportBlocker())
socket.socket = blocked_runtime
subprocess.Popen = blocked_runtime
subprocess.call = blocked_runtime
subprocess.check_call = blocked_runtime
subprocess.check_output = blocked_runtime
subprocess.run = blocked_runtime
os.system = blocked_runtime
os.popen = blocked_runtime
sys.path.insert(0, sys.argv[2])
from _knowledge_social_lease import (
    RunLeaseRequest,
    acquire_run_lease,
    release_run_lease,
)
from _knowledge_social_medium import (
    _normalized_url,
    parse_medium_archive,
    persist_medium_archive,
)
from knowledge_social_store import SocialStoreError

first = _normalized_url("https://example.invalid/story?id=1")
second = _normalized_url("https://example.invalid/story?id=2")
assert first != second and first.endswith("?id=1") and second.endswith("?id=2")
for unsafe_url in (
    "https://example.invalid/story?access_token=forbidden",
    "https://example.invalid/story?X-Amz-Signature=forbidden",
    "https://example.invalid/story?X-Goog-Credential=forbidden",
    "https://example.invalid/story?sig=forbidden",
):
    try:
        _normalized_url(unsafe_url)
    except SocialStoreError:
        pass
    else:
        raise AssertionError("credential-shaped URL query was accepted")
parsed, _payload = parse_medium_archive(
    Path(sys.argv[1]), "conn_runtime_check", "medium_user_42", "fixture",
    "2026-07-28T08:00:00Z", 512 * 1024 * 1024, 50_000,
)
runtime_root = Path(sys.argv[3])
runtime_root.mkdir(mode=0o700)
lease = acquire_run_lease(
    runtime_root,
    RunLeaseRequest("conn_runtime_check", "archive", "runtime_check", "sync", 300),
)
result = persist_medium_archive(runtime_root, parsed, _payload, lease)
release_run_lease(runtime_root, lease)
print("isolated" if result["status"] == "complete" else "failed")
PY
)
assert_eq "runtime import cannot reach network, subprocess, or mutation adapters" \
	"$runtime_isolation" isolated
result=$("$HELPER" import-medium-archive --base "$BASE" --alias personal:default \
	--archive "$ARCHIVE" --connection-id conn_medium --account-id medium_user_42 \
	--username fixture --exported-at 2026-07-28T08:00:00Z)
assert_eq "validated Medium archive import completes" "$(json_field "$result" status)" complete
assert_eq "first import is distinguished from an exact replay" \
	"$(json_field "$result" replayed)" False
assert_eq "current sanitized fixture recognizes all social HTML members" \
	"$(json_field "$result" recognized_members)" 11
assert_eq "unsupported session metadata remains an explicit unmapped member" \
	"$(json_field "$result" unrecognized_members)" 1
assert_eq "profile identity binds the selected Medium user ID and handle" \
	"$(sql_value "SELECT remote_id || ':' || handle FROM accounts WHERE provider='medium' AND remote_id='medium_user_42'")" \
	"medium_user_42:fixture"
assert_eq "authored posts stay distinct from curated objects" \
	"$(sql_value "SELECT count(*) || ':' || (SELECT count(*) FROM objects WHERE provider='medium' AND evidence_class='curated') FROM objects WHERE provider='medium' AND evidence_class='authored'")" \
	"2:4"
assert_eq "an explicit response marker survives normalization" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='medium' AND provider_json LIKE '%\"post_kind\":\"response\"%'")" 1
assert_eq "publication membership and all three follow directions persist" \
	"$(sql_value "SELECT count(*) FROM activities WHERE provider='medium' AND activity_type IN ('publication_membership','follow_user','follow_publication','follow_topic')")" 4
assert_eq "timezone-free curation timestamps are preserved without invented UTC" \
	"$(sql_value "SELECT count(*) FROM activities WHERE provider='medium' AND activity_type='bookmark' AND occurred_at IS NULL AND provider_json LIKE '%2026-07-27 4:50 pm%'")" 1
assert_eq "response coverage remains partial instead of claiming archive parity" \
	"$(sql_value "SELECT status || ':' || cursor_exhausted FROM coverage_records WHERE provider='medium' AND stream='responses'")" partial:1
assert_eq "missing media and messages remain explicit No coverage" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE provider='medium' AND stream IN ('local_media','mentions_messages') AND status='unavailable'")" 2
assert_eq "unmapped native export state is retained as partial coverage" \
	"$(sql_value "SELECT status FROM coverage_records WHERE provider='medium' AND stream='unmapped_archive_members'")" partial
assert_eq "archive replay marker is an independent exhausted checkpoint" \
	"$(sql_value "SELECT coalesce(cursor,'done') || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_medium' AND stream='archive'")" done:1

archive_hash=$(
	python3 - "$ARCHIVE" <<'PY'
import hashlib
import sys
from pathlib import Path

print(hashlib.sha256(Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)
assert_eq "result exposes only the content-addressed archive digest" \
	"$(json_field "$result" archive_sha256)" "$archive_hash"
raw_integrity=$(
	python3 - "$ARCHIVE" "$ROOT" <<'PY'
import gzip
import hashlib
import sqlite3
import sys
from pathlib import Path

archive = Path(sys.argv[1]).read_bytes()
root = Path(sys.argv[2])
with sqlite3.connect(root / "index" / "social.db") as database:
    relative = database.execute(
        "SELECT blob_ref FROM fetch_batches WHERE provider='medium' AND connection_id='conn_medium'"
    ).fetchone()[0]
with gzip.open(root / relative, "rb") as source:
    stored = source.read()
print("verified" if stored == archive and hashlib.sha256(stored).hexdigest() == hashlib.sha256(archive).hexdigest() else "failed")
PY
)
assert_eq "immutable raw evidence is the exact original ZIP payload" "$raw_integrity" verified

batch_count=$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='medium' AND connection_id='conn_medium'")
object_count=$(sql_value "SELECT count(*) FROM objects WHERE provider='medium'")
replay_result=$("$HELPER" import-medium-archive --base "$BASE" --alias personal:default \
	--archive "$ARCHIVE" --connection-id conn_medium --account-id medium_user_42 \
	--username fixture --exported-at 2026-07-28T08:00:00Z)
assert_eq "exact Medium archive replay is content-addressed and idempotent" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='medium' AND connection_id='conn_medium'")" "$batch_count"
assert_eq "exact replay follows the no-op path" \
	"$(json_field "$replay_result" replayed)" True
assert_eq "archive replay preserves normalized object cardinality" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='medium'")" "$object_count"

observed_before=$(sql_value "SELECT observed_at FROM objects WHERE provider='medium' AND evidence_class='authored' LIMIT 1")
if "$HELPER" import-medium-archive --base "$BASE" --alias personal:default \
	--archive "$ARCHIVE" --connection-id conn_medium --account-id medium_user_42 \
	--username fixture --exported-at 2026-07-28T09:00:00Z >/dev/null 2>&1; then
	replay_metadata=accepted
else
	replay_metadata=rejected
fi
assert_eq "same bytes with conflicting observation metadata are rejected" \
	"$replay_metadata" rejected
assert_eq "conflicting replay metadata cannot rewrite normalized evidence" \
	"$(sql_value "SELECT observed_at FROM objects WHERE provider='medium' AND evidence_class='authored' LIMIT 1")" \
	"$observed_before"

expect_import_failure "one content digest cannot bind a second connection" \
	"$ARCHIVE" conn_duplicate_digest medium_user_42
assert_eq "cross-connection digest rejection creates no second raw blob" \
	"$(raw_count conn_duplicate_digest)" 0

wrong_archive="${TMP_DIR}/wrong.zip"
make_archive "$wrong_archive" minimal
expect_import_failure "selected account mismatch fails before persistence" \
	"$wrong_archive" conn_wrong another_user_99
assert_eq "identity mismatch creates no raw Medium evidence" "$(raw_count conn_wrong)" 0

credential_archive="${TMP_DIR}/credential.zip"
make_archive "$credential_archive" credential
credential_error="${TMP_DIR}/credential-error.txt"
if "$HELPER" import-medium-archive --base "$BASE" --alias personal:default \
	--archive "$credential_archive" --connection-id conn_credential \
	--account-id medium_user_42 --username fixture \
	--exported-at 2026-07-28T08:00:00Z >/dev/null 2>"$credential_error"; then
	credential_result=accepted
else
	credential_result=rejected
fi
assert_eq "credential-shaped HTML is rejected before persistence" "$credential_result" rejected
if [[ $(<"$credential_error") == *"must-not-persist"* ]]; then
	assert_eq "credential rejection diagnostics are sanitized" leaked sanitized
else
	assert_eq "credential rejection diagnostics are sanitized" sanitized sanitized
fi
assert_eq "credential rejection creates no raw evidence" "$(raw_count conn_credential)" 0

malformed_archive="${TMP_DIR}/malformed.zip"
make_archive "$malformed_archive" malformed
cursor_before=$(sql_value "SELECT watermark FROM sync_cursors WHERE connection_id='conn_medium' AND stream='archive'")
expect_import_failure "malformed category HTML is terminal before persistence" \
	"$malformed_archive" conn_malformed medium_user_42
assert_eq "malformed import preserves the prior successful checkpoint" \
	"$(sql_value "SELECT watermark FROM sync_cursors WHERE connection_id='conn_medium' AND stream='archive'")" "$cursor_before"
assert_eq "malformed import creates no raw evidence" "$(raw_count conn_malformed)" 0

malformed_bookmarks="${TMP_DIR}/malformed-bookmarks.zip"
make_archive "$malformed_bookmarks" malformed-bookmarks
expect_import_failure "recognized categories cannot claim complete after schema drift" \
	"$malformed_bookmarks" conn_malformed_bookmarks medium_user_42
assert_eq "unparseable category markers create no raw evidence" \
	"$(raw_count conn_malformed_bookmarks)" 0

malformed_highlights="${TMP_DIR}/malformed-highlights.zip"
make_archive "$malformed_highlights" malformed-highlights
expect_import_failure "empty highlight markers cannot claim complete coverage" \
	"$malformed_highlights" conn_malformed_highlights medium_user_42
assert_eq "empty highlight selections create no raw evidence" \
	"$(raw_count conn_malformed_highlights)" 0

traversal_archive="${TMP_DIR}/traversal.zip"
make_archive "$traversal_archive" traversal
expect_import_failure "ZIP traversal members fail closed" \
	"$traversal_archive" conn_traversal medium_user_42
assert_eq "unsafe ZIP members create no raw evidence" "$(raw_count conn_traversal)" 0

symlink_archive="${TMP_DIR}/archive-link.zip"
ln -s "$ARCHIVE" "$symlink_archive"
expect_import_failure "input archive symlinks fail closed" \
	"$symlink_archive" conn_input_symlink medium_user_42

duplicate_archive="${TMP_DIR}/duplicate.zip"
make_archive "$duplicate_archive" duplicate
expect_import_failure "case-folded duplicate ZIP paths fail closed" \
	"$duplicate_archive" conn_duplicate medium_user_42

member_symlink_archive="${TMP_DIR}/member-symlink.zip"
make_archive "$member_symlink_archive" member-symlink
expect_import_failure "ZIP member symlinks fail closed" \
	"$member_symlink_archive" conn_member_symlink medium_user_42

encrypted_archive="${TMP_DIR}/encrypted.zip"
make_archive "$encrypted_archive" encrypted
expect_import_failure "encrypted ZIP members fail closed before parsing" \
	"$encrypted_archive" conn_encrypted medium_user_42

oversized_member_archive="${TMP_DIR}/oversized-member.zip"
make_archive "$oversized_member_archive" oversized-member
expect_import_failure "the per-member expansion ceiling fails closed" \
	"$oversized_member_archive" conn_oversized_member medium_user_42
assert_eq "encrypted and oversized members create no raw evidence" \
	"$(($(raw_count conn_encrypted) + $(raw_count conn_oversized_member)))" 0

deep_archive="${TMP_DIR}/deep.zip"
make_archive "$deep_archive" deep
deep_error="${TMP_DIR}/deep-error.txt"
if "$HELPER" import-medium-archive --base "$BASE" --alias personal:default \
	--archive "$deep_archive" --connection-id conn_deep --account-id medium_user_42 \
	--username fixture --exported-at 2026-07-28T08:00:00Z \
	>/dev/null 2>"$deep_error"; then
	deep_result=accepted
else
	deep_result=rejected
fi
assert_eq "pathological HTML depth fails as a bounded validation error" \
	"$deep_result" rejected
if [[ $(<"$deep_error") == *"Traceback"* ]]; then
	assert_eq "deep HTML diagnostics contain no traceback or local paths" leaked sanitized
else
	assert_eq "deep HTML diagnostics contain no traceback or local paths" sanitized sanitized
fi

expect_import_failure "member and normalized item budget stops before persistence" \
	"$ARCHIVE" conn_item_budget medium_user_42 --max-items 3
expect_import_failure "compressed byte budget stops before persistence" \
	"$ARCHIVE" conn_byte_budget medium_user_42 --max-bytes 128
expansion_archive="${TMP_DIR}/expansion.zip"
make_archive "$expansion_archive" expansion
expect_import_failure "aggregate uncompressed ZIP growth stops before persistence" \
	"$expansion_archive" conn_expansion_budget medium_user_42 --max-bytes 4096
assert_eq "budget stops create no raw evidence" \
	"$(($(raw_count conn_item_budget) + $(raw_count conn_byte_budget) + $(raw_count conn_expansion_budget)))" 0

other_archive="${TMP_DIR}/other-account.zip"
make_archive "$other_archive" other-account
raw_before_rebind=$(raw_count conn_medium)
fetch_before_rebind=$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='medium' AND connection_id='conn_medium'")
expect_import_failure "connection rebinding is rejected under the final fence" \
	"$other_archive" conn_medium medium_other_99 --username fixture
assert_eq "account rebinding writes no raw evidence or fetch batch" \
	"$(raw_count conn_medium):$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='medium' AND connection_id='conn_medium'")" \
	"${raw_before_rebind}:${fetch_before_rebind}"

python3 - "$ROOT" "$ARCHIVE" "$SCRIPT_DIR/../scripts" "$expansion_archive" <<'PY'
import os
import sqlite3
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[3])
import _knowledge_social_medium as medium
from _knowledge_social_lease import (
    RunLeaseRequest,
    SocialLeaseLostError,
    acquire_run_lease,
    release_run_lease,
)
from _knowledge_social_medium import parse_medium_archive, persist_medium_archive

root = Path(sys.argv[1])
parsed, payload = parse_medium_archive(
    Path(sys.argv[2]),
    "conn_medium_stale",
    "medium_user_42",
    "fixture",
    "2026-07-28T08:00:00Z",
    512 * 1024 * 1024,
    50_000,
)
old = acquire_run_lease(
    root,
    RunLeaseRequest("conn_medium_stale", "archive", "old_runner", "sync", 1),
    now_epoch=9000,
)
new = acquire_run_lease(
    root,
    RunLeaseRequest("conn_medium_stale", "archive", "new_runner", "sync", 10),
    now_epoch=9001,
)
os.environ["AIDEVOPS_SOCIAL_NOW_EPOCH"] = "9001"
try:
    persist_medium_archive(root, parsed, payload, old)
except SocialLeaseLostError:
    pass
else:
    raise SystemExit("stale Medium archive lease advanced persistence")
with sqlite3.connect(root / "index" / "social.db") as database:
    count = database.execute(
        "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_medium_stale'"
    ).fetchone()[0]
assert count == 0
release_run_lease(root, new)

expiring_parsed, expiring_payload = parse_medium_archive(
    Path(sys.argv[4]),
    "conn_medium_expiring",
    "medium_user_42",
    "fixture",
    "2026-07-28T08:00:00Z",
    512 * 1024 * 1024,
    50_000,
)
expiring = acquire_run_lease(
    root,
    RunLeaseRequest("conn_medium_expiring", "archive", "expiring_runner", "sync", 1),
    now_epoch=9100,
)
os.environ["AIDEVOPS_SOCIAL_NOW_EPOCH"] = "9100"
original_update = medium.update_run_receipt


def expire_before_receipt(database, lease, update):
    os.environ["AIDEVOPS_SOCIAL_NOW_EPOCH"] = "9101"
    return original_update(database, lease, update)


medium.update_run_receipt = expire_before_receipt
try:
    medium.persist_medium_archive(root, expiring_parsed, expiring_payload, expiring)
except SocialLeaseLostError:
    pass
else:
    raise SystemExit("expired Medium archive lease advanced persistence")
finally:
    medium.update_run_receipt = original_update
with sqlite3.connect(root / "index" / "social.db") as database:
    count = database.execute(
        "SELECT count(*) FROM fetch_batches WHERE connection_id='conn_medium_expiring'"
    ).fetchone()[0]
assert count == 0
release_run_lease(root, expiring)
PY
assert_eq "stale archive lease cannot commit evidence or a replay checkpoint" \
	"$(raw_count conn_medium_stale):$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_medium_stale'")" 0:0
assert_eq "lease expiry after raw staging rolls back the blob and database rows" \
	"$(raw_count conn_medium_expiring):$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_medium_expiring'")" 0:0

assert_eq "profile email and security state never enter normalized provider rows" \
	"$(sql_value "SELECT count(*) FROM accounts WHERE provider='medium' AND provider_json LIKE '%example.invalid%'")" 0

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -ne 0 ]]; then
	exit 1
fi
exit 0
