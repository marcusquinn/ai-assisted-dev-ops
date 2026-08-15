"""Event and governance persistence for the performance store facade."""

from __future__ import annotations

import hashlib
from typing import TYPE_CHECKING, Any, Protocol

from performance_contract import canonical_json, event_for_fingerprint
from _performance_store_types import EventInsertContext, GovernanceContext, QuarantineContext

if TYPE_CHECKING:
    import sqlite3

    class _StoreHost(Protocol):
        connection: sqlite3.Connection

        def pseudonym(self, prefix: str, *parts: str) -> str: ...
        def _source_event_ref(self, source: str, account_ref: str, source_event_id: str) -> str: ...
        def _subject_ref(self, source: str, account_ref: str, source_subject_ref: str) -> str: ...
        def _record_ref(self, event_ref: str, revision: int) -> str: ...
        def _storage_dimensions(self, source: str, account_ref: str, dimensions: dict[str, str | int | float | bool]) -> dict[str, str | int | float | bool]: ...
        def _quarantine(self, context: QuarantineContext) -> str: ...
        def _insert_governance(self, context: GovernanceContext) -> None: ...


def quarantine(store: _StoreHost, context: QuarantineContext) -> str:
    """Persist one pseudonymized quarantine record."""
    source_event_ref = store._source_event_ref(
        context.source, context.account_ref, context.source_event_id
    )
    digest = hashlib.sha256(
        f"{context.source}\0{context.account_ref}\0{source_event_ref}\0{context.reason}\0{context.evidence_ref}".encode()
    ).hexdigest()
    quarantine_ref = f"mkt-quarantine-v1:{digest}"
    store.connection.execute(
        "INSERT OR IGNORE INTO quarantine("
        "quarantine_ref,source,account_ref,source_event_ref,reason,evidence_ref,recorded_at,details_json"
        ") VALUES(?,?,?,?,?,?,?,?)",
        (
            quarantine_ref, context.source, context.account_ref, source_event_ref,
            context.reason, context.evidence_ref, context.recorded_at,
            canonical_json(context.details),
        ),
    )
    return quarantine_ref


def insert_governance(store: _StoreHost, context: GovernanceContext) -> None:
    """Persist consent and suppression ledger entries for one subject."""
    if context.subject_id is None:
        return
    for index, consent in enumerate(context.event["governance"]["consent"]):
        ledger_ref = store.pseudonym(
            "mkt-consent-v1", context.record_ref, str(index), canonical_json(consent)
        )
        store.connection.execute(
            "INSERT OR IGNORE INTO consent_ledger("
            "ledger_ref,subject_id,purpose,state,lawful_basis,source,account_ref,effective_at,observed_at,recorded_at,evidence_ref"
            ") VALUES(?,?,?,?,?,?,?,?,?,?,?)",
            (
                ledger_ref, context.subject_id, consent["purpose"], consent["state"],
                consent["lawful_basis"], context.source, context.account_ref,
                consent["effective_at"], context.observed_at, context.recorded_at,
                context.evidence_ref,
            ),
        )
    suppression = context.event["governance"]["suppression"]
    if suppression is None:
        return
    ledger_ref = store.pseudonym(
        "mkt-suppression-v1", context.record_ref, canonical_json(suppression)
    )
    store.connection.execute(
        "INSERT OR IGNORE INTO suppression_ledger("
        "ledger_ref,subject_id,state,reason,source,account_ref,effective_at,observed_at,recorded_at,evidence_ref"
        ") VALUES(?,?,?,?,?,?,?,?,?,?)",
        (
            ledger_ref, context.subject_id, suppression["state"], suppression["reason"],
            context.source, context.account_ref, suppression["effective_at"],
            context.observed_at, context.recorded_at, context.evidence_ref,
        ),
    )


def _correction_reason(
    store: _StoreHost,
    correction_ref: str,
    event_ref: str,
    values: dict[str, Any],
) -> str | None:
    target = store.connection.execute(
        "SELECT * FROM events WHERE event_ref=? ORDER BY revision DESC LIMIT 1",
        (correction_ref,),
    ).fetchone()
    fields = (
        "subject_id", "campaign_id", "channel", "creative_id", "touchpoint_id",
        "outcome_id", "dimensions_json", "metric_id", "unit", "aggregation",
        "currency", "period_start", "period_end",
    )
    if target is None:
        return "correction_target_pending"
    if any(target[field] != values[field] for field in fields):
        return "correction_target_mismatch"
    existing = store.connection.execute(
        "SELECT event_ref FROM events WHERE correction_ref=? LIMIT 1", (correction_ref,)
    ).fetchone()
    if existing is not None and str(existing["event_ref"]) != event_ref:
        return "correction_target_already_corrected"
    return None


def insert_event(store: _StoreHost, context: EventInsertContext) -> str:
    """Persist one immutable event, rejecting conflicts fail closed."""
    header = context.header
    event = {
        **context.event,
        "scope": {
            **context.event["scope"],
            "dimensions": store._storage_dimensions(
                header["source"], header["account_ref"],
                context.event["scope"]["dimensions"],
            ),
        },
    }
    source, account_ref = header["source"], header["account_ref"]
    event_ref = store._source_event_ref(source, account_ref, event["source_event_id"])
    record_ref = store._record_ref(event_ref, int(event["revision"]))
    fingerprint = hashlib.sha256(
        canonical_json(event_for_fingerprint(event)).encode()
    ).hexdigest()
    existing = store.connection.execute(
        "SELECT payload_fingerprint FROM events WHERE record_ref=?", (record_ref,)
    ).fetchone()
    if existing is not None:
        if str(existing["payload_fingerprint"]) == fingerprint:
            return "duplicate"
        store._quarantine(QuarantineContext(
            source, account_ref, event["source_event_id"],
            "same_revision_payload_conflict", context.evidence_ref,
            context.recorded_at, {"reason": "same_revision_payload_conflict"},
        ))
        return "conflict"
    subject = event["subject"]
    if subject["identity_state"] == "ambiguous":
        store._quarantine(QuarantineContext(
            source, account_ref, event["source_event_id"], "identity_ambiguous",
            context.evidence_ref, context.recorded_at,
            {"reason": "identity_ambiguous", "candidate_count": len(subject["candidate_refs"])},
        ))
        return "quarantined"
    subject_id = None
    if subject["source_ref"] is not None:
        subject_id = store._subject_ref(source, account_ref, subject["source_ref"])
    correction_ref = None
    if event["correction_of"] is not None:
        correction_ref = store._source_event_ref(source, account_ref, event["correction_of"])
    scope, measurement, quality = event["scope"], event["measurement"], event["quality"]
    if correction_ref is not None:
        values = {
            "subject_id": subject_id, **scope, **measurement,
            "dimensions_json": canonical_json(scope["dimensions"]),
        }
        reason = _correction_reason(store, correction_ref, event_ref, values)
        if reason is not None:
            store._quarantine(QuarantineContext(
                source, account_ref, event["source_event_id"], reason,
                context.evidence_ref, context.recorded_at, {"reason": reason},
            ))
            return "quarantined"
    store.connection.execute(
        "INSERT INTO events("
        "record_ref,event_ref,source,account_ref,revision,correction_ref,event_type,occurred_at,observed_at,recorded_at,"
        "source_observed_at,source_recorded_at,subject_id,subject_kind,identity_state,campaign_id,channel,creative_id,"
        "touchpoint_id,outcome_id,dimensions_json,metric_id,value_text,unit,aggregation,currency,period_start,period_end,"
        "confidence,completeness,source_type,collected_by,evidence_ref,payload_fingerprint"
        ") VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        (
            record_ref, event_ref, source, account_ref, event["revision"], correction_ref,
            event["event_type"], event["occurred_at"], header["observed_at"], context.recorded_at,
            event["source_observed_at"], event["source_recorded_at"], subject_id,
            subject["kind"], subject["identity_state"], scope["campaign_id"], scope["channel"],
            scope["creative_id"], scope["touchpoint_id"], scope["outcome_id"],
            canonical_json(scope["dimensions"]), measurement["metric_id"], measurement["value"],
            measurement["unit"], measurement["aggregation"], measurement["currency"],
            measurement["period_start"], measurement["period_end"], quality["confidence"],
            quality["completeness"], quality["source_type"], quality["collected_by"],
            context.evidence_ref, fingerprint,
        ),
    )
    store._insert_governance(GovernanceContext(
        event, record_ref, subject_id, source, account_ref,
        header["observed_at"], context.recorded_at, context.evidence_ref,
    ))
    return "inserted"
