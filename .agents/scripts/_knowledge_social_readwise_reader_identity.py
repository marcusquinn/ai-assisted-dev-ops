#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Deployment-owned Readwise Reader account and token binding."""

from __future__ import annotations

import hashlib
import hmac
import re
from typing import Any

from knowledge_social_store import SocialStoreError

ACCOUNT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
BINDING = re.compile(r"^[0-9a-f]{64}$")


class ReadwiseReaderAdapterError(SocialStoreError):
    """Raised when guarded Reader collection cannot continue safely."""


class ReadwiseReaderProviderUnavailableError(ReadwiseReaderAdapterError):
    """Raised when the bounded Reader HTTP child cannot complete a read."""


def binding_account_id(value: Any) -> str:
    if not isinstance(value, str) or ACCOUNT.fullmatch(value) is None:
        raise ReadwiseReaderAdapterError("Readwise Reader account binding ID is invalid")
    return value


def token_binding(token: Any, account: Any, key: Any) -> str:
    selected = binding_account_id(account)
    if not isinstance(token, str) or not token or "\x00" in token:
        raise ReadwiseReaderAdapterError("Readwise Reader access token is invalid")
    if not isinstance(key, str) or len(key.encode()) < 32:
        raise ReadwiseReaderAdapterError(
            "Readwise Reader binding key must be at least 32 bytes"
        )
    return hmac.new(key.encode(), f"{selected}\0{token}".encode(), hashlib.sha256).hexdigest()


def expected_binding(value: Any) -> str:
    if not isinstance(value, str) or BINDING.fullmatch(value) is None:
        raise ReadwiseReaderAdapterError(
            "Readwise Reader expected token binding is invalid"
        )
    return value


def verify_token_binding(token: str, account: str, key: str, expected: str) -> None:
    actual = token_binding(token, account, key)
    if not hmac.compare_digest(actual, expected_binding(expected)):
        raise ReadwiseReaderAdapterError(
            "Readwise Reader token does not match the deployment account binding"
        )


def account_id(account: Any, key: Any) -> str:
    selected = binding_account_id(account)
    if not isinstance(key, str) or len(key.encode()) < 32:
        raise ReadwiseReaderAdapterError(
            "Readwise Reader binding key must be at least 32 bytes"
        )
    digest = hmac.new(key.encode(), selected.encode(), hashlib.sha256).hexdigest()[:24]
    return f"rwr_{digest}"


def resource_id(kind: str, value: Any) -> str:
    if not kind.replace("_", "").isalpha() or len(kind) > 32:
        raise ReadwiseReaderAdapterError("Readwise Reader resource kind is invalid")
    if not isinstance(value, str) or not value or "\x00" in value or len(value.encode()) > 4096:
        raise ReadwiseReaderAdapterError("Readwise Reader resource identity is invalid")
    digest = hashlib.sha256(value.encode()).hexdigest()[:32]
    return f"rwr_{kind}_{digest}"
