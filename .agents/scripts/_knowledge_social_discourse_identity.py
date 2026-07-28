#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Discourse installation, account, and resource identity validation."""

from __future__ import annotations

import re
from typing import Any

from knowledge_social_store import SocialStoreError

INSTANCE_ID = re.compile(r"^[0-9a-f]{24}$")
PROVIDER_ACCOUNT_ID = re.compile(r"^[1-9][0-9]{0,19}$")
USERNAME = re.compile(r"^[A-Za-z0-9_.-]{1,100}$")
RESOURCE_KIND = re.compile(r"^[a-z][a-z_]{0,31}$")
RESOURCE_ID = re.compile(r"^[A-Za-z0-9_-]{1,128}$")


class DiscourseAdapterError(SocialStoreError):
    """Raised when guarded Discourse collection cannot continue safely."""


class DiscourseProviderUnavailableError(DiscourseAdapterError):
    """Raised when the bounded Discourse HTTP child cannot complete a read."""


def instance_id(value: Any) -> str:
    """Validate a privacy-safe stable installation fingerprint."""
    if not isinstance(value, str):
        raise DiscourseAdapterError("Discourse installation identity is invalid")
    if INSTANCE_ID.fullmatch(value) is None:
        raise DiscourseAdapterError("Discourse installation identity is invalid")
    return value


def provider_account_id(value: Any) -> str:
    """Normalize a CLI-safe selector or installation-local numeric user ID."""
    text = str(value) if isinstance(value, int) and not isinstance(value, bool) else value
    if isinstance(text, str) and text.startswith("user_"):
        text = text.removeprefix("user_")
    if not isinstance(text, str):
        raise DiscourseAdapterError("Discourse account ID is invalid")
    if PROVIDER_ACCOUNT_ID.fullmatch(text) is None:
        raise DiscourseAdapterError("Discourse account ID is invalid")
    return text


def username(value: Any) -> str:
    """Validate a selected Discourse username before path interpolation."""
    if not isinstance(value, str):
        raise DiscourseAdapterError("Discourse account username is invalid")
    if USERNAME.fullmatch(value) is None:
        raise DiscourseAdapterError("Discourse account username is invalid")
    return value


def namespaced_id(installation: str, kind: str, value: str) -> str:
    """Namespace an installation-local resource ID for shared storage."""
    stable_instance = instance_id(installation)
    if RESOURCE_KIND.fullmatch(kind) is None:
        raise DiscourseAdapterError("Discourse resource kind is invalid")
    if not isinstance(value, str):
        raise DiscourseAdapterError("Discourse resource ID is invalid")
    if not value or RESOURCE_ID.fullmatch(value) is None:
        raise DiscourseAdapterError("Discourse resource ID is invalid")
    return f"dsc_{stable_instance}_{kind}_{value}"
