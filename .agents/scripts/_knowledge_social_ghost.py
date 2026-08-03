#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Ghost publication stream policy and durable snapshot checkpoints."""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from _knowledge_social_ghost_identity import (
    GhostAdapterError,
    GhostProviderUnavailableError,
    instance_id,
    namespaced_id,
    provider_account_id,
)
from _knowledge_social_oauth_request import OAuthPageRequest
from knowledge_social_import import canonical_json, reject_credentials

PROVIDER = "ghost"
CURSOR_PREFIX = "ghost-v1:"
RETENTION_LIMIT = "current_publication_visibility_and_operator_retention"
MAX_PAGE_ITEMS = 100
ACCOUNT_AUTH_MODE = "content_api_key"

ADAPTER_ERROR = GhostAdapterError
PROVIDER_UNAVAILABLE_ERROR = GhostProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    """Static collection and coverage policy for one Ghost stream."""

    resource_kind: str
    activity_mode: str
    pagination: str
    incremental: bool
    retention_limit: str | None
    coverage_status: str | None = None
    unavailable_reason: str | None = None
    cost_units: int = 2


def _snapshot(resource_kind: str, activity_mode: str) -> StreamSpec:
    return StreamSpec(
        resource_kind,
        activity_mode,
        "snapshot",
        False,
        RETENTION_LIMIT,
    )


STREAMS = {
    "posts": _snapshot("post", "content_author"),
    "pages": _snapshot("page", "content_author"),
    "tags": _snapshot("tag", "selected_account"),
    "authors": _snapshot("author", "selected_account"),
}


class PageRequest(OAuthPageRequest):
    """Allowlisted bounded request passed to the Ghost HTTP subprocess."""

    HANDLE_KEY = "site_id"

    @property
    def site_id(self) -> str:
        return self.handle


PAGE_REQUEST_KEYS = {
    "action",
    "stream",
    "account_id",
    "provider_account_id",
    "site_id",
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
        raise GhostAdapterError(f"Ghost {field} is invalid")
    return value


def _position(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise GhostAdapterError(f"Ghost {field} must be positive")
    return value


def _encode_cursor(position: int) -> str:
    encoded = base64.urlsafe_b64encode(
        canonical_json({"position": position}).encode()
    ).decode("ascii").rstrip("=")
    return f"{CURSOR_PREFIX}{encoded}"


def _decode_cursor(cursor: str) -> int:
    if not cursor.startswith(CURSOR_PREFIX):
        raise GhostAdapterError("stored Ghost cursor has an unsupported version")
    encoded = cursor.removeprefix(CURSOR_PREFIX)
    try:
        parsed = json.loads(
            base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
        )
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise GhostAdapterError("stored Ghost cursor is invalid") from error
    if not isinstance(parsed, dict) or set(parsed) != {"position"}:
        raise GhostAdapterError("stored Ghost cursor has an invalid shape")
    reject_credentials(parsed)
    return _position(parsed["position"], "cursor position")


def page_request(
    stream: str,
    account: dict[str, Any],
    state: CursorState,
    limit: int,
) -> PageRequest:
    """Build one allowlisted request from durable per-stream state."""
    if stream not in STREAMS:
        raise GhostAdapterError("Ghost stream is unsupported")
    selected_id = _checkpoint_id(account.get("id"), "selected account ID")
    if selected_id is None:
        raise GhostAdapterError("verified Ghost identity is incomplete")
    site = provider_account_id(account.get("provider_account_id"))
    position = _decode_cursor(state.cursor) if state.cursor else 1
    return PageRequest(
        stream,
        selected_id,
        site,
        provider_account_id(account.get("site_id")),
        instance_id(account.get("instance_id")),
        position,
        None,
        limit,
    )


def _request_values(payload: dict[str, Any]) -> tuple[str, str, int, int]:
    """Validate scalar request fields before constructing the boundary object."""
    if set(payload) != PAGE_REQUEST_KEYS or payload.get("action") != "page":
        raise GhostAdapterError("Ghost read request has an invalid action shape")
    stream = payload.get("stream")
    if not isinstance(stream, str) or stream not in STREAMS:
        raise GhostAdapterError("Ghost stream is unsupported")
    limit = payload.get("limit")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
        raise GhostAdapterError("Ghost page size is invalid")
    account_id = _checkpoint_id(payload.get("account_id"), "selected account ID")
    if account_id is None:
        raise GhostAdapterError("Ghost selected account ID is required")
    if payload.get("stop_at") is not None:
        raise GhostAdapterError("Ghost snapshot request cannot contain a watermark")
    return stream, account_id, _position(payload.get("position"), "page position"), limit


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    """Validate the exact child-process page request shape."""
    stream, account_id, position, limit = _request_values(payload)
    return PageRequest(
        stream,
        account_id,
        provider_account_id(payload.get("provider_account_id")),
        provider_account_id(payload.get("site_id")),
        instance_id(payload.get("instance_id")),
        position,
        None,
        limit,
    )


def response_status(payload: dict[str, Any]) -> int:
    """Return a validated HTTP-like status from a Ghost response."""
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise GhostAdapterError("Ghost response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise GhostAdapterError("Ghost page data must be an array")
    return data


@dataclass(frozen=True)
class PageMetadata:
    next_position: int | None
    newest_id: str | None
    complete: bool


def _validated_meta(payload: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    """Return credential-free metadata bound to the requested stream and site."""
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise GhostAdapterError("Ghost page metadata must be an object")
    reject_credentials(meta)
    if meta.get("stream") != request.stream:
        raise GhostAdapterError("Ghost page provenance is invalid")
    if instance_id(meta.get("instance_id")) != request.instance_id:
        raise GhostAdapterError("Ghost page provenance is invalid")
    if meta.get("snapshot") is not True:
        raise GhostAdapterError("Ghost page pagination metadata is invalid")
    return meta


def _page_metadata(payload: dict[str, Any], request: PageRequest) -> PageMetadata:
    meta = _validated_meta(payload, request)
    next_value = meta.get("next_position")
    next_position = None if next_value is None else _position(next_value, "next page")
    if next_position is not None and next_position <= request.position:
        raise GhostAdapterError("Ghost next page position did not advance")
    complete = meta.get("complete")
    if not isinstance(complete, bool) or complete == (next_position is not None):
        raise GhostAdapterError("Ghost page completion cursor is invalid")
    return PageMetadata(
        next_position,
        _checkpoint_id(meta.get("newest_id"), "newest ID", optional=True),
        complete,
    )


def page_checkpoint(
    payload: dict[str, Any],
    state: CursorState,
    request: PageRequest,
) -> tuple[PageCheckpoint, bool]:
    """Calculate one atomic per-installation, per-stream checkpoint."""
    meta = _page_metadata(payload, request)
    if len(page_data(payload)) > MAX_PAGE_ITEMS:
        raise GhostAdapterError("Ghost page exceeds the item safety limit")
    next_cursor = _encode_cursor(meta.next_position) if meta.next_position else None
    return PageCheckpoint(next_cursor, state.watermark), meta.complete
