#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""FreshRSS stream policy and independent continuation checkpoints."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from _knowledge_social_freshrss_cursor import (
    MAX_CURSOR_HISTORY,
    continuation_value,
    continuation_digest,
    decode_cursor,
    encode_cursor,
    positive_int,
    validate_continuation_history,
)
from _knowledge_social_freshrss_identity import (
    FreshRSSAdapterError,
    FreshRSSProviderUnavailableError,
    account_id,
    user_id,
)
from knowledge_social_import import canonical_json, reject_credentials

PROVIDER = "freshrss"
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
    seen_continuations: tuple[str, ...] = ()

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
            "seen_continuations": list(self.seen_continuations),
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())


PAGE_REQUEST_KEYS = frozenset(PageRequest.__dataclass_fields__) | {"action"}


def _text(value: Any, field: str) -> str:
    if not isinstance(value, str):
        raise FreshRSSAdapterError(f"FreshRSS {field} is invalid")
    if not value or "\x00" in value:
        raise FreshRSSAdapterError(f"FreshRSS {field} is invalid")
    if len(value.encode()) > 4096:
        raise FreshRSSAdapterError(f"FreshRSS {field} is invalid")
    return value


def _incremental_watermark(value: str | None) -> int:
    if value is None or not value.isdigit():
        raise FreshRSSAdapterError("stored FreshRSS watermark is invalid")
    return max(0, int(value) - 1)


def _request_cursor(
    stream: str, state: CursorState
) -> tuple[str | None, int | None, tuple[str, ...]]:
    if stream not in ITEM_STREAMS:
        return None, None, ()
    if state.cursor:
        return decode_cursor(state.cursor)
    if stream == "items" and state.backfill_complete:
        return None, _incremental_watermark(state.watermark), ()
    return None, None, ()


def page_request(
    stream: str, account: dict[str, Any], state: CursorState, limit: int
) -> PageRequest:
    if stream not in STREAMS:
        raise FreshRSSAdapterError("FreshRSS stream is unsupported")
    continuation, newer_than, seen = _request_cursor(stream, state)
    return PageRequest(
        stream,
        _text(account.get("id"), "selected account ID"),
        _text(account.get("installation_id"), "installation ID"),
        user_id(account.get("user_id")),
        continuation,
        newer_than,
        limit,
        seen,
    )


def _request_stream(payload: dict[str, Any]) -> str:
    stream = payload.get("stream")
    if not isinstance(stream, str) or stream not in STREAMS:
        raise FreshRSSAdapterError("FreshRSS stream is unsupported")
    return stream


def _request_limit(payload: dict[str, Any]) -> int:
    limit = positive_int(payload.get("limit"), "page size")
    if limit > MAX_PAGE_ITEMS:
        raise FreshRSSAdapterError("FreshRSS page size is invalid")
    return limit


def _request_position(
    payload: dict[str, Any], stream: str
) -> tuple[str | None, int | None, tuple[str, ...]]:
    newer_than = payload.get("newer_than")
    if newer_than is not None:
        newer_than = positive_int(newer_than, "newer-than cursor", allow_zero=True)
    continuation = continuation_value(payload.get("continuation"))
    seen = validate_continuation_history(
        payload.get("seen_continuations"), continuation, "request continuation history"
    )
    if stream not in ITEM_STREAMS:
        if continuation is not None:
            raise FreshRSSAdapterError("FreshRSS snapshot request has an invalid cursor")
        if newer_than is not None:
            raise FreshRSSAdapterError("FreshRSS snapshot request has an invalid cursor")
        if seen:
            raise FreshRSSAdapterError("FreshRSS snapshot request has an invalid cursor")
    return continuation, newer_than, seen


def _request_identity(payload: dict[str, Any]) -> tuple[str, str, str]:
    local = user_id(payload.get("user_id"))
    instance = _text(payload.get("installation_id"), "installation ID")
    selected = _text(payload.get("account_id"), "selected account ID")
    if selected != account_id(instance, local):
        raise FreshRSSAdapterError("FreshRSS account identity binding is invalid")
    return selected, instance, local


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    if set(payload) != PAGE_REQUEST_KEYS:
        raise FreshRSSAdapterError("FreshRSS read request has an invalid action shape")
    if payload.get("action") != "page":
        raise FreshRSSAdapterError("FreshRSS read request has an invalid action shape")
    stream = _request_stream(payload)
    limit = _request_limit(payload)
    continuation, newer_than, seen = _request_position(payload, stream)
    selected, instance, local = _request_identity(payload)
    return PageRequest(
        stream, selected, instance, local, continuation, newer_than, limit, seen
    )


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


def _page_meta(
    payload: dict[str, Any], request: PageRequest, item_count: int
) -> tuple[dict[str, Any], bool]:
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise FreshRSSAdapterError("FreshRSS page provenance is invalid")
    if meta.get("stream") != request.stream:
        raise FreshRSSAdapterError("FreshRSS page provenance is invalid")
    reject_credentials(meta)
    expected_snapshot = request.stream not in ITEM_STREAMS
    if item_count > request.limit:
        raise FreshRSSAdapterError("FreshRSS page metadata is invalid")
    if meta.get("snapshot") is not expected_snapshot:
        raise FreshRSSAdapterError("FreshRSS page metadata is invalid")
    has_more = meta.get("has_more")
    if not isinstance(has_more, bool):
        raise FreshRSSAdapterError("FreshRSS has_more is invalid")
    if expected_snapshot and has_more:
        raise FreshRSSAdapterError("FreshRSS has_more is invalid")
    return meta, has_more


def _next_cursor(meta: dict[str, Any], request: PageRequest, has_more: bool) -> str | None:
    next_continuation = continuation_value(meta.get("next_continuation"))
    if has_more:
        if next_continuation is None:
            raise FreshRSSAdapterError("FreshRSS continuation did not advance")
        digest = continuation_digest(next_continuation)
        if digest in request.seen_continuations:
            raise FreshRSSAdapterError("FreshRSS continuation loop was detected")
        seen = (*request.seen_continuations, digest)[-MAX_CURSOR_HISTORY:]
        return encode_cursor(next_continuation, request.newer_than, seen)
    if next_continuation is not None:
        raise FreshRSSAdapterError("FreshRSS terminal page retained a continuation")
    return None


def _next_watermark(meta: dict[str, Any], stored: str | None) -> str | None:
    observed = meta.get("watermark")
    if observed is None:
        return stored
    current = positive_int(observed, "watermark", allow_zero=True)
    previous = int(stored) if stored and stored.isdigit() else 0
    return str(max(previous, current))


def page_checkpoint(
    payload: dict[str, Any], state: CursorState, request: PageRequest
) -> tuple[PageCheckpoint, bool]:
    items = page_data(payload)
    meta, has_more = _page_meta(payload, request, len(items))
    cursor = _next_cursor(meta, request, has_more)
    watermark = state.watermark
    watermark = _next_watermark(meta, watermark)
    return PageCheckpoint(cursor, watermark), not has_more
