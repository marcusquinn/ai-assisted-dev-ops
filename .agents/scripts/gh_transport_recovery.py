# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Bounded recovery predicates and read-only REST admission diagnostics."""

import os
import sqlite3
import time
from pathlib import Path


def mark_dead_reservations(budget, now, process_birth):
    """A dead executor remains uncertain spend; caller owns the transaction."""
    for identity, pid, birth in budget.db.execute(
        "SELECT id,pid,birth FROM reservation WHERE scope=? AND uncertain=0",
        (budget.scope,),
    ).fetchall():
        try:
            os.kill(pid, 0)
            current_birth = budget.birth if pid == os.getpid() else process_birth(pid)
            if birth and current_birth and birth != current_birth:
                raise ProcessLookupError
        except ProcessLookupError:
            budget.db.execute("UPDATE reservation SET uncertain=1,started=? WHERE id=?",
                              (now, identity))


def reserve_probe_allowed(row, active, total, previous, now):
    if active or row[0] - total < 1:
        return False
    last_probe = previous[0] if previous else row[2]
    return now - max(row[2], last_probe) >= 60


def probe_recovers(budget, reservation, resource, row, reset_at):
    """Called inside the existing transaction; never changes quota or ownership."""
    if not row:
        return False
    probe = budget.db.execute(
        "SELECT reservation_id FROM revalidation WHERE scope=? AND resource=?",
        (budget.scope, resource),
    ).fetchone()
    own = budget.db.execute(
        "SELECT started,credential FROM reservation WHERE id=? AND scope=? AND resource=?",
        (reservation, budget.scope, resource),
    ).fetchone()
    if not probe or not own:
        return False
    if own[1] != budget.credential or reservation != probe[0]:
        return False
    owners = sum(budget._root(binding[0]) == budget.scope for binding in
                 budget.db.execute("SELECT scope FROM binding").fetchall())
    if owners != 1 and not budget.attributed:
        return False
    return own[0] >= row[2] and reset_at >= row[1]


def admission_status(directory: Path, scope: str, *, attributed: bool = False) -> dict:
    """Read local core admission evidence without credentials, HTTP or mutations."""
    path = directory / "admission.sqlite3"
    if not path.is_file() or path.is_symlink():
        return {"state": "unknown"}
    db = sqlite3.connect(path.as_uri() + "?mode=ro", uri=True, timeout=2)
    try:
        requested_scope = scope
        for _ in range(256):
            alias = db.execute("SELECT target FROM alias WHERE scope=?", (scope,)).fetchone()
            if not alias:
                break
            scope = alias[0]
        else:
            return {"state": "unknown"}
        bindings = sum(1 for binding in db.execute("SELECT scope FROM binding").fetchall()
                       if _read_root(db, binding[0]) == scope)
        ambiguity = None
        if attributed and requested_scope != scope:
            ambiguity = "configured_owner_requires_reconciliation"
        elif not attributed and bindings > 1:
            ambiguity = "unresolved_scope_has_multiple_credentials"
        diagnostics = {"scope_mode": "configured" if attributed else "unresolved",
                       "bound_credentials": bindings, "ambiguity": ambiguity}
        if ambiguity:
            diagnostics["reconcile_command"] = (
                "python3 .agents/scripts/gh_transport_budget.py reconcile"
            )
        row = db.execute(
            "SELECT remaining,reset,observed,blocked_until,quota_limit FROM quota "
            "WHERE scope=? AND resource='core'", (scope,),
        ).fetchone()
        if not row:
            return {"state": "unknown", **diagnostics}
        reserved = db.execute(
            "SELECT COUNT(*) FROM reservation WHERE scope=? AND resource='core'", (scope,),
        ).fetchone()[0]
        now = time.time()
        floor = 0
        state = "available"
        if row[3] > now:
            state = "cooldown"
        elif row[1] <= now or row[2] > now:
            state = "unknown"
        elif row[0] - reserved <= floor:
            state = "exhausted"
        return {"state": state, "source": "local_response_headers", **diagnostics,
                "remaining": row[0],
                "limit": row[4], "reserved": reserved, "floor": floor,
                "blocked_until": row[3],
                "reset": int(row[1]), "observation_age_seconds": max(0, int(now - row[2]))}
    finally:
        db.close()


def _read_root(db, scope: str) -> str:
    for _ in range(256):
        alias = db.execute("SELECT target FROM alias WHERE scope=?", (scope,)).fetchone()
        if not alias:
            return scope
        scope = alias[0]
    raise ValueError("quota scope alias cycle")
