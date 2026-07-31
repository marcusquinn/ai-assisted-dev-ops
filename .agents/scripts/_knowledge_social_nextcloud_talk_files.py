#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate already-authorized message-linked Nextcloud Talk attachment bytes."""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass

from _knowledge_social_nextcloud_talk import NextcloudTalkAdapterError

DIGEST = re.compile(r"^[0-9a-f]{64}$")


@dataclass(frozen=True)
class VerifiedAttachment:
    content_sha256: str
    byte_size: int
    mime_type: str


def validate_attachment_bytes(
    content: bytes,
    *,
    expected_sha256: str,
    expected_size: int,
    mime_type: str,
    max_bytes: int,
    allowed_mime_types: frozenset[str],
) -> VerifiedAttachment:
    """Fail closed before bytes can be handed to canonical blob persistence."""
    if not isinstance(content, bytes) or len(content) > max_bytes or max_bytes < 1:
        raise NextcloudTalkAdapterError("Nextcloud Talk attachment exceeds the byte budget")
    if isinstance(expected_size, bool) or expected_size < 0 or len(content) != expected_size:
        raise NextcloudTalkAdapterError("Nextcloud Talk attachment size identity changed")
    if mime_type not in allowed_mime_types or "\x00" in mime_type:
        raise NextcloudTalkAdapterError("Nextcloud Talk attachment MIME type is denied")
    digest = hashlib.sha256(content).hexdigest()
    if DIGEST.fullmatch(expected_sha256) is None or not hmac_compare(digest, expected_sha256):
        raise NextcloudTalkAdapterError("Nextcloud Talk attachment digest identity changed")
    return VerifiedAttachment(digest, len(content), mime_type)


def hmac_compare(actual: str, expected: str) -> bool:
    """Compare public content digests without data-dependent early exit."""
    if len(actual) != len(expected):
        return False
    difference = 0
    for actual_byte, expected_byte in zip(actual.encode(), expected.encode(), strict=True):
        difference |= actual_byte ^ expected_byte
    return difference == 0
