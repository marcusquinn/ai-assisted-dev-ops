#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded, version-gated, GET-only Lemmy account reader subprocess."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from functools import partial
from typing import Any

from _knowledge_social_lemmy import (
    ACCOUNT_AUTH_MODE,
    LemmyAdapterError,
    PageRequest,
    namespaced_id,
    parse_page_request,
    provider_account_id,
)
from _knowledge_social_lemmy_contract import (
    ApiResult,
    LemmyReadProviderError,
    exact_keys,
    identity_value,
    object_value,
    observed_at,
    request_object,
    terminal_payload,
)
from _knowledge_social_lemmy_http import (
    DISCOVERY_PATH,
    MAX_RESPONSE_BYTES,
    Opener,
    ProfileConfig,
    _canonical_base_url,
    _http_exports,
    api,
    installation_fingerprint,
)
from _knowledge_social_lemmy_v3 import page as page_v3
from _knowledge_social_lemmy_v4 import page as page_v4

MAX_REQUEST_BYTES = 32 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")


def _profile_prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise LemmyReadProviderError("Lemmy profile name is invalid")
    return f"LEMMY_{profile.upper()}"


def _profile_value(prefix: str, suffix: str, field: str, limit: int) -> str:
    value = os.environ.get(f"{prefix}_{suffix}", "")
    if not value or "\x00" in value or len(value.encode()) > limit:
        raise LemmyReadProviderError(f"Lemmy profile {field} is missing")
    return value


def _profile(profile: str) -> ProfileConfig:
    prefix = _profile_prefix(profile)
    base_url = _canonical_base_url(_profile_value(prefix, "BASE_URL", "base URL", 4096))
    token = _profile_value(prefix, "ACCESS_TOKEN", "access token", 16 * 1024)
    origin_key = _profile_value(prefix, "ORIGIN_KEY", "origin key", 16 * 1024)
    auth_mode = _profile_value(prefix, "AUTH_MODE", "auth mode", 64)
    if auth_mode != ACCOUNT_AUTH_MODE:
        raise LemmyReadProviderError("Lemmy profile must declare a user token")
    return ProfileConfig(
        base_url,
        token,
        auth_mode,
        installation_fingerprint(base_url, origin_key),
    )


def _identity(config: ProfileConfig, opener: Opener, expected_id: str) -> dict[str, Any]:
    result = api(config, opener, DISCOVERY_PATH, {})
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
    expected = namespaced_id(config.instance_id, "person", request.provider_account_id)
    checks = (
        data.get("instance_id") == request.instance_id == config.instance_id,
        data.get("provider_account_id") == request.provider_account_id,
        data.get("username") == request.username,
        data.get("ap_id") == request.ap_id,
        data.get("api_family") == request.api_family,
        data.get("exact_version") == request.exact_version,
        request.account_id == expected,
    )
    if not all(checks):
        raise LemmyReadProviderError(
            "selected Lemmy account or version does not match the configured connection"
        )


def _dispatch(
    request: dict[str, Any], config: ProfileConfig, opener: Opener
) -> dict[str, Any]:
    action = request.get("action")
    if action == "identity":
        exact_keys(request, {"action", "account_id"})
        return _identity(config, opener, provider_account_id(request.get("account_id")))
    if action != "page":
        raise LemmyReadProviderError("Lemmy read action is unsupported")
    page_request = parse_page_request(request)
    if page_request.instance_id != config.instance_id:
        raise LemmyReadProviderError(
            "selected Lemmy instance does not match the connection"
        )
    identity = _identity(config, opener, page_request.provider_account_id)
    if identity.get("status") != 200:
        return identity
    data = object_value(identity.get("data"), "account verification")
    _verify_page_account(page_request, data, config)
    read_api = partial(api, config, opener)
    result = (
        page_v4(read_api, page_request, data)
        if page_request.api_family == "v4"
        else page_v3(read_api, page_request, data)
    )
    return terminal_payload(result) if isinstance(result, ApiResult) else result


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode()) > MAX_RESPONSE_BYTES:
        raise LemmyReadProviderError("Lemmy read response exceeds the safety limit")
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
    except (LemmyReadProviderError, LemmyAdapterError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: Lemmy read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
