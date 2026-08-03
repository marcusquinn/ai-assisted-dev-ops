#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Hacker News public-history policy and deterministic slice checkpoints."""

from __future__ import annotations

import base64
import hashlib
import json
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from _knowledge_social_hacker_news_contract import submitted_ids
from _knowledge_social_hacker_news_identity import (
    HackerNewsAdapterError,
    HackerNewsProviderUnavailableError,
    item_id,
    selector_id,
    username,
)
from knowledge_social_import import canonical_json, reject_credentials

PROVIDER = "hacker-news"
CURSOR_PREFIX = "hacker-news-submitted-v1:"
RETENTION_LIMIT = "public_submitted_slice_and_current_item_visibility"
MAX_SLICE_ITEMS = 100

ADAPTER_ERROR = HackerNewsAdapterError
PROVIDER_UNAVAILABLE_ERROR = HackerNewsProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    resource_kind: str = "item"
    activity_mode: str = "public_attribution"
    pagination: str = "bounded_snapshot"
    incremental: bool = False
    retention_limit: str | None = RETENTION_LIMIT
    coverage_status: str | None = "partial"
    unavailable_reason: str | None = "public_selector_and_submitted_slice_bound"
    cost_units: int = 2


STREAMS = {"submitted": StreamSpec()}


def _snapshot(items: tuple[int, ...]) -> str:
    return hashlib.sha256(canonical_json(list(items)).encode("utf-8")).hexdigest()


@dataclass(frozen=True)
class PageRequest:
    stream: str
    username: str
    selector_id: str
    items: tuple[int, ...]
    position: int
    snapshot_sha256: str

    @property
    def item_id(self) -> int | None:
        return self.items[self.position] if self.position < len(self.items) else None

    def payload(self) -> dict[str, Any]:
        return {
            "action": "page",
            "stream": self.stream,
            "username": self.username,
            "selector_id": self.selector_id,
            "items": list(self.items),
            "position": self.position,
            "snapshot_sha256": self.snapshot_sha256,
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())


PAGE_REQUEST_KEYS = {
    "action",
    "stream",
    "username",
    "selector_id",
    "items",
    "position",
    "snapshot_sha256",
}


def _position(value: Any, item_count: int, *, cursor: bool = False) -> int:
    maximum = item_count - 1 if cursor else item_count
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or value < 0
        or value > maximum
    ):
        raise HackerNewsAdapterError("Hacker News snapshot position is invalid")
    return value


def _item_tuple(value: Any) -> tuple[int, ...]:
    try:
        items = submitted_ids(value)
    except RuntimeError as error:
        raise HackerNewsAdapterError(str(error)) from error
    if len(items) > MAX_SLICE_ITEMS:
        raise HackerNewsAdapterError("Hacker News snapshot exceeds the item budget")
    return items


def _encode_cursor(request: PageRequest, position: int) -> str:
    payload = {
        "items": list(request.items),
        "position": position,
        "snapshot_sha256": request.snapshot_sha256,
        "username": request.username,
    }
    encoded = base64.urlsafe_b64encode(canonical_json(payload).encode("utf-8"))
    return f"{CURSOR_PREFIX}{encoded.decode('ascii').rstrip('=')}"


def _decode_cursor(cursor: str, selected_username: str) -> tuple[tuple[int, ...], int, str]:
    if not cursor.startswith(CURSOR_PREFIX):
        raise HackerNewsAdapterError(
            "stored Hacker News cursor has an unsupported version"
        )
    try:
        encoded = cursor.removeprefix(CURSOR_PREFIX)
        parsed = json.loads(
            base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
        )
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise HackerNewsAdapterError("stored Hacker News cursor is invalid") from error
    if not isinstance(parsed, dict) or set(parsed) != {
        "items",
        "position",
        "snapshot_sha256",
        "username",
    }:
        raise HackerNewsAdapterError("stored Hacker News cursor has an invalid shape")
    reject_credentials(parsed)
    selected = username(parsed.get("username"))
    if selected != username(selected_username):
        raise HackerNewsAdapterError(
            "stored Hacker News cursor belongs to another public selector"
        )
    items = _item_tuple(parsed.get("items"))
    position = _position(parsed.get("position"), len(items), cursor=True)
    snapshot = parsed.get("snapshot_sha256")
    if not isinstance(snapshot, str) or snapshot != _snapshot(items):
        raise HackerNewsAdapterError("stored Hacker News cursor snapshot is invalid")
    return items, position, snapshot


def page_request(
    stream: str,
    account: dict[str, Any],
    state: CursorState,
    limit: int,
) -> PageRequest:
    if stream != "submitted":
        raise HackerNewsAdapterError("Hacker News stream is unsupported")
    selected = username(account.get("username"))
    selected_id = selector_id(selected)
    if account.get("id") != selected_id:
        raise HackerNewsAdapterError("Hacker News public selector binding is invalid")
    if state.cursor:
        items, position, snapshot = _decode_cursor(state.cursor, selected)
    else:
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
            raise HackerNewsAdapterError("Hacker News item budget is invalid")
        raw_submitted = account.get("submitted", [])
        items = _item_tuple(raw_submitted)[:limit]
        position = 0
        snapshot = _snapshot(items)
    return PageRequest(stream, selected, selected_id, items, position, snapshot)


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    if set(payload) != PAGE_REQUEST_KEYS or payload.get("action") != "page":
        raise HackerNewsAdapterError("Hacker News read request has an invalid action shape")
    if payload.get("stream") != "submitted":
        raise HackerNewsAdapterError("Hacker News stream is unsupported")
    selected = username(payload.get("username"))
    selected_id = selector_id(selected)
    if payload.get("selector_id") != selected_id:
        raise HackerNewsAdapterError("Hacker News public selector binding is invalid")
    items = _item_tuple(payload.get("items"))
    position = _position(payload.get("position"), len(items))
    snapshot = payload.get("snapshot_sha256")
    if not isinstance(snapshot, str) or snapshot != _snapshot(items):
        raise HackerNewsAdapterError("Hacker News request snapshot is invalid")
    return PageRequest("submitted", selected, selected_id, items, position, snapshot)


def response_status(payload: dict[str, Any]) -> int:
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise HackerNewsAdapterError("Hacker News response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(record, dict) for record in data):
        raise HackerNewsAdapterError("Hacker News page data must be an array")
    if len(data) > 1:
        raise HackerNewsAdapterError("Hacker News page exceeds the item budget")
    return data


def _meta_integer(meta: dict[str, Any], key: str) -> int:
    value = meta.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise HackerNewsAdapterError(f"Hacker News {key} metadata is invalid")
    return value


def page_checkpoint(
    payload: dict[str, Any],
    state: CursorState,
    request: PageRequest,
) -> tuple[PageCheckpoint, bool]:
    del state
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise HackerNewsAdapterError("Hacker News page metadata must be an object")
    reject_credentials(meta)
    expected_item = request.item_id
    provenance = (
        meta.get("stream") == request.stream,
        meta.get("username") == request.username,
        meta.get("selector_id") == request.selector_id,
        meta.get("snapshot_sha256") == request.snapshot_sha256,
        meta.get("position") == request.position,
        meta.get("total") == len(request.items),
        meta.get("item_id") == expected_item,
    )
    if not all(provenance):
        raise HackerNewsAdapterError("Hacker News page provenance is invalid")
    _meta_integer(meta, "response_bytes")
    item_state = meta.get("item_state")
    allowed_states = {"live", "missing", "deleted", "dead", "empty"}
    if item_state not in allowed_states:
        raise HackerNewsAdapterError("Hacker News item state is invalid")
    records = page_data(payload)
    if expected_item is None:
        if item_state != "empty" or records:
            raise HackerNewsAdapterError("Hacker News empty snapshot response is invalid")
    elif len(records) != 1 or records[0].get("item_id") != expected_item:
        raise HackerNewsAdapterError("Hacker News item response is incomplete")
    elif records[0].get("state") != item_state:
        raise HackerNewsAdapterError("Hacker News item state provenance is invalid")
    complete = expected_item is None or request.position + 1 >= len(request.items)
    cursor = None if complete else _encode_cursor(request, request.position + 1)
    return PageCheckpoint(cursor, request.snapshot_sha256), complete
