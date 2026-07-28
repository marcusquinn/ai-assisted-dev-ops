#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation and serialization for the bounded Discourse HTTP child."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_discourse import (
    DiscourseAdapterError,
    instance_id,
    namespaced_id,
    provider_account_id,
    username,
)

MAX_TEXT_BYTES = 256 * 1024
MAX_IDENTITY_ITEMS = 1000


class DiscourseReadProviderError(RuntimeError):
    """Raised for a privacy-safe local Discourse provider failure."""


@dataclass(frozen=True)
class ApiResult:
    """One bounded HTTP result without provider error-body disclosure."""

    status: int
    payload: Any
    retry_after: int | None = None


def observed_at() -> str:
    """Return a UTC timestamp for one bounded provider response."""
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def exact_keys(request: dict[str, Any], expected: set[str]) -> None:
    """Reject request shapes outside the allowlisted read contract."""
    if set(request) != expected:
        raise DiscourseReadProviderError(
            "Discourse read request has an invalid action shape"
        )


def _bounded_request(payload: bytes, limit: int) -> bytes:
    if len(payload) > limit:
        raise DiscourseReadProviderError(
            "Discourse read request exceeds the safety limit"
        )
    return payload


def _decoded_request(payload: bytes) -> Any:
    try:
        return json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DiscourseReadProviderError(
            "Discourse read request is not valid JSON"
        ) from error


def request_object(payload: bytes, limit: int) -> dict[str, Any]:
    """Decode one bounded provider request without retaining raw input."""
    request = _decoded_request(_bounded_request(payload, limit))
    if not isinstance(request, dict):
        raise DiscourseReadProviderError(
            "Discourse read request root must be an object"
        )
    return request


def object_value(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise DiscourseReadProviderError(f"Discourse {field} must be an object")
    return value


def object_list(
    value: Any, field: str, *, limit: int | None = None
) -> list[dict[str, Any]]:
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise DiscourseReadProviderError(
            f"Discourse {field} must be an array of objects"
        )
    if limit is not None and len(value) > limit:
        raise DiscourseReadProviderError(
            f"Discourse {field} exceeds the item safety limit"
        )
    return value


def optional_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value:
        raise DiscourseReadProviderError(f"Discourse {field} must be text")
    if len(value.encode("utf-8")) > MAX_TEXT_BYTES:
        raise DiscourseReadProviderError(
            f"Discourse {field} exceeds the safety limit"
        )
    return value


def required_text(value: Any, field: str) -> str:
    text = optional_text(value, field)
    if not text:
        raise DiscourseReadProviderError(f"Discourse {field} is required")
    return text


def non_negative_integer(value: Any, field: str, *, optional: bool = False) -> int | None:
    if value is None and optional:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise DiscourseReadProviderError(
            f"Discourse {field} must be a non-negative integer"
        )
    return value


def positive_id(value: Any, field: str, *, optional: bool = False) -> str | None:
    if value is None and optional:
        return None
    number = non_negative_integer(value, field)
    if number is None or number < 1:
        raise DiscourseReadProviderError(f"Discourse {field} must be positive")
    return str(number)


def optional_boolean(value: Any, field: str) -> bool | None:
    if value is None:
        return None
    if not isinstance(value, bool):
        raise DiscourseReadProviderError(f"Discourse {field} must be boolean")
    return value


def _id_array(value: Any, field: str) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise DiscourseReadProviderError(f"Discourse {field} must be an array")
    if len(value) > MAX_IDENTITY_ITEMS:
        raise DiscourseReadProviderError(
            f"Discourse {field} exceeds the item safety limit"
        )
    return [positive_id(item, field) or "" for item in value]


def _groups(value: Any) -> list[dict[str, Any]]:
    if value is None:
        return []
    groups = object_list(value, "identity groups", limit=MAX_IDENTITY_ITEMS)
    return [
        {
            "id": positive_id(group.get("id"), "group ID"),
            "name": required_text(group.get("name"), "group name"),
            "has_messages": optional_boolean(
                group.get("has_messages"), "group message flag"
            ),
            "owner": optional_boolean(group.get("owner"), "group owner flag"),
        }
        for group in groups
    ]


CATEGORY_PREFERENCE_FIELDS = {
    "muted": "muted_category_ids",
    "regular": "regular_category_ids",
    "tracked": "tracked_category_ids",
    "watched": "watched_category_ids",
    "watched_first_post": "watched_first_post_category_ids",
}


def identity_value(
    payload: Any, expected_id: str, installation: str
) -> dict[str, Any]:
    """Serialize only the selected current-user identity and preference fields."""
    root = object_value(payload, "identity response")
    current = object_value(root.get("current_user"), "current user")
    local_id = positive_id(current.get("id"), "account ID")
    if local_id is None or local_id != provider_account_id(expected_id):
        raise DiscourseReadProviderError(
            "selected Discourse account does not match the configured connection"
        )
    handle = username(current.get("username"))
    preferences = {
        label: _id_array(current.get(field), f"{label} category IDs")
        for label, field in CATEGORY_PREFERENCE_FIELDS.items()
    }
    return {
        "provider_account_id": local_id,
        "username": handle,
        "name": optional_text(current.get("name"), "account name") or None,
        "instance_id": instance_id(installation),
        "groups": _groups(current.get("groups")),
        "category_preferences": preferences,
    }


def resource_id(installation: str, kind: str, value: Any, field: str) -> str:
    local_id = positive_id(value, field)
    if local_id is None:
        raise DiscourseReadProviderError(f"Discourse {field} is required")
    try:
        return namespaced_id(installation, kind, local_id)
    except DiscourseAdapterError as error:
        raise DiscourseReadProviderError(str(error)) from error


def terminal_payload(result: ApiResult) -> dict[str, Any]:
    """Build a sanitized terminal envelope from one HTTP result."""
    payload: dict[str, Any] = {"status": result.status, "observed_at": observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload
