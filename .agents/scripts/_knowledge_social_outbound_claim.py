#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Atomic outbound operation claim transaction."""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass

from _knowledge_social_outbound import ClaimedOperation, _new_id, _verified_operation
from _knowledge_social_outbound_cooldown import active_connection_cooldown
from knowledge_social_store import SocialStoreError, validate_opaque

CLAIM_OPERATION_SQL = """UPDATE outbound_operations
                  SET state='claimed',claim_token=?,claimed_by=?,claim_expires_at=?,
                      last_attempt_id=?,updated_at=?
                WHERE operation_id=? AND state='approved'"""
INSERT_ATTEMPT_SQL = """INSERT INTO outbound_attempts(
                attempt_id,operation_id,claim_token,executor_id,status,started_at)
               VALUES(?,?,?,?,?,?)"""


@dataclass(frozen=True)
class ClaimRequest:
    """Owner, executor, and lease values for one atomic operation claim."""

    operation_id: str
    principal_id: str
    executor_id: str
    current_time: int
    claim_seconds: int


def _claimable_operation(
    database: sqlite3.Connection, request: ClaimRequest, principal_id: str
) -> sqlite3.Row:
    row = _verified_operation(database, request.operation_id)
    invalid_state = row["state"] != "approved"
    not_due = int(row["scheduled_at"]) > request.current_time
    wrong_owner = row["created_by"] != principal_id
    if invalid_state or not_due or wrong_owner:
        raise SocialStoreError("operation is not due and approved")
    if active_connection_cooldown(
        database, str(row["connection_id"]), request.current_time
    ) is not None:
        raise SocialStoreError("operation account is in provider cooldown")
    approval = database.execute(
        """SELECT approval_id FROM outbound_approvals
            WHERE operation_id=? AND principal_id=? AND intent_sha256=?
              AND revoked_at IS NULL AND expires_at>?
            ORDER BY approved_at DESC LIMIT 1""",
        (request.operation_id, principal_id, row["intent_sha256"], request.current_time),
    ).fetchone()
    if approval is None:
        raise SocialStoreError("operation approval is missing or expired")
    return row


def _persist_claim(
    database: sqlite3.Connection,
    request: ClaimRequest,
    row: sqlite3.Row,
    executor_id: str,
) -> tuple[int, str]:
    claim_token = int(row["claim_token"]) + 1
    attempt_id = _new_id("att")
    changed = database.execute(
        CLAIM_OPERATION_SQL,
        (
            claim_token,
            executor_id,
            request.current_time + request.claim_seconds,
            attempt_id,
            request.current_time,
            request.operation_id,
        ),
    ).rowcount
    if changed != 1:
        raise SocialStoreError("operation claim lost a concurrent race")
    database.execute(
        INSERT_ATTEMPT_SQL,
        (
            attempt_id,
            request.operation_id,
            claim_token,
            executor_id,
            "running",
            request.current_time,
        ),
    )
    return claim_token, attempt_id


def claim_operation(
    database: sqlite3.Connection, request: ClaimRequest
) -> ClaimedOperation:
    """Atomically claim one due operation and persist its sole running attempt."""
    if request.claim_seconds < 1 or request.claim_seconds > 3600:
        raise SocialStoreError("claim_seconds must be between 1 and 3600")
    principal_id = validate_opaque(request.principal_id, "principal_id")
    executor_id = validate_opaque(request.executor_id, "executor_id")
    database.execute("BEGIN IMMEDIATE")
    try:
        row = _claimable_operation(database, request, principal_id)
        claim_token, attempt_id = _persist_claim(database, request, row, executor_id)
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    return ClaimedOperation(
        operation_id=request.operation_id,
        provider=str(row["provider"]),
        action=str(row["action"]),
        remote_account_id=str(row["remote_account_id"]),
        target_remote_id=row["target_remote_id"],
        destination_remote_id=row["destination_remote_id"],
        payload=row["payload"],
        subject=row["subject"],
        app_profile=row["app_profile"],
        username=row["username"],
        claim_token=claim_token,
        attempt_id=attempt_id,
        media_path=row["media_path"],
        media_sha256=row["media_sha256"],
    )
