#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Redirect-free Hashnode transport for exact allowlisted read queries."""

from __future__ import annotations

import json
import math
import re
import time
from dataclasses import dataclass
from typing import Any, Protocol
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener

from _knowledge_social_hashnode_contract import (
    ApiResult,
    HashnodeReadProviderError,
    decode_json,
)
from _knowledge_social_hashnode_routes import ALLOWED_QUERIES, QUERY_VARIABLES
from knowledge_social_import import reject_credentials

GRAPHQL_URL = "https://gql-beta.hashnode.com/"
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_REQUEST_BYTES = 100 * 1024
HTTP_TIMEOUT_SECONDS = 60
OPERATION = re.compile(r"^query\s+AidevopsHashnode[A-Za-z0-9_]*\b")


class Headers(Protocol):
    def get(self, key: str, default: str | None = None) -> str | None: ...


class Response(Protocol):
    status: int
    headers: Headers

    def __enter__(self) -> Response: ...
    def __exit__(self, *args: Any) -> None: ...
    def read(self, size: int = -1) -> bytes: ...


class Opener(Protocol):
    def open(self, request: Request, timeout: int) -> Response: ...


@dataclass(frozen=True)
class ProfileConfig:
    personal_access_token: str


class _RejectRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


def _http_exports() -> Opener:
    exports = (Request, build_opener, HTTPRedirectHandler)
    if not all(callable(item) for item in exports):
        raise HashnodeReadProviderError("Python urllib HTTP exports are unavailable")
    return build_opener(_RejectRedirect())


def _retry_epoch(value: str | None) -> int | None:
    if value is None:
        return None
    try:
        seconds = float(value)
    except (TypeError, ValueError):
        return None
    if not math.isfinite(seconds) or seconds < 0:
        return None
    return int(time.time() + math.ceil(seconds))


def _headers(config: ProfileConfig) -> dict[str, str]:
    return {
        "Accept": "application/json",
        "Authorization": f"Bearer {config.personal_access_token}",
        "Content-Type": "application/json",
        "User-Agent": "aidevops-hashnode-knowledge/1",
    }


def _validate_variables(query: str, variables: dict[str, Any]) -> None:
    if set(variables) != QUERY_VARIABLES[query]:
        raise HashnodeReadProviderError("Hashnode GraphQL variables are not allowlisted")
    reject_credentials(variables)
    for key, value in variables.items():
        if key == "first":
            if isinstance(value, bool) or not isinstance(value, int) or not 1 <= value <= 50:
                raise HashnodeReadProviderError("Hashnode GraphQL page size is invalid")
        elif value is not None:
            if not isinstance(value, str) or not value or "\x00" in value:
                raise HashnodeReadProviderError("Hashnode GraphQL variable is invalid")
            if len(value.encode()) > 64 * 1024:
                raise HashnodeReadProviderError("Hashnode GraphQL variable is invalid")


def _request_body(query: str, variables: dict[str, Any]) -> bytes:
    if query not in ALLOWED_QUERIES:
        raise HashnodeReadProviderError("Hashnode GraphQL query is not allowlisted")
    normalized = " ".join(query.split())
    if (
        OPERATION.match(normalized) is None
        or re.search(r"\b(?:mutation|subscription)\b", normalized, re.IGNORECASE)
    ):
        raise HashnodeReadProviderError("Hashnode GraphQL operation is not a read query")
    _validate_variables(query, variables)
    body = json.dumps(
        {"query": query, "variables": variables}, sort_keys=True, separators=(",", ":")
    ).encode()
    if len(body) > MAX_REQUEST_BYTES:
        raise HashnodeReadProviderError("Hashnode GraphQL request exceeds the safety limit")
    return body


def _decode_response(payload: bytes) -> dict[str, Any]:
    decoded = decode_json(payload, MAX_RESPONSE_BYTES)
    if not isinstance(decoded, dict):
        raise HashnodeReadProviderError("Hashnode API response root must be an object")
    reject_credentials(decoded)
    return decoded


def _execute(opener: Opener, request: Request) -> tuple[int, dict[str, Any], Headers]:
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            status = getattr(response, "status", 200)
            if isinstance(status, bool) or not isinstance(status, int):
                raise HashnodeReadProviderError("Hashnode HTTP status is invalid")
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if not isinstance(payload, bytes):
                raise HashnodeReadProviderError("Hashnode HTTP response is invalid")
            return status, _decode_response(payload), response.headers
    except HTTPError as error:
        headers = error.headers if error.headers is not None else _ErrorHeaders()
        return error.code, {}, headers
    except (TimeoutError, URLError, OSError) as error:
        raise HashnodeReadProviderError("Hashnode read provider request failed") from error


class _ErrorHeaders:
    def get(self, key: str, default: str | None = None) -> str | None:
        del key
        return default


def _graphql_error_status(payload: dict[str, Any]) -> int | None:
    errors = payload.get("errors")
    if errors is None or errors == []:
        return None
    if not isinstance(errors, list) or any(not isinstance(item, dict) for item in errors):
        return 500
    statuses = []
    mapping = {
        "UNAUTHENTICATED": 401,
        "FORBIDDEN": 403,
        "NOT_FOUND": 404,
        "BAD_USER_INPUT": 400,
        "INTERNAL_SERVER_ERROR": 500,
    }
    for item in errors:
        extensions = item.get("extensions")
        if not isinstance(extensions, dict):
            statuses.append(500)
            continue
        code = extensions.get("code")
        statuses.append(mapping.get(code, 500) if isinstance(code, str) else 500)
    for status in (401, 403, 429, 500, 404, 400):
        if status in statuses:
            return status
    return 500


def graphql_api(
    config: ProfileConfig,
    opener: Opener,
    query: str,
    variables: dict[str, Any],
) -> ApiResult:
    """Execute one exact read query; mutations and redirects are unreachable."""
    request = Request(
        GRAPHQL_URL,
        data=_request_body(query, variables),
        headers=_headers(config),
        method="POST",
    )
    status, payload, headers = _execute(opener, request)
    retry_after = _retry_epoch(headers.get("Retry-After"))
    if status != 200:
        return ApiResult(status, {}, retry_after)
    graph_status = _graphql_error_status(payload)
    if graph_status is not None:
        return ApiResult(graph_status, {}, retry_after)
    return ApiResult(200, payload, retry_after)
