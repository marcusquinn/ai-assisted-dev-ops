#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and deterministic fixture readers for Discourse collection."""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_collect_cli import (
    READER_ENVIRONMENT_KEYS,
    GuardedReaderProcess,
)
from _knowledge_social_discourse import (
    PageRequest,
    DiscourseAdapterError,
    DiscourseProviderUnavailableError,
    instance_id,
    namespaced_id,
    provider_account_id,
    username,
)
from _knowledge_social_fixture import FixtureSequence
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")
SAFE_PROVIDER_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "Discourse profile name is invalid",
    "Discourse profile base URL is missing",
    "Discourse profile base URL must be HTTPS",
    "Discourse profile user API key is missing",
    "Discourse profile origin key is missing",
    "Discourse profile origin key must be at least 32 bytes",
    "Discourse profile user API scope is missing",
    "Discourse user API profile must declare the read scope",
    "selected Discourse account does not match the configured connection",
    "selected Discourse installation does not match the connection",
)


class DiscourseReader(Protocol):
    """Minimal read-only surface consumed by the shared OAuth collector."""

    def identity(self, expected_id: str) -> dict[str, Any]: ...

    def page(self, request: PageRequest) -> dict[str, Any]: ...


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise DiscourseAdapterError("Discourse read response exceeds the safety limit")
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise DiscourseAdapterError(
            "Discourse read provider returned no valid JSON"
        ) from error
    if not isinstance(payload, dict):
        raise DiscourseAdapterError("Discourse read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> DiscourseProviderUnavailableError:
    for message in SAFE_PROVIDER_FAILURES:
        if f"ERROR: {message}" in stderr:
            return DiscourseProviderUnavailableError(message)
    return DiscourseProviderUnavailableError(
        "Discourse read provider is unavailable"
    )


class GuardedDiscourse:
    """Execute only identity and allowlisted page reads in a bounded child."""

    def __init__(self, helper: Path, profile: str) -> None:
        if PROFILE_NAME.fullmatch(profile) is None:
            raise DiscourseProviderUnavailableError(
                "Discourse profile name is invalid"
            )
        if helper.is_symlink() or not helper.is_file():
            raise DiscourseProviderUnavailableError(
                "Discourse read provider is unavailable"
            )
        self.profile = profile
        self.process = GuardedReaderProcess(
            helper=helper,
            profile=profile,
            environment=self._environment,
            timeout_seconds=READ_TIMEOUT_SECONDS,
            decode_output=_decode_output,
            provider_failure=_provider_failure,
            unavailable_error=DiscourseProviderUnavailableError,
            provider_name="Discourse",
        )

    def _environment(self) -> dict[str, str]:
        prefix = f"DISCOURSE_{self.profile.upper()}"
        profile_keys = {
            f"{prefix}_BASE_URL",
            f"{prefix}_USER_API_KEY",
            f"{prefix}_ORIGIN_KEY",
            f"{prefix}_USER_API_SCOPE",
        }
        environment = {
            key: value
            for key, value in os.environ.items()
            if key in READER_ENVIRONMENT_KEYS or key in profile_keys
        }
        if os.environ.get("AIDEVOPS_TEST_MODE") == "1":
            for key in ("AIDEVOPS_TEST_MODE", "PYTHONPATH", "DISCOURSE_READ_LOG"):
                if key in os.environ:
                    environment[key] = os.environ[key]
        return environment

    def identity(self, expected_id: str) -> dict[str, Any]:
        return self.process.run({"action": "identity", "account_id": expected_id})

    def page(self, request: PageRequest) -> dict[str, Any]:
        return self.process.run(request.payload())


def _fixture_object(value: Any, message: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise DiscourseAdapterError(message)
    return value


def _fixture_page(entry: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    expectation = _fixture_object(
        entry.get("expect_request", {}),
        "Discourse fixture request expectation must be an object",
    )
    actual = request.payload()
    for key, value in expectation.items():
        if actual.get(key) != value:
            raise DiscourseAdapterError(
                "Discourse request did not resume at the expected checkpoint"
            )
    return _fixture_object(
        entry.get("response", entry),
        "Discourse fixture page response must be an object",
    )


class FixtureDiscourse:
    """Deterministic HTTP substitute for pagination and failure fixtures."""

    def __init__(self, path: Path) -> None:
        self.fixture = FixtureSequence(path, "Discourse", DiscourseAdapterError)

    def identity(self, expected_id: str) -> dict[str, Any]:
        del expected_id
        return self.fixture.identity()

    def page(self, request: PageRequest) -> dict[str, Any]:
        return _fixture_page(self.fixture.next_page(), request)


def _display_name(value: Any) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str):
        raise DiscourseAdapterError("Discourse account name must be text")
    if not value:
        raise DiscourseAdapterError("Discourse account name must be text")
    if "\x00" in value:
        raise DiscourseAdapterError("Discourse account name must be text")
    if len(value.encode("utf-8")) > 256 * 1024:
        raise DiscourseAdapterError("Discourse account name must be text")
    return value


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Bind an installation-local user ID to a privacy-safe global namespace."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise DiscourseAdapterError(
            "Discourse account verification returned no account"
        )
    local_id = provider_account_id(data.get("provider_account_id"))
    installation = instance_id(data.get("instance_id"))
    handle = username(data.get("username"))
    if local_id != provider_account_id(expected_id):
        raise DiscourseAdapterError(
            "selected Discourse account does not match the configured connection"
        )
    display_name = _display_name(data.get("name"))
    return {
        "id": namespaced_id(installation, "user", local_id),
        "provider_account_id": local_id,
        "instance_id": installation,
        "username": handle,
        "name": display_name,
    }
