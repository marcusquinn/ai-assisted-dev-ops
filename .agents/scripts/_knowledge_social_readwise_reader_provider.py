#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded GET-only Readwise Reader subprocess."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from functools import partial
from typing import Any

from _knowledge_social_readwise_reader import (
    PageRequest,
    ReadwiseReaderAdapterError,
    parse_page_request,
)
from _knowledge_social_readwise_reader_contract import (
    ApiResult,
    ReadwiseReaderProviderError,
    identity_value,
    object_value,
    observed_at,
    request_object,
    terminal_payload,
)
from _knowledge_social_readwise_reader_http import (
    MAX_RESPONSE_BYTES,
    Opener,
    ProfileConfig,
    _http_exports,
    api,
)
from _knowledge_social_readwise_reader_identity import (
    account_id,
    binding_account_id,
    expected_binding,
    verify_token_binding,
)
from _knowledge_social_readwise_reader_routes import page

MAX_REQUEST_BYTES = 32 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")


def _prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise ReadwiseReaderProviderError("Readwise Reader profile name is invalid")
    return f"READWISE_READER_{profile.upper()}"


def _value(prefix: str, suffix: str, field: str, limit: int) -> str:
    value = os.environ.get(f"{prefix}_{suffix}", "")
    if not value or "\x00" in value or len(value.encode()) > limit:
        raise ReadwiseReaderProviderError(f"Readwise Reader profile {field} is missing")
    return value


def _profile(profile: str) -> ProfileConfig:
    prefix = _prefix(profile)
    token = _value(prefix, "ACCESS_TOKEN", "access token", 16 * 1024)
    binding_id = binding_account_id(_value(prefix, "ACCOUNT_ID", "account ID", 128))
    key = _value(prefix, "BINDING_KEY", "binding key", 16 * 1024)
    expected = expected_binding(_value(prefix, "EXPECTED_TOKEN_BINDING", "expected token binding", 64))
    verify_token_binding(token, binding_id, key, expected)
    return ProfileConfig(token, binding_id, key, expected)


def _identity(config: ProfileConfig, opener: Opener, expected_id: str) -> dict[str, Any]:
    if binding_account_id(expected_id) != config.binding_account_id:
        raise ReadwiseReaderProviderError(
            "selected Readwise Reader account does not match the deployment binding"
        )
    result = api(config, opener, "/api/v2/auth/", {})
    if result.status != 204:
        return terminal_payload(result)
    return {
        "status": 200, "observed_at": observed_at(),
        "data": identity_value(config.binding_account_id, config.binding_key),
    }


def _verify_page_account(request: PageRequest, identity: dict[str, Any], config: ProfileConfig) -> None:
    if (
        request.binding_account_id != config.binding_account_id
        or identity.get("binding_account_id") != request.binding_account_id
        or request.account_id
        != account_id(request.binding_account_id, config.binding_key)
    ):
        raise ReadwiseReaderProviderError(
            "selected Readwise Reader account does not match the deployment binding"
        )


def _dispatch(request: dict[str, Any], config: ProfileConfig, opener: Opener) -> dict[str, Any]:
    if request.get("action") == "identity":
        if set(request) != {"action", "account_id"}:
            raise ReadwiseReaderProviderError("Readwise Reader identity request shape is invalid")
        return _identity(config, opener, binding_account_id(request.get("account_id")))
    page_request = parse_page_request(request)
    verified = _identity(config, opener, page_request.binding_account_id)
    if verified.get("status") != 200:
        return verified
    identity = object_value(verified.get("data"), "account verification")
    _verify_page_account(page_request, identity, config)
    result = page(partial(api, config, opener), page_request)
    return terminal_payload(result) if isinstance(result, ApiResult) else result


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode()) > MAX_RESPONSE_BYTES:
        raise ReadwiseReaderProviderError("Readwise Reader response exceeds the safety limit")
    print(encoded)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    args = parser.parse_args()
    try:
        request = request_object(sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1), MAX_REQUEST_BYTES)
        _emit(_dispatch(request, _profile(args.profile), _http_exports()))
        return 0
    except (ReadwiseReaderProviderError, ReadwiseReaderAdapterError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: Readwise Reader request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
