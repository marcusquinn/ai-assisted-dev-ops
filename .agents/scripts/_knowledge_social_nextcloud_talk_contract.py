#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation primitives for bounded Nextcloud Talk OCS reads."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Mapping

from _knowledge_social_nextcloud_talk import NextcloudTalkAdapterError

MAX_TEXT_BYTES = 256 * 1024


class NextcloudTalkReadProviderError(NextcloudTalkAdapterError):
    """Raised for a privacy-safe local Talk provider failure."""


@dataclass(frozen=True)
class ApiResult:
    status: int
    payload: Any
    headers: Mapping[str, str]
    retry_after: int | None = None


def observed_at() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def request_object(payload: bytes, limit: int) -> dict[str, Any]:
    if len(payload) > limit:
        raise NextcloudTalkReadProviderError("Nextcloud Talk request exceeds the safety limit")
    try:
        request = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise NextcloudTalkReadProviderError("Nextcloud Talk request is not valid JSON") from error
    if not isinstance(request, dict):
        raise NextcloudTalkReadProviderError("Nextcloud Talk request root must be an object")
    return request


def object_value(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise NextcloudTalkReadProviderError(f"Nextcloud Talk {field} must be an object")
    return value


def object_list(value: Any, field: str, *, limit: int) -> list[dict[str, Any]]:
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise NextcloudTalkReadProviderError(
            f"Nextcloud Talk {field} must be an array of objects"
        )
    if len(value) > limit:
        raise NextcloudTalkReadProviderError(f"Nextcloud Talk {field} exceeds the item limit")
    return value


def optional_text(value: Any, field: str, *, limit: int = MAX_TEXT_BYTES) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value or len(value.encode()) > limit:
        raise NextcloudTalkReadProviderError(f"Nextcloud Talk {field} must be bounded text")
    return value


def required_text(value: Any, field: str, *, limit: int = MAX_TEXT_BYTES) -> str:
    text = optional_text(value, field, limit=limit)
    if not text:
        raise NextcloudTalkReadProviderError(f"Nextcloud Talk {field} is required")
    return text


def integer(value: Any, field: str, *, optional: bool = False) -> int | None:
    if value is None and optional:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        raise NextcloudTalkReadProviderError(f"Nextcloud Talk {field} must be an integer")
    return value


def non_negative(value: Any, field: str, *, optional: bool = False) -> int | None:
    number = integer(value, field, optional=optional)
    if number is not None and number < 0:
        raise NextcloudTalkReadProviderError(
            f"Nextcloud Talk {field} must be non-negative"
        )
    return number


def boolean(value: Any, field: str, *, optional: bool = False) -> bool | None:
    if value is None and optional:
        return None
    if not isinstance(value, bool):
        raise NextcloudTalkReadProviderError(f"Nextcloud Talk {field} must be boolean")
    return value


def ocs_data(payload: Any, field: str) -> Any:
    """Return data from a successful JSON OCS envelope."""
    root = object_value(payload, f"{field} response")
    ocs = object_value(root.get("ocs"), f"{field} OCS envelope")
    meta = object_value(ocs.get("meta"), f"{field} OCS metadata")
    status_code = integer(meta.get("statuscode"), f"{field} OCS status")
    if status_code not in (100, 200):
        raise NextcloudTalkReadProviderError(f"Nextcloud Talk {field} OCS request failed")
    return ocs.get("data")


def terminal_payload(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {"status": result.status, "observed_at": observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload
