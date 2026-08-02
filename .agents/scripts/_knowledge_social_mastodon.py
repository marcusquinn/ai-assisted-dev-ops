#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Mastodon stream policy, instance identity, and opaque Link checkpoints."""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from _knowledge_social_mastodon_identity import (
    MastodonAdapterError,
    MastodonProviderUnavailableError,
    account_handle,
    instance_id,
    namespaced_id,
    provider_account_id,
)
from _knowledge_social_oauth_request import OAuthPageRequest
from knowledge_social_import import canonical_json, reject_credentials

PROVIDER = "mastodon"
CURSOR_PREFIX = "mastodon-link-v1:"
RETENTION_LIMIT = "instance_policy_federation_and_current_account_visibility"
MAX_PAGE_ITEMS = 100
ACCOUNT_AUTH_MODE = "user_token"

ADAPTER_ERROR = MastodonAdapterError
PROVIDER_UNAVAILABLE_ERROR = MastodonProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    resource_kind: str
    activity_mode: str
    pagination: str = "snapshot"
    incremental: bool = False
    retention_limit: str | None = RETENTION_LIMIT
    coverage_status: str | None = "partial"
    unavailable_reason: str | None = "instance_policy_and_federation_bound"
    cost_units: int = 2


STREAMS = {
    "authored_statuses": StreamSpec("status", "content_author"),
    "favourites": StreamSpec("status", "selected_account"),
    "bookmarks": StreamSpec("status", "selected_account"),
    "notifications": StreamSpec("notification", "selected_account"),
    "followers": StreamSpec("account", "relationship"),
    "following": StreamSpec("account", "relationship"),
    "followed_tags": StreamSpec("tag", "selected_account"),
    "lists": StreamSpec("list", "selected_account"),
}


class PageRequest(OAuthPageRequest):
    """Allowlisted request carrying an opaque next-link in stop_at."""

    HANDLE_KEY = "acct"

    @property
    def acct(self) -> str:
        return self.handle


PAGE_REQUEST_KEYS = {
    "action", "stream", "account_id", "provider_account_id", "acct",
    "instance_id", "position", "stop_at", "limit",
}


def _text(value: Any, field: str, *, optional: bool = False, limit: int = 8192) -> str | None:
    if value is None and optional:
        return None
    if not isinstance(value, str) or not value or "\x00" in value:
        raise MastodonAdapterError(f"Mastodon {field} is invalid")
    if len(value.encode("utf-8")) > limit:
        raise MastodonAdapterError(f"Mastodon {field} is invalid")
    return value


def _position(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise MastodonAdapterError("Mastodon page position must be positive")
    return value


def _encode_cursor(position: int, next_url: str) -> str:
    payload = canonical_json({"next_url": next_url, "position": position}).encode()
    encoded = base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")
    return f"{CURSOR_PREFIX}{encoded}"


def _decode_cursor(cursor: str) -> tuple[int, str]:
    if not cursor.startswith(CURSOR_PREFIX):
        raise MastodonAdapterError("stored Mastodon cursor has an unsupported version")
    try:
        raw = cursor.removeprefix(CURSOR_PREFIX)
        parsed = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise MastodonAdapterError("stored Mastodon cursor is invalid") from error
    if not isinstance(parsed, dict) or set(parsed) != {"next_url", "position"}:
        raise MastodonAdapterError("stored Mastodon cursor has an invalid shape")
    reject_credentials(parsed)
    next_url = _text(parsed["next_url"], "next link")
    if next_url is None:
        raise MastodonAdapterError("stored Mastodon cursor is invalid")
    return _position(parsed["position"]), next_url


def _request_identity(identity: dict[str, Any]) -> tuple[str, str, str]:
    """Validate fields shared by collection and provider requests."""
    return (
        provider_account_id(identity.get("provider_account_id")),
        account_handle(identity.get("acct")),
        instance_id(identity.get("instance_id")),
    )


def page_request(stream: str, account: dict[str, Any], state: CursorState, limit: int) -> PageRequest:
    if stream not in STREAMS:
        raise MastodonAdapterError("Mastodon stream is unsupported")
    position, next_url = (1, None)
    if state.cursor:
        position, next_url = _decode_cursor(state.cursor)
    selected_id = _text(account.get("id"), "selected account ID")
    if selected_id is None:
        raise MastodonAdapterError("verified Mastodon identity is incomplete")
    return PageRequest(
        stream, selected_id, *_request_identity(account), position, next_url, limit,
    )


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    if set(payload) != PAGE_REQUEST_KEYS or payload.get("action") != "page":
        raise MastodonAdapterError("Mastodon read request has an invalid action shape")
    stream = payload.get("stream")
    if not isinstance(stream, str) or stream not in STREAMS:
        raise MastodonAdapterError("Mastodon stream is unsupported")
    limit = payload.get("limit")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
        raise MastodonAdapterError("Mastodon page size is invalid")
    account_id = _text(payload.get("account_id"), "selected account ID")
    if account_id is None:
        raise MastodonAdapterError("Mastodon selected account ID is required")
    return PageRequest(
        stream,
        account_id,
        *_request_identity(payload),
        _position(payload.get("position")),
        _text(payload.get("stop_at"), "next link", optional=True),
        limit,
    )


def response_status(payload: dict[str, Any]) -> int:
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise MastodonAdapterError("Mastodon response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise MastodonAdapterError("Mastodon page data must be an array")
    return data


def page_checkpoint(
    payload: dict[str, Any], state: CursorState, request: PageRequest
) -> tuple[PageCheckpoint, bool]:
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise MastodonAdapterError("Mastodon page metadata must be an object")
    reject_credentials(meta)
    if meta.get("stream") != request.stream or instance_id(meta.get("instance_id")) != request.instance_id:
        raise MastodonAdapterError("Mastodon page provenance is invalid")
    if meta.get("snapshot") is not True:
        raise MastodonAdapterError("Mastodon page pagination metadata is invalid")
    if len(page_data(payload)) > MAX_PAGE_ITEMS:
        raise MastodonAdapterError("Mastodon page exceeds the item safety limit")
    next_url = _text(meta.get("next_url"), "next link", optional=True)
    complete = meta.get("complete")
    if not isinstance(complete, bool) or complete == (next_url is not None):
        raise MastodonAdapterError("Mastodon page completion cursor is invalid")
    cursor = _encode_cursor(request.position + 1, next_url) if next_url else None
    return PageCheckpoint(cursor, state.watermark), complete
