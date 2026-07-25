#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-operations.sh — Approval-bound social operation tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
VAULT_PYTHON="${HOME}/.aidevops/.agent-workspace/python-env/vault/bin/python3"
export PYTHONPATH="${SCRIPT_DIR}/../scripts"
TMP_DIR=$(mktemp -d)
BASE="${TMP_DIR}/knowledge"
ROOT="${BASE}/_knowledge"
RESTORE_ROOT="${TMP_DIR}/restored"
MIGRATION_BASE="${TMP_DIR}/migration"
MIGRATION_ROOT="${MIGRATION_BASE}/_knowledge"
FAKE_BIN="${TMP_DIR}/bin"
XURL_LOG="${TMP_DIR}/xurl.log"
ARCHIVE="${TMP_DIR}/archive.json"
POST_BODY="${TMP_DIR}/post.txt"
REPLY_BODY="${TMP_DIR}/reply.txt"
OPTION_BODY="${TMP_DIR}/option.txt"
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

assert_contains() {
	local description="$1"
	local actual="$2"
	local expected="$3"
	if [[ "$actual" == *"$expected"* ]]; then
		assert_eq "$description" "present" "present"
	else
		assert_eq "$description" "absent" "present"
	fi
	return 0
}

assert_absent() {
	local description="$1"
	local actual="$2"
	local forbidden="$3"
	if [[ "$actual" == *"$forbidden"* ]]; then
		assert_eq "$description" "present" "absent"
	else
		assert_eq "$description" "absent" "absent"
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
	else
		assert_contains "$description" "$output" "$expected"
	fi
	return 0
}

json_field() {
	local payload="$1"
	local field="$2"
	python3 -c 'import json,sys; print(json.loads(sys.argv[1])[sys.argv[2]])' \
		"$payload" "$field"
	return 0
}

sql_value() {
	local database="$1"
	local query="$2"
	python3 - "$database" "$query" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    print(connection.execute(sys.argv[2]).fetchone()[0])
PY
	return 0
}

log_count() {
	local needle="$1"
	python3 - "$XURL_LOG" "$needle" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
print(sum(sys.argv[2] in line for line in lines))
PY
	return 0
}

create_and_approve() {
	local operation_id="$1"
	local action="$2"
	local target_id="$3"
	local body_file="$4"
	local arguments=(
		operation-create --base "$BASE" --connection-id conn_ops
		--account-id acct42 --action "$action" --scheduled-at 1000
		--operation-id "$operation_id" --app fixture-app --username fixture-user
		--now-epoch 1000
	)
	if [[ "$target_id" != "none" ]]; then
		arguments+=(--target-id "$target_id")
	fi
	if [[ "$body_file" != "none" ]]; then
		arguments+=(--body-file "$body_file")
	fi
	"$HELPER" "${arguments[@]}" >/dev/null
	"$HELPER" operation-approve --base "$BASE" --operation-id "$operation_id" \
		--expires-at 2000 --now-epoch 1000 >/dev/null
	return 0
}

mkdir -p "$ROOT" "$FAKE_BIN" "$RESTORE_ROOT" "$MIGRATION_ROOT"
chmod 0700 "$BASE" "$ROOT" "$FAKE_BIN" "$RESTORE_ROOT" \
	"$MIGRATION_BASE" "$MIGRATION_ROOT"
: >"$XURL_LOG"
chmod 0600 "$XURL_LOG"

cat >"${FAKE_BIN}/xurl" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${XURL_LOG:?}"
case " $* " in
*" whoami "*)
	if [[ "${XURL_MODE:-success}" == "identity-mismatch" ]]; then
		printf '%s\n' '{"data":{"id":"acct_other"}}'
	else
		printf '%s\n' '{"data":{"id":"acct42"}}'
	fi
	exit 0
	;;
esac
if [[ -n "${XURL_DELAY:-}" ]]; then
	sleep "$XURL_DELAY"
fi
case "${XURL_MODE:-success}" in
write-fail)
	printf '%s\n' '{"status":503}'
	exit 1
	;;
invalid-output)
	printf '%s\n' 'not-json'
	exit 0
	;;
status-error)
	printf '%s\n' '{"status":403}'
	exit 0
	;;
*)
	printf '%s\n' '{"data":{"id":"post_created_001"}}'
	exit 0
	;;
