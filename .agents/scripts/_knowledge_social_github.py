#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""GitHub stream policy, durable identity, and opaque mixed-API checkpoints."""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from _knowledge_social_github_identity import (
    GitHubAdapterError,
    GitHubProviderUnavailableError,
    instance_id,
    login,
    provider_account_id,
)
from _knowledge_social_oauth_request import OAuthPageRequest
from knowledge_social_import import canonical_json, reject_credentials

PROVIDER = "github"
CURSOR_PREFIX = "github-page-v1:"
RETENTION_LIMIT = "token_capability_and_current_resource_visibility"
MAX_PAGE_ITEMS = 100

ADAPTER_ERROR = GitHubAdapterError
PROVIDER_UNAVAILABLE_ERROR = GitHubProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    resource_kind: str
    activity_mode: str
    transport: str
    pagination: str = "snapshot"
    incremental: bool = False
    retention_limit: str | None = RETENTION_LIMIT
    coverage_status: str | None = "partial"
    unavailable_reason: str | None = "token_capability_and_visibility_bound"
    cost_units: int = 3


STREAMS = {
    "contributions": StreamSpec("contribution", "content_author", "graphql"),
    "repositories": StreamSpec("repository", "selected_account", "rest"),
    "stars": StreamSpec("repository", "selected_account", "rest"),
    "notifications": StreamSpec("notification", "selected_account", "rest"),
    "followers": StreamSpec("account", "relationship", "rest"),
    "following": StreamSpec("account", "relationship", "rest"),
    "organizations": StreamSpec("organization", "membership", "rest"),
    "subscriptions": StreamSpec("repository", "selected_account", "rest"),
    "user_lists": StreamSpec("user_list", "selected_account", "graphql"),
    "projects_v2": StreamSpec("project", "selected_account", "graphql"),
}


class PageRequest(OAuthPageRequest):
    HANDLE_KEY = "login"

    @property
    def login(self) -> str:
        return self.handle


PAGE_REQUEST_KEYS = {
    "action", "stream", "account_id", "provider_account_id", "login",
    "instance_id", "position", "stop_at", "limit",
}


def _text(value: Any, field: str, *, optional: bool = False) -> str | None:
    if value is None and optional:
        return None
    if not isinstance(value, str) or not value or "\x00" in value:
        raise GitHubAdapterError(f"GitHub {field} is invalid")
    if len(value.encode()) > 16 * 1024:
        raise GitHubAdapterError(f"GitHub {field} is invalid")
    return value


def _position(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise GitHubAdapterError("GitHub page position must be positive")
    return value


def _encode_cursor(position: int, cursor: str) -> str:
    payload = canonical_json({"cursor": cursor, "position": position}).encode()
    encoded = base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")
    return f"{CURSOR_PREFIX}{encoded}"


def _decode_cursor(cursor: str) -> tuple[int, str]:
    if not cursor.startswith(CURSOR_PREFIX):
        raise GitHubAdapterError("stored GitHub cursor has an unsupported version")
    try:
        raw = cursor.removeprefix(CURSOR_PREFIX)
        parsed = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise GitHubAdapterError("stored GitHub cursor is invalid") from error
    if not isinstance(parsed, dict) or set(parsed) != {"cursor", "position"}:
        raise GitHubAdapterError("stored GitHub cursor has an invalid shape")
    reject_credentials(parsed)
    opaque = _text(parsed.get("cursor"), "cursor")
    if opaque is None:
        raise GitHubAdapterError("stored GitHub cursor is invalid")
    return _position(parsed.get("position")), opaque


def page_request(stream: str, account: dict[str, Any], state: CursorState, limit: int) -> PageRequest:
    if stream not in STREAMS:
        raise GitHubAdapterError("GitHub stream is unsupported")
    position, cursor = (1, None)
    if state.cursor:
        position, cursor = _decode_cursor(state.cursor)
    selected = _text(account.get("id"), "selected account ID")
    if selected is None:
        raise GitHubAdapterError("verified GitHub identity is incomplete")
    return PageRequest(
        stream,
        selected,
        provider_account_id(account.get("provider_account_id")),
        login(account.get("login")),
        instance_id(account.get("instance_id")),
        position,
        cursor,
        limit,
    )


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    if set(payload) != PAGE_REQUEST_KEYS or payload.get("action") != "page":
        raise GitHubAdapterError("GitHub read request has an invalid action shape")
    stream = payload.get("stream")
    if not isinstance(stream, str) or stream not in STREAMS:
        raise GitHubAdapterError("GitHub stream is unsupported")
    limit = payload.get("limit")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
        raise GitHubAdapterError("GitHub page size is invalid")
    selected = _text(payload.get("account_id"), "selected account ID")
    if selected is None:
        raise GitHubAdapterError("GitHub selected account ID is required")
    return PageRequest(
        stream,
        selected,
        provider_account_id(payload.get("provider_account_id")),
        login(payload.get("login")),
        instance_id(payload.get("instance_id")),
        _position(payload.get("position")),
        _text(payload.get("stop_at"), "cursor", optional=True),
        limit,
    )


def response_status(payload: dict[str, Any]) -> int:
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise GitHubAdapterError("GitHub response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise GitHubAdapterError("GitHub page data must be an array")
    return data


def page_checkpoint(
    payload: dict[str, Any], state: CursorState, request: PageRequest
) -> tuple[PageCheckpoint, bool]:
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise GitHubAdapterError("GitHub page metadata must be an object")
    reject_credentials(meta)
    if meta.get("stream") != request.stream or instance_id(meta.get("instance_id")) != request.instance_id:
        raise GitHubAdapterError("GitHub page provenance is invalid")
    if meta.get("snapshot") is not True or meta.get("transport") != STREAMS[request.stream].transport:
        raise GitHubAdapterError("GitHub page pagination metadata is invalid")
    if len(page_data(payload)) > MAX_PAGE_ITEMS:
        raise GitHubAdapterError("GitHub page exceeds the item safety limit")
    next_cursor = _text(meta.get("next_cursor"), "next cursor", optional=True)
    complete = meta.get("complete")
    if not isinstance(complete, bool) or complete == (next_cursor is not None):
        raise GitHubAdapterError("GitHub page completion cursor is invalid")
    cursor = _encode_cursor(request.position + 1, next_cursor) if next_cursor else None
    return PageCheckpoint(cursor, state.watermark), complete
