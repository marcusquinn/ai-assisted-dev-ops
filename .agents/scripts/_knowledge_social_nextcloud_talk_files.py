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


@dataclass(frozen=True)
class AttachmentPolicy:
    expected_sha256: str
    expected_size: int
    mime_type: str
    max_bytes: int
    allowed_mime_types: frozenset[str]


def validate_attachment_bytes(
    content: bytes,
    policy: AttachmentPolicy,
) -> VerifiedAttachment:
    """Fail closed before bytes can be handed to canonical blob persistence."""
    byte_budget_valid = (
        isinstance(content, bytes),
        policy.max_bytes >= 1,
        isinstance(content, bytes) and len(content) <= policy.max_bytes,
    )
    if not all(byte_budget_valid):
        raise NextcloudTalkAdapterError("Nextcloud Talk attachment exceeds the byte budget")
    size_valid = (
        isinstance(policy.expected_size, int),
        not isinstance(policy.expected_size, bool),
        isinstance(policy.expected_size, int) and policy.expected_size >= 0,
        len(content) == policy.expected_size,
    )
    if not all(size_valid):
        raise NextcloudTalkAdapterError("Nextcloud Talk attachment size identity changed")
    if policy.mime_type not in policy.allowed_mime_types or "\x00" in policy.mime_type:
        raise NextcloudTalkAdapterError("Nextcloud Talk attachment MIME type is denied")
    digest = hashlib.sha256(content).hexdigest()
    if DIGEST.fullmatch(policy.expected_sha256) is None or not hmac_compare(
        digest, policy.expected_sha256
    ):
        raise NextcloudTalkAdapterError("Nextcloud Talk attachment digest identity changed")
    return VerifiedAttachment(digest, len(content), policy.mime_type)


def hmac_compare(actual: str, expected: str) -> bool:
    """Compare public content digests without data-dependent early exit."""
    if len(actual) != len(expected):
        return False
    difference = 0
    for actual_byte, expected_byte in zip(actual.encode(), expected.encode(), strict=True):
        difference |= actual_byte ^ expected_byte
    return difference == 0
