#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Issue and accept signed social workspace membership grants."""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterator

from _knowledge_social_share_catalog import (
    WorkspaceState,
    _open_mutable,
    _require_capability,
    _require_owner,
    _state,
    _state_row,
    _upsert_device,
    _upsert_principal,
    validate_alias,
)
from _knowledge_social_share_crypto import (
    PrivateIdentity,
    PublicIdentity,
    ShareError,
    validate_opaque,
)
from _knowledge_social_share_envelope import WorkspaceScope, create_grant_envelope
from knowledge_corpus_catalog import CAPABILITIES
from knowledge_corpus_context import prepare_private_directory

MEMBER_CAPABILITIES = {"knowledge.read", "knowledge.write"}


@dataclass(frozen=True)
class _GrantGraphContext:
    alias: str
    root: Path
    owner: PublicIdentity
    recipient: PrivateIdentity


@contextmanager
def authorized_grant(
    base: Path,
    alias: str,
    owner: PrivateIdentity,
    recipient: PublicIdentity,
    capabilities: list[str],
) -> Iterator[tuple[WorkspaceState, dict[str, Any]]]:
    if recipient.principal_id == owner.public.principal_id:
        raise ShareError("SOCIAL_SHARE_INVALID", "owner cannot be added as a member", 3)
    normalized = sorted(set(capabilities))
    if not normalized or any(item not in MEMBER_CAPABILITIES for item in normalized):
        raise ShareError("SOCIAL_SHARE_INVALID", "member capabilities are invalid", 3)
    resolved, principal_id, connection = _open_mutable(base)
    try:
        connection.execute("BEGIN IMMEDIATE")
        state = _state(resolved, _state_row(connection, alias))
        _require_owner(state, owner, principal_id)
        _require_capability(connection, state, principal_id, "knowledge.manage")
        envelope = create_grant_envelope(
            owner,
            recipient,
            WorkspaceScope(state.workspace_id, state.corpus_id, state.key_generation),
            normalized,
        )
        record = envelope["record"]
        _upsert_principal(connection, recipient.principal_id)
        _upsert_device(connection, recipient)
        connection.execute(
            "INSERT INTO workspace_memberships(workspace_id,principal_id,role,status) "
            "VALUES(?,?,'member','active') ON CONFLICT(workspace_id,principal_id) "
            "DO UPDATE SET role='member',status='active'",
            (state.workspace_id, recipient.principal_id),
        )
        for capability in normalized:
            connection.execute(
                "INSERT INTO corpus_grants(corpus_id,principal_id,role,capability,scope,status) "
                "VALUES(?,?,'member',?,'corpus','active') ON CONFLICT"
                "(corpus_id,principal_id,capability,scope) DO UPDATE SET status='active'",
                (state.corpus_id, recipient.principal_id, capability),
            )
        connection.execute(
            "INSERT INTO workspace_device_grants(workspace_id,principal_id,device_id,status) "
            "VALUES(?,?,?,'active') ON CONFLICT(workspace_id,principal_id,device_id) "
            "DO UPDATE SET status='active'",
            (state.workspace_id, recipient.principal_id, recipient.device_id),
        )
        connection.execute(
            "INSERT INTO workspace_share_events(event_id,workspace_id,corpus_id,"
            "event_kind,principal_id,key_generation,created_at) VALUES(?,?,?,'grant',?,?,?)",
            (
                str(record["grant_id"]),
                state.workspace_id,
                state.corpus_id,
                recipient.principal_id,
                state.key_generation,
                int(record["created_at"]),
            ),
        )
        yield state, envelope
        connection.execute("COMMIT")
    except Exception:
        if connection.in_transaction:
            connection.execute("ROLLBACK")
        raise
    finally:
        connection.close()


