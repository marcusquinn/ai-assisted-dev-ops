#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Gumroad stream policy, identity binding, and durable checkpoints."""

from __future__ import annotations

import base64
import json
import re
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from knowledge_social_import import canonical_json, reject_credentials

PROVIDER = "gumroad"
CURSOR_PREFIX = "gumroad-v1:"
RETENTION_LIMIT = "current_api_visibility_and_undocumented_provider_retention"
PROVIDER_ID = re.compile(r"^[A-Za-z0-9_=-]{6,160}$")


class GumroadAdapterError(RuntimeError):
    """Raised when Gumroad evidence violates the local collector contract."""


class GumroadProviderUnavailableError(GumroadAdapterError):
    """Raised when the isolated Gumroad reader cannot run safely."""


ADAPTER_ERROR = GumroadAdapterError
PROVIDER_UNAVAILABLE_ERROR = GumroadProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    """Static collection and coverage policy for one Gumroad stream."""

    resource_kind: str
    activity_mode: str
    pagination: str
    incremental: bool
    retention_limit: str | None
    coverage_status: str | None = None
    unavailable_reason: str | None = None
    cost_units: int = 2


STREAMS = {
    "profile": StreamSpec("seller_profile", "selected_account", "snapshot", False, RETENTION_LIMIT),
    "products": StreamSpec("product", "seller_inventory", "snapshot", False, RETENTION_LIMIT),
    "sales": StreamSpec("sale", "seller_transaction", "listing", True, RETENTION_LIMIT),
    "payouts": StreamSpec("payout", "seller_payout", "listing", True, RETENTION_LIMIT),
}


def provider_id(value: Any, field: str = "ID") -> str:
    """Validate one opaque Gumroad identifier without exposing it in errors."""
    if not isinstance(value, str) or PROVIDER_ID.fullmatch(value) is None:
        raise GumroadAdapterError(f"Gumroad {field} is invalid")
    return value


def seller_id(value: Any, field: str = "seller ID") -> str:
    """Map Gumroad's padded user ID to the corpus-safe account namespace."""
    raw = provider_id(value, field)
    if raw.startswith("gumroad_"):
        return raw
    return provider_id(f"gumroad_{raw.rstrip('=')}", field)


def _optional_cursor(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value or "\x00" in value or len(value.encode()) > 1024:
        raise GumroadAdapterError(f"Gumroad {field} is invalid")
    return value


def _encode_cursor(page_key: str) -> str:
    encoded = base64.urlsafe_b64encode(canonical_json({"page_key": page_key}).encode()).decode().rstrip("=")
    return f"{CURSOR_PREFIX}{encoded}"


def _decode_cursor(cursor: str) -> str:
    if not cursor.startswith(CURSOR_PREFIX):
        raise GumroadAdapterError("stored Gumroad cursor has an unsupported version")
    encoded = cursor.removeprefix(CURSOR_PREFIX)
    try:
        payload = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise GumroadAdapterError("stored Gumroad cursor is invalid") from error
    if not isinstance(payload, dict) or set(payload) != {"page_key"}:
        raise GumroadAdapterError("stored Gumroad cursor has an invalid shape")
    reject_credentials(payload)
    page_key = _optional_cursor(payload["page_key"], "page key")
    if page_key is None:
        raise GumroadAdapterError("stored Gumroad page key is missing")
    return page_key


@dataclass(frozen=True)
class PageRequest:
    """Allowlisted request passed to the isolated Gumroad HTTP child."""

    stream: str
    account_id: str
    provider_account_id: str
    page_key: str | None
    stop_at: str | None
    limit: int

    def payload(self) -> dict[str, Any]:
        return {
            "action": "page",
            "stream": self.stream,
            "account_id": self.account_id,
            "provider_account_id": self.provider_account_id,
            "page_key": self.page_key,
            "stop_at": self.stop_at,
            "limit": self.limit,
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())


def page_request(stream: str, account: dict[str, Any], state: CursorState, limit: int) -> PageRequest:
    """Build one request from an independent per-stream checkpoint."""
    if stream not in STREAMS:
        raise GumroadAdapterError("Gumroad stream is unsupported")
    account_id = seller_id(account.get("id"), "selected account ID")
    remote_id = seller_id(account.get("provider_account_id"), "provider account ID")
    if account_id != remote_id:
        raise GumroadAdapterError("selected Gumroad account does not match the configured connection")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
        raise GumroadAdapterError("Gumroad page safety limit is invalid")
    page_key = _decode_cursor(state.cursor) if state.cursor else None
    stop_at = state.watermark if STREAMS[stream].incremental and state.backfill_complete else None
    return PageRequest(stream, account_id, remote_id, page_key, stop_at, limit)


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    """Validate the exact child-process page request shape."""
    expected = {"action", "stream", "account_id", "provider_account_id", "page_key", "stop_at", "limit"}
    if set(payload) != expected or payload.get("action") != "page":
        raise GumroadAdapterError("Gumroad read request has an invalid action shape")
    stream = payload.get("stream")
    if not isinstance(stream, str) or stream not in STREAMS:
        raise GumroadAdapterError("Gumroad stream is unsupported")
    account_id = seller_id(payload.get("account_id"), "selected account ID")
    provider_account = seller_id(payload.get("provider_account_id"), "provider account ID")
    if account_id != provider_account:
        raise GumroadAdapterError("selected Gumroad account does not match the configured connection")
    limit = payload.get("limit")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
        raise GumroadAdapterError("Gumroad page safety limit is invalid")
    return PageRequest(
        stream,
        account_id,
        provider_account,
        _optional_cursor(payload.get("page_key"), "page key"),
        _optional_cursor(payload.get("stop_at"), "watermark"),
        limit,
    )


def response_status(payload: dict[str, Any]) -> int:
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise GumroadAdapterError("Gumroad response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise GumroadAdapterError("Gumroad page data must be an array")
    return data


def page_checkpoint(payload: dict[str, Any], state: CursorState, request: PageRequest) -> tuple[PageCheckpoint, bool]:
    """Calculate one atomic page-key checkpoint and stable watermark."""
    data = page_data(payload)
    if len(data) > request.limit:
        raise GumroadAdapterError("Gumroad page exceeds the item safety limit")
    meta = payload.get("meta")
    if not isinstance(meta, dict) or meta.get("stream") != request.stream:
        raise GumroadAdapterError("Gumroad page provenance is invalid")
    reject_credentials(meta)
    next_key = _optional_cursor(meta.get("next_page_key"), "next page key")
    newest_id = _optional_cursor(meta.get("newest_id"), "newest ID")
    reached = meta.get("reached_watermark")
    complete_flag = meta.get("complete")
    if not isinstance(reached, bool) or not isinstance(complete_flag, bool):
        raise GumroadAdapterError("Gumroad page completion metadata is invalid")
    complete = reached or complete_flag
    if complete == (next_key is not None):
        raise GumroadAdapterError("Gumroad page completion cursor is invalid")
    if next_key is not None and next_key == request.page_key:
        raise GumroadAdapterError("Gumroad next page key did not advance")
    next_cursor = _encode_cursor(next_key) if next_key else None
    watermark = state.watermark
    if STREAMS[request.stream].incremental and request.page_key is None:
        watermark = newest_id or watermark
    return PageCheckpoint(next_cursor, watermark), complete
