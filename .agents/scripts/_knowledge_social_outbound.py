#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Approval-bound outbound social operation intent and authorization state."""

from __future__ import annotations

import hashlib
import re
import sqlite3
import time
import uuid
from dataclasses import dataclass
from typing import Any

from _knowledge_social_outbound_validation import (
    MAX_SUBJECT_BYTES,
    optional_selector as _optional_selector,
    validated_destination as _validated_destination,
    validated_media as _validated_media,
    validated_subject as _validated_subject,
    validated_target as _validated_target,
)
from knowledge_social_import import canonical_json
from knowledge_social_store import SocialStoreError, validate_opaque

ACTIONS = ("post", "reply", "like", "bookmark")
OUTBOUND_PROVIDER_ACTIONS = {
    "linkedin": ("post",),
    "meta_facebook": ("post", "reply"),
    "meta_instagram": ("post",),
    "meta_threads": ("post", "reply"),
    "reddit": ACTIONS,
    "tiktok": ("post",),
    "xapi": ACTIONS,
    "youtube": ("post",),
}
TERMINAL_STATES = ("succeeded", "failed", "unknown", "cancelled")
FAILURE_CLASSES = (
    "authorization",
    "executor_lost",
    "identity",
    "provider_unavailable",
    "rate_limit",
    "reconciled_not_sent",
    "runtime",
    "validation",
)
MAX_PAYLOAD_BYTES = 16 * 1024
MAX_APPROVAL_SECONDS = 31 * 24 * 60 * 60
CURRENT_INTENT_VERSION = 3
REDDIT_PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")


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
    destination_remote_id: str | None = None
    subject: str | None = None
    media_path: str | None = None
    media_sha256: str | None = None
    operation_id: str | None = None
    created_at: int | None = None


@dataclass(frozen=True)
class ConnectionValues:
    """Validated connection values used to create an outbound operation."""

    provider: str
    connection_id: str
    remote_account_id: str
    auth_profile_ref: str | None


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
    provider: str
    action: str
    remote_account_id: str
    target_remote_id: str | None
    destination_remote_id: str | None
    payload: str | None
    subject: str | None
    app_profile: str | None
    username: str | None
    claim_token: int
    attempt_id: str
    media_path: str | None = None
    media_sha256: str | None = None


def now_epoch() -> int:
    """Return the current whole-second epoch."""
    return int(time.time())


def _new_id(prefix: str) -> str:
    return f"{prefix}_{uuid.uuid4().hex}"


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


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


def _intent_document(values: dict[str, Any]) -> dict[str, Any]:
    version = int(values["intent_version"])
    document = {
        "version": version,
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
    if version in (2, 3):
        document.update(
            {
                "destination_remote_id": values["destination_remote_id"],
                "subject_sha256": values["subject_sha256"],
            }
        )
    if version == 3:
        document.update(
            {
                "media_path": values["media_path"],
                "media_sha256": values["media_sha256"],
            }
        )
    elif version not in (1, 2):
        raise SocialStoreError("unsupported outbound intent version")
    return document


def _intent_sha256(values: dict[str, Any]) -> str:
    return _digest(canonical_json(_intent_document(values)))


def _verify_operation_row(row: sqlite3.Row) -> sqlite3.Row:
    payload_sha256 = _digest(row["payload"] or "")
    if payload_sha256 != row["payload_sha256"]:
        raise SocialStoreError("outbound operation payload integrity check failed")
    intent_version = int(row["intent_version"])
    if intent_version == 1:
        if any(
            row[field] is not None
            for field in ("destination_remote_id", "subject", "subject_sha256")
        ):
            raise SocialStoreError("legacy outbound operation has unbound provider fields")
    elif intent_version in (2, 3):
        subject_sha256 = _digest(row["subject"] or "")
        if subject_sha256 != row["subject_sha256"]:
            raise SocialStoreError("outbound operation subject integrity check failed")
        if intent_version == 3 and (
            (row["media_path"] is None) != (row["media_sha256"] is None)
            or (
                row["media_sha256"] is not None
                and re.fullmatch(r"[0-9a-f]{64}", str(row["media_sha256"])) is None
            )
        ):
            raise SocialStoreError("outbound operation media integrity check failed")
    else:
        raise SocialStoreError("unsupported outbound intent version")
    values = dict(row)
    values["payload_sha256"] = payload_sha256
    if _intent_sha256(values) != row["intent_sha256"]:
        raise SocialStoreError("outbound operation intent integrity check failed")
    return row


def _connection_values(
    database: sqlite3.Connection, intent: OperationIntent
) -> ConnectionValues:
    connection_id = validate_opaque(intent.connection_id, "connection_id")
    remote_account_id = validate_opaque(intent.remote_account_id, "remote_account_id")
    row = database.execute(
        "SELECT provider,remote_account_id,auth_profile_ref FROM connections "
        "WHERE connection_id=?",
        (connection_id,),
    ).fetchone()
    if row is None:
        raise SocialStoreError("outbound connection is unavailable")
    if row["remote_account_id"] != remote_account_id:
        raise SocialStoreError("outbound connection does not match the account")
    provider = validate_opaque(str(row["provider"]), "provider")
    if provider not in OUTBOUND_PROVIDER_ACTIONS:
        raise SocialStoreError("outbound connection provider is unsupported")
    return ConnectionValues(
        provider=provider,
        connection_id=connection_id,
        remote_account_id=remote_account_id,
        auth_profile_ref=row["auth_profile_ref"],
    )


def _operation_values(
    intent: OperationIntent,
    operation_id: str,
    connection: ConnectionValues,
) -> dict[str, Any]:
    provider = connection.provider
    if intent.action not in OUTBOUND_PROVIDER_ACTIONS[provider]:
        raise SocialStoreError("unsupported outbound action")
    if intent.scheduled_at < 0:
        raise SocialStoreError("scheduled_at must be a non-negative epoch")
    payload = _validated_payload(intent.action, intent.payload)
    profile = (
        intent.app_profile
        if intent.app_profile is not None
        else connection.auth_profile_ref
    )
    app_profile = _optional_selector(profile, "app_profile")
    username = _optional_selector(intent.username, "username")
    if provider == "reddit":
        if app_profile is None:
            raise SocialStoreError("Reddit operations require a named auth profile")
        if REDDIT_PROFILE_NAME.fullmatch(app_profile) is None:
            raise SocialStoreError(
                "Reddit auth profile must be a lowercase environment-safe slug"
            )
        if username is not None:
            raise SocialStoreError("Reddit identity is selected only by its auth profile")
    subject = _validated_subject(provider, intent.action, intent.subject)
    media_path, media_sha256 = _validated_media(
        provider, intent.action, intent.media_path, intent.media_sha256
    )
    return {
        "operation_id": validate_opaque(operation_id, "operation_id"),
        "provider": provider,
        "connection_id": connection.connection_id,
        "remote_account_id": connection.remote_account_id,
        "action": intent.action,
        "target_remote_id": _validated_target(
            provider, intent.action, intent.target_remote_id
        ),
        "destination_remote_id": _validated_destination(
            provider, intent.action, intent.destination_remote_id
        ),
        "payload": payload,
        "payload_sha256": _digest(payload or ""),
        "subject": subject,
        "subject_sha256": _digest(subject or ""),
        "media_path": media_path,
        "media_sha256": media_sha256,
        "intent_version": CURRENT_INTENT_VERSION,
        "app_profile": app_profile,
        "username": username,
        "scheduled_at": intent.scheduled_at,
        "created_by": validate_opaque(intent.created_by, "created_by"),
    }


def _public_operation(row: sqlite3.Row) -> dict[str, Any]:
    return {
        "operation_id": str(row["operation_id"]),
        "provider": str(row["provider"]),
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
            target_remote_id,destination_remote_id,payload,payload_sha256,
            subject,subject_sha256,media_path,media_sha256,intent_version,intent_sha256,app_profile,
            username,scheduled_at,state,created_by,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (
            values["operation_id"],
            values["provider"],
            values["connection_id"],
            values["remote_account_id"],
            values["action"],
            values["target_remote_id"],
            values["destination_remote_id"],
            values["payload"],
            values["payload_sha256"],
            values["subject"],
            values["subject_sha256"],
            values["media_path"],
            values["media_sha256"],
            values["intent_version"],
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
    database.execute("BEGIN IMMEDIATE")
    try:
        connection = _connection_values(database, intent)
        values = _operation_values(intent, operation_id, connection)
        values["intent_sha256"] = _intent_sha256(values)
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
        "provider": str(values["provider"]),
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
