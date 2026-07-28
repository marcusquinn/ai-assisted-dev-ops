#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded, redirect-free, GET-only Discourse account reader subprocess."""

from __future__ import annotations

import argparse
import hashlib
import hmac
import json
import math
import os
import re
import sys
import time
from dataclasses import dataclass
from typing import Any, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from _knowledge_social_discourse import (
    DiscourseAdapterError,
    namespaced_id,
    parse_page_request,
    provider_account_id,
)
from _knowledge_social_discourse_contract import (
    ApiResult,
    DiscourseReadProviderError,
    exact_keys,
    identity_value,
    object_value,
    observed_at,
    terminal_payload,
)
from _knowledge_social_discourse_routes import allowlisted_path, page

MAX_REQUEST_BYTES = 32 * 1024
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
HTTP_TIMEOUT_SECONDS = 60
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")


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
    user_api_key: str
    scope: str
    instance_id: str


class _RejectRedirect(HTTPRedirectHandler):
    """Convert every redirect into a terminal HTTP response without following it."""

    def redirect_request(
        self,
        req: Request,
        fp: Any,
        code: int,
        msg: str,
        headers: Any,
        newurl: str,
    ) -> None:
        del req, fp, code, msg, headers, newurl
        return None


def _profile_prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise DiscourseReadProviderError("Discourse profile name is invalid")
    return f"DISCOURSE_{profile.upper()}"


def _profile_value(prefix: str, suffix: str, field: str, limit: int) -> str:
    value = os.environ.get(f"{prefix}_{suffix}", "")
    if not value or "\x00" in value or len(value.encode("utf-8")) > limit:
        raise DiscourseReadProviderError(f"Discourse profile {field} is missing")
    return value


