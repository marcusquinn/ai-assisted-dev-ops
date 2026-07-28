#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded, redirect-free, GET-only Discourse account reader subprocess."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from functools import partial
from typing import Any

from _knowledge_social_discourse import (
    DiscourseAdapterError,
    PageRequest,
    namespaced_id,
    parse_page_request,
    provider_account_id,
)
from _knowledge_social_discourse_contract import (
    ApiResult,
    DiscourseReadProviderError,
    exact_keys,
    identity_value,
    object_value,
    observed_at,
    request_object,
    terminal_payload,
)
from _knowledge_social_discourse_http import (
    HTTP_TIMEOUT_SECONDS,
    MAX_RESPONSE_BYTES,
    Opener,
    ProfileConfig,
    _api,
    _canonical_base_url,
    _http_exports,
    installation_fingerprint,
)
from _knowledge_social_discourse_routes import page

MAX_REQUEST_BYTES = 32 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")


def _profile_prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise DiscourseReadProviderError("Discourse profile name is invalid")
    return f"DISCOURSE_{profile.upper()}"


def _profile_value(prefix: str, suffix: str, field: str, limit: int) -> str:
    value = os.environ.get(f"{prefix}_{suffix}", "")
    if not value or "\x00" in value or len(value.encode("utf-8")) > limit:
        raise DiscourseReadProviderError(f"Discourse profile {field} is missing")
    return value


def _profile(profile: str) -> ProfileConfig:
    prefix = _profile_prefix(profile)
    base_url = _canonical_base_url(
        _profile_value(prefix, "BASE_URL", "base URL", 4096)
    )
    user_api_key = _profile_value(
        prefix, "USER_API_KEY", "user API key", 16 * 1024
    )
    origin_key = _profile_value(prefix, "ORIGIN_KEY", "origin key", 16 * 1024)
    scope = _profile_value(prefix, "USER_API_SCOPE", "user API scope", 64)
    if scope != "read":
        raise DiscourseReadProviderError(
            "Discourse user API profile must declare the read scope"
        )
    return ProfileConfig(
        base_url,
        user_api_key,
        scope,
        installation_fingerprint(base_url, origin_key),
    )


def _request() -> dict[str, Any]:
    payload = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    return request_object(payload, MAX_REQUEST_BYTES)


def _identity(
    config: ProfileConfig, opener: Opener, expected_id: str
) -> dict[str, Any]:
    result = _api(config, opener, "/session/current.json", {})
    if result.status != 200:
        return terminal_payload(result)
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": identity_value(result.payload, expected_id, config.instance_id),
    }


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise DiscourseReadProviderError(
            "Discourse read response exceeds the safety limit"
        )
    print(encoded)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    return parser.parse_args()


def _identity_action(
    request: dict[str, Any], config: ProfileConfig, opener: Opener
) -> dict[str, Any]:
    exact_keys(request, {"action", "account_id"})
    expected_id = provider_account_id(request.get("account_id"))
    return _identity(config, opener, expected_id)


def _verify_page_account(
    request: PageRequest, data: dict[str, Any], config: ProfileConfig
) -> None:
    expected_namespace = namespaced_id(
        config.instance_id, "user", request.provider_account_id
    )
    if data.get("instance_id") != request.instance_id:
        raise DiscourseReadProviderError(
            "selected Discourse account does not match the connection"
        )
    if data.get("provider_account_id") != request.provider_account_id:
        raise DiscourseReadProviderError(
            "selected Discourse account does not match the connection"
        )
    if data.get("username") != request.username:
        raise DiscourseReadProviderError(
            "selected Discourse account does not match the connection"
        )
    if request.account_id != expected_namespace:
        raise DiscourseReadProviderError(
            "selected Discourse account does not match the connection"
        )


def _page_action(
    raw_request: dict[str, Any], config: ProfileConfig, opener: Opener
) -> dict[str, Any]:
    request = parse_page_request(raw_request)
    if request.instance_id != config.instance_id:
        raise DiscourseReadProviderError(
            "selected Discourse installation does not match the connection"
        )
    identity = _identity(config, opener, request.provider_account_id)
    if identity.get("status") != 200:
        return identity
    data = object_value(identity.get("data"), "account verification")
    _verify_page_account(request, data, config)
    result = page(partial(_api, config, opener), request, data)
    if isinstance(result, ApiResult):
        return terminal_payload(result)
    return result


def _dispatch(
    request: dict[str, Any], config: ProfileConfig, opener: Opener
) -> dict[str, Any]:
    action = request.get("action")
    if action == "identity":
        return _identity_action(request, config, opener)
    if action == "page":
        return _page_action(request, config, opener)
    raise DiscourseReadProviderError("Discourse read action is unsupported")


def main() -> int:
    args = parse_args()
    try:
        raw_request = _request()
        config = _profile(args.profile)
        opener = _http_exports()
        _emit(_dispatch(raw_request, config, opener))
        return 0
    except (DiscourseReadProviderError, DiscourseAdapterError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: Discourse read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
