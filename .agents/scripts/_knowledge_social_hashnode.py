#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Hashnode stream policy and opaque GraphQL connection checkpoints."""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from _knowledge_social_hashnode_identity import (
    HashnodeAdapterError,
    HashnodeProviderUnavailableError,
    instance_id,
    provider_account_id,
    username,
)
from _knowledge_social_oauth_request import OAuthPageRequest
from knowledge_social_import import canonical_json, reject_credentials

PROVIDER = "hashnode"
CURSOR_PREFIX = "hashnode-page-v1:"
RETENTION_LIMIT = "account_active_or_provider_visibility_and_pro_plan_bound"
MAX_PAGE_ITEMS = 50

ADAPTER_ERROR = HashnodeAdapterError
PROVIDER_UNAVAILABLE_ERROR = HashnodeProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    resource_kind: str
    activity_mode: str
    transport: str = "graphql"
    pagination: str = "snapshot"
    incremental: bool = False
    retention_limit: str | None = RETENTION_LIMIT
    coverage_status: str | None = "partial"
    unavailable_reason: str | None = "current_api_visibility_and_plan_bound"
    cost_units: int = 2


STREAMS = {
    "profile": StreamSpec("profile", "selected_account"),
    "publications": StreamSpec("publication", "publication_owner"),
    "posts": StreamSpec("post", "content_author"),
    "drafts": StreamSpec("draft", "content_author"),
    "comments": StreamSpec("comment", "comment_received"),
    "reactions": StreamSpec("reaction", "reaction_received"),
    "followers": StreamSpec("account", "follower"),
    "following": StreamSpec("account", "following"),
}


class PageRequest(OAuthPageRequest):
    HANDLE_KEY = "username"

    @property
    def username(self) -> str:
        return self.handle


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


def _text(value: Any, field: str, *, optional: bool = False) -> str | None:
    if value is None and optional:
        return None
    if not isinstance(value, str) or not value or "\x00" in value:
        raise HashnodeAdapterError(f"Hashnode {field} is invalid")
    if len(value.encode()) > 64 * 1024:
        raise HashnodeAdapterError(f"Hashnode {field} is invalid")
    return value


def _position(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise HashnodeAdapterError("Hashnode page position must be positive")
    return value


def _encode_cursor(position: int, state: str) -> str:
    payload = canonical_json({"position": position, "state": state}).encode()
    encoded = base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")
    return f"{CURSOR_PREFIX}{encoded}"


def _decode_cursor(cursor: str) -> tuple[int, str]:
    if not cursor.startswith(CURSOR_PREFIX):
        raise HashnodeAdapterError("stored Hashnode cursor has an unsupported version")
    try:
        raw = cursor.removeprefix(CURSOR_PREFIX)
        parsed = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise HashnodeAdapterError("stored Hashnode cursor is invalid") from error
    if not isinstance(parsed, dict) or set(parsed) != {"position", "state"}:
        raise HashnodeAdapterError("stored Hashnode cursor has an invalid shape")
    reject_credentials(parsed)
    state = _text(parsed.get("state"), "cursor state")
    if state is None:
        raise HashnodeAdapterError("stored Hashnode cursor is invalid")
    return _position(parsed.get("position")), state


def page_request(
    stream: str, account: dict[str, Any], state: CursorState, limit: int
) -> PageRequest:
    if stream not in STREAMS:
        raise HashnodeAdapterError("Hashnode stream is unsupported")
    position, cursor = (1, None)
    if state.cursor:
        position, cursor = _decode_cursor(state.cursor)
    selected = _text(account.get("id"), "selected account ID")
    if selected is None:
        raise HashnodeAdapterError("verified Hashnode identity is incomplete")
    return PageRequest(
        stream,
        selected,
        provider_account_id(account.get("provider_account_id")),
        username(account.get("username")),
        instance_id(account.get("instance_id")),
        position,
        cursor,
        limit,
    )


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    if set(payload) != PAGE_REQUEST_KEYS or payload.get("action") != "page":
        raise HashnodeAdapterError("Hashnode read request has an invalid action shape")
    stream = payload.get("stream")
    if not isinstance(stream, str) or stream not in STREAMS:
        raise HashnodeAdapterError("Hashnode stream is unsupported")
    limit = payload.get("limit")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 50:
        raise HashnodeAdapterError("Hashnode page size is invalid")
    selected = _text(payload.get("account_id"), "selected account ID")
    if selected is None:
        raise HashnodeAdapterError("Hashnode selected account ID is required")
    return PageRequest(
        stream,
        selected,
        provider_account_id(payload.get("provider_account_id")),
        username(payload.get("username")),
        instance_id(payload.get("instance_id")),
        _position(payload.get("position")),
        _text(payload.get("stop_at"), "cursor state", optional=True),
        limit,
    )


def response_status(payload: dict[str, Any]) -> int:
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise HashnodeAdapterError("Hashnode response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise HashnodeAdapterError("Hashnode page data must be an array")
    return data


def page_checkpoint(
    payload: dict[str, Any], state: CursorState, request: PageRequest
) -> tuple[PageCheckpoint, bool]:
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise HashnodeAdapterError("Hashnode page metadata must be an object")
    reject_credentials(meta)
    if (
        meta.get("stream") != request.stream
        or instance_id(meta.get("instance_id")) != request.instance_id
        or meta.get("transport") != "graphql"
        or meta.get("snapshot") is not True
    ):
        raise HashnodeAdapterError("Hashnode page provenance is invalid")
    if len(page_data(payload)) > MAX_PAGE_ITEMS:
        raise HashnodeAdapterError("Hashnode page exceeds the item safety limit")
    next_state = _text(meta.get("next_cursor"), "next cursor", optional=True)
    complete = meta.get("complete")
    if not isinstance(complete, bool) or complete == (next_state is not None):
        raise HashnodeAdapterError("Hashnode page completion cursor is invalid")
    cursor = _encode_cursor(request.position + 1, next_state) if next_state else None
    return PageCheckpoint(cursor, state.watermark), complete
