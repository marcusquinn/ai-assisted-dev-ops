#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Outbound reconciliation decisions and privacy-safe operation history."""

from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass
from typing import Any, Iterable, Mapping

from _knowledge_social_outbound import (
    OUTBOUND_PROVIDER_ACTIONS,
    _new_id,
    _verified_operation,
    now_epoch,
)
from _knowledge_social_outbound_runtime import expire_claims
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
UNKNOWN_RECEIPTS_SQL = """SELECT o.operation_id,o.provider,o.connection_id,o.action,
                    o.updated_at,a.failure_class,a.provider_remote_id,a.finished_at
               FROM outbound_operations o
               JOIN outbound_attempts a ON a.attempt_id=o.last_attempt_id
              WHERE o.created_by=? AND o.state='unknown'
              ORDER BY o.updated_at,o.operation_id LIMIT ?"""


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


def _unknown_attempt(
    database: sqlite3.Connection,
    row: sqlite3.Row,
    decision: ValidatedReconciliation,
) -> sqlite3.Row:
    attempt = database.execute(
        """SELECT status,failure_class,provider_remote_id,finished_at,diagnostics
             FROM outbound_attempts
            WHERE attempt_id=? AND operation_id=? AND claim_token=? AND status='unknown'""",
        (row["last_attempt_id"], decision.operation_id, row["claim_token"]),
    ).fetchone()
    if attempt is None:
        raise SocialStoreError("unknown outbound receipt is inconsistent")
    return attempt


