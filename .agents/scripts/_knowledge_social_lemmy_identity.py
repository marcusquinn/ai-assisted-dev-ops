#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Lemmy instance, version, account, and resource identity validation."""

from __future__ import annotations

import hashlib
import re
from typing import Any
from urllib.parse import urlsplit

from knowledge_social_store import SocialStoreError

INSTANCE_ID = re.compile(r"^[0-9a-f]{24}$")
RESOURCE_KIND = re.compile(r"^[a-z][a-z_]{0,31}$")
VERSION = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$")


class LemmyAdapterError(SocialStoreError):
    """Raised when guarded Lemmy collection cannot continue safely."""


class LemmyProviderUnavailableError(LemmyAdapterError):
    """Raised when the bounded Lemmy HTTP child cannot complete a read."""


def instance_id(value: Any) -> str:
    """Validate a privacy-safe stable home-instance fingerprint."""
    if not isinstance(value, str) or INSTANCE_ID.fullmatch(value) is None:
        raise LemmyAdapterError("Lemmy instance identity is invalid")
    return value


def positive_id(value: Any, field: str) -> str:
    """Normalize one positive instance-local numeric ID without coercion."""
    if isinstance(value, bool):
        raise LemmyAdapterError(f"Lemmy {field} is invalid")
    if isinstance(value, int):
        normalized = str(value)
    elif isinstance(value, str) and value.isdigit():
        normalized = value
    else:
        raise LemmyAdapterError(f"Lemmy {field} is invalid")
    if int(normalized) < 1 or len(normalized) > 20:
        raise LemmyAdapterError(f"Lemmy {field} is invalid")
    return normalized


def provider_account_id(value: Any) -> str:
    """Validate a selected home-instance person ID."""
    if isinstance(value, str) and value.startswith("person_"):
        value = value.removeprefix("person_")
    return positive_id(value, "person ID")


def account_name(value: Any) -> str:
    """Validate one bounded Lemmy account name."""
    if not isinstance(value, str) or not value or "\x00" in value:
        raise LemmyAdapterError("Lemmy account name is invalid")
    if len(value.encode("utf-8")) > 256:
        raise LemmyAdapterError("Lemmy account name is invalid")
    return value


def _is_https_identity(parsed: Any) -> bool:
    checks = (
        parsed.scheme.lower() == "https",
        parsed.hostname is not None,
        parsed.username is None,
        parsed.password is None,
        not parsed.fragment,
    )
    return all(checks)


def activitypub_id(value: Any, field: str = "ActivityPub ID") -> str:
    """Validate and retain one credential-free HTTPS ActivityPub identity."""
    if not isinstance(value, str) or not value or "\x00" in value:
        raise LemmyAdapterError(f"Lemmy {field} is invalid")
    if len(value.encode("utf-8")) > 4096:
        raise LemmyAdapterError(f"Lemmy {field} is invalid")
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise LemmyAdapterError(f"Lemmy {field} is invalid") from error
    del port
    if not _is_https_identity(parsed):
        raise LemmyAdapterError(f"Lemmy {field} is invalid")
    return value


def api_family(value: Any) -> str:
    """Map an exact supported Lemmy server version to one API family."""
    if not isinstance(value, str) or VERSION.fullmatch(value) is None:
        raise LemmyAdapterError("Lemmy instance version is ambiguous")
    if value.startswith("1."):
        return "v4"
    if value.startswith("0.19."):
        return "v3"
    raise LemmyAdapterError("Lemmy instance version is unsupported")


def namespaced_id(installation: str, kind: str, value: Any) -> str:
    """Namespace one installation-local numeric ID without embedding it."""
    stable_instance = instance_id(installation)
    if RESOURCE_KIND.fullmatch(kind) is None:
        raise LemmyAdapterError("Lemmy resource kind is invalid")
    local_id = positive_id(value, "resource ID")
    digest = hashlib.sha256(local_id.encode("ascii")).hexdigest()[:32]
    return f"lmy_{stable_instance}_{kind}_{digest}"
