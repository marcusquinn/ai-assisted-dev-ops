#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation and serialization for the bounded YouTube OAuth subprocess."""

from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

MAX_TEXT_BYTES = 256 * 1024
STABLE_ID = re.compile(r"^[A-Za-z0-9_-]{3,128}$")


class YouTubeReadProviderError(RuntimeError):
    """Raised for a privacy-safe local YouTube provider failure."""


@dataclass(frozen=True)
class ApiResult:
    """One bounded HTTP result without provider error-body disclosure."""

    status: int
    payload: dict[str, Any]
    retry_after: int | None = None


def observed_at() -> str:
    """Return a stable UTC timestamp for one bounded provider response."""
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def exact_keys(request: dict[str, Any], expected: set[str]) -> None:
    """Reject request shapes outside the allowlisted read contract."""
    if set(request) != expected:
        raise YouTubeReadProviderError(
            "YouTube read request has an invalid action shape"
        )


def object_value(value: Any, field: str) -> dict[str, Any]:
    """Validate one provider object."""
    if not isinstance(value, dict):
        raise YouTubeReadProviderError(f"YouTube {field} must be an object")
    return value


def optional_object(value: Any, field: str) -> dict[str, Any]:
    """Validate an optional provider object, returning an empty object."""
    if value is None:
        return {}
    return object_value(value, field)


def optional_text(value: Any, field: str) -> str | None:
    """Validate one bounded optional text field."""
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value:
        raise YouTubeReadProviderError(f"YouTube {field} must be text")
    if len(value.encode("utf-8")) > MAX_TEXT_BYTES:
        raise YouTubeReadProviderError(f"YouTube {field} exceeds the safety limit")
    return value


def required_text(value: Any, field: str) -> str:
    """Validate one non-empty bounded text field."""
    text = optional_text(value, field)
    if not text:
        raise YouTubeReadProviderError(f"YouTube {field} is required")
    return text


def stable_id(value: Any, field: str) -> str:
    """Validate one provider-stable resource ID."""
    text = required_text(value, field)
    if STABLE_ID.fullmatch(text) is None:
        raise YouTubeReadProviderError(f"YouTube {field} is invalid")
    return text


def optional_id(value: Any, field: str) -> str | None:
    """Validate one optional provider-stable resource ID."""
    if value is None:
        return None
    return stable_id(value, field)


def integer(value: Any, field: str) -> int:
    """Validate a non-negative integer."""
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise YouTubeReadProviderError(f"YouTube {field} must be a non-negative integer")
    return value


def response_items(payload: dict[str, Any]) -> list[dict[str, Any]]:
    """Return a validated YouTube list-response item array."""
    items = payload.get("items", [])
    if not isinstance(items, list) or any(not isinstance(item, dict) for item in items):
        raise YouTubeReadProviderError("YouTube API items must be an array")
    return items


def next_page_token(payload: dict[str, Any]) -> str | None:
    """Return a validated provider page token."""
    token = optional_text(payload.get("nextPageToken"), "next page token")
    if token is not None and (not token or len(token.encode("utf-8")) > 2048):
        raise YouTubeReadProviderError("YouTube next page token is invalid")
    return token


def listed_records(
    records: list[dict[str, Any]], stop_at: str | None
) -> tuple[list[dict[str, Any]], str | None, bool]:
    """Filter one newest-first page at its durable watermark."""
    newest = records[0].get("remote_id") if records else None
    if newest is not None:
        newest = stable_id(newest, "newest resource ID")
    accepted: list[dict[str, Any]] = []
    reached = False
    for record in records:
        if stop_at is not None and record.get("remote_id") == stop_at:
            reached = True
            break
        accepted.append(record)
    return accepted, newest, reached