def _canonical_base_url(value: str) -> str:
    """Canonicalize one HTTPS installation base without leaking it in errors."""
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except ValueError as error:
        raise DiscourseReadProviderError("Discourse profile base URL is invalid") from error
    if (
        parsed.scheme.lower() != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise DiscourseReadProviderError("Discourse profile base URL must be HTTPS")
    path = parsed.path.rstrip("/")
    lowered_path = path.lower()
    if (
        "\\" in path
        or "%" in path
        or "//" in path
        or any(part in (".", "..") for part in path.split("/") if part)
    ):
        raise DiscourseReadProviderError("Discourse profile base URL is invalid")
    host = parsed.hostname.lower()
    rendered_host = f"[{host}]" if ":" in host else host
    if port is not None and port != 443:
        rendered_host = f"{rendered_host}:{port}"
    if lowered_path.startswith("/admin"):
        raise DiscourseReadProviderError("Discourse profile base URL is invalid")
    return f"https://{rendered_host}{path}"


def installation_fingerprint(base_url: str, origin_key: str) -> str:
    """Return a corpus-local keyed installation namespace."""
    canonical = _canonical_base_url(base_url)
    key = origin_key.encode("utf-8")
    if len(key) < 32:
        raise DiscourseReadProviderError(
            "Discourse profile origin key must be at least 32 bytes"
        )
    return hmac.new(key, canonical.encode("utf-8"), hashlib.sha256).hexdigest()[:24]


def _profile(profile: str) -> ProfileConfig:
    prefix = _profile_prefix(profile)
    base_url = _canonical_base_url(
        _profile_value(prefix, "BASE_URL", "base URL", 4096)
    )
    user_api_key = _profile_value(
        prefix, "USER_API_KEY", "user API key", 16 * 1024
    )
    origin_key = _profile_value(prefix, "ORIGIN_KEY", "origin key", 16 * 1024)
    scope = _profile_value(prefix, "USER_API_SCOPE", "user API scope", 64)
    if scope != "read":
        raise DiscourseReadProviderError(
            "Discourse user API profile must declare the read scope"
        )
    return ProfileConfig(
        base_url,
        user_api_key,
        scope,
        installation_fingerprint(base_url, origin_key),
    )


def _http_exports() -> Opener:
    """Verify and return the installed standard-library HTTP surface."""
    if not all(
        callable(item)
        for item in (Request, build_opener, urlencode, urlsplit, HTTPRedirectHandler)
    ):
        raise DiscourseReadProviderError("Python urllib HTTP exports are unavailable")
    return build_opener(_RejectRedirect())


def _request() -> dict[str, Any]:
    payload = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    if len(payload) > MAX_REQUEST_BYTES:
        raise DiscourseReadProviderError(
            "Discourse read request exceeds the safety limit"
        )
    try:
        request = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DiscourseReadProviderError(
            "Discourse read request is not valid JSON"
        ) from error
    if not isinstance(request, dict):
        raise DiscourseReadProviderError(
            "Discourse read request root must be an object"
        )
    return request


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
        raise DiscourseReadProviderError(
            "Discourse read response exceeds the safety limit"
        )
    try:
        decoded = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DiscourseReadProviderError(
            "Discourse read provider returned no valid JSON"
        ) from error
    if not isinstance(decoded, (dict, list)):
        raise DiscourseReadProviderError(
            "Discourse API response root must be an object or array"
        )
    return decoded


def _query_keys(path: str) -> frozenset[str]:
    if path == "/user_actions.json":
        return frozenset({"username", "filter", "offset", "limit"})
    if path == "/notifications.json":
        return frozenset({"username", "offset", "limit"})
    if path.endswith("/bookmarks.json"):
        return frozenset({"page", "limit"})
    if path.startswith("/topics/private-messages"):
        return frozenset({"page"})
    return frozenset()


def _api(
    config: ProfileConfig,
    opener: Opener,
    path: str,
    params: dict[str, str],
) -> ApiResult:
    """Execute one exact-origin, redirect-free, GET-only JSON request."""
    if not allowlisted_path(path) or set(params) != _query_keys(path):
        raise DiscourseReadProviderError("Discourse API route is not allowlisted")
    if "recent" in params or any(
        not isinstance(key, str)
        or not isinstance(value, str)
        or "\x00" in key
        or "\x00" in value
        for key, value in params.items()
    ):
        raise DiscourseReadProviderError("Discourse API query is invalid")
    query = f"?{urlencode(params)}" if params else ""
    request = Request(
        f"{config.base_url}{path}{query}",
        headers={
            "Accept": "application/json",
            "User-Api-Key": config.user_api_key,
            "User-Agent": "aidevops-discourse-knowledge/1",
        },
        method="GET",
    )
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            status = getattr(response, "status", 200)
            if isinstance(status, bool) or not isinstance(status, int):
                raise DiscourseReadProviderError("Discourse HTTP status is invalid")
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if not isinstance(payload, bytes):
                raise DiscourseReadProviderError("Discourse HTTP response is invalid")
            return ApiResult(status, _decode_response(payload))
    except HTTPError as error:
        status = error.code
        if isinstance(status, bool) or not isinstance(status, int):
            raise DiscourseReadProviderError("Discourse HTTP status is invalid") from error
        retry_header = (
            error.headers.get("Retry-After") if error.headers is not None else None
        )
        return ApiResult(status, {}, _retry_epoch(retry_header))
    except (TimeoutError, URLError, OSError) as error:
        raise DiscourseReadProviderError(
            "Discourse read provider request failed"
        ) from error


def _identity(
    config: ProfileConfig, opener: Opener, expected_id: str
) -> dict[str, Any]:
    result = _api(config, opener, "/session/current.json", {})
    if result.status != 200:
        return terminal_payload(result)
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": identity_value(result.payload, expected_id, config.instance_id),
    }


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise DiscourseReadProviderError(
            "Discourse read response exceeds the safety limit"
        )
    print(encoded)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        raw_request = _request()
        action = raw_request.get("action")
        if action not in ("identity", "page"):
            raise DiscourseReadProviderError("Discourse read action is unsupported")
        config = _profile(args.profile)
        opener = _http_exports()
        if action == "identity":
            exact_keys(raw_request, {"action", "account_id"})
            expected_id = provider_account_id(raw_request.get("account_id"))
            payload = _identity(config, opener, expected_id)
        else:
            request = parse_page_request(raw_request)
            if request.instance_id != config.instance_id:
                raise DiscourseReadProviderError(
                    "selected Discourse installation does not match the connection"
                )
            identity = _identity(config, opener, request.provider_account_id)
            if identity.get("status") != 200:
                payload = identity
            else:
                data = object_value(identity.get("data"), "account verification")
                expected_namespace = namespaced_id(
                    config.instance_id, "user", request.provider_account_id
                )
                if (
                    data.get("instance_id") != request.instance_id
                    or data.get("provider_account_id") != request.provider_account_id
                    or data.get("username") != request.username
                    or request.account_id != expected_namespace
                ):
                    raise DiscourseReadProviderError(
                        "selected Discourse account does not match the connection"
                    )
                result = page(
                    lambda path, params: _api(config, opener, path, params),
                    request,
                    data,
                )
                payload = terminal_payload(result) if isinstance(result, ApiResult) else result
        _emit(payload)
        return 0
    except (DiscourseReadProviderError, DiscourseAdapterError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: Discourse read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
