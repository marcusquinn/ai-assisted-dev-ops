#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Health projection for knowledge collector state."""

from __future__ import annotations

from typing import Any

from _knowledge_collector_model import Connection, _record, due_at


def _health(connection: Connection, record: dict[str, Any], now: int) -> str:
    health = "healthy" if record.get("last_success", 0) else "pending"
    if not connection.enabled:
        health = "disabled"
    elif connection.mode in ("archive", "manual"):
        health = "manual"
    elif record.get("status") == "running":
        health = "pending"
    elif isinstance(record.get("rate_reset_at"), int) and record["rate_reset_at"] > now:
        health = "rate-reset"
    elif isinstance(record.get("consecutive_failures", 0), int) and record.get(
        "consecutive_failures", 0
    ) >= connection.alert_after_failures:
        health = "terminal-failure"
    elif record.get("status") == "pending":
        health = "pending"
    elif record.get("status") == "partial" or record.get("coverage_status") == "partial":
        health = "partial"
    else:
        freshness_reference = record.get("last_success", 0) or record.get("last_attempt", 0)
        if freshness_reference and now - freshness_reference > connection.stale_seconds:
            health = "stale"
    return health


def health_record(
    connection: Connection, record: dict[str, Any], now: int
) -> dict[str, Any]:
    """Project one content-free collector record for shared health consumers."""
    boundary = due_at(connection, record, now)
    health = _health(connection, record, now)
    last_success = record.get("last_success", 0)
    return {
        "connection_id": connection.connection_id,
        "connector_id": connection.connector_id,
        "due": boundary is not None and boundary <= now,
        "freshness_lag_seconds": now - last_success if last_success else None,
        "health": health,
        "missed_sla": health in ("stale", "terminal-failure"),
        "mode": connection.mode,
        "next_due": boundary,
    }


def plan(connections: list[Connection], state: dict[str, Any], now: int) -> list[dict[str, Any]]:
    result = []
    for connection in connections:
        record = _record(state, connection.connection_id)
        result.append(health_record(connection, record, now))
    return result
