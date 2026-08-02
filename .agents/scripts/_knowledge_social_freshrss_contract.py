#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation primitives for bounded FreshRSS API responses."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any
from urllib.parse import parse_qsl, urlsplit

from _knowledge_social_freshrss_identity import account_id, user_id

MAX_TEXT_BYTES = 256 * 1024
SENSITIVE_QUERY_MARKERS = (
    "api_key",
    "auth",
    "credential",
    "key",
    "passwd",
    "password",
    "secret",
    "sid",
    "token",
)


class FreshRSSReadProviderError(RuntimeError):
    """Raised for a privacy-safe local FreshRSS provider failure."""


@dataclass(frozen=True)
class ApiResult:
    status: int
    payload: Any
    retry_after: int | None = None


def observed_at() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def decode_json(payload: bytes, limit: int) -> Any:
    if len(payload) > limit:
        raise FreshRSSReadProviderError("FreshRSS JSON payload exceeds the safety limit")
    try:
        return json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise FreshRSSReadProviderError("FreshRSS JSON payload is invalid") from error


def request_object(payload: bytes, limit: int) -> dict[str, Any]:
    request = decode_json(payload, limit)
    if not isinstance(request, dict):
        raise FreshRSSReadProviderError("FreshRSS read request root must be an object")
    return request


def object_value(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise FreshRSSReadProviderError(f"FreshRSS {field} must be an object")
    return value


def object_list(value: Any, field: str, *, limit: int) -> list[dict[str, Any]]:
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise FreshRSSReadProviderError(f"FreshRSS {field} must be an array of objects")
    if len(value) > limit:
        raise FreshRSSReadProviderError(f"FreshRSS {field} exceeds the item safety limit")
    return value


def optional_text(value: Any, field: str, *, limit: int = MAX_TEXT_BYTES) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value or len(value.encode()) > limit:
        raise FreshRSSReadProviderError(f"FreshRSS {field} must be text")
    return value


def required_text(value: Any, field: str, *, limit: int = 4096) -> str:
    text = optional_text(value, field, limit=limit)
    if not text:
        raise FreshRSSReadProviderError(f"FreshRSS {field} is required")
    return text


def safe_url(value: Any, field: str) -> str | None:
    """Reject credentials and credential-shaped URL query parameters."""
    text = optional_text(value, field, limit=64 * 1024)
    if text is None:
        return None
    try:
        parsed = urlsplit(text)
        port = parsed.port
    except ValueError as error:
        raise FreshRSSReadProviderError(f"FreshRSS {field} is invalid") from error
    if (
        parsed.scheme.lower() not in {"http", "https"}
        or parsed.hostname is None
        or parsed.username is not None
        or parsed.password is not None
        or port is not None and not 1 <= port <= 65535
    ):
        raise FreshRSSReadProviderError(f"FreshRSS {field} is invalid")
    for key, _value in parse_qsl(parsed.query, keep_blank_values=True):
        normalized = key.casefold().replace("-", "_")
        if any(marker in normalized for marker in SENSITIVE_QUERY_MARKERS):
            raise FreshRSSReadProviderError(
                f"FreshRSS {field} contains credential-shaped data"
            )
    return text


def login_token(payload: bytes, limit: int) -> str:
    """Parse ClientLogin without exposing SID/Auth material to the parent."""
    if len(payload) > limit:
        raise FreshRSSReadProviderError("FreshRSS login response exceeds the safety limit")
    try:
        text = payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise FreshRSSReadProviderError("FreshRSS login response is invalid") from error
    values: dict[str, str] = {}
    for line in text.splitlines():
        if not line:
            continue
        key, separator, value = line.partition("=")
        if not separator or key in values or key not in {"SID", "LSID", "Auth"}:
            raise FreshRSSReadProviderError("FreshRSS login response is invalid")
        values[key] = value
    token = values.get("Auth")
    if (
        not token
        or "\x00" in token
        or len(token.encode()) > 16 * 1024
        or any(character.isspace() for character in token)
    ):
        raise FreshRSSReadProviderError("FreshRSS login response is invalid")
    return token


def identity_value(payload: Any, expected_user_id: str, instance: str) -> dict[str, Any]:
    """Bind current GReader identity to the selected installation and username."""
    root = object_value(payload, "account response")
    expected = user_id(expected_user_id)
    identities = tuple(
        user_id(root.get(field)) for field in ("userId", "userName", "userProfileId")
    )
    if any(identity != expected for identity in identities):
        raise FreshRSSReadProviderError(
            "selected FreshRSS account does not match the configured connection"
        )
    return {
        "id": account_id(instance, expected),
        "installation_id": instance,
        "user_id": expected,
        "username": identities[1],
    }


def terminal_payload(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {"status": result.status, "observed_at": observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload
