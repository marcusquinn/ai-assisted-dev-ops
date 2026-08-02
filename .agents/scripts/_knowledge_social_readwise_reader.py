#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Readwise Reader stream policy and opaque cursor checkpoints."""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from _knowledge_social_readwise_reader_identity import (
    ReadwiseReaderAdapterError,
    ReadwiseReaderProviderUnavailableError,
    binding_account_id,
)
from knowledge_social_import import canonical_json, reject_credentials

PROVIDER = "readwise-reader"
CURSOR_PREFIX = "readwise-reader-v1:"
RETENTION_LIMIT = "service_retention_deletion_and_export_boundary"
MAX_PAGE_ITEMS = 100

ADAPTER_ERROR = ReadwiseReaderAdapterError
PROVIDER_UNAVAILABLE_ERROR = ReadwiseReaderProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    resource_kind: str
    activity_mode: str
    pagination: str = "opaque_page_cursor"
    incremental: bool = True
    retention_limit: str | None = RETENTION_LIMIT
    coverage_status: str | None = "partial"
    unavailable_reason: str | None = "service_retention_and_api_history_bound"
    cost_units: int = 2


STREAMS = {
    "documents": StreamSpec("document", "selected_account"),
    "tags": StreamSpec("tag", "selected_account", incremental=False),
    "notes": StreamSpec("note", "selected_account"),
    "state": StreamSpec("document_state", "selected_account"),
    "progress": StreamSpec("reading_progress", "selected_account"),
    "locations": StreamSpec("location", "selected_account"),
    "html": StreamSpec("document", "selected_account"),
}


@dataclass(frozen=True)
class PageRequest:
    stream: str
    account_id: str
    binding_account_id: str
    page_cursor: str | None
    updated_after: str | None
    limit: int

    def payload(self) -> dict[str, Any]:
        return {
            "action": "page", "stream": self.stream,
            "account_id": self.account_id,
            "binding_account_id": self.binding_account_id,
            "page_cursor": self.page_cursor,
            "updated_after": self.updated_after, "limit": self.limit,
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())


PAGE_REQUEST_KEYS = frozenset(PageRequest.__dataclass_fields__) | {"action"}


def _text(value: Any, field: str, *, optional: bool = False) -> str | None:
    if value is None and optional:
        return None
    if not isinstance(value, str) or not value or "\x00" in value or len(value.encode()) > 4096:
        raise ReadwiseReaderAdapterError(f"Readwise Reader {field} is invalid")
    return value


def _updated_after(value: Any) -> str | None:
    text = _text(value, "updatedAfter", optional=True)
    if text is None:
        return None
    try:
        datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError as error:
        raise ReadwiseReaderAdapterError("Readwise Reader updatedAfter is invalid") from error
    return text


def _overlap(value: str) -> str:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00")) - timedelta(seconds=1)
    return parsed.isoformat().replace("+00:00", "Z")


def _encode_cursor(cursor: str, updated_after: str | None) -> str:
    encoded = base64.urlsafe_b64encode(
        canonical_json({"cursor": cursor, "updated_after": updated_after}).encode()
    ).decode().rstrip("=")
    return f"{CURSOR_PREFIX}{encoded}"


def _decode_cursor(cursor: str) -> tuple[str, str | None]:
    if not cursor.startswith(CURSOR_PREFIX):
        raise ReadwiseReaderAdapterError("stored Readwise Reader cursor has an unsupported version")
    try:
        raw = cursor.removeprefix(CURSOR_PREFIX)
        payload = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise ReadwiseReaderAdapterError("stored Readwise Reader cursor is invalid") from error
    if not isinstance(payload, dict) or set(payload) != {"cursor", "updated_after"}:
        raise ReadwiseReaderAdapterError("stored Readwise Reader cursor has an invalid shape")
    reject_credentials(payload)
    return _text(payload.get("cursor"), "page cursor") or "", _updated_after(payload.get("updated_after"))


def page_request(stream: str, account: dict[str, Any], state: CursorState, limit: int) -> PageRequest:
    if stream not in STREAMS:
        raise ReadwiseReaderAdapterError("Readwise Reader stream is unsupported")
    cursor, updated = _decode_cursor(state.cursor) if state.cursor else (None, None)
    if stream != "tags" and state.backfill_complete and not state.cursor:
        if state.watermark is None:
            raise ReadwiseReaderAdapterError("stored Readwise Reader watermark is invalid")
        updated = _overlap(_updated_after(state.watermark) or "")
    return PageRequest(
        stream, _text(account.get("id"), "selected account ID") or "",
        binding_account_id(account.get("binding_account_id")), cursor, updated, limit,
    )


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    if set(payload) != PAGE_REQUEST_KEYS or payload.get("action") != "page":
        raise ReadwiseReaderAdapterError("Readwise Reader request has an invalid action shape")
    stream = payload.get("stream")
    if not isinstance(stream, str) or stream not in STREAMS:
        raise ReadwiseReaderAdapterError("Readwise Reader stream is unsupported")
    limit = payload.get("limit")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= MAX_PAGE_ITEMS:
        raise ReadwiseReaderAdapterError("Readwise Reader page size is invalid")
    return PageRequest(
        stream, _text(payload.get("account_id"), "selected account ID") or "",
        binding_account_id(payload.get("binding_account_id")),
        _text(payload.get("page_cursor"), "page cursor", optional=True),
        _updated_after(payload.get("updated_after")), limit,
    )


def response_status(payload: dict[str, Any]) -> int:
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise ReadwiseReaderAdapterError("Readwise Reader response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise ReadwiseReaderAdapterError("Readwise Reader page data must be an array")
    return data


def page_checkpoint(
    payload: dict[str, Any], state: CursorState, request: PageRequest
) -> tuple[PageCheckpoint, bool]:
    meta = payload.get("meta")
    if not isinstance(meta, dict) or meta.get("stream") != request.stream:
        raise ReadwiseReaderAdapterError("Readwise Reader page provenance is invalid")
    reject_credentials(meta)
    if len(page_data(payload)) > request.limit:
        raise ReadwiseReaderAdapterError("Readwise Reader page exceeds the item safety limit")
    next_cursor = _text(meta.get("next_page_cursor"), "next page cursor", optional=True)
    cursor = _encode_cursor(next_cursor, request.updated_after) if next_cursor else None
    watermark = _updated_after(meta.get("watermark")) or state.watermark
    return PageCheckpoint(cursor, watermark), next_cursor is None
