#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one read-only X stream into an authorized social corpus."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from urllib.parse import urlencode

from knowledge_corpus_catalog import DEFAULT_ALIAS, resolve
from knowledge_corpus_context import CatalogError
from knowledge_social_import import (
    canonical_json,
    import_accounts,
    import_activities,
    import_media,
    import_objects,
    reject_credentials,
    upsert_connection,
)
from knowledge_social_store import (
    SocialStoreError,
    connect,
    migrate,
    validate_opaque,
    validate_root,
    write_raw_batch,
)

PROVIDER = "xapi"
STREAM_PATHS = {
    "authored": "/2/users/{account_id}/tweets",
    "mentions": "/2/users/{account_id}/mentions",
    "likes": "/2/users/{account_id}/liked_tweets",
    "bookmarks": "/2/users/{account_id}/bookmarks",
    "followers": "/2/users/{account_id}/followers",
    "following": "/2/users/{account_id}/following",
}
TWEET_STREAMS = {"authored", "mentions", "likes", "bookmarks"}


class XAdapterError(SocialStoreError):
    """Raised when guarded X collection cannot continue safely."""


class GuardedXurl:
    """Execute only the two read-only helper surfaces used by this adapter."""

    def __init__(self, helper: Path, app: str | None, username: str | None) -> None:
        self.helper = helper
        self.profile_args: list[str] = []
        if app:
            self.profile_args.extend(("--app", app))
        if username:
            self.profile_args.extend(("--username", username))

    def _json(self, command: list[str]) -> dict[str, Any]:
        completed = subprocess.run(  # nosec B603 -- argv is built from a fixed helper and allowlisted reads
            command, check=False, capture_output=True, text=True, timeout=120
        )
        try:
            payload = json.loads(completed.stdout)
        except json.JSONDecodeError as error:
            raise XAdapterError("xurl returned no valid JSON") from error
        if not isinstance(payload, dict):
            raise XAdapterError("xurl response root must be an object")
        if completed.returncode != 0 and "status" not in payload:
            raise XAdapterError("xurl read request failed")
        return payload

    def identity(self) -> dict[str, Any]:
        return self._json([str(self.helper), "whoami", *self.profile_args])

    def page(self, endpoint: str) -> dict[str, Any]:
        return self._json(
            [str(self.helper), "run", *self.profile_args, "--", endpoint]
        )


class FixtureXurl:
    """Deterministic xurl substitute for pagination and failure fixtures."""

    def __init__(self, path: Path) -> None:
        try:
            fixture = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise XAdapterError("X fixture is not valid UTF-8 JSON") from error
        if not isinstance(fixture, dict) or not isinstance(fixture.get("pages"), list):
            raise XAdapterError("X fixture requires identity and pages")
        self.fixture = fixture
        self.position = 0

    def identity(self) -> dict[str, Any]:
        identity = self.fixture.get("identity")
        if not isinstance(identity, dict):
            raise XAdapterError("X fixture identity must be an object")
        return identity

    def page(self, endpoint: str) -> dict[str, Any]:
        del endpoint
        pages = self.fixture["pages"]
        if self.position >= len(pages) or not isinstance(pages[self.position], dict):
            raise XAdapterError("X fixture has no page for request")
        page = pages[self.position]
        self.position += 1
        return page


def response_status(payload: dict[str, Any]) -> int:
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise XAdapterError("X response status must be an integer")
    return status


def identity_data(payload: dict[str, Any]) -> dict[str, Any]:
    data = payload.get("data", payload)
    if not isinstance(data, dict) or not isinstance(data.get("id"), str):
        raise XAdapterError("xurl account verification returned no account ID")
    return data


def account_record(user: dict[str, Any], observed_at: str) -> dict[str, Any]:
    return {
        "remote_id": user["id"],
        "handle": user.get("username"),
        "display_name": user.get("name"),
        "observed_at": observed_at,
        "provider_json": {
            key: value
            for key, value in user.items()
            if key not in {"id", "username", "name"}
        },
    }


