#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and fixture readers for the read-only X adapter."""

from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_x import XAdapterError, response_status
from knowledge_social_import import reject_credentials


class XReader(Protocol):
    """Minimal read-only provider surface used by collection."""

    def identity(self) -> dict[str, Any]: ...

    def page(self, endpoint: str) -> dict[str, Any]: ...


def _decode_output(output: str) -> dict[str, Any]:
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise XAdapterError("xurl returned no valid JSON") from error
    if not isinstance(payload, dict):
        raise XAdapterError("xurl response root must be an object")
    return payload


class GuardedXurl:
    """Execute only the two read-only helper surfaces used by this adapter."""

    def __init__(self, helper: Path, app: str | None, username: str | None) -> None:
        if helper.is_symlink() or not helper.is_file():
            raise XAdapterError("guarded xurl helper is unavailable")
        self.helper = helper
        self.profile_args: list[str] = []
        if app:
            self.profile_args.extend(("--app", app))
        if username:
            self.profile_args.extend(("--username", username))

    def _json(self, command: list[str]) -> dict[str, Any]:
        completed = subprocess.run(  # nosec B603 -- fixed helper plus allowlisted read argv
            command, check=False, capture_output=True, text=True, timeout=120
        )
        payload = _decode_output(completed.stdout)
        if completed.returncode != 0 and response_status(payload) < 400:
            raise XAdapterError("xurl read request failed")
        return payload

    def identity(self) -> dict[str, Any]:
        return self._json([str(self.helper), "whoami", *self.profile_args])

    def page(self, endpoint: str) -> dict[str, Any]:
        return self._json(
            [str(self.helper), "run", *self.profile_args, "--", endpoint]
        )


def _load_fixture(path: Path) -> dict[str, Any]:
    if path.is_symlink() or not path.is_file():
        raise XAdapterError("X fixture must be a regular non-symlink file")
    try:
        fixture = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise XAdapterError("X fixture is not valid UTF-8 JSON") from error
    if not isinstance(fixture, dict) or not isinstance(fixture.get("pages"), list):
        raise XAdapterError("X fixture requires identity and pages")
    return fixture


def _fixture_page(entry: dict[str, Any], endpoint: str) -> dict[str, Any]:
    expectations = entry.get("expect_endpoint_contains", [])
    if not isinstance(expectations, list) or any(
        not isinstance(value, str) for value in expectations
    ):
        raise XAdapterError("X fixture endpoint expectations must be text")
    if any(value not in endpoint for value in expectations):
        raise XAdapterError("X request did not resume at the expected checkpoint")
    response = entry.get("response", entry)
    if not isinstance(response, dict):
        raise XAdapterError("X fixture page response must be an object")
    return response


class FixtureXurl:
    """Deterministic xurl substitute for pagination and failure fixtures."""

    def __init__(self, path: Path) -> None:
        self.fixture = _load_fixture(path)
        self.position = 0

    def identity(self) -> dict[str, Any]:
        identity = self.fixture.get("identity")
        if not isinstance(identity, dict):
            raise XAdapterError("X fixture identity must be an object")
        return identity

    def page(self, endpoint: str) -> dict[str, Any]:
        pages = self.fixture["pages"]
        if self.position >= len(pages) or not isinstance(pages[self.position], dict):
            raise XAdapterError("X fixture has no page for request")
        page = _fixture_page(pages[self.position], endpoint)
        self.position += 1
        return page


def _optional_text(record: dict[str, Any], key: str) -> None:
    value = record.get(key)
    if value is not None and not isinstance(value, str):
        raise XAdapterError(f"X account {key} must be text")


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Validate xurl identity without allowing credential-shaped fields through."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise XAdapterError("xurl account verification returned no account")
    remote_id = data.get("id")
    if not isinstance(remote_id, str) or not remote_id:
        raise XAdapterError("xurl account verification returned no account ID")
    _optional_text(data, "username")
    _optional_text(data, "name")
    if remote_id != expected_id:
        raise XAdapterError(
            "selected xurl account does not match the configured connection"
        )
    return data
