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
from typing import Any, Callable

from _knowledge_social_notion import Limits, PageRequest, Task, parse_page_request
from _knowledge_social_notion_contract import (
    ApiResult,
    NotionReadProviderError,
    file_descriptors,
    list_value,
    object_value,
    observed_at,
    optional_text,
    parent_value,
    plain_text,
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


def _record_page(value: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    task = request.task
    page_id = notion_id(value.get("id"), "page ID")
    if value.get("object") != "page" or page_id != task.resource_id:
        raise NotionReadProviderError("Notion page response does not match the requested page")
    if task.parent_kind is not None:
        parent = parent_value(value.get("parent"), task.parent_kind, task.parent_id, task.database_id)
    else:
        if page_id not in request.root_page_ids:
            raise NotionReadProviderError("Notion page is not an authorized root")
        parent = parent_value(value.get("parent"))
    properties = object_value(value.get("properties", {}), "page properties")
    return {
        "created_at": optional_text(value.get("created_time"), "page creation time", maximum=128),
        "files": file_descriptors(value),
        "id": page_id,
        "in_trash": value.get("in_trash") is True,
        "kind": "page",
        "last_edited_at": optional_text(
            value.get("last_edited_time"), "page edit time", maximum=128
        ),
        "parent": parent,
        "published": value.get("public_url") is not None,
        "text": plain_text(properties),
    }


def _page_discoveries(request: PageRequest) -> list[Task]:
    task = request.task
    discoveries = [Task("blocks", task.resource_id, task.depth)]
    if request.include_comments:
        discoveries.append(Task("comments", task.resource_id, task.depth))
    return discoveries


def _block_record(value: dict[str, Any], request: PageRequest) -> tuple[dict[str, Any], list[Task], str | None]:
    task = request.task
    if value.get("object") != "block":
        raise NotionReadProviderError("Notion child response contains a non-block object")
    block_id = notion_id(value.get("id"), "block ID")
    parent = parent_value(value.get("parent"))
    if parent.get(parent.get("type")) != task.resource_id:
        raise NotionReadProviderError("Notion child block escaped the requested parent")
    block_type = value.get("type")
    if not isinstance(block_type, str) or not block_type or "\x00" in block_type:
        raise NotionReadProviderError("Notion block type is invalid")
    body = value.get(block_type, {})
    record = {
        "block_type": block_type,
        "created_at": optional_text(value.get("created_time"), "block creation time", maximum=128),
        "external_target_not_fetched": block_type in {"bookmark", "embed", "link_preview"},
        "files": file_descriptors(body),
        "id": block_id,
        "in_trash": value.get("in_trash") is True,
        "kind": "block",
        "last_edited_at": optional_text(
            value.get("last_edited_time"), "block edit time", maximum=128
        ),
        "parent": parent,
        "text": plain_text(body),
    }
    discoveries: list[Task] = []
    needs_depth = block_type in {"child_page", "child_database"} or value.get("has_children") is True
    if needs_depth and task.depth >= request.limits.max_depth:
        return record, discoveries, "depth"
    child_depth = task.depth + 1
    if block_type == "child_page":
        discoveries.append(
            Task("page", block_id, child_depth, parent_kind=parent["type"], parent_id=task.resource_id)
        )
    elif block_type == "child_database":
        discoveries.append(
            Task("database", block_id, child_depth, parent_kind=parent["type"], parent_id=task.resource_id)
        )
    elif value.get("has_children") is True:
        synced = block_type == "synced_block" and isinstance(body, dict) and body.get("synced_from") is not None
        if not synced:
            discoveries.append(
                Task("blocks", block_id, child_depth, parent_kind=parent["type"], parent_id=task.resource_id)
            )
        else:
            record["synced_external_target_not_followed"] = True
    if request.include_comments:
        discoveries.append(
            Task("comments", block_id, child_depth, parent_kind="block_id", parent_id=task.resource_id)
        )
    return record, discoveries, None


def _database_record(value: dict[str, Any], request: PageRequest) -> tuple[dict[str, Any], list[Task]]:
    task = request.task
    database_id = notion_id(value.get("id"), "database ID")
    if value.get("object") != "database" or database_id != task.resource_id:
        raise NotionReadProviderError("Notion database response does not match the request")
    parent = parent_value(value.get("parent"), task.parent_kind, task.parent_id)
    sources = list_value(value.get("data_sources", []), "database data sources", 100)
    discoveries = [
        Task(
            "data_source",
            notion_id(source.get("id"), "data source ID"),
            task.depth,
            parent_kind="database_id",
            parent_id=database_id,
            database_id=database_id,
        )
        for source in sources
    ]
    return (
        {
            "files": file_descriptors(value),
            "id": database_id,
            "kind": "database",
            "parent": parent,
            "text": plain_text(value.get("title", [])),
        },
        discoveries,
    )


def _row_record(value: dict[str, Any], request: PageRequest) -> tuple[dict[str, Any], list[Task]]:
    task = request.task
    if value.get("object") != "page":
        raise NotionReadProviderError("Notion data source returned an unsupported child")
    row_id = notion_id(value.get("id"), "data source row page ID")
    parent = parent_value(
        value.get("parent"), "data_source_id", task.resource_id, task.database_id
    )
    properties = object_value(value.get("properties", {}), "row page properties")
    discoveries = [
        Task(
            "blocks",
            row_id,
            task.depth + 1,
            parent_kind="data_source_id",
            parent_id=task.resource_id,
            database_id=task.database_id,
        )
    ]
    if request.include_comments:
        discoveries.append(
            Task(
                "comments",
                row_id,
                task.depth + 1,
                parent_kind="data_source_id",
                parent_id=task.resource_id,
                database_id=task.database_id,
            )
        )
    return (
        {
            "created_at": optional_text(value.get("created_time"), "row creation time", maximum=128),
            "files": file_descriptors(value),
            "id": row_id,
            "kind": "page",
            "parent": parent,
            "published": value.get("public_url") is not None,
            "text": plain_text(properties),
        },
        discoveries,
    )


def _comment_record(value: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    if value.get("object") != "comment":
        raise NotionReadProviderError("Notion comment response contains a non-comment object")
    parent = parent_value(value.get("parent"))
    if parent.get(parent.get("type")) != request.task.resource_id:
        raise NotionReadProviderError("Notion comment escaped the requested resource")
    creator = object_value(value.get("created_by"), "comment creator")
    return {
        "created_at": optional_text(value.get("created_time"), "comment creation time", maximum=128),
        "created_by": notion_id(creator.get("id"), "comment creator ID"),
        "discussion_id": notion_id(value.get("discussion_id"), "discussion ID"),
        "files": file_descriptors(value.get("attachments", [])),
        "id": notion_id(value.get("id"), "comment ID"),
        "kind": "comment",
        "parent": parent,
        "text": plain_text(value.get("rich_text", [])),
    }


def _list_response(result: ApiResult, request: PageRequest) -> tuple[list[dict[str, Any]], str | None, str]:
    payload = object_value(result.payload, "list response")
    if payload.get("object") != "list":
        raise NotionReadProviderError("Notion paginated response is not a list")
    records = list_value(payload.get("results"), "paginated results", request.page_size)
    has_more = payload.get("has_more")
    if not isinstance(has_more, bool):
        raise NotionReadProviderError("Notion pagination flag is invalid")
    next_cursor = payload.get("next_cursor")
    if has_more:
        next_cursor = optional_text(next_cursor, "next cursor", maximum=4096)
        if not next_cursor:
            raise NotionReadProviderError("Notion pagination cursor is missing")
    elif next_cursor is not None:
        raise NotionReadProviderError("Notion terminal page unexpectedly returned a cursor")
    status = object_value(payload.get("request_status", {"type": "complete"}), "request status")
    status_type = status.get("type")
    if status_type not in {"complete", "incomplete"}:
        raise NotionReadProviderError("Notion request status is invalid")
    return records, next_cursor, status_type


def _handle_result(result: ApiResult, request: PageRequest) -> dict[str, Any]:
    task = request.task
    discoveries: list[Task] = []
    limit_reason: str | None = None
    next_cursor: str | None = None
    request_status = "complete"
    page_count = 0
    block_count = 0
    if task.kind == "page":
        raw = object_value(result.payload, "page response")
        records = [_record_page(raw, request)]
        discoveries = _page_discoveries(request)
        page_count = 1
    elif task.kind == "blocks":
        raw_records, next_cursor, request_status = _list_response(result, request)
        records = []
        for raw in raw_records:
            record, found, current_limit = _block_record(raw, request)
            records.append(record)
            discoveries.extend(found)
            limit_reason = limit_reason or current_limit
        block_count = len(records)
    elif task.kind == "database":
        raw = object_value(result.payload, "database response")
        record, discoveries = _database_record(raw, request)
        records = [record]
    elif task.kind == "data_source":
        raw_records, next_cursor, request_status = _list_response(result, request)
        records = []
        for raw in raw_records:
            record, found = _row_record(raw, request)
            records.append(record)
            discoveries.extend(found)
        page_count = len(records)
    else:
        raw_records, next_cursor, request_status = _list_response(result, request)
        records = [_comment_record(raw, request) for raw in raw_records]
    if page_count > request.limits.max_pages:
        limit_reason = "pages"
    if block_count > request.limits.max_blocks:
        limit_reason = "blocks"
    return {
        "data": records,
        "meta": {
            "block_count": block_count,
            "discoveries": [task.payload() for task in discoveries],
            "limit_reason": limit_reason,
            "next_cursor": next_cursor,
            "page_count": page_count,
            "request_sha256": request.digest(),
            "request_status": request_status,
            "response_bytes": result.response_bytes,
            "task": task.payload(),
        },
        "observed_at": observed_at(),
        "status": 200,
    }


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
