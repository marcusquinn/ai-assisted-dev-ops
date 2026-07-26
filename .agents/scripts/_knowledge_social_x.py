#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""X stream capabilities, response validation, and checkpoint calculation."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any
from urllib.parse import urlencode

from _knowledge_social_collect import CursorState, PageCheckpoint
from knowledge_social_store import SocialStoreError

PROVIDER = "xapi"


class XAdapterError(SocialStoreError):
    """Raised when guarded X collection cannot continue safely."""


@dataclass(frozen=True)
class StreamSpec:
    """Static capability and cost policy for one X collection stream."""

    path: str
    resource_kind: str
    activity_mode: str
    supports_since_id: bool
    cost_units: int = 1
    refresh_after_complete: bool = False


STREAMS = {
    "authored": StreamSpec(
        "/2/users/{account_id}/tweets", "tweet", "content_author", True
    ),
    "mentions": StreamSpec(
        "/2/users/{account_id}/mentions", "tweet", "content_author", True
    ),
    "likes": StreamSpec(
        "/2/users/{account_id}/liked_tweets", "tweet", "selected_account", False
    ),
    "bookmarks": StreamSpec(
        "/2/users/{account_id}/bookmarks", "tweet", "selected_account", False
    ),
    "followers": StreamSpec(
        "/2/users/{account_id}/followers", "account", "remote_follows_selected", False
    ),
    "following": StreamSpec(
        "/2/users/{account_id}/following", "account", "selected_follows_remote", False
    ),
    "owned_lists": StreamSpec(
        "/2/users/{account_id}/owned_lists",
        "custom_feed",
        "selected_owns_remote",
        False,
        refresh_after_complete=True,
    ),
    "followed_lists": StreamSpec(
        "/2/users/{account_id}/followed_lists",
        "custom_feed",
        "selected_follows_remote",
        False,
        refresh_after_complete=True,
    ),
    "list_memberships": StreamSpec(
        "/2/users/{account_id}/list_memberships",
        "custom_feed",
        "remote_contains_selected",
        False,
        refresh_after_complete=True,
    ),
}


def response_status(payload: dict[str, Any]) -> int:
    """Return a validated HTTP-like status from an xurl payload."""
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise XAdapterError("X response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    """Return a validated provider data array."""
    data = payload.get("data", [])
    if data is None:
        return []
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise XAdapterError("X page data must be an array")
    return data


def _newest_id(ids: list[str], previous: str | None) -> str | None:
    candidates = ids + ([previous] if previous else [])
    if not candidates:
        return None
    return max(
        candidates,
        key=lambda value: (1, int(value)) if value.isdigit() else (0, value),
    )


def page_checkpoint(
    payload: dict[str, Any], previous_watermark: str | None
) -> PageCheckpoint:
    """Calculate the next cursor and monotonic provider watermark."""
    meta = payload.get("meta", {})
    if not isinstance(meta, dict):
        raise XAdapterError("X page meta must be an object")
    next_cursor = meta.get("next_token")
    if next_cursor is not None and not isinstance(next_cursor, str):
        raise XAdapterError("X next_token must be text")
    ids = [item["id"] for item in page_data(payload) if isinstance(item.get("id"), str)]
    return PageCheckpoint(next_cursor, _newest_id(ids, previous_watermark))


def stream_endpoint(stream: str, account_id: str, state: CursorState) -> str:
    """Build one allowlisted official read endpoint from validated state."""
    spec = STREAMS[stream]
    params = {"max_results": "100"}
    if spec.resource_kind == "tweet":
        params.update(
            {
                "expansions": "author_id,attachments.media_keys",
                "tweet.fields": (
                    "author_id,created_at,attachments,public_metrics,referenced_tweets"
                ),
                "user.fields": "id,name,username",
                "media.fields": "media_key,type",
            }
        )
    elif spec.resource_kind == "account":
        params["user.fields"] = "id,name,username"
    elif spec.resource_kind == "custom_feed":
        params["list.fields"] = (
            "created_at,description,follower_count,member_count,owner_id,private"
        )
    else:
        raise XAdapterError("X stream resource kind is unsupported")
    if state.cursor:
        params["pagination_token"] = state.cursor
    elif state.backfill_complete and state.watermark and spec.supports_since_id:
        params["since_id"] = state.watermark
    path = spec.path.format(account_id=account_id)
    return f"{path}?{urlencode(params)}"
