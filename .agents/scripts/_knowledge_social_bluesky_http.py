#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Credential isolation, HTTPS validation, and GET-only Bluesky XRPC transport."""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import time
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

from _knowledge_social_bluesky import STREAMS, BlueskyAdapterError

MAX_REQUEST_BYTES = 32 * 1024
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
HTTP_TIMEOUT_SECONDS = 60
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")
SERVICE_IDENTITY = re.compile(
    r"^did:[a-z0-9]+:[A-Za-z0-9._:%-]+#[A-Za-z0-9._-]+$"
)
IDENTITY_ENDPOINTS = frozenset(
    {"com.atproto.identity.resolveHandle", "com.atproto.repo.describeRepo"}
)
READ_ENDPOINTS = frozenset(
    spec.endpoint for spec in STREAMS.values() if spec.endpoint != "unavailable"
) | IDENTITY_ENDPOINTS


class _RejectRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args: Any, **kwargs: Any) -> None:
        del args, kwargs
        return None


@dataclass(frozen=True)
class Profile:
    token: str
    handle: str
    pds: str
    appview: str
    chat: str | None
    chat_enabled: bool
    auth_mode: str


@dataclass(frozen=True)
class ApiResult:
    status: int
    payload: dict[str, Any]
    retry_after: int | None = None


def observed_at() -> str:
    return datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def _prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise BlueskyAdapterError("Bluesky profile name is invalid")
    return f"BLUESKY_{profile.upper()}"


def _unsafe_service(parsed: Any) -> bool:
    unsafe_authority = (
        not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
    )
    unsafe_suffix = bool(parsed.query or parsed.fragment or parsed.path not in ("", "/"))
    return parsed.scheme != "https" or unsafe_authority or unsafe_suffix


def service_url(value: str) -> str:
    parsed = urlsplit(value)
    if _unsafe_service(parsed):
        raise BlueskyAdapterError("Bluesky service URL is missing or unsafe")
    port = f":{parsed.port}" if parsed.port else ""
    return f"https://{parsed.hostname.lower()}{port}"


def service_identity(value: str, message: str) -> str:
    if SERVICE_IDENTITY.fullmatch(value) is None:
        raise BlueskyAdapterError(message)
    return value


def _bounded_secret(value: str, message: str, limit: int) -> str:
    if not value or "\x00" in value or len(value.encode()) > limit:
        raise BlueskyAdapterError(message)
    return value


def profile_from_environment(name: str) -> Profile:
    prefix = _prefix(name)
    token = _bounded_secret(
        os.environ.get(f"{prefix}_ACCESS_TOKEN", ""),
        "Bluesky profile access token is missing",
        16 * 1024,
    )
    handle = _bounded_secret(
        os.environ.get(f"{prefix}_HANDLE", ""),
        "Bluesky profile handle is missing",
        512,
    )
    auth_mode = os.environ.get(f"{prefix}_AUTH_MODE", "")
    if auth_mode == "oauth":
        raise BlueskyAdapterError("Bluesky OAuth profile requires DPoP support")
    if auth_mode != "app_password_session":
        raise BlueskyAdapterError("Bluesky profile auth mode is invalid")
    chat_setting = os.environ.get(f"{prefix}_CHAT_ENABLED", "0")
    if chat_setting not in ("0", "1"):
        raise BlueskyAdapterError("Bluesky chat authorization setting is invalid")
    chat_enabled = chat_setting == "1"
    appview = service_identity(
        os.environ.get(f"{prefix}_APPVIEW_SERVICE", ""),
        "Bluesky AppView service identity is invalid",
    )
    chat_value = os.environ.get(f"{prefix}_CHAT_SERVICE", "")
    return Profile(
        token,
        handle,
        service_url(os.environ.get(f"{prefix}_PDS_URL", "")),
        appview,
        service_identity(chat_value, "Bluesky chat service identity is invalid")
        if chat_enabled
        else None,
        chat_enabled,
        auth_mode,
    )


def service_id(value: str | None) -> str:
    material = value if value is not None else "chat-disabled"
    return hashlib.sha256(material.encode()).hexdigest()[:24]


def connection_id(account_did: str, profile: Profile) -> str:
    identities = (service_id(profile.pds), service_id(profile.appview), service_id(profile.chat))
    return hashlib.sha256("|".join((account_did, *identities)).encode()).hexdigest()[:24]


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


def _decoded(payload: bytes) -> dict[str, Any]:
    if len(payload) > MAX_RESPONSE_BYTES:
        raise BlueskyAdapterError("Bluesky read response exceeds the safety limit")
    try:
        value = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise BlueskyAdapterError("Bluesky read provider returned no valid JSON") from error
    if not isinstance(value, dict):
        raise BlueskyAdapterError("Bluesky API response root must be an object")
    return value


def _response(result: Any) -> ApiResult:
    status = getattr(result, "status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise BlueskyAdapterError("Bluesky HTTP status is invalid")
    body = result.read(MAX_RESPONSE_BYTES + 1)
    if not isinstance(body, bytes):
        raise BlueskyAdapterError("Bluesky HTTP response is invalid")
    return ApiResult(status, _decoded(body))


def public_json(url: str) -> dict[str, Any]:
    """Read one fixed-authority public identity document without credentials."""
    request = Request(
        url,
        headers={"Accept": "application/json", "User-Agent": "aidevops-bluesky-knowledge/1"},
        method="GET",
    )
    try:
        with build_opener(_RejectRedirect).open(request, timeout=HTTP_TIMEOUT_SECONDS) as result:
            return _response(result).payload
    except (HTTPError, TimeoutError, URLError, OSError) as error:
        raise BlueskyAdapterError("Bluesky DID document resolution failed") from error


def api(
    profile: Profile,
    base: str,
    endpoint: str,
    params: dict[str, str],
    proxy: str | None = None,
) -> ApiResult:
    """Execute one allowlisted XRPC query with redirect rejection."""
    if endpoint not in READ_ENDPOINTS:
        raise BlueskyAdapterError("Bluesky XRPC query is not allowlisted")
    query = f"?{urlencode(params)}" if params else ""
    headers = {
        "Accept": "application/json",
        "Authorization": f"Bearer {profile.token}",
        "User-Agent": "aidevops-bluesky-knowledge/1",
    }
    if proxy is not None:
        headers["Atproto-Proxy"] = proxy
    request = Request(
        f"{base}/xrpc/{endpoint}{query}",
        headers=headers,
        method="GET",
    )
    try:
        with build_opener(_RejectRedirect).open(request, timeout=HTTP_TIMEOUT_SECONDS) as result:
            return _response(result)
    except HTTPError as error:
        if 300 <= error.code < 400:
            raise BlueskyAdapterError("Bluesky service redirects are rejected") from error
        return ApiResult(error.code, {}, _retry_epoch(error.headers.get("Retry-After")))
    except (TimeoutError, URLError, OSError) as error:
        raise BlueskyAdapterError("Bluesky read provider request failed") from error


def terminal_payload(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {"status": result.status, "observed_at": observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload
