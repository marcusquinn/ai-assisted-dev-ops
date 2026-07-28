#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and deterministic fixture readers for NodeBB collection."""

from __future__ import annotations

import json
import os
import re
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_collect_cli import READER_ENVIRONMENT_KEYS, GuardedReaderProcess
from _knowledge_social_fixture import FixtureSequence
from _knowledge_social_nodebb import (
    NodeBBAdapterError,
    NodeBBProviderUnavailableError,
    PageRequest,
    instance_id,
    namespaced_id,
    provider_account_id,
    userslug,
)
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")
SAFE_PROVIDER_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "NodeBB profile name is invalid",
    "NodeBB profile base URL is missing",
    "NodeBB profile base URL must be HTTPS",
    "NodeBB profile bearer token is missing",
    "NodeBB profile origin key is missing",
    "NodeBB profile origin key must be at least 32 bytes",
    "NodeBB profile token type is missing",
    "NodeBB profile must declare a dedicated user token",
    "selected NodeBB account does not match the configured connection",
    "selected NodeBB installation does not match the connection",
)


class NodeBBReader(Protocol):
    def identity(self, expected_id: str) -> dict[str, Any]: ...

    def page(self, request: PageRequest) -> dict[str, Any]: ...


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode()) > MAX_RESPONSE_BYTES:
        raise NodeBBAdapterError("NodeBB read response exceeds the safety limit")
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise NodeBBAdapterError("NodeBB read provider returned no valid JSON") from error
    if not isinstance(payload, dict):
        raise NodeBBAdapterError("NodeBB read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> NodeBBProviderUnavailableError:
    for message in SAFE_PROVIDER_FAILURES:
        if f"ERROR: {message}" in stderr:
            return NodeBBProviderUnavailableError(message)
    return NodeBBProviderUnavailableError("NodeBB read provider is unavailable")


class GuardedNodeBB:
    """Execute only identity and allowlisted page reads in a bounded child."""

    def __init__(self, helper: Path, profile: str) -> None:
        if PROFILE_NAME.fullmatch(profile) is None:
            raise NodeBBProviderUnavailableError("NodeBB profile name is invalid")
        if helper.is_symlink() or not helper.is_file():
            raise NodeBBProviderUnavailableError("NodeBB read provider is unavailable")
        self.profile = profile
        self.process = GuardedReaderProcess(
            helper=helper,
            profile=profile,
            environment=self._environment,
            timeout_seconds=READ_TIMEOUT_SECONDS,
            decode_output=_decode_output,
            provider_failure=_provider_failure,
            unavailable_error=NodeBBProviderUnavailableError,
            provider_name="NodeBB",
        )

    def _environment(self) -> dict[str, str]:
        prefix = f"NODEBB_{self.profile.upper()}"
        profile_keys = {
            f"{prefix}_BASE_URL",
            f"{prefix}_BEARER_TOKEN",
            f"{prefix}_ORIGIN_KEY",
            f"{prefix}_TOKEN_TYPE",
        }
        environment = {
            key: value
            for key, value in os.environ.items()
            if key in READER_ENVIRONMENT_KEYS or key in profile_keys
        }
        if os.environ.get("AIDEVOPS_TEST_MODE") == "1":
            for key in ("AIDEVOPS_TEST_MODE", "PYTHONPATH", "NODEBB_READ_LOG"):
                if key in os.environ:
                    environment[key] = os.environ[key]
        return environment

    def identity(self, expected_id: str) -> dict[str, Any]:
        return self.process.run({"action": "identity", "account_id": expected_id})

    def page(self, request: PageRequest) -> dict[str, Any]:
        return self.process.run(request.payload())


def _fixture_object(value: Any, message: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise NodeBBAdapterError(message)
    return value


class FixtureNodeBB:
    """Deterministic HTTP substitute for pagination and failure fixtures."""

    def __init__(self, path: Path) -> None:
        self.fixture = FixtureSequence(path, "NodeBB", NodeBBAdapterError)

    def identity(self, expected_id: str) -> dict[str, Any]:
        del expected_id
        return self.fixture.identity()

    def page(self, request: PageRequest) -> dict[str, Any]:
        entry = self.fixture.next_page()
        expectation = _fixture_object(
            entry.get("expect_request", {}),
            "NodeBB fixture request expectation must be an object",
        )
        actual = request.payload()
        for key, value in expectation.items():
            if actual.get(key) != value:
                raise NodeBBAdapterError(
                    "NodeBB request did not resume at the expected checkpoint"
                )
        return _fixture_object(
            entry.get("response", entry),
            "NodeBB fixture page response must be an object",
        )


def _display_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value or "\x00" in value:
        raise NodeBBAdapterError(f"NodeBB account {field} must be text")
    if len(value.encode()) > 256 * 1024:
        raise NodeBBAdapterError(f"NodeBB account {field} must be text")
    return value


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Bind an installation-local user ID to a privacy-safe global namespace."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise NodeBBAdapterError("NodeBB account verification returned no account")
    local_id = provider_account_id(data.get("provider_account_id"))
    installation = instance_id(data.get("instance_id"))
    slug = userslug(data.get("userslug"))
    if local_id != provider_account_id(expected_id):
        raise NodeBBAdapterError(
            "selected NodeBB account does not match the configured connection"
        )
    return {
        "id": namespaced_id(installation, "user", local_id),
        "provider_account_id": local_id,
        "instance_id": installation,
        "userslug": slug,
        "username": _display_text(data.get("username"), "username") or slug,
        "name": _display_text(data.get("display_name"), "display name"),
    }
