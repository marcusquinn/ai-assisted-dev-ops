#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded GET-only XRPC subprocess for Bluesky account collection."""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any

from _knowledge_social_bluesky import BlueskyAdapterError, PageRequest, did, parse_page_request
from _knowledge_social_bluesky_http import (
    MAX_REQUEST_BYTES,
    MAX_RESPONSE_BYTES,
    Profile,
    api,
    connection_id,
    observed_at,
    profile_from_environment,
    service_id,
    terminal_payload,
)
from _knowledge_social_bluesky_identity import resolve_pds
from _knowledge_social_bluesky_routes import page


def identity(profile: Profile, expected_id: str) -> dict[str, Any]:
    """Verify handle resolution and current PDS ownership for one stable DID."""
    account_did = did(expected_id, "configured account DID")
    if resolve_pds(account_did) != profile.pds:
        raise BlueskyAdapterError(
            "selected Bluesky PDS does not match the authoritative DID document"
        )
    describe = api(
        profile,
        profile.pds,
        "com.atproto.repo.describeRepo",
        {"repo": account_did},
    )
    if describe.status != 200:
        return terminal_payload(describe)
    resolved = api(
        profile,
        profile.pds,
        "com.atproto.identity.resolveHandle",
        {"handle": profile.handle},
    )
    if resolved.status != 200:
        return terminal_payload(resolved)
    if describe.payload.get("did") != account_did:
        raise BlueskyAdapterError("selected Bluesky PDS does not serve the configured DID")
    if resolved.payload.get("did") != account_did:
        raise BlueskyAdapterError("selected Bluesky handle does not resolve to the configured DID")
    current_handle = describe.payload.get("handle")
    if not isinstance(current_handle, str) or not current_handle:
        current_handle = profile.handle
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": {
            "did": account_did,
            "handle": current_handle,
            "pds_id": service_id(profile.pds),
            "appview_id": service_id(profile.appview),
            "chat_id": service_id(profile.chat),
            "instance_id": connection_id(account_did, profile),
            "auth_mode": profile.auth_mode,
        },
    }


def _read_request() -> dict[str, Any]:
    payload = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    if len(payload) > MAX_REQUEST_BYTES:
        raise BlueskyAdapterError("Bluesky read request exceeds the safety limit")
    try:
        value = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise BlueskyAdapterError("Bluesky read request is not valid JSON") from error
    if not isinstance(value, dict):
        raise BlueskyAdapterError("Bluesky read request root must be an object")
    return value


def _expected_service(data: dict[str, Any], request: PageRequest) -> Any:
    field = "pds_id" if request.authority == "sync" else f"{request.authority}_id"
    return data.get(field)


def _verified_page(profile: Profile, request: PageRequest) -> dict[str, Any]:
    verified = identity(profile, request.account_id)
    if verified.get("status") != 200:
        return verified
    data = verified.get("data")
    if not isinstance(data, dict) or _expected_service(data, request) != request.service_id:
        raise BlueskyAdapterError("Bluesky service changed during collection")
    return page(profile, request)


def handle_request(profile: Profile, raw: dict[str, Any]) -> dict[str, Any]:
    """Dispatch only the two exact child-process actions."""
    action = raw.get("action")
    if action == "identity" and set(raw) == {"action", "account_id"}:
        return identity(profile, did(raw.get("account_id"), "account DID"))
    if action == "page":
        return _verified_page(profile, parse_page_request(raw))
    raise BlueskyAdapterError("Bluesky read action is unsupported")


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode()) > MAX_RESPONSE_BYTES:
        raise BlueskyAdapterError("Bluesky read response exceeds the safety limit")
    print(encoded)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    return parser.parse_args()


def run(profile_name: str) -> int:
    """Run one redacted child invocation."""
    try:
        _emit(handle_request(profile_from_environment(profile_name), _read_request()))
        return 0
    except BlueskyAdapterError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - redact transport and credential internals
        print("ERROR: Bluesky read provider request failed", file=sys.stderr)
        return 1


def main() -> int:
    return run(parse_args().profile)


if __name__ == "__main__":
    raise SystemExit(main())
