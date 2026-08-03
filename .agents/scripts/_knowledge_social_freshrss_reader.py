#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and deterministic fixture readers for FreshRSS."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_fixture import FixturePageReader
from _knowledge_social_freshrss import (
    FreshRSSAdapterError,
    FreshRSSProviderUnavailableError,
    PageRequest,
)
from _knowledge_social_freshrss_identity import account_id, user_id
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 180
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SAFE_PROVIDER_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "FreshRSS profile name is invalid",
    "FreshRSS profile base URL is missing",
    "FreshRSS profile username is missing",
    "FreshRSS profile API password is missing",
    "FreshRSS profile origin key is missing",
    "FreshRSS profile base URL must be HTTPS",
    "FreshRSS profile origin key must be at least 32 bytes",
    "selected FreshRSS account does not match the configured connection",
    "selected FreshRSS installation does not match the connection",
)


class FreshRSSReader(Protocol):
    def identity(self, expected_id: str) -> dict[str, Any]: ...
    def page(self, request: PageRequest) -> dict[str, Any]: ...


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode()) > MAX_RESPONSE_BYTES:
        raise FreshRSSAdapterError("FreshRSS read response exceeds the safety limit")
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise FreshRSSAdapterError(
            "FreshRSS read provider returned no valid JSON"
        ) from error
    if not isinstance(payload, dict):
        raise FreshRSSAdapterError("FreshRSS read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> FreshRSSProviderUnavailableError:
    for message in SAFE_PROVIDER_FAILURES:
        if f"ERROR: {message}" in stderr:
            return FreshRSSProviderUnavailableError(message)
    return FreshRSSProviderUnavailableError("FreshRSS read provider is unavailable")


FRESHRSS_READER_POLICY = GuardedOAuthPolicy(
    "FreshRSS",
    "FRESHRSS",
    "FRESHRSS_READ_LOG",
    READ_TIMEOUT_SECONDS,
    _decode_output,
    _provider_failure,
    FreshRSSProviderUnavailableError,
    ("BASE_URL", "USERNAME", "API_PASSWORD", "ORIGIN_KEY"),
    "",
)


class GuardedFreshRSS(GuardedOAuthReader):
    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, FRESHRSS_READER_POLICY)


class FixtureFreshRSS(FixturePageReader):
    def __init__(self, path: Path) -> None:
        super().__init__(path, "FreshRSS", FreshRSSAdapterError)


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise FreshRSSAdapterError("FreshRSS account verification returned no account")
    local = user_id(data.get("user_id"))
    if local != user_id(expected_id):
        raise FreshRSSAdapterError(
            "selected FreshRSS account does not match the configured connection"
        )
    instance = data.get("installation_id")
    durable = account_id(instance, local)
    if data.get("id") != durable:
        raise FreshRSSAdapterError("FreshRSS account identity binding is invalid")
    username = data.get("username")
    if username is not None and user_id(username) != local:
        raise FreshRSSAdapterError("FreshRSS account username is invalid")
    return {
        "id": durable,
        "installation_id": instance,
        "user_id": local,
        "username": username,
    }
