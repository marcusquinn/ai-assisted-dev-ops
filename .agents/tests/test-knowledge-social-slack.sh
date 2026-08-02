#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# test-knowledge-social-slack.sh — Slack API and approved-export collector tests

set -euo pipefail
export AIDEVOPS_TEST_MODE=1
export AIDEVOPS_SOCIAL_NOW_EPOCH=1785524400
export SLACK_FIXTURE_WORKSPACE_ID=T123ABC456
export SLACK_FIXTURE_TOKEN_TYPE=bot
export SLACK_FIXTURE_CONVERSATIONS='{"engineering":{"id":"C123ABC456","kind":"public_channel"}}'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SLACK_ENTRY="${SCRIPT_DIR}/../scripts/knowledge_social_slack.py"
SOCIAL_HELPER="${SCRIPT_DIR}/../scripts/knowledge-social-helper.sh"
CORPUS_HELPER="${SCRIPT_DIR}/../scripts/knowledge-corpus-helper.sh"
FIXTURES="${SCRIPT_DIR}/fixtures/knowledge-social-slack"
ARCHIVE_BUILDER="${SCRIPT_DIR}/fixtures/slack-archive-fixture.py"
TMP_DIR=$(mktemp -d)
BASE="${TMP_DIR}/knowledge"
ROOT="${BASE}/_knowledge"
ACCOUNT_ID="slack_T123ABC456_user_U123ABC456"
MESSAGE_ID="slack_T123ABC456_message_QzEyM0FCQzQ1NjoxNzEwMDAwMDAwLjAwMDAwMQ"
BINDING_HASH="3fcc8f8db59e6e3e71c06f82804df4a43cc456c1283010b6b809874c47136b4c"
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
	python3 - "$ROOT/sources/social/raw/slack" <<'PY'
import sys
from pathlib import Path

root = Path(sys.argv[1])
print(len(list(root.rglob("*.json.gz"))) if root.exists() else 0)
PY
	return 0
}

raw_archive_contains() {
	local connection_id="$1"
	local needle="$2"
	python3 - "$ROOT/sources/social/raw/slack/$connection_id" "$needle" <<'PY'
import gzip
import sys
from pathlib import Path

root = Path(sys.argv[1])
needle = sys.argv[2]
present = False
for path in root.glob("*.json.gz") if root.exists() else ():
    with gzip.open(path, "rt", encoding="utf-8") as source:
        present = present or needle in source.read()
print("present" if present else "absent")
PY
	return 0
}

api_sync() {
	local fixture="$1"
	local connection_id="$2"
	local budget="$3"
	if python3 "$SLACK_ENTRY" api --base "$BASE" --alias personal:default \
		--connection-id "$connection_id" --account-id "$ACCOUNT_ID" \
		--stream conversation/engineering/history --profile fixture \
		--fixture "$fixture" --budget "$budget" --page-size 1; then
		return 0
	fi
	return 1
}

archive_import() {
	local archive="$1"
	local connection_id="$2"
	local exported_at="${3:-2026-07-31T19:04:00Z}"
	if python3 "$SLACK_ENTRY" archive --base "$BASE" --alias personal:default \
		--archive "$archive" --connection-id "$connection_id" \
		--account-id "$ACCOUNT_ID" --profile fixture \
		--exported-at "$exported_at"; then
		return 0
	fi
	return 1
}

expect_archive_failure() {
	local description="$1"
	local archive="$2"
	local connection_id="$3"
	if archive_import "$archive" "$connection_id" >/dev/null 2>&1; then
		assert_eq "$description" accepted rejected
	else
		assert_eq "$description" rejected rejected
	fi
	return 0
}

mkdir -p "$ROOT"
chmod 0700 "$BASE" "$ROOT"
"$CORPUS_HELPER" provision --base "$BASE" >/dev/null
"$SOCIAL_HELPER" provision --base "$BASE" --alias personal:default >/dev/null

printf 'Slack social collector tests\n'

docs_output=$(<"$SCRIPT_DIR/../content/social-slack.md")
if [[ "$docs_output" == *'SLACK_<PROFILE>_CONVERSATIONS='* &&
	"$docs_output" == *'POST bookmarks.list'* ]]; then
	assert_eq "Slack operator guide records profile and read-scope evidence" \
		verified verified
else
	assert_eq "Slack operator guide records profile and read-scope evidence" \
		missing verified
fi

python3 - "$SCRIPT_DIR/../scripts" "$ROOT" <<'PY'
import ast
import io
import json
import os
import sqlite3
import sys
import zipfile
from pathlib import Path

scripts = Path(sys.argv[1])
root = Path(sys.argv[2])
sys.path.insert(0, str(scripts))

from _knowledge_social_collect import (
    CollectionContext,
    ConnectionConfig,
    CursorState,
    PageCheckpoint,
    SuccessfulPage,
)
from _knowledge_social_collect_persist import persist_page
from _knowledge_social_lease import (
    RunLeaseRequest,
    acquire_run_lease,
    release_run_lease,
    renew_run_lease,
)
from _knowledge_social_slack import (
    STREAMS,
    SlackAdapterError,
    page_request,
    parse_stream,
)
from _knowledge_social_slack_contract import (
    ApiResult,
    IdentityBinding,
    SlackReadProviderError,
    identity_value,
)
from _knowledge_social_slack_evidence_guard import reject_slack_credentials
from _knowledge_social_slack_http import (
    HTTP_TIMEOUT_SECONDS,
    READ_METHODS,
    _RejectRedirects,
    api,
)
from _knowledge_social_slack_normalize import (
    API_SOURCE,
    NormalizationBatch,
    PageContext,
    canonical_observed_at,
    normalize_records,
)
from _knowledge_social_slack_provider import load_profile
from _knowledge_social_slack_persist import persist_slack_page
from _knowledge_social_slack_records import message_record, reaction_item_records
from _knowledge_social_slack_routes import page
from _knowledge_social_slack_store import store_ordered_records
import _knowledge_social_slack_zip as slack_zip
from knowledge_social_store import connect, migrate


def must_reject(callback):
    try:
        callback()
    except (SlackAdapterError, SlackReadProviderError):
        return
    raise AssertionError("unsafe Slack operation was accepted")


