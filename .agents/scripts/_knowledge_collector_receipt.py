#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Content-free receipt normalization for knowledge collectors."""

from __future__ import annotations

import json
import re
from datetime import datetime
from typing import Any

OPAQUE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
CHANGE_KEYS = ("changed_count", "fetched_count", "normalized_items", "resource_count", "resources", "processed")
COUNT_KEYS = ("pages", "items", "bytes", "budget_units")
COVERAGE_STATES = frozenset(("complete", "partial", "unavailable", "unknown"))
DEFERRED_STATUSES = frozenset(("busy", "deferred", "rate_limited"))
PARTIAL_STATUSES = frozenset(("budget-stopped", "budget_exhausted", "delta_unavailable", "partial", "partial_error"))
FAILED_STATUSES = frozenset(("error", "failed"))
COMPLETE_STATUSES = frozenset(("complete", "ok", "success"))


class CollectorScheduleError(ValueError):
    """Raised for a privacy-safe collector scheduling failure."""


def _last_object(stdout: str) -> dict[str, Any]:
    for line in reversed(stdout.splitlines()):
        try:
            candidate = json.loads(line)
        except (json.JSONDecodeError, UnicodeError):
            continue
        if isinstance(candidate, dict):
            return candidate
    raise CollectorScheduleError("collector did not emit a valid receipt")


def _changed_count(value: dict[str, Any]) -> int:
    for key in CHANGE_KEYS:
        count = value.get(key)
        if isinstance(count, int) and not isinstance(count, bool) and count >= 0:
            return count
    counts = value.get("counts")
    imported = counts.get("imported") if isinstance(counts, dict) else None
    if isinstance(imported, int) and not isinstance(imported, bool) and imported >= 0:
        return imported
    raise CollectorScheduleError("collector receipt has no changed count")


def _metadata(value: dict[str, Any]) -> dict[str, Any]:
    receipt: dict[str, Any] = {"changed_count": _changed_count(value)}
    for key in COUNT_KEYS:
        count = value.get(key)
        if isinstance(count, int) and not isinstance(count, bool) and count >= 0:
            receipt[key] = count
    rate_reset = value.get("rate_reset_at")
    if isinstance(rate_reset, int) and not isinstance(rate_reset, bool) and rate_reset >= 0:
        receipt["rate_reset_at"] = rate_reset
    coverage = value.get("coverage_status")
    if coverage in COVERAGE_STATES:
        receipt["coverage_status"] = coverage
    if isinstance(value.get("budget_stop"), bool):
        receipt["budget_stop"] = value["budget_stop"]
    return receipt


def _validated_status(value: dict[str, Any]) -> tuple[str, str | None]:
    if value.get("commit_state") in ("dry-run", "planned"):
        raise CollectorScheduleError("collector receipt reports an uncommitted run")
    status = value.get("collector_status", value.get("status", "complete"))
    failure_class = value.get("failure_class")
    if not isinstance(status, str) or not OPAQUE.fullmatch(status):
        raise CollectorScheduleError("collector receipt status is invalid")
    if failure_class is not None and (not isinstance(failure_class, str) or not OPAQUE.fullmatch(failure_class)):
        raise CollectorScheduleError("collector receipt failure class is invalid")
    return status, failure_class


def _disposition(receipt: dict[str, Any], status: str, failure_class: str | None) -> str:
    if status in DEFERRED_STATUSES:
        return "deferred"
    if status in PARTIAL_STATUSES or failure_class == "delta_not_supported":
        receipt.setdefault("coverage_status", "unavailable" if status == "delta_unavailable" else "partial")
        if status in ("budget-stopped", "budget_exhausted"):
            receipt["budget_stop"] = True
        return "partial"
    if status in FAILED_STATUSES or failure_class is not None:
        return "failed"
    if receipt.get("coverage_status") == "partial":
        return "partial"
    if status in COMPLETE_STATUSES:
        return "complete"
    raise CollectorScheduleError("collector receipt status is unsupported")


def _duration(value: Any, now: int | None) -> int:
    if isinstance(value, str) and value.isdigit():
        value = int(value)
    if isinstance(value, bool) or not isinstance(value, int) or not 0 <= value <= 31_536_000 or now is None:
        raise CollectorScheduleError("collector retry duration is invalid")
    return now + value


def _retry_boundary(value: Any, now: int | None) -> int:
    if isinstance(value, int) and not isinstance(value, bool):
        return max(0, value)
    if not isinstance(value, str):
        raise CollectorScheduleError("collector retry boundary is invalid")
    try:
        if value.isdigit():
            if now is None:
                raise ValueError
            return now + int(value)
        parsed_retry = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed_retry.tzinfo is None:
            raise ValueError
        return int(parsed_retry.timestamp())
    except (OverflowError, ValueError) as error:
        raise CollectorScheduleError("collector retry boundary is invalid") from error


def _apply_retry(value: dict[str, Any], receipt: dict[str, Any], now: int | None) -> None:
    retry_seconds = value.get("retry_after_seconds")
    retry_after = value.get("retry_after")
    if retry_seconds is not None and retry_after is not None:
        raise CollectorScheduleError("collector receipt has ambiguous retry boundaries")
    if retry_seconds is not None:
        receipt["rate_reset_at"] = _duration(retry_seconds, now)
    elif retry_after is not None:
        receipt["rate_reset_at"] = _retry_boundary(retry_after, now)


def _receipt(stdout: str, now: int | None = None) -> dict[str, Any]:
    value = _last_object(stdout)
    receipt = _metadata(value)
    status, failure_class = _validated_status(value)
    receipt["disposition"] = _disposition(receipt, status, failure_class)
    _apply_retry(value, receipt, now)
    return receipt
