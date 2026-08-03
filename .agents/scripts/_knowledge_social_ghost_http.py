#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact-origin, redirect-free HTTP transport for Ghost Content API reads."""

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

from _knowledge_social_ghost_contract import ApiResult, GhostReadProviderError
from _knowledge_social_ghost_routes import SITE_PATH, STREAM_PATHS, allowlisted_path

MAX_RESPONSE_BYTES = 8 * 1024 * 1024
HTTP_TIMEOUT_SECONDS = 60
ACCEPT_VERSION = "v6.0"


class Response(Protocol):
    status: int

    def __enter__(self) -> Response: ...

    def __exit__(self, *args: Any) -> None: ...

    def read(self, size: int = -1) -> bytes: ...


class Opener(Protocol):
    def open(self, request: Request, timeout: int) -> Response: ...


@dataclass(frozen=True)
class ProfileConfig:
    """Validated public-read profile and privacy-safe installation identity."""

    admin_url: str
    site_url: str
    site_id: str
    content_api_key: str
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
        raise GhostReadProviderError("Ghost profile URL is invalid") from error
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
        raise GhostReadProviderError("Ghost profile URL must be HTTPS")


def _canonical_path(path: str, *, admin: bool) -> str:
    result = path.rstrip("/")
    if any(marker in result for marker in ("\\", "%", "//")):
        raise GhostReadProviderError("Ghost profile URL is invalid")
    if any(part in (".", "..") for part in result.split("/") if part):
        raise GhostReadProviderError("Ghost profile URL is invalid")
    lowered = result.lower()
    if admin and (lowered.endswith("/ghost") or "/ghost/api" in lowered):
        raise GhostReadProviderError("Ghost profile admin URL must omit the API path")
    return result


def _canonical_url(value: str, *, admin: bool) -> str:
    parsed, port = _parsed_url(value)
    _validate_origin(parsed)
    host = parsed.hostname or ""
    rendered = f"[{host.lower()}]" if ":" in host else host.lower()
    if port is not None and port != 443:
        rendered = f"{rendered}:{port}"
    return f"https://{rendered}{_canonical_path(parsed.path, admin=admin)}"


def _canonical_admin_url(value: str) -> str:
    """Canonicalize one HTTPS admin base without exposing it in failures."""
    return _canonical_url(value, admin=True)


def _canonical_site_url(value: str) -> str:
    """Canonicalize one expected HTTPS publication URL."""
    return _canonical_url(value, admin=False)


def installation_fingerprint(admin_url: str, origin_key: str) -> str:
    canonical = _canonical_admin_url(admin_url)
    key = origin_key.encode()
    if len(key) < 32:
        raise GhostReadProviderError("Ghost profile origin key must be at least 32 bytes")
    return hmac.new(key, canonical.encode(), hashlib.sha256).hexdigest()[:24]


def _http_exports() -> Opener:
    exports = (Request, build_opener, urlencode, urlsplit, HTTPRedirectHandler)
    if not all(callable(item) for item in exports):
        raise GhostReadProviderError("Python urllib HTTP exports are unavailable")
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


def _parse_json(payload: bytes) -> Any:
    try:
        return json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise GhostReadProviderError("Ghost read provider returned no valid JSON") from error


def _decode_response(payload: bytes) -> Any:
    if len(payload) > MAX_RESPONSE_BYTES:
        raise GhostReadProviderError("Ghost read response exceeds the safety limit")
    value = _parse_json(payload)
    if not isinstance(value, dict):
        raise GhostReadProviderError("Ghost API response root must be an object")
    return value


def _query_keys(path: str) -> frozenset[str]:
    if path == SITE_PATH:
        return frozenset()
    if path in (STREAM_PATHS["posts"], STREAM_PATHS["pages"]):
        return frozenset({"page", "limit", "formats"})
    if path == STREAM_PATHS["tags"]:
        return frozenset({"page", "limit", "filter", "include"})
    if path == STREAM_PATHS["authors"]:
        return frozenset({"page", "limit", "include"})
    return frozenset()


def _validate_api_request(path: str, params: dict[str, str]) -> None:
    if not allowlisted_path(path) or set(params) != _query_keys(path):
        raise GhostReadProviderError("Ghost API route is not allowlisted")
    for key, value in params.items():
        if not isinstance(key, str) or not isinstance(value, str) or "\x00" in value:
            raise GhostReadProviderError("Ghost API query is invalid")
    if path == SITE_PATH:
        return
    try:
        page = int(params["page"])
        limit = int(params["limit"])
    except (KeyError, ValueError) as error:
        raise GhostReadProviderError("Ghost API pagination query is invalid") from error
    if page < 1 or not 1 <= limit <= 100:
        raise GhostReadProviderError("Ghost API pagination query is invalid")
    if "formats" in params and params["formats"] != "html,plaintext":
        raise GhostReadProviderError("Ghost Content API formats are invalid")
    if "filter" in params and params["filter"] != "visibility:public":
        raise GhostReadProviderError("Ghost tag visibility filter is invalid")
    if "include" in params and params["include"] != "count.posts":
        raise GhostReadProviderError("Ghost Content API include is invalid")


def _http_status(value: Any) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise GhostReadProviderError("Ghost HTTP status is invalid")
    return value


def _request_for(config: ProfileConfig, path: str, params: dict[str, str]) -> Request:
    query_params = dict(params)
    if path != SITE_PATH:
        query_params["key"] = config.content_api_key
    query = f"?{urlencode(query_params)}" if query_params else ""
    return Request(
        f"{config.admin_url}{path}{query}",
        headers={
            "Accept": "application/json",
            "Accept-Version": ACCEPT_VERSION,
            "User-Agent": "aidevops-ghost-knowledge/1",
        },
        method="GET",
    )


def _read_result(response: Response) -> ApiResult:
    status = _http_status(getattr(response, "status", 200))
    payload = response.read(MAX_RESPONSE_BYTES + 1)
    if not isinstance(payload, bytes):
        raise GhostReadProviderError("Ghost HTTP response is invalid")
    return ApiResult(status, _decode_response(payload))


def _open_request(opener: Opener, request: Request) -> ApiResult:
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            return _read_result(response)
    except HTTPError as error:
        retry = error.headers.get("Retry-After") if error.headers is not None else None
        return ApiResult(_http_status(error.code), {}, _retry_epoch(retry))
    except (TimeoutError, URLError, OSError) as error:
        raise GhostReadProviderError("Ghost read provider request failed") from error


def api(
    config: ProfileConfig,
    opener: Opener,
    path: str,
    params: dict[str, str],
) -> ApiResult:
    """Execute one exact-origin, redirect-free, GET-only JSON request."""
    _validate_api_request(path, params)
    return _open_request(opener, _request_for(config, path, params))
