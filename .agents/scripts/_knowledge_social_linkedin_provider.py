#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded GET-only OAuth subprocess for LinkedIn Member Snapshot reads."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from _knowledge_social_linkedin import API_VERSION, STREAMS
from _knowledge_social_linkedin_contract import (
    ApiResult,
    LinkedInReadProviderError,
    exact_keys,
    identity_value,
    observed_at,
    snapshot_page,
    stable_member_id,
    terminal_payload,
)
from _knowledge_social_linkedin_http import (
    MAX_RESPONSE_BYTES,
    NO_DATA_MESSAGE,
    decode_response,
    http_error_result,
)

API_BASE = "https://api.linkedin.com/rest"
READ_ENDPOINTS = {"memberAuthorizations", "memberSnapshotData"}
MAX_REQUEST_BYTES = 32 * 1024
HTTP_TIMEOUT_SECONDS = 60
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")
UrlOpen = Callable[..., Any]


def _profile_prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise LinkedInReadProviderError("LinkedIn OAuth profile name is invalid")
    return f"LINKEDIN_{profile.upper()}"


def _access_token(profile: str) -> str:
    token = os.environ.get(f"{_profile_prefix(profile)}_ACCESS_TOKEN", "")
    if not token or "\x00" in token or len(token.encode("utf-8")) > 16 * 1024:
        raise LinkedInReadProviderError(
            "LinkedIn OAuth profile access token is missing"
        )
    return token


def _http_exports() -> UrlOpen:
    if not callable(Request) or not callable(urlopen) or not callable(urlencode):
        raise LinkedInReadProviderError("Python urllib HTTP exports are unavailable")
    return urlopen


def _request() -> dict[str, Any]:
    payload = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    if len(payload) > MAX_REQUEST_BYTES:
        raise LinkedInReadProviderError("LinkedIn read request exceeds the safety limit")
    try:
        request = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise LinkedInReadProviderError(
            "LinkedIn read request is not valid JSON"
        ) from error
    if not isinstance(request, dict):
        raise LinkedInReadProviderError("LinkedIn read request root must be an object")
    return request


def _api(token: str, opener: UrlOpen, endpoint: str, params: dict[str, str]) -> ApiResult:
    if endpoint not in READ_ENDPOINTS:
        raise LinkedInReadProviderError("LinkedIn API endpoint is not allowlisted")
    url = f"{API_BASE}/{endpoint}?{urlencode(params)}"
    request = Request(
        url,
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Linkedin-Version": API_VERSION,
            "User-Agent": "aidevops-linkedin-knowledge/1",
        },
        method="GET",
    )
    try:
        with opener(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            status = getattr(response, "status", 200)
            if isinstance(status, bool) or not isinstance(status, int):
                raise LinkedInReadProviderError("LinkedIn HTTP status is invalid")
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if not isinstance(payload, bytes):
                raise LinkedInReadProviderError("LinkedIn HTTP response is invalid")
            return ApiResult(status, decode_response(payload))
    except HTTPError as error:
        return http_error_result(error)
    except (TimeoutError, URLError, OSError) as error:
        raise LinkedInReadProviderError("LinkedIn read provider request failed") from error


def _identity(
    api: Callable[[str, dict[str, str]], ApiResult], expected_id: str
) -> dict[str, Any]:
    result = api("memberAuthorizations", {"q": "memberAndApplication"})
    if result.status != 200:
        return terminal_payload(result)
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": identity_value(result.payload, expected_id),
    }


def _page_request(request: dict[str, Any]) -> tuple[str, str, str, int, int]:
    exact_keys(
        request,
        {"action", "stream", "account_id", "domain", "start", "limit"},
    )
    stream = request.get("stream")
    if not isinstance(stream, str) or stream not in STREAMS:
        raise LinkedInReadProviderError("LinkedIn read stream is unsupported")
    domain = request.get("domain")
    if domain != STREAMS[stream].snapshot_domain:
        raise LinkedInReadProviderError("LinkedIn snapshot domain is unsupported")
    start = request.get("start")
    limit = request.get("limit")
    if isinstance(start, bool) or not isinstance(start, int) or not 0 <= start <= 1_000_000_000:
        raise LinkedInReadProviderError("LinkedIn read start is invalid")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 50:
        raise LinkedInReadProviderError("LinkedIn read limit must be between 1 and 50")
    return (
        stream,
        stable_member_id(request.get("account_id"), "account ID"),
        domain,
        start,
        limit,
    )


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise LinkedInReadProviderError("LinkedIn read response exceeds the safety limit")
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
            raise LinkedInReadProviderError("LinkedIn read action is unsupported")
        token = _access_token(args.profile)
        opener = _http_exports()
        api = lambda endpoint, params: _api(token, opener, endpoint, params)
        if action == "identity":
            exact_keys(raw_request, {"action", "account_id"})
            expected_id = stable_member_id(raw_request.get("account_id"), "account ID")
            payload = _identity(api, expected_id)
        else:
            _stream, account_id, domain, start, limit = _page_request(raw_request)
            identity = _identity(api, account_id)
            if identity.get("status") != 200:
                payload = identity
            else:
                data = identity.get("data")
                if not isinstance(data, dict) or data.get("id") != account_id:
                    raise LinkedInReadProviderError(
                        "selected LinkedIn member does not match the configured connection"
                    )
                result = api(
                    "memberSnapshotData",
                    {
                        "q": "criteria",
                        "domain": domain,
                        "start": str(start),
                        "count": str(limit),
                    },
                )
                payload = snapshot_page(result, domain, start, limit)
        _emit(payload)
        return 0
    except LinkedInReadProviderError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: LinkedIn read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
