#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation primitives for the bounded Reddit read subprocess."""

from __future__ import annotations

import math
import re
from datetime import UTC, datetime
from typing import Any

MAX_TEXT_BYTES = 256 * 1024
FULLNAME = re.compile(r"^t[1-9]_[A-Za-z0-9]+$")
OPAQUE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$")


class RedditReadProviderError(RuntimeError):
    """Raised for a privacy-safe local Reddit read failure."""


def observed_at() -> str:
    """Return a stable UTC timestamp for one bounded provider response."""
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def exact_keys(request: dict[str, Any], expected: set[str]) -> None:
    """Reject request shapes outside the allowlisted action contract."""
    if set(request) != expected:
        raise RedditReadProviderError("Reddit read request has an invalid action shape")


def identity_value(identity: Any) -> dict[str, str]:
    """Serialize a selected Reddit identity without credential fields."""
    remote_id = getattr(identity, "id", None)
    username = getattr(identity, "name", None)
    if not isinstance(remote_id, str) or OPAQUE_ID.fullmatch(remote_id) is None:
        raise RedditReadProviderError("Reddit identity has no stable account ID")
    if not isinstance(username, str) or not username:
        raise RedditReadProviderError("Reddit identity has no account name")
    return {"id": remote_id, "username": username}


def optional_text(value: Any, field: str) -> str | None:
    """Validate a bounded optional text field from a provider object."""
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value:
        raise RedditReadProviderError(f"Reddit {field} must be text")
    if len(value.encode("utf-8")) > MAX_TEXT_BYTES:
        raise RedditReadProviderError(f"Reddit {field} exceeds the safety limit")
    return value


def attribute(value: Any, name: str) -> Any:
    """Read only already-loaded PRAW attributes without lazy network fetches."""
    try:
        attributes = object.__getattribute__(value, "__dict__")
    except (AttributeError, TypeError) as error:
        raise RedditReadProviderError("Reddit response attribute is unavailable") from error
    if not isinstance(attributes, dict):
        raise RedditReadProviderError("Reddit response attributes are invalid")
    return attributes.get(name)


def number(value: Any, field: str) -> int | float | None:
    """Validate a finite optional number."""
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise RedditReadProviderError(f"Reddit {field} must be numeric")
    if not math.isfinite(float(value)):
        raise RedditReadProviderError(f"Reddit {field} must be finite")
    return value


def integer(value: Any, field: str) -> int | None:
    """Validate an optional integer."""
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        raise RedditReadProviderError(f"Reddit {field} must be an integer")
    return value


def boolean(value: Any, field: str) -> bool | None:
    """Validate an optional boolean."""
    if value is None:
        return None
    if not isinstance(value, bool):
        raise RedditReadProviderError(f"Reddit {field} must be boolean")
    return value


def fullname(value: Any, prefix: str) -> str:
    """Resolve one stable already-loaded Reddit fullname."""
    for field in ("fullname", "name"):
        candidate = attribute(value, field)
        if isinstance(candidate, str) and FULLNAME.fullmatch(candidate):
            return candidate
    remote_id = attribute(value, "id")
    candidate = f"{prefix}_{remote_id}" if isinstance(remote_id, str) else ""
    if FULLNAME.fullmatch(candidate) is None:
        raise RedditReadProviderError("Reddit response has no stable fullname")
    return candidate


def optional_fullname(value: Any) -> str | None:
    """Validate an optional listing cursor fullname."""
    if value is not None and (
        not isinstance(value, str) or FULLNAME.fullmatch(value) is None
    ):
        raise RedditReadProviderError("Reddit read checkpoint is invalid")
    return value