esac
FAKE
chmod 0700 "${FAKE_BIN}/xurl"
export XURL_LOG
export PATH="${FAKE_BIN}:${PATH}"

cat >"$ARCHIVE" <<'JSON'
{
  "provider": "xapi",
  "connection_id": "conn_ops",
  "remote_account_id": "acct42",
  "exported_at": "2026-07-25T12:00:00Z",
  "enabled_streams": ["mentions"],
  "policy": {},
  "accounts": [
    {"remote_id":"acct42","observed_at":"2026-07-25T12:00:00Z"},
    {"remote_id":"acct_other","observed_at":"2026-07-25T12:00:00Z"}
  ],
  "objects": [
    {
      "object_type":"post","remote_id":"post_mention_001",
      "account_remote_id":"acct_other","text":"mention fixture marker",
      "observed_at":"2026-07-25T12:00:00Z","evidence_class":"observed",
      "provider_json":{}
    },
    {
      "object_type":"post","remote_id":"post_reply_001",
      "account_remote_id":"acct_other","text":"reply fixture marker",
      "observed_at":"2026-07-25T12:01:00Z","evidence_class":"observed",
      "provider_json":{"referenced_tweets":[{"type":"replied_to","id":"post_parent_001"}]}
    }
  ],
  "activities": [
    {
      "activity_type":"mentions","remote_id":"activity_mention_001",
      "actor_remote_id":"acct_other","object_remote_id":"post_mention_001",
      "observed_at":"2026-07-25T12:00:00Z","state":"active"
    },
    {
      "activity_type":"mentions","remote_id":"activity_reply_001",
      "actor_remote_id":"acct_other","object_remote_id":"post_reply_001",
      "observed_at":"2026-07-25T12:01:00Z","state":"active"
    }
  ],
  "media": [],
  "coverage": []
}
JSON
printf '%s\n' 'private post fixture marker' >"$POST_BODY"
printf '%s\n' 'private reply fixture marker' >"$REPLY_BODY"
printf '%s' '--app' >"$OPTION_BODY"
chmod 0600 "$ARCHIVE" "$POST_BODY" "$REPLY_BODY" "$OPTION_BODY"

printf 'Approval-bound social operations tests\n'
"$CORPUS_HELPER" provision --base "$MIGRATION_BASE" >/dev/null
"$HELPER" provision --base "$MIGRATION_BASE" >/dev/null
python3 - "$MIGRATION_ROOT/index/social.db" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as database:
    database.execute("DROP TABLE notification_state")
    database.execute("DROP TABLE outbound_attempts")
    database.execute("DROP TABLE outbound_approvals")
    database.execute("DROP TABLE outbound_operations")
    database.execute("DELETE FROM schema_meta WHERE version=3")
    database.execute("PRAGMA user_version=2")
PY
"$HELPER" provision --base "$MIGRATION_BASE" >/dev/null
assert_eq "schema v2 migrates additively to all local operation tables" \
	"$(sql_value "$MIGRATION_ROOT/index/social.db" "SELECT (SELECT user_version FROM pragma_user_version) || ':' || count(*) FROM sqlite_master WHERE name IN ('outbound_operations','outbound_approvals','outbound_attempts','notification_state')")" \
	"3:4"

"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$HELPER" provision --base "$BASE" >/dev/null
"$HELPER" import-archive --base "$BASE" --archive "$ARCHIVE" >/dev/null

create_result=$("$HELPER" operation-create --base "$BASE" \
	--connection-id conn_ops --account-id acct42 --action post \
	--body-file "$POST_BODY" --scheduled-at 1000 --operation-id op_post_001 \
	--app fixture-app --username fixture-user --now-epoch 1000)
assert_eq "draft creation returns no private body" \
	"$([[ "$create_result" == *"private post"* ]] && printf leaked || printf private)" "private"
assert_eq "draft creation records the approved action" \
	"$(json_field "$create_result" action)" "post"

duplicate_result=$("$HELPER" operation-create --base "$BASE" \
	--connection-id conn_ops --account-id acct42 --action post \
	--body-file "$POST_BODY" --scheduled-at 1000 --operation-id op_post_001 \
	--app fixture-app --username fixture-user --now-epoch 1000)
assert_eq "matching operation IDs recover idempotently" \
	"$(json_field "$duplicate_result" state)" "draft"
