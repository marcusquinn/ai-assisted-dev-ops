#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded GET-only Miniflux account reader subprocess."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from functools import partial
from typing import Any

from _knowledge_social_miniflux import MinifluxAdapterError, PageRequest, parse_page_request
from _knowledge_social_miniflux_contract import (
    ApiResult,
    MinifluxReadProviderError,
    identity_value,
    object_value,
    observed_at,
    request_object,
    terminal_payload,
)
from _knowledge_social_miniflux_http import (
    MAX_RESPONSE_BYTES,
    Opener,
    ProfileConfig,
    _http_exports,
    api,
)
from _knowledge_social_miniflux_identity import (
    account_id,
    canonical_base_url,
    installation_id,
    user_id,
)
from _knowledge_social_miniflux_routes import page

MAX_REQUEST_BYTES = 32 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")


def _profile_prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise MinifluxReadProviderError("Miniflux profile name is invalid")
    return f"MINIFLUX_{profile.upper()}"


def _profile_value(prefix: str, suffix: str, field: str, limit: int) -> str:
    value = os.environ.get(f"{prefix}_{suffix}", "")
    if not value or "\x00" in value or len(value.encode()) > limit:
        raise MinifluxReadProviderError(f"Miniflux profile {field} is missing")
    return value


def _profile(profile: str) -> ProfileConfig:
    prefix = _profile_prefix(profile)
    base = canonical_base_url(_profile_value(prefix, "BASE_URL", "base URL", 4096))
    token = _profile_value(prefix, "API_TOKEN", "API token", 16 * 1024)
    origin_key = _profile_value(prefix, "ORIGIN_KEY", "origin key", 16 * 1024)
    return ProfileConfig(base, token, origin_key, installation_id(base, origin_key))


def _identity(config: ProfileConfig, opener: Opener, expected_id: str) -> dict[str, Any]:
    result = api(config, opener, "/v1/me", {})
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
        raise MinifluxReadProviderError(
            "selected Miniflux account does not match the configured connection"
        )


def _dispatch(request: dict[str, Any], config: ProfileConfig, opener: Opener) -> dict[str, Any]:
    action = request.get("action")
    if action == "identity":
        if set(request) != {"action", "account_id"}:
            raise MinifluxReadProviderError("Miniflux identity request shape is invalid")
        return _identity(config, opener, user_id(request.get("account_id")))
    if action != "page":
        raise MinifluxReadProviderError("Miniflux read action is unsupported")
    page_request = parse_page_request(request)
    if page_request.installation_id != config.installation_id:
        raise MinifluxReadProviderError(
            "selected Miniflux installation does not match the connection"
        )
    verified = _identity(config, opener, page_request.user_id)
    if verified.get("status") != 200:
        return verified
    identity = object_value(verified.get("data"), "account verification")
    _verify_page_account(page_request, identity)
    result = page(partial(api, config, opener), page_request)
    return terminal_payload(result) if isinstance(result, ApiResult) else result


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode()) > MAX_RESPONSE_BYTES:
        raise MinifluxReadProviderError("Miniflux read response exceeds the safety limit")
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
    except (MinifluxReadProviderError, MinifluxAdapterError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: Miniflux read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