def _insert_grant_graph(
    connection: Any,
    record: dict[str, Any],
    context: _GrantGraphContext,
) -> None:
    owner = context.owner
    recipient = context.recipient
    workspace_id = str(record["workspace_id"])
    corpus_id = str(record["corpus_id"])
    _upsert_principal(connection, owner.principal_id)
    _upsert_principal(connection, recipient.public.principal_id)
    _upsert_device(connection, owner)
    _upsert_device(connection, recipient.public)
    existing_workspace = connection.execute(
        "SELECT kind FROM workspaces WHERE workspace_id=?", (workspace_id,)
    ).fetchone()
    if existing_workspace is not None and str(existing_workspace["kind"]) != "workspace":
        raise ShareError("SOCIAL_SHARE_CONFLICT", "workspace id conflicts with catalog", 4)
    connection.execute(
        "INSERT OR IGNORE INTO workspaces(workspace_id,kind,status) VALUES(?,'workspace','active')",
        (workspace_id,),
    )
    for principal, role in (
        (owner.principal_id, "owner"),
        (recipient.public.principal_id, "member"),
    ):
        connection.execute(
            "INSERT INTO workspace_memberships(workspace_id,principal_id,role,status) "
            "VALUES(?,?,?,'active') ON CONFLICT(workspace_id,principal_id) "
            "DO UPDATE SET role=excluded.role,status='active'",
            (workspace_id, principal, role),
        )
    existing_corpus = connection.execute(
        "SELECT workspace_id,location_ref FROM corpora WHERE corpus_id=?", (corpus_id,)
    ).fetchone()
    if existing_corpus is not None and (
        str(existing_corpus["workspace_id"]) != workspace_id
        or str(existing_corpus["location_ref"]) != str(context.root)
    ):
        raise ShareError("SOCIAL_SHARE_CONFLICT", "corpus id conflicts with catalog", 4)
    connection.execute(
        "INSERT OR IGNORE INTO corpora(corpus_id,workspace_id,location_ref,sensitivity,status) "
        "VALUES(?,?,?,'internal','active')",
        (corpus_id, workspace_id, str(context.root)),
    )
    connection.execute(
        "INSERT OR IGNORE INTO corpus_aliases(alias,corpus_id) VALUES(?,?)",
        (context.alias, corpus_id),
    )
    for capability in CAPABILITIES:
        connection.execute(
            "INSERT OR IGNORE INTO corpus_grants(corpus_id,principal_id,role,capability,scope,status) "
            "VALUES(?,?,'owner',?,'corpus','active')",
            (corpus_id, owner.principal_id, capability),
        )
    for capability in record["capabilities"]:
        connection.execute(
            "INSERT INTO corpus_grants(corpus_id,principal_id,role,capability,scope,status) "
            "VALUES(?,?,'member',?,'corpus','active') ON CONFLICT"
            "(corpus_id,principal_id,capability,scope) DO UPDATE SET status='active'",
            (corpus_id, recipient.public.principal_id, capability),
        )
    for identity in (owner, recipient.public):
        connection.execute(
            "INSERT INTO workspace_device_grants(workspace_id,principal_id,device_id,status) "
            "VALUES(?,?,?,'active') ON CONFLICT(workspace_id,principal_id,device_id) "
            "DO UPDATE SET status='active'",
            (workspace_id, identity.principal_id, identity.device_id),
        )


def accept_grant(
    base: Path,
    alias: str,
    owner: PublicIdentity,
    recipient: PrivateIdentity,
    record: dict[str, Any],
) -> WorkspaceState:
    validate_alias(alias)
    resolved, principal_id, connection = _open_mutable(base)
    if recipient.public.principal_id != principal_id:
        connection.close()
        raise ShareError("SOCIAL_SHARE_ACCESS_DENIED", "grant recipient is not authenticated", 5)
    workspace_id = validate_opaque(record.get("workspace_id"), "workspace_id")
    corpus_id = validate_opaque(record.get("corpus_id"), "corpus_id")
    root = prepare_private_directory(resolved / "_workspaces", "shared workspace root")
    root = prepare_private_directory(root / workspace_id, "shared workspace directory")
    root = prepare_private_directory(root / corpus_id, "shared corpus directory")
    try:
        connection.execute("BEGIN IMMEDIATE")
        alias_row = connection.execute(
            "SELECT corpus_id FROM corpus_aliases WHERE alias=?", (alias,)
        ).fetchone()
        if alias_row is not None and str(alias_row["corpus_id"]) != corpus_id:
            raise ShareError("SOCIAL_SHARE_CONFLICT", "shared workspace alias conflicts", 4)
        _insert_grant_graph(
            connection,
            record,
            _GrantGraphContext(alias, root, owner, recipient),
        )
        existing = connection.execute(
            "SELECT owner_principal_id,owner_device_id,key_generation FROM workspace_share_state "
            "WHERE workspace_id=?",
            (workspace_id,),
        ).fetchone()
        if existing is not None and (
            str(existing["owner_principal_id"]) != owner.principal_id
            or str(existing["owner_device_id"]) != owner.device_id
            or int(existing["key_generation"]) > int(record["key_generation"])
        ):
            raise ShareError("SOCIAL_SHARE_ROLLBACK", "sharing grant is stale or conflicts", 4)
        connection.execute(
            "INSERT INTO workspace_share_state(workspace_id,corpus_id,owner_principal_id,"
            "owner_device_id,key_generation) VALUES(?,?,?,?,?) ON CONFLICT(workspace_id) "
            "DO UPDATE SET key_generation=excluded.key_generation",
            (
                workspace_id,
                corpus_id,
                owner.principal_id,
                owner.device_id,
                int(record["key_generation"]),
            ),
        )
        connection.execute(
            "INSERT OR IGNORE INTO workspace_share_events(event_id,workspace_id,corpus_id,"
            "event_kind,principal_id,key_generation,created_at) VALUES(?,?,?,'grant',?,?,?)",
            (
                str(record["grant_id"]),
                workspace_id,
                corpus_id,
                principal_id,
                int(record["key_generation"]),
                int(record["created_at"]),
            ),
        )
        connection.execute("COMMIT")
        return WorkspaceState(
            alias,
            root,
            workspace_id,
            corpus_id,
            owner.principal_id,
            owner.device_id,
            int(record["key_generation"]),
            0,
            0,
        )
    except Exception:
        if connection.in_transaction:
            connection.execute("ROLLBACK")
        raise
    finally:
        connection.close()
