#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Outbound reconciliation decisions and privacy-safe operation history."""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from typing import Any

from _knowledge_social_outbound import _verified_operation, now_epoch
from knowledge_social_import import canonical_json
from knowledge_social_store import SocialStoreError, validate_opaque


@dataclass(frozen=True)
class ReconciliationRequest:
    """Owner decision that resolves one ambiguous provider attempt."""

    operation_id: str
    principal_id: str
    outcome: str
    provider_remote_id: str | None = None
    reconciled_at: int | None = None


def reconcile_unknown(
    database: sqlite3.Connection, request: ReconciliationRequest
) -> dict[str, Any]:
    """Resolve an ambiguous attempt without ever placing it back in the queue."""
    if request.outcome not in ("succeeded", "not-sent"):
        raise SocialStoreError("reconciliation outcome must be succeeded or not-sent")
    reconciled_at = (
        now_epoch() if request.reconciled_at is None else request.reconciled_at
    )
    principal_id = validate_opaque(request.principal_id, "principal_id")
    state = "succeeded" if request.outcome == "succeeded" else "failed"
    if state == "succeeded" and request.provider_remote_id is None:
        raise SocialStoreError("successful reconciliation requires a provider ID")
    if state == "failed" and request.provider_remote_id is not None:
        raise SocialStoreError("not-sent reconciliation forbids a provider ID")
    provider_remote_id = request.provider_remote_id
    if provider_remote_id is not None:
        provider_remote_id = validate_opaque(provider_remote_id, "provider_remote_id")
    database.execute("BEGIN IMMEDIATE")
    try:
        row = _verified_operation(database, request.operation_id)
        if row["state"] != "unknown" or row["created_by"] != principal_id:
            raise SocialStoreError("only an owner unknown operation can be reconciled")
        changed = database.execute(
            """UPDATE outbound_attempts
                  SET status=?,finished_at=?,provider_remote_id=?,failure_class=?,diagnostics=?
                WHERE attempt_id=? AND operation_id=? AND claim_token=? AND status='unknown'""",
            (
                state,
                reconciled_at,
                provider_remote_id,
                None if state == "succeeded" else "reconciled_not_sent",
                canonical_json({"reconciled": request.outcome}),
                row["last_attempt_id"],
                request.operation_id,
                row["claim_token"],
            ),
        ).rowcount
        if changed != 1:
            raise SocialStoreError("unknown outbound receipt is inconsistent")
        database.execute(
            "UPDATE outbound_operations SET state=?,updated_at=? WHERE operation_id=?",
            (state, reconciled_at, request.operation_id),
        )
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    result = {"operation_id": request.operation_id, "state": state}
    if provider_remote_id is not None:
        result["provider_remote_id"] = provider_remote_id
    return result


def list_operations(
    database: sqlite3.Connection,
    principal_id: str,
    operation_id: str | None,
    limit: int,
) -> list[dict[str, Any]]:
    """List privacy-safe operation and receipt metadata for one owner."""
    if limit < 1 or limit > 1000:
        raise SocialStoreError("operation list limit must be between 1 and 1000")
    principal_id = validate_opaque(principal_id, "principal_id")
    parameters: list[Any] = [principal_id]
    condition = "o.created_by=?"
    if operation_id is not None:
        condition += " AND o.operation_id=?"
        parameters.append(validate_opaque(operation_id, "operation_id"))
    parameters.append(limit)
    rows = database.execute(
        f"""SELECT o.operation_id,o.action,o.state,o.scheduled_at,o.updated_at,
                    a.attempt_id,a.status AS attempt_status,a.provider_remote_id,
                    a.failure_class,a.started_at,a.finished_at
               FROM outbound_operations o
               LEFT JOIN outbound_attempts a ON a.attempt_id=o.last_attempt_id
              WHERE {condition}
              ORDER BY o.created_at DESC,o.operation_id LIMIT ?""",  # nosec B608 -- fixed clauses
        parameters,
    ).fetchall()
    return [dict(row) for row in rows]
