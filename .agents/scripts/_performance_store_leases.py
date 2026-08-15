"""Fenced source/account leases for performance ingestion."""

from __future__ import annotations

import secrets
import time
from typing import Any


def acquire_lease(store: Any, source: str, account_ref: str) -> str:
    """Acquire or replace only an expired exact source/account lease."""
    token = secrets.token_hex(24)
    now_epoch = int(time.time())
    lease_seconds = int(store.config["lease_seconds"])
    store.connection.execute("BEGIN IMMEDIATE")
    try:
        existing = store.connection.execute(
            "SELECT expires_at FROM leases WHERE source=? AND account_ref=?",
            (source, account_ref),
        ).fetchone()
        if existing is not None and int(existing["expires_at"]) > now_epoch:
            raise store.error_type("exact source/account ingest is already leased")
        store.connection.execute(
            "INSERT INTO leases(source,account_ref,token,acquired_at,expires_at) "
            "VALUES(?,?,?,?,?) ON CONFLICT(source,account_ref) DO UPDATE SET "
            "token=excluded.token,acquired_at=excluded.acquired_at,expires_at=excluded.expires_at",
            (source, account_ref, token, now_epoch, now_epoch + lease_seconds),
        )
        store.connection.commit()
    except Exception:
        store.connection.rollback()
        raise
    return token


def release_lease(store: Any, source: str, account_ref: str, token: str) -> None:
    store.connection.execute(
        "DELETE FROM leases WHERE source=? AND account_ref=? AND token=?",
        (source, account_ref, token),
    )
    store.connection.commit()


def recover_expired_leases(store: Any) -> int:
    """Remove only expired mutable lease projections."""
    cursor = store.connection.execute(
        "DELETE FROM leases WHERE expires_at <= ?", (int(time.time()),)
    )
    store.connection.commit()
    return int(cursor.rowcount)
