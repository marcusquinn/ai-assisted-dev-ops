#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded, redirect-free, GET-only Ghost Content API reader subprocess."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from functools import partial
from typing import Any

from _knowledge_social_ghost import (
    ACCOUNT_AUTH_MODE,
    GhostAdapterError,
    PageRequest,
    namespaced_id,
    parse_page_request,
    provider_account_id,
)
from _knowledge_social_ghost_contract import (
    ApiResult,
    GhostReadProviderError,
    exact_keys,
    identity_value,
    object_value,
    request_object,
    required_text,
    terminal_payload,
)
from _knowledge_social_ghost_http import (
    MAX_RESPONSE_BYTES,
    Opener,
    ProfileConfig,
    _canonical_admin_url,
    _canonical_site_url,
    _http_exports,
    api,
    installation_fingerprint,
)
from _knowledge_social_ghost_routes import SITE_PATH, page

MAX_REQUEST_BYTES = 32 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")
CONTENT_KEY = re.compile(r"^[0-9a-fA-F]{16,256}$")


def _profile_prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise GhostReadProviderError("Ghost profile name is invalid")
    return f"GHOST_{profile.upper()}"


def _profile_value(prefix: str, suffix: str, field: str, limit: int) -> str:
    value = os.environ.get(f"{prefix}_{suffix}", "")
    if not value or "\x00" in value or len(value.encode()) > limit:
        raise GhostReadProviderError(f"Ghost profile {field} is missing")
    return value


def _profile(profile: str) -> ProfileConfig:
    prefix = _profile_prefix(profile)
    values = tuple(
        _profile_value(prefix, suffix, field, limit)
        for suffix, field, limit in (
            ("ADMIN_URL", "admin URL", 4096),
            ("SITE_URL", "site URL", 4096),
            ("SITE_ID", "site ID", 128),
            ("CONTENT_API_KEY", "Content API credential", 1024),
            ("ORIGIN_KEY", "origin key", 16 * 1024),
            ("AUTH_MODE", "auth mode", 64),
        )
    )
    admin_url, site_url, site_id, content_key, origin_key, auth_mode = values
    admin_url = _canonical_admin_url(admin_url)
    site_url = _canonical_site_url(site_url)
    site_id = provider_account_id(site_id)
    if CONTENT_KEY.fullmatch(content_key) is None:
        raise GhostReadProviderError("Ghost profile Content API credential is invalid")
    if auth_mode != ACCOUNT_AUTH_MODE:
        raise GhostReadProviderError(
            "Ghost profile must declare a public Content API credential"
        )
    return ProfileConfig(
        admin_url,
        site_url,
        site_id,
        content_key,
        auth_mode,
        installation_fingerprint(admin_url, origin_key),
    )


def _identity(config: ProfileConfig, opener: Opener, expected_id: str) -> dict[str, Any]:
    selected_id = provider_account_id(expected_id)
    if selected_id != config.site_id:
        raise GhostReadProviderError(
            "selected Ghost publication does not match the configured connection"
        )
    result = api(config, opener, SITE_PATH, {})
    if result.status != 200:
        return terminal_payload(result)
    site = object_value(
        object_value(result.payload, "site response").get("site"), "site"
    )
    observed_url = _canonical_site_url(required_text(site.get("url"), "site URL"))
    if observed_url != config.site_url:
        raise GhostReadProviderError(
            "selected Ghost site URL does not match the configured connection"
        )
    return {
        "status": 200,
        "data": identity_value(result.payload, selected_id, config.instance_id),
    }


def _verify_page_account(
    request: PageRequest, data: dict[str, Any], config: ProfileConfig
) -> None:
    expected = namespaced_id(config.instance_id, "site", config.site_id)
    if (
        data.get("instance_id") != request.instance_id
        or data.get("provider_account_id") != request.provider_account_id
        or data.get("site_id") != request.site_id
        or request.account_id != expected
    ):
        raise GhostReadProviderError(
            "selected Ghost publication does not match the configured connection"
        )


def _dispatch(
    request: dict[str, Any], config: ProfileConfig, opener: Opener
) -> dict[str, Any]:
    action = request.get("action")
    if action == "identity":
        exact_keys(request, {"action", "account_id"})
        return _identity(config, opener, provider_account_id(request.get("account_id")))
    if action != "page":
        raise GhostReadProviderError("Ghost read action is unsupported")
    page_request = parse_page_request(request)
    if page_request.instance_id != config.instance_id:
        raise GhostReadProviderError(
            "selected Ghost installation does not match the connection"
        )
    identity = _identity(config, opener, page_request.provider_account_id)
    if identity.get("status") != 200:
        return identity
    data = object_value(identity.get("data"), "publication verification")
    _verify_page_account(page_request, data, config)
    result = page(partial(api, config, opener), page_request, data)
    return terminal_payload(result) if isinstance(result, ApiResult) else result


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode()) > MAX_RESPONSE_BYTES:
        raise GhostReadProviderError("Ghost read response exceeds the safety limit")
    print(encoded)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    return parser.parse_args()


def _execute(profile: str) -> int:
    request = request_object(
        sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1), MAX_REQUEST_BYTES
    )
    config = _profile(profile)
    _emit(_dispatch(request, config, _http_exports()))
    return 0


def main() -> int:
    profile = parse_args().profile
    try:
        return _execute(profile)
    except (GhostReadProviderError, GhostAdapterError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: Ghost read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
