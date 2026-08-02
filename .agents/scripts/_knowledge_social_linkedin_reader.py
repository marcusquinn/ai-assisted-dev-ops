#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and fixture readers for LinkedIn Member Snapshot data."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_fixture import FixturePageReader
from _knowledge_social_linkedin import (
    LinkedInAdapterError,
    LinkedInProviderUnavailableError,
    PageRequest,
    member_id,
)
from _knowledge_social_oauth_reader import (
    GuardedOAuthPolicy,
    GuardedOAuthReader,
)
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SAFE_PROVIDER_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "LinkedIn OAuth profile access token is missing",
    "LinkedIn OAuth profile name is invalid",
    "selected LinkedIn member does not match the configured connection",
)


class LinkedInReader(Protocol):
    """Minimal GET-only provider surface used by collection."""

    def identity(self, expected_id: str) -> dict[str, Any]: ...

    def page(self, request: PageRequest) -> dict[str, Any]: ...


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise LinkedInAdapterError("LinkedIn read response exceeds the safety limit")
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise LinkedInAdapterError(
            "LinkedIn read provider returned no valid JSON"
        ) from error
    if not isinstance(payload, dict):
        raise LinkedInAdapterError("LinkedIn read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> LinkedInProviderUnavailableError:
    for message in SAFE_PROVIDER_FAILURES:
        if f"ERROR: {message}" in stderr:
            return LinkedInProviderUnavailableError(message)
    return LinkedInProviderUnavailableError("LinkedIn read provider is unavailable")


LINKEDIN_OAUTH_POLICY = GuardedOAuthPolicy(
    "LinkedIn",
    "LINKEDIN",
    "LINKEDIN_READ_LOG",
    READ_TIMEOUT_SECONDS,
    _decode_output,
    _provider_failure,
    LinkedInProviderUnavailableError,
)


class GuardedLinkedInOAuth(GuardedOAuthReader):
    """Execute only identity and allowlisted snapshot GETs in a bounded child."""

    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, LINKEDIN_OAUTH_POLICY)


class FixtureLinkedIn(FixturePageReader):
    """Deterministic OAuth substitute for pagination and failure fixtures."""

    def __init__(self, path: Path) -> None:
        super().__init__(path, "LinkedIn", LinkedInAdapterError)


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, str]:
    """Validate token identity without allowing credential-shaped fields through."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise LinkedInAdapterError("LinkedIn account verification returned no member")
    remote_id = member_id(data.get("id"), "account ID")
    if remote_id != expected_id:
        raise LinkedInAdapterError(
            "selected LinkedIn member does not match the configured connection"
        )
    return {"id": remote_id}