printf '%s\n' 'substituted fixture body' >"$POST_BODY"
expect_failure "operation IDs reject payload substitution" "another intent" \
	"$HELPER" operation-create --base "$BASE" --connection-id conn_ops \
	--account-id acct42 --action post --body-file "$POST_BODY" --scheduled-at 1000 \
	--operation-id op_post_001 --app fixture-app --username fixture-user --now-epoch 1000
printf '%s\n' 'private post fixture marker' >"$POST_BODY"

"$HELPER" operation-approve --base "$BASE" --operation-id op_post_001 \
	--expires-at 2000 --now-epoch 1000 >/dev/null
"$HELPER" operation-approve --base "$BASE" --operation-id op_post_001 \
	--expires-at 1500 --now-epoch 1100 >/dev/null
assert_eq "reapproval replaces authority with the exact requested expiry" \
	"$(sql_value "$ROOT/index/social.db" "SELECT count(*) || ':' || max(expires_at) FROM outbound_approvals WHERE operation_id='op_post_001' AND revoked_at IS NULL")" \
	"1:1500"

post_result=$("$HELPER" operation-run --base "$BASE" --operation-id op_post_001 \
	--executor-id exe_post_001 --claim-seconds 300 --now-epoch 1200)
assert_eq "approved immediate posts reach one successful receipt" \
	"$(json_field "$post_result" state)" "succeeded"
assert_absent "post receipts omit private text" "$post_result" "private post fixture marker"
assert_absent "post receipts omit local profile selectors" "$post_result" "fixture-app"
assert_eq "provider start is durable before success" \
	"$(sql_value "$ROOT/index/social.db" "SELECT count(*) FROM outbound_attempts WHERE operation_id='op_post_001' AND provider_started_at IS NOT NULL AND status='succeeded'")" "1"
assert_eq "post executes once through the mapped helper" \
	"$(log_count ' post private post fixture marker')" "1"

create_and_approve op_option_body post none "$OPTION_BODY"
option_result=$("$HELPER" operation-run --base "$BASE" \
	--operation-id op_option_body --executor-id exe_option_body --now-epoch 1200)
assert_eq "option-shaped body text cannot alter approved profile selection" \
	"$(json_field "$option_result" state)" "succeeded"
assert_eq "option-shaped body reaches xurl as post content" \
	"$(log_count ' post --app')" "1"

create_and_approve op_reply_001 reply post_target_001 "$REPLY_BODY"
create_and_approve op_like_001 like post_target_002 none
create_and_approve op_bookmark_001 bookmark post_target_003 none
due_result=$("$HELPER" operations-run-due --base "$BASE" --executor-id exe_due_001 \
	--limit 10 --claim-seconds 300 --now-epoch 1200)
assert_eq "reply, like, and bookmark share one due queue" \
	"$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])["results"]))' "$due_result")" "3"
assert_eq "all mapped due actions succeed" \
	"$(python3 -c 'import json,sys; print(all(row["state"] == "succeeded" for row in json.loads(sys.argv[1])["results"]))' "$due_result")" "True"
assert_eq "reply mapping preserves target and private body" \
	"$(log_count ' reply post_target_001 private reply fixture marker')" "1"
assert_eq "like mapping executes once" "$(log_count ' like post_target_002')" "1"
assert_eq "bookmark mapping executes once" "$(log_count ' bookmark post_target_003')" "1"

create_and_approve op_identity_001 like post_target_004 none
identity_result=$(XURL_MODE=identity-mismatch "$HELPER" operation-run --base "$BASE" \
	--operation-id op_identity_001 --executor-id exe_identity_001 --now-epoch 1200)
assert_eq "identity mismatch is terminal before provider execution" \
	"$(json_field "$identity_result" state):$(json_field "$identity_result" failure_class)" \
	"failed:identity"
assert_eq "identity mismatch performs no like" "$(log_count ' like post_target_004')" "0"

create_and_approve op_unknown_001 like post_target_005 none
unknown_result=$(XURL_MODE=write-fail "$HELPER" operation-run --base "$BASE" \
	--operation-id op_unknown_001 --executor-id exe_unknown_001 --now-epoch 1200)
assert_eq "post-invocation non-zero outcomes are ambiguous" \
	"$(json_field "$unknown_result" state)" "unknown"
