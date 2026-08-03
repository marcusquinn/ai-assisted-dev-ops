#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and deterministic fixture readers for Notion Sites."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_fixture import FixturePageReader
from _knowledge_social_notion import (
    API_VERSION,
    PageRequest,
    limits_value,
)
from _knowledge_social_notion_identity import (
    NotionAdapterError,
    NotionProviderUnavailableError,
    notion_id,
    root_page_ids,
)
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SAFE_PROVIDER_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "Notion profile configuration is incomplete",
    "Notion profile limit is invalid",
    "Notion comment collection policy is invalid",
    "Notion profile must identify an integration bot",
    "Notion workspace identity does not match the connection",
    "Notion request does not match the secret profile binding",
    "Notion response escaped the authorized parent binding",
    "Notion read provider request failed",
)


class NotionReader(Protocol):
    def identity(self, expected_id: str) -> dict[str, Any]: ...
    def page(self, request: PageRequest) -> dict[str, Any]: ...


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise NotionAdapterError("Notion read response exceeds the safety limit")
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise NotionAdapterError("Notion read provider returned no valid JSON") from error
    if not isinstance(payload, dict):
        raise NotionAdapterError("Notion read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> NotionProviderUnavailableError:
    for message in SAFE_PROVIDER_FAILURES:
        if f"ERROR: {message}" in stderr:
            return NotionProviderUnavailableError(message)
    return NotionProviderUnavailableError("Notion read provider is unavailable")


NOTION_READER_POLICY = GuardedOAuthPolicy(
    "Notion",
    "NOTION",
    "NOTION_READ_LOG",
    READ_TIMEOUT_SECONDS,
    _decode_output,
    _provider_failure,
    NotionProviderUnavailableError,
    (
        "ACCESS_TOKEN",
        "WORKSPACE_ID",
        "ROOT_PAGE_IDS",
        "INCLUDE_COMMENTS",
        "MAX_DEPTH",
        "MAX_PAGES",
        "MAX_BLOCKS",
        "MAX_BYTES",
    ),
    "",
)


class GuardedNotion(GuardedOAuthReader):
    """Execute only the fixed official API reader with a filtered profile."""

    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, NOTION_READER_POLICY)


class FixtureNotion(FixturePageReader):
    """Deterministic substitute for queue, pagination, and failure tests."""

    def __init__(self, path: Path) -> None:
        super().__init__(path, "Notion", NotionAdapterError)


def _optional_name(value: Any) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value or "\x00" in value:
        raise NotionAdapterError("Notion workspace name is invalid")
    if len(value.encode("utf-8")) > 512:
        raise NotionAdapterError("Notion workspace name exceeds the safety limit")
    return value


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Bind one bot, workspace, explicit root allowlist, and traversal policy."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise NotionAdapterError("Notion identity response returned no account")
    workspace = notion_id(data.get("workspace_id"), "workspace ID")
    if workspace != notion_id(expected_id, "expected workspace ID"):
        raise NotionAdapterError(
            "Notion workspace identity does not match the configured connection"
        )
    if data.get("api_version") != API_VERSION:
        raise NotionAdapterError("Notion API version does not match the reviewed contract")
    owner_type = data.get("owner_type")
    if owner_type not in {"user", "workspace"}:
        raise NotionAdapterError("Notion bot owner type is invalid")
    comments = data.get("include_comments")
    if not isinstance(comments, bool):
        raise NotionAdapterError("Notion comment collection policy must be boolean")
    response_bytes = data.get("response_bytes", 0)
    if (
        isinstance(response_bytes, bool)
        or not isinstance(response_bytes, int)
        or response_bytes < 0
        or response_bytes > MAX_RESPONSE_BYTES
    ):
        raise NotionAdapterError("Notion identity byte count is invalid")
    return {
        "bot_id": notion_id(data.get("bot_id"), "bot user ID"),
        "id": workspace,
        "include_comments": comments,
        "limits": limits_value(data.get("limits")).payload(),
        "owner_type": owner_type,
        "root_page_ids": list(root_page_ids(data.get("root_page_ids"))),
        "workspace_id": workspace,
        "workspace_name": _optional_name(data.get("workspace_name")),
    }
