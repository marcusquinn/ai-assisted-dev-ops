#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Descriptor-bound media reads for Telegram Desktop exports."""

from __future__ import annotations

import hashlib
import json
import mimetypes
import os
import stat
from errno import ENOENT
from pathlib import Path
from typing import Any

from _knowledge_social_telegram_contract import (
    TelegramMediaPayload,
    require_object,
)
from knowledge_social_import import reject_credentials
from knowledge_social_store import SocialStoreError


def _read_descriptor(descriptor: int, max_bytes: int, field: str) -> bytes:
    if not stat.S_ISREG(os.fstat(descriptor).st_mode):
        raise SocialStoreError(f"Telegram {field} must be a regular file")
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


def read_export(path: Path, max_bytes: int) -> tuple[dict[str, Any], bytes, int]:
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    try:
        directory = os.open(path.parent, directory_flags | nofollow)
    except OSError as error:
        raise SocialStoreError("Telegram export directory is unsafe") from error
    try:
        descriptor = os.open(path.name, os.O_RDONLY | nofollow, dir_fd=directory)
        try:
            payload = _read_descriptor(descriptor, max_bytes, "export")
        finally:
            os.close(descriptor)
        root = _decode_export(payload)
        return root, payload, directory
    except Exception:
        os.close(directory)
        raise


def _decode_export(payload: bytes) -> dict[str, Any]:
    try:
        parsed = json.loads(payload.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise SocialStoreError("Telegram export is not valid UTF-8 JSON") from error
    root = require_object(parsed, "export root")
    reject_credentials(root)
    about = root.get("about")
    if not isinstance(about, str) or "Telegram Desktop" not in about:
        raise SocialStoreError("Telegram export provenance marker is missing")
    return root


def _relative_media_path(value: Any) -> Path | None:
    if not isinstance(value, str) or not value or value.startswith("("):
        return None
    relative = Path(value)
    if relative.is_absolute() or ".." in relative.parts or not relative.parts:
        raise SocialStoreError("Telegram export media path escapes the export directory")
    return relative


def _open_media_descriptor(export_directory: int, relative: Path) -> tuple[int, list[int]]:
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    descriptors = [os.dup(export_directory)]
    current = descriptors[0]
    for component in relative.parts[:-1]:
        current = os.open(component, directory_flags | nofollow, dir_fd=current)
        descriptors.append(current)
    descriptor = os.open(relative.parts[-1], os.O_RDONLY | nofollow, dir_fd=current)
    descriptors.append(descriptor)
    return descriptor, descriptors


def _read_relative_media(
    export_directory: int, value: Any, max_bytes: int
) -> tuple[bytes, str] | None:
    relative = _relative_media_path(value)
    if relative is None:
        return None
    descriptors: list[int] = []
    try:
        descriptor, descriptors = _open_media_descriptor(export_directory, relative)
        return _read_descriptor(descriptor, max_bytes, "export media"), relative.name
    except OSError as error:
        if error.errno == ENOENT:
            return None
        raise SocialStoreError("Telegram export media path is unsafe") from error
    finally:
        for descriptor in reversed(descriptors):
            os.close(descriptor)


def _media_record(
    message: dict[str, Any], object_id: str, payload: bytes, filename: str
) -> tuple[dict[str, Any], TelegramMediaPayload]:
    digest = hashlib.sha256(payload).hexdigest()
    remote_id = f"attachment:{object_id}:sha256:{digest}"
    mime_type = message.get("mime_type")
    if not isinstance(mime_type, str):
        mime_type = mimetypes.guess_type(filename)[0]
    record = {
        "remote_id": remote_id,
        "object_remote_id": object_id,
        "content_sha256": digest,
        "mime_type": mime_type,
        "byte_size": len(payload),
        "blob_ref": None,
        "hydration_state": "staged",
    }
    return record, TelegramMediaPayload(remote_id, object_id, mime_type, payload)


def message_media(
    export_directory: int,
    message: dict[str, Any],
    object_id: str,
    used_bytes: int,
    max_media_bytes: int,
) -> tuple[list[dict[str, Any]], list[TelegramMediaPayload], int, bool]:
    records: list[dict[str, Any]] = []
    payloads: list[TelegramMediaPayload] = []
    missing = False
    for raw_path in (message.get("file"), message.get("photo")):
        if raw_path is None:
            continue
        result = _read_relative_media(export_directory, raw_path, max_media_bytes - used_bytes)
        if result is None:
            missing = True
            continue
        payload, filename = result
        used_bytes += len(payload)
        record, media_payload = _media_record(message, object_id, payload, filename)
        records.append(record)
        payloads.append(media_payload)
    return records, payloads, used_bytes, missing
