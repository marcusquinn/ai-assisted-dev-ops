#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Privacy-minimized normalization for beehiiv publication posts."""

from __future__ import annotations

import math
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_beehiiv import BeehiivProviderError, post_id
from knowledge_social_import import reject_credentials

MAX_TEXT_BYTES = 2 * 1024 * 1024


def _object(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise BeehiivProviderError(f"beehiiv {field} must be an object")
    return value


def validated_text(
    value: Any, field: str, *, optional: bool = False, limit: int = 64 * 1024
) -> str | None:
    if value is None and optional:
        return None
    if not isinstance(value, str):
        raise BeehiivProviderError(f"beehiiv {field} is invalid")
    if not value and not optional:
        raise BeehiivProviderError(f"beehiiv {field} is invalid")
    if "\x00" in value or len(value.encode()) > limit:
        raise BeehiivProviderError(f"beehiiv {field} is invalid")
    return value


def _epoch(value: Any, field: str, *, optional: bool = False) -> str | None:
    if value is None and optional:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise BeehiivProviderError(f"beehiiv {field} is invalid")
    if not math.isfinite(value) or value < 0:
        raise BeehiivProviderError(f"beehiiv {field} is invalid")
    try:
        return datetime.fromtimestamp(value, UTC).isoformat().replace("+00:00", "Z")
    except (OverflowError, OSError, ValueError) as error:
        raise BeehiivProviderError(f"beehiiv {field} is invalid") from error


def _string(value: Any, field: str) -> str:
    if not isinstance(value, str):
        raise BeehiivProviderError(f"beehiiv post {field} is invalid")
    if not value or "\x00" in value or len(value.encode()) > 4096:
        raise BeehiivProviderError(f"beehiiv post {field} is invalid")
    return value


def _strings(value: Any, field: str) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list) or len(value) > 100:
        raise BeehiivProviderError(f"beehiiv post {field} is invalid")
    return [_string(item, field) for item in value]


def _enum(value: Any, field: str, allowed: frozenset[str]) -> str:
    text = validated_text(value, f"post {field}")
    if text not in allowed:
        raise BeehiivProviderError(f"beehiiv post {field} is unsupported")
    return text


def _boolean(value: Any, field: str, *, default: bool = False) -> bool:
    if value is None:
        return default
    if not isinstance(value, bool):
        raise BeehiivProviderError(f"beehiiv post {field} is invalid")
    return value


def _free_web_content(item: dict[str, Any]) -> str | None:
    content_value = item.get("content")
    if content_value is None:
        return None
    content = _object(content_value, "post content")
    if content.get("premium") not in (None, {}):
        raise BeehiivProviderError("beehiiv premium post content is outside the read policy")
    free_value = content.get("free")
    if free_value is None:
        return None
    free = _object(free_value, "free post content")
    return validated_text(
        free.get("web"), "free web content", optional=True, limit=MAX_TEXT_BYTES
    )


def normalize_post(
    item: dict[str, Any], observed_epoch: float
) -> dict[str, Any] | None:
    """Validate and minimize one confirmed post without audience statistics."""
    reject_credentials(item)
    if item.get("stats") not in (None, {}):
        raise BeehiivProviderError("beehiiv post statistics are outside the privacy policy")
    status = _enum(item.get("status"), "status", frozenset({"confirmed"}))
    publish_value = item.get("publish_date")
    publish_date = _epoch(publish_value, "post publish date", optional=True)
    if publish_value is not None and float(publish_value) > observed_epoch:
        return None
    return {
        "kind": "post",
        "remote_id": post_id(item.get("id")),
        "title": validated_text(item.get("title"), "post title", optional=True),
        "subtitle": validated_text(item.get("subtitle"), "post subtitle", optional=True),
        "authors": _strings(item.get("authors"), "authors"),
        "created_at": _epoch(item.get("created"), "post creation time", optional=True),
        "status": status,
        "publish_date": publish_date,
        "displayed_date": _epoch(
            item.get("displayed_date"), "post displayed date", optional=True
        ),
        "subject_line": validated_text(
            item.get("subject_line"), "post subject line", optional=True
        ),
        "preview_text": validated_text(
            item.get("preview_text"), "post preview text", optional=True
        ),
        "slug": validated_text(item.get("slug"), "post slug", optional=True),
        "web_url": validated_text(item.get("web_url"), "post web URL", optional=True),
        "audience": _enum(
            item.get("audience"),
            "audience",
            frozenset({"free", "premium", "both"}),
        ),
        "platform": _enum(
            item.get("platform"),
            "platform",
            frozenset({"web", "email", "both"}),
        ),
        "content_tags": _strings(item.get("content_tags"), "content tags"),
        "meta_default_description": validated_text(
            item.get("meta_default_description"), "post meta description", optional=True
        ),
        "meta_default_title": validated_text(
            item.get("meta_default_title"), "post meta title", optional=True
        ),
        "hidden_from_feed": _boolean(item.get("hidden_from_feed"), "hidden state"),
        "enforce_gated_content": _boolean(
            item.get("enforce_gated_content"), "gated-content state"
        ),
        "free_web_content": _free_web_content(item),
    }
