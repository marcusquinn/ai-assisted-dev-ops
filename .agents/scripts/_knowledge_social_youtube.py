#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""YouTube stream capabilities and durable checkpoint calculation."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from _knowledge_social_oauth_request import OAuthPageResponseCodec
from knowledge_social_import import canonical_json, reject_credentials
from knowledge_social_store import SocialStoreError

PROVIDER = "youtube"
CURSOR_PREFIX = "youtube-v1:"
YOUTUBE_ID = re.compile(r"^[A-Za-z0-9_-]{3,128}$")
API_RETENTION = "youtube_api_data_refresh_or_delete_within_30_days"


class YouTubeAdapterError(SocialStoreError):
    """Raised when guarded YouTube collection cannot continue safely."""


class YouTubeProviderUnavailableError(YouTubeAdapterError):
    """Raised when the bounded OAuth child cannot complete a read."""


ADAPTER_ERROR = YouTubeAdapterError
PROVIDER_UNAVAILABLE_ERROR = YouTubeProviderUnavailableError
PAGE_CODEC = OAuthPageResponseCodec(
    display_name="YouTube",
    cursor_prefix=CURSOR_PREFIX,
    error_type=YouTubeAdapterError,
)


@dataclass(frozen=True)
class StreamSpec:
    """Static collection and coverage policy for one YouTube stream."""

    resource_kind: str
    activity_mode: str
    pagination: str
    incremental: bool
    retention_limit: str | None
    coverage_status: str | None = None
    unavailable_reason: str | None = None
    cost_units: int = 2


STREAMS = {
    "authored_videos": StreamSpec(
        "video", "content_author", "listing", True, API_RETENTION
    ),
    "channel_activity": StreamSpec(
        "activity",
        "selected_account",
        "listing",
        True,
        API_RETENTION,
        "partial",
        "youtube_activity_feed_is_not_complete_history",
    ),
    "owned_playlists": StreamSpec(
        "playlist",
        "selected_account",
        "compound_snapshot",
        False,
        API_RETENTION,
        "partial",
        "saved_third_party_playlists_are_not_listable",
    ),
    "subscriptions": StreamSpec(
        "subscription", "selected_account", "snapshot", False, API_RETENTION
    ),
    "comments": StreamSpec(
        "comment",
        "content_author",
        "compound_listing",
        True,
        API_RETENTION,
        "partial",
        "channel_related_visible_comments_only",
    ),
    "liked_videos": StreamSpec(
        "video", "selected_account", "snapshot", False, API_RETENTION
    ),
}


@dataclass(frozen=True)
class PageRequest:
    """Allowlisted bounded request passed to the OAuth subprocess."""

    stream: str
    account_id: str
    uploads_playlist_id: str
    cursor: dict[str, Any] | None
    stop_at: str | None
    limit: int

    def payload(self) -> dict[str, Any]:
        return {
            "action": "page",
            "stream": self.stream,
            "account_id": self.account_id,
            "uploads_playlist_id": self.uploads_playlist_id,
            "cursor": self.cursor,
            "stop_at": self.stop_at,
            "limit": self.limit,
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())


def youtube_id(value: Any, field: str, *, optional: bool = False) -> str | None:
    """Validate one provider-stable YouTube resource ID."""
    if value is None and optional:
        return None
    if not isinstance(value, str) or YOUTUBE_ID.fullmatch(value) is None:
        raise YouTubeAdapterError(f"YouTube {field} must be a stable ID")
    return value


def _encode_cursor(cursor: dict[str, Any]) -> str:
    return PAGE_CODEC.encode_cursor(cursor)


def _decode_cursor(cursor: str) -> dict[str, Any]:
    return PAGE_CODEC.decode_cursor(cursor)


def page_request(
    stream: str,
    account: dict[str, Any],
    state: CursorState,
    limit: int,
) -> PageRequest:
    """Build one allowlisted request from durable per-stream state."""
    spec = STREAMS[stream]
    account_id = youtube_id(account.get("id"), "account ID")
    uploads_id = youtube_id(account.get("uploads_playlist_id"), "uploads playlist ID")
    if account_id is None or uploads_id is None:
        raise YouTubeAdapterError("verified YouTube identity is incomplete")
    cursor = _decode_cursor(state.cursor) if state.cursor else None
    stop_at = (
        youtube_id(state.watermark, "watermark", optional=True)
        if spec.incremental and state.backfill_complete and cursor is None
        else None
    )
    return PageRequest(stream, account_id, uploads_id, cursor, stop_at, limit)


def response_status(payload: dict[str, Any]) -> int:
    """Return a validated HTTP-like status from a YouTube read response."""
    return PAGE_CODEC.response_status(payload)


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    """Return a validated provider data array."""
    return PAGE_CODEC.page_data(payload)


def _page_meta(payload: dict[str, Any]) -> dict[str, Any]:
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise YouTubeAdapterError("YouTube page meta must be an object")
    reject_credentials(meta)
    return meta


def _meta_boolean(meta: dict[str, Any], field: str) -> bool:
    value = meta.get(field)
    if not isinstance(value, bool):
        raise YouTubeAdapterError("YouTube page completion metadata is invalid")
    return value


def page_checkpoint(
    payload: dict[str, Any],
    state: CursorState,
    request: PageRequest,
) -> tuple[PageCheckpoint, bool]:
    """Calculate a resumable cursor and stable newest-resource watermark."""
    spec = STREAMS[request.stream]
    meta = _page_meta(payload)
    next_value = meta.get("next_cursor")
    if next_value is not None and not isinstance(next_value, dict):
        raise YouTubeAdapterError("YouTube next cursor must be an object")
    newest = youtube_id(meta.get("newest_id"), "newest ID", optional=True)
    reached = _meta_boolean(meta, "reached_watermark")
    complete = _meta_boolean(meta, "complete") or reached
    snapshot = meta.get("snapshot")
    if not isinstance(snapshot, bool) or snapshot != (not spec.incremental):
        raise YouTubeAdapterError("YouTube page pagination metadata is invalid")
    if complete == (next_value is not None):
        message = (
            "complete YouTube page cannot have a next cursor"
            if complete
            else "partial YouTube page requires a next cursor"
        )
        raise YouTubeAdapterError(message)
    watermark = state.watermark
    if spec.incremental and request.cursor is None and newest is not None:
        watermark = newest
    next_cursor = _encode_cursor(next_value) if next_value is not None else None
    return PageCheckpoint(next_cursor, watermark), complete
