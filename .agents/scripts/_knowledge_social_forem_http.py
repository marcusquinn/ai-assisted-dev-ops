#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact-origin, redirect-free HTTP transport for Forem account reads."""

from __future__ import annotations

import hashlib
import hmac
import json
import math
import time
from dataclasses import dataclass
from typing import Any, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import SplitResult, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from _knowledge_social_forem_contract import ApiResult, ForemReadProviderError
from _knowledge_social_forem_routes import allowlisted_path

MAX_RESPONSE_BYTES = 8 * 1024 * 1024
HTTP_TIMEOUT_SECONDS = 60
ACCEPT_HEADER = "application/vnd.forem.api-v1+json"


class Response(Protocol):
    status: int

    def __enter__(self) -> Response: ...

    def __exit__(self, *args: Any) -> None: ...

    def read(self, size: int = -1) -> bytes: ...


class Opener(Protocol):
    def open(self, request: Request, timeout: int) -> Response: ...


@dataclass(frozen=True)
class ProfileConfig:
    """Validated secret profile and privacy-safe installation identity."""

    base_url: str
    api_key: str
    auth_mode: str
    instance_id: str


class _RejectRedirect(HTTPRedirectHandler):
    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


def _parsed_url(value: str) -> tuple[SplitResult, int | None]:
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise ForemReadProviderError("Forem profile base URL is invalid") from error
    return parsed, port


def _validate_origin(parsed: SplitResult) -> None:
    checks = (
        parsed.scheme.lower() == "https",
        parsed.hostname is not None,
        parsed.username is None,
        parsed.password is None,
        not parsed.query,
        not parsed.fragment,
    )
    if not all(checks):
        raise ForemReadProviderError("Forem profile base URL must be HTTPS")


def _canonical_path(path: str) -> str:
    result = path.rstrip("/")
    if any(marker in result for marker in ("\\", "%", "//")):
        raise ForemReadProviderError("Forem profile base URL is invalid")
    if any(part in (".", "..") for part in result.split("/") if part):
        raise ForemReadProviderError("Forem profile base URL is invalid")
    if result.lower().startswith(("/admin", "/api")):
        raise ForemReadProviderError("Forem profile base URL is invalid")
    return result


def _canonical_base_url(value: str) -> str:
    """Canonicalize one HTTPS installation base without leaking it in errors."""
    parsed, port = _parsed_url(value)
    _validate_origin(parsed)
    host = parsed.hostname or ""
    rendered = f"[{host.lower()}]" if ":" in host else host.lower()
    if port is not None and port != 443:
        rendered = f"{rendered}:{port}"
    return f"https://{rendered}{_canonical_path(parsed.path)}"


def installation_fingerprint(base_url: str, origin_key: str) -> str:
    canonical = _canonical_base_url(base_url)
    key = origin_key.encode()
    if len(key) < 32:
        raise ForemReadProviderError(
            "Forem profile origin key must be at least 32 bytes"
        )
    return hmac.new(key, canonical.encode(), hashlib.sha256).hexdigest()[:24]


def _http_exports() -> Opener:
    exports = (Request, build_opener, urlencode, urlsplit, HTTPRedirectHandler)
    if not all(callable(item) for item in exports):
        raise ForemReadProviderError("Python urllib HTTP exports are unavailable")
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
    if len(payload) > MAX_RESPONSE_BYTES:
        raise ForemReadProviderError("Forem read response exceeds the safety limit")
    try:
        decoded = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ForemReadProviderError(
            "Forem read provider returned no valid JSON"
        ) from error
    if not isinstance(decoded, (dict, list)):
        raise ForemReadProviderError(
            "Forem API response root must be an object or array"
        )
    return decoded


def _query_keys(path: str) -> frozenset[str]:
    if path in ("/api/articles/me/all", "/api/readinglist"):
        return frozenset({"page", "per_page"})
    if path == "/api/followers/users":
        return frozenset({"page", "per_page", "sort"})
    return frozenset()


def _validate_api_request(path: str, params: dict[str, str]) -> None:
    if not allowlisted_path(path) or set(params) != _query_keys(path):
        raise ForemReadProviderError("Forem API route is not allowlisted")
    for key, value in params.items():
        if not isinstance(key, str) or not isinstance(value, str):
            raise ForemReadProviderError("Forem API query is invalid")
        if "\x00" in key or "\x00" in value:
            raise ForemReadProviderError("Forem API query is invalid")


def _http_status(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ForemReadProviderError("Forem HTTP status is invalid")
    return value


def _request_for(config: ProfileConfig, path: str, params: dict[str, str]) -> Request:
    query = f"?{urlencode(params)}" if params else ""
    return Request(
        f"{config.base_url}{path}{query}",
        headers={
            "Accept": ACCEPT_HEADER,
            "api-key": config.api_key,
            "User-Agent": "aidevops-forem-knowledge/1",
        },
        method="GET",
    )


def api(
    config: ProfileConfig,
    opener: Opener,
    path: str,
    params: dict[str, str],
) -> ApiResult:
    """Execute one exact-origin, redirect-free, GET-only JSON request."""
    _validate_api_request(path, params)
    request = _request_for(config, path, params)
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            status = _http_status(getattr(response, "status", 200))
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if not isinstance(payload, bytes):
                raise ForemReadProviderError("Forem HTTP response is invalid")
            return ApiResult(status, _decode_response(payload))
    except HTTPError as error:
        retry = error.headers.get("Retry-After") if error.headers is not None else None
        return ApiResult(_http_status(error.code), {}, _retry_epoch(retry))
    except (TimeoutError, URLError, OSError) as error:
        raise ForemReadProviderError("Forem read provider request failed") from error
