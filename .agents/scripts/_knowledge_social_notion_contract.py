#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Response validation and redaction for official Notion API reads."""

from __future__ import annotations

import json
import re
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_notion_identity import NotionAdapterError, notion_id

MAX_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_TEXT_BYTES = 512 * 1024
MAX_FILES_PER_RESPONSE = 1_000
CREDENTIAL_VALUE = re.compile(
    r"(?i)(?:^|[?&;\s])(?:access[_-]?token|api[_-]?key|authorization|"
    r"client[_-]?secret|password|secret|session[_-]?token)\s*[=:]\s*[^\s&;]{4,}"
)
JWT_VALUE = re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b")


class NotionReadProviderError(RuntimeError):
    """Raised for a privacy-safe local Notion provider failure."""


@dataclass(frozen=True)
class ApiResult:
    status: int
    payload: Any
    response_bytes: int = 0
    retry_after: int | None = None


def observed_at() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def decode_json(payload: bytes) -> Any:
    if len(payload) > MAX_RESPONSE_BYTES:
        raise NotionReadProviderError("Notion JSON payload exceeds the safety limit")
    try:
        return json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise NotionReadProviderError("Notion JSON payload is invalid") from error


def object_value(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise NotionReadProviderError(f"Notion {field} must be an object")
    return value


def list_value(value: Any, field: str, limit: int) -> list[dict[str, Any]]:
    if (
        not isinstance(value, list)
        or len(value) > limit
        or any(not isinstance(item, dict) for item in value)
    ):
        raise NotionReadProviderError(f"Notion {field} must be a bounded object array")
    return value


def optional_text(value: Any, field: str, *, maximum: int = MAX_TEXT_BYTES) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value:
        raise NotionReadProviderError(f"Notion {field} must be text")
    if len(value.encode("utf-8")) > maximum:
        raise NotionReadProviderError(f"Notion {field} exceeds the text safety limit")
    if CREDENTIAL_VALUE.search(value) or JWT_VALUE.search(value):
        raise NotionReadProviderError("Notion response contains credential-shaped text")
    return value


def _walk_text(value: Any, output: list[str]) -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if key == "plain_text":
                text = optional_text(child, "rich text")
                if text:
                    output.append(text)
            elif key not in {"url", "href", "public_url"}:
                _walk_text(child, output)
    elif isinstance(value, list):
        for child in value:
            _walk_text(child, output)


def plain_text(value: Any) -> str | None:
    """Extract only provider-rendered plain text, never links or HTML."""
    pieces: list[str] = []
    _walk_text(value, pieces)
    rendered = "\n".join(piece for piece in pieces if piece).strip()
    if not rendered:
        return None
    if len(rendered.encode("utf-8")) > MAX_TEXT_BYTES:
        raise NotionReadProviderError("Notion rendered text exceeds the safety limit")
    return rendered


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
        return {
            "disposition": "external_target_not_fetched",
            "kind": "external",
        }
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
        normalized = {
            "type": kind,
            kind: notion_id(parent.get(kind), f"{kind} parent"),
        }
        if kind == "data_source_id":
            normalized["database_id"] = notion_id(
                parent.get("database_id"), "data source parent database ID"
            )
    else:
        raise NotionReadProviderError("Notion parent type is unsupported")
    if expected_kind is not None:
        if normalized.get("type") != expected_kind or normalized.get(expected_kind) != expected_id:
            raise NotionReadProviderError(
                "Notion response escaped the authorized parent binding"
            )
    if database_id is not None and normalized.get("database_id") != database_id:
        raise NotionReadProviderError("Notion response database binding changed")
    return normalized


def terminal_payload(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "observed_at": observed_at(),
        "response_bytes": result.response_bytes,
        "status": result.status,
    }
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload
