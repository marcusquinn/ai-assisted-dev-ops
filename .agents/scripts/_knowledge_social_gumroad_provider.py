#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded, redirect-free, GET-only Gumroad seller reader subprocess."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

from _knowledge_social_gumroad import (
    GumroadAdapterError,
    PageRequest,
    parse_page_request,
    seller_id,
)
from _knowledge_social_gumroad_records import (
    object_list,
    object_value,
    payout_record,
    product_record,
    sale_record,
    text_value,
)

API_ROOT = "https://api.gumroad.com/v2"
MAX_REQUEST_BYTES = 32 * 1024
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")
ROUTES = {"profile": "/user", "products": "/products", "sales": "/sales", "payouts": "/payouts"}
COLLECTION_KEYS = {"products": "products", "sales": "sales", "payouts": "payouts"}


class GumroadReadProviderError(RuntimeError):
    """Raised for a privacy-safe local provider failure."""


class RejectRedirects(HTTPRedirectHandler):
    """Reject redirects so bearer credentials never cross origins."""

    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


@dataclass(frozen=True)
class Profile:
    access_token: str
    pii_key: bytes


@dataclass(frozen=True)
class ApiResult:
    status: int
    payload: Any
    retry_after: str | None = None


def _observed_at() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _profile(profile: str) -> Profile:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise GumroadReadProviderError("Gumroad profile name is invalid")
    prefix = f"GUMROAD_{profile.upper()}"
    token = os.environ.get(f"{prefix}_ACCESS_TOKEN", "")
    pii_key = os.environ.get(f"{prefix}_PII_KEY", "")
    if not token or "\x00" in token or len(token.encode()) > 16 * 1024:
        raise GumroadReadProviderError("Gumroad profile access token is missing")
    if not pii_key or "\x00" in pii_key or len(pii_key.encode()) > 16 * 1024:
        raise GumroadReadProviderError("Gumroad profile PII key is missing")
    if len(pii_key.encode()) < 32:
        raise GumroadReadProviderError("Gumroad profile PII key must be at least 32 bytes")
    return Profile(token, pii_key.encode())


def _request(profile: Profile, path: str, params: dict[str, str]) -> ApiResult:
    if path not in ROUTES.values():
        raise GumroadReadProviderError("Gumroad read route is unsupported")
    query = f"?{urlencode(params)}" if params else ""
    request = Request(
        f"{API_ROOT}{path}{query}",
        headers={"Accept": "application/json", "Authorization": f"Bearer {profile.access_token}"},
        method="GET",
    )
    try:
        with build_opener(RejectRedirects).open(request, timeout=60) as response:
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            status = int(response.status)
            retry_after = response.headers.get("Retry-After")
    except HTTPError as error:
        status = int(error.code)
        payload = b"{}"
        retry_after = error.headers.get("Retry-After") if error.headers else None
    except (OSError, URLError) as error:
        raise GumroadReadProviderError("Gumroad API request failed") from error
    if len(payload) > MAX_RESPONSE_BYTES:
        raise GumroadReadProviderError("Gumroad API response exceeds the byte safety limit")
    try:
        decoded = json.loads(payload.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise GumroadReadProviderError("Gumroad API returned no valid JSON") from error
    retry = retry_after if isinstance(retry_after, str) and retry_after.isdigit() else None
    return ApiResult(status, decoded, retry)


def _terminal(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {"status": result.status, "observed_at": _observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload


def _identity(profile: Profile, expected_id: str) -> dict[str, Any]:
    result = _request(profile, "/user", {})
    if result.status != 200:
        return _terminal(result)
    root = object_value(result.payload, "identity response")
    if root.get("success") is not True:
        return {"status": 502, "observed_at": _observed_at()}
    user = object_value(root.get("user"), "identity user")
    remote_id = seller_id(user.get("user_id"), "account ID")
    if remote_id != seller_id(expected_id, "selected account ID"):
        raise GumroadReadProviderError("selected Gumroad account does not match the configured connection")
    return {
        "status": 200,
        "observed_at": _observed_at(),
        "data": {
            "provider_account_id": remote_id,
            "username": text_value(user.get("url"), "account URL"),
            "display_name": text_value(user.get("name"), "account name"),
        },
    }


def _page(profile: Profile, request: PageRequest, identity: dict[str, Any]) -> dict[str, Any]:
    if identity.get("provider_account_id") != request.provider_account_id:
        raise GumroadReadProviderError("selected Gumroad account does not match the configured connection")
    if request.stream == "profile":
        return {
            "status": 200,
            "observed_at": _observed_at(),
            "data": [{"kind": "seller_profile", "remote_id": request.account_id, "name": identity.get("display_name")}],
            "meta": {"stream": "profile", "next_page_key": None, "newest_id": request.account_id, "reached_watermark": False, "complete": True},
        }
    params = {"page_key": request.page_key} if request.page_key else {}
    result = _request(profile, ROUTES[request.stream], params)
    if result.status != 200:
        return _terminal(result)
    root = object_value(result.payload, f"{request.stream} response")
    if root.get("success") is not True:
        return {"status": 502, "observed_at": _observed_at()}
    values = object_list(root.get(COLLECTION_KEYS[request.stream]), request.stream, 100)
    converters = {
        "products": product_record,
        "sales": lambda item: sale_record(profile.pii_key, item),
        "payouts": payout_record,
    }
    converted = [converters[request.stream](item) for item in values]
    reached = False
    if request.stop_at:
        retained = []
        for item in converted:
            if item["remote_id"] == request.stop_at:
                reached = True
                break
            retained.append(item)
        converted = retained
    if len(converted) > request.limit:
        raise GumroadReadProviderError("Gumroad page exceeds the configured item safety limit")
    next_key = text_value(root.get("next_page_key"), "next page key")
    complete = reached or next_key is None
    return {
        "status": 200,
        "observed_at": _observed_at(),
        "data": converted,
        "meta": {
            "stream": request.stream,
            "next_page_key": None if complete else next_key,
            "newest_id": converted[0]["remote_id"] if converted else None,
            "reached_watermark": reached,
            "complete": complete,
        },
    }


def _request_object(payload: bytes) -> dict[str, Any]:
    if len(payload) > MAX_REQUEST_BYTES:
        raise GumroadReadProviderError("Gumroad read request exceeds the safety limit")
    try:
        request = json.loads(payload.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise GumroadReadProviderError("Gumroad read request is not valid JSON") from error
    return object_value(request, "read request")


def _dispatch(request: dict[str, Any], profile: Profile) -> dict[str, Any]:
    action = request.get("action")
    if action == "identity":
        if set(request) != {"action", "account_id"}:
            raise GumroadReadProviderError("Gumroad read request has an invalid action shape")
        return _identity(profile, seller_id(request.get("account_id"), "selected account ID"))
    if action != "page":
        raise GumroadReadProviderError("Gumroad read action is unsupported")
    page_request = parse_page_request(request)
    identity_result = _identity(profile, page_request.provider_account_id)
    if identity_result.get("status") != 200:
        return identity_result
    identity = object_value(identity_result.get("data"), "verified identity")
    return _page(profile, page_request, identity)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    args = parser.parse_args()
    try:
        payload = _dispatch(_request_object(sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)), _profile(args.profile))
        encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
        if len(encoded.encode()) > MAX_RESPONSE_BYTES:
            raise GumroadReadProviderError("Gumroad read response exceeds the safety limit")
        print(encoded)
        return 0
    except (GumroadReadProviderError, GumroadAdapterError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - redact provider and customer internals
        print("ERROR: Gumroad read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
