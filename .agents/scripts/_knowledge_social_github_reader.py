#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and deterministic fixture readers for GitHub collection."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_fixture import FixtureSequence
from _knowledge_social_github import (
    GitHubAdapterError,
    GitHubProviderUnavailableError,
    PageRequest,
)
from _knowledge_social_github_identity import (
    INSTANCE_ID,
    account_id,
    login,
    node_id,
    provider_account_id,
)
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SAFE_PROVIDER_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "GitHub profile name is invalid",
    "GitHub profile access token is missing",
    "GitHub profile token family is missing",
    "GitHub profile token family is invalid",
    "GitHub profile scopes are invalid",
    "GitHub profile token family cannot read the selected stream",
    "selected GitHub account does not match the configured connection",
)


class GitHubReader(Protocol):
    def identity(self, expected_id: str) -> dict[str, Any]: ...
    def page(self, request: PageRequest) -> dict[str, Any]: ...


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode()) > MAX_RESPONSE_BYTES:
        raise GitHubAdapterError("GitHub read response exceeds the safety limit")
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise GitHubAdapterError("GitHub read provider returned no valid JSON") from error
    if not isinstance(payload, dict):
        raise GitHubAdapterError("GitHub read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> GitHubProviderUnavailableError:
    for message in SAFE_PROVIDER_FAILURES:
        if f"ERROR: {message}" in stderr:
            return GitHubProviderUnavailableError(message)
    return GitHubProviderUnavailableError("GitHub read provider is unavailable")


GITHUB_READER_POLICY = GuardedOAuthPolicy(
    "GitHub",
    "GITHUB",
    "GITHUB_READ_LOG",
    READ_TIMEOUT_SECONDS,
    _decode_output,
    _provider_failure,
    GitHubProviderUnavailableError,
    ("ACCESS_TOKEN", "TOKEN_FAMILY", "SCOPES"),
    "",
)


class GuardedGitHub(GuardedOAuthReader):
    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, GITHUB_READER_POLICY)


def _fixture_object(value: Any, message: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise GitHubAdapterError(message)
    return value


class FixtureGitHub:
    def __init__(self, path: Path) -> None:
        self.fixture = FixtureSequence(path, "GitHub", GitHubAdapterError)

    def identity(self, expected_id: str) -> dict[str, Any]:
        del expected_id
        return self.fixture.identity()

    def page(self, request: PageRequest) -> dict[str, Any]:
        entry = self.fixture.next_page()
        expectation = _fixture_object(
            entry.get("expect_request", {}),
            "GitHub fixture request expectation must be an object",
        )
        actual = request.payload()
        for key, value in expectation.items():
            if actual.get(key) != value:
                raise GitHubAdapterError(
                    "GitHub request did not resume at the expected checkpoint"
                )
        return _fixture_object(
            entry.get("response", entry),
            "GitHub fixture page response must be an object",
        )


def _display_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value or len(value.encode()) > 256 * 1024:
        raise GitHubAdapterError(f"GitHub account {field} must be text")
    return value


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Bind REST numeric identity and GraphQL node identity before collection."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise GitHubAdapterError("GitHub account verification returned no account")
    numeric = provider_account_id(data.get("provider_account_id"))
    graph_node = node_id(data.get("node_id"))
    handle = login(data.get("login"))
    if numeric != provider_account_id(expected_id) or data.get("instance_id") != INSTANCE_ID:
        raise GitHubAdapterError(
            "selected GitHub account does not match the configured connection"
        )
    durable = account_id(numeric, graph_node)
    if data.get("id") != durable:
        raise GitHubAdapterError("GitHub account identity binding is invalid")
    return {
        "id": durable,
        "provider_account_id": numeric,
        "node_id": graph_node,
        "instance_id": INSTANCE_ID,
        "login": handle,
        "name": _display_text(data.get("name"), "name"),
        "bio": _display_text(data.get("bio"), "bio"),
    }
