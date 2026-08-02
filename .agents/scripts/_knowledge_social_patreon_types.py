#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared Patreon identifiers, limits, and adapter errors."""

from __future__ import annotations

import re
from typing import Any

PROVIDER = "patreon"
CURSOR_PREFIX = "patreon-v2:"
RETENTION_LIMIT = "current_api_visibility_and_creator_privacy_purpose"
OPAQUE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,159}$")
CAMPAIGN_ID = re.compile(r"^[1-9][0-9]{0,31}$")
MAX_CURSOR_BYTES = 4096
MAX_CURSOR_HISTORY = 256


class PatreonAdapterError(RuntimeError):
    """Raised when Patreon evidence violates the local collector contract."""


class PatreonProviderUnavailableError(PatreonAdapterError):
    """Raised when the isolated Patreon reader cannot run safely."""


def provider_id(value: Any, field: str = "ID") -> str:
    """Validate one opaque Patreon identifier without exposing it in errors."""
    if not isinstance(value, str) or OPAQUE_ID.fullmatch(value) is None:
        raise PatreonAdapterError(f"Patreon {field} is invalid")
    return value


def campaign_id(value: Any, field: str = "campaign ID") -> str:
    """Validate one documented numeric Patreon campaign identifier."""
    if not isinstance(value, str) or CAMPAIGN_ID.fullmatch(value) is None:
        raise PatreonAdapterError(f"Patreon {field} is invalid")
    return value


def selected_campaign_ids(value: Any) -> tuple[str, ...]:
    """Validate the explicit creator-owned campaign allowlist."""
    if not isinstance(value, (list, tuple)) or not 1 <= len(value) <= 20:
        raise PatreonAdapterError("Patreon selected campaigns must contain 1-20 IDs")
    selected = tuple(campaign_id(item, "selected campaign ID") for item in value)
    if len(selected) != len(set(selected)):
        raise PatreonAdapterError("Patreon selected campaigns contain duplicates")
    return tuple(sorted(selected, key=int))
