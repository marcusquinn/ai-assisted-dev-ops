#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate Signal attachment metadata without reading provider payload paths."""

from __future__ import annotations

from typing import Any

from _knowledge_social_signal import (
    MAX_ATTACHMENT_BYTES,
    MAX_ATTACHMENTS_PER_MESSAGE,
    SignalCollectorError,
    _digest,
    _text,
)


def _attachment_size(size: Any) -> int | None:
    if size is None:
        return None
    if isinstance(size, bool) or not isinstance(size, int):
        raise SignalCollectorError("Signal attachment size is invalid or too large")
    if size < 0 or size > MAX_ATTACHMENT_BYTES:
        raise SignalCollectorError("Signal attachment size is invalid or too large")
    return size


def _attachment_row(
    attachment: Any, message_id: str, index: int
) -> dict[str, Any]:
    if not isinstance(attachment, dict):
        raise SignalCollectorError("Signal attachment must be an object")
    return {
        "remote_id": f"media_{_digest(message_id, attachment.get('id'), index)}",
        "object_remote_id": message_id,
        "content_sha256": None,
        "mime_type": _text(
            attachment.get("contentType"), "attachment content type"
        ),
        "byte_size": _attachment_size(attachment.get("size")),
        "blob_ref": None,
        "hydration_state": "metadata_only",
    }


def attachment_rows(
    attachments: Any, message_id: str, ephemeral: bool
) -> list[dict[str, Any]]:
    """Return bounded metadata rows, excluding all ephemeral attachment evidence."""
    if attachments is None or ephemeral:
        return []
    if not isinstance(attachments, list):
        raise SignalCollectorError("Signal attachments must be a bounded array")
    if len(attachments) > MAX_ATTACHMENTS_PER_MESSAGE:
        raise SignalCollectorError("Signal attachments must be a bounded array")
    return [
        _attachment_row(attachment, message_id, index)
        for index, attachment in enumerate(attachments)
    ]
