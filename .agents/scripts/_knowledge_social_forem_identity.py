#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Forem installation, account, handle, and resource identity validation."""

from __future__ import annotations

import re
from typing import Any

from knowledge_social_store import SocialStoreError

INSTANCE_ID = re.compile(r"^[0-9a-f]{24}$")
PROVIDER_ACCOUNT_ID = re.compile(r"^[1-9][0-9]{0,19}$")
USERNAME = re.compile(r"^[A-Za-z0-9_-]{1,128}$")
RESOURCE_KIND = re.compile(r"^[a-z][a-z_]{0,31}$")
RESOURCE_ID = re.compile(r"^[A-Za-z0-9_.~-]{1,160}$")


class ForemAdapterError(SocialStoreError):
    """Raised when guarded Forem collection cannot continue safely."""


class ForemProviderUnavailableError(ForemAdapterError):
    """Raised when the bounded Forem HTTP child cannot complete a read."""


def instance_id(value: Any) -> str:
    """Validate a privacy-safe stable installation fingerprint."""
    if not isinstance(value, str) or INSTANCE_ID.fullmatch(value) is None:
        raise ForemAdapterError("Forem installation identity is invalid")
    return value


def provider_account_id(value: Any) -> str:
    """Normalize a CLI-safe selector or installation-local numeric user ID."""
    text = str(value) if isinstance(value, int) and not isinstance(value, bool) else value
    if isinstance(text, str) and text.startswith("user_"):
        text = text.removeprefix("user_")
    if not isinstance(text, str) or PROVIDER_ACCOUNT_ID.fullmatch(text) is None:
        raise ForemAdapterError("Forem account ID is invalid")
    return text


def username(value: Any) -> str:
    """Validate the selected Forem username returned by authenticated identity."""
    if not isinstance(value, str) or USERNAME.fullmatch(value) is None:
        raise ForemAdapterError("Forem account username is invalid")
    return value


def namespaced_id(installation: str, kind: str, value: str) -> str:
    """Namespace an installation-local resource ID for shared storage."""
    stable_instance = instance_id(installation)
    if RESOURCE_KIND.fullmatch(kind) is None:
        raise ForemAdapterError("Forem resource kind is invalid")
    if not isinstance(value, str) or RESOURCE_ID.fullmatch(value) is None:
        raise ForemAdapterError("Forem resource ID is invalid")
    return f"frm_{stable_instance}_{kind}_{value}"
