#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation and serialization primitives for the bounded GitHub child."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_github_identity import (
    INSTANCE_ID,
    account_id,
    login,
    node_id,
    provider_account_id,
)

MAX_TEXT_BYTES = 256 * 1024


class GitHubReadProviderError(RuntimeError):
    """Raised for a privacy-safe local GitHub provider failure."""


@dataclass(frozen=True)
class ApiResult:
    status: int
    payload: Any
    next_url: str | None = None
    retry_after: int | None = None


def observed_at() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def decode_json(payload: bytes, limit: int) -> Any:
    if len(payload) > limit:
        raise GitHubReadProviderError("GitHub JSON payload exceeds the safety limit")
    try:
        return json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise GitHubReadProviderError("GitHub JSON payload is invalid") from error


def request_object(payload: bytes, limit: int) -> dict[str, Any]:
    request = decode_json(payload, limit)
    if not isinstance(request, dict):
        raise GitHubReadProviderError("GitHub read request root must be an object")
    return request


def object_value(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise GitHubReadProviderError(f"GitHub {field} must be an object")
    return value


def object_list(value: Any, field: str, *, limit: int) -> list[dict[str, Any]]:
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise GitHubReadProviderError(f"GitHub {field} must be an array of objects")
    if len(value) > limit:
        raise GitHubReadProviderError(f"GitHub {field} exceeds the item safety limit")
    return value


def optional_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value:
        raise GitHubReadProviderError(f"GitHub {field} must be text")
    if len(value.encode()) > MAX_TEXT_BYTES:
        raise GitHubReadProviderError(f"GitHub {field} exceeds the safety limit")
    return value


def required_text(value: Any, field: str) -> str:
    text = optional_text(value, field)
    if not text:
        raise GitHubReadProviderError(f"GitHub {field} is required")
    return text


def combined_identity(rest: Any, graphql: Any, expected_id: str) -> dict[str, Any]:
    rest_user = object_value(rest, "REST identity response")
    graph_root = object_value(graphql, "GraphQL identity response")
    graph_data = object_value(graph_root.get("data"), "GraphQL identity data")
    viewer = object_value(graph_data.get("viewer"), "GraphQL viewer")
    numeric = provider_account_id(rest_user.get("id"))
    rest_node = node_id(rest_user.get("node_id"))
    graph_node = node_id(viewer.get("id"))
    graph_numeric = provider_account_id(viewer.get("databaseId"))
    if numeric != provider_account_id(expected_id) or numeric != graph_numeric or rest_node != graph_node:
        raise GitHubReadProviderError(
            "selected GitHub account does not match the configured connection"
        )
    rest_login = login(rest_user.get("login"))
    if rest_login.casefold() != login(viewer.get("login")).casefold():
        raise GitHubReadProviderError("GitHub REST and GraphQL identities do not match")
    return {
        "id": account_id(numeric, rest_node),
        "provider_account_id": numeric,
        "node_id": rest_node,
        "login": rest_login,
        "name": optional_text(rest_user.get("name"), "account name"),
        "bio": optional_text(rest_user.get("bio"), "account bio"),
        "instance_id": INSTANCE_ID,
    }


def terminal_payload(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {"status": result.status, "observed_at": observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload
