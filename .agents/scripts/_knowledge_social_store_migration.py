#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Schema-v6 raw identity migration for private social stores."""

from __future__ import annotations

import sqlite3

from _knowledge_social_store_raw import collector_envelope, read_raw_payload, store_root
from _knowledge_social_store_support import SHA256_HEX, SocialStoreError


def _canonical_fetch_identity_v6(
    connection: sqlite3.Connection, row: sqlite3.Row
) -> tuple[str, str]:
    payload, digest, provider, connection_id = read_raw_payload(
        connection, str(row["blob_ref"])
    )
    envelope = collector_envelope(
        payload, provider, connection_id, required=False
    )
    if envelope is None:
        if str(row["batch_id"]) != digest:
            raise SocialStoreError("legacy fetch batch raw identity cannot be migrated")
        return digest, str(row["response_hash"])
    stored_scope = (
        row["provider"],
        row["connection_id"],
        row["stream"],
        row["request_hash"],
        row["completed_at"],
    )
    raw_scope = (
        provider,
        connection_id,
        envelope["stream"],
        envelope["request_hash"],
        envelope["observed_at"],
    )
    if stored_scope != raw_scope:
        raise SocialStoreError("legacy fetch batch metadata conflicts with raw evidence")
    return digest, str(envelope["response_sha256"])


def _canonical_fetch_rows_v6(
    connection: sqlite3.Connection,
) -> list[tuple[sqlite3.Row, str, str]]:
    rows = connection.execute("SELECT * FROM fetch_batches ORDER BY batch_id").fetchall()
    return [
        (row, *_canonical_fetch_identity_v6(connection, row)) for row in rows
    ]


def _deduplicate_fetch_rows_v6(
    migrated: list[tuple[sqlite3.Row, str, str]],
) -> dict[str, tuple[sqlite3.Row, str]]:
    canonical: dict[str, tuple[sqlite3.Row, str]] = {}
    signatures: dict[str, tuple[object, ...]] = {}
    for row, batch_id, response_hash in migrated:
        metadata = (
            row["provider"],
            row["connection_id"],
            row["stream"],
            row["request_hash"],
            row["blob_ref"],
            row["resource_count"],
            row["budget_units"],
            row["started_at"],
            row["completed_at"],
            row["terminal_status"],
            response_hash,
        )
        existing = signatures.setdefault(batch_id, metadata)
        if existing != metadata:
            raise SocialStoreError("legacy fetch batch aliases have conflicting metadata")
        canonical.setdefault(batch_id, (row, response_hash))
    return canonical


def _create_fetch_batches_v6(
    connection: sqlite3.Connection,
    canonical: dict[str, tuple[sqlite3.Row, str]],
) -> None:
    connection.execute(
        """CREATE TABLE fetch_batches_v6 (
             batch_id TEXT PRIMARY KEY, provider TEXT NOT NULL,
             connection_id TEXT NOT NULL, stream TEXT NOT NULL,
             request_hash TEXT, response_hash TEXT NOT NULL, blob_ref TEXT NOT NULL,
             resource_count INTEGER NOT NULL, budget_units INTEGER NOT NULL DEFAULT 0,
             started_at TEXT, completed_at TEXT NOT NULL, terminal_status TEXT NOT NULL,
             evidence_id TEXT REFERENCES evidence_sources(evidence_id))"""
    )
    connection.executemany(
        """INSERT INTO fetch_batches_v6(
             batch_id,provider,connection_id,stream,request_hash,response_hash,blob_ref,
             resource_count,budget_units,started_at,completed_at,terminal_status,evidence_id)
           VALUES(?,?,?,?,?,?,?,?,?,?,?,?,NULL)""",
        [
            (
                batch_id,
                row["provider"],
                row["connection_id"],
                row["stream"],
                row["request_hash"],
                response_hash,
                row["blob_ref"],
                row["resource_count"],
                row["budget_units"],
                row["started_at"],
                row["completed_at"],
                row["terminal_status"],
            )
            for batch_id, (row, response_hash) in sorted(canonical.items())
        ],
    )


