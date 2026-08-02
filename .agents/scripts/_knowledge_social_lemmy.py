#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Lemmy version-gated stream policy and isolated cursor contracts."""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from _knowledge_social_lemmy_identity import (
    LemmyAdapterError,
    LemmyProviderUnavailableError,
    account_name,
    activitypub_id,
    api_family,
    instance_id,
    namespaced_id,
    provider_account_id,
)
from _knowledge_social_lemmy_streams import (
    STREAMS,
    V3_STREAMS,
    V4_STREAMS,
    checkpoint_watermark,
    initial_overlap_cutoff,
    require_overlap_policy,
)
from knowledge_social_import import canonical_json, reject_credentials

PROVIDER = "lemmy"
V4_CURSOR_PREFIX = "lemmy-v4-cursor-v1:"
V3_CURSOR_PREFIX = "lemmy-v3-page-v1:"
MAX_PAGE_ITEMS = 50
ACCOUNT_AUTH_MODE = "user_token"

ADAPTER_ERROR = LemmyAdapterError
PROVIDER_UNAVAILABLE_ERROR = LemmyProviderUnavailableError


@dataclass(frozen=True)
class PageRequest:
    stream: str
    account_id: str
    provider_account_id: str
    username: str
    ap_id: str
    instance_id: str
    api_family: str
    exact_version: str
    position: int
    page_cursor: str | None
    watermark: str | None
    overlap_cutoff: str | None
    limit: int

    def payload(self) -> dict[str, Any]:
        return {
            "action": "page",
            "stream": self.stream,
            "account_id": self.account_id,
            "provider_account_id": self.provider_account_id,
            "username": self.username,
            "ap_id": self.ap_id,
            "instance_id": self.instance_id,
            "api_family": self.api_family,
            "exact_version": self.exact_version,
            "position": self.position,
            "page_cursor": self.page_cursor,
            "watermark": self.watermark,
            "overlap_cutoff": self.overlap_cutoff,
            "limit": self.limit,
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())


PAGE_REQUEST_KEYS = {
    "action", "stream", "account_id", "provider_account_id", "username",
    "ap_id", "instance_id", "api_family", "exact_version", "position",
    "page_cursor", "watermark", "overlap_cutoff", "limit",
}


def _text(value: Any, field: str, *, optional: bool = False, limit: int = 8192) -> str | None:
    if value is None and optional:
        return None
    if not isinstance(value, str) or not value or "\x00" in value:
        raise LemmyAdapterError(f"Lemmy {field} is invalid")
    if len(value.encode("utf-8")) > limit:
        raise LemmyAdapterError(f"Lemmy {field} is invalid")
    return value


