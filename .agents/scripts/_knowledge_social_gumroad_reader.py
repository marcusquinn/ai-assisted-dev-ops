#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and deterministic fixture readers for Gumroad collection."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from _knowledge_social_fixture import FixtureSequence
from _knowledge_social_gumroad import (
    GumroadAdapterError,
    GumroadProviderUnavailableError,
    PageRequest,
    seller_id,
)
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from knowledge_social_import import reject_credentials

MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SAFE_FAILURES = (
    "Gumroad profile name is invalid",
    "Gumroad profile access token is missing",
    "Gumroad profile PII key is missing",
    "Gumroad profile PII key must be at least 32 bytes",
    "selected Gumroad account does not match the configured connection",
)


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode()) > MAX_RESPONSE_BYTES:
        raise GumroadAdapterError("Gumroad read response exceeds the safety limit")
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise GumroadAdapterError("Gumroad read provider returned no valid JSON") from error
    if not isinstance(payload, dict):
        raise GumroadAdapterError("Gumroad read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> GumroadProviderUnavailableError:
    for message in SAFE_FAILURES:
        if f"ERROR: {message}" in stderr:
            return GumroadProviderUnavailableError(message)
    return GumroadProviderUnavailableError("Gumroad read provider is unavailable")


READER_POLICY = GuardedOAuthPolicy(
    "Gumroad",
    "GUMROAD",
    "GUMROAD_READ_LOG",
    120,
    _decode_output,
    _provider_failure,
    GumroadProviderUnavailableError,
    ("ACCESS_TOKEN", "PII_KEY"),
)


def _fixture_page(fixture: FixtureSequence, request: PageRequest) -> dict[str, Any]:
    entry = fixture.next_page()
    expectation = entry.get("expect_request", {})
    if not isinstance(expectation, dict):
        raise GumroadAdapterError("Gumroad fixture expectation must be an object")
    actual = request.payload()
    if any(actual.get(key) != value for key, value in expectation.items()):
        raise GumroadAdapterError(
            "Gumroad request did not resume at the expected checkpoint"
        )
    response = entry.get("response", entry)
    if not isinstance(response, dict):
        raise GumroadAdapterError("Gumroad fixture page response must be an object")
    return response


class GuardedGumroad(GuardedOAuthReader):
    """Execute only identity and allowlisted GET reads in a bounded child."""

    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, READER_POLICY)


class FixtureGumroad:
    """Deterministic HTTP substitute for pagination and failure fixtures."""

    def __init__(self, path: Path) -> None:
        self.fixture = FixtureSequence(path, "Gumroad", GumroadAdapterError)

    def identity(self, expected_id: str) -> dict[str, Any]:
        del expected_id
        return self.fixture.identity()

    def page(self, request: PageRequest) -> dict[str, Any]:
        return _fixture_page(self.fixture, request)


def _optional_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value or len(value.encode()) > 4096:
        raise GumroadAdapterError(f"Gumroad account {field} must be bounded text")
    return value


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Bind every run to the exact seller returned by GET /v2/user."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise GumroadAdapterError("Gumroad account verification returned no account")
    remote_id = seller_id(data.get("provider_account_id"), "account ID")
    if remote_id != seller_id(expected_id, "selected account ID"):
        raise GumroadAdapterError("selected Gumroad account does not match the configured connection")
    return {
        "id": remote_id,
        "provider_account_id": remote_id,
        "username": _optional_text(data.get("username"), "username"),
        "name": _optional_text(data.get("display_name"), "display name"),
    }