def _append_reconciliation(
    database: sqlite3.Connection,
    row: sqlite3.Row,
    attempt: sqlite3.Row,
    decision: ValidatedReconciliation,
) -> str:
    reconciliation_id = _new_id("rec")
    database.execute(
        """INSERT INTO outbound_reconciliations(
               reconciliation_id,operation_id,attempt_id,principal_id,outcome,
               resolved_state,provider_remote_id,reconciled_at,original_status,
               original_failure_class,original_provider_remote_id,
               original_finished_at,original_diagnostics)
           VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (
            reconciliation_id,
            decision.operation_id,
            row["last_attempt_id"],
            decision.principal_id,
            decision.outcome,
            decision.state,
            decision.provider_remote_id,
            decision.reconciled_at,
            attempt["status"],
            attempt["failure_class"],
            attempt["provider_remote_id"],
            attempt["finished_at"],
            attempt["diagnostics"],
        ),
    )
    return reconciliation_id


def _persist_reconciliation(
    database: sqlite3.Connection, decision: ValidatedReconciliation
) -> str:
    database.execute("BEGIN IMMEDIATE")
    try:
        row = _verified_operation(database, decision.operation_id)
        if row["state"] != "unknown" or row["created_by"] != decision.principal_id:
            raise SocialStoreError("only an owner unknown operation can be reconciled")
        attempt = _unknown_attempt(database, row, decision)
        reconciliation_id = _append_reconciliation(
            database, row, attempt, decision
        )
        changed = database.execute(
            """UPDATE outbound_operations SET state=?,updated_at=?
                 WHERE operation_id=? AND state='unknown'""",
            (decision.state, decision.reconciled_at, decision.operation_id),
        ).rowcount
        if changed != 1:
            raise SocialStoreError("unknown outbound operation is inconsistent")
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    return reconciliation_id


def reconcile_unknown(
    database: sqlite3.Connection, request: ReconciliationRequest
) -> dict[str, Any]:
    """Resolve an ambiguous attempt without ever placing it back in the queue."""
    decision = _validated_reconciliation(request)
    reconciliation_id = _persist_reconciliation(database, decision)
    result = {
        "operation_id": decision.operation_id,
        "reconciliation_id": reconciliation_id,
        "state": decision.state,
    }
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


def unknown_receipts(
    database: sqlite3.Connection,
    principal_id: str,
    limit: int,
) -> list[dict[str, Any]]:
    """Return bounded ambiguous receipts without private intent content."""
    if limit < 1 or limit > 1000:
        raise SocialStoreError("unknown receipt limit must be between 1 and 1000")
    principal_id = validate_opaque(principal_id, "principal_id")
    rows = database.execute(UNKNOWN_RECEIPTS_SQL, (principal_id, limit)).fetchall()
    return [dict(row) for row in rows]


def _validated_limits(limit: int, per_provider_limit: int) -> None:
    if limit < 1 or limit > 100:
        raise SocialStoreError("reconciliation limit must be between 1 and 100")
    if per_provider_limit < 1 or per_provider_limit > 20:
        raise SocialStoreError(
            "per-provider reconciliation limit must be between 1 and 20"
        )


def _decision_map(
    decisions: Iterable[ReconciliationRequest], principal_id: str
) -> dict[str, ReconciliationRequest]:
    result: dict[str, ReconciliationRequest] = {}
    for decision in decisions:
        operation_id = validate_opaque(decision.operation_id, "operation_id")
        if validate_opaque(decision.principal_id, "principal_id") != principal_id:
            raise SocialStoreError("reconciliation decision owner does not match")
        if operation_id in result:
            raise SocialStoreError("reconciliation decisions contain a duplicate operation")
        result[operation_id] = decision
    return result


def _decision_receipts(
    database: sqlite3.Connection,
    principal_id: str,
    operation_ids: Iterable[str],
) -> list[dict[str, Any]]:
    ids = tuple(operation_ids)
    if not ids:
        return []
    placeholders = ",".join("?" for _operation_id in ids)
    rows = database.execute(
        f"""SELECT o.operation_id,o.provider,o.connection_id,o.action,
                    o.updated_at,a.failure_class,a.provider_remote_id,a.finished_at
               FROM outbound_operations o
               JOIN outbound_attempts a ON a.attempt_id=o.last_attempt_id
              WHERE o.created_by=? AND o.state='unknown'
                AND o.operation_id IN ({placeholders})
              ORDER BY o.updated_at,o.operation_id""",  # nosec B608 -- placeholders only
        (principal_id, *ids),
    ).fetchall()
    return [dict(row) for row in rows]


def _bounded_receipts(
    receipts: Iterable[dict[str, Any]], limit: int, per_provider_limit: int
) -> list[dict[str, Any]]:
    if limit == 0:
        return []
    selected: list[dict[str, Any]] = []
    provider_counts: dict[str, int] = {}
    for receipt in receipts:
        provider = str(receipt["provider"])
        if provider_counts.get(provider, 0) >= per_provider_limit:
            continue
        provider_counts[provider] = provider_counts.get(provider, 0) + 1
        selected.append(receipt)
        if len(selected) == limit:
            break
    return selected


def bounded_reconcile(
    database: sqlite3.Connection,
    principal_id: str,
    current_time: int,
    *,
    decisions: Iterable[ReconciliationRequest] = (),
    cooldowns: Mapping[str, int] | None = None,
    limit: int = 10,
    per_provider_limit: int = 3,
) -> dict[str, Any]:
    """Apply bounded, account-cooldown-aware owner decisions without replay."""
    _validated_limits(limit, per_provider_limit)
    if current_time < 0:
        raise SocialStoreError("reconciliation time must be a non-negative epoch")
    principal_id = validate_opaque(principal_id, "principal_id")
    decision_by_id = _decision_map(decisions, principal_id)
    if len(decision_by_id) > limit:
        raise SocialStoreError("reconciliation decisions exceed the global limit")
    expired = expire_claims(database, principal_id, current_time, limit)
    remaining = limit - len(expired)
    candidates = (
        _decision_receipts(database, principal_id, decision_by_id)
        if decision_by_id
        else _bounded_receipts(
            unknown_receipts(
                database,
                principal_id,
                min(1000, limit * len(OUTBOUND_PROVIDER_ACTIONS)),
            ),
            remaining,
            per_provider_limit,
        )
    )
    cooldowns = cooldowns or {}
    resolved: list[dict[str, Any]] = []
    skipped: list[dict[str, str]] = []
    pending: list[dict[str, Any]] = []
    selected_ids: set[str] = set()
    provider_counts: dict[str, int] = {}
    for receipt in candidates:
        operation_id = str(receipt["operation_id"])
        provider = str(receipt["provider"])
        connection_id = str(receipt["connection_id"])
        selected_ids.add(operation_id)
        decision = decision_by_id.get(operation_id)
        if decision is None:
            pending.append(receipt)
            continue
        if cooldowns.get(connection_id, 0) > current_time:
            skipped.append(
                {
                    "operation_id": operation_id,
                    "provider_id": provider,
                    "reason": "cooldown",
                }
            )
            pending.append(receipt)
            continue
        if remaining == 0:
            skipped.append(
                {
                    "operation_id": operation_id,
                    "provider_id": provider,
                    "reason": "global_budget",
                }
            )
            pending.append(receipt)
            continue
        if provider_counts.get(provider, 0) >= per_provider_limit:
            skipped.append(
                {
                    "operation_id": operation_id,
                    "provider_id": provider,
                    "reason": "provider_budget",
                }
            )
            pending.append(receipt)
            continue
        resolved.append(reconcile_unknown(database, decision))
        provider_counts[provider] = provider_counts.get(provider, 0) + 1
        remaining -= 1
    for operation_id in sorted(set(decision_by_id) - selected_ids):
        skipped.append(
            {
                "operation_id": operation_id,
                "provider_id": "unknown",
                "reason": "not_due_or_budgeted",
            }
        )
    return {
        "expired_claims": expired,
        "resolved": resolved,
        "resolved_count": len(resolved),
        "skipped": skipped,
        "unresolved": pending,
        "unresolved_count": len(pending),
    }
