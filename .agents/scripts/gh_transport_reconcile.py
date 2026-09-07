# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Quiescent migration of unresolved GitHub quota evidence to a known owner."""

from __future__ import annotations

import os
import sqlite3
import time
from pathlib import Path


STATE_TABLES = ("quota", "reservation", "binding", "revalidation",
                "admission_history", "pacing")
SCOPED_TABLES = (*STATE_TABLES, "alias")
CLEAR_TABLES = ("quota", "revalidation", "admission_history", "pacing")


class Reconciliation:
    """Apply one atomic, conservative scope migration."""

    def __init__(self, db, source: str, owner: str, now: float, deferred_type):
        self.db = db
        self.source = source
        self.owner = owner
        self.now = now
        self.deferred_type = deferred_type

    def root(self, scope: str) -> str:
        for _ in range(256):
            row = self.db.execute("SELECT target FROM alias WHERE scope=?", (scope,)).fetchone()
            if not row:
                return scope
            scope = row[0]
        raise ValueError("quota scope alias cycle")

    def receipt_state(self) -> dict | None:
        receipt = self.db.execute(
            "SELECT owner FROM reconciliation WHERE source=?", (self.source,)
        ).fetchone()
        if not receipt:
            return None
        if receipt[0] != self.owner:
            raise ValueError("quota state is reconciled to a different configured owner")
        return {"state": "already_reconciled"}

    def known_scopes(self, source_root: str, owner_root: str) -> set[str]:
        scopes = {self.source, self.owner, source_root, owner_root}
        for table in SCOPED_TABLES:
            columns = ("scope", "target") if table == "alias" else ("scope",)
            for column in columns:
                rows = self.db.execute(f"SELECT DISTINCT {column} FROM {table}").fetchall()
                scopes.update(row[0] for row in rows)
        return scopes

    def component(self, scopes: set[str], root: str) -> set[str]:
        return {scope for scope in scopes if self.root(scope) == root}

    def has_state(self, scopes: set[str]) -> bool:
        return any(
            self.db.execute(f"SELECT 1 FROM {table} WHERE scope=? LIMIT 1", (scope,)).fetchone()
            for scope in scopes
            for table in STATE_TABLES
        )

    def require_quiescence(self, scopes: set[str]) -> None:
        reservations = sum(self.db.execute(
            "SELECT COUNT(*) FROM reservation WHERE scope=?", (scope,)
        ).fetchone()[0] for scope in scopes)
        if reservations:
            raise self.deferred_type("quota reconciliation requires no active or uncertain requests")

    def cooldowns(self, scopes: set[str]) -> dict[str, tuple[float, int]]:
        preserved: dict[str, tuple[float, int]] = {}
        for scope in scopes:
            rows = self.db.execute(
                "SELECT resource,blocked_until,quota_limit FROM quota WHERE scope=?", (scope,)
            ).fetchall()
            for resource, blocked_until, quota_limit in rows:
                if blocked_until > self.now:
                    previous = preserved.get(resource, (0.0, quota_limit))
                    preserved[resource] = (max(previous[0], blocked_until),
                                           min(previous[1], quota_limit))
        return preserved

    def rebind(self, scopes: set[str], cooldowns: dict[str, tuple[float, int]]) -> int:
        bindings = sum(self.db.execute(
            "SELECT COUNT(*) FROM binding WHERE scope=?", (scope,)
        ).fetchone()[0] for scope in scopes)
        for scope in scopes:
            for table in CLEAR_TABLES:
                self.db.execute(f"DELETE FROM {table} WHERE scope=?", (scope,))
            self.db.execute("DELETE FROM alias WHERE scope=? OR target=?", (scope, scope))
            self.db.execute("UPDATE binding SET scope=? WHERE scope=?", (self.owner, scope))
        for scope in scopes - {self.owner}:
            self.db.execute("INSERT OR REPLACE INTO alias VALUES(?,?)", (scope, self.owner))
        for resource, (blocked_until, quota_limit) in cooldowns.items():
            self.db.execute(
                "INSERT OR REPLACE INTO quota VALUES(?,?,?,?,?,?,?)",
                (self.owner, resource, 0, blocked_until, self.now, blocked_until, quota_limit),
            )
        return bindings

    def record(self) -> None:
        self.db.execute("INSERT OR REPLACE INTO reconciliation VALUES(?,?,?)",
                        (self.source, self.owner, self.now))

    def run(self) -> dict:
        self.db.execute("CREATE TABLE IF NOT EXISTS reconciliation ("
                        "source TEXT PRIMARY KEY,owner TEXT NOT NULL,reconciled REAL NOT NULL)")
        prior = self.receipt_state()
        if prior:
            return prior
        source_root = self.root(self.source)
        owner_root = self.root(self.owner)
        if source_root == self.owner and owner_root == self.owner:
            self.record()
            return {"state": "already_reconciled"}
        scopes = self.known_scopes(source_root, owner_root)
        source_component = self.component(scopes, source_root)
        owner_component = self.component(scopes, owner_root)
        if source_root != owner_root and self.has_state(owner_component):
            raise ValueError("configured quota owner already has independent state")
        component = source_component | owner_component | {self.source, self.owner}
        self.require_quiescence(component)
        cooldowns = self.cooldowns(component)
        bindings = self.rebind(component, cooldowns)
        self.record()
        return {"state": "reconciled", "bindings_rebound": bindings,
                "cooldowns_preserved": len(cooldowns)}


def reconcile_scope(directory: Path, unresolved_scope: str, owner_scope: str,
                    *, context: tuple[float | None, type[BaseException]]) -> dict:
    """Run reconciliation under an immediate SQLite transaction."""
    if unresolved_scope == owner_scope:
        raise ValueError("a configured GitHub quota owner is required")
    now, deferred_type = context
    path = directory / "admission.sqlite3"
    if not path.is_file() or path.is_symlink():
        return {"state": "no_state"}
    if path.stat().st_uid != os.getuid():
        raise ValueError("transport state file is not owned by this user")
    db = sqlite3.connect(path, timeout=2, isolation_level=None)
    try:
        db.execute("BEGIN IMMEDIATE")
        result = Reconciliation(
            db, unresolved_scope, owner_scope, time.time() if now is None else now, deferred_type
        ).run()
        db.execute("COMMIT")
        return result
    except BaseException:
        if db.in_transaction:
            db.execute("ROLLBACK")
        raise
    finally:
        db.close()
