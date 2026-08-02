#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Versioned opaque FreshRSS continuation encoding and validation."""

from __future__ import annotations

import base64
import json
from typing import Any

from _knowledge_social_freshrss_identity import FreshRSSAdapterError
from knowledge_social_import import canonical_json, reject_credentials

CURSOR_PREFIX = "freshrss-greader-v1:"


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


def encode_cursor(continuation: str, newer_than: int | None) -> str:
    encoded = base64.urlsafe_b64encode(
        canonical_json({"continuation": continuation, "newer_than": newer_than}).encode()
    ).decode().rstrip("=")
    return f"{CURSOR_PREFIX}{encoded}"


def decode_cursor(cursor: str) -> tuple[str, int | None]:
    if not cursor.startswith(CURSOR_PREFIX):
        raise FreshRSSAdapterError("stored FreshRSS cursor has an unsupported version")
    try:
        raw = cursor.removeprefix(CURSOR_PREFIX)
        payload = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise FreshRSSAdapterError("stored FreshRSS cursor is invalid") from error
    if not isinstance(payload, dict) or set(payload) != {"continuation", "newer_than"}:
        raise FreshRSSAdapterError("stored FreshRSS cursor has an invalid shape")
    reject_credentials(payload)
    newer_than = payload.get("newer_than")
    if newer_than is not None:
        newer_than = positive_int(newer_than, "newer-than cursor", allow_zero=True)
    continuation = continuation_value(payload.get("continuation"))
    if continuation is None:
        raise FreshRSSAdapterError("stored FreshRSS cursor is invalid")
    return continuation, newer_than
