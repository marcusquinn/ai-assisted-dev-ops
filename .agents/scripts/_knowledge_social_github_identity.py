#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Durable GitHub.com numeric, node, and resource identity validation."""

from __future__ import annotations

import hashlib
import re
from typing import Any

from knowledge_social_store import SocialStoreError

INSTANCE_ID = "github-com"
NODE_ID = re.compile(r"^[A-Za-z0-9_=-]{4,512}$")
LOGIN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})$")
RESOURCE_KIND = re.compile(r"^[a-z][a-z_]{0,31}$")


class GitHubAdapterError(SocialStoreError):
    """Raised when guarded GitHub collection cannot continue safely."""


class GitHubProviderUnavailableError(GitHubAdapterError):
    """Raised when the bounded GitHub HTTP child cannot complete a read."""


def instance_id(value: Any) -> str:
    if value != INSTANCE_ID:
        raise GitHubAdapterError("GitHub installation identity is invalid")
    return INSTANCE_ID


def provider_account_id(value: Any) -> str:
    if isinstance(value, str) and value.startswith("account_"):
        value = value.removeprefix("account_")
    if isinstance(value, bool):
        raise GitHubAdapterError("GitHub numeric account ID is invalid")
    try:
        numeric = int(value)
    except (TypeError, ValueError) as error:
        raise GitHubAdapterError("GitHub numeric account ID is invalid") from error
    if numeric < 1 or str(numeric) != str(value):
        raise GitHubAdapterError("GitHub numeric account ID is invalid")
    return str(numeric)


def node_id(value: Any) -> str:
    if not isinstance(value, str) or NODE_ID.fullmatch(value) is None:
        raise GitHubAdapterError("GitHub node identity is invalid")
    return value


def login(value: Any) -> str:
    if not isinstance(value, str) or LOGIN.fullmatch(value) is None:
        raise GitHubAdapterError("GitHub login is invalid")
    return value


def namespaced_id(kind: str, value: Any) -> str:
    if RESOURCE_KIND.fullmatch(kind) is None:
        raise GitHubAdapterError("GitHub resource kind is invalid")
    if isinstance(value, bool) or not isinstance(value, (str, int)):
        raise GitHubAdapterError("GitHub resource identity is invalid")
    opaque = str(value)
    if not opaque or "\x00" in opaque or len(opaque.encode()) > 512:
        raise GitHubAdapterError("GitHub resource identity is invalid")
    digest = hashlib.sha256(opaque.encode()).hexdigest()[:32]
    return f"gh_{kind}_{digest}"


def account_id(numeric_id: Any, graph_node_id: Any) -> str:
    numeric = provider_account_id(numeric_id)
    node = node_id(graph_node_id)
    return f"ghu_{numeric}_{hashlib.sha256(node.encode()).hexdigest()[:24]}"
