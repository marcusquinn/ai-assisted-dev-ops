#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Fenced outbound claim, attempt, receipt, and lease state."""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from typing import Any

from _knowledge_social_outbound import (
    FAILURE_CLASSES,
    ClaimedOperation,
    _new_id,
    _verified_operation,
    now_epoch,
)
from _knowledge_social_outbound_claim import ClaimRequest, claim_operation
from _knowledge_social_outbound_cooldown import (
    active_connection_cooldown,
    defer_claim_for_cooldown,
)
from _knowledge_social_outbound_queries import due_operation_ids, outbound_health_rows
from knowledge_social_import import canonical_json
from knowledge_social_store import SocialStoreError, validate_opaque

__all__ = [
    "ClaimRequest",
    "active_connection_cooldown",
    "due_operation_ids",
]


@dataclass(frozen=True)
class AttemptOutcome:
    """Privacy-safe terminal result for one fenced provider attempt."""

    status: str
    provider_remote_id: str | None = None
    failure_class: str | None = None
    finished_at: int | None = None
    retry_after: int | None = None


def record_provider_checkpoint(
    database: sqlite3.Connection,
    claimed: ClaimedOperation,
    executor_id: str,
    checkpoint_id: str,
) -> None:
    """Persist an opaque resumable provider ID before remote continuation."""
    executor_id = validate_opaque(executor_id, "executor_id")
    checkpoint_id = validate_opaque(checkpoint_id, "provider_checkpoint_id")
    changed = database.execute(
        """UPDATE outbound_attempts SET diagnostics=?
             WHERE attempt_id=? AND operation_id=? AND claim_token=? AND executor_id=?
               AND status='running' AND provider_started_at IS NOT NULL""",
        (
            canonical_json({"phase": "provider", "checkpoint": checkpoint_id}),
            claimed.attempt_id,
            claimed.operation_id,
            claimed.claim_token,
            executor_id,
        ),
    ).rowcount
    if changed != 1:
        raise SocialStoreError("outbound provider checkpoint is stale")


def mark_provider_started(
    database: sqlite3.Connection,
    claimed: ClaimedOperation,
    executor_id: str,
    *,
    started_at: int | None = None,
) -> None:
    """Durably mark the boundary after which failures are always ambiguous."""
    started_at = now_epoch() if started_at is None else started_at
    executor_id = validate_opaque(executor_id, "executor_id")
    changed = database.execute(
        """UPDATE outbound_attempts SET provider_started_at=?
             WHERE attempt_id=? AND operation_id=? AND claim_token=?
               AND executor_id=? AND status='running' AND provider_started_at IS NULL
               AND EXISTS(
                   SELECT 1 FROM outbound_operations o
                   JOIN outbound_approvals a ON a.operation_id=o.operation_id
                    WHERE o.operation_id=outbound_attempts.operation_id
                      AND o.state='claimed' AND o.claim_token=outbound_attempts.claim_token
                       AND o.claimed_by=? AND o.last_attempt_id=outbound_attempts.attempt_id
                       AND o.claim_expires_at>? AND a.principal_id=o.created_by
                       AND a.intent_sha256=o.intent_sha256 AND a.revoked_at IS NULL
                       AND a.expires_at>?
                       AND NOT EXISTS(
                           SELECT 1 FROM sync_runs s
                            WHERE s.connection_id=o.connection_id
                              AND s.status='paused'
                              AND s.failure_class='rate_limit'
                              AND s.retry_after!=''
                              AND s.retry_after NOT GLOB '*[^0-9]*'
                              AND CAST(s.retry_after AS INTEGER)>?
                       )
                )""",
        (
            started_at,
            claimed.attempt_id,
            claimed.operation_id,
            claimed.claim_token,
            executor_id,
            executor_id,
            started_at,
            started_at,
            started_at,
        ),
    ).rowcount
    if changed != 1:
        raise SocialStoreError("outbound provider boundary is stale or already marked")


def _assert_outcome_fields(
    status: str, provider_remote_id: str | None, failure_class: str | None
) -> None:
    if status == "succeeded":
        if provider_remote_id is None or failure_class is not None:
            raise SocialStoreError("successful outbound receipt requires only a provider ID")
    elif status == "failed":
        if provider_remote_id is not None or failure_class is None:
            raise SocialStoreError("failed outbound receipt requires only a failure class")
    elif failure_class is None:
        raise SocialStoreError("unknown outbound receipt requires a failure class")


