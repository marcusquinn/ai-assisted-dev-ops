#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Exact-route, redirect-free, standard-library Slack Web API transport."""

from __future__ import annotations

import json
from typing import Any, Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

from _knowledge_social_slack_contract import ApiResult, SlackReadProviderError

API_BASE = "https://slack.com/api"
HTTP_TIMEOUT_SECONDS = 60
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_RETRY_SECONDS = 31 * 24 * 60 * 60
READ_METHODS = {
    "auth.test": "POST",
    "team.info": "GET",
    "users.list": "GET",
    "conversations.info": "GET",
    "conversations.members": "GET",
    "conversations.history": "GET",
    "conversations.replies": "GET",
    "pins.list": "GET",
    "bookmarks.list": "POST",
    "files.list": "GET",
    "reactions.list": "GET",
}
READ_SCOPES = frozenset(
    {
        "team:read",
        "users:read",
        "channels:read",
        "groups:read",
        "im:read",
        "mpim:read",
        "channels:history",
        "groups:history",
        "im:history",
        "mpim:history",
        "reactions:read",
        "files:read",
        "pins:read",
        "bookmarks:read",
    }
)

AUTH_ERRORS = frozenset(
    {"invalid_auth", "not_authed", "token_expired", "token_revoked", "account_inactive"}
)
AUTHORIZATION_ERRORS = frozenset(
    {
        "access_denied",
        "missing_scope",
        "no_permission",
        "not_allowed_token_type",
        "not_in_channel",
        "team_access_not_granted",
        "enterprise_is_restricted",
        "ekm_access_denied",
    }
)
UNAVAILABLE_ERRORS = frozenset(
    {
        "channel_not_found",
        "file_not_found",
        "thread_not_found",
        "method_not_supported_for_channel_type",
        "not_implemented",
    }
)
PROVIDER_ERRORS = frozenset(
    {"fatal_error", "internal_error", "service_unavailable", "request_timeout"}
)


class ResponseHeaders(Protocol):
    def get(self, name: str, default: Any = None) -> Any: ...


class Opener(Protocol):
    def open(self, request: Request, timeout: int) -> Any: ...


class _RejectRedirects(HTTPRedirectHandler):
    def redirect_request(
        self, *_args: Any, **_kwargs: Any
    ) -> None:
        return None


def _http_exports() -> Opener:
    if not all(callable(value) for value in (Request, build_opener, urlencode)):
        raise SlackReadProviderError("Python urllib HTTP exports are unavailable")
    return build_opener(_RejectRedirects())


def _decode(payload: bytes) -> dict[str, Any]:
    if len(payload) > MAX_RESPONSE_BYTES:
        raise SlackReadProviderError("Slack HTTP response exceeds the safety limit")
    try:
        parsed = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SlackReadProviderError("Slack HTTP response is not valid JSON") from error
    if not isinstance(parsed, dict):
        raise SlackReadProviderError("Slack HTTP response root must be an object")
    return parsed


def _response_bytes(response: Any) -> bytes:
    payload = response.read(MAX_RESPONSE_BYTES + 1)
    if not isinstance(payload, bytes):
        raise SlackReadProviderError("Slack HTTP response is invalid")
    if len(payload) > MAX_RESPONSE_BYTES:
        raise SlackReadProviderError("Slack HTTP response exceeds the safety limit")
    return payload


def _scopes(headers: ResponseHeaders, *, required: bool) -> frozenset[str]:
    value = headers.get("X-OAuth-Scopes")
    if value is None:
        if required:
            raise SlackReadProviderError("Slack response did not attest token scopes")
        return frozenset()
    if not isinstance(value, str) or "\x00" in value:
        raise SlackReadProviderError("Slack response scope attestation is invalid")
    scopes = frozenset(part.strip() for part in value.split(",") if part.strip())
    if not scopes or any(scope not in READ_SCOPES for scope in scopes):
        raise SlackReadProviderError("Slack token includes an unsupported or write scope")
    return scopes


def _retry_after(headers: ResponseHeaders) -> str | None:
    value = headers.get("Retry-After")
    if value is None:
        return None
    if not isinstance(value, str) or not value.isascii() or not value.isdigit():
        raise SlackReadProviderError("Slack Retry-After header is invalid")
    seconds = int(value)
    if not 1 <= seconds <= MAX_RETRY_SECONDS:
        raise SlackReadProviderError("Slack Retry-After header is outside the safety limit")
    return value


def _error_status(payload: dict[str, Any], http_status: int) -> int:
    error = payload.get("error")
    status = 400
    if error == "ratelimited" or http_status == 429:
        status = 429
    elif error in AUTH_ERRORS or http_status == 401:
        status = 401
    elif error in AUTHORIZATION_ERRORS or http_status == 403:
        status = 403
    elif error in UNAVAILABLE_ERRORS or http_status == 404:
        status = 404
    elif error in PROVIDER_ERRORS or http_status >= 500:
        status = 500
    return status


def _result(payload: dict[str, Any], status: int, headers: ResponseHeaders) -> ApiResult:
    successful = status == 200 and payload.get("ok") is True
    scopes = _scopes(headers, required=successful)
    retry_after = _retry_after(headers)
    if successful:
        return ApiResult(200, payload, scopes, retry_after)
    return ApiResult(_error_status(payload, status), {}, scopes, retry_after)


def api(
    token: str,
    opener: Opener,
    endpoint: str,
    params: dict[str, str],
) -> ApiResult:
    """Execute one reviewed Slack read method without redirects or token URLs."""
    method = READ_METHODS.get(endpoint)
    if method is None:
        raise SlackReadProviderError("Slack API endpoint is not allowlisted")
    encoded = urlencode(params).encode("utf-8")
    url = f"{API_BASE}/{endpoint}"
    data: bytes | None = None
    if method == "GET":
        if encoded:
            url = f"{url}?{encoded.decode('ascii')}"
    else:
        data = encoded
    request = Request(
        url,
        data=data,
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/x-www-form-urlencoded; charset=utf-8",
            "User-Agent": "aidevops-slack-knowledge/1",
        },
        method=method,
    )
    try:
        with opener.open(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            status = getattr(response, "status", 200)
            if isinstance(status, bool) or not isinstance(status, int):
                raise SlackReadProviderError("Slack HTTP status is invalid")
            return _result(_decode(_response_bytes(response)), status, response.headers)
    except HTTPError as error:
        try:
            payload = _decode(_response_bytes(error))
        except SlackReadProviderError:
            payload = {}
        return _result(payload, int(error.code), error.headers)
    except (TimeoutError, URLError, OSError) as error:
        raise SlackReadProviderError("Slack read provider request failed") from error
