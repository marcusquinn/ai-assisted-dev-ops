#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared types and bounded input handling for performance adapters."""

from __future__ import annotations

import json
import os
import stat
from dataclasses import dataclass
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any

from performance_contract import PerformanceContractError

MAX_INPUT_BYTES = 20 * 1024 * 1024
FIXTURE_ONLY_ADAPTERS = {"social", "analytics", "crm", "commerce", "outreach"}
ADAPTERS = {"normalized", "campaign", "phase1", *FIXTURE_ONLY_ADAPTERS}


class PerformanceAdapterError(PerformanceContractError):
    """Raised when a source fixture cannot be mapped safely."""


@dataclass(frozen=True)
class AdapterResult:
    """Normalized batch plus content-free per-record adapter failures."""

    batch: dict[str, Any]
    errors: list[dict[str, Any]]
    raw_bytes: bytes
    suffix: str


def read_input(path: Path) -> bytes:
    """Read one bounded regular file without following a directory contract."""
    if path.is_symlink():
        raise PerformanceAdapterError("input must be a regular non-symlink file")
    descriptor = -1
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise PerformanceAdapterError("input must be a regular non-symlink file")
        if metadata.st_size > MAX_INPUT_BYTES:
            raise PerformanceAdapterError("input exceeds the 20 MiB safety limit")
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = -1
            data = handle.read(MAX_INPUT_BYTES + 1)
        if len(data) > MAX_INPUT_BYTES:
            raise PerformanceAdapterError("input exceeds the 20 MiB safety limit")
        return data
    except OSError as exc:
        raise PerformanceAdapterError("input must be a readable regular non-symlink file") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def load_json(raw_bytes: bytes) -> dict[str, Any]:
    """Decode one exact-decimal UTF-8 JSON object."""
    try:
        document = json.loads(raw_bytes.decode("utf-8"), parse_float=Decimal)
    except (UnicodeDecodeError, json.JSONDecodeError, InvalidOperation, ValueError) as exc:
        raise PerformanceAdapterError("input must be valid UTF-8 JSON") from exc
    if not isinstance(document, dict):
        raise PerformanceAdapterError("input JSON must be an object")
    return document
