#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and deterministic fixture readers for Patreon collection."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from _knowledge_social_fixture import FixtureSequence
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from _knowledge_social_patreon import (
    PageRequest,
    PatreonAdapterError,
    PatreonProviderUnavailableError,
    provider_id,
    selected_campaign_ids,
)
from knowledge_social_import import reject_credentials

MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SAFE_FAILURES = (
    "Patreon profile name is invalid",
    "Patreon profile access token is missing",
    "Patreon profile campaign IDs are missing",
    "Patreon profile scopes are missing",
    "Patreon profile includes unsupported or sensitive scopes",
    "Patreon profile is missing required read scopes",
    "Patreon memberships require the membership-services purpose gate",
    "Patreon profile PII key is missing",
    "Patreon profile PII key must be at least 32 bytes",
    "selected Patreon account does not match the configured connection",
    "selected Patreon campaign is not owned by the authenticated creator",
    "Patreon campaign ownership exceeds the bounded identity page",
)


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode()) > MAX_RESPONSE_BYTES:
        raise PatreonAdapterError("Patreon read response exceeds the safety limit")
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise PatreonAdapterError("Patreon read provider returned no valid JSON") from error
    if not isinstance(payload, dict):
        raise PatreonAdapterError("Patreon read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> PatreonProviderUnavailableError:
    for message in SAFE_FAILURES:
        if f"ERROR: {message}" in stderr:
            return PatreonProviderUnavailableError(message)
    return PatreonProviderUnavailableError("Patreon read provider is unavailable")


READER_POLICY = GuardedOAuthPolicy(
    "Patreon",
    "PATREON",
    "PATREON_READ_LOG",
    120,
    _decode_output,
    _provider_failure,
    PatreonProviderUnavailableError,
    (
        "ACCESS_TOKEN",
        "CAMPAIGN_IDS",
        "SCOPES",
        "PII_KEY",
        "MEMBER_DATA_PURPOSE",
    ),
)


def _fixture_page(fixture: FixtureSequence, request: PageRequest) -> dict[str, Any]:
    entry = fixture.next_page()
    expectation = entry.get("expect_request", {})
    if not isinstance(expectation, dict):
        raise PatreonAdapterError("Patreon fixture expectation must be an object")
    actual = request.payload()
    if any(actual.get(key) != value for key, value in expectation.items()):
        raise PatreonAdapterError("Patreon request did not resume at the expected checkpoint")
    response = entry.get("response", entry)
    if not isinstance(response, dict):
        raise PatreonAdapterError("Patreon fixture page response must be an object")
    return response


class GuardedPatreon(GuardedOAuthReader):
    """Execute only identity and allowlisted GET reads in a bounded child."""

    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, READER_POLICY)


class FixturePatreon:
    """Deterministic HTTP substitute for pagination and failure fixtures."""

    def __init__(self, path: Path) -> None:
        self.fixture = FixtureSequence(path, "Patreon", PatreonAdapterError)

    def identity(self, expected_id: str) -> dict[str, Any]:
        del expected_id
        return self.fixture.identity()

    def page(self, request: PageRequest) -> dict[str, Any]:
        return _fixture_page(self.fixture, request)


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Bind every run to one creator and an explicit owned-campaign allowlist."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise PatreonAdapterError("Patreon account verification returned no account")
    remote_id = provider_id(data.get("provider_account_id"), "account ID")
    if remote_id != provider_id(expected_id, "selected account ID"):
        raise PatreonAdapterError(
            "selected Patreon account does not match the configured connection"
        )
    if data.get("role") != "creator" or data.get("is_creator") is not True:
        raise PatreonAdapterError("selected Patreon account is not an active creator")
    campaigns = selected_campaign_ids(data.get("campaign_ids"))
    authorized = data.get("member_data_authorized")
    if not isinstance(authorized, bool):
        raise PatreonAdapterError("Patreon member-data authorization is invalid")
    return {
        "id": remote_id,
        "provider_account_id": remote_id,
        "role": "creator",
        "is_creator": True,
        "campaign_ids": list(campaigns),
        "member_data_authorized": authorized,
    }
