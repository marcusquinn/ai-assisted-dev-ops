#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Notion root-bound traversal policy and durable queue checkpoints."""

from __future__ import annotations

import base64
import hashlib
import json
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState
from _knowledge_social_notion_identity import (
    NotionAdapterError,
    NotionProviderUnavailableError,
    bounded_integer,
    notion_id,
    root_page_ids,
)
from knowledge_social_import import canonical_json, reject_credentials

PROVIDER = "notion-sites"
API_VERSION = "2026-03-11"
CURSOR_PREFIX = "notion-sites-v1:"
RETENTION_LIMIT = "connection_access_and_notion_workspace_retention"
MAX_CURSOR_BYTES = 512 * 1024
TASK_KINDS = frozenset({"page", "blocks", "database", "data_source", "comments"})

ADAPTER_ERROR = NotionAdapterError
PROVIDER_UNAVAILABLE_ERROR = NotionProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    resource_kind: str = "notion_object"
    activity_mode: str = "authorized_content"
    pagination: str = "opaque_cursor_and_durable_queue"
    incremental: bool = False
    retention_limit: str | None = RETENTION_LIMIT
    coverage_status: str | None = "partial"
    unavailable_reason: str | None = "explicit_root_descendants_only"
    cost_units: int = 2


STREAMS = {"site_tree": StreamSpec()}


@dataclass(frozen=True)
class Limits:
    max_depth: int
    max_pages: int
    max_blocks: int
    max_bytes: int

    def payload(self) -> dict[str, int]:
        return {
            "max_blocks": self.max_blocks,
            "max_bytes": self.max_bytes,
            "max_depth": self.max_depth,
            "max_pages": self.max_pages,
        }


def limits_value(value: Any) -> Limits:
    if not isinstance(value, dict) or set(value) != {
        "max_blocks",
        "max_bytes",
        "max_depth",
        "max_pages",
    }:
        raise NotionAdapterError("Notion traversal limits have an invalid shape")
    return Limits(
        bounded_integer(value["max_depth"], "maximum depth", 0, 20),
        bounded_integer(value["max_pages"], "maximum pages", 1, 10_000),
        bounded_integer(value["max_blocks"], "maximum blocks", 1, 100_000),
        bounded_integer(value["max_bytes"], "maximum bytes", 65_536, 268_435_456),
    )


@dataclass(frozen=True)
class Task:
    kind: str
    resource_id: str
    depth: int
    cursor: str | None = None
    parent_kind: str | None = None
    parent_id: str | None = None
    database_id: str | None = None

    def payload(self) -> dict[str, Any]:
        return {
            "cursor": self.cursor,
            "database_id": self.database_id,
            "depth": self.depth,
            "kind": self.kind,
            "parent_id": self.parent_id,
            "parent_kind": self.parent_kind,
            "resource_id": self.resource_id,
        }

    def key(self) -> str:
        return canonical_json(
            [self.kind, self.resource_id, self.parent_kind, self.parent_id, self.database_id]
        )


TASK_KEYS = {
    "cursor",
    "database_id",
    "depth",
    "kind",
    "parent_id",
    "parent_kind",
    "resource_id",
}


def _optional_id(value: Any, field: str) -> str | None:
    return None if value is None else notion_id(value, field)


def _cursor_value(value: Any) -> str | None:
    if value is None:
        return None
    if (
        not isinstance(value, str)
        or not value
        or "\x00" in value
        or len(value.encode("utf-8")) > 4096
    ):
        raise NotionAdapterError("Notion pagination cursor is invalid")
    return value


def _task_parent_binding(value: dict[str, Any]) -> tuple[str | None, str | None]:
    parent_kind = value.get("parent_kind")
    if parent_kind not in {None, "page_id", "block_id", "database_id", "data_source_id"}:
        raise NotionAdapterError("Notion traversal parent kind is invalid")
    parent_id = _optional_id(value.get("parent_id"), "task parent ID")
    if (parent_kind is None) != (parent_id is None):
        raise NotionAdapterError("Notion traversal parent binding is incomplete")
    return parent_kind, parent_id


