#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared deterministic fixture sequence for live social adapters."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any


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
