#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact-origin, redirect-free HTTP transport for Mastodon account reads."""

from __future__ import annotations

import hashlib
import hmac
import math
import re
import time
from dataclasses import dataclass
from typing import Any, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import SplitResult, parse_qsl, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from _knowledge_social_mastodon_contract import (
    ApiResult,
    MastodonReadProviderError,
    decode_json,
)
from _knowledge_social_mastodon_routes import (
    allowlisted_path,
    page_limit_for_path,
    query_keys_for_path,
)

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
    base_url: str
    access_token: str
    auth_mode: str
    instance_id: str
    scopes: frozenset[str]


class _RejectRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


def _parsed_url(value: str) -> tuple[SplitResult, int | None]:
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise MastodonReadProviderError("Mastodon profile base URL is invalid") from error
    return parsed, port


def _canonical_base_url(value: str) -> str:
    parsed, port = _parsed_url(value)
    checks = (
        parsed.scheme.lower() == "https",
        parsed.hostname is not None,
        parsed.username is None,
        parsed.password is None,
        parsed.path in ("", "/"),
        not parsed.query,
        not parsed.fragment,
    )
    if not all(checks):
        raise MastodonReadProviderError("Mastodon profile base URL must be an HTTPS origin")
    host = parsed.hostname or ""
    rendered = f"[{host.lower()}]" if ":" in host else host.lower()
    if port is not None and port != 443:
        rendered = f"{rendered}:{port}"
    return f"https://{rendered}"


def installation_fingerprint(base_url: str, origin_key: str) -> str:
    canonical = _canonical_base_url(base_url)
    key = origin_key.encode()
    if len(key) < 32:
        raise MastodonReadProviderError(
            "Mastodon profile origin key must be at least 32 bytes"
        )
    return hmac.new(key, canonical.encode(), hashlib.sha256).hexdigest()[:24]


def _http_exports() -> Opener:
    exports = (Request, build_opener, urlencode, urlsplit, HTTPRedirectHandler)
    if not all(callable(item) for item in exports):
        raise MastodonReadProviderError("Python urllib HTTP exports are unavailable")
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


def _decode_response(payload: bytes) -> Any:
    decoded = decode_json(payload, MAX_RESPONSE_BYTES)
    if not isinstance(decoded, (dict, list)):
        raise MastodonReadProviderError(
            "Mastodon API response root must be an object or array"
        )
    return decoded


def _same_origin(config: ProfileConfig, parsed: SplitResult) -> bool:
    base = urlsplit(config.base_url)
    checks = (
        parsed.scheme.lower() == base.scheme,
        parsed.hostname == base.hostname,
        parsed.port == base.port,
        parsed.username is None,
        parsed.password is None,
        not parsed.fragment,
    )
    return all(checks)


def _validate_query(path: str, query: str) -> None:
    allowed = query_keys_for_path(path)
    try:
        pairs = parse_qsl(query, keep_blank_values=True, strict_parsing=True)
    except ValueError as error:
        raise MastodonReadProviderError("Mastodon pagination query is invalid") from error
    if len(pairs) != len({key for key, _value in pairs}):
        raise MastodonReadProviderError("Mastodon pagination query is invalid")
    if any(key not in allowed or not value or "\x00" in value for key, value in pairs):
        raise MastodonReadProviderError("Mastodon pagination query is not allowlisted")
    for key, value in pairs:
        if key == "limit" and (
            not value.isdigit() or not 1 <= int(value) <= page_limit_for_path(path)
        ):
            raise MastodonReadProviderError("Mastodon pagination limit is invalid")


def _target_url(config: ProfileConfig, target: str, params: dict[str, str]) -> str:
    if target.startswith("/"):
        if not allowlisted_path(target) or set(params) - query_keys_for_path(target):
            raise MastodonReadProviderError("Mastodon API route is not allowlisted")
        if any(not isinstance(value, str) or not value or "\x00" in value for value in params.values()):
            raise MastodonReadProviderError("Mastodon API query is invalid")
        query = urlencode(params)
        _validate_query(target, query)
        return f"{config.base_url}{target}" + (f"?{query}" if query else "")
    if params:
        raise MastodonReadProviderError("Mastodon opaque next link cannot be rewritten")
    parsed, _port = _parsed_url(target)
    if not _same_origin(config, parsed) or not allowlisted_path(parsed.path):
        raise MastodonReadProviderError("Mastodon pagination link is not allowlisted")
    _validate_query(parsed.path, parsed.query)
    return target


def _next_link(config: ProfileConfig, header: str | None) -> str | None:
    if not header:
        return None
    for match in re.finditer(r"<([^<>]+)>\s*;([^,]*)", header):
        target, attributes = match.groups()
        relation = re.search(r'(?:^|;)\s*rel\s*=\s*"?([^";,\s]+)', attributes)
        if relation is not None and relation.group(1) == "next":
            return _target_url(config, target, {})
    return None


def _request_for(config: ProfileConfig, url: str) -> Request:
    return Request(
        url,
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {config.access_token}",
            "User-Agent": "aidevops-mastodon-knowledge/1",
        },
        method="GET",
    )


def api(
    config: ProfileConfig,
    opener: Opener,
    target: str,
    params: dict[str, str],
) -> ApiResult:
    """Execute one exact-origin, redirect-free, GET-only JSON request."""
    url = _target_url(config, target, params)
    request = _request_for(config, url)
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            status = getattr(response, "status", 200)
            if isinstance(status, bool) or not isinstance(status, int):
                raise MastodonReadProviderError("Mastodon HTTP status is invalid")
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if not isinstance(payload, bytes):
                raise MastodonReadProviderError("Mastodon HTTP response is invalid")
            return ApiResult(
                status,
                _decode_response(payload),
                _next_link(config, response.headers.get("Link")),
            )
    except HTTPError as error:
        retry = error.headers.get("Retry-After") if error.headers is not None else None
        return ApiResult(error.code, {}, retry_after=_retry_epoch(retry))
    except (TimeoutError, URLError, OSError) as error:
        raise MastodonReadProviderError("Mastodon read provider request failed") from error
