#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Sequence, recipient, and revocation state for social workspace sharing."""

from __future__ import annotations

from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator

from _knowledge_social_share_catalog import (
    WorkspaceState,
    _open_mutable,
    _require_capability,
    _require_owner,
    _state,
    _state_row,
)
from _knowledge_social_share_crypto import (
    PrivateIdentity,
    PublicIdentity,
    ShareError,
    b64d,
    b64e,
    validate_opaque,
)


@contextmanager
def authorized_export(
    base: Path, alias: str, owner: PrivateIdentity
) -> Iterator[tuple[WorkspaceState, list[PublicIdentity]]]:
    resolved, principal_id, connection = _open_mutable(base)
    try:
        connection.execute("BEGIN IMMEDIATE")
        state = _state(resolved, _state_row(connection, alias))
        _require_owner(state, owner, principal_id)
        _require_capability(connection, state, principal_id, "knowledge.manage")
        rows = connection.execute(
            """SELECT DISTINCT d.principal_id,d.device_id,d.signing_public_key,
                               d.encryption_public_key
                 FROM workspace_device_grants wd
                 JOIN principal_devices d ON d.device_id=wd.device_id
                    AND d.principal_id=wd.principal_id
                 JOIN principals p ON p.principal_id=wd.principal_id
                 JOIN workspace_memberships m ON m.workspace_id=wd.workspace_id
                    AND m.principal_id=wd.principal_id
                 JOIN corpus_grants g ON g.principal_id=wd.principal_id
                WHERE wd.workspace_id=? AND g.corpus_id=?
                  AND p.status='active' AND d.status='active' AND wd.status='active'
                  AND m.status='active' AND g.capability='knowledge.read'
                  AND g.scope='corpus' AND g.status='active'
                ORDER BY d.principal_id,d.device_id""",
            (state.workspace_id, state.corpus_id),
        ).fetchall()
        recipients = [
            PublicIdentity(
                str(row["principal_id"]),
                str(row["device_id"]),
                b64d(str(row["signing_public_key"]), "signing public key", 32),
                b64d(str(row["encryption_public_key"]), "encryption public key", 32),
            )
            for row in rows
        ]
        if not recipients:
            raise ShareError("SOCIAL_SHARE_NO_RECIPIENTS", "no active workspace recipients", 5)
        reserved = WorkspaceState(
            state.alias,
            state.root,
            state.workspace_id,
            state.corpus_id,
            state.owner_principal_id,
            state.owner_device_id,
            state.key_generation,
            state.export_sequence + 1,
            state.import_sequence,
        )
        yield reserved, recipients
        connection.execute(
            "UPDATE workspace_share_state SET export_sequence=export_sequence+1 "
            "WHERE workspace_id=?",
            (state.workspace_id,),
        )
        connection.execute("COMMIT")
    except Exception:
        if connection.in_transaction:
            connection.execute("ROLLBACK")
        raise
    finally:
        connection.close()


@contextmanager
def authorized_import(
    base: Path,
    alias: str,
    sender: PublicIdentity,
    recipient: PrivateIdentity,
    header: dict[str, Any],
) -> Iterator[WorkspaceState]:
    resolved, principal_id, connection = _open_mutable(base)
    try:
        connection.execute("BEGIN IMMEDIATE")
        state = _state(resolved, _state_row(connection, alias))
        _require_capability(connection, state, principal_id, "knowledge.read")
        if recipient.public.principal_id != principal_id:
            raise ShareError("SOCIAL_SHARE_ACCESS_DENIED", "sharing recipient is not authenticated", 5)
        recipient_grant = connection.execute(
            """SELECT 1 FROM workspace_device_grants wd
                 JOIN principal_devices d ON d.device_id=wd.device_id
                    AND d.principal_id=wd.principal_id
                WHERE wd.workspace_id=? AND wd.principal_id=? AND wd.device_id=?
                  AND wd.status='active' AND d.status='active'
                  AND d.signing_public_key=? AND d.encryption_public_key=?""",
            (
                state.workspace_id,
                principal_id,
                recipient.public.device_id,
                b64e(recipient.public.signing_public_key),
                b64e(recipient.public.encryption_public_key),
            ),
        ).fetchone()
        trusted = connection.execute(
            """SELECT d.signing_public_key FROM workspace_device_grants wd
                 JOIN principal_devices d ON d.device_id=wd.device_id
                    AND d.principal_id=wd.principal_id
                 JOIN principals p ON p.principal_id=wd.principal_id
                 JOIN workspace_memberships m ON m.workspace_id=wd.workspace_id
                    AND m.principal_id=wd.principal_id
                 JOIN corpus_grants g ON g.corpus_id=?
                    AND g.principal_id=wd.principal_id
                WHERE wd.workspace_id=? AND d.principal_id=? AND d.device_id=?
                  AND p.status='active' AND d.status='active' AND wd.status='active'
                  AND m.status='active' AND g.capability='knowledge.read'
                  AND g.scope='corpus' AND g.status='active'""",
            (state.corpus_id, state.workspace_id, sender.principal_id, sender.device_id),
        ).fetchone()
        if recipient_grant is None:
            raise ShareError("SOCIAL_SHARE_ACCESS_DENIED", "sharing device grant is inactive", 5)
        if (
            sender.principal_id != state.owner_principal_id
            or sender.device_id != state.owner_device_id
            or trusted is None
            or str(trusted["signing_public_key"]) != b64e(sender.signing_public_key)
        ):
            raise ShareError("SOCIAL_SHARE_SENDER_MISMATCH", "workspace sender is not trusted", 4)
        if (
            header.get("workspace_id") != state.workspace_id
            or header.get("corpus_id") != state.corpus_id
        ):
            raise ShareError("SOCIAL_SHARE_ACCESS_DENIED", "sharing batch targets another workspace", 5)
        generation = int(header["key_generation"])
        sequence = int(header["batch_sequence"])
        if generation != state.key_generation:
            raise ShareError(
                "SOCIAL_SHARE_ROLLBACK",
                "sharing key generation is stale or has unapplied grant state",
                4,
            )
        if sequence <= state.import_sequence:
            raise ShareError("SOCIAL_SHARE_ROLLBACK", "sharing batch is stale or replayed", 4)
        yield state
        connection.execute(
            "UPDATE workspace_share_state SET import_sequence=? WHERE workspace_id=?",
            (sequence, state.workspace_id),
        )
        connection.execute(
            "INSERT INTO workspace_share_events(event_id,workspace_id,corpus_id,event_kind,"
            "principal_id,key_generation,sequence,created_at) VALUES(?,?,?,'import',?,?,?,?)",
            (
                str(header["distribution_id"]),
                state.workspace_id,
                state.corpus_id,
                principal_id,
                generation,
                sequence,
                int(header["created_at"]),
            ),
        )
        connection.execute("COMMIT")
    except Exception:
        if connection.in_transaction:
            connection.execute("ROLLBACK")
        raise
    finally:
        connection.close()


@contextmanager
def authorized_revocation(
    base: Path, alias: str, owner: PrivateIdentity, revoked_principal_id: str
) -> Iterator[tuple[WorkspaceState, list[str]]]:
    revoked_principal_id = validate_opaque(revoked_principal_id, "principal_id")
    resolved, principal_id, connection = _open_mutable(base)
    try:
        connection.execute("BEGIN IMMEDIATE")
        state = _state(resolved, _state_row(connection, alias))
        _require_owner(state, owner, principal_id)
        _require_capability(connection, state, principal_id, "knowledge.manage")
        if revoked_principal_id == state.owner_principal_id:
            raise ShareError("SOCIAL_SHARE_INVALID", "workspace owner cannot self-revoke", 3)
        membership = connection.execute(
            "SELECT status FROM workspace_memberships WHERE workspace_id=? AND principal_id=?",
            (state.workspace_id, revoked_principal_id),
        ).fetchone()
        if membership is None or str(membership["status"]) != "active":
            raise ShareError("SOCIAL_SHARE_ACCESS_DENIED", "workspace member is not active", 5)
        devices = [
            str(row["device_id"])
            for row in connection.execute(
                "SELECT device_id FROM workspace_device_grants WHERE workspace_id=? "
                "AND principal_id=? AND status='active' ORDER BY device_id",
                (state.workspace_id, revoked_principal_id),
            ).fetchall()
        ]
        if not devices:
            raise ShareError("SOCIAL_SHARE_ACCESS_DENIED", "workspace member has no active devices", 5)
        connection.execute(
            "UPDATE workspace_memberships SET status='inactive' WHERE workspace_id=? "
            "AND principal_id=?",
            (state.workspace_id, revoked_principal_id),
        )
        connection.execute(
            "UPDATE corpus_grants SET status='inactive' WHERE corpus_id=? AND principal_id=?",
            (state.corpus_id, revoked_principal_id),
        )
        connection.execute(
            "UPDATE workspace_device_grants SET status='revoked' WHERE workspace_id=? "
            "AND principal_id=?",
            (state.workspace_id, revoked_principal_id),
        )
        connection.execute(
            "UPDATE workspace_share_state SET key_generation=key_generation+1 "
            "WHERE workspace_id=?",
            (state.workspace_id,),
        )
        rotated = WorkspaceState(
            state.alias,
            state.root,
            state.workspace_id,
            state.corpus_id,
            state.owner_principal_id,
            state.owner_device_id,
            state.key_generation + 1,
            state.export_sequence,
            state.import_sequence,
        )
        yield rotated, devices
        connection.execute("COMMIT")
    except Exception:
        if connection.in_transaction:
            connection.execute("ROLLBACK")
        raise
    finally:
        connection.close()


