#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and fixture readers for the read-only Reddit adapter."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_fixture import FixtureSequence
from _knowledge_social_reddit import (
    PageRequest,
    RedditAdapterError,
    RedditProviderUnavailableError,
)
from knowledge_social_import import canonical_json, reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SAFE_PROVIDER_FAILURES = (
    "PRAW is unavailable; install it outside the agent session",
    "PRAW major version 8 is required",
    "PRAW listing generator metadata is unavailable",
    "PRAW listing generator is incompatible",
    "Reddit auth profile credentials are incomplete",
    "Reddit auth profile name is invalid",
)


class RedditReader(Protocol):
    """Minimal read-only provider surface used by Reddit collection."""

    def identity(self) -> dict[str, Any]: ...

    def page(self, request: PageRequest) -> dict[str, Any]: ...


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise RedditAdapterError("Reddit read response exceeds the safety limit")
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise RedditAdapterError("Reddit read provider returned no valid JSON") from error
    if not isinstance(payload, dict):
        raise RedditAdapterError("Reddit read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> RedditProviderUnavailableError:
    for message in SAFE_PROVIDER_FAILURES:
        if f"ERROR: {message}" in stderr:
            return RedditProviderUnavailableError(message)
    return RedditProviderUnavailableError("Reddit read provider is unavailable")


class GuardedPraw:
    """Execute only identity and allowlisted page reads in a bounded child."""

    def __init__(self, helper: Path, profile: str) -> None:
        if helper.is_symlink() or not helper.is_file():
            raise RedditProviderUnavailableError("Reddit read provider is unavailable")
        self.helper = helper
        self.profile = profile

    def _environment(self) -> dict[str, str]:
        profile_prefix = f"REDDIT_{self.profile.upper()}_"
        credential_names = {
            f"{profile_prefix}{field}"
            for field in (
                "CLIENT_ID",
                "CLIENT_SECRET",
                "PASSWORD",
                "USER_AGENT",
                "USERNAME",
            )
        }
        inherited = {
            "HOME",
            "HTTPS_PROXY",
            "HTTP_PROXY",
            "LANG",
            "LC_ALL",
            "NO_PROXY",
            "PATH",
            "REQUESTS_CA_BUNDLE",
            "SSL_CERT_FILE",
            "TMPDIR",
            "https_proxy",
            "http_proxy",
            "no_proxy",
        }
        environment = {
            key: value
            for key, value in os.environ.items()
            if key in inherited or key in credential_names
        }
        if os.environ.get("AIDEVOPS_TEST_MODE") == "1":
            for key in (
                "AIDEVOPS_TEST_MODE",
                "PYTHONPATH",
                "REDDIT_READ_LOG",
                "REDDIT_READ_MODE",
            ):
                if key in os.environ:
                    environment[key] = os.environ[key]
        return environment

    def _run(self, request: dict[str, Any]) -> dict[str, Any]:
        try:
            completed = subprocess.run(  # nosec B603 -- fixed helper and fixed argv
                [sys.executable, str(self.helper), "--profile", self.profile],
                check=False,
                capture_output=True,
                input=canonical_json(request),
                env=self._environment(),
                shell=False,
                text=True,
                timeout=READ_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired as error:
            raise RedditProviderUnavailableError(
                "Reddit read provider timed out"
            ) from error
        except OSError as error:
            raise RedditProviderUnavailableError(
                "Reddit read provider is unavailable"
            ) from error
        if completed.returncode != 0:
            raise _provider_failure(completed.stderr)
        return _decode_output(completed.stdout)

    def identity(self) -> dict[str, Any]:
        return self._run({"action": "identity"})

    def page(self, request: PageRequest) -> dict[str, Any]:
        return self._run(request.payload())


def _fixture_page(entry: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    expectation = entry.get("expect_request", {})
    if not isinstance(expectation, dict):
        raise RedditAdapterError("Reddit fixture request expectation must be an object")
    actual = request.payload()
    if any(actual.get(key) != value for key, value in expectation.items()):
        raise RedditAdapterError("Reddit request did not resume at the expected checkpoint")
    response = entry.get("response", entry)
    if not isinstance(response, dict):
        raise RedditAdapterError("Reddit fixture page response must be an object")
    return response


class FixtureReddit:
    """Deterministic PRAW substitute for pagination and failure fixtures."""

    def __init__(self, path: Path) -> None:
        self.fixture = FixtureSequence(path, "Reddit", RedditAdapterError)

    def identity(self) -> dict[str, Any]:
        return self.fixture.identity()

    def page(self, request: PageRequest) -> dict[str, Any]:
        return _fixture_page(self.fixture.next_page(), request)


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Validate PRAW identity without allowing credential-shaped fields through."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise RedditAdapterError("Reddit account verification returned no account")
    remote_id = data.get("id")
    username = data.get("username")
    if not isinstance(remote_id, str) or not remote_id:
        raise RedditAdapterError("Reddit account verification returned no account ID")
    if username is not None and (not isinstance(username, str) or not username):
        raise RedditAdapterError("Reddit account name must be text")
    if remote_id != expected_id:
        raise RedditAdapterError(
            "selected Reddit account does not match the configured connection"
        )
    return data