def _position(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 1:
        raise LemmyAdapterError("Lemmy page position must be positive")
    return value


def _supported_stream(family: str, stream: str) -> None:
    supported = V4_STREAMS if family == "v4" else V3_STREAMS
    if stream not in supported:
        raise LemmyAdapterError("Lemmy stream is unsupported for the discovered version")


def _encode_cursor(
    family: str,
    version: str,
    position: int,
    token: str,
    overlap_cutoff: str | None,
) -> str:
    payload = canonical_json(
        {
            "api_family": family,
            "exact_version": version,
            "position": position,
            "page_value": token,
            "overlap_cutoff": overlap_cutoff,
        }
    ).encode()
    encoded = base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")
    prefix = V4_CURSOR_PREFIX if family == "v4" else V3_CURSOR_PREFIX
    return f"{prefix}{encoded}"


def _decode_cursor(
    cursor: str, family: str, version: str
) -> tuple[int, str, str | None]:
    expected_prefix = V4_CURSOR_PREFIX if family == "v4" else V3_CURSOR_PREFIX
    if not cursor.startswith(expected_prefix):
        raise LemmyAdapterError("stored Lemmy cursor belongs to another API family")
    try:
        raw = cursor.removeprefix(expected_prefix)
        parsed = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise LemmyAdapterError("stored Lemmy cursor is invalid") from error
    if not isinstance(parsed, dict) or set(parsed) != {
        "api_family", "exact_version", "overlap_cutoff", "page_value", "position",
    }:
        raise LemmyAdapterError("stored Lemmy cursor has an invalid shape")
    reject_credentials(parsed)
    if parsed["api_family"] != family or parsed["exact_version"] != version:
        raise LemmyAdapterError("stored Lemmy cursor version does not match the instance")
    position = _position(parsed["position"])
    token = _text(parsed["page_value"], "cursor value")
    overlap_cutoff = _text(
        parsed["overlap_cutoff"], "overlap cutoff", optional=True
    )
    if token is None:
        raise LemmyAdapterError("stored Lemmy cursor is invalid")
    if family == "v3" and (not token.isdigit() or int(token) != position):
        raise LemmyAdapterError("stored Lemmy v3 page cursor is invalid")
    return position, token, overlap_cutoff


def page_request(stream: str, account: dict[str, Any], state: CursorState, limit: int) -> PageRequest:
    if stream not in STREAMS:
        raise LemmyAdapterError("Lemmy stream is unsupported")
    family = _text(account.get("api_family"), "API family")
    version = _text(account.get("exact_version"), "instance version")
    if family not in ("v3", "v4") or version is None or api_family(version) != family:
        raise LemmyAdapterError("verified Lemmy version identity is incomplete")
    _supported_stream(family, stream)
    watermark = _text(state.watermark, "watermark", optional=True)
    position, page_cursor, overlap_cutoff = (1, None, None)
    if state.cursor:
        position, page_cursor, overlap_cutoff = _decode_cursor(
            state.cursor, family, version
        )
    else:
        overlap_cutoff = initial_overlap_cutoff(
            stream, state.backfill_complete, watermark
        )
    require_overlap_policy(stream, overlap_cutoff)
    local_id = provider_account_id(account.get("provider_account_id"))
    installation = instance_id(account.get("instance_id"))
    expected_account = namespaced_id(installation, "person", local_id)
    if account.get("id") != expected_account:
        raise LemmyAdapterError("verified Lemmy identity is incomplete")
    return PageRequest(
        stream,
        expected_account,
        local_id,
        account_name(account.get("username")),
        activitypub_id(account.get("ap_id"), "person ActivityPub ID"),
        installation,
        family,
        version,
        position,
        page_cursor,
        watermark,
        overlap_cutoff,
        limit,
    )


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    if set(payload) != PAGE_REQUEST_KEYS or payload.get("action") != "page":
        raise LemmyAdapterError("Lemmy read request has an invalid action shape")
    stream = payload.get("stream")
    family = payload.get("api_family")
    version = _text(payload.get("exact_version"), "instance version")
    if not isinstance(stream, str) or stream not in STREAMS:
        raise LemmyAdapterError("Lemmy stream is unsupported")
    if family not in ("v3", "v4") or version is None or api_family(version) != family:
        raise LemmyAdapterError("Lemmy API family is invalid")
    _supported_stream(family, stream)
    limit = payload.get("limit")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= MAX_PAGE_ITEMS:
        raise LemmyAdapterError("Lemmy page size is invalid")
    installation = instance_id(payload.get("instance_id"))
    local_id = provider_account_id(payload.get("provider_account_id"))
    if payload.get("account_id") != namespaced_id(installation, "person", local_id):
        raise LemmyAdapterError("Lemmy selected account ID is invalid")
    page_cursor = _text(payload.get("page_cursor"), "page cursor", optional=True)
    position = _position(payload.get("position"))
    if family == "v3" and position > 1 and page_cursor != str(position):
        raise LemmyAdapterError("Lemmy v3 page cursor is invalid")
    overlap_cutoff = _text(
        payload.get("overlap_cutoff"), "overlap cutoff", optional=True
    )
    require_overlap_policy(stream, overlap_cutoff)
    return PageRequest(
        stream,
        payload["account_id"],
        local_id,
        account_name(payload.get("username")),
        activitypub_id(payload.get("ap_id"), "person ActivityPub ID"),
        installation,
        family,
        version,
        position,
        page_cursor,
        _text(payload.get("watermark"), "watermark", optional=True),
        overlap_cutoff,
        limit,
    )


def response_status(payload: dict[str, Any]) -> int:
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise LemmyAdapterError("Lemmy response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise LemmyAdapterError("Lemmy page data must be an array")
    return data


def page_checkpoint(
    payload: dict[str, Any], state: CursorState, request: PageRequest
) -> tuple[PageCheckpoint, bool]:
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise LemmyAdapterError("Lemmy page metadata must be an object")
    reject_credentials(meta)
    provenance = (
        meta.get("stream") == request.stream,
        meta.get("instance_id") == request.instance_id,
        meta.get("api_family") == request.api_family,
        meta.get("exact_version") == request.exact_version,
        meta.get("snapshot") is True,
    )
    if not all(provenance):
        raise LemmyAdapterError("Lemmy page provenance is invalid")
    if len(page_data(payload)) > MAX_PAGE_ITEMS:
        raise LemmyAdapterError("Lemmy page exceeds the item safety limit")
    complete = meta.get("complete")
    if not isinstance(complete, bool):
        raise LemmyAdapterError("Lemmy page completion metadata is invalid")
    next_value = meta.get("next")
    if complete != (next_value is None):
        raise LemmyAdapterError("Lemmy page completion cursor is invalid")
    token: str | None = None
    if next_value is not None:
        if request.api_family == "v4":
            token = _text(next_value, "v4 page cursor")
        elif (
            isinstance(next_value, bool)
            or not isinstance(next_value, int)
            or next_value != request.position + 1
        ):
            raise LemmyAdapterError("Lemmy v3 next page is invalid")
        else:
            token = str(next_value)
    watermark = checkpoint_watermark(
        request.stream,
        state.watermark,
        _text(meta.get("watermark"), "watermark", optional=True),
    )
    cursor = (
        _encode_cursor(
            request.api_family,
            request.exact_version,
            request.position + 1,
            token,
            request.overlap_cutoff,
        )
        if token is not None
        else None
    )
    return PageCheckpoint(cursor, watermark), complete
