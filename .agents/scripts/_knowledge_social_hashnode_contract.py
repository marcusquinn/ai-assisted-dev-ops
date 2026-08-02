#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation primitives for the bounded Hashnode GraphQL child."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any
from urllib.parse import urlsplit

from _knowledge_social_hashnode_identity import (
    INSTANCE_ID,
    account_id,
    provider_account_id,
    username,
)

MAX_TEXT_BYTES = 512 * 1024


class HashnodeReadProviderError(RuntimeError):
    """Raised for a privacy-safe local Hashnode provider failure."""


@dataclass(frozen=True)
class ApiResult:
    status: int
    payload: Any
    retry_after: int | None = None


def observed_at() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def decode_json(payload: bytes, limit: int) -> Any:
    if len(payload) > limit:
        raise HashnodeReadProviderError("Hashnode JSON payload exceeds the safety limit")
    try:
        return json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise HashnodeReadProviderError("Hashnode JSON payload is invalid") from error


def request_object(payload: bytes, limit: int) -> dict[str, Any]:
    request = decode_json(payload, limit)
    if not isinstance(request, dict):
        raise HashnodeReadProviderError("Hashnode read request root must be an object")
    return request


def object_value(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise HashnodeReadProviderError(f"Hashnode {field} must be an object")
    return value


def object_list(value: Any, field: str, *, limit: int) -> list[dict[str, Any]]:
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise HashnodeReadProviderError(
            f"Hashnode {field} must be an array of objects"
        )
    if len(value) > limit:
        raise HashnodeReadProviderError(
            f"Hashnode {field} exceeds the item safety limit"
        )
    return value


def optional_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value:
        raise HashnodeReadProviderError(f"Hashnode {field} must be text")
    if len(value.encode()) > MAX_TEXT_BYTES:
        raise HashnodeReadProviderError(f"Hashnode {field} exceeds the safety limit")
    return value


def required_text(value: Any, field: str) -> str:
    text = optional_text(value, field)
    if not text:
        raise HashnodeReadProviderError(f"Hashnode {field} is required")
    return text


def public_url(value: Any, field: str) -> str | None:
    text = optional_text(value, field)
    if text is None:
        return None
    try:
        parsed = urlsplit(text)
        port = parsed.port
    except ValueError as error:
        raise HashnodeReadProviderError(f"Hashnode {field} is invalid") from error
    if parsed.scheme != "https" or not parsed.hostname:
        raise HashnodeReadProviderError(f"Hashnode {field} is not a safe public URL")
    if port not in (None, 443):
        raise HashnodeReadProviderError(f"Hashnode {field} is not a safe public URL")
    if parsed.username is not None or parsed.password is not None:
        raise HashnodeReadProviderError(f"Hashnode {field} is not a safe public URL")
    if parsed.query or parsed.fragment:
        raise HashnodeReadProviderError(f"Hashnode {field} is not a safe public URL")
    return text


def nonnegative_int(value: Any, field: str, *, optional: bool = False) -> int | None:
    if value is None and optional:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise HashnodeReadProviderError(f"Hashnode {field} must be non-negative")
    return value


def terminal_payload(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {"status": result.status, "observed_at": observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload


def identity_record(payload: Any, expected_id: str) -> dict[str, Any]:
    root = object_value(payload, "GraphQL identity response")
    data = object_value(root.get("data"), "GraphQL identity data")
    viewer = object_value(data.get("me"), "GraphQL viewer")
    remote = provider_account_id(viewer.get("id"))
    if remote != provider_account_id(expected_id):
        raise HashnodeReadProviderError(
            "selected Hashnode account does not match the configured connection"
        )
    handle = username(viewer.get("username"))
    bio = viewer.get("bio")
    bio_text = None
    if bio is not None:
        bio_text = optional_text(object_value(bio, "viewer bio").get("text"), "viewer bio")
    return {
        "id": account_id(remote),
        "provider_account_id": remote,
        "username": handle,
        "name": optional_text(viewer.get("name"), "viewer name"),
        "bio": bio_text,
        "tagline": optional_text(viewer.get("tagline"), "viewer tagline"),
        "location": optional_text(viewer.get("location"), "viewer location"),
        "date_joined": optional_text(viewer.get("dateJoined"), "viewer join date"),
        "instance_id": INSTANCE_ID,
    }
