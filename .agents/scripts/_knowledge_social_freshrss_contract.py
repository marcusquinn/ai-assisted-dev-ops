#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation primitives for bounded FreshRSS API responses."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any
from urllib.parse import SplitResult, parse_qsl, unquote, urlsplit

from _knowledge_social_freshrss_identity import account_id, user_id
from knowledge_source_contract import (
    FORBIDDEN_CREDENTIAL_KEYS,
    FORBIDDEN_CREDENTIAL_SUFFIXES,
)

MAX_TEXT_BYTES = 256 * 1024
SENSITIVE_URL_KEYS = FORBIDDEN_CREDENTIAL_KEYS | {"key", "passwd", "sid"}
SENSITIVE_URL_PARTS = {
    "auth",
    "authorization",
    "credential",
    "credentials",
    "key",
    "passwd",
    "password",
    "secret",
    "sid",
    "token",
}


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
    if not isinstance(value, str):
        raise FreshRSSReadProviderError(f"FreshRSS {field} must be text")
    if "\x00" in value or len(value.encode()) > limit:
        raise FreshRSSReadProviderError(f"FreshRSS {field} must be text")
    return value


def required_text(value: Any, field: str, *, limit: int = 4096) -> str:
    text = optional_text(value, field, limit=limit)
    if not text:
        raise FreshRSSReadProviderError(f"FreshRSS {field} is required")
    return text


def _url_parts(text: str, field: str) -> tuple[SplitResult, int | None]:
    try:
        parsed = urlsplit(text)
        port = parsed.port
    except ValueError as error:
        raise FreshRSSReadProviderError(f"FreshRSS {field} is invalid") from error
    return parsed, port


def _validate_url_origin(parsed: SplitResult, port: int | None, field: str) -> None:
    if parsed.scheme.lower() not in {"http", "https"}:
        raise FreshRSSReadProviderError(f"FreshRSS {field} is invalid")
    if parsed.hostname is None:
        raise FreshRSSReadProviderError(f"FreshRSS {field} is invalid")
    if parsed.username is not None:
        raise FreshRSSReadProviderError(f"FreshRSS {field} is invalid")
    if parsed.password is not None:
        raise FreshRSSReadProviderError(f"FreshRSS {field} is invalid")
    if port is None:
        return
    if port < 1 or port > 65535:
        raise FreshRSSReadProviderError(f"FreshRSS {field} is invalid")


def _credential_shaped_key(value: str) -> bool:
    folded = value.casefold()
    normalized = "".join(character for character in folded if character.isalnum())
    parts = {part for part in re.split(r"[^a-z0-9]+", folded) if part}
    return normalized in SENSITIVE_URL_KEYS or normalized.endswith(
        FORBIDDEN_CREDENTIAL_SUFFIXES
    ) or bool(parts.intersection(SENSITIVE_URL_PARTS))


def _reject_sensitive_parameters(value: str, field: str) -> None:
    for key, _parameter in parse_qsl(value, keep_blank_values=True):
        if _credential_shaped_key(key):
            raise FreshRSSReadProviderError(
                f"FreshRSS {field} contains credential-shaped data"
            )


def _reject_sensitive_url_data(parsed: SplitResult, field: str) -> None:
    _reject_sensitive_parameters(parsed.query, field)
    _reject_sensitive_parameters(parsed.fragment, field)
    for segment in parsed.path.split("/"):
        decoded = unquote(segment)
        key = decoded.partition("=")[0].partition(":")[0]
        if not key:
            continue
        if _credential_shaped_key(key):
            raise FreshRSSReadProviderError(
                f"FreshRSS {field} contains credential-shaped data"
            )


def safe_url(value: Any, field: str) -> str | None:
    """Reject credentials and credential-shaped URL components."""
    text = optional_text(value, field, limit=64 * 1024)
    if text is None:
        return None
    parsed, port = _url_parts(text, field)
    _validate_url_origin(parsed, port, field)
    _reject_sensitive_url_data(parsed, field)
    return text


def _login_text(payload: bytes, limit: int) -> str:
    if len(payload) > limit:
        raise FreshRSSReadProviderError("FreshRSS login response exceeds the safety limit")
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise FreshRSSReadProviderError("FreshRSS login response is invalid") from error


def _login_values(text: str) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in text.splitlines():
        if not line:
            continue
        key, separator, value = line.partition("=")
        if not separator:
            raise FreshRSSReadProviderError("FreshRSS login response is invalid")
        if key in values:
            raise FreshRSSReadProviderError("FreshRSS login response is invalid")
        if key not in {"SID", "LSID", "Auth"}:
            raise FreshRSSReadProviderError("FreshRSS login response is invalid")
        values[key] = value
    return values


def _auth_value(values: dict[str, str]) -> str:
    token = values.get("Auth")
    if not token:
        raise FreshRSSReadProviderError("FreshRSS login response is invalid")
    if "\x00" in token:
        raise FreshRSSReadProviderError("FreshRSS login response is invalid")
    if len(token.encode()) > 16 * 1024:
        raise FreshRSSReadProviderError("FreshRSS login response is invalid")
    if any(character.isspace() for character in token):
        raise FreshRSSReadProviderError("FreshRSS login response is invalid")
    return token


def login_token(payload: bytes, limit: int) -> str:
    """Parse ClientLogin without exposing SID/Auth material to the parent."""
    return _auth_value(_login_values(_login_text(payload, limit)))


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
