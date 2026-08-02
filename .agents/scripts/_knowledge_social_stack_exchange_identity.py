#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Durable Stack Exchange network and per-site identity validation."""

from __future__ import annotations

import hashlib
import re
from typing import Any

from knowledge_social_store import SocialStoreError

SITE_PARAMETER = re.compile(r"^[a-z0-9](?:[a-z0-9.-]{0,98}[a-z0-9])?$")
RESOURCE_KIND = re.compile(r"^[a-z][a-z_]{0,31}$")


class StackExchangeAdapterError(SocialStoreError):
    """Raised when guarded Stack Exchange collection cannot continue safely."""


class StackExchangeProviderUnavailableError(StackExchangeAdapterError):
    """Raised when the bounded Stack Exchange HTTP child cannot complete a read."""


def numeric_id(value: Any, field: str) -> str:
    if isinstance(value, str) and value.startswith("account_"):
        value = value.removeprefix("account_")
    if isinstance(value, bool):
        raise StackExchangeAdapterError(f"Stack Exchange {field} is invalid")
    try:
        numeric = int(value)
    except (TypeError, ValueError) as error:
        raise StackExchangeAdapterError(f"Stack Exchange {field} is invalid") from error
    if numeric < 1 or str(numeric) != str(value):
        raise StackExchangeAdapterError(f"Stack Exchange {field} is invalid")
    return str(numeric)


def network_account_id(value: Any) -> str:
    return numeric_id(value, "network account ID")


def site_user_id(value: Any) -> str:
    return numeric_id(value, "site user ID")


def api_site_parameter(value: Any) -> str:
    if not isinstance(value, str) or SITE_PARAMETER.fullmatch(value) is None:
        raise StackExchangeAdapterError("Stack Exchange API site parameter is invalid")
    return value


def namespaced_id(site: Any, kind: str, value: Any) -> str:
    selected_site = api_site_parameter(site)
    if RESOURCE_KIND.fullmatch(kind) is None:
        raise StackExchangeAdapterError("Stack Exchange resource kind is invalid")
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        raise StackExchangeAdapterError("Stack Exchange resource identity is invalid")
    opaque = str(value)
    if not opaque or "\x00" in opaque or len(opaque.encode()) > 512:
        raise StackExchangeAdapterError("Stack Exchange resource identity is invalid")
    digest = hashlib.sha256(f"{selected_site}\0{opaque}".encode()).hexdigest()[:32]
    return f"se_{kind}_{digest}"


def account_id(network_id: Any, site: Any, user_id: Any) -> str:
    network = network_account_id(network_id)
    selected_site = api_site_parameter(site)
    user = site_user_id(user_id)
    digest = hashlib.sha256(f"{selected_site}\0{user}".encode()).hexdigest()[:24]
    return f"seu_{network}_{digest}"


def associated_account_id(network_id: Any, site_url: Any, user_id: Any) -> str:
    network = network_account_id(network_id)
    user = site_user_id(user_id)
    if not isinstance(site_url, str) or not site_url.startswith("https://"):
        raise StackExchangeAdapterError("Stack Exchange associated site URL is invalid")
    if "\x00" in site_url or len(site_url.encode()) > 4096:
        raise StackExchangeAdapterError("Stack Exchange associated site URL is invalid")
    digest = hashlib.sha256(f"{site_url.casefold()}\0{user}".encode()).hexdigest()[:24]
    return f"sea_{network}_{digest}"
