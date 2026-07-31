#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and deterministic fixture readers for Bluesky."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from _knowledge_social_bluesky import (
    BlueskyAdapterError,
    BlueskyProviderUnavailableError,
    PageRequest,
    did,
    service_id,
    text,
)
from _knowledge_social_fixture import FixtureSequence
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from knowledge_social_import import reject_credentials

MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SAFE_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "Bluesky profile name is invalid",
    "Bluesky profile access token is missing",
    "Bluesky profile handle is missing",
    "Bluesky OAuth profile requires DPoP support",
    "Bluesky AppView service identity is invalid",
    "Bluesky chat service identity is invalid",
    "Bluesky service URL is missing or unsafe",
    "selected Bluesky DID does not match the configured connection",
    "selected Bluesky handle does not resolve to the configured DID",
    "selected Bluesky PDS does not serve the configured DID",
    "selected Bluesky PDS does not match the authoritative DID document",
    "Bluesky service changed during collection",
)


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode()) > MAX_RESPONSE_BYTES:
        raise BlueskyAdapterError("Bluesky read response exceeds the safety limit")
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise BlueskyAdapterError("Bluesky read provider returned no valid JSON") from error
    if not isinstance(payload, dict):
        raise BlueskyAdapterError("Bluesky read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> BlueskyProviderUnavailableError:
    for message in SAFE_FAILURES:
        if f"ERROR: {message}" in stderr:
            return BlueskyProviderUnavailableError(message)
    return BlueskyProviderUnavailableError("Bluesky read provider is unavailable")


BLUESKY_READER_POLICY = GuardedOAuthPolicy(
    "Bluesky",
    "BLUESKY",
    "BLUESKY_READ_LOG",
    120,
    _decode_output,
    _provider_failure,
    BlueskyProviderUnavailableError,
    (
        "ACCESS_TOKEN",
        "HANDLE",
        "PDS_URL",
        "APPVIEW_SERVICE",
        "CHAT_SERVICE",
        "CHAT_ENABLED",
        "AUTH_MODE",
    ),
    "",
)


class GuardedBluesky(GuardedOAuthReader):
    """Run only identity and allowlisted XRPC query requests in a child."""

    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, BLUESKY_READER_POLICY)


class FixtureBluesky:
    """Deterministic substitute for service, cursor, and migration fixtures."""

    def __init__(self, path: Path) -> None:
        self.fixture = FixtureSequence(path, "Bluesky", BlueskyAdapterError)

    def identity(self, expected_id: str) -> dict[str, Any]:
        del expected_id
        return self.fixture.identity()

    def page(self, request: PageRequest) -> dict[str, Any]:
        entry = self.fixture.next_page()
        expected = entry.get("expect_request", {})
        if not isinstance(expected, dict):
            raise BlueskyAdapterError("Bluesky fixture request expectation must be an object")
        actual = request.payload()
        if any(actual.get(key) != value for key, value in expected.items()):
            raise BlueskyAdapterError("Bluesky request did not resume at the expected checkpoint")
        response = entry.get("response", entry)
        if not isinstance(response, dict):
            raise BlueskyAdapterError("Bluesky fixture page response must be an object")
        return response


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Bind mutable handle/service aliases to one stable account DID."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise BlueskyAdapterError("Bluesky account verification returned no account")
    account_did = did(data.get("did"), "account DID")
    if account_did != did(expected_id, "configured account DID"):
        raise BlueskyAdapterError("selected Bluesky DID does not match the configured connection")
    return {
        "id": account_did,
        "provider_account_id": account_did,
        "handle": text(data.get("handle"), "handle"),
        "pds_id": service_id(data.get("pds_id"), "PDS identity"),
        "appview_id": service_id(data.get("appview_id"), "AppView identity"),
        "chat_id": service_id(data.get("chat_id"), "chat identity"),
        "instance_id": service_id(data.get("instance_id"), "connection identity"),
        "name": text(data.get("display_name"), "display name", optional=True),
    }
