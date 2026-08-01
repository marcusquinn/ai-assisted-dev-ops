#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared contracts for allowlisted Slack read routes."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

from _knowledge_social_slack import PageRequest
from _knowledge_social_slack_contract import (
    ApiResult,
    SlackAuthorizationError,
    SlackReadProviderError,
    object_value,
    observed_at,
    optional_text,
)

Api = Callable[[str, dict[str, str]], ApiResult]
PageResult = ApiResult | dict[str, Any]


@dataclass(frozen=True)
class ConversationTarget:
    """One profile-approved Slack conversation alias."""

    alias: str
    conversation_id: str
    kind: str


def identity_scopes(identity: dict[str, Any]) -> frozenset[str]:
    values = identity.get("scopes")
    if not isinstance(values, list) or any(
        not isinstance(value, str) for value in values
    ):
        raise SlackReadProviderError("Slack identity scopes are invalid")
    return frozenset(values)


def require_scope(identity: dict[str, Any], scope: str) -> None:
    if scope not in identity_scopes(identity):
        raise SlackAuthorizationError("Slack profile lacks the required read scope")


def verified_result(result: ApiResult, identity: dict[str, Any]) -> ApiResult:
    if result.status == 200 and result.scopes != identity_scopes(identity):
        raise SlackReadProviderError("Slack token scopes changed during collection")
    return result


def next_cursor(payload: dict[str, Any]) -> str | None:
    metadata = payload.get("response_metadata", {})
    if metadata is None:
        return None
    root = object_value(metadata, "response metadata")
    value = optional_text(root.get("next_cursor"), "next cursor", limit=4096)
    return value or None


def page_payload(
    request: PageRequest,
    records: list[dict[str, Any]],
    cursor: str | None,
    newest_ts: str | None = None,
) -> dict[str, Any]:
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": records,
        "meta": {
            "stream": request.stream,
            "selector": request.selector,
            "workspace_id": request.workspace_id,
            "next_cursor": cursor,
            "newest_ts": newest_ts,
            "complete": cursor is None,
            "source": "slack_web_api",
        },
    }
