#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""NodeBB stream policy, instance identity, and durable checkpoints."""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from _knowledge_social_nodebb_identity import (
    NodeBBAdapterError,
    NodeBBProviderUnavailableError,
    instance_id,
    namespaced_id,
    provider_account_id,
    userslug,
)
from _knowledge_social_oauth_request import OAuthPageRequest
from knowledge_social_import import canonical_json, reject_credentials

PROVIDER = "nodebb"
CURSOR_PREFIX = "nodebb-v1:"
RETENTION_LIMIT = "installation_policy_and_current_account_visibility"
MAX_LEGACY_PAGE_ITEMS = 100
ACCOUNT_AUTH_MODE = "user"

ADAPTER_ERROR = NodeBBAdapterError
PROVIDER_UNAVAILABLE_ERROR = NodeBBProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    """Static collection and coverage policy for one NodeBB stream."""

    resource_kind: str
    activity_mode: str
    pagination: str
    incremental: bool
    retention_limit: str | None
    coverage_status: str | None = None
    unavailable_reason: str | None = None
    cost_units: int = 2


@dataclass(frozen=True)
class StreamOptions:
    """Optional pagination and coverage policy for a NodeBB stream."""

    incremental: bool = False
    partial: str | None = None
    cost_units: int = 2


def _listing(
    resource_kind: str,
    activity_mode: str,
    options: StreamOptions = StreamOptions(),
) -> StreamSpec:
    return StreamSpec(
        resource_kind,
        activity_mode,
        "listing" if options.incremental else "snapshot",
        options.incremental,
        RETENTION_LIMIT,
        "partial" if options.partial else None,
        options.partial,
        options.cost_units,
    )


STREAMS = {
    "capabilities": _listing(
        "installation_capability",
        "selected_account",
        StreamOptions(partial="public_core_capabilities_only", cost_units=3),
    ),
    "authored_topics": _listing(
        "topic", "content_author", StreamOptions(incremental=True)
    ),
    "authored_posts": _listing(
        "post", "content_author", StreamOptions(incremental=True)
    ),
    "upvoted": _listing("post", "selected_account"),
    "downvoted": _listing("post", "selected_account"),
    "bookmarks": _listing("post", "selected_account"),
    "watched_topics": _listing("topic", "selected_account"),
    "category_state": _listing("category", "selected_account"),
    "following": _listing("user", "selected_account"),
    "followers": _listing("user", "selected_account"),
    "groups": _listing("group", "selected_account"),
    "notifications": _listing("notification", "selected_account"),
    "chat_rooms": _listing(
        "chat_room",
        "selected_account",
        StreamOptions(partial="room_metadata_without_message_bodies"),
    ),
}


class PageRequest(OAuthPageRequest):
    """Allowlisted bounded request passed to the NodeBB HTTP subprocess."""

    HANDLE_KEY = "userslug"

    @property
    def userslug(self) -> str:
        return self.handle


PAGE_REQUEST_KEYS = {
    "action",
    "stream",
    "account_id",
    "provider_account_id",
    "userslug",
    "instance_id",
    "position",
    "stop_at",
    "limit",
}


def _checkpoint_id(value: Any, field: str, *, optional: bool = False) -> str | None:
    if value is None and optional:
        return None
    if (
        not isinstance(value, str)
        or not value
        or "\x00" in value
        or len(value.encode("utf-8")) > 512
    ):
        raise NodeBBAdapterError(f"NodeBB {field} is invalid")
    return value


def _position(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise NodeBBAdapterError(f"NodeBB {field} must be non-negative")
    return value


def _encode_cursor(position: int, stop_at: str | None) -> str:
    payload = canonical_json({"position": position, "stop_at": stop_at}).encode()
    encoded = base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")
    return f"{CURSOR_PREFIX}{encoded}"


def _decode_cursor(cursor: str) -> tuple[int, str | None]:
    if not cursor.startswith(CURSOR_PREFIX):
        raise NodeBBAdapterError("stored NodeBB cursor has an unsupported version")
    encoded = cursor.removeprefix(CURSOR_PREFIX)
    try:
        parsed = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise NodeBBAdapterError("stored NodeBB cursor is invalid") from error
    if not isinstance(parsed, dict) or set(parsed) != {"position", "stop_at"}:
        raise NodeBBAdapterError("stored NodeBB cursor has an invalid shape")
    reject_credentials(parsed)
    return (
        _position(parsed["position"], "cursor position"),
        _checkpoint_id(parsed["stop_at"], "cursor watermark", optional=True),
    )


def _initial_position(stream: str) -> int:
    return 0 if stream in ("capabilities", "chat_rooms") else 1


def page_request(
    stream: str,
    account: dict[str, Any],
    state: CursorState,
    limit: int,
) -> PageRequest:
    """Build one allowlisted request from durable per-stream state."""
    if stream not in STREAMS:
        raise NodeBBAdapterError("NodeBB stream is unsupported")
    selected_id = _checkpoint_id(account.get("id"), "selected account ID")
    if selected_id is None:
        raise NodeBBAdapterError("verified NodeBB identity is incomplete")
    position = _initial_position(stream)
    stop_at: str | None = None
    if state.cursor:
        position, stop_at = _decode_cursor(state.cursor)
    elif STREAMS[stream].incremental and state.backfill_complete:
        stop_at = _checkpoint_id(state.watermark, "watermark", optional=True)
    return PageRequest(
        stream,
        selected_id,
        provider_account_id(account.get("provider_account_id")),
        userslug(account.get("userslug")),
        instance_id(account.get("instance_id")),
        position,
        stop_at,
        limit,
    )


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    """Validate the exact child-process page request shape."""
    if set(payload) != PAGE_REQUEST_KEYS or payload.get("action") != "page":
        raise NodeBBAdapterError("NodeBB read request has an invalid action shape")
    stream = payload.get("stream")
    if not isinstance(stream, str) or stream not in STREAMS:
        raise NodeBBAdapterError("NodeBB stream is unsupported")
    limit = payload.get("limit")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 50:
        raise NodeBBAdapterError("NodeBB page size is invalid")
    account_id = _checkpoint_id(payload.get("account_id"), "selected account ID")
    if account_id is None:
        raise NodeBBAdapterError("NodeBB selected account ID is required")
    return PageRequest(
        stream,
        account_id,
        provider_account_id(payload.get("provider_account_id")),
        userslug(payload.get("userslug")),
        instance_id(payload.get("instance_id")),
        _position(payload.get("position"), "page position"),
        _checkpoint_id(payload.get("stop_at"), "request watermark", optional=True),
        limit,
    )


def response_status(payload: dict[str, Any]) -> int:
    """Return a validated HTTP-like status from a NodeBB response."""
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise NodeBBAdapterError("NodeBB response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise NodeBBAdapterError("NodeBB page data must be an array")
    return data


@dataclass(frozen=True)
class PageMetadata:
    next_position: int | None
    newest_id: str | None
    reached_watermark: bool
    complete: bool
    snapshot: bool


def _flag(meta: dict[str, Any], field: str) -> bool:
    value = meta.get(field)
    if not isinstance(value, bool):
        raise NodeBBAdapterError("NodeBB page completion metadata is invalid")
    return value


def _page_metadata(payload: dict[str, Any], request: PageRequest) -> PageMetadata:
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise NodeBBAdapterError("NodeBB page metadata must be an object")
    reject_credentials(meta)
    if meta.get("stream") != request.stream:
        raise NodeBBAdapterError("NodeBB page provenance is invalid")
    if instance_id(meta.get("instance_id")) != request.instance_id:
        raise NodeBBAdapterError("NodeBB page provenance is invalid")
    next_value = meta.get("next_position")
    next_position = None if next_value is None else _position(next_value, "next page position")
    if next_position is not None and next_position <= request.position:
        raise NodeBBAdapterError("NodeBB next page position did not advance")
    snapshot = meta.get("snapshot")
    if not isinstance(snapshot, bool):
        raise NodeBBAdapterError("NodeBB page pagination metadata is invalid")
    return PageMetadata(
        next_position,
        _checkpoint_id(meta.get("newest_id"), "newest ID", optional=True),
        _flag(meta, "reached_watermark"),
        _flag(meta, "complete"),
        snapshot,
    )


def page_checkpoint(
    payload: dict[str, Any],
    state: CursorState,
    request: PageRequest,
) -> tuple[PageCheckpoint, bool]:
    """Calculate one atomic per-installation, per-stream checkpoint."""
    meta = _page_metadata(payload, request)
    item_limit = request.limit if request.stream == "chat_rooms" else MAX_LEGACY_PAGE_ITEMS
    if request.stream == "capabilities":
        item_limit = 1
    if len(page_data(payload)) > item_limit:
        raise NodeBBAdapterError("NodeBB page exceeds the item safety limit")
    spec = STREAMS[request.stream]
    if meta.snapshot != (spec.pagination == "snapshot"):
        raise NodeBBAdapterError("NodeBB page pagination metadata is invalid")
    complete = meta.complete or meta.reached_watermark
    if complete == (meta.next_position is not None):
        raise NodeBBAdapterError("NodeBB page completion cursor is invalid")
    next_cursor = None
    if meta.next_position is not None:
        next_cursor = _encode_cursor(meta.next_position, request.stop_at)
    watermark = state.watermark
    if spec.incremental and request.position == _initial_position(request.stream):
        watermark = meta.newest_id or watermark
    return PageCheckpoint(next_cursor, watermark), complete
