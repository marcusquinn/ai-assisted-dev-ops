#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-sharing.sh — Encrypted cross-principal workspace tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
MESSAGE_HELPER="${SCRIPT_DIR}/../scripts/vault-message-helper.sh"
VAULT_PYTHON="${AIDEVOPS_VAULT_PYTHON:-${HOME}/.aidevops/.agent-workspace/python-env/vault/bin/python3}"
TMP_DIR=$(mktemp -d 2>/dev/null || mktemp -d -t aidevops-social-share)
TMP_DIR="$(cd "$TMP_DIR" && pwd -P)"
ALICE_BASE="${TMP_DIR}/alice/knowledge"
BOB_BASE="${TMP_DIR}/bob/knowledge"
EVE_BASE="${TMP_DIR}/eve/knowledge"
ALICE_VAULT="${TMP_DIR}/alice/vault"
BOB_VAULT="${TMP_DIR}/bob/vault"
EVE_VAULT="${TMP_DIR}/eve/vault"
ALICE_ID="${TMP_DIR}/alice-id.json"
BOB_ID="${TMP_DIR}/bob-id.json"
BOB_ROTATED_ID="${TMP_DIR}/bob-rotated-id.json"
EVE_ID="${TMP_DIR}/eve-id.json"
LOW_ORDER_ID="${TMP_DIR}/low-order-id.json"
GRANT="${TMP_DIR}/bob-grant.json"
GRANT_CONFLICT="${TMP_DIR}/bob-grant-conflict.json"
EVE_GRANT="${TMP_DIR}/eve-grant.json"
ROTATED_GRANT="${TMP_DIR}/bob-rotated-grant.json"
BATCH="${TMP_DIR}/batch.json"
SECOND_BATCH="${TMP_DIR}/second-batch.json"
TAMPERED="${TMP_DIR}/tampered.json"
REVOCATION="${TMP_DIR}/revocation.json"
EVE_REVOCATION="${TMP_DIR}/eve-revocation.json"
REVOCATION_CONFLICT="${TMP_DIR}/revocation-conflict.json"
SELF_REVOCATION="${TMP_DIR}/self-revocation.json"
ROTATED_BATCH="${TMP_DIR}/rotated-batch.json"
REGRANTED_BATCH="${TMP_DIR}/regranted-batch.json"
BOB_OLD_VAULT="${TMP_DIR}/bob-old-vault"
MEMBER_EXPORT="${TMP_DIR}/member-export.json"
ARCHIVE="${TMP_DIR}/team-archive.json"
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
		printf '  FAIL  %s (expected=%s actual=%s)\n' "$description" "$expected" "$actual"
	fi
	return 0
}

assert_absent() {
	local description="$1"
	local payload="$2"
	local forbidden="$3"
	if [[ "$payload" != *"$forbidden"* ]]; then
		assert_eq "$description" "absent" "absent"
	else
		assert_eq "$description" "present" "absent"
	fi
	return 0
}

expect_failure() {
	local description="$1"
	local expected="$2"
	shift 2
	local output=""
	if output=$("$@" 2>&1); then
		assert_eq "$description" "accepted" "rejected"
	elif [[ "$output" == *"$expected"* ]]; then
		assert_eq "$description" "rejected" "rejected"
	else
		assert_eq "$description" "$output" "error containing: $expected"
	fi
	return 0
}

json_value() {
	local path="$1"
	local field="$2"
	python3 - "$path" "$field" <<'PY' || return 1
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
for component in sys.argv[2].split("."):
    value = value[component]
print(value)
PY
	return 0
}

store_count() {
	local base="$1"
	local table="$2"
	python3 - "$base" "$table" <<'PY' || return 1
import json
import sqlite3
import sys
from pathlib import Path

base = Path(sys.argv[1])
table = sys.argv[2]
principal = json.loads((base / "_config" / "principal.json").read_text())["principal_id"]
with sqlite3.connect(base / "catalog.db") as catalog:
    location = catalog.execute(
        "SELECT c.location_ref FROM corpora c JOIN corpus_aliases a ON a.corpus_id=c.corpus_id "
        "WHERE a.alias='workspace:alpha'"
    ).fetchone()[0]
with sqlite3.connect(Path(location) / "index" / "social.db") as social:
    print(social.execute(f"SELECT count(*) FROM {table}").fetchone()[0])
PY
	return 0
}

set_device_grant_status() {
	local base="$1"
	local device_id="$2"
	local status="$3"
	python3 - "$base" "$device_id" "$status" <<'PY' || return 1
import sqlite3
import sys
from pathlib import Path

with sqlite3.connect(Path(sys.argv[1]) / "catalog.db") as catalog:
    changed = catalog.execute(
        "UPDATE workspace_device_grants SET status=? WHERE device_id=?",
        (sys.argv[3], sys.argv[2]),
    ).rowcount
    if changed != 1:
        raise SystemExit("expected exactly one device grant")
PY
	return 0
}

set_principal_device_status() {
	local base="$1"
	local device_id="$2"
	local status="$3"
	python3 - "$base" "$device_id" "$status" <<'PY' || return 1
import sqlite3
import sys
from pathlib import Path

with sqlite3.connect(Path(sys.argv[1]) / "catalog.db") as catalog:
    changed = catalog.execute(
        "UPDATE principal_devices SET status=? WHERE device_id=?",
        (sys.argv[3], sys.argv[2]),
    ).rowcount
    if changed != 1:
        raise SystemExit("expected exactly one principal device")
PY
	return 0
}

membership_status() {
	local base="$1"
	local principal_id="$2"
	python3 - "$base" "$principal_id" <<'PY' || return 1
import sqlite3
import sys
from pathlib import Path

with sqlite3.connect(Path(sys.argv[1]) / "catalog.db") as catalog:
    row = catalog.execute(
        "SELECT status FROM workspace_memberships WHERE principal_id=? AND role='member'",
        (sys.argv[2],),
    ).fetchone()
    if row is None:
        raise SystemExit("expected member status")
    print(row[0])
PY
	return 0
}

membership_count() {
	local base="$1"
	local principal_id="$2"
	python3 - "$base" "$principal_id" <<'PY' || return 1
import sqlite3
import sys
from pathlib import Path

with sqlite3.connect(Path(sys.argv[1]) / "catalog.db") as catalog:
    print(
        catalog.execute(
            "SELECT count(*) FROM workspace_memberships WHERE principal_id=?",
            (sys.argv[2],),
        ).fetchone()[0]
    )
PY
	return 0
}

share_generation() {
	local base="$1"
	python3 - "$base" <<'PY' || return 1
import sqlite3
import sys
from pathlib import Path

with sqlite3.connect(Path(sys.argv[1]) / "catalog.db") as catalog:
    row = catalog.execute("SELECT key_generation FROM workspace_share_state").fetchone()
    if row is None:
        raise SystemExit("expected workspace share state")
    print(row[0])
PY
	return 0
}

set_share_generation() {
	local base="$1"
	local generation="$2"
	python3 - "$base" "$generation" <<'PY' || return 1
import sqlite3
import sys
from pathlib import Path

with sqlite3.connect(Path(sys.argv[1]) / "catalog.db") as catalog:
    changed = catalog.execute(
        "UPDATE workspace_share_state SET key_generation=?",
        (int(sys.argv[2]),),
    ).rowcount
    if changed != 1:
        raise SystemExit("expected exactly one workspace share state")
PY
	return 0
}

if [[ ! -x "$VAULT_PYTHON" ]]; then
	printf 'FAIL: managed Vault Python is unavailable: %s\n' "$VAULT_PYTHON" >&2
	exit 1
fi
export AIDEVOPS_VAULT_TEST_MODE=1
export AIDEVOPS_VAULT_PYTHON="$VAULT_PYTHON"
export PATH="${VAULT_PYTHON%/*}:${PATH}"

printf 'Encrypted social workspace sharing tests\n'
expect_failure "unverified crypto runtimes fail before sharing code executes" \
	"managed Vault test crypto runtime failed verification" \
	env AIDEVOPS_VAULT_TEST_MODE=1 AIDEVOPS_VAULT_PYTHON="${TMP_DIR}/missing-python" \
	"$HELPER" identity-export --base "$ALICE_BASE" --vault-dir "$ALICE_VAULT" \
	--output "${TMP_DIR}/missing-runtime-id.json"
for base in "$ALICE_BASE" "$BOB_BASE" "$EVE_BASE"; do
	mkdir -p "${base}/_knowledge"
	chmod 0700 "${base}" "${base}/_knowledge"
	"$CORPUS_HELPER" provision --base "$base" >/dev/null
done

"$MESSAGE_HELPER" init --vault-dir "$ALICE_VAULT" >/dev/null
"$MESSAGE_HELPER" init --vault-dir "$BOB_VAULT" >/dev/null
"$MESSAGE_HELPER" init --vault-dir "$EVE_VAULT" >/dev/null
"$HELPER" identity-export --base "$ALICE_BASE" --vault-dir "$ALICE_VAULT" \
	--output "$ALICE_ID" >/dev/null
"$HELPER" identity-export --base "$BOB_BASE" --vault-dir "$BOB_VAULT" \
	--output "$BOB_ID" >/dev/null
"$HELPER" identity-export --base "$EVE_BASE" --vault-dir "$EVE_VAULT" \
	--output "$EVE_ID" >/dev/null
ln -s "${TMP_DIR}/alice" "${TMP_DIR}/alice-parent-link"
expect_failure "Vault identity paths reject symlinked parent components" \
	"Vault message identity directory is unsafe" \
	"$HELPER" identity-export --base "$ALICE_BASE" \
	--vault-dir "${TMP_DIR}/alice-parent-link/vault" \
	--output "${TMP_DIR}/symlinked-vault-id.json"

alice_principal=$(json_value "$ALICE_ID" identity.principal_id)
bob_principal=$(json_value "$BOB_ID" identity.principal_id)
bob_device=$(json_value "$BOB_ID" identity.device_id)
mkdir "${TMP_DIR}/unsafe-output"
chmod 0777 "${TMP_DIR}/unsafe-output"
expect_failure "sharing outputs reject directories writable by other users" \
	"sharing output directory must not be writable by other users" \
	"$HELPER" identity-export --base "$ALICE_BASE" --vault-dir "$ALICE_VAULT" \
	--output "${TMP_DIR}/unsafe-output/alice-id.json"

"$HELPER" workspace-create --base "$ALICE_BASE" --vault-dir "$ALICE_VAULT" \
	--alias workspace:alpha >/dev/null
python3 - "$LOW_ORDER_ID" "$bob_principal" <<'PY'
import base64
import hashlib
import json
import os
import sys
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey


def encode(value):
    return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")


signing = Ed25519PrivateKey.generate()
signing_public = signing.public_key().public_bytes(
    serialization.Encoding.Raw, serialization.PublicFormat.Raw
)
encryption_public = bytes(32)
identity = {
    "schema_version": 1,
    "kind": "social-share-identity",
    "principal_id": sys.argv[2],
    "device_id": hashlib.sha256(signing_public + encryption_public).hexdigest(),
    "signing_public_key": encode(signing_public),
    "encryption_public_key": encode(encryption_public),
}
canonical = json.dumps(identity, sort_keys=True, separators=(",", ":")).encode("utf-8")
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump({"identity": identity, "signature": encode(signing.sign(canonical))}, handle)
    handle.write("\n")
