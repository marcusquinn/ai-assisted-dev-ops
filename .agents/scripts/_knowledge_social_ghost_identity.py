#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Ghost installation, publication, and resource identity validation."""

from __future__ import annotations

import re
from typing import Any

from knowledge_social_store import SocialStoreError

INSTANCE_ID = re.compile(r"^[0-9a-f]{24}$")
SITE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$")
RESOURCE_KIND = re.compile(r"^[a-z][a-z_]{0,31}$")
RESOURCE_ID = re.compile(r"^[A-Za-z0-9_.~-]{1,200}$")


class GhostAdapterError(SocialStoreError):
    """Raised when guarded Ghost collection cannot continue safely."""


class GhostProviderUnavailableError(GhostAdapterError):
    """Raised when the bounded Ghost HTTP child cannot complete a read."""


def _validated_text(value: Any, pattern: re.Pattern[str], message: str) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise GhostAdapterError(message)
    return value


def instance_id(value: Any) -> str:
    """Validate a privacy-safe stable Ghost installation fingerprint."""
    return _validated_text(value, INSTANCE_ID, "Ghost installation identity is invalid")


def provider_account_id(value: Any) -> str:
    """Validate one operator-selected opaque publication identity."""
    return _validated_text(value, SITE_ID, "Ghost publication ID is invalid")


def namespaced_id(installation: str, kind: str, value: str) -> str:
    """Namespace installation-local Ghost resource IDs for shared storage."""
    stable_installation = instance_id(installation)
    if RESOURCE_KIND.fullmatch(kind) is None:
        raise GhostAdapterError("Ghost resource kind is invalid")
    stable_value = _validated_text(value, RESOURCE_ID, "Ghost resource ID is invalid")
    return f"gst_{stable_installation}_{kind}_{stable_value}"
