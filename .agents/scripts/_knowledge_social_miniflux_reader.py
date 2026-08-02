#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and deterministic fixture readers for Miniflux."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_fixture import FixtureSequence
from _knowledge_social_miniflux import (
    MinifluxAdapterError,
    MinifluxProviderUnavailableError,
    PageRequest,
)
from _knowledge_social_miniflux_identity import account_id, user_id
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SAFE_PROVIDER_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "Miniflux profile name is invalid",
    "Miniflux profile base URL is missing",
    "Miniflux profile API token is missing",
    "Miniflux profile origin key is missing",
    "Miniflux profile base URL must be HTTPS",
    "Miniflux profile origin key must be at least 32 bytes",
    "selected Miniflux account does not match the configured connection",
    "selected Miniflux installation does not match the connection",
)


class MinifluxReader(Protocol):
    def identity(self, expected_id: str) -> dict[str, Any]: ...
    def page(self, request: PageRequest) -> dict[str, Any]: ...


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode()) > MAX_RESPONSE_BYTES:
        raise MinifluxAdapterError("Miniflux read response exceeds the safety limit")
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise MinifluxAdapterError("Miniflux read provider returned no valid JSON") from error
    if not isinstance(payload, dict):
        raise MinifluxAdapterError("Miniflux read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> MinifluxProviderUnavailableError:
    for message in SAFE_PROVIDER_FAILURES:
        if f"ERROR: {message}" in stderr:
            return MinifluxProviderUnavailableError(message)
    return MinifluxProviderUnavailableError("Miniflux read provider is unavailable")


MINIFLUX_READER_POLICY = GuardedOAuthPolicy(
    "Miniflux", "MINIFLUX", "MINIFLUX_READ_LOG", READ_TIMEOUT_SECONDS,
    _decode_output, _provider_failure, MinifluxProviderUnavailableError,
    ("BASE_URL", "API_TOKEN", "ORIGIN_KEY"), "",
)


class GuardedMiniflux(GuardedOAuthReader):
    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, MINIFLUX_READER_POLICY)


def _fixture_object(value: Any, message: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise MinifluxAdapterError(message)
    return value


class FixtureMiniflux:
    def __init__(self, path: Path) -> None:
        self.fixture = FixtureSequence(path, "Miniflux", MinifluxAdapterError)

    def identity(self, expected_id: str) -> dict[str, Any]:
        del expected_id
        return self.fixture.identity()

    def page(self, request: PageRequest) -> dict[str, Any]:
        entry = self.fixture.next_page()
        expectation = _fixture_object(
            entry.get("expect_request", {}),
            "Miniflux fixture request expectation must be an object",
        )
        for key, value in expectation.items():
            if request.payload().get(key) != value:
                raise MinifluxAdapterError(
                    "Miniflux request did not resume at the expected checkpoint"
                )
        return _fixture_object(
            entry.get("response", entry),
            "Miniflux fixture page response must be an object",
        )


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise MinifluxAdapterError("Miniflux account verification returned no account")
    local = user_id(data.get("user_id"))
    if local != user_id(expected_id):
        raise MinifluxAdapterError(
            "selected Miniflux account does not match the configured connection"
        )
    instance = data.get("installation_id")
    durable = account_id(instance, local)
    if data.get("id") != durable:
        raise MinifluxAdapterError("Miniflux account identity binding is invalid")
    username = data.get("username")
    if username is not None and (
        not isinstance(username, str) or "\x00" in username or len(username.encode()) > 4096
    ):
        raise MinifluxAdapterError("Miniflux account username must be text")
    return {
        "id": durable, "installation_id": instance,
        "user_id": local, "username": username,
    }
