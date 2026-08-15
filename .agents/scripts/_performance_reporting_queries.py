"""Source, event, and identity queries for performance reporting."""

from __future__ import annotations

import json
import time
from collections import defaultdict
from typing import Any

from performance_contract import PerformanceContractError, timestamp_epoch


def _resolved_quarantine_refs(reporting: Any, now: int) -> set[str]:
    return {
        str(row["target_ref"])
        for row in reporting.connection.execute("SELECT target_ref,effective_at FROM reconciliations WHERE action='resolve_quarantine'")
        if timestamp_epoch(str(row["effective_at"])) <= now
    }


def _known_event_refs(reporting: Any) -> set[str]:
    return {str(row["event_ref"]) for row in reporting.connection.execute("SELECT DISTINCT event_ref FROM events")}


def _unresolved_counts(reporting: Any, resolutions: set[str], event_refs: set[str]) -> dict[tuple[str, str], int]:
    unresolved: dict[tuple[str, str], int] = defaultdict(int)
    for row in reporting.connection.execute("SELECT * FROM quarantine"):
        if str(row["quarantine_ref"]) in resolutions:
            continue
        resolved_pending = str(row["reason"]) == "correction_target_pending" and str(row["source_event_ref"]) in event_refs
        if not resolved_pending:
            unresolved[(str(row["source"]), str(row["account_ref"]))] += 1
    return unresolved


def _active_leases(reporting: Any, now: int) -> set[tuple[str, str]]:
    return {
        (str(row["source"]), str(row["account_ref"]))
        for row in reporting.connection.execute("SELECT source,account_ref FROM leases WHERE expires_at>?", (now,))
    }


def source_rows(reporting: Any, now_epoch: int | None = None) -> list[dict[str, Any]]:
    now = int(time.time()) if now_epoch is None else now_epoch
    resolutions = _resolved_quarantine_refs(reporting, now)
    unresolved = _unresolved_counts(reporting, resolutions, _known_event_refs(reporting))
    active = _active_leases(reporting, now)
    return [_source_record(row, now, unresolved, active) for row in reporting.connection.execute("SELECT * FROM sources ORDER BY source,account_ref")]


def _source_record(row: Any, now: int, unresolved: dict[tuple[str, str], int], active: set[tuple[str, str]]) -> dict[str, Any]:
    key = (str(row["source"]), str(row["account_ref"]))
    observed_at = row["last_observed_at"]
    lag_seconds = None if observed_at is None else int(max(0, now - timestamp_epoch(str(observed_at))))
    stale = lag_seconds is not None and lag_seconds > int(row["stale_after_seconds"])
    status = str(row["status"])
    if unresolved.get(key, 0) > 0:
        status = "partial"
    elif key in active:
        status = "leased"
    elif stale:
        status = "stale"
    return {
        "source": key[0], "account_ref": key[1], "adapter": str(row["adapter"]),
        "status": status, "coverage": str(row["coverage"]),
        "missing_scopes": json.loads(str(row["missing_scopes_json"])),
        "cursor_present": row["cursor_ref"] is not None,
        "last_observed_at": observed_at, "last_success_at": row["last_success_at"],
        "stale_after_seconds": int(row["stale_after_seconds"]), "lag_seconds": lag_seconds,
        "stale": stale, "unresolved_quarantine": unresolved.get(key, 0),
    }


def _event_rows(reporting: Any, source: str | None, account_ref: str | None) -> list[Any]:
    if source is not None and account_ref is not None:
        return list(reporting.connection.execute(
            "SELECT * FROM events WHERE source=? AND account_ref=? ORDER BY occurred_at,recorded_at,record_ref",
            (source, account_ref),
        ))
    if source is not None:
        return list(reporting.connection.execute(
            "SELECT * FROM events WHERE source=? ORDER BY occurred_at,recorded_at,record_ref",
            (source,),
        ))
    if account_ref is not None:
        return list(reporting.connection.execute(
            "SELECT * FROM events WHERE account_ref=? ORDER BY occurred_at,recorded_at,record_ref",
            (account_ref,),
        ))
    return list(reporting.connection.execute("SELECT * FROM events ORDER BY occurred_at,recorded_at,record_ref"))


def _latest_events(rows: list[Any]) -> dict[tuple[str, str, str], Any]:
    latest: dict[tuple[str, str, str], Any] = {}
    for row in rows:
        key = (str(row["source"]), str(row["account_ref"]), str(row["event_ref"]))
        if key not in latest or int(row["revision"]) > int(latest[key]["revision"]):
            latest[key] = row
    return latest


def _current_events(rows: list[Any], latest: dict[tuple[str, str, str], Any]) -> list[Any]:
    correction_refs = {str(row["correction_ref"]) for row in latest.values() if row["correction_ref"] is not None}
    return [
        row for row in rows
        if latest.get((str(row["source"]), str(row["account_ref"]), str(row["event_ref"]))) is row
        and str(row["event_ref"]) not in correction_refs
    ]


def _campaign_events(rows: list[Any], campaign_id: str | None) -> list[Any]:
    return [row for row in rows if campaign_id is None or row["campaign_id"] == campaign_id]


def effective_rows(reporting: Any, history: bool = False, source: str | None = None, account_ref: str | None = None, campaign_id: str | None = None) -> list[Any]:
    rows = _event_rows(reporting, source, account_ref)
    if history:
        return _campaign_events(rows, campaign_id)
    return _campaign_events(_current_events(rows, _latest_events(rows)), campaign_id)


def current_links(reporting: Any, now_timestamp: str) -> tuple[dict[str, str], dict[str, str], list[dict[str, Any]]]:
    latest: dict[str, Any] = {}
    keys: dict[str, tuple[float, float, str]] = {}
    rows = list(reporting.connection.execute("SELECT * FROM identity_links"))
    ordering = lambda row: (timestamp_epoch(str(row["effective_at"])), timestamp_epoch(str(row["recorded_at"])), str(row["link_ref"]))
    history = [dict(row) for row in sorted(rows, key=ordering)]
    boundary = timestamp_epoch(now_timestamp)
    for row in rows:
        member = str(row["member_subject_id"])
        row_key = ordering(row)
        if row_key[0] <= boundary and row_key > keys.get(member, (float("-inf"), float("-inf"), "")):
            latest[member] = row
            keys[member] = row_key
    links: dict[str, str] = {}
    states: dict[str, str] = {}
    for member, row in latest.items():
        action = str(row["action"])
        states[member] = "linked" if action == "link" else "split"
        if action == "link":
            links[member] = str(row["canonical_subject_id"])
    return links, states, history


def assert_identity_graph_acyclic(reporting: Any, effective_at: str) -> None:
    effective_epoch = timestamp_epoch(effective_at)
    boundaries = [str(row["effective_at"]) for row in reporting.connection.execute("SELECT DISTINCT effective_at FROM identity_links") if timestamp_epoch(str(row["effective_at"])) >= effective_epoch]
    for boundary in sorted(boundaries, key=timestamp_epoch):
        links, _states, _history = reporting._current_links(boundary)
        if any(reporting._canonical(subject_id, links)[1] for subject_id in links):
            raise PerformanceContractError("identity reconciliation must not create a cyclic link graph")
