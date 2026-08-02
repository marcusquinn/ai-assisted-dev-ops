#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded FreshRSS GReader account subprocess with one login POST."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from functools import partial
from typing import Any

from _knowledge_social_freshrss import (
    FreshRSSAdapterError,
    PageRequest,
    parse_page_request,
)
from _knowledge_social_freshrss_contract import (
    ApiResult,
    FreshRSSReadProviderError,
    identity_value,
    object_value,
    observed_at,
    request_object,
    terminal_payload,
)
from _knowledge_social_freshrss_http import (
    MAX_RESPONSE_BYTES,
    Opener,
    ProfileConfig,
    _http_exports,
    api,
    login,
)
from _knowledge_social_freshrss_identity import (
    account_id,
    canonical_base_url,
    installation_id,
    user_id,
)
from _knowledge_social_freshrss_routes import IDENTITY_PATH, page

MAX_REQUEST_BYTES = 32 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")


def _profile_prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise FreshRSSReadProviderError("FreshRSS profile name is invalid")
    return f"FRESHRSS_{profile.upper()}"


def _profile_value(prefix: str, suffix: str, field: str, limit: int) -> str:
    value = os.environ.get(f"{prefix}_{suffix}", "")
    if not value or "\x00" in value or len(value.encode()) > limit:
        raise FreshRSSReadProviderError(f"FreshRSS profile {field} is missing")
    return value


def _profile(profile: str) -> ProfileConfig:
    prefix = _profile_prefix(profile)
    base = canonical_base_url(_profile_value(prefix, "BASE_URL", "base URL", 4096))
    username = user_id(_profile_value(prefix, "USERNAME", "username", 4096))
    password = _profile_value(prefix, "API_PASSWORD", "API password", 16 * 1024)
    origin_key = _profile_value(prefix, "ORIGIN_KEY", "origin key", 16 * 1024)
    return ProfileConfig(
        base,
        username,
        password,
        origin_key,
        installation_id(base, origin_key),
    )


def _authorize(config: ProfileConfig, opener: Opener) -> ApiResult:
    result = login(config, opener)
    if result.status != 200:
        return result
    if not isinstance(result.payload, str):
        raise FreshRSSReadProviderError("FreshRSS login response is invalid")
    return result


def _identity(
    config: ProfileConfig,
    opener: Opener,
    expected_id: str,
    authorization: ApiResult | None = None,
) -> dict[str, Any]:
    authorized = authorization or _authorize(config, opener)
    if authorized.status != 200:
        return terminal_payload(authorized)
    result = api(config, opener, authorized.payload, IDENTITY_PATH, {})
    if result.status != 200:
        return terminal_payload(result)
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": identity_value(result.payload, expected_id, config.installation_id),
    }


def _verify_page_account(request: PageRequest, identity: dict[str, Any]) -> None:
    if (
        identity.get("installation_id") != request.installation_id
        or identity.get("user_id") != request.user_id
        or request.account_id
        != account_id(identity.get("installation_id"), identity.get("user_id"))
    ):
        raise FreshRSSReadProviderError(
            "selected FreshRSS account does not match the configured connection"
        )


def _identity_action(
    request: dict[str, Any], config: ProfileConfig, opener: Opener
) -> dict[str, Any]:
    if set(request) != {"action", "account_id"}:
        raise FreshRSSReadProviderError("FreshRSS identity request shape is invalid")
    return _identity(config, opener, user_id(request.get("account_id")))


def _page_action(
    request: dict[str, Any], config: ProfileConfig, opener: Opener
) -> dict[str, Any]:
    page_request = parse_page_request(request)
    if page_request.installation_id != config.installation_id:
        raise FreshRSSReadProviderError(
            "selected FreshRSS installation does not match the connection"
        )
    authorized = _authorize(config, opener)
    if authorized.status != 200:
        return terminal_payload(authorized)
    verified = _identity(config, opener, page_request.user_id, authorized)
    if verified.get("status") != 200:
        return verified
    identity = object_value(verified.get("data"), "account verification")
    _verify_page_account(page_request, identity)
    result = page(partial(api, config, opener, authorized.payload), page_request)
    return terminal_payload(result) if isinstance(result, ApiResult) else result


def _dispatch(
    request: dict[str, Any], config: ProfileConfig, opener: Opener
) -> dict[str, Any]:
    action = request.get("action")
    if action == "identity":
        return _identity_action(request, config, opener)
    if action == "page":
        return _page_action(request, config, opener)
    raise FreshRSSReadProviderError("FreshRSS read action is unsupported")


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode()) > MAX_RESPONSE_BYTES:
        raise FreshRSSReadProviderError("FreshRSS read response exceeds the safety limit")
    print(encoded)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        request = request_object(
            sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1), MAX_REQUEST_BYTES
        )
        _emit(_dispatch(request, _profile(args.profile), _http_exports()))
        return 0
    except (FreshRSSReadProviderError, FreshRSSAdapterError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: FreshRSS read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
