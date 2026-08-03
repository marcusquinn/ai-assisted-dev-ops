#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""URL-free Notion file metadata and authorized parent validation."""

from __future__ import annotations

from typing import Any

from _knowledge_social_notion_identity import notion_id
from _knowledge_social_notion_values import (
    NotionReadProviderError,
    object_value,
    optional_text,
)

MAX_FILES_PER_RESPONSE = 1_000


def _file_descriptor(value: dict[str, Any]) -> dict[str, Any] | None:
    file_type = value.get("type")
    if file_type == "file":
        source = object_value(value.get("file"), "hosted file")
        optional_text(source.get("url"), "hosted file URL", maximum=16 * 1024)
        return {
            "disposition": "metadata_only_not_fetched",
            "expiry_time": optional_text(source.get("expiry_time"), "file expiry", maximum=128),
            "kind": "notion_hosted",
        }
    if file_type == "external":
        source = object_value(value.get("external"), "external file")
        optional_text(source.get("url"), "external file URL", maximum=16 * 1024)
        return {"disposition": "external_target_not_fetched", "kind": "external"}
    if file_type == "file_upload":
        source = object_value(value.get("file_upload"), "file upload")
        return {
            "disposition": "metadata_only_not_fetched",
            "id": notion_id(source.get("id"), "file upload ID"),
            "kind": "file_upload",
        }
    return None


def _walk_files(value: Any, output: list[dict[str, Any]]) -> None:
    if isinstance(value, dict):
        descriptor = _file_descriptor(value)
        if descriptor is not None:
            output.append(descriptor)
            return
        for key, child in value.items():
            if key not in {"url", "href", "public_url"}:
                _walk_files(child, output)
    elif isinstance(value, list):
        for child in value:
            _walk_files(child, output)


def file_descriptors(value: Any) -> list[dict[str, Any]]:
    """Return URL-free file metadata and reject credential-shaped source URLs."""
    files: list[dict[str, Any]] = []
    _walk_files(value, files)
    if len(files) > MAX_FILES_PER_RESPONSE:
        raise NotionReadProviderError("Notion response contains too many file references")
    return files


def parent_value(
    value: Any,
    expected_kind: str | None = None,
    expected_id: str | None = None,
    database_id: str | None = None,
) -> dict[str, Any]:
    parent = object_value(value, "parent")
    kind = parent.get("type")
    if kind == "workspace":
        if parent.get("workspace") is not True:
            raise NotionReadProviderError("Notion workspace parent is invalid")
        normalized: dict[str, Any] = {"type": "workspace"}
    elif kind in {"page_id", "block_id", "database_id", "data_source_id"}:
        normalized = {"type": kind, kind: notion_id(parent.get(kind), f"{kind} parent")}
        if kind == "data_source_id":
            normalized["database_id"] = notion_id(
                parent.get("database_id"), "data source parent database ID"
            )
    else:
        raise NotionReadProviderError("Notion parent type is unsupported")
    if expected_kind is not None and (
        normalized.get("type") != expected_kind or normalized.get(expected_kind) != expected_id
    ):
        raise NotionReadProviderError("Notion response escaped the authorized parent binding")
    if database_id is not None and normalized.get("database_id") != database_id:
        raise NotionReadProviderError("Notion response database binding changed")
    return normalized
