#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Durable Miniflux installation and account identity validation."""

from __future__ import annotations

import hashlib
import hmac
from typing import Any
from urllib.parse import SplitResult, urlsplit

from knowledge_social_store import SocialStoreError


class MinifluxAdapterError(SocialStoreError):
    """Raised when guarded Miniflux collection cannot continue safely."""


class MinifluxProviderUnavailableError(MinifluxAdapterError):
    """Raised when the bounded Miniflux HTTP child cannot complete a read."""


def _parsed_url(value: str) -> tuple[SplitResult, int | None]:
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise MinifluxAdapterError("Miniflux profile base URL is invalid") from error
    return parsed, port


def canonical_base_url(value: Any) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise MinifluxAdapterError("Miniflux profile base URL is invalid")
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
        raise MinifluxAdapterError("Miniflux profile base URL must be HTTPS")
    path = parsed.path.rstrip("/")
    if any(marker in path for marker in ("\\", "%", "//")) or any(
        part in (".", "..") for part in path.split("/") if part
    ):
        raise MinifluxAdapterError("Miniflux profile base URL is invalid")
    host = parsed.hostname.lower()
    rendered = f"[{host}]" if ":" in host else host
    if port is not None and port != 443:
        rendered = f"{rendered}:{port}"
    return f"https://{rendered}{path}"


def installation_id(base_url: Any, origin_key: Any) -> str:
    canonical = canonical_base_url(base_url)
    if not isinstance(origin_key, str) or len(origin_key.encode()) < 32:
        raise MinifluxAdapterError(
            "Miniflux profile origin key must be at least 32 bytes"
        )
    digest = hmac.new(origin_key.encode(), canonical.encode(), hashlib.sha256).hexdigest()
    return f"miniflux_{digest[:24]}"


def user_id(value: Any) -> str:
    if isinstance(value, str) and value.startswith("user_"):
        value = value.removeprefix("user_")
    if isinstance(value, bool):
        raise MinifluxAdapterError("Miniflux user ID is invalid")
    try:
        numeric = int(value)
    except (TypeError, ValueError) as error:
        raise MinifluxAdapterError("Miniflux user ID is invalid") from error
    if numeric < 1 or str(numeric) != str(value):
        raise MinifluxAdapterError("Miniflux user ID is invalid")
    return str(numeric)


def account_id(instance: Any, local_user_id: Any) -> str:
    if not isinstance(instance, str) or not instance.startswith("miniflux_"):
        raise MinifluxAdapterError("Miniflux installation identity is invalid")
    local = user_id(local_user_id)
    return f"{instance}_user_{local}"


def resource_id(instance: Any, kind: str, value: Any) -> str:
    if not isinstance(instance, str) or not instance.startswith("miniflux_"):
        raise MinifluxAdapterError("Miniflux installation identity is invalid")
    if not kind.replace("_", "").isalpha() or len(kind) > 32:
        raise MinifluxAdapterError("Miniflux resource kind is invalid")
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        raise MinifluxAdapterError("Miniflux resource identity is invalid")
    opaque = str(value)
    if not opaque or "\x00" in opaque or len(opaque.encode()) > 4096:
        raise MinifluxAdapterError("Miniflux resource identity is invalid")
    digest = hashlib.sha256(f"{instance}\0{opaque}".encode()).hexdigest()[:32]
    return f"mf_{kind}_{digest}"
