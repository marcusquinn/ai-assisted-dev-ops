#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Stable identity primitives for authorized Notion workspace reads."""

from __future__ import annotations

import uuid
from typing import Any


class NotionAdapterError(ValueError):
    """Raised when Notion evidence violates the local collection contract."""


class NotionProviderUnavailableError(RuntimeError):
    """Raised when the guarded Notion reader cannot execute safely."""


def notion_id(value: Any, field: str) -> str:
    """Return one canonical UUID without accepting URLs or arbitrary selectors."""
    if not isinstance(value, str) or not value or "\x00" in value:
        raise NotionAdapterError(f"Notion {field} must be a UUID")
    try:
        parsed = uuid.UUID(value)
    except (AttributeError, ValueError) as error:
        raise NotionAdapterError(f"Notion {field} must be a UUID") from error
    return str(parsed)


def root_page_ids(value: Any) -> tuple[str, ...]:
    """Validate a small explicit root allowlist and reject duplicate aliases."""
    if not isinstance(value, (list, tuple)) or not 1 <= len(value) <= 20:
        raise NotionAdapterError("Notion requires between 1 and 20 root page IDs")
    roots = tuple(notion_id(item, "root page ID") for item in value)
    if len(roots) != len(set(roots)):
        raise NotionAdapterError("Notion root page IDs must be unique")
    return roots


def bounded_integer(
    value: Any, field: str, minimum: int, maximum: int
) -> int:
    """Validate one explicit traversal budget."""
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or value < minimum
        or value > maximum
    ):
        raise NotionAdapterError(
            f"Notion {field} must be between {minimum} and {maximum}"
        )
    return value
