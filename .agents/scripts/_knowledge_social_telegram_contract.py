#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Typed, privacy-safe contract for Telegram export and event evidence."""

from __future__ import annotations

import json
import os
import stat
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from knowledge_social_import import reject_credentials
from knowledge_social_store import SocialStoreError, validate_opaque

PROVIDER = "telegram"
EXPORT_SCHEMA = "telegram-desktop-json-v1"
UPDATE_SCHEMA = "telegram-bot-api-update-fanout-v1"
RETENTION_LIMIT = "operator_authorized_private_evidence"


@dataclass(frozen=True)
class TelegramRequest:
    path: Path
    connection_id: str
    expected_identity: str
    allowed_chats: frozenset[str]
    observed_at: str
    max_bytes: int
    max_items: int
    max_media_bytes: int
    expected_owner: str | None = None


@dataclass(frozen=True)
class TelegramMediaPayload:
    remote_id: str
    object_remote_id: str
    mime_type: str | None
    payload: bytes


@dataclass(frozen=True)
class ParsedTelegramBatch:
    archive: dict[str, Any]
    raw_payload: bytes
    raw_sha256: str
    stream: str
    next_offset: int | None
    update_ids: tuple[int, ...]
    media_payloads: tuple[TelegramMediaPayload, ...]
    normalized_items: int


@dataclass(frozen=True)
class CoverageDetail:
    reason: str | None = None
    exhausted: bool = False


def canonical_json(value: Any) -> str:
    """Serialize selected provider data deterministically."""
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def read_bounded_path(path: Path, max_bytes: int, field: str) -> bytes:
    """Read one regular file descriptor with no symlink or size-check race."""
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise SocialStoreError(f"Telegram {field} must be a regular non-symlink file") from error
    try:
        details = os.fstat(descriptor)
        if not stat.S_ISREG(details.st_mode):
            raise SocialStoreError(f"Telegram {field} must be a regular non-symlink file")
        chunks: list[bytes] = []
        remaining = max_bytes + 1
        while remaining > 0:
            chunk = os.read(descriptor, min(1024 * 1024, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        payload = b"".join(chunks)
        if len(payload) > max_bytes or os.read(descriptor, 1):
            raise SocialStoreError(f"Telegram {field} exceeds the byte budget")
        return payload
    finally:
        os.close(descriptor)


def require_object(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise SocialStoreError(f"Telegram {field} must be an object")
    return value


def require_list(value: Any, field: str) -> list[Any]:
    if not isinstance(value, list):
        raise SocialStoreError(f"Telegram {field} must be an array")
    return value


def stable_id(value: Any, field: str) -> str:
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise SocialStoreError(f"Telegram {field} must be a stable identifier")
    result = str(value).strip()
    if not result or len(result) > 191:
        raise SocialStoreError(f"Telegram {field} must be a stable identifier")
    return result


def canonical_user_id(value: Any, field: str = "user ID") -> str:
    result = stable_id(value, field)
    return result if result.startswith(("user", "bot", "channel")) else f"user{result}"


def normalized_time(value: Any, unix_value: Any, field: str) -> str:
    """Return a timezone-explicit timestamp without inventing a local timezone."""
    if unix_value not in (None, ""):
        try:
            epoch = int(unix_value)
        except (TypeError, ValueError) as error:
            raise SocialStoreError(f"Telegram {field} Unix time is invalid") from error
        if epoch < 0:
            raise SocialStoreError(f"Telegram {field} Unix time is invalid")
        return datetime.fromtimestamp(epoch, UTC).isoformat().replace("+00:00", "Z")
    if not isinstance(value, str) or not value.strip():
        raise SocialStoreError(f"Telegram {field} is missing")
    candidate = value.strip().replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(candidate)
    except ValueError as error:
        raise SocialStoreError(f"Telegram {field} is invalid") from error
    if parsed.tzinfo is None:
        raise SocialStoreError(
            f"Telegram {field} has no timezone or validated Unix timestamp"
        )
    return parsed.astimezone(UTC).isoformat().replace("+00:00", "Z")


def message_text(value: Any) -> str | None:
    """Flatten Telegram Desktop's string-or-rich-segment text representation."""
    if value is None:
        return None
    if isinstance(value, str):
        return value
    if not isinstance(value, list):
        raise SocialStoreError("Telegram message text has an unsupported shape")
    pieces: list[str] = []
    for segment in value:
        if isinstance(segment, str):
            pieces.append(segment)
        elif isinstance(segment, dict) and isinstance(segment.get("text"), str):
            pieces.append(segment["text"])
        else:
            raise SocialStoreError("Telegram rich text segment is invalid")
    return "".join(pieces)


def coverage_record(
    stream: str,
    status: str,
    observed_at: str,
    detail: CoverageDetail | None = None,
) -> dict[str, Any]:
    selected = detail or CoverageDetail()
    return {
        "stream": stream,
        "earliest_at": None,
        "latest_at": None,
        "cursor_exhausted": selected.exhausted,
        "retention_limit": RETENTION_LIMIT,
        "unavailable_reason": selected.reason,
        "status": status,
        "observed_at": observed_at,
    }


def finalize_archive(archive: dict[str, Any], max_items: int) -> int:
    """Reject credential-shaped projections and enforce a global item budget."""
    reject_credentials(archive)
    count = sum(
        len(archive.get(key, []))
        for key in ("accounts", "objects", "activities", "media")
    )
    if count > max_items:
        raise SocialStoreError("Telegram evidence exceeds the item budget")
    validate_opaque(str(archive["connection_id"]), "connection_id")
    return count
