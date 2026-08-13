#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Outbound reconciliation decisions and privacy-safe operation history."""

from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass
from typing import Any

from _knowledge_social_outbound import _verified_operation, now_epoch
from knowledge_social_import import canonical_json
from knowledge_social_store import SocialStoreError, validate_opaque

LIST_OPERATIONS_SQL = """SELECT o.operation_id,o.action,o.state,o.scheduled_at,o.updated_at,
                    a.attempt_id,a.status AS attempt_status,a.provider_remote_id,
                    a.failure_class,a.started_at,a.finished_at
               FROM outbound_operations o
               LEFT JOIN outbound_attempts a ON a.attempt_id=o.last_attempt_id
              WHERE o.created_by=?
              ORDER BY o.created_at DESC,o.operation_id LIMIT ?"""
LIST_OPERATION_SQL = """SELECT o.operation_id,o.action,o.state,o.scheduled_at,o.updated_at,
                    a.attempt_id,a.status AS attempt_status,a.provider_remote_id,
                    a.failure_class,a.started_at,a.finished_at
               FROM outbound_operations o
               LEFT JOIN outbound_attempts a ON a.attempt_id=o.last_attempt_id
              WHERE o.created_by=? AND o.operation_id=?
              ORDER BY o.created_at DESC,o.operation_id LIMIT ?"""


@dataclass(frozen=True)
class ReconciliationRequest:
    """Owner decision that resolves one ambiguous provider attempt."""

    operation_id: str
    principal_id: str
    outcome: str
    provider_remote_id: str | None = None
    reconciled_at: int | None = None


@dataclass(frozen=True)
class ValidatedReconciliation:
    """Normalized owner decision ready for one fenced transaction."""

    operation_id: str
    principal_id: str
    outcome: str
    state: str
    provider_remote_id: str | None
    reconciled_at: int


def _validated_reconciliation(
    request: ReconciliationRequest,
) -> ValidatedReconciliation:
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
    return ValidatedReconciliation(
        validate_opaque(request.operation_id, "operation_id"),
        principal_id,
        request.outcome,
        state,
        provider_remote_id,
        reconciled_at,
    )


def _persist_reconciliation(
    database: sqlite3.Connection, decision: ValidatedReconciliation
) -> None:
    database.execute("BEGIN IMMEDIATE")
    try:
        row = _verified_operation(database, decision.operation_id)
        if row["state"] != "unknown" or row["created_by"] != decision.principal_id:
            raise SocialStoreError("only an owner unknown operation can be reconciled")
        changed = database.execute(
            """UPDATE outbound_attempts
                  SET status=?,finished_at=?,provider_remote_id=?,failure_class=?,diagnostics=?
                WHERE attempt_id=? AND operation_id=? AND claim_token=? AND status='unknown'""",
            (
                decision.state,
                decision.reconciled_at,
                decision.provider_remote_id,
                None if decision.state == "succeeded" else "reconciled_not_sent",
                canonical_json({"reconciled": decision.outcome}),
                row["last_attempt_id"],
                decision.operation_id,
                row["claim_token"],
            ),
        ).rowcount
        if changed != 1:
            raise SocialStoreError("unknown outbound receipt is inconsistent")
        database.execute(
            "UPDATE outbound_operations SET state=?,updated_at=? WHERE operation_id=?",
            (decision.state, decision.reconciled_at, decision.operation_id),
        )
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise


def reconcile_unknown(
    database: sqlite3.Connection, request: ReconciliationRequest
) -> dict[str, Any]:
    """Resolve an ambiguous attempt without ever placing it back in the queue."""
    decision = _validated_reconciliation(request)
    _persist_reconciliation(database, decision)
    result = {"operation_id": decision.operation_id, "state": decision.state}
    if decision.provider_remote_id is not None:
        result["provider_remote_id"] = decision.provider_remote_id
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
    if operation_id is None:
        rows = database.execute(
            LIST_OPERATIONS_SQL, (principal_id, limit)
        ).fetchall()
    else:
        rows = database.execute(
            LIST_OPERATION_SQL,
            (principal_id, validate_opaque(operation_id, "operation_id"), limit),
        ).fetchall()
    return [dict(row) for row in rows]