def _require_revocation_sender(
    state: WorkspaceState,
    sender: PublicIdentity,
    record: dict[str, Any],
    trusted: Any,
) -> None:
    if sender.principal_id != state.owner_principal_id:
        raise ShareError("SOCIAL_SHARE_SENDER_MISMATCH", "revocation is not from workspace owner", 4)
    if sender.device_id != state.owner_device_id:
        raise ShareError("SOCIAL_SHARE_SENDER_MISMATCH", "revocation is not from workspace owner", 4)
    if record.get("workspace_id") != state.workspace_id:
        raise ShareError("SOCIAL_SHARE_SENDER_MISMATCH", "revocation is not from workspace owner", 4)
    if record.get("corpus_id") != state.corpus_id:
        raise ShareError("SOCIAL_SHARE_SENDER_MISMATCH", "revocation is not from workspace owner", 4)
    if trusted is None:
        raise ShareError("SOCIAL_SHARE_SENDER_MISMATCH", "revocation is not from workspace owner", 4)
    if str(trusted["signing_public_key"]) != b64e(sender.signing_public_key):
        raise ShareError("SOCIAL_SHARE_SENDER_MISMATCH", "revocation is not from workspace owner", 4)


def _same_revocation_event(
    existing: Any, state: WorkspaceState, revoked: str, generation: int
) -> bool:
    if str(existing["workspace_id"]) != state.workspace_id:
        return False
    if str(existing["corpus_id"]) != state.corpus_id:
        return False
    if str(existing["event_kind"]) != "revocation":
        return False
    if str(existing["principal_id"]) != revoked:
        return False
    return int(existing["key_generation"]) == generation


def apply_revocation(
    base: Path, alias: str, sender: PublicIdentity, record: dict[str, Any]
) -> WorkspaceState:
    resolved, _, connection = _open_mutable(base)
    try:
        connection.execute("BEGIN IMMEDIATE")
        state = _state(resolved, _state_row(connection, alias))
        event_id = str(record["event_id"])
        revoked = validate_opaque(record.get("revoked_principal_id"), "principal_id")
        generation = int(record["key_generation"])
        trusted = connection.execute(
            """SELECT d.signing_public_key FROM workspace_device_grants wd
                 JOIN principal_devices d ON d.device_id=wd.device_id
                    AND d.principal_id=wd.principal_id
                WHERE wd.workspace_id=? AND d.principal_id=? AND d.device_id=?
                  AND d.status='active' AND wd.status='active'""",
            (state.workspace_id, sender.principal_id, sender.device_id),
        ).fetchone()
        _require_revocation_sender(state, sender, record, trusted)
        existing = connection.execute(
            "SELECT workspace_id,corpus_id,event_kind,principal_id,key_generation "
            "FROM workspace_share_events WHERE event_id=?",
            (event_id,),
        ).fetchone()
        if existing is not None:
            if not _same_revocation_event(existing, state, revoked, generation):
                raise ShareError("SOCIAL_SHARE_CONFLICT", "sharing event id conflicts with catalog", 4)
            connection.execute("COMMIT")
            return state
        if generation != state.key_generation + 1:
            raise ShareError(
                "SOCIAL_SHARE_ROLLBACK",
                "revocation generation is not the next signed state",
                4,
            )
        connection.execute(
            "UPDATE workspace_memberships SET status='inactive' WHERE workspace_id=? "
            "AND principal_id=?",
            (state.workspace_id, revoked),
        )
        connection.execute(
            "UPDATE corpus_grants SET status='inactive' WHERE corpus_id=? AND principal_id=?",
            (state.corpus_id, revoked),
        )
        connection.execute(
            "UPDATE workspace_device_grants SET status='revoked' WHERE workspace_id=? "
            "AND principal_id=?",
            (state.workspace_id, revoked),
        )
        connection.execute(
            "UPDATE workspace_share_state SET key_generation=? WHERE workspace_id=?",
            (generation, state.workspace_id),
        )
        connection.execute(
            "INSERT INTO workspace_share_events(event_id,workspace_id,corpus_id,event_kind,"
            "principal_id,key_generation,created_at) VALUES(?,?,?,'revocation',?,?,?)",
            (
                event_id,
                state.workspace_id,
                state.corpus_id,
                revoked,
                generation,
                int(record["created_at"]),
            ),
        )
        connection.execute("COMMIT")
        return WorkspaceState(
            state.alias,
            state.root,
            state.workspace_id,
            state.corpus_id,
            state.owner_principal_id,
            state.owner_device_id,
            generation,
            state.export_sequence,
            state.import_sequence,
        )
    except Exception:
        if connection.in_transaction:
            connection.execute("ROLLBACK")
        raise
    finally:
        connection.close()
