#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared deterministic fixture sequence for live social adapters."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Protocol


class FixturePageRequest(Protocol):
    def payload(self) -> dict[str, Any]: ...


class FixtureSequence:
    """Load one private fixture and expose identity plus ordered page entries."""

    def __init__(self, path: Path, provider: str, error_type: type[Exception]) -> None:
        self.provider = provider
        self.error_type = error_type
        self.fixture = self._load(path)
        self.position = 0

    def _error(self, message: str) -> Exception:
        return self.error_type(f"{self.provider} fixture {message}")

    def _load(self, path: Path) -> dict[str, Any]:
        if path.is_symlink() or not path.is_file():
            raise self._error("must be a regular non-symlink file")
        try:
            fixture = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as error:
            raise self._error("is not valid UTF-8 JSON") from error
        if not isinstance(fixture, dict) or not isinstance(fixture.get("pages"), list):
            raise self._error("requires identity and pages")
        return fixture

    def identity(self) -> dict[str, Any]:
        identity = self.fixture.get("identity")
        if not isinstance(identity, dict):
            raise self._error("identity must be an object")
        return identity

    def next_page(self) -> dict[str, Any]:
        pages = self.fixture["pages"]
        if self.position >= len(pages) or not isinstance(pages[self.position], dict):
            raise self._error("has no page for request")
        page = pages[self.position]
        self.position += 1
        return page


class FixturePageReader:
    """Match provider page requests against one deterministic fixture sequence."""

    def __init__(self, path: Path, provider: str, error_type: type[Exception]) -> None:
        self.provider = provider
        self.error_type = error_type
        self.fixture = FixtureSequence(path, provider, error_type)

    def _object(self, value: Any, message: str) -> dict[str, Any]:
        if not isinstance(value, dict):
            raise self.error_type(f"{self.provider} {message}")
        return value

    def identity(self, expected_id: str) -> dict[str, Any]:
        del expected_id
        return self.fixture.identity()

    def page(self, request: FixturePageRequest) -> dict[str, Any]:
        entry = self.fixture.next_page()
        expectation = self._object(
            entry.get("expect_request", {}),
            "fixture request expectation must be an object",
        )
        actual = request.payload()
        for key, value in expectation.items():
            if actual.get(key) != value:
                raise self.error_type(
                    f"{self.provider} request did not resume at the expected checkpoint"
                )
        return self._object(
            entry.get("response", entry),
            "fixture page response must be an object",
        )
