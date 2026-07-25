#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Collect one read-only X stream into an authorized social corpus."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any
from urllib.parse import urlencode

from knowledge_corpus_catalog import DEFAULT_ALIAS, resolve
from knowledge_corpus_context import CatalogError
from knowledge_social_store import (
    SocialStoreError,
    validate_opaque,
    validate_root,
)
from knowledge_social_x_contract import STREAM_PATHS, TWEET_STREAMS
from knowledge_social_x_normalize import XNormalizeError, page_archive
from knowledge_social_x_store import (
    PageCheckpoint,
    load_stream_state,
    persist_page,
    record_stop,
)


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


def xurl_runner(args: argparse.Namespace) -> Any:
    if args.fixture and os.environ.get("AIDEVOPS_TEST_MODE") != "1":
        raise XAdapterError("X fixtures are disabled outside the test harness")
    if args.fixture:
        return FixtureXurl(args.fixture)
    helper = Path(__file__).with_name("xurl-helper.sh")
    return GuardedXurl(helper, args.app, args.username)


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
        checkpoint = PageCheckpoint(
            stream=args.stream,
            cursor=next_cursor,
            watermark=newest,
            complete=next_cursor is None,
        )
        resources += persist_page(root, archive, payload, checkpoint)
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
        XNormalizeError,
        ValueError,
        subprocess.SubprocessError,
    ) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