def terminal_payload(result: ApiResult) -> dict[str, Any]:
    """Build a sanitized terminal envelope from one HTTP result."""
    payload: dict[str, Any] = {"status": result.status, "observed_at": observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload


def identity_value(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Select and serialize the explicitly configured OAuth-owned channel."""
    expected = stable_id(expected_id, "account ID")
    selected = next(
        (
            item
            for item in response_items(payload)
            if item.get("id") == expected
        ),
        None,
    )
    if selected is None:
        raise YouTubeReadProviderError(
            "selected YouTube channel does not match the configured connection"
        )
    snippet = optional_object(selected.get("snippet"), "channel snippet")
    details = object_value(selected.get("contentDetails"), "channel content details")
    related = object_value(details.get("relatedPlaylists"), "related playlists")
    return {
        "id": expected,
        "title": optional_text(snippet.get("title"), "channel title"),
        "handle": optional_text(snippet.get("customUrl"), "channel handle"),
        "uploads_playlist_id": stable_id(
            related.get("uploads"), "uploads playlist ID"
        ),
    }


def _snippet(item: dict[str, Any], kind: str) -> dict[str, Any]:
    return object_value(item.get("snippet"), f"{kind} snippet")


def _resource_video_id(snippet: dict[str, Any], details: dict[str, Any]) -> str:
    resource = optional_object(snippet.get("resourceId"), "video resource ID")
    candidate = details.get("videoId") or resource.get("videoId")
    return stable_id(candidate, "video ID")


def serialize_uploaded_video(item: dict[str, Any]) -> dict[str, Any]:
    """Serialize one uploads-playlist item as authored video knowledge."""
    snippet = _snippet(item, "playlist item")
    details = optional_object(item.get("contentDetails"), "playlist item details")
    status = optional_object(item.get("status"), "playlist item status")
    return {
        "kind": "video",
        "remote_id": _resource_video_id(snippet, details),
        "playlist_item_id": stable_id(item.get("id"), "playlist item ID"),
        "title": optional_text(snippet.get("title"), "video title"),
        "description": optional_text(snippet.get("description"), "video description"),
        "published_at": optional_text(snippet.get("publishedAt"), "video timestamp"),
        "channel_id": optional_id(snippet.get("channelId"), "channel ID"),
        "channel_title": optional_text(snippet.get("channelTitle"), "channel title"),
        "position": integer(snippet.get("position", 0), "playlist position"),
        "privacy_status": optional_text(status.get("privacyStatus"), "privacy status"),
    }


def serialize_video(item: dict[str, Any]) -> dict[str, Any]:
    """Serialize one liked-video resource."""
    snippet = _snippet(item, "video")
    status = optional_object(item.get("status"), "video status")
    return {
        "kind": "video",
        "remote_id": stable_id(item.get("id"), "video ID"),
        "title": optional_text(snippet.get("title"), "video title"),
        "description": optional_text(snippet.get("description"), "video description"),
        "published_at": optional_text(snippet.get("publishedAt"), "video timestamp"),
        "channel_id": optional_id(snippet.get("channelId"), "channel ID"),
        "channel_title": optional_text(snippet.get("channelTitle"), "channel title"),
        "privacy_status": optional_text(status.get("privacyStatus"), "privacy status"),
    }


def serialize_playlist(item: dict[str, Any]) -> dict[str, Any]:
    """Serialize one OAuth-owned playlist."""
    snippet = _snippet(item, "playlist")
    details = object_value(item.get("contentDetails"), "playlist details")
    status = optional_object(item.get("status"), "playlist status")
    return {
        "kind": "playlist",
        "remote_id": stable_id(item.get("id"), "playlist ID"),
        "title": optional_text(snippet.get("title"), "playlist title"),
        "description": optional_text(snippet.get("description"), "playlist description"),
        "published_at": optional_text(snippet.get("publishedAt"), "playlist timestamp"),
        "channel_id": optional_id(snippet.get("channelId"), "channel ID"),
        "channel_title": optional_text(snippet.get("channelTitle"), "channel title"),
        "item_count": integer(details.get("itemCount", 0), "playlist item count"),
        "privacy_status": optional_text(status.get("privacyStatus"), "privacy status"),
    }


def serialize_playlist_item(
    item: dict[str, Any], playlist_id: str
) -> dict[str, Any]:
    """Serialize one explicit owned-playlist membership."""
    snippet = _snippet(item, "playlist item")
    details = optional_object(item.get("contentDetails"), "playlist item details")
    status = optional_object(item.get("status"), "playlist item status")
    return {
        "kind": "playlist_item",
        "remote_id": stable_id(item.get("id"), "playlist item ID"),
        "playlist_id": stable_id(playlist_id, "playlist ID"),
        "video_id": _resource_video_id(snippet, details),
        "title": optional_text(snippet.get("title"), "video title"),
        "description": optional_text(snippet.get("description"), "video description"),
        "published_at": optional_text(snippet.get("publishedAt"), "membership timestamp"),
        "position": integer(snippet.get("position", 0), "playlist position"),
        "privacy_status": optional_text(status.get("privacyStatus"), "privacy status"),
    }


def serialize_subscription(item: dict[str, Any]) -> dict[str, Any]:
    """Serialize one outbound subscription with explicit direction."""
    snippet = _snippet(item, "subscription")
    resource = object_value(snippet.get("resourceId"), "subscription resource ID")
    return {
        "kind": "subscription",
        "remote_id": stable_id(item.get("id"), "subscription ID"),
        "subscriber_channel_id": stable_id(
            snippet.get("channelId"), "subscriber channel ID"
        ),
        "subscribed_channel_id": stable_id(
            resource.get("channelId"), "subscribed channel ID"
        ),
        "title": optional_text(snippet.get("title"), "subscribed channel title"),
        "description": optional_text(
            snippet.get("description"), "subscribed channel description"
        ),
        "published_at": optional_text(
            snippet.get("publishedAt"), "subscription timestamp"
        ),
    }


def serialize_comment(item: dict[str, Any], parent_id: str | None) -> dict[str, Any]:
    """Serialize one top-level comment or reply."""
    snippet = _snippet(item, "comment")
    author = optional_object(snippet.get("authorChannelId"), "comment author channel")
    resolved_parent = optional_id(
        snippet.get("parentId", parent_id), "comment parent ID"
    )
    return {
        "kind": "comment",
        "remote_id": stable_id(item.get("id"), "comment ID"),
        "parent_id": resolved_parent,
        "video_id": optional_id(snippet.get("videoId"), "comment video ID"),
        "channel_id": optional_id(snippet.get("channelId"), "comment channel ID"),
        "author_channel_id": optional_id(author.get("value"), "author channel ID"),
        "author_display_name": optional_text(
            snippet.get("authorDisplayName"), "comment author name"
        ),
        "text": optional_text(
            snippet.get("textOriginal", snippet.get("textDisplay")), "comment text"
        ),
        "published_at": optional_text(
            snippet.get("publishedAt"), "comment timestamp"
        ),
        "updated_at": optional_text(snippet.get("updatedAt"), "comment update time"),
    }


def serialize_comment_thread(item: dict[str, Any]) -> tuple[dict[str, Any], int]:
    """Serialize a thread's top-level comment and declared reply count."""
    snippet = _snippet(item, "comment thread")
    top_level = object_value(snippet.get("topLevelComment"), "top-level comment")
    return (
        serialize_comment(top_level, None),
        integer(snippet.get("totalReplyCount", 0), "reply count"),
    )


def serialize_activity(item: dict[str, Any]) -> dict[str, Any]:
    """Serialize one documented channel activity resource."""
    snippet = _snippet(item, "activity")
    details = optional_object(item.get("contentDetails"), "activity details")
    activity_type = required_text(snippet.get("type"), "activity type")
    detail = optional_object(details.get(activity_type), "activity type details")
    resource = optional_object(detail.get("resourceId"), "activity resource ID")
    subject_id = None
    subject_kind = optional_text(resource.get("kind"), "activity resource kind")
    for candidate in (
        detail.get("videoId"),
        detail.get("playlistId"),
        resource.get("videoId"),
        resource.get("channelId"),
        resource.get("playlistId"),
    ):
        if candidate is not None:
            subject_id = stable_id(candidate, "activity subject ID")
            break
    return {
        "kind": "activity",
        "remote_id": stable_id(item.get("id"), "activity ID"),
        "activity_type": activity_type,
        "title": optional_text(snippet.get("title"), "activity title"),
        "description": optional_text(snippet.get("description"), "activity description"),
        "published_at": optional_text(snippet.get("publishedAt"), "activity timestamp"),
        "channel_id": optional_id(snippet.get("channelId"), "channel ID"),
        "channel_title": optional_text(snippet.get("channelTitle"), "channel title"),
        "subject_id": subject_id,
        "subject_kind": subject_kind,
    }
