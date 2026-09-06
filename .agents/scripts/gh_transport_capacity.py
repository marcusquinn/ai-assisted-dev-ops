# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2026 Marcus Quinn
"""Capacity-based local REST admission, not a reserved slice of primary quota.

GitHub's secondary ceilings are 100 concurrent requests and 900 REST points/min.
This history covers supported one-point GETs only, not opaque native commands or
other machines. Server cooldowns remain authoritative for those shared consumers.
"""


PRIMARY_PACING = "local primary pacing from observed demand and reset"


def capacity_wait(budget, resource, row, reserved, now):
    """Return (reason, retry_at); caller holds the admission transaction."""
    budget.db.execute("DELETE FROM admission_history WHERE started<=?", (now - 60,))
    active = budget.db.execute(
        "SELECT COUNT(*) FROM reservation WHERE scope=? AND uncertain=0",
        (budget.scope,),
    ).fetchone()[0]
    if active >= 100:
        return "local REST concurrency at GitHub secondary ceiling", now + 0.1
    count, oldest = budget.db.execute(
        "SELECT COUNT(*),MIN(started) FROM admission_history WHERE scope=?",
        (budget.scope,),
    ).fetchone()
    if count >= 900:
        return "local REST points at GitHub secondary ceiling", oldest + 60
    if not row or row[1] <= now or row[2] > now:
        return "", now
    return primary_wait(budget, resource, row, reserved, now)


def primary_wait(budget, resource, row, reserved, now):
    available = row[0] - reserved
    # Do not turn pacing into a final-point reserve. Atomic admission still
    # prevents overspend and secondary limits still apply above this boundary.
    if available == 1:
        return "", now
    saved = budget.db.execute(
        "SELECT reset,retry_at,remaining FROM pacing WHERE scope=? AND resource=?",
        (budget.scope, resource),
    ).fetchone()
    if saved and saved[0] == row[1] and row[0] <= saved[2]:
        if saved[1] > now:
            return PRIMARY_PACING, saved[1]
        # Keep pacing across long waits even after the 60s demand history expires.
        # The next request consumes one of the available points in this window.
        next_at = now + (row[1] - now) / available
        budget.db.execute("UPDATE pacing SET retry_at=?,remaining=? WHERE scope=? AND resource=?",
                          (next_at, row[0], budget.scope, resource))
        return "", now
    budget.db.execute("DELETE FROM pacing WHERE scope=? AND resource=?", (budget.scope, resource))
    count, oldest, latest = budget.db.execute(
        "SELECT COUNT(*),MIN(started),MAX(started) FROM admission_history "
        "WHERE scope=? AND resource=?", (budget.scope, resource),
    ).fetchone()
    # Measure demand before pacing; do not impose a low startup/burst allowance.
    # When demand would exhaust this window, spread the remaining usable points
    # to reset instead of holding a fixed reserve idle. Every point stays usable.
    if count > 1 and now - oldest >= 10 and available > 0:
        seconds_left = row[1] - now
        demand = (count - 1) / (now - oldest)
        if demand * seconds_left > available:
            retry_at = latest + seconds_left / available
            if retry_at > now:
                budget.db.execute("INSERT OR REPLACE INTO pacing VALUES(?,?,?,?,?)",
                                  (budget.scope, resource, row[1], retry_at, row[0]))
                return PRIMARY_PACING, retry_at
    return "", now
