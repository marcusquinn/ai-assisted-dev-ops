#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and fixture readers for Readwise Reader."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_fixture import FixtureSequence
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from _knowledge_social_readwise_reader import (
    PageRequest,
    ReadwiseReaderAdapterError,
    ReadwiseReaderProviderUnavailableError,
)
from _knowledge_social_readwise_reader_identity import binding_account_id
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 16 * 1024 * 1024
SAFE_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "Readwise Reader profile name is invalid",
    "Readwise Reader profile access token is missing",
    "Readwise Reader profile account ID is missing",
    "Readwise Reader profile binding key is missing",
    "Readwise Reader profile expected token binding is missing",
    "Readwise Reader token does not match the deployment account binding",
    "selected Readwise Reader account does not match the deployment binding",
)


class Reader(Protocol):
    def identity(self, expected_id: str) -> dict[str, Any]: ...
    def page(self, request: PageRequest) -> dict[str, Any]: ...


def _decode(output: str) -> dict[str, Any]:
    if len(output.encode()) > MAX_RESPONSE_BYTES:
        raise ReadwiseReaderAdapterError("Readwise Reader response exceeds the safety limit")
    try:
        value = json.loads(output)
    except json.JSONDecodeError as error:
        raise ReadwiseReaderAdapterError("Readwise Reader returned no valid JSON") from error
    if not isinstance(value, dict):
        raise ReadwiseReaderAdapterError("Readwise Reader response must be an object")
    return value


def _failure(stderr: str) -> ReadwiseReaderProviderUnavailableError:
    for message in SAFE_FAILURES:
        if f"ERROR: {message}" in stderr:
            return ReadwiseReaderProviderUnavailableError(message)
    return ReadwiseReaderProviderUnavailableError("Readwise Reader provider is unavailable")


POLICY = GuardedOAuthPolicy(
    "Readwise Reader", "READWISE_READER", "READWISE_READER_READ_LOG",
    READ_TIMEOUT_SECONDS, _decode, _failure, ReadwiseReaderProviderUnavailableError,
    ("ACCESS_TOKEN", "ACCOUNT_ID", "BINDING_KEY", "EXPECTED_TOKEN_BINDING"), "",
)


class GuardedReadwiseReader(GuardedOAuthReader):
    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, POLICY)


class FixtureReadwiseReader:
    def __init__(self, path: Path) -> None:
        self.fixture = FixtureSequence(path, "Readwise Reader", ReadwiseReaderAdapterError)

    def identity(self, expected_id: str) -> dict[str, Any]:
        del expected_id
        return self.fixture.identity()

    def page(self, request: PageRequest) -> dict[str, Any]:
        entry = self.fixture.next_page()
        expectation = entry.get("expect_request", {})
        if not isinstance(expectation, dict):
            raise ReadwiseReaderAdapterError("Reader fixture expectation must be an object")
        if any(request.payload().get(key) != value for key, value in expectation.items()):
            raise ReadwiseReaderAdapterError("Reader request did not resume at the expected cursor")
        response = entry.get("response", entry)
        if not isinstance(response, dict):
            raise ReadwiseReaderAdapterError("Reader fixture response must be an object")
        return response


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise ReadwiseReaderAdapterError("Reader account verification returned no account")
    selected = binding_account_id(data.get("binding_account_id"))
    if selected != binding_account_id(expected_id):
        raise ReadwiseReaderAdapterError(
            "selected Readwise Reader account does not match the deployment binding"
        )
    durable = data.get("id")
    if not isinstance(durable, str) or not durable.startswith("rwr_"):
        raise ReadwiseReaderAdapterError("Readwise Reader account identity binding is invalid")
    return {"id": durable, "binding_account_id": selected}
