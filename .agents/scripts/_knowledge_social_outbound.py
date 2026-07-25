#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Approval-bound outbound social operation state and receipts."""

from __future__ import annotations

import hashlib
import sqlite3
import time
import uuid
from dataclasses import dataclass
from typing import Any

from knowledge_social_import import canonical_json
from knowledge_social_store import SocialStoreError, validate_opaque

ACTIONS = ("post", "reply", "like", "bookmark")
TERMINAL_STATES = ("succeeded", "failed", "unknown", "cancelled")
FAILURE_CLASSES = (
    "authorization",
    "executor_lost",
    "identity",
    "provider_unavailable",
    "reconciled_not_sent",
    "runtime",
    "validation",
)
MAX_PAYLOAD_BYTES = 16 * 1024
MAX_SELECTOR_BYTES = 256
MAX_APPROVAL_SECONDS = 31 * 24 * 60 * 60


@dataclass(frozen=True)
class ClaimedOperation:
    """Private operation values needed for exactly one provider attempt."""

    operation_id: str
    action: str
    remote_account_id: str
    target_remote_id: str | None
    payload: str | None
    app_profile: str | None
    username: str | None
    claim_token: int
    attempt_id: str


def now_epoch() -> int:
    """Return the current whole-second epoch."""
    return int(time.time())


def _new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex}"


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _optional_selector(value: str | None, field: str) -> str | None:
    if value is None:
        return None
    if (
        not value
        or value.startswith("-")
        or "\x00" in value
        or "\n" in value
        or "\r" in value
    ):
        raise SocialStoreError(f"{field} must be one non-empty line")
    if len(value.encode("utf-8")) > MAX_SELECTOR_BYTES:
        raise SocialStoreError(f"{field} is too long")
    return value


def _validated_payload(action: str, payload: str | None) -> str | None:
    if action in ("post", "reply"):
        if payload is None or not payload.strip() or "\x00" in payload:
            raise SocialStoreError(f"{action} requires a non-empty private body file")
        if len(payload.encode("utf-8")) > MAX_PAYLOAD_BYTES:
            raise SocialStoreError("outbound body exceeds the private payload limit")
        return payload
    if payload is not None:
        raise SocialStoreError(f"{action} does not accept a body")
    return None


def _validated_target(action: str, target: str | None) -> str | None:
    if action == "post":
        if target is not None:
            raise SocialStoreError("post does not accept a target")
        return None
    if target is None:
        raise SocialStoreError(f"{action} requires a target post ID")
    return validate_opaque(target, "target_remote_id")


def _intent_document(values: dict[str, Any]) -> dict[str, Any]:
    return {
        "version": 1,
        "operation_id": values["operation_id"],
        "provider": values["provider"],
        "connection_id": values["connection_id"],
        "remote_account_id": values["remote_account_id"],
        "action": values["action"],
        "target_remote_id": values["target_remote_id"],
        "payload_sha256": values["payload_sha256"],
        "app_profile": values["app_profile"],
        "username": values["username"],
        "scheduled_at": values["scheduled_at"],
        "created_by": values["created_by"],
    }


def _intent_sha256(values: dict[str, Any]) -> str:
    return _digest(canonical_json(_intent_document(values)))


def _verify_operation_row(row: sqlite3.Row) -> sqlite3.Row:
    payload_sha256 = _digest(row["payload"] or "")
    if payload_sha256 != row["payload_sha256"]:
        raise SocialStoreError("outbound operation payload integrity check failed")
    values = dict(row)
    values["payload_sha256"] = payload_sha256
    if _intent_sha256(values) != row["intent_sha256"]:
        raise SocialStoreError("outbound operation intent integrity check failed")
    return row


