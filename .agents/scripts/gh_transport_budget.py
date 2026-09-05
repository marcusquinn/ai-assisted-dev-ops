# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Local atomic admission for observed GitHub REST resources, never a data cache.

Only response headers establish quota. Unresolved identities deliberately share
one conservative host scope, rather than granting each token a new allowance.
This database coordinates local processes, not independently configured hosts.
"""

from __future__ import annotations

import hashlib
import os
import sqlite3
import subprocess
import time
import uuid
from contextlib import contextmanager
from pathlib import Path


class Deferred(Exception):
    """No safe admission is currently available."""

    def __init__(self, message: str, *, retryable: bool = False):
        super().__init__(message)
        self.retryable = retryable


def private_directory(path: Path) -> None:
    if not path.is_absolute() or path.is_symlink():
        raise ValueError("unsafe transport state directory")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    if path.stat().st_uid != os.getuid():
        raise ValueError("transport state directory is not owned by this user")
    path.chmod(0o700)


def scope_key(host: str) -> str:
    # Only trusted launch context may name a quota owner. A credential digest is
    # not a quota owner: two PATs can spend the same user's allowance.
    owner = os.environ.get("AIDEVOPS_GH_QUOTA_OWNER", "unresolved")
    return hashlib.sha256(f"{host}\0{owner}".encode()).hexdigest()


def credential_identity(executable: str, host: str) -> tuple[str, bool, dict[str, str]]:
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token:
        try:
            token = subprocess.check_output(
                [executable, "auth", "token", "--hostname", host],
                stderr=subprocess.DEVNULL, timeout=5,
            ).decode().strip()
        except (OSError, ValueError, subprocess.SubprocessError):
            token = "anonymous"
    authenticated = bool(token and token != "anonymous")
    environment = os.environ.copy()
    if authenticated:
        # Pin only the native child, not a long-lived wrapper or worker parent.
        # The hashed identity and the request must use exactly the same token.
        environment["GH_TOKEN"] = token
    return hashlib.sha256(f"{host}\0{token}".encode()).hexdigest(), authenticated, environment


def process_birth(pid: int) -> str:
    try:
        value = subprocess.check_output(
            ["ps", "-p", str(pid), "-o", "lstart="],
            stderr=subprocess.DEVNULL, timeout=2,
        ).strip()
        return hashlib.sha256(value).hexdigest() if value else ""
    except (OSError, subprocess.SubprocessError):
        return ""


class Budget:
    def __init__(self, directory: Path, scope: str, credential: str | None = None):
        private_directory(directory)
        self.path = directory / "admission.sqlite3"
        if self.path.is_symlink():
            raise ValueError("unsafe transport state file")
        # O_NOFOLLOW closes the final-component creation race. SQLite then opens
        # this user-owned file beneath a mode-700 directory.
        fd = os.open(self.path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        os.close(fd)
        if self.path.stat().st_uid != os.getuid():
            raise ValueError("transport state file is not owned by this user")
        self.path.chmod(0o600)
        self.db = sqlite3.connect(self.path, timeout=2, isolation_level=None)
        self.scope = scope
        self.credential = credential or scope
        self.birth = process_birth(os.getpid())
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS quota (
                scope TEXT NOT NULL, resource TEXT NOT NULL,
                remaining INTEGER NOT NULL, reset REAL NOT NULL,
                observed REAL NOT NULL, blocked_until REAL NOT NULL DEFAULT 0,
                quota_limit INTEGER NOT NULL,
                PRIMARY KEY(scope, resource));
            CREATE TABLE IF NOT EXISTS reservation (
                id TEXT PRIMARY KEY, scope TEXT NOT NULL, resource TEXT NOT NULL,
                started REAL NOT NULL, pid INTEGER NOT NULL,
                birth TEXT NOT NULL, credential TEXT NOT NULL,
                uncertain INTEGER NOT NULL DEFAULT 0);
            CREATE TABLE IF NOT EXISTS binding (credential TEXT PRIMARY KEY, scope TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS alias (scope TEXT PRIMARY KEY, target TEXT NOT NULL);
        """)
        with self.transaction():
            self._bind_scope()

    def _root(self, scope: str) -> str:
        for _ in range(256):
            row = self.db.execute("SELECT target FROM alias WHERE scope=?", (scope,)).fetchone()
            if not row:
                return scope
            scope = row[0]
        raise ValueError("quota scope alias cycle")

    def _bind_scope(self) -> None:
        self.scope = self._root(self.scope)
        bound = self.db.execute(
            "SELECT scope FROM binding WHERE credential=?", (self.credential,)
        ).fetchone()
        if bound and self._root(bound[0]) != self.scope:
            previous = self._root(bound[0])
            # A known credential cannot get a second allowance by changing from
            # unresolved to configured owner. Merge, never split live evidence.
            for row in self.db.execute(
                "SELECT resource,remaining,reset,observed,blocked_until,quota_limit "
                "FROM quota WHERE scope=?", (self.scope,)
            ).fetchall():
                old = self.db.execute(
                    "SELECT remaining,reset,observed,blocked_until,quota_limit "
                    "FROM quota WHERE scope=? AND resource=?", (previous, row[0])
                ).fetchone()
                values = row[1:] if not old else (
                    min(row[1], old[0]), max(row[2], old[1]), min(row[3], old[2]),
                    max(row[4], old[3]), min(row[5], old[4]),
                )
                self.db.execute("INSERT OR REPLACE INTO quota VALUES(?,?,?,?,?,?,?)",
                                (previous, row[0], *values))
            self.db.execute("DELETE FROM quota WHERE scope=?", (self.scope,))
            self.db.execute("UPDATE reservation SET scope=? WHERE scope=?", (previous, self.scope))
            self.db.execute("INSERT OR REPLACE INTO alias VALUES(?,?)", (self.scope, previous))
            self.scope = previous
        self.db.execute("INSERT OR REPLACE INTO binding VALUES(?,?)", (self.credential, self.scope))

    @contextmanager
    def transaction(self):
        self.db.execute("BEGIN IMMEDIATE")
        try:
            self.scope = self._root(self.scope)
            yield
            self.db.execute("COMMIT")
        except BaseException:
            self.db.execute("ROLLBACK")
            raise

    def acquire(self, resource: str, *, now: float | None = None) -> str:
        now = time.time() if now is None else now
        with self.transaction():
            # A dead executor is uncertain spend, not free quota. Converting it
            # to debt permits a later serialized observation to recover safely.
            for identity, pid, birth in self.db.execute(
                "SELECT id,pid,birth FROM reservation WHERE scope=? AND uncertain=0",
                (self.scope,),
            ).fetchall():
                try:
                    os.kill(pid, 0)
                    current_birth = self.birth if pid == os.getpid() else process_birth(pid)
                    if birth and current_birth and birth != current_birth:
                        raise ProcessLookupError
                except ProcessLookupError:
                    self.db.execute(
                        "UPDATE reservation SET uncertain=1,started=? WHERE id=?",
                        (now, identity),
                    )
            row = self.db.execute(
                "SELECT remaining,reset,observed,blocked_until,quota_limit FROM quota "
                "WHERE scope=? AND resource=?", (self.scope, resource)
            ).fetchone()
            total, active = self.db.execute(
                "SELECT COUNT(*),COALESCE(SUM(uncertain=0),0) FROM reservation "
                "WHERE scope=? AND resource=?",
                (self.scope, resource),
            ).fetchone()
            if row and row[3] > now:
                raise Deferred("resource cooldown is active")
            floor = min(100, max(1, row[4] // 10)) if row and resource == "core" else 1
            if row and row[1] > now and row[0] - total <= floor:
                raise Deferred("REST resource reserve is protected")
            # Expired/missing observations are not a new 5,000-point grant.
            # Permit one serialized real request to obtain fresh headers.
            fresh = row and 0 <= now - row[2] <= 20 and row[1] > now
            if not fresh and active:
                raise Deferred("waiting for an authoritative quota observation", retryable=True)
            # A small local concurrency ceiling also applies with ample quota.
            if active >= 4:
                raise Deferred("local REST transport concurrency is occupied", retryable=True)
            reservation = uuid.uuid4().hex
            self.db.execute(
                "INSERT INTO reservation(id,scope,resource,started,pid,birth,credential) VALUES(?,?,?,?,?,?,?)",
                (reservation, self.scope, resource, now, os.getpid(), self.birth, self.credential),
            )
            return reservation

    def finish(self, reservation: str, resource: str, headers: dict[str, str],
               *, started: float, now: float | None = None) -> None:
        now = time.time() if now is None else now
        remaining = headers.get("x-ratelimit-remaining", "")
        reset = headers.get("x-ratelimit-reset", "")
        limit = headers.get("x-ratelimit-limit", "")
        actual_resource = headers.get("x-ratelimit-resource", "")
        valid = (actual_resource == resource and remaining.isdecimal() and limit.isdecimal()
                 and 0 <= int(remaining) <= int(limit) <= 1000000
                 and reset.isdecimal() and now < int(reset) <= now + 86400)
        with self.transaction():
            if valid:
                row = self.db.execute(
                    "SELECT remaining,reset,observed,blocked_until FROM quota "
                    "WHERE scope=? AND resource=?", (self.scope, resource)
                ).fetchone()
                available, reset_at = int(remaining), int(reset)
                blocked_until = 0.0
                if row and row[1] > now:
                    # Late responses and unresolved owners with different reset
                    # epochs cannot restore quota observed to have been spent.
                    available = min(available, row[0])
                    reset_at = max(reset_at, row[1])
                    blocked_until = row[3]
                retry_after = headers.get("retry-after", "")
                if retry_after.isdecimal():
                    blocked_until = max(blocked_until, now + int(retry_after))
                if available == 0:
                    blocked_until = max(blocked_until, reset_at)
                self.db.execute(
                    "INSERT OR REPLACE INTO quota VALUES(?,?,?,?,?,?,?)",
                    (self.scope, resource, available, reset_at, now, blocked_until, int(limit)),
                )
                # This response includes charges for completed unknown requests
                # which ended before it started. Never clear concurrent work.
                self.db.execute(
                    "DELETE FROM reservation WHERE scope=? AND resource=? "
                    "AND uncertain=1 AND credential=? AND started<?",
                    (self.scope, resource, self.credential, started)
                )
                self.db.execute("DELETE FROM reservation WHERE id=?", (reservation,))
            else:
                # Uncertain execution may have spent a point. Keep its debt;
                # it is covered only by a later authoritative observation.
                self.db.execute(
                    "UPDATE reservation SET uncertain=1,started=? WHERE id=?",
                    (now, reservation),
                )

    def close(self) -> None:
        self.db.close()