def _rewrite_projection_aliases_v6(
    connection: sqlite3.Connection,
    migrated: list[tuple[sqlite3.Row, str, str]],
) -> None:
    aliases = [
        (batch_id, row["batch_id"])
        for row, batch_id, _ in migrated
        if row["batch_id"] != batch_id
    ]
    for statement in (
        "UPDATE objects SET batch_id=? WHERE batch_id=?",
        "UPDATE activities SET batch_id=? WHERE batch_id=?",
        "UPDATE media SET batch_id=? WHERE batch_id=?",
        "UPDATE coverage_records SET batch_id=? WHERE batch_id=?",
        "UPDATE tombstones SET batch_id=? WHERE batch_id=?",
    ):
        connection.executemany(statement, aliases)


def migrate_fetch_batches_v6(connection: sqlite3.Connection) -> None:
    """Make raw-envelope hashes canonical batch IDs without body-hash uniqueness."""
    connection.execute("DROP TRIGGER IF EXISTS fetch_batch_evidence_ai")
    connection.execute("DROP VIEW IF EXISTS canonical_evidence_projections")
    migrated = _canonical_fetch_rows_v6(connection)
    _create_fetch_batches_v6(connection, _deduplicate_fetch_rows_v6(migrated))
    connection.execute("DROP TABLE fetch_batches")
    connection.execute("ALTER TABLE fetch_batches_v6 RENAME TO fetch_batches")
    _rewrite_projection_aliases_v6(connection, migrated)


def _orphan_projection_batch_ids(connection: sqlite3.Connection) -> list[str]:
    rows = connection.execute(
        """SELECT p.batch_id FROM (
             SELECT batch_id FROM objects UNION SELECT batch_id FROM activities
             UNION SELECT batch_id FROM media UNION SELECT batch_id FROM coverage_records
             UNION SELECT batch_id FROM tombstones
           ) p LEFT JOIN fetch_batches f ON f.batch_id=p.batch_id
           WHERE f.batch_id IS NULL ORDER BY p.batch_id"""
    ).fetchall()
    return [str(row["batch_id"]) for row in rows]


def _raw_envelope_for_batch(
    connection: sqlite3.Connection, batch_id: str
) -> tuple[dict[str, object], str]:
    if SHA256_HEX.fullmatch(batch_id) is None:
        raise SocialStoreError("legacy social projection has an invalid batch ID")
    root = store_root(connection)
    raw_root = root / "sources" / "social" / "raw"
    candidates = list(raw_root.glob(f"*/*/{batch_id}.json.gz"))
    if len(candidates) != 1:
        raise SocialStoreError(
            "legacy social projection raw evidence is missing or ambiguous"
        )
    blob_ref = candidates[0].relative_to(root).as_posix()
    payload, digest, provider, connection_id = read_raw_payload(connection, blob_ref)
    if digest != batch_id:
        raise SocialStoreError("legacy social raw evidence hash does not match")
    envelope = collector_envelope(payload, provider, connection_id, required=True)
    if envelope is None:
        raise SocialStoreError("legacy social raw evidence envelope is invalid")
    return envelope, blob_ref


def recover_orphaned_fetch_batches_v6(connection: sqlite3.Connection) -> None:
    for batch_id in _orphan_projection_batch_ids(connection):
        envelope, blob_ref = _raw_envelope_for_batch(connection, batch_id)
        resource_count = connection.execute(
            """SELECT (SELECT count(*) FROM objects WHERE batch_id=?) +
                      (SELECT count(*) FROM activities WHERE batch_id=?) +
                      (SELECT count(*) FROM media WHERE batch_id=?)""",
            (batch_id, batch_id, batch_id),
        ).fetchone()[0]
        connection.execute(
            """INSERT INTO fetch_batches(
                 batch_id,provider,connection_id,stream,request_hash,response_hash,
                 blob_ref,resource_count,budget_units,started_at,completed_at,
                 terminal_status)
               VALUES(?,?,?,?,?,?,?,?,?,?,?,?)""",
            (
                batch_id,
                envelope["provider"],
                envelope["connection_id"],
                envelope["stream"],
                envelope["request_hash"],
                envelope["response_sha256"],
                blob_ref,
                resource_count,
                0,
                envelope["observed_at"],
                envelope["observed_at"],
                "legacy_recovered",
            ),
        )
