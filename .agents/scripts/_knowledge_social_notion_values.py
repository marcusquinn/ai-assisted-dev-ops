#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded scalar, object, list, and rendered-text validation for Notion."""

from __future__ import annotations

import re
from typing import Any

MAX_TEXT_BYTES = 512 * 1024
CREDENTIAL_VALUE = re.compile(
    r"(?i)(?:^|[?&;\s])(?:access[_-]?token|api[_-]?key|authorization|"
    r"client[_-]?secret|password|secret|session[_-]?token)\s*[=:]\s*[^\s&;]{4,}"
)
JWT_VALUE = re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")


class NotionReadProviderError(RuntimeError):
    """Raised for a privacy-safe local Notion provider failure."""


def object_value(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise NotionReadProviderError(f"Notion {field} must be an object")
    return value


def list_value(value: Any, field: str, limit: int) -> list[dict[str, Any]]:
    if (
        not isinstance(value, list)
        or len(value) > limit
        or any(not isinstance(item, dict) for item in value)
    ):
        raise NotionReadProviderError(f"Notion {field} must be a bounded object array")
    return value


def optional_text(value: Any, field: str, *, maximum: int = MAX_TEXT_BYTES) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value:
        raise NotionReadProviderError(f"Notion {field} must be text")
    if len(value.encode("utf-8")) > maximum:
        raise NotionReadProviderError(f"Notion {field} exceeds the text safety limit")
    if CREDENTIAL_VALUE.search(value) or JWT_VALUE.search(value):
        raise NotionReadProviderError("Notion response contains credential-shaped text")
    return value


def _walk_text(value: Any, output: list[str]) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "plain_text":
                text = optional_text(child, "rich text")
                if text:
                    output.append(text)
            elif key not in {"url", "href", "public_url"}:
                _walk_text(child, output)
    elif isinstance(value, list):
        for child in value:
            _walk_text(child, output)


def plain_text(value: Any) -> str | None:
    """Extract only provider-rendered plain text, never links or HTML."""
    pieces: list[str] = []
    _walk_text(value, pieces)
    rendered = "\n".join(piece for piece in pieces if piece).strip()
    if not rendered:
        return None
    if len(rendered.encode("utf-8")) > MAX_TEXT_BYTES:
        raise NotionReadProviderError("Notion rendered text exceeds the safety limit")
    return rendered
