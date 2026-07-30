#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""NodeBB installation, account, and resource identity validation."""

from __future__ import annotations

import re
from typing import Any

from knowledge_social_store import SocialStoreError

INSTANCE_ID = re.compile(r"^[0-9a-f]{24}$")
PROVIDER_ACCOUNT_ID = re.compile(r"^[1-9][0-9]{0,19}$")
USERSLUG = re.compile(r"^[A-Za-z0-9_.~-]{1,128}$")
RESOURCE_KIND = re.compile(r"^[a-z][a-z_]{0,31}$")
RESOURCE_ID = re.compile(r"^[A-Za-z0-9_.~-]{1,160}$")


class NodeBBAdapterError(SocialStoreError):
    """Raised when guarded NodeBB collection cannot continue safely."""


class NodeBBProviderUnavailableError(NodeBBAdapterError):
    """Raised when the bounded NodeBB HTTP child cannot complete a read."""


def instance_id(value: Any) -> str:
    """Validate a privacy-safe stable installation fingerprint."""
    if not isinstance(value, str) or INSTANCE_ID.fullmatch(value) is None:
        raise NodeBBAdapterError("NodeBB installation identity is invalid")
    return value


def provider_account_id(value: Any) -> str:
    """Normalize a CLI-safe selector or installation-local numeric user ID."""
    text = str(value) if isinstance(value, int) and not isinstance(value, bool) else value
    if isinstance(text, str) and text.startswith("user_"):
        text = text.removeprefix("user_")
    if not isinstance(text, str) or PROVIDER_ACCOUNT_ID.fullmatch(text) is None:
        raise NodeBBAdapterError("NodeBB account ID is invalid")
    return text


def userslug(value: Any) -> str:
    """Validate a selected NodeBB userslug before path interpolation."""
    if not isinstance(value, str) or USERSLUG.fullmatch(value) is None:
        raise NodeBBAdapterError("NodeBB account userslug is invalid")
    return value


def namespaced_id(installation: str, kind: str, value: str) -> str:
    """Namespace an installation-local resource ID for shared storage."""
    stable_instance = instance_id(installation)
    if RESOURCE_KIND.fullmatch(kind) is None:
        raise NodeBBAdapterError("NodeBB resource kind is invalid")
    if not isinstance(value, str) or RESOURCE_ID.fullmatch(value) is None:
        raise NodeBBAdapterError("NodeBB resource ID is invalid")
    return f"nbb_{stable_instance}_{kind}_{value}"
