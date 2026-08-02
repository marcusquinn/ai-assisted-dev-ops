#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Apply normalized collector receipts to durable state."""

from __future__ import annotations

from typing import Any

from _knowledge_collector_model import Connection

OPTIONAL_RECEIPT_KEYS = (
    "pages", "items", "bytes", "budget_units", "rate_reset_at", "coverage_status", "budget_stop"
)


def _record_failure(record: dict[str, Any], connection: Connection, now: int) -> None:
    failures = int(record.get("consecutive_failures", 0)) + 1
    record.update(
        {
            "alert": failures >= connection.alert_after_failures,
            "collector_outcome": "failed",
            "consecutive_failures": failures,
            "last_terminal_failure": now,
            "status": "failed",
        }
    )


def _apply_receipt(
    record: dict[str, Any],
    connection: Connection,
    receipt: dict[str, Any],
    now: int,
    returncode: int,
) -> tuple[int, bool]:
    changed = receipt.pop("changed_count")
    disposition = receipt.pop("disposition")
    if returncode != 0 and disposition == "complete":
        disposition = "failed"
    projection_pending = connection.projection_root is not None and (
        changed > 0 or record.get("projection_status") == "pending"
    )
    for key in OPTIONAL_RECEIPT_KEYS:
        record.pop(key, None)
    record.update(
        {
            "changed_count": changed,
            "collector_outcome": disposition,
            "projection_status": "pending" if projection_pending else "not-needed",
            **receipt,
        }
    )
    if disposition == "failed":
        _record_failure(record, connection, now)
    elif disposition == "deferred":
        record.update({"last_deferred": now, "status": "pending"})
    elif disposition == "partial":
        record.update({"last_partial": now, "status": "partial"})
    else:
        record.update(
            {
                "alert": False,
                "consecutive_failures": 0,
                "last_success": now,
                "status": "partial" if projection_pending else "complete",
            }
        )
        if connection.event_token is not None:
            record["event_token"] = connection.event_token
    return changed, projection_pending
