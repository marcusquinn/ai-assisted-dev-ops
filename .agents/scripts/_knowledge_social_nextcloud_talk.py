#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Nextcloud Talk stream policy, private instance identity, and checkpoints."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import re
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from knowledge_social_import import canonical_json, reject_credentials

PROVIDER = "nextcloud_talk"
CURSOR_PREFIX = "nextcloud-talk-v1:"
RETENTION_LIMIT = "room_retention_membership_and_message_expiration"
INSTANCE = re.compile(r"^[0-9a-f]{24}$")
OPAQUE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,191}$")


class NextcloudTalkAdapterError(RuntimeError):
    """Raised when provider evidence violates the Talk collector contract."""


class NextcloudTalkProviderUnavailableError(NextcloudTalkAdapterError):
    """Raised when the isolated Talk reader cannot be used safely."""


ADAPTER_ERROR = NextcloudTalkAdapterError
PROVIDER_UNAVAILABLE_ERROR = NextcloudTalkProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    """Collection and coverage policy for one Talk stream."""

    resource_kind: str
    activity_mode: str
    pagination: str
    incremental: bool
    retention_limit: str | None
    coverage_status: str | None = None
    unavailable_reason: str | None = None
    cost_units: int = 3


STREAMS = {
    "capabilities": StreamSpec(
        "installation_capability", "selected_account", "snapshot", False, None, cost_units=3
    ),
    "rooms": StreamSpec("conversation", "membership", "snapshot", False, RETENTION_LIMIT),
    "participants": StreamSpec(
        "participant", "room_membership", "room_snapshot", False, RETENTION_LIMIT
    ),
    "messages": StreamSpec(
        "message", "room_history", "room_history", True, RETENTION_LIMIT
    ),
}


def _text(value: Any, field: str, *, limit: int = 512) -> str:
    if (
        not isinstance(value, str)
        or not value
        or "\x00" in value
        or len(value.encode("utf-8")) > limit
    ):
        raise NextcloudTalkAdapterError(f"Nextcloud Talk {field} is invalid")
    return value


def instance_id(value: Any) -> str:
    """Validate one privacy-safe installation fingerprint."""
    text = _text(value, "instance identity", limit=24)
    if INSTANCE.fullmatch(text) is None:
        raise NextcloudTalkAdapterError("Nextcloud Talk instance identity is invalid")
    return text


def provider_account_id(value: Any) -> str:
    """Validate the selected account selector without accepting a global ID."""
    text = _text(value, "account ID")
    local = text.removeprefix("user_")
    if not local or OPAQUE.fullmatch(local) is None:
        raise NextcloudTalkAdapterError("Nextcloud Talk account ID is invalid")
    return local


def private_fingerprint(key: str, *parts: str) -> str:
    """Create an opaque stable identifier without persisting native identifiers."""
    encoded = key.encode("utf-8")
    if len(encoded) < 32:
        raise NextcloudTalkAdapterError(
            "Nextcloud Talk profile origin key must be at least 32 bytes"
        )
    message = "\x00".join(parts).encode("utf-8")
    return hmac.new(encoded, message, hashlib.sha256).hexdigest()[:24]


def namespaced_id(installation: str, kind: str, native_id: Any) -> str:
    """Namespace a provider object while hiding its native identifier."""
    installation = instance_id(installation)
    kind = _text(kind, "object kind", limit=32)
    native = _text(str(native_id), "native object ID", limit=2048)
    digest = hashlib.sha256(f"{installation}\x00{kind}\x00{native}".encode()).hexdigest()[:24]
    return f"nct_{installation}_{kind}_{digest}"


def _non_negative(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise NextcloudTalkAdapterError(f"Nextcloud Talk {field} must be non-negative")
    return value


def _watermarks(value: Any, field: str) -> dict[str, str]:
    if value is None:
        return {}
    if not isinstance(value, dict) or len(value) > 100:
        raise NextcloudTalkAdapterError(f"Nextcloud Talk {field} is invalid")
    result: dict[str, str] = {}
    for room_id, message_id in value.items():
        room = _text(room_id, f"{field} room")
        message = _text(message_id, f"{field} message")
        result[room] = message
    return result


def _encode_state(
    room_index: int,
    position: int,
    stop_map: dict[str, str],
    newest_map: dict[str, str],
) -> str:
    payload = canonical_json(
        {
            "newest": newest_map,
            "position": position,
            "room_index": room_index,
            "stop": stop_map,
        }
    ).encode()
    return CURSOR_PREFIX + base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")


def _decode_state(cursor: str) -> tuple[int, int, dict[str, str], dict[str, str]]:
    if not cursor.startswith(CURSOR_PREFIX):
        raise NextcloudTalkAdapterError("stored Nextcloud Talk cursor is unsupported")
    encoded = cursor.removeprefix(CURSOR_PREFIX)
    try:
        payload = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise NextcloudTalkAdapterError("stored Nextcloud Talk cursor is invalid") from error
    if not isinstance(payload, dict) or set(payload) != {
        "newest", "position", "room_index", "stop"
    }:
        raise NextcloudTalkAdapterError("stored Nextcloud Talk cursor shape is invalid")
    reject_credentials(payload)
    return (
        _non_negative(payload["room_index"], "cursor room index"),
        _non_negative(payload["position"], "cursor message position"),
        _watermarks(payload["stop"], "cursor stop map"),
        _watermarks(payload["newest"], "cursor newest map"),
    )


def _encode_watermark(value: dict[str, str]) -> str | None:
    if not value:
        return None
    payload = canonical_json(value).encode()
    return base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")


def _decode_watermark(value: str | None) -> dict[str, str]:
    if value is None:
        return {}
    try:
        payload = json.loads(base64.urlsafe_b64decode(value + "=" * (-len(value) % 4)))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise NextcloudTalkAdapterError("stored Nextcloud Talk watermark is invalid") from error
    return _watermarks(payload, "watermark")


@dataclass(frozen=True)
class PageRequest:
    """Exact request envelope passed to the isolated GET-only child."""

    stream: str
    account_id: str
    provider_account_id: str
    instance_id: str
    room_index: int
    room_id: str | None
    position: int
    stop_at: str | None
    limit: int
    stop_map: dict[str, str]
    newest_map: dict[str, str]

    def payload(self) -> dict[str, Any]:
        return {
            "action": "page",
            "stream": self.stream,
            "account_id": self.account_id,
            "provider_account_id": self.provider_account_id,
            "instance_id": self.instance_id,
            "room_index": self.room_index,
            "room_id": self.room_id,
            "position": self.position,
            "stop_at": self.stop_at,
            "limit": self.limit,
            "stop_map": self.stop_map,
            "newest_map": self.newest_map,
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())


PAGE_REQUEST_KEYS = set(PageRequest.__dataclass_fields__) | {"action"}


def _room_ids(account: dict[str, Any]) -> tuple[str, ...]:
    values = account.get("room_ids")
    if not isinstance(values, list) or not values or len(values) > 100:
        raise NextcloudTalkAdapterError("verified Nextcloud Talk room allowlist is invalid")
    rooms = tuple(_text(value, "room identity") for value in values)
    if len(set(rooms)) != len(rooms):
        raise NextcloudTalkAdapterError("verified Nextcloud Talk room allowlist is invalid")
    return rooms


def page_request(
    stream: str, account: dict[str, Any], state: CursorState, limit: int
) -> PageRequest:
    """Build one request from independent stream and per-room history state."""
    if stream not in STREAMS:
        raise NextcloudTalkAdapterError("Nextcloud Talk stream is unsupported")
    rooms = _room_ids(account)
    room_index = 0
    position = 0
    stop_map = _decode_watermark(state.watermark) if state.backfill_complete else {}
    newest_map = dict(stop_map)
    if state.cursor:
        room_index, position, stop_map, newest_map = _decode_state(state.cursor)
    if stream in ("capabilities", "rooms"):
        room_index = 0
        position = 0
        room_id = None
    else:
        if room_index >= len(rooms):
            raise NextcloudTalkAdapterError("Nextcloud Talk cursor room is out of range")
        room_id = rooms[room_index]
    return PageRequest(
        stream,
        _text(account.get("id"), "selected account identity"),
        provider_account_id(account.get("provider_account_id")),
        instance_id(account.get("instance_id")),
        room_index,
        room_id,
        position,
        stop_map.get(room_id) if room_id else None,
        limit,
        stop_map,
        newest_map,
    )


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    """Validate an exact child-process page request."""
    if set(payload) != PAGE_REQUEST_KEYS or payload.get("action") != "page":
        raise NextcloudTalkAdapterError("Nextcloud Talk read request shape is invalid")
    stream = payload.get("stream")
    if not isinstance(stream, str) or stream not in STREAMS:
        raise NextcloudTalkAdapterError("Nextcloud Talk stream is unsupported")
    limit = payload.get("limit")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 200:
        raise NextcloudTalkAdapterError("Nextcloud Talk page size is invalid")
    room = payload.get("room_id")
    if room is not None:
        room = _text(room, "room identity")
    return PageRequest(
        stream,
        _text(payload.get("account_id"), "selected account identity"),
        provider_account_id(payload.get("provider_account_id")),
        instance_id(payload.get("instance_id")),
        _non_negative(payload.get("room_index"), "room index"),
        room,
        _non_negative(payload.get("position"), "message position"),
        None if payload.get("stop_at") is None else _text(payload.get("stop_at"), "watermark"),
        limit,
        _watermarks(payload.get("stop_map"), "stop map"),
        _watermarks(payload.get("newest_map"), "newest map"),
    )


def response_status(payload: dict[str, Any]) -> int:
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise NextcloudTalkAdapterError("Nextcloud Talk response status is invalid")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise NextcloudTalkAdapterError("Nextcloud Talk page data must be an array")
    return data


def page_checkpoint(
    payload: dict[str, Any], state: CursorState, request: PageRequest
) -> tuple[PageCheckpoint, bool]:
    """Calculate one atomic stream checkpoint with independent room watermarks."""
    del state
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise NextcloudTalkAdapterError("Nextcloud Talk page metadata is missing")
    reject_credentials(meta)
    if meta.get("stream") != request.stream or meta.get("instance_id") != request.instance_id:
        raise NextcloudTalkAdapterError("Nextcloud Talk page provenance is invalid")
    if meta.get("room_id") != request.room_id:
        raise NextcloudTalkAdapterError("Nextcloud Talk room identity was rebound")
    limits = {
        "capabilities": 1,
        "rooms": 100,
        "participants": 500,
        "messages": request.limit,
    }
    if len(page_data(payload)) > limits[request.stream]:
        raise NextcloudTalkAdapterError("Nextcloud Talk page exceeds the item safety limit")
    complete = meta.get("complete")
    if not isinstance(complete, bool):
        raise NextcloudTalkAdapterError("Nextcloud Talk completion metadata is invalid")
    newest_map = dict(request.newest_map)
    newest = meta.get("newest_id")
    if newest is not None and request.room_id and request.position == 0:
        newest_map[request.room_id] = _text(newest, "newest message identity")
    if complete:
        return PageCheckpoint(None, _encode_watermark(newest_map)), True
    next_room = _non_negative(meta.get("next_room_index"), "next room index")
    next_position = _non_negative(meta.get("next_position"), "next message position")
    if next_room < request.room_index or (
        next_room == request.room_index and next_position <= request.position
    ):
        raise NextcloudTalkAdapterError("Nextcloud Talk pagination did not advance")
    cursor = _encode_state(next_room, next_position, request.stop_map, newest_map)
    return PageCheckpoint(cursor, _encode_watermark(newest_map)), False
