#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and fixture readers for one beehiiv publication."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_beehiiv import (
    BeehiivAdapterError,
    BeehiivProviderUnavailableError,
    PageRequest,
    verified_identity,
)
from _knowledge_social_fixture import FixturePageReader
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 16 * 1024 * 1024
SAFE_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "beehiiv profile name is invalid",
    "beehiiv profile access token is missing",
    "beehiiv profile publication ID is missing",
    "beehiiv profile publication name is missing",
    "beehiiv profile organization name is missing",
    "beehiiv profile creator-owned publication ID is missing",
    "beehiiv profile creator ownership attestation does not match publication",
    "selected beehiiv publication does not match the configured publication",
    "beehiiv credential is not bound to exactly one visible publication",
    "beehiiv publication identity does not match expectations",
)


class Reader(Protocol):
    def identity(self, expected_id: str) -> dict[str, Any]: ...
    def page(self, request: PageRequest) -> dict[str, Any]: ...


def _decode(output: str) -> dict[str, Any]:
    if len(output.encode()) > MAX_RESPONSE_BYTES:
        raise BeehiivAdapterError("beehiiv response exceeds the safety limit")
    try:
        value = json.loads(output)
    except json.JSONDecodeError as error:
        raise BeehiivAdapterError("beehiiv returned no valid JSON") from error
    if not isinstance(value, dict):
        raise BeehiivAdapterError("beehiiv response must be an object")
    return value


def _failure(stderr: str) -> BeehiivProviderUnavailableError:
    for message in SAFE_FAILURES:
        if f"ERROR: {message}" in stderr:
            return BeehiivProviderUnavailableError(message)
    return BeehiivProviderUnavailableError("beehiiv provider is unavailable")


POLICY = GuardedOAuthPolicy(
    "beehiiv",
    "BEEHIIV",
    "BEEHIIV_READ_LOG",
    READ_TIMEOUT_SECONDS,
    _decode,
    _failure,
    BeehiivProviderUnavailableError,
    (
        "ACCESS_TOKEN",
        "PUBLICATION_ID",
        "PUBLICATION_NAME",
        "ORGANIZATION_NAME",
        "CREATOR_OWNED_PUBLICATION_ID",
    ),
    "",
)


class GuardedBeehiivReader(GuardedOAuthReader):
    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, POLICY)


class FixtureBeehiivReader(FixturePageReader):
    def __init__(self, path: Path) -> None:
        super().__init__(path, "beehiiv", BeehiivAdapterError)


__all__ = (
    "FixtureBeehiivReader",
    "GuardedBeehiivReader",
    "verified_identity",
)
