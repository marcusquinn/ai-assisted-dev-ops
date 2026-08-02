#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Durable Hashnode account and resource identity validation."""

from __future__ import annotations

import hashlib
import re
from typing import Any

from knowledge_social_store import SocialStoreError

INSTANCE_ID = "hashnode-gql-beta"
OPAQUE_ID = re.compile(r"^[A-Za-z0-9_-]{8,256}$")
USERNAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$")
RESOURCE_KIND = re.compile(r"^[a-z][a-z_]{0,31}$")


class HashnodeAdapterError(SocialStoreError):
    """Raised when guarded Hashnode collection cannot continue safely."""


class HashnodeProviderUnavailableError(HashnodeAdapterError):
    """Raised when the bounded Hashnode HTTP child cannot complete a read."""


def instance_id(value: Any) -> str:
    if value != INSTANCE_ID:
        raise HashnodeAdapterError("Hashnode API identity is invalid")
    return INSTANCE_ID


def provider_account_id(value: Any) -> str:
    if isinstance(value, str) and value.startswith("account_"):
        value = value.removeprefix("account_")
    if not isinstance(value, str) or OPAQUE_ID.fullmatch(value) is None:
        raise HashnodeAdapterError("Hashnode account ID is invalid")
    return value


def username(value: Any) -> str:
    if not isinstance(value, str) or USERNAME.fullmatch(value) is None:
        raise HashnodeAdapterError("Hashnode username is invalid")
    return value


def opaque_id(value: Any, field: str) -> str:
    if not isinstance(value, str) or OPAQUE_ID.fullmatch(value) is None:
        raise HashnodeAdapterError(f"Hashnode {field} is invalid")
    return value


def namespaced_id(kind: str, value: Any) -> str:
    if RESOURCE_KIND.fullmatch(kind) is None:
        raise HashnodeAdapterError("Hashnode resource kind is invalid")
    if not isinstance(value, str) or not value or "\x00" in value:
        raise HashnodeAdapterError("Hashnode resource identity is invalid")
    if len(value.encode()) > 1024:
        raise HashnodeAdapterError("Hashnode resource identity is invalid")
    digest = hashlib.sha256(value.encode()).hexdigest()[:32]
    return f"hn_{kind}_{digest}"


def account_id(value: Any) -> str:
    remote = provider_account_id(value)
    return f"hnu_{hashlib.sha256(remote.encode()).hexdigest()[:32]}"
