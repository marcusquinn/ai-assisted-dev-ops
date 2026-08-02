#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded Hashnode gql-beta reader with fixed query-only transport."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from functools import partial
from typing import Any

from _knowledge_social_hashnode import (
    HashnodeAdapterError,
    PageRequest,
    parse_page_request,
)
from _knowledge_social_hashnode_contract import (
    ApiResult,
    HashnodeReadProviderError,
    identity_record,
    object_value,
    observed_at,
    request_object,
    terminal_payload,
)
from _knowledge_social_hashnode_http import (
    MAX_RESPONSE_BYTES,
    Opener,
    ProfileConfig,
    _http_exports,
    graphql_api,
)
from _knowledge_social_hashnode_identity import account_id, provider_account_id
from _knowledge_social_hashnode_routes import IDENTITY_QUERY, page

MAX_REQUEST_BYTES = 32 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")


def _profile_prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise HashnodeReadProviderError("Hashnode profile name is invalid")
    return f"HASHNODE_{profile.upper()}"


def _profile(profile: str) -> ProfileConfig:
    prefix = _profile_prefix(profile)
    token = os.environ.get(f"{prefix}_PAT", "")
    if not token or "\x00" in token or len(token.encode()) > 16 * 1024:
        raise HashnodeReadProviderError("Hashnode profile personal access token is missing")
    return ProfileConfig(token)


def _identity(config: ProfileConfig, opener: Opener, expected_id: str) -> dict[str, Any]:
    result = graphql_api(config, opener, IDENTITY_QUERY, {})
    if result.status != 200:
        return terminal_payload(result)
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": identity_record(result.payload, expected_id),
    }


def _verify_page_account(request: PageRequest, identity: dict[str, Any]) -> None:
    if (
        identity.get("provider_account_id") != request.provider_account_id
        or identity.get("username") != request.username
        or identity.get("instance_id") != request.instance_id
        or request.account_id != account_id(identity.get("provider_account_id"))
    ):
        raise HashnodeReadProviderError(
            "selected Hashnode account does not match the configured connection"
        )


def _dispatch(
    request: dict[str, Any], config: ProfileConfig, opener: Opener
) -> dict[str, Any]:
    action = request.get("action")
    if action == "identity":
        if set(request) != {"action", "account_id"}:
            raise HashnodeReadProviderError("Hashnode identity request shape is invalid")
        return _identity(config, opener, provider_account_id(request.get("account_id")))
    if action != "page":
        raise HashnodeReadProviderError("Hashnode read action is unsupported")
    page_request = parse_page_request(request)
    verified = _identity(config, opener, page_request.provider_account_id)
    if verified.get("status") != 200:
        return verified
    identity = object_value(verified.get("data"), "account verification")
    _verify_page_account(page_request, identity)
    result = page(partial(graphql_api, config, opener), page_request)
    return terminal_payload(result) if isinstance(result, ApiResult) else result


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode()) > MAX_RESPONSE_BYTES:
        raise HashnodeReadProviderError("Hashnode read response exceeds the safety limit")
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
    except (HashnodeReadProviderError, HashnodeAdapterError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: Hashnode read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
