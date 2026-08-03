#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate Notion traversal results and advance durable queue checkpoints."""

from __future__ import annotations

from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from _knowledge_social_notion_identity import NotionAdapterError
from knowledge_social_import import reject_credentials


def response_status(payload: dict[str, Any]) -> int:
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise NotionAdapterError("Notion response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise NotionAdapterError("Notion page data must be an array")
    return data


def _nonnegative(meta: dict[str, Any], key: str) -> int:
    value = meta.get(key)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise NotionAdapterError(f"Notion {key} metadata is invalid")
    return value


def _page_discovery_valid(current: Any, candidate: Any) -> bool:
    return (
        candidate.depth == current.depth
        and candidate.resource_id == current.resource_id
        and candidate.kind in {"blocks", "comments"}
        and candidate.parent_kind is None
    )


def _block_discovery_valid(current: Any, candidate: Any) -> bool:
    parent_valid = (
        candidate.parent_kind == "block_id"
        if candidate.kind == "comments"
        else candidate.parent_kind in {"page_id", "block_id"}
    )
    return (
        candidate.depth == current.depth + 1
        and candidate.kind in {"blocks", "comments", "page", "database"}
        and candidate.parent_id == current.resource_id
        and parent_valid
    )


def _database_discovery_valid(current: Any, candidate: Any) -> bool:
    return all(
        (
            candidate.depth == current.depth,
            candidate.kind == "data_source",
            candidate.parent_kind == "database_id",
            candidate.database_id == current.resource_id,
            candidate.parent_id == current.resource_id,
        )
    )


def _data_source_discovery_valid(current: Any, candidate: Any) -> bool:
    return all(
        (
            candidate.depth == current.depth + 1,
            candidate.kind in {"blocks", "comments"},
            candidate.parent_kind == "data_source_id",
            candidate.parent_id == current.resource_id,
            candidate.database_id == current.database_id,
        )
    )


def _validate_discovery(current: Any, candidate: Any) -> None:
    validators = {
        "page": _page_discovery_valid,
        "blocks": _block_discovery_valid,
        "database": _database_discovery_valid,
        "data_source": _data_source_discovery_valid,
    }
    validator = validators.get(current.kind)
    if validator is None or not validator(current, candidate):
        raise NotionAdapterError("Notion traversal attempted to escape its authorized descendants")


def _metadata(payload: dict[str, Any], request: Any) -> tuple[Any, ...]:
    from _knowledge_social_notion import _cursor_value, task_value

    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise NotionAdapterError("Notion page metadata must be an object")
    reject_credentials(meta)
    if meta.get("request_sha256") != request.digest() or meta.get("task") != request.task.payload():
        raise NotionAdapterError("Notion page provenance is invalid")
    if meta.get("request_status", "complete") != "complete":
        raise NotionAdapterError("Notion returned an incomplete result set")
    limit_reason = meta.get("limit_reason")
    if limit_reason is not None:
        if limit_reason not in {"blocks", "bytes", "depth", "pages", "queue"}:
            raise NotionAdapterError("Notion traversal limit reason is invalid")
        raise NotionAdapterError(f"Notion {limit_reason} safety limit exhausted")
    next_cursor = _cursor_value(meta.get("next_cursor"))
    if next_cursor is not None and next_cursor == request.task.cursor:
        raise NotionAdapterError("Notion pagination cursor did not advance")
    discoveries_value = meta.get("discoveries", [])
    if not isinstance(discoveries_value, list):
        raise NotionAdapterError("Notion traversal discoveries are invalid")
    discoveries = tuple(task_value(item, request.limits) for item in discoveries_value)
    for candidate in discoveries:
        _validate_discovery(request.task, candidate)
    return (
        next_cursor,
        discoveries,
        _nonnegative(meta, "page_count"),
        _nonnegative(meta, "block_count"),
        _nonnegative(meta, "response_bytes"),
    )


def _continued_task(request: Any, next_cursor: str) -> Any:
    from _knowledge_social_notion import Task

    task = request.task
    return Task(
        task.kind,
        task.resource_id,
        task.depth,
        next_cursor,
        task.parent_kind,
        task.parent_id,
        task.database_id,
    )


def _bounded_totals(traversal: Any, request: Any, counts: tuple[int, int, int]) -> tuple[int, int, int]:
    total_pages = traversal.pages + counts[0]
    total_blocks = traversal.blocks + counts[1]
    total_bytes = traversal.response_bytes + counts[2]
    if total_pages > request.limits.max_pages:
        raise NotionAdapterError("Notion pages safety limit exhausted")
    if total_blocks > request.limits.max_blocks:
        raise NotionAdapterError("Notion blocks safety limit exhausted")
    if total_bytes > request.limits.max_bytes:
        raise NotionAdapterError("Notion bytes safety limit exhausted")
    return total_pages, total_blocks, total_bytes


def page_checkpoint(
    payload: dict[str, Any], state: CursorState, request: Any
) -> tuple[PageCheckpoint, bool]:
    from _knowledge_social_notion import (
        TraversalState,
        _decode_state,
        _encode_state,
        _initial_state,
    )

    data = page_data(payload)
    if len(data) > request.page_size:
        raise NotionAdapterError("Notion response exceeds the configured page size")
    traversal = (
        _decode_state(state.cursor, request.binding, request.limits)
        if state.cursor
        else _initial_state(request.root_page_ids, request.limits)
    )
    if not traversal.queue or traversal.queue[0] != request.task:
        raise NotionAdapterError("Notion response does not match the durable queue head")
    next_cursor, discoveries, pages, blocks, response_bytes = _metadata(payload, request)
    totals = _bounded_totals(traversal, request, (pages, blocks, response_bytes))
    queue = list(traversal.queue[1:])
    scheduled = set(traversal.scheduled)
    if next_cursor is not None:
        queue.insert(0, _continued_task(request, next_cursor))
    for candidate in discoveries:
        if candidate.key() not in scheduled:
            queue.append(candidate)
            scheduled.add(candidate.key())
    maximum_tasks = request.limits.max_pages + request.limits.max_blocks * 3 + 100
    if len(scheduled) > maximum_tasks:
        raise NotionAdapterError("Notion queue safety limit exhausted")
    next_state = TraversalState(tuple(queue), frozenset(scheduled), *totals)
    complete = not next_state.queue
    cursor = None if complete else _encode_state(next_state, request.binding)
    return PageCheckpoint(cursor, request.binding), complete
