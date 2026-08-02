#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation primitives for bounded Readwise Reader responses."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_readwise_reader_identity import account_id, binding_account_id

MAX_TEXT_BYTES = 2 * 1024 * 1024


class ReadwiseReaderProviderError(RuntimeError):
    """Raised for a privacy-safe local Reader provider failure."""


@dataclass(frozen=True)
class ApiResult:
    status: int
    payload: Any
    retry_after: int | None = None


def observed_at() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def decode_json(payload: bytes, limit: int) -> Any:
    if len(payload) > limit:
        raise ReadwiseReaderProviderError("Readwise Reader JSON exceeds the safety limit")
    try:
        return json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ReadwiseReaderProviderError("Readwise Reader JSON is invalid") from error


def request_object(payload: bytes, limit: int) -> dict[str, Any]:
    value = decode_json(payload, limit)
    if not isinstance(value, dict):
        raise ReadwiseReaderProviderError("Readwise Reader request must be an object")
    return value


def object_value(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ReadwiseReaderProviderError(f"Readwise Reader {field} must be an object")
    return value


def object_list(value: Any, field: str, limit: int) -> list[dict[str, Any]]:
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise ReadwiseReaderProviderError(f"Readwise Reader {field} must be an array")
    if len(value) > limit:
        raise ReadwiseReaderProviderError(f"Readwise Reader {field} exceeds the item limit")
    return value


def optional_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value or len(value.encode()) > MAX_TEXT_BYTES:
        raise ReadwiseReaderProviderError(f"Readwise Reader {field} must be text")
    return value


def identity_value(binding_id: str, key: str) -> dict[str, Any]:
    selected = binding_account_id(binding_id)
    return {
        "id": account_id(selected, key),
        "binding_account_id": selected,
    }


def terminal_payload(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {"status": result.status, "observed_at": observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload
