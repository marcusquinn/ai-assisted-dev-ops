#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation and serialization for the bounded Lemmy HTTP child."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Protocol

from _knowledge_social_lemmy_identity import (
    activitypub_id,
    api_family,
    provider_account_id,
)

MAX_TEXT_BYTES = 256 * 1024


class LemmyReadProviderError(RuntimeError):
    """Raised for a privacy-safe local Lemmy provider failure."""


@dataclass(frozen=True)
class ApiResult:
    status: int
    payload: Any
    retry_after: int | None = None


class PageEnvelopeRequest(Protocol):
    stream: str
    instance_id: str
    api_family: str
    exact_version: str


def observed_at() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def exact_keys(request: dict[str, Any], expected: set[str]) -> None:
    if set(request) != expected:
        raise LemmyReadProviderError("Lemmy read request has an invalid action shape")


def decode_json(payload: bytes, limit: int) -> Any:
    if len(payload) > limit:
        raise LemmyReadProviderError("Lemmy JSON payload exceeds the safety limit")
    try:
        return json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise LemmyReadProviderError("Lemmy JSON payload is invalid") from error


def request_object(payload: bytes, limit: int) -> dict[str, Any]:
    request = decode_json(payload, limit)
    if not isinstance(request, dict):
        raise LemmyReadProviderError("Lemmy read request root must be an object")
    return request


def object_value(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise LemmyReadProviderError(f"Lemmy {field} must be an object")
    return value


def object_list(value: Any, field: str, *, limit: int) -> list[dict[str, Any]]:
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise LemmyReadProviderError(f"Lemmy {field} must be an array of objects")
    if len(value) > limit:
        raise LemmyReadProviderError(f"Lemmy {field} exceeds the item safety limit")
    return value


def optional_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value:
        raise LemmyReadProviderError(f"Lemmy {field} must be text")
    if len(value.encode("utf-8")) > MAX_TEXT_BYTES:
        raise LemmyReadProviderError(f"Lemmy {field} exceeds the safety limit")
    return value


def required_text(value: Any, field: str) -> str:
    text = optional_text(value, field)
    if not text:
        raise LemmyReadProviderError(f"Lemmy {field} is required")
    return text


def optional_boolean(value: Any, field: str) -> bool | None:
    if value is None:
        return None
    if not isinstance(value, bool):
        raise LemmyReadProviderError(f"Lemmy {field} must be boolean")
    return value


def identity_value(payload: Any, expected_id: str, installation: str) -> dict[str, Any]:
    """Serialize identity from the cross-version GET /api/v3/site response."""
    site = object_value(payload, "site discovery response")
    version = required_text(site.get("version"), "instance version")
    try:
        family = api_family(version)
    except RuntimeError as error:
        raise LemmyReadProviderError(str(error)) from error
    my_user = object_value(site.get("my_user"), "authenticated user")
    local_view = object_value(my_user.get("local_user_view"), "local user view")
    person = object_value(local_view.get("person"), "authenticated person")
    try:
        local_id = provider_account_id(person.get("id"))
        expected = provider_account_id(expected_id)
        ap_id_key = "ap_id" if family == "v4" else "actor_id"
        person_ap_id = activitypub_id(person.get(ap_id_key), "person ActivityPub ID")
    except RuntimeError as error:
        raise LemmyReadProviderError(str(error)) from error
    if local_id != expected or person.get("local") is not True:
        raise LemmyReadProviderError(
            "selected Lemmy account does not match the configured connection"
        )
    return {
        "provider_account_id": local_id,
        "username": required_text(person.get("name"), "person name"),
        "display_name": optional_text(person.get("display_name"), "person display name"),
        "ap_id": person_ap_id,
        "instance_id": installation,
        "api_family": family,
        "exact_version": version,
    }


def page_payload(
    request: PageEnvelopeRequest,
    records: list[dict[str, Any]],
    next_page: str | int | None,
    complete: bool,
    watermark: str | None,
) -> dict[str, Any]:
    """Serialize one version-specific page through a shared neutral envelope."""
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": records,
        "meta": {
            "stream": request.stream,
            "instance_id": request.instance_id,
            "api_family": request.api_family,
            "exact_version": request.exact_version,
            "next": next_page,
            "complete": complete,
            "watermark": watermark,
            "snapshot": True,
        },
    }


def terminal_payload(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {"status": result.status, "observed_at": observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload
