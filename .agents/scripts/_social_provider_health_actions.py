#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Action-level social provider readiness records."""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from typing import Any

from _social_provider_health_evidence import (
    authentication,
    evidence,
    freshness,
    latest_stream_sync,
    queue,
)

DIMENSIONS = (
    "catalogued", "deployed", "installed", "configured", "enabled",
    "authenticated", "authorized", "reachable", "runtime_compatible",
    "tool_visible", "usable",
)
UNWIRED_WRITE_PROVIDERS = frozenset(
    ("meta_facebook", "meta_instagram", "meta_threads", "tiktok")
)


@dataclass(frozen=True)
class DimensionState:
    """One complete readiness dimension projection."""

    configured: bool
    enabled: bool
    authenticated: bool | None
    authorized: bool
    reachable: bool | None
    usable: bool
    catalogued: bool = True
    deployed: bool = True
    installed: bool = True
    runtime_compatible: bool = True
    tool_visible: bool = True


@dataclass(frozen=True)
class ActionContext:
    """Shared health state for all actions on one account."""

    now: int
    configured: bool
    enabled: bool
    cooldown: bool
    quota: dict[str, int | bool | None]
    stale_after: int


@dataclass(frozen=True)
class WriteReadiness:
    """Derived write evidence used to project readiness dimensions."""

    action_queue: dict[str, int]
    authenticated: bool | None
    authorized: bool
    reachable: bool | None
    stale: bool


def dimensions(state: DimensionState) -> dict[str, bool | None]:
    """Render a stable schema-compatible readiness map."""
    return {name: getattr(state, name) for name in DIMENSIONS}


def aggregate_dimensions(records: list[dict[str, Any]]) -> dict[str, bool | None]:
    result: dict[str, bool | None] = {}
    for dimension in DIMENSIONS:
        values = [record["dimensions"][dimension] for record in records]
        result[dimension] = True if True in values else False if False in values else None
    return result


def readiness_status(
    values: dict[str, bool | None], *, ambiguous: bool, cooldown: bool, stale: bool
) -> str:
    """Return the highest-priority readiness state."""
    priorities = (
        (not values["configured"], "unconfigured"),
        (values["authenticated"] is False, "unauthenticated"),
        (ambiguous, "ambiguous"),
        (cooldown, "rate_limited"),
        (values["reachable"] is False, "unreachable"),
        (stale, "stale"),
        (bool(values["usable"]), "usable"),
        (values["authenticated"] is None or values["reachable"] is None, "unknown"),
        (not values["authorized"], "awaiting_approval"),
    )
    return next((status for applies, status in priorities if applies), "ready")


def next_action(status: str, mode: str = "aggregate") -> str:
    if status == "usable" and mode == "read":
        return "collect_enabled_stream"
    return {
        "unconfigured": "configure_selected_account",
        "unauthenticated": "refresh_authentication",
        "ambiguous": "reconcile_unknown_receipt",
        "rate_limited": "wait_for_provider_reset",
        "unreachable": "inspect_provider_availability",
        "stale": "refresh_provider_health",
        "usable": "execute_approved_intent",
        "awaiting_approval": "create_and_approve_intent",
        "ready": "wait_for_due_operation",
        "partial": "inspect_account_evidence",
        "unknown": "run_provider_preflight",
    }[status]


def fallback(status: str) -> str:
    return {
        "rate_limited": "wait_without_retry",
        "ambiguous": "owner_reconciliation_required",
    }.get(status, "gated_no_mutation")


def read_action_record(
    database: sqlite3.Connection,
    connection_id: str,
    action: str,
    context: ActionContext,
) -> dict[str, Any]:
    stored = evidence(latest_stream_sync(database, connection_id, action), [])
    authenticated, reachable = authentication(context.configured, stored)
    action_freshness, stale = freshness(stored, context.now, context.stale_after)
    authorized = authenticated is True and reachable is True
    usable = bool(authorized and not context.cooldown and not stale)
    values = dimensions(
        DimensionState(
            configured=context.configured,
            enabled=True,
            authenticated=authenticated,
            authorized=authorized,
            reachable=reachable,
            usable=usable,
        )
    )
    status = readiness_status(
        values, ambiguous=False, cooldown=context.cooldown, stale=stale
    )
    return {
        "action": action,
        "mode": "read",
        "dimensions": values,
        "queue": queue([], context.now),
        "quota": dict(context.quota),
        "freshness": action_freshness,
        "status": status,
        "fallback": fallback(status),
        "next_action": next_action(status, "read"),
    }


def _write_dimensions(
    context: ActionContext,
    readiness: WriteReadiness,
) -> dict[str, bool | None]:
    usable = bool(
        all(
            (
                readiness.action_queue["due"], context.configured,
                readiness.authenticated is True, readiness.reachable is True,
                readiness.authorized, not context.cooldown, not readiness.stale,
                readiness.action_queue["unknown"] == 0,
            )
        )
    )
    return dimensions(
        DimensionState(
            configured=context.configured,
            enabled=context.enabled,
            authenticated=readiness.authenticated,
            authorized=readiness.authorized,
            reachable=readiness.reachable,
            usable=usable,
        )
    )


def write_action_record(
    provider: str,
    action: str,
    rows: list[dict[str, Any]],
    context: ActionContext,
) -> dict[str, Any]:
    action_rows = [row for row in rows if row["action"] == action]
    action_queue = queue(action_rows, context.now)
    stored = evidence(None, action_rows)
    authenticated, reachable = authentication(context.configured, stored)
    if provider in UNWIRED_WRITE_PROVIDERS:
        reachable = False
    action_freshness, stale = freshness(stored, context.now, context.stale_after)
    authorized = any(
        row["state"] in ("approved", "claimed") and row["has_current_approval"]
        for row in action_rows
    )
    values = _write_dimensions(
        context,
        WriteReadiness(action_queue, authenticated, authorized, reachable, stale),
    )
    status = readiness_status(
        values,
        ambiguous=action_queue["unknown"] > 0,
        cooldown=context.cooldown,
        stale=stale,
    )
    return {
        "action": action,
        "mode": "write",
        "dimensions": values,
        "queue": action_queue,
        "quota": dict(context.quota),
        "freshness": dict(action_freshness),
        "status": status,
        "fallback": fallback(status),
        "next_action": next_action(status),
    }


def aggregate_status(records: list[dict[str, Any]]) -> str:
    statuses = {str(record["status"]) for record in records}
    if len(statuses) == 1:
        return next(iter(statuses))
    if statuses and statuses <= {"ready", "usable"}:
        return "usable" if "usable" in statuses else "ready"
    return "partial"
