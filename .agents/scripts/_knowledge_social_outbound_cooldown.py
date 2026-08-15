#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Account cooldown queries and pre-provider claim deferral."""

from __future__ import annotations

import sqlite3
from typing import Any

from _knowledge_social_outbound import ClaimedOperation
from knowledge_social_import import canonical_json
from knowledge_social_store import SocialStoreError, validate_opaque


def active_connection_cooldown(
    database: sqlite3.Connection, connection_id: str, current_time: int
) -> int | None:
    """Return the latest active reset boundary for one exact connection."""
    connection_id = validate_opaque(connection_id, "connection_id")
    if current_time < 0:
        raise SocialStoreError("cooldown time must be a non-negative epoch")
    row = database.execute(
        """SELECT MAX(CAST(retry_after AS INTEGER)) AS reset_at
             FROM sync_runs
            WHERE connection_id=? AND status='paused' AND failure_class='rate_limit'
              AND retry_after!='' AND retry_after NOT GLOB '*[^0-9]*'
              AND CAST(retry_after AS INTEGER)>?""",
        (connection_id, current_time),
    ).fetchone()
    return int(row["reset_at"]) if row and row["reset_at"] is not None else None


def _cooldown_claim_row(
    database: sqlite3.Connection, operation_id: str
) -> sqlite3.Row | None:
    return database.execute(
        """SELECT o.connection_id,o.state,o.claim_token,o.claimed_by,
                  o.last_attempt_id,a.status,a.provider_started_at
             FROM outbound_operations o
             JOIN outbound_attempts a ON a.attempt_id=o.last_attempt_id
            WHERE o.operation_id=?""",
        (operation_id,),
    ).fetchone()


def _assert_cooldown_claim(
    row: sqlite3.Row | None, claimed: ClaimedOperation, executor_id: str
) -> None:
    expected = (
        "claimed",
        claimed.claim_token,
        executor_id,
        claimed.attempt_id,
        "running",
        None,
    )
    actual = tuple(row)[1:] if row is not None else ()
    if actual != expected:
        raise SocialStoreError("cooldown deferral claim is stale")


def _persist_cooldown_deferral(
    database: sqlite3.Connection,
    claimed: ClaimedOperation,
    executor_id: str,
    current_time: int,
) -> None:
    attempt_changed = database.execute(
        """UPDATE outbound_attempts
              SET status='failed',finished_at=?,failure_class='rate_limit',diagnostics=?
            WHERE attempt_id=? AND operation_id=? AND claim_token=?
              AND executor_id=? AND status='running' AND provider_started_at IS NULL""",
        (
            current_time,
            canonical_json({"phase": "pre-provider", "reason": "cooldown"}),
            claimed.attempt_id,
            claimed.operation_id,
            claimed.claim_token,
            executor_id,
        ),
    ).rowcount
    operation_changed = database.execute(
        """UPDATE outbound_operations
              SET state='approved',claimed_by=NULL,claim_expires_at=NULL,updated_at=?
            WHERE operation_id=? AND state='claimed' AND claim_token=?
              AND claimed_by=? AND last_attempt_id=?""",
        (
            current_time,
            claimed.operation_id,
            claimed.claim_token,
            executor_id,
            claimed.attempt_id,
        ),
    ).rowcount
    if attempt_changed != 1 or operation_changed != 1:
        raise SocialStoreError("cooldown deferral claim is inconsistent")


def defer_claim_for_cooldown(
    database: sqlite3.Connection,
    claimed: ClaimedOperation,
    executor_id: str,
    current_time: int,
) -> dict[str, Any] | None:
    """Return a pre-provider claim to approved while preserving its attempt."""
    executor_id = validate_opaque(executor_id, "executor_id")
    database.execute("BEGIN IMMEDIATE")
    try:
        row = _cooldown_claim_row(database, claimed.operation_id)
        _assert_cooldown_claim(row, claimed, executor_id)
        if row is None:
            raise SocialStoreError("cooldown deferral claim does not exist")
        reset_at = active_connection_cooldown(
            database, str(row["connection_id"]), current_time
        )
        if reset_at is None:
            database.execute("ROLLBACK")
            return None
        _persist_cooldown_deferral(database, claimed, executor_id, current_time)
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    return {
        "operation_id": claimed.operation_id,
        "attempt_id": claimed.attempt_id,
        "state": "approved",
        "failure_class": "rate_limit",
        "retry_after": reset_at,
    }