def _validate_task_binding(
    kind: str,
    parent_kind: str | None,
    parent_id: str | None,
    database_id: str | None,
) -> None:
    if kind == "data_source" and (
        database_id is None
        or parent_kind != "database_id"
        or parent_id != database_id
    ):
        raise NotionAdapterError("Notion data source task requires its database binding")
    if kind == "database" and parent_kind not in {"page_id", "block_id"}:
        raise NotionAdapterError("Notion database task requires its descendant parent")
    if kind == "page" and parent_kind not in {None, "page_id", "block_id"}:
        raise NotionAdapterError("Notion page task parent binding is invalid")
    if parent_kind == "data_source_id" and (
        kind not in {"blocks", "comments"} or database_id is None
    ):
        raise NotionAdapterError("Notion row task database binding is invalid")
    if parent_kind != "data_source_id" and kind != "data_source" and database_id is not None:
        raise NotionAdapterError("Notion traversal database binding is unexpected")


def task_value(value: Any, limits: Limits) -> Task:
    if not isinstance(value, dict) or set(value) != TASK_KEYS:
        raise NotionAdapterError("Notion traversal task has an invalid shape")
    kind = value.get("kind")
    if kind not in TASK_KINDS:
        raise NotionAdapterError("Notion traversal task kind is unsupported")
    depth = bounded_integer(value.get("depth"), "task depth", 0, limits.max_depth)
    parent_kind, parent_id = _task_parent_binding(value)
    database_id = _optional_id(value.get("database_id"), "task database ID")
    _validate_task_binding(kind, parent_kind, parent_id, database_id)
    return Task(
        kind,
        notion_id(value.get("resource_id"), "task resource ID"),
        depth,
        _cursor_value(value.get("cursor")),
        parent_kind,
        parent_id,
        database_id,
    )


@dataclass(frozen=True)
class TraversalState:
    queue: tuple[Task, ...]
    scheduled: frozenset[str]
    pages: int
    blocks: int
    response_bytes: int


def _binding(workspace_id: str, roots: tuple[str, ...], limits: Limits, comments: bool) -> str:
    return hashlib.sha256(
        canonical_json(
            {
                "api_version": API_VERSION,
                "include_comments": comments,
                "limits": limits.payload(),
                "root_page_ids": list(roots),
                "workspace_id": workspace_id,
            }
        ).encode("utf-8")
    ).hexdigest()


def _account(account: dict[str, Any]) -> tuple[str, tuple[str, ...], Limits, bool, str]:
    workspace = notion_id(account.get("workspace_id"), "workspace ID")
    if notion_id(account.get("id"), "account ID") != workspace:
        raise NotionAdapterError("Notion workspace identity binding is invalid")
    roots = root_page_ids(account.get("root_page_ids"))
    limits = limits_value(account.get("limits"))
    comments = account.get("include_comments")
    if not isinstance(comments, bool):
        raise NotionAdapterError("Notion comment collection policy must be boolean")
    return workspace, roots, limits, comments, _binding(workspace, roots, limits, comments)


def _initial_state(roots: tuple[str, ...], limits: Limits) -> TraversalState:
    queue = tuple(Task("page", root, 0) for root in roots)
    return TraversalState(queue, frozenset(task.key() for task in queue), 0, 0, 0)


def _encode_state(state: TraversalState, binding: str) -> str:
    payload = {
        "binding": binding,
        "blocks": state.blocks,
        "pages": state.pages,
        "queue": [task.payload() for task in state.queue],
        "response_bytes": state.response_bytes,
        "scheduled": sorted(state.scheduled),
    }
    raw = canonical_json(payload).encode("utf-8")
    if len(raw) > MAX_CURSOR_BYTES:
        raise NotionAdapterError("Notion traversal checkpoint exceeds the safety limit")
    encoded = base64.urlsafe_b64encode(raw).decode("ascii").rstrip("=")
    return f"{CURSOR_PREFIX}{encoded}"


def _decode_state(cursor: str, binding: str, limits: Limits) -> TraversalState:
    if not cursor.startswith(CURSOR_PREFIX):
        raise NotionAdapterError("stored Notion cursor has an unsupported version")
    try:
        encoded = cursor.removeprefix(CURSOR_PREFIX)
        raw = base64.urlsafe_b64decode(encoded + "=" * (-len(encoded) % 4))
        if len(raw) > MAX_CURSOR_BYTES:
            raise ValueError("cursor too large")
        parsed = json.loads(raw)
    except (UnicodeError, ValueError, json.JSONDecodeError) as error:
        raise NotionAdapterError("stored Notion cursor is invalid") from error
    if not isinstance(parsed, dict) or set(parsed) != {
        "binding",
        "blocks",
        "pages",
        "queue",
        "response_bytes",
        "scheduled",
    }:
        raise NotionAdapterError("stored Notion cursor has an invalid shape")
    reject_credentials(parsed)
    if parsed.get("binding") != binding:
        raise NotionAdapterError("stored Notion cursor belongs to another root policy")
    queue_value = parsed.get("queue")
    scheduled_value = parsed.get("scheduled")
    if not isinstance(queue_value, list) or not isinstance(scheduled_value, list):
        raise NotionAdapterError("stored Notion traversal queue is invalid")
    queue = tuple(task_value(item, limits) for item in queue_value)
    scheduled = frozenset(scheduled_value)
    if any(not isinstance(item, str) or not item for item in scheduled_value):
        raise NotionAdapterError("stored Notion scheduled set is invalid")
    if len(scheduled) != len(scheduled_value) or any(task.key() not in scheduled for task in queue):
        raise NotionAdapterError("stored Notion scheduled set is inconsistent")
    pages = bounded_integer(parsed.get("pages"), "stored page count", 0, limits.max_pages)
    blocks = bounded_integer(parsed.get("blocks"), "stored block count", 0, limits.max_blocks)
    response_bytes = bounded_integer(
        parsed.get("response_bytes"), "stored byte count", 0, limits.max_bytes
    )
    return TraversalState(queue, scheduled, pages, blocks, response_bytes)


@dataclass(frozen=True)
class PageRequest:
    workspace_id: str
    root_page_ids: tuple[str, ...]
    limits: Limits
    include_comments: bool
    binding: str
    task: Task
    page_size: int

    def payload(self) -> dict[str, Any]:
        return {
            "action": "page",
            "binding": self.binding,
            "include_comments": self.include_comments,
            "limits": self.limits.payload(),
            "page_size": self.page_size,
            "root_page_ids": list(self.root_page_ids),
            "stream": "site_tree",
            "task": self.task.payload(),
            "workspace_id": self.workspace_id,
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())

    def digest(self) -> str:
        return hashlib.sha256(self.evidence_key().encode("utf-8")).hexdigest()


PAGE_REQUEST_KEYS = {
    "action",
    "binding",
    "include_comments",
    "limits",
    "page_size",
    "root_page_ids",
    "stream",
    "task",
    "workspace_id",
}


def page_request(
    stream: str, account: dict[str, Any], state: CursorState, limit: int
) -> PageRequest:
    if stream != "site_tree":
        raise NotionAdapterError("Notion stream is unsupported")
    workspace, roots, limits, comments, binding = _account(account)
    page_size = bounded_integer(limit, "page size", 1, 100)
    traversal = (
        _decode_state(state.cursor, binding, limits)
        if state.cursor
        else _initial_state(roots, limits)
    )
    if not traversal.queue:
        raise NotionAdapterError("Notion traversal checkpoint is already complete")
    return PageRequest(
        workspace, roots, limits, comments, binding, traversal.queue[0], page_size
    )


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    if set(payload) != PAGE_REQUEST_KEYS or payload.get("action") != "page":
        raise NotionAdapterError("Notion read request has an invalid action shape")
    if payload.get("stream") != "site_tree":
        raise NotionAdapterError("Notion stream is unsupported")
    workspace = notion_id(payload.get("workspace_id"), "workspace ID")
    roots = root_page_ids(payload.get("root_page_ids"))
    limits = limits_value(payload.get("limits"))
    comments = payload.get("include_comments")
    if not isinstance(comments, bool):
        raise NotionAdapterError("Notion comment collection policy must be boolean")
    binding = _binding(workspace, roots, limits, comments)
    if payload.get("binding") != binding:
        raise NotionAdapterError("Notion request root binding is invalid")
    page_size = bounded_integer(payload.get("page_size"), "page size", 1, 100)
    return PageRequest(
        workspace,
        roots,
        limits,
        comments,
        binding,
        task_value(payload.get("task"), limits),
        page_size,
    )


from _knowledge_social_notion_checkpoint import page_checkpoint, page_data, response_status
