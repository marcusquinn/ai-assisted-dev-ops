#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and deterministic fixture readers for Nextcloud Talk."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_fixture import FixtureSequence
from _knowledge_social_nextcloud_talk import (
    NextcloudTalkAdapterError,
    NextcloudTalkProviderUnavailableError,
    PageRequest,
    instance_id,
)
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 180
MAX_RESPONSE_BYTES = 16 * 1024 * 1024
SAFE_PROVIDER_FAILURES = frozenset(
    {
        "Python urllib HTTP exports are unavailable",
        "Nextcloud Talk profile name is invalid",
        "Nextcloud Talk profile base URL is missing",
        "Nextcloud Talk profile base URL must be exact HTTPS",
        "Nextcloud Talk profile username is missing",
        "Nextcloud Talk profile app password is missing",
        "Nextcloud Talk profile origin key is missing",
        "Nextcloud Talk profile origin key must be at least 32 bytes",
        "Nextcloud Talk profile room allowlist is invalid",
        "Nextcloud Talk profile server major is invalid",
        "Nextcloud Talk profile Talk major is invalid",
        "selected Nextcloud Talk account does not match the profile",
        "selected Nextcloud Talk account or room does not match the profile",
        "configured Nextcloud Talk room is unavailable to the selected account",
        "Nextcloud Talk server or app version changed from the configured profile",
        "Nextcloud Talk required read APIs are unavailable",
    }
)


class NextcloudTalkReader(Protocol):
    def identity(self, expected_id: str) -> dict[str, Any]: ...

    def page(self, request: PageRequest) -> dict[str, Any]: ...


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode()) > MAX_RESPONSE_BYTES:
        raise NextcloudTalkAdapterError("Nextcloud Talk response exceeds the safety limit")
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise NextcloudTalkAdapterError(
            "Nextcloud Talk provider returned no valid JSON"
        ) from error
    if not isinstance(payload, dict):
        raise NextcloudTalkAdapterError("Nextcloud Talk response root must be an object")
    return payload


def _provider_failure(stderr: str) -> NextcloudTalkProviderUnavailableError:
    for message in SAFE_PROVIDER_FAILURES:
        if f"ERROR: {message}" in stderr:
            return NextcloudTalkProviderUnavailableError(message)
    return NextcloudTalkProviderUnavailableError("Nextcloud Talk read provider is unavailable")


NEXTCLOUD_TALK_READER_POLICY = GuardedOAuthPolicy(
    "Nextcloud Talk",
    "NEXTCLOUD_TALK",
    "NEXTCLOUD_TALK_READ_LOG",
    READ_TIMEOUT_SECONDS,
    _decode_output,
    _provider_failure,
    NextcloudTalkProviderUnavailableError,
    (
        "BASE_URL",
        "USERNAME",
        "APP_PASSWORD",
        "ORIGIN_KEY",
        "ALLOWED_ROOMS",
        "EXPECTED_SERVER_MAJOR",
        "EXPECTED_TALK_MAJOR",
    ),
    "",
)


class GuardedNextcloudTalk(GuardedOAuthReader):
    """Execute only identity and allowlisted Talk page reads in a child."""

    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, NEXTCLOUD_TALK_READER_POLICY)


def _fixture_object(value: Any, description: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise NextcloudTalkAdapterError(
            f"Nextcloud Talk fixture {description} must be an object"
        )
    return value


def _fixture_response(entry: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    expected = _fixture_object(entry.get("expect_request", {}), "request expectation")
    actual = request.payload()
    mismatches = {
        key: (value, actual.get(key))
        for key, value in expected.items()
        if actual.get(key) != value
    }
    if mismatches:
        raise NextcloudTalkAdapterError(
            "Nextcloud Talk request did not resume at the expected checkpoint"
        )
    return _fixture_object(entry.get("response", entry), "page response")


class FixtureNextcloudTalk:
    """Deterministic OCS substitute for version, pagination, and failure fixtures."""

    def __init__(self, path: Path) -> None:
        self.fixture = FixtureSequence(path, "Nextcloud Talk", NextcloudTalkAdapterError)

    def identity(self, expected_id: str) -> dict[str, Any]:
        del expected_id
        return self.fixture.identity()

    def page(self, request: PageRequest) -> dict[str, Any]:
        return _fixture_response(self.fixture.next_page(), request)


def _bounded_text(value: Any, field: str, *, optional: bool = False) -> str | None:
    if value is None and optional:
        return None
    if not isinstance(value, str) or not value or "\x00" in value or len(value.encode()) > 512:
        raise NextcloudTalkAdapterError(f"Nextcloud Talk account {field} is invalid")
    return value


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Bind the child-verified user to one installation and room allowlist."""
    del expected_id
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise NextcloudTalkAdapterError("Nextcloud Talk verification returned no account")
    rooms = data.get("room_ids")
    if not isinstance(rooms, list) or not rooms or len(rooms) > 100:
        raise NextcloudTalkAdapterError("Nextcloud Talk room allowlist is invalid")
    room_ids = [_bounded_text(room, "room identity") for room in rooms]
    if len(set(room_ids)) != len(room_ids):
        raise NextcloudTalkAdapterError("Nextcloud Talk room allowlist is invalid")
    features = data.get("features")
    if not isinstance(features, list) or any(not isinstance(value, str) for value in features):
        raise NextcloudTalkAdapterError("Nextcloud Talk features are invalid")
    return {
        "id": _bounded_text(data.get("id"), "identity"),
        "provider_account_id": _bounded_text(data.get("provider_account_id"), "account ID"),
        "instance_id": instance_id(data.get("instance_id")),
        "room_ids": room_ids,
        "name": _bounded_text(data.get("display_name"), "display name", optional=True),
        "server_version": _bounded_text(data.get("server_version"), "server version"),
        "talk_version": _bounded_text(data.get("talk_version"), "Talk version"),
        "features": features,
    }
