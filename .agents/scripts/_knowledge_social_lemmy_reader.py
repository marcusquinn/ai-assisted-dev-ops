#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and deterministic fixture readers for Lemmy collection."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_fixture import FixtureSequence
from _knowledge_social_lemmy import (
    LemmyAdapterError,
    LemmyProviderUnavailableError,
    PageRequest,
    account_name,
    activitypub_id,
    api_family,
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
    "Lemmy profile name is invalid",
    "Lemmy profile base URL is missing",
    "Lemmy profile base URL must be an HTTPS origin",
    "Lemmy profile access token is missing",
    "Lemmy profile origin key is missing",
    "Lemmy profile origin key must be at least 32 bytes",
    "Lemmy profile auth mode is missing",
    "Lemmy profile must declare a user token",
    "Lemmy instance version is ambiguous",
    "Lemmy instance version is unsupported",
    "selected Lemmy account does not match the configured connection",
    "selected Lemmy account or version does not match the configured connection",
    "selected Lemmy instance does not match the connection",
)


class LemmyReader(Protocol):
    def identity(self, expected_id: str) -> dict[str, Any]: ...
    def page(self, request: PageRequest) -> dict[str, Any]: ...


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode()) > MAX_RESPONSE_BYTES:
        raise LemmyAdapterError("Lemmy read response exceeds the safety limit")
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise LemmyAdapterError("Lemmy read provider returned no valid JSON") from error
    if not isinstance(payload, dict):
        raise LemmyAdapterError("Lemmy read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> LemmyProviderUnavailableError:
    for message in SAFE_PROVIDER_FAILURES:
        if f"ERROR: {message}" in stderr:
            return LemmyProviderUnavailableError(message)
    return LemmyProviderUnavailableError("Lemmy read provider is unavailable")


LEMMY_READER_POLICY = GuardedOAuthPolicy(
    "Lemmy",
    "LEMMY",
    "LEMMY_READ_LOG",
    READ_TIMEOUT_SECONDS,
    _decode_output,
    _provider_failure,
    LemmyProviderUnavailableError,
    ("BASE_URL", "ACCESS_TOKEN", "ORIGIN_KEY", "AUTH_MODE"),
    "",
)


class GuardedLemmy(GuardedOAuthReader):
    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, LEMMY_READER_POLICY)


def _fixture_object(value: Any, message: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise LemmyAdapterError(message)
    return value


def _fixture_page(sequence: FixtureSequence, request: PageRequest) -> dict[str, Any]:
    entry = sequence.next_page()
    expectation = _fixture_object(
        entry.get("expect_request", {}),
        "Lemmy fixture request expectation must be an object",
    )
    actual = request.payload()
    if any(actual.get(key) != value for key, value in expectation.items()):
        raise LemmyAdapterError("Lemmy request did not resume at the expected checkpoint")
    return _fixture_object(
        entry.get("response", entry),
        "Lemmy fixture page response must be an object",
    )


class FixtureLemmy:
    def __init__(self, path: Path) -> None:
        self.fixture = FixtureSequence(path, "Lemmy", LemmyAdapterError)

    def identity(self, expected_id: str) -> dict[str, Any]:
        del expected_id
        return self.fixture.identity()

    def page(self, request: PageRequest) -> dict[str, Any]:
        return _fixture_page(self.fixture, request)


def _display_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value or "\x00" in value:
        raise LemmyAdapterError(f"Lemmy account {field} must be text")
    if len(value.encode()) > 256 * 1024:
        raise LemmyAdapterError(f"Lemmy account {field} must be text")
    return value


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Bind one local person, ActivityPub ID, version, and home instance."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise LemmyAdapterError("Lemmy account verification returned no account")
    local_id = provider_account_id(data.get("provider_account_id"))
    installation = instance_id(data.get("instance_id"))
    family = data.get("api_family")
    version = _display_text(data.get("exact_version"), "version")
    if family not in ("v3", "v4") or version is None or api_family(version) != family:
        raise LemmyAdapterError("Lemmy account verification returned no supported version")
    if local_id != provider_account_id(expected_id):
        raise LemmyAdapterError(
            "selected Lemmy account does not match the configured connection"
        )
    return {
        "id": namespaced_id(installation, "person", local_id),
        "provider_account_id": local_id,
        "instance_id": installation,
        "username": account_name(data.get("username")),
        "name": _display_text(data.get("display_name"), "display name"),
        "ap_id": activitypub_id(data.get("ap_id"), "person ActivityPub ID"),
        "api_family": family,
        "exact_version": version,
    }