unknown_writes=$(log_count ' like post_target_005')
expect_failure "unknown outcomes cannot be blindly rerun" "not due and approved" \
	"$HELPER" operation-run --base "$BASE" --operation-id op_unknown_001 \
	--executor-id exe_unknown_002 --now-epoch 1300
assert_eq "blocked retry makes no second provider write" \
	"$(log_count ' like post_target_005')" "$unknown_writes"
reconciled=$("$HELPER" operation-reconcile --base "$BASE" \
	--operation-id op_unknown_001 --outcome not-sent --now-epoch 1300)
assert_eq "unknown outcomes require explicit reconciliation" \
	"$(json_field "$reconciled" state)" "failed"

create_and_approve op_status_001 like post_target_status none
status_result=$(XURL_MODE=status-error "$HELPER" operation-run --base "$BASE" \
	--operation-id op_status_001 --executor-id exe_status_001 --now-epoch 1200)
assert_eq "provider error JSON cannot masquerade as engagement success" \
	"$(json_field "$status_result" state)" "unknown"

create_and_approve op_cancel_001 bookmark post_target_006 none
"$HELPER" operation-revoke --base "$BASE" --operation-id op_cancel_001 \
	--now-epoch 1100 >/dev/null
assert_eq "revocation returns approved work to a non-due draft" \
	"$(sql_value "$ROOT/index/social.db" "SELECT state FROM outbound_operations WHERE operation_id='op_cancel_001'")" "draft"
"$HELPER" operation-cancel --base "$BASE" --operation-id op_cancel_001 \
	--now-epoch 1200 >/dev/null
assert_eq "cancelled work remains terminal without an attempt" \
	"$(sql_value "$ROOT/index/social.db" "SELECT state || ':' || (SELECT count(*) FROM outbound_attempts WHERE operation_id='op_cancel_001') FROM outbound_operations WHERE operation_id='op_cancel_001'")" \
	"cancelled:0"

python3 - "$BASE" "$ROOT" <<'PY'
import json
import sqlite3
import sys
from pathlib import Path

from _knowledge_social_outbound import (
    OperationIntent,
    approve_operation,
    create_operation,
)
from _knowledge_social_outbound_runtime import (
    AttemptOutcome,
    ClaimRequest,
    claim_operation,
    due_operation_ids,
    expire_claims,
    finalize_operation,
    mark_provider_started,
)
from knowledge_social_store import SocialStoreError, connect, migrate

base = Path(sys.argv[1])
root = Path(sys.argv[2])
principal = json.loads((base / "_config" / "principal.json").read_text())["principal_id"]
database = connect(root)
migrate(database)


def rejected(callback):
    try:
        callback()
    except (SocialStoreError, sqlite3.IntegrityError):
        return
    raise AssertionError("unsafe outbound state mutation was accepted")


def intent(
    operation_id,
    target_remote_id,
    action="like",
    payload=None,
    app_profile=None,
    username=None,
):
    return OperationIntent(
        connection_id="conn_ops",
        remote_account_id="acct42",
        action=action,
        target_remote_id=target_remote_id,
        payload=payload,
        app_profile=app_profile,
        username=username,
        scheduled_at=1000,
        created_by=principal,
        operation_id=operation_id,
        created_at=1000,
    )


tampering = (
    ("payload", "changed body"),
    ("connection_id", "conn_other"),
    ("remote_account_id", "acct_other"),
    ("target_remote_id", "post_changed_001"),
    ("app_profile", "changed-profile"),
    ("username", "changed-user"),
    ("scheduled_at", 999),
)
for index, (field, value) in enumerate(tampering):
    operation_id = f"op_tamper_{index:03d}"
    create_operation(
        database,
        intent(
            operation_id,
            "post_original_001",
            action="reply",
            payload="bound fixture body",
            app_profile="fixture-app",
            username="fixture-user",
        ),
    )
    approve_operation(database, operation_id, principal, 2000, approved_at=1000)
    database.execute(f"UPDATE outbound_operations SET {field}=? WHERE operation_id=?", (value, operation_id))
    rejected(lambda: due_operation_ids(database, principal, 1200, 100))
    database.execute(
        "UPDATE outbound_operations SET state='cancelled' WHERE operation_id=?",
        (operation_id,),
    )

create_operation(
    database,
    intent("op_tamper_action", "post_action_001"),
)
approve_operation(database, "op_tamper_action", principal, 2000, approved_at=1000)
database.execute("UPDATE outbound_operations SET action='bookmark' WHERE operation_id='op_tamper_action'")
rejected(lambda: due_operation_ids(database, principal, 1200, 100))
database.execute(
    "UPDATE outbound_operations SET state='cancelled' WHERE operation_id='op_tamper_action'"
)

create_operation(
    database,
    intent("op_approval_expired", "post_approval_expired"),
)
approve_operation(database, "op_approval_expired", principal, 1100, approved_at=1000)
assert due_operation_ids(database, principal, 1100, 100) == []
rejected(
    lambda: claim_operation(
        database,
        ClaimRequest(
            "op_approval_expired", principal, "exe_approval_expired", 1100, 300
        ),
    )
)

create_operation(
    database,
    intent("op_boundary_expired", "post_boundary_expired"),
)
approve_operation(database, "op_boundary_expired", principal, 1101, approved_at=1000)
boundary = claim_operation(
    database,
    ClaimRequest("op_boundary_expired", principal, "exe_boundary", 1100, 300),
)
rejected(
    lambda: mark_provider_started(database, boundary, "exe_boundary", started_at=1101)
)
finalize_operation(
    database,
    boundary,
    "exe_boundary",
    AttemptOutcome("failed", failure_class="authorization", finished_at=1101),
)

create_operation(
    database,
    intent("op_expired_claim", "post_expired_claim"),
)
approve_operation(database, "op_expired_claim", principal, 2000, approved_at=1000)
claimed = claim_operation(
    database, ClaimRequest("op_expired_claim", principal, "exe_expired", 1100, 1)
)
assert expire_claims(database, principal, 1101, 10) == ["op_expired_claim"]
rejected(
    lambda: finalize_operation(
        database,
        claimed,
        "exe_expired",
        AttemptOutcome("failed", failure_class="runtime", finished_at=1102),
    )
)

create_operation(
    database,
    intent("op_started_001", "post_started_001"),
)
approve_operation(database, "op_started_001", principal, 2000, approved_at=1000)
started = claim_operation(
    database, ClaimRequest("op_started_001", principal, "exe_started", 1100, 300)
)
mark_provider_started(database, started, "exe_started", started_at=1101)
rejected(
    lambda: finalize_operation(
        database,
        started,
        "exe_started",
        AttemptOutcome("failed", failure_class="runtime", finished_at=1102),
    )
)
finalize_operation(
    database,
    started,
    "exe_started",
    AttemptOutcome(
        "unknown", failure_class="provider_unavailable", finished_at=1102
    ),
)
database.close()
PY
assert_eq "tampering, fencing, and ambiguous-outcome state checks pass" "verified" "verified"

create_and_approve op_race_001 like post_target_race none
race_before=$(log_count ' like post_target_race')
set +e
XURL_DELAY=1 "$HELPER" operation-run --base "$BASE" --operation-id op_race_001 \
	--executor-id exe_race_a --now-epoch 1200 >"${TMP_DIR}/race-a.out" 2>&1 &
race_a=$!
XURL_DELAY=1 "$HELPER" operation-run --base "$BASE" --operation-id op_race_001 \
	--executor-id exe_race_b --now-epoch 1200 >"${TMP_DIR}/race-b.out" 2>&1 &
race_b=$!
wait "$race_a"
race_a_status=$?
wait "$race_b"
race_b_status=$?
set -e
race_after=$(log_count ' like post_target_race')
assert_eq "concurrent runners make at most one provider attempt" \
	"$((race_after - race_before))" "1"
assert_eq "exactly one concurrent runner owns the claim" \
	"$((race_a_status + race_b_status > 0 ? 1 : 0))" "1"

refresh_result=$("$HELPER" notifications-refresh --base "$BASE" --now-epoch 1200)
assert_eq "mention/reply projection creates two notifications" \
	"$(json_field "$refresh_result" inserted)" "2"
second_refresh=$("$HELPER" notifications-refresh --base "$BASE" --now-epoch 1300)
assert_eq "notification projection is idempotent" \
	"$(json_field "$second_refresh" inserted)" "0"
notifications=$("$HELPER" notifications-list --base "$BASE")
assert_eq "notification kinds distinguish mentions and replies" \
	"$(python3 -c 'import json,sys; print(",".join(sorted(row["kind"] for row in json.loads(sys.argv[1]))))' "$notifications")" \
	"mention,reply"
assert_absent "notification listings omit private content" "$notifications" "fixture marker"
assert_absent "notification listings omit actor IDs" "$notifications" "acct_other"
notification_id=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])[0]["notification_id"])' "$notifications")
"$HELPER" notification-set --base "$BASE" --notification-id "$notification_id" \
	--status seen --now-epoch 1300 >/dev/null
"$HELPER" notification-set --base "$BASE" --notification-id "$notification_id" \
	--status responded --now-epoch 1301 >/dev/null
"$HELPER" notifications-refresh --base "$BASE" --now-epoch 1400 >/dev/null
assert_eq "evidence refresh preserves explicit workflow state" \
	"$(sql_value "$ROOT/index/social.db" "SELECT status FROM notification_state WHERE notification_id='${notification_id}'")" \
	"responded"
expect_failure "invalid notification regressions fail closed" "transition is not allowed" \
	"$HELPER" notification-set --base "$BASE" --notification-id "$notification_id" \
	--status seen --now-epoch 1401

python3 - "$BASE/catalog.db" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    connection.execute(
        "UPDATE corpus_grants SET status='inactive' WHERE capability='knowledge.manage'"
    )
PY
expect_failure "ordinary write authority cannot manage shared-account operations" \
	"access denied" "$HELPER" operations-list --base "$BASE"
python3 - "$BASE/catalog.db" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    connection.execute(
        "UPDATE corpus_grants SET status='active' WHERE capability='knowledge.manage'"
    )
PY

if [[ ! -x "$VAULT_PYTHON" ]]; then
	printf 'FAIL: managed Vault Python is unavailable: %s\n' "$VAULT_PYTHON" >&2
	exit 1
fi
"$VAULT_PYTHON" - "$ROOT" "$RESTORE_ROOT" <<'PY'
import json
import sqlite3
import sys
from pathlib import Path

from _knowledge_social_notifications import project_notifications, set_notification_status
from _knowledge_social_outbound import OperationIntent, create_operation
from _knowledge_social_share_data import (
    LOCAL_ONLY_TABLES,
    TABLE_COLUMNS,
    build_snapshot,
    restore_snapshot,
)
from knowledge_social_store import connect, migrate

root = Path(sys.argv[1]).resolve()
restore_root = Path(sys.argv[2]).resolve()
local_only = LOCAL_ONLY_TABLES
assert local_only.isdisjoint(TABLE_COLUMNS)
database = sqlite3.connect(root / "index" / "social.db")
try:
    database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
finally:
    database.close()
workspace_id = "wsp_00000000000000000000000000000001"
corpus_id = "cor_00000000000000000000000000000001"
snapshot = build_snapshot(root, workspace_id, corpus_id)
serialized = json.dumps(snapshot, sort_keys=True)
assert "private post fixture marker" not in serialized
assert "fixture-app" not in serialized
assert local_only.isdisjoint(snapshot["tables"])

restore_snapshot(restore_root, snapshot, workspace_id, corpus_id)
database = connect(restore_root)
migrate(database)
create_operation(
    database,
    OperationIntent(
        connection_id="conn_ops",
        remote_account_id="acct42",
        action="like",
        target_remote_id="post_local_only",
        payload=None,
        app_profile="local-profile",
        username=None,
        scheduled_at=1000,
        created_by="prn_local_owner",
        operation_id="op_local_only",
        created_at=1000,
    ),
)
project_notifications(database, "prn_local_owner", projected_at=1000)
notification = database.execute(
    "SELECT notification_id FROM notification_state ORDER BY notification_id LIMIT 1"
).fetchone()[0]
set_notification_status(
    database,
    "prn_local_owner",
    notification,
    "responded",
    updated_at=1001,
)
database.close()
restore_snapshot(restore_root, snapshot, workspace_id, corpus_id)
with sqlite3.connect(restore_root / "index" / "social.db") as database:
    assert database.execute("SELECT count(*) FROM outbound_operations").fetchone()[0] == 1
    assert database.execute(
        "SELECT status FROM notification_state WHERE notification_id=?", (notification,)
    ).fetchone()[0] == "responded"
PY
assert_eq "sharing excludes and restore preserves owner-local operational state" \
	"verified" "verified"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
