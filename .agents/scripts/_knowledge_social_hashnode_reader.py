#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and deterministic fixture readers for Hashnode collection."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_fixture import FixturePageReader
from _knowledge_social_hashnode import (
    HashnodeAdapterError,
    HashnodeProviderUnavailableError,
    PageRequest,
)
from _knowledge_social_hashnode_identity import (
    INSTANCE_ID,
    account_id,
    provider_account_id,
    username,
)
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SAFE_PROVIDER_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "Hashnode profile name is invalid",
    "Hashnode profile personal access token is missing",
    "selected Hashnode account does not match the configured connection",
)


class HashnodeReader(Protocol):
    def identity(self, expected_id: str) -> dict[str, Any]: ...
    def page(self, request: PageRequest) -> dict[str, Any]: ...


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode()) > MAX_RESPONSE_BYTES:
        raise HashnodeAdapterError("Hashnode read response exceeds the safety limit")
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise HashnodeAdapterError("Hashnode read provider returned no valid JSON") from error
    if not isinstance(payload, dict):
        raise HashnodeAdapterError("Hashnode read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> HashnodeProviderUnavailableError:
    for message in SAFE_PROVIDER_FAILURES:
        if f"ERROR: {message}" in stderr:
            return HashnodeProviderUnavailableError(message)
    return HashnodeProviderUnavailableError("Hashnode read provider is unavailable")


HASHNODE_READER_POLICY = GuardedOAuthPolicy(
    "Hashnode",
    "HASHNODE",
    "HASHNODE_READ_LOG",
    READ_TIMEOUT_SECONDS,
    _decode_output,
    _provider_failure,
    HashnodeProviderUnavailableError,
    ("PAT",),
    "",
)


class GuardedHashnode(GuardedOAuthReader):
    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, HASHNODE_READER_POLICY)


class FixtureHashnode(FixturePageReader):
    def __init__(self, path: Path) -> None:
        super().__init__(path, "Hashnode", HashnodeAdapterError)


def _display_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value or len(value.encode()) > 512 * 1024:
        raise HashnodeAdapterError(f"Hashnode account {field} must be text")
    return value


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Bind the authenticated Hashnode viewer before collection."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise HashnodeAdapterError("Hashnode account verification returned no account")
    remote = provider_account_id(data.get("provider_account_id"))
    handle = username(data.get("username"))
    if remote != provider_account_id(expected_id) or data.get("instance_id") != INSTANCE_ID:
        raise HashnodeAdapterError(
            "selected Hashnode account does not match the configured connection"
        )
    durable = account_id(remote)
    if data.get("id") != durable:
        raise HashnodeAdapterError("Hashnode account identity binding is invalid")
    return {
        "id": durable,
        "provider_account_id": remote,
        "instance_id": INSTANCE_ID,
        "username": handle,
        "name": _display_text(data.get("name"), "name"),
        "bio": _display_text(data.get("bio"), "bio"),
        "tagline": _display_text(data.get("tagline"), "tagline"),
        "location": _display_text(data.get("location"), "location"),
        "date_joined": _display_text(data.get("date_joined"), "join date"),
    }