def _validated_outcome(outcome: AttemptOutcome) -> AttemptOutcome:
    if outcome.status not in ("succeeded", "failed", "unknown"):
        raise SocialStoreError("invalid outbound terminal status")
    finished_at = now_epoch() if outcome.finished_at is None else outcome.finished_at
    provider_remote_id = outcome.provider_remote_id
    if provider_remote_id is not None:
        provider_remote_id = validate_opaque(provider_remote_id, "provider_remote_id")
    if outcome.failure_class is not None and outcome.failure_class not in FAILURE_CLASSES:
        raise SocialStoreError("invalid outbound failure class")
    retry_after = outcome.retry_after
    if retry_after is not None:
        valid_retry = isinstance(retry_after, int) and not isinstance(retry_after, bool)
        if not valid_retry or retry_after <= finished_at:
            raise SocialStoreError("invalid outbound rate-limit reset")
        if outcome.failure_class != "rate_limit":
            raise SocialStoreError("invalid outbound rate-limit reset")
    _assert_outcome_fields(
        outcome.status, provider_remote_id, outcome.failure_class
    )
    return AttemptOutcome(
        outcome.status,
        provider_remote_id,
        outcome.failure_class,
        finished_at,
        retry_after,
    )


def _provider_started(
    database: sqlite3.Connection,
    claimed: ClaimedOperation,
    executor_id: str,
) -> tuple[bool, int]:
    row = database.execute(
        "SELECT state,claim_token,claimed_by,last_attempt_id,claim_expires_at "
        "FROM outbound_operations WHERE operation_id=?",
        (claimed.operation_id,),
    ).fetchone()
    expected = ("claimed", claimed.claim_token, executor_id, claimed.attempt_id)
    actual = tuple(row)[:4] if row is not None else ()
    if actual != expected:
        raise SocialStoreError("stale outbound executor cannot finalize")
    attempt = database.execute(
        """SELECT provider_started_at FROM outbound_attempts
             WHERE attempt_id=? AND operation_id=? AND claim_token=?
               AND executor_id=? AND status='running'""",
        (
            claimed.attempt_id,
            claimed.operation_id,
            claimed.claim_token,
            executor_id,
        ),
    ).fetchone()
    if attempt is None:
        raise SocialStoreError("outbound attempt is no longer running")
    return attempt["provider_started_at"] is not None, int(row["claim_expires_at"])


def _assert_outcome_boundary(provider_started: bool, outcome: AttemptOutcome) -> None:
    if provider_started and outcome.status == "failed":
        raise SocialStoreError("started provider attempts cannot be retry-safe failures")
    if not provider_started and outcome.status in ("succeeded", "unknown"):
        raise SocialStoreError("provider outcome requires a started provider attempt")


def _expired_claim_outcome(outcome: AttemptOutcome) -> AttemptOutcome:
    failure_class = outcome.failure_class or "executor_lost"
    return AttemptOutcome(
        "unknown",
        provider_remote_id=outcome.provider_remote_id,
        failure_class=failure_class,
        finished_at=outcome.finished_at,
        retry_after=(
            outcome.retry_after if failure_class == "rate_limit" else None
        ),
    )


def _persist_outcome(
    database: sqlite3.Connection,
    claimed: ClaimedOperation,
    executor_id: str,
    outcome: AttemptOutcome,
    provider_started: bool,
) -> None:
    changed = database.execute(
        """UPDATE outbound_attempts
              SET status=?,finished_at=?,provider_remote_id=?,failure_class=?,diagnostics=?
            WHERE attempt_id=? AND operation_id=? AND claim_token=?
              AND executor_id=? AND status='running'""",
        (
            outcome.status,
            outcome.finished_at,
            outcome.provider_remote_id,
            outcome.failure_class,
            canonical_json({"phase": "provider" if provider_started else "pre-provider"}),
            claimed.attempt_id,
            claimed.operation_id,
            claimed.claim_token,
            executor_id,
        ),
    ).rowcount
    if changed != 1:
        raise SocialStoreError("outbound attempt is no longer running")
    database.execute(
        """UPDATE outbound_operations
              SET state=?,claim_expires_at=NULL,updated_at=?
            WHERE operation_id=?""",
        (outcome.status, outcome.finished_at, claimed.operation_id),
    )


