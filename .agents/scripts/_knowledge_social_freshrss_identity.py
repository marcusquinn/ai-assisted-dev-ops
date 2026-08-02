#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Durable FreshRSS installation and account identity validation."""

from __future__ import annotations

import hashlib
import hmac
from typing import Any
from urllib.parse import SplitResult, urlsplit

from knowledge_social_store import SocialStoreError


class FreshRSSAdapterError(SocialStoreError):
    """Raised when guarded FreshRSS collection cannot continue safely."""


class FreshRSSProviderUnavailableError(FreshRSSAdapterError):
    """Raised when the bounded FreshRSS HTTP child cannot complete a read."""


def _parsed_url(value: str) -> tuple[SplitResult, int | None]:
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise FreshRSSAdapterError("FreshRSS profile base URL is invalid") from error
    return parsed, port


def canonical_base_url(value: Any) -> str:
    """Return one credential-free exact HTTPS FreshRSS installation root."""
    if not isinstance(value, str) or not value or "\x00" in value:
        raise FreshRSSAdapterError("FreshRSS profile base URL is invalid")
    parsed, port = _parsed_url(value)
    checks = (
        parsed.scheme.lower() == "https",
        parsed.hostname is not None,
        parsed.username is None,
        parsed.password is None,
        not parsed.query,
        not parsed.fragment,
    )
    if not all(checks):
        raise FreshRSSAdapterError("FreshRSS profile base URL must be HTTPS")
    path = parsed.path.rstrip("/")
    if any(marker in path for marker in ("\\", "%", "//")) or any(
        part in (".", "..") for part in path.split("/") if part
    ):
        raise FreshRSSAdapterError("FreshRSS profile base URL is invalid")
    host = parsed.hostname.lower()
    rendered = f"[{host}]" if ":" in host else host
    if port is not None and port != 443:
        rendered = f"{rendered}:{port}"
    return f"https://{rendered}{path}"


def installation_id(base_url: Any, origin_key: Any) -> str:
    """Key the installation identity without persisting its private URL."""
    canonical = canonical_base_url(base_url)
    if not isinstance(origin_key, str) or len(origin_key.encode()) < 32:
        raise FreshRSSAdapterError(
            "FreshRSS profile origin key must be at least 32 bytes"
        )
    digest = hmac.new(origin_key.encode(), canonical.encode(), hashlib.sha256).hexdigest()
    return f"freshrss_{digest[:24]}"


def user_id(value: Any) -> str:
    """Validate one case-sensitive native FreshRSS username."""
    if (
        not isinstance(value, str)
        or not value
        or value != value.strip()
        or "\x00" in value
        or len(value.encode()) > 256
        or any(character.isspace() for character in value)
    ):
        raise FreshRSSAdapterError("FreshRSS user ID is invalid")
    return value


def account_id(instance: Any, local_user_id: Any) -> str:
    """Namespace a private native username by the exact installation."""
    if not isinstance(instance, str) or not instance.startswith("freshrss_"):
        raise FreshRSSAdapterError("FreshRSS installation identity is invalid")
    local = user_id(local_user_id)
    digest = hashlib.sha256(f"{instance}\0{local}".encode()).hexdigest()[:24]
    return f"{instance}_user_{digest}"


def resource_id(instance: Any, kind: str, value: Any) -> str:
    """Return one installation-qualified opaque resource ID."""
    if not isinstance(instance, str) or not instance.startswith("freshrss_"):
        raise FreshRSSAdapterError("FreshRSS installation identity is invalid")
    if not kind.replace("_", "").isalpha() or len(kind) > 32:
        raise FreshRSSAdapterError("FreshRSS resource kind is invalid")
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        raise FreshRSSAdapterError("FreshRSS resource identity is invalid")
    opaque = str(value)
    if not opaque or "\x00" in opaque or len(opaque.encode()) > 4096:
        raise FreshRSSAdapterError("FreshRSS resource identity is invalid")
    digest = hashlib.sha256(f"{instance}\0{opaque}".encode()).hexdigest()[:32]
    return f"frss_{kind}_{digest}"
