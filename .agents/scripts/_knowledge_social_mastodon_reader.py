#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and deterministic fixture readers for Mastodon collection."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_fixture import FixturePageReader
from _knowledge_social_mastodon import (
    MastodonAdapterError,
    MastodonProviderUnavailableError,
    PageRequest,
    account_handle,
    instance_id,
    namespaced_id,
    provider_account_id,
)
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SAFE_PROVIDER_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "Mastodon profile name is invalid",
    "Mastodon profile base URL is missing",
    "Mastodon profile base URL must be an HTTPS origin",
    "Mastodon profile access token is missing",
    "Mastodon profile origin key is missing",
    "Mastodon profile origin key must be at least 32 bytes",
    "Mastodon profile auth mode is missing",
    "Mastodon profile must declare a user token",
    "Mastodon profile scopes are missing",
    "Mastodon profile scopes are invalid",
    "Mastodon profile lacks account identity scope",
    "Mastodon profile lacks the selected stream scope",
    "selected Mastodon account does not match the configured connection",
    "selected Mastodon instance does not match the connection",
)


class MastodonReader(Protocol):
    def identity(self, expected_id: str) -> dict[str, Any]: ...
    def page(self, request: PageRequest) -> dict[str, Any]: ...


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode()) > MAX_RESPONSE_BYTES:
        raise MastodonAdapterError("Mastodon read response exceeds the safety limit")
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise MastodonAdapterError("Mastodon read provider returned no valid JSON") from error
    if not isinstance(payload, dict):
        raise MastodonAdapterError("Mastodon read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> MastodonProviderUnavailableError:
    for message in SAFE_PROVIDER_FAILURES:
        if f"ERROR: {message}" in stderr:
            return MastodonProviderUnavailableError(message)
    return MastodonProviderUnavailableError("Mastodon read provider is unavailable")


MASTODON_READER_POLICY = GuardedOAuthPolicy(
    "Mastodon",
    "MASTODON",
    "MASTODON_READ_LOG",
    READ_TIMEOUT_SECONDS,
    _decode_output,
    _provider_failure,
    MastodonProviderUnavailableError,
    ("BASE_URL", "ACCESS_TOKEN", "ORIGIN_KEY", "AUTH_MODE", "SCOPES"),
    "",
)


class GuardedMastodon(GuardedOAuthReader):
    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, MASTODON_READER_POLICY)


class FixtureMastodon(FixturePageReader):
    def __init__(self, path: Path) -> None:
        super().__init__(path, "Mastodon", MastodonAdapterError)


def _display_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value or "\x00" in value:
        raise MastodonAdapterError(f"Mastodon account {field} must be text")
    if len(value.encode()) > 256 * 1024:
        raise MastodonAdapterError(f"Mastodon account {field} must be text")
    return value


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Bind an opaque home-instance account ID to a global namespace."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise MastodonAdapterError("Mastodon account verification returned no account")
    local_id = provider_account_id(data.get("provider_account_id"))
    installation = instance_id(data.get("instance_id"))
    acct = account_handle(data.get("acct"))
    if local_id != provider_account_id(expected_id):
        raise MastodonAdapterError(
            "selected Mastodon account does not match the configured connection"
        )
    return {
        "id": namespaced_id(installation, "account", local_id),
        "provider_account_id": local_id,
        "instance_id": installation,
        "acct": acct,
        "username": _display_text(data.get("username"), "username"),
        "name": _display_text(data.get("display_name"), "display name"),
        "uri": _display_text(data.get("uri"), "URI"),
    }
