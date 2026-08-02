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


def _validate_origin(parsed: SplitResult) -> None:
    if parsed.scheme.lower() != "https":
        raise FreshRSSAdapterError("FreshRSS profile base URL must be HTTPS")
    if parsed.hostname is None:
        raise FreshRSSAdapterError("FreshRSS profile base URL must be HTTPS")
    if parsed.username is not None:
        raise FreshRSSAdapterError("FreshRSS profile base URL must be HTTPS")
    if parsed.password is not None:
        raise FreshRSSAdapterError("FreshRSS profile base URL must be HTTPS")
    if parsed.query:
        raise FreshRSSAdapterError("FreshRSS profile base URL must be HTTPS")
    if parsed.fragment:
        raise FreshRSSAdapterError("FreshRSS profile base URL must be HTTPS")


def _validate_path(path: str) -> None:
    for marker in ("\\", "%", "//"):
        if marker in path:
            raise FreshRSSAdapterError("FreshRSS profile base URL is invalid")
    for part in path.split("/"):
        if part in (".", ".."):
            raise FreshRSSAdapterError("FreshRSS profile base URL is invalid")


def _render_origin(parsed: SplitResult, port: int | None) -> str:
    host = parsed.hostname
    if host is None:
        raise FreshRSSAdapterError("FreshRSS profile base URL must be HTTPS")
    rendered = f"[{host.lower()}]" if ":" in host else host.lower()
    if port is not None and port != 443:
        return f"{rendered}:{port}"
    return rendered


def canonical_base_url(value: Any) -> str:
    """Return one credential-free exact HTTPS FreshRSS installation root."""
    if not isinstance(value, str):
        raise FreshRSSAdapterError("FreshRSS profile base URL is invalid")
    if not value or "\x00" in value:
        raise FreshRSSAdapterError("FreshRSS profile base URL is invalid")
    parsed, port = _parsed_url(value)
    _validate_origin(parsed)
    path = parsed.path.rstrip("/")
    _validate_path(path)
    return f"https://{_render_origin(parsed, port)}{path}"


def installation_id(base_url: Any, origin_key: Any) -> str:
    """Key the installation identity without persisting its private URL."""
    canonical = canonical_base_url(base_url)
    if not isinstance(origin_key, str):
        raise FreshRSSAdapterError(
            "FreshRSS profile origin key must be at least 32 bytes"
        )
    if len(origin_key.encode()) < 32:
        raise FreshRSSAdapterError(
            "FreshRSS profile origin key must be at least 32 bytes"
        )
    digest = hmac.new(origin_key.encode(), canonical.encode(), hashlib.sha256).hexdigest()
    return f"freshrss_{digest[:24]}"


def user_id(value: Any) -> str:
    """Validate one case-sensitive native FreshRSS username."""
    if not isinstance(value, str):
        raise FreshRSSAdapterError("FreshRSS user ID is invalid")
    if not value or value != value.strip():
        raise FreshRSSAdapterError("FreshRSS user ID is invalid")
    if "\x00" in value or len(value.encode()) > 256:
        raise FreshRSSAdapterError("FreshRSS user ID is invalid")
    if any(character.isspace() for character in value):
        raise FreshRSSAdapterError("FreshRSS user ID is invalid")
    return value


def _instance_id(value: Any) -> str:
    if not isinstance(value, str):
        raise FreshRSSAdapterError("FreshRSS installation identity is invalid")
    if not value.startswith("freshrss_"):
        raise FreshRSSAdapterError("FreshRSS installation identity is invalid")
    return value


def _resource_kind(value: Any) -> str:
    if not isinstance(value, str):
        raise FreshRSSAdapterError("FreshRSS resource kind is invalid")
    if len(value) > 32 or not value.replace("_", "").isalpha():
        raise FreshRSSAdapterError("FreshRSS resource kind is invalid")
    return value


def _resource_value(value: Any) -> str:
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        raise FreshRSSAdapterError("FreshRSS resource identity is invalid")
    opaque = str(value)
    if not opaque or "\x00" in opaque:
        raise FreshRSSAdapterError("FreshRSS resource identity is invalid")
    if len(opaque.encode()) > 4096:
        raise FreshRSSAdapterError("FreshRSS resource identity is invalid")
    return opaque


def account_id(instance: Any, local_user_id: Any) -> str:
    """Namespace a private native username by the exact installation."""
    selected_instance = _instance_id(instance)
    local = user_id(local_user_id)
    digest = hashlib.sha256(f"{selected_instance}\0{local}".encode()).hexdigest()[:24]
    return f"{selected_instance}_user_{digest}"


def resource_id(instance: Any, kind: str, value: Any) -> str:
    """Return one installation-qualified opaque resource ID."""
    selected_instance = _instance_id(instance)
    selected_kind = _resource_kind(kind)
    opaque = _resource_value(value)
    digest = hashlib.sha256(f"{selected_instance}\0{opaque}".encode()).hexdigest()[:32]
    return f"frss_{selected_kind}_{digest}"
