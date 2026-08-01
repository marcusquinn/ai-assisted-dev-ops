#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate and namespace immutable Slack workspace identities."""

from __future__ import annotations

import base64
import hashlib
import re
from typing import Any

from knowledge_social_import import canonical_json
from knowledge_social_store import SocialStoreError

TOKEN_TYPES = frozenset({"bot", "user"})
CONVERSATION_KINDS = frozenset(
    {"public_channel", "private_channel", "im", "mpim"}
)
ALIAS = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
SLACK_TEAM_ID = re.compile(r"^T[A-Z0-9]{2,31}$")
SLACK_ENTERPRISE_ID = re.compile(r"^E[A-Z0-9]{2,31}$")
SLACK_USER_ID = re.compile(r"^[UW][A-Z0-9]{2,31}$")
SLACK_CONVERSATION_ID = re.compile(r"^[CDG][A-Z0-9]{2,31}$")
SLACK_TIMESTAMP = re.compile(r"^[0-9]{1,16}\.[0-9]{6}$")
ACCOUNT_ID = re.compile(r"^slack_(T[A-Z0-9]{2,31})_user_([UW][A-Z0-9]{2,31})$")


class SlackAdapterError(SocialStoreError):
    """Raised when bounded Slack collection cannot continue safely."""


class SlackProviderUnavailableError(SlackAdapterError):
    """Raised when the isolated Slack reader cannot complete a read."""


def _slack_id(value: Any, field: str, pattern: re.Pattern[str]) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise SlackAdapterError(f"Slack {field} is invalid")
    return value


def team_id(value: Any) -> str:
    return _slack_id(value, "workspace ID", SLACK_TEAM_ID)


def enterprise_id(value: Any, *, optional: bool = True) -> str | None:
    if value is None and optional:
        return None
    return _slack_id(value, "enterprise ID", SLACK_ENTERPRISE_ID)


def user_id(value: Any) -> str:
    return _slack_id(value, "user ID", SLACK_USER_ID)


def conversation_id(value: Any) -> str:
    return _slack_id(value, "conversation ID", SLACK_CONVERSATION_ID)


def slack_timestamp(value: Any, field: str = "timestamp") -> str:
    return _slack_id(value, field, SLACK_TIMESTAMP)


def token_type(value: Any) -> str:
    if value not in TOKEN_TYPES:
        raise SlackAdapterError("Slack token type must be bot or user")
    return str(value)


def account_id(workspace: str, user: str) -> str:
    return f"slack_{team_id(workspace)}_user_{user_id(user)}"


def parse_account_id(value: Any) -> tuple[str, str]:
    if not isinstance(value, str):
        raise SlackAdapterError("Slack account ID is invalid")
    match = ACCOUNT_ID.fullmatch(value)
    if match is None:
        raise SlackAdapterError("Slack account ID is invalid")
    return match.group(1), match.group(2)


def conversation_binding_sha256(value: Any) -> str:
    """Hash one exact alias-to-conversation policy after full validation."""
    if not isinstance(value, dict) or len(value) > 500:
        raise SlackAdapterError("Slack conversation binding is invalid")
    prefixes = {
        "public_channel": "C",
        "private_channel": "G",
        "im": "D",
        "mpim": "G",
    }
    normalized: dict[str, dict[str, str]] = {}
    for alias, target in value.items():
        if not isinstance(alias, str) or ALIAS.fullmatch(alias) is None:
            raise SlackAdapterError("Slack conversation alias is invalid")
        if not isinstance(target, dict) or set(target) != {"id", "kind"}:
            raise SlackAdapterError("Slack conversation binding is invalid")
        native_id = conversation_id(target.get("id"))
        kind = target.get("kind")
        prefix = prefixes.get(str(kind))
        if prefix is None or not native_id.startswith(prefix):
            raise SlackAdapterError("Slack conversation ID and kind conflict")
        normalized[alias] = {"id": native_id, "kind": str(kind)}
    native_ids = {target["id"] for target in normalized.values()}
    if len(native_ids) != len(normalized):
        raise SlackAdapterError("Slack conversation binding contains duplicate IDs")
    payload = canonical_json(normalized).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def namespaced_id(workspace: str, kind: str, native_id: Any) -> str:
    """Build one API/export-stable identity from reviewed Slack native IDs."""
    workspace = team_id(workspace)
    if not isinstance(kind, str) or not re.fullmatch(r"[a-z][a-z_]{1,31}", kind):
        raise SlackAdapterError("Slack identity kind is invalid")
    if not isinstance(native_id, str) or not native_id or "\x00" in native_id:
        raise SlackAdapterError("Slack native identity is invalid")
    if len(native_id.encode("utf-8")) > 256:
        raise SlackAdapterError("Slack native identity exceeds the safety limit")
    encoded = base64.urlsafe_b64encode(native_id.encode("utf-8")).decode("ascii")
    return f"slack_{workspace}_{kind}_{encoded.rstrip('=')}"