expected_methods = {
    "auth.test": "POST",
    "team.info": "GET",
    "users.list": "GET",
    "conversations.info": "GET",
    "conversations.members": "GET",
    "conversations.history": "GET",
    "conversations.replies": "GET",
    "pins.list": "GET",
    "bookmarks.list": "POST",
    "files.list": "GET",
    "reactions.list": "GET",
}
assert READ_METHODS == expected_methods
assert set(STREAMS) == {"workspace", "users", "reactions"}
assert "conversation/engineering/history" in STREAMS
assert "conversation/engineering/thread/1710000000.000001" in STREAMS
assert parse_stream("conversation/engineering/files").kind == "files"
assert STREAMS["conversation/engineering/pins"].coverage_status == "partial"
assert STREAMS["conversation/engineering/bookmarks"].coverage_status == "partial"
must_reject(lambda: parse_stream("conversation/engineering/admin"))
assert canonical_observed_at("2026-07-31T19:00:00Z") == (
    "2026-07-31T19:00:00.000000Z"
)
assert canonical_observed_at("2026-07-31T19:00:00Z") < canonical_observed_at(
    "2026-07-31T19:00:00.000001Z"
)
must_reject(lambda: canonical_observed_at("2026-07-31T19:00:00"))
reject_slack_credentials({"text": "discussion of token rotation is allowed"})
token_prefix = "xo" + "xb" + "-"
reject_slack_credentials({"text": token_prefix + "1" * 40})
reject_slack_credentials({"text": token_prefix + "example-placeholder"})
reject_slack_credentials({"text": token_prefix + "1" * 12 + "-" + "a" * 32})
synthetic_token = token_prefix + "123456789012-" + "A1b2C3d4E5f6G7h8" * 2
must_reject(
    lambda: reject_slack_credentials({"text": synthetic_token})
)
must_reject(
    lambda: reject_slack_credentials(
        {
            "text": "https://hooks.slack.com/triggers/"
            + "A" * 12
            + "/"
            + "b" * 32
        }
    )
)
active_token = "fixture-active-secret-" + "1" * 20
must_reject(
    lambda: reject_slack_credentials(
        {"text": f"reflected {active_token}"}, exact_secret=active_token
    )
)

zip_payload = io.BytesIO()
with zipfile.ZipFile(zip_payload, "w") as fixture_zip:
    fixture_zip.writestr("fixture.json", b"{}")
real_zip_file = slack_zip.zipfile.ZipFile
zip_opens = [0]


def counting_zip_file(*args, **kwargs):
    zip_opens[0] += 1
    return real_zip_file(*args, **kwargs)


slack_zip.zipfile.ZipFile = counting_zip_file
try:
    with slack_zip.index_archive(zip_payload.getvalue(), 1024, 2) as zip_index:
        assert zip_index.member_bytes("fixture.json") == b"{}"
        assert zip_index.member_bytes("fixture.json") == b"{}"
finally:
    slack_zip.zipfile.ZipFile = real_zip_file
assert zip_opens == [2]
assert zip_index.archive.fp is None


def ordered_archive(connection_id, label):
    observed_at = "2026-07-31T19:00:20.000000Z"
    account_id = "slack_T123ABC456_user_U123ABC456"
    return {
        "provider": "slack",
        "connection_id": connection_id,
        "remote_account_id": account_id,
        "exported_at": observed_at,
        "enabled_streams": ["workspace"],
        "policy": {},
        "accounts": [
            {
                "remote_id": account_id,
                "handle": label,
                "display_name": label,
                "observed_at": observed_at,
                "provider_json": {"label": label},
            }
        ],
        "objects": [
            {
                "object_type": object_type,
                "remote_id": remote_id,
                "account_remote_id": account_id,
                "text": label,
                "created_at": observed_at,
                "observed_at": observed_at,
                "evidence_class": "observed",
                "provider_json": {"label": label},
            }
            for object_type, remote_id in (
                ("message", "shared-message"),
                ("file", "shared-file"),
            )
        ],
        "activities": [
            {
                "activity_type": "message",
                "remote_id": "shared-activity",
                "actor_remote_id": account_id,
                "object_remote_id": "shared-message",
                "occurred_at": observed_at,
                "observed_at": observed_at,
                "state": "active",
                "provider_json": {"label": label},
            }
        ],
        "media": [
            {
                "remote_id": "shared-file",
                "object_remote_id": "shared-file",
                "content_sha256": None,
                "mime_type": f"text/{label}",
                "byte_size": 1,
                "blob_ref": None,
                "hydration_state": "metadata_only",
            }
        ],
        "coverage": [],
    }


def tie_result(directory, observations):
    directory.mkdir(mode=0o700)
    database = connect(directory)
    try:
        migrate(database)
        for connection_id, label, batch_id in observations:
            store_ordered_records(
                database,
                ordered_archive(connection_id, label),
                batch_id,
                connection_id,
            )
        return (
            database.execute(
                "SELECT handle FROM accounts WHERE provider='slack'"
            ).fetchone()[0],
            tuple(
                database.execute(
                    "SELECT text_content,batch_id FROM objects "
                    "WHERE provider='slack' AND object_type='message'"
                ).fetchone()
            ),
            tuple(
                database.execute(
                    "SELECT json_extract(provider_json,'$.label'),batch_id "
                    "FROM activities WHERE provider='slack'"
                ).fetchone()
            ),
            tuple(
                database.execute(
                    "SELECT mime_type,batch_id FROM media WHERE provider='slack'"
                ).fetchone()
            ),
        )
    finally:
        database.close()


alpha = ("conn_tie_alpha", "alpha", "a" * 64)
beta = ("conn_tie_beta", "beta", "b" * 64)
forward_tie = tie_result(root.parent / "tie-forward", (alpha, beta))
reverse_tie = tie_result(root.parent / "tie-reverse", (beta, alpha))
assert forward_tie == reverse_tie
assert forward_tie == (
    "beta",
    ("beta", "b" * 64),
    ("beta", "b" * 64),
    ("text/beta", "b" * 64),
)

profile = load_profile("fixture", require_token=False)
assert profile.token is None
assert profile.binding == IdentityBinding("T123ABC456", None, "bot")
assert profile.conversations["engineering"].conversation_id == "C123ABC456"
assert profile.conversation_binding_sha256 == (
    "3fcc8f8db59e6e3e71c06f82804df4a43cc456c1283010b6b809874c47136b4c"
)
os.environ["SLACK_FIXTURE_ACCESS_TOKEN"] = "fixture-archive-token"
assert load_profile(
    "fixture", require_token=False, include_token=False
).token is None
os.environ.pop("SLACK_FIXTURE_ACCESS_TOKEN")

direct_account = {
    "id": "slack_T123ABC456_user_U123ABC456",
    "provider_account_id": "U123ABC456",
    "workspace_id": "T123ABC456",
    "enterprise_id": None,
    "token_type": "bot",
    "scopes": ["team:read"],
    "conversation_binding_sha256": profile.conversation_binding_sha256,
    "username": "fixture-user",
    "workspace_name": "Fixture Workspace",
}
direct_config = ConnectionConfig(("workspace",), {"media_hydration": "none"})


def direct_context(connection_id, lease):
    return CollectionContext(
        root,
        connection_id,
        direct_account,
        "workspace",
        "none",
        direct_config,
        CursorState(None, None, False),
        STREAMS["workspace"],
        lease=lease,
        provider="slack",
    )


def direct_archive(connection_id, observed_at):
    return normalize_records(
        [],
        PageContext(
            connection_id,
            direct_account,
            "workspace",
            direct_config.enabled_streams,
            direct_config.policy,
        ),
        NormalizationBatch(observed_at, API_SOURCE),
    )


credential_connection = "conn_direct_credential"
credential_lease = acquire_run_lease(
    root,
    RunLeaseRequest(
        credential_connection, "workspace", "direct_credential", "sync", 300
    ),
)
credential_time = "2026-07-31T19:00:30.000000Z"
try:
    must_reject(
        lambda: persist_slack_page(
            direct_context(credential_connection, credential_lease),
            SuccessfulPage(
                {
                    "status": 200,
                    "observed_at": credential_time,
                    "data": [{"text": synthetic_token}],
                },
                "direct-credential-boundary",
                direct_archive(credential_connection, credential_time),
                PageCheckpoint(None, None),
                True,
                2,
            ),
        )
    )
finally:
    assert release_run_lease(root, credential_lease)

rollback_connection = "conn_direct_rollback"
rollback_lease = acquire_run_lease(
    root,
    RunLeaseRequest(
        rollback_connection, "workspace", "direct_rollback", "sync", 300
    ),
)
rollback_time = "2026-07-31T19:00:31.000000Z"
malformed_archive = direct_archive(rollback_connection, rollback_time)
del malformed_archive["objects"]
try:
    persist_slack_page(
        direct_context(rollback_connection, rollback_lease),
        SuccessfulPage(
            {"status": 200, "observed_at": rollback_time, "data": []},
            "direct-rollback-boundary",
            malformed_archive,
            PageCheckpoint(None, None),
            True,
            2,
        ),
    )
except KeyError:
    pass
else:
    raise AssertionError("malformed Slack page unexpectedly persisted")
finally:
    assert release_run_lease(root, rollback_lease)

for connection_id in (credential_connection, rollback_connection):
    raw_root = root / "sources" / "social" / "raw" / "slack" / connection_id
    assert not list(raw_root.glob("*.json.gz")) if raw_root.exists() else True
with sqlite3.connect(root / "index" / "social.db") as database:
    assert database.execute(
        "SELECT count(*) FROM fetch_batches WHERE connection_id IN (?,?)",
        (credential_connection, rollback_connection),
    ).fetchone()[0] == 0

reaction_file = {
    "type": "file",
    "file": {
        "id": "F123ABC456",
        "user": "U123ABC456",
        "channels": ["C999ABC456"],
        "groups": [],
        "ims": [],
    },
}
assert reaction_item_records(
    reaction_file, "T123ABC456", frozenset({"C123ABC456"})
) == []
reaction_file["file"]["channels"] = ["C123ABC456"]
assert len(
    reaction_item_records(
        reaction_file, "T123ABC456", frozenset({"C123ABC456"})
    )
) == 1
reaction_file["file"]["channels"] = "C123ABC456"
must_reject(
    lambda: reaction_item_records(
        reaction_file, "T123ABC456", frozenset({"C123ABC456"})
    )
)
must_reject(
    lambda: reaction_item_records(
        {
            "type": "message",
            "channel": "C123ABC456",
            "message": {
                "type": "message",
                "user": "U123ABC456",
                "text": "bounded reactions",
                "ts": "1710000000.000001",
                "reactions": [
                    {
                        "name": "eyes",
                        "count": 101,
                        "users": ["U123ABC456"] * 101,
                    }
                ],
            },
        },
        "T123ABC456",
        frozenset({"C123ABC456"}),
    )
)
edited_message = message_record(
    {
        "type": "message",
        "user": "U123ABC456",
        "text": "edited message",
        "ts": "1710000000.000001",
        "edited": {"user": "U999ABC456", "ts": "1710000001.000001"},
    },
    "T123ABC456",
    "C123ABC456",
)[0]
assert edited_message["state"] == "edited"
assert edited_message["editor_remote_id"] == (
    "slack_T123ABC456_user_U999ABC456"
)

account = {
    "id": "slack_T123ABC456_user_U123ABC456",
    "provider_account_id": "U123ABC456",
    "workspace_id": "T123ABC456",
    "enterprise_id": None,
    "token_type": "bot",
    "scopes": ["files:read"],
    "conversation_binding_sha256": profile.conversation_binding_sha256,
}
tombstoned = normalize_records(
    [
        {
            "kind": "file",
            "remote_id": "slack_T123ABC456_file_RjEyM0FCQzQ1Ng",
            "actor_remote_id": account["id"],
            "is_tombstoned": True,
        }
    ],
    PageContext(
        "conn_tombstone",
        account,
        "conversation/engineering/files",
        ("conversation/engineering/files",),
        {},
    ),
    NormalizationBatch("2026-07-31T19:00:00Z", API_SOURCE),
)
assert tombstoned["activities"][0]["state"] == "deleted"
incremental = page_request(
    "conversation/engineering/history",
    account,
    CursorState(None, "1710000000.000001", True),
    1,
)
assert incremental.oldest == "1709395200.000001"
thread = page_request(
    "conversation/engineering/thread/1710000000.000001",
    account,
    CursorState(None, None, False),
    1,
)
assert thread.selector == "thread" and thread.thread_ts == "1710000000.000001"


class Response:
    def __init__(self, payload, scopes=None, status=200, retry_after=None):
        self.payload = json.dumps(payload).encode("utf-8")
        self.status = status
        self.headers = {}
        if scopes is not None:
            self.headers["X-OAuth-Scopes"] = scopes
        if retry_after is not None:
            self.headers["Retry-After"] = retry_after

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return None

    def read(self, size=-1):
        return self.payload[:size] if size >= 0 else self.payload


class Opener:
    def __init__(self, response):
        self.response = response
        self.requests = []

    def open(self, request, timeout):
        assert timeout == HTTP_TIMEOUT_SECONDS
        assert "fixture-read-token" not in request.full_url
        self.requests.append(request)
        return self.response


team_opener = Opener(Response({"ok": True, "team": {}}, "team:read"))
team_result = api("fixture-read-token", team_opener, "team.info", {})
assert team_result.status == 200
assert team_opener.requests[0].method == "GET"
assert team_opener.requests[0].data is None
assert team_opener.requests[0].headers["Authorization"] == "Bearer fixture-read-token"

bookmark_opener = Opener(Response({"ok": True, "bookmarks": []}, "bookmarks:read"))
api(
    "fixture-read-token",
    bookmark_opener,
    "bookmarks.list",
    {"channel_id": "C123ABC456"},
)
assert bookmark_opener.requests[0].method == "POST"
assert bookmark_opener.requests[0].data == b"channel_id=C123ABC456"

must_reject(
    lambda: api(
        "fixture-read-token",
        Opener(Response({"ok": True}, "chat:write")),
        "auth.test",
        {},
    )
)
must_reject(
    lambda: api(
        "fixture-read-token",
        Opener(Response({"ok": True})),
        "auth.test",
        {},
    )
)
must_reject(
    lambda: api(
        "fixture-read-token",
        Opener(Response({"ok": True}, "team:read")),
        "chat.postMessage",
        {},
    )
)
rate = api(
    "fixture-read-token",
    Opener(Response({"ok": False, "error": "ratelimited"}, status=429, retry_after="30")),
    "team.info",
    {},
)
assert rate.status == 429 and rate.retry_after == "30"
assert (
    _RejectRedirects().redirect_request(None, None, 302, "moved", {}, "https://example.invalid")
    is None
)

identity = identity_value(
    {
        "ok": True,
        "team_id": "T123ABC456",
        "user_id": "U123ABC456",
        "bot_id": "B123ABC456",
    },
    account["id"],
    profile.binding,
    frozenset({"channels:history"}),
)
assert identity["id"] == account["id"]
must_reject(
    lambda: identity_value(
        {
            "ok": True,
            "team_id": "T123ABC456",
            "user_id": "U999ABC456",
            "bot_id": "B123ABC456",
        },
        account["id"],
        profile.binding,
        frozenset({"channels:history"}),
    )
)


def history_api(endpoint, params):
    assert endpoint == "conversations.history"
    assert params == {
        "channel": "C123ABC456",
        "limit": "1",
        "oldest": "1709395200.000001",
        "inclusive": "true",
    }
    return ApiResult(
        200,
        {
            "ok": True,
            "messages": [
                {
                    "type": "message",
                    "user": "U123ABC456",
                    "text": "bounded route fixture",
                    "ts": "1710000000.000001",
                }
            ],
            "response_metadata": {"next_cursor": ""},
        },
        frozenset({"channels:history"}),
    )


routed = page(
    history_api,
    incremental,
    {**identity, "scopes": ["channels:history"]},
    profile.conversations,
)
assert routed["data"][0]["remote_id"] == (
    "slack_T123ABC456_message_QzEyM0FCQzQ1NjoxNzEwMDAwMDAwLjAwMDAwMQ"
)
must_reject(
    lambda: page(
        history_api,
        incremental,
        {**identity, "scopes": ["channels:history"]},
        {},
    )
)


def run_route(stream, scope, endpoint, payload):
    request = page_request(stream, account, CursorState(None, None, False), 1)
    calls = []

    def route_api(actual_endpoint, params):
        calls.append((actual_endpoint, params))
        return ApiResult(200, payload, frozenset({scope}))

    result = page(
        route_api,
        request,
        {**identity, "scopes": [scope]},
        profile.conversations,
    )
    assert calls and calls[0][0] == endpoint
    return result


workspace = run_route(
    "workspace",
    "team:read",
    "team.info",
    {"ok": True, "team": {"id": "T123ABC456", "name": "Fixture"}},
)
assert workspace["data"][0]["kind"] == "workspace"
users = run_route(
    "users",
    "users:read",
    "users.list",
    {
        "ok": True,
        "members": [
            {
                "id": "U123ABC456",
                "name": "fixture-user",
                "profile": {"display_name": "Fixture User"},
            }
        ],
        "response_metadata": {"next_cursor": ""},
    },
)
assert users["data"][0]["kind"] == "user"
reactions = run_route(
    "reactions",
    "reactions:read",
    "reactions.list",
    {
        "ok": True,
        "items": [
            {
                "type": "message",
                "channel": "C123ABC456",
                "message": {
                    "user": "U123ABC456",
                    "text": "Reaction fixture",
                    "ts": "1710000000.000001",
                },
            }
        ],
        "response_metadata": {"next_cursor": ""},
    },
)
assert reactions["data"][0]["kind"] == "message"
info = run_route(
    "conversation/engineering/info",
    "channels:read",
    "conversations.info",
    {
        "ok": True,
        "channel": {
            "id": "C123ABC456",
            "name": "engineering",
            "is_channel": True,
        },
    },
)
assert info["data"][0]["kind"] == "conversation"
members = run_route(
    "conversation/engineering/members",
    "channels:read",
    "conversations.members",
    {
        "ok": True,
        "members": ["U123ABC456"],
        "response_metadata": {"next_cursor": ""},
    },
)
assert members["data"][0]["kind"] == "membership"
thread_result = run_route(
    "conversation/engineering/thread/1710000000.000001",
    "channels:history",
    "conversations.replies",
    {
        "ok": True,
        "messages": [
            {
                "user": "U123ABC456",
                "text": "Thread fixture",
                "ts": "1710000001.000001",
                "thread_ts": "1710000000.000001",
            }
        ],
        "response_metadata": {"next_cursor": ""},
    },
)
assert thread_result["data"][0]["thread_remote_id"] is not None
must_reject(
    lambda: run_route(
        "conversation/engineering/thread/1710000000.000001",
        "channels:history",
        "conversations.replies",
        {
            "ok": True,
            "messages": [
                {
                    "user": "U123ABC456",
                    "text": "Unrelated thread fixture",
                    "ts": "1710000002.000001",
                    "thread_ts": "1710000009.000001",
                }
            ],
            "response_metadata": {"next_cursor": ""},
        },
    )
)
pins = run_route(
    "conversation/engineering/pins",
    "pins:read",
    "pins.list",
    {
        "ok": True,
        "items": [
            {
                "type": "message",
                "channel": "C123ABC456",
                "message": {
                    "ts": "1710000000.000001",
                    "text": "Pinned fixture",
                },
                "created": 1710000000,
                "created_by": "U123ABC456",
            }
        ],
    },
)
assert pins["data"][0]["kind"] == "pin"
bookmarks = run_route(
    "conversation/engineering/bookmarks",
    "bookmarks:read",
    "bookmarks.list",
    {
        "ok": True,
        "bookmarks": [
            {
                "id": "Bk123ABC456",
                "channel_id": "C123ABC456",
                "title": "Bookmark fixture",
                "type": "link",
                "last_updated_by_user_id": "U123ABC456",
            }
        ],
    },
)
assert bookmarks["data"][0]["kind"] == "bookmark"
files = run_route(
    "conversation/engineering/files",
    "files:read",
    "files.list",
    {
        "ok": True,
        "files": [
            {
                "id": "F123ABC456",
                "user": "U123ABC456",
                "channels": ["C123ABC456"],
                "groups": [],
                "ims": [],
            }
        ],
        "paging": {"page": 1, "pages": 1},
    },
)
assert files["data"][0]["kind"] == "file"
unallowlisted_files = run_route(
    "conversation/engineering/files",
    "files:read",
    "files.list",
    {
        "ok": True,
        "files": [
            {
                "id": "F999ABC456",
                "user": "U123ABC456",
                "channels": ["C999ABC456"],
                "groups": [],
                "ims": [],
            }
        ],
        "paging": {"page": 1, "pages": 1},
    },
)
assert unallowlisted_files["data"] == []
must_reject(
    lambda: page(
        lambda *_args: (_ for _ in ()).throw(AssertionError("unexpected API call")),
        page_request(
            "conversation/engineering/info",
            account,
            CursorState(None, None, False),
            1,
        ),
        {**identity, "scopes": []},
        profile.conversations,
    )
)

