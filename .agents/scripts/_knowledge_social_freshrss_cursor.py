#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Versioned opaque FreshRSS continuation encoding and validation."""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import re
from typing import Any

from _knowledge_social_freshrss_identity import FreshRSSAdapterError
from knowledge_social_import import canonical_json, reject_credentials

CURSOR_PREFIX = "freshrss-greader-v2:"
MAX_CURSOR_ENVELOPE_BYTES = 64 * 1024
MAX_CURSOR_HISTORY = 256
SHA256 = re.compile(r"^[0-9a-f]{64}$")


def positive_int(value: Any, field: str, *, allow_zero: bool = False) -> int:
    minimum = 0 if allow_zero else 1
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise FreshRSSAdapterError(f"FreshRSS {field} is invalid")
    return value


def continuation_value(value: Any) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise FreshRSSAdapterError("FreshRSS continuation is invalid")
    if not value or "\x00" in value:
        raise FreshRSSAdapterError("FreshRSS continuation is invalid")
    if len(value.encode()) > 16 * 1024:
        raise FreshRSSAdapterError("FreshRSS continuation is invalid")
    return value


def continuation_digest(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def validate_continuation_history(
    value: Any, continuation: str | None, field: str
) -> tuple[str, ...]:
    if not isinstance(value, list) or len(value) > MAX_CURSOR_HISTORY:
        raise FreshRSSAdapterError(f"FreshRSS {field} is invalid")
    if any(
        not isinstance(item, str) or SHA256.fullmatch(item) is None for item in value
    ):
        raise FreshRSSAdapterError(f"FreshRSS {field} is invalid")
    if len(value) != len(set(value)):
        raise FreshRSSAdapterError(f"FreshRSS {field} is invalid")
    seen = tuple(value)
    if continuation is None and seen:
        raise FreshRSSAdapterError(f"FreshRSS {field} is inconsistent")
    if continuation is not None and continuation_digest(continuation) not in seen:
        raise FreshRSSAdapterError(f"FreshRSS {field} is incomplete")
    return seen


def encode_cursor(
    continuation: str, newer_than: int | None, seen: tuple[str, ...]
) -> str:
    encoded = base64.urlsafe_b64encode(
        canonical_json(
            {"continuation": continuation, "newer_than": newer_than, "seen": list(seen)}
        ).encode()
    ).decode().rstrip("=")
    return f"{CURSOR_PREFIX}{encoded}"


def decode_cursor(cursor: str) -> tuple[str, int | None, tuple[str, ...]]:
    if (
        not isinstance(cursor, str)
        or not cursor.startswith(CURSOR_PREFIX)
        or len(cursor.encode()) > MAX_CURSOR_ENVELOPE_BYTES
    ):
        raise FreshRSSAdapterError("stored FreshRSS cursor has an unsupported version")
    try:
        raw = cursor.removeprefix(CURSOR_PREFIX)
        decoded = base64.b64decode(
            raw + "=" * (-len(raw) % 4), altchars=b"-_", validate=True
        )
        payload = json.loads(decoded)
    except (ValueError, UnicodeError, json.JSONDecodeError, binascii.Error) as error:
        raise FreshRSSAdapterError("stored FreshRSS cursor is invalid") from error
    if not isinstance(payload, dict) or set(payload) != {
        "continuation",
        "newer_than",
        "seen",
    }:
        raise FreshRSSAdapterError("stored FreshRSS cursor has an invalid shape")
    reject_credentials(payload)
    newer_than = payload.get("newer_than")
    if newer_than is not None:
        newer_than = positive_int(newer_than, "newer-than cursor", allow_zero=True)
    continuation = continuation_value(payload.get("continuation"))
    if continuation is None:
        raise FreshRSSAdapterError("stored FreshRSS cursor is invalid")
    seen = validate_continuation_history(
        payload.get("seen"), continuation, "stored continuation history"
    )
    return continuation, newer_than, seen
