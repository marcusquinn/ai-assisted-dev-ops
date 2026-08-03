#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation and serialization for the bounded Ghost HTTP child."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_ghost_identity import (
    GhostAdapterError,
    instance_id,
    provider_account_id,
)

MAX_TEXT_BYTES = 1024 * 1024
SITE_VERSION = re.compile(r"^(?P<major>[0-9]{1,3})\.[0-9]{1,3}(?:\.[0-9]{1,3})?$")


class GhostReadProviderError(RuntimeError):
    """Raised for a privacy-safe local Ghost provider failure."""


@dataclass(frozen=True)
class ApiResult:
    status: int
    payload: Any
    retry_after: int | None = None


def observed_at() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def exact_keys(request: dict[str, Any], expected: set[str]) -> None:
    if set(request) != expected:
        raise GhostReadProviderError("Ghost read request has an invalid action shape")


def request_object(payload: bytes, limit: int) -> dict[str, Any]:
    if len(payload) > limit:
        raise GhostReadProviderError("Ghost read request exceeds the safety limit")
    try:
        request = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise GhostReadProviderError("Ghost read request is not valid JSON") from error
    if not isinstance(request, dict):
        raise GhostReadProviderError("Ghost read request root must be an object")
    return request


def object_value(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise GhostReadProviderError(f"Ghost {field} must be an object")
    return value


def object_list(value: Any, field: str, *, limit: int) -> list[dict[str, Any]]:
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise GhostReadProviderError(f"Ghost {field} must be an array of objects")
    if len(value) > limit:
        raise GhostReadProviderError(f"Ghost {field} exceeds the item safety limit")
    return value


def optional_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value:
        raise GhostReadProviderError(f"Ghost {field} must be text")
    if len(value.encode("utf-8")) > MAX_TEXT_BYTES:
        raise GhostReadProviderError(f"Ghost {field} exceeds the safety limit")
    return value


def required_text(value: Any, field: str) -> str:
    text = optional_text(value, field)
    if not text:
        raise GhostReadProviderError(f"Ghost {field} is required")
    return text


def non_negative_integer(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise GhostReadProviderError(f"Ghost {field} must be a non-negative integer")
    return value


def positive_integer(value: Any, field: str) -> int:
    number = non_negative_integer(value, field)
    if number < 1:
        raise GhostReadProviderError(f"Ghost {field} must be positive")
    return number


def site_version(value: Any) -> str:
    version = required_text(value, "site version")
    match = SITE_VERSION.fullmatch(version)
    if match is None or int(match.group("major")) < 6:
        raise GhostReadProviderError("Ghost site does not satisfy API v6")
    return version


def identity_value(
    payload: Any,
    expected_id: str,
    installation: str,
) -> dict[str, Any]:
    """Serialize only non-sensitive fields from the unauthenticated site route."""
    site = object_value(object_value(payload, "site response").get("site"), "site")
    return {
        "provider_account_id": provider_account_id(expected_id),
        "site_id": provider_account_id(expected_id),
        "display_name": required_text(site.get("title"), "site title"),
        "version": site_version(site.get("version")),
        "instance_id": instance_id(installation),
    }


def terminal_payload(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {"status": result.status, "observed_at": observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload


__all__ = [
    "ApiResult",
    "GhostAdapterError",
    "GhostReadProviderError",
    "exact_keys",
    "identity_value",
    "non_negative_integer",
    "object_list",
    "object_value",
    "observed_at",
    "optional_text",
    "positive_integer",
    "request_object",
    "required_text",
    "site_version",
    "terminal_payload",
]