public_entry = scripts / "knowledge_social_slack.py"
assert public_entry.is_file()
source_paths = [
    public_entry,
    *sorted(scripts.glob("_knowledge_social_slack*.py")),
]
sources = [path.read_text(encoding="utf-8") for path in source_paths]
trees = [ast.parse(source) for source in sources]
imports = {
    alias.name.split(".")[0]
    for tree in trees
    for node in ast.walk(tree)
    if isinstance(node, (ast.Import, ast.ImportFrom))
    for alias in (
        node.names
        if isinstance(node, ast.Import)
        else [ast.alias(node.module or "")]
    )
}
forbidden_imports = {
    "_knowledge_social_outbound",
    "httpx",
    "knowledge_social_browser",
    "knowledge_social_operations",
    "playwright",
    "requests",
    "selenium",
    "subprocess",
}
assert imports.isdisjoint(forbidden_imports)
forbidden_references = (
    "_knowledge_social_outbound",
    "knowledge_social_browser",
    "knowledge_social_operations",
)
assert all(
    forbidden not in source
    for source in sources
    for forbidden in forbidden_references
)

clock_environment = {
    key: os.environ.pop(key, None)
    for key in ("AIDEVOPS_TEST_MODE", "AIDEVOPS_SOCIAL_NOW_EPOCH")
}
try:
    lease = acquire_run_lease(
        root,
        RunLeaseRequest(
            "conn_real_clock", "archive", "real_clock", "sync", 300
        ),
    )
    lease = renew_run_lease(root, lease, 300)
    real_account = {
        "id": "slack_T123ABC456_user_U123ABC456",
        "provider_account_id": "U123ABC456",
        "workspace_id": "T123ABC456",
        "enterprise_id": None,
        "token_type": "bot",
        "scopes": ["team:read"],
        "conversation_binding_sha256": profile.conversation_binding_sha256,
        "username": "fixture-user",
        "workspace_name": "Fixture Workspace",
    }
    observed_at = "2026-07-31T19:00:00Z"
    config = ConnectionConfig(("workspace",), {"media_hydration": "none"})
    archive = normalize_records(
        [],
        PageContext(
            "conn_real_clock",
            real_account,
            "workspace",
            config.enabled_streams,
            config.policy,
        ),
        NormalizationBatch(observed_at, API_SOURCE),
    )
    persist_page(
        CollectionContext(
            root,
            "conn_real_clock",
            real_account,
            "workspace",
            "none",
            config,
            CursorState(None, None, False),
            STREAMS["workspace"],
            lease=lease,
            provider="slack",
        ),
        SuccessfulPage(
            {"status": 200, "observed_at": observed_at, "data": []},
            "real-clock-regression",
            archive,
            PageCheckpoint(None, None),
            True,
            2,
        ),
    )
    assert release_run_lease(root, lease)
finally:
    for key, value in clock_environment.items():
        if value is not None:
            os.environ[key] = value
PY
assert_eq "methods, scopes, identities, streams, and production clocks are guarded" \
	verified verified

first_result=$(api_sync "$FIXTURES/api-history-page-one.json" conn_history 3)
assert_eq "bounded first history page pauses for its durable cursor" \
	"$(json_field "$first_result" status)" budget_exhausted
assert_eq "identity plus one Slack page consumes three request units" \
	"$(json_field "$first_result" budget_units)" 3
assert_eq "first history page persists an independent cursor and watermark" \
	"$(sql_value "SELECT (cursor IS NOT NULL) || ':' || watermark || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_history' AND stream='conversation/engineering/history'")" \
	"1:1710000000.000001:0"

second_result=$(api_sync "$FIXTURES/api-history-page-two.json" conn_history 3)
assert_eq "second history invocation resumes the exact Slack cursor" \
	"$(json_field "$second_result" status)" complete
assert_eq "completed history preserves its newest high-water mark" \
	"$(sql_value "SELECT coalesce(cursor,'done') || ':' || watermark || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_history' AND stream='conversation/engineering/history'")" \
	"done:1710000000.000001:1"

incremental_result=$(api_sync "$FIXTURES/api-history-incremental.json" conn_history 3)
assert_eq "completed backfill starts a seven-day overlapping refresh" \
	"$(json_field "$incremental_result" status)" complete
assert_eq "overlap refresh updates a stable message rather than duplicating it" \
	"$(sql_value "SELECT count(*) || ':' || text_content FROM objects WHERE provider='slack' AND remote_id='$MESSAGE_ID'")" \
	"1:edited Slack fixture knowledge"
assert_eq "edited Slack evidence emits an explicit edit activity" \
	"$(sql_value "SELECT count(*) FROM activities WHERE provider='slack' AND activity_type='message_edit' AND object_remote_id='$MESSAGE_ID'")" 1
assert_eq "API limitations remain explicit coverage records" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE provider='slack' AND connection_id='conn_history' AND stream LIKE 'api_%'")" 8

python3 - "$FIXTURES/api-history-incremental.json" "$TMP_DIR" <<'PY'
import copy
import json
import sys
from pathlib import Path

with Path(sys.argv[1]).open(encoding="utf-8") as source:
    template = json.load(source)
target = Path(sys.argv[2])
token_prefix = "xo" + "xb" + "-"
synthetic_token = token_prefix + "123456789012-" + "A1b2C3d4E5f6G7h8" * 2
cases = {
    "binding": ("conversation_binding_sha256", "0" * 64),
    "enterprise": ("enterprise_id", "E123ABC456"),
    "token-type": ("token_type", "user"),
}
for name, (field, value) in cases.items():
    payload = copy.deepcopy(template)
    payload["identity"]["data"][field] = value
    with (target / f"api-policy-{name}.json").open("w", encoding="utf-8") as output:
        json.dump(payload, output)
equal_time = copy.deepcopy(template)
equal_time["pages"][0]["response"]["data"][0]["text"] = (
    "conflicting equal-time API fixture knowledge"
)
with (target / "api-equal-time-conflict.json").open("w", encoding="utf-8") as output:
    json.dump(equal_time, output)
credential = copy.deepcopy(template)
credential["pages"][0]["response"]["data"][0]["access_token"] = (
    "fixture-redacted-value"
)
with (target / "api-policy-credential.json").open("w", encoding="utf-8") as output:
    json.dump(credential, output)
scalar_credential = copy.deepcopy(template)
scalar_page = scalar_credential["pages"][0]
scalar_page["expect_request"]["oldest"] = None
scalar_page["response"]["data"][0]["text"] = synthetic_token
with (target / "api-scalar-credential.json").open("w", encoding="utf-8") as output:
    json.dump(scalar_credential, output)
PY
equal_api_raw=$(raw_count)
equal_api_batches=$(sql_value \
	"SELECT count(*) FROM fetch_batches WHERE provider='slack' AND connection_id='conn_history'")
if api_sync "$TMP_DIR/api-equal-time-conflict.json" conn_history 3 \
	>/dev/null 2>&1; then
	assert_eq "conflicting API evidence at one observation timestamp is rejected" \
		accepted rejected
else
	assert_eq "conflicting API evidence at one observation timestamp is rejected" \
		rejected rejected
fi
assert_eq "equal-timestamp API rejection preserves canonical state" \
	"$(sql_value "SELECT text_content FROM objects WHERE provider='slack' AND remote_id='$MESSAGE_ID'")" \
	"edited Slack fixture knowledge"
assert_eq "equal-timestamp API rejection persists no provider evidence" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='slack' AND connection_id='conn_history'"):$(raw_count)" \
	"${equal_api_batches}:${equal_api_raw}"

scalar_api_raw=$(raw_count)
if api_sync "$TMP_DIR/api-scalar-credential.json" conn_scalar_credential 3 \
	>/dev/null 2>&1; then
	assert_eq "Slack token-shaped scalar API evidence is rejected" accepted rejected
else
	assert_eq "Slack token-shaped scalar API evidence is rejected" rejected rejected
fi
assert_eq "scalar API credential rejection persists no provider evidence" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='slack' AND connection_id='conn_scalar_credential'"):$(raw_count)" \
	"0:${scalar_api_raw}"

for policy_case in binding enterprise token-type credential; do
	raw_before=$(raw_count)
	if api_sync "$TMP_DIR/api-policy-${policy_case}.json" conn_history 3 \
		>/dev/null 2>&1; then
		assert_eq "${policy_case} Slack policy change is rejected" accepted rejected
	else
		assert_eq "${policy_case} Slack policy change is rejected" rejected rejected
	fi
	assert_eq "${policy_case} rejection persists no provider evidence" \
		"$(raw_count)" "$raw_before"
done
assert_eq "rejected policy changes preserve the history checkpoint" \
	"$(sql_value "SELECT coalesce(cursor,'done') || ':' || watermark || ':' || backfill_complete FROM sync_cursors WHERE connection_id='conn_history' AND stream='conversation/engineering/history'")" \
	"done:1710000000.000001:1"

cat >"$TMP_DIR/api-identity-mismatch.json" <<'JSON'
{
  "identity": {
    "data": {
      "id": "slack_T123ABC456_user_U999ABC456",
      "provider_account_id": "U999ABC456",
      "workspace_id": "T123ABC456",
      "enterprise_id": null,
      "token_type": "bot",
      "scopes": ["channels:history"],
      "conversation_binding_sha256": "3fcc8f8db59e6e3e71c06f82804df4a43cc456c1283010b6b809874c47136b4c"
    }
  },
  "pages": []
}
JSON
raw_before=$(raw_count)
if api_sync "$TMP_DIR/api-identity-mismatch.json" conn_identity 3 \
	>/dev/null 2>&1; then
	assert_eq "API identity rebinding is rejected" accepted rejected
else
	assert_eq "API identity rebinding is rejected" rejected rejected
fi
assert_eq "identity rejection persists no provider evidence" \
	"$(raw_count)" "$raw_before"

cat >"$TMP_DIR/api-rate-limit.json" <<'JSON'
{
  "identity": {
    "data": {
      "id": "slack_T123ABC456_user_U123ABC456",
      "provider_account_id": "U123ABC456",
      "workspace_id": "T123ABC456",
      "enterprise_id": null,
      "token_type": "bot",
      "scopes": ["channels:history"],
      "conversation_binding_sha256": "3fcc8f8db59e6e3e71c06f82804df4a43cc456c1283010b6b809874c47136b4c"
    }
  },
  "pages": [
    {
      "response": {
        "status": 429,
        "observed_at": "2026-07-31T19:03:00Z",
        "retry_after": "30"
      }
    }
  ]
}
JSON
rate_result=$(api_sync "$TMP_DIR/api-rate-limit.json" conn_rate 3)
assert_eq "Slack rate limits produce a paused terminal result" \
	"$(json_field "$rate_result" status):$(json_field "$rate_result" failure_class)" \
	"rate_limited:rate_limit"
assert_eq "rate-limited streams advance no checkpoint" \
	"$(sql_value "SELECT count(*) FROM sync_cursors WHERE connection_id='conn_rate'")" 0
assert_eq "Slack retry duration persists as an absolute scheduler boundary" \
	"$(sql_value "SELECT retry_after FROM sync_runs WHERE connection_id='conn_rate' ORDER BY rowid DESC LIMIT 1")" \
	1785524430

VALID_ARCHIVE="$TMP_DIR/slack-valid.zip"
CHANGED_ARCHIVE="$TMP_DIR/slack-changed.zip"
STALE_ARCHIVE="$TMP_DIR/slack-stale.zip"
python3 "$ARCHIVE_BUILDER" "$VALID_ARCHIVE" valid
python3 "$ARCHIVE_BUILDER" "$CHANGED_ARCHIVE" changed
python3 "$ARCHIVE_BUILDER" "$STALE_ARCHIVE" stale

raw_before=$(raw_count)
if archive_import "$VALID_ARCHIVE" conn_future 2026-07-31T19:05:01Z \
	>/dev/null 2>&1; then
	assert_eq "future-dated Slack exports are rejected" accepted rejected
else
	assert_eq "future-dated Slack exports are rejected" rejected rejected
fi
assert_eq "future export rejection persists no provider evidence" \
	"$(raw_count)" "$raw_before"

archive_result=$(archive_import "$VALID_ARCHIVE" conn_archive)
assert_eq "approved export persists normalized filtered Slack evidence" \
	"$(json_field "$archive_result" status):$(json_field "$archive_result" normalized_items)" \
	"complete:18"
assert_eq "approved export hashes only four selected source members" \
	"$(json_field "$archive_result" selected_members)" 4
assert_eq "archive persists an immutable token and conversation binding" \
	"$(sql_value "SELECT json_extract(policy_json,'$.slack_token_type') || ':' || json_extract(policy_json,'$.slack_conversation_binding_sha256') FROM connections WHERE connection_id='conn_archive'")" \
	"bot:${BINDING_HASH}"
assert_eq "filtered archive evidence carries its immutable binding" \
	"$(raw_archive_contains conn_archive "$BINDING_HASH")" present
assert_eq "API and export use one canonical message identity" \
	"$(sql_value "SELECT count(*) FROM objects WHERE provider='slack' AND remote_id='$MESSAGE_ID'")" 1
assert_eq "export source wins through the shared canonical projection" \
	"$(sql_value "SELECT json_extract(provider_json,'$.source') FROM objects WHERE provider='slack' AND remote_id='$MESSAGE_ID'")" \
	slack_admin_json_export
assert_eq "selected archive text reaches full-text search" \
	"$(sql_value "SELECT count(*) FROM objects_fts WHERE provider='slack' AND remote_id='$MESSAGE_ID' AND objects_fts MATCH 'bounded'")" 1
assert_eq "archive edits and deletions remain explicit activities" \
	"$(sql_value "SELECT count(*) FROM activities WHERE provider='slack' AND activity_type IN ('message_edit','message_delete') AND json_extract(provider_json,'$.source')='slack_admin_json_export'")" 2
assert_eq "archive reaction actors remain explicit activities" \
	"$(sql_value "SELECT count(*) FROM activities WHERE provider='slack' AND activity_type='reaction' AND object_remote_id='$MESSAGE_ID'")" 1