def _operation_values(
    operation_id: str,
    connection_id: str,
    remote_account_id: str,
    action: str,
    target_remote_id: str | None,
    payload: str | None,
    app_profile: str | None,
    username: str | None,
    scheduled_at: int,
    created_by: str,
) -> dict[str, Any]:
    if action not in ACTIONS:
        raise SocialStoreError("unsupported outbound action")
    if scheduled_at < 0:
        raise SocialStoreError("scheduled_at must be a non-negative epoch")
    payload = _validated_payload(action, payload)
    return {
        "operation_id": validate_opaque(operation_id, "operation_id"),
        "provider": "xapi",
        "connection_id": validate_opaque(connection_id, "connection_id"),
        "remote_account_id": validate_opaque(
            remote_account_id, "remote_account_id"
        ),
        "action": action,
        "target_remote_id": _validated_target(action, target_remote_id),
        "payload": payload,
        "payload_sha256": _digest(payload or ""),
        "app_profile": _optional_selector(app_profile, "app_profile"),
        "username": _optional_selector(username, "username"),
        "scheduled_at": scheduled_at,
        "created_by": validate_opaque(created_by, "created_by"),
    }


def _assert_connection(database: sqlite3.Connection, values: dict[str, Any]) -> None:
    row = database.execute(
        "SELECT provider,remote_account_id FROM connections WHERE connection_id=?",
        (values["connection_id"],),
    ).fetchone()
    if row is None:
        raise SocialStoreError("outbound connection is unavailable")
    if row["provider"] != "xapi" or row["remote_account_id"] != values[
        "remote_account_id"
    ]:
        raise SocialStoreError("outbound connection does not match the X account")


def _public_operation(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "operation_id": str(row["operation_id"]),
        "action": str(row["action"]),
        "state": str(row["state"]),
        "scheduled_at": int(row["scheduled_at"]),
        "updated_at": int(row["updated_at"]),
    }


def create_operation(
    database: sqlite3.Connection,
    *,
    connection_id: str,
    remote_account_id: str,
    action: str,
    target_remote_id: str | None,
    payload: str | None,
    app_profile: str | None,
    username: str | None,
    scheduled_at: int,
    created_by: str,
    operation_id: str | None = None,
    created_at: int | None = None,
) -> dict[str, Any]:
    """Create or idempotently recover one immutable draft operation."""
    operation_id = operation_id or _new_id("op")
    created_at = now_epoch() if created_at is None else created_at
    values = _operation_values(
        operation_id,
        connection_id,
        remote_account_id,
        action,
        target_remote_id,
        payload,
        app_profile,
        username,
        scheduled_at,
        created_by,
    )
    values["intent_sha256"] = _intent_sha256(values)
    database.execute("BEGIN IMMEDIATE")
    try:
        _assert_connection(database, values)
        existing = database.execute(
            "SELECT * FROM outbound_operations WHERE operation_id=?", (operation_id,)
        ).fetchone()
        if existing is not None:
            _verify_operation_row(existing)
            if existing["intent_sha256"] != values["intent_sha256"]:
                raise SocialStoreError("operation ID is bound to another intent")
            database.execute("COMMIT")
            return _public_operation(existing)
        database.execute(
            """INSERT INTO outbound_operations(
                operation_id,provider,connection_id,remote_account_id,action,
                target_remote_id,payload,payload_sha256,intent_sha256,app_profile,
                username,scheduled_at,state,created_by,created_at,updated_at)
               VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
            (
                values["operation_id"],
                values["provider"],
                values["connection_id"],
                values["remote_account_id"],
                values["action"],
                values["target_remote_id"],
                values["payload"],
                values["payload_sha256"],
                values["intent_sha256"],
                values["app_profile"],
                values["username"],
                values["scheduled_at"],
                "draft",
                values["created_by"],
                created_at,
                created_at,
            ),
        )
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    return {
        "operation_id": operation_id,
        "action": action,
        "state": "draft",
        "scheduled_at": scheduled_at,
        "updated_at": created_at,
    }


def _verified_operation(database: sqlite3.Connection, operation_id: str) -> sqlite3.Row:
    row = database.execute(
        "SELECT * FROM outbound_operations WHERE operation_id=?",
        (validate_opaque(operation_id, "operation_id"),),
    ).fetchone()
    if row is None:
        raise SocialStoreError("outbound operation is unavailable")
    return _verify_operation_row(row)


def approve_operation(
    database: sqlite3.Connection,
    operation_id: str,
    principal_id: str,
    expires_at: int,
    *,
    approved_at: int | None = None,
) -> dict[str, Any]:
    """Bind one authenticated owner approval to the exact stored intent."""
    approved_at = now_epoch() if approved_at is None else approved_at
    if expires_at <= approved_at or expires_at - approved_at > MAX_APPROVAL_SECONDS:
        raise SocialStoreError("approval expiry must be within 31 days")
    principal_id = validate_opaque(principal_id, "principal_id")
    database.execute("BEGIN IMMEDIATE")
    try:
        row = _verified_operation(database, operation_id)
        if row["created_by"] != principal_id:
            raise SocialStoreError("operation approval requires its owner")
        if row["state"] in TERMINAL_STATES or row["state"] == "claimed":
            raise SocialStoreError("operation cannot be approved in its current state")
        database.execute(
            """UPDATE outbound_approvals SET revoked_at=?
                WHERE operation_id=? AND principal_id=? AND revoked_at IS NULL""",
            (approved_at, operation_id, principal_id),
        )
        approval_id = _new_id("apr")
        database.execute(
            """INSERT INTO outbound_approvals(
                approval_id,operation_id,principal_id,intent_sha256,
                approved_at,expires_at,revoked_at)
               VALUES(?,?,?,?,?,?,NULL)""",
            (
                approval_id,
                operation_id,
                principal_id,
                row["intent_sha256"],
                approved_at,
                expires_at,
            ),
        )
        database.execute(
            "UPDATE outbound_operations SET state='approved',updated_at=? WHERE operation_id=?",
            (approved_at, operation_id),
        )
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    return {
        "operation_id": operation_id,
        "approval_id": approval_id,
        "state": "approved",
        "expires_at": expires_at,
    }


def revoke_approval(
    database: sqlite3.Connection,
    operation_id: str,
    principal_id: str,
    *,
    revoked_at: int | None = None,
) -> dict[str, Any]:
    """Revoke every active approval before an operation is claimed."""
    revoked_at = now_epoch() if revoked_at is None else revoked_at
    principal_id = validate_opaque(principal_id, "principal_id")
    database.execute("BEGIN IMMEDIATE")
    try:
        row = _verified_operation(database, operation_id)
        if row["created_by"] != principal_id or row["state"] == "claimed":
            raise SocialStoreError("operation approval cannot be revoked")
        if row["state"] in TERMINAL_STATES:
            raise SocialStoreError("terminal operation approval cannot be revoked")
        changed = database.execute(
            """UPDATE outbound_approvals SET revoked_at=?
                WHERE operation_id=? AND principal_id=? AND revoked_at IS NULL""",
            (revoked_at, operation_id, principal_id),
        ).rowcount
        if changed == 0:
            raise SocialStoreError("operation has no active approval")
        database.execute(
            "UPDATE outbound_operations SET state='draft',updated_at=? WHERE operation_id=?",
            (revoked_at, operation_id),
        )
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    return {"operation_id": operation_id, "state": "draft", "revoked": changed}


def cancel_operation(
    database: sqlite3.Connection,
    operation_id: str,
    principal_id: str,
    *,
    cancelled_at: int | None = None,
) -> dict[str, Any]:
    """Cancel a draft or approved operation before any provider attempt."""
    cancelled_at = now_epoch() if cancelled_at is None else cancelled_at
    principal_id = validate_opaque(principal_id, "principal_id")
    database.execute("BEGIN IMMEDIATE")
    try:
        row = _verified_operation(database, operation_id)
        if row["created_by"] != principal_id or row["state"] not in (
            "draft",
            "approved",
        ):
            raise SocialStoreError("operation cannot be cancelled")
        database.execute(
            "UPDATE outbound_approvals SET revoked_at=? "
            "WHERE operation_id=? AND revoked_at IS NULL",
            (cancelled_at, operation_id),
        )
        database.execute(
            """UPDATE outbound_operations
                  SET state='cancelled',updated_at=? WHERE operation_id=?""",
            (cancelled_at, operation_id),
        )
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    return {"operation_id": operation_id, "state": "cancelled"}


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
             ORDER BY o.scheduled_at,o.operation_id LIMIT ?""",
        (current_time, principal_id, principal_id, current_time, limit),
    ).fetchall()
    return [str(_verify_operation_row(row)["operation_id"]) for row in rows]


