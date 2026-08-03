#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and deterministic fixture readers for Hacker News."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_fixture import FixtureSequence
from _knowledge_social_hacker_news import PageRequest
from _knowledge_social_hacker_news_contract import (
    HackerNewsReadProviderError,
    MAX_ITEM_RESPONSE_BYTES,
    MAX_USER_RESPONSE_BYTES,
    submitted_ids,
)
from _knowledge_social_hacker_news_identity import (
    HackerNewsAdapterError,
    HackerNewsProviderUnavailableError,
    selector_id,
    username,
)
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = MAX_USER_RESPONSE_BYTES + MAX_ITEM_RESPONSE_BYTES + 256 * 1024
SAFE_PROVIDER_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "Hacker News profile must be the credential-free public profile",
    "Hacker News public username is invalid",
    "Hacker News public selector changed during collection",
)


class HackerNewsReader(Protocol):
    def identity(self, expected_id: str) -> dict[str, Any]: ...
    def page(self, request: PageRequest) -> dict[str, Any]: ...


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise HackerNewsAdapterError(
            "Hacker News read response exceeds the safety limit"
        )
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise HackerNewsAdapterError(
            "Hacker News read provider returned no valid JSON"
        ) from error
    if not isinstance(payload, dict):
        raise HackerNewsAdapterError("Hacker News read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> HackerNewsProviderUnavailableError:
    for message in SAFE_PROVIDER_FAILURES:
        if f"ERROR: {message}" in stderr:
            return HackerNewsProviderUnavailableError(message)
    return HackerNewsProviderUnavailableError(
        "Hacker News public read provider is unavailable"
    )


HACKER_NEWS_READER_POLICY = GuardedOAuthPolicy(
    "Hacker News",
    "HACKER_NEWS",
    "HACKER_NEWS_READ_LOG",
    READ_TIMEOUT_SECONDS,
    _decode_output,
    _provider_failure,
    HackerNewsProviderUnavailableError,
    (),
    "public",
)


class GuardedHackerNews(GuardedOAuthReader):
    def __init__(self, helper: Path, profile: str) -> None:
        if profile != "public":
            raise HackerNewsProviderUnavailableError(
                "Hacker News profile must be the credential-free public profile"
            )
        super().__init__(helper, profile, HACKER_NEWS_READER_POLICY)


def _fixture_object(value: Any, message: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise HackerNewsAdapterError(message)
    return value


def _fixture_page(sequence: FixtureSequence, request: PageRequest) -> dict[str, Any]:
    entry = sequence.next_page()
    expectation = _fixture_object(
        entry.get("expect_request", {}),
        "Hacker News fixture request expectation must be an object",
    )
    actual = request.payload()
    if {key: actual.get(key) for key in expectation} != expectation:
        raise HackerNewsAdapterError(
            "Hacker News request did not resume at the expected checkpoint"
        )
    return _fixture_object(
        entry.get("response", entry),
        "Hacker News fixture page response must be an object",
    )


class FixtureHackerNews:
    def __init__(self, path: Path) -> None:
        self.fixture = FixtureSequence(path, "Hacker News", HackerNewsAdapterError)

    def identity(self, expected_id: str) -> dict[str, Any]:
        del expected_id
        return self.fixture.identity()

    def page(self, request: PageRequest) -> dict[str, Any]:
        return _fixture_page(self.fixture, request)


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Verify only an exact public selector, never authenticated account identity."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise HackerNewsAdapterError(
            "Hacker News public selector response returned no observation"
        )
    selected = username(data.get("username"))
    if selected != username(expected_id) or data.get("id") != selector_id(selected):
        raise HackerNewsAdapterError(
            "Hacker News public username does not match the configured selector"
        )
    availability = data.get("availability")
    if availability not in {"public", "missing"}:
        raise HackerNewsAdapterError(
            "Hacker News public selector availability is invalid"
        )
    try:
        submitted = submitted_ids(data.get("submitted", []))
    except HackerNewsReadProviderError as error:
        raise HackerNewsAdapterError(str(error)) from error
    response_bytes = data.get("response_bytes", 0)
    if (
        isinstance(response_bytes, bool)
        or not isinstance(response_bytes, int)
        or response_bytes < 0
        or response_bytes > MAX_USER_RESPONSE_BYTES
    ):
        raise HackerNewsAdapterError(
            "Hacker News public selector byte count is invalid"
        )
    return {
        "id": selector_id(selected),
        "username": selected,
        "availability": availability,
        "submitted": list(submitted),
        "created": data.get("created"),
        "karma": data.get("karma"),
        "about": data.get("about"),
        "response_bytes": response_bytes,
        "identity_boundary": "public_mutable_username_selector",
    }
