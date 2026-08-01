#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and deterministic fixture readers for Slack collection."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_fixture import FixtureSequence
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from _knowledge_social_slack import (
    PageRequest,
    SlackAdapterError,
    SlackProviderUnavailableError,
    enterprise_id,
    parse_account_id,
    team_id,
    token_type,
    user_id,
)
from _knowledge_social_slack_evidence_guard import reject_slack_credentials
from _knowledge_social_slack_http import READ_SCOPES

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SHA256 = re.compile(r"^[a-f0-9]{64}$")
SAFE_PROVIDER_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "Slack profile name is invalid",
    "Slack profile access token is missing",
    "Slack profile workspace ID is missing",
    "Slack profile enterprise ID is invalid",
    "Slack profile token type is missing",
    "Slack profile conversation allowlist is missing",
    "Slack profile conversation allowlist is invalid",
    "Slack token includes an unsupported or write scope",
    "Slack response did not attest token scopes",
    "selected Slack workspace or account does not match the configured connection",
)


class SlackReader(Protocol):
    def identity(self, expected_id: str) -> dict[str, Any]: ...

    def page(self, request: PageRequest) -> dict[str, Any]: ...


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise SlackAdapterError("Slack read response exceeds the safety limit")
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise SlackAdapterError("Slack read provider returned no valid JSON") from error
    if not isinstance(payload, dict):
        raise SlackAdapterError("Slack read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> SlackProviderUnavailableError:
    for message in SAFE_PROVIDER_FAILURES:
        if f"ERROR: {message}" in stderr:
            return SlackProviderUnavailableError(message)
    return SlackProviderUnavailableError("Slack read provider is unavailable")


SLACK_READER_POLICY = GuardedOAuthPolicy(
    "Slack",
    "SLACK",
    "SLACK_READ_LOG",
    READ_TIMEOUT_SECONDS,
    _decode_output,
    _provider_failure,
    SlackProviderUnavailableError,
    (
        "ACCESS_TOKEN",
        "WORKSPACE_ID",
        "ENTERPRISE_ID",
        "TOKEN_TYPE",
        "CONVERSATIONS",
    ),
    "",
)


class GuardedSlack(GuardedOAuthReader):
    """Execute only identity and exact allowlisted Slack reads in a child."""

    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, SLACK_READER_POLICY)


def _fixture_object(value: Any, message: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise SlackAdapterError(message)
    return value


class FixtureSlack:
    """Deterministic Slack substitute for pagination and failure fixtures."""

    def __init__(self, path: Path) -> None:
        self.sequence = FixtureSequence(path, "Slack", SlackAdapterError)

    def identity(self, expected_id: str) -> dict[str, Any]:
        del expected_id
        return self.sequence.identity()

    def page(self, request: PageRequest) -> dict[str, Any]:
        entry = self.sequence.next_page()
        expectation = _fixture_object(
            entry.get("expect_request", {}),
            "Slack fixture request expectation must be an object",
        )
        actual = request.payload()
        mismatch = any(
            actual.get(key) != expected for key, expected in expectation.items()
        )
        if mismatch:
            raise SlackAdapterError(
                "Slack request did not resume at the expected checkpoint"
            )
        response = entry.get("response", entry)
        return _fixture_object(
            response, "Slack fixture page response must be an object"
        )


def _optional_display(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or not value or "\x00" in value:
        raise SlackAdapterError(f"Slack account {field} must be text")
    if len(value.encode("utf-8")) > 256 * 1024:
        raise SlackAdapterError(f"Slack account {field} exceeds the safety limit")
    return value


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Bind one user or bot identity to an exact Slack workspace installation."""
    reject_slack_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise SlackAdapterError("Slack account verification returned no account")
    expected_workspace, expected_user = parse_account_id(expected_id)
    workspace = team_id(data.get("workspace_id"))
    selected_user = user_id(data.get("provider_account_id"))
    identity = data.get("id")
    if (
        identity != expected_id
        or workspace != expected_workspace
        or selected_user != expected_user
    ):
        raise SlackAdapterError(
            "selected Slack workspace or account does not match the configured connection"
        )
    scopes = data.get("scopes")
    if (
        not isinstance(scopes, list)
        or not scopes
        or any(not isinstance(scope, str) or scope not in READ_SCOPES for scope in scopes)
        or len(set(scopes)) != len(scopes)
    ):
        raise SlackAdapterError("Slack identity scopes are invalid")
    conversation_binding = data.get("conversation_binding_sha256")
    if (
        not isinstance(conversation_binding, str)
        or SHA256.fullmatch(conversation_binding) is None
    ):
        raise SlackAdapterError("Slack conversation binding is invalid")
    return {
        "id": identity,
        "provider_account_id": selected_user,
        "workspace_id": workspace,
        "enterprise_id": enterprise_id(data.get("enterprise_id")),
        "token_type": token_type(data.get("token_type")),
        "scopes": sorted(scopes),
        "conversation_binding_sha256": conversation_binding,
        "username": _optional_display(data.get("username"), "name"),
        "workspace_name": _optional_display(
            data.get("workspace_name"), "workspace name"
        ),
    }
