#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Idempotent column upgrades for the private social corpus schema."""

from __future__ import annotations

import sqlite3


def add_sync_run_v2_columns(connection: sqlite3.Connection) -> None:
    columns = {
        str(row["name"])
        for row in connection.execute("PRAGMA table_info(sync_runs)").fetchall()
    }
    if "stream" not in columns:
        connection.execute(
            "ALTER TABLE sync_runs ADD COLUMN stream TEXT NOT NULL DEFAULT ''"
        )
    if "run_kind" not in columns:
        connection.execute(
            "ALTER TABLE sync_runs ADD COLUMN run_kind TEXT NOT NULL DEFAULT 'sync'"
        )
    if "collector_id" not in columns:
        connection.execute("ALTER TABLE sync_runs ADD COLUMN collector_id TEXT")
    if "started_at" not in columns:
        connection.execute("ALTER TABLE sync_runs ADD COLUMN started_at INTEGER")
    if "completed_at" not in columns:
        connection.execute("ALTER TABLE sync_runs ADD COLUMN completed_at INTEGER")
    if "request_hash" not in columns:
        connection.execute("ALTER TABLE sync_runs ADD COLUMN request_hash TEXT")


def add_outbound_v4_columns(connection: sqlite3.Connection) -> None:
    columns = {
        str(row["name"])
        for row in connection.execute("PRAGMA table_info(outbound_operations)").fetchall()
    }
    additions = (
        (
            "destination_remote_id",
            "ALTER TABLE outbound_operations ADD COLUMN destination_remote_id TEXT",
        ),
        ("subject", "ALTER TABLE outbound_operations ADD COLUMN subject TEXT"),
        (
            "subject_sha256",
            "ALTER TABLE outbound_operations ADD COLUMN subject_sha256 TEXT",
        ),
        (
            "intent_version",
            "ALTER TABLE outbound_operations ADD COLUMN "
            "intent_version INTEGER NOT NULL DEFAULT 1",
        ),
    )
    for column, statement in additions:
        if column not in columns:
            connection.execute(statement)


def add_source_v5_columns(connection: sqlite3.Connection) -> None:
    table = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='fetch_batches'"
    ).fetchone()
    if table is None:
        return
    columns = {
        str(row["name"])
        for row in connection.execute("PRAGMA table_info(fetch_batches)").fetchall()
    }
    if "evidence_id" not in columns:
        connection.execute(
            "ALTER TABLE fetch_batches ADD COLUMN evidence_id TEXT "
            "REFERENCES evidence_sources(evidence_id)"
        )
