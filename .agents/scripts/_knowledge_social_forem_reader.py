#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and deterministic fixture readers for Forem collection."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_fixture import FixturePageReader
from _knowledge_social_forem import (
    ForemAdapterError,
    ForemProviderUnavailableError,
    PageRequest,
    instance_id,
    namespaced_id,
    provider_account_id,
    username,
)
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SAFE_PROVIDER_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "Forem profile name is invalid",
    "Forem profile base URL is missing",
    "Forem profile base URL must be HTTPS",
    "Forem profile API key is missing",
    "Forem profile origin key is missing",
    "Forem profile origin key must be at least 32 bytes",
    "Forem profile auth mode is missing",
    "Forem profile must declare a user-generated API key",
    "selected Forem account does not match the configured connection",
    "selected Forem installation does not match the connection",
)


class ForemReader(Protocol):
    def identity(self, expected_id: str) -> dict[str, Any]: ...

    def page(self, request: PageRequest) -> dict[str, Any]: ...


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode()) > MAX_RESPONSE_BYTES:
        raise ForemAdapterError("Forem read response exceeds the safety limit")
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise ForemAdapterError("Forem read provider returned no valid JSON") from error
    if not isinstance(payload, dict):
        raise ForemAdapterError("Forem read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> ForemProviderUnavailableError:
    for message in SAFE_PROVIDER_FAILURES:
        if f"ERROR: {message}" in stderr:
            return ForemProviderUnavailableError(message)
    return ForemProviderUnavailableError("Forem read provider is unavailable")


FOREM_READER_POLICY = GuardedOAuthPolicy(
    "Forem",
    "FOREM",
    "FOREM_READ_LOG",
    READ_TIMEOUT_SECONDS,
    _decode_output,
    _provider_failure,
    ForemProviderUnavailableError,
    ("BASE_URL", "API_KEY", "ORIGIN_KEY", "AUTH_MODE"),
    "",
)


class GuardedForem(GuardedOAuthReader):
    """Execute only identity and allowlisted page reads in a bounded child."""

    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, FOREM_READER_POLICY)


class FixtureForem(FixturePageReader):
    """Deterministic HTTP substitute for pagination and failure fixtures."""

    def __init__(self, path: Path) -> None:
        super().__init__(path, "Forem", ForemAdapterError)


def _display_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value or "\x00" in value:
        raise ForemAdapterError(f"Forem account {field} must be text")
    if len(value.encode()) > 256 * 1024:
        raise ForemAdapterError(f"Forem account {field} must be text")
    return value


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Bind an installation-local user ID to a privacy-safe global namespace."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise ForemAdapterError("Forem account verification returned no account")
    local_id = provider_account_id(data.get("provider_account_id"))
    installation = instance_id(data.get("instance_id"))
    handle = username(data.get("username"))
    if local_id != provider_account_id(expected_id):
        raise ForemAdapterError(
            "selected Forem account does not match the configured connection"
        )
    return {
        "id": namespaced_id(installation, "user", local_id),
        "provider_account_id": local_id,
        "instance_id": installation,
        "username": handle,
        "name": _display_text(data.get("display_name"), "display name"),
    }
