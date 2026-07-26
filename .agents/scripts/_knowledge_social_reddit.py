#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Reddit stream capabilities and durable checkpoint calculation."""

from __future__ import annotations

import base64
import json
import re
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from knowledge_social_import import canonical_json
from knowledge_social_store import SocialStoreError

PROVIDER = "reddit"
FULLNAME = re.compile(r"^t[1-9]_[A-Za-z0-9]+$")
CURSOR_PREFIX = "reddit-v1:"
LISTING_RETENTION = "provider_listing_window"


class RedditAdapterError(SocialStoreError):
    """Raised when guarded Reddit collection cannot continue safely."""


class RedditProviderUnavailableError(RedditAdapterError):
    """Raised when the bounded PRAW child cannot complete a read."""


@dataclass(frozen=True)
class StreamSpec:
    """Static collection and coverage policy for one Reddit stream."""

    resource_kind: str
    activity_mode: str
    pagination: str
    incremental: bool
    retention_limit: str | None
    cost_units: int = 1


@dataclass(frozen=True)
class PaginationMeta:
    """Validated pagination facts returned by the bounded PRAW child."""

    next_after: str | None
    newest: str | None
    reached: bool
    complete: bool


def _listing(
    resource_kind: str,
    activity_mode: str,
    *,
    incremental: bool,
) -> StreamSpec:
    return StreamSpec(
        resource_kind,
        activity_mode,
        "listing",
        incremental,
        LISTING_RETENTION,
    )


STREAMS = {
    "authored_submissions": _listing("submission", "content_author", incremental=True),
    "authored_comments": _listing("comment", "content_author", incremental=True),
    "mentions": _listing("comment", "content_author", incremental=True),
    "comment_replies": _listing("comment", "content_author", incremental=True),
    "submission_replies": _listing("comment", "content_author", incremental=True),
    "inbox_messages": _listing("message", "content_author", incremental=True),
    "sent_messages": _listing("message", "content_author", incremental=True),
    "saved": _listing("content", "selected_account", incremental=True),
    "upvoted": _listing("content", "selected_account", incremental=True),
    "downvoted": _listing("content", "selected_account", incremental=True),
    "hidden": _listing("content", "selected_account", incremental=True),
    "subscribed_subreddits": _listing(
        "subreddit", "selected_account", incremental=False
    ),
    "moderated_subreddits": _listing(
        "subreddit", "selected_account", incremental=False
    ),
    "contributor_subreddits": _listing(
        "subreddit", "selected_account", incremental=False
    ),
    "multireddits": StreamSpec(
        "multireddit", "selected_account", "snapshot", False, None
    ),
    "friends": StreamSpec("redditor", "selected_account", "snapshot", False, None),
    "blocked": StreamSpec("redditor", "selected_account", "snapshot", False, None),
    "trusted": StreamSpec("redditor", "selected_account", "snapshot", False, None),
}


@dataclass(frozen=True)
class PageRequest:
    """Allowlisted bounded request passed to the PRAW subprocess."""

    stream: str
    account_id: str
    after: str | None
    stop_at: str | None
    limit: int

    def payload(self) -> dict[str, Any]:
        return {
            "action": "page",
            "stream": self.stream,
            "account_id": self.account_id,
            "after": self.after,
            "stop_at": self.stop_at,
            "limit": self.limit,
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())


def _fullname(value: Any, field: str, *, optional: bool = False) -> str | None:
    if value is None and optional:
        return None
    if not isinstance(value, str) or FULLNAME.fullmatch(value) is None:
        raise RedditAdapterError(f"Reddit {field} must be a stable fullname")
    return value


def _encode_cursor(after: str, stop_at: str | None) -> str:
    payload = canonical_json({"after": after, "stop_at": stop_at}).encode("utf-8")
    encoded = base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")
    return f"{CURSOR_PREFIX}{encoded}"


def _decode_cursor(cursor: str) -> tuple[str, str | None]:
    if not cursor.startswith(CURSOR_PREFIX):
        raise RedditAdapterError("stored Reddit cursor has an unsupported version")
    encoded = cursor.removeprefix(CURSOR_PREFIX)
    try:
        padding = "=" * (-len(encoded) % 4)
        parsed = json.loads(base64.urlsafe_b64decode(encoded + padding))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise RedditAdapterError("stored Reddit cursor is invalid") from error
    if not isinstance(parsed, dict) or set(parsed) != {"after", "stop_at"}:
        raise RedditAdapterError("stored Reddit cursor has an invalid shape")
    after = _fullname(parsed["after"], "cursor after")
    stop_at = _fullname(parsed["stop_at"], "cursor watermark", optional=True)
    if after is None:
        raise RedditAdapterError("stored Reddit cursor has no resume value")
    return after, stop_at


def page_request(
    stream: str,
    account_id: str,
    state: CursorState,
    limit: int,
) -> PageRequest:
    """Build one allowlisted request from the durable stream state."""
    spec = STREAMS[stream]
    after: str | None = None
    stop_at: str | None = None
    if state.cursor:
        after, stop_at = _decode_cursor(state.cursor)
    elif spec.incremental and state.backfill_complete:
        stop_at = _fullname(state.watermark, "watermark", optional=True)
    return PageRequest(stream, account_id, after, stop_at, limit)


def response_status(payload: dict[str, Any]) -> int:
    """Return a validated HTTP-like status from a Reddit read response."""
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise RedditAdapterError("Reddit response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    """Return a validated provider data array."""
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise RedditAdapterError("Reddit page data must be an array")
    return data


def _page_meta(payload: dict[str, Any]) -> dict[str, Any]:
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise RedditAdapterError("Reddit page meta must be an object")
    return meta


def _meta_boolean(meta: dict[str, Any], field: str) -> bool:
    value = meta.get(field)
    if not isinstance(value, bool):
        raise RedditAdapterError("Reddit page completion metadata is invalid")
    return value


def _pagination_meta(payload: dict[str, Any], spec: StreamSpec) -> PaginationMeta:
    meta = _page_meta(payload)
    next_after = _fullname(meta.get("next_after"), "next_after", optional=True)
    newest = _fullname(meta.get("newest_fullname"), "newest item", optional=True)
    reached = _meta_boolean(meta, "reached_watermark")
    complete = _meta_boolean(meta, "complete") or reached
    snapshot = meta.get("snapshot")
    if not isinstance(snapshot, bool) or snapshot != (spec.pagination == "snapshot"):
        raise RedditAdapterError("Reddit page pagination metadata is invalid")
    if complete == (next_after is not None):
        message = (
            "complete Reddit page cannot have a next cursor"
            if complete
            else "partial Reddit page requires a next cursor"
        )
        raise RedditAdapterError(message)
    return PaginationMeta(next_after, newest, reached, complete)


def page_checkpoint(
    payload: dict[str, Any],
    state: CursorState,
    request: PageRequest,
) -> tuple[PageCheckpoint, bool]:
    """Calculate a resumable cursor and stable newest-item watermark."""
    spec = STREAMS[request.stream]
    meta = _pagination_meta(payload, spec)
    watermark = state.watermark
    if spec.incremental and request.after is None and meta.newest is not None:
        watermark = meta.newest
    next_cursor = (
        _encode_cursor(meta.next_after, request.stop_at)
        if meta.next_after is not None
        else None
    )
    return PageCheckpoint(next_cursor, watermark), meta.complete
