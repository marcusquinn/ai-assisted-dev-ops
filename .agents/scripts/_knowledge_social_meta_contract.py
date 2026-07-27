#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation and redaction for the bounded Meta Graph subprocess."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any
from urllib.parse import parse_qs, urlsplit

from _knowledge_social_meta import (
    MetaAdapterError,
    ProductSpec,
    StreamSpec,
    account_id,
    graph_id,
    provider_cursor,
)
from knowledge_social_import import canonical_json, reject_credentials

MAX_TEXT_BYTES = 256 * 1024
MAX_ITEM_BYTES = 512 * 1024


class MetaReadProviderError(RuntimeError):
    """Raised for a privacy-safe local Meta provider failure."""


@dataclass(frozen=True)
class ApiResult:
    """One bounded HTTP result without provider error-body disclosure."""

    status: int
    payload: dict[str, Any]
    retry_after: int | None = None


def observed_at() -> str:
    """Return a stable UTC timestamp for one provider response."""
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def exact_keys(request: dict[str, Any], expected: set[str]) -> None:
    """Reject parent requests outside the allowlisted read contract."""
    if set(request) != expected:
        raise MetaReadProviderError("Meta read request has an invalid action shape")


def bounded_text(value: Any, field: str) -> str:
    """Validate bounded provider text without exposing its content in errors."""
    if not isinstance(value, str) or not value or "\x00" in value:
        raise MetaReadProviderError(f"Meta {field} is invalid")
    if len(value.encode("utf-8")) > MAX_TEXT_BYTES:
        raise MetaReadProviderError(f"Meta {field} exceeds the safety limit")
    return value


def stable_graph_id(value: Any, field: str) -> str:
    """Translate shared Graph-ID validation into the child error boundary."""
    try:
        return graph_id(value, field)
    except MetaAdapterError as error:
        raise MetaReadProviderError(str(error)) from error


def stable_account_id(value: Any, field: str) -> str:
    """Translate strict account-ID validation into the child error boundary."""
    try:
        return account_id(value, field)
    except MetaAdapterError as error:
        raise MetaReadProviderError(str(error)) from error


def terminal_payload(result: ApiResult) -> dict[str, Any]:
    """Build a sanitized terminal response envelope."""
    payload: dict[str, Any] = {"status": result.status, "observed_at": observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload


def _record(value: Any, fields: tuple[str, ...], field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise MetaReadProviderError(f"Meta {field} must be an object")
    reject_credentials(value)
    selected = {name: value[name] for name in fields if name in value}
    if len(canonical_json(selected).encode("utf-8")) > MAX_ITEM_BYTES:
        raise MetaReadProviderError(f"Meta {field} exceeds the safety limit")
    stable_graph_id(selected.get("id"), f"{field} ID")
    return selected


def identity_payload(
    result: ApiResult, spec: ProductSpec, expected_id: str
) -> dict[str, Any]:
    """Allowlist and bind one product identity to the configured account."""
    if result.status != 200:
        return terminal_payload(result)
    identity = _record(result.payload, spec.identity_fields, "identity")
    expected = stable_account_id(expected_id, "account ID")
    actual = stable_account_id(identity.get("id"), "identity account ID")
    if actual != expected:
        raise MetaReadProviderError(
            f"selected {spec.product} account does not match the configured connection"
        )
    identity["product"] = spec.product
    return {"status": 200, "observed_at": observed_at(), "data": identity}


def _next_cursor(
    paging: Any,
    spec: ProductSpec,
    stream: StreamSpec,
    account_id: str,
) -> str | None:
    if paging is None:
        return None
    if not isinstance(paging, dict):
        raise MetaReadProviderError("Meta paging metadata must be an object")
    next_url = paging.get("next")
    if next_url is None:
        return None
    if not isinstance(next_url, str) or len(next_url.encode("utf-8")) > 8192:
        raise MetaReadProviderError("Meta next-page URL is invalid")
    parsed = urlsplit(next_url)
    base = urlsplit(spec.api_base)
    expected_leaf = account_id if spec.identity_path == "account" else "me"
    expected_path = f"{base.path}/{expected_leaf}/{stream.edge}"
    if parsed.scheme != "https":
        raise MetaReadProviderError("Meta next-page URL is outside the allowlisted edge")
    if parsed.hostname not in spec.paging_hosts:
        raise MetaReadProviderError("Meta next-page URL is outside the allowlisted edge")
    if parsed.username is not None:
        raise MetaReadProviderError("Meta next-page URL is outside the allowlisted edge")
    if parsed.password is not None:
        raise MetaReadProviderError("Meta next-page URL is outside the allowlisted edge")
    if parsed.fragment:
        raise MetaReadProviderError("Meta next-page URL is outside the allowlisted edge")
    if parsed.path != expected_path:
        raise MetaReadProviderError("Meta next-page URL is outside the allowlisted edge")
    query = parse_qs(parsed.query, keep_blank_values=True)
    cursors = paging.get("cursors")
    if not isinstance(cursors, dict):
        raise MetaReadProviderError("Meta paging cursors must be an object")
    after = cursors.get("after")
    try:
        cursor = provider_cursor(after)
    except MetaAdapterError as error:
        raise MetaReadProviderError(str(error)) from error
    if query.get("after") != [cursor]:
        raise MetaReadProviderError("Meta next-page cursor does not match paging metadata")
    return cursor


def page_payload(
    result: ApiResult,
    spec: ProductSpec,
    stream_name: str,
    account_id: str,
    limit: int,
) -> dict[str, Any]:
    """Allowlist one Graph page and discard provider paging URLs and tokens."""
    if result.status != 200:
        return terminal_payload(result)
    if stream_name not in spec.streams:
        raise MetaReadProviderError("Meta read stream is unsupported")
    stream = spec.streams[stream_name]
    raw_data = result.payload.get("data")
    if not isinstance(raw_data, list):
        raise MetaReadProviderError("Meta page data must be an array")
    if len(raw_data) > limit:
        raise MetaReadProviderError("Meta page exceeds the requested item limit")
    data = [_record(item, stream.fields, "page item") for item in raw_data]
    cursor = _next_cursor(result.payload.get("paging"), spec, stream, account_id)
    payload = {
        "status": 200,
        "observed_at": observed_at(),
        "data": data,
        "meta": {
            "product": spec.product,
            "stream": stream_name,
            "next_cursor": cursor,
            "complete": cursor is None,
        },
    }
    reject_credentials(payload)
    return payload


def decode_response(payload: bytes) -> dict[str, Any]:
    """Decode one already size-bounded Graph response object."""
    try:
        value = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise MetaReadProviderError("Meta HTTP response is not valid JSON") from error
    if not isinstance(value, dict):
        raise MetaReadProviderError("Meta HTTP response root must be an object")
    return value
