#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation primitives for bounded Miniflux API responses."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_miniflux_identity import account_id, user_id

MAX_TEXT_BYTES = 256 * 1024


class MinifluxReadProviderError(RuntimeError):
    """Raised for a privacy-safe local Miniflux provider failure."""


@dataclass(frozen=True)
class ApiResult:
    status: int
    payload: Any
    retry_after: int | None = None


def observed_at() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def decode_json(payload: bytes, limit: int) -> Any:
    if len(payload) > limit:
        raise MinifluxReadProviderError("Miniflux JSON payload exceeds the safety limit")
    try:
        return json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise MinifluxReadProviderError("Miniflux JSON payload is invalid") from error


def request_object(payload: bytes, limit: int) -> dict[str, Any]:
    request = decode_json(payload, limit)
    if not isinstance(request, dict):
        raise MinifluxReadProviderError("Miniflux read request root must be an object")
    return request


def object_value(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise MinifluxReadProviderError(f"Miniflux {field} must be an object")
    return value


def object_list(value: Any, field: str, *, limit: int) -> list[dict[str, Any]]:
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise MinifluxReadProviderError(f"Miniflux {field} must be an array of objects")
    if len(value) > limit:
        raise MinifluxReadProviderError(f"Miniflux {field} exceeds the item safety limit")
    return value


def optional_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value or len(value.encode()) > MAX_TEXT_BYTES:
        raise MinifluxReadProviderError(f"Miniflux {field} must be text")
    return value


def identity_value(payload: Any, expected_user_id: str, instance: str) -> dict[str, Any]:
    user = object_value(payload, "account response")
    local = user_id(user.get("id"))
    if local != user_id(expected_user_id):
        raise MinifluxReadProviderError(
            "selected Miniflux account does not match the configured connection"
        )
    return {
        "id": account_id(instance, local),
        "installation_id": instance,
        "user_id": local,
        "username": optional_text(user.get("username"), "account username"),
    }


def terminal_payload(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {"status": result.status, "observed_at": observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload
