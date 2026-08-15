"""Transactional ingest orchestration for the performance store facade."""

from __future__ import annotations

import sqlite3
import time
from pathlib import Path
from typing import Any

from performance_contract import (
    PerformanceContractError,
    timestamp_epoch,
    utc_now,
    validate_batch_header,
    validate_event,
)
from _performance_store_types import QuarantineContext


def _complete_campaign_revision(adapter: str, events: list[dict[str, Any]], counts: dict[str, int], header: dict[str, Any]) -> bool:
    if adapter != "campaign" or not events:
        return False
    if counts["inserted"] != len(events):
        return False
    if any(counts[name] for name in ("duplicate", "conflict", "quarantined")):
        return False
    return header["coverage"] == "complete" and not header["missing_scopes"]


def _exact_replay(store: Any, events: list[dict[str, Any]], counts: dict[str, int], header: dict[str, Any], evidence_ref: str) -> bool:
    if counts["duplicate"] != len(events) or counts["inserted"]:
        return False
    if counts["conflict"] or counts["quarantined"]:
        return False
    if not store._events_match_evidence(events, header, evidence_ref):
        return False
    return store._events_are_current(events, header)


def _is_partial(header: dict[str, Any], counts: dict[str, int]) -> bool:
    if header["coverage"] != "complete" or bool(header["missing_scopes"]):
        return True
    return any(counts[name] > 0 for name in ("conflict", "quarantined"))


def validate_events(store: Any, header: dict[str, Any], adapter_errors: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    events: list[dict[str, Any]] = []
    errors = [dict(error) for error in adapter_errors]
    coverage = "partial" if header["missing_scopes"] else header["coverage"]
    for index, raw_event in enumerate(header["events"]):
        try:
            events.append(validate_event(raw_event, coverage, header["missing_scopes"]))
        except PerformanceContractError as error:
            source_event_id = f"record-{index}"
            if isinstance(raw_event, dict) and isinstance(raw_event.get("source_event_id"), str):
                source_event_id = raw_event["source_event_id"]
            errors.append({"index": index, "reason": str(error), "source_event_id": source_event_id})
    return events, errors


def checkpoint_conflicts(store: Any, header: dict[str, Any]) -> bool:
    """Detect a conflicting opaque cursor at the same successful watermark."""
    if header["cursor"] is None:
        return False
    existing = store.connection.execute(
        "SELECT cursor_ref,last_success_at FROM sources WHERE source=? AND account_ref=?",
        (header["source"], header["account_ref"]),
    ).fetchone()
    if existing is None or existing["cursor_ref"] is None or existing["last_success_at"] is None:
        return False
    if timestamp_epoch(header["observed_at"]) != timestamp_epoch(str(existing["last_success_at"])):
        return False
    incoming = store._cursor_ref(header["source"], header["account_ref"], header["cursor"])
    return incoming != str(existing["cursor_ref"])


def _dry_run(header: dict[str, Any], events: list[dict[str, Any]], errors: list[dict[str, Any]], safe_errors: list[dict[str, Any]]) -> dict[str, Any]:
    return {
        "schema": "aidevops.marketing-performance-ingest/v1", "dry_run": True,
        "source": header["source"], "account_ref": header["account_ref"],
        "accepted": len(events), "quarantined": len(errors),
        "coverage": "partial" if errors or header["missing_scopes"] else header["coverage"],
        "errors": safe_errors,
    }


def _record_rejections(store: Any, errors: list[dict[str, Any]], context: tuple[str, str, str, str], counts: dict[str, int]) -> None:
    source, account_ref, evidence_ref, recorded_at = context
    for error in errors:
        source_event_id = str(error.get("source_event_id", f"record-{error.get('index', 'unknown')}"))
        store._quarantine(QuarantineContext(source, account_ref, source_event_id, "adapter_or_contract_rejected", evidence_ref, recorded_at, store._safe_error(error)))
        counts["quarantined"] += 1


def _record_cursor_conflict(store: Any, header: dict[str, Any], context: tuple[str, str, str, str], counts: dict[str, int], complete_campaign: bool) -> None:
    if not store._checkpoint_conflicts(header) or complete_campaign:
        return
    if counts["conflict"] or counts["quarantined"]:
        return
    source, account_ref, evidence_ref, recorded_at = context
    store._quarantine(QuarantineContext(source, account_ref, "batch-cursor", "same_watermark_cursor_conflict", evidence_ref, recorded_at, {"reason": "same_watermark_cursor_conflict"}))
    counts["quarantined"] += 1


def ingest(store: Any, adapter: str, result: Any, dry_run: bool = False) -> dict[str, Any]:
    """Validate, lease, append, and advance one exact source/account cursor."""
    header = validate_batch_header(result.batch)
    if len(header["events"]) + len(result.errors) > int(store.config["max_batch_events"]):
        raise store.error_type("batch exceeds configured event limit")
    events, validation_errors = store._validate_events(header, result.errors)
    safe_errors = [store._safe_error(error) for error in validation_errors]
    if dry_run:
        return _dry_run(header, events, validation_errors, safe_errors)
    source, account_ref = header["source"], header["account_ref"]
    lease_token = store._acquire_lease(source, account_ref)
    evidence_ref, content_digest = store._evidence_ref(source, account_ref, result.raw_bytes)
    raw_path: Path | None = None
    try:
        raw_path, _ = store._write_raw(source, account_ref, content_digest, result.suffix, result.raw_bytes)
        recorded_at = utc_now()
        store.connection.execute("BEGIN IMMEDIATE")
        lease = store.connection.execute("SELECT token,expires_at FROM leases WHERE source=? AND account_ref=?", (source, account_ref)).fetchone()
        if lease is None or str(lease["token"]) != lease_token or int(lease["expires_at"]) <= int(time.time()):
            raise store.error_type("source/account lease expired before commit")
        store.connection.execute(
            "INSERT OR IGNORE INTO evidence(evidence_ref,source,account_ref,sha256,relative_path,observed_at,recorded_at) VALUES(?,?,?,?,?,?,?)",
            (evidence_ref, source, account_ref, content_digest, raw_path.relative_to(store.paths.repo).as_posix(), header["observed_at"], recorded_at),
        )
        counts = {"inserted": 0, "duplicate": 0, "conflict": 0, "quarantined": 0}
        for event in events:
            counts[store._insert_event(event, header, evidence_ref, recorded_at)] += 1
        context = (source, account_ref, evidence_ref, recorded_at)
        _record_rejections(store, validation_errors, context, counts)
        complete_campaign = _complete_campaign_revision(adapter, events, counts, header)
        _record_cursor_conflict(store, header, context, counts, complete_campaign)
        exact_replay = _exact_replay(store, events, counts, header, evidence_ref)
        partial = _is_partial(header, counts)
        cursor_advanced = store._update_source_state(adapter, header, evidence_ref, recorded_at, partial)
        release = store.connection.execute(
            "DELETE FROM leases WHERE source=? AND account_ref=? AND token=?",
            (source, account_ref, lease_token),
        )
        if release.rowcount > 0:
            store.connection.execute(
                "INSERT INTO lease_history("
                "source,account_ref,token,action,occurred_at,expires_at"
                ") VALUES(?,?,?,?,?,NULL)",
                (source, account_ref, lease_token, "release", int(time.time())),
            )
        store.connection.commit()
        return {
            "schema": "aidevops.marketing-performance-ingest/v1", "dry_run": False,
            "source": source, "account_ref": account_ref, "evidence_ref": evidence_ref,
            "accepted": counts["inserted"], "duplicates": counts["duplicate"],
            "quarantined": counts["quarantined"] + counts["conflict"],
            "coverage": "partial" if partial else header["coverage"],
            "cursor_advanced": cursor_advanced, "exact_replay": exact_replay, "errors": safe_errors,
        }
    except Exception:
        store.connection.rollback()
        try:
            store._release_lease(source, account_ref, lease_token)
        except sqlite3.Error:
            pass
        raise