assert_eq "file binaries remain disabled metadata-only evidence" \
	"$(sql_value "SELECT hydration_state || ':' || coalesce(blob_ref,'none') FROM media WHERE provider='slack'")" \
	"metadata_only:none"
assert_eq "archive scope and retention limits remain explicit" \
	"$(sql_value "SELECT count(*) FROM coverage_records WHERE provider='slack' AND connection_id='conn_archive'")" 9
assert_eq "unallowlisted conversation content is absent from filtered evidence" \
	"$(raw_archive_contains conn_archive must-not-persist-from-unselected-conversation)" absent
assert_eq "unselected user email is absent from filtered evidence" \
	"$(raw_archive_contains conn_archive not-collected@example.invalid)" absent
assert_eq "file credential-bearing links are absent from filtered evidence" \
	"$(raw_archive_contains conn_archive credential-bearing-link)" absent

archive_batches=$(sql_value \
	"SELECT count(*) FROM fetch_batches WHERE provider='slack' AND connection_id='conn_archive' AND stream='archive'")
archive_raw=$(raw_count)
replay_result=$(archive_import "$VALID_ARCHIVE" conn_archive)
assert_eq "exact approved-export replay is idempotent" \
	"$(json_field "$replay_result" replayed)" True
assert_eq "archive replay creates no second batch or raw blob" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='slack' AND connection_id='conn_archive' AND stream='archive'"):$(raw_count)" \
	"${archive_batches}:${archive_raw}"

archive_batch=$(json_field "$archive_result" evidence_sha256)
python3 - "$ROOT/index/social.db" "$archive_batch" 19 <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as database:
    database.execute(
        "UPDATE fetch_batches SET resource_count=? WHERE batch_id=?",
        (int(sys.argv[3]), sys.argv[2]),
    )
PY
replay_metadata_raw=$(raw_count)
if archive_import "$VALID_ARCHIVE" conn_archive >/dev/null 2>&1; then
	assert_eq "archive replay rejects conflicting result metadata" accepted rejected
else
	assert_eq "archive replay rejects conflicting result metadata" rejected rejected
fi
assert_eq "conflicting replay metadata creates no raw evidence" \
	"$(raw_count)" "$replay_metadata_raw"
python3 - "$ROOT/index/social.db" "$archive_batch" 18 <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as database:
    database.execute(
        "UPDATE fetch_batches SET resource_count=? WHERE batch_id=?",
        (int(sys.argv[3]), sys.argv[2]),
    )
PY

renamed_result=$(env SLACK_FIXTURE_CONVERSATIONS='{"renamed":{"id":"C123ABC456","kind":"public_channel"}}' \
	python3 "$SLACK_ENTRY" archive --base "$BASE" --alias personal:default \
	--archive "$VALID_ARCHIVE" --connection-id conn_archive_renamed \
	--account-id "$ACCOUNT_ID" --profile fixture \
	--exported-at 2026-07-31T19:04:00Z)
assert_eq "a newly bound connection does not collide with prior raw evidence" \
	"$(json_field "$renamed_result" status):$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='slack' AND connection_id='conn_archive_renamed'")" \
	"complete:1"

python3 - "$FIXTURES/api-history.json" "$TMP_DIR/api-convergence.json" <<'PY'
import json
import sys
from pathlib import Path

with Path(sys.argv[1]).open(encoding="utf-8") as source:
    payload = json.load(source)
payload["pages"][0]["response"]["observed_at"] = "2026-07-31T19:04:00Z"
with Path(sys.argv[2]).with_name("api-cross-stream-equal.json").open(
    "w", encoding="utf-8"
) as target:
    json.dump(payload, target)
payload["pages"][0]["response"]["observed_at"] = "2026-07-31T19:04:30Z"
with Path(sys.argv[2]).open("w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
cross_stream_raw=$(raw_count)
cross_stream_batches=$(sql_value \
	"SELECT count(*) FROM fetch_batches WHERE provider='slack' AND connection_id='conn_archive'")
if api_sync "$TMP_DIR/api-cross-stream-equal.json" conn_archive 3 \
	>/dev/null 2>&1; then
	assert_eq "equal-timestamp evidence across Slack streams is rejected" \
		accepted rejected
else
	assert_eq "equal-timestamp evidence across Slack streams is rejected" \
		rejected rejected
fi
assert_eq "cross-stream equal-timestamp rejection persists no evidence" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='slack' AND connection_id='conn_archive'"):$(raw_count)" \
	"${cross_stream_batches}:${cross_stream_raw}"
convergence_result=$(api_sync "$TMP_DIR/api-convergence.json" conn_archive 3)
assert_eq "archive and API modes converge on one live connection" \
	"$(json_field "$convergence_result" status)" complete
assert_eq "API transition preserves archive and history stream registration" \
	"$(sql_value "SELECT count(*) FROM json_each((SELECT enabled_streams FROM connections WHERE connection_id='conn_archive')) WHERE value IN ('archive','conversation/engineering/history')")" 2
assert_eq "API transition preserves immutable binding and attested scopes" \
	"$(sql_value "SELECT json_extract(policy_json,'$.slack_token_type') || ':' || json_extract(policy_json,'$.slack_conversation_binding_sha256') || ':' || json_extract(policy_json,'$.slack_read_scopes[0]') FROM connections WHERE connection_id='conn_archive'")" \
	"bot:${BINDING_HASH}:channels:history"
archive_raw=$(raw_count)

changed_result=$(archive_import \
	"$CHANGED_ARCHIVE" conn_archive 2026-07-31T19:05:00Z)
changed_source=$(json_field "$changed_result" source_sha256)
assert_eq "changed approved evidence updates the canonical object" \
	"$(sql_value "SELECT text_content FROM objects WHERE provider='slack' AND remote_id='$MESSAGE_ID'")" \
	"updated archive fixture knowledge"
assert_eq "changed approved evidence creates one new immutable batch" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='slack' AND connection_id='conn_archive' AND stream='archive'")" \
	$((archive_batches + 1))

equal_time_raw=$(raw_count)
equal_time_batches=$(sql_value \
	"SELECT count(*) FROM fetch_batches WHERE provider='slack' AND connection_id='conn_archive'")
if archive_import \
	"$STALE_ARCHIVE" conn_archive 2026-07-31T19:05:00Z >/dev/null 2>&1; then
	assert_eq "conflicting evidence at one observation timestamp is rejected" \
		accepted rejected
else
	assert_eq "conflicting evidence at one observation timestamp is rejected" \
		rejected rejected
fi
assert_eq "equal-timestamp rejection preserves canonical state" \
	"$(sql_value "SELECT text_content FROM objects WHERE provider='slack' AND remote_id='$MESSAGE_ID'")" \
	"updated archive fixture knowledge"
assert_eq "equal-timestamp rejection persists no provider evidence" \
	"$(sql_value "SELECT count(*) FROM fetch_batches WHERE provider='slack' AND connection_id='conn_archive'"):$(raw_count)" \
	"${equal_time_batches}:${equal_time_raw}"

python3 - "$TMP_DIR/api-convergence.json" "$TMP_DIR/api-stale-after-export.json" <<'PY'
import json
import sys
from pathlib import Path

with Path(sys.argv[1]).open(encoding="utf-8") as source:
    payload = json.load(source)
page = payload["pages"][0]
page["expect_request"]["oldest"] = "1709395200.000001"
page["response"]["observed_at"] = "2026-07-31T19:04:15Z"
page["response"]["data"][0]["text"] = "stale API fixture knowledge"
with Path(sys.argv[2]).open("w", encoding="utf-8") as target:
    json.dump(payload, target)
PY
stale_api_result=$(api_sync "$TMP_DIR/api-stale-after-export.json" conn_archive 3)
assert_eq "older API evidence completes without regressing canonical state" \
	"$(json_field "$stale_api_result" status):$(sql_value "SELECT text_content FROM objects WHERE provider='slack' AND remote_id='$MESSAGE_ID'")" \
	"complete:updated archive fixture knowledge"
assert_eq "older API evidence cannot regress its durable cursor" \
	"$(sql_value "SELECT last_success_at FROM sync_cursors WHERE connection_id='conn_archive' AND stream='conversation/engineering/history'")" \
	"2026-07-31T19:04:30.000000Z"

archive_import "$STALE_ARCHIVE" conn_archive 2026-07-31T19:03:00Z >/dev/null
assert_eq "older archive evidence cannot overwrite a newer canonical object" \
	"$(sql_value "SELECT text_content FROM objects WHERE provider='slack' AND remote_id='$MESSAGE_ID'")" \
	"updated archive fixture knowledge"
assert_eq "older archive evidence cannot regress its cursor" \
	"$(sql_value "SELECT last_success_at FROM sync_cursors WHERE connection_id='conn_archive' AND stream='archive'")" \
	"2026-07-31T19:05:00.000000Z"
assert_eq "older archive evidence cannot regress current connection policy" \
	"$(sql_value "SELECT json_extract(policy_json,'$.slack_export_sha256') FROM connections WHERE connection_id='conn_archive'")" \
	"$changed_source"
newest_replay=$(archive_import \
	"$CHANGED_ARCHIVE" conn_archive 2026-07-31T19:05:00Z)
assert_eq "newest replay remains idempotent after an older import" \
	"$(json_field "$newest_replay" replayed):$(sql_value "SELECT text_content FROM objects WHERE provider='slack' AND remote_id='$MESSAGE_ID'")" \
	"True:updated archive fixture knowledge"

raw_before=$(raw_count)
if env SLACK_FIXTURE_CONVERSATIONS='{"engineering":{"id":"C999ABC456","kind":"public_channel"}}' \
	python3 "$SLACK_ENTRY" archive --base "$BASE" --alias personal:default \
	--archive "$VALID_ARCHIVE" --connection-id conn_archive \
	--account-id "$ACCOUNT_ID" --profile fixture \
	--exported-at 2026-07-31T19:05:00Z >/dev/null 2>&1; then
	assert_eq "archive conversation rebinding is rejected" accepted rejected
else
	assert_eq "archive conversation rebinding is rejected" rejected rejected
fi
if env SLACK_FIXTURE_TOKEN_TYPE=user \
	python3 "$SLACK_ENTRY" archive --base "$BASE" --alias personal:default \
	--archive "$VALID_ARCHIVE" --connection-id conn_archive \
	--account-id "$ACCOUNT_ID" --profile fixture \
	--exported-at 2026-07-31T19:05:00Z >/dev/null 2>&1; then
	assert_eq "archive token-type rebinding is rejected" accepted rejected
else
	assert_eq "archive token-type rebinding is rejected" rejected rejected
fi
assert_eq "archive binding rejection persists no provider evidence" \
	"$(raw_count)" "$raw_before"

for mode in wrong-account wrong-workspace conflicting-workspace unsafe-folder traversal duplicate member-symlink credential credential-scalar; do
	unsafe_archive="$TMP_DIR/slack-${mode}.zip"
	python3 "$ARCHIVE_BUILDER" "$unsafe_archive" "$mode"
	expect_archive_failure "${mode} Slack export is rejected" \
		"$unsafe_archive" "conn_${mode//-/_}"
done

for mode in duplicate-folder casefold-folder; do
	duplicate_folder="$TMP_DIR/slack-${mode}.zip"
	python3 "$ARCHIVE_BUILDER" "$duplicate_folder" "$mode"
	if env SLACK_FIXTURE_CONVERSATIONS='{"engineering":{"id":"C123ABC456","kind":"public_channel"},"engineering-copy":{"id":"C777ABC456","kind":"public_channel"}}' \
		python3 "$SLACK_ENTRY" archive --base "$BASE" --alias personal:default \
		--archive "$duplicate_folder" --connection-id "conn_${mode//-/_}" \
		--account-id "$ACCOUNT_ID" --profile fixture \
		--exported-at 2026-07-31T19:04:00Z >/dev/null 2>&1; then
		assert_eq "${mode} export conversation folders are rejected" accepted rejected
	else
		assert_eq "${mode} export conversation folders are rejected" rejected rejected
	fi
done
assert_eq "rejected exports create no raw evidence" "$(raw_count)" \
	$((archive_raw + 3))

ln -s "$VALID_ARCHIVE" "$TMP_DIR/slack-link.zip"
expect_archive_failure "archive path symlinks are rejected" \
	"$TMP_DIR/slack-link.zip" conn_symlink
if python3 "$SLACK_ENTRY" archive --base "$BASE" --alias personal:default \
	--archive "$VALID_ARCHIVE" --connection-id conn_bytes \
	--account-id "$ACCOUNT_ID" --profile fixture \
	--exported-at 2026-07-31T19:00:00Z --max-bytes 1 \
	>/dev/null 2>&1; then
	assert_eq "compressed archive byte budgets fail closed" accepted rejected
else
	assert_eq "compressed archive byte budgets fail closed" rejected rejected
fi
if python3 "$SLACK_ENTRY" archive --base "$BASE" --alias personal:default \
	--archive "$VALID_ARCHIVE" --connection-id conn_items \
	--account-id "$ACCOUNT_ID" --profile fixture \
	--exported-at 2026-07-31T19:00:00Z --max-items 1 \
	>/dev/null 2>&1; then
	assert_eq "archive member budgets fail closed" accepted rejected
else
	assert_eq "archive member budgets fail closed" rejected rejected
fi
if python3 "$SLACK_ENTRY" archive --base "$BASE" --alias personal:default \
	--archive "$VALID_ARCHIVE" --connection-id conn_normalized_items \
	--account-id "$ACCOUNT_ID" --profile fixture \
	--exported-at 2026-07-31T19:00:00Z --max-items 10 \
	>/dev/null 2>&1; then
	assert_eq "archive normalized item budgets fail closed" accepted rejected
else
	assert_eq "archive normalized item budgets fail closed" rejected rejected
fi

assert_eq "completed Slack collectors release every live lease" \
	"$(sql_value "SELECT count(*) FROM collector_leases")" 0

printf '\nResults: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
