#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared validation primitives for campaign research dossiers."""

from __future__ import annotations

import datetime as dt
import json
import re
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
MAX_SOURCES = 20
MAX_OBSERVATIONS = 200
MAX_AGE_DAYS = 30
SOURCE_TYPES = {"manual", "export", "knowledge_query", "public_search", "seo"}
AUTHORIZATION_MODES = {"manual", "authorized_export", "authorized_collector", "public_lawful"}
SOURCE_STATUSES = {"complete", "partial", "gated", "absent", "stale", "rate_limited", "failed"}
SENSITIVITIES = {"public", "internal", "sensitive"}
CONFIDENCES = {"low", "medium", "high"}
KINDS = {"audience", "competitor", "creator", "trend", "channel_fit", "opportunity", "contradiction"}
PRIVATE_IDENTIFIER = re.compile(r"(?i)(?:api[_ -]?key|password|token|secret|email|phone)\s*[:=]|\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b|\+?[0-9][0-9 .()/-]{7,}[0-9]")
INSTRUCTION_LIKE_CONTENT = re.compile(r"(?i)\b(?:ignore|disregard)\b.{0,80}\b(?:instruction|prompt|rule)s?\b")


class DossierError(ValueError):
    """Raised when campaign research input violates the bounded contract."""


def canonical_bytes(value: Any) -> bytes:
    """Return deterministic JSON bytes for snapshot hashing."""
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")


def required_text(value: Any, field: str, maximum: int = 2000) -> str:
    """Validate a safe single-line text field."""
    if not isinstance(value, str) or not value.strip() or len(value.strip()) > maximum:
        raise DossierError(f"{field} must be non-empty text up to {maximum} characters")
    text = value.strip()
    if any(ord(character) < 32 for character in text):
        raise DossierError(f"{field} must be single-line text")
    return text


def parse_time(value: Any, field: str) -> tuple[str, dt.datetime]:
    """Normalize a timezone-aware ISO timestamp."""
    text = required_text(value, field, 64)
    try:
        parsed = dt.datetime.fromisoformat(text[:-1] + "+00:00" if text.endswith("Z") else text)
    except ValueError as error:
        raise DossierError(f"{field} must be ISO-8601") from error
    if parsed.tzinfo is None:
        raise DossierError(f"{field} requires a timezone")
    normalized = parsed.astimezone(dt.timezone.utc).replace(microsecond=0)
    return normalized.isoformat().replace("+00:00", "Z"), normalized


def relative_reference(value: Any) -> str:
    """Reject absolute and traversal references without dereferencing artifacts."""
    reference = required_text(value, "reference", 1024)
    if reference.startswith(("/", "~")) or ".." in Path(reference).parts:
        raise DossierError("reference must be a relative non-traversing reference")
    return reference


def source_freshness(captured_at: dt.datetime, status: str, now: dt.datetime) -> str:
    """Compute truthful freshness without advancing failed evidence."""
    if status == "stale" or now - captured_at > dt.timedelta(days=MAX_AGE_DAYS):
        return "stale"
    return "fresh"
