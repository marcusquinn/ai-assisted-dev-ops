"""Monotonic source-state transitions for the performance store."""

from __future__ import annotations

from typing import Any

from performance_contract import canonical_json, timestamp_epoch
from _performance_store_types import SourceStateContext


def _at_or_after(value: str, previous: object) -> bool:
    return previous is None or timestamp_epoch(value) >= timestamp_epoch(str(previous))


def _observation_fields(adapter: str, header: dict[str, Any], evidence_ref: str, partial: bool) -> tuple[str, str, str, str, str]:
    return (
        adapter,
        "partial" if partial else "ready",
        "partial" if partial else header["coverage"],
        canonical_json(sorted(set(header["missing_scopes"]))),
        evidence_ref,
    )


def _preserved_fields(existing: Any) -> tuple[str, str, str, str, object]:
    return (
        str(existing["adapter"]),
        str(existing["status"]),
        str(existing["coverage"]),
        str(existing["missing_scopes_json"]),
        existing["last_evidence_ref"],
    )


def update_source_state(store: Any, context: SourceStateContext) -> bool:
    """Advance only monotonic source observations and successful checkpoints."""
    adapter = context.adapter
    header = context.header
    evidence_ref = context.evidence_ref
    recorded_at = context.recorded_at
    partial = context.partial
    source = header["source"]
    account_ref = header["account_ref"]
    existing = store.connection.execute(
        "SELECT * FROM sources WHERE source=? AND account_ref=?", (source, account_ref)
    ).fetchone()
    observed_at = header["observed_at"]
    latest = existing is None or _at_or_after(observed_at, existing["last_observed_at"])
    prior_success = None if existing is None else existing["last_success_at"]
    successful = not partial and _at_or_after(observed_at, prior_success)
    prior_cursor = None if existing is None else existing["cursor_ref"]
    next_cursor = prior_cursor
    if successful and header["cursor"] is not None:
        next_cursor = store._cursor_ref(source, account_ref, header["cursor"])
    cursor_advanced = bool(successful and header["cursor"] is not None and next_cursor != prior_cursor)
    if existing is None or latest:
        state = _observation_fields(adapter, header, evidence_ref, partial)
    else:
        state = _preserved_fields(existing)
    last_observed_at = observed_at
    if existing is not None and existing["last_observed_at"] is not None and not latest:
        last_observed_at = str(existing["last_observed_at"])
    last_success_at = observed_at if successful else prior_success
    stale_map = store.config["source_stale_after_seconds"]
    stale_after = int(stale_map.get(source, store.config["default_stale_after_seconds"]))
    state_values = (
        source,
        account_ref,
        *state[:4],
        next_cursor,
        last_observed_at,
        last_success_at,
        state[4],
        stale_after,
        recorded_at,
    )
    store.connection.execute(
        "INSERT INTO sources(source,account_ref,adapter,status,coverage,missing_scopes_json,cursor_ref,last_observed_at,last_success_at,last_evidence_ref,stale_after_seconds,updated_at) "
        "VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(source,account_ref) DO UPDATE SET "
        "adapter=excluded.adapter,status=excluded.status,coverage=excluded.coverage,missing_scopes_json=excluded.missing_scopes_json,cursor_ref=excluded.cursor_ref,"
        "last_observed_at=excluded.last_observed_at,last_success_at=excluded.last_success_at,last_evidence_ref=excluded.last_evidence_ref,stale_after_seconds=excluded.stale_after_seconds,updated_at=excluded.updated_at",
        state_values,
    )
    store.connection.execute(
        "INSERT INTO source_history("
        "source,account_ref,adapter,status,coverage,missing_scopes_json,cursor_ref,"
        "last_observed_at,last_success_at,last_evidence_ref,stale_after_seconds,updated_at"
        ") VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
        state_values,
    )
    return cursor_advanced
