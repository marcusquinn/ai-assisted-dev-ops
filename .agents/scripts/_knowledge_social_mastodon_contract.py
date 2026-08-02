#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation and serialization for the bounded Mastodon HTTP child."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_mastodon_identity import provider_account_id

MAX_TEXT_BYTES = 256 * 1024


class MastodonReadProviderError(RuntimeError):
    """Raised for a privacy-safe local Mastodon provider failure."""


@dataclass(frozen=True)
class ApiResult:
    status: int
    payload: Any
    next_url: str | None = None
    retry_after: int | None = None


def observed_at() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def exact_keys(request: dict[str, Any], expected: set[str]) -> None:
    if set(request) != expected:
        raise MastodonReadProviderError("Mastodon read request has an invalid action shape")


def decode_json(payload: bytes, limit: int) -> Any:
    if len(payload) > limit:
        raise MastodonReadProviderError("Mastodon JSON payload exceeds the safety limit")
    try:
        return json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise MastodonReadProviderError("Mastodon JSON payload is invalid") from error


def request_object(payload: bytes, limit: int) -> dict[str, Any]:
    request = decode_json(payload, limit)
    if not isinstance(request, dict):
        raise MastodonReadProviderError("Mastodon read request root must be an object")
    return request


def object_value(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise MastodonReadProviderError(f"Mastodon {field} must be an object")
    return value


def object_list(value: Any, field: str, *, limit: int) -> list[dict[str, Any]]:
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise MastodonReadProviderError(f"Mastodon {field} must be an array of objects")
    if len(value) > limit:
        raise MastodonReadProviderError(f"Mastodon {field} exceeds the item safety limit")
    return value


def optional_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value:
        raise MastodonReadProviderError(f"Mastodon {field} must be text")
    if len(value.encode("utf-8")) > MAX_TEXT_BYTES:
        raise MastodonReadProviderError(f"Mastodon {field} exceeds the safety limit")
    return value


def required_text(value: Any, field: str) -> str:
    text = optional_text(value, field)
    if not text:
        raise MastodonReadProviderError(f"Mastodon {field} is required")
    return text


def optional_boolean(value: Any, field: str) -> bool | None:
    if value is None:
        return None
    if not isinstance(value, bool):
        raise MastodonReadProviderError(f"Mastodon {field} must be boolean")
    return value


def identity_value(payload: Any, expected_id: str, installation: str) -> dict[str, Any]:
    """Serialize only stable allowlisted fields from verify_credentials."""
    account = object_value(payload, "identity response")
    local_id = required_text(account.get("id"), "account ID")
    if provider_account_id(local_id) != provider_account_id(expected_id):
        raise MastodonReadProviderError(
            "selected Mastodon account does not match the configured connection"
        )
    username = required_text(account.get("username"), "account username")
    acct = required_text(account.get("acct"), "account acct")
    return {
        "provider_account_id": local_id,
        "username": username,
        "acct": acct,
        "display_name": optional_text(account.get("display_name"), "account display name"),
        "uri": optional_text(account.get("uri"), "account URI"),
        "instance_id": installation,
    }


def terminal_payload(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {"status": result.status, "observed_at": observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload
