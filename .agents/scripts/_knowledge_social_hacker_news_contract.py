#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation primitives for bounded public Hacker News API reads."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_hacker_news_identity import (
    HackerNewsAdapterError,
    item_id,
    selector_id,
    username,
)

MAX_USER_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_ITEM_RESPONSE_BYTES = 512 * 1024
MAX_SUBMITTED_ITEMS = 100_000
MAX_RELATED_ITEMS = 100_000
MAX_TEXT_BYTES = 256 * 1024
ITEM_TYPES = frozenset({"job", "story", "comment", "poll", "pollopt"})


class HackerNewsReadProviderError(RuntimeError):
    """Raised for a privacy-safe local Hacker News provider failure."""


@dataclass(frozen=True)
class ApiResult:
    status: int
    payload: Any
    response_bytes: int = 0
    retry_after: int | None = None


def observed_at() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def decode_json(payload: bytes, limit: int) -> Any:
    if len(payload) > limit:
        raise HackerNewsReadProviderError(
            "Hacker News JSON payload exceeds the safety limit"
        )
    try:
        return json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise HackerNewsReadProviderError("Hacker News JSON payload is invalid") from error


def request_object(payload: bytes, limit: int) -> dict[str, Any]:
    request = decode_json(payload, limit)
    if not isinstance(request, dict):
        raise HackerNewsReadProviderError(
            "Hacker News read request root must be an object"
        )
    return request


def _integer(value: Any, field: str, *, signed: bool = False) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        raise HackerNewsReadProviderError(f"Hacker News {field} is invalid")
    if not signed and value < 0:
        raise HackerNewsReadProviderError(f"Hacker News {field} is invalid")
    return value


def _boolean(value: Any, field: str) -> bool:
    if value is None:
        return False
    if not isinstance(value, bool):
        raise HackerNewsReadProviderError(f"Hacker News {field} must be boolean")
    return value


def optional_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value:
        raise HackerNewsReadProviderError(f"Hacker News {field} must be text")
    if len(value.encode("utf-8")) > MAX_TEXT_BYTES:
        raise HackerNewsReadProviderError(
            f"Hacker News {field} exceeds the text safety limit"
        )
    return value


def submitted_ids(value: Any) -> tuple[int, ...]:
    if not isinstance(value, list) or len(value) > MAX_SUBMITTED_ITEMS:
        raise HackerNewsReadProviderError(
            "Hacker News submitted history exceeds the item safety limit"
        )
    submitted = tuple(item_id(current) for current in value)
    if len(submitted) != len(set(submitted)):
        raise HackerNewsReadProviderError(
            "Hacker News submitted history contains duplicate item IDs"
        )
    return submitted


def _related_ids(value: Any, field: str) -> list[int] | None:
    if value is None:
        return None
    if not isinstance(value, list) or len(value) > MAX_RELATED_ITEMS:
        raise HackerNewsReadProviderError(f"Hacker News {field} is invalid")
    return [item_id(current) for current in value]


def user_value(payload: Any, expected_username: str) -> dict[str, Any]:
    """Normalize one public user response as a mutable selector observation."""
    selected = username(expected_username)
    if payload is None:
        return {
            "id": selector_id(selected),
            "username": selected,
            "availability": "missing",
            "submitted": [],
        }
    if not isinstance(payload, dict):
        raise HackerNewsReadProviderError(
            "Hacker News public user response must be an object or null"
        )
    try:
        returned = username(payload.get("id"))
    except HackerNewsAdapterError as error:
        raise HackerNewsReadProviderError(str(error)) from error
    if returned != selected:
        raise HackerNewsReadProviderError(
            "Hacker News public username does not match the configured selector"
        )
    return {
        "id": selector_id(selected),
        "username": selected,
        "availability": "public",
        "created": _integer(payload.get("created"), "user creation timestamp"),
        "karma": _integer(payload.get("karma"), "user karma", signed=True),
        "about": optional_text(payload.get("about"), "user about text"),
        "submitted": list(submitted_ids(payload.get("submitted", []))),
    }


def _live_item(payload: dict[str, Any], expected_username: str) -> dict[str, Any]:
    item_type = payload.get("type")
    if item_type not in ITEM_TYPES:
        raise HackerNewsReadProviderError("Hacker News item type is invalid")
    try:
        author = username(payload.get("by"))
    except HackerNewsAdapterError as error:
        raise HackerNewsReadProviderError(str(error)) from error
    if author != username(expected_username):
        raise HackerNewsReadProviderError(
            "Hacker News item author does not match the public selector"
        )
    return {
        "type": item_type,
        "by": author,
        "time": _integer(payload.get("time"), "item creation timestamp"),
        "text": optional_text(payload.get("text"), "item text"),
        "title": optional_text(payload.get("title"), "item title"),
        "url": optional_text(payload.get("url"), "item URL"),
        "parent": _integer(payload.get("parent"), "item parent"),
        "poll": _integer(payload.get("poll"), "item poll"),
        "score": _integer(payload.get("score"), "item score", signed=True),
        "descendants": _integer(payload.get("descendants"), "item descendants"),
        "kids": _related_ids(payload.get("kids"), "item children"),
        "parts": _related_ids(payload.get("parts"), "item poll parts"),
    }


def item_value(payload: Any, expected_id: int, expected_username: str) -> dict[str, Any]:
    """Normalize a live item or an explicit public tombstone observation."""
    selected_id = item_id(expected_id)
    if payload is None:
        return {"item_id": selected_id, "state": "missing"}
    if not isinstance(payload, dict):
        raise HackerNewsReadProviderError(
            "Hacker News item response must be an object or null"
        )
    if item_id(payload.get("id")) != selected_id:
        raise HackerNewsReadProviderError(
            "Hacker News item response does not match the requested item ID"
        )
    deleted = _boolean(payload.get("deleted"), "item deleted flag")
    dead = _boolean(payload.get("dead"), "item dead flag")
    state = "deleted" if deleted else "dead" if dead else "live"
    record: dict[str, Any] = {"item_id": selected_id, "state": state}
    if state == "live":
        record.update(_live_item(payload, expected_username))
    else:
        author = payload.get("by")
        if author is not None and username(author) != username(expected_username):
            raise HackerNewsReadProviderError(
                "Hacker News tombstone author does not match the public selector"
            )
        item_type = payload.get("type")
        if item_type is not None and item_type not in ITEM_TYPES:
            raise HackerNewsReadProviderError("Hacker News item type is invalid")
        record.update({"type": item_type, "by": author})
    return record


def terminal_payload(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "status": result.status,
        "observed_at": observed_at(),
        "response_bytes": result.response_bytes,
    }
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload
