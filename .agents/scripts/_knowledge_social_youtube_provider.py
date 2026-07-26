#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded read-only OAuth subprocess for YouTube account collection."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
import time
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from _knowledge_social_youtube_contract import (
    ApiResult,
    YouTubeReadProviderError,
    exact_keys,
    identity_value,
    observed_at,
    stable_id,
    terminal_payload,
)
from _knowledge_social_youtube_routes import READ_ENDPOINTS, page, page_request

API_BASE = "https://www.googleapis.com/youtube/v3"
MAX_REQUEST_BYTES = 32 * 1024
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
HTTP_TIMEOUT_SECONDS = 60
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")
RATE_LIMIT_REASONS = frozenset(
    {
        "concurrentLimitExceeded",
        "dailyLimitExceeded",
        "dailyLimitExceededUnreg",
        "limitExceeded",
        "quotaExceeded",
        "rateLimitExceeded",
        "rateLimitExceededUnreg",
        "servingLimitExceeded",
        "userRateLimitExceeded",
        "userRateLimitExceededUnreg",
        "variableTermExpiredDailyExceeded",
        "variableTermLimitExceeded",
    }
)
UrlOpen = Callable[..., Any]


def _profile_prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise YouTubeReadProviderError("YouTube OAuth profile name is invalid")
    return f"YOUTUBE_{profile.upper()}"


def _access_token(profile: str) -> str:
    token = os.environ.get(f"{_profile_prefix(profile)}_ACCESS_TOKEN", "")
    if not token or "\x00" in token or len(token.encode("utf-8")) > 16 * 1024:
        raise YouTubeReadProviderError(
            "YouTube OAuth profile access token is missing"
        )
    return token


def _http_exports() -> UrlOpen:
    if not callable(Request) or not callable(urlopen) or not callable(urlencode):
        raise YouTubeReadProviderError("Python urllib HTTP exports are unavailable")
    return urlopen


def _request() -> dict[str, Any]:
    payload = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    if len(payload) > MAX_REQUEST_BYTES:
        raise YouTubeReadProviderError("YouTube read request exceeds the safety limit")
    try:
        request = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise YouTubeReadProviderError("YouTube read request is not valid JSON") from error
    if not isinstance(request, dict):
        raise YouTubeReadProviderError("YouTube read request root must be an object")
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


def _decode_response(payload: bytes) -> dict[str, Any]:
    if len(payload) > MAX_RESPONSE_BYTES:
        raise YouTubeReadProviderError("YouTube read response exceeds the safety limit")
    try:
        decoded = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise YouTubeReadProviderError(
            "YouTube read provider returned no valid JSON"
        ) from error
    if not isinstance(decoded, dict):
        raise YouTubeReadProviderError("YouTube API response root must be an object")
    return decoded


def _error_reasons(error: HTTPError) -> set[str]:
    """Extract only bounded, allowlist-comparable Google error reasons."""
    try:
        payload = _decode_response(error.read(MAX_RESPONSE_BYTES + 1))
    except (OSError, ValueError, YouTubeReadProviderError):
        return set()
    envelope = payload.get("error")
    entries = envelope.get("errors") if isinstance(envelope, dict) else None
    if not isinstance(entries, list):
        return set()
    return {
        reason
        for entry in entries
        if isinstance(entry, dict)
        for reason in (entry.get("reason"),)
        if isinstance(reason, str)
    }


def _terminal_status(error: HTTPError) -> int:
    """Normalize documented 403 quota reasons to the shared rate-limit status."""
    status = error.code
    if status == 403 and _error_reasons(error).intersection(RATE_LIMIT_REASONS):
        return 429
    return status


def _api(token: str, opener: UrlOpen, endpoint: str, params: dict[str, str]) -> ApiResult:
    if endpoint not in READ_ENDPOINTS:
        raise YouTubeReadProviderError("YouTube API endpoint is not allowlisted")
    url = f"{API_BASE}/{endpoint}?{urlencode(params)}"
    request = Request(
        url,
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "aidevops-youtube-knowledge/1",
        },
        method="GET",
    )
    try:
        with opener(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            status = getattr(response, "status", 200)
            if isinstance(status, bool) or not isinstance(status, int):
                raise YouTubeReadProviderError("YouTube HTTP status is invalid")
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if not isinstance(payload, bytes):
                raise YouTubeReadProviderError("YouTube HTTP response is invalid")
            return ApiResult(status, _decode_response(payload))
    except HTTPError as error:
        status = _terminal_status(error)
        if isinstance(status, bool) or not isinstance(status, int):
            raise YouTubeReadProviderError("YouTube HTTP status is invalid") from error
        retry_after = _retry_epoch(error.headers.get("Retry-After"))
        return ApiResult(status, {}, retry_after)
    except (TimeoutError, URLError, OSError) as error:
        raise YouTubeReadProviderError("YouTube read provider request failed") from error


def _identity(
    api: Callable[[str, dict[str, str]], ApiResult], expected_id: str
) -> dict[str, Any]:
    result = api(
        "channels",
        {
            "part": "id,snippet,contentDetails",
            "mine": "true",
            "maxResults": "50",
        },
    )
    if result.status != 200:
        return terminal_payload(result)
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": identity_value(result.payload, expected_id),
    }


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise YouTubeReadProviderError("YouTube read response exceeds the safety limit")
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
            raise YouTubeReadProviderError("YouTube read action is unsupported")
        token = _access_token(args.profile)
        opener = _http_exports()
        api = lambda endpoint, params: _api(token, opener, endpoint, params)
        if action == "identity":
            exact_keys(raw_request, {"action", "account_id"})
            expected_id = stable_id(raw_request.get("account_id"), "account ID")
            payload = _identity(api, expected_id)
        else:
            request = page_request(raw_request)
            identity = _identity(api, request.account_id)
            if identity.get("status") != 200:
                payload = identity
            else:
                data = identity.get("data")
                if not isinstance(data, dict):
                    raise YouTubeReadProviderError(
                        "YouTube account verification returned no channel"
                    )
                if data.get("uploads_playlist_id") != request.uploads_playlist_id:
                    raise YouTubeReadProviderError(
                        "selected YouTube channel does not match the configured connection"
                    )
                payload = page(api, request)
        _emit(payload)
        return 0
    except YouTubeReadProviderError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: YouTube read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
