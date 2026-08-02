#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Stack Exchange stream policy and independent per-site page checkpoints."""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from _knowledge_social_stack_exchange_identity import (
    StackExchangeAdapterError,
    StackExchangeProviderUnavailableError,
    api_site_parameter,
    network_account_id,
    site_user_id,
)
from knowledge_social_import import canonical_json, reject_credentials

PROVIDER = "stack-exchange"
CURSOR_PREFIX = "stack-exchange-page-v1:"
RETENTION_LIMIT = "site_visibility_token_scope_and_api_history_bound"
MAX_PAGE_ITEMS = 100

ADAPTER_ERROR = StackExchangeAdapterError
PROVIDER_UNAVAILABLE_ERROR = StackExchangeProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    resource_kind: str
    activity_mode: str
    pagination: str = "snapshot"
    incremental: bool = False
    retention_limit: str | None = RETENTION_LIMIT
    coverage_status: str | None = "partial"
    unavailable_reason: str | None = "site_visibility_and_api_history_bound"
    cost_units: int = 2


STREAMS = {
    "posts": StreamSpec("post", "content_author"),
    "questions": StreamSpec("question", "content_author"),
    "answers": StreamSpec("answer", "content_author"),
    "comments": StreamSpec("comment", "content_author"),
    "favorites": StreamSpec("question", "selected_account"),
    "inbox": StreamSpec("inbox_item", "selected_account"),
    "notifications": StreamSpec("notification", "selected_account"),
    "associated_accounts": StreamSpec("account", "network_membership"),
}


@dataclass(frozen=True)
class PageRequest:
    stream: str
    account_id: str
    network_account_id: str
    site_user_id: str
    api_site_parameter: str
    page: int
    limit: int

    def payload(self) -> dict[str, Any]:
        return {
            "action": "page",
            "stream": self.stream,
            "account_id": self.account_id,
            "network_account_id": self.network_account_id,
            "site_user_id": self.site_user_id,
            "api_site_parameter": self.api_site_parameter,
            "page": self.page,
            "limit": self.limit,
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())


PAGE_REQUEST_KEYS = {
    "action", "stream", "account_id", "network_account_id", "site_user_id",
    "api_site_parameter", "page", "limit",
}


def _text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value or len(value.encode()) > 4096:
        raise StackExchangeAdapterError(f"Stack Exchange {field} is invalid")
    return value


def _page(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 100000:
        raise StackExchangeAdapterError("Stack Exchange page is invalid")
    return value


def _encode_cursor(page: int, site: str) -> str:
    payload = canonical_json({"page": page, "site": site}).encode()
    encoded = base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")
    return f"{CURSOR_PREFIX}{encoded}"


def _decode_cursor(cursor: str, site: str) -> int:
    if not cursor.startswith(CURSOR_PREFIX):
        raise StackExchangeAdapterError(
            "stored Stack Exchange cursor has an unsupported version"
        )
    try:
        raw = cursor.removeprefix(CURSOR_PREFIX)
        parsed = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise StackExchangeAdapterError("stored Stack Exchange cursor is invalid") from error
    if not isinstance(parsed, dict) or set(parsed) != {"page", "site"}:
        raise StackExchangeAdapterError("stored Stack Exchange cursor has an invalid shape")
    reject_credentials(parsed)
    if api_site_parameter(parsed.get("site")) != site:
        raise StackExchangeAdapterError("stored Stack Exchange cursor belongs to another site")
    return _page(parsed.get("page"))


def page_request(stream: str, account: dict[str, Any], state: CursorState, limit: int) -> PageRequest:
    if stream not in STREAMS:
        raise StackExchangeAdapterError("Stack Exchange stream is unsupported")
    site = api_site_parameter(account.get("api_site_parameter"))
    page = _decode_cursor(state.cursor, site) if state.cursor else 1
    return PageRequest(
        stream,
        _text(account.get("id"), "selected account ID"),
        network_account_id(account.get("network_account_id")),
        site_user_id(account.get("site_user_id")),
        site,
        page,
        limit,
    )


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    if set(payload) != PAGE_REQUEST_KEYS or payload.get("action") != "page":
        raise StackExchangeAdapterError("Stack Exchange read request has an invalid action shape")
    stream = payload.get("stream")
    if not isinstance(stream, str) or stream not in STREAMS:
        raise StackExchangeAdapterError("Stack Exchange stream is unsupported")
    limit = payload.get("limit")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
        raise StackExchangeAdapterError("Stack Exchange page size is invalid")
    return PageRequest(
        stream,
        _text(payload.get("account_id"), "selected account ID"),
        network_account_id(payload.get("network_account_id")),
        site_user_id(payload.get("site_user_id")),
        api_site_parameter(payload.get("api_site_parameter")),
        _page(payload.get("page")),
        limit,
    )


def response_status(payload: dict[str, Any]) -> int:
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise StackExchangeAdapterError("Stack Exchange response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise StackExchangeAdapterError("Stack Exchange page data must be an array")
    return data


def page_checkpoint(
    payload: dict[str, Any], state: CursorState, request: PageRequest
) -> tuple[PageCheckpoint, bool]:
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise StackExchangeAdapterError("Stack Exchange page metadata must be an object")
    reject_credentials(meta)
    if (
        meta.get("stream") != request.stream
        or api_site_parameter(meta.get("api_site_parameter")) != request.api_site_parameter
    ):
        raise StackExchangeAdapterError("Stack Exchange page provenance is invalid")
    if meta.get("snapshot") is not True or len(page_data(payload)) > MAX_PAGE_ITEMS:
        raise StackExchangeAdapterError("Stack Exchange page metadata is invalid")
    has_more = meta.get("has_more")
    if not isinstance(has_more, bool):
        raise StackExchangeAdapterError("Stack Exchange has_more must be boolean")
    cursor = _encode_cursor(request.page + 1, request.api_site_parameter) if has_more else None
    return PageCheckpoint(cursor, state.watermark), not has_more
