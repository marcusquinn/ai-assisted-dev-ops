#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Additive SQLite migrations for the marketing performance store."""

from __future__ import annotations

import sqlite3


def migrate_v2_to_v3(connection: sqlite3.Connection) -> None:
    """Add immutable source and lease history plus ledger record times."""
    consent_columns = {
        str(row["name"])
        for row in connection.execute("PRAGMA table_info(consent_ledger)")
    }
    suppression_columns = {
        str(row["name"])
        for row in connection.execute("PRAGMA table_info(suppression_ledger)")
    }
    connection.execute("BEGIN IMMEDIATE")
    try:
        if "recorded_at" not in consent_columns:
            connection.execute(
                "ALTER TABLE consent_ledger ADD COLUMN recorded_at TEXT"
            )
        if "recorded_at" not in suppression_columns:
            connection.execute(
                "ALTER TABLE suppression_ledger ADD COLUMN recorded_at TEXT"
            )
        connection.execute(
            "UPDATE consent_ledger SET recorded_at=observed_at "
            "WHERE recorded_at IS NULL"
        )
        connection.execute(
            "UPDATE suppression_ledger SET recorded_at=observed_at "
            "WHERE recorded_at IS NULL"
        )
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS source_history (
                state_id INTEGER PRIMARY KEY AUTOINCREMENT,
                source TEXT NOT NULL,
                account_ref TEXT NOT NULL,
                adapter TEXT NOT NULL,
                status TEXT NOT NULL,
                coverage TEXT NOT NULL,
                missing_scopes_json TEXT NOT NULL,
                cursor_ref TEXT,
                last_observed_at TEXT,
                last_success_at TEXT,
                last_evidence_ref TEXT,
                stale_after_seconds INTEGER NOT NULL,
                updated_at TEXT NOT NULL
            )
            """
        )
        connection.execute(
            "CREATE INDEX IF NOT EXISTS source_history_boundary_idx "
            "ON source_history(source,account_ref,updated_at,state_id)"
        )
        connection.execute(
            """
            INSERT INTO source_history(
                source,account_ref,adapter,status,coverage,missing_scopes_json,
                cursor_ref,last_observed_at,last_success_at,last_evidence_ref,
                stale_after_seconds,updated_at
            )
            SELECT
                source,account_ref,adapter,status,coverage,missing_scopes_json,
                cursor_ref,last_observed_at,last_success_at,last_evidence_ref,
                stale_after_seconds,updated_at
            FROM sources
            WHERE NOT EXISTS (
                SELECT 1 FROM source_history
                WHERE source_history.source=sources.source
                  AND source_history.account_ref=sources.account_ref
                  AND source_history.updated_at=sources.updated_at
            )
            """
        )
        connection.execute(
            """
            CREATE TABLE IF NOT EXISTS lease_history (
                lease_event_id INTEGER PRIMARY KEY AUTOINCREMENT,
                source TEXT NOT NULL,
                account_ref TEXT NOT NULL,
                token TEXT NOT NULL,
                action TEXT NOT NULL,
                occurred_at INTEGER NOT NULL,
                expires_at INTEGER
            )
            """
        )
        connection.execute(
            "CREATE INDEX IF NOT EXISTS lease_history_boundary_idx "
            "ON lease_history(source,account_ref,token,occurred_at,lease_event_id)"
        )
        connection.execute(
            """
            INSERT INTO lease_history(
                source,account_ref,token,action,occurred_at,expires_at
            )
            SELECT source,account_ref,token,'acquire',acquired_at,expires_at
            FROM leases
            WHERE NOT EXISTS (
                SELECT 1 FROM lease_history
                WHERE lease_history.token=leases.token
                  AND lease_history.action='acquire'
            )
            """
        )
        connection.execute(
            "CREATE TRIGGER IF NOT EXISTS source_history_no_update "
            "BEFORE UPDATE ON source_history BEGIN "
            "SELECT RAISE(ABORT, 'source history is immutable'); END"
        )
        connection.execute(
            "CREATE TRIGGER IF NOT EXISTS source_history_no_delete "
            "BEFORE DELETE ON source_history BEGIN "
            "SELECT RAISE(ABORT, 'source history is immutable'); END"
        )
        connection.execute(
            "CREATE TRIGGER IF NOT EXISTS lease_history_no_update "
            "BEFORE UPDATE ON lease_history BEGIN "
            "SELECT RAISE(ABORT, 'lease history is immutable'); END"
        )
        connection.execute(
            "CREATE TRIGGER IF NOT EXISTS lease_history_no_delete "
            "BEFORE DELETE ON lease_history BEGIN "
            "SELECT RAISE(ABORT, 'lease history is immutable'); END"
        )
        connection.execute("PRAGMA user_version=3")
        connection.commit()
    except Exception:
        connection.rollback()
        raise


def migrate_v1_to_v2(connection: sqlite3.Connection) -> None:
    """Add period, dimensions, and source-time fields to stored events."""
    connection.execute("BEGIN IMMEDIATE")
    try:
        columns = {
            str(row["name"])
            for row in connection.execute("PRAGMA table_info(events)")
        }
        if "period_start" not in columns:
            connection.execute("ALTER TABLE events ADD COLUMN period_start TEXT")
        if "period_end" not in columns:
            connection.execute("ALTER TABLE events ADD COLUMN period_end TEXT")
        if "dimensions_json" not in columns:
            connection.execute(
                "ALTER TABLE events ADD COLUMN dimensions_json TEXT NOT NULL DEFAULT '{}'"
            )
        if "source_observed_at" not in columns:
            connection.execute(
                "ALTER TABLE events ADD COLUMN source_observed_at TEXT"
            )
        if "source_recorded_at" not in columns:
            connection.execute(
                "ALTER TABLE events ADD COLUMN source_recorded_at TEXT"
            )
        connection.execute("PRAGMA user_version=2")
        connection.commit()
    except Exception:
        connection.rollback()
        raise
