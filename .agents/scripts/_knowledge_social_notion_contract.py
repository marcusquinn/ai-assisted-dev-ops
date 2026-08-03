#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Response validation and redaction for official Notion API reads."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_notion_files import file_descriptors, parent_value
from _knowledge_social_notion_values import (
    NotionReadProviderError,
    list_value,
    object_value,
    optional_text,
    plain_text,
)

MAX_RESPONSE_BYTES = 8 * 1024 * 1024


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


def terminal_payload(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "observed_at": observed_at(),
        "response_bytes": result.response_bytes,
        "status": result.status,
    }
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload
