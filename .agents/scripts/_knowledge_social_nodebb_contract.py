#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation and serialization for the bounded NodeBB HTTP child."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_nodebb import instance_id, provider_account_id, userslug

MAX_TEXT_BYTES = 256 * 1024


class NodeBBReadProviderError(RuntimeError):
    """Raised for a privacy-safe local NodeBB provider failure."""


@dataclass(frozen=True)
class ApiResult:
    status: int
    payload: Any
    retry_after: int | None = None


def observed_at() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def exact_keys(request: dict[str, Any], expected: set[str]) -> None:
    if set(request) != expected:
        raise NodeBBReadProviderError("NodeBB read request has an invalid action shape")


def request_object(payload: bytes, limit: int) -> dict[str, Any]:
    if len(payload) > limit:
        raise NodeBBReadProviderError("NodeBB read request exceeds the safety limit")
    try:
        request = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise NodeBBReadProviderError("NodeBB read request is not valid JSON") from error
    if not isinstance(request, dict):
        raise NodeBBReadProviderError("NodeBB read request root must be an object")
    return request


def object_value(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise NodeBBReadProviderError(f"NodeBB {field} must be an object")
    return value


def object_list(value: Any, field: str, *, limit: int) -> list[dict[str, Any]]:
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise NodeBBReadProviderError(f"NodeBB {field} must be an array of objects")
    if len(value) > limit:
        raise NodeBBReadProviderError(f"NodeBB {field} exceeds the item safety limit")
    return value


def optional_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value:
        raise NodeBBReadProviderError(f"NodeBB {field} must be text")
    if len(value.encode("utf-8")) > MAX_TEXT_BYTES:
        raise NodeBBReadProviderError(f"NodeBB {field} exceeds the safety limit")
    return value


def required_text(value: Any, field: str) -> str:
    text = optional_text(value, field)
    if not text:
        raise NodeBBReadProviderError(f"NodeBB {field} is required")
    return text


def non_negative_integer(value: Any, field: str, *, optional: bool = False) -> int | None:
    if value is None and optional:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise NodeBBReadProviderError(f"NodeBB {field} must be a non-negative integer")
    return value


def positive_id(value: Any, field: str, *, optional: bool = False) -> str | None:
    if value is None and optional:
        return None
    number = non_negative_integer(value, field)
    if number is None or number < 1:
        raise NodeBBReadProviderError(f"NodeBB {field} must be positive")
    return str(number)


def optional_boolean(value: Any, field: str) -> bool | None:
    if value is None:
        return None
    if not isinstance(value, bool):
        raise NodeBBReadProviderError(f"NodeBB {field} must be boolean")
    return value


def identity_value(payload: Any, expected_id: str, installation: str) -> dict[str, Any]:
    """Serialize only stable current-user fields from GET /api/self."""
    root = object_value(payload, "identity response")
    current = object_value(root.get("user", root), "current user")
    local_id = positive_id(current.get("uid"), "account ID")
    if local_id is None or local_id != provider_account_id(expected_id):
        raise NodeBBReadProviderError(
            "selected NodeBB account does not match the configured connection"
        )
    slug = userslug(current.get("userslug"))
    return {
        "provider_account_id": local_id,
        "userslug": slug,
        "username": optional_text(current.get("username"), "account username") or slug,
        "display_name": optional_text(current.get("displayname"), "account display name"),
        "instance_id": instance_id(installation),
    }


def terminal_payload(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {"status": result.status, "observed_at": observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload
