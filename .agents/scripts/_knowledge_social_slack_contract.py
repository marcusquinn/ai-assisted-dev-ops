#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation primitives for the isolated Slack HTTP and export readers."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_slack import (
    SlackAdapterError,
    account_id,
    enterprise_id,
    team_id,
    token_type,
    user_id,
)

MAX_TEXT_BYTES = 256 * 1024


class SlackReadProviderError(SlackAdapterError):
    """Raised for a privacy-safe local Slack provider failure."""


class SlackAuthorizationError(SlackReadProviderError):
    """Raised when a verified token lacks one required read capability."""


@dataclass(frozen=True)
class ApiResult:
    """One bounded Slack Web API result plus verified response metadata."""

    status: int
    payload: Any
    scopes: frozenset[str]
    retry_after: str | None = None


@dataclass(frozen=True)
class IdentityBinding:
    """Non-secret profile authority that every live request must revalidate."""

    workspace_id: str
    enterprise_id: str | None
    token_type: str


def observed_at() -> str:
    return (
        datetime.now(UTC)
        .isoformat(timespec="microseconds")
        .replace("+00:00", "Z")
    )


def exact_keys(request: dict[str, Any], expected: set[str]) -> None:
    if set(request) != expected:
        raise SlackReadProviderError("Slack read request has an invalid action shape")


def request_object(payload: bytes, limit: int) -> dict[str, Any]:
    if len(payload) > limit:
        raise SlackReadProviderError("Slack read request exceeds the safety limit")
    try:
        request = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SlackReadProviderError("Slack read request is not valid JSON") from error
    if not isinstance(request, dict):
        raise SlackReadProviderError("Slack read request root must be an object")
    return request


def object_value(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise SlackReadProviderError(f"Slack {field} must be an object")
    return value


def object_list(value: Any, field: str, *, limit: int) -> list[dict[str, Any]]:
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise SlackReadProviderError(f"Slack {field} must be an array of objects")
    if len(value) > limit:
        raise SlackReadProviderError(f"Slack {field} exceeds the item safety limit")
    return value


def optional_text(value: Any, field: str, *, limit: int = MAX_TEXT_BYTES) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value:
        raise SlackReadProviderError(f"Slack {field} must be text")
    if len(value.encode("utf-8")) > limit:
        raise SlackReadProviderError(f"Slack {field} exceeds the safety limit")
    return value


def required_text(value: Any, field: str, *, limit: int = MAX_TEXT_BYTES) -> str:
    text = optional_text(value, field, limit=limit)
    if not text:
        raise SlackReadProviderError(f"Slack {field} is required")
    return text


def optional_boolean(value: Any, field: str) -> bool | None:
    if value is None:
        return None
    if not isinstance(value, bool):
        raise SlackReadProviderError(f"Slack {field} must be boolean")
    return value


def non_negative_integer(
    value: Any, field: str, *, optional: bool = False
) -> int | None:
    if value is None and optional:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise SlackReadProviderError(
            f"Slack {field} must be a non-negative integer"
        )
    return value


def _identity_token_type(payload: dict[str, Any]) -> str:
    bot = payload.get("bot_id")
    if bot is not None:
        required_text(bot, "bot ID", limit=64)
        return "bot"
    return "user"


def identity_value(
    payload: Any,
    expected_id: str,
    binding: IdentityBinding,
    scopes: frozenset[str],
) -> dict[str, Any]:
    """Serialize stable auth.test identity and fail closed on profile rebinding."""
    root = object_value(payload, "identity response")
    if root.get("ok") is not True:
        raise SlackReadProviderError("Slack identity response is unsuccessful")
    workspace = team_id(root.get("team_id"))
    selected_user = user_id(root.get("user_id"))
    enterprise = enterprise_id(root.get("enterprise_id"))
    actual_type = _identity_token_type(root)
    expected_workspace, expected_user = _expected_account(expected_id)
    observed = (workspace, workspace, selected_user, enterprise, actual_type)
    expected = (
        binding.workspace_id,
        expected_workspace,
        expected_user,
        binding.enterprise_id,
        binding.token_type,
    )
    if observed != expected:
        raise SlackReadProviderError(
            "selected Slack workspace or account does not match the configured connection"
        )
    return {
        "id": account_id(workspace, selected_user),
        "provider_account_id": selected_user,
        "workspace_id": workspace,
        "enterprise_id": enterprise,
        "token_type": token_type(actual_type),
        "scopes": sorted(scopes),
        "username": optional_text(root.get("user"), "account name"),
        "workspace_name": optional_text(root.get("team"), "workspace name"),
    }


def _expected_account(value: Any) -> tuple[str, str]:
    from _knowledge_social_slack import parse_account_id

    return parse_account_id(value)


def terminal_payload(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {"status": result.status, "observed_at": observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload
