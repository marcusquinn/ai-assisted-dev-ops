#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded GET-only subprocess for Google Business Profile APIs."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Callable

from _knowledge_social_google_business_profile_records import (
    RecordError,
    serialize_records,
)
from _knowledge_social_google_business_profile_routes import (
    READ_STREAMS,
    build_route,
)
from _knowledge_social_google_business_profile_transport import (
    ApiResult,
    ProviderError,
    UrlOpen,
    api_request,
    http_exports,
)

MAX_REQUEST_BYTES = 32 * 1024
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")
STABLE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$")


@dataclass(frozen=True)
class Identity:
    """Expected hierarchy loaded only inside the guarded process."""

    google_subject: str
    account_id: str
    organization_id: str | None
    location_id: str


def _profile_prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise ProviderError("Google Business Profile OAuth profile name is invalid")
    return f"GOOGLE_BUSINESS_PROFILE_{profile.upper()}"


def _env(prefix: str, suffix: str, *, optional: bool = False) -> str | None:
    value = os.environ.get(f"{prefix}_{suffix}", "")
    if not value and optional:
        return None
    if not value or "\x00" in value or len(value.encode("utf-8")) > 16 * 1024:
        raise ProviderError("Google Business Profile OAuth profile is incomplete")
    return value


def _stable_id(value: Any, field: str, *, optional: bool = False) -> str | None:
    if value is None and optional:
        return None
    if not isinstance(value, str) or STABLE_ID.fullmatch(value) is None:
        raise ProviderError(f"Google Business Profile {field} is invalid")
    return value


def _profile(profile: str) -> tuple[str, Identity]:
    prefix = _profile_prefix(profile)
    token = _env(prefix, "ACCESS_TOKEN")
    subject = _env(prefix, "GOOGLE_SUBJECT")
    account_id = _stable_id(_env(prefix, "ACCOUNT_ID"), "account ID")
    organization_id = _stable_id(
        _env(prefix, "ORGANIZATION_ID", optional=True),
        "organization ID",
        optional=True,
    )
    location_id = _stable_id(_env(prefix, "LOCATION_ID"), "location ID")
    if token is None or subject is None or account_id is None or location_id is None:
        raise ProviderError("Google Business Profile OAuth profile is incomplete")
    return token, Identity(subject, account_id, organization_id, location_id)


def _observed_at() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _terminal(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {"status": result.status, "observed_at": _observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload


def _resource_name(payload: dict[str, Any], expected: str) -> dict[str, Any]:
    if payload.get("name") != expected:
        raise ProviderError(
            "selected Google identity or Business Profile hierarchy does not match the configured connection"
        )
    return payload


def _identity(
    api: Callable[[str, str, dict[str, Any] | None], ApiResult],
    expected_location_id: str,
    identity: Identity,
) -> dict[str, Any]:
    if expected_location_id != identity.location_id:
        raise ProviderError(
            "selected Google identity or Business Profile hierarchy does not match the configured connection"
        )
    user = api("https://www.googleapis.com/oauth2/v3", "/userinfo", None)
    account = api(
        "https://mybusinessaccountmanagement.googleapis.com/v1",
        f"/accounts/{identity.account_id}",
        None,
    )
    if user.status != 200:
        return _terminal(user)
    if account.status != 200:
        return _terminal(account)
    if user.payload.get("sub") != identity.google_subject:
        raise ProviderError(
            "selected Google identity or Business Profile hierarchy does not match the configured connection"
        )
    _resource_name(account.payload, f"accounts/{identity.account_id}")
    if identity.organization_id is not None:
        organization = api(
            "https://mybusinessaccountmanagement.googleapis.com/v1",
            f"/accounts/{identity.organization_id}",
            None,
        )
        if organization.status != 200:
            return _terminal(organization)
        _resource_name(organization.payload, f"accounts/{identity.organization_id}")
    location = api(
        "https://mybusinessbusinessinformation.googleapis.com/v1",
        f"/locations/{identity.location_id}",
        {"readMask": "name,title,metadata"},
    )
    if location.status != 200:
        return _terminal(location)
    _resource_name(location.payload, f"locations/{identity.location_id}")
    return {
        "status": 200,
        "observed_at": _observed_at(),
        "data": {
            "id": identity.location_id,
            "business_account_id": identity.account_id,
            "organization_id": identity.organization_id,
            "title": location.payload.get("title"),
            "google_identity_verified": True,
        },
    }


def _page_token(cursor: Any) -> str | None:
    if cursor is None:
        return None
    if not isinstance(cursor, dict) or set(cursor) != {"page_token"}:
        raise ProviderError("Google Business Profile page cursor is invalid")
    token = cursor.get("page_token")
    if not isinstance(token, str) or not token or len(token) > 2048:
        raise ProviderError("Google Business Profile page cursor is invalid")
    return token


def _route(
    api: Callable[[str, str, dict[str, Any] | None], ApiResult],
    request: dict[str, Any],
    identity: Identity,
) -> dict[str, Any]:
    stream = request.get("stream")
    limit = request.get("limit")
    if stream not in READ_STREAMS:
        raise ProviderError("Google Business Profile read stream is unsupported")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
        raise ProviderError("Google Business Profile read limit must be between 1 and 100")
    if request.get("location_id") != identity.location_id or request.get("business_account_id") != identity.account_id or request.get("organization_id") != identity.organization_id:
        raise ProviderError(
            "selected Google identity or Business Profile hierarchy does not match the configured connection"
        )
    if request.get("stop_at") is not None:
        raise ProviderError("Google Business Profile snapshot watermark must be empty")
    token = _page_token(request.get("cursor"))
    route = build_route(
        stream, identity.account_id, identity.location_id, token, limit
    )
    result = api(route.base, route.path, route.params)
    if result.status != 200:
        return _terminal(result)
    next_token = result.payload.get("nextPageToken")
    if next_token is not None and (not isinstance(next_token, str) or not next_token):
        raise ProviderError("Google Business Profile next page token is invalid")
    try:
        records = serialize_records(stream, result.payload, identity.location_id)
    except RecordError as error:
        raise ProviderError(str(error)) from error
    return {
        "status": 200,
        "observed_at": _observed_at(),
        "data": records,
        "meta": {
            "next_cursor": {"page_token": next_token} if next_token else None,
            "complete": next_token is None,
            "snapshot": True,
        },
    }


def _guarded_page(
    api: Callable[[str, str, dict[str, Any] | None], ApiResult],
    request: dict[str, Any],
    identity: Identity,
) -> dict[str, Any]:
    """Read one page only while both surrounding identity fences pass."""
    initial_fence = _identity(api, identity.location_id, identity)
    if initial_fence.get("status") != 200:
        return initial_fence
    page = _route(api, request, identity)
    if page.get("status") != 200:
        return page
    final_fence = _identity(api, identity.location_id, identity)
    return page if final_fence.get("status") == 200 else final_fence


def _request() -> dict[str, Any]:
    payload = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    if len(payload) > MAX_REQUEST_BYTES:
        raise ProviderError("Google Business Profile request exceeds the safety limit")
    try:
        request = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProviderError("Google Business Profile request is not valid JSON") from error
    if not isinstance(request, dict):
        raise ProviderError("Google Business Profile request root must be an object")
    return request


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise ProviderError("Google Business Profile response exceeds the safety limit")
    print(encoded)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        request = _request()
        token, identity = _profile(args.profile)
        opener = http_exports()
        api = lambda base, path, params=None: api_request(
            token, opener, base, path, params
        )
        action = request.get("action")
        if action == "identity" and set(request) == {"action", "account_id"}:
            expected = _stable_id(request.get("account_id"), "location ID")
            if expected is None:
                raise ProviderError("Google Business Profile location ID is invalid")
            payload = _identity(api, expected, identity)
        elif action == "page" and set(request) == {
            "action", "stream", "location_id", "business_account_id",
            "organization_id", "cursor", "stop_at", "limit",
        }:
            payload = _guarded_page(api, request, identity)
        else:
            raise ProviderError("Google Business Profile read action is unsupported")
        _emit(payload)
        return 0
    except ProviderError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: Google Business Profile read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
