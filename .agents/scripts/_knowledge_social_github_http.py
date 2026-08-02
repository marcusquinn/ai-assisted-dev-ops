#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Redirect-free, bounded GitHub REST reads and fixed GraphQL queries."""

from __future__ import annotations

import json
import math
import re
import time
from dataclasses import dataclass
from typing import Any, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import SplitResult, parse_qsl, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from _knowledge_social_github_contract import (
    ApiResult,
    GitHubReadProviderError,
    decode_json,
)
from _knowledge_social_github_routes import allowlisted_path, query_keys_for_path

REST_ORIGIN = "https://api.github.com"
GRAPHQL_URL = f"{REST_ORIGIN}/graphql"
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
HTTP_TIMEOUT_SECONDS = 60


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
    access_token: str
    token_family: str
    scopes: frozenset[str]


class _RejectRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


def _http_exports() -> Opener:
    exports = (Request, build_opener, urlencode, urlsplit, HTTPRedirectHandler)
    if not all(callable(item) for item in exports):
        raise GitHubReadProviderError("Python urllib HTTP exports are unavailable")
    return build_opener(_RejectRedirect())


def _parsed_url(value: str) -> SplitResult:
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise GitHubReadProviderError("GitHub API URL is invalid") from error
    if (
        parsed.scheme != "https"
        or parsed.hostname != "api.github.com"
        or port not in (None, 443)
        or parsed.username is not None
        or parsed.password is not None
        or parsed.fragment
    ):
        raise GitHubReadProviderError("GitHub API URL is not allowlisted")
    return parsed


def _validate_query(path: str, query: str) -> None:
    try:
        pairs = parse_qsl(query, keep_blank_values=True, strict_parsing=True)
    except ValueError as error:
        raise GitHubReadProviderError("GitHub pagination query is invalid") from error
    allowed = query_keys_for_path(path)
    if len(pairs) != len({key for key, _value in pairs}):
        raise GitHubReadProviderError("GitHub pagination query is invalid")
    for key, value in pairs:
        if key not in allowed or not value or "\x00" in value:
            raise GitHubReadProviderError("GitHub pagination query is not allowlisted")
        if key == "per_page" and (not value.isdigit() or not 1 <= int(value) <= 100):
            raise GitHubReadProviderError("GitHub pagination limit is invalid")


def _rest_url(target: str, params: dict[str, str]) -> str:
    if target.startswith("/"):
        if not allowlisted_path(target) or set(params) - query_keys_for_path(target):
            raise GitHubReadProviderError("GitHub REST route is not allowlisted")
        if any(not value or "\x00" in value for value in params.values()):
            raise GitHubReadProviderError("GitHub REST query is invalid")
        query = urlencode(params)
        _validate_query(target, query)
        return f"{REST_ORIGIN}{target}" + (f"?{query}" if query else "")
    if params:
        raise GitHubReadProviderError("GitHub opaque next link cannot be rewritten")
    parsed = _parsed_url(target)
    if not allowlisted_path(parsed.path):
        raise GitHubReadProviderError("GitHub pagination link route is not allowlisted")
    _validate_query(parsed.path, parsed.query)
    return target


def _next_link(header: str | None) -> str | None:
    if not header:
        return None
    for match in re.finditer(r"<([^<>]+)>\s*;([^,]*)", header):
        target, attributes = match.groups()
        relation = re.search(r'(?:^|;)\s*rel\s*=\s*"?([^";,\s]+)', attributes)
        if relation is not None and relation.group(1) == "next":
            return _rest_url(target, {})
    return None


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


def _rate_reset(headers: Headers) -> int | None:
    retry = _retry_epoch(headers.get("Retry-After"))
    if retry is not None:
        return retry
    reset = headers.get("X-RateLimit-Reset")
    if reset is None or not reset.isdigit():
        return None
    epoch = int(reset)
    return epoch if epoch >= 0 else None


def _decode_response(payload: bytes) -> Any:
    decoded = decode_json(payload, MAX_RESPONSE_BYTES)
    if not isinstance(decoded, (dict, list)):
        raise GitHubReadProviderError("GitHub API response root must be an object or array")
    return decoded


def _execute(opener: Opener, request: Request) -> tuple[int, Any, Headers]:
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            status = getattr(response, "status", 200)
            if isinstance(status, bool) or not isinstance(status, int):
                raise GitHubReadProviderError("GitHub HTTP status is invalid")
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if not isinstance(payload, bytes):
                raise GitHubReadProviderError("GitHub HTTP response is invalid")
            return status, _decode_response(payload), response.headers
    except HTTPError as error:
        headers = error.headers if error.headers is not None else _ErrorHeaders()
        return error.code, {}, headers
    except (TimeoutError, URLError, OSError) as error:
        raise GitHubReadProviderError("GitHub read provider request failed") from error


class _ErrorHeaders:
    def get(self, key: str, default: str | None = None) -> str | None:
        del key
        return default


def _headers(config: ProfileConfig) -> dict[str, str]:
    return {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {config.access_token}",
        "User-Agent": "aidevops-github-knowledge/1",
        "X-GitHub-Api-Version": "2022-11-28",
    }


def rest_api(
    config: ProfileConfig, opener: Opener, target: str, params: dict[str, str]
) -> ApiResult:
    """Execute one allowlisted GitHub REST GET without following redirects."""
    request = Request(_rest_url(target, params), headers=_headers(config), method="GET")
    status, payload, headers = _execute(opener, request)
    return ApiResult(
        status,
        payload,
        _next_link(headers.get("Link")) if status == 200 else None,
        _rate_reset(headers),
    )


def graphql_api(
    config: ProfileConfig,
    opener: Opener,
    query: str,
    variables: dict[str, Any],
) -> ApiResult:
    """Execute one fixed read query; mutations and subscriptions are unreachable."""
    normalized = " ".join(query.split()).casefold()
    if not normalized.startswith("query ") or " mutation " in f" {normalized} " or " subscription " in f" {normalized} ":
        raise GitHubReadProviderError("GitHub GraphQL operation is not a read query")
    body = json.dumps({"query": query, "variables": variables}, sort_keys=True).encode()
    if len(body) > 64 * 1024:
        raise GitHubReadProviderError("GitHub GraphQL request exceeds the safety limit")
    headers = _headers(config)
    headers["Content-Type"] = "application/json"
    request = Request(GRAPHQL_URL, data=body, headers=headers, method="POST")
    status, payload, response_headers = _execute(opener, request)
    return ApiResult(status, payload, retry_after=_rate_reset(response_headers))
