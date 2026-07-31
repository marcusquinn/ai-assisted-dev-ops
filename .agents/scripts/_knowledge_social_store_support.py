#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared contracts for private social store modules."""

from __future__ import annotations

import re


class SocialStoreError(RuntimeError):
    """Raised when private social storage cannot be used safely."""


OPAQUE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$")
SHA256_HEX = re.compile(r"^[0-9a-f]{64}$")
MAX_RAW_BATCH_BYTES = 64 * 1024 * 1024
COLLECTOR_ENVELOPE_FIELDS = frozenset(
    {
        "provider",
        "connection_id",
        "stream",
        "observed_at",
        "request_hash",
        "response_sha256",
        "response",
    }
)
INVALID_RAW_PATH = "legacy social raw evidence path is invalid"
INVALID_RAW_METADATA = "legacy social raw evidence metadata is invalid"