def claim_operation(
    database: sqlite3.Connection,
    operation_id: str,
    principal_id: str,
    executor_id: str,
    current_time: int,
    claim_seconds: int,
) -> ClaimedOperation:
    """Atomically claim one due operation and persist its sole running attempt."""
    if claim_seconds < 1 or claim_seconds > 3600:
        raise SocialStoreError("claim_seconds must be between 1 and 3600")
    principal_id = validate_opaque(principal_id, "principal_id")
    executor_id = validate_opaque(executor_id, "executor_id")
    database.execute("BEGIN IMMEDIATE")
    try:
        row = _verified_operation(database, operation_id)
        if (
            row["state"] != "approved"
            or int(row["scheduled_at"]) > current_time
            or row["created_by"] != principal_id
        ):
            raise SocialStoreError("operation is not due and approved")
        approval = database.execute(
            """SELECT approval_id FROM outbound_approvals
                WHERE operation_id=? AND principal_id=? AND intent_sha256=?
                  AND revoked_at IS NULL AND expires_at>?
                ORDER BY approved_at DESC LIMIT 1""",
            (operation_id, principal_id, row["intent_sha256"], current_time),
        ).fetchone()
        if approval is None:
            raise SocialStoreError("operation approval is missing or expired")
        claim_token = int(row["claim_token"]) + 1
        attempt_id = _new_id("att")
        changed = database.execute(
            """UPDATE outbound_operations
                  SET state='claimed',claim_token=?,claimed_by=?,claim_expires_at=?,
                      last_attempt_id=?,updated_at=?
                WHERE operation_id=? AND state='approved'""",
            (
                claim_token,
                executor_id,
                current_time + claim_seconds,
                attempt_id,
                current_time,
                operation_id,
            ),
        ).rowcount
        if changed != 1:
            raise SocialStoreError("operation claim lost a concurrent race")
        database.execute(
            """INSERT INTO outbound_attempts(
                attempt_id,operation_id,claim_token,executor_id,status,started_at)
               VALUES(?,?,?,?,?,?)""",
            (attempt_id, operation_id, claim_token, executor_id, "running", current_time),
        )
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    return ClaimedOperation(
        operation_id,
        str(row["action"]),
        str(row["remote_account_id"]),
        row["target_remote_id"],
        row["payload"],
        row["app_profile"],
        row["username"],
        claim_token,
        attempt_id,
    )


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
        ),
    ).rowcount
    if changed != 1:
        raise SocialStoreError("outbound provider boundary is stale or already marked")


def finalize_operation(
    database: sqlite3.Connection,
    claimed: ClaimedOperation,
    executor_id: str,
    status: str,
    *,
    provider_remote_id: str | None = None,
    failure_class: str | None = None,
    finished_at: int | None = None,
) -> dict[str, Any]:
    """Fence and record the provider attempt's privacy-safe terminal outcome."""
    if status not in ("succeeded", "failed", "unknown"):
        raise SocialStoreError("invalid outbound terminal status")
    finished_at = now_epoch() if finished_at is None else finished_at
    if provider_remote_id is not None:
        provider_remote_id = validate_opaque(provider_remote_id, "provider_remote_id")
    if failure_class is not None and failure_class not in FAILURE_CLASSES:
        raise SocialStoreError("invalid outbound failure class")
    if status == "succeeded" and (
        provider_remote_id is None or failure_class is not None
    ):
        raise SocialStoreError("successful outbound receipt requires only a provider ID")
    if status != "succeeded" and (
        provider_remote_id is not None or failure_class is None
    ):
        raise SocialStoreError("unsuccessful outbound receipt requires only a failure class")
    executor_id = validate_opaque(executor_id, "executor_id")
    database.execute("BEGIN IMMEDIATE")
    try:
        row = database.execute(
            "SELECT state,claim_token,claimed_by,last_attempt_id FROM outbound_operations "
            "WHERE operation_id=?",
            (claimed.operation_id,),
        ).fetchone()
        expected = (
            "claimed",
            claimed.claim_token,
            executor_id,
            claimed.attempt_id,
        )
        actual = tuple(row) if row is not None else ()
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
        provider_started = attempt["provider_started_at"] is not None
        if provider_started and status == "failed":
            raise SocialStoreError("started provider attempts cannot be retry-safe failures")
        if not provider_started and status in ("succeeded", "unknown"):
            raise SocialStoreError("provider outcome requires a started provider attempt")
        changed = database.execute(
            """UPDATE outbound_attempts
                  SET status=?,finished_at=?,provider_remote_id=?,failure_class=?,diagnostics=?
                WHERE attempt_id=? AND operation_id=? AND claim_token=? AND status='running'""",
            (
                status,
                finished_at,
                provider_remote_id,
                failure_class,
                canonical_json({"phase": "provider" if provider_started else "pre-provider"}),
                claimed.attempt_id,
                claimed.operation_id,
                claimed.claim_token,
            ),
        ).rowcount
        if changed != 1:
            raise SocialStoreError("outbound attempt is no longer running")
        database.execute(
            """UPDATE outbound_operations
                  SET state=?,claim_expires_at=NULL,updated_at=?
                WHERE operation_id=?""",
            (status, finished_at, claimed.operation_id),
        )
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    result: dict[str, Any] = {
        "operation_id": claimed.operation_id,
        "attempt_id": claimed.attempt_id,
        "state": status,
    }
    if provider_remote_id is not None:
        result["provider_remote_id"] = provider_remote_id
    if failure_class is not None:
        result["failure_class"] = failure_class
    return result


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
        expired: list[str] = []
        for row in rows:
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
            expired.append(str(row["operation_id"]))
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    return expired


def reconcile_unknown(
    database: sqlite3.Connection,
    operation_id: str,
    principal_id: str,
    outcome: str,
    provider_remote_id: str | None,
    *,
    reconciled_at: int | None = None,
) -> dict[str, Any]:
    """Resolve an ambiguous attempt without ever placing it back in the queue."""
    if outcome not in ("succeeded", "not-sent"):
        raise SocialStoreError("reconciliation outcome must be succeeded or not-sent")
    reconciled_at = now_epoch() if reconciled_at is None else reconciled_at
    principal_id = validate_opaque(principal_id, "principal_id")
    state = "succeeded" if outcome == "succeeded" else "failed"
    if state == "succeeded" and provider_remote_id is None:
        raise SocialStoreError("successful reconciliation requires a provider ID")
    if state == "failed" and provider_remote_id is not None:
        raise SocialStoreError("not-sent reconciliation forbids a provider ID")
    if provider_remote_id is not None:
        provider_remote_id = validate_opaque(provider_remote_id, "provider_remote_id")
    database.execute("BEGIN IMMEDIATE")
    try:
        row = _verified_operation(database, operation_id)
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
                canonical_json({"reconciled": outcome}),
                row["last_attempt_id"],
                operation_id,
                row["claim_token"],
            ),
        ).rowcount
        if changed != 1:
            raise SocialStoreError("unknown outbound receipt is inconsistent")
        database.execute(
            "UPDATE outbound_operations SET state=?,updated_at=? WHERE operation_id=?",
            (state, reconciled_at, operation_id),
        )
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    result = {"operation_id": operation_id, "state": state}
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
