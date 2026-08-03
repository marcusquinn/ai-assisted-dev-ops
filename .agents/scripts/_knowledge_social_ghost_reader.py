#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and deterministic fixture readers for Ghost collection."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_fixture import FixtureSequence
from _knowledge_social_ghost import (
    GhostAdapterError,
    GhostProviderUnavailableError,
    PageRequest,
    instance_id,
    namespaced_id,
    provider_account_id,
)
from _knowledge_social_ghost_contract import site_version
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SAFE_PROVIDER_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "Ghost profile name is invalid",
    "Ghost profile admin URL is missing",
    "Ghost profile site URL is missing",
    "Ghost profile site ID is missing",
    "Ghost profile Content API credential is missing",
    "Ghost profile Content API credential is invalid",
    "Ghost profile origin key is missing",
    "Ghost profile origin key must be at least 32 bytes",
    "Ghost profile auth mode is missing",
    "Ghost profile must declare a public Content API credential",
    "selected Ghost publication does not match the configured connection",
    "selected Ghost installation does not match the connection",
    "selected Ghost site URL does not match the configured connection",
)


class GhostReader(Protocol):
    def identity(self, expected_id: str) -> dict[str, Any]: ...

    def page(self, request: PageRequest) -> dict[str, Any]: ...


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode()) > MAX_RESPONSE_BYTES:
        raise GhostAdapterError("Ghost read response exceeds the safety limit")
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise GhostAdapterError("Ghost read provider returned no valid JSON") from error
    if not isinstance(payload, dict):
        raise GhostAdapterError("Ghost read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> GhostProviderUnavailableError:
    for message in SAFE_PROVIDER_FAILURES:
        if f"ERROR: {message}" in stderr:
            return GhostProviderUnavailableError(message)
    return GhostProviderUnavailableError("Ghost read provider is unavailable")


GHOST_READER_POLICY = GuardedOAuthPolicy(
    "Ghost",
    "GHOST",
    "GHOST_READ_LOG",
    READ_TIMEOUT_SECONDS,
    _decode_output,
    _provider_failure,
    GhostProviderUnavailableError,
    (
        "ADMIN_URL",
        "SITE_URL",
        "SITE_ID",
        "CONTENT_API_KEY",
        "ORIGIN_KEY",
        "AUTH_MODE",
    ),
    "",
)


class GuardedGhost(GuardedOAuthReader):
    """Execute only publication identity and allowlisted Content API reads."""

    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, GHOST_READER_POLICY)


def _fixture_object(value: Any, message: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise GhostAdapterError(message)
    return value


class FixtureGhost:
    """Deterministic HTTP substitute for pagination and failure fixtures."""

    def __init__(self, path: Path) -> None:
        self.fixture = FixtureSequence(path, "Ghost", GhostAdapterError)

    def identity(self, expected_id: str) -> dict[str, Any]:
        del expected_id
        return self.fixture.identity()

    def page(self, request: PageRequest) -> dict[str, Any]:
        entry = self.fixture.next_page()
        expectation = _fixture_object(
            entry.get("expect_request", {}),
            "Ghost fixture request expectation must be an object",
        )
        actual = request.payload()
        for key, value in expectation.items():
            if actual.get(key) != value:
                raise GhostAdapterError(
                    "Ghost request did not resume at the expected checkpoint"
                )
        return _fixture_object(
            entry.get("response", entry),
            "Ghost fixture page response must be an object",
        )


def _display_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value or "\x00" in value:
        raise GhostAdapterError(f"Ghost publication {field} must be text")
    if len(value.encode()) > 256 * 1024:
        raise GhostAdapterError(f"Ghost publication {field} must be text")
    return value


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Bind an expected publication ID to one privacy-safe installation."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise GhostAdapterError("Ghost publication verification returned no site")
    local_id = provider_account_id(data.get("provider_account_id"))
    site = provider_account_id(data.get("site_id"))
    installation = instance_id(data.get("instance_id"))
    if local_id != provider_account_id(expected_id) or site != local_id:
        raise GhostAdapterError(
            "selected Ghost publication does not match the configured connection"
        )
    return {
        "id": namespaced_id(installation, "site", local_id),
        "provider_account_id": local_id,
        "site_id": site,
        "instance_id": installation,
        "version": site_version(data.get("version")),
        "name": _display_text(data.get("display_name"), "display name"),
    }
