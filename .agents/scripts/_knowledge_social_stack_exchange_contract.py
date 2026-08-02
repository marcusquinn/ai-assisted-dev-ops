#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation primitives for bounded Stack Exchange API wrappers."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_stack_exchange_identity import (
    account_id,
    api_site_parameter,
    network_account_id,
    site_user_id,
)

MAX_TEXT_BYTES = 256 * 1024


class StackExchangeReadProviderError(RuntimeError):
    """Raised for a privacy-safe local Stack Exchange provider failure."""


@dataclass(frozen=True)
class ApiResult:
    status: int
    payload: Any
    retry_after: int | None = None


def observed_at() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def decode_json(payload: bytes, limit: int) -> Any:
    if len(payload) > limit:
        raise StackExchangeReadProviderError(
            "Stack Exchange JSON payload exceeds the safety limit"
        )
    try:
        return json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise StackExchangeReadProviderError("Stack Exchange JSON payload is invalid") from error


def request_object(payload: bytes, limit: int) -> dict[str, Any]:
    request = decode_json(payload, limit)
    if not isinstance(request, dict):
        raise StackExchangeReadProviderError(
            "Stack Exchange read request root must be an object"
        )
    return request


def object_value(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise StackExchangeReadProviderError(f"Stack Exchange {field} must be an object")
    return value


def object_list(value: Any, field: str, *, limit: int) -> list[dict[str, Any]]:
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise StackExchangeReadProviderError(
            f"Stack Exchange {field} must be an array of objects"
        )
    if len(value) > limit:
        raise StackExchangeReadProviderError(
            f"Stack Exchange {field} exceeds the item safety limit"
        )
    return value


def optional_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value or len(value.encode()) > MAX_TEXT_BYTES:
        raise StackExchangeReadProviderError(f"Stack Exchange {field} must be text")
    return value


def required_text(value: Any, field: str) -> str:
    text = optional_text(value, field)
    if not text:
        raise StackExchangeReadProviderError(f"Stack Exchange {field} is required")
    return text


def wrapper(payload: Any, *, limit: int) -> tuple[list[dict[str, Any]], bool, int | None, int]:
    root = object_value(payload, "response")
    if root.get("error_id") is not None:
        raise StackExchangeReadProviderError("Stack Exchange API returned an error")
    items = object_list(root.get("items"), "response items", limit=limit)
    has_more = root.get("has_more", False)
    if not isinstance(has_more, bool):
        raise StackExchangeReadProviderError("Stack Exchange has_more must be boolean")
    backoff = root.get("backoff")
    if backoff is not None and (
        isinstance(backoff, bool) or not isinstance(backoff, int) or not 1 <= backoff <= 86400
    ):
        raise StackExchangeReadProviderError("Stack Exchange backoff is invalid")
    quota = root.get("quota_remaining")
    if isinstance(quota, bool) or not isinstance(quota, int) or quota < 0:
        raise StackExchangeReadProviderError("Stack Exchange quota_remaining is invalid")
    return items, has_more, backoff, quota


def identity_value(payload: Any, expected_network_id: str, site: str) -> dict[str, Any]:
    items, _has_more, backoff, quota = wrapper(payload, limit=1)
    if backoff is not None or quota == 0:
        raise StackExchangeReadProviderError("Stack Exchange identity is rate limited")
    if len(items) != 1:
        raise StackExchangeReadProviderError("Stack Exchange account verification returned no account")
    user = items[0]
    network = network_account_id(user.get("account_id"))
    local = site_user_id(user.get("user_id"))
    selected_site = api_site_parameter(site)
    if network != network_account_id(expected_network_id):
        raise StackExchangeReadProviderError(
            "selected Stack Exchange account does not match the configured connection"
        )
    return {
        "id": account_id(network, selected_site, local),
        "network_account_id": network,
        "site_user_id": local,
        "api_site_parameter": selected_site,
        "display_name": optional_text(user.get("display_name"), "account display name"),
        "link": optional_text(user.get("link"), "account link"),
    }


def terminal_payload(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {"status": result.status, "observed_at": observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload
