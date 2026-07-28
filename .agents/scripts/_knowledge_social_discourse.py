#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Discourse stream policy, instance identity, and durable checkpoints."""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from _knowledge_social_discourse_identity import (
    DiscourseAdapterError,
    DiscourseProviderUnavailableError,
    instance_id,
    namespaced_id,
    provider_account_id,
    username,
)
from knowledge_social_import import canonical_json, reject_credentials

PROVIDER = "discourse"
CURSOR_PREFIX = "discourse-v1:"
RETENTION_LIMIT = "installation_policy_and_current_user_visibility"
MAX_MESSAGE_PAGE_ITEMS = 100
MAX_SNAPSHOT_ITEMS = 1000


ADAPTER_ERROR = DiscourseAdapterError
PROVIDER_UNAVAILABLE_ERROR = DiscourseProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    """Static collection and coverage policy for one Discourse stream."""

    resource_kind: str
    activity_mode: str
    pagination: str
    incremental: bool
    retention_limit: str | None
    coverage_status: str | None = None
    unavailable_reason: str | None = None
    cost_units: int = 2


def _listing(
    resource_kind: str, activity_mode: str, *, incremental: bool = True
) -> StreamSpec:
    return StreamSpec(
        resource_kind,
        activity_mode,
        "listing" if incremental else "snapshot",
        incremental,
        RETENTION_LIMIT,
    )


STREAMS = {
    "authored_topics": _listing("topic", "content_author"),
    "authored_posts": _listing("post", "content_author"),
    "likes": _listing("post", "selected_account", incremental=False),
    "bookmarks": _listing("post", "selected_account", incremental=False),
    "notifications": _listing(
        "notification", "selected_account", incremental=False
    ),
    "private_messages": StreamSpec(
        "private_message_topic",
        "selected_account",
        "snapshot",
        False,
        RETENTION_LIMIT,
        "partial",
        "private_message_topic_metadata_only",
    ),
    "sent_messages": StreamSpec(
        "private_message_topic",
        "selected_account",
        "snapshot",
        False,
        RETENTION_LIMIT,
        "partial",
        "private_message_topic_metadata_only",
    ),
    "reading_state": StreamSpec(
        "topic_state",
        "selected_account",
        "snapshot",
        False,
        RETENTION_LIMIT,
        "partial",
        "current_topic_state_not_event_history",
    ),
    "groups": StreamSpec(
        "group", "selected_account", "snapshot", False, RETENTION_LIMIT
    ),
    "category_preferences": StreamSpec(
        "category", "selected_account", "snapshot", False, RETENTION_LIMIT
    ),
}


@dataclass(frozen=True)
class PageRequest:
    """Allowlisted bounded request passed to the Discourse HTTP subprocess."""

    stream: str
    account_id: str
    provider_account_id: str
    username: str
    instance_id: str
    position: int
    stop_at: str | None
    limit: int

    def payload(self) -> dict[str, Any]:
        return {
            "action": "page",
            "stream": self.stream,
            "account_id": self.account_id,
            "provider_account_id": self.provider_account_id,
            "username": self.username,
            "instance_id": self.instance_id,
            "position": self.position,
            "stop_at": self.stop_at,
            "limit": self.limit,
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())


