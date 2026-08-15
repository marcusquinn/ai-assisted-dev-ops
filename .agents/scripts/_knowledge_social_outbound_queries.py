#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Read-only outbound queue and health projections."""

from __future__ import annotations

import sqlite3
from typing import Any

from _knowledge_social_outbound import _verified_operation
from knowledge_social_store import SocialStoreError, validate_opaque


def due_operation_ids(
    database: sqlite3.Connection,
    principal_id: str,
    current_time: int,
    limit: int,
) -> list[str]:
    """Return deterministic due IDs with a current exact-intent approval."""
    if limit < 1 or limit > 100:
        raise SocialStoreError("due limit must be between 1 and 100")
    principal_id = validate_opaque(principal_id, "principal_id")
    rows = database.execute(
        """SELECT DISTINCT o.* FROM outbound_operations o
              JOIN outbound_approvals a ON a.operation_id=o.operation_id
             WHERE o.state='approved' AND o.scheduled_at<=?
               AND o.created_by=? AND a.principal_id=?
               AND a.intent_sha256=o.intent_sha256
               AND a.revoked_at IS NULL AND a.expires_at>?
               AND NOT EXISTS(
                   SELECT 1 FROM sync_runs s
                    WHERE s.connection_id=o.connection_id
                      AND s.status='paused' AND s.failure_class='rate_limit'
                      AND s.retry_after!=''
                      AND s.retry_after NOT GLOB '*[^0-9]*'
                      AND CAST(s.retry_after AS INTEGER)>?
               )
              ORDER BY o.scheduled_at,o.operation_id LIMIT ?""",
        (current_time, principal_id, principal_id, current_time, current_time, limit),
    ).fetchall()
    return [
        str(_verified_operation(database, row["operation_id"])["operation_id"])
        for row in rows
    ]


def _health_projection(database: sqlite3.Connection) -> tuple[str, str, str, str]:
    has_reconciliations = database.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' "
        "AND name='outbound_reconciliations'"
    ).fetchone()
    if not has_reconciliations:
        return "a.status", "a.finished_at", "a.failure_class", ""
    return (
        "COALESCE(r.resolved_state,a.status)",
        "COALESCE(r.reconciled_at,a.finished_at)",
        "CASE WHEN r.outcome='succeeded' THEN NULL "
        "WHEN r.outcome='not-sent' THEN 'reconciled_not_sent' "
        "ELSE a.failure_class END",
        "LEFT JOIN outbound_reconciliations r ON r.attempt_id=a.attempt_id",
    )


def outbound_health_rows(
    database: sqlite3.Connection,
    principal_id: str,
    current_time: int,
) -> list[dict[str, Any]]:
    """Return content-free operation evidence for health aggregation."""
    principal_id = validate_opaque(principal_id, "principal_id")
    if current_time < 0:
        raise SocialStoreError("health time must be a non-negative epoch")
    attempt_status, finished_at, failure_class, reconciliation_join = (
        _health_projection(database)
    )
    # The interpolated fragments are selected exclusively by _health_projection.
    # nosemgrep: python.sqlalchemy.security.sqlalchemy-execute-raw-query.sqlalchemy-execute-raw-query, python_sql_rule-hardcoded-sql-expression
    rows = database.execute(
        f"""SELECT o.operation_id,o.provider,o.connection_id,o.action,o.state,
                  o.scheduled_at,o.updated_at,o.claim_expires_at,
                  a.attempt_id,{attempt_status} AS attempt_status,
                  a.provider_started_at,{finished_at} AS finished_at,
                  {failure_class} AS failure_class,
                  CASE WHEN EXISTS(
                      SELECT 1 FROM outbound_approvals p
                       WHERE p.operation_id=o.operation_id
                         AND p.principal_id=o.created_by
                         AND p.intent_sha256=o.intent_sha256
                         AND p.revoked_at IS NULL AND p.expires_at>?
                   ) THEN 1 ELSE 0 END AS has_current_approval
             FROM outbound_operations o
              LEFT JOIN outbound_attempts a ON a.attempt_id=o.last_attempt_id
              {reconciliation_join}
             WHERE o.created_by=?
             ORDER BY o.connection_id,o.action,o.created_at,o.operation_id""",  # nosec B608 -- fixed internal projections
        (current_time, principal_id),
    ).fetchall()
    return [dict(row) for row in rows]
