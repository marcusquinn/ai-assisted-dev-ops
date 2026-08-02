#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""FreshRSS stream policy and independent continuation checkpoints."""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from _knowledge_social_freshrss_identity import (
    FreshRSSAdapterError,
    FreshRSSProviderUnavailableError,
    account_id,
    user_id,
)
from knowledge_social_import import canonical_json, reject_credentials

PROVIDER = "freshrss"
CURSOR_PREFIX = "freshrss-greader-v1:"
RETENTION_LIMIT = "operator_retention_and_current_database_state"
MAX_PAGE_ITEMS = 1000

ADAPTER_ERROR = FreshRSSAdapterError
PROVIDER_UNAVAILABLE_ERROR = FreshRSSProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    resource_kind: str
    activity_mode: str
    pagination: str
    incremental: bool
    retention_limit: str | None = RETENTION_LIMIT
    coverage_status: str | None = "partial"
    unavailable_reason: str | None = "operator_retention_and_api_window"
    cost_units: int = 3


STREAMS = {
    "items": StreamSpec("entry", "content_observed", "opaque_continuation", True),
    "unread": StreamSpec("entry", "selected_account", "opaque_continuation", False),
    "starred": StreamSpec("entry", "selected_account", "opaque_continuation", False),
    "subscriptions": StreamSpec("feed", "subscription", "snapshot", False),
    "folders": StreamSpec("folder", "subscription", "snapshot", False),
    "tags": StreamSpec("tag", "selected_account", "snapshot", False),
    "opml": StreamSpec("feed", "subscription", "snapshot", False),
}
ITEM_STREAMS = frozenset({"items", "unread", "starred"})


@dataclass(frozen=True)
class PageRequest:
    stream: str
    account_id: str
    installation_id: str
    user_id: str
    continuation: str | None
    newer_than: int | None
    limit: int

    def payload(self) -> dict[str, Any]:
        return {
            "action": "page",
            "stream": self.stream,
            "account_id": self.account_id,
            "installation_id": self.installation_id,
            "user_id": self.user_id,
            "continuation": self.continuation,
            "newer_than": self.newer_than,
            "limit": self.limit,
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())


PAGE_REQUEST_KEYS = frozenset(PageRequest.__dataclass_fields__) | {"action"}


def _positive(value: Any, field: str, *, allow_zero: bool = False) -> int:
    minimum = 0 if allow_zero else 1
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise FreshRSSAdapterError(f"FreshRSS {field} is invalid")
    return value


def _text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value or len(value.encode()) > 4096:
        raise FreshRSSAdapterError(f"FreshRSS {field} is invalid")
    return value


def _continuation(value: Any) -> str | None:
    if value is None:
        return None
    if (
        not isinstance(value, str)
        or not value
        or "\x00" in value
        or len(value.encode()) > 16 * 1024
    ):
        raise FreshRSSAdapterError("FreshRSS continuation is invalid")
    return value


def _encode_cursor(continuation: str, newer_than: int | None) -> str:
    encoded = base64.urlsafe_b64encode(
        canonical_json({"continuation": continuation, "newer_than": newer_than}).encode()
    ).decode().rstrip("=")
    return f"{CURSOR_PREFIX}{encoded}"


def _decode_cursor(cursor: str) -> tuple[str, int | None]:
    if not cursor.startswith(CURSOR_PREFIX):
        raise FreshRSSAdapterError("stored FreshRSS cursor has an unsupported version")
    try:
        raw = cursor.removeprefix(CURSOR_PREFIX)
        payload = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise FreshRSSAdapterError("stored FreshRSS cursor is invalid") from error
    if not isinstance(payload, dict) or set(payload) != {"continuation", "newer_than"}:
        raise FreshRSSAdapterError("stored FreshRSS cursor has an invalid shape")
    reject_credentials(payload)
    newer_than = payload.get("newer_than")
    if newer_than is not None:
        newer_than = _positive(newer_than, "newer-than cursor", allow_zero=True)
    continuation = _continuation(payload.get("continuation"))
    if continuation is None:
        raise FreshRSSAdapterError("stored FreshRSS cursor is invalid")
    return continuation, newer_than


def page_request(
    stream: str, account: dict[str, Any], state: CursorState, limit: int
) -> PageRequest:
    if stream not in STREAMS:
        raise FreshRSSAdapterError("FreshRSS stream is unsupported")
    continuation, newer_than = _decode_cursor(state.cursor) if state.cursor else (None, None)
    if stream == "items" and state.backfill_complete and not state.cursor:
        if state.watermark is None or not state.watermark.isdigit():
            raise FreshRSSAdapterError("stored FreshRSS watermark is invalid")
        newer_than = max(0, int(state.watermark) - 1)
    if stream not in ITEM_STREAMS:
        continuation, newer_than = None, None
    return PageRequest(
        stream,
        _text(account.get("id"), "selected account ID"),
        _text(account.get("installation_id"), "installation ID"),
        user_id(account.get("user_id")),
        continuation,
        newer_than,
        limit,
    )


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    if set(payload) != PAGE_REQUEST_KEYS or payload.get("action") != "page":
        raise FreshRSSAdapterError("FreshRSS read request has an invalid action shape")
    stream = payload.get("stream")
    if not isinstance(stream, str) or stream not in STREAMS:
        raise FreshRSSAdapterError("FreshRSS stream is unsupported")
    limit = _positive(payload.get("limit"), "page size")
    if limit > MAX_PAGE_ITEMS:
        raise FreshRSSAdapterError("FreshRSS page size is invalid")
    newer_than = payload.get("newer_than")
    if newer_than is not None:
        newer_than = _positive(newer_than, "newer-than cursor", allow_zero=True)
    continuation = _continuation(payload.get("continuation"))
    if stream not in ITEM_STREAMS and (continuation is not None or newer_than is not None):
        raise FreshRSSAdapterError("FreshRSS snapshot request has an invalid cursor")
    local = user_id(payload.get("user_id"))
    instance = _text(payload.get("installation_id"), "installation ID")
    selected = _text(payload.get("account_id"), "selected account ID")
    if selected != account_id(instance, local):
        raise FreshRSSAdapterError("FreshRSS account identity binding is invalid")
    return PageRequest(stream, selected, instance, local, continuation, newer_than, limit)


def response_status(payload: dict[str, Any]) -> int:
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise FreshRSSAdapterError("FreshRSS response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise FreshRSSAdapterError("FreshRSS page data must be an array")
    return data


def page_checkpoint(
    payload: dict[str, Any], state: CursorState, request: PageRequest
) -> tuple[PageCheckpoint, bool]:
    meta = payload.get("meta")
    if not isinstance(meta, dict) or meta.get("stream") != request.stream:
        raise FreshRSSAdapterError("FreshRSS page provenance is invalid")
    reject_credentials(meta)
    items = page_data(payload)
    expected_snapshot = request.stream not in ITEM_STREAMS
    if len(items) > request.limit or meta.get("snapshot") is not expected_snapshot:
        raise FreshRSSAdapterError("FreshRSS page metadata is invalid")
    has_more = meta.get("has_more")
    if not isinstance(has_more, bool) or expected_snapshot and has_more:
        raise FreshRSSAdapterError("FreshRSS has_more is invalid")
    next_continuation = _continuation(meta.get("next_continuation"))
    if has_more and (
        next_continuation is None or next_continuation == request.continuation
    ):
        raise FreshRSSAdapterError("FreshRSS continuation did not advance")
    if not has_more and next_continuation is not None:
        raise FreshRSSAdapterError("FreshRSS terminal page retained a continuation")
    cursor = (
        _encode_cursor(next_continuation, request.newer_than)
        if next_continuation is not None
        else None
    )
    watermark = state.watermark
    observed = meta.get("watermark")
    if observed is not None:
        observed = _positive(observed, "watermark", allow_zero=True)
        previous = int(watermark) if watermark and watermark.isdigit() else 0
        watermark = str(max(previous, observed))
    return PageCheckpoint(cursor, watermark), not has_more