PAGE_REQUEST_KEYS = {
    "action",
    "stream",
    "account_id",
    "provider_account_id",
    "username",
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
        raise DiscourseAdapterError(f"Discourse {field} is invalid")
    return value


def _position(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise DiscourseAdapterError(f"Discourse {field} must be non-negative")
    return value


def _encode_cursor(position: int, stop_at: str | None) -> str:
    payload = canonical_json({"position": position, "stop_at": stop_at}).encode(
        "utf-8"
    )
    encoded = base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")
    return f"{CURSOR_PREFIX}{encoded}"


def _decode_cursor(cursor: str) -> tuple[int, str | None]:
    if not cursor.startswith(CURSOR_PREFIX):
        raise DiscourseAdapterError("stored Discourse cursor has an unsupported version")
    encoded = cursor.removeprefix(CURSOR_PREFIX)
    try:
        padding = "=" * (-len(encoded) % 4)
        parsed = json.loads(base64.urlsafe_b64decode(encoded + padding))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise DiscourseAdapterError("stored Discourse cursor is invalid") from error
    if not isinstance(parsed, dict) or set(parsed) != {"position", "stop_at"}:
        raise DiscourseAdapterError("stored Discourse cursor has an invalid shape")
    reject_credentials(parsed)
    return (
        _position(parsed["position"], "cursor position"),
        _checkpoint_id(parsed["stop_at"], "cursor watermark", optional=True),
    )


def page_request(
    stream: str,
    account: dict[str, Any],
    state: CursorState,
    limit: int,
) -> PageRequest:
    """Build one allowlisted request from durable per-stream state."""
    if stream not in STREAMS:
        raise DiscourseAdapterError("Discourse stream is unsupported")
    selected_id = _checkpoint_id(account.get("id"), "selected account ID")
    if selected_id is None:
        raise DiscourseAdapterError("verified Discourse identity is incomplete")
    local_id = provider_account_id(account.get("provider_account_id"))
    selected_username = username(account.get("username"))
    installation = instance_id(account.get("instance_id"))
    position = 0
    stop_at: str | None = None
    if state.cursor:
        position, stop_at = _decode_cursor(state.cursor)
    elif STREAMS[stream].incremental and state.backfill_complete:
        stop_at = _checkpoint_id(state.watermark, "watermark", optional=True)
    return PageRequest(
        stream,
        selected_id,
        local_id,
        selected_username,
        installation,
        position,
        stop_at,
        limit,
    )


def _request_stream(payload: dict[str, Any]) -> str:
    stream = payload.get("stream")
    if not isinstance(stream, str):
        raise DiscourseAdapterError("Discourse stream is unsupported")
    if stream not in STREAMS:
        raise DiscourseAdapterError("Discourse stream is unsupported")
    return stream


def _request_account_id(payload: dict[str, Any]) -> str:
    account_id = _checkpoint_id(payload.get("account_id"), "selected account ID")
    if account_id is None:
        raise DiscourseAdapterError("Discourse selected account ID is required")
    return account_id


def _request_limit(payload: dict[str, Any]) -> int:
    limit = payload.get("limit")
    if isinstance(limit, bool) or not isinstance(limit, int):
        raise DiscourseAdapterError("Discourse page size is invalid")
    if not 1 <= limit <= 20:
        raise DiscourseAdapterError("Discourse page size is invalid")
    return limit


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    """Validate the exact child-process page request shape."""
    if set(payload) != PAGE_REQUEST_KEYS or payload.get("action") != "page":
        raise DiscourseAdapterError("Discourse read request has an invalid action shape")
    return PageRequest(
        _request_stream(payload),
        _request_account_id(payload),
        provider_account_id(payload.get("provider_account_id")),
        username(payload.get("username")),
        instance_id(payload.get("instance_id")),
        _position(payload.get("position"), "page position"),
        _checkpoint_id(payload.get("stop_at"), "request watermark", optional=True),
        _request_limit(payload),
    )


def response_status(payload: dict[str, Any]) -> int:
    """Return a validated HTTP-like status from a Discourse response."""
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise DiscourseAdapterError("Discourse response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    """Return a validated, already allowlisted provider data array."""
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise DiscourseAdapterError("Discourse page data must be an array")
    return data


@dataclass(frozen=True)
class PageMetadata:
    """Validated checkpoint metadata returned by the HTTP child."""

    next_position: int | None
    newest_id: str | None
    reached_watermark: bool
    complete: bool
    snapshot: bool


def _completion_flag(meta: dict[str, Any], field: str) -> bool:
    value = meta.get(field)
    if not isinstance(value, bool):
        raise DiscourseAdapterError("Discourse page completion metadata is invalid")
    return value


def _page_metadata(payload: dict[str, Any], request: PageRequest) -> PageMetadata:
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise DiscourseAdapterError("Discourse page metadata must be an object")
    reject_credentials(meta)
    if meta.get("stream") != request.stream:
        raise DiscourseAdapterError("Discourse page provenance is invalid")
    if instance_id(meta.get("instance_id")) != request.instance_id:
        raise DiscourseAdapterError("Discourse page provenance is invalid")
    next_value = meta.get("next_position")
    next_position = None
    if next_value is not None:
        next_position = _position(next_value, "next page position")
    if next_position is not None and next_position <= request.position:
        raise DiscourseAdapterError("Discourse next page position did not advance")
    snapshot = meta.get("snapshot")
    if not isinstance(snapshot, bool):
        raise DiscourseAdapterError("Discourse page pagination metadata is invalid")
    return PageMetadata(
        next_position,
        _checkpoint_id(meta.get("newest_id"), "newest ID", optional=True),
        _completion_flag(meta, "reached_watermark"),
        _completion_flag(meta, "complete"),
        snapshot,
    )


def _page_item_limit(request: PageRequest) -> int:
    if request.stream in ("private_messages", "sent_messages"):
        return MAX_MESSAGE_PAGE_ITEMS
    if request.stream in ("reading_state", "groups", "category_preferences"):
        return MAX_SNAPSHOT_ITEMS
    return request.limit


def _validate_page_items(payload: dict[str, Any], request: PageRequest) -> None:
    if len(page_data(payload)) > _page_item_limit(request):
        raise DiscourseAdapterError("Discourse page exceeds the item safety limit")


def _validate_page_mode(request: PageRequest, meta: PageMetadata) -> None:
    spec = STREAMS[request.stream]
    if not spec.incremental and request.stop_at is not None:
        raise DiscourseAdapterError("Discourse snapshot cannot use a watermark")
    if meta.snapshot != (spec.pagination == "snapshot"):
        raise DiscourseAdapterError("Discourse page pagination metadata is invalid")


def _page_complete(meta: PageMetadata) -> bool:
    complete = meta.complete or meta.reached_watermark
    if complete and meta.next_position is not None:
        raise DiscourseAdapterError("complete Discourse page cannot have a next cursor")
    if not complete and meta.next_position is None:
        raise DiscourseAdapterError("partial Discourse page requires a next cursor")
    return complete


def _page_watermark(
    state: CursorState, request: PageRequest, meta: PageMetadata
) -> str | None:
    spec = STREAMS[request.stream]
    if not spec.incremental:
        return state.watermark
    if request.position != 0:
        return state.watermark
    if meta.newest_id is None:
        return state.watermark
    return meta.newest_id


def page_checkpoint(
    payload: dict[str, Any],
    state: CursorState,
    request: PageRequest,
) -> tuple[PageCheckpoint, bool]:
    """Calculate one atomic per-installation, per-stream checkpoint."""
    meta = _page_metadata(payload, request)
    _validate_page_items(payload, request)
    _validate_page_mode(request, meta)
    complete = _page_complete(meta)
    next_cursor = None
    if meta.next_position is not None:
        next_cursor = _encode_cursor(meta.next_position, request.stop_at)
    return PageCheckpoint(
        next_cursor,
        _page_watermark(state, request, meta),
    ), complete
