#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded, redirect-free, GET-only Mastodon account reader subprocess."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from functools import partial
from typing import Any

from _knowledge_social_mastodon import (
    ACCOUNT_AUTH_MODE,
    MastodonAdapterError,
    PageRequest,
    namespaced_id,
    parse_page_request,
    provider_account_id,
)
from _knowledge_social_mastodon_contract import (
    ApiResult,
    MastodonReadProviderError,
    exact_keys,
    identity_value,
    object_value,
    observed_at,
    request_object,
    terminal_payload,
)
from _knowledge_social_mastodon_http import (
    MAX_RESPONSE_BYTES,
    Opener,
    ProfileConfig,
    _canonical_base_url,
    _http_exports,
    api,
    installation_fingerprint,
)
from _knowledge_social_mastodon_routes import page

MAX_REQUEST_BYTES = 32 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")
SCOPE = re.compile(r"^[a-z]+(?::[a-z_]+)?$")
STREAM_SCOPES = {
    "authored_statuses": "read:statuses",
    "favourites": "read:favourites",
    "bookmarks": "read:bookmarks",
    "notifications": "read:notifications",
    "followers": "read:accounts",
    "following": "read:accounts",
    "followed_tags": "read:follows",
    "lists": "read:lists",
}


def _profile_prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise MastodonReadProviderError("Mastodon profile name is invalid")
    return f"MASTODON_{profile.upper()}"


def _profile_value(prefix: str, suffix: str, field: str, limit: int) -> str:
    value = os.environ.get(f"{prefix}_{suffix}", "")
    if not value or "\x00" in value or len(value.encode()) > limit:
        raise MastodonReadProviderError(f"Mastodon profile {field} is missing")
    return value


def _scopes(value: str) -> frozenset[str]:
    scopes = frozenset(value.split())
    if (
        not scopes
        or any(SCOPE.fullmatch(scope) is None for scope in scopes)
        or any(scope == "write" or scope.startswith("write:") for scope in scopes)
    ):
        raise MastodonReadProviderError("Mastodon profile scopes are invalid")
    if "read:accounts" not in scopes and "profile" not in scopes and "read" not in scopes:
        raise MastodonReadProviderError("Mastodon profile lacks account identity scope")
    return scopes


def _profile(profile: str) -> ProfileConfig:
    prefix = _profile_prefix(profile)
    base_url = _canonical_base_url(_profile_value(prefix, "BASE_URL", "base URL", 4096))
    token = _profile_value(prefix, "ACCESS_TOKEN", "access token", 16 * 1024)
    origin_key = _profile_value(prefix, "ORIGIN_KEY", "origin key", 16 * 1024)
    auth_mode = _profile_value(prefix, "AUTH_MODE", "auth mode", 64)
    scopes = _scopes(_profile_value(prefix, "SCOPES", "scopes", 4096))
    if auth_mode != ACCOUNT_AUTH_MODE:
        raise MastodonReadProviderError("Mastodon profile must declare a user token")
    return ProfileConfig(
        base_url,
        token,
        auth_mode,
        installation_fingerprint(base_url, origin_key),
        scopes,
    )


def _has_scope(config: ProfileConfig, required: str) -> bool:
    return required in config.scopes or "read" in config.scopes


def _identity(config: ProfileConfig, opener: Opener, expected_id: str) -> dict[str, Any]:
    result = api(config, opener, "/api/v1/accounts/verify_credentials", {})
    if result.status != 200:
        return terminal_payload(result)
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": identity_value(result.payload, expected_id, config.instance_id),
    }


def _verify_page_account(
    request: PageRequest, data: dict[str, Any], config: ProfileConfig
) -> None:
    expected = namespaced_id(config.instance_id, "account", request.provider_account_id)
    if (
        data.get("instance_id") != request.instance_id
        or data.get("provider_account_id") != request.provider_account_id
        or data.get("acct") != request.acct
        or request.account_id != expected
    ):
        raise MastodonReadProviderError(
            "selected Mastodon account does not match the configured connection"
        )


def _dispatch(
    request: dict[str, Any], config: ProfileConfig, opener: Opener
) -> dict[str, Any]:
    action = request.get("action")
    if action == "identity":
        exact_keys(request, {"action", "account_id"})
        return _identity(config, opener, provider_account_id(request.get("account_id")))
    if action != "page":
        raise MastodonReadProviderError("Mastodon read action is unsupported")
    page_request = parse_page_request(request)
    if page_request.instance_id != config.instance_id:
        raise MastodonReadProviderError(
            "selected Mastodon instance does not match the connection"
        )
    required_scope = STREAM_SCOPES[page_request.stream]
    if not _has_scope(config, required_scope):
        raise MastodonReadProviderError("Mastodon profile lacks the selected stream scope")
    identity = _identity(config, opener, page_request.provider_account_id)
    if identity.get("status") != 200:
        return identity
    data = object_value(identity.get("data"), "account verification")
    _verify_page_account(page_request, data, config)
    result = page(partial(api, config, opener), page_request, data)
    return terminal_payload(result) if isinstance(result, ApiResult) else result


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode()) > MAX_RESPONSE_BYTES:
        raise MastodonReadProviderError("Mastodon read response exceeds the safety limit")
    print(encoded)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        request = request_object(sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1), MAX_REQUEST_BYTES)
        config = _profile(args.profile)
        _emit(_dispatch(request, config, _http_exports()))
        return 0
    except (MastodonReadProviderError, MastodonAdapterError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: Mastodon read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
