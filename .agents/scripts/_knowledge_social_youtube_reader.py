#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and fixture readers for the read-only YouTube adapter."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_fixture import FixtureSequence
from _knowledge_social_oauth_reader import (
    GuardedOAuthPolicy,
    GuardedOAuthReader,
)
from _knowledge_social_youtube import (
    PageRequest,
    YouTubeAdapterError,
    YouTubeProviderUnavailableError,
    youtube_id,
)
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SAFE_PROVIDER_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "YouTube OAuth profile access token is missing",
    "YouTube OAuth profile name is invalid",
    "selected YouTube channel does not match the configured connection",
)


class YouTubeReader(Protocol):
    """Minimal read-only provider surface used by YouTube collection."""

    def identity(self, expected_id: str) -> dict[str, Any]: ...

    def page(self, request: PageRequest) -> dict[str, Any]: ...


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise YouTubeAdapterError("YouTube read response exceeds the safety limit")
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise YouTubeAdapterError("YouTube read provider returned no valid JSON") from error
    if not isinstance(payload, dict):
        raise YouTubeAdapterError("YouTube read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> YouTubeProviderUnavailableError:
    for message in SAFE_PROVIDER_FAILURES:
        if f"ERROR: {message}" in stderr:
            return YouTubeProviderUnavailableError(message)
    return YouTubeProviderUnavailableError("YouTube read provider is unavailable")


YOUTUBE_OAUTH_POLICY = GuardedOAuthPolicy(
    "YouTube",
    "YOUTUBE",
    "YOUTUBE_READ_LOG",
    READ_TIMEOUT_SECONDS,
    _decode_output,
    _provider_failure,
    YouTubeProviderUnavailableError,
)


class GuardedYouTubeOAuth(GuardedOAuthReader):
    """Execute only identity and allowlisted page reads in a bounded child."""

    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, YOUTUBE_OAUTH_POLICY)


def _fixture_page(entry: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    expectation = entry.get("expect_request", {})
    if not isinstance(expectation, dict):
        raise YouTubeAdapterError("YouTube fixture request expectation must be an object")
    actual = request.payload()
    if any(actual.get(key) != value for key, value in expectation.items()):
        raise YouTubeAdapterError(
            "YouTube request did not resume at the expected checkpoint"
        )
    response = entry.get("response", entry)
    if not isinstance(response, dict):
        raise YouTubeAdapterError("YouTube fixture page response must be an object")
    return response


class FixtureYouTube:
    """Deterministic OAuth substitute for pagination and failure fixtures."""

    def __init__(self, path: Path) -> None:
        self.fixture = FixtureSequence(path, "YouTube", YouTubeAdapterError)

    def identity(self, expected_id: str) -> dict[str, Any]:
        del expected_id
        return self.fixture.identity()

    def page(self, request: PageRequest) -> dict[str, Any]:
        return _fixture_page(self.fixture.next_page(), request)


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Validate OAuth identity without allowing credential-shaped fields through."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise YouTubeAdapterError("YouTube account verification returned no channel")
    remote_id = youtube_id(data.get("id"), "account ID")
    uploads_id = youtube_id(data.get("uploads_playlist_id"), "uploads playlist ID")
    title = data.get("title")
    handle = data.get("handle")
    if title is not None and (not isinstance(title, str) or not title):
        raise YouTubeAdapterError("YouTube channel title must be text")
    if handle is not None and (not isinstance(handle, str) or not handle):
        raise YouTubeAdapterError("YouTube channel handle must be text")
    if remote_id != expected_id:
        raise YouTubeAdapterError(
            "selected YouTube channel does not match the configured connection"
        )
    return {
        "id": remote_id,
        "uploads_playlist_id": uploads_id,
        "title": title,
        "handle": handle,
    }
