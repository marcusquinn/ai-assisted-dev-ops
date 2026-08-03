#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Public Hacker News selector and item identity validation."""

from __future__ import annotations

import hashlib
from typing import Any

from knowledge_social_store import SocialStoreError


class HackerNewsAdapterError(SocialStoreError):
    """Raised when public Hacker News collection cannot continue safely."""


class HackerNewsProviderUnavailableError(HackerNewsAdapterError):
    """Raised when the bounded Hacker News HTTP child cannot complete a read."""


def username(value: Any) -> str:
    """Validate one case-sensitive public username without normalizing it."""
    if not isinstance(value, str) or not value or "\x00" in value:
        raise HackerNewsAdapterError("Hacker News public username is invalid")
    if len(value.encode("utf-8")) > 256 or any(ord(character) < 32 for character in value):
        raise HackerNewsAdapterError("Hacker News public username is invalid")
    return value


def selector_id(value: Any) -> str:
    """Namespace a mutable public username without claiming account identity."""
    selected = username(value)
    digest = hashlib.sha256(selected.encode("utf-8")).hexdigest()[:32]
    return f"hnu_{digest}"


def item_id(value: Any) -> int:
    """Validate one official positive integer item ID."""
    if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value < 2**63:
        raise HackerNewsAdapterError("Hacker News item ID is invalid")
    return value
