#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared privacy-safe marketing optimization primitives."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any

SCHEMA_ATTRIBUTION = "aidevops.marketing-attribution/v1"
SCHEMA_EXPERIMENT_ANALYSIS = "aidevops.marketing-experiment-analysis/v1"
SCHEMA_REPORT = "aidevops.marketing-optimization-report/v1"
SCHEMA_RECOMMENDATION = "aidevops.growth-recommendation/v1"
PROHIBITED_MUTATIONS = [
    "publish",
    "message",
    "spend",
    "retarget",
    "change_audience",
    "change_offer",
    "mutate_provider_account",
]


class OptimizationError(ValueError):
    """Raised when an optimization input violates the public contract."""


def load_document(path: str) -> dict[str, Any]:
    document = json.loads(Path(path).expanduser().read_text(encoding="utf-8"))
    if not isinstance(document, dict):
        raise OptimizationError("input must be a JSON object")
    return document


def canonical(document: Any) -> str:
    return json.dumps(document, sort_keys=True, separators=(",", ":"), ensure_ascii=True)


def digest(prefix: str, document: Any) -> str:
    value = hashlib.sha256(canonical(document).encode("utf-8")).hexdigest()
    return f"{prefix}:{value}"


def timestamp(value: Any, field: str) -> datetime:
    if not isinstance(value, str):
        raise OptimizationError(f"{field} must be an RFC 3339 timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as exc:
        raise OptimizationError(f"{field} must be an RFC 3339 timestamp") from exc
    if parsed.tzinfo is None:
        raise OptimizationError(f"{field} must include a timezone")
    return parsed.astimezone(timezone.utc)


def decimal_value(value: Any, field: str) -> Decimal:
    if isinstance(value, bool) or not isinstance(value, (int, str)):
        raise OptimizationError(f"{field} must be an integer or canonical decimal string")
    try:
        return Decimal(str(value))
    except InvalidOperation as exc:
        raise OptimizationError(f"{field} is not numeric") from exc


def decimal_text(value: Decimal) -> str:
    normalized = format(value, "f")
    if "." in normalized:
        normalized = normalized.rstrip("0").rstrip(".")
    return normalized or "0"


def _artifact_identity(document: dict[str, Any]) -> Any:
    fields = ("projection_id", "analysis_id", "report_id", "recommendation_id")
    return next((document.get(field) for field in fields if document.get(field)), None)


def _artifact_time(document: dict[str, Any]) -> Any:
    return document.get("generated_at") or document.get("observed_at") or document.get("created_at")


def _guard_publish(target: Path, document: dict[str, Any]) -> None:
    if not target.exists():
        return
    existing = json.loads(target.read_text(encoding="utf-8"))
    existing_time = _artifact_time(existing)
    incoming_time = _artifact_time(document)
    same_identity = _artifact_identity(existing) == _artifact_identity(document)
    if same_identity or not existing_time or not incoming_time:
        return
    if timestamp(incoming_time, "incoming publish time") <= timestamp(existing_time, "existing publish time"):
        raise OptimizationError("atomic publish refused to overwrite an equal or newer analytical artifact")


def _atomic_replace(target: Path, rendered: str) -> None:
    file_descriptor, temporary = tempfile.mkstemp(prefix=f".{target.name}.", dir=target.parent)
    try:
        with os.fdopen(file_descriptor, "w", encoding="utf-8") as handle:
            handle.write(rendered)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, target)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_document(document: dict[str, Any], output: str | None) -> None:
    rendered = json.dumps(document, sort_keys=True, indent=2) + "\n"
    if output is None:
        print(rendered, end="")
        return
    target = Path(output).expanduser().absolute()
    target.parent.mkdir(parents=True, exist_ok=True)
    _guard_publish(target, document)
    _atomic_replace(target, rendered)
