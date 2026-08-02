#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Miniflux stream policy and independent incremental checkpoints."""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from _knowledge_social_miniflux_identity import (
    MinifluxAdapterError,
    MinifluxProviderUnavailableError,
    account_id,
    user_id,
)
from knowledge_social_import import canonical_json, reject_credentials

PROVIDER = "miniflux"
CURSOR_PREFIX = "miniflux-entry-v1:"
RETENTION_LIMIT = "operator_cleanup_configuration_and_current_database_state"
MAX_PAGE_ITEMS = 100

ADAPTER_ERROR = MinifluxAdapterError
PROVIDER_UNAVAILABLE_ERROR = MinifluxProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    resource_kind: str
    activity_mode: str
    pagination: str
    incremental: bool
    retention_limit: str | None = RETENTION_LIMIT
    coverage_status: str | None = "partial"
    unavailable_reason: str | None = "operator_configurable_retention"
    cost_units: int = 2


STREAMS = {
    "entries": StreamSpec("entry", "content_observed", "entry_id_changed_after", True),
    "read": StreamSpec("entry", "selected_account", "entry_id_changed_after", True),
    "removed": StreamSpec("entry", "selected_account", "entry_id_changed_after", True),
    "starred": StreamSpec("entry", "selected_account", "entry_id_changed_after", True),
    "tags": StreamSpec("tag", "selected_account", "entry_id_changed_after", True),
    "feeds": StreamSpec("feed", "subscription", "snapshot", False),
    "categories": StreamSpec("category", "subscription", "snapshot", False),
    "opml": StreamSpec("feed", "subscription", "snapshot", False),
}
ENTRY_STREAMS = frozenset({"entries", "read", "removed", "starred", "tags"})


@dataclass(frozen=True)
class PageRequest:
    stream: str
    account_id: str
    installation_id: str
    user_id: str
    after_entry_id: int
    changed_after: int | None
    limit: int

    def payload(self) -> dict[str, Any]:
        return {
            "action": "page",
            "stream": self.stream,
            "account_id": self.account_id,
            "installation_id": self.installation_id,
            "user_id": self.user_id,
            "after_entry_id": self.after_entry_id,
            "changed_after": self.changed_after,
            "limit": self.limit,
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())


PAGE_REQUEST_KEYS = frozenset(PageRequest.__dataclass_fields__) | {"action"}


def _positive(value: Any, field: str, *, allow_zero: bool = False) -> int:
    minimum = 0 if allow_zero else 1
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise MinifluxAdapterError(f"Miniflux {field} is invalid")
    return value


def _text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value or len(value.encode()) > 4096:
        raise MinifluxAdapterError(f"Miniflux {field} is invalid")
    return value


def _encode_cursor(after_id: int, changed_after: int | None) -> str:
    encoded = base64.urlsafe_b64encode(
        canonical_json({"after": after_id, "changed_after": changed_after}).encode()
    ).decode().rstrip("=")
    return f"{CURSOR_PREFIX}{encoded}"


def _decode_cursor(cursor: str) -> tuple[int, int | None]:
    if not cursor.startswith(CURSOR_PREFIX):
        raise MinifluxAdapterError("stored Miniflux cursor has an unsupported version")
    try:
        raw = cursor.removeprefix(CURSOR_PREFIX)
        payload = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise MinifluxAdapterError("stored Miniflux cursor is invalid") from error
    if not isinstance(payload, dict) or set(payload) != {"after", "changed_after"}:
        raise MinifluxAdapterError("stored Miniflux cursor has an invalid shape")
    reject_credentials(payload)
    after_id = _positive(payload.get("after"), "entry cursor", allow_zero=True)
    changed = payload.get("changed_after")
    if changed is not None:
        changed = _positive(changed, "changed_after", allow_zero=True)
    return after_id, changed


def page_request(stream: str, account: dict[str, Any], state: CursorState, limit: int) -> PageRequest:
    if stream not in STREAMS:
        raise MinifluxAdapterError("Miniflux stream is unsupported")
    after_id, changed = _decode_cursor(state.cursor) if state.cursor else (0, None)
    if stream in ENTRY_STREAMS and state.backfill_complete and not state.cursor:
        if state.watermark is None or not state.watermark.isdigit():
            raise MinifluxAdapterError("stored Miniflux watermark is invalid")
        changed = max(0, int(state.watermark) - 1)
    return PageRequest(
        stream,
        _text(account.get("id"), "selected account ID"),
        _text(account.get("installation_id"), "installation ID"),
        user_id(account.get("user_id")),
        after_id,
        changed,
        limit,
    )


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    if set(payload) != PAGE_REQUEST_KEYS or payload.get("action") != "page":
        raise MinifluxAdapterError("Miniflux read request has an invalid action shape")
    stream = payload.get("stream")
    if not isinstance(stream, str) or stream not in STREAMS:
        raise MinifluxAdapterError("Miniflux stream is unsupported")
    changed = payload.get("changed_after")
    if changed is not None:
        changed = _positive(changed, "changed_after", allow_zero=True)
    limit = _positive(payload.get("limit"), "page size")
    if limit > MAX_PAGE_ITEMS:
        raise MinifluxAdapterError("Miniflux page size is invalid")
    local = user_id(payload.get("user_id"))
    installation = _text(payload.get("installation_id"), "installation ID")
    selected = _text(payload.get("account_id"), "selected account ID")
    if selected != account_id(installation, local):
        raise MinifluxAdapterError("Miniflux account identity binding is invalid")
    return PageRequest(
        stream, selected, installation, local,
        _positive(payload.get("after_entry_id"), "entry cursor", allow_zero=True),
        changed, limit,
    )


def response_status(payload: dict[str, Any]) -> int:
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise MinifluxAdapterError("Miniflux response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise MinifluxAdapterError("Miniflux page data must be an array")
    return data


def _timestamp_epoch(value: Any) -> int | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value or "\x00" in value:
        raise MinifluxAdapterError("Miniflux changed timestamp is invalid")
    try:
        return int(datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(UTC).timestamp())
    except ValueError as error:
        raise MinifluxAdapterError("Miniflux changed timestamp is invalid") from error


def page_checkpoint(
    payload: dict[str, Any], state: CursorState, request: PageRequest
) -> tuple[PageCheckpoint, bool]:
    meta = payload.get("meta")
    if not isinstance(meta, dict) or meta.get("stream") != request.stream:
        raise MinifluxAdapterError("Miniflux page provenance is invalid")
    reject_credentials(meta)
    items = page_data(payload)
    if len(items) > request.limit or meta.get("snapshot") is not (request.stream not in ENTRY_STREAMS):
        raise MinifluxAdapterError("Miniflux page metadata is invalid")
    has_more = meta.get("has_more")
    if not isinstance(has_more, bool):
        raise MinifluxAdapterError("Miniflux has_more must be boolean")
    next_after = meta.get("next_after_entry_id", request.after_entry_id)
    next_after = _positive(next_after, "next entry cursor", allow_zero=True)
    if has_more and next_after <= request.after_entry_id:
        raise MinifluxAdapterError("Miniflux entry cursor did not advance")
    cursor = _encode_cursor(next_after, request.changed_after) if has_more else None
    watermark = state.watermark
    changed_values = [_timestamp_epoch(item.get("changed_at")) for item in items]
    observed = meta.get("watermark")
    if observed is not None:
        observed = _positive(observed, "watermark", allow_zero=True)
        changed_values.append(observed)
    present = [value for value in changed_values if value is not None]
    if present:
        watermark = str(max(present + ([int(watermark)] if watermark and watermark.isdigit() else [])))
    return PageCheckpoint(cursor, watermark), not has_more
