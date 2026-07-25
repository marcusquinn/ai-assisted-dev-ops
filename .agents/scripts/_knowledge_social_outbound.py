#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Approval-bound outbound social operation intent and authorization state."""

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
class OperationIntent:
    """Private immutable values from which one outbound intent is created."""

    connection_id: str
    remote_account_id: str
    action: str
    target_remote_id: str | None
    payload: str | None
    app_profile: str | None
    username: str | None
    scheduled_at: int
    created_by: str
    operation_id: str | None = None
    created_at: int | None = None


@dataclass(frozen=True)
class ApprovalDecision:
    """Normalized approval authority for one exact stored intent."""

    operation_id: str
    principal_id: str
    expires_at: int
    approved_at: int


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
    if not value:
        raise SocialStoreError(f"{field} must be one non-empty line")
    if value.startswith("-"):
        raise SocialStoreError(f"{field} must not be option-shaped")
    if any(marker in value for marker in ("\x00", "\n", "\r")):
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


def _operation_values(intent: OperationIntent, operation_id: str) -> dict[str, Any]:
    if intent.action not in ACTIONS:
        raise SocialStoreError("unsupported outbound action")
    if intent.scheduled_at < 0:
        raise SocialStoreError("scheduled_at must be a non-negative epoch")
    payload = _validated_payload(intent.action, intent.payload)
    return {
        "operation_id": validate_opaque(operation_id, "operation_id"),
        "provider": "xapi",
        "connection_id": validate_opaque(intent.connection_id, "connection_id"),
        "remote_account_id": validate_opaque(
            intent.remote_account_id, "remote_account_id"
        ),
        "action": intent.action,
        "target_remote_id": _validated_target(
            intent.action, intent.target_remote_id
        ),
        "payload": payload,
        "payload_sha256": _digest(payload or ""),
        "app_profile": _optional_selector(intent.app_profile, "app_profile"),
        "username": _optional_selector(intent.username, "username"),
        "scheduled_at": intent.scheduled_at,
        "created_by": validate_opaque(intent.created_by, "created_by"),
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


def _existing_public_operation(
    database: sqlite3.Connection, operation_id: str, intent_sha256: str
) -> dict[str, Any] | None:
    existing = database.execute(
        "SELECT * FROM outbound_operations WHERE operation_id=?", (operation_id,)
    ).fetchone()
    if existing is None:
        return None
    _verify_operation_row(existing)
    if existing["intent_sha256"] != intent_sha256:
        raise SocialStoreError("operation ID is bound to another intent")
    return _public_operation(existing)


def _insert_operation(
    database: sqlite3.Connection, values: dict[str, Any], created_at: int
) -> None:
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


def create_operation(
    database: sqlite3.Connection, intent: OperationIntent
) -> dict[str, Any]:
    """Create or idempotently recover one immutable draft operation."""
    operation_id = intent.operation_id or _new_id("op")
    created_at = now_epoch() if intent.created_at is None else intent.created_at
    values = _operation_values(intent, operation_id)
    values["intent_sha256"] = _intent_sha256(values)
    database.execute("BEGIN IMMEDIATE")
    try:
        _assert_connection(database, values)
        existing = _existing_public_operation(
            database, operation_id, str(values["intent_sha256"])
        )
        if existing is not None:
            database.execute("COMMIT")
            return existing
        _insert_operation(database, values, created_at)
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    return {
        "operation_id": operation_id,
        "action": intent.action,
        "state": "draft",
        "scheduled_at": intent.scheduled_at,
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


def _validated_approval_row(
    database: sqlite3.Connection, decision: ApprovalDecision
) -> sqlite3.Row:
    row = _verified_operation(database, decision.operation_id)
    if row["created_by"] != decision.principal_id:
        raise SocialStoreError("operation approval requires its owner")
    if row["state"] in TERMINAL_STATES or row["state"] == "claimed":
        raise SocialStoreError("operation cannot be approved in its current state")
    return row


def _persist_approval(
    database: sqlite3.Connection,
    row: sqlite3.Row,
    decision: ApprovalDecision,
) -> str:
    database.execute(
        """UPDATE outbound_approvals SET revoked_at=?
            WHERE operation_id=? AND principal_id=? AND revoked_at IS NULL""",
        (decision.approved_at, decision.operation_id, decision.principal_id),
    )
    approval_id = _new_id("apr")
    database.execute(
        """INSERT INTO outbound_approvals(
            approval_id,operation_id,principal_id,intent_sha256,
            approved_at,expires_at,revoked_at)
           VALUES(?,?,?,?,?,?,NULL)""",
        (
            approval_id,
            decision.operation_id,
            decision.principal_id,
            row["intent_sha256"],
            decision.approved_at,
            decision.expires_at,
        ),
    )
    database.execute(
        "UPDATE outbound_operations SET state='approved',updated_at=? WHERE operation_id=?",
        (decision.approved_at, decision.operation_id),
    )
    return approval_id


def approve_operation(
    database: sqlite3.Connection,
    operation_id: str,
    principal_id: str,
    expires_at: int,
    approved_at: int | None = None,
) -> dict[str, Any]:
    """Bind one authenticated owner approval to the exact stored intent."""
    approved_at = now_epoch() if approved_at is None else approved_at
    if expires_at <= approved_at or expires_at - approved_at > MAX_APPROVAL_SECONDS:
        raise SocialStoreError("approval expiry must be within 31 days")
    decision = ApprovalDecision(
        validate_opaque(operation_id, "operation_id"),
        validate_opaque(principal_id, "principal_id"),
        expires_at,
        approved_at,
    )
    database.execute("BEGIN IMMEDIATE")
    try:
        row = _validated_approval_row(database, decision)
        approval_id = _persist_approval(database, row, decision)
        database.execute("COMMIT")
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise
    return {
        "operation_id": decision.operation_id,
        "approval_id": approval_id,
        "state": "approved",
        "expires_at": decision.expires_at,
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
