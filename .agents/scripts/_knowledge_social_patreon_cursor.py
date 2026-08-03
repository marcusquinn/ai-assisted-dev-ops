#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Opaque Patreon cursor envelopes and JSON:API pagination validation."""

from __future__ import annotations

import base64
import hashlib
import json
import re
from typing import Any

from _knowledge_social_patreon_types import (
    CURSOR_PREFIX,
    MAX_CURSOR_BYTES,
    MAX_CURSOR_HISTORY,
    PatreonAdapterError,
    campaign_id,
)
from knowledge_social_import import canonical_json, reject_credentials


def optional_cursor(value: Any, field: str) -> str | None:
    """Validate one bounded opaque provider cursor."""
    if value is None:
        return None
    if not isinstance(value, str) or not value or "\x00" in value:
        raise PatreonAdapterError(f"Patreon {field} is invalid")
    if len(value.encode()) > MAX_CURSOR_BYTES:
        raise PatreonAdapterError(f"Patreon {field} is invalid")
    return value


def cursor_digest(value: str) -> str:
    """Return the non-reversible loop-detection digest for a cursor."""
    return hashlib.sha256(value.encode()).hexdigest()


def validate_cursor_history(
    value: Any, cursor: str | None, field: str
) -> tuple[str, ...]:
    """Validate bounded cursor-digest history and its current-cursor binding."""
    if not isinstance(value, list) or len(value) > MAX_CURSOR_HISTORY:
        raise PatreonAdapterError(f"Patreon {field} is invalid")
    if any(not isinstance(item, str) for item in value):
        raise PatreonAdapterError(f"Patreon {field} is invalid")
    if any(re.fullmatch(r"[0-9a-f]{64}", item) is None for item in value):
        raise PatreonAdapterError(f"Patreon {field} is invalid")
    if len(value) != len(set(value)):
        raise PatreonAdapterError(f"Patreon {field} is invalid")
    seen = tuple(value)
    if cursor is None and seen:
        raise PatreonAdapterError(f"Patreon {field} is inconsistent")
    if cursor is not None and cursor_digest(cursor) not in seen:
        raise PatreonAdapterError(f"Patreon {field} is incomplete")
    return seen


def encode_cursor(campaign: str, cursor: str | None, seen: tuple[str, ...]) -> str:
    """Encode one versioned local campaign/cursor checkpoint."""
    payload = {"campaign_id": campaign, "cursor": cursor, "seen": list(seen)}
    encoded = base64.urlsafe_b64encode(canonical_json(payload).encode()).decode().rstrip("=")
    return f"{CURSOR_PREFIX}{encoded}"


def _cursor_payload(value: str) -> dict[str, Any]:
    if not value.startswith(CURSOR_PREFIX) or len(value.encode()) > 32 * 1024:
        raise PatreonAdapterError("stored Patreon cursor has an unsupported version")
    encoded = value.removeprefix(CURSOR_PREFIX)
    try:
        payload = json.loads(base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4)))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise PatreonAdapterError("stored Patreon cursor is invalid") from error
    if not isinstance(payload, dict):
        raise PatreonAdapterError("stored Patreon cursor has an invalid shape")
    if set(payload) != {"campaign_id", "cursor", "seen"}:
        raise PatreonAdapterError("stored Patreon cursor has an invalid shape")
    reject_credentials(payload)
    return payload


def decode_cursor(value: str) -> tuple[str, str | None, tuple[str, ...]]:
    """Decode and validate one versioned local campaign/cursor checkpoint."""
    payload = _cursor_payload(value)
    campaign = campaign_id(payload.get("campaign_id"), "cursor campaign ID")
    cursor = optional_cursor(payload.get("cursor"), "cursor value")
    seen = validate_cursor_history(payload.get("seen"), cursor, "stored cursor history")
    return campaign, cursor, seen


def _object(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise PatreonAdapterError(f"Patreon {field} must be an object")
    return value


def next_cursor(root: dict[str, Any]) -> str | None:
    """Read the optional next cursor from a bounded JSON:API document."""
    metadata = root.get("meta")
    if metadata is None:
        return None
    pagination = _object(metadata, "pagination metadata").get("pagination")
    if pagination is None:
        return None
    cursors = _object(pagination, "pagination").get("cursors")
    if cursors is None:
        return None
    return optional_cursor(_object(cursors, "pagination cursors").get("next"), "next pagination cursor")