os.chmod(sys.argv[1], 0o600)
PY
expect_failure "low-order X25519 recipient identities fail before catalog mutation" \
	"sharing encryption public key is unsafe" \
	"$HELPER" workspace-grant --base "$ALICE_BASE" --vault-dir "$ALICE_VAULT" \
	--alias workspace:alpha --recipient "$LOW_ORDER_ID" --output "${TMP_DIR}/unsafe-grant.json"
cat >"$ARCHIVE" <<'JSON'
{
  "provider": "xapi",
  "connection_id": "conn_shared",
  "remote_account_id": "acct_shared",
  "exported_at": "2026-07-25T09:00:00Z",
  "enabled_streams": ["authored"],
  "policy": {"media_hydration": false},
  "accounts": [{"remote_id": "acct_shared", "handle": "shared-handle", "display_name": "Shared", "observed_at": "2026-07-25T09:00:00Z"}],
  "objects": [{"object_type": "post", "remote_id": "post_shared", "account_remote_id": "acct_shared", "text": "encrypted workspace marker", "created_at": "2026-07-25T08:00:00Z", "observed_at": "2026-07-25T09:00:00Z", "evidence_class": "authored"}],
  "activities": [{"activity_type": "authored", "remote_id": "activity_shared", "actor_remote_id": "acct_shared", "object_remote_id": "post_shared", "occurred_at": "2026-07-25T08:00:00Z", "observed_at": "2026-07-25T09:00:00Z", "state": "active"}],
  "media": [],
  "coverage": [{"stream": "authored", "earliest_at": "2026-07-25T08:00:00Z", "latest_at": "2026-07-25T08:00:00Z", "cursor_exhausted": true, "status": "complete", "observed_at": "2026-07-25T09:00:00Z"}]
}
JSON
chmod 0600 "$ARCHIVE"
"$HELPER" import-archive --base "$ALICE_BASE" --alias workspace:alpha \
	--archive "$ARCHIVE" >/dev/null
printf '{}\n' >"$GRANT_CONFLICT"
expect_failure "failed grant output leaves recipient authorization absent" \
	"refusing to replace an existing sharing output" \
	"$HELPER" workspace-grant --base "$ALICE_BASE" --vault-dir "$ALICE_VAULT" \
	--alias workspace:alpha --recipient "$BOB_ID" --output "$GRANT_CONFLICT"
assert_eq "failed grant output creates no workspace membership" \
	"$(membership_count "$ALICE_BASE" "$bob_principal")" "0"
"$HELPER" workspace-grant --base "$ALICE_BASE" --vault-dir "$ALICE_VAULT" \
	--alias workspace:alpha --recipient "$BOB_ID" --output "$GRANT" >/dev/null
grant_payload=$(<"$GRANT")
assert_absent "signed grants omit owner-local paths" "$grant_payload" "$ALICE_BASE"
assert_absent "signed grants omit private workspace aliases" "$grant_payload" "workspace:alpha"
assert_absent "signed grants do not transport catalog files" "$grant_payload" "catalog.db"
"$HELPER" workspace-accept --base "$BOB_BASE" --vault-dir "$BOB_VAULT" \
	--alias workspace:alpha --sender "$ALICE_ID" --grant "$GRANT" >/dev/null
expect_failure "workspace owners cannot orphan a workspace by self-revoking" \
	"workspace owner cannot self-revoke" \
	"$HELPER" workspace-revoke --base "$ALICE_BASE" --vault-dir "$ALICE_VAULT" \
	--alias workspace:alpha --principal-id "$alice_principal" --output "$SELF_REVOCATION"

"$HELPER" share-export --base "$ALICE_BASE" --vault-dir "$ALICE_VAULT" \
	--alias workspace:alpha --output "$BATCH" >/dev/null
batch_payload=$(<"$BATCH")
assert_absent "ciphertext transport omits shared plaintext" "$batch_payload" "encrypted workspace marker"
assert_absent "ciphertext transport omits physical corpus paths" "$batch_payload" "$ALICE_BASE"
assert_absent "ciphertext transport omits local FTS table names" "$batch_payload" "objects_fts"
assert_absent "ciphertext transport omits private workspace aliases" "$batch_payload" "workspace:alpha"
assert_absent "ciphertext transport omits SQLite filenames" "$batch_payload" "social.db"
assert_absent "ciphertext transport omits catalog filenames" "$batch_payload" "catalog.db"

python3 - "$BATCH" "$TAMPERED" <<'PY'
import json
import os
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
ciphertext = value["record"]["payload"]["ciphertext"]
value["record"]["payload"]["ciphertext"] = ("A" if ciphertext[0] != "A" else "B") + ciphertext[1:]
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(value, handle, sort_keys=True)
    handle.write("\n")
os.chmod(sys.argv[2], 0o644)
PY
expect_failure "tampered signed transport fails before decryption" "SIGNATURE_INVALID" \
	"$HELPER" share-import --base "$BOB_BASE" --vault-dir "$BOB_VAULT" \
	--alias workspace:alpha --sender "$ALICE_ID" --batch "$TAMPERED"

"$HELPER" share-import --base "$BOB_BASE" --vault-dir "$BOB_VAULT" \
	--alias workspace:alpha --sender "$ALICE_ID" --batch "$BATCH" >/dev/null
bob_query=$("$HELPER" query --base "$BOB_BASE" --alias workspace:alpha \
	--query "encrypted workspace marker")
assert_eq "recipient rebuilds a searchable local FTS projection" \
	"$([[ "$bob_query" == *post_shared* ]] && printf found || printf missing)" "found"
assert_eq "recipient restores normalized objects" "$(store_count "$BOB_BASE" objects)" "1"
assert_eq "recipient restores immutable raw evidence" "$(store_count "$BOB_BASE" fetch_batches)" "1"
expect_failure "ordinary workspace members cannot redistribute snapshots" \
	"workspace owner identity is required" \
	"$HELPER" share-export --base "$BOB_BASE" --vault-dir "$BOB_VAULT" \
	--alias workspace:alpha --output "$MEMBER_EXPORT"
expect_failure "replayed distributions fail closed" "stale or replayed" \
	"$HELPER" share-import --base "$BOB_BASE" --vault-dir "$BOB_VAULT" \
	--alias workspace:alpha --sender "$ALICE_ID" --batch "$BATCH"

"$HELPER" share-export --base "$ALICE_BASE" --vault-dir "$ALICE_VAULT" \
	--alias workspace:alpha --output "$SECOND_BATCH" >/dev/null
set_device_grant_status "$BOB_BASE" "$bob_device" revoked
expect_failure "inactive device grants deny import before content-key unwrap" \
	"sharing device grant is inactive" \
	"$HELPER" share-import --base "$BOB_BASE" --vault-dir "$BOB_VAULT" \
	--alias workspace:alpha --sender "$ALICE_ID" --batch "$SECOND_BATCH"
set_device_grant_status "$BOB_BASE" "$bob_device" active
"$HELPER" share-import --base "$BOB_BASE" --vault-dir "$BOB_VAULT" \
	--alias workspace:alpha --sender "$ALICE_ID" --batch "$SECOND_BATCH" >/dev/null
set_principal_device_status "$BOB_BASE" "$bob_device" revoked
expect_failure "globally revoked devices deny import before content-key unwrap" \
	"sharing device grant is inactive" \
	"$HELPER" share-import --base "$BOB_BASE" --vault-dir "$BOB_VAULT" \
	--alias workspace:alpha --sender "$ALICE_ID" --batch "$SECOND_BATCH"
set_principal_device_status "$BOB_BASE" "$bob_device" active

expect_failure "a grant cannot be accepted by another principal" "does not target" \
	"$HELPER" workspace-accept --base "$EVE_BASE" --vault-dir "$EVE_VAULT" \
	--alias workspace:alpha --sender "$ALICE_ID" --grant "$GRANT"
expect_failure "an ungranted principal cannot import a shared batch" "workspace is unavailable" \
	"$HELPER" share-import --base "$EVE_BASE" --vault-dir "$EVE_VAULT" \
	--alias workspace:alpha --sender "$ALICE_ID" --batch "$BATCH"
expect_failure "a forged sender trust anchor is rejected" "trusted identity" \
	"$HELPER" share-import --base "$BOB_BASE" --vault-dir "$BOB_VAULT" \
	--alias workspace:alpha --sender "$EVE_ID" --batch "$BATCH"

"$HELPER" workspace-grant --base "$ALICE_BASE" --vault-dir "$ALICE_VAULT" \
	--alias workspace:alpha --recipient "$EVE_ID" --output "$EVE_GRANT" >/dev/null
"$HELPER" workspace-accept --base "$EVE_BASE" --vault-dir "$EVE_VAULT" \
	--alias workspace:alpha --sender "$ALICE_ID" --grant "$EVE_GRANT" >/dev/null
printf '{}\n' >"$REVOCATION_CONFLICT"
expect_failure "failed revocation output leaves authorization and generation unchanged" \
	"refusing to replace an existing sharing output" \
	"$HELPER" workspace-revoke --base "$ALICE_BASE" --vault-dir "$ALICE_VAULT" \
	--alias workspace:alpha --principal-id "$bob_principal" --output "$REVOCATION_CONFLICT"
assert_eq "failed revocation output preserves active membership" \
	"$(membership_status "$ALICE_BASE" "$bob_principal")" "active"
assert_eq "failed revocation output preserves the current generation" \
	"$(share_generation "$ALICE_BASE")" "1"
eve_principal=$(json_value "$EVE_ID" identity.principal_id)
"$HELPER" workspace-revoke --base "$ALICE_BASE" --vault-dir "$ALICE_VAULT" \
	--alias workspace:alpha --principal-id "$eve_principal" --output "$EVE_REVOCATION" >/dev/null
"$HELPER" workspace-revoke --base "$ALICE_BASE" --vault-dir "$ALICE_VAULT" \
	--alias workspace:alpha --principal-id "$bob_principal" --output "$REVOCATION" >/dev/null
revocation_payload=$(<"$REVOCATION")
assert_absent "signed revocations omit owner-local paths" "$revocation_payload" "$ALICE_BASE"
assert_absent "signed revocations omit private workspace aliases" "$revocation_payload" "workspace:alpha"
expect_failure "out-of-order revocations cannot skip signed generation state" \
	"revocation generation is not the next signed state" \
	"$HELPER" revocation-apply --base "$BOB_BASE" --alias workspace:alpha \
	--sender "$ALICE_ID" --revocation "$REVOCATION"
"$HELPER" revocation-apply --base "$BOB_BASE" --alias workspace:alpha \
	--sender "$ALICE_ID" --revocation "$EVE_REVOCATION" >/dev/null
assert_eq "another member's revocation preserves local query authorization" \
	"$([[ $("$HELPER" query --base "$BOB_BASE" --alias workspace:alpha --query marker) == *post_shared* ]] && printf found || printf missing)" \
	"found"
"$HELPER" revocation-apply --base "$BOB_BASE" --alias workspace:alpha \
	--sender "$ALICE_ID" --revocation "$REVOCATION" >/dev/null
expect_failure "revocation removes query access before cached content is served" "access denied" \
	"$HELPER" query --base "$BOB_BASE" --alias workspace:alpha --query marker
"$HELPER" revocation-apply --base "$BOB_BASE" --alias workspace:alpha \
	--sender "$ALICE_ID" --revocation "$REVOCATION" >/dev/null
assert_eq "signed revocation replay is idempotent" "accepted" "accepted"

rotated_result=$("$HELPER" share-export --base "$ALICE_BASE" --vault-dir "$ALICE_VAULT" \
	--alias workspace:alpha --output "$ROTATED_BATCH")
rotated_payload=$(<"$ROTATED_BATCH")
assert_eq "post-revocation batches wrap only to active owner devices" \
	"$(
		python3 - "$rotated_result" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["recipients"])
PY
	)" "1"
assert_absent "post-revocation transport excludes revoked principal id" \
	"$rotated_payload" "$bob_principal"
assert_absent "post-revocation transport excludes revoked device id" \
	"$rotated_payload" "$bob_device"
expect_failure "revoked member cannot import a rotated batch" "ACCESS_DENIED" \
	"$HELPER" share-import --base "$BOB_BASE" --vault-dir "$BOB_VAULT" \
	--alias workspace:alpha --sender "$ALICE_ID" --batch "$ROTATED_BATCH"

cp -R "$BOB_VAULT" "$BOB_OLD_VAULT"
"$MESSAGE_HELPER" init --vault-dir "$BOB_VAULT" --force >/dev/null
"$HELPER" identity-export --base "$BOB_BASE" --vault-dir "$BOB_VAULT" \
	--output "$BOB_ROTATED_ID" >/dev/null
bob_rotated_device=$(json_value "$BOB_ROTATED_ID" identity.device_id)
"$HELPER" workspace-grant --base "$ALICE_BASE" --vault-dir "$ALICE_VAULT" \
	--alias workspace:alpha --recipient "$BOB_ROTATED_ID" --output "$ROTATED_GRANT" >/dev/null
"$HELPER" workspace-accept --base "$BOB_BASE" --vault-dir "$BOB_VAULT" \
	--alias workspace:alpha --sender "$ALICE_ID" --grant "$ROTATED_GRANT" >/dev/null
regranted_result=$("$HELPER" share-export --base "$ALICE_BASE" --vault-dir "$ALICE_VAULT" \
	--alias workspace:alpha --output "$REGRANTED_BATCH")
regranted_payload=$(<"$REGRANTED_BATCH")
regranted_generation=$(
	python3 - "$regranted_result" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["key_generation"])
PY
)
assert_eq "regrant wraps the next generation to owner and replacement device" \
	"$(
		python3 - "$regranted_result" <<'PY'
import json
import sys
print(json.loads(sys.argv[1])["recipients"])
PY
	)" "2"
assert_absent "replacement transport excludes the revoked device key" \
	"$regranted_payload" "$bob_device"
assert_eq "replacement transport includes the newly granted device key" \
	"$([[ "$regranted_payload" == *"$bob_rotated_device"* ]] && printf present || printf absent)" \
	"present"
expect_failure "replaced device keys cannot unwrap later generations" \
	"sharing device grant is inactive" \
	"$HELPER" share-import --base "$BOB_BASE" --vault-dir "$BOB_OLD_VAULT" \
	--alias workspace:alpha --sender "$ALICE_ID" --batch "$REGRANTED_BATCH"
set_share_generation "$BOB_BASE" 1
expect_failure "future generations require signed local grant-state convergence" \
	"stale or has unapplied grant state" \
	"$HELPER" share-import --base "$BOB_BASE" --vault-dir "$BOB_VAULT" \
	--alias workspace:alpha --sender "$ALICE_ID" --batch "$REGRANTED_BATCH"
set_share_generation "$BOB_BASE" "$regranted_generation"
"$HELPER" share-import --base "$BOB_BASE" --vault-dir "$BOB_VAULT" \
	--alias workspace:alpha --sender "$ALICE_ID" --batch "$REGRANTED_BATCH" >/dev/null
assert_eq "owner principal remains distinct from revoked member" \
	"$([[ "$alice_principal" != "$bob_principal" ]] && printf distinct || printf same)" "distinct"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
