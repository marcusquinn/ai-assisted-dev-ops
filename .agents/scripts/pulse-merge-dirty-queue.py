#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bounded local PR wake hints and leases; never a cache of merge authority."""

from __future__ import annotations

import json
import os
import re
import sqlite3
import sys
import time
import uuid
from pathlib import Path

from gh_transport_budget import private_directory, process_birth


MAX_HINTS = 4096
RETENTION_SECONDS = 604800


def target(repo: str, pr: str) -> tuple[str, int]:
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*/[A-Za-z0-9_.-]+", repo):
        raise ValueError("invalid repository")
    if repo.split("/")[1] in {".", ".."} or not pr.isdecimal() or not 0 < int(pr) <= 2147483647:
        raise ValueError("invalid PR")
    return repo.lower(), int(pr)


def alive(pid: int, birth: str) -> bool:
    if pid <= 0:
        return True  # Corrupt ownership is not permission for a second actor.
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    current = process_birth(pid)
    return not birth or not current or current == birth


class Queue:
    def __init__(self, directory: Path):
        private_directory(directory)
        path = directory / "work.sqlite3"
        fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        os.close(fd)
        if path.stat().st_uid != os.getuid():
            raise ValueError("foreign queue owner")
        path.chmod(0o600)
        self.db = sqlite3.connect(path, timeout=2, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("""CREATE TABLE IF NOT EXISTS work (
            repo TEXT NOT NULL, pr INTEGER NOT NULL, generation TEXT NOT NULL,
            updated REAL NOT NULL, wake_until REAL NOT NULL DEFAULT 0,
            nonce TEXT NOT NULL DEFAULT '', pid INTEGER NOT NULL DEFAULT 0,
            birth TEXT NOT NULL DEFAULT '', PRIMARY KEY(repo,pr))""")

    def row(self, repo: str, pr: int):
        row = self.db.execute("SELECT * FROM work WHERE repo=? AND pr=?", (repo, pr)).fetchone()
        if row and row["nonce"] and not alive(row["pid"], row["birth"]):
            self.db.execute("UPDATE work SET nonce='',pid=0,birth='',wake_until=0 WHERE repo=? AND pr=?", (repo, pr))
            return self.db.execute("SELECT * FROM work WHERE repo=? AND pr=?", (repo, pr)).fetchone()
        return row

    def capacity(self, now: float) -> None:
        # Expiry removes hints, not GitHub work. Polling remains authoritative.
        self.db.execute("DELETE FROM work WHERE nonce='' AND updated<?", (now - RETENTION_SECONDS,))
        if self.db.execute("SELECT count(*) FROM work").fetchone()[0] >= MAX_HINTS:
            raise ValueError("queue capacity reached; polling recovery required")

    def enqueue(self, repo: str, pr: int, now: float) -> str:
        repo = repo.lower()
        row = self.row(repo, pr)
        if not row:
            self.capacity(now)
            self.db.execute("INSERT INTO work(repo,pr,generation,updated) VALUES(?,?,?,?)",
                            (repo, pr, "", now))
        wake = not row or (not row["nonce"] and row["wake_until"] <= now)
        self.db.execute("UPDATE work SET generation=?,updated=?,wake_until=? WHERE repo=? AND pr=?",
                        (uuid.uuid4().hex, now, now + 30 if wake else (row["wake_until"] if row else 0), repo, pr))
        return "wake" if wake else "coalesced"

    def claim(self, repo: str, pr: int, pid: int, now: float) -> dict | None:
        repo = repo.lower()
        row = self.row(repo, pr)
        if row and row["nonce"]:
            return None
        birth = process_birth(pid)
        if not birth or not alive(pid, birth):
            raise ValueError("claim owner unavailable")
        if not row:
            self.capacity(now)
            self.db.execute("INSERT INTO work(repo,pr,generation,updated) VALUES(?,?,?,?)",
                            (repo, pr, "", now))
        nonce = uuid.uuid4().hex
        self.db.execute("UPDATE work SET nonce=?,pid=?,birth=?,wake_until=0 WHERE repo=? AND pr=?",
                        (nonce, pid, birth, repo, pr))
        return {"repo": repo, "pr": pr, "generation": row["generation"] if row else "",
                "nonce": nonce, "pid": pid, "birth": birth}

    def finish(self, receipt: dict, handled: bool) -> None:
        repo, pr = target(receipt["repo"], str(receipt["pr"]))
        row = self.row(repo, pr)
        if not row or row["nonce"] != receipt["nonce"] or row["pid"] != receipt["pid"] or row["birth"] != receipt["birth"]:
            raise ValueError("queue lease ownership changed")
        same_generation = row["generation"] == receipt["generation"]
        if same_generation and (handled or not row["generation"]):
            self.db.execute("DELETE FROM work WHERE repo=? AND pr=?", (repo, pr))
        else:
            # New events during processing ALWAYS survive the old completion.
            self.db.execute("UPDATE work SET nonce='',pid=0,birth='' WHERE repo=? AND pr=?", (repo, pr))

    def priority(self, repo: str, now: float) -> str:
        rows = self.db.execute("SELECT pr FROM work WHERE repo=? AND generation!='' AND updated>=? ORDER BY updated DESC LIMIT ?",
                               (repo.lower(), now - RETENTION_SECONDS, MAX_HINTS)).fetchall()
        return "|" + "|".join(str(row[0]) for row in rows) + "|" if rows else ""


def main(args: list[str]) -> int:
    directory = Path(os.environ.get("AIDEVOPS_PULSE_MERGE_DIRTY_QUEUE_DIR",
                                    str(Path.home() / ".aidevops/state/pulse-merge-dirty")))
    queue = None
    try:
        command = args[0]
        if command == "priority" and not (directory / "work.sqlite3").exists():
            print("")
            return 0
        queue = Queue(directory)
        queue.db.execute("BEGIN IMMEDIATE")
        now = time.time()
        output = None
        if command == "enqueue" and len(args) == 3:
            output = queue.enqueue(*target(args[1], args[2]), now)
        elif command == "claim" and len(args) == 4:
            receipt = queue.claim(*target(args[1], args[2]), int(args[3]), now)
            if receipt is None:
                queue.db.execute("ROLLBACK")
                return 75
            output = json.dumps(receipt, separators=(",", ":"))
        elif command == "finish" and len(args) == 3:
            if args[2] not in {"0", "1"}:
                raise ValueError("invalid handled flag")
            queue.finish(json.loads(args[1]), args[2] == "1")
        elif command == "priority" and len(args) == 2:
            output = queue.priority(args[1], now)
        else:
            raise ValueError("invalid queue command")
        queue.db.execute("COMMIT")
        if output is not None:
            print(output)
        return 0
    except (OSError, ValueError, TypeError, KeyError, IndexError, sqlite3.Error):
        if queue is not None and queue.db.in_transaction:
            queue.db.execute("ROLLBACK")
        print("pulse merge queue unavailable; retain polling recovery", file=sys.stderr)
        return 2
    finally:
        if queue is not None:
            queue.db.close()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
