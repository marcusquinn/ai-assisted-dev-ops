#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded, redirect-free, GET-only Forem account reader subprocess."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from functools import partial
from typing import Any

from _knowledge_social_forem import (
    ACCOUNT_AUTH_MODE,
    ForemAdapterError,
    PageRequest,
    namespaced_id,
    parse_page_request,
    provider_account_id,
)
from _knowledge_social_forem_contract import (
    ApiResult,
    ForemReadProviderError,
    exact_keys,
    identity_value,
    object_value,
    observed_at,
    request_object,
    terminal_payload,
)
from _knowledge_social_forem_http import (
    MAX_RESPONSE_BYTES,
    Opener,
    ProfileConfig,
    _canonical_base_url,
    _http_exports,
    api,
    installation_fingerprint,
)
from _knowledge_social_forem_routes import page

MAX_REQUEST_BYTES = 32 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")


def _profile_prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise ForemReadProviderError("Forem profile name is invalid")
    return f"FOREM_{profile.upper()}"


def _profile_value(prefix: str, suffix: str, field: str, limit: int) -> str:
    value = os.environ.get(f"{prefix}_{suffix}", "")
    if not value or "\x00" in value or len(value.encode()) > limit:
        raise ForemReadProviderError(f"Forem profile {field} is missing")
    return value


def _profile(profile: str) -> ProfileConfig:
    prefix = _profile_prefix(profile)
    values = tuple(
        _profile_value(prefix, suffix, field, limit)
        for suffix, field, limit in (
            ("BASE_URL", "base URL", 4096),
            ("API_KEY", "API key", 16 * 1024),
            ("ORIGIN_KEY", "origin key", 16 * 1024),
            ("AUTH_MODE", "auth mode", 64),
        )
    )
    base_url, api_key, origin_key, auth_mode = values
    base_url = _canonical_base_url(base_url)
    if auth_mode != ACCOUNT_AUTH_MODE:
        raise ForemReadProviderError(
            "Forem profile must declare a user-generated API key"
        )
    return ProfileConfig(
        base_url,
        api_key,
        auth_mode,
        installation_fingerprint(base_url, origin_key),
    )


def _identity(config: ProfileConfig, opener: Opener, expected_id: str) -> dict[str, Any]:
    result = api(config, opener, "/api/users/me", {})
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
    expected = namespaced_id(config.instance_id, "user", request.provider_account_id)
    if (
        data.get("instance_id") != request.instance_id
        or data.get("provider_account_id") != request.provider_account_id
        or data.get("username") != request.username
        or request.account_id != expected
    ):
        raise ForemReadProviderError(
            "selected Forem account does not match the configured connection"
        )


def _dispatch(
    request: dict[str, Any], config: ProfileConfig, opener: Opener
) -> dict[str, Any]:
    action = request.get("action")
    if action == "identity":
        exact_keys(request, {"action", "account_id"})
        return _identity(config, opener, provider_account_id(request.get("account_id")))
    if action != "page":
        raise ForemReadProviderError("Forem read action is unsupported")
    page_request = parse_page_request(request)
    if page_request.instance_id != config.instance_id:
        raise ForemReadProviderError(
            "selected Forem installation does not match the connection"
        )
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
        raise ForemReadProviderError("Forem read response exceeds the safety limit")
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
    except (ForemReadProviderError, ForemAdapterError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: Forem read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
