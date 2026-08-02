#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and deterministic fixture readers for Stack Exchange."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_fixture import FixtureSequence
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from _knowledge_social_stack_exchange import (
    PageRequest,
    StackExchangeAdapterError,
    StackExchangeProviderUnavailableError,
)
from _knowledge_social_stack_exchange_identity import (
    account_id,
    api_site_parameter,
    network_account_id,
    site_user_id,
)
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SAFE_PROVIDER_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "Stack Exchange profile name is invalid",
    "Stack Exchange profile access token is missing",
    "Stack Exchange profile site is missing",
    "Stack Exchange profile scopes are invalid",
    "Stack Exchange profile lacks the read_inbox scope",
    "selected Stack Exchange account does not match the configured connection",
    "selected Stack Exchange site does not match the connection",
)


class StackExchangeReader(Protocol):
    def identity(self, expected_id: str) -> dict[str, Any]: ...
    def page(self, request: PageRequest) -> dict[str, Any]: ...


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode()) > MAX_RESPONSE_BYTES:
        raise StackExchangeAdapterError(
            "Stack Exchange read response exceeds the safety limit"
        )
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise StackExchangeAdapterError(
            "Stack Exchange read provider returned no valid JSON"
        ) from error
    if not isinstance(payload, dict):
        raise StackExchangeAdapterError("Stack Exchange read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> StackExchangeProviderUnavailableError:
    for message in SAFE_PROVIDER_FAILURES:
        if f"ERROR: {message}" in stderr:
            return StackExchangeProviderUnavailableError(message)
    return StackExchangeProviderUnavailableError(
        "Stack Exchange read provider is unavailable"
    )


STACK_EXCHANGE_READER_POLICY = GuardedOAuthPolicy(
    "Stack Exchange",
    "STACK_EXCHANGE",
    "STACK_EXCHANGE_READ_LOG",
    READ_TIMEOUT_SECONDS,
    _decode_output,
    _provider_failure,
    StackExchangeProviderUnavailableError,
    ("ACCESS_TOKEN", "SITE", "SCOPES"),
    "",
)


class GuardedStackExchange(GuardedOAuthReader):
    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, STACK_EXCHANGE_READER_POLICY)


def _fixture_object(value: Any, message: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise StackExchangeAdapterError(message)
    return value


class FixtureStackExchange:
    def __init__(self, path: Path) -> None:
        self.fixture = FixtureSequence(path, "Stack Exchange", StackExchangeAdapterError)

    def identity(self, expected_id: str) -> dict[str, Any]:
        del expected_id
        return self.fixture.identity()

    def page(self, request: PageRequest) -> dict[str, Any]:
        entry = self.fixture.next_page()
        expectation = _fixture_object(
            entry.get("expect_request", {}),
            "Stack Exchange fixture request expectation must be an object",
        )
        actual = request.payload()
        for key, value in expectation.items():
            if actual.get(key) != value:
                raise StackExchangeAdapterError(
                    "Stack Exchange request did not resume at the expected checkpoint"
                )
        return _fixture_object(
            entry.get("response", entry),
            "Stack Exchange fixture page response must be an object",
        )


def _display_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value or len(value.encode()) > 256 * 1024:
        raise StackExchangeAdapterError(f"Stack Exchange account {field} must be text")
    return value


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise StackExchangeAdapterError(
            "Stack Exchange account verification returned no account"
        )
    network = network_account_id(data.get("network_account_id"))
    local = site_user_id(data.get("site_user_id"))
    site = api_site_parameter(data.get("api_site_parameter"))
    if network != network_account_id(expected_id):
        raise StackExchangeAdapterError(
            "selected Stack Exchange account does not match the configured connection"
        )
    durable = account_id(network, site, local)
    if data.get("id") != durable:
        raise StackExchangeAdapterError("Stack Exchange account identity binding is invalid")
    return {
        "id": durable,
        "network_account_id": network,
        "site_user_id": local,
        "api_site_parameter": site,
        "display_name": _display_text(data.get("display_name"), "display name"),
        "link": _display_text(data.get("link"), "link"),
    }
