#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Root-bound official Notion API reader subprocess."""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from typing import Any

from _knowledge_social_notion import Limits, PageRequest, parse_page_request
from _knowledge_social_notion_contract import (
    ApiResult,
    NotionReadProviderError,
    object_value,
    observed_at,
    optional_text,
    terminal_payload,
)
from _knowledge_social_notion_http import (
    Opener,
    ProfileConfig,
    http_opener,
    identity_api,
    task_api,
)
from _knowledge_social_notion_identity import (
    NotionAdapterError,
    bounded_integer,
    notion_id,
    root_page_ids,
)
from _knowledge_social_notion_result import _handle_result
from knowledge_social_import import reject_credentials

MAX_REQUEST_BYTES = 128 * 1024
MAX_OUTPUT_BYTES = 8 * 1024 * 1024
PROFILE_DEFAULTS = {
    "MAX_BLOCKS": 5_000,
    "MAX_BYTES": 16 * 1024 * 1024,
    "MAX_DEPTH": 8,
    "MAX_PAGES": 500,
}


def _required(name: str) -> str:
    value = os.environ.get(name)
    if not value or "\x00" in value or "\n" in value or "\r" in value:
        raise NotionReadProviderError("Notion profile configuration is incomplete")
    return value


def _profile_integer(prefix: str, suffix: str, minimum: int, maximum: int) -> int:
    raw = os.environ.get(f"{prefix}_{suffix}")
    if raw is None:
        value = PROFILE_DEFAULTS[suffix]
    else:
        try:
            value = int(raw)
        except ValueError as error:
            raise NotionReadProviderError("Notion profile limit is invalid") from error
    try:
        return bounded_integer(value, suffix.lower().replace("_", " "), minimum, maximum)
    except NotionAdapterError as error:
        raise NotionReadProviderError(str(error)) from error


def _profile(profile: str) -> ProfileConfig:
    prefix = f"NOTION_{profile.upper()}"
    try:
        workspace = notion_id(_required(f"{prefix}_WORKSPACE_ID"), "profile workspace ID")
        roots = root_page_ids(
            [item.strip() for item in _required(f"{prefix}_ROOT_PAGE_IDS").split(",")]
        )
    except NotionAdapterError as error:
        raise NotionReadProviderError(str(error)) from error
    comments_raw = os.environ.get(f"{prefix}_INCLUDE_COMMENTS", "false").lower()
    if comments_raw not in {"true", "false"}:
        raise NotionReadProviderError("Notion comment collection policy is invalid")
    return ProfileConfig(
        _required(f"{prefix}_ACCESS_TOKEN"),
        workspace,
        roots,
        comments_raw == "true",
        _profile_integer(prefix, "MAX_DEPTH", 0, 20),
        _profile_integer(prefix, "MAX_PAGES", 1, 10_000),
        _profile_integer(prefix, "MAX_BLOCKS", 1, 100_000),
        _profile_integer(prefix, "MAX_BYTES", 65_536, 268_435_456),
    )


def _identity_data(result: ApiResult, config: ProfileConfig, expected_id: str) -> dict[str, Any]:
    payload = object_value(result.payload, "identity response")
    if payload.get("object") != "user" or payload.get("type") != "bot":
        raise NotionReadProviderError("Notion profile must identify an integration bot")
    bot = object_value(payload.get("bot"), "bot identity")
    workspace = notion_id(bot.get("workspace_id"), "returned workspace ID")
    if workspace != config.workspace_id or workspace != notion_id(expected_id, "expected workspace ID"):
        raise NotionReadProviderError("Notion workspace identity does not match the connection")
    owner = object_value(bot.get("owner"), "bot owner")
    owner_type = owner.get("type")
    if owner_type not in {"user", "workspace"}:
        raise NotionReadProviderError("Notion bot owner type is invalid")
    return {
        "api_version": "2026-03-11",
        "bot_id": notion_id(payload.get("id"), "bot user ID"),
        "id": workspace,
        "include_comments": config.include_comments,
        "limits": {
            "max_blocks": config.max_blocks,
            "max_bytes": config.max_bytes,
            "max_depth": config.max_depth,
            "max_pages": config.max_pages,
        },
        "owner_type": owner_type,
        "response_bytes": result.response_bytes,
        "root_page_ids": list(config.root_page_ids),
        "workspace_id": workspace,
        "workspace_name": optional_text(bot.get("workspace_name"), "workspace name"),
    }


def _identity(opener: Opener, config: ProfileConfig, expected_id: str) -> dict[str, Any]:
    result = identity_api(config, opener)
    if result.status != 200:
        return terminal_payload(result)
    return {
        "data": _identity_data(result, config, expected_id),
        "observed_at": observed_at(),
        "status": 200,
    }


def _profile_matches(request: PageRequest, config: ProfileConfig) -> None:
    expected_limits = Limits(
        config.max_depth, config.max_pages, config.max_blocks, config.max_bytes
    )
    if (
        request.workspace_id != config.workspace_id
        or request.root_page_ids != config.root_page_ids
        or request.include_comments != config.include_comments
        or request.limits != expected_limits
    ):
        raise NotionReadProviderError("Notion request does not match the secret profile binding")


def _pace() -> None:
    if os.environ.get("AIDEVOPS_TEST_MODE") != "1":
        time.sleep(0.35)


def _page(opener: Opener, config: ProfileConfig, request: PageRequest) -> dict[str, Any]:
    _profile_matches(request, config)
    identity = identity_api(config, opener)
    if identity.status != 200:
        return terminal_payload(identity)
    _identity_data(identity, config, request.workspace_id)
    _pace()
    result = task_api(config, opener, request)
    if result.status != 200:
        terminal = terminal_payload(result)
        terminal["response_bytes"] += identity.response_bytes
        return terminal
    payload = _handle_result(result, request)
    payload["meta"]["response_bytes"] += identity.response_bytes
    reject_credentials(payload)
    _pace()
    return payload


def _request_object() -> dict[str, Any]:
    raw = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    if len(raw) > MAX_REQUEST_BYTES:
        raise NotionReadProviderError("Notion read request exceeds the safety limit")
    try:
        payload = json.loads(raw)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise NotionReadProviderError("Notion read request is invalid") from error
    if not isinstance(payload, dict):
        raise NotionReadProviderError("Notion read request root must be an object")
    return payload


def _dispatch(request: dict[str, Any], opener: Opener, config: ProfileConfig) -> dict[str, Any]:
    action = request.get("action")
    if action == "identity":
        if set(request) != {"action", "account_id"}:
            raise NotionReadProviderError("Notion identity request shape is invalid")
        return _identity(opener, config, notion_id(request.get("account_id"), "workspace ID"))
    if action != "page":
        raise NotionReadProviderError("Notion read action is unsupported")
    return _page(opener, config, parse_page_request(request))


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode("utf-8")) > MAX_OUTPUT_BYTES:
        raise NotionReadProviderError("Notion read response exceeds the safety limit")
    print(encoded)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        _emit(_dispatch(_request_object(), http_opener(), _profile(args.profile)))
        return 0
    except (NotionAdapterError, NotionReadProviderError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - redact provider and credential internals
        print("ERROR: Notion read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
