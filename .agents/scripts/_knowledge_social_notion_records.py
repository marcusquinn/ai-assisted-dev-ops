#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize root-bound Notion pages, blocks, databases, rows, and comments."""

from __future__ import annotations

from typing import Any

from _knowledge_social_notion import PageRequest, Task
from _knowledge_social_notion_contract import (
    NotionReadProviderError,
    file_descriptors,
    list_value,
    object_value,
    optional_text,
    parent_value,
    plain_text,
)
from _knowledge_social_notion_identity import notion_id


def record_page(value: dict[str, Any], request: PageRequest) -> dict[str, Any]:
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
        "last_edited_at": optional_text(value.get("last_edited_time"), "page edit time", maximum=128),
        "parent": parent,
        "published": value.get("public_url") is not None,
        "text": plain_text(properties),
    }


def page_discoveries(request: PageRequest) -> list[Task]:
    task = request.task
    discoveries = [Task("blocks", task.resource_id, task.depth)]
    if request.include_comments:
        discoveries.append(Task("comments", task.resource_id, task.depth))
    return discoveries


def _child_task(block_type: str, block_id: str, request: PageRequest, parent: dict[str, Any]) -> Task:
    task = request.task
    depth = task.depth + 1
    if block_type == "child_page":
        return Task("page", block_id, depth, parent_kind=parent["type"], parent_id=task.resource_id)
    if block_type == "child_database":
        return Task("database", block_id, depth, parent_kind=parent["type"], parent_id=task.resource_id)
    return Task("blocks", block_id, depth, parent_kind=parent["type"], parent_id=task.resource_id)


def block_record(
    value: dict[str, Any], request: PageRequest
) -> tuple[dict[str, Any], list[Task], str | None]:
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
        "last_edited_at": optional_text(value.get("last_edited_time"), "block edit time", maximum=128),
        "parent": parent,
        "text": plain_text(body),
    }
    discoveries: list[Task] = []
    needs_depth = block_type in {"child_page", "child_database"} or value.get("has_children") is True
    if needs_depth and task.depth >= request.limits.max_depth:
        return record, discoveries, "depth"
    if needs_depth:
        synced = block_type == "synced_block" and isinstance(body, dict) and body.get("synced_from") is not None
        if synced:
            record["synced_external_target_not_followed"] = True
        else:
            discoveries.append(_child_task(block_type, block_id, request, parent))
    if request.include_comments:
        discoveries.append(
            Task("comments", block_id, task.depth + 1, parent_kind="block_id", parent_id=task.resource_id)
        )
    return record, discoveries, None


def database_record(value: dict[str, Any], request: PageRequest) -> tuple[dict[str, Any], list[Task]]:
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


def row_record(value: dict[str, Any], request: PageRequest) -> tuple[dict[str, Any], list[Task]]:
    task = request.task
    if value.get("object") != "page":
        raise NotionReadProviderError("Notion data source returned an unsupported child")
    row_id = notion_id(value.get("id"), "data source row page ID")
    parent = parent_value(value.get("parent"), "data_source_id", task.resource_id, task.database_id)
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


def comment_record(value: dict[str, Any], request: PageRequest) -> dict[str, Any]:
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