def page_accounts(
    account: dict[str, Any],
    includes: dict[str, Any],
    data: list[dict[str, Any]],
    stream: str,
    observed_at: str,
) -> list[dict[str, Any]]:
    accounts = [account_record(account, observed_at)]
    for user in includes.get("users", []):
        if isinstance(user, dict) and isinstance(user.get("id"), str):
            accounts.append(account_record(user, observed_at))
    if stream not in TWEET_STREAMS:
        for user in data:
            if isinstance(user.get("id"), str):
                accounts.append(account_record(user, observed_at))
    return accounts


def evidence_class(stream: str) -> str:
    if stream == "authored":
        return "authored"
    if stream in {"likes", "bookmarks"}:
        return "weak_signal"
    return "observed"


def page_resources(
    data: list[dict[str, Any]],
    account_id: str,
    stream: str,
    observed_at: str,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    objects: list[dict[str, Any]] = []
    activities: list[dict[str, Any]] = []
    for item in data:
        remote_id = item.get("id")
        if not isinstance(remote_id, str) or not remote_id:
            raise XAdapterError("X resource requires an ID")
        actor = item.get("author_id", account_id)
        if not isinstance(actor, str):
            raise XAdapterError("X resource author_id must be text")
        object_id: str | None = None
        if stream in TWEET_STREAMS:
            object_id = remote_id
            objects.append(
                {
                    "object_type": "post",
                    "remote_id": remote_id,
                    "account_remote_id": actor,
                    "text": item.get("text"),
                    "created_at": item.get("created_at"),
                    "observed_at": observed_at,
                    "evidence_class": evidence_class(stream),
                    "provider_json": {
                        key: value
                        for key, value in item.items()
                        if key not in {"id", "author_id", "text", "created_at"}
                    },
                }
            )
        activities.append(
            {
                "activity_type": stream,
                "remote_id": f"{stream}-{remote_id}",
                "actor_remote_id": account_id,
                "object_remote_id": object_id,
                "occurred_at": item.get("created_at"),
                "observed_at": observed_at,
                "state": "active",
            }
        )
    return objects, activities


def page_media(includes: dict[str, Any], media_policy: str) -> list[dict[str, Any]]:
    media: list[dict[str, Any]] = []
    if media_policy != "metadata":
        return media
    for item in includes.get("media", []):
        if isinstance(item, dict) and isinstance(item.get("media_key"), str):
            media.append(
                {
                    "remote_id": item["media_key"],
                    "object_remote_id": None,
                    "mime_type": item.get("type"),
                    "hydration_state": "metadata_only",
                }
            )
    return media


def page_archive(
    payload: dict[str, Any],
    connection_id: str,
    account: dict[str, Any],
    stream: str,
    media_policy: str,
) -> dict[str, Any]:
    reject_credentials(payload)
    data = payload.get("data", [])
    if data is None:
        data = []
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise XAdapterError("X page data must be an array")
    observed_at = payload.get("observed_at")
    if observed_at is None:
        observed_at = datetime.now(UTC).isoformat().replace("+00:00", "Z")
    if not isinstance(observed_at, str) or not observed_at:
        raise XAdapterError("X page observed_at must be text")
    includes = payload.get("includes", {})
    if not isinstance(includes, dict):
        raise XAdapterError("X page includes must be an object")

    accounts = page_accounts(account, includes, data, stream, observed_at)
    objects, activities = page_resources(data, account["id"], stream, observed_at)
    media = page_media(includes, media_policy)
    return {
        "provider": PROVIDER,
        "connection_id": connection_id,
        "remote_account_id": account["id"],
        "exported_at": observed_at,
        "enabled_streams": [stream],
        "policy": {"media_hydration": media_policy},
        "accounts": accounts,
        "objects": objects,
        "activities": activities,
        "media": media,
        "coverage": [],
    }


def current_cursor(
    database: Any, connection_id: str, stream: str
) -> tuple[str | None, str | None, bool]:
    row = database.execute(
        "SELECT cursor,watermark,backfill_complete FROM sync_cursors WHERE connection_id=? AND stream=?",
        (connection_id, stream),
    ).fetchone()
    if row is None:
        return None, None, False
    return row["cursor"], row["watermark"], bool(row["backfill_complete"])


def persist_page(
    root: Path,
    archive: dict[str, Any],
    payload: dict[str, Any],
    stream: str,
    next_cursor: str | None,
    watermark: str | None,
    complete: bool,
) -> int:
    raw = canonical_json(payload).encode("utf-8")
    connection_id = archive["connection_id"]
    database = connect(root)
    try:
        migrate(database)
        batch_id, blob_ref = write_raw_batch(root, PROVIDER, connection_id, raw)
        database.execute("BEGIN IMMEDIATE")
        upsert_connection(database, archive, PROVIDER, connection_id)
        import_accounts(database, archive, PROVIDER)
        import_objects(database, archive, PROVIDER, batch_id)
        import_activities(database, archive, PROVIDER, batch_id)
        import_media(database, archive, PROVIDER, batch_id)
        count = sum(
            len(archive[key]) for key in ("accounts", "objects", "activities", "media")
        )
        database.execute(
            """INSERT OR IGNORE INTO fetch_batches(
               batch_id,provider,connection_id,stream,request_hash,response_hash,blob_ref,
               resource_count,budget_units,completed_at,terminal_status)
               VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
            (
                batch_id,
                PROVIDER,
                connection_id,
                stream,
                hashlib.sha256(stream.encode()).hexdigest(),
                batch_id,
                blob_ref,
                count,
                1,
                archive["exported_at"],
                "success",
            ),
        )
        database.execute(
            """INSERT INTO sync_cursors(
               connection_id,stream,cursor,watermark,last_success_at,backfill_complete)
               VALUES(?,?,?,?,?,?) ON CONFLICT(connection_id,stream) DO UPDATE SET
               cursor=excluded.cursor,watermark=excluded.watermark,
               last_success_at=excluded.last_success_at,
               backfill_complete=excluded.backfill_complete""",
            (
                connection_id,
                stream,
                next_cursor,
                watermark,
                archive["exported_at"],
                int(complete),
            ),
        )
        database.execute("COMMIT")
        return count
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    finally:
        database.close()


def record_stop(
    root: Path,
    connection_id: str,
    status: str,
    failure: str,
    retry_after: str | None,
) -> None:
    database = connect(root)
    try:
        migrate(database)
        database.execute(
            "INSERT INTO sync_runs(run_id,connection_id,status,failure_class,retry_after,diagnostics) VALUES(?,?,?,?,?,?)",
            (uuid.uuid4().hex, connection_id, status, failure, retry_after, "sanitized"),
        )
    finally:
        database.close()


def xurl_runner(args: argparse.Namespace) -> Any:
    if args.fixture and os.environ.get("AIDEVOPS_TEST_MODE") != "1":
        raise XAdapterError("X fixtures are disabled outside the test harness")
    if args.fixture:
        return FixtureXurl(args.fixture)
    helper = Path(__file__).with_name("xurl-helper.sh")
    return GuardedXurl(helper, args.app, args.username)


def load_stream_state(
    root: Path, connection_id: str, stream: str
) -> tuple[str | None, str | None, bool]:
    database = connect(root)
    try:
        migrate(database)
        return current_cursor(database, connection_id, stream)
    finally:
        database.close()


def stream_endpoint(
    stream: str,
    account_id: str,
    cursor: str | None,
    watermark: str | None,
    backfill_complete: bool,
) -> str:
    params = {"max_results": "100"}
    if stream in TWEET_STREAMS:
        params.update(
            {
                "expansions": "author_id,attachments.media_keys",
                "tweet.fields": "author_id,created_at,attachments,public_metrics",
                "user.fields": "id,name,username",
                "media.fields": "media_key,type",
            }
        )
    else:
        params["user.fields"] = "id,name,username"
    if cursor:
        params["pagination_token"] = cursor
    elif backfill_complete and watermark:
        params["since_id"] = watermark
    return STREAM_PATHS[stream].format(account_id=account_id) + "?" + urlencode(params)


def terminal_response(
    payload: dict[str, Any],
    root: Path,
    connection_id: str,
    pages: int,
    resources: int,
) -> dict[str, Any] | None:
    status = response_status(payload)
    retry_after = payload.get("retry_after")
    if retry_after is not None and not isinstance(retry_after, str):
        raise XAdapterError("X retry_after must be text")
    if status == 429:
        record_stop(root, connection_id, "paused", "rate_limit", retry_after)
        return {
            "status": "rate_limited",
            "pages": pages,
            "resources": resources,
            "retry_after": retry_after,
        }
    if status not in (401, 403, 404) and status < 500:
        if status != 200:
            raise XAdapterError("X response has unsupported status")
        return None
    if status in (401, 403):
        failure = "authorization"
    elif status == 404:
        failure = "unavailable"
    else:
        failure = "provider"
    record_stop(root, connection_id, "failed", failure, retry_after)
    return {
        "status": "failed",
        "failure_class": failure,
        "pages": pages,
        "resources": resources,
    }


def page_checkpoint(
    payload: dict[str, Any], watermark: str | None
) -> tuple[str | None, str | None]:
    meta = payload.get("meta", {})
    if not isinstance(meta, dict):
        raise XAdapterError("X page meta must be an object")
    next_cursor = meta.get("next_token")
    if next_cursor is not None and not isinstance(next_cursor, str):
        raise XAdapterError("X next_token must be text")
    ids = [
        item.get("id")
        for item in payload.get("data", [])
        if isinstance(item, dict) and isinstance(item.get("id"), str)
    ]
    candidates = ids + ([watermark] if watermark else [])
    newest = (
        max(
            candidates,
            key=lambda value: (1, int(value)) if value.isdigit() else (0, value),
        )
        if candidates
        else None
    )
    return next_cursor, newest


def collect(args: argparse.Namespace, root: Path) -> dict[str, Any]:
    connection_id = validate_opaque(args.connection_id, "connection_id")
    account_id = validate_opaque(args.account_id, "account_id")
    runner = xurl_runner(args)
    account = identity_data(runner.identity())
    if account["id"] != account_id:
        raise XAdapterError(
            "selected xurl account does not match the configured connection"
        )
    cursor, watermark, backfill_complete = load_stream_state(
        root, connection_id, args.stream
    )
    pages = 0
    resources = 0
    while pages < args.budget:
        endpoint = stream_endpoint(
            args.stream, account_id, cursor, watermark, backfill_complete
        )
        payload = runner.page(endpoint)
        stopped = terminal_response(payload, root, connection_id, pages, resources)
        if stopped is not None:
            return stopped
        next_cursor, newest = page_checkpoint(payload, watermark)
        archive = page_archive(
            payload, connection_id, account, args.stream, args.media_policy
        )
        resources += persist_page(
            root,
            archive,
            payload,
            args.stream,
            next_cursor,
            newest,
            next_cursor is None,
        )
        pages += 1
        cursor = next_cursor
        watermark = newest
        if next_cursor is None:
            return {"status": "complete", "pages": pages, "resources": resources}
    record_stop(root, connection_id, "paused", "budget", None)
    return {"status": "budget_exhausted", "pages": pages, "resources": resources}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", type=Path)
    parser.add_argument("--alias", default=DEFAULT_ALIAS)
    parser.add_argument("--connection-id", required=True)
    parser.add_argument("--account-id", required=True)
    parser.add_argument("--stream", required=True, choices=tuple(STREAM_PATHS))
    parser.add_argument("--budget", type=int, default=10)
    parser.add_argument(
        "--media-policy", choices=("none", "metadata"), default="none"
    )
    parser.add_argument("--app")
    parser.add_argument("--username")
    parser.add_argument("--fixture", type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.budget < 1 or args.budget > 1000:
        parser.error("--budget must be between 1 and 1000")
    return args


def main() -> int:
    args = parse_args()
    try:
        base = (
            args.base
            if args.base
            else Path.home() / ".aidevops" / ".agent-workspace" / "knowledge"
        )
        root = validate_root(resolve(base, args.alias, "knowledge.write"))
        print(json.dumps(collect(args, root), sort_keys=True))
        return 0
    except (
        CatalogError,
        OSError,
        XAdapterError,
        ValueError,
        subprocess.SubprocessError,
    ) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
