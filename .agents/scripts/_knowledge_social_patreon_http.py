#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Redirect-free, GET-only Patreon API v2 transport."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

from _knowledge_social_patreon_profile import Profile, PatreonReadProviderError
from _knowledge_social_patreon_types import PatreonAdapterError, campaign_id

API_ROOT = "https://www.patreon.com/api/oauth2/v2"
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_ERROR_BYTES = 64 * 1024


class RejectRedirects(HTTPRedirectHandler):
    """Reject redirects so bearer credentials never cross origins."""

    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


@dataclass(frozen=True)
class ApiResult:
    status: int
    payload: Any
    retry_after: int | None = None


ApiCall = Callable[[Profile, str, dict[str, str]], ApiResult]


def _path_allowed(profile: Profile, path: str) -> bool:
    if path in {"/identity", "/campaigns"}:
        return True
    parts = path.strip("/").split("/")
    if len(parts) not in (2, 3) or parts[0] != "campaigns":
        return False
    try:
        selected = campaign_id(parts[1])
    except PatreonAdapterError:
        return False
    return selected in profile.campaign_ids and (
        len(parts) == 2 or parts[2] in {"posts", "members"}
    )


def _bounded_retry_after(value: Any) -> int | None:
    if isinstance(value, str) and value.isdigit():
        value = int(value)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return min(value, 86400)


def _retry_after(headers: Any, payload: Any) -> int | None:
    header = headers.get("Retry-After") if headers is not None else None
    bounded = _bounded_retry_after(header)
    if bounded is not None or not isinstance(payload, dict):
        return bounded
    errors = payload.get("errors")
    if not isinstance(errors, list) or not errors or not isinstance(errors[0], dict):
        return None
    return _bounded_retry_after(errors[0].get("retry_after_seconds"))


def _decode_json(payload: bytes, field: str) -> Any:
    try:
        return json.loads(payload.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise PatreonReadProviderError(f"Patreon API returned no valid {field} JSON") from error


def _http_error(error: HTTPError) -> ApiResult:
    status = int(error.code)
    raw = error.read(MAX_ERROR_BYTES + 1)
    if 300 <= status < 400:
        return ApiResult(502, {})
    payload = _decode_json(raw, "error") if raw and len(raw) <= MAX_ERROR_BYTES else {}
    return ApiResult(status, {}, _retry_after(error.headers, payload))


def request(profile: Profile, path: str, params: dict[str, str]) -> ApiResult:
    """Perform one allowlisted Patreon GET without following redirects."""
    if not _path_allowed(profile, path):
        raise PatreonReadProviderError("Patreon read route is unsupported")
    query = f"?{urlencode(params)}" if params else ""
    api_request = Request(
        f"{API_ROOT}{path}{query}",
        headers={
            "Accept": "application/vnd.api+json",
            "Authorization": f"Bearer {profile.access_token}",
            "User-Agent": "aidevops-patreon-knowledge/1",
        },
        method="GET",
    )
    try:
        with build_opener(RejectRedirects).open(api_request, timeout=60) as response:
            raw = response.read(MAX_RESPONSE_BYTES + 1)
            status = int(response.status)
            headers = response.headers
    except HTTPError as error:
        return _http_error(error)
    except (OSError, URLError) as error:
        raise PatreonReadProviderError("Patreon API request failed") from error
    if len(raw) > MAX_RESPONSE_BYTES:
        raise PatreonReadProviderError("Patreon API response exceeds the byte safety limit")
    payload = _decode_json(raw, "response")
    return ApiResult(status, payload, _retry_after(headers, payload))
