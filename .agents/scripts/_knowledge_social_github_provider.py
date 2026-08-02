#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded GitHub.com reader with GET-only REST and fixed GraphQL queries."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from functools import partial
from typing import Any

from _knowledge_social_github import GitHubAdapterError, PageRequest, parse_page_request
from _knowledge_social_github_contract import (
    ApiResult,
    GitHubReadProviderError,
    combined_identity,
    object_value,
    observed_at,
    request_object,
    terminal_payload,
)
from _knowledge_social_github_http import (
    MAX_RESPONSE_BYTES,
    Opener,
    ProfileConfig,
    _http_exports,
    graphql_api,
    rest_api,
)
from _knowledge_social_github_identity import INSTANCE_ID, account_id, provider_account_id
from _knowledge_social_github_routes import IDENTITY_QUERY, page

MAX_REQUEST_BYTES = 32 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")
TOKEN_FAMILIES = frozenset({"classic_pat", "fine_grained_pat", "oauth_user_token"})
STREAM_CAPABILITIES = {
    "contributions": frozenset(TOKEN_FAMILIES),
    "repositories": frozenset(TOKEN_FAMILIES),
    "stars": frozenset(TOKEN_FAMILIES),
    "notifications": frozenset({"classic_pat", "oauth_user_token"}),
    "followers": frozenset(TOKEN_FAMILIES),
    "following": frozenset(TOKEN_FAMILIES),
    "organizations": frozenset(TOKEN_FAMILIES),
    "subscriptions": frozenset(TOKEN_FAMILIES),
    "user_lists": frozenset(TOKEN_FAMILIES),
    "projects_v2": frozenset(TOKEN_FAMILIES),
}


def _profile_prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise GitHubReadProviderError("GitHub profile name is invalid")
    return f"GITHUB_{profile.upper()}"


def _profile_value(prefix: str, suffix: str, field: str, limit: int) -> str:
    value = os.environ.get(f"{prefix}_{suffix}", "")
    if not value or "\x00" in value or len(value.encode()) > limit:
        raise GitHubReadProviderError(f"GitHub profile {field} is missing")
    return value


def _profile(profile: str) -> ProfileConfig:
    prefix = _profile_prefix(profile)
    token = _profile_value(prefix, "ACCESS_TOKEN", "access token", 16 * 1024)
    family = _profile_value(prefix, "TOKEN_FAMILY", "token family", 64)
    if family not in TOKEN_FAMILIES:
        raise GitHubReadProviderError("GitHub profile token family is invalid")
    scope_text = os.environ.get(f"{prefix}_SCOPES", "")
    if "\x00" in scope_text or len(scope_text.encode()) > 4096:
        raise GitHubReadProviderError("GitHub profile scopes are invalid")
    scopes = frozenset(part.strip() for part in scope_text.split(",") if part.strip())
    return ProfileConfig(token, family, scopes)


def _identity(config: ProfileConfig, opener: Opener, expected_id: str) -> dict[str, Any]:
    rest = rest_api(config, opener, "/user", {})
    if rest.status != 200:
        return terminal_payload(rest)
    graph = graphql_api(config, opener, IDENTITY_QUERY, {})
    if graph.status != 200:
        return terminal_payload(graph)
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": combined_identity(rest.payload, graph.payload, expected_id),
    }


def _verify_page_account(request: PageRequest, identity: dict[str, Any]) -> None:
    if (
        identity.get("instance_id") != INSTANCE_ID
        or identity.get("provider_account_id") != request.provider_account_id
        or identity.get("login") != request.login
        or request.account_id
        != account_id(identity.get("provider_account_id"), identity.get("node_id"))
    ):
        raise GitHubReadProviderError(
            "selected GitHub account does not match the configured connection"
        )


def _dispatch(request: dict[str, Any], config: ProfileConfig, opener: Opener) -> dict[str, Any]:
    action = request.get("action")
    if action == "identity":
        if set(request) != {"action", "account_id"}:
            raise GitHubReadProviderError("GitHub identity request shape is invalid")
        return _identity(config, opener, provider_account_id(request.get("account_id")))
    if action != "page":
        raise GitHubReadProviderError("GitHub read action is unsupported")
    page_request = parse_page_request(request)
    if config.token_family not in STREAM_CAPABILITIES[page_request.stream]:
        raise GitHubReadProviderError(
            "GitHub profile token family cannot read the selected stream"
        )
    verified = _identity(config, opener, page_request.provider_account_id)
    if verified.get("status") != 200:
        return verified
    identity = object_value(verified.get("data"), "account verification")
    _verify_page_account(page_request, identity)
    result = page(
        partial(rest_api, config, opener),
        partial(graphql_api, config, opener),
        page_request,
    )
    return terminal_payload(result) if isinstance(result, ApiResult) else result


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode()) > MAX_RESPONSE_BYTES:
        raise GitHubReadProviderError("GitHub read response exceeds the safety limit")
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
    except (GitHubReadProviderError, GitHubAdapterError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: GitHub read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
