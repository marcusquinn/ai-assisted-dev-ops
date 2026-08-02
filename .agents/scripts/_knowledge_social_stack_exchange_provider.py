#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded GET-only Stack Exchange API v2.3 account reader subprocess."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from functools import partial
from typing import Any

from _knowledge_social_stack_exchange import (
    PageRequest,
    StackExchangeAdapterError,
    parse_page_request,
)
from _knowledge_social_stack_exchange_contract import (
    ApiResult,
    StackExchangeReadProviderError,
    identity_value,
    object_value,
    observed_at,
    request_object,
    terminal_payload,
    wrapper,
)
from _knowledge_social_stack_exchange_http import (
    MAX_RESPONSE_BYTES,
    Opener,
    ProfileConfig,
    _http_exports,
    api,
)
from _knowledge_social_stack_exchange_identity import (
    account_id,
    api_site_parameter,
    network_account_id,
)
from _knowledge_social_stack_exchange_routes import page

MAX_REQUEST_BYTES = 32 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")
ALLOWED_SCOPES = frozenset({"read_inbox", "private_info"})


def _profile_prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise StackExchangeReadProviderError("Stack Exchange profile name is invalid")
    return f"STACK_EXCHANGE_{profile.upper()}"


def _profile_value(prefix: str, suffix: str, field: str, limit: int) -> str:
    value = os.environ.get(f"{prefix}_{suffix}", "")
    if not value or "\x00" in value or len(value.encode()) > limit:
        raise StackExchangeReadProviderError(f"Stack Exchange profile {field} is missing")
    return value


def _profile(profile: str) -> ProfileConfig:
    prefix = _profile_prefix(profile)
    token = _profile_value(prefix, "ACCESS_TOKEN", "access token", 16 * 1024)
    site = api_site_parameter(_profile_value(prefix, "SITE", "site", 256))
    scope_text = os.environ.get(f"{prefix}_SCOPES", "")
    if "\x00" in scope_text or len(scope_text.encode()) > 4096:
        raise StackExchangeReadProviderError("Stack Exchange profile scopes are invalid")
    scopes = frozenset(scope_text.replace(",", " ").split())
    if scopes - ALLOWED_SCOPES:
        raise StackExchangeReadProviderError("Stack Exchange profile scopes are invalid")
    return ProfileConfig(token, site, scopes)


def _identity(config: ProfileConfig, opener: Opener, expected_id: str) -> dict[str, Any]:
    result = api(config, opener, "/me", {"site": config.api_site_parameter})
    if result.status != 200:
        return terminal_payload(result)
    _items, _has_more, backoff, quota = wrapper(result.payload, limit=1)
    if backoff is not None:
        return terminal_payload(ApiResult(429, {}, int(time.time()) + backoff))
    if quota == 0:
        return terminal_payload(ApiResult(429, {}))
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": identity_value(result.payload, expected_id, config.api_site_parameter),
    }


def _verify_page_account(request: PageRequest, identity: dict[str, Any]) -> None:
    if (
        identity.get("network_account_id") != request.network_account_id
        or identity.get("site_user_id") != request.site_user_id
        or identity.get("api_site_parameter") != request.api_site_parameter
        or request.account_id
        != account_id(
            identity.get("network_account_id"),
            identity.get("api_site_parameter"),
            identity.get("site_user_id"),
        )
    ):
        raise StackExchangeReadProviderError(
            "selected Stack Exchange account does not match the configured connection"
        )


def _dispatch(request: dict[str, Any], config: ProfileConfig, opener: Opener) -> dict[str, Any]:
    action = request.get("action")
    if action == "identity":
        if set(request) != {"action", "account_id"}:
            raise StackExchangeReadProviderError(
                "Stack Exchange identity request shape is invalid"
            )
        return _identity(config, opener, network_account_id(request.get("account_id")))
    if action != "page":
        raise StackExchangeReadProviderError("Stack Exchange read action is unsupported")
    page_request = parse_page_request(request)
    if page_request.api_site_parameter != config.api_site_parameter:
        raise StackExchangeReadProviderError(
            "selected Stack Exchange site does not match the connection"
        )
    if page_request.stream == "inbox" and "read_inbox" not in config.scopes:
        raise StackExchangeReadProviderError(
            "Stack Exchange profile lacks the read_inbox scope"
        )
    verified = _identity(config, opener, page_request.network_account_id)
    if verified.get("status") != 200:
        return verified
    identity = object_value(verified.get("data"), "account verification")
    _verify_page_account(page_request, identity)
    result = page(partial(api, config, opener), page_request)
    return terminal_payload(result) if isinstance(result, ApiResult) else result


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode()) > MAX_RESPONSE_BYTES:
        raise StackExchangeReadProviderError(
            "Stack Exchange read response exceeds the safety limit"
        )
    print(encoded)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        request = request_object(sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1), MAX_REQUEST_BYTES)
        _emit(_dispatch(request, _profile(args.profile), _http_exports()))
        return 0
    except (StackExchangeReadProviderError, StackExchangeAdapterError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: Stack Exchange read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
