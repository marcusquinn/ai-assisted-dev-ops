#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Mastodon instance, account, and resource identity validation."""

from __future__ import annotations

import hashlib
import re
from typing import Any

from knowledge_social_store import SocialStoreError

INSTANCE_ID = re.compile(r"^[0-9a-f]{24}$")
RESOURCE_KIND = re.compile(r"^[a-z][a-z_]{0,31}$")


class MastodonAdapterError(SocialStoreError):
    """Raised when guarded Mastodon collection cannot continue safely."""


class MastodonProviderUnavailableError(MastodonAdapterError):
    """Raised when the bounded Mastodon HTTP child cannot complete a read."""


def _opaque_id(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise MastodonAdapterError(f"Mastodon {field} is invalid")
    if len(value.encode("utf-8")) > 512:
        raise MastodonAdapterError(f"Mastodon {field} is invalid")
    return value


def instance_id(value: Any) -> str:
    """Validate a privacy-safe stable home-instance fingerprint."""
    if not isinstance(value, str) or INSTANCE_ID.fullmatch(value) is None:
        raise MastodonAdapterError("Mastodon instance identity is invalid")
    return value


def provider_account_id(value: Any) -> str:
    """Validate an opaque home-instance account ID."""
    if isinstance(value, str) and value.startswith("account_"):
        value = value.removeprefix("account_")
    return _opaque_id(value, "account ID")


def account_handle(value: Any) -> str:
    """Validate an allowlisted account handle without interpreting federation."""
    return _opaque_id(value, "account handle")


def namespaced_id(installation: str, kind: str, value: str) -> str:
    """Namespace one opaque installation-local ID without embedding its value."""
    stable_instance = instance_id(installation)
    if RESOURCE_KIND.fullmatch(kind) is None:
        raise MastodonAdapterError("Mastodon resource kind is invalid")
    opaque = _opaque_id(value, "resource ID")
    digest = hashlib.sha256(opaque.encode("utf-8")).hexdigest()[:32]
    return f"mst_{stable_instance}_{kind}_{digest}"