def _persist_rate_limit_cooldown(
    database: sqlite3.Connection,
    claimed: ClaimedOperation,
    executor_id: str,
    outcome: AttemptOutcome,
) -> None:
    if outcome.retry_after is None:
        return
    row = database.execute(
        """SELECT o.connection_id,o.action,a.provider_started_at
             FROM outbound_operations o
             JOIN outbound_attempts a ON a.attempt_id=o.last_attempt_id
            WHERE o.operation_id=? AND a.attempt_id=?""",
        (claimed.operation_id, claimed.attempt_id),
    ).fetchone()
    if row is None:
        raise SocialStoreError("outbound rate-limit receipt is unavailable")
    database.execute(
        """INSERT INTO sync_runs(
               run_id,connection_id,status,failure_class,retry_after,stream,run_kind,
               collector_id,started_at,completed_at,diagnostics)
             VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
        (
            _new_id("run"),
            row["connection_id"],
            "paused",
            "rate_limit",
            str(outcome.retry_after),
            row["action"],
            "outbound",
            executor_id,
            row["provider_started_at"] or outcome.finished_at,
            outcome.finished_at,
            canonical_json({"phase": "provider", "reason": "rate_limit"}),
        ),
    )


def _outcome_receipt(
    claimed: ClaimedOperation, outcome: AttemptOutcome
) -> dict[str, Any]:
    result: dict[str, Any] = {
        "operation_id": claimed.operation_id,
        "attempt_id": claimed.attempt_id,
        "state": outcome.status,
    }
    if outcome.provider_remote_id is not None:
        result["provider_remote_id"] = outcome.provider_remote_id
    if outcome.failure_class is not None:
        result["failure_class"] = outcome.failure_class
    if outcome.retry_after is not None:
        result["retry_after"] = outcome.retry_after
    return result


def finalize_operation(
    database: sqlite3.Connection,
    claimed: ClaimedOperation,
    executor_id: str,
    outcome: AttemptOutcome,
) -> dict[str, Any]:
    """Fence and record the provider attempt's privacy-safe terminal outcome."""
    outcome = _validated_outcome(outcome)
    executor_id = validate_opaque(executor_id, "executor_id")
    database.execute("BEGIN IMMEDIATE")
    try:
        provider_started, claim_expires_at = _provider_started(
            database, claimed, executor_id
        )
        if claim_expires_at <= int(outcome.finished_at):
            outcome = _expired_claim_outcome(outcome)
        else:
            _assert_outcome_boundary(provider_started, outcome)
        _persist_outcome(database, claimed, executor_id, outcome, provider_started)
        _persist_rate_limit_cooldown(database, claimed, executor_id, outcome)
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    return _outcome_receipt(claimed, outcome)


def _expire_claim(
    database: sqlite3.Connection, row: sqlite3.Row, current_time: int
) -> str:
    changed = database.execute(
        """UPDATE outbound_attempts
              SET status='unknown',finished_at=?,failure_class='executor_lost',
                  diagnostics=?
            WHERE attempt_id=? AND operation_id=? AND claim_token=?
              AND status='running'""",
        (
            current_time,
            canonical_json({"phase": "executor"}),
            row["last_attempt_id"],
            row["operation_id"],
            row["claim_token"],
        ),
    ).rowcount
    if changed != 1:
        raise SocialStoreError("expired outbound attempt is inconsistent")
    operation_changed = database.execute(
        """UPDATE outbound_operations
              SET state='unknown',claim_expires_at=NULL,updated_at=?
            WHERE operation_id=? AND state='claimed' AND claim_token=?""",
        (current_time, row["operation_id"], row["claim_token"]),
    ).rowcount
    if operation_changed != 1:
        raise SocialStoreError("expired outbound operation is inconsistent")
    return str(row["operation_id"])


def expire_claims(
    database: sqlite3.Connection,
    principal_id: str,
    current_time: int,
    limit: int,
) -> list[str]:
    """Fence expired executors and conservatively make their outcomes unknown."""
    if limit < 1 or limit > 100:
        raise SocialStoreError("claim expiry limit must be between 1 and 100")
    principal_id = validate_opaque(principal_id, "principal_id")
    database.execute("BEGIN IMMEDIATE")
    try:
        rows = database.execute(
            """SELECT operation_id,last_attempt_id,claim_token
                 FROM outbound_operations
                WHERE state='claimed' AND created_by=? AND claim_expires_at<=?
                ORDER BY claim_expires_at,operation_id LIMIT ?""",
            (principal_id, current_time, limit),
        ).fetchall()
        expired = [_expire_claim(database, row, current_time) for row in rows]
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    return expired
